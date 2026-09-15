import Foundation

// MARK: - Resets the account is given

/// Something to say about the early resets a provider gives out — Codex
/// hands them to accounts every so often, and each runs out unspent after
/// about a month.
public struct ResetCreditNotice: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// The count went up by this many since the reading before.
        case given(Int)
        /// This credit runs out within a day.
        case expiring(ResetCredit)
    }

    public var provider: ProviderID
    public var kind: Kind
    /// How many the account holds now.
    public var available: Int
    /// Identifies the notice, so it is said once.
    public var key: String
}

public enum ResetCreditCheck {
    /// How long before a deadline the reminder comes.
    public static let expiryLead: TimeInterval = 24 * 3600

    /// The notices a new reading brings.
    ///
    /// A reset given needs a reading from before to compare with: the first
    /// one ever read sets the baseline and says nothing, the way the pace
    /// alerts do. A reading from before that carried no count had none to
    /// spend. A reminder is keyed by the credit, so each speaks once, however
    /// many times the list is read in its last day.
    public static func notices(
        provider: ProviderID,
        previous: UsageSnapshot?,
        current: ResetCredits?,
        notified: [String],
        now: Date = .now) -> [ResetCreditNotice]
    {
        guard let current else { return [] }
        var out: [ResetCreditNotice] = []
        if let previous {
            let before = previous.resetCredits?.available ?? 0
            if current.available > before {
                let key = "\(provider.rawValue)|given|\(current.available)"
                out.append(ResetCreditNotice(provider: provider, kind: .given(current.available - before), available: current.available, key: key))
            }
        }
        for credit in current.credits {
            guard let expiresAt = credit.expiresAt, expiresAt > now, expiresAt.timeIntervalSince(now) <= expiryLead else { continue }
            let key = "\(provider.rawValue)|expiring|\(credit.id ?? String(Int(expiresAt.timeIntervalSince1970)))"
            guard !notified.contains(key) else { continue }
            out.append(ResetCreditNotice(provider: provider, kind: .expiring(credit), available: current.available, key: key))
        }
        return out
    }
}

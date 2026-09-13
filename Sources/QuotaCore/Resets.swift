import Foundation

// MARK: - Window resets

/// A window that reset between two readings: the 5-hour window rolling over,
/// the week starting again, a billing month turning.
public struct ResetEvent: Sendable, Equatable, Identifiable {
    public let provider: ProviderID
    public let windowID: String
    /// The window's own name — its scope ("Fable") where it has one.
    public let name: String
    public let previousUsed: Double
    public let usedNow: Double
    /// When the window reset: the reset time the previous reading promised,
    /// or when the reset was noticed if it promised none.
    public let resetAt: Date
    public let noticedAt: Date

    public var id: String { "\(provider.rawValue)|\(windowID)" }

    public init(provider: ProviderID, windowID: String, name: String, previousUsed: Double, usedNow: Double, resetAt: Date, noticedAt: Date) {
        self.provider = provider
        self.windowID = windowID
        self.name = name
        self.previousUsed = previousUsed
        self.usedNow = usedNow
        self.resetAt = resetAt
        self.noticedAt = noticedAt
    }

    /// Noticed close enough to the reset to call it news. A reading cached
    /// from before the app was quit, replaced hours after the reset, is not.
    public var isFresh: Bool { noticedAt.timeIntervalSince(resetAt) <= ResetDetector.freshness }

    /// The window had been run close to empty — the reset that is worth a
    /// notification, because it is the one someone was waiting for.
    public var followedHeavyUse: Bool { previousUsed >= ResetDetector.heavyUse }
}

public enum ResetDetector {
    /// A drop smaller than this is noise or a provider rounding, not a reset.
    public static let minimumDrop: Double = 10
    /// How long after the reset it still counts as having just happened.
    public static let freshness: TimeInterval = 30 * 60
    /// "Heavy use" for the notification: the window was at least this full.
    public static let heavyUse: Double = 90

    /// The windows present in both readings that reset in between.
    ///
    /// A reset needs two things: the figure fell by at least `minimumDrop`
    /// points, and the reading says time ran out — the previous reset time
    /// has passed, or the reset time moved forward by at least a tenth of the
    /// window (at least ten minutes). A drop alone is a top-up or a provider
    /// correcting itself; a moved reset time alone is a window that rolled
    /// with nothing used.
    public static func events(provider: ProviderID, previous: UsageSnapshot?, current: UsageSnapshot, now: Date = Date()) -> [ResetEvent] {
        guard let previous, !accountChanged(from: previous, to: current) else { return [] }
        let before = Dictionary(previous.windows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var events: [ResetEvent] = []
        for window in current.windows {
            guard let old = before[window.id], let was = old.usedPercent, let used = window.usedPercent,
                  was - used >= minimumDrop
            else { continue }
            let passed = old.resetsAt.map { $0 <= now.addingTimeInterval(60) } ?? false
            var moved = false
            if let oldReset = old.resetsAt, let newReset = window.resetsAt {
                let span = Double(window.windowSeconds ?? old.windowSeconds ?? 0)
                moved = newReset.timeIntervalSince(oldReset) >= max(600, span / 10)
            }
            guard passed || moved else { continue }
            let resetAt = min(old.resetsAt ?? now, now)
            events.append(ResetEvent(
                provider: provider,
                windowID: window.id,
                name: window.scope ?? window.title,
                previousUsed: was,
                usedNow: used,
                resetAt: resetAt,
                noticedAt: now))
        }
        return events
    }

    /// The CLI was signed in to another account between the two readings.
    /// Its figures and reset times are simply someone else's — a drop there
    /// is not a reset. Unknown on either side counts as the same account.
    public static func accountChanged(from previous: UsageSnapshot, to current: UsageSnapshot) -> Bool {
        guard let before = previous.account?.lowercased(), let after = current.account?.lowercased(),
              !before.isEmpty, !after.isEmpty
        else { return false }
        return before != after
    }

    /// When to read a provider again so a reset shows when it happens rather
    /// than at the next scheduled refresh: a little after the earliest
    /// upcoming reset among its windows. Providers take a moment to roll the
    /// window over, hence the grace.
    public static func nextCheck(for snapshot: UsageSnapshot, after now: Date = Date(), grace: TimeInterval = 20) -> Date? {
        snapshot.windows.compactMap(\.resetsAt).filter { $0 > now }.min()?.addingTimeInterval(grace)
    }
}

/// Whether a reset raises a system notification.
public enum ResetNotifyMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case off
    /// Only after the window had been used past `ResetDetector.heavyUse`.
    case afterHeavyUse
    case always

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off: L10n.t("Off", "关闭")
        case .afterHeavyUse: L10n.t("After heavy use", "用满后")
        case .always: L10n.t("Always", "每次")
        }
    }

    public func shouldNotify(_ event: ResetEvent) -> Bool {
        guard event.isFresh else { return false }
        switch self {
        case .off: return false
        case .afterHeavyUse: return event.followedHeavyUse
        case .always: return true
        }
    }
}

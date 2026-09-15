import CryptoKit
import Foundation

// MARK: - Quota Run: readings, runs and personal records

/// One window of one successful provider reading: what the run ledger keeps,
/// and — once the owner has joined — what `POST /snapshots` sends.
///
/// Times are whole Unix seconds, as they go over the wire. `seq` is the
/// ledger's own counter, which the uploader's cursor follows; it never leaves
/// the Mac.
public struct RunReading: Sendable, Equatable {
    public var seq: Int
    public var provider: String
    public var plan: String?
    public var accountDigest: String?
    public var windowKey: String
    /// English and language-independent where the length is known, so a
    /// board does not show one window under two names.
    public var windowTitle: String
    /// 0 when the provider reports no length.
    public var windowSeconds: Int
    public var scope: String?
    public var usedPercent: Double
    public var resetsAt: Int?
    public var observedAt: Int
    /// `api` or `local`.
    public var source: String

    public init(
        seq: Int = 0,
        provider: String,
        plan: String? = nil,
        accountDigest: String? = nil,
        windowKey: String,
        windowTitle: String,
        windowSeconds: Int,
        scope: String? = nil,
        usedPercent: Double,
        resetsAt: Int?,
        observedAt: Int,
        source: String = "api")
    {
        self.seq = seq
        self.provider = provider
        self.plan = plan
        self.accountDigest = accountDigest
        self.windowKey = windowKey
        self.windowTitle = windowTitle
        self.windowSeconds = windowSeconds
        self.scope = scope
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.observedAt = observedAt
        self.source = source
    }

    /// The readings one refresh of one provider yields: every window that
    /// carries a percentage. Balances and credit counts without one have no
    /// place on a used-percent board.
    public static func from(provider: ProviderID, snapshot: UsageSnapshot) -> [RunReading] {
        let observed = Int(snapshot.fetchedAt.timeIntervalSince1970)
        let digest = snapshot.account.flatMap { RunAccountDigest.digest(provider: provider.rawValue, account: $0) }
        let plan = snapshot.planName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return snapshot.windows.compactMap { window in
            guard let used = window.usedPercent, used.isFinite else { return nil }
            let seconds = max(window.windowSeconds ?? 0, 0)
            let scope = window.scope?.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanScope = (scope?.isEmpty ?? true) ? nil : scope
            return RunReading(
                provider: provider.rawValue,
                plan: (plan?.isEmpty ?? true) ? nil : plan,
                accountDigest: digest,
                windowKey: RunMath.windowKey(seconds: seconds, scope: cleanScope),
                windowTitle: RunMath.canonicalTitle(seconds: seconds, scope: cleanScope, fallback: window.title),
                windowSeconds: seconds,
                scope: cleanScope,
                // Two decimals is finer than any provider reports and keeps
                // the ledger file from carrying 36.499999999999996.
                usedPercent: (min(max(used, 0), 100) * 100).rounded() / 100,
                resetsAt: window.resetsAt.map { Int($0.timeIntervalSince1970.rounded()) },
                observedAt: observed,
                source: provider.runSource)
        }
    }
}

extension ProviderID {
    /// `local` for the one provider whose figures come from a file on this Mac
    /// rather than from the provider — Windsurf's cached plan.
    public var runSource: String {
        self == .windsurf ? "local" : "api"
    }
}

// MARK: - Account digest

/// A one-way digest of the provider account, so the server can tell two Quota
/// accounts claiming one subscription apart without ever holding the email.
public enum RunAccountDigest {
    public static func digest(provider: String, account: String) -> String? {
        let cleaned = account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleaned.isEmpty else { return nil }
        let input = "quota-run-account-v1\n" + provider + "\n" + cleaned
        return SHA256.hash(data: Data(input.utf8)).hexString
    }

    /// Lower-case hex SHA-256, the only form a digest travels in.
    public static func isDigest(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// The account as this Mac may show it, and nowhere else: `p***@gmail.com`
    /// for an email, the first four characters and an ellipsis for an id.
    public static func masked(_ account: String) -> String {
        let cleaned = account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let at = cleaned.lastIndex(of: "@"), at != cleaned.startIndex, cleaned.index(after: at) != cleaned.endIndex {
            return "\(cleaned[cleaned.startIndex])***\(cleaned[at...])"
        }
        // A short id would be shown whole by its first four characters.
        return String(cleaned.prefix(cleaned.count > 8 ? 4 : 1)) + "…"
    }
}

/// A provider account this Mac is signed in with, as the Quota Run page
/// needs it: the digest to look up and unbind, and the masked form to show.
/// The email or id itself is not kept.
public struct RunLocalAccount: Equatable, Sendable, Identifiable {
    public var provider: String
    public var digest: String
    public var masked: String
    /// An email, which a quota.run sign-in could claim; not Codex's account id.
    public var isEmail: Bool

    public var id: String { digest }
    public var providerID: ProviderID? { ProviderID(rawValue: provider) }

    public init(provider: String, digest: String, masked: String, isEmail: Bool) {
        self.provider = provider
        self.digest = digest
        self.masked = masked
        self.isEmail = isEmail
    }

    public init?(provider: ProviderID, account: String) {
        guard let digest = RunAccountDigest.digest(provider: provider.rawValue, account: account) else { return nil }
        self.init(
            provider: provider.rawValue, digest: digest, masked: RunAccountDigest.masked(account),
            isEmail: RunAccountDigest.masked(account).contains("@"))
    }

    /// One per provider, the latest account each reported, in the providers'
    /// own order.
    public static func merge(_ list: [RunLocalAccount], with account: RunLocalAccount) -> [RunLocalAccount] {
        var next = list.filter { $0.provider != account.provider }
        next.append(account)
        let order = Dictionary(uniqueKeysWithValues: ProviderID.allCases.enumerated().map { ($1.rawValue, $0) })
        return next.sorted { (order[$0.provider] ?? .max, $0.provider) < (order[$1.provider] ?? .max, $1.provider) }
    }
}

/// Where a provider account stands, for its row on the Quota Run page.
public enum RunAccountStanding: Equatable, Sendable {
    /// quota.run has no reading from it on this user yet.
    case notUploaded
    case bound(RunProviderAccount)
    /// Owned through a verified sign-in email.
    case verified(RunProviderAccount)
    /// Another Quota account owns it; runs from it are flagged.
    case elsewhere(RunProviderAccount)
    /// On this Mac's exclusion list: not uploaded until bound again.
    case unbound

    public static func of(digest: String, lookups: [String: RunProviderAccount], excluded: Set<String>) -> RunAccountStanding {
        if excluded.contains(digest) { return .unbound }
        guard let account = lookups[digest] else { return .notUploaded }
        if account.status == .elsewhere { return .elsewhere(account) }
        return account.verifiedByEmail ? .verified(account) : .bound(account)
    }

    /// The server's id, when there is something on quota.run to unbind.
    public var account: RunProviderAccount? {
        switch self {
        case let .bound(account), let .verified(account), let .elsewhere(account): account
        case .notUploaded, .unbound: nil
        }
    }
}

extension Sequence where Element == UInt8 {
    /// Lower-case hex, as the contract writes every digest.
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

extension SHA256Digest {
    var hexString: String { Array(self).hexString }
}

// MARK: - Runs

public enum RunTier: String, Codable, Sendable, CaseIterable {
    case verified
    case standard
    case flagged

    public var displayName: String {
        switch self {
        case .verified: L10n.t("Verified", "已验证")
        case .standard: L10n.t("Standard", "普通")
        case .flagged: L10n.t("Flagged", "存疑")
        }
    }
}

/// One reset period of one window for one provider account, worked out from
/// the readings exactly as the server does — for personal records only. The
/// server decides every published result.
public struct RunRecord: Codable, Sendable, Equatable, Identifiable {
    public var provider: String
    /// The plan name as last reported, for display.
    public var plan: String?
    public var planNorm: String
    public var windowKey: String
    public var windowSeconds: Int
    public var scope: String?
    public var windowTitle: String
    /// The group's reset time, rounded to five minutes.
    public var resetsAt: Int
    public var windowStart: Int
    public var peakPercent: Double
    public var lastPercent: Double
    public var secondsTo50: Int?
    public var secondsTo90: Int?
    public var secondsTo100: Int?
    public var completedAt: Int?
    public var firstObservedAt: Int
    public var lastObservedAt: Int
    public var readingCount: Int
    /// This Mac's estimate of the server's tier.
    public var tier: RunTier
    /// A reading carried no provider account digest: the server stores such a
    /// run as unranked, off every board, unless it is flagged anyway.
    public var unbound: Bool = false

    public var id: String { "\(provider)|\(planNorm)|\(windowKey)|\(resetsAt)" }
    /// The board this run would be ranked on.
    public var boardKey: String { "\(provider)|\(planNorm)|\(windowKey)" }

    /// Whether the server would rank it, as far as this Mac can tell.
    public var wouldRank: Bool { tier != .flagged && !unbound }
}

extension RunRecord {
    private enum CodingKeys: String, CodingKey {
        case provider, plan, planNorm, windowKey, windowSeconds, scope, windowTitle, resetsAt, windowStart, peakPercent, lastPercent
        case secondsTo50, secondsTo90, secondsTo100, completedAt, firstObservedAt, lastObservedAt, readingCount, tier, unbound
    }

    /// Bests kept from before `unbound` existed decode as bound: a record
    /// that fails to decode would take every stored best with it.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decode(String.self, forKey: .provider)
        plan = try c.decodeIfPresent(String.self, forKey: .plan)
        planNorm = try c.decode(String.self, forKey: .planNorm)
        windowKey = try c.decode(String.self, forKey: .windowKey)
        windowSeconds = try c.decode(Int.self, forKey: .windowSeconds)
        scope = try c.decodeIfPresent(String.self, forKey: .scope)
        windowTitle = try c.decode(String.self, forKey: .windowTitle)
        resetsAt = try c.decode(Int.self, forKey: .resetsAt)
        windowStart = try c.decode(Int.self, forKey: .windowStart)
        peakPercent = try c.decode(Double.self, forKey: .peakPercent)
        lastPercent = try c.decode(Double.self, forKey: .lastPercent)
        secondsTo50 = try c.decodeIfPresent(Int.self, forKey: .secondsTo50)
        secondsTo90 = try c.decodeIfPresent(Int.self, forKey: .secondsTo90)
        secondsTo100 = try c.decodeIfPresent(Int.self, forKey: .secondsTo100)
        completedAt = try c.decodeIfPresent(Int.self, forKey: .completedAt)
        firstObservedAt = try c.decode(Int.self, forKey: .firstObservedAt)
        lastObservedAt = try c.decode(Int.self, forKey: .lastObservedAt)
        readingCount = try c.decode(Int.self, forKey: .readingCount)
        tier = try c.decode(RunTier.self, forKey: .tier)
        unbound = (try? c.decodeIfPresent(Bool.self, forKey: .unbound)) ?? false
    }
}

/// The contract's run arithmetic as pure functions, so the fixtures in the
/// tests pin the same numbers the server computes.
public enum RunMath {
    /// Rankable window lengths: an hour to 32 days.
    public static let minimumWindow = 3_600
    public static let maximumWindow = 2_764_800
    /// A reading this high counts as having reached 100%: providers round, and
    /// a window that stops at 99.6% is spent.
    public static let completeAt = 99.5
    public static let resetGrain = 300

    /// `"Pro 20x"` → `pro20x`: lower-case, ASCII letters and digits only.
    public static func planNorm(_ plan: String?) -> String {
        guard let plan else { return "" }
        return String(plan.lowercased().unicodeScalars.filter { scalar in
            (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9")
        }.map(Character.init))
    }

    public static func windowKey(seconds: Int?, scope: String?) -> String {
        "\(max(seconds ?? 0, 0)):\(scope ?? "")"
    }

    /// The nearest five-minute mark, halves rounding up. A reset time that a
    /// provider computes from "now + n seconds" jitters by a second or two per
    /// reading; the grain is what keeps one reset period one run.
    public static func roundedReset(_ resetsAt: Int) -> Int {
        let grain = resetGrain
        let shifted = resetsAt + grain / 2
        return (shifted >= 0 ? shifted / grain : (shifted - grain + 1) / grain) * grain
    }

    public static func isRankable(windowSeconds: Int, resetsAt: Int?) -> Bool {
        resetsAt != nil && windowSeconds >= minimumWindow && windowSeconds <= maximumWindow
    }

    public static let windowSlack = 300

    /// The server refuses a reading of a rankable window taken more than five
    /// minutes outside that window (`outside_window`) — a provider still
    /// reporting last period's reset a moment after rolling over, say — so
    /// neither the upload nor the local runs count one.
    public static func isInsideWindow(_ reading: RunReading) -> Bool {
        guard isRankable(windowSeconds: reading.windowSeconds, resetsAt: reading.resetsAt),
              let resetsAt = reading.resetsAt else { return true }
        return reading.observedAt >= resetsAt - reading.windowSeconds - windowSlack
            && reading.observedAt <= resetsAt + windowSlack
    }

    /// The window's name in English, independent of the interface language:
    /// the board shows one name per window whoever uploaded the reading.
    /// Mirrors `WindowTitle.forSeconds`; a window with no length keeps the
    /// provider's own title.
    public static func canonicalTitle(seconds: Int, scope: String?, fallback: String) -> String {
        guard seconds > 0 else { return fallback }
        let base: String
        switch seconds {
        case 604_800: base = "Weekly window"
        case 86_400: base = "Daily window"
        case 2_592_000, 2_678_400, 2_628_000: base = "Monthly window"
        default:
            if seconds % 86_400 == 0 {
                base = "\(seconds / 86_400)-day window"
            } else if seconds % 3_600 == 0 {
                base = "\(seconds / 3_600)-hour window"
            } else {
                base = "\(max(1, seconds / 60))-minute window"
            }
        }
        return scope.map { "\(base) · \($0)" } ?? base
    }

    /// Whether the local logs show tokens for `source` between two instants.
    public typealias ActivityCheck = (_ source: String, _ from: Int, _ to: Int) -> Bool

    /// Every rankable run in a set of readings, newest reset first.
    public static func runs(from readings: [RunReading], activity: ActivityCheck = { _, _, _ in false }) -> [RunRecord] {
        var groups: [String: [RunReading]] = [:]
        for reading in readings {
            guard isRankable(windowSeconds: reading.windowSeconds, resetsAt: reading.resetsAt),
                  let resetsAt = reading.resetsAt, isInsideWindow(reading) else { continue }
            let key = "\(reading.provider)|\(planNorm(reading.plan))|\(reading.windowKey)|\(roundedReset(resetsAt))"
            groups[key, default: []].append(reading)
        }
        return groups.values.compactMap { run(from: $0, activity: activity) }
            .sorted { $0.resetsAt == $1.resetsAt ? $0.id < $1.id : $0.resetsAt > $1.resetsAt }
    }

    /// One run from the readings of one group. `nil` for an empty or
    /// unrankable group.
    public static func run(from group: [RunReading], activity: ActivityCheck = { _, _, _ in false }) -> RunRecord? {
        let sorted = group.sorted { $0.observedAt == $1.observedAt ? $0.seq < $1.seq : $0.observedAt < $1.observedAt }
        guard let first = sorted.first, let last = sorted.last, let reset = first.resetsAt,
              isRankable(windowSeconds: first.windowSeconds, resetsAt: reset)
        else { return nil }
        let resetsAt = roundedReset(reset)
        let windowStart = resetsAt - first.windowSeconds
        func secondsTo(_ threshold: Double) -> Int? {
            sorted.first { $0.usedPercent >= threshold }.map { $0.observedAt - windowStart }
        }
        let to100 = secondsTo(completeAt)
        let completedAt = to100.map { windowStart + $0 }
        return RunRecord(
            provider: first.provider,
            plan: last.plan,
            planNorm: planNorm(first.plan),
            windowKey: first.windowKey,
            windowSeconds: first.windowSeconds,
            scope: first.scope,
            windowTitle: last.windowTitle,
            resetsAt: resetsAt,
            windowStart: windowStart,
            peakPercent: sorted.map(\.usedPercent).max() ?? 0,
            lastPercent: last.usedPercent,
            secondsTo50: secondsTo(50),
            secondsTo90: secondsTo(90),
            secondsTo100: to100,
            completedAt: completedAt,
            firstObservedAt: first.observedAt,
            lastObservedAt: last.observedAt,
            readingCount: sorted.count,
            tier: tier(sorted: sorted, completedAt: completedAt, activity: activity),
            unbound: sorted.contains { $0.accountDigest == nil })
    }

    // MARK: Tiers

    public static let monotonicSlack = 2.0
    public static let implausibleRise = 60.0
    public static let implausibleSpan = 300
    public static let firstReadingCeiling = 50.0
    public static let maximumGap = 1_200

    /// Rule 2: no reading more than two points below an earlier one.
    public static func isMonotonic(_ sorted: [RunReading]) -> Bool {
        var highest = -Double.infinity
        for reading in sorted {
            if reading.usedPercent < highest - monotonicSlack { return false }
            highest = max(highest, reading.usedPercent)
        }
        return true
    }

    /// Rule 3: no rise of more than 60 points between two readings under five
    /// minutes apart. Any pair, not only neighbours: two 40-point steps
    /// inside four minutes are the same implausible jump taken twice.
    public static func isPlausible(_ sorted: [RunReading]) -> Bool {
        var start = 0
        for (index, reading) in sorted.enumerated() {
            while reading.observedAt - sorted[start].observedAt >= implausibleSpan { start += 1 }
            for earlier in sorted[start..<index] where reading.usedPercent - earlier.usedPercent > implausibleRise {
                return false
            }
        }
        return true
    }

    /// Rule 4: starts at or below half, and no gap over 20 minutes up to the
    /// 100% reading (or the last one).
    public static func isCovered(_ sorted: [RunReading]) -> Bool {
        guard let first = sorted.first, first.usedPercent <= firstReadingCeiling else { return false }
        let end = sorted.firstIndex { $0.usedPercent >= completeAt } ?? (sorted.count - 1)
        guard end > 0 else { return true }
        for index in 1...end where sorted[index].observedAt - sorted[index - 1].observedAt > maximumGap {
            return false
        }
        return true
    }

    /// The providers whose runs need token activity from their CLI's logs.
    public static func activitySource(for provider: String) -> String? {
        switch provider {
        case ProviderID.codex.rawValue: "codex"
        case ProviderID.claude.rawValue: "claude"
        default: nil
        }
    }

    /// All five rules, with the binding of rule 1 unknowable on this Mac: a
    /// digest on every reading passes it locally (a run missing one is
    /// `unbound` besides), and only the server can say another Quota account
    /// owns the provider account.
    public static func tier(sorted: [RunReading], completedAt: Int?, activity: ActivityCheck) -> RunTier {
        guard isMonotonic(sorted), isPlausible(sorted) else { return .flagged }
        guard let first = sorted.first, let last = sorted.last else { return .standard }
        let digested = sorted.allSatisfy { $0.accountDigest != nil }
        var active = true
        if let source = activitySource(for: first.provider) {
            active = activity(source, first.observedAt, completedAt ?? last.observedAt)
        }
        return digested && isCovered(sorted) && active ? .verified : .standard
    }

    // MARK: Personal bests

    /// Fastest to 100% and highest peak per board, from the runs worked out
    /// now and the bests kept from before — the ledger forgets readings after
    /// 60 days, a record should not go with them. A run in both sets is taken
    /// from `runs`, which has seen more of it. Flagged runs never count.
    public static func bests(from runs: [RunRecord], keeping stored: [PersonalBest] = []) -> [PersonalBest] {
        var seen = Set(runs.map(\.id))
        var candidates = runs
        // The two slots of a stored best may hold one run or two.
        for kept in stored.flatMap({ [$0.fastest, $0.highestPeak] }).compactMap({ $0 }) where seen.insert(kept.id).inserted {
            candidates.append(kept)
        }
        var boards: [String: [RunRecord]] = [:]
        for run in candidates where run.tier != .flagged {
            boards[run.boardKey, default: []].append(run)
        }
        return boards.map { key, runs in
            let fastest = runs.filter { $0.secondsTo100 != nil }.min { a, b in
                a.secondsTo100! == b.secondsTo100! ? (a.completedAt ?? 0) < (b.completedAt ?? 0) : a.secondsTo100! < b.secondsTo100!
            }
            let peak = runs.min { a, b in
                if a.peakPercent != b.peakPercent { return a.peakPercent > b.peakPercent }
                return (a.completedAt ?? a.lastObservedAt) < (b.completedAt ?? b.lastObservedAt)
            }
            let latest = runs.max { $0.lastObservedAt < $1.lastObservedAt } ?? runs[0]
            return PersonalBest(
                id: key,
                provider: latest.provider,
                plan: latest.plan,
                planNorm: latest.planNorm,
                windowKey: latest.windowKey,
                windowSeconds: latest.windowSeconds,
                scope: latest.scope,
                fastest: fastest,
                highestPeak: peak)
        }
        .sorted { a, b in
            switch (a.fastest?.secondsTo100, b.fastest?.secondsTo100) {
            case (nil, nil): return a.id < b.id
            case (nil, _): return false
            case (_, nil): return true
            case let (x?, y?): return x == y ? a.id < b.id : x < y
            }
        }
    }

    /// The run of each board that is still under way, fullest first.
    public static func inProgress(_ runs: [RunRecord], now: Int) -> [RunRecord] {
        var current: [String: RunRecord] = [:]
        for run in runs where run.resetsAt > now && run.windowStart <= now {
            if let kept = current[run.boardKey], kept.lastObservedAt >= run.lastObservedAt { continue }
            current[run.boardKey] = run
        }
        return current.values.sorted { $0.lastPercent == $1.lastPercent ? $0.id < $1.id : $0.lastPercent > $1.lastPercent }
    }
}

/// A board's records on this Mac.
public struct PersonalBest: Codable, Sendable, Equatable, Identifiable {
    /// `provider|planNorm|windowKey`.
    public var id: String
    public var provider: String
    public var plan: String?
    public var planNorm: String
    public var windowKey: String
    public var windowSeconds: Int
    public var scope: String?
    public var fastest: RunRecord?
    public var highestPeak: RunRecord?

    public init(
        id: String, provider: String, plan: String?, planNorm: String, windowKey: String,
        windowSeconds: Int, scope: String?, fastest: RunRecord?, highestPeak: RunRecord?)
    {
        self.id = id
        self.provider = provider
        self.plan = plan
        self.planNorm = planNorm
        self.windowKey = windowKey
        self.windowSeconds = windowSeconds
        self.scope = scope
        self.fastest = fastest
        self.highestPeak = highestPeak
    }
}

// MARK: - Formatting

public enum RunFormat {
    /// "2h 37m", "1d 4h", "41m" — how long a window took to fill. Compact and
    /// untranslated in English, like the board; spelled out in Chinese.
    public static func duration(_ seconds: Int) -> String {
        let total = max(seconds, 0)
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 {
            return L10n.t("\(days)d \(hours)h", "\(days) 天 \(hours) 小时")
        }
        if hours > 0 {
            return L10n.t("\(hours)h \(minutes)m", "\(hours) 小时 \(minutes) 分")
        }
        if minutes > 0 { return L10n.t("\(minutes)m", "\(minutes) 分钟") }
        return L10n.t("under a minute", "不到 1 分钟")
    }

    /// The window as the interface names it: "Weekly window", "周窗口", with
    /// the scope after a dot.
    public static func windowName(seconds: Int, scope: String?, fallback: String) -> String {
        guard seconds > 0 else { return fallback }
        let base = WindowTitle.forSeconds(seconds)
        return scope.map { "\(base) · \($0)" } ?? base
    }
}

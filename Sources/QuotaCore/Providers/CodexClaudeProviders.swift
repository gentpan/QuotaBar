import Foundation

// MARK: - Codex (ChatGPT OAuth via ~/.codex/auth.json → wham/usage)

public struct CodexProvider: QuotaProvider {
    public let id = ProviderID.codex

    public init() {}

    public func isConfigured(config: ConfigStore) -> Bool {
        LocalCredentials.codexAuth() != nil
    }

    public func fetch(config: ConfigStore) async throws -> UsageSnapshot {
        guard let auth = LocalCredentials.codexAuth() else {
            throw ProviderError.notConfigured(hint: ProviderID.codex.setupHint)
        }
        var headers = [
            "Authorization": "Bearer \(auth.accessToken)",
            "Accept": "application/json",
            "User-Agent": "QuotaBar",
        ]
        if let accountId = auth.accountId {
            headers["ChatGPT-Account-Id"] = accountId
        }
        let url = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
        let response = try await HTTP.get(url, headers: headers).requireOK()
        var snapshot = try Self.parse(response.data, fallbackAccount: auth.accountId)
        // The usage reply only counts the resets the account was given; what
        // they are, when each runs out and how many came in all is one list
        // away. A failure there costs those, not the reading (issue #3).
        if let available = snapshot.resetCredits?.available {
            let account = auth.accountId ?? snapshot.account
            var list = Self.creditList.reusable(account: account, available: available)
            if list == nil,
               let response = try? await HTTP.get(
                   URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!, headers: headers).requireOK(),
               let read = Self.resetCreditList(response.data)
            {
                Self.creditList.store(read, account: account, available: available)
                list = read
            }
            if let list {
                snapshot.resetCredits?.credits = list.credits
                snapshot.resetCredits?.totalEarned = list.totalEarned
            }
        }
        return snapshot
    }

    static let creditList = ResetCreditListCache()

    /// What the credit list says: the available credits and how many the
    /// account was ever given.
    struct ResetCreditList: Equatable, Sendable {
        var credits: [ResetCredit]
        var totalEarned: Int?
    }

    /// The last credit list read, so it is not read with every refresh: the
    /// endpoint answers 429 when polled. Asked again when the count changes —
    /// a reset given or spent — when a deadline it listed has passed, or
    /// after an hour.
    final class ResetCreditListCache: @unchecked Sendable {
        private struct Entry {
            let account: String?
            let available: Int
            let list: ResetCreditList
            let readAt: Date
        }

        private let lock = NSLock()
        private var entry: Entry?

        func reusable(account: String?, available: Int, now: Date = .now) -> ResetCreditList? {
            lock.withLock {
                guard let entry, entry.account == account, entry.available == available,
                      now.timeIntervalSince(entry.readAt) < 3600,
                      !entry.list.credits.contains(where: { ($0.expiresAt ?? .distantFuture) <= now })
                else { return nil }
                return entry.list
            }
        }

        func store(_ list: ResetCreditList, account: String?, available: Int, now: Date = .now) {
            lock.withLock { entry = Entry(account: account, available: available, list: list, readAt: now) }
        }
    }

    /// `{"credits":[{"id":…,"reset_type":"codex_rate_limits","status":"available",
    /// "granted_at":"2026-06-17T00:00:00Z","expires_at":"2026-07-17T00:00:00Z",
    /// "title":"Full reset (Weekly + 5 hr)"}],"available_count":1,
    /// "total_earned_count":3}` — the shape the Codex CLI reads. The credits
    /// still available, soonest deadline first and the ones that never expire
    /// last; nil for a reply that is not that list.
    static func resetCreditList(_ data: Data, now: Date = .now) -> ResetCreditList? {
        struct Credit: Decodable {
            let id: String?
            let status: String?
            let title: String?
            let grantedAt: String?
            let expiresAt: String?
            enum CodingKeys: String, CodingKey {
                case id, status, title
                case grantedAt = "granted_at"
                case expiresAt = "expires_at"
            }
        }
        struct Body: Decodable {
            let credits: [Credit]?
            let totalEarnedCount: Int?
            enum CodingKeys: String, CodingKey {
                case credits
                case totalEarnedCount = "total_earned_count"
            }
        }
        guard let body = try? JSONDecoder().decode(Body.self, from: data),
              body.credits != nil || body.totalEarnedCount != nil
        else { return nil }
        let credits = (body.credits ?? [])
            .filter { ($0.status ?? "available") == "available" }
            .map { credit in
                ResetCredit(
                    id: credit.id,
                    title: credit.title.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 },
                    grantedAt: Dates.parseISO(credit.grantedAt),
                    expiresAt: Dates.parseISO(credit.expiresAt))
            }
            .filter { ($0.expiresAt ?? .distantFuture) > now }
            .sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
        return ResetCreditList(credits: credits, totalEarned: body.totalEarnedCount)
    }

    // MARK: Response shape

    struct Window: Decodable {
        let usedPercent: Double?
        /// Window length; the label is derived from this rather than assumed —
        /// a Pro plan reports a single 7-day primary window, not a 5-hour one.
        let limitWindowSeconds: Int?
        let resetAfterSeconds: Int?
        let resetAt: Double?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case limitWindowSeconds = "limit_window_seconds"
            case resetAfterSeconds = "reset_after_seconds"
            case resetAt = "reset_at"
        }
    }

    struct RateLimit: Decodable {
        let primaryWindow: Window?
        let secondaryWindow: Window?

        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }

    struct AdditionalLimit: Decodable {
        let limitName: String?
        let meteredFeature: String?
        let rateLimit: RateLimit?

        enum CodingKeys: String, CodingKey {
            case limitName = "limit_name"
            case meteredFeature = "metered_feature"
            case rateLimit = "rate_limit"
        }
    }

    struct Credits: Decodable {
        let hasCredits: Bool?
        let unlimited: Bool?
        let balance: String?
        let overageLimitReached: Bool?

        enum CodingKeys: String, CodingKey {
            case hasCredits = "has_credits"
            case unlimited
            case balance
            case overageLimitReached = "overage_limit_reached"
        }
    }

    struct ResetCreditsBody: Decodable {
        let availableCount: Int?
        let applicableAvailableCount: Int?

        enum CodingKeys: String, CodingKey {
            case availableCount = "available_count"
            case applicableAvailableCount = "applicable_available_count"
        }
    }

    struct Body: Decodable {
        let email: String?
        let accountId: String?
        let planType: String?
        let rateLimit: RateLimit?
        let additionalRateLimits: [AdditionalLimit]?
        let credits: Credits?
        let rateLimitResetCredits: ResetCreditsBody?

        enum CodingKeys: String, CodingKey {
            case email
            case accountId = "account_id"
            case planType = "plan_type"
            case rateLimit = "rate_limit"
            case additionalRateLimits = "additional_rate_limits"
            case credits
            case rateLimitResetCredits = "rate_limit_reset_credits"
        }
    }

    /// The plan as ChatGPT sells it. The usage endpoint names the two Pro
    /// tiers by their internal ids — `prolite` is the 5× plan, `pro` the 20×
    /// one — so capitalising the id showed both as "Pro". The mapping is the
    /// one openusage uses against the same endpoint; anything else is the id
    /// with its underscores turned into spaces.
    public static func planName(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "prolite": return "Pro 5x"
        case "pro": return "Pro 20x"
        case "self_serve_business_prolite": return "Business Premium"
        default:
            return raw.split(separator: "_")
                .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
                .joined(separator: " ")
        }
    }

    /// Pure parse step, kept separate from the network call so it can be
    /// tested against recorded responses.
    public static func parse(_ data: Data, fallbackAccount: String? = nil) throws -> UsageSnapshot {
        let body: Body
        do {
            body = try JSONDecoder().decode(Body.self, from: data)
        } catch {
            throw ProviderError.badResponse
        }

        var windows: [UsageWindow] = []
        windows.append(contentsOf: convert(body.rateLimit, prefix: nil, active: true))
        for extra in body.additionalRateLimits ?? [] {
            let name = extra.limitName ?? extra.meteredFeature
            windows.append(contentsOf: convert(extra.rateLimit, prefix: name, active: false))
        }
        if let creditWindow = creditWindow(body.credits) {
            windows.append(creditWindow)
        }

        // Kept at zero too: an account that was given resets before still has
        // a count to show, once the list says how many it had.
        var resetCredits: ResetCredits?
        if let raw = body.rateLimitResetCredits, let available = raw.availableCount, available >= 0 {
            resetCredits = ResetCredits(
                available: available,
                applicable: raw.applicableAvailableCount)
        }

        return UsageSnapshot(
            planName: planName(body.planType),
            account: body.email ?? body.accountId ?? fallbackAccount,
            windows: windows,
            resetCredits: resetCredits)
    }

    private static func convert(_ limit: RateLimit?, prefix: String?, active: Bool) -> [UsageWindow] {
        guard let limit else { return [] }
        return [limit.primaryWindow, limit.secondaryWindow]
            .compactMap { $0 }
            .compactMap { window -> UsageWindow? in
                guard let percent = window.usedPercent else { return nil }
                let base = window.limitWindowSeconds.map(WindowTitle.forSeconds)
                    ?? L10n.t("Usage", "用量")
                let resetsAt = Dates.parseEpoch(window.resetAt)
                    ?? window.resetAfterSeconds.map { Date().addingTimeInterval(TimeInterval($0)) }
                return UsageWindow(
                    title: prefix.map { "\($0) · \(base)" } ?? base,
                    usedPercent: percent,
                    resetsAt: resetsAt,
                    isActive: active,
                    windowSeconds: window.limitWindowSeconds,
                    scope: prefix)
            }
    }

    private static func creditWindow(_ credits: Credits?) -> UsageWindow? {
        guard let credits else { return nil }
        if credits.unlimited == true {
            return UsageWindow(
                title: L10n.t("Credits", "额度点数"),
                detail: L10n.t("Unlimited", "无限制"))
        }
        // A zero balance on an account that has never bought credits is noise.
        guard credits.hasCredits == true, let balance = credits.balance else { return nil }
        return UsageWindow(
            title: L10n.t("Credits", "额度点数"),
            detail: credits.overageLimitReached == true
                ? L10n.t("\(balance) · overage limit reached", "\(balance) · 已达超额上限")
                : balance)
    }
}

// MARK: - Claude (Claude Code Keychain OAuth → /api/oauth/usage)

public struct ClaudeProvider: QuotaProvider {
    public let id = ProviderID.claude

    public init() {}

    public func isConfigured(config: ConfigStore) -> Bool {
        LocalCredentials.claudeOAuthToken() != nil
    }

    public func fetch(config: ConfigStore) async throws -> UsageSnapshot {
        guard let token = LocalCredentials.claudeOAuthToken() else {
            // Two different situations behind one nil: no session at all, or
            // a session macOS will not hand over until the user says so.
            if LocalCredentials.claudeCredentialState() == .needsAuthorization {
                throw ProviderError.needsAuthorization(hint: LocalCredentials.claudeAuthorizationHint)
            }
            throw ProviderError.notConfigured(hint: ProviderID.claude.setupHint)
        }
        let headers = [
            "Authorization": "Bearer \(token)",
            "Accept": "application/json",
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": "claude-code/2.1.0",
        ]
        let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
        let response = try await HTTP.get(url, headers: headers).requireOK()
        var snapshot = try Self.parse(response.data)
        // The usage endpoint does not name the plan; Claude Code's item does.
        if snapshot.planName == nil { snapshot.planName = LocalCredentials.claudePlanName() }
        // Nor the account; /api/oauth/profile does. Memoized per token, so
        // the extra request happens once per sign-in, not once per minute.
        snapshot.account = await Self.profileEmail(headers: headers, token: token)
        return snapshot
    }

    // MARK: Profile

    private static let profileMemo = ProfileMemo()

    final class ProfileMemo: @unchecked Sendable {
        private let lock = NSLock()
        private var token: String?
        private var email: String?

        func email(for token: String) -> String? {
            lock.lock(); defer { lock.unlock() }
            return self.token == token ? email : nil
        }

        func store(_ email: String, for token: String) {
            lock.lock(); defer { lock.unlock() }
            self.token = token
            self.email = email
        }
    }

    struct Profile: Decodable {
        struct Account: Decodable { let email: String? }
        let account: Account?
    }

    /// Best effort: a failure here leaves the card without an account line,
    /// never without its numbers. Only a hit is cached, so a transient
    /// failure is retried on the next refresh.
    static func profileEmail(headers: [String: String], token: String) async -> String? {
        if let cached = profileMemo.email(for: token) { return cached }
        let url = URL(string: "https://api.anthropic.com/api/oauth/profile")!
        guard let response = try? await HTTP.get(url, headers: headers),
              response.status == 200,
              let email = (try? response.json(Profile.self))?.account?.email,
              !email.isEmpty
        else { return nil }
        profileMemo.store(email, for: token)
        return email
    }

    // MARK: Response shape

    struct LegacyWindow: Decodable {
        let utilization: Double?
        let resetsAt: String?
        let limitDollars: Double?
        let usedDollars: Double?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
            case limitDollars = "limit_dollars"
            case usedDollars = "used_dollars"
        }
    }

    struct Scope: Decodable {
        struct Model: Decodable {
            let id: String?
            let displayName: String?
            enum CodingKeys: String, CodingKey {
                case id
                case displayName = "display_name"
            }
        }
        let model: Model?
        let surface: String?
    }

    /// The authoritative list: one entry per limit the account is subject to,
    /// including per-model weekly caps that the legacy top-level fields omit.
    struct Limit: Decodable {
        let kind: String?
        let group: String?
        let percent: Double?
        let severity: String?
        let resetsAt: String?
        let scope: Scope?
        let isActive: Bool?

        enum CodingKeys: String, CodingKey {
            case kind, group, percent, severity, scope
            case resetsAt = "resets_at"
            case isActive = "is_active"
        }
    }

    struct ExtraUsage: Decodable {
        let isEnabled: Bool?
        let monthlyLimit: Double?
        let usedCredits: Double?
        let utilization: Double?
        let currency: String?
        let spendLimitReached: Bool?

        enum CodingKeys: String, CodingKey {
            case isEnabled = "is_enabled"
            case monthlyLimit = "monthly_limit"
            case usedCredits = "used_credits"
            case utilization
            case currency
            case spendLimitReached = "spend_limit_reached"
        }
    }

    struct Body: Decodable {
        let fiveHour: LegacyWindow?
        let sevenDay: LegacyWindow?
        let limits: [Limit]?
        let extraUsage: ExtraUsage?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case limits
            case extraUsage = "extra_usage"
        }
    }

    public static func parse(_ data: Data) throws -> UsageSnapshot {
        let body: Body
        do {
            body = try JSONDecoder().decode(Body.self, from: data)
        } catch {
            throw ProviderError.badResponse
        }

        var windows: [UsageWindow] = []
        if let limits = body.limits, !limits.isEmpty {
            windows = limits.compactMap { convert($0, body: body) }
        }
        if windows.isEmpty {
            // Older responses only carried the two top-level windows.
            windows = [
                body.fiveHour.map {
                    legacy($0, title: WindowTitle.forSeconds(18_000), seconds: 18_000, active: true)
                },
                body.sevenDay.map {
                    legacy($0, title: WindowTitle.forSeconds(604_800), seconds: 604_800, active: false)
                },
            ].compactMap { $0 }
        }
        if let extra = extraUsageWindow(body.extraUsage) {
            windows.append(extra)
        }
        guard !windows.isEmpty else { throw ProviderError.badResponse }
        return UsageSnapshot(windows: windows)
    }

    private static func convert(_ limit: Limit, body: Body) -> UsageWindow? {
        guard let percent = limit.percent else { return nil }
        let kind = limit.kind ?? limit.group ?? ""
        var title: String
        var seconds: Int?
        var scope: String?
        switch kind {
        case "session":
            seconds = 18_000
            title = WindowTitle.forSeconds(18_000)
        case "weekly_all":
            seconds = 604_800
            title = WindowTitle.forSeconds(604_800)
        case "weekly_scoped":
            seconds = 604_800
            let weekly = WindowTitle.forSeconds(604_800)
            scope = limit.scope?.model?.displayName ?? limit.scope?.model?.id
            title = scope.map { "\(weekly) · \($0)" } ?? weekly
        default:
            title = prettify(kind)
        }
        // Dollar figures only exist on the legacy fields; carry them across when
        // they describe the same window.
        let dollars: LegacyWindow? = kind == "session" ? body.fiveHour
            : (kind == "weekly_all" ? body.sevenDay : nil)
        return UsageWindow(
            title: title,
            usedPercent: percent,
            detail: dollarDetail(dollars),
            resetsAt: Dates.parseISO(limit.resetsAt),
            isActive: limit.isActive ?? false,
            windowSeconds: seconds,
            scope: scope)
    }

    private static func legacy(
        _ window: LegacyWindow,
        title: String,
        seconds: Int,
        active: Bool) -> UsageWindow
    {
        UsageWindow(
            title: title,
            usedPercent: window.utilization,
            detail: dollarDetail(window),
            resetsAt: Dates.parseISO(window.resetsAt),
            isActive: active,
            windowSeconds: seconds)
    }

    private static func dollarDetail(_ window: LegacyWindow?) -> String? {
        guard let window, let limit = window.limitDollars, limit > 0 else { return nil }
        let used = window.usedDollars ?? 0
        return "\(QuotaFormat.usd(used)) / \(QuotaFormat.usd(limit))"
    }

    private static func extraUsageWindow(_ extra: ExtraUsage?) -> UsageWindow? {
        guard let extra, extra.isEnabled == true else { return nil }
        var detail: String?
        if let limit = extra.monthlyLimit, limit > 0 {
            detail = "\(QuotaFormat.usd(extra.usedCredits ?? 0)) / \(QuotaFormat.usd(limit))"
        }
        if extra.spendLimitReached == true {
            let reached = L10n.t("spend limit reached", "已达消费上限")
            detail = detail.map { "\($0) · \(reached)" } ?? reached
        }
        return UsageWindow(
            title: L10n.t("Extra usage", "额外用量"),
            usedPercent: extra.utilization,
            detail: detail)
    }

    /// "weekly_opus" → "Weekly opus"
    private static func prettify(_ kind: String) -> String {
        guard !kind.isEmpty else { return L10n.t("Quota", "额度") }
        return kind.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

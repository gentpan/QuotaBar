import Foundation

// MARK: - Cursor (browser session cookie → cursor.com/api/usage-summary)

public struct CursorProvider: QuotaProvider {
    public let id = ProviderID.cursor

    public func isConfigured(config: ConfigStore) -> Bool {
        // A manually pasted cookie wins so the user can override a stale local
        // session; otherwise fall back to the session Cursor.app established.
        config.credential(for: .cursor) != nil || LocalCredentials.cursorSession() != nil
    }

    /// The value for the WorkosCursorSessionToken cookie. A pasted credential
    /// is used verbatim; otherwise it is composed from Cursor.app's own
    /// signed-in session, which stores the token as `sub::JWT`.
    private func cookieHeader(_ config: ConfigStore) throws -> String {
        if let raw = config.credential(for: .cursor) {
            if raw.lowercased().contains("workoscursorsessiontoken=") {
                return raw
            }
            return "WorkosCursorSessionToken=\(raw)"
        }
        if let session = LocalCredentials.cursorSession() {
            // The composite carries "::" and the JWT's own characters, which
            // must be percent-encoded to survive the Cookie header.
            let encoded = session.sessionCookie.addingPercentEncoding(
                withAllowedCharacters: .alphanumerics) ?? session.sessionCookie
            return "WorkosCursorSessionToken=\(encoded)"
        }
        throw ProviderError.notConfigured(hint: ProviderID.cursor.setupHint)
    }

    // MARK: Response shape

    struct Breakdown: Decodable {
        let included: Int?
        let bonus: Int?
        let total: Int?
    }

    struct Cents: Decodable {
        let used: Int?
        let limit: Int?
        let remaining: Int?
        let breakdown: Breakdown?
        /// Cursor's own figures. `limit` covers only the *included* allowance,
        /// so used/limit ignores bonus credit and reads 100% on an account
        /// that Cursor itself shows as half consumed.
        let totalPercentUsed: Double?
        let apiPercentUsed: Double?
        let autoPercentUsed: Double?
    }

    struct Individual: Decodable {
        let plan: Cents?
        let onDemand: Cents?
    }

    struct Summary: Decodable {
        let membershipType: String?
        let billingCycleEnd: String?
        let individualUsage: Individual?
    }

    struct Me: Decodable {
        let email: String?
    }

    /// Grok Bot's weekly included usage — "Sand" inside Cursor — from the
    /// dashboard endpoint the usage summary does not cover.
    struct SandUsage: Decodable {
        let currentPeriodStart: String?
        let nextResetTimestampUtc: String?
        let usagePercent: Double?
        let hasAvailableUsage: Bool?
        let hasNonZeroIncludedLimit: Bool?
    }

    public func fetch(config: ConfigStore) async throws -> UsageSnapshot {
        let cookie = try cookieHeader(config)
        let headers = ["Accept": "application/json", "Cookie": cookie]

        let summaryURL = URL(string: "https://cursor.com/api/usage-summary")!
        let response = try await HTTP.get(summaryURL, headers: headers).requireOK()
        let summary = try response.json(Summary.self)

        let account = try? await HTTP.get(URL(string: "https://cursor.com/api/auth/me")!, headers: headers)
            .requireOK().json(Me.self)

        // Best effort, like the account: an account without Grok Bot, or a
        // stalled endpoint, must not cost the card its plan numbers.
        let sandURL = URL(string: "https://cursor.com/api/dashboard/get-sand-usage-status")!
        var sandHeaders = headers
        sandHeaders["Origin"] = "https://cursor.com"
        let sand = try? await HTTP.post(sandURL, headers: sandHeaders).requireOK().json(SandUsage.self)

        return Self.snapshot(from: summary, account: account?.email, sand: sand)
    }

    /// Pure parse step, pinned by a recorded response.
    public static func parse(_ data: Data, account: String? = nil, sand: Data? = nil) throws -> UsageSnapshot {
        guard let summary = try? JSONDecoder().decode(Summary.self, from: data) else {
            throw ProviderError.badResponse
        }
        let sandUsage = sand.flatMap { try? JSONDecoder().decode(SandUsage.self, from: $0) }
        return snapshot(from: summary, account: account, sand: sandUsage)
    }

    static func snapshot(from summary: Summary, account: String?, sand: SandUsage? = nil) -> UsageSnapshot {
        let cycleEnd = Dates.parseAny(summary.billingCycleEnd)
        var windows: [UsageWindow] = []
        if let plan = summary.individualUsage?.plan {
            windows.append(contentsOf: planWindows(plan, resetsAt: cycleEnd))
        }
        if let onDemand = summary.individualUsage?.onDemand, let limit = onDemand.limit, limit > 0 {
            let used = onDemand.used ?? 0
            windows.append(UsageWindow(
                title: L10n.t("On-demand", "按量付费"),
                usedPercent: Double(used) / Double(limit) * 100,
                detail: "\(QuotaFormat.dollars(cents: used)) / \(QuotaFormat.dollars(cents: limit))",
                resetsAt: cycleEnd))
        }
        if let sand, let window = grokBotWindow(sand) {
            windows.append(window)
        }
        return UsageSnapshot(
            planName: summary.membershipType?.capitalized,
            account: account,
            windows: windows)
    }

    /// Cursor reports the plan three ways, and `used / limit` is the one that
    /// lies: `limit` is the included allowance only, so an account holding
    /// bonus credit reads 100% while Cursor's own page says 54%. Prefer the
    /// percentages it publishes, and size the money against the real total.
    static func planWindows(_ plan: Cents, resetsAt: Date?) -> [UsageWindow] {
        var windows: [UsageWindow] = []
        let total = plan.breakdown?.total ?? plan.limit

        if let percent = plan.totalPercentUsed {
            var detail: String?
            if let total, total > 0 {
                // The absolute spend is not published; derive it from the
                // percentage, the only figure that accounts for bonus credit.
                let spent = Int((percent / 100 * Double(total)).rounded())
                detail = "\(QuotaFormat.dollars(cents: spent)) / \(QuotaFormat.dollars(cents: total))"
            }
            windows.append(UsageWindow(
                title: L10n.t("Monthly plan", "月度套餐"),
                usedPercent: percent,
                detail: detail,
                resetsAt: resetsAt))
        } else if let limit = plan.limit, limit > 0 {
            // Older shape, with no percentages to prefer.
            let used = plan.used ?? 0
            windows.append(UsageWindow(
                title: L10n.t("Monthly plan", "月度套餐"),
                usedPercent: Double(used) / Double(limit) * 100,
                detail: "\(QuotaFormat.dollars(cents: used)) / \(QuotaFormat.dollars(cents: limit))",
                resetsAt: resetsAt))
        }

        // Named-model usage runs down faster than the total and is usually the
        // binding constraint, so it gets its own row rather than being buried
        // inside the headline.
        if let api = plan.apiPercentUsed {
            windows.append(UsageWindow(
                title: L10n.t("Named models", "指定模型"),
                usedPercent: api,
                resetsAt: resetsAt,
                scope: L10n.t("Named models", "指定模型")))
        }
        return windows
    }

    /// Only accounts whose plan includes Grok Bot get the row: the endpoint
    /// answers for everyone, with `hasNonZeroIncludedLimit` false for the rest,
    /// and a 0% bar for an allowance that does not exist would be a lie.
    static func grokBotWindow(_ sand: SandUsage) -> UsageWindow? {
        guard sand.hasNonZeroIncludedLimit == true, let percent = sand.usagePercent else { return nil }
        let start = Dates.parseISO(sand.currentPeriodStart)
        let end = Dates.parseISO(sand.nextResetTimestampUtc)
        var seconds: Int?
        if let start, let end, end > start {
            seconds = Int(end.timeIntervalSince(start).rounded())
        }
        return UsageWindow(
            title: "Grok Bot",
            usedPercent: percent,
            resetsAt: end,
            windowSeconds: seconds,
            scope: "Grok Bot")
    }
}

// MARK: - Kimi (kimi-auth cookie JWT → kimi.com gateway billing RPC)

public struct KimiProvider: QuotaProvider {
    public let id = ProviderID.kimi

    public func isConfigured(config: ConfigStore) -> Bool {
        config.credential(for: .kimi) != nil
    }

    public func fetch(config: ConfigStore) async throws -> UsageSnapshot {
        guard let token = config.credential(for: .kimi) else {
            throw ProviderError.notConfigured(hint: ProviderID.kimi.setupHint)
        }
        let headers = [
            "Authorization": "Bearer \(token)",
            "Cookie": "kimi-auth=\(token)",
            "Content-Type": "application/json",
            "Accept": "application/json",
            "Origin": "https://www.kimi.com",
            "Referer": "https://www.kimi.com/code/console",
            "connect-protocol-version": "1",
            "x-msh-platform": "web",
        ]

        struct Detail: Decodable {
            let limit: String?
            let used: String?
            let remaining: String?
            let resetTime: String?
            let resetAt: String?
        }
        struct Usage: Decodable {
            let scope: String?
            let detail: Detail?
        }
        struct UsagesBody: Decodable {
            let usages: [Usage]?
        }
        struct SubscriptionBalance: Decodable {
            let amountUsedRatio: Double?
            let expireTime: String?
        }
        struct RateLimit7d: Decodable {
            let ratio: Double?
            let resetTime: String?
        }
        struct StatsBody: Decodable {
            let subscriptionBalance: SubscriptionBalance?
            let ratelimitCode7d: RateLimit7d?
        }

        let usagesURL = URL(string: "https://www.kimi.com/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages")!
        let usages = try await HTTP.post(usagesURL, headers: headers).requireOK().json(UsagesBody.self)

        var windows: [UsageWindow] = []
        for usage in usages.usages ?? [] {
            guard let detail = usage.detail else { continue }
            let limit = Double(detail.limit ?? "") ?? 0
            let used = Double(detail.used ?? "") ?? 0
            let reset = Dates.parseAny(detail.resetTime) ?? Dates.parseAny(detail.resetAt)
            let percent: Double? = limit > 0 ? used / limit * 100 : nil
            windows.append(UsageWindow(
                title: usage.scope ?? L10n.t("Usage", "用量"),
                usedPercent: percent,
                detail: limit > 0 ? "\(Int(used)) / \(Int(limit))" : nil,
                resetsAt: reset))
        }

        let statsURL = URL(string: "https://www.kimi.com/apiv2/kimi.gateway.membership.v2.MembershipService/GetSubscriptionStats")!
        if let stats = try? await HTTP.post(statsURL, headers: headers).requireOK().json(StatsBody.self) {
            if let balance = stats.subscriptionBalance, let ratio = balance.amountUsedRatio {
                windows.append(UsageWindow(
                    title: L10n.t("Subscription balance", "订阅余额"),
                    usedPercent: ratio <= 1 ? ratio * 100 : ratio,
                    resetsAt: Dates.parseAny(balance.expireTime)))
            }
            if let weekly = stats.ratelimitCode7d, let ratio = weekly.ratio {
                windows.append(UsageWindow(
                    title: WindowTitle.forSeconds(604_800),
                    usedPercent: ratio <= 1 ? ratio * 100 : ratio,
                    resetsAt: Dates.parseAny(weekly.resetTime),
                    windowSeconds: 604_800))
            }
        }
        guard !windows.isEmpty else { throw ProviderError.badResponse }
        return UsageSnapshot(windows: windows)
    }
}

// MARK: - z.ai (API key → api.z.ai quota/limit)

public struct ZaiProvider: QuotaProvider {
    public let id = ProviderID.zai

    public func isConfigured(config: ConfigStore) -> Bool {
        config.credential(for: .zai) != nil
    }

    public func fetch(config: ConfigStore) async throws -> UsageSnapshot {
        guard let key = config.credential(for: .zai) else {
            throw ProviderError.notConfigured(hint: ProviderID.zai.setupHint)
        }
        let url = URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!
        let response = try await HTTP.get(url, headers: [
            "Authorization": "Bearer \(key)",
            "Accept": "application/json",
        ]).requireOK()

        struct Limit: Decodable {
            let type: String?
            let percentage: Double?
            let usage: Int?
            let remaining: Int?
            let nextResetTime: Double?
            let unit: Int?
            let number: Int?
        }
        struct DataBody: Decodable {
            let limits: [Limit]?
        }
        struct Body: Decodable {
            let data: DataBody?
        }

        let body = try response.json(Body.self)
        guard let limits = body.data?.limits else { throw ProviderError.badResponse }

        // z.ai encodes the window as (unit, number); minutes per unit code.
        let unitMinutes: [Int: Int] = [0: 1, 1: 60, 2: 1440, 3: 10_080, 4: 43_200, 5: 43_800]
        var windows: [UsageWindow] = []
        for limit in limits {
            let minutes = (limit.number ?? 0) * (unitMinutes[limit.unit ?? -1] ?? 0)
            let title = minutes > 0
                ? WindowTitle.forMinutes(minutes)
                : (limit.type ?? L10n.t("Quota", "额度"))
            windows.append(UsageWindow(
                title: title,
                usedPercent: limit.percentage,
                detail: limit.usage.flatMap { usage in
                    limit.remaining.map { L10n.t("\($0) left of \(usage)", "剩余 \($0) / 共 \(usage)") }
                },
                resetsAt: Dates.parseEpoch(limit.nextResetTime),
                windowSeconds: minutes > 0 ? minutes * 60 : nil))
        }
        return UsageSnapshot(windows: windows)
    }
}

import Foundation

// MARK: - Manus (session token → api.manus.im GetAvailableCredits)

public struct ManusProvider: QuotaProvider {
    public let id = ProviderID.manus

    public func isConfigured(config: ConfigStore) -> Bool {
        config.credential(for: .manus) != nil
    }

    public func fetch(config: ConfigStore) async throws -> UsageSnapshot {
        guard let token = config.credential(for: .manus) else {
            throw ProviderError.notConfigured(hint: ProviderID.manus.setupHint)
        }
        let url = URL(string: "https://api.manus.im/user.v1.UserService/GetAvailableCredits")!
        let response = try await HTTP.post(url, headers: [
            "Authorization": "Bearer \(token)",
            "Origin": "https://manus.im",
            "Referer": "https://manus.im/",
            "Connect-Protocol-Version": "1",
        ]).requireOK()

        struct Body: Decodable {
            let totalCredits: Double?
            let refreshCredits: Double?
            let maxRefreshCredits: Double?
            let periodicCredits: Double?
            let addonCredits: Double?
            let nextRefreshTime: String?
        }

        let body = try response.json(Body.self)
        var windows: [UsageWindow] = []
        if let max = body.maxRefreshCredits, max > 0, let refresh = body.refreshCredits {
            windows.append(UsageWindow(
                title: L10n.t("Daily credits", "每日额度"),
                usedPercent: (1 - refresh / max) * 100,
                detail: L10n.t("\(Int(refresh)) / \(Int(max)) credits", "\(Int(refresh)) / \(Int(max)) 点"),
                resetsAt: Dates.parseAny(body.nextRefreshTime)))
        }
        if let total = body.totalCredits {
            let periodic = body.periodicCredits ?? 0
            let addon = body.addonCredits ?? 0
            windows.append(UsageWindow(
                title: L10n.t("Total balance", "总余额"),
                detail: L10n.t(
                    "\(Int(total)) credits (\(Int(periodic)) plan + \(Int(addon)) add-on)",
                    "\(Int(total)) 点（套餐 \(Int(periodic)) + 加购 \(Int(addon))）")))
        }
        guard !windows.isEmpty else { throw ProviderError.badResponse }
        return UsageSnapshot(windows: windows)
    }
}

// MARK: - DeepSeek (API key → api.deepseek.com/user/balance)

public struct DeepSeekProvider: QuotaProvider {
    public let id = ProviderID.deepseek

    public func isConfigured(config: ConfigStore) -> Bool {
        config.credential(for: .deepseek) != nil
    }

    public func fetch(config: ConfigStore) async throws -> UsageSnapshot {
        guard let key = config.credential(for: .deepseek) else {
            throw ProviderError.notConfigured(hint: ProviderID.deepseek.setupHint)
        }
        let url = URL(string: "https://api.deepseek.com/user/balance")!
        let response = try await HTTP.get(url, headers: [
            "Authorization": "Bearer \(key)",
            "Accept": "application/json",
        ]).requireOK()

        struct Info: Decodable {
            let totalBalance: String?
            let grantedBalance: String?
            let toppedUpBalance: String?
            let currency: String?
        }
        struct Body: Decodable {
            let balanceInfos: [Info]?
        }

        let body = try response.json(Body.self)
        guard let info = body.balanceInfos?.first else { throw ProviderError.badResponse }
        let currency = info.currency ?? "CNY"
        let total = Double(info.totalBalance ?? "") ?? 0
        let granted = Double(info.grantedBalance ?? "") ?? 0
        let topped = Double(info.toppedUpBalance ?? "") ?? 0
        let window = UsageWindow(
            title: L10n.t("Balance", "余额"),
            detail: String(
                format: "%.2f %@ (%.2f paid + %.2f granted)",
                total, currency, topped, granted))
        return UsageSnapshot(windows: [window])
    }
}

// MARK: - Grok (grok CLI auth file or manual token → cli-chat-proxy billing)

public struct GrokProvider: QuotaProvider {
    public let id = ProviderID.grok

    public func isConfigured(config: ConfigStore) -> Bool {
        config.credential(for: .grok) != nil || LocalCredentials.grokAccessToken() != nil
    }

    public func fetch(config: ConfigStore) async throws -> UsageSnapshot {
        let local = LocalCredentials.grokAuth()
        guard let token = config.credential(for: .grok) ?? local?.accessToken else {
            throw ProviderError.notConfigured(hint: ProviderID.grok.setupHint)
        }
        let url = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
        let response = try await HTTP.get(url, headers: [
            "Authorization": "Bearer \(token)",
            "x-xai-token-auth": "xai-grok-cli",
            "Accept": "application/json",
            "User-Agent": "QuotaBar",
        ]).requireOK()
        var snapshot = try Self.parse(response.data)
        // The billing response carries no identity; the CLI's auth entry does.
        if snapshot.account == nil { snapshot.account = local?.email }
        return snapshot
    }

    // MARK: Response shape

    struct Amount: Decodable { let val: Double? }
    struct Period: Decodable {
        let type: String?
        let end: String?
    }
    struct Product: Decodable {
        let product: String?
        let usagePercent: Double?
    }
    struct Config: Decodable {
        let creditUsagePercent: Double?
        let currentPeriod: Period?
        let billingPeriodEnd: String?
        let onDemandCap: Amount?
        let onDemandUsed: Amount?
        let productUsage: [Product]?
        let subscriptionTier: String?
    }
    struct Body: Decodable {
        let config: Config?
        let subscriptionTier: String?
    }

    /// The period is whatever the account is on. Live accounts report
    /// `USAGE_PERIOD_TYPE_WEEKLY`; before the type was read the window was
    /// labelled "monthly" regardless, which was simply wrong on those. Each
    /// `productUsage` entry (Grok Imagine, Grok Build, …) becomes a scoped
    /// window under the same period, the way Claude's per-model windows do.
    static func parse(_ data: Data) throws -> UsageSnapshot {
        let body: Body
        do { body = try JSONDecoder().decode(Body.self, from: data) } catch { throw ProviderError.badResponse }
        guard let configBody = body.config else { throw ProviderError.badResponse }

        let periodEnd = Dates.parseISO(configBody.currentPeriod?.end)
            ?? Dates.parseISO(configBody.billingPeriodEnd)
        let (title, seconds) = periodLabel(configBody.currentPeriod?.type)

        var windows: [UsageWindow] = []
        if let percent = configBody.creditUsagePercent {
            windows.append(UsageWindow(
                title: title,
                usedPercent: percent,
                resetsAt: periodEnd,
                windowSeconds: seconds))
        }
        for product in configBody.productUsage ?? [] {
            guard let raw = product.product, let percent = product.usagePercent else { continue }
            let name = productName(raw)
            // `UsageWindow.id` is the title, so a scoped window needs its own.
            windows.append(UsageWindow(
                title: "\(title) · \(name)",
                usedPercent: percent,
                resetsAt: periodEnd,
                windowSeconds: seconds,
                scope: name))
        }
        if let cap = configBody.onDemandCap?.val, cap > 0, let used = configBody.onDemandUsed?.val {
            windows.append(UsageWindow(
                title: L10n.t("On-demand", "按量付费"),
                usedPercent: used / cap * 100,
                detail: String(format: "%.2f / %.2f", used, cap),
                resetsAt: periodEnd))
        }
        guard !windows.isEmpty else { throw ProviderError.badResponse }
        return UsageSnapshot(
            planName: configBody.subscriptionTier ?? body.subscriptionTier,
            windows: windows)
    }

    /// `USAGE_PERIOD_TYPE_WEEKLY` and friends → a title and the window length
    /// the menu-bar glyph keys its short label off.
    static func periodLabel(_ type: String?) -> (title: String, seconds: Int?) {
        let value = type?.uppercased() ?? ""
        if value.contains("WEEK") { return (L10n.t("Weekly credits", "每周额度"), 7 * 86_400) }
        // "DAILY" does not contain "DAY".
        if value.contains("DAI") || value.contains("DAY") { return (L10n.t("Daily credits", "每日额度"), 86_400) }
        if value.contains("MONTH") { return (L10n.t("Monthly credits", "月度额度"), 30 * 86_400) }
        return (L10n.t("Credits", "额度"), nil)
    }

    /// `GrokImagine` → `Grok Imagine`. The API's product ids are camel-cased
    /// brand names; the space is what the product is actually called.
    static func productName(_ raw: String) -> String {
        var out = ""
        var previous: Character?
        for ch in raw {
            if ch.isUppercase, let previous, previous.isLowercase || previous.isNumber { out.append(" ") }
            out.append(ch)
            previous = ch
        }
        return out
    }
}

// MARK: - Registry

public enum ProviderRegistry {
    public static func make(_ id: ProviderID) -> any QuotaProvider {
        switch id {
        case .codex: CodexProvider()
        case .claude: ClaudeProvider()
        case .cursor: CursorProvider()
        case .kimi: KimiProvider()
        case .zai: ZaiProvider()
        case .opencodeGo: OpenCodeGoProvider()
        case .minimax: MiniMaxProvider()
        case .gemini: GeminiProvider()
        case .manus: ManusProvider()
        case .deepseek: DeepSeekProvider()
        case .grok: GrokProvider()
        case .antigravity: AntigravityProvider()
        case .qwen: QwenProvider()
        case .alibaba: AlibabaCodingPlanProvider()
        case .volcengine: VolcengineArkProvider()
        case .zhipu: ZhipuProvider()
        case .moonshot: MoonshotBalanceProvider()
        case .copilot: CopilotProvider()
        case .openrouter: OpenRouterProvider()
        case .mimo: MiMoProvider()
        case .qoder: QoderProvider()
        case .windsurf: WindsurfProvider()
        case .kiro: KiroProvider()
        }
    }

    public static var all: [any QuotaProvider] {
        ProviderID.allCases.map(make)
    }
}

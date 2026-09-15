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
        guard let raw = config.credential(for: .deepseek) else {
            throw ProviderError.notConfigured(hint: ProviderID.deepseek.setupHint)
        }
        switch Self.credential(raw) {
        case let .apiKey(key):
            let url = URL(string: "https://api.deepseek.com/user/balance")!
            let response = try await HTTP.get(url, headers: [
                "Authorization": "Bearer \(key)",
                "Accept": "application/json",
            ]).requireOK()
            return try Self.parse(response.data)
        case let .consoleToken(token):
            return try await Self.fetchConsole(token: token)
        }
    }

    enum Credential: Equatable {
        case apiKey(String)
        case consoleToken(String)
    }

    /// One field takes either. An API key (`sk-…`) can only ask for the
    /// balance; each key's usage is behind the platform console's own sign-in,
    /// the `userToken` it keeps in local storage. That value is sometimes
    /// copied as the JSON it is stored in, or with its `Bearer` prefix.
    static func credential(_ raw: String) -> Credential {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("bearer ") { value = String(value.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        if value.hasPrefix("{"), let object = ProviderJSON.object(Data(value.utf8)) as? [String: Any],
           let inner = ProviderJSON.string(object["value"])
        {
            value = inner
        }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return value.hasPrefix("sk-") ? .apiKey(value) : .consoleToken(value)
    }

    // MARK: Console

    static let console = "https://platform.deepseek.com/api/v0"

    /// The console's own reads, as its usage page makes them: the wallets and
    /// this month's spend, the keys, then cost and tokens per key per day.
    /// One range covers the month and the week — whichever starts earlier, at
    /// most 31 days, which is as long a range as the console accepts — so the
    /// three periods come from two requests.
    static func fetchConsole(token: String, now: Date = .now, calendar: Calendar = .current) async throws -> UsageSnapshot {
        let headers = [
            "Authorization": "Bearer \(token)",
            "Accept": "application/json",
            "Origin": "https://platform.deepseek.com",
            "Referer": "https://platform.deepseek.com/usage",
            "User-Agent": QwenProvider.browserAgent,
        ]
        let summary = try await HTTP.get(URL(string: "\(console)/users/get_user_summary")!, headers: headers).requireOK()
        let range = ConsoleRange(now: now, calendar: calendar)
        let query = "start=\(Int(range.start.timeIntervalSince1970))&end=\(Int(range.end.timeIntervalSince1970))&tz=\(calendar.timeZone.secondsFromGMT(for: now))"
        let keys = try? await HTTP.get(URL(string: "\(console)/users/get_api_keys")!, headers: headers).requireOK()
        let cost = try? await HTTP.get(URL(string: "\(console)/usage/by_api_key/cost?\(query)")!, headers: headers).requireOK()
        let amount = try? await HTTP.get(URL(string: "\(console)/usage/by_api_key/amount?\(query)")!, headers: headers).requireOK()
        return try parseConsole(summary: summary.data, keys: keys?.data, cost: cost?.data, amount: amount?.data, range: range)
    }

    struct ConsoleRange {
        let today: Date
        let week: Date
        let month: Date
        let start: Date
        let end: Date

        /// The start of every day in the range, oldest first.
        let days: [Date]

        init(now: Date, calendar: Calendar) {
            today = calendar.startOfDay(for: now)
            week = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today
            month = calendar.dateInterval(of: .month, for: now)?.start ?? today
            start = min(week, month)
            end = calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400)
            var days: [Date] = []
            var day = start
            while day < end, days.count < 32 {
                days.append(day)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
            self.days = days
        }

        func periods(containing time: Date) -> [KeyUsagePeriod] {
            var periods: [KeyUsagePeriod] = []
            if time >= today { periods.append(.today) }
            if time >= week { periods.append(.week) }
            if time >= month { periods.append(.month) }
            return periods
        }
    }

    /// `{"code":0,"msg":"","data":{"biz_code":0,"biz_msg":"","biz_data":{…}}}`
    /// — two envelopes. A missing or expired token is an outer code
    /// (40002 "Missing Token"), a bad query an inner one.
    static func consoleData(_ data: Data) throws -> [String: Any] {
        guard let body = ProviderJSON.object(data) as? [String: Any] else { throw ProviderError.badResponse }
        let code = QwenProvider.number(body["code"]) ?? 0
        if code != 0 {
            if (40_000..<41_000).contains(code) { throw ProviderError.unauthorized }
            throw ProviderError.badResponse
        }
        guard let inner = body["data"] as? [String: Any], (QwenProvider.number(inner["biz_code"]) ?? 0) == 0,
              let payload = inner["biz_data"] as? [String: Any]
        else { throw ProviderError.badResponse }
        return payload
    }

    static func parseConsole(summary: Data, keys: Data?, cost: Data?, amount: Data?, range: ConsoleRange) throws -> UsageSnapshot {
        let wallets = try consoleData(summary)
        func amounts(_ list: Any?, _ field: String) -> [(currency: String, value: Double)] {
            (list as? [[String: Any]] ?? []).compactMap { entry in
                guard let currency = ProviderJSON.string(entry["currency"]), let value = QwenProvider.number(entry[field]) else { return nil }
                return (currency.uppercased(), value)
            }
        }
        let normal = amounts(wallets["normal_wallets"], "balance")
        let bonus = amounts(wallets["bonus_wallets"], "balance")
        var currencies: [String] = []
        for entry in normal + bonus where !currencies.contains(entry.currency) { currencies.append(entry.currency) }
        var balances = currencies.map { currency -> AccountBalance in
            let paid = normal.filter { $0.currency == currency }.reduce(0) { $0 + $1.value }
            let granted = bonus.filter { $0.currency == currency }.reduce(0) { $0 + $1.value }
            return AccountBalance(currency: currency, total: paid + granted, paid: paid, granted: granted > 0 ? granted : nil)
        }
        // A wallet the account has never used is listed at zero; show it only
        // when it is all there is.
        if balances.contains(where: { $0.total > 0 }) { balances.removeAll { $0.total <= 0 } }
        if balances.isEmpty { balances = [AccountBalance(currency: "CNY", total: 0)] }

        var spend: [KeyUsagePeriod: [Money]] = [:]
        var models: [KeyUsagePeriod: [ModelCost]] = [:]
        let month = amounts(wallets["total_costs"], "amount").filter { $0.value > 0 }
        if !month.isEmpty { spend[.month] = month.map { Money(currency: $0.currency, amount: $0.value) } }

        var keyList: [APIKeyUsage]?
        var note: String?
        if let listed = keys.flatMap({ try? consoleData($0) }), let entries = listed["api_keys"] as? [[String: Any]] {
            keyList = entries.compactMap { entry in
                guard let id = ProviderJSON.string(entry["tracking_id"]) else { return nil }
                return APIKeyUsage(
                    id: id,
                    name: ProviderJSON.string(entry["name"]) ?? L10n.t("Unnamed key", "未命名 Key"),
                    maskedKey: ProviderJSON.string(entry["sensitive_id"]),
                    lastUsed: (QwenProvider.number(entry["last_use"]) ?? 0) > 0 ? QwenProvider.date(entry["last_use"]) : nil)
            }
        }
        let costs = cost.flatMap { try? consoleData($0) }
        let counts = amount.flatMap { try? consoleData($0) }
        if costs == nil && counts == nil {
            note = L10n.t("Couldn't read each key's usage this time.", "这次没能读到各个 Key 的用量。")
        } else {
            var byID: [String: APIKeyUsage] = [:]
            var order: [String] = []
            for key in keyList ?? [] {
                byID[key.id] = key
                order.append(key.id)
            }
            // A deleted key keeps its history in the usage replies and nowhere else.
            func key(_ raw: Any?) -> String? {
                guard let info = raw as? [String: Any], let id = ProviderJSON.string(info["tracking_id"]) else { return nil }
                if byID[id] == nil {
                    byID[id] = APIKeyUsage(
                        id: id,
                        name: ProviderJSON.string(info["name"]) ?? L10n.t("Deleted key", "已删除的 Key"),
                        maskedKey: ProviderJSON.string(info["sensitive_id"]),
                        isDisabled: (info["valid"] as? Bool) == false)
                    order.append(id)
                }
                return id
            }
            var money: [String: [KeyUsagePeriod: MoneyTally]] = [:]
            var modelMoney: [String: [KeyUsagePeriod: [String: MoneyTally]]] = [:]
            var dayMoney: [String: [Double: MoneyTally]] = [:]
            for block in costs?["data"] as? [[String: Any]] ?? [] {
                let currency = (ProviderJSON.string(block["currency"]) ?? "CNY").uppercased()
                for series in block["series"] as? [[String: Any]] ?? [] {
                    guard let id = key(series["api_key"]) else { continue }
                    let model = ProviderJSON.string(series["model"]) ?? "—"
                    for bucket in series["buckets"] as? [[String: Any]] ?? [] {
                        guard let time = QwenProvider.number(bucket["time"]), let value = QwenProvider.number(bucket["cost"]), value > 0 else { continue }
                        dayMoney[id, default: [:]][time, default: MoneyTally()].add(currency, value)
                        for period in range.periods(containing: Date(timeIntervalSince1970: time)) {
                            money[id, default: [:]][period, default: MoneyTally()].add(currency, value)
                            modelMoney[id, default: [:]][period, default: [:]][model, default: MoneyTally()].add(currency, value)
                        }
                    }
                }
            }
            // Requests and tokens come from the other reply, also per key and
            // per model; the model names are the same strings in both.
            var requests: [String: [KeyUsagePeriod: [String: Int]]] = [:]
            var tokens: [String: [KeyUsagePeriod: [String: Int]]] = [:]
            var dayCounts: [String: [Double: (requests: Int, tokens: Int)]] = [:]
            for series in counts?["series"] as? [[String: Any]] ?? [] {
                guard let id = key(series["api_key"]) else { continue }
                let model = ProviderJSON.string(series["model"]) ?? "—"
                for bucket in series["buckets"] as? [[String: Any]] ?? [] {
                    guard let time = QwenProvider.number(bucket["time"]), let usage = bucket["usage"] as? [String: Any] else { continue }
                    let asked = Int(QwenProvider.number(usage["REQUEST"]) ?? 0)
                    let used = ["RESPONSE_TOKEN", "PROMPT_CACHE_HIT_TOKEN", "PROMPT_CACHE_MISS_TOKEN"]
                        .reduce(0) { $0 + Int(QwenProvider.number(usage[$1]) ?? 0) }
                    guard asked > 0 || used > 0 else { continue }
                    dayCounts[id, default: [:]][time, default: (0, 0)].requests += asked
                    dayCounts[id, default: [:]][time, default: (0, 0)].tokens += used
                    for period in range.periods(containing: Date(timeIntervalSince1970: time)) {
                        requests[id, default: [:]][period, default: [:]][model, default: 0] += asked
                        tokens[id, default: [:]][period, default: [:]][model, default: 0] += used
                    }
                }
            }
            let known = counts != nil
            var totals: [KeyUsagePeriod: MoneyTally] = [:]
            var accountModels: [KeyUsagePeriod: [String: (money: MoneyTally, requests: Int, tokens: Int)]] = [:]
            keyList = order.compactMap { id in
                guard var entry = byID[id] else { return nil }
                for period in KeyUsagePeriod.allCases {
                    let costs = money[id]?[period]?.money ?? []
                    for cost in costs { totals[period, default: MoneyTally()].add(cost.currency, cost.amount) }
                    let spent = modelMoney[id]?[period] ?? [:]
                    let asked = requests[id]?[period] ?? [:]
                    let used = tokens[id]?[period] ?? [:]
                    let names = Set(spent.keys).union(asked.keys).union(used.keys)
                    let models = names.map { name -> ModelCost in
                        var row = accountModels[period, default: [:]][name] ?? (MoneyTally(), 0, 0)
                        for cost in spent[name]?.money ?? [] { row.money.add(cost.currency, cost.amount) }
                        row.requests += asked[name] ?? 0
                        row.tokens += used[name] ?? 0
                        accountModels[period, default: [:]][name] = row
                        return ModelCost(
                            model: name, costs: spent[name]?.money ?? [],
                            requests: known ? asked[name] ?? 0 : nil, tokens: known ? used[name] ?? 0 : nil)
                    }
                    .sorted(by: ModelCost.busiestFirst)
                    let figures = KeyUsageFigures(
                        costs: costs,
                        requests: known ? asked.values.reduce(0, +) : nil,
                        tokens: known ? used.values.reduce(0, +) : nil,
                        models: models)
                    if !figures.isEmpty { entry.usage[period] = figures }
                }
                if !entry.usage.isEmpty {
                    entry.daily = range.days.map { day in
                        let time = day.timeIntervalSince1970
                        return DailyUsage(
                            day: day,
                            costs: dayMoney[id]?[time]?.money ?? [],
                            requests: known ? dayCounts[id]?[time]?.requests ?? 0 : nil,
                            tokens: known ? dayCounts[id]?[time]?.tokens ?? 0 : nil)
                    }
                }
                // A deleted key with nothing in range is not worth a row.
                return entry.isDisabled && entry.usage.isEmpty ? nil : entry
            }
            for period in [KeyUsagePeriod.today, .week] {
                if let tally = totals[period] { spend[period] = tally.money }
            }
            if spend[.month] == nil, let tally = totals[.month] { spend[.month] = tally.money }
            for (period, rows) in accountModels {
                models[period] = rows
                    .map { ModelCost(model: $0.key, costs: $0.value.money.money, requests: known ? $0.value.requests : nil, tokens: known ? $0.value.tokens : nil) }
                    .sorted(by: ModelCost.busiestFirst)
            }
        }

        let windows = balanceWindows(balances, canCallAPI: nil)
        return UsageSnapshot(
            planName: L10n.t("Pay as you go", "按量付费"),
            windows: windows,
            balance: BalanceSheet(
                balances: balances,
                spend: spend,
                models: models,
                keys: keyList,
                keysNote: note,
                representedWindowIDs: windows.map(\.id)))
    }

    /// The figure-only windows a balance is also reported as, for the local
    /// API and the surfaces that only read windows.
    static func balanceWindows(_ balances: [AccountBalance], canCallAPI: Bool?) -> [UsageWindow] {
        balances.map { entry in
            var detail = L10n.t(
                "Balance \(QuotaFormat.amount(entry.total, code: entry.currency))",
                "余额 \(QuotaFormat.amount(entry.total, code: entry.currency))")
            if let granted = entry.granted, granted > 0 {
                let paid = QuotaFormat.amount(entry.paid ?? entry.total - granted, code: entry.currency)
                let gift = QuotaFormat.amount(granted, code: entry.currency)
                detail += L10n.t(" · \(paid) paid + \(gift) granted", " · 充值 \(paid) + 赠送 \(gift)")
            }
            if canCallAPI == false {
                detail += L10n.t(" · not enough for API calls", " · 余额不足，无法调用 API")
            }
            // `UsageWindow.id` is the title, so a second currency needs its own.
            let title = balances.count > 1 ? "\(L10n.t("Balance", "余额")) · \(entry.currency)" : L10n.t("Balance", "余额")
            return UsageWindow(title: title, detail: detail)
        }
    }

    /// `{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"110.00",
    /// "granted_balance":"10.00","topped_up_balance":"100.00"}]}` — snake_case,
    /// amounts as strings. The keys were once read camel-cased, so every
    /// account failed to parse. An account can hold CNY and USD side by side,
    /// and a new one with nothing topped up may list no entry at all.
    static func parse(_ data: Data) throws -> UsageSnapshot {
        guard let body = ProviderJSON.object(data) as? [String: Any],
              let infos = body["balance_infos"] as? [[String: Any]]
        else { throw ProviderError.badResponse }

        let canCall = body["is_available"] as? Bool
        var balances = infos.compactMap { info -> AccountBalance? in
            guard let total = QwenProvider.number(info["total_balance"]) else { return nil }
            let granted = QwenProvider.number(info["granted_balance"]) ?? 0
            return AccountBalance(
                currency: ((info["currency"] as? String) ?? "CNY").uppercased(),
                total: total,
                paid: QwenProvider.number(info["topped_up_balance"]),
                granted: granted > 0 ? granted : nil)
        }
        if !infos.isEmpty, balances.isEmpty { throw ProviderError.badResponse }
        if balances.isEmpty { balances = [AccountBalance(currency: "CNY", total: 0)] }

        let windows = balanceWindows(balances, canCallAPI: canCall)
        return UsageSnapshot(
            planName: L10n.t("Pay as you go", "按量付费"),
            windows: windows,
            balance: BalanceSheet(
                balances: balances,
                keysNote: L10n.t(
                    "An API key only shows the balance. Paste the console's sign-in token in Settings to see this month's spend and each key's usage.",
                    "API Key 只能读到余额。在设置里改为粘贴控制台的登录令牌，可以看到本月消费和每个 Key 的用量。"),
                canCallAPI: canCall,
                representedWindowIDs: windows.map(\.id)))
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
            // The products split the one credit pool. A product holding all of
            // it — only Grok Build used this week — is the same bar a second
            // time: same figure, same reset (issue #2).
            if let total = configBody.creditUsagePercent, abs(percent - total) < 0.05 { continue }
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

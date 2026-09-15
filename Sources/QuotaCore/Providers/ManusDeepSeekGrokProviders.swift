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

    /// The console's own reads, as its usage page makes them:
    ///
    /// - the wallets, and everything ever spent (`total_costs`);
    /// - the keys, with the names given them on DeepSeek;
    /// - cost and requests per key per model per day over the last thirty
    ///   days — as long a range as the per-key endpoints accept is 31 days;
    /// - today's cost hour by hour, for today's chart;
    /// - a month at a time for the chart of all of it, from the month the
    ///   oldest key was made. A month that is over never changes, so months
    ///   already read are carried over from the last reading and only the
    ///   current one — and at most a few missing ones — are asked for.
    static func fetchConsole(token: String, now: Date = .now, calendar: Calendar = .current) async throws -> UsageSnapshot {
        let headers = [
            "Authorization": "Bearer \(token)",
            "Accept": "application/json",
            "Origin": "https://platform.deepseek.com",
            "Referer": "https://platform.deepseek.com/usage",
            "User-Agent": QwenProvider.browserAgent,
        ]
        func get(_ path: String) async -> Data? {
            try? await HTTP.get(URL(string: "\(console)/\(path)")!, headers: headers).requireOK().data
        }
        let summary = try await HTTP.get(URL(string: "\(console)/users/get_user_summary")!, headers: headers).requireOK()
        let range = ConsoleRange(now: now, calendar: calendar)
        let tz = calendar.timeZone.secondsFromGMT(for: now)
        let recent = "start=\(Int(range.start.timeIntervalSince1970))&end=\(Int(range.end.timeIntervalSince1970))&tz=\(tz)"
        let day = "start=\(Int(range.today.timeIntervalSince1970))&end=\(Int(range.end.timeIntervalSince1970))&tz=\(tz)"
        let keys = await get("users/get_api_keys")
        let cost = await get("usage/by_api_key/cost?\(recent)")
        let amount = await get("usage/by_api_key/amount?\(recent)")
        let hourly = await get("usage/by_api_key/cost?\(day)")

        // Months for the all-time chart.
        let firstKey = keys.flatMap { try? consoleData($0) }.flatMap { $0["api_keys"] as? [[String: Any]] }?
            .compactMap { QwenProvider.date($0["created_at"]) }.min()
        let cached = SnapshotCache.shared.snapshot(for: .deepseek)?.balance?.chart[.all] ?? []
        var months: [UsageBucket] = []
        var asked = 0
        for start in UsageBuckets.starts(for: .all, now: now, first: firstKey ?? range.month, calendar: calendar).suffix(24) {
            let current = start == range.month
            if !current, let known = cached.first(where: { $0.start == start }) {
                months.append(known)
                continue
            }
            // A handful a refresh: the console turns away a burst.
            guard current || asked < 3 else { continue }
            asked += 1
            let parts = calendar.dateComponents([.year, .month], from: start)
            if let data = await get("usage/cost?month=\(parts.month ?? 1)&year=\(parts.year ?? 1970)"),
               let bucket = monthBucket(data, start: start)
            {
                months.append(bucket)
            }
        }
        return try parseConsole(summary: summary.data, keys: keys, cost: cost, amount: amount, hourly: hourly, months: months, range: range)
    }

    struct ConsoleRange {
        let now: Date
        let calendar: Calendar
        let today: Date
        let month: Date
        /// The first of the thirty days the per-key reads cover.
        let start: Date
        let end: Date

        init(now: Date, calendar: Calendar) {
            self.now = now
            self.calendar = calendar
            today = calendar.startOfDay(for: now)
            month = calendar.dateInterval(of: .month, for: now)?.start ?? today
            start = calendar.date(byAdding: .day, value: -29, to: today) ?? today
            end = calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400)
        }

        /// The periods ending today that a day belongs to. All of it is told
        /// by the console's own total, not by adding up thirty days.
        func periods(containing day: Date) -> [KeyUsagePeriod] {
            [KeyUsagePeriod.today, .last7, .last30].filter { period in
                UsageBuckets.periodStart(period, now: now, calendar: calendar).map { day >= $0 } ?? false
            }
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

    /// `usage/cost?month=&year=`: per currency, each model's cost split by
    /// token type (`PROMPT_CACHE_HIT_TOKEN`, `RESPONSE_TOKEN`, …). Its
    /// `biz_data` is the array itself, not an object.
    static func monthBucket(_ data: Data, start: Date) -> UsageBucket? {
        guard let body = ProviderJSON.object(data) as? [String: Any], (QwenProvider.number(body["code"]) ?? 0) == 0,
              let inner = body["data"] as? [String: Any], (QwenProvider.number(inner["biz_code"]) ?? 0) == 0,
              let currencies = inner["biz_data"] as? [[String: Any]]
        else { return nil }
        var money = MoneyTally()
        for block in currencies {
            let currency = (ProviderJSON.string(block["currency"]) ?? "CNY").uppercased()
            let total = (block["total"] as? [[String: Any]] ?? []).reduce(0.0) { sum, model in
                sum + (model["usage"] as? [[String: Any]] ?? []).reduce(0.0) { $0 + (QwenProvider.number($1["amount"]) ?? 0) }
            }
            if total > 0 { money.add(currency, total) }
        }
        return UsageBucket(start: start, costs: money.money)
    }

    static func parseConsole(
        summary: Data, keys: Data?, cost: Data?, amount: Data?, hourly: Data? = nil, months: [UsageBucket] = [],
        range: ConsoleRange) throws -> UsageSnapshot
    {
        let calendar = range.calendar
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

        var usage: [KeyUsagePeriod: KeyUsageFigures] = [:]
        var chart: [KeyUsagePeriod: [UsageBucket]] = [:]
        // `total_costs` is everything the account has spent, not this month:
        // on the owner's account it was ¥592.74 against ¥36.79 for September.
        let lifetime = amounts(wallets["total_costs"], "amount").filter { $0.value > 0 }
        usage[.all] = KeyUsageFigures(costs: lifetime.map { Money(currency: $0.currency, amount: $0.value) })
        if !months.isEmpty { chart[.all] = months.sorted { $0.start < $1.start } }

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
            note = L10n.t("Couldn't read the recent usage this time.", "这次没能读到最近的用量。")
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
            // Every non-zero bucket of both replies, as (key, model, entry).
            var events: [(key: String, model: String, entry: UsageBuckets.Entry)] = []
            for block in costs?["data"] as? [[String: Any]] ?? [] {
                let currency = (ProviderJSON.string(block["currency"]) ?? "CNY").uppercased()
                for series in block["series"] as? [[String: Any]] ?? [] {
                    guard let id = key(series["api_key"]) else { continue }
                    let model = ProviderJSON.string(series["model"]) ?? "—"
                    for bucket in series["buckets"] as? [[String: Any]] ?? [] {
                        guard let time = QwenProvider.number(bucket["time"]), let value = QwenProvider.number(bucket["cost"]), value > 0 else { continue }
                        events.append((id, model, UsageBuckets.Entry(date: Date(timeIntervalSince1970: time), currency: currency, cost: value)))
                    }
                }
            }
            let known = counts != nil
            for series in counts?["series"] as? [[String: Any]] ?? [] {
                guard let id = key(series["api_key"]) else { continue }
                let model = ProviderJSON.string(series["model"]) ?? "—"
                for bucket in series["buckets"] as? [[String: Any]] ?? [] {
                    guard let time = QwenProvider.number(bucket["time"]), let figures = bucket["usage"] as? [String: Any] else { continue }
                    let asked = Int(QwenProvider.number(figures["REQUEST"]) ?? 0)
                    let used = ["RESPONSE_TOKEN", "PROMPT_CACHE_HIT_TOKEN", "PROMPT_CACHE_MISS_TOKEN"]
                        .reduce(0) { $0 + Int(QwenProvider.number(figures[$1]) ?? 0) }
                    guard asked > 0 || used > 0 else { continue }
                    events.append((id, model, UsageBuckets.Entry(date: Date(timeIntervalSince1970: time), currency: "", cost: 0, requests: asked, tokens: used)))
                }
            }

            func models(_ rows: [(key: String, model: String, entry: UsageBuckets.Entry)]) -> [ModelCost] {
                Dictionary(grouping: rows, by: \.model).map { name, rows in
                    let figures = UsageBuckets.figures(rows.map(\.entry), since: nil)
                    return ModelCost(model: name, costs: figures.costs, requests: known ? figures.requests ?? 0 : nil, tokens: known ? figures.tokens ?? 0 : nil)
                }
                .sorted(by: ModelCost.busiestFirst)
            }
            func figures(_ rows: [(key: String, model: String, entry: UsageBuckets.Entry)]) -> KeyUsageFigures {
                var total = UsageBuckets.figures(rows.map(\.entry), since: nil, models: models(rows))
                if known { total.requests = total.requests ?? 0; total.tokens = total.tokens ?? 0 } else { total.requests = nil; total.tokens = nil }
                return total
            }

            for period in [KeyUsagePeriod.today, .last7, .last30] {
                let inPeriod = events.filter { range.periods(containing: $0.entry.date).contains(period) }
                usage[period] = figures(inPeriod)
            }
            let days = UsageBuckets.starts(for: .last30, now: range.now, first: nil, calendar: calendar)
            chart[.last30] = UsageBuckets.fill(days, span: .day, entries: events.map(\.entry), calendar: calendar)
            chart[.last7] = Array((chart[.last30] ?? []).suffix(7))

            keyList = order.compactMap { id in
                guard var entry = byID[id] else { return nil }
                let mine = events.filter { $0.key == id }
                for period in [KeyUsagePeriod.today, .last7, .last30] {
                    let figures = figures(mine.filter { range.periods(containing: $0.entry.date).contains(period) })
                    if !figures.isEmpty { entry.usage[period] = figures }
                }
                if !entry.usage.isEmpty {
                    entry.daily = UsageBuckets.fill(days, span: .day, entries: mine.map(\.entry), calendar: calendar)
                }
                // A deleted key with nothing in range is not worth a row.
                return entry.isDisabled && entry.usage.isEmpty ? nil : entry
            }
        }

        // Today by the hour, from its own read; the daily figures above
        // already count today, so this is for the chart only.
        if let hours = hourly.flatMap({ try? consoleData($0) }) {
            var entries: [UsageBuckets.Entry] = []
            for block in hours["data"] as? [[String: Any]] ?? [] {
                let currency = (ProviderJSON.string(block["currency"]) ?? "CNY").uppercased()
                for series in block["series"] as? [[String: Any]] ?? [] {
                    for bucket in series["buckets"] as? [[String: Any]] ?? [] {
                        guard let time = QwenProvider.number(bucket["time"]), let value = QwenProvider.number(bucket["cost"]), value > 0 else { continue }
                        entries.append(UsageBuckets.Entry(date: Date(timeIntervalSince1970: time), currency: currency, cost: value))
                    }
                }
            }
            chart[.today] = UsageBuckets.fill(
                UsageBuckets.starts(for: .today, now: range.now, first: nil, calendar: calendar),
                span: .hour, entries: entries, calendar: calendar)
        }

        let windows = balanceWindows(balances, canCallAPI: nil)
        return UsageSnapshot(
            planName: L10n.t("Pay as you go", "按量付费"),
            windows: windows,
            balance: BalanceSheet(
                balances: balances,
                usage: usage,
                chart: chart,
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
                    "For exact usage and each key's and model's, choose Sign in in a browser… for DeepSeek in Settings.",
                    "想看精确用量和每个 Key、每个模型的明细，在设置 → 服务商 → DeepSeek 点「浏览器登录…」。"),
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

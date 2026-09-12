import Foundation

// MARK: - Providers added in 0.5
//
// Endpoints and fields follow CodexBar's (MIT) working implementations of the
// same services. Only Copilot could be exercised against a live account while
// these were written; the rest are marked experimental in Settings until an
// owner's account confirms them.

// MARK: - Shared helpers

enum ProviderJSON {
    static func object(_ data: Data) -> Any? {
        try? JSONSerialization.jsonObject(with: data)
    }

    static func dictionary(_ value: Any?) -> [String: Any]? { value as? [String: Any] }

    static func string(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }

    /// The first value under any of `keys`, searched depth-first.
    static func first(_ keys: [String], in value: Any) -> Any? {
        if let dictionary = value as? [String: Any] {
            for key in keys { if let hit = dictionary[key], !(hit is NSNull) { return hit } }
            for child in dictionary.values { if let hit = first(keys, in: child) { return hit } }
        } else if let array = value as? [Any] {
            for child in array { if let hit = first(keys, in: child) { return hit } }
        }
        return nil
    }

    static func percent(used: Double, total: Double) -> Double? {
        guard total > 0 else { return nil }
        return min(max(used / total * 100, 0), 100)
    }
}

/// Runs a command-line tool the owner already has signed in, and returns its
/// standard output. Looks where Homebrew, npm, cargo and the tools' own
/// installers put binaries; a GUI app does not inherit the shell's PATH.
enum ToolRunner {
    static let searchPaths: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "\(home)/.local/bin", "\(home)/bin",
                "\(home)/.cargo/bin", "\(home)/go/bin", "\(home)/.npm-global/bin", "\(home)/.volta/bin",
                "\(home)/.arkcli/bin", "\(home)/.bun/bin"]
    }()

    static func locate(_ name: String) -> String? {
        let fm = FileManager.default
        return searchPaths.map { "\($0)/\(name)" }.first { fm.isExecutableFile(atPath: $0) }
    }

    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 20) -> (status: Int32, output: Data)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (searchPaths + [environment["PATH"] ?? ""]).joined(separator: ":")
        environment["NO_COLOR"] = "1"
        process.environment = environment
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = DispatchTime.now() + timeout
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        let reader = DispatchQueue(label: "bar.quota.tool")
        var output = Data()
        let readDone = DispatchSemaphore(value: 0)
        reader.async {
            output = stdout.fileHandleForReading.readDataToEndOfFile()
            readDone.signal()
        }
        if done.wait(timeout: deadline) == .timedOut {
            process.terminate()
            return nil
        }
        _ = readDone.wait(timeout: .now() + 2)
        return (process.terminationStatus, output)
    }
}

// MARK: - 阿里云百炼 Coding Plan

/// Alibaba Cloud Model Studio (百炼) Coding Plan: 5-hour, weekly and monthly
/// request quotas from the console's own gateway, signed in by cookie. China
/// mainland first, then the international console.
public struct AlibabaCodingPlanProvider: QuotaProvider {
    public let id = ProviderID.alibaba

    struct Region {
        let console: String
        let referer: String
        let gateway: String
        let action: String
        let commodity: String
        let regionID: String
        let site: String

        static let china = Region(
            console: "https://bailian.console.aliyun.com",
            referer: "https://bailian.console.aliyun.com/cn-beijing/?tab=model",
            gateway: "https://bailian-cs.console.aliyun.com",
            action: "BroadScopeAspnGateway",
            commodity: "sfm_codingplan_public_cn",
            regionID: "cn-beijing",
            site: "BAILIAN_ALIYUN")
        static let international = Region(
            console: "https://modelstudio.console.alibabacloud.com",
            referer: "https://modelstudio.console.alibabacloud.com/ap-southeast-1/?tab=coding-plan",
            gateway: "https://bailian-singapore-cs.alibabacloud.com",
            action: "IntlBroadScopeAspnGateway",
            commodity: "sfm_codingplan_public_intl",
            regionID: "ap-southeast-1",
            site: "MODELSTUDIO_ALIBABACLOUD")
    }

    static let api = "zeldaEasy.broadscope-bailian.codingPlan.queryCodingPlanInstanceInfoV2"

    public func isConfigured(config: ConfigStore) -> Bool { config.credential(for: id) != nil }

    public func fetch(config: ConfigStore) async throws -> UsageSnapshot {
        guard let raw = config.credential(for: id), let cookie = QwenProvider.normalizeCookie(raw) else {
            throw ProviderError.notConfigured(hint: id.setupHint)
        }
        var lastError: Error = ProviderError.unauthorized
        for region in [Region.china, .international] {
            do {
                return try await fetch(region: region, cookie: cookie)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func fetch(region: Region, cookie: String) async throws -> UsageSnapshot {
        let page = try? await HTTP.get(URL(string: region.referer)!, headers: [
            "Cookie": cookie, "Accept": "text/html,application/xhtml+xml", "User-Agent": QwenProvider.browserAgent,
        ])
        guard let secToken = page.flatMap({ QwenProvider.secToken(inHTML: String(decoding: $0.data, as: UTF8.self)) })
            ?? QwenProvider.cookieValue("sec_token", in: cookie)
        else { throw ProviderError.unauthorized }

        var components = URLComponents(string: region.gateway + "/data/api.json")!
        components.queryItems = [
            URLQueryItem(name: "action", value: region.action),
            URLQueryItem(name: "product", value: "sfm_bailian"),
            URLQueryItem(name: "api", value: Self.api),
            URLQueryItem(name: "_v", value: "undefined"),
        ]
        var cornerstone: [String: Any] = [
            "feTraceId": UUID().uuidString.lowercased(), "feURL": region.referer, "protocol": "V2",
            "console": "ONE_CONSOLE", "productCode": "p_efm", "domain": URL(string: region.console)?.host ?? "",
            "consoleSite": region.site, "userNickName": "", "userPrincipalName": "", "xsp_lang": "zh-CN",
        ]
        if let anonymous = QwenProvider.cookieValue("cna", in: cookie) { cornerstone["X-Anonymous-Id"] = anonymous }
        let params: [String: Any] = [
            "Api": Self.api, "V": "1.0",
            "Data": [
                "queryCodingPlanInstanceInfoRequest": ["commodityCode": region.commodity, "onlyLatestOne": true],
                "cornerstoneParam": cornerstone,
            ],
        ]
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "params", value: String(decoding: try JSONSerialization.data(withJSONObject: params), as: UTF8.self)),
            URLQueryItem(name: "region", value: region.regionID),
            URLQueryItem(name: "sec_token", value: secToken),
        ]
        var headers = [
            "Content-Type": "application/x-www-form-urlencoded", "Accept": "*/*", "Cookie": cookie,
            "X-Requested-With": "XMLHttpRequest", "User-Agent": QwenProvider.browserAgent,
            "Origin": region.console, "Referer": region.referer,
        ]
        if let csrf = QwenProvider.cookieValue("login_aliyunid_csrf", in: cookie) ?? QwenProvider.cookieValue("csrf", in: cookie) {
            headers["x-xsrf-token"] = csrf
            headers["x-csrf-token"] = csrf
        }
        let response = try await HTTP.post(components.url!, headers: headers, jsonBody: form.percentEncodedQuery ?? "").requireOK()
        return try Self.parse(response.data)
    }

    /// The gateway nests the plan's JSON, sometimes as a string; the quota
    /// object is wherever its counters are.
    public static func parse(_ data: Data) throws -> UsageSnapshot {
        guard let raw = ProviderJSON.object(data) else { throw ProviderError.badResponse }
        let root = QwenProvider.expandEmbeddedJSON(raw)
        let text = String(decoding: data, as: UTF8.self)
        let counters: Set<String> = ["per5HourTotalQuota", "perWeekTotalQuota", "perBillMonthTotalQuota", "perFiveHourTotalQuota", "perMonthTotalQuota"]
        guard let quota = QwenProvider.findObject(containingAnyOf: counters, in: root) else {
            if text.contains("ConsoleNeedLogin") || text.lowercased().contains("login") { throw ProviderError.unauthorized }
            throw ProviderError.badResponse
        }
        func window(_ title: String, _ used: [String], _ total: [String], _ reset: [String], seconds: Int) -> UsageWindow? {
            guard let totalValue = total.lazy.compactMap({ QwenProvider.number(quota[$0]) }).first, totalValue > 0 else { return nil }
            let usedValue = used.lazy.compactMap { QwenProvider.number(quota[$0]) }.first ?? 0
            return UsageWindow(
                title: title,
                usedPercent: ProviderJSON.percent(used: usedValue, total: totalValue),
                detail: L10n.t("\(Int(usedValue)) / \(Int(totalValue)) requests", "\(Int(usedValue)) / \(Int(totalValue)) 次请求"),
                resetsAt: reset.lazy.compactMap { QwenProvider.date(quota[$0]) }.first,
                windowSeconds: seconds)
        }
        let windows = [
            window(L10n.t("5-hour window", "5 小时窗口"), ["per5HourUsedQuota", "perFiveHourUsedQuota"], ["per5HourTotalQuota", "perFiveHourTotalQuota"], ["per5HourQuotaNextRefreshTime", "perFiveHourQuotaNextRefreshTime"], seconds: 18_000),
            window(L10n.t("Weekly window", "周窗口"), ["perWeekUsedQuota"], ["perWeekTotalQuota"], ["perWeekQuotaNextRefreshTime"], seconds: 604_800),
            window(L10n.t("Monthly window", "月窗口"), ["perBillMonthUsedQuota", "perMonthUsedQuota"], ["perBillMonthTotalQuota", "perMonthTotalQuota"], ["perBillMonthQuotaNextRefreshTime", "perMonthQuotaNextRefreshTime"], seconds: 2_592_000),
        ].compactMap { $0 }
        guard !windows.isEmpty else { throw ProviderError.badResponse }
        let plan = ProviderJSON.first(["planName", "instanceName", "packageName"], in: root).flatMap(ProviderJSON.string)
        return UsageSnapshot(planName: plan, windows: windows)
    }
}

// MARK: - 火山方舟 Coding Plan

/// Volcengine Ark (火山方舟, Doubao) Coding and Agent Plans, read through the
/// official `arkcli` the owner has signed in with (`arkcli auth login`).
public struct VolcengineArkProvider: QuotaProvider {
    public let id = ProviderID.volcengine

    public func isConfigured(config: ConfigStore) -> Bool { ToolRunner.locate("arkcli") != nil }

    public func fetch(config: ConfigStore) async throws -> UsageSnapshot {
        guard let path = ToolRunner.locate("arkcli") else { throw ProviderError.notConfigured(hint: id.setupHint) }
        let result = await Task.detached { ToolRunner.run(path, ["usage", "plan", "--format", "json"]) }.value
        guard let result else { throw ProviderError.network(L10n.t("arkcli timed out", "arkcli 超时")) }
        return try Self.parse(result.output)
    }

    public static func parse(_ data: Data) throws -> UsageSnapshot {
        guard let root = ProviderJSON.object(data) as? [String: Any] else { throw ProviderError.badResponse }
        if let method = (root["viewer"] as? [String: Any])?["auth_method"] as? String, method.lowercased() == "none" {
            throw ProviderError.unauthorized
        }
        let products: [String: String] = [
            "coding-plan": "Coding Plan", "agent-plan": "Agent Plan",
            "coding-plan-team": L10n.t("Coding Plan · team", "Coding Plan · 团队"),
            "agent-plan-team": L10n.t("Agent Plan · team", "Agent Plan · 团队"),
        ]
        var windows: [UsageWindow] = []
        var plans: [String] = []
        for item in root["items"] as? [[String: Any]] ?? [] {
            guard let product = (item["product"] as? String)?.lowercased(), let name = products[product],
                  (item["subscribed"] as? Bool) != false
            else { continue }
            let periods = item["periods"] as? [[String: Any]] ?? []
            if !periods.isEmpty { plans.append(name) }
            for period in periods {
                let label = (period["label"] as? String ?? "").lowercased()
                let seconds = label.contains("week") ? 604_800 : label.contains("month") ? 2_592_000 : 18_000
                let title = WindowTitle.forSeconds(seconds)
                windows.append(UsageWindow(
                    title: product == "coding-plan" ? title : "\(name) · \(title)",
                    usedPercent: QwenProvider.number(period["percent"]).map { min(max($0 <= 1 && $0 > 0 ? $0 * 100 : $0, 0), 100) },
                    resetsAt: QwenProvider.date(period["reset_at"]),
                    windowSeconds: seconds,
                    scope: product == "coding-plan" ? nil : name))
            }
        }
        guard !windows.isEmpty else { throw ProviderError.badResponse }
        return UsageSnapshot(planName: plans.first, windows: windows)
    }
}

// MARK: - 智谱 GLM Coding Plan（国内站）

/// Zhipu's GLM Coding Plan on bigmodel.cn: the same quota endpoint as z.ai,
/// on the China host.
public struct ZhipuProvider: QuotaProvider {
    public let id = ProviderID.zhipu

    public func isConfigured(config: ConfigStore) -> Bool { config.credential(for: id) != nil }

    public func fetch(config: ConfigStore) async throws -> UsageSnapshot {
        guard let key = config.credential(for: id) else { throw ProviderError.notConfigured(hint: id.setupHint) }
        return try await ZaiProvider.fetchQuota(host: "https://open.bigmodel.cn", key: key)
    }
}

// MARK: - 月之暗面开放平台余额

/// The Kimi / Moonshot open platform's account balance, by API key — China
/// host first, then the international one.
public struct MoonshotBalanceProvider: QuotaProvider {
    public let id = ProviderID.moonshot

    public func isConfigured(config: ConfigStore) -> Bool { config.credential(for: id) != nil }

    public func fetch(config: ConfigStore) async throws -> UsageSnapshot {
        guard let key = config.credential(for: id) else { throw ProviderError.notConfigured(hint: id.setupHint) }
        var lastError: Error = ProviderError.unauthorized
        for (host, currency) in [("https://api.moonshot.cn", "CNY"), ("https://api.moonshot.ai", "USD")] {
            do {
                let response = try await HTTP.get(URL(string: "\(host)/v1/users/me/balance")!, headers: [
                    "Authorization": "Bearer \(key.trimmingCharacters(in: .whitespacesAndNewlines))", "Accept": "application/json",
                ]).requireOK()
                return try Self.parse(response.data, currency: currency)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    public static func parse(_ data: Data, currency: String) throws -> UsageSnapshot {
        guard let body = ProviderJSON.object(data) as? [String: Any],
              let payload = body["data"] as? [String: Any],
              let available = QwenProvider.number(payload["available_balance"])
        else { throw ProviderError.badResponse }
        let symbol = currency == "CNY" ? "¥" : "$"
        let voucher = QwenProvider.number(payload["voucher_balance"]) ?? 0
        let cash = QwenProvider.number(payload["cash_balance"]) ?? available
        var detail = L10n.t("Balance \(symbol)\(String(format: "%.2f", available))", "余额 \(symbol)\(String(format: "%.2f", available))")
        if voucher > 0 { detail += L10n.t(" · vouchers \(symbol)\(String(format: "%.2f", voucher))", " · 代金券 \(symbol)\(String(format: "%.2f", voucher))") }
        if cash < 0 { detail += L10n.t(" · owing \(symbol)\(String(format: "%.2f", -cash))", " · 欠费 \(symbol)\(String(format: "%.2f", -cash))") }
        return UsageSnapshot(
            planName: L10n.t("Pay as you go", "按量付费"),
            windows: [UsageWindow(title: L10n.t("Account balance", "账户余额"), detail: detail)])
    }
}

// MARK: - GitHub Copilot

/// Copilot's monthly premium requests, chat and completions, from the
/// endpoint the editors read. Signed in through the GitHub CLI the owner
/// already uses (`gh auth token`), or a pasted token.
public struct CopilotProvider: QuotaProvider {
    public let id = ProviderID.copilot

    public func isConfigured(config: ConfigStore) -> Bool {
        config.credential(for: id) != nil || ToolRunner.locate("gh") != nil
    }

    static func token(config: ConfigStore) async -> String? {
        if let manual = config.credential(for: .copilot) { return manual.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let gh = ToolRunner.locate("gh") else { return nil }
        let result = await Task.detached { ToolRunner.run(gh, ["auth", "token"], timeout: 10) }.value
        guard let result, result.status == 0 else { return nil }
        let token = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    public func fetch(config: ConfigStore) async throws -> UsageSnapshot {
        guard let token = await Self.token(config: config) else { throw ProviderError.notConfigured(hint: id.setupHint) }
        let response = try await HTTP.get(URL(string: "https://api.github.com/copilot_internal/user")!, headers: [
            "Authorization": "token \(token)",
            "Accept": "application/json",
            "Editor-Version": "vscode/1.96.2",
            "Editor-Plugin-Version": "copilot-chat/0.26.7",
            "User-Agent": "GitHubCopilotChat/0.26.7",
            "X-Github-Api-Version": "2025-04-01",
        ])
        if response.status == 404 {
            throw ProviderError.notConfigured(hint: L10n.t("This GitHub account has no Copilot.", "这个 GitHub 账号没有 Copilot。"))
        }
        return try Self.parse(try response.requireOK().data)
    }

    public static func parse(_ data: Data) throws -> UsageSnapshot {
        guard let root = ProviderJSON.object(data) as? [String: Any] else { throw ProviderError.badResponse }
        let reset = (root["quota_reset_date_utc"] as? String).flatMap(Dates.parseISO)
            ?? (root["quota_reset_date"] as? String).flatMap(day)
            ?? (root["limited_user_reset_date"] as? String).flatMap(day)
        let titles: [String: String] = [
            "premium_interactions": L10n.t("Premium requests", "高级请求"),
            "chat": L10n.t("Chat", "聊天"),
            "completions": L10n.t("Completions", "代码补全"),
        ]
        var windows: [UsageWindow] = []
        let snapshots = root["quota_snapshots"] as? [String: Any] ?? [:]
        for key in ["premium_interactions", "chat", "completions"] {
            guard let snapshot = snapshots[key] as? [String: Any], (snapshot["unlimited"] as? Bool) != true else { continue }
            let entitlement = QwenProvider.number(snapshot["entitlement"]) ?? 0
            let remaining = QwenProvider.number(snapshot["remaining"])
            let percentRemaining = QwenProvider.number(snapshot["percent_remaining"])
                ?? remaining.flatMap { entitlement > 0 ? $0 / entitlement * 100 : nil }
            guard let percentRemaining, entitlement > 0 || snapshot["percent_remaining"] != nil else { continue }
            windows.append(UsageWindow(
                title: titles[key] ?? key,
                usedPercent: min(max(100 - percentRemaining, 0), 100),
                detail: remaining.map { L10n.t("\(Int($0)) of \(Int(entitlement)) left", "剩余 \(Int($0)) / \(Int(entitlement))") },
                resetsAt: reset))
        }
        // The free plan reports what is left and what the month allows separately.
        if windows.isEmpty, let left = root["limited_user_quotas"] as? [String: Any], let monthly = root["monthly_quotas"] as? [String: Any] {
            for key in ["chat", "completions"] {
                guard let total = QwenProvider.number(monthly[key]), total > 0, let remaining = QwenProvider.number(left[key]) else { continue }
                windows.append(UsageWindow(
                    title: titles[key] ?? key,
                    usedPercent: ProviderJSON.percent(used: total - remaining, total: total),
                    detail: L10n.t("\(Int(remaining)) of \(Int(total)) left", "剩余 \(Int(remaining)) / \(Int(total))"),
                    resetsAt: reset))
            }
        }
        let sku = (root["access_type_sku"] as? String)?.lowercased() ?? ""
        if windows.isEmpty {
            windows.append(UsageWindow(
                title: L10n.t("Subscription", "订阅"),
                detail: sku.contains("ended")
                    ? L10n.t("Subscription ended", "订阅已结束")
                    : L10n.t("Unlimited on this plan", "此套餐不限量")))
        }
        let plan = (root["copilot_plan"] as? String).map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return UsageSnapshot(planName: plan, account: root["login"] as? String, windows: windows)
    }

    private static func day(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(string.prefix(10)))
    }
}

// MARK: - OpenRouter

/// OpenRouter credits and, when the key has one, its spending limit.
public struct OpenRouterProvider: QuotaProvider {
    public let id = ProviderID.openrouter

    public func isConfigured(config: ConfigStore) -> Bool { config.credential(for: id) != nil }

    public func fetch(config: ConfigStore) async throws -> UsageSnapshot {
        guard let key = config.credential(for: id)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw ProviderError.notConfigured(hint: id.setupHint)
        }
        let headers = ["Authorization": "Bearer \(key)", "Accept": "application/json", "X-Title": "QuotaBar", "HTTP-Referer": "https://quota.bar"]
        let credits = try await HTTP.get(URL(string: "https://openrouter.ai/api/v1/credits")!, headers: headers).requireOK()
        let keyInfo = try? await HTTP.get(URL(string: "https://openrouter.ai/api/v1/key")!, headers: headers).requireOK()
        return try Self.parse(credits: credits.data, key: keyInfo?.data)
    }

    public static func parse(credits: Data, key: Data?) throws -> UsageSnapshot {
        guard let body = ProviderJSON.object(credits) as? [String: Any], let data = body["data"] as? [String: Any],
              let total = QwenProvider.number(data["total_credits"]), let used = QwenProvider.number(data["total_usage"])
        else { throw ProviderError.badResponse }
        var windows = [UsageWindow(
            title: L10n.t("Credits", "额度"),
            usedPercent: ProviderJSON.percent(used: used, total: total),
            detail: L10n.t("$\(String(format: "%.2f", max(0, total - used))) left of $\(String(format: "%.2f", total))",
                           "剩余 $\(String(format: "%.2f", max(0, total - used))) / 共 $\(String(format: "%.2f", total))"))]
        if let keyBody = key.flatMap(ProviderJSON.object) as? [String: Any], let info = keyBody["data"] as? [String: Any] {
            if let limit = QwenProvider.number(info["limit"]), limit > 0 {
                let remaining = QwenProvider.number(info["limit_remaining"]) ?? limit
                windows.append(UsageWindow(
                    title: L10n.t("Key limit", "密钥额度"),
                    usedPercent: ProviderJSON.percent(used: limit - remaining, total: limit),
                    detail: L10n.t("$\(String(format: "%.2f", remaining)) left of $\(String(format: "%.2f", limit))",
                                   "剩余 $\(String(format: "%.2f", remaining)) / 共 $\(String(format: "%.2f", limit))"),
                    resetsAt: QwenProvider.date(info["limit_reset"])))
            }
            let daily = QwenProvider.number(info["usage_daily"]), weekly = QwenProvider.number(info["usage_weekly"]), monthly = QwenProvider.number(info["usage_monthly"])
            if daily != nil || weekly != nil || monthly != nil {
                func money(_ value: Double?) -> String { value.map { "$" + String(format: "%.2f", $0) } ?? "—" }
                windows.append(UsageWindow(
                    title: L10n.t("Spend", "花费"),
                    detail: L10n.t("Today \(money(daily)) · week \(money(weekly)) · month \(money(monthly))",
                                   "今日 \(money(daily)) · 本周 \(money(weekly)) · 本月 \(money(monthly))")))
            }
        }
        return UsageSnapshot(windows: windows)
    }
}

// MARK: - 小米 MiMo

/// Xiaomi MiMo: the Token Plan's monthly usage and the account balance, by
/// the platform console's cookie.
public struct MiMoProvider: QuotaProvider {
    public let id = ProviderID.mimo
    static let base = "https://platform.xiaomimimo.com/api/v1"

    public func isConfigured(config: ConfigStore) -> Bool { config.credential(for: id) != nil }

    public func fetch(config: ConfigStore) async throws -> UsageSnapshot {
        guard let raw = config.credential(for: id), let cookie = QwenProvider.normalizeCookie(raw) else {
            throw ProviderError.notConfigured(hint: id.setupHint)
        }
        let headers = [
            "Cookie": cookie, "Accept": "application/json, text/plain, */*", "Accept-Language": "zh-CN,zh;q=0.9",
            "x-timeZone": "UTC+08:00", "Origin": "https://platform.xiaomimimo.com",
            "Referer": "https://platform.xiaomimimo.com/#/console/balance", "User-Agent": QwenProvider.browserAgent,
        ]
        let balance = try await HTTP.get(URL(string: "\(Self.base)/balance")!, headers: headers).requireOK()
        let detail = try? await HTTP.get(URL(string: "\(Self.base)/tokenPlan/detail")!, headers: headers)
        let usage = try? await HTTP.get(URL(string: "\(Self.base)/tokenPlan/usage")!, headers: headers)
        return try Self.parse(balance: balance.data, detail: detail?.data, usage: usage?.data)
    }

    public static func parse(balance: Data, detail: Data?, usage: Data?) throws -> UsageSnapshot {
        guard let body = ProviderJSON.object(balance) as? [String: Any] else { throw ProviderError.badResponse }
        let code = QwenProvider.number(body["code"]) ?? 0
        if code == 401 || code == 403 { throw ProviderError.unauthorized }
        guard code == 0, let data = body["data"] as? [String: Any], let amount = QwenProvider.number(data["balance"]) else {
            throw ProviderError.badResponse
        }
        let currency = (data["currency"] as? String)?.uppercased() == "USD" ? "$" : "¥"
        var windows: [UsageWindow] = []
        var plan: String?
        if let detailBody = detail.flatMap(ProviderJSON.object) as? [String: Any], let info = detailBody["data"] as? [String: Any] {
            plan = ProviderJSON.string(info["planCode"])
            if (info["expired"] as? Bool) == true { plan = plan.map { L10n.t("\($0) (expired)", "\($0)（已过期）") } }
        }
        if let usageBody = usage.flatMap(ProviderJSON.object) as? [String: Any],
           let month = (usageBody["data"] as? [String: Any])?["monthUsage"] as? [String: Any],
           let item = (month["items"] as? [[String: Any]])?.first,
           let limit = QwenProvider.number(item["limit"]), limit > 0
        {
            let used = QwenProvider.number(item["used"]) ?? 0
            windows.append(UsageWindow(
                title: L10n.t("Token Plan · month", "Token Plan · 本月"),
                usedPercent: ProviderJSON.percent(used: used, total: limit),
                detail: "\(QuotaFormat.compact(Int(used))) / \(QuotaFormat.compact(Int(limit)))",
                windowSeconds: 2_592_000))
        }
        windows.append(UsageWindow(
            title: L10n.t("Account balance", "账户余额"),
            detail: L10n.t("Balance \(currency)\(String(format: "%.2f", amount))", "余额 \(currency)\(String(format: "%.2f", amount))")))
        return UsageSnapshot(planName: plan, windows: windows)
    }
}

// MARK: - Qoder

/// Qoder's big-model credits, by cookie from qoder.com or qoder.com.cn.
public struct QoderProvider: QuotaProvider {
    public let id = ProviderID.qoder

    public func isConfigured(config: ConfigStore) -> Bool { config.credential(for: id) != nil }

    public func fetch(config: ConfigStore) async throws -> UsageSnapshot {
        guard let raw = config.credential(for: id), let cookie = QwenProvider.normalizeCookie(raw) else {
            throw ProviderError.notConfigured(hint: id.setupHint)
        }
        var lastError: Error = ProviderError.unauthorized
        for site in ["qoder.com.cn", "qoder.com"] {
            let origin = "https://\(site)"
            do {
                let response = try await HTTP.get(URL(string: "\(origin)/api/v2/me/usages/big_model_credits")!, headers: [
                    "Cookie": cookie, "Origin": origin, "Referer": "\(origin)/account/usage",
                    "X-Requested-With": "XMLHttpRequest", "Bx-V": "2.5.35", "Accept": "application/json",
                    "User-Agent": QwenProvider.browserAgent,
                ]).requireOK()
                return try Self.parse(response.data)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    public static func parse(_ data: Data) throws -> UsageSnapshot {
        guard let root = ProviderJSON.object(data) as? [String: Any] else { throw ProviderError.badResponse }
        func summary(_ keys: [String]) -> [String: Any]? {
            guard let container = keys.lazy.compactMap({ root[$0] as? [String: Any] }).first else { return nil }
            return (container["quotaSummary"] ?? container["quota_summary"]) as? [String: Any]
        }
        guard let total = summary(["totalQuota", "total_quota"]) else { throw ProviderError.badResponse }
        let shared = summary(["sharedQuota", "shared_quota"])
        func value(_ object: [String: Any]?, _ camel: String, _ snake: String) -> Double {
            QwenProvider.number(object?[camel] ?? object?[snake]) ?? 0
        }
        let used = value(total, "usedValue", "used_value") + value(shared, "usedValue", "used_value")
        let limit = value(total, "limitValue", "limit_value") + value(shared, "limitValue", "limit_value")
        let percent = shared == nil
            ? (QwenProvider.number(total["usagePercentage"] ?? total["usage_percentage"]) ?? ProviderJSON.percent(used: used, total: limit))
            : ProviderJSON.percent(used: used, total: limit)
        return UsageSnapshot(windows: [UsageWindow(
            title: L10n.t("Credits", "额度"),
            usedPercent: percent.map { min(max($0, 0), 100) },
            detail: L10n.t("\(Int(used)) / \(Int(limit)) credits", "\(Int(used)) / \(Int(limit)) 点"),
            resetsAt: QwenProvider.date(root["nextResetAt"] ?? root["next_reset_at"]))])
    }
}

// MARK: - Windsurf

/// Windsurf's plan, read from the cache the editor keeps of it on this Mac.
public struct WindsurfProvider: QuotaProvider {
    public let id = ProviderID.windsurf

    static var database: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Windsurf/User/globalStorage/state.vscdb").path
    }

    public func isConfigured(config: ConfigStore) -> Bool { FileManager.default.fileExists(atPath: Self.database) }

    public func fetch(config: ConfigStore) async throws -> UsageSnapshot {
        let rows = SQLiteRead.rows(inFile: Self.database, query: "SELECT value FROM ItemTable WHERE key = 'windsurf.settings.cachedPlanInfo' LIMIT 1;")
        guard let json = rows.first?.first ?? nil else { throw ProviderError.notConfigured(hint: id.setupHint) }
        return try Self.parse(Data(json.utf8))
    }

    public static func parse(_ data: Data) throws -> UsageSnapshot {
        guard let root = ProviderJSON.object(data) as? [String: Any] else { throw ProviderError.badResponse }
        var windows: [UsageWindow] = []
        if let quota = root["quotaUsage"] as? [String: Any] {
            if let daily = QwenProvider.number(quota["dailyRemainingPercent"]) {
                windows.append(UsageWindow(title: L10n.t("Daily", "每日"), usedPercent: min(max(100 - daily, 0), 100),
                                           resetsAt: QwenProvider.date(quota["dailyResetAtUnix"]), windowSeconds: 86_400))
            }
            if let weekly = QwenProvider.number(quota["weeklyRemainingPercent"]) {
                windows.append(UsageWindow(title: L10n.t("Weekly", "每周"), usedPercent: min(max(100 - weekly, 0), 100),
                                           resetsAt: QwenProvider.date(quota["weeklyResetAtUnix"]), windowSeconds: 604_800))
            }
        }
        let end = QwenProvider.date(root["endTimestamp"])
        if let usage = root["usage"] as? [String: Any] {
            for (title, total, used, remaining) in [
                (L10n.t("Prompt credits", "提示额度"), "messages", "usedMessages", "remainingMessages"),
                (L10n.t("Flow actions", "Flow 操作"), "flowActions", "usedFlowActions", "remainingFlowActions"),
                (L10n.t("Flex credits", "弹性额度"), "flexCredits", "usedFlexCredits", "remainingFlexCredits"),
            ] {
                guard let totalValue = QwenProvider.number(usage[total]), totalValue > 0 else { continue }
                let usedValue = QwenProvider.number(usage[used])
                    ?? QwenProvider.number(usage[remaining]).map { totalValue - $0 } ?? 0
                windows.append(UsageWindow(
                    title: title,
                    usedPercent: ProviderJSON.percent(used: usedValue, total: totalValue),
                    detail: "\(Int(usedValue)) / \(Int(totalValue))",
                    resetsAt: end))
            }
        }
        guard !windows.isEmpty else { throw ProviderError.badResponse }
        return UsageSnapshot(planName: ProviderJSON.string(root["planName"]), windows: windows)
    }
}

// MARK: - Kiro

/// Kiro's monthly credits, asked of AWS with the session `kiro-cli` keeps on
/// this Mac.
public struct KiroProvider: QuotaProvider {
    public let id = ProviderID.kiro

    static var database: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/kiro-cli/data.sqlite3").path
    }

    public func isConfigured(config: ConfigStore) -> Bool { FileManager.default.fileExists(atPath: Self.database) }

    public func fetch(config: ConfigStore) async throws -> UsageSnapshot {
        guard let tokenJSON = SQLiteRead.rows(inFile: Self.database, query: "SELECT value FROM auth_kv WHERE key = 'kirocli:odic:token'").first?.first ?? nil,
              let profileJSON = SQLiteRead.rows(inFile: Self.database, query: "SELECT value FROM state WHERE key = 'api.codewhisperer.profile'").first?.first ?? nil,
              let token = (ProviderJSON.object(Data(tokenJSON.utf8)) as? [String: Any])?["access_token"] as? String,
              let arn = (ProviderJSON.object(Data(profileJSON.utf8)) as? [String: Any])?["arn"] as? String
        else { throw ProviderError.notConfigured(hint: id.setupHint) }
        let parts = arn.split(separator: ":", maxSplits: 5, omittingEmptySubsequences: false)
        let endpoints = ["us-east-1": "https://codewhisperer.us-east-1.amazonaws.com/", "eu-central-1": "https://q.eu-central-1.amazonaws.com/"]
        guard parts.count == 6, let endpoint = endpoints[String(parts[3])], let url = URL(string: endpoint) else {
            throw ProviderError.badResponse
        }
        let body = String(decoding: try JSONSerialization.data(withJSONObject: ["profileArn": arn]), as: UTF8.self)
        let response = try await HTTP.post(url, headers: [
            "Content-Type": "application/x-amz-json-1.0",
            "X-Amz-Target": "AmazonCodeWhispererService.GetUsageLimits",
            "Authorization": "Bearer \(token)",
        ], jsonBody: body).requireOK()
        return try Self.parse(response.data)
    }

    public static func parse(_ data: Data) throws -> UsageSnapshot {
        guard let root = ProviderJSON.object(data) as? [String: Any],
              let credit = (root["usageBreakdownList"] as? [[String: Any]])?.first(where: { ($0["resourceType"] as? String) == "CREDIT" })
        else { throw ProviderError.badResponse }
        let limit = QwenProvider.number(credit["usageLimitWithPrecision"]) ?? 0
        let used = QwenProvider.number(credit["currentUsageWithPrecision"]) ?? 0
        guard limit > 0 else { throw ProviderError.badResponse }
        let reset = QwenProvider.date(credit["nextDateReset"] ?? root["nextDateReset"])
        return UsageSnapshot(windows: [UsageWindow(
            title: L10n.t("Monthly credits", "每月额度"),
            usedPercent: ProviderJSON.percent(used: used, total: limit),
            detail: L10n.t("\(String(format: "%.1f", used)) / \(String(format: "%.0f", limit)) credits", "\(String(format: "%.1f", used)) / \(String(format: "%.0f", limit)) 点"),
            resetsAt: reset)])
    }
}

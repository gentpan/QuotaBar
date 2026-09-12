import Foundation

// MARK: - Antigravity (the app's own OAuth token → Cloud Code quota buckets)

/// Google's Antigravity IDE keeps a standalone OAuth token on disk and
/// asks the Cloud Code companion API for its model quotas. The same
/// calls, with the same token: `loadCodeAssist` for the project and tier,
/// `fetchAvailableModels` for each model's remaining fraction, and
/// `retrieveUserQuota` when the model list carries no fractions. Request
/// shapes follow CodexBar's, which follow the app's.
public struct AntigravityProvider: QuotaProvider {
    public let id = ProviderID.antigravity

    static let base = "https://cloudcode-pa.googleapis.com/v1internal"

    public func isConfigured(config: ConfigStore) -> Bool {
        LocalCredentials.antigravityToken() != nil
    }

    public func fetch(config: ConfigStore) async throws -> UsageSnapshot {
        guard let token = LocalCredentials.antigravityToken() else {
            throw ProviderError.notConfigured(hint: ProviderID.antigravity.setupHint)
        }
        // The token cannot be refreshed from here; the app does that
        // whenever it runs.
        guard !token.isExpired() else {
            throw ProviderError.notConfigured(hint: L10n.t(
                "Antigravity's sign-in has expired — open Antigravity once and it refreshes.",
                "Antigravity 的登录已过期：打开一次 Antigravity 就会刷新。"))
        }
        let headers = [
            "Authorization": "Bearer \(token.accessToken)",
            "Accept": "application/json",
            "User-Agent": "antigravity",
        ]
        let metadata = #"{"metadata":{"ideType":"ANTIGRAVITY","platform":"PLATFORM_UNSPECIFIED","pluginType":"GEMINI"}}"#
        let assist = try? await HTTP.post(URL(string: "\(Self.base):loadCodeAssist")!, headers: headers, jsonBody: metadata)
            .requireOK().json(CodeAssist.self)
        let projectBody = assist?.projectID.map { #"{"project":"\#($0)"}"# } ?? "{}"

        var quotas: [ModelQuota] = []
        if let models = try? await HTTP.post(URL(string: "\(Self.base):fetchAvailableModels")!, headers: headers, jsonBody: projectBody)
            .requireOK().json(AvailableModels.self)
        {
            quotas = Self.quotas(from: models)
        }
        if !quotas.contains(where: { $0.remainingFraction != nil }) {
            let response = try await HTTP.post(URL(string: "\(Self.base):retrieveUserQuota")!, headers: headers, jsonBody: projectBody)
                .requireOK()
            quotas = Self.quotas(from: try response.json(UserQuota.self))
        }
        return try Self.snapshot(quotas, plan: assist?.currentTier?.name)
    }

    // MARK: Response shapes

    struct CodeAssist: Decodable {
        struct Tier: Decodable { let id: String?; let name: String? }
        let currentTier: Tier?
        /// A string, or an object with an id — the API has sent both.
        let cloudaicompanionProject: Project?

        var projectID: String? {
            cloudaicompanionProject?.id?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }

        struct Project: Decodable {
            let id: String?
            init(from decoder: Decoder) throws {
                if let single = try? decoder.singleValueContainer(), let value = try? single.decode(String.self) {
                    id = value
                    return
                }
                let keyed = try decoder.container(keyedBy: Keys.self)
                id = try keyed.decodeIfPresent(String.self, forKey: .id)
                    ?? keyed.decodeIfPresent(String.self, forKey: .projectId)
            }
            enum Keys: String, CodingKey { case id, projectId }
        }
    }

    struct AvailableModels: Decodable {
        struct Model: Decodable {
            let displayName: String?
            let label: String?
            let quotaInfo: QuotaInfo?
        }
        let models: [String: Model]?
    }

    struct QuotaInfo: Decodable {
        let remainingFraction: Double?
        let resetTime: String?
    }

    struct UserQuota: Decodable {
        struct Bucket: Decodable {
            let modelId: String?
            let remainingFraction: Double?
            let resetTime: String?
        }
        let buckets: [Bucket]?
    }

    struct ModelQuota: Equatable {
        let modelID: String
        let label: String
        let remainingFraction: Double?
        let resetsAt: Date?
    }

    static func quotas(from response: AvailableModels) -> [ModelQuota] {
        (response.models ?? [:]).compactMap { modelID, model in
            guard let info = model.quotaInfo else { return nil }
            let label = model.displayName?.nilIfEmpty ?? model.label?.nilIfEmpty ?? modelID
            return ModelQuota(
                modelID: modelID,
                label: label,
                remainingFraction: info.remainingFraction,
                resetsAt: LocalCredentials.parseFlexibleISO(info.resetTime))
        }
        .sorted { $0.label < $1.label }
    }

    /// Several buckets can name one model; the emptiest one is the binding.
    static func quotas(from response: UserQuota) -> [ModelQuota] {
        var byModel: [String: ModelQuota] = [:]
        for bucket in response.buckets ?? [] {
            guard let modelID = bucket.modelId?.nilIfEmpty else { continue }
            let next = ModelQuota(
                modelID: modelID,
                label: modelID,
                remainingFraction: bucket.remainingFraction,
                resetsAt: LocalCredentials.parseFlexibleISO(bucket.resetTime))
            if let existing = byModel[modelID],
               (existing.remainingFraction ?? .greatestFiniteMagnitude) <= (next.remainingFraction ?? .greatestFiniteMagnitude)
            {
                continue
            }
            byModel[modelID] = next
        }
        return byModel.values.sorted { $0.label < $1.label }
    }

    /// One window per model, named for it. Antigravity quotas are per model
    /// family rather than per time window, so the model is the scope.
    static func snapshot(_ quotas: [ModelQuota], plan: String?) throws -> UsageSnapshot {
        let windows = quotas.map { quota in
            UsageWindow(
                title: quota.label,
                usedPercent: quota.remainingFraction.map { (1 - min(max($0, 0), 1)) * 100 },
                resetsAt: quota.resetsAt,
                scope: quota.label)
        }
        guard !windows.isEmpty else { throw ProviderError.badResponse }
        return UsageSnapshot(planName: plan?.nilIfEmpty, windows: windows)
    }

    /// Pinned by the tests against recorded shapes.
    public static func parse(models data: Data, plan: String? = nil) throws -> UsageSnapshot {
        let response: AvailableModels
        do { response = try JSONDecoder().decode(AvailableModels.self, from: data) } catch { throw ProviderError.badResponse }
        return try snapshot(quotas(from: response), plan: plan)
    }

    public static func parse(buckets data: Data, plan: String? = nil) throws -> UsageSnapshot {
        let response: UserQuota
        do { response = try JSONDecoder().decode(UserQuota.self, from: data) } catch { throw ProviderError.badResponse }
        return try snapshot(quotas(from: response), plan: plan)
    }
}

// MARK: - Qwen Cloud (console Cookie header → token plan usage)

/// Alibaba's Qwen Cloud token plan, read the way the console page reads it:
/// a `sec_token` from the signed-in dashboard, then the console's data
/// gateway, which wraps the plan API. Cookie-based, so the credential is
/// the full Cookie header from a signed-in browser. Shapes follow
/// CodexBar's reading of the same console.
public struct QwenProvider: QuotaProvider {
    public let id = ProviderID.qwen

    static let dashboard = URL(string: "https://home.qwencloud.com/billing/subscription/token-plan-individual")!
    static let origin = "https://home.qwencloud.com"
    static let gateway = "https://cs-data.qwencloud.com/data/api.json"
    static let usageAPI = "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage"
    static let subscriptionAPI = "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/subscription"
    static let productCode = "sfm_tokenplansolo_public_intl"
    static let browserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    public func isConfigured(config: ConfigStore) -> Bool {
        config.credential(for: .qwen) != nil
    }

    public func fetch(config: ConfigStore) async throws -> UsageSnapshot {
        guard let raw = config.credential(for: .qwen), let cookie = Self.normalizeCookie(raw) else {
            throw ProviderError.notConfigured(hint: ProviderID.qwen.setupHint)
        }
        // The console injects sec_token into the signed-in page; a page
        // without one is the login page.
        let page = try await HTTP.get(Self.dashboard, headers: [
            "Cookie": cookie,
            "Accept": "text/html,application/xhtml+xml",
            "User-Agent": Self.browserAgent,
        ]).requireOK()
        guard let secToken = Self.secToken(inHTML: String(decoding: page.data, as: UTF8.self))
            ?? Self.cookieValue("sec_token", in: cookie)
        else { throw ProviderError.unauthorized }

        let usage = try await Self.call(Self.usageAPI, data: [:], secToken: secToken, cookie: cookie).requireOK()
        let subscription = try? await Self.call(
            Self.subscriptionAPI, data: ["commodityCode": Self.productCode], secToken: secToken, cookie: cookie)
            .requireOK()
        return try Self.parse(usage.data, subscription: subscription?.data)
    }

    // MARK: Console gateway

    static func call(_ api: String, data: [String: String], secToken: String, cookie: String) async throws -> HTTPResponse {
        var components = URLComponents(string: gateway)!
        components.queryItems = [
            URLQueryItem(name: "action", value: "IntlBroadScopeAspnGateway"),
            URLQueryItem(name: "product", value: "sfm_bailian"),
            URLQueryItem(name: "api", value: api),
            URLQueryItem(name: "_v", value: "undefined"),
        ]
        var cornerstone: [String: Any] = [
            "feTraceId": UUID().uuidString.lowercased(),
            "feURL": dashboard.absoluteString,
            "protocol": "V2",
            "console": "ONE_CONSOLE",
            "productCode": "p_efm",
            "domain": dashboard.host ?? "home.qwencloud.com",
            "consoleSite": "QWENCLOUD",
            "userNickName": "",
            "userPrincipalName": "",
            "xsp_lang": "en-US",
        ]
        if let anonymous = cookieValue("cna", in: cookie) { cornerstone["X-Anonymous-Id"] = anonymous }
        var payload: [String: Any] = data
        payload["cornerstoneParam"] = cornerstone
        let params: [String: Any] = ["Api": api, "V": "1.0", "Data": payload]
        let paramsJSON = String(decoding: try JSONSerialization.data(withJSONObject: params), as: UTF8.self)

        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "product", value: "sfm_bailian"),
            URLQueryItem(name: "action", value: "IntlBroadScopeAspnGateway"),
            URLQueryItem(name: "sec_token", value: secToken),
            URLQueryItem(name: "region", value: "ap-southeast-1"),
            URLQueryItem(name: "language", value: "en-US"),
            URLQueryItem(name: "params", value: paramsJSON),
        ]
        var headers = [
            "Content-Type": "application/x-www-form-urlencoded",
            "Accept": "application/json, text/plain, */*",
            "Cookie": cookie,
            "Origin": origin,
            "Referer": dashboard.absoluteString,
            "X-Requested-With": "XMLHttpRequest",
            "User-Agent": browserAgent,
        ]
        if let csrf = cookieValue("login_aliyunid_csrf", in: cookie) ?? cookieValue("csrf", in: cookie) {
            headers["x-xsrf-token"] = csrf
            headers["x-csrf-token"] = csrf
        }
        return try await HTTP.post(components.url!, headers: headers, jsonBody: form.percentEncodedQuery ?? "")
    }

    // MARK: Parsing

    /// The gateway wraps the plan API's JSON as a string inside its own
    /// JSON, sometimes twice; the usage object is wherever it ends up.
    public static func parse(_ data: Data, subscription: Data? = nil, now: Date = Date()) throws -> UsageSnapshot {
        guard let raw = try? JSONSerialization.jsonObject(with: data) else { throw ProviderError.badResponse }
        let expanded = expandEmbeddedJSON(raw)
        guard let usage = findObject(containingAnyOf: ["per5HourPercentage", "per1WeekPercentage"], in: expanded) else {
            if String(decoding: data, as: UTF8.self).lowercased().contains("login") { throw ProviderError.unauthorized }
            throw ProviderError.badResponse
        }
        var windows: [UsageWindow] = []
        if let ratio = number(usage["per5HourPercentage"]) {
            windows.append(UsageWindow(
                title: L10n.t("5-hour window", "5 小时窗口"),
                usedPercent: percent(ratio),
                resetsAt: date(usage["per5HourResetTime"]),
                windowSeconds: 5 * 3600))
        }
        if let ratio = number(usage["per1WeekPercentage"]) {
            windows.append(UsageWindow(
                title: L10n.t("Weekly window", "周窗口"),
                usedPercent: percent(ratio),
                resetsAt: date(usage["per1WeekResetTime"]),
                windowSeconds: 7 * 86_400))
        }
        guard !windows.isEmpty else { throw ProviderError.badResponse }
        return UsageSnapshot(planName: subscription.flatMap(planName), windows: windows)
    }

    static func planName(from data: Data) -> String? {
        guard let raw = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let keys = ["specCode", "spec_code", "planName", "plan_name"]
        guard let plan = findObject(containingAnyOf: Set(keys), in: expandEmbeddedJSON(raw)) else { return nil }
        for key in keys {
            guard let value = (plan[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !value.isEmpty else { continue }
            switch value {
            case "lite": return "Lite"
            case "standard": return "Standard"
            case "pro": return "Pro"
            case "max": return "Max"
            default: return value
            }
        }
        return nil
    }

    /// Ratios come as 0–1, occasionally already as 0–100.
    static func percent(_ ratio: Double) -> Double {
        ratio <= 1 ? ratio * 100 : ratio
    }

    static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: return number.doubleValue
        case let string as String: return Double(string)
        default: return nil
        }
    }

    /// Epoch milliseconds, epoch seconds, or an ISO string.
    static func date(_ value: Any?) -> Date? {
        if let string = value as? String, let iso = Dates.parseISO(string) { return iso }
        guard let raw = number(value) else { return nil }
        return Dates.parseEpoch(raw)
    }

    static func expandEmbeddedJSON(_ value: Any) -> Any {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("{") || trimmed.hasPrefix("["),
                  let data = trimmed.data(using: .utf8),
                  let decoded = try? JSONSerialization.jsonObject(with: data)
            else { return value }
            return expandEmbeddedJSON(decoded)
        }
        if let dictionary = value as? [String: Any] { return dictionary.mapValues(expandEmbeddedJSON) }
        if let array = value as? [Any] { return array.map(expandEmbeddedJSON) }
        return value
    }

    static func findObject(containingAnyOf keys: Set<String>, in value: Any) -> [String: Any]? {
        if let dictionary = value as? [String: Any] {
            if !keys.isDisjoint(with: dictionary.keys) { return dictionary }
            for child in dictionary.values {
                if let found = findObject(containingAnyOf: keys, in: child) { return found }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let found = findObject(containingAnyOf: keys, in: child) { return found }
            }
        }
        return nil
    }

    // MARK: Cookies

    /// "Cookie: a=b; c=d" as pasted from DevTools, or the bare pairs.
    static func normalizeCookie(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("cookie:") { value = String(value.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        return value.isEmpty ? nil : value
    }

    static func cookieValue(_ name: String, in header: String) -> String? {
        for pair in header.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0] == name, !parts[1].isEmpty else { continue }
            return parts[1]
        }
        return nil
    }

    static func secToken(inHTML html: String) -> String? {
        let patterns = [
            #""sec_token"\s*:\s*"([^"]+)""#,
            #"sec_token['"]?\s*[:=]\s*['"]([^'"]+)['"]"#,
            #""secToken"\s*:\s*"([^"]+)""#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: 1), in: html)
            else { continue }
            let token = String(html[range])
            if !token.isEmpty { return token }
        }
        return nil
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

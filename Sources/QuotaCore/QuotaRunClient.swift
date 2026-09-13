import CryptoKit
import Foundation

// MARK: - Quota Run wire client (docs/quota-run.md)

/// base64url without padding — every key, nonce and signature on the wire.
public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ string: String) -> Data? {
        var base = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base.count % 4
        guard remainder != 1 else { return nil }
        if remainder > 0 { base += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base)
    }
}

/// The device's signing key, wherever it lives. The Secure Enclave key and the
/// software fallback both reach the client through this, and the tests sign
/// with a software key.
public protocol RunSigner: Sendable {
    /// X9.63 uncompressed point, 65 bytes.
    var publicKeyX963: Data { get }
    /// ECDSA P-256 over SHA-256 of `data`, DER encoded.
    func signature(for data: Data) throws -> Data
}

public struct SoftwareRunSigner: RunSigner {
    public let key: P256.Signing.PrivateKey

    public init(key: P256.Signing.PrivateKey = P256.Signing.PrivateKey()) {
        self.key = key
    }

    public var publicKeyX963: Data { key.publicKey.x963Representation }

    public func signature(for data: Data) throws -> Data {
        try key.signature(for: data).derRepresentation
    }
}

/// The string every authenticated request signs.
public enum RunCanonical {
    public static let prefix = "quota-run-v1"

    /// Lower-case hex SHA-256 of the raw body; of the empty string without one.
    public static func bodyHash(_ body: Data?) -> String {
        SHA256.hash(data: body ?? Data()).hexString
    }

    public static func string(method: String, path: String, timestamp: Int, nonce: String, body: Data?) -> String {
        [prefix, method.uppercased(), path, String(timestamp), nonce, bodyHash(body)].joined(separator: "\n")
    }
}

// MARK: - Payloads

public enum RunRegion: String, Codable, CaseIterable, Identifiable, Sendable {
    case global
    case china

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .global: L10n.t("Global", "全球")
        case .china: L10n.t("China", "中国")
        }
    }
}

/// `POST /snapshots` — field names and nulls exactly as the contract writes them.
public struct RunSnapshotPayload: Codable, Equatable, Sendable {
    public var provider: String
    public var plan: String?
    public var accountDigest: String?
    public var windowKey: String
    public var windowTitle: String
    public var windowSeconds: Int
    public var scope: String?
    public var usedPercent: Double
    public var resetsAt: Int?
    public var observedAt: Int
    public var source: String

    public init(_ reading: RunReading) {
        provider = reading.provider
        plan = reading.plan
        accountDigest = reading.accountDigest
        windowKey = reading.windowKey
        windowTitle = reading.windowTitle
        windowSeconds = reading.windowSeconds
        scope = reading.scope
        usedPercent = reading.usedPercent
        resetsAt = reading.resetsAt
        observedAt = reading.observedAt
        source = reading.source
    }

    private enum CodingKeys: String, CodingKey {
        case provider, plan, accountDigest, windowKey, windowTitle, windowSeconds, scope, usedPercent, resetsAt, observedAt, source
    }

    /// Absent values go out as `null`, not as a missing key, like the
    /// contract's example.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(provider, forKey: .provider)
        try c.encode(plan, forKey: .plan)
        try c.encode(accountDigest, forKey: .accountDigest)
        try c.encode(windowKey, forKey: .windowKey)
        try c.encode(windowTitle, forKey: .windowTitle)
        try c.encode(windowSeconds, forKey: .windowSeconds)
        try c.encode(scope, forKey: .scope)
        try c.encode(usedPercent, forKey: .usedPercent)
        try c.encode(resetsAt, forKey: .resetsAt)
        try c.encode(observedAt, forKey: .observedAt)
        try c.encode(source, forKey: .source)
    }
}

public struct RunActivityPayload: Codable, Equatable, Sendable {
    public var minute: Int
    public var source: String
    public var tokens: Int

    public init(minute: Int, source: String, tokens: Int) {
        self.minute = minute
        self.source = source
        self.tokens = tokens
    }
}

public struct RunUploadBody: Encodable, Sendable {
    public var snapshots: [RunSnapshotPayload]
    public var activity: [RunActivityPayload]

    public init(snapshots: [RunSnapshotPayload], activity: [RunActivityPayload]) {
        self.snapshots = snapshots
        self.activity = activity
    }
}

public struct RunLinks: Codable, Equatable, Sendable {
    public var website: String?
    public var github: String?
    public var x: String?

    public init(website: String? = nil, github: String? = nil, x: String? = nil) {
        self.website = website
        self.github = github
        self.x = x
    }

    private enum CodingKeys: String, CodingKey { case website, github, x }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        website = try? c.decodeIfPresent(String.self, forKey: .website)
        github = try? c.decodeIfPresent(String.self, forKey: .github)
        x = try? c.decodeIfPresent(String.self, forKey: .x)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(website.nilIfBlank, forKey: .website)
        try c.encode(github.nilIfBlank, forKey: .github)
        try c.encode(x.nilIfBlank, forKey: .x)
    }
}

public struct RunUser: Codable, Equatable, Sendable {
    public var username: String
    public var displayName: String
    public var bio: String
    public var region: RunRegion
    public var links: RunLinks
    public var joinedAt: Date?

    public init(username: String, displayName: String, bio: String = "", region: RunRegion = .global, links: RunLinks = RunLinks(), joinedAt: Date? = nil) {
        self.username = username
        self.displayName = displayName
        self.bio = bio
        self.region = region
        self.links = links
        self.joinedAt = joinedAt
    }

    private enum CodingKeys: String, CodingKey { case username, displayName, bio, region, links, joinedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        username = try c.decode(String.self, forKey: .username)
        displayName = (try? c.decodeIfPresent(String.self, forKey: .displayName)) ?? username
        bio = (try? c.decodeIfPresent(String.self, forKey: .bio)) ?? ""
        region = (try? c.decodeIfPresent(String.self, forKey: .region)).flatMap(RunRegion.init(rawValue:)) ?? .global
        links = (try? c.decodeIfPresent(RunLinks.self, forKey: .links)) ?? RunLinks()
        joinedAt = c.lenientDate(.joinedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(username, forKey: .username)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(bio, forKey: .bio)
        try c.encode(region, forKey: .region)
        try c.encode(links, forKey: .links)
        try c.encodeIfPresent(joinedAt.map { Int($0.timeIntervalSince1970) }, forKey: .joinedAt)
    }
}

public struct RunDevice: Codable, Equatable, Sendable, Identifiable {
    public var deviceId: String
    public var name: String
    public var ranked: Bool
    public var lastSeenAt: Date?
    public var current: Bool

    public var id: String { deviceId }

    public init(deviceId: String, name: String, ranked: Bool, lastSeenAt: Date? = nil, current: Bool = false) {
        self.deviceId = deviceId
        self.name = name
        self.ranked = ranked
        self.lastSeenAt = lastSeenAt
        self.current = current
    }

    private enum CodingKeys: String, CodingKey { case deviceId, name, ranked, lastSeenAt, current }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceId = try c.decode(String.self, forKey: .deviceId)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Mac"
        ranked = (try? c.decodeIfPresent(Bool.self, forKey: .ranked)) ?? false
        lastSeenAt = c.lenientDate(.lastSeenAt)
        current = (try? c.decodeIfPresent(Bool.self, forKey: .current)) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(deviceId, forKey: .deviceId)
        try c.encode(name, forKey: .name)
        try c.encode(ranked, forKey: .ranked)
        try c.encodeIfPresent(lastSeenAt.map { Int($0.timeIntervalSince1970) }, forKey: .lastSeenAt)
        try c.encode(current, forKey: .current)
    }
}

public struct RunProject: Codable, Equatable, Sendable {
    public static let limit = 12

    public var name: String
    public var url: String
    public var description: String
    public var github: String?
    /// Provider raw values.
    public var builtWith: [String]

    public init(name: String = "", url: String = "", description: String = "", github: String? = nil, builtWith: [String] = []) {
        self.name = name
        self.url = url
        self.description = description
        self.github = github
        self.builtWith = builtWith
    }

    private enum CodingKeys: String, CodingKey { case name, url, description, github, builtWith }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        url = (try? c.decodeIfPresent(String.self, forKey: .url)) ?? ""
        description = (try? c.decodeIfPresent(String.self, forKey: .description)) ?? ""
        github = try? c.decodeIfPresent(String.self, forKey: .github)
        builtWith = (try? c.decodeIfPresent([String].self, forKey: .builtWith)) ?? []
    }

    /// `github` is optional in the contract, so an empty one is left out.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(url, forKey: .url)
        try c.encode(description, forKey: .description)
        try c.encodeIfPresent(github.nilIfBlank, forKey: .github)
        try c.encode(builtWith, forKey: .builtWith)
    }

    /// What the server would refuse, checked before sending: a name, and an
    /// `https://` address. GitHub may be `owner/repo` — the server expands it.
    public var problem: String? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty { return L10n.t("Give the project a name.", "请填写项目名称。") }
        if trimmedName.count > 40 { return L10n.t("Names are at most 40 characters.", "名称最多 40 个字符。") }
        if description.count > 140 { return L10n.t("Descriptions are at most 140 characters.", "简介最多 140 个字符。") }
        if !RunProject.isHTTPS(url) { return L10n.t("The address must start with https://.", "网址必须以 https:// 开头。") }
        if let github = github.nilIfBlank, !RunProject.isHandleOrHTTPS(github) {
            return L10n.t("GitHub takes owner/repo or an https:// address.", "GitHub 请填 owner/repo 或 https:// 地址。")
        }
        return nil
    }

    public static func isHTTPS(_ string: String) -> Bool {
        guard let components = URLComponents(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "https", let host = components.host, !host.isEmpty
        else { return false }
        return true
    }

    /// A bare handle (`gentpan`, `@gentpan`, `owner/repo`) or an `https://`
    /// address; anything with another scheme is refused.
    public static func isHandleOrHTTPS(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if trimmed.contains("://") || lower.hasPrefix("http:") || lower.hasPrefix("https:") { return isHTTPS(trimmed) }
        return !trimmed.contains(where: \.isWhitespace)
    }
}

public struct RunMe: Codable, Equatable, Sendable {
    public var user: RunUser
    public var devices: [RunDevice]
    public var rankedChangeAvailableAt: Date?
    public var lastUploadAt: Date?
    public var projects: [RunProject]

    public init(user: RunUser, devices: [RunDevice] = [], rankedChangeAvailableAt: Date? = nil, lastUploadAt: Date? = nil, projects: [RunProject] = []) {
        self.user = user
        self.devices = devices
        self.rankedChangeAvailableAt = rankedChangeAvailableAt
        self.lastUploadAt = lastUploadAt
        self.projects = projects
    }

    private enum CodingKeys: String, CodingKey { case user, devices, rankedChangeAvailableAt, lastUploadAt, projects }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        user = try c.decode(RunUser.self, forKey: .user)
        devices = (try? c.decodeIfPresent([RunDevice].self, forKey: .devices)) ?? []
        rankedChangeAvailableAt = c.lenientDate(.rankedChangeAvailableAt)
        lastUploadAt = c.lenientDate(.lastUploadAt)
        projects = (try? c.decodeIfPresent([RunProject].self, forKey: .projects)) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(user, forKey: .user)
        try c.encode(devices, forKey: .devices)
        try c.encodeIfPresent(rankedChangeAvailableAt.map { Int($0.timeIntervalSince1970) }, forKey: .rankedChangeAvailableAt)
        try c.encodeIfPresent(lastUploadAt.map { Int($0.timeIntervalSince1970) }, forKey: .lastUploadAt)
        try c.encode(projects, forKey: .projects)
    }

    /// The device this request came from, as the server sees it.
    public var currentDevice: RunDevice? { devices.first { $0.current } }
}

public struct RunRegistration: Decodable, Equatable, Sendable {
    public var user: RunUser
    public var deviceId: String
    public var ranked: Bool

    private enum CodingKeys: String, CodingKey { case user, deviceId, ranked }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        user = try c.decode(RunUser.self, forKey: .user)
        deviceId = try c.decode(String.self, forKey: .deviceId)
        ranked = (try? c.decodeIfPresent(Bool.self, forKey: .ranked)) ?? false
    }
}

public struct RunUploadReceipt: Decodable, Equatable, Sendable {
    public struct Rejection: Decodable, Equatable, Sendable {
        public var index: Int
        public var reason: String
    }

    public var accepted: Int
    public var duplicates: Int
    public var rejected: [Rejection]

    private enum CodingKeys: String, CodingKey { case accepted, duplicates, rejected }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accepted = (try? c.decodeIfPresent(Int.self, forKey: .accepted)) ?? 0
        duplicates = (try? c.decodeIfPresent(Int.self, forKey: .duplicates)) ?? 0
        rejected = (try? c.decodeIfPresent([Rejection].self, forKey: .rejected)) ?? []
    }
}

public struct RunPairCode: Decodable, Equatable, Sendable {
    public var code: String
    public var expiresAt: Date?

    public init(code: String, expiresAt: Date?) {
        self.code = code
        self.expiresAt = expiresAt
    }

    private enum CodingKeys: String, CodingKey { case code, expiresAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decode(String.self, forKey: .code)
        expiresAt = c.lenientDate(.expiresAt)
    }
}

extension KeyedDecodingContainer {
    /// Unix seconds or milliseconds, or an ISO-8601 string — the contract
    /// does not pin the form, so accept what a server is likely to send.
    func lenientDate(_ key: Key) -> Date? {
        if let number = try? decodeIfPresent(Double.self, forKey: key) { return Dates.parseEpoch(number) }
        if let string = try? decodeIfPresent(String.self, forKey: key) { return Dates.parseAny(string) }
        return nil
    }
}

extension Optional where Wrapped == String {
    var nilIfBlank: String? {
        guard let trimmed = self?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

// MARK: - Usernames

public enum RunUsername {
    public static let reserved: Set<String> = [
        "admin", "api", "app", "about", "help", "leaderboard", "run", "quota", "quotabar", "settings", "support",
        "www", "zh", "en", "me", "user", "users", "login", "logout", "signup", "register", "profile", "u",
    ]

    public enum Problem: Equatable, Sendable {
        case empty
        case invalid
        case reserved

        public var message: String {
            switch self {
            case .empty: L10n.t("Choose a username.", "请填写用户名。")
            case .invalid: L10n.t(
                "3–20 characters: lower-case letters, digits, _ and -, starting with a letter or digit.",
                "3–20 个字符：小写字母、数字、_ 和 -，以字母或数字开头。")
            case .reserved: L10n.t("That name is reserved.", "这个用户名是保留字，不能使用。")
            }
        }
    }

    /// Case-folded and trimmed, as the server stores it.
    public static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static func problem(_ raw: String) -> Problem? {
        let name = normalize(raw)
        guard !name.isEmpty else { return .empty }
        guard name.range(of: "^[a-z0-9][a-z0-9_-]{2,19}$", options: .regularExpression) != nil else { return .invalid }
        return reserved.contains(name) ? .reserved : nil
    }
}

// MARK: - Errors

public struct QuotaRunError: LocalizedError, Equatable, Sendable {
    /// HTTP status; 0 when the request never got an answer.
    public var status: Int
    /// The server's `error` code, or `network` / `bad_response` / `signing`.
    public var code: String
    public var message: String
    /// For `409 cooldown`: when the ranked device may change again.
    public var availableAt: Date?
    /// For a 401 over clock skew: how far this Mac's clock is ahead of the
    /// server's, in seconds (negative when behind).
    public var clockSkew: TimeInterval?
    /// For 429: how long the server asked to be left alone.
    public var retryAfter: TimeInterval?

    public init(status: Int, code: String, message: String = "", availableAt: Date? = nil, clockSkew: TimeInterval? = nil, retryAfter: TimeInterval? = nil) {
        self.status = status
        self.code = code
        self.message = message
        self.availableAt = availableAt
        self.clockSkew = clockSkew
        self.retryAfter = retryAfter
    }

    /// The key was not accepted: revoked, or the account is gone. Uploading
    /// again will not help. A 401 that is only this Mac's clock being off is
    /// not one — it passes once the clock is right.
    public var isAuthFailure: Bool { (status == 401 || status == 403) && clockSkew == nil }

    public static func network(_ message: String) -> QuotaRunError {
        QuotaRunError(status: 0, code: "network", message: message)
    }

    public static let badResponse = QuotaRunError(status: 0, code: "bad_response")
    public static let signing = QuotaRunError(status: 0, code: "signing")

    /// Maps a non-2xx answer through its `{"error", "message"}` body, plus
    /// the extras some answers carry: `availableAt` (cooldown), `serverTime`
    /// (a 401 over the clock), `retryAfter` (429).
    public static func from(status: Int, body: Data, now: Date = Date()) -> QuotaRunError {
        struct Body: Decodable {
            let error: String?
            let message: String?
            let availableAt: Double?
            let availableAtText: String?
            let serverTime: Double?
            let retryAfter: Double?

            private enum CodingKeys: String, CodingKey { case error, message, availableAt, serverTime, retryAfter }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                error = try? c.decodeIfPresent(String.self, forKey: .error)
                message = try? c.decodeIfPresent(String.self, forKey: .message)
                availableAt = try? c.decodeIfPresent(Double.self, forKey: .availableAt)
                availableAtText = try? c.decodeIfPresent(String.self, forKey: .availableAt)
                serverTime = try? c.decodeIfPresent(Double.self, forKey: .serverTime)
                retryAfter = try? c.decodeIfPresent(Double.self, forKey: .retryAfter)
            }
        }
        let parsed = try? JSONDecoder().decode(Body.self, from: body)
        let fallback: String
        switch status {
        case 401: fallback = "unauthorized"
        case 403: fallback = "forbidden"
        case 404: fallback = "not_found"
        case 409: fallback = "conflict"
        case 413: fallback = "too_large"
        case 429: fallback = "rate_limited"
        default: fallback = "http_\(status)"
        }
        let serverTime = status == 401 ? parsed?.serverTime.flatMap(Dates.parseEpoch) : nil
        return QuotaRunError(
            status: status,
            code: parsed?.error ?? fallback,
            message: parsed?.message ?? "",
            availableAt: parsed?.availableAt.flatMap(Dates.parseEpoch) ?? Dates.parseAny(parsed?.availableAtText),
            clockSkew: serverTime.map { now.timeIntervalSince($0) },
            retryAfter: parsed?.retryAfter.flatMap { $0 > 0 ? $0 : nil })
    }

    public var errorDescription: String? {
        if let clockSkew {
            let minutes = max(1, Int((abs(clockSkew) / 60).rounded()))
            return clockSkew > 0
                ? L10n.t(
                    "This Mac's clock is \(minutes) min ahead of quota.run's. Turn on \"Set time and date automatically\" in System Settings.",
                    "这台 Mac 的时钟比 quota.run 快了 \(minutes) 分钟。请在系统设置里打开「自动设置日期与时间」。")
                : L10n.t(
                    "This Mac's clock is \(minutes) min behind quota.run's. Turn on \"Set time and date automatically\" in System Settings.",
                    "这台 Mac 的时钟比 quota.run 慢了 \(minutes) 分钟。请在系统设置里打开「自动设置日期与时间」。")
        }
        switch code {
        case "username_taken": return L10n.t("That username is taken.", "这个用户名已被占用。")
        case "invalid_username": return RunUsername.Problem.invalid.message
        case "pair_code_invalid": return L10n.t("That pairing code is wrong or has expired.", "配对码不正确或已过期。")
        case "current_device": return L10n.t("This Mac cannot remove itself; leave Quota Run instead.", "不能移除本机；如需退出请使用「退出 Quota Run」。")
        case "ranked_device": return L10n.t("Make another Mac the ranked device before removing this one.", "请先把另一台 Mac 设为计分设备，再移除这台。")
        case "cooldown":
            if let availableAt {
                return L10n.t(
                    "The ranked device can change again on \(Self.day(availableAt)).",
                    "\(Self.day(availableAt))之后才能再次更换计分设备。")
            }
            return L10n.t("The ranked device changed less than 7 days ago.", "计分设备 7 天内只能更换一次。")
        case "network":
            return L10n.t("Could not reach quota.run (\(message)).", "连不上 quota.run（\(message)）。")
        case "bad_response": return L10n.t("quota.run sent an answer this version cannot read.", "quota.run 返回了这个版本读不懂的内容。")
        case "signing": return L10n.t("This Mac's key could not sign the request.", "本机密钥无法签名请求。")
        default:
            if isAuthFailure {
                return L10n.t(
                    "quota.run no longer accepts this Mac's key. It may have been removed from your account.",
                    "quota.run 不再接受这台 Mac 的密钥，可能已从你的账户中移除。")
            }
            if status == 429 { return L10n.t("Too many requests; trying again later.", "请求太频繁，稍后再试。") }
            // The server's own sentence is English; better than a bare code.
            return message.isEmpty ? L10n.t("quota.run answered HTTP \(status).", "quota.run 返回 HTTP \(status)。") : message
        }
    }

    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.setLocalizedDateFormatFromTemplate("MMMdjm")
        return formatter.string(from: date)
    }
}

// MARK: - Client

/// A request ready to send: the bytes that were signed and the headers that
/// carry the signature.
public struct RunSignedRequest: Sendable, Equatable {
    public var method: String
    public var url: URL
    public var path: String
    public var headers: [String: String]
    public var body: Data?
    /// What the signature covers, for the tests.
    public var canonical: String
}

public struct QuotaRunClient: Sendable {
    public typealias Transport = @Sendable (_ method: String, _ url: URL, _ headers: [String: String], _ body: Data?) async throws -> HTTPResponse

    public static let productionBase = URL(string: "https://quota.run/api/v1")!

    /// `QUOTABAR_RUN_API` points a build at a local or staging server.
    public static var defaultBase: URL {
        if let raw = ProcessInfo.processInfo.environment["QUOTABAR_RUN_API"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let url = URL(string: raw), url.scheme != nil, url.host != nil
        {
            return url
        }
        return productionBase
    }

    public var base: URL
    public var signer: RunSigner
    /// Absent until registration hands one out.
    public var deviceId: String?
    public var transport: Transport
    public var clock: @Sendable () -> Date
    public var nonce: @Sendable () -> Data

    public init(
        base: URL = QuotaRunClient.defaultBase,
        signer: RunSigner,
        deviceId: String? = nil,
        transport: @escaping Transport = { method, url, headers, body in
            try await HTTP.send(method, url, headers: headers, body: body)
        },
        clock: @escaping @Sendable () -> Date = { Date() },
        nonce: @escaping @Sendable () -> Data = { QuotaRunClient.randomNonce() })
    {
        self.base = base
        self.signer = signer
        self.deviceId = deviceId
        self.transport = transport
        self.clock = clock
        self.nonce = nonce
    }

    public static func randomNonce() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<16).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    /// Builds and signs a request without sending it.
    public func signedRequest(_ method: String, _ endpoint: String, body: Data? = nil) throws -> RunSignedRequest {
        var text = base.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text + endpoint) else { throw QuotaRunError.badResponse }
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        let timestamp = Int(clock().timeIntervalSince1970)
        let nonce = Base64URL.encode(self.nonce())
        let canonical = RunCanonical.string(method: method, path: path, timestamp: timestamp, nonce: nonce, body: body)
        let signature: Data
        do {
            signature = try signer.signature(for: Data(canonical.utf8))
        } catch {
            throw QuotaRunError.signing
        }
        var headers = [
            "Accept": "application/json",
            "User-Agent": "QuotaBar",
            "X-Quota-Timestamp": String(timestamp),
            "X-Quota-Nonce": nonce,
            "X-Quota-Signature": Base64URL.encode(signature),
        ]
        if let deviceId { headers["X-Quota-Device"] = deviceId }
        if body != nil { headers["Content-Type"] = "application/json" }
        return RunSignedRequest(method: method.uppercased(), url: url, path: path, headers: headers, body: body, canonical: canonical)
    }

    private func send(_ method: String, _ endpoint: String, json: (some Encodable)?) async throws -> Data {
        let body = try json.map { try Self.encoder.encode($0) }
        let request = try signedRequest(method, endpoint, body: body)
        let response: HTTPResponse
        do {
            response = try await transport(request.method, request.url, request.headers, request.body)
        } catch let error as QuotaRunError {
            throw error
        } catch {
            let message = (error as? ProviderError).flatMap { error -> String? in
                if case let .network(text) = error { return text }
                return nil
            } ?? error.localizedDescription
            throw QuotaRunError.network(message)
        }
        guard (200...299).contains(response.status) else {
            throw QuotaRunError.from(status: response.status, body: response.data, now: clock())
        }
        return response.data
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw QuotaRunError.badResponse
        }
    }

    private struct Empty: Encodable {}

    // MARK: Endpoints

    public struct RegisterBody: Encodable, Sendable {
        public var username: String?
        public var displayName: String?
        public var region: RunRegion?
        public var pairCode: String?
        public var publicKey: String
        public var deviceName: String
        public var platform = "macos"
        public var appVersion: String
    }

    public func register(username: String, displayName: String, region: RunRegion, deviceName: String, appVersion: String) async throws -> RunRegistration {
        let body = RegisterBody(
            username: RunUsername.normalize(username), displayName: displayName, region: region, pairCode: nil,
            publicKey: Base64URL.encode(signer.publicKeyX963), deviceName: deviceName, appVersion: appVersion)
        return try decode(RunRegistration.self, try await send("POST", "/register", json: body))
    }

    public func register(pairCode: String, deviceName: String, appVersion: String) async throws -> RunRegistration {
        let code = pairCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let body = RegisterBody(
            username: nil, displayName: nil, region: nil, pairCode: code,
            publicKey: Base64URL.encode(signer.publicKeyX963), deviceName: deviceName, appVersion: appVersion)
        return try decode(RunRegistration.self, try await send("POST", "/register", json: body))
    }

    public func me() async throws -> RunMe {
        try decode(RunMe.self, try await send("GET", "/me", json: Optional<Empty>.none))
    }

    public func upload(_ body: RunUploadBody) async throws -> RunUploadReceipt {
        try decode(RunUploadReceipt.self, try await send("POST", "/snapshots", json: body))
    }

    public struct ProfileBody: Encodable, Sendable {
        public var displayName: String
        public var bio: String
        public var region: RunRegion
        public var links: RunLinks

        public init(displayName: String, bio: String, region: RunRegion, links: RunLinks) {
            self.displayName = displayName
            self.bio = bio
            self.region = region
            self.links = links
        }
    }

    public func updateProfile(_ body: ProfileBody) async throws -> RunUser {
        struct Answer: Decodable { let user: RunUser }
        return try decode(Answer.self, try await send("PUT", "/profile", json: body)).user
    }

    public func updateProjects(_ projects: [RunProject]) async throws -> [RunProject] {
        struct Body: Encodable { let projects: [RunProject] }
        struct Answer: Decodable { let projects: [RunProject] }
        return try decode(Answer.self, try await send("PUT", "/projects", json: Body(projects: projects))).projects
    }

    public struct RankedChange: Decodable, Equatable, Sendable {
        public var devices: [RunDevice]
        /// Null once a change is allowed again.
        public var rankedChangeAvailableAt: Date?

        private enum CodingKeys: String, CodingKey { case devices, rankedChangeAvailableAt }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            devices = (try? c.decodeIfPresent([RunDevice].self, forKey: .devices)) ?? []
            rankedChangeAvailableAt = c.lenientDate(.rankedChangeAvailableAt)
        }
    }

    public func setRanked(deviceId: String) async throws -> RankedChange {
        struct Body: Encodable { let deviceId: String }
        return try decode(RankedChange.self, try await send("POST", "/devices/ranked", json: Body(deviceId: deviceId)))
    }

    public func pair() async throws -> RunPairCode {
        try decode(RunPairCode.self, try await send("POST", "/pair", json: Optional<Empty>.none))
    }

    public func deleteDevice(_ deviceId: String) async throws -> [RunDevice] {
        struct Answer: Decodable { let devices: [RunDevice] }
        let escaped = deviceId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? deviceId
        return try decode(Answer.self, try await send("DELETE", "/devices/\(escaped)", json: Optional<Empty>.none)).devices
    }

    public func deleteAccount() async throws {
        _ = try await send("DELETE", "/account", json: Optional<Empty>.none)
    }
}

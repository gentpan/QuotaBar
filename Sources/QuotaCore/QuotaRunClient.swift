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
    /// The QuotaBar version the Mac connected with; absent from older servers.
    public var appVersion: String?

    public var id: String { deviceId }

    public init(deviceId: String, name: String, ranked: Bool, lastSeenAt: Date? = nil, current: Bool = false, appVersion: String? = nil) {
        self.deviceId = deviceId
        self.name = name
        self.ranked = ranked
        self.lastSeenAt = lastSeenAt
        self.current = current
        self.appVersion = appVersion
    }

    private enum CodingKeys: String, CodingKey { case deviceId, name, ranked, lastSeenAt, current, appVersion }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceId = try c.decode(String.self, forKey: .deviceId)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Mac"
        ranked = (try? c.decodeIfPresent(Bool.self, forKey: .ranked)) ?? false
        lastSeenAt = c.lenientDate(.lastSeenAt)
        current = (try? c.decodeIfPresent(Bool.self, forKey: .current)) ?? false
        appVersion = (try? c.decodeIfPresent(String.self, forKey: .appVersion)).nilIfBlank
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(deviceId, forKey: .deviceId)
        try c.encode(name, forKey: .name)
        try c.encode(ranked, forKey: .ranked)
        try c.encodeIfPresent(lastSeenAt.map { Int($0.timeIntervalSince1970) }, forKey: .lastSeenAt)
        try c.encode(current, forKey: .current)
        try c.encodeIfPresent(appVersion, forKey: .appVersion)
    }
}

/// One way into the account on quota.run: Google, GitHub or an email code.
/// The app only shows these; linking and removing happen on the account page.
public struct RunIdentity: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    /// `google`, `github` or `email`.
    public var provider: String
    public var email: String?
    public var name: String?
    public var linkedAt: Date?

    public init(id: String, provider: String, email: String? = nil, name: String? = nil, linkedAt: Date? = nil) {
        self.id = id
        self.provider = provider
        self.email = email
        self.name = name
        self.linkedAt = linkedAt
    }

    private enum CodingKeys: String, CodingKey { case id, provider, email, name, linkedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A row id, which a server may well send as a number.
        if let text = try? c.decode(String.self, forKey: .id) {
            id = text
        } else {
            id = String(try c.decode(Int.self, forKey: .id))
        }
        provider = (try? c.decodeIfPresent(String.self, forKey: .provider)) ?? ""
        email = (try? c.decodeIfPresent(String.self, forKey: .email)).nilIfBlank
        name = (try? c.decodeIfPresent(String.self, forKey: .name)).nilIfBlank
        linkedAt = c.lenientDate(.linkedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(provider, forKey: .provider)
        try c.encodeIfPresent(email, forKey: .email)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(linkedAt.map { Int($0.timeIntervalSince1970) }, forKey: .linkedAt)
    }

    /// "GitHub", "Google", "Email".
    public var providerName: String {
        switch provider {
        case "github": "GitHub"
        case "google": "Google"
        case "email": L10n.t("Email", "邮箱")
        default: provider.capitalized
        }
    }

    /// "GitHub · gentpan", "Google · peter@example.com", "Email · peter@example.com":
    /// the name GitHub knows, the address for the other two.
    public var label: String {
        let detail = provider == "github" ? (name ?? email) : (email ?? name)
        return [providerName, detail].compactMap { $0 }.joined(separator: " · ")
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

/// A provider account (the digest of a provider's email or account id) as
/// quota.run holds it for this user. `id` is the first 16 hex characters of
/// the server's HMAC of the digest: shown to its own user only, and all the
/// app needs to unbind it.
public struct RunProviderAccount: Codable, Equatable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable {
        /// This Quota account owns it; its runs can rank.
        case owned
        /// Another Quota account owns it, so this user's runs for it are flagged.
        case elsewhere
    }

    public var id: String
    public var provider: String
    public var firstSeenAt: Date?
    public var lastSeenAt: Date?
    public var status: Status
    /// Owned because its email is one of the account's verified sign-in emails.
    public var verifiedByEmail: Bool
    /// This user's runs for it that are neither flagged nor unranked.
    public var runs: Int

    public init(id: String, provider: String, firstSeenAt: Date? = nil, lastSeenAt: Date? = nil, status: Status = .owned, verifiedByEmail: Bool = false, runs: Int = 0) {
        self.id = id
        self.provider = provider
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.status = status
        self.verifiedByEmail = verifiedByEmail
        self.runs = runs
    }

    private enum CodingKeys: String, CodingKey { case id, provider, firstSeenAt, lastSeenAt, status, verifiedByEmail, runs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let text = try? c.decode(String.self, forKey: .id) {
            id = text
        } else {
            id = String(try c.decode(Int.self, forKey: .id))
        }
        provider = (try? c.decodeIfPresent(String.self, forKey: .provider)) ?? ""
        firstSeenAt = c.lenientDate(.firstSeenAt)
        lastSeenAt = c.lenientDate(.lastSeenAt)
        // A status this version does not know is not a claim of ownership.
        let rawStatus = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? Status.owned.rawValue
        status = Status(rawValue: rawStatus) ?? .elsewhere
        verifiedByEmail = (try? c.decodeIfPresent(Bool.self, forKey: .verifiedByEmail)) ?? false
        runs = max((try? c.decodeIfPresent(Int.self, forKey: .runs)) ?? 0, 0)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(provider, forKey: .provider)
        try c.encodeIfPresent(firstSeenAt.map { Int($0.timeIntervalSince1970) }, forKey: .firstSeenAt)
        try c.encodeIfPresent(lastSeenAt.map { Int($0.timeIntervalSince1970) }, forKey: .lastSeenAt)
        try c.encode(status, forKey: .status)
        try c.encode(verifiedByEmail, forKey: .verifiedByEmail)
        try c.encode(runs, forKey: .runs)
    }
}

/// One answer of `POST /accounts/lookup`: the account, or nil when this user
/// never uploaded the digest.
public struct RunAccountLookup: Codable, Equatable, Sendable {
    public var digest: String
    public var account: RunProviderAccount?

    public init(digest: String, account: RunProviderAccount?) {
        self.digest = digest
        self.account = account
    }

    private enum CodingKeys: String, CodingKey { case digest, account }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        digest = try c.decode(String.self, forKey: .digest).lowercased()
        account = try? c.decodeIfPresent(RunProviderAccount.self, forKey: .account)
    }
}

public struct RunMe: Codable, Equatable, Sendable {
    public var user: RunUser
    public var devices: [RunDevice]
    public var rankedChangeAvailableAt: Date?
    public var lastUploadAt: Date?
    public var projects: [RunProject]
    /// How the account signs in on quota.run.
    public var identities: [RunIdentity]
    /// The provider accounts bound to the account, from every Mac.
    public var providerAccounts: [RunProviderAccount]

    public init(user: RunUser, devices: [RunDevice] = [], rankedChangeAvailableAt: Date? = nil, lastUploadAt: Date? = nil, projects: [RunProject] = [], identities: [RunIdentity] = [], providerAccounts: [RunProviderAccount] = []) {
        self.user = user
        self.devices = devices
        self.rankedChangeAvailableAt = rankedChangeAvailableAt
        self.lastUploadAt = lastUploadAt
        self.projects = projects
        self.identities = identities
        self.providerAccounts = providerAccounts
    }

    private enum CodingKeys: String, CodingKey { case user, devices, rankedChangeAvailableAt, lastUploadAt, projects, identities, providerAccounts }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        user = try c.decode(RunUser.self, forKey: .user)
        devices = (try? c.decodeIfPresent([RunDevice].self, forKey: .devices)) ?? []
        rankedChangeAvailableAt = c.lenientDate(.rankedChangeAvailableAt)
        lastUploadAt = c.lenientDate(.lastUploadAt)
        projects = (try? c.decodeIfPresent([RunProject].self, forKey: .projects)) ?? []
        identities = (try? c.decodeIfPresent([RunIdentity].self, forKey: .identities)) ?? []
        providerAccounts = (try? c.decodeIfPresent([RunProviderAccount].self, forKey: .providerAccounts)) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(user, forKey: .user)
        try c.encode(devices, forKey: .devices)
        try c.encodeIfPresent(rankedChangeAvailableAt.map { Int($0.timeIntervalSince1970) }, forKey: .rankedChangeAvailableAt)
        try c.encodeIfPresent(lastUploadAt.map { Int($0.timeIntervalSince1970) }, forKey: .lastUploadAt)
        try c.encode(projects, forKey: .projects)
        try c.encode(identities, forKey: .identities)
        try c.encode(providerAccounts, forKey: .providerAccounts)
    }

    /// The device this request came from, as the server sees it.
    public var currentDevice: RunDevice? { devices.first { $0.current } }
}

/// Who this Mac became once quota.run approved it: the account, the device id
/// the signatures carry from now on, and whether its readings count.
public struct RunRegistration: Decodable, Equatable, Sendable {
    public var user: RunUser
    public var deviceId: String
    public var ranked: Bool

    public init(user: RunUser, deviceId: String, ranked: Bool) {
        self.user = user
        self.deviceId = deviceId
        self.ranked = ranked
    }

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

/// `POST /connect/start`: the code to compare, the page to approve it on, and
/// how long and how often to ask.
public struct RunConnectStart: Decodable, Equatable, Sendable {
    public var requestId: String
    /// `ABCD-EFGH`.
    public var userCode: String
    public var verifyURL: URL
    public var expiresAt: Date
    /// Seconds between polls.
    public var interval: TimeInterval

    public init(requestId: String, userCode: String, verifyURL: URL, expiresAt: Date, interval: TimeInterval = 3) {
        self.requestId = requestId
        self.userCode = userCode
        self.verifyURL = verifyURL
        self.expiresAt = expiresAt
        self.interval = interval
    }

    private enum CodingKeys: String, CodingKey { case requestId, userCode, verifyURL, expiresAt, interval }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestId = try c.decode(String.self, forKey: .requestId)
        userCode = try c.decode(String.self, forKey: .userCode)
        // Only a web page goes to the browser, whatever the answer says.
        guard let url = URL(string: try c.decode(String.self, forKey: .verifyURL)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http"
        else {
            throw DecodingError.dataCorruptedError(forKey: .verifyURL, in: c, debugDescription: "not a web address")
        }
        verifyURL = url
        // The contract gives the code 10 minutes.
        expiresAt = c.lenientDate(.expiresAt) ?? Date().addingTimeInterval(600)
        let seconds = (try? c.decodeIfPresent(Double.self, forKey: .interval)) ?? 3
        interval = min(max(seconds, 1), 30)
    }
}

/// `POST /connect/poll`.
public enum RunConnectStatus: Equatable, Sendable {
    case pending
    case denied
    case expired
    case approved(RunRegistration)
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
        case "connect_request_invalid":
            return L10n.t("quota.run no longer knows this sign-in request. Sign in again.", "quota.run 已找不到这次登录请求，请重新登录。")
        case "key_registered":
            return L10n.t("This Mac's new key is already connected to an account. Sign in again.", "这台 Mac 的新密钥已经连接过账户，请重新登录。")
        case "not_signed_in": return L10n.t("Sign in on quota.run first.", "请先在 quota.run 登录。")
        case "needs_signup":
            return L10n.t("Finish creating your account on quota.run first.", "请先在 quota.run 完成账户创建。")
        case "invalid_region": return L10n.t("quota.run does not know that region.", "quota.run 不认识这个地区。")
        case "account_not_found":
            return L10n.t("quota.run has no such provider account on your Quota account.", "你的 Quota 账户下没有这个服务商账号。")
        case "invalid_digests":
            return L10n.t("quota.run could not read this Mac's provider account digests.", "quota.run 无法识别这台 Mac 发送的服务商账号摘要。")
        case "current_device": return L10n.t("This Mac cannot remove itself here; use Disconnect This Mac.", "不能在这里移除本机，请使用「断开这台 Mac」。")
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
                    "quota.run no longer accepts this Mac's key; it may have been removed from your account. Disconnect this Mac and sign in again.",
                    "quota.run 不再接受这台 Mac 的密钥，可能已从你的账户中移除。请断开这台 Mac 后重新登录。")
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
    /// Absent until quota.run approves the connection.
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

    /// Builds and signs a request without sending it. `anonymous` leaves the
    /// device id out: `connect/start` and `connect/poll` are verified with
    /// the public key in their body, before there is a device.
    public func signedRequest(_ method: String, _ endpoint: String, body: Data? = nil, anonymous: Bool = false) throws -> RunSignedRequest {
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
        if let deviceId, !anonymous { headers["X-Quota-Device"] = deviceId }
        if body != nil { headers["Content-Type"] = "application/json" }
        return RunSignedRequest(method: method.uppercased(), url: url, path: path, headers: headers, body: body, canonical: canonical)
    }

    private func send(_ method: String, _ endpoint: String, json: (some Encodable)?, anonymous: Bool = false) async throws -> Data {
        let body = try json.map { try Self.encoder.encode($0) }
        let request = try signedRequest(method, endpoint, body: body, anonymous: anonymous)
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

    public struct ConnectStartBody: Encodable, Sendable {
        public var publicKey: String
        public var deviceName: String
        public var platform = "macos"
        public var appVersion: String
        /// `zh` sends the browser to `/zh/connect`.
        public var lang: String
    }

    /// Asks quota.run for a code to approve this Mac's key with. The key is
    /// the client's signer; nothing about the person goes with it.
    public func connectStart(deviceName: String, appVersion: String, lang: String = L10n.isChinese ? "zh" : "en") async throws -> RunConnectStart {
        let body = ConnectStartBody(
            publicKey: Base64URL.encode(signer.publicKeyX963),
            deviceName: String(deviceName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60)),
            appVersion: String(appVersion.prefix(40)),
            lang: lang)
        return try decode(RunConnectStart.self, try await send("POST", "/connect/start", json: body, anonymous: true))
    }

    /// Whether the code has been approved on quota.run yet.
    public func connectPoll(requestId: String) async throws -> RunConnectStatus {
        struct Body: Encodable {
            let requestId: String
            let publicKey: String
        }
        struct Answer: Decodable { let status: String }
        let data = try await send(
            "POST", "/connect/poll",
            json: Body(requestId: requestId, publicKey: Base64URL.encode(signer.publicKeyX963)), anonymous: true)
        switch try decode(Answer.self, data).status {
        case "pending": return .pending
        case "denied": return .denied
        case "expired": return .expired
        case "approved": return .approved(try decode(RunRegistration.self, data))
        default: throw QuotaRunError.badResponse
        }
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

    public func deleteDevice(_ deviceId: String) async throws -> [RunDevice] {
        struct Answer: Decodable { let devices: [RunDevice] }
        let escaped = deviceId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? deviceId
        return try decode(Answer.self, try await send("DELETE", "/devices/\(escaped)", json: Optional<Empty>.none)).devices
    }

    /// This Mac leaves the account; the account and its other Macs stay.
    public func disconnectCurrentDevice() async throws {
        _ = try await send("DELETE", "/devices/current", json: Optional<Empty>.none)
    }

    public func deleteAccount() async throws {
        _ = try await send("DELETE", "/account", json: Optional<Empty>.none)
    }

    /// The contract's limit per lookup.
    public static let lookupLimit = 20

    /// What quota.run holds for each provider account digest, asked for 20 at
    /// a time. Only digests go out — never the email or account id behind
    /// them. Duplicates and anything that is not a lower-case hex SHA-256 are
    /// left out rather than refused.
    public func lookupAccounts(digests: [String]) async throws -> [RunAccountLookup] {
        struct Body: Encodable { let digests: [String] }
        /// One malformed entry is dropped, not the answer.
        struct Lenient: Decodable {
            let value: RunAccountLookup?
            init(from decoder: Decoder) throws { value = try? RunAccountLookup(from: decoder) }
        }
        struct Answer: Decodable {
            let accounts: [RunAccountLookup]

            private enum CodingKeys: String, CodingKey { case accounts }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                accounts = try c.decode([Lenient].self, forKey: .accounts).compactMap(\.value)
            }
        }
        var seen = Set<String>()
        let clean = digests.map { $0.lowercased() }.filter { RunAccountDigest.isDigest($0) && seen.insert($0).inserted }
        var results: [RunAccountLookup] = []
        var start = 0
        while start < clean.count {
            let chunk = Array(clean[start..<min(start + Self.lookupLimit, clean.count)])
            results += try decode(Answer.self, try await send("POST", "/accounts/lookup", json: Body(digests: chunk))).accounts
            start += Self.lookupLimit
        }
        return results
    }

    /// Unbinds a provider account: quota.run deletes this user's readings and
    /// runs for it. Answers with the accounts that remain.
    public func unbindAccount(id: String) async throws -> [RunProviderAccount] {
        struct Answer: Decodable {
            let providerAccounts: [RunProviderAccount]

            private enum CodingKeys: String, CodingKey { case providerAccounts }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                providerAccounts = (try? c.decodeIfPresent([RunProviderAccount].self, forKey: .providerAccounts)) ?? []
            }
        }
        let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? id
        return try decode(Answer.self, try await send("DELETE", "/accounts/\(escaped)", json: Optional<Empty>.none)).providerAccounts
    }
}

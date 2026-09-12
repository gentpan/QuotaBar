import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPResponse: Sendable {
    public let status: Int
    public let data: Data

    public func json<T: Decodable>(_ type: T.Type, decoder: JSONDecoder = JSONDecoder()) throws -> T {
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw ProviderError.badResponse
        }
    }

    /// Throws a normalized ProviderError for non-2xx statuses.
    public func requireOK() throws -> HTTPResponse {
        switch status {
        case 200...299: return self
        case 401, 403: throw ProviderError.unauthorized
        case 429: throw ProviderError.rateLimited
        default: throw ProviderError.http(status)
        }
    }
}

public enum HTTP {
    private static let sessionLock = NSLock()
    nonisolated(unsafe) private static var currentSession = makeSession(proxy: nil)
    nonisolated(unsafe) private static var currentProxy = ""

    private static var session: URLSession {
        sessionLock.withLock { currentSession }
    }

    private static func makeSession(proxy: ProxySpec?) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.httpCookieStorage = nil
        config.urlCache = nil
        if let proxy { config.connectionProxyDictionary = proxy.dictionary }
        return URLSession(configuration: config)
    }

    /// Routes every provider request through a proxy, after openusage:
    /// "http://host:port", "https://host:port" or "socks5://host:port".
    /// Empty or unparseable means direct. Returns whether the value was used.
    @discardableResult
    public static func configureProxy(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let spec = ProxySpec(trimmed)
        return sessionLock.withLock {
            guard trimmed != currentProxy else { return spec != nil || trimmed.isEmpty }
            currentProxy = trimmed
            currentSession = makeSession(proxy: spec)
            return spec != nil || trimmed.isEmpty
        }
    }

    public static func send(
        _ method: String,
        _ url: URL,
        headers: [String: String] = [:],
        body: Data? = nil) async throws -> HTTPResponse
    {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = body
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ProviderError.badResponse
            }
            return HTTPResponse(status: http.statusCode, data: data)
        } catch let error as ProviderError {
            throw error
        } catch {
            throw ProviderError.network(error.localizedDescription)
        }
    }

    public static func get(_ url: URL, headers: [String: String] = [:]) async throws -> HTTPResponse {
        try await send("GET", url, headers: headers)
    }

    public static func post(
        _ url: URL,
        headers: [String: String] = [:],
        jsonBody: String = "{}") async throws -> HTTPResponse
    {
        var headers = headers
        if headers["Content-Type"] == nil {
            headers["Content-Type"] = "application/json"
        }
        return try await send("POST", url, headers: headers, body: Data(jsonBody.utf8))
    }
}

// MARK: - Lenient date parsing

public enum Dates {
    public static func parseISO(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    /// Accepts epoch seconds or milliseconds.
    public static func parseEpoch(_ value: Double?) -> Date? {
        guard let value, value > 0 else { return nil }
        return value > 100_000_000_000 ? Date(timeIntervalSince1970: value / 1000) : Date(timeIntervalSince1970: value)
    }

    /// Tries ISO first, then epoch (s/ms) encoded as string/number.
    public static func parseAny(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        if let iso = parseISO(string) { return iso }
        return parseEpoch(Double(string))
    }
}

/// A parsed proxy address.
public struct ProxySpec: Equatable, Sendable {
    public enum Kind: String, Sendable { case http, https, socks5 }
    public var kind: Kind
    public var host: String
    public var port: Int

    public init?(_ value: String) {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              let kind = Kind(rawValue: scheme == "socks" ? "socks5" : scheme),
              let host = url.host, !host.isEmpty
        else { return nil }
        self.kind = kind
        self.host = host
        self.port = url.port ?? (kind == .socks5 ? 1080 : 8080)
    }

    var dictionary: [AnyHashable: Any] {
        switch kind {
        case .socks5:
            return [
                kCFNetworkProxiesSOCKSEnable as String: 1,
                kCFNetworkProxiesSOCKSProxy as String: host,
                kCFNetworkProxiesSOCKSPort as String: port,
            ]
        case .http, .https:
            return [
                kCFNetworkProxiesHTTPEnable as String: 1,
                kCFNetworkProxiesHTTPProxy as String: host,
                kCFNetworkProxiesHTTPPort as String: port,
                kCFNetworkProxiesHTTPSEnable as String: 1,
                kCFNetworkProxiesHTTPSProxy as String: host,
                kCFNetworkProxiesHTTPSPort as String: port,
            ]
        }
    }
}

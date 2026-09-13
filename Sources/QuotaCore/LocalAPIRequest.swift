import Foundation

/// What the local API accepts, kept apart from the socket so it can be tested.
public enum LocalAPIRequest {
    /// True for a request addressed to this Mac by a local tool.
    ///
    /// The listener is loopback-only and sends no CORS header, which keeps a
    /// web page from reading it — except through DNS rebinding: a page on
    /// evil.example re-points its own name at 127.0.0.1 and then asks
    /// "same-origin". The browser still sends `Host: evil.example`, so only
    /// requests naming 127.0.0.1 or localhost are answered. A request without
    /// a Host header is a hand-rolled local client, not a browser.
    /// A cross-site `Origin` is refused as well.
    public static func isAllowed(_ request: String, port: UInt16) -> Bool {
        let headers = request.components(separatedBy: "\r\n").dropFirst()
        var host: String?
        var origin: String?
        for line in headers {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces).lowercased()
            if name == "host" { host = value }
            if name == "origin" { origin = value }
        }
        let local = ["127.0.0.1", "localhost", "[::1]"]
        if let host {
            let name = host.hasPrefix("[") ? String(host.prefix { $0 != "]" }) + "]" : String(host.split(separator: ":").first ?? "")
            let hostPort = host.split(separator: ":").last.flatMap { UInt16($0) }
            guard local.contains(name), hostPort == nil || hostPort == port || host == name else { return false }
        }
        if let origin, origin != "null" {
            guard let url = URL(string: origin), let originHost = url.host, local.contains(originHost) || local.contains("[\(originHost)]") else {
                return false
            }
        }
        return true
    }
}

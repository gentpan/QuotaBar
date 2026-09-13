import Foundation
import Network
import QuotaCore

/// `http://127.0.0.1:6736/v1/limits` for other local tools, after openusage.
/// Loopback only, off by default, never a credential or an account name, no
/// CORS header, and only requests addressed to 127.0.0.1 or localhost — a web
/// page cannot read it, not even by rebinding its own name to this Mac.
@MainActor
final class LocalAPIServer {
    static let shared = LocalAPIServer()
    static let port: UInt16 = 6736

    private var listener: NWListener?
    private weak var store: UsageStore?
    private(set) var failure: String?

    func apply(enabled: Bool, store: UsageStore) {
        self.store = store
        if enabled, listener == nil { start() }
        if !enabled { stop() }
    }

    private func start() {
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: Self.port)!)
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { connection in
                Task { @MainActor in LocalAPIServer.shared.handle(connection) }
            }
            listener.stateUpdateHandler = { state in
                if case let .failed(error) = state {
                    Task { @MainActor in LocalAPIServer.shared.failure = error.localizedDescription }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    private func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
            Task { @MainActor in
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                let (status, body) = LocalAPIRequest.isAllowed(request, port: LocalAPIServer.port)
                    ? LocalAPIServer.shared.respond(to: path)
                    : ("403 Forbidden", Data(#"{"error":"only requests addressed to 127.0.0.1 or localhost are answered"}"#.utf8))
                let head = "HTTP/1.1 \(status)\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
                connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    private func respond(to path: String) -> (String, Data) {
        guard let store else { return ("503 Service Unavailable", Data("{}".utf8)) }
        switch path.split(separator: "?").first.map(String.init) ?? path {
        case "/v1/limits", "/v1/usage":
            let providers = store.enabled.map { (id: $0, snapshot: store.states[$0]?.snapshot, error: store.states[$0]?.errorMessage) }
            return ("200 OK", LimitsJSON.make(providers: providers))
        case "/v1/spend":
            var body: [String: Any] = [:]
            for period in SpendPeriod.allCases {
                let spend = store.cost.spend(period)
                body[period.rawValue] = ["usd": (spend.usd * 100).rounded() / 100, "tokens": spend.tokens, "billableTokens": spend.billableTokens]
            }
            return ("200 OK", (try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys])) ?? Data())
        default:
            return ("404 Not Found", Data(#"{"error":"not found","paths":["/v1/limits","/v1/spend"]}"#.utf8))
        }
    }
}

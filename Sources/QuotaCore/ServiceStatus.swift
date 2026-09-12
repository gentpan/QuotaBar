import Foundation

// MARK: - Public status pages (Statuspage `summary.json`, no credentials)

/// The five bands Statuspage reports. A page that could not be read is
/// shown as nothing rather than as a grey "unknown" chip, since a status
/// the app cannot see says nothing about the service.
public enum ServiceStatusLevel: String, Sendable, Codable, Equatable {
    case operational
    case minor
    case major
    case critical
    case maintenance

    /// Short, so it fits beside a name: "运行正常", not the page's sentence.
    public var displayName: String {
        switch self {
        case .operational: L10n.t("Operational", "运行正常")
        case .minor: L10n.t("Minor outage", "轻微故障")
        case .major: L10n.t("Partial outage", "部分故障")
        case .critical: L10n.t("Major outage", "重大故障")
        case .maintenance: L10n.t("Maintenance", "维护中")
        }
    }

    /// codex-island's ramp: live teal, alert amber, alert red; blue for a
    /// planned window, which is neither good nor bad news.
    public var colorHex: String {
        switch self {
        case .operational: "3DD68C"
        case .minor: "F5A524"
        case .major, .critical: "E5484D"
        case .maintenance: "0A84FF"
        }
    }

    public var isHealthy: Bool { self == .operational }
}

/// One reading of a provider's public status page.
public struct ServiceStatus: Sendable, Equatable {
    public let level: ServiceStatusLevel
    /// The page's own words — its headline, or the open incident's name —
    /// for a tooltip; the chip shows `level.displayName`.
    public let description: String
    public let pageURL: URL
    public let checkedAt: Date

    public init(level: ServiceStatusLevel, description: String, pageURL: URL, checkedAt: Date) {
        self.level = level
        self.description = description
        self.pageURL = pageURL
        self.checkedAt = checkedAt
    }
}

public enum StatusPages {
    /// Where a provider's status lives, and how it is read.
    enum Feed {
        /// Atlassian Statuspage: `<api>/api/v2/summary.json`. The API host is
        /// not always the page's own — DeepSeek's page is served through a
        /// front that answers 404 to the API, while the Statuspage origin
        /// behind it answers.
        case statuspage(api: URL)
        /// Google Cloud's incidents feed, filtered to the products named.
        case googleCloud(product: String)
    }

    /// The providers with a status feed readable without signing in. xAI's
    /// page sits behind a bot wall, Z.ai and OpenCode have none.
    static func feed(for id: ProviderID) -> Feed? {
        switch id {
        case .claude: .statuspage(api: URL(string: "https://status.claude.com")!)
        case .codex: .statuspage(api: URL(string: "https://status.openai.com")!)
        case .cursor: .statuspage(api: URL(string: "https://status.cursor.com")!)
        case .manus: .statuspage(api: URL(string: "https://status.manus.im")!)
        case .minimax: .statuspage(api: URL(string: "https://status.minimax.io")!)
        case .kimi: .statuspage(api: URL(string: "https://status.moonshot.cn")!)
        case .deepseek: .statuspage(api: URL(string: "https://deepseek.statuspage.io")!)
        case .gemini: .googleCloud(product: "Gemini")
        case .zai, .opencodeGo, .grok: nil
        }
    }

    /// The page a person would open.
    public static func page(for id: ProviderID) -> URL? {
        switch id {
        case .claude: URL(string: "https://status.claude.com")
        case .codex: URL(string: "https://status.openai.com")
        case .cursor: URL(string: "https://status.cursor.com")
        case .manus: URL(string: "https://status.manus.im")
        case .minimax: URL(string: "https://status.minimax.io")
        case .kimi: URL(string: "https://status.moonshot.cn")
        case .deepseek: URL(string: "https://status.deepseek.com")
        case .gemini: URL(string: "https://status.cloud.google.com")
        case .zai, .opencodeGo, .grok: nil
        }
    }

    public static var supported: [ProviderID] {
        ProviderID.allCases.filter { page(for: $0) != nil }
    }

    /// nil on any failure. The reading is decoration on a quota card; a
    /// network blip must not turn into an error the user has to dismiss.
    public static func fetch(_ id: ProviderID, now: Date = Date()) async -> ServiceStatus? {
        guard let feed = feed(for: id), let page = page(for: id) else { return nil }
        switch feed {
        case let .statuspage(api):
            let url = api.appendingPathComponent("api/v2/summary.json")
            guard let response = try? await HTTP.get(url, headers: ["Accept": "application/json"]),
                  response.status == 200
            else { return nil }
            return try? parse(response.data, page: page, now: now)
        case let .googleCloud(product):
            let url = URL(string: "https://status.cloud.google.com/incidents.json")!
            guard let response = try? await HTTP.get(url, headers: ["Accept": "application/json"]),
                  response.status == 200
            else { return nil }
            return try? parseGoogleCloud(response.data, product: product, page: page, now: now)
        }
    }

    struct Summary: Decodable {
        struct Status: Decodable {
            let indicator: String?
            let description: String?
        }
        struct Incident: Decodable {
            let name: String?
            let status: String?
        }
        let status: Status?
        let incidents: [Incident]?
    }

    /// Exposed for the tests, which pin it to recorded responses.
    public static func parse(_ data: Data, page: URL, now: Date = Date()) throws -> ServiceStatus {
        let summary: Summary
        do { summary = try JSONDecoder().decode(Summary.self, from: data) } catch { throw ProviderError.badResponse }
        let level: ServiceStatusLevel
        switch summary.status?.indicator?.lowercased() {
        case "none": level = .operational
        case "minor": level = .minor
        case "major": level = .major
        case "critical": level = .critical
        case "maintenance": level = .maintenance
        default: throw ProviderError.badResponse
        }
        // An open incident's name says what is actually wrong; the headline
        // only says how badly.
        let incident = summary.incidents?.first?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let headline = summary.status?.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = [incident, headline].compactMap { $0 }.first { !$0.isEmpty } ?? level.displayName
        return ServiceStatus(level: level, description: description, pageURL: page, checkedAt: now)
    }

    // MARK: Google Cloud

    struct CloudIncident: Decodable {
        struct Product: Decodable { let title: String? }
        let end: String?
        let status_impact: String?
        let external_desc: String?
        let affected_products: [Product]?
    }

    /// Google publishes every Cloud incident, open and closed, as one list.
    /// An open one (no `end`) touching a product whose name contains
    /// `product` is the reading; none means operational.
    public static func parseGoogleCloud(
        _ data: Data,
        product: String,
        page: URL,
        now: Date = Date()) throws -> ServiceStatus
    {
        let incidents: [CloudIncident]
        do { incidents = try JSONDecoder().decode([CloudIncident].self, from: data) } catch { throw ProviderError.badResponse }
        let open = incidents.filter { incident in
            incident.end == nil && (incident.affected_products ?? []).contains {
                ($0.title ?? "").localizedCaseInsensitiveContains(product)
            }
        }
        guard let worst = open.max(by: { rank($0.status_impact) < rank($1.status_impact) }) else {
            return ServiceStatus(
                level: .operational,
                description: L10n.t("No open incidents for \(product)", "\(product) 没有未结束的事件"),
                pageURL: page,
                checkedAt: now)
        }
        let level: ServiceStatusLevel = rank(worst.status_impact) >= 2 ? .major : .minor
        let description = worst.external_desc?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ServiceStatus(
            level: level,
            description: (description?.isEmpty == false ? description : nil) ?? level.displayName,
            pageURL: page,
            checkedAt: now)
    }

    private static func rank(_ impact: String?) -> Int {
        switch impact?.uppercased() {
        case "SERVICE_OUTAGE": 2
        case "SERVICE_DISRUPTION": 1
        default: 0
        }
    }
}

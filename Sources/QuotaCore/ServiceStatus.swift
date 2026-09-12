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

/// One of the parts a status page reports on — "claude.ai", "Claude Code",
/// "API Service" — with its own band.
public struct ServiceComponent: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let level: ServiceStatusLevel

    public init(id: String, name: String, level: ServiceStatusLevel) {
        self.id = id
        self.name = name
        self.level = level
    }
}

/// One day of a component's 90-day history, as the page draws it.
public struct UptimeDay: Sendable, Equatable {
    public let date: Date
    public let level: ServiceStatusLevel
    /// Incident names that touched the day, for the tooltip.
    public let events: [String]
    /// Seconds the page counted as partial or major outage that day; what
    /// its uptime percentage is made of.
    public let downtimeSeconds: Double

    public init(date: Date, level: ServiceStatusLevel, events: [String], downtimeSeconds: Double = 0) {
        self.date = date
        self.level = level
        self.events = events
        self.downtimeSeconds = downtimeSeconds
    }

    /// Time-weighted, the way the page's own figure is: a two-hour blip on
    /// one day is 0.1% of a quarter, not a whole red day.
    public static func uptimePercent(_ days: [UptimeDay]) -> Double {
        guard !days.isEmpty else { return 100 }
        let down = days.reduce(0) { $0 + $1.downtimeSeconds }
        return max(0, 100 - down / (Double(days.count) * 86_400) * 100)
    }
}

/// One reading of a provider's public status page.
public struct ServiceStatus: Sendable, Equatable {
    public let level: ServiceStatusLevel
    /// The page's own words — its headline, or the open incident's name —
    /// for a tooltip; the chip shows `level.displayName`.
    public let description: String
    public let pageURL: URL
    public let checkedAt: Date
    /// The page's showcased components, in its order. Empty for feeds that
    /// have none (Google Cloud's).
    public let components: [ServiceComponent]
    /// The components `level` and `description` follow — the coding services,
    /// Claude Code rather than Claude Cowork. Empty when the reading is the
    /// whole page's.
    public let focus: [String]
    /// Open incidents on the page that touch none of `focus`: shown where
    /// the page is opened up, kept out of the badge.
    public let elsewhere: [String]

    public init(
        level: ServiceStatusLevel,
        description: String,
        pageURL: URL,
        checkedAt: Date,
        components: [ServiceComponent] = [],
        focus: [String] = [],
        elsewhere: [String] = [])
    {
        self.level = level
        self.description = description
        self.pageURL = pageURL
        self.checkedAt = checkedAt
        self.components = components
        self.focus = focus
        self.elsewhere = elsewhere
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

    /// The components the badge follows: what writing code with this
    /// provider depends on. Claude's page also reports Cowork, Government
    /// and the consumer app, and an incident there says nothing about
    /// whether Claude Code works; Claude Code runs on the API, so that is
    /// followed too. In order — the first is the one a closed status row
    /// draws. Matched by name, exact before loose. Empty = the whole page.
    static func focusComponentNames(for id: ProviderID) -> [String] {
        switch id {
        case .claude: ["Claude Code", "Claude API"]
        case .codex: ["CLI", "VS Code extension", "Codex API", "Codex Web", "Codex in ChatGPT Desktop"]
        case .cursor: ["IDE", "CLI", "Cloud Agents"]
        case .kimi: ["Open API", "API Service"]
        case .minimax: ["Large Language Models"]
        case .deepseek: ["API Service"]
        case .copilot: ["Copilot"]
        case .windsurf: ["Cascade", "Windsurf Tab"]
        case .moonshot: ["Open API", "Open Platform Portal"]
        default: []
        }
    }

    /// Words that tie an incident to the focus when the page does not list
    /// the components it touched — OpenAI's feed never does.
    static func focusKeywords(for id: ProviderID) -> [String] {
        switch id {
        case .claude: ["Claude Code"]
        case .codex: ["Codex"]
        default: []
        }
    }

    /// The components of `components` named by `names`, in the names' order.
    static func matching(_ names: [String], in components: [ServiceComponent]) -> [ServiceComponent] {
        var out: [ServiceComponent] = []
        for name in names {
            let exact = components.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            let hits = exact.isEmpty ? components.filter { $0.name.localizedCaseInsensitiveContains(name) } : exact
            for hit in hits where !out.contains(where: { $0.id == hit.id }) { out.append(hit) }
        }
        return out
    }

    /// The one component that stands for the provider on a single line: the
    /// first coding service the page reports, not whatever it happens to list
    /// first. A page that has renamed everything still answers with its
    /// first entry.
    public static func primaryComponent(for id: ProviderID, in components: [ServiceComponent]) -> ServiceComponent? {
        let fallback: [String] = id == .manus ? ["manus.im"] : []
        return matching(focusComponentNames(for: id) + fallback, in: components).first ?? components.first
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
        case .copilot: .statuspage(api: URL(string: "https://www.githubstatus.com")!)
        case .windsurf: .statuspage(api: URL(string: "https://status.windsurf.com")!)
        case .moonshot: .statuspage(api: URL(string: "https://status.moonshot.cn")!)
        case .zai, .opencodeGo, .grok, .antigravity, .qwen, .alibaba, .volcengine, .zhipu, .openrouter, .mimo, .qoder, .kiro: nil
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
        case .copilot: URL(string: "https://www.githubstatus.com")
        case .windsurf: URL(string: "https://status.windsurf.com")
        case .moonshot: URL(string: "https://status.moonshot.cn")
        case .zai, .opencodeGo, .grok, .antigravity, .qwen, .alibaba, .volcengine, .zhipu, .openrouter, .mimo, .qoder, .kiro: nil
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
            let focus = focusComponentNames(for: id)
            // OpenAI's summary carries 25 of its 34 components, and the CLI is
            // one it leaves out; the full list is asked for only then.
            var extra: Data?
            if !focus.isEmpty, let summary = try? JSONDecoder().decode(Summary.self, from: response.data),
               matching(focus, in: components(of: summary)).count < focus.count
            {
                let all = api.appendingPathComponent("api/v2/components.json")
                if let more = try? await HTTP.get(all, headers: ["Accept": "application/json"]), more.status == 200 {
                    extra = more.data
                }
            }
            return try? parse(
                response.data, page: page, focus: focus, keywords: focusKeywords(for: id),
                allComponents: extra, now: now)
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
            struct Touched: Decodable {
                let id: String?
                let name: String?
            }
            let name: String?
            let status: String?
            let components: [Touched]?
        }
        struct Component: Decodable {
            let id: String?
            let name: String?
            let status: String?
            let group: Bool?
            let showcase: Bool?
        }
        let status: Status?
        let incidents: [Incident]?
        let components: [Component]?
    }

    /// Statuspage's component bands → ours.
    static func componentLevel(_ status: String?) -> ServiceStatusLevel {
        switch status?.lowercased() {
        case "operational": .operational
        case "degraded_performance": .minor
        case "partial_outage": .major
        case "major_outage": .critical
        case "under_maintenance": .maintenance
        default: .operational
        }
    }

    /// The page's showcased components; every non-group one when the page
    /// showcases none (OpenAI's marks none and shows all).
    static func components(of summary: Summary) -> [ServiceComponent] {
        let leaves = (summary.components ?? []).filter { $0.group != true }
        let picked = leaves.contains { $0.showcase == true } ? leaves.filter { $0.showcase == true } : leaves
        return picked.compactMap { component in
            guard let id = component.id, let name = component.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { return nil }
            return ServiceComponent(id: id, name: name, level: componentLevel(component.status))
        }
    }

    /// Exposed for the tests, which pin it to recorded responses. With
    /// `focus`, the level and sentence are those of the named components
    /// and the incidents that touch them; without, the page's own.
    public static func parse(
        _ data: Data,
        page: URL,
        focus focusNames: [String] = [],
        keywords: [String] = [],
        allComponents: Data? = nil,
        now: Date = Date()) throws -> ServiceStatus
    {
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
        var listed = components(of: summary)
        // Focus components the summary left out, from the page's full list.
        if let allComponents, let full = try? JSONDecoder().decode(Summary.self, from: allComponents) {
            let known = Set(listed.map(\.id))
            let everything = (full.components ?? []).filter { $0.group != true }.compactMap { part -> ServiceComponent? in
                guard let id = part.id, let name = part.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty
                else { return nil }
                return ServiceComponent(id: id, name: name, level: componentLevel(part.status))
            }
            listed += matching(focusNames, in: everything).filter { !known.contains($0.id) }
        }
        let focus = matching(focusNames, in: listed)
        guard !focus.isEmpty else {
            return ServiceStatus(level: level, description: description, pageURL: page, checkedAt: now, components: listed)
        }
        return focused(summary: summary, listed: listed, focus: focus, keywords: keywords, page: page, now: now)
    }

    /// The badge for the focus alone. Worst of the focus components' own
    /// bands; an open incident that touches one of them while they all still
    /// read operational is at least minor — the page is saying something is
    /// wrong before it has moved a band. Incidents elsewhere on the page are
    /// kept for the opened row.
    private static func focused(
        summary: Summary, listed: [ServiceComponent], focus: [ServiceComponent],
        keywords: [String], page: URL, now: Date) -> ServiceStatus
    {
        let focusIDs = Set(focus.map(\.id))
        let focusNames = focus.map(\.name)
        var touching: [String] = []
        var elsewhere: [String] = []
        for incident in summary.incidents ?? [] {
            guard let name = incident.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { continue }
            let touched = incident.components ?? []
            let hits: Bool
            if touched.isEmpty {
                // No component list: judge by the incident's own words.
                hits = (focusNames + keywords).contains { name.localizedCaseInsensitiveContains($0) }
            } else {
                hits = touched.contains { part in
                    part.id.map(focusIDs.contains) ?? false
                        || focusNames.contains { $0.caseInsensitiveCompare(part.name ?? "") == .orderedSame }
                }
            }
            if hits { touching.append(name) } else { elsewhere.append(name) }
        }
        var level = focus.map(\.level).max { rank($0) < rank($1) } ?? .operational
        if !touching.isEmpty, rank(level) < rank(.minor) { level = .minor }
        let label = focus.map(\.name).joined(separator: L10n.t(", ", "、"))
        let description: String
        if let first = touching.first {
            description = first
        } else if level.isHealthy {
            description = L10n.t("\(label): operational", "\(label) 运行正常")
        } else {
            description = L10n.t("\(label): \(level.displayName)", "\(label)：\(level.displayName)")
        }
        return ServiceStatus(
            level: level,
            description: description,
            pageURL: page,
            checkedAt: now,
            components: listed,
            focus: focus.map(\.name),
            elsewhere: elsewhere)
    }

    // MARK: 90-day history

    /// The page's own uptime widget data: `<page>/uptime/<component>?page=1`
    /// answers JSON when asked for it — three months of days, each with the
    /// colour the page paints it and the incidents that touched it. Not
    /// part of the documented API, and OpenAI's page (a different renderer)
    /// does not answer it; nil then.
    public static func uptime(for id: ProviderID, component: String, now: Date = Date()) async -> [UptimeDay]? {
        guard case let .statuspage(api)? = feed(for: id) else { return nil }
        let browser = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        let url = api.appendingPathComponent("uptime/\(component)").appending(queryItems: [URLQueryItem(name: "page", value: "1")])
        if let response = try? await HTTP.get(url, headers: ["Accept": "application/json", "User-Agent": browser]),
           response.status == 200, let days = try? parseUptime(response.data)
        {
            return days
        }
        // incident.io-hosted pages (OpenAI's) have no such widget, but their
        // own incident list carries every component impact with its start
        // and end, which is enough to draw the days from.
        guard let proxy = incidentIOProxy(for: id) else { return nil }
        let data: Data
        if let cached = incidentIOMemo.data(for: proxy, now: now) {
            data = cached
        } else {
            let url = proxy.appendingPathComponent("incidents")
            guard let response = try? await HTTP.get(url, headers: ["Accept": "application/json", "User-Agent": browser]),
                  response.status == 200 else { return nil }
            data = response.data
            incidentIOMemo.store(data, for: proxy, now: now)
        }
        return try? uptimeFromIncidentIO(data, componentID: component, now: now)
    }

    /// incident.io's public proxy for a page, where its component impacts
    /// live. Only OpenAI's page is hosted there among ours.
    static func incidentIOProxy(for id: ProviderID) -> URL? {
        switch id {
        case .codex: URL(string: "https://status.openai.com/proxy/status.openai.com")
        default: nil
        }
    }

    /// The incident list is half a megabyte and every component of the page
    /// wants it; one fetch serves an opened row.
    private static let incidentIOMemo = IncidentIOMemo()

    final class IncidentIOMemo: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [URL: (data: Data, at: Date)] = [:]

        func data(for url: URL, now: Date) -> Data? {
            lock.lock(); defer { lock.unlock() }
            guard let entry = entries[url], now.timeIntervalSince(entry.at) < 300 else { return nil }
            return entry.data
        }

        func store(_ data: Data, for url: URL, now: Date) {
            lock.lock(); defer { lock.unlock() }
            entries[url] = (data, now)
        }
    }

    struct IncidentIOIncidents: Decodable {
        struct Incident: Decodable {
            struct Impact: Decodable {
                let component_id: String?
                let status: String?
                let start_at: String?
                let end_at: String?
            }
            let name: String?
            let component_impacts: [Impact]?
        }
        let incidents: [Incident]?
    }

    /// The last `days` local days of one component, from the impacts the
    /// page's incidents recorded against it: the worst band that touched
    /// the day, the incidents' names, and the seconds they overlapped it.
    public static func uptimeFromIncidentIO(
        _ data: Data,
        componentID: String,
        days count: Int = 30,
        now: Date = Date(),
        calendar: Calendar = .current) throws -> [UptimeDay]
    {
        let list: IncidentIOIncidents
        do { list = try JSONDecoder().decode(IncidentIOIncidents.self, from: data) } catch { throw ProviderError.badResponse }
        struct Span { let start: Date; let end: Date; let level: ServiceStatusLevel; let name: String }
        var spans: [Span] = []
        for incident in list.incidents ?? [] {
            for impact in incident.component_impacts ?? [] where impact.component_id == componentID {
                guard let start = Dates.parseISO(impact.start_at) else { continue }
                let end = Dates.parseISO(impact.end_at) ?? now
                let level: ServiceStatusLevel
                switch impact.status?.lowercased() {
                case "full_outage", "major_outage": level = .critical
                case "partial_outage": level = .major
                case "under_maintenance": level = .maintenance
                default: level = .minor
                }
                spans.append(Span(start: start, end: max(end, start), level: level, name: incident.name ?? ""))
            }
        }
        let today = calendar.startOfDay(for: now)
        return (0..<count).reversed().compactMap { offset -> UptimeDay? in
            guard let dayStart = calendar.date(byAdding: .day, value: -offset, to: today),
                  let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return nil }
            var level = ServiceStatusLevel.operational
            var seconds = 0.0
            var names: [String] = []
            for span in spans where span.start < dayEnd && span.end > dayStart {
                seconds += min(span.end, dayEnd).timeIntervalSince(max(span.start, dayStart))
                if rank(span.level) > rank(level) { level = span.level }
                if !span.name.isEmpty, !names.contains(span.name) { names.append(span.name) }
            }
            return UptimeDay(date: dayStart, level: level, events: names, downtimeSeconds: seconds)
        }
    }

    private static func rank(_ level: ServiceStatusLevel) -> Int {
        switch level {
        case .operational: 0
        case .maintenance: 1
        case .minor: 2
        case .major: 3
        case .critical: 4
        }
    }

    struct Uptime: Decodable {
        struct Month: Decodable {
            let days: [Day]?
        }
        struct Day: Decodable {
            struct Event: Decodable { let name: String? }
            let color: String?
            let date: String?
            let events: [Event]?
            /// Minutes of partial and of major outage.
            let p: Double?
            let m: Double?
        }
        let months: [Month]?
    }

    public static func parseUptime(_ data: Data) throws -> [UptimeDay] {
        let uptime: Uptime
        do { uptime = try JSONDecoder().decode(Uptime.self, from: data) } catch { throw ProviderError.badResponse }
        let days = (uptime.months ?? []).flatMap { $0.days ?? [] }.compactMap { day -> UptimeDay? in
            guard let date = Dates.parseISO(day.date), let level = dayLevel(color: day.color) else { return nil }
            return UptimeDay(
                date: date,
                level: level,
                events: (day.events ?? []).compactMap { $0.name }.filter { !$0.isEmpty },
                downtimeSeconds: (day.p ?? 0) + (day.m ?? 0))
        }
        guard !days.isEmpty else { throw ProviderError.badResponse }
        return days.sorted { $0.date < $1.date }
    }

    /// The page paints each day on a ramp from green through yellow and
    /// orange to red by how bad it was, and grey for days it has nothing
    /// for (the rest of the current month). Read the hue rather than match
    /// the exact shades, of which there are dozens; nil for grey.
    static func dayLevel(color: String?) -> ServiceStatusLevel? {
        guard let color, let (r, g, b) = rgb(color) else { return .operational }
        let maxC = max(r, g, b), minC = min(r, g, b)
        let delta = maxC - minC
        // No hue at all: the page's placeholder grey.
        guard maxC > 0, delta / maxC > 0.15 else { return nil }
        var hue: Double
        if maxC == r { hue = 60 * ((g - b) / delta) }
        else if maxC == g { hue = 60 * (2 + (b - r) / delta) }
        else { hue = 60 * (4 + (r - g) / delta) }
        if hue < 0 { hue += 360 }
        // #e04343 sits at 0°, #e75f36 at 14°, #f08030 at 25°, #d2a92a at 45°.
        switch hue {
        case ..<12: return .critical
        case ..<34: return .major
        case ..<70: return .minor
        case ..<170: return .operational
        case ..<260: return .maintenance
        default: return .critical
        }
    }

    private static func rgb(_ hex: String) -> (Double, Double, Double)? {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased()
        guard cleaned.count == 6, let value = UInt64(cleaned, radix: 16) else { return nil }
        return (
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255)
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

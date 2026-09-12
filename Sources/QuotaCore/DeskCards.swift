import Foundation

// MARK: - Desktop cards

/// How a desktop card draws itself.
public enum DeskCardStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    /// One provider, its main window as a big figure.
    case focus
    /// One provider, a gauge with reset and run-out.
    case gauge
    /// Spend today with a 14-day line.
    case trend
    /// Tokens day by day as bars.
    case daily
    /// Several providers as tiles.
    case grid
    /// Several providers, closest to the limit first.
    case ranking
    /// The card from before 0.5: rings, figures or bars.
    case classic

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .focus: L10n.t("Big figure", "大数字")
        case .gauge: L10n.t("Gauge", "环形仪表")
        case .trend: L10n.t("Spend trend", "花费趋势")
        case .daily: L10n.t("Day by day", "每日对比")
        case .grid: L10n.t("Provider grid", "服务商网格")
        case .ranking: L10n.t("Closest first", "紧迫排行")
        case .classic: L10n.t("Classic", "经典")
        }
    }

    /// Whether the card is about one provider.
    public var singleProvider: Bool { self == .focus || self == .gauge }
    /// Whether the card reads the local logs, and so can narrow to one CLI.
    public var readsLogs: Bool { self == .trend || self == .daily }
}

public enum DeskCardSize: String, Codable, CaseIterable, Identifiable, Sendable {
    case small, medium, large

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .small: L10n.t("Small", "小")
        case .medium: L10n.t("Medium", "中")
        case .large: L10n.t("Large", "大")
        }
    }

    /// For the three-way switch in Settings, where "Medium" does not fit.
    public var shortName: String {
        switch self {
        case .small: L10n.t("S", "小")
        case .medium: L10n.t("M", "中")
        case .large: L10n.t("L", "大")
        }
    }

    /// The system widget families' proportions.
    public var width: Double { self == .small ? 170 : 344 }
    public var height: Double {
        switch self {
        case .small: 170
        case .medium: 224
        case .large: 344
        }
    }
}

/// One card on the desktop. Each has its own style, size, subject and place.
public struct DeskCard: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var style: DeskCardStyle
    public var size: DeskCardSize
    /// The provider a single-provider card shows, or the only one a
    /// multi-provider card shows; nil follows the focused provider or shows all.
    public var provider: ProviderID?
    /// The CLI a log card counts; nil counts every one.
    public var source: CostSource?
    /// Position as fractions of the visible screen, 0,0 top-left.
    public var x: Double
    public var y: Double

    public init(
        id: String = UUID().uuidString,
        style: DeskCardStyle,
        size: DeskCardSize = .medium,
        provider: ProviderID? = nil,
        source: CostSource? = nil,
        x: Double = 0.85,
        y: Double = 0.1)
    {
        self.id = id
        self.style = style
        self.size = size
        self.provider = provider
        self.source = source
        self.x = min(max(x, 0), 1)
        self.y = min(max(y, 0), 1)
    }

    private enum CodingKeys: String, CodingKey { case id, style, size, provider, source, x, y }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        style = (try? c.decode(String.self, forKey: .style)).flatMap(DeskCardStyle.init(rawValue:)) ?? .focus
        size = (try? c.decode(String.self, forKey: .size)).flatMap(DeskCardSize.init(rawValue:)) ?? .medium
        provider = (try? c.decodeIfPresent(String.self, forKey: .provider)).flatMap { $0 }.flatMap(ProviderID.init(rawValue:))
        source = (try? c.decodeIfPresent(String.self, forKey: .source)).flatMap { $0 }.flatMap(CostSource.init(rawValue:))
        x = min(max((try? c.decode(Double.self, forKey: .x)) ?? 0.85, 0), 1)
        y = min(max((try? c.decode(Double.self, forKey: .y)) ?? 0.1, 0), 1)
    }

    /// The default pair for a first desktop: the main provider as a big
    /// figure, and spend as a trend beneath it.
    public static func defaults(provider: ProviderID?, x: Double = 0.95, y: Double = 0.06) -> [DeskCard] {
        [
            DeskCard(style: .focus, size: .medium, provider: provider, x: x, y: y),
            DeskCard(style: .trend, size: .medium, x: x, y: min(1, y + 0.36)),
        ]
    }
}

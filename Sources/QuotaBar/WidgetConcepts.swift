import AppKit
import SwiftUI
import QuotaCore

// MARK: - Desktop cards, rendered off-screen

/// Every desktop card style at every size, drawn from this Mac's cached
/// readings and archive: `QuotaBar --widget-concepts <dir>`. For looking at
/// the cards without putting them on the desktop.
enum WidgetConceptBoard {
    @MainActor
    static func render(directory: String) {
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let store = previewStore()
        let styles = DeskCardStyle.allCases.filter { $0 != .classic }

        // The image "Copy as Image" puts on the clipboard, for each enabled provider.
        for id in store.enabled {
            let copied = ShareableCard(store: store) { ProviderCardView(store: store, id: id, forExport: true) }
            if let image = CardImageExporter.image(copied, scale: 2), let png = CardImageExporter.pngData(image) {
                try? png.write(to: url.appendingPathComponent("copied-\(id.rawValue).png"))
            }
        }

        renderBalanceCards(into: url)

        for size in DeskCardSize.allCases {
            let board = VStack(alignment: .leading, spacing: 30) {
                Text(L10n.t("Desktop cards · \(size.displayName)", "桌面卡片 · \(size.displayName)号"))
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                ForEach(0..<2, id: \.self) { row in
                    HStack(alignment: .top, spacing: 32) {
                        ForEach(styles.dropFirst(row * 3).prefix(3)) { style in
                            VStack(alignment: .leading, spacing: 12) {
                                Text(style.displayName)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.85))
                                DeskCardView(store: store, card: DeskCard(style: style, size: size))
                            }
                        }
                    }
                }
            }
            .padding(40)
            .background(wallpaper)
            write(board, to: url.appendingPathComponent("desk-cards-\(size.rawValue).png"))
        }
    }

    private static var wallpaper: some View {
        LinearGradient(colors: [Color(hex: "0E1726"), Color(hex: "3A2A2A"), Color(hex: "0E1726")], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    @MainActor
    private static func write(_ view: some View, to url: URL) {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:])
        else { return }
        try? png.write(to: url)
    }

    @MainActor
    /// A prepaid provider's card from made-up accounts: signed in to the
    /// console (`balance-console-*.png`, with a key opened and the copied
    /// image) and with an API key alone (`balance-estimated.png`).
    private static func renderBalanceCards(into url: URL) {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        func cny(_ value: Double) -> [Money] { value > 0 ? [Money(currency: "CNY", amount: value)] : [] }
        let pattern: [Double] = [18, 22, 9, 0, 0, 31, 27, 24, 19, 0, 35, 40, 21, 14, 12.4, 16, 25, 30, 8, 0, 11, 26, 33, 29, 18, 22, 0, 15, 20, 12.4]
        let days = pattern.enumerated().map { index, spent in
            UsageBucket(start: calendar.date(byAdding: .day, value: index - 29, to: today)!, costs: cny(spent), requests: Int(spent * 13), tokens: Int(spent * 190_000))
        }
        let hours = (0..<24).map { hour in
            let spent = hour <= calendar.component(.hour, from: now) ? [0, 0, 0, 0, 0, 0, 0, 0.2, 1.1, 1.8, 2.4, 0.9, 0.4, 1.6, 2.2, 1.3, 0.5, 0, 0, 0, 0, 0, 0, 0][hour] : 0
            return UsageBucket(start: calendar.date(byAdding: .hour, value: hour, to: today)!, costs: cny(spent))
        }
        let months = (0..<4).map { index in
            UsageBucket(start: calendar.date(byAdding: .month, value: index - 3, to: calendar.dateInterval(of: .month, for: now)!.start)!, costs: cny([96.2, 289.7, 170.1, 36.8][index]))
        }
        func figures(_ spent: Double, _ models: [(String, Double)]) -> KeyUsageFigures {
            KeyUsageFigures(costs: cny(spent), requests: Int(spent * 13), tokens: Int(spent * 190_000),
                            models: models.map { ModelCost(model: $0.0, costs: cny($0.1), requests: Int($0.1 * 13), tokens: Int($0.1 * 190_000)) })
        }
        let keys = [
            APIKeyUsage(id: "a", name: "Editor", maskedKey: "sk-8f3a****c21", lastUsed: now.addingTimeInterval(-3_600), usage: [
                .today: figures(8.1, [("deepseek-v4-pro", 6.0), ("deepseek-chat", 2.1)]),
                .last7: figures(72.4, [("deepseek-v4-pro", 51.0), ("deepseek-chat", 21.4)]),
                .last30: figures(354.3, [("deepseek-v4-pro", 270.1), ("deepseek-chat", 84.2)]),
            ], daily: days.map { UsageBucket(start: $0.start, costs: cny($0.costTotal * 0.62), requests: $0.requests, tokens: $0.tokens) }),
            APIKeyUsage(id: "b", name: "Agents", maskedKey: "sk-19bd****7e0", usage: [
                .today: figures(4.3, [("deepseek-v4-flash", 4.3)]),
                .last7: figures(41.9, [("deepseek-v4-flash", 41.9)]),
                .last30: figures(160.0, [("deepseek-v4-flash", 160.0)]),
            ]),
            APIKeyUsage(id: "c", name: "Scripts", maskedKey: "sk-c0de****911", usage: [
                .last30: figures(51.4, [("deepseek-chat", 51.4)]),
            ]),
            APIKeyUsage(id: "d", name: "Old bot", maskedKey: "sk-77aa****0f2", isDisabled: true, usage: [
                .last30: figures(22.2, [("deepseek-chat", 22.2)]),
            ]),
            APIKeyUsage(id: "e", name: "Test", maskedKey: "sk-4e41****a9b"),
        ]
        let console = BalanceSheet(
            balances: [
                AccountBalance(currency: "CNY", total: 107.39, paid: 100, granted: 7.39),
                AccountBalance(currency: "USD", total: 12.33, paid: 12.33),
            ],
            usage: [
                .today: figures(12.4, [("deepseek-v4-pro", 6.0), ("deepseek-v4-flash", 4.3), ("deepseek-chat", 2.1)]),
                .last7: figures(114.3, [("deepseek-v4-pro", 51.0), ("deepseek-v4-flash", 41.9), ("deepseek-chat", 21.4)]),
                .last30: figures(587.9, [("deepseek-v4-pro", 270.1), ("deepseek-v4-flash", 160.0), ("deepseek-chat", 157.8)]),
                .all: KeyUsageFigures(costs: [Money(currency: "CNY", amount: 592.74), Money(currency: "USD", amount: 7.67)]),
            ],
            chart: [.today: hours, .last7: Array(days.suffix(7)), .last30: days, .all: months],
            keys: keys)
        let estimated: BalanceSheet = {
            var sheet = BalanceSheet(
                balances: [AccountBalance(currency: "CNY", total: 64.12)])
            var total = 180.0
            var readings = [BalanceReading(date: calendar.date(byAdding: .day, value: -12, to: now)!, totals: ["CNY": total])]
            for step in 1...140 {
                total -= [0, 0.4, 1.2, 0.0, 2.1, 0.8][step % 6]
                readings.append(BalanceReading(date: calendar.date(byAdding: .hour, value: step * 2, to: readings[0].date)!, totals: ["CNY": max(total, 64.12)]))
            }
            BalanceEstimate.apply(to: &sheet, readings: readings, now: now, calendar: calendar)
            return sheet
        }()

        func store(_ sheet: BalanceSheet) -> UsageStore {
            let snapshot = UsageSnapshot(planName: L10n.t("Pay as you go", "按量付费"), balance: sheet)
            let store = UsageStore.preview(enabled: [.deepseek], states: [.deepseek: .loaded(snapshot)], cost: .empty, ledger: .empty, history: [:])
            store.serviceStatus[.deepseek] = ServiceStatus(level: .operational, description: "", pageURL: URL(string: "https://quota.bar")!, checkedAt: Date())
            return store
        }
        func write(_ view: some View, _ name: String) {
            if let image = CardImageExporter.image(view, scale: 2), let png = CardImageExporter.pngData(image) {
                try? png.write(to: url.appendingPathComponent(name))
            }
        }
        func panel(_ store: UsageStore, _ sheet: BalanceSheet, period: KeyUsagePeriod, focused: String? = nil, style: BalanceChartStyle = .bars) -> some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    ProviderGlyph(id: .deepseek, size: 16, tint: .white)
                    Text("DeepSeek").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    Spacer()
                }
                BalanceSheetView(store: store, id: .deepseek, sheet: sheet, period: period, focusedKey: focused, chartStyle: style)
            }
            .padding(12)
            .frame(width: 350)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.05)))
            .padding(12)
            .background(Color.black)
            .environment(\.colorScheme, .dark)
        }
        let signedIn = store(console)
        write(panel(signedIn, console, period: .last7), "balance-console-7d.png")
        write(panel(signedIn, console, period: .last30, style: .line), "balance-console-30d-line.png")
        write(panel(signedIn, console, period: .today), "balance-console-today.png")
        write(panel(signedIn, console, period: .all), "balance-console-all.png")
        write(panel(signedIn, console, period: .last30, focused: "a"), "balance-console-key.png")
        write(ShareableCard(store: signedIn) { ProviderCardView(store: signedIn, id: .deepseek, forExport: true) }, "balance-copied.png")
        let apiKey = store(estimated)
        write(panel(apiKey, estimated, period: .last7), "balance-estimated.png")
    }

    /// The last readings, the archive and the trend history this Mac has on disk.
    @MainActor
    private static func previewStore() -> UsageStore {
        let ids = ConfigStore.shared.enabledProviders
        var states: [ProviderID: ProviderPhase] = [:]
        var history: [ProviderID: [Double]] = [:]
        for id in ids {
            if let cached = SnapshotCache.shared.snapshot(for: id) { states[id] = .loaded(cached) }
            history[id] = UsageHistoryStore.shared.readings(for: id).map(\.percent)
        }
        let archive = UsageArchiveStore.shared.current
        let store = UsageStore.preview(enabled: ids, states: states, cost: archive.costSummary(), ledger: archive.ledger(), history: history)
        store.archive = archive
        store.selected = ConfigStore.shared.selected
        for id in ids {
            store.serviceStatus[id] = ServiceStatus(level: .operational, description: "", pageURL: URL(string: "https://quota.bar")!, checkedAt: Date())
        }
        return store
    }
}

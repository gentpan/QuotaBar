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
    /// A prepaid provider's card, collapsed and expanded, from a made-up
    /// account: `balance-collapsed.png`, `balance-expanded.png` and the
    /// copied image, `balance-copied.png`.
    private static func renderBalanceCards(into url: URL) {
        func figures(_ cny: Double, _ requests: Int, _ tokens: Int, _ models: [(String, Double)]) -> KeyUsageFigures {
            KeyUsageFigures(
                costs: [Money(currency: "CNY", amount: cny)], requests: requests, tokens: tokens,
                models: models.map { ModelCost(model: $0.0, costs: [Money(currency: "CNY", amount: $0.1)]) })
        }
        let keys = [
            APIKeyUsage(id: "a", name: "Editor", maskedKey: "sk-8f3a****c21", lastUsed: Date().addingTimeInterval(-3_600), usage: [
                .today: figures(12.4, 180, 2_400_000, [("deepseek-v4-pro", 9.1), ("deepseek-chat", 3.3)]),
                .week: figures(58.2, 820, 11_000_000, [("deepseek-v4-pro", 41.0), ("deepseek-chat", 17.2)]),
                .month: figures(312.4, 4_210, 61_000_000, [("deepseek-v4-pro", 240.1), ("deepseek-chat", 72.3)]),
            ], daily: (0..<15).map { offset in
                let spent = [18.0, 22, 9, 0, 0, 31, 27, 24, 19, 0, 35, 40, 21, 14, 12.4][offset]
                return DailyUsage(
                    day: Calendar.current.date(byAdding: .day, value: offset - 14, to: Calendar.current.startOfDay(for: Date()))!,
                    costs: spent > 0 ? [Money(currency: "CNY", amount: spent)] : [],
                    requests: Int(spent * 13), tokens: Int(spent * 190_000))
            }),
            APIKeyUsage(id: "b", name: "Agents", maskedKey: "sk-19bd****7e0", usage: [
                .week: figures(21.9, 300, 4_100_000, [("deepseek-v4-flash", 21.9)]),
                .month: figures(180.0, 2_050, 30_500_000, [("deepseek-v4-flash", 180.0)]),
            ]),
            APIKeyUsage(id: "c", name: "Scripts", maskedKey: "sk-c0de****911", usage: [
                .month: figures(64.3, 900, 9_800_000, [("deepseek-chat", 64.3)]),
            ]),
            APIKeyUsage(id: "d", name: "Old bot", maskedKey: "sk-77aa****0f2", isDisabled: true, usage: [
                .month: figures(35.9, 410, 5_000_000, [("deepseek-chat", 35.9)]),
            ]),
            APIKeyUsage(id: "e", name: "Test", maskedKey: "sk-4e41****a9b"),
        ]
        func models(_ rows: [(String, Double, Int, Int)]) -> [ModelCost] {
            rows.map { ModelCost(model: $0.0, costs: [Money(currency: "CNY", amount: $0.1)], requests: $0.2, tokens: $0.3) }
        }
        let sheet = BalanceSheet(
            balances: [
                AccountBalance(currency: "CNY", total: 107.39, paid: 100, granted: 7.39),
                AccountBalance(currency: "USD", total: 12.33, paid: 12.33),
            ],
            spend: [
                .today: [Money(currency: "CNY", amount: 12.4)],
                .week: [Money(currency: "CNY", amount: 80.1)],
                .month: [Money(currency: "CNY", amount: 592.67), Money(currency: "USD", amount: 7.66)],
            ],
            models: [
                .today: models([("deepseek-v4-pro", 9.1, 120, 1_700_000), ("deepseek-chat", 3.3, 60, 700_000)]),
                .week: models([("deepseek-v4-pro", 41.0, 500, 7_000_000), ("deepseek-flash", 21.9, 300, 4_100_000), ("deepseek-chat", 17.2, 320, 4_000_000)]),
                .month: models([("deepseek-v4-pro", 240.1, 2_900, 40_000_000), ("deepseek-v4-flash", 180.0, 2_050, 30_500_000), ("deepseek-chat", 172.5, 2_620, 35_800_000), ("deepseek-v4-flash-vision-exp", 0.07, 3, 12_000)]),
            ],
            keys: keys)
        let snapshot = UsageSnapshot(planName: L10n.t("Pay as you go", "按量付费"), balance: sheet)
        let store = UsageStore.preview(enabled: [.deepseek], states: [.deepseek: .loaded(snapshot)], cost: .empty, ledger: .empty, history: [:])
        store.serviceStatus[.deepseek] = ServiceStatus(level: .operational, description: "", pageURL: URL(string: "https://quota.bar")!, checkedAt: Date())

        func write(_ view: some View, _ name: String) {
            if let image = CardImageExporter.image(view, scale: 2), let png = CardImageExporter.pngData(image) {
                try? png.write(to: url.appendingPathComponent(name))
            }
        }
        func panel(expanded: Bool) -> some View {
            ProviderCardView(store: store, id: .deepseek)
                .frame(width: 350)
                .padding(12)
                .background(Color.black)
                .environment(\.colorScheme, .dark)
        }
        write(panel(expanded: false), "balance-collapsed.png")
        store.toggleCardExpanded(.deepseek)
        write(panel(expanded: true), "balance-expanded.png")
        store.toggleCardExpanded(.deepseek)
        write(ShareableCard(store: store) { ProviderCardView(store: store, id: .deepseek, forExport: true) }, "balance-copied.png")
        write(
            BalanceSheetView(store: store, id: .deepseek, sheet: sheet, focusedKey: "a")
                .frame(width: 326)
                .padding(24)
                .background(Color(white: 0.06))
                .environment(\.colorScheme, .dark),
            "balance-key.png")
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

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

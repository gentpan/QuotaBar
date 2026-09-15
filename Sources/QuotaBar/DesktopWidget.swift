import AppKit
import SwiftUI
import QuotaCore

/// The cards on the desktop, each in its own panel.
///
/// Desktop level by default — above the wallpaper and icons, below every
/// window. That is what makes them widgets rather than overlays: there when
/// you clear the screen, and out of the way when you do not. Each card keeps
/// its own style, size, subject and place; right-click one to change it.
@MainActor
final class DesktopWidgetCoordinator {
    private var panels: [String: NSPanel] = [:]
    private weak var store: UsageStore?

    func sync(store: UsageStore) {
        self.store = store
        migrateIfNeeded(store)
        guard store.widgetEnabled else { return hide() }
        let cards = store.experience.deskCards
        for (id, panel) in panels where !cards.contains(where: { $0.id == id }) {
            panel.orderOut(nil)
            panels[id] = nil
        }
        for card in cards {
            let panel = panels[card.id] ?? makePanel(card: card, store: store)
            panels[card.id] = panel
            if let host = panel.contentView as? NSHostingView<DeskCardHost> {
                host.rootView = DeskCardHost(store: store, card: card, coordinator: self)
            }
            applyLevel(panel)
            place(panel, card: card)
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        for panel in panels.values { panel.orderOut(nil) }
        panels.removeAll()
    }

    /// A first 0.5 launch: whoever had the card on keeps a card where it was —
    /// the recommended pair, the main provider big and spend beneath it.
    private func migrateIfNeeded(_ store: UsageStore) {
        guard !store.experience.deskCardsMigrated else { return }
        let origin = ConfigStore.shared.widgetOrigin
        let pinned = ConfigStore.shared.widgetScope == .pinned ? ConfigStore.shared.widgetPin : nil
        store.updateExperience { prefs in
            if prefs.deskCards.isEmpty {
                prefs.deskCards = DeskCard.defaults(provider: pinned, x: origin.x, y: min(origin.y, 0.55))
            }
            prefs.deskCardsMigrated = true
        }
    }

    private func makePanel(card: DeskCard, store: UsageStore) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: card.size.width, height: card.size.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        // Never take focus from whatever the user is actually working in.
        panel.becomesKeyOnlyIfNeeded = true
        let host = NSHostingView(rootView: DeskCardHost(store: store, card: card, coordinator: self))
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        return panel
    }

    private func applyLevel(_ panel: NSPanel) {
        panel.level = ConfigStore.shared.widgetAlwaysOnTop
            ? .floating
            // Just above the desktop icons, so the card is part of the
            // desktop rather than something floating over the work.
            : NSWindow.Level(Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
    }

    /// Places a card from its stored fractions, fully on screen.
    private func place(_ panel: NSPanel, card: DeskCard) {
        guard let screen = EdgeDockCoordinator.hostScreen else { return }
        let visible = screen.visibleFrame
        let size = panel.contentView?.fittingSize ?? NSSize(width: card.size.width, height: card.size.height)
        let width = max(size.width, 40), height = max(size.height, 40)
        let x = visible.minX + (visible.width - width) * CGFloat(card.x)
        let y = visible.maxY - height - (visible.height - height) * CGFloat(card.y)
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }

    func move(_ cardID: String, by translation: CGSize) {
        guard let panel = panels[cardID], let screen = EdgeDockCoordinator.hostScreen else { return }
        let visible = screen.visibleFrame
        var frame = panel.frame
        frame.origin.x = min(max(frame.origin.x + translation.width, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y - translation.height, visible.minY), visible.maxY - frame.height)
        panel.setFrame(frame, display: true)
    }

    func persist(_ cardID: String) {
        guard let panel = panels[cardID], let screen = EdgeDockCoordinator.hostScreen, let store else { return }
        let visible = screen.visibleFrame
        let x = Double((panel.frame.minX - visible.minX) / max(1, visible.width - panel.frame.width))
        let y = Double((visible.maxY - panel.frame.maxY) / max(1, visible.height - panel.frame.height))
        store.updateDeskCard(cardID) { $0.x = min(max(x, 0), 1); $0.y = min(max(y, 0), 1) }
    }
}

/// A card with what makes it a desktop card: drag to move, double-click for
/// the menu panel, right-click to change it.
struct DeskCardHost: View {
    @ObservedObject var store: UsageStore
    let card: DeskCard
    let coordinator: DesktopWidgetCoordinator
    @State private var dragging = false

    var body: some View {
        DeskCardView(store: store, card: card)
            .scaleEffect(dragging ? 1.02 : 1)
            .animation(Motion.animation(.easeOut(duration: 0.12)), value: dragging)
            .fixedSize()
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .onTapGesture(count: 2) { MenuPanelController.shared.open(from: nil) }
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged {
                        dragging = true
                        coordinator.move(card.id, by: $0.translation)
                    }
                    .onEnded { _ in
                        dragging = false
                        coordinator.persist(card.id)
                    })
            .contextMenu { DeskCardMenu(store: store, card: card) }
            .honoursReducedMotion()
    }
}

/// Right-click on a card: its style, size and subject; another card; this
/// one gone.
struct DeskCardMenu: View {
    @ObservedObject var store: UsageStore
    let card: DeskCard

    var body: some View {
        Menu(L10n.t("Style", "样式")) {
            ForEach(DeskCardStyle.allCases) { style in
                Toggle(style.displayName, isOn: Binding(
                    get: { card.style == style },
                    set: { if $0 { store.updateDeskCard(card.id) { $0.style = style } } }))
            }
        }
        Menu(L10n.t("Size", "尺寸")) {
            ForEach(DeskCardSize.allCases) { size in
                Toggle(size.displayName, isOn: Binding(
                    get: { card.size == size },
                    set: { if $0 { store.updateDeskCard(card.id) { $0.size = size } } }))
            }
        }
        if card.style.readsLogs {
            Menu(L10n.t("Counts", "统计来源")) {
                Toggle(L10n.t("Every CLI", "全部"), isOn: Binding(
                    get: { card.source == nil },
                    set: { if $0 { store.updateDeskCard(card.id) { $0.source = nil } } }))
                ForEach(CostSource.allCases, id: \.self) { source in
                    Toggle(source.displayName, isOn: Binding(
                        get: { card.source == source },
                        set: { if $0 { store.updateDeskCard(card.id) { $0.source = source } } }))
                }
            }
        } else {
            Menu(L10n.t("Provider", "服务商")) {
                Toggle(card.style.singleProvider ? L10n.t("Follow the menu bar", "跟随菜单栏选中的") : L10n.t("Every provider", "全部服务商"), isOn: Binding(
                    get: { card.provider == nil },
                    set: { if $0 { store.updateDeskCard(card.id) { $0.provider = nil } } }))
                ForEach(store.enabled) { id in
                    Toggle(id.displayName, isOn: Binding(
                        get: { card.provider == id },
                        set: { if $0 { store.updateDeskCard(card.id) { $0.provider = id } } }))
                }
            }
        }
        Divider()
        Button(L10n.t("Add a Card", "添加卡片")) { store.addDeskCard(near: card) }
        Toggle(L10n.t("Keep Above Other Windows", "置于其他窗口之上"), isOn: Binding(
            get: { store.widgetAlwaysOnTop },
            set: { store.setWidgetAlwaysOnTop($0) }))
        Button(L10n.t("Refresh Everything", "全部刷新")) { store.forceRefreshAll() }
        Divider()
        Button(L10n.t("Remove This Card", "删除这张卡片"), role: .destructive) { store.removeDeskCard(card.id) }
        Button(L10n.t("Settings…", "设置…")) { SettingsWindow.open() }
    }
}

/// The card from before 0.5 — rings, rings with figures, or a row per
/// provider — now one of the desktop card styles, sized by its card.
struct DesktopWidgetView: View {
    @ObservedObject var store: UsageStore
    var density: WidgetDensity
    var providerList: [ProviderID]

    init(store: UsageStore, density: WidgetDensity, providers: [ProviderID]) {
        self.store = store
        self.density = density
        self.providerList = providers
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.space3) {
            header
            if providerList.isEmpty {
                Text(L10n.t("No providers enabled.", "尚未启用任何服务商。"))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            } else {
                content
            }
        }
        .padding(Design.space4 - 2)
        .background(
            RoundedRectangle(cornerRadius: Design.radiusPanel + 4, style: .continuous)
                .fill(Color.black.opacity(0.82)))
        .overlay(
            // A hairline so the card keeps an edge against a dark wallpaper.
            RoundedRectangle(cornerRadius: Design.radiusPanel + 4, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1))
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }

    private var header: some View {
        HStack(spacing: Design.space2) {
            Text("QuotaBar")
                .font(Design.wordmark(size: 11))
                .foregroundStyle(.white.opacity(0.65))
            Spacer(minLength: Design.space3)
            if let updated = latestFetch {
                Text(QuotaFormat.age(of: updated))
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    private var latestFetch: Date? {
        providerList.compactMap { store.states[$0]?.snapshot?.fetchedAt }.max()
    }

    @ViewBuilder
    private var content: some View {
        switch density {
        case .compact:
            HStack(spacing: Design.space3) {
                ForEach(providers) { id in
                    ProviderRing(
                        id: id,
                        percent: percent(id),
                        mode: store.meterMode,
                        diameter: 34,
                        showsLabel: false)
                }
            }
        case .standard:
            HStack(alignment: .top, spacing: Design.space4 - 2) {
                ForEach(providers) { id in
                    VStack(spacing: 3) {
                        ProviderRing(
                            id: id,
                            percent: percent(id),
                            mode: store.meterMode,
                            diameter: 40)
                        if let resetsAt = store.headlineWindow(for: id)?.resetsAt {
                            Text(QuotaFormat.tick(to: resetsAt))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                    }
                }
            }
        case .detailed:
            VStack(alignment: .leading, spacing: Design.space3) {
                ForEach(providers) { id in
                    detailRow(id)
                }
                if store.cost.hasData {
                    HStack {
                        Text(L10n.t("Today", "今日"))
                        Text(QuotaFormat.money(store.cost.spend(.today).usd)).monospacedDigit()
                        Spacer()
                        Text(SpendPeriod.window.displayName(windowDays: store.cost.windowDays))
                        Text(QuotaFormat.money(store.cost.spend(.window).usd)).monospacedDigit()
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.55))
                }
            }
            .frame(width: 250, alignment: .leading)
        }
    }

    private func detailRow(_ id: ProviderID) -> some View {
        HStack(alignment: .top, spacing: Design.space3) {
            ProviderRing(
                id: id,
                percent: percent(id),
                mode: store.meterMode,
                diameter: 32,
                showsLabel: false)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(id.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                    Spacer()
                    Text(percent(id).map { QuotaFormat.percent(store.meterMode.shownPercent(fromUsed: $0)) } ?? "—")
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                }
                // The two horizons, when the provider reports both. This is
                // the same split the menu-bar glyph uses.
                ForEach(windows(id), id: \.id) { window in
                    HStack(spacing: Design.space2) {
                        if let label = window.shortLabel {
                            Text(label)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.55))
                                .frame(width: 22, alignment: .leading)
                        }
                        Meter(
                            percent: window.usedPercent.map { store.meterMode.shownPercent(fromUsed: $0) },
                            tint: window.usedPercent.map(tint) ?? .clear,
                            style: store.meterStyle,
                            height: 4,
                            track: Color.white.opacity(0.15))
                        .paceTick(window, mode: store.meterMode, always: store.experience.alwaysShowPace)
                        if let resetsAt = window.resetsAt {
                            Text(QuotaFormat.tick(to: resetsAt))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.45))
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    /// One row per horizon, two at most: a 5-hour and a 7-day bar when the
    /// provider reports both, one bar when it reports one. Not one per
    /// window — Cursor's three monthly windows and Grok's per-product
    /// weeklies all run on the same clock, and stacking them was a wall of
    /// bars that said the same thing.
    private func windows(_ id: ProviderID) -> [UsageWindow] {
        var seen = Set<String>()
        var out: [UsageWindow] = []
        for window in store.states[id]?.snapshot?.windows ?? [] where window.usedPercent != nil {
            let horizon = window.shortLabel ?? window.title
            guard seen.insert(horizon).inserted else { continue }
            out.append(window)
            if out.count == 2 { break }
        }
        return out
    }

    private func percent(_ id: ProviderID) -> Double? {
        store.headlinePercent(for: id)
    }

    /// In the order enabled, or closest to the limit first when asked.
    private var providers: [ProviderID] {
        guard store.experience.widgetSortsByUrgency else { return providerList }
        return providerList.sorted { (percent($0) ?? -1) > (percent($1) ?? -1) }
    }

    private func tint(_ percent: Double) -> Color {
        return Color(hex: UsageRamp.hex(used: percent))
    }
}

import AppKit
import SwiftUI
import QuotaCore

// MARK: - The menu panel, back in 0.5

/// The panel under the menu-bar item: the numbers people check most, one
/// screen, after openusage's popover — spend at the top, a card per provider,
/// and a footer with the next refresh and the options.
///
/// A key-capable, non-activating panel rather than an `NSPopover`: it takes
/// Esc, ⌘R and ⌘, without pulling the app forward, and it is sized to its
/// content with the top edge pinned under the item.
@MainActor
final class MenuPanelController {
    static let shared = MenuPanelController()

    static let width: CGFloat = 372

    private var panel: KeyPanel?
    private weak var store: UsageStore?
    private weak var anchor: NSStatusBarButton?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var keyMonitor: Any?
    private var contentHeight: CGFloat = 480

    var isOpen: Bool { panel?.isVisible == true }

    func configure(store: UsageStore) {
        self.store = store
    }

    func toggle(from button: NSStatusBarButton?) {
        if isOpen { close() } else { open(from: button) }
    }

    func open(from button: NSStatusBarButton?) {
        guard let store else { return }
        anchor = button
        let panel = self.panel ?? makePanel(store: store)
        self.panel = panel
        place(panel, animated: false)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.reduced ? 0 : 0.14
            panel.animator().alphaValue = 1
        }
        button?.highlight(true)
        installMonitors()
        if !store.isComputingCost && !store.cost.hasData { store.refreshCost() }
    }

    func close() {
        guard let panel, panel.isVisible else { return }
        removeMonitors()
        anchor?.highlight(false)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Motion.reduced ? 0 : 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in panel.orderOut(nil) }
        })
    }

    /// The content reports its height; the panel follows, top edge fixed.
    func setContentHeight(_ height: CGFloat) {
        guard abs(height - contentHeight) > 0.5 else { return }
        contentHeight = height
        guard let panel, panel.isVisible else { return }
        place(panel, animated: true)
    }

    // MARK: Window

    final class KeyPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override func cancelOperation(_ sender: Any?) {
            Task { @MainActor in MenuPanelController.shared.close() }
        }
    }

    private func makePanel(store: UsageStore) -> KeyPanel {
        let panel = KeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: contentHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.animationBehavior = .none
        let host = FirstMouseHostingView(rootView: MenuPanelView(store: store))
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }

    private func place(_ panel: NSPanel, animated: Bool) {
        let screen = anchor?.window?.screen ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let height = min(contentHeight, visible.height - 16)
        let anchorFrame = anchor?.window?.frame
        var x = (anchorFrame?.midX ?? (visible.maxX - Self.width / 2 - 12)) - Self.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - Self.width - 8)
        let top = min(anchorFrame?.minY ?? visible.maxY, visible.maxY) - 6
        let frame = NSRect(x: x, y: top - height, width: Self.width, height: height)
        guard animated, !Motion.reduced else {
            panel.setFrame(frame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
            panel.animator().setFrame(frame, display: true)
        }
    }

    // MARK: Dismissal and keys

    private func installMonitors() {
        removeMonitors()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            Task { @MainActor in MenuPanelController.shared.close() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            // Our own other windows — the dock, the island, settings — dismiss
            // it too; the item's button toggles it itself.
            if event.window !== self.panel, event.window !== self.anchor?.window, event.window?.className.contains("Popover") != true {
                self.close()
            }
            return event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            let command = event.modifierFlags.contains(.command)
            switch (command, event.charactersIgnoringModifiers?.lowercased()) {
            case (false, _) where event.keyCode == 53:
                self.close()
                return nil
            case (true, "r"):
                self.store?.forceRefreshAll()
                return nil
            case (true, ","):
                self.close()
                SettingsWindow.open()
                return nil
            case (true, "w"):
                self.close()
                return nil
            default:
                return event
            }
        }
    }

    private func removeMonitors() {
        for monitor in [globalMonitor, localMonitor, keyMonitor].compactMap({ $0 }) {
            NSEvent.removeMonitor(monitor)
        }
        globalMonitor = nil
        localMonitor = nil
        keyMonitor = nil
    }
}

// MARK: - Content

/// Each provider card's height, for working out when a dragged card has
/// passed its neighbour.
private struct CardHeightsKey: PreferenceKey {
    static var defaultValue: [ProviderID: CGFloat] = [:]
    static func reduce(value: inout [ProviderID: CGFloat], nextValue: () -> [ProviderID: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

/// The AppKit scroll view behind a SwiftUI ScrollView, for reading how far
/// it has scrolled and scrolling it from code.
@MainActor
final class ScrollViewHandle {
    weak var scrollView: NSScrollView?

    /// Distance scrolled from the top.
    var offset: CGFloat {
        guard let clip = scrollView?.contentView else { return 0 }
        if clip.isFlipped { return clip.bounds.origin.y }
        return (clip.documentView?.frame.height ?? 0) - clip.bounds.maxY
    }

    /// Scrolls by `delta` points (positive: further down the content),
    /// clamped to the content. False when it was already at that end.
    @discardableResult
    func scroll(by delta: CGFloat) -> Bool {
        guard let scrollView, let document = scrollView.documentView else { return false }
        let clip = scrollView.contentView
        let maxOffset = max(0, document.frame.height - clip.bounds.height)
        let target = min(max(offset + delta, 0), maxOffset)
        guard abs(target - offset) > 0.1 else { return false }
        let y = clip.isFlipped ? target : maxOffset - target
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        scrollView.reflectScrolledClipView(clip)
        return true
    }

    struct Reader: NSViewRepresentable {
        let handle: ScrollViewHandle

        func makeNSView(context: Context) -> Probe {
            let probe = Probe()
            probe.handle = handle
            return probe
        }

        func updateNSView(_ probe: Probe, context: Context) {
            probe.handle = handle
            probe.attach()
        }

        final class Probe: NSView {
            weak var handle: ScrollViewHandle?

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                attach()
            }

            func attach() {
                MainActor.assumeIsolated { handle?.scrollView = enclosingScrollView }
            }
        }
    }
}

private struct PanelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct MenuPanelView: View {
    @ObservedObject var store: UsageStore
    /// Off for off-screen renders, which draw a ScrollView's content as nothing.
    var scrollable = true
    @State private var scrollHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 52
    /// Dragging a provider card: which one, the order as it stands mid-drag,
    /// and how far the card sits from its current slot. The order is saved
    /// once, on release.
    @State private var dragging: ProviderID?
    @State private var dragOrder: [ProviderID]?
    @State private var dragOffset: CGFloat = 0
    /// How far the dragged card's slot has moved since the drag began, as
    /// the cards it passed closed up behind it.
    @State private var dragShift: CGFloat = 0
    @State private var cardHeights: [ProviderID: CGFloat] = [:]
    /// True while a card is held. It resets on its own when the gesture ends
    /// *or is cancelled* — released outside the panel, say — which `onEnded`
    /// alone does not report, and the card was left lifted with the order unsaved.
    @GestureState private var holdingCard = false
    /// Scrolling while a card is held near the top or bottom of the list:
    /// the scroll view, its visible frame, how far it had scrolled when the
    /// drag began, the drag's last translation, and the timer that scrolls.
    @State private var scroller = ScrollViewHandle()
    @State private var viewport: CGRect = .zero
    @State private var dragScrollStart: CGFloat = 0
    @State private var dragTranslation: CGFloat = 0
    @State private var dragPointerY: CGFloat = 0
    @State private var autoscroll: Timer?

    var body: some View {
        VStack(spacing: 0) {
            if scrollable {
                ScrollView {
                    cards.background(ScrollViewHandle.Reader(handle: scroller))
                }
                    .scrollIndicators(.never)
                    .background(GeometryReader { proxy in
                        Color.clear
                            .onAppear { viewport = proxy.frame(in: .global) }
                            .onChange(of: proxy.frame(in: .global)) { _, frame in viewport = frame }
                    })
                    .onPreferenceChange(PanelHeightKey.self) { height in
                        scrollHeight = height
                        MenuPanelController.shared.setContentHeight(height + footerHeight)
                    }
            } else {
                cards
            }

            PanelFooter(store: store)
                .background(GeometryReader { proxy in
                    Color.clear.onAppear { footerHeight = proxy.size.height }
                })
        }
        .frame(width: MenuPanelController.width)
        .background {
            let shape = RoundedRectangle(cornerRadius: Design.radiusPanel, style: .continuous)
            if store.experience.panelTranslucent {
                shape.fill(.ultraThinMaterial).overlay(shape.fill(Color.black.opacity(0.55)))
            } else {
                shape.fill(Color.black)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: Design.radiusPanel, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: Design.radiusPanel, style: .continuous))
        .overlay(alignment: .bottom) {
            if let notice = store.copiedNotice {
                TransientPill(symbol: "checkmark.circle.fill", text: notice)
                    .padding(.bottom, footerHeight + 10)
            }
        }
        .animation(Motion.animation(Motion.spring), value: store.copiedNotice)
        .environment(\.colorScheme, .dark)
        .honoursReducedMotion()
    }

    private var cardSpacing: CGFloat { store.experience.panelDensity == .compact ? 8 : 10 }

    private var cards: some View {
                VStack(spacing: cardSpacing) {
                    if !store.experience.welcomeDismissed {
                        WelcomeCard(store: store)
                    }
                    UpdateBanner(store: store)
                    if store.experience.showSpendCard {
                        SpendCardView(store: store)
                    }
                    if store.enabled.isEmpty {
                        emptyState
                    }
                    ForEach(dragOrder ?? store.panelProviders) { id in
                        let lifted = dragging == id
                        ProviderCardView(store: store, id: id)
                            .background(GeometryReader { proxy in
                                Color.clear.preference(key: CardHeightsKey.self, value: [id: proxy.size.height])
                            })
                            .scaleEffect(lifted ? 1.02 : 1)
                            .shadow(color: .black.opacity(lifted ? 0.5 : 0), radius: lifted ? 16 : 0, y: lifted ? 8 : 0)
                            .offset(y: lifted ? dragOffset : 0)
                            .zIndex(lifted ? 1 : 0)
                            // The lifted card follows the pointer exactly; only
                            // the cards making room for it animate.
                            .transaction { if lifted { $0.animation = nil } }
                            .gesture(reorderGesture(for: id))
                    }
                    let hidden = store.hiddenProviders(on: .panel)
                    if !hidden.isEmpty {
                        HiddenProvidersNote(store: store, hidden: hidden)
                    }
                }
                .padding(10)
                .onPreferenceChange(CardHeightsKey.self) { cardHeights = $0 }
                .onChange(of: holdingCard) { _, holding in
                    if !holding { finishReorder() }
                }
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: PanelHeightKey.self, value: proxy.size.height)
                })
                .animation(Motion.animation(Motion.spring), value: store.experience.expandedCards)
    }

    /// Press a card and drag it up or down the list. Once its centre passes
    /// halfway over a neighbour, the two trade places and the neighbour slides
    /// into the gap; on release the card settles into its slot and the order
    /// is saved for every surface. Clicks, buttons and the bars inside the card
    /// keep working: the drag only starts after six points of movement.
    private func reorderGesture(for id: ProviderID) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .updating($holdingCard) { _, holding, _ in holding = true }
            .onChanged { value in
                if dragging == nil {
                    dragging = id
                    dragOrder = store.panelProviders
                    dragShift = 0
                    dragScrollStart = scroller.offset
                    startAutoscroll()
                }
                guard dragging == id else { return }
                dragTranslation = value.translation.height
                dragPointerY = value.location.y
                follow()
            }
            .onEnded { _ in finishReorder() }
    }

    /// Where the lifted card goes for the pointer's travel plus however far
    /// the list has scrolled under it; neighbours it passes halfway over
    /// trade places with it.
    private func follow() {
        guard let id = dragging, var order = dragOrder, let index = order.firstIndex(of: id) else { return }
        var offset = dragTranslation + (scroller.offset - dragScrollStart) - dragShift
        if offset > 0, index + 1 < order.count {
            let step = (cardHeights[order[index + 1]] ?? 0) + cardSpacing
            if step > cardSpacing, offset > step / 2 {
                order.swapAt(index, index + 1)
                dragShift += step
                offset -= step
                withAnimation(Motion.animation(Motion.spring)) { dragOrder = order }
            }
        } else if offset < 0, index > 0 {
            let step = (cardHeights[order[index - 1]] ?? 0) + cardSpacing
            if step > cardSpacing, -offset > step / 2 {
                order.swapAt(index, index - 1)
                dragShift -= step
                offset += step
                withAnimation(Motion.animation(Motion.spring)) { dragOrder = order }
            }
        }
        dragOffset = offset
    }

    /// Held within 40pt of the list's top or bottom edge, the list scrolls
    /// that way — faster the closer the pointer — and the card keeps up.
    private func startAutoscroll() {
        autoscroll?.invalidate()
        let edge: CGFloat = 40
        autoscroll = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard dragging != nil, viewport.height > edge * 2 else { return }
                let fromTop = dragPointerY - viewport.minY
                let fromBottom = viewport.maxY - dragPointerY
                var step: CGFloat = 0
                if fromTop < edge { step = -(edge - max(fromTop, 0)) / 3 }
                if fromBottom < edge { step = (edge - max(fromBottom, 0)) / 3 }
                guard step != 0, scroller.scroll(by: step) else { return }
                follow()
            }
        }
    }

    /// Settles the lifted card into its slot and saves the order.
    private func finishReorder() {
        autoscroll?.invalidate()
        autoscroll = nil
        guard dragging != nil else { return }
        if let order = dragOrder { store.arrangeProviders(order) }
        withAnimation(Motion.animation(Motion.spring)) {
            dragOffset = 0
            dragging = nil
        }
        dragOrder = nil
        dragShift = 0
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text(L10n.t("No providers are on.", "还没有开启服务商。"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
            Pressable(action: { MenuPanelController.shared.close(); SettingsWindow.open() }) {
                Text(L10n.t("Choose providers", "选择服务商"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.white))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }
}

/// The one-time card after a first launch: what was switched on, and where
/// to change it.
private struct WelcomeCard: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.7))
            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.t("Welcome to QuotaBar", "欢迎使用 QuotaBar"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Text(L10n.t(
                    "We turned on the \(store.enabled.count) providers signed in on this Mac. Add or hide providers any time.",
                    "已按本机的登录情况开启 \(store.enabled.count) 个服务商，随时可以在设置里增减。"))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
                Pressable(action: { MenuPanelController.shared.close(); SettingsWindow.open() }) {
                    Text(L10n.t("Open Settings", "打开设置"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
            CalloutButton(symbol: "xmark", help: L10n.t("Dismiss", "关闭")) {
                withAnimation(Motion.animation(Motion.spring)) {
                    store.updateExperience { $0.welcomeDismissed = true }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.07)))
    }
}

/// A release that is ready or found, in the panel where it will be seen.
private struct UpdateBanner: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        switch store.updateStage {
        case let .readyToInstall(release):
            banner(
                L10n.t("QuotaBar \(release.version) is ready", "QuotaBar \(release.version) 已下载"),
                action: L10n.t("Update", "更新")) { [store] in UpdateWindow.show(store: store) }
        case let .available(release):
            banner(
                L10n.t("QuotaBar \(release.version) is available", "发现新版本 \(release.version)"),
                action: L10n.t("See What's New", "查看更新")) { [store] in UpdateWindow.show(store: store) }
        default:
            EmptyView()
        }
    }

    private func banner(_ title: String, action: String, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(Palette.live)
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
            Spacer()
            Pressable(action: perform) {
                Text(action)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Palette.live))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.07)))
    }
}

// MARK: - Footer

private struct PanelFooter: View {
    @ObservedObject var store: UsageStore

    private var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).map { "QuotaBar \($0)" } ?? "QuotaBar"
    }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5)
            HStack(spacing: 8) {
                BreathingDot(active: store.failingProviders.isEmpty, color: store.failingProviders.isEmpty ? Palette.live : Palette.amber, pulse: store.tick)
                // One line: the version, then when the next automatic refresh is.
                HStack(spacing: 5) {
                    Text(version)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                    Text("·")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.3))
                    refreshLine
                }
                .lineLimit(1)
                Spacer(minLength: 6)
                refreshAllButton
                CalloutButton(symbol: "gearshape", help: L10n.t("Settings (⌘,)", "设置（⌘,）")) {
                    MenuPanelController.shared.close()
                    SettingsWindow.open()
                }
                OptionsMenuButton(store: store)
                    .frame(width: 22, height: 22)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(Color(white: 0.06))
    }

    /// Refreshes everything — every provider, the status pages and the logs
    /// — and spins until all of it is back. A card's own button refreshes
    /// just that card.
    @ViewBuilder
    private var refreshAllButton: some View {
        if store.isForceRefreshing {
            ProgressView()
                .controlSize(.small)
                .frame(width: 22, height: 22)
                .help(L10n.t("Refreshing everything…", "正在全部刷新…"))
        } else {
            CalloutButton(symbol: "arrow.clockwise", help: L10n.t("Refresh everything (⌘R)", "全部刷新（⌘R）")) {
                store.forceRefreshAll()
            }
        }
    }

    @ViewBuilder
    private var refreshLine: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            Text(store.isForceRefreshing ? L10n.t("Refreshing…", "正在刷新…") : refreshStatus(now: context.date))
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.45))
                .help(refreshHelp)
        }
    }

    /// "Just updated" for a minute after a refresh finishes — the timer has
    /// just started over, and a fresh "5 minutes" read as if the button had
    /// done nothing — then the countdown to the next automatic one.
    private func refreshStatus(now: Date) -> String {
        if let last = store.lastRefreshAt, now.timeIntervalSince(last) < 60 {
            return L10n.t("Updated just now", "刚刚更新")
        }
        let seconds = max(0, store.nextRefreshAt.timeIntervalSince(now))
        let minutes = Int((seconds / 60).rounded(.up))
        return minutes <= 1
            ? L10n.t("Auto-refresh within a minute", "1 分钟内自动刷新")
            : L10n.t("Auto-refresh in \(minutes)m", "\(minutes) 分钟后自动刷新")
    }

    private var refreshHelp: String {
        let clock = DateFormatter()
        clock.locale = L10n.locale
        clock.dateStyle = .none
        clock.timeStyle = .short
        let every = QuotaConfig.clampRefresh(store.refreshMinutes)
        let next = L10n.t(
            "Next automatic refresh at \(clock.string(from: store.nextRefreshAt)), every \(every) minutes.",
            "下次自动刷新 \(clock.string(from: store.nextRefreshAt))，每 \(every) 分钟一次。")
        guard let last = store.lastRefreshAt else { return next }
        return L10n.t("Last updated at \(clock.string(from: last)). ", "上次更新 \(clock.string(from: last))。") + next
    }
}

/// The footer's "…" menu: everything the panel can do that is not a number.
private struct OptionsMenuButton: NSViewRepresentable {
    let store: UsageStore

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: L10n.t("Options", "选项")) ?? NSImage(), target: context.coordinator, action: #selector(Coordinator.show(_:)))
        button.isBordered = false
        button.contentTintColor = NSColor.white.withAlphaComponent(0.6)
        button.toolTip = L10n.t("Options", "选项")
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.store = store
    }

    func makeCoordinator() -> Coordinator { Coordinator(store: store) }

    @MainActor
    final class Coordinator: NSObject {
        var store: UsageStore
        init(store: UsageStore) { self.store = store }

        @objc func show(_ sender: NSButton) {
            let menu = NSMenu()
            add(menu, L10n.t("Settings…", "设置…"), ",") {
                MenuPanelController.shared.close()
                SettingsWindow.open()
            }
            add(menu, L10n.t("Share Usage Card…", "分享用量卡片…"), "") { [store] in ShareStudio.open(store: store) }
            let copy = NSMenuItem(title: L10n.t("Copy as Image", "复制为图片"), action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            add(submenu, L10n.t("Total spend", "总花费"), "") { [store] in
                if CardImageExporter.copy(ShareableCard(store: store) { SpendCardView(store: store, forExport: true) }) {
                    store.flashNotice(L10n.t("Copied to clipboard", "已复制到剪贴板"))
                }
            }
            for id in store.enabled {
                add(submenu, id.displayName, "") { [store] in
                    if CardImageExporter.copy(ShareableCard(store: store) { ProviderCardView(store: store, id: id, forExport: true) }) {
                        store.flashNotice(L10n.t("Copied to clipboard", "已复制到剪贴板"))
                    }
                }
            }
            copy.submenu = submenu
            menu.addItem(copy)
            menu.addItem(.separator())
            add(menu, L10n.t("Refresh Everything", "全部刷新"), "r") { [store] in store.forceRefreshAll() }
            add(menu, L10n.t("Check for Updates…", "检查更新…"), "") { [store] in store.checkForUpdate(manual: true, presenting: true) }
            add(menu, L10n.t("About QuotaBar", "关于 QuotaBar"), "") {
                MenuPanelController.shared.close()
                SettingsWindow.open()
                NSApp.orderFrontStandardAboutPanel(nil)
            }
            menu.addItem(.separator())
            add(menu, L10n.t("Quit QuotaBar", "退出 QuotaBar"), "q") { NSApp.terminate(nil) }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
        }

        private var actions: [ClosureTarget] = []

        private func add(_ menu: NSMenu, _ title: String, _ key: String, _ action: @escaping () -> Void) {
            let target = ClosureTarget(action)
            actions.append(target)
            let item = NSMenuItem(title: title, action: #selector(ClosureTarget.fire), keyEquivalent: key)
            item.target = target
            menu.addItem(item)
        }
    }
}

final class ClosureTarget: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @MainActor @objc func fire() { action() }
}

/// Under the cards, when some are hidden from the panel: how many, their
/// marks, and a way to show them again.
struct HiddenProvidersNote: View {
    @ObservedObject var store: UsageStore
    let hidden: [ProviderID]

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "eye.slash")
                .font(.system(size: 10, weight: .medium))
            Text(L10n.t("\(hidden.count) hidden here", "\(hidden.count) 个已在面板隐藏"))
                .font(.system(size: 11))
            HStack(spacing: -3) {
                ForEach(hidden.prefix(6)) { id in
                    ProviderGlyph(id: id, size: 12, tint: .white.opacity(0.7))
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
            }
            Spacer(minLength: 4)
            Menu {
                ForEach(hidden) { id in
                    Button(L10n.t("Show \(id.displayName)", "显示 \(id.displayName)")) {
                        withAnimation(Motion.animation(Motion.spring)) { store.setHidden(false, id, on: .panel) }
                    }
                }
                Divider()
                Button(L10n.t("Manage in Settings…", "在设置中管理…")) {
                    MenuPanelController.shared.close()
                    SettingsWindow.open(section: .presentation)
                }
            } label: {
                Text(L10n.t("Show", "显示"))
                    .font(.system(size: 11, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .foregroundStyle(.white.opacity(0.5))
        .padding(.horizontal, 6)
        .padding(.top, 2)
    }
}

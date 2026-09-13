import AppKit
import SwiftUI
import QuotaCore

/// A strip docked to the right edge of the screen that hides itself until the
/// pointer reaches the edge.
///
/// The panel is always the strip's full size, flush against the edge. At rest
/// only the handle is drawn in it and everywhere else lets the mouse through;
/// on hover the black shape grows inside the fixed window — wider first, then
/// taller — so the window never resizes under the animation. Resizing it was
/// what left a gap: for a frame the old, narrow content sat at the new
/// window's inboard side, away from the edge.
@MainActor
final class EdgeDockCoordinator {
    private var panel: NSPanel?
    /// For what the strip lists: its height follows the providers shown.
    private weak var store: UsageStore?
    /// The callout lives in its own panel. Drawing it inside the strip would
    /// need a panel wide enough to hold it, and that panel's empty region
    /// would swallow clicks meant for whatever is underneath.
    private var calloutPanel: NSPanel?
    private var collapseTask: Task<Void, Never>?
    private var expanded = false
    /// The pointer is over the callout. The card is a second window, so
    /// leaving the strip for it looks, to the strip, like leaving; this is
    /// what tells the collapse to wait.
    private(set) var calloutHovered = false
    /// The strip's expansion setter, kept so the callout can hand the strip
    /// a collapse when the pointer leaves the card for empty space.
    private var applyExpanded: ((Bool) -> Void)?

    static let calloutWidth: CGFloat = 260

    /// A reset for the view to play; the coordinator decides which.
    final class ResetBridge: ObservableObject {
        @Published var current: ResetBanner?
    }
    let resets = ResetBridge()

    /// Windows that just reset: the strip comes out on its own, the ring of
    /// the provider whose window had been fullest fills in its colour, and a
    /// card beside it says so, then all of it goes back.
    func playReset(_ events: [ResetEvent], store: UsageStore) {
        guard panel != nil else { return }
        let shown = events.filter { store.dockProviders.contains($0.provider) }
        guard !shown.isEmpty else { return }
        resets.current = ResetBanner(events: shown)
    }
    /// One ring, the dot row under it, and the stack spacing. No figure: the
    /// owner had the percentages removed — the callout carries them.
    static let cellHeight: CGFloat = ProviderRing.cellHeight(selectionDot: true) + Design.space3
    /// The strip's vertical insets. A ring's 3pt arc is stroked centred on
    /// the disc's edge, so its ink reaches 1.5pt above the top cell; the last
    /// cell ends with the 10pt dot row, which is empty unless that provider is
    /// the selected one. Top 16 and bottom 8 put about 15pt of black above the
    /// first arc and 17 below the last, and keep the dot 8pt off the edge.
    static let stripInsetTop: CGFloat = Design.space4
    static let stripInsetBottom: CGFloat = Design.space2

    /// Collapsed, the dock is a handle rather than a sliver of the strip.
    /// Five points of an off-screen panel is neither visible nor clickable —
    /// it reads as the feature not being there at all.
    static let handleWidth: CGFloat = 18
    static let handleHeight: CGFloat = 92
    static let width: CGFloat = 74
    /// Past this the strip stops growing and its rings scroll: it keeps
    /// 24pt clear of the menu bar and of the screen's bottom edge.
    static let screenMargin: CGFloat = Design.space6

    /// How far the rings are scrolled from the top, reported by the view.
    /// The callout lines up with a ring by arithmetic, so it has to know.
    var scrollOffset: CGFloat = 0

    /// The reveal's time scale: 0.24 is normal. `QUOTABAR_DOCK_SLIDE=2`
    /// stretches the grow so a frame of it can actually be caught.
    static let slideDuration: TimeInterval =
        ProcessInfo.processInfo.environment["QUOTABAR_DOCK_SLIDE"]
            .flatMap(Double.init) ?? 0.24

    /// `QUOTABAR_DOCK_TRACE=1` logs every frame request and what was decided.
    /// The reveal's failure mode is that it completes either way, so the only
    /// way to see two sources fighting over the frame is to print them.
    static let tracing = ProcessInfo.processInfo.environment["QUOTABAR_DOCK_TRACE"] == "1"

    static func trace(_ message: @autoclosure () -> String) {
        guard tracing else { return }
        let stamp = String(format: "%8.3f", ProcessInfo.processInfo.systemUptime)
        FileHandle.standardError.write(Data("[dock \(stamp)] \(message())\n".utf8))
    }

    func sync(store: UsageStore) {
        if store.presentation == .edgeDock {
            show(store: store)
        } else {
            hide()
        }
    }

    func hide() {
        collapseTask?.cancel()
        collapseTask = nil
        for monitor in mouseMonitors { NSEvent.removeMonitor(monitor) }
        mouseMonitors = []
        panel?.orderOut(nil)
        panel = nil
        hideCallout()
        expanded = false
    }

    /// Where the handle sits inside the fixed window, for the view.
    final class Geometry: ObservableObject {
        /// The handle's centre below the window's centre, in points; zero
        /// unless the strip is held on screen at the top or bottom.
        @Published var handleOffset: CGFloat = 0
    }
    let geometry = Geometry()
    /// The handle in screen coordinates: the only part of the window that
    /// takes the mouse while the strip is folded.
    private var handleFrame: NSRect = .zero
    private var mouseMonitors: [Any] = []

    /// Click-through outside what is drawn: the folded window is mostly empty,
    /// and that emptiness must not swallow clicks meant for the window under it.
    private func installMouseTracking() {
        let update: () -> Void = { [weak self] in
            guard let self, let panel = self.panel else { return }
            let point = NSEvent.mouseLocation
            let live = self.expanded || self.alwaysVisible ? panel.frame : self.handleFrame
            let inside = live.contains(point)
            if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        }
        update()
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { _ in
            MainActor.assumeIsolated { update() }
        }) {
            mouseMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { event in
            MainActor.assumeIsolated { update() }
            return event
        }) {
            mouseMonitors.append(local)
        }
        refreshMouseThrough = update
    }
    private var refreshMouseThrough: (() -> Void)?

    // MARK: Callout

    /// Shows the bubble beside ring `index`, or hides it when nil.
    ///
    /// Moving between rings *travels*: the window's frame animates on a curve
    /// with a little overshoot — the same hand as the settings rail's light —
    /// and the content crossfades, so the card is one thing following the
    /// pointer rather than a new card appearing at each ring. First
    /// appearance fades in from the ring's side. `animator()`, never
    /// `setFrame(animate:)`: the latter blocks the main thread for the whole
    /// animation (measured 341ms on the strip).
    /// The full card is wider than the summary.
    static let detailWidth: CGFloat = 320

    /// Measured card sizes by what decides them — provider, full or summary,
    /// and the store's revision — so moving between rings reuses a layout
    /// instead of building a throwaway hosting view for every hover.
    private var calloutSizes: [String: CGSize] = [:]

    func showCallout<Content: View>(
        at index: Int?,
        total: Int,
        width: CGFloat? = nil,
        sizeKey: String? = nil,
        @ViewBuilder content: () -> Content)
    {
        let width = width ?? Self.calloutWidth
        Self.trace("showCallout(index: \(index.map(String.init) ?? "nil"), expanded: \(expanded))")
        guard let index, expanded, let strip = panel else {
            hideCallout()
            return
        }
        let root = CalloutRoot(key: index, content: AnyView(content()))
        let appearing = calloutPanel == nil
        let panel = calloutPanel ?? makeCalloutPanel()
        if let host = panel.contentView as? FirstMouseHostingView<CalloutRoot> {
            withAnimation(Self.calloutFade) { host.rootView = root }
        } else {
            let host = FirstMouseHostingView(rootView: root)
            // The frame is ours to animate; the host must not fight it.
            host.sizingOptions = []
            panel.contentView = host
        }
        // Measure the incoming content, not the host mid-crossfade — once per
        // provider and revision.
        let size: CGSize
        if let sizeKey, let cached = calloutSizes[sizeKey] {
            size = cached
        } else {
            size = NSHostingView(rootView: root).fittingSize
            if let sizeKey {
                if calloutSizes.count > 64 { calloutSizes.removeAll() }
                calloutSizes[sizeKey] = size
            }
        }

        // Line the bubble up with the ring it belongs to. The strip lays its
        // rings out from the top, and AppKit measures from the bottom. The
        // window is always the strip's frame, so it is where the rings will be
        // even while the shape is still growing.
        let stripFrame = strip.frame
        // The disc's centre, not the cell's: the cell has the dot row under
        // the disc, so its middle sits 5pt low.
        let centreFromTop = Self.stripInsetTop + CGFloat(index) * Self.cellHeight + ProviderRing.defaultDiameter / 2 - scrollOffset
        // A ring scrolled half out of view still gets its card, held level
        // with the strip rather than floating past its end.
        let centreY = min(max(stripFrame.maxY - centreFromTop, stripFrame.minY), stripFrame.maxY)
        let height = max(size.height, 40)
        // On the inboard side of the strip, whichever edge it is docked to.
        let onLeft = ConfigStore.shared.dockEdge == .left
        let x = onLeft
            ? stripFrame.maxX + Design.space2
            : stripFrame.minX - width - Design.space2
        let frame = NSRect(x: x, y: centreY - height / 2, width: width, height: height)

        if appearing {
            panel.alphaValue = 0
            // Starts a step closer to the strip and settles outward.
            let towardStrip: CGFloat = onLeft ? -Design.space2 : Design.space2
            panel.setFrame(frame.offsetBy(dx: towardStrip, dy: 0), display: false)
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
                panel.animator().alphaValue = 1
            }
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                // Mild overshoot. The rail's 1.95 would be too much here: the
                // frame's height animates on the same curve, and a card
                // that visibly over-grows reads as a glitch.
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.08)
                panel.animator().setFrame(frame, display: true)
            }
        }
        calloutPanel = panel
    }

    private static let calloutFade = Animation.easeOut(duration: 0.16)

    /// One host for the callout's lifetime; the key changes the identity so
    /// the content crossfades instead of being rebuilt in place.
    struct CalloutRoot: View {
        let key: Int
        let content: AnyView

        var body: some View {
            content
                .id(key)
                .transition(.opacity)
        }
    }

    func hideCallout() {
        Self.trace("hideCallout (panel: \(calloutPanel != nil))")
        calloutPanel?.orderOut(nil)
        calloutPanel = nil
        calloutHovered = false
    }

    /// The callout reports its own hover. Entering it cancels a pending
    /// collapse; leaving it — for anywhere but the strip, which cancels
    /// again on entry — collapses the strip the same way leaving the strip
    /// would, and takes the card with it.
    func setCalloutHovered(_ inside: Bool) {
        Self.trace("calloutHovered(\(inside)) mouse=\(NSEvent.mouseLocation) card=\(calloutPanel?.frame ?? .zero)")
        calloutHovered = inside
        if inside {
            collapseTask?.cancel()
            collapseTask = nil
        } else if let apply = applyExpanded {
            setExpanded(false, apply: apply)
        }
    }

    /// A borderless panel cannot become key, and a click on a window that
    /// cannot become key is spent making it key — which it never becomes —
    /// so the card's buttons swallowed every press. This one can, and being
    /// non-activating, does so without bringing the app forward.
    private final class CalloutPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private func makeCalloutPanel() -> NSPanel {
        let panel = CalloutPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: Self.calloutWidth, height: 40)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Hover and clicks on the card: it holds two buttons now.
        panel.acceptsMouseMovedEvents = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        // It used to ignore the mouse, as a tooltip would. It holds buttons
        // now, and the pointer resting on it is what keeps it open.
        panel.ignoresMouseEvents = false
        return panel
    }

    private func show(store: UsageStore) {
        self.store = store
        guard panel == nil else { return }
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: Self.width, height: 200)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.isMovable = false
        // Borderless panels default to the utility-window behaviour, which adds
        // its own fade on top of ours.
        panel.animationBehavior = .none
        panel.contentView = FirstMouseHostingView(
            rootView: EdgeDockView(store: store, coordinator: self, resets: resets, geometry: geometry))
        self.panel = panel
        layout(expanded: false)
        panel.orderFrontRegardless()
        installMouseTracking()
    }

    /// Whether the strip should sit fully on screen regardless of the pointer.
    var alwaysVisible: Bool { ConfigStore.shared.dockAlwaysVisible }

    /// Re-places the panel after a setting that moves it — the edge, the
    /// position, always-visible. Snapped, not slid: the change came from a
    /// control the user just operated, and the SwiftUI content had already
    /// mirrored itself for the new edge while the window sat where it was,
    /// which read as the setting having done half its job.
    func relayout() {
        guard panel != nil else { return }
        hideCallout()
        layout(expanded: expanded)
        refreshMouseThrough?()
    }

    /// Collapsing is delayed so a pointer crossing the strip on its way
    /// somewhere else does not make it flap open and shut.
    func setExpanded(_ value: Bool, apply: @escaping (Bool) -> Void) {
        collapseTask?.cancel()
        collapseTask = nil
        applyExpanded = apply
        Self.trace("setExpanded(\(value))")
        if value {
            expanded = true
            // The view stages the grow itself: wider, then taller.
            apply(true)
            refreshMouseThrough?()
            return
        }
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(320))
            // The pointer went to the card, not away: stay open.
            guard !Task.isCancelled, self?.calloutHovered != true else { return }
            self?.expanded = false
            apply(false)
            self?.hideCallout()
            self?.refreshMouseThrough?()
        }
    }

    /// The strip is as tall as its contents, so the panel resizes as providers
    /// are enabled or disabled.
    func setContentHeight(_ height: CGFloat) {
        Self.trace("setContentHeight(\(Int(height))) expanded=\(expanded)")
        // On its way out the strip is being squeezed into the handle's frame
        // and reports *that*. Recording it would make the next reveal aim at
        // the handle's height and then correct itself.
        guard expanded || alwaysVisible else { return }
        let count = store?.dockProviders.count ?? 0
        let measured = max(80, height)
        guard measuredHeights[count] != measured else { return }
        measuredHeights[count] = measured
        // Not animated: this fires when a provider is enabled or a refresh
        // changes the row count, and a panel that eases into every such change
        // reads as drift rather than as a response to anything.
        layout(expanded: expanded)
    }

    /// The strip's height is deterministic: `n` rings, the gaps between them
    /// and the vertical padding. Computing it means the reveal can aim at the
    /// right frame *before* the strip has ever been laid out — waiting for a
    /// measurement meant the transition started toward a placeholder height and
    /// was re-aimed four milliseconds later, which is two animations.
    static func computedStripHeight(providers count: Int) -> CGFloat {
        guard count > 0 else { return handleHeight }
        // cellHeight is one ring plus one gap; the last ring has no gap after it.
        return stripInsetTop + stripInsetBottom + CGFloat(count) * cellHeight - Design.space3
    }

    /// Keyed by provider count, so enabling one invalidates the old figure
    /// rather than carrying it over. Seeded by the arithmetic above; the
    /// measurement only corrects it if `ProviderRing` ever changes size.
    private var measuredHeights: [Int: CGFloat] = [:]

    private func stripHeight(providers count: Int) -> CGFloat {
        measuredHeights[count] ?? Self.computedStripHeight(providers: count)
    }
    /// Places the window: always the full strip, flush against the edge and
    /// centred on the handle, held on screen at the extremes. Folding and
    /// unfolding never touch it; only a change of edge, position, screen or
    /// provider count does.
    private func layout(expanded: Bool, animated: Bool = false) {
        guard let panel, let screen = Self.hostScreen else { return }
        let config = ConfigStore.shared
        let visible = screen.visibleFrame
        let panelWidth = Self.width
        // As tall as the rings need, up to the screen less its margins; the
        // rest scrolls inside the strip.
        let panelHeight = min(
            stripHeight(providers: store?.dockProviders.count ?? 0),
            max(Self.handleHeight, visible.height - Self.screenMargin * 2))
        let x = config.dockEdge == .right ? visible.maxX - panelWidth : visible.minX

        // dockPosition is a fraction of the handle's travel from the top;
        // AppKit measures from the bottom. The strip is centred on the handle
        // it grows out of, and kept on screen at the extremes — where the
        // handle then sits off the window's centre, which the view is told.
        let handleTravel = max(0, visible.height - Self.handleHeight)
        let handleY = visible.maxY - Self.handleHeight - handleTravel * CGFloat(config.dockPosition)
        let centred = handleY + Self.handleHeight / 2 - panelHeight / 2
        let y = min(max(centred, visible.minY), visible.maxY - panelHeight)
        let frame = NSRect(x: x, y: y, width: panelWidth, height: panelHeight)

        handleFrame = NSRect(
            x: config.dockEdge == .right ? frame.maxX - Self.handleWidth : frame.minX,
            y: handleY, width: Self.handleWidth, height: Self.handleHeight)
        let offset = frame.midY - (handleY + Self.handleHeight / 2)
        if geometry.handleOffset != offset { geometry.handleOffset = offset }
        Self.trace("layout \(Int(frame.width))x\(Int(frame.height))@\(Int(frame.origin.y)) handleOffset=\(Int(offset))")
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    /// Records where the user dragged the strip to, as a fraction of the
    /// available travel.
    /// Stored as the handle's position, whichever state was dragged: the
    /// handle sits at the strip's centre, so the centre is what is kept.
    func persistPosition() {
        guard let panel, let screen = Self.hostScreen else { return }
        let visible = screen.visibleFrame
        let travel = max(1, visible.height - Self.handleHeight)
        let handleTop = panel.frame.midY + Self.handleHeight / 2
        let fromTop = visible.maxY - handleTop
        ConfigStore.shared.dockPosition = Double(min(max(fromTop / travel, 0), 1))
    }

    func move(byVertical delta: CGFloat) {
        guard let panel, let screen = Self.hostScreen else { return }
        let visible = screen.visibleFrame
        var frame = panel.frame
        frame.origin.y = min(
            max(frame.origin.y - delta, visible.minY),
            visible.maxY - frame.height)
        // Dragged open, the handle travels at the strip's centre.
        handleFrame.origin.y = frame.midY - Self.handleHeight / 2
        geometry.handleOffset = 0
        panel.setFrame(frame, display: true)
    }

    /// The screen the owner chose, else the one holding the menu bar.
    /// `NSScreen.main` follows the key window, which for a menu-bar-only app
    /// can be any display.
    static var hostScreen: NSScreen? {
        ScreenChoice.chosen ?? NSScreen.screens.first ?? NSScreen.main
    }
}

struct EdgeDockView: View {
    @ObservedObject var store: UsageStore
    var coordinator: EdgeDockCoordinator
    @ObservedObject var resets: EdgeDockCoordinator.ResetBridge
    @ObservedObject var geometry: EdgeDockCoordinator.Geometry
    /// The grow in two steps: the capsule widens out of the edge, then the
    /// strip stretches to its full height and the rings arrive.
    @State private var wide = false
    @State private var tall = false
    /// Reaching the edge shows the icons only. A card needs a hover that was
    /// meant: once the strip has finished opening, the pointer has to move
    /// onto a ring — the ring it happened to land on when the strip grew
    /// under it does not count until it moves.
    @State private var armed = false
    @State private var armOrigin: NSPoint?
    @State private var armTask: Task<Void, Never>?
    /// The reset being played, and the figure its ring shows meanwhile — the
    /// reading from before, then animated to the one now.
    @State private var playing: ResetBanner?
    @State private var ringOverride: [ProviderID: Double] = [:]
    @State private var resetTask: Task<Void, Never>?
    @State private var expanded = false
    @State private var hovered: ProviderID?
    /// The ring that was clicked: its card is the full one, with the pin
    /// row, until the strip closes.
    @State private var detail: ProviderID?
    /// Clears `hovered` a beat after the pointer leaves a ring, unless it
    /// turns up on the callout first. Leaving a ring for the card crosses
    /// 14pt of strip and an 8pt gap; cleared at once, the card was gone
    /// before the pointer arrived.
    @State private var hoverClearTask: Task<Void, Never>?
    /// Scrolling, when there are more rings than the screen holds: where the
    /// list is, whether it is moving (the thin indicator brightens while it
    /// is, then fades back), and the ring a reset asks to bring into view.
    @State private var scrollOffset: CGFloat = 0
    @State private var scrolling = false
    @State private var scrollIdleTask: Task<Void, Never>?
    @State private var revealRing: ProviderID?

    private var onLeft: Bool { store.dockEdge == .left }

    /// How far the rings sit toward the screen edge, past the strip's own
    /// centre. A MacBook's display has a black border beyond its last pixel,
    /// and against it the strip reads as that much wider on the edge side;
    /// centred on the strip alone, the rings looked pushed inboard. Half
    /// of a typical border.
    static let edgeBias: CGFloat = 5

    private var isWide: Bool { wide || coordinator.alwaysVisible }
    private var isTall: Bool { tall || coordinator.alwaysVisible }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: onLeft ? .leading : .trailing) {
                // One black shape for both states, grown inside the fixed
                // window: from the handle's 18x92 it widens out of the edge,
                // then stretches to the strip's height. It stays against the
                // edge the whole way — nothing about the window moves.
                Self.dockShape(onLeft: onLeft)
                    .fill(Color.black)
                    .frame(
                        width: isWide ? EdgeDockCoordinator.width : EdgeDockCoordinator.handleWidth,
                        height: isTall ? proxy.size.height : EdgeDockCoordinator.handleHeight)
                    .offset(y: isTall ? 0 : geometry.handleOffset)
                Group {
                    if isTall {
                        // Out of the docked edge as the height arrives, so the
                        // rings come from the screen's side rather than
                        // brightening in place.
                        strip(height: proxy.size.height)
                            .transition(.move(edge: onLeft ? .leading : .trailing).combined(with: .opacity))
                    } else if !isWide {
                        handle
                            .offset(y: geometry.handleOffset)
                            .transition(.opacity)
                    }
                }
                // Fixed at its own size and pinned to the docked edge, so the
                // shape growing around it reveals it instead of reflowing it.
                .fixedSize()
                // Clipped to the shape as it grows: the rings arrive while the
                // height is still stretching, and unclipped they showed above
                // and below the black.
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: onLeft ? .leading : .trailing)
                .mask(alignment: onLeft ? .leading : .trailing) {
                    Self.dockShape(onLeft: onLeft)
                        .frame(
                            width: isWide ? EdgeDockCoordinator.width : EdgeDockCoordinator.handleWidth,
                            height: isTall ? proxy.size.height : EdgeDockCoordinator.handleHeight)
                        .offset(y: isTall ? 0 : geometry.handleOffset)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: onLeft ? .leading : .trailing)
        }
        // The same three actions the menu-bar item offers on its secondary
        // click, so the dock is complete on its own when the menu-bar item
        // is hidden behind the notch.
        .contextMenu {
            Button(L10n.t("Refresh now", "立即刷新")) { store.refreshAll() }
            // Pinned open: the strip stays out instead of folding to the
            // handle. Kept above other windows either way — it is a sliver
            // at the screen's edge, like the Dock, and a strip that could be
            // buried would need to be found again.
            Toggle(L10n.t("Keep open", "锁定显示"), isOn: Binding(
                get: { store.dockAlwaysVisible },
                set: { store.setDockAlwaysVisible($0) }))
            if store.dockPin != nil {
                Button(L10n.t("Show every provider", "显示全部服务商")) { store.setDockPin(nil) }
            }
            let hiddenHere = store.hiddenProviders(on: .dock)
            if !hiddenHere.isEmpty {
                Menu(L10n.t("Hidden from the dock (\(hiddenHere.count))", "已隐藏的服务商（\(hiddenHere.count)）")) {
                    ForEach(hiddenHere) { id in
                        Button(L10n.t("Show \(id.displayName)", "显示 \(id.displayName)")) { store.setHidden(false, id, on: .dock) }
                    }
                }
            }
            Button(L10n.t("Settings…", "设置…")) { SettingsWindow.open() }
            Divider()
            Button(L10n.t("Quit QuotaBar", "退出 QuotaBar")) { NSApp.terminate(nil) }
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: onLeft ? .leading : .trailing)
        // Flat black: glass was tried here and read as grey over light
        // windows (GlassStyle.swift has the numbers); black is what the
        // owner wants. Always dark, like the panel, the island and the widget.
        .environment(\.colorScheme, .dark)
        .onHover { inside in
            coordinator.setExpanded(inside) { expanded = $0 }
            if inside {
                hoverClearTask?.cancel()
            } else {
                scheduleHoverClear()
            }
        }
        .onChange(of: hovered) { _, id in
            presentCallout(for: id)
        }
        .onChange(of: resets.current) { _, banner in
            if let banner { play(banner) }
        }
        .onChange(of: expanded) { _, isOpen in
            stage(isOpen)
            if !isOpen {
                coordinator.hideCallout()
                hovered = nil
                detail = nil
                // Folded, the rings are rebuilt at the top when the strip next
                // opens; kept open, they stay where they were scrolled.
                if !coordinator.alwaysVisible {
                    scrollOffset = 0
                    coordinator.scrollOffset = 0
                }
            }
        }
    }

    /// The edge against the screen is square; the outboard corners take the
    /// island's 14pt, the radius codex-island cuts its notch with. The 20pt
    /// before it read as nearly a semicircle on a strip this narrow, and a
    /// square option was dropped along with it: the owner wanted one shape,
    /// closer to square than that, not a choice.
    static func dockShape(onLeft: Bool) -> UnevenRoundedRectangle {
        let radius: CGFloat = Design.radiusPanel
        return UnevenRoundedRectangle(
            topLeadingRadius: onLeft ? 0 : radius,
            bottomLeadingRadius: onLeft ? 0 : radius,
            bottomTrailingRadius: onLeft ? radius : 0,
            topTrailingRadius: onLeft ? radius : 0,
            style: .continuous)
    }

    private var handle: some View {
        DockHandle(fraction: handleFraction, tint: handleTint, onLeft: onLeft)
    }

    private var handleFraction: CGFloat {
        guard let used = store.headlinePercent else { return 0 }
        return CGFloat(store.meterMode.shownPercent(fromUsed: used) / 100)
    }

    private var handleTint: Color {
        // No reading is not 0% used — 0 is the brightest green on the ramp.
        guard let used = store.headlinePercent else { return .white.opacity(0.35) }
        return Color(hex: UsageRamp.hex(used: used))
    }

    private func presentCallout(for id: ProviderID?) {
        let index = id.flatMap { store.dockProviders.firstIndex(of: $0) }
        let isDetail = id != nil && detail == id
        // Everything that changes the card's height: its data (the tick moves
        // on every refresh), the preferences, the bar style.
        let sizeKey = id.map { "\($0.rawValue)|\(isDetail)|\(store.tick)|\(store.experienceRevision)|\(store.meterStyle.rawValue)|\(store.serviceStatus[$0]?.level.rawValue ?? "")" }
        coordinator.showCallout(
            at: index,
            total: store.dockProviders.count,
            width: isDetail ? EdgeDockCoordinator.detailWidth : EdgeDockCoordinator.calloutWidth,
            sizeKey: sizeKey)
        {
            if let id {
                ProviderCallout(store: store, id: id, detail: isDetail)
                    .onHover { coordinator.setCalloutHovered($0) }
            }
        }
    }

    /// Open: the capsule widens, then the strip stretches tall and the rings
    /// slide in. Shut: the reverse, height first. `QUOTABAR_DOCK_SLIDE`
    /// scales both steps to catch a frame of them.
    private func stage(_ open: Bool) {
        let k = EdgeDockCoordinator.slideDuration / 0.24
        if open {
            if coordinator.alwaysVisible {
                // Nothing grows under the pointer; hovering is already meant.
                armTask?.cancel()
                armOrigin = nil
                armed = true
            } else {
                arm(after: Motion.reduced ? 0.05 : 0.45 * k)
            }
        }
        guard !Motion.reduced else {
            wide = open
            tall = open
            if !open { disarm() }
            return
        }
        if open {
            withAnimation(.easeOut(duration: 0.18 * k)) { wide = true }
            withAnimation(.spring(response: 0.36 * k, dampingFraction: 0.86).delay(0.14 * k)) { tall = true }
        } else {
            disarm()
            withAnimation(.easeInOut(duration: 0.2 * k)) { tall = false }
            withAnimation(.easeIn(duration: 0.16 * k).delay(0.17 * k)) { wide = false }
        }
    }

    /// Cards become available once the strip has opened, measured from where
    /// the pointer was at that moment.
    private func arm(after seconds: Double) {
        armTask?.cancel()
        armTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            armOrigin = NSEvent.mouseLocation
            armed = true
        }
    }

    private func disarm() {
        armTask?.cancel()
        armed = false
        armOrigin = nil
    }

    /// The pointer over a ring: a card only once armed, and only after the
    /// pointer has moved a few points since — so the ring under a pointer
    /// that simply arrived at the edge stays quiet.
    private func ringHover(_ id: ProviderID, _ phase: HoverPhase) {
        switch phase {
        case .active:
            let pinnedOpen = coordinator.alwaysVisible && !expanded
            guard armed || pinnedOpen else { return }
            if let origin = armOrigin {
                let here = NSEvent.mouseLocation
                guard hypot(here.x - origin.x, here.y - origin.y) >= 6 else { return }
                armOrigin = nil
            }
            hoverClearTask?.cancel()
            if hovered != id { hovered = id }
        case .ended:
            if hovered == id { scheduleHoverClear() }
        }
    }

    private func play(_ banner: ResetBanner) {
        resetTask?.cancel()
        let id = banner.provider
        ringOverride[id] = banner.usedBefore
        // Scrolled out of sight, the ring that reset is brought into view
        // while the strip opens, before its card needs lining up with it.
        revealRing = id
        coordinator.setExpanded(true) { expanded = $0 }
        resetTask = Task { @MainActor in
            // Out first — wider, then taller; the fill starts once it has arrived.
            try? await Task.sleep(for: .milliseconds(520))
            guard !Task.isCancelled else { return }
            playing = banner
            withAnimation(Motion.animation(.timingCurve(0.22, 0.9, 0.24, 1, duration: 1.0).delay(0.15))) {
                ringOverride[id] = banner.usedNow
            }
            if hovered == nil, let index = store.dockProviders.firstIndex(of: id) {
                coordinator.showCallout(
                    at: index,
                    total: store.dockProviders.count,
                    width: EdgeDockCoordinator.calloutWidth,
                    sizeKey: "reset|\(banner.id)")
                {
                    ResetCallout(store: store, banner: banner)
                        .onHover { coordinator.setCalloutHovered($0) }
                }
            }
            try? await Task.sleep(for: .milliseconds(3000))
            guard !Task.isCancelled else { return }
            playing = nil
            ringOverride[id] = nil
            resets.current = nil
            // Whoever arrived meanwhile keeps the strip; otherwise it folds.
            if hovered == nil, !coordinator.calloutHovered {
                coordinator.hideCallout()
                coordinator.setExpanded(false) { expanded = $0 }
            }
        }
    }

    private func scheduleHoverClear() {
        hoverClearTask?.cancel()
        hoverClearTask = Task {
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled, !coordinator.calloutHovered else { return }
            hovered = nil
        }
    }

    private var rings: some View {
        VStack(spacing: Design.space3) {
            ForEach(store.dockProviders) { id in
                ProviderRing(
                    id: id,
                    percent: ringOverride[id] ?? store.headlinePercent(for: id),
                    alerts: store.alertSettings,
                    showsLabel: false,
                    selected: store.selected == id,
                    hovered: hovered == id,
                    selectionDot: true)
                    .overlay(alignment: .top) {
                        if playing?.provider == id {
                            ResetSweep(color: id.accent, diameter: ProviderRing.defaultDiameter)
                                .id(playing?.id)
                        }
                    }
                    .scaleEffect(playing?.provider == id && !Motion.reduced ? 1.06 : 1, anchor: .top)
                    .animation(Motion.animation(.spring(response: 0.4, dampingFraction: 0.5)), value: playing?.id)
                    .onContinuousHover { phase in ringHover(id, phase) }
                    .contextMenu {
                        Button(L10n.t("Refresh \(id.displayName)", "刷新 \(id.displayName)")) { store.refresh(id) }
                        Button(L10n.t("Hide from the dock", "在停靠条中隐藏")) { store.setHidden(true, id, on: .dock) }
                        let hiddenHere = store.hiddenProviders(on: .dock)
                        if !hiddenHere.isEmpty {
                            Menu(L10n.t("Hidden from the dock (\(hiddenHere.count))", "已隐藏的服务商（\(hiddenHere.count)）")) {
                                ForEach(hiddenHere) { hidden in
                                    Button(L10n.t("Show \(hidden.displayName)", "显示 \(hidden.displayName)")) { store.setHidden(false, hidden, on: .dock) }
                                }
                            }
                        }
                        Divider()
                        Button(L10n.t("Where each provider shows…", "各处显示的服务商…")) { SettingsWindow.open(section: .presentation) }
                        Button(L10n.t("Settings…", "设置…")) { SettingsWindow.open() }
                    }
                    // Declared before the single tap: SwiftUI resolves the
                    // higher count first only if it is attached first.
                    .onTapGesture(count: 2) {
                        store.selected = id
                        SettingsWindow.open()
                    }
                    .onTapGesture {
                        // Hover is the summary; a click is the full card,
                        // with the pin row; a second click on the same ring
                        // folds it back. Opening a window takes two.
                        detail = detail == id ? nil : id
                        hovered = id
                        presentCallout(for: id)
                    }
            }
        }
        // Toward the edge, by the border's half-width; layout is untouched,
        // so the callout and the strip's frame know nothing of it.
        .offset(x: onLeft ? -Self.edgeBias : Self.edgeBias)
        .padding(.top, EdgeDockCoordinator.stripInsetTop)
        .padding(.bottom, EdgeDockCoordinator.stripInsetBottom)
        .frame(width: EdgeDockCoordinator.width)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onChange(of: proxy.size.height, initial: true) { _, height in
                        coordinator.setContentHeight(height)
                    }
            })
    }

    /// The rings, scrolling when the screen cannot hold them all. The
    /// system's scroller is replaced with a 2pt line on the inboard side:
    /// faint while the list sits still, brighter while it moves. The ends
    /// fade into the black where there is more to scroll to.
    private func strip(height: CGFloat) -> some View {
        let content = EdgeDockCoordinator.computedStripHeight(providers: store.dockProviders.count)
        let overflow = content > height + 1
        let maxOffset = max(1, content - height)
        return ScrollViewReader { reader in
            ScrollView(.vertical) {
                rings.background(ScrollOffsetReader { offset in
                    guard abs(offset - scrollOffset) > 0.5 else { return }
                    scrollOffset = offset
                    coordinator.scrollOffset = offset
                    noteScrolled()
                })
            }
            .scrollIndicators(.never)
            .scrollDisabled(!overflow)
            .frame(width: EdgeDockCoordinator.width, height: height)
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [overflow && scrollOffset > 1 ? .clear : .black, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: Design.space4)
                    Color.black
                    LinearGradient(colors: [.black, overflow && scrollOffset < maxOffset - 1 ? .clear : .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: Design.space4)
                }
            }
            .overlay(alignment: onLeft ? .topTrailing : .topLeading) {
                if overflow {
                    let track = height - Design.space6
                    let thumb = max(Design.space4, track * height / content)
                    let progress = min(max(scrollOffset / maxOffset, 0), 1)
                    Capsule()
                        .fill(Color.white.opacity(scrolling ? 0.4 : 0.14))
                        .frame(width: 2, height: thumb)
                        .offset(x: onLeft ? -3 : 3, y: Design.space3 + (track - thumb) * progress)
                        .animation(Motion.animation(.easeOut(duration: 0.25)), value: scrolling)
                        .allowsHitTesting(false)
                }
            }
            .onChange(of: revealRing, initial: true) { _, id in
                guard let id, overflow else { return }
                withAnimation(Motion.animation(.easeInOut(duration: 0.3))) {
                    reader.scrollTo(id, anchor: .center)
                }
                revealRing = nil
            }
            // Dragging moves the strip; the wheel and the trackpad scroll it.
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { coordinator.move(byVertical: $0.translation.height) }
                    .onEnded { _ in coordinator.persistPosition() })
        }
    }

    /// The card belongs to a ring that has just moved; it goes until the
    /// pointer settles on a ring again.
    private func noteScrolled() {
        if hovered != nil, playing == nil {
            hovered = nil
            coordinator.hideCallout()
        }
        scrolling = true
        scrollIdleTask?.cancel()
        scrollIdleTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            scrolling = false
        }
    }
}

/// How far the scroll view around it is scrolled from the top.
///
/// Read from the NSScrollView itself: on macOS a GeometryReader inside a
/// ScrollView is not re-evaluated as it scrolls, so a preference-based offset
/// sat at zero while the rings moved. Reported on the next turn of the run
/// loop — the scroll that `scrollTo` performs happens during a view update,
/// and state set synchronously from it was dropped.
private struct ScrollOffsetReader: NSViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.onChange = onChange
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) {
        probe.onChange = onChange
    }

    final class Probe: NSView {
        var onChange: ((CGFloat) -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard window != nil, let clip = enclosingScrollView?.contentView else { return }
            clip.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main)
            { [weak self] _ in
                let fromTop = clip.isFlipped
                    ? clip.bounds.origin.y
                    : (clip.documentView.map { $0.frame.height - clip.bounds.maxY } ?? 0)
                DispatchQueue.main.async { self?.onChange?(max(0, fromTop)) }
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}

/// A hosting view that takes the first click. The strip and the card float
/// over other apps and are never key; AppKit spends the first click on a
/// non-key window bringing it forward and hands the view nothing, so a
/// single tap on a ring or a card button had to be made twice.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// What the dock looks like at rest: a slim tab carrying the worst reading, so
/// it is both a target to aim at and worth a glance before it is opened.
struct DockHandle: View {
    let fraction: CGFloat
    let tint: Color
    let onLeft: Bool

    var body: some View {
        ZStack {
            // The black behind this is the dock's own shape, drawn by the
            // container — the handle and the strip share it so the reveal
            // grows one shape instead of dissolving between two.
            // Fills from the bottom against a full-height track. Growing from
            // the centre gave the level nothing to be measured against — the
            // bar's height was the only cue and it read as a floating mark.
            GeometryReader { proxy in
                ZStack(alignment: .bottom) {
                    Capsule()
                        .fill(Color.white.opacity(0.16))
                        .frame(width: 5)
                    Capsule()
                        .fill(tint)
                        .frame(width: 5, height: max(4, proxy.size.height * fraction))
                    // Quarter marks, so the reading is against a scale rather
                    // than estimated off a bare column.
                    VStack(spacing: 0) {
                        ForEach(1..<4) { _ in
                            Spacer(minLength: 0)
                            Rectangle()
                                .fill(Color.black.opacity(0.55))
                                .frame(width: 5, height: 1)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.vertical, 12)
        }
        .frame(
            width: EdgeDockCoordinator.handleWidth,
            height: EdgeDockCoordinator.handleHeight)
    }
}

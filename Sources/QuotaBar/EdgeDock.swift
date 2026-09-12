import AppKit
import SwiftUI
import QuotaCore

/// A strip docked to the right edge of the screen that hides itself until the
/// pointer reaches the edge.
///
/// The panel is always present and always at the edge; hiding is done by
/// sliding it off-screen and leaving a sliver behind. That keeps the reveal
/// entirely inside the panel's own tracking area — no global mouse monitor,
/// which would be a heavier thing to ask of the system for a hover affordance.
@MainActor
final class EdgeDockCoordinator {
    private var panel: NSPanel?
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

    /// One clock for the panel's frame and for the content inside it. They used
    /// to be independent — the content swapped instantly and the frame animated
    /// afterwards — which is what the hitch was.
    /// `QUOTABAR_DOCK_SLIDE=2` stretches the reveal so a frame of it can
    /// actually be caught — at 0.24s a screen capture lands either side of it.
    static let slideDuration: TimeInterval =
        ProcessInfo.processInfo.environment["QUOTABAR_DOCK_SLIDE"]
            .flatMap(Double.init) ?? 0.24
    static var slide: Animation { .easeOut(duration: slideDuration) }

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
        panel?.orderOut(nil)
        panel = nil
        targetFrame = nil
        sliding = false
        hideCallout()
        expanded = false
    }

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
        // rings out from the top, and AppKit measures from the bottom. Against
        // where the strip is *going*, not where it is: the first hover lands
        // on the handle, the strip is still sliding open when the ring reports
        // it, and a card placed against the in-between frame sat well below
        // the ring's centre.
        let stripFrame = targetFrame ?? strip.frame
        // The disc's centre, not the cell's: the cell has the dot row under
        // the disc, so its middle sits 5pt low.
        let centreFromTop = Self.stripInsetTop + CGFloat(index) * Self.cellHeight + ProviderRing.defaultDiameter / 2
        let centreY = stripFrame.maxY - centreFromTop
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
            rootView: EdgeDockView(store: store, coordinator: self))
        self.panel = panel
        layout(expanded: false)
        panel.orderFrontRegardless()
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
        targetFrame = nil
        hideCallout()
        layout(expanded: expanded)
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
            withAnimation(Self.slide) { apply(true) }
            layout(expanded: true, animated: true)
            return
        }
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(320))
            // The pointer went to the card, not away: stay open.
            guard !Task.isCancelled, self?.calloutHovered != true else { return }
            self?.expanded = false
            withAnimation(Self.slide) { apply(false) }
            self?.hideCallout()
            self?.layout(expanded: false, animated: true)
        }
    }

    /// The strip is as tall as its contents, so the panel resizes as providers
    /// are enabled or disabled.
    func setContentHeight(_ height: CGFloat) {
        Self.trace("setContentHeight(\(Int(height))) expanded=\(expanded) sliding=\(sliding)")
        // On its way out the strip is being squeezed into the handle's frame
        // and reports *that*. Recording it would make the next reveal aim at
        // the handle's height and then correct itself.
        guard expanded || alwaysVisible else { return }
        let count = ConfigStore.shared.providers(pinnedTo: ConfigStore.shared.dockPin).count
        let measured = max(80, height)
        guard measuredHeights[count] != measured else { return }
        measuredHeights[count] = measured
        // Never re-aim mid-slide. Four milliseconds into the animation is a
        // second animation, not a correction, and the panel changes course
        // where the user can see it. The measurement above is already recorded,
        // so the next reveal lands on it — the cost is that a provider toggled
        // during the 240ms reveal leaves the strip its old height until then.
        guard !sliding else { return }
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
    /// Where the panel is *going*, which is not `panel.frame` while a slide is
    /// in flight — that reports the in-between value.
    private var targetFrame: NSRect?
    private var sliding = false

    private func layout(expanded: Bool, animated: Bool = false) {
        guard let panel, let screen = Self.hostScreen else { return }
        let config = ConfigStore.shared
        let visible = screen.visibleFrame
        // Always-visible means the full strip, whatever the pointer is doing.
        let out = expanded || config.dockAlwaysVisible

        // Both states sit flush against the edge and are fully on screen; what
        // changes is how wide and tall the panel is.
        let panelWidth = out ? Self.width : Self.handleWidth
        let panelHeight = out
            ? stripHeight(providers: config.providers(pinnedTo: config.dockPin).count)
            : Self.handleHeight
        let x = config.dockEdge == .right
            ? visible.maxX - panelWidth
            : visible.minX

        // dockPosition is a fraction of the handle's travel from the top;
        // AppKit measures from the bottom. The strip is centred on the
        // handle it grows out of — placing it by its own travel put its
        // centre somewhere else at every position but the middle, so the
        // reveal jumped up or down — and is kept on screen at the extremes.
        let handleTravel = max(0, visible.height - Self.handleHeight)
        let handleY = visible.maxY - Self.handleHeight - handleTravel * CGFloat(config.dockPosition)
        let centred = handleY + Self.handleHeight / 2 - panelHeight / 2
        let y = out
            ? min(max(centred, visible.minY), visible.maxY - panelHeight)
            : handleY
        let frame = NSRect(x: x, y: y, width: panelWidth, height: panelHeight)
        let decision = DockSlide.decide(
            target: frame, pending: targetFrame, animated: animated)
        Self.trace(
            "layout animated=\(animated) sliding=\(sliding) "
                + "target=\(Int(frame.width))x\(Int(frame.height))@\(Int(frame.origin.y)) "
                + "pending=\(targetFrame.map { "\(Int($0.width))x\(Int($0.height))@\(Int($0.origin.y))" } ?? "-") "
                + "-> \(decision)")
        switch decision {
        case .skip:
            return
        case let .snap(target):
            targetFrame = target
            panel.setFrame(target, display: true)
            return
        case .animate:
            targetFrame = frame
        }
        // The window is never animated. Animating its frame — even through
        // the animator — repaints a transparent window a step behind its
        // new bounds, and the owner saw that as a blank sliver down the
        // strip's inboard side on every reveal. Instead the window snaps to
        // the larger of the two frames and the black silhouette grows or
        // shrinks *inside* it, on SwiftUI's spring, out of the edge: on the
        // way open the window goes first, on the way shut it goes last.
        // Both frames share a midpoint, so nothing visibly moves at the
        // snap. (`setFrame(_:display:animate:)` was worse still: it blocks
        // the main thread for the whole resize, measured at 341ms.)
        if frame.width >= panel.frame.width {
            sliding = false
            panel.setFrame(frame, display: true)
            Self.trace("snapped open")
        } else {
            sliding = true
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.slideDuration))
                guard let self, self.targetFrame == frame else { return }
                self.sliding = false
                panel.setFrame(frame, display: true)
                Self.trace("snapped shut")
            }
        }
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
        // Dragging writes the frame directly, so the slide's idea of where the
        // panel is headed has to be brought along or the next reveal no-ops.
        targetFrame = frame
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

    private var onLeft: Bool { store.dockEdge == .left }

    /// How far the rings sit toward the screen edge, past the strip's own
    /// centre. A MacBook's display has a black border beyond its last pixel,
    /// and against it the strip reads as that much wider on the edge side;
    /// centred on the strip alone, the rings looked pushed inboard. Half
    /// of a typical border.
    static let edgeBias: CGFloat = 5

    private var showsStrip: Bool { expanded || coordinator.alwaysVisible }

    var body: some View {
        ZStack(alignment: onLeft ? .leading : .trailing) {
            // The silhouette, sized by state rather than by the window: it
            // grows from the handle's 18x92 to the strip's full size on the
            // same spring the content uses, so the reveal is one shape
            // swelling out of the edge. The window has already snapped to
            // the larger frame by then, and shrinks only after this has.
            Self.dockShape(onLeft: onLeft)
                .fill(Color.black)
                .frame(width: showsStrip ? EdgeDockCoordinator.width : EdgeDockCoordinator.handleWidth)
                .frame(maxHeight: showsStrip ? .infinity : EdgeDockCoordinator.handleHeight)
            Group {
                if showsStrip {
                    // Slides in from the docked edge as the silhouette grows,
                    // so the rings come out of the screen's side. A plain
                    // fade put them at their final position at 0% opacity
                    // and brightened them there, which read as the strip
                    // materialising next to the edge rather than emerging
                    // from it.
                    strip.transition(.move(edge: onLeft ? .leading : .trailing).combined(with: .opacity))
                } else {
                    handle.transition(.opacity)
                }
            }
            // Fixed at its own size and pinned to the docked edge, so the
            // silhouette growing around it reveals it instead of reflowing
            // it. Vertically centred because both frames share a midpoint:
            // 18x92 and 74x332 have the same centre.
            .fixedSize()
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
        .onChange(of: expanded) { _, isOpen in
            if !isOpen {
                coordinator.hideCallout()
                hovered = nil
                detail = nil
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

    private func scheduleHoverClear() {
        hoverClearTask?.cancel()
        hoverClearTask = Task {
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled, !coordinator.calloutHovered else { return }
            hovered = nil
        }
    }

    private var strip: some View {
        VStack(spacing: Design.space3) {
            ForEach(store.dockProviders) { id in
                ProviderRing(
                    id: id,
                    percent: store.headlinePercent(for: id),
                    alerts: store.alertSettings,
                    showsLabel: false,
                    selected: store.selected == id,
                    hovered: hovered == id,
                    selectionDot: true)
                    .onHover { inside in
                        if inside {
                            hoverClearTask?.cancel()
                            hovered = id
                        } else if hovered == id {
                            scheduleHoverClear()
                        }
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
        // No background of its own: the container owns the one black shape
        // both states share.
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { coordinator.move(byVertical: $0.translation.height) }
                .onEnded { _ in coordinator.persistPosition() })
        .background(
            GeometryReader { proxy in
                Color.clear.onChange(of: proxy.size.height, initial: true) { _, height in
                    coordinator.setContentHeight(height)
                }
            })

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

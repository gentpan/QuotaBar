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

    static let calloutWidth: CGFloat = 260
    /// One ring plus its label plus the stack spacing.
    static let cellHeight: CGFloat = 78

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
    func showCallout<Content: View>(
        at index: Int?,
        total: Int,
        @ViewBuilder content: () -> Content)
    {
        guard let index, expanded, let strip = panel else {
            hideCallout()
            return
        }
        let host = NSHostingView(rootView: content())
        let size = host.fittingSize
        let panel = calloutPanel ?? makeCalloutPanel()
        panel.contentView = host

        // Line the bubble up with the ring it belongs to. The strip lays its
        // rings out from the top, and AppKit measures from the bottom.
        let stripFrame = strip.frame
        let insetTop = Design.space4
        let centreFromTop = insetTop + CGFloat(index) * Self.cellHeight + Self.cellHeight / 2
        let centreY = stripFrame.maxY - centreFromTop
        let height = max(size.height, 40)
        let x = stripFrame.minX - Self.calloutWidth - Design.space2
        panel.setFrame(
            NSRect(x: x, y: centreY - height / 2, width: Self.calloutWidth, height: height),
            display: true)
        panel.orderFrontRegardless()
        calloutPanel = panel
    }

    func hideCallout() {
        calloutPanel?.orderOut(nil)
        calloutPanel = nil
    }

    private func makeCalloutPanel() -> NSPanel {
        let panel = NSPanel(
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
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        // Purely informational: never take a click that was meant for the
        // window underneath.
        panel.ignoresMouseEvents = true
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
        panel.contentView = NSHostingView(
            rootView: EdgeDockView(store: store, coordinator: self))
        self.panel = panel
        layout(expanded: false)
        panel.orderFrontRegardless()
    }

    /// Whether the strip should sit fully on screen regardless of the pointer.
    var alwaysVisible: Bool { ConfigStore.shared.dockAlwaysVisible }

    /// Collapsing is delayed so a pointer crossing the strip on its way
    /// somewhere else does not make it flap open and shut.
    func setExpanded(_ value: Bool, apply: @escaping (Bool) -> Void) {
        collapseTask?.cancel()
        collapseTask = nil
        Self.trace("setExpanded(\(value))")
        if value {
            expanded = true
            withAnimation(Self.slide) { apply(true) }
            layout(expanded: true, animated: true)
            return
        }
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }
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
        let count = ConfigStore.shared.enabledProviders.count
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
        return Design.space4 * 2 + CGFloat(count) * cellHeight - Design.space3
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
            ? stripHeight(providers: config.enabledProviders.count)
            : Self.handleHeight
        let x = config.dockEdge == .right
            ? visible.maxX - panelWidth
            : visible.minX

        // dockPosition is a fraction from the top; AppKit measures from the
        // bottom, and the panel is kept fully on screen at either extreme.
        let travel = max(0, visible.height - panelHeight)
        let y = visible.maxY - panelHeight - travel * CGFloat(config.dockPosition)
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
        // Not `setFrame(_:display:animate:)`. That one steps the resize on a
        // *blocking* run-loop loop — measured at 341ms of stalled main thread
        // for this size change — and relayouts the hosting view on every step,
        // so the content's own animation cannot run at all while it is going.
        // The animator hands the frame to Core Animation and returns in under
        // a millisecond.
        sliding = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.slideDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(frame, display: true)
        }, completionHandler: {
            MainActor.assumeIsolated {
                self.sliding = false
                Self.trace("slide finished")
            }
        })
    }

    /// Records where the user dragged the strip to, as a fraction of the
    /// available travel.
    func persistPosition() {
        guard let panel, let screen = Self.hostScreen else { return }
        let visible = screen.visibleFrame
        let travel = max(1, visible.height - panel.frame.height)
        let fromTop = visible.maxY - panel.frame.maxY
        ConfigStore.shared.dockPosition = Double(fromTop / travel)
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

    /// The screen holding the menu bar. `NSScreen.main` follows the key window,
    /// which for a menu-bar-only app can be any display.
    static var hostScreen: NSScreen? {
        NSScreen.screens.first ?? NSScreen.main
    }
}

struct EdgeDockView: View {
    @ObservedObject var store: UsageStore
    var coordinator: EdgeDockCoordinator
    @State private var expanded = false
    @State private var hovered: ProviderID?

    @Environment(\.openSettings) private var openSettings

    private var onLeft: Bool { store.dockEdge == .left }

    private var showsStrip: Bool { expanded || coordinator.alwaysVisible }

    var body: some View {
        Group {
            if showsStrip {
                strip.transition(.opacity)
            } else {
                handle.transition(.opacity)
            }
        }
        // Fixed at its own size and pinned to the docked edge, so the panel
        // growing around it reveals it instead of reflowing it. Without this
        // the four rings are laid out again on every frame of the reveal —
        // squeezed into the handle's 92pt at the start and relaxing over the
        // next 240ms, which looks like the content fighting the window.
        // Vertically centred because the panel grows symmetrically about its
        // own centre: 18x92 and 74x332 share a midpoint.
        .fixedSize()
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: onLeft ? .leading : .trailing)
        // One shape for both states, sized to the panel, so the reveal is a
        // single shape growing rather than two shapes of different sizes
        // cross-fading through each other — which looked like the handle and
        // the strip arguing over the same corner. The radius is clamped to the
        // shape it is drawn in, so the same 20pt reads as the panel's corner at
        // 74pt wide and as the handle's pill edge at 18. Dark glass on macOS
        // 26, the flat black it always was below.
        .background(DarkGlassBacking(shape: Self.dockShape(onLeft: onLeft)))
        .onHover { inside in
            coordinator.setExpanded(inside) { expanded = $0 }
            if !inside { hovered = nil }
        }
        .onChange(of: hovered) { _, id in
            presentCallout(for: id)
        }
        .onChange(of: expanded) { _, isOpen in
            if !isOpen { coordinator.hideCallout() }
        }
    }

    static func dockShape(onLeft: Bool) -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: onLeft ? 0 : Design.radiusPanel + 6,
            bottomLeadingRadius: onLeft ? 0 : Design.radiusPanel + 6,
            bottomTrailingRadius: onLeft ? Design.radiusPanel + 6 : 0,
            topTrailingRadius: onLeft ? Design.radiusPanel + 6 : 0,
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
        let index = id.flatMap { store.enabled.firstIndex(of: $0) }
        coordinator.showCallout(at: index, total: store.enabled.count) {
            if let id {
                ProviderCallout(
                    id: id,
                    phase: store.states[id],
                    alerts: store.alertSettings)
            }
        }
    }

    private var strip: some View {
        VStack(spacing: Design.space3) {
            ForEach(store.enabled) { id in
                ProviderRing(
                    id: id,
                    percent: store.states[id]?.snapshot?.headlinePercent,
                    alerts: store.alertSettings,
                    selected: store.selected == id,
                    hovered: hovered == id)
                    .onHover { inside in
                        hovered = inside ? id : (hovered == id ? nil : hovered)
                    }
                    // Declared before the single tap: SwiftUI resolves the
                    // higher count first only if it is attached first.
                    .onTapGesture(count: 2) {
                        store.selected = id
                        openSettings()
                        SettingsWindow.focus()
                    }
                    .onTapGesture {
                        // A single click only points the menu-bar glyph at this
                        // provider. Opening a window is a bigger thing than
                        // choosing what an icon means, so it takes two.
                        store.selected = id
                    }
            }
        }
        .padding(.vertical, Design.space4)
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

import AppKit
import SwiftUI
import QuotaCore

/// Notch-island presentation: a borderless floating panel pinned to the top
/// centre of the screen, over the notch on notched Macs. At rest it is a
/// strip of figures either side of the notch (a pill on other displays);
/// hover and it grows downward into the full panel, after codex-island.
/// The menu-bar item stays as the settings entry point.
@MainActor
final class IslandCoordinator {
    private var panel: NSPanel?
    private var collapseTask: Task<Void, Never>?
    private weak var store: UsageStore?
    private(set) var expanded = false

    /// Room around the silhouette for the glow, after codex-island. The
    /// window is this much wider and taller than the shape; outside the
    /// shape it lets clicks through.
    static let glowMargin: CGFloat = 22

    /// What the view observes that the coordinator decides: a peek request
    /// when a window crosses its warning, whether the island can be seen.
    final class Bridge: ObservableObject {
        @Published var peek = 0
        /// The reset banner on show, if any.
        @Published var banner: ResetBanner?
        @Published var occluded = false
        @Published var page: IslandPanel.Page = .quota
    }

    let bridge = Bridge()
    private var mouseMonitors: [Any] = []
    private var occlusionObserver: NSObjectProtocol?
    private var lastSeverity: AlertLevel = .none
    private var severityBaselined = false
    private var bannerTask: Task<Void, Never>?
    private var bannerShown = false

    /// Windows that just reset: the silhouette grows a row under the notch
    /// that says which, glows green, and folds away after a few seconds.
    /// Nothing happens while the panel is open — its rows say it instead.
    func playReset(_ events: [ResetEvent], store: UsageStore) {
        let shown = events.filter { store.islandProviders.contains($0.provider) }
        guard panel != nil, !expanded, !shown.isEmpty else { return }
        bridge.banner = ResetBanner(events: shown)
        bannerShown = true
        layout(expanded: false, animated: true)
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.dismissBanner()
        }
    }

    private func dismissBanner() {
        bannerTask?.cancel()
        bannerTask = nil
        guard bannerShown else { return }
        bannerShown = false
        bridge.banner = nil
        if !expanded { layout(expanded: false, animated: true) }
    }

    func sync(store: UsageStore) {
        if store.presentation == .island {
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
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        panel?.orderOut(nil)
        panel = nil
        expanded = false
    }

    /// Opens the island for a few seconds when a tracked window newly
    /// crosses its warning line — unless it is already open.
    func noteSeverity(_ severity: AlertLevel, enabled: Bool) {
        defer { lastSeverity = severity }
        // What is already past its line at launch is the baseline, not news.
        guard severityBaselined else { severityBaselined = true; return }
        guard enabled, panel != nil, severity > lastSeverity, severity != .none, !expanded else { return }
        bridge.peek &+= 1
    }

    private func show(store: UsageStore) {
        guard panel == nil else { return }
        self.store = store
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size(expanded: false, store: store)),
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
        panel.animationBehavior = .none
        let host = IslandHostingView(rootView: IslandView(store: store, coordinator: self, bridge: bridge))
        host.coordinator = self
        // The frame is ours; the content fills whatever it is given.
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel
        layout(expanded: false, animated: false)
        panel.orderFrontRegardless()
        installMouseTracking()
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main)
        { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                self.bridge.occluded = !panel.occlusionState.contains(.visible)
            }
        }
    }

    /// The silhouette in window coordinates: the window minus the glow margin.
    func silhouetteContains(screenPoint point: NSPoint) -> Bool {
        guard let panel else { return false }
        let frame = panel.frame
        let margin = Self.glowMargin
        let shape = NSRect(x: frame.minX + margin, y: frame.minY + margin, width: frame.width - margin * 2, height: frame.height - margin)
        return shape.contains(point)
    }

    /// Click-through outside the shape: the margin that holds the glow must
    /// not swallow clicks meant for the menu bar or the window beneath.
    private func installMouseTracking() {
        let update: () -> Void = { [weak self] in
            guard let self, let panel = self.panel else { return }
            let inside = self.silhouetteContains(screenPoint: NSEvent.mouseLocation)
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
    }

    /// Re-places the panel after a setting changed the strip's width.
    func relayout() {
        guard panel != nil else { return }
        layout(expanded: expanded, animated: false)
    }

    /// Collapsing is delayed so a quick pointer sweep across the strip does
    /// not make the panel flicker open and shut.
    func requestExpanded(_ value: Bool, apply: @escaping (Bool) -> Void) {
        collapseTask?.cancel()
        collapseTask = nil
        if value {
            if bannerShown {
                bannerTask?.cancel()
                bannerShown = false
                bridge.banner = nil
            }
            expanded = true
            apply(true)
            layout(expanded: true, animated: true)
            return
        }
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.expanded = false
            apply(false)
            self?.layout(expanded: false, animated: true)
        }
    }

    /// Anchored at the top centre, so the panel grows downward out of the
    /// notch. `animator()`, never `setFrame(animate:)`, which blocks the main
    /// thread for the whole animation.
    func layout(expanded: Bool, animated: Bool) {
        guard let panel, let screen = Self.hostScreen, let store else { return }
        let shape = !expanded && bannerShown ? Self.bannerSize(store: store) : Self.size(expanded: expanded, store: store)
        let margin = Self.glowMargin
        let size = NSSize(width: shape.width + margin * 2, height: shape.height + margin)
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height)
        guard animated else {
            panel.setFrame(frame, display: true)
            return
        }
        let growing = expanded || bannerShown
        NSAnimationContext.runAnimationGroup { context in
            // The banner opens like the Dynamic Island, with a clear rebound;
            // the panel keeps its touch of overshoot.
            context.duration = bannerShown && !expanded ? 0.52 : (growing ? 0.34 : 0.3)
            context.timingFunction = bannerShown && !expanded
                ? CAMediaTimingFunction(controlPoints: 0.34, 1.36, 0.64, 1)
                : growing
                    ? CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.04)
                    : CAMediaTimingFunction(controlPoints: 0.5, 0, 0.2, 1)
            panel.animator().setFrame(frame, display: true)
        }
    }

    /// The screen the owner chose; else the built-in display that actually
    /// has a notch; else the screen holding the menu bar. `NSScreen.main`
    /// follows the key window, which for a menu-bar-only app can be any
    /// display.
    static var hostScreen: NSScreen? {
        ScreenChoice.chosen
            ?? NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
            ?? NSScreen.screens.first
            ?? NSScreen.main
    }

    static func size(expanded: Bool, store: UsageStore) -> NSSize {
        let slots = store.islandSlots
        let notch = notchMetrics()
        if expanded {
            // Rows per column: the left column is the fuller one.
            let rows = min(slots, max(1, store.islandProviders.count))
            return NSSize(
                width: IslandPanelLayout.width(notchWidth: notch?.notchWidth),
                height: IslandPanelLayout.height(rows: rows, notch: notch?.height ?? 0))
        }
        if let notch {
            return NSSize(width: notch.totalWidth(slots: slots), height: notch.height)
        }
        return NSSize(width: 220, height: 40)
    }

    /// The strip with the reset banner hanging under it.
    static func bannerSize(store: UsageStore) -> NSSize {
        let collapsed = size(expanded: false, store: store)
        return NSSize(width: max(collapsed.width, 400), height: collapsed.height + ResetBannerRow.height)
    }

    /// Where the notch is, and how much room sits either side of it.
    struct NotchMetrics {
        let notchWidth: CGFloat
        let height: CGFloat

        /// One slot is "5d 17h · 70%" and a mark; two are a mark and a
        /// figure each; three need a little more. Kept narrow enough to stay
        /// in the dead zone — past this the strip starts covering the app's
        /// own menus on the left and the status items on the right.
        func sideWidth(slots: Int) -> CGFloat {
            switch slots {
            case ...1: 132
            case 2: 132
            default: 176
            }
        }

        func totalWidth(slots: Int) -> CGFloat { notchWidth + sideWidth(slots: slots) * 2 }

        var sideWidth: CGFloat { sideWidth(slots: 1) }
        var totalWidth: CGFloat { totalWidth(slots: 1) }
    }

    /// nil on a screen with no notch, which is most external displays. The
    /// caller falls back to the pill; a strip built around a zero-width notch
    /// would just be a centred bar sitting on top of the menu bar's own items.
    static func notchMetrics() -> NotchMetrics? {
        guard let screen = hostScreen else { return nil }
        let height = screen.safeAreaInsets.top
        guard height > 0,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea
        else { return nil }
        let notch = screen.frame.width - left.width - right.width
        guard notch > 40 else { return nil }
        return NotchMetrics(notchWidth: notch, height: height)
    }
}

// MARK: - View

struct IslandView: View {
    @ObservedObject var store: UsageStore
    var coordinator: IslandCoordinator
    @ObservedObject var bridge: IslandCoordinator.Bridge
    @State private var expanded = false
    /// The panel's content fades in a beat after the silhouette starts to
    /// grow, and is gone before it starts to shrink — the shape is the
    /// animation, the content arrives in it.
    @State private var contentVisible = false
    @State private var hovering = false
    @State private var peekTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .top) {
            if store.experience.islandGlow {
                IslandGlow(
                    shape: silhouette,
                    color: glowColor,
                    ambient: !store.experience.lowPowerGlow || glowEvent,
                    sweeping: !bridge.occluded && (!store.experience.lowPowerGlow || glowEvent) && !Motion.reduced,
                    expanded: expanded)
            }
            silhouette.fill(Color.black)
            if expanded {
                IslandPanel(store: store, notch: notchMetrics, bridge: bridge)
                    .opacity(contentVisible ? 1 : 0)
                    .offset(y: contentVisible ? 0 : -8)
                    .allowsHitTesting(contentVisible)
            } else if let notch = notchMetrics {
                VStack(spacing: 0) {
                    NotchStrip(store: store, metrics: notch, slots: store.islandSlots)
                    if let banner = bridge.banner {
                        ResetBannerRow(banner: banner).id(banner.id)
                    }
                }
            } else {
                VStack(spacing: 0) {
                    compactPill
                    if let banner = bridge.banner {
                        ResetBannerRow(banner: banner).id(banner.id)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(silhouette)
        .onHover { inside in
            hovering = inside
            peekTask?.cancel()
            setExpanded(inside)
        }
        .padding(.horizontal, IslandCoordinator.glowMargin)
        .padding(.bottom, IslandCoordinator.glowMargin)
        .onChange(of: bridge.peek) { _, _ in
            // A window just crossed its warning: open for four seconds, then
            // close again unless the pointer has arrived meanwhile.
            setExpanded(true)
            peekTask?.cancel()
            peekTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled, !hovering else { return }
                setExpanded(false)
            }
        }
        .environment(\.colorScheme, .dark)
        .honoursReducedMotion()
    }

    private func setExpanded(_ value: Bool) {
        coordinator.requestExpanded(value) { value in
            expanded = value
            if value {
                withAnimation(Motion.animation(.easeOut(duration: 0.22).delay(0.1))) { contentVisible = true }
            } else {
                withAnimation(Motion.animation(.easeOut(duration: 0.12))) { contentVisible = false }
            }
        }
    }

    /// Under low power the glow shows only while something is happening.
    private var glowEvent: Bool {
        hovering || bridge.banner != nil || store.enabled.contains { store.isLoading($0) } || store.isComputingCost || severity != .none
    }

    private var severity: AlertLevel {
        store.islandProviders.compactMap { store.headlinePercent(for: $0) }
            .map { store.alertSettings.level(for: $0) }
            .max() ?? .none
    }

    /// Cobalt at rest; amber or red when a tracked window is past its line.
    private var glowColor: Color {
        if let banner = bridge.banner { return banner.provider.accent }
        switch severity {
        case .none: return Palette.cobalt
        case .warning: return Palette.amber
        case .critical: return Palette.red
        }
    }

    /// Read per render rather than captured at construction: the app survives
    /// the display arrangement changing under it, and the strip only exists on
    /// a notched screen.
    private var notchMetrics: IslandCoordinator.NotchMetrics? {
        IslandCoordinator.notchMetrics()
    }

    /// Flat against the screen's top edge, 14pt at the bottom corners — the
    /// notch's own curve, and codex-island's.
    private var silhouette: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: 14,
            bottomTrailingRadius: 14,
            topTrailingRadius: 0,
            style: .continuous)
    }

    // MARK: Compact pill (no notch)

    private var compactPill: some View {
        HStack(spacing: Design.space2 + 2) {
            ZStack {
                Circle().fill(Design.accent)
                Text("Q")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(Design.ink)
            }
            .frame(width: 20, height: 20)

            ForEach(store.islandProviders.prefix(3)) { id in
                if let used = store.headlinePercent(for: id) {
                    // Same glanceable role as the menu-bar glyph, so it follows
                    // the same remaining/used preference.
                    let shown = store.meterMode.shownPercent(fromUsed: used)
                    HStack(spacing: Design.space1) {
                        ProviderGlyph(id: id, size: 13, tint: .white)
                        Text("\(Int(shown.rounded()))%")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    }
                    .foregroundStyle(.white)
                } else if let balance = store.balanceFigure(for: id) {
                    HStack(spacing: Design.space1) {
                        ProviderGlyph(id: id, size: 13, tint: .white)
                        Text(balance)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    }
                    .foregroundStyle(.white)
                }
            }
            Spacer(minLength: 0)
            LiveDot(level: store.alertLevel, warn: !store.failingProviders.isEmpty)
        }
        .padding(.horizontal, Design.space3)
        .frame(height: 40)
    }
}

// MARK: - Reset banner

/// The row under the notch when a window resets: a small ring filling in the
/// provider's colour round its mark, "Limit reset" and which window, and
/// what is left counting up to the new figure.
struct ResetBannerRow: View {
    static let height: CGFloat = 60
    let banner: ResetBanner
    var settled = false
    @State private var arrived: Bool

    init(banner: ResetBanner, settled: Bool = false) {
        self.banner = banner
        self.settled = settled
        _arrived = State(initialValue: settled)
    }

    var body: some View {
        HStack(spacing: Design.space3) {
            ZStack {
                RefillRing(color: banner.provider.accent, from: banner.leftBefore / 100, to: banner.leftNow / 100, lineWidth: 3, delay: 0.5, settled: settled)
                ProviderGlyph(id: banner.provider, size: 17, tint: .white)
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.t("Limit reset", "额度已重置"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(banner.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)
            }
            Spacer(minLength: Design.space2)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                CountUpNumber(from: banner.leftBefore, to: banner.leftNow, delay: 0.55, settled: settled)
                    .font(.system(size: 24, weight: .semibold, design: .monospaced))
                    .foregroundStyle(banner.provider.accent)
                Text(L10n.t("% left", "% 可用"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
            }
        }
        .padding(.horizontal, Design.space4 + 4)
        .frame(height: Self.height)
        .opacity(arrived ? 1 : 0)
        .offset(y: arrived ? 0 : -8)
        .onAppear {
            guard !settled else { return }
            withAnimation(Motion.animation(.easeOut(duration: 0.3).delay(0.22))) { arrived = true }
        }
    }
}

/// Alert indicator dot for the compact pill.
struct LiveDot: View {
    let level: AlertLevel
    var warn: Bool = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .help(warn ? L10n.t("A provider is not updating", "有服务商未能更新") : level.displayName)
    }

    private var color: Color {
        if let hex = level.hex { return Color(hex: hex) }
        return warn ? .orange : Design.accent
    }
}

// MARK: - Notch strip

/// The collapsed island on a notched Mac: the figures sit in the dead space
/// either side of the notch instead of in a pill beside it.
///
/// The two sides are mirrored — the figure is always on the outer edge and the
/// mark always against the notch — so the pair reads outward from the middle
/// rather than left-to-right across a gap you cannot draw in. With one slot a
/// side, the slot also carries the reset countdown; with two or three, each
/// is a mark and a figure, nearest the notch first, in the order enabled.
struct NotchStrip: View {
    @ObservedObject var store: UsageStore
    let metrics: IslandCoordinator.NotchMetrics
    var slots: Int = 1

    private var left: [ProviderID] { Array(store.islandProviders.prefix(slots)) }
    private var right: [ProviderID] { Array(store.islandProviders.dropFirst(slots).prefix(slots)) }

    var body: some View {
        HStack(spacing: 0) {
            side(left, mirrored: true)
                .frame(width: metrics.sideWidth(slots: slots))
            // The notch itself. Painted black like the rest so the strip reads
            // as one shape continuous with the hardware, not two tabs.
            Color.black.frame(width: metrics.notchWidth)
            side(right, mirrored: false)
                .frame(width: metrics.sideWidth(slots: slots))
        }
        .frame(height: metrics.height)
    }

    @ViewBuilder
    private func side(_ ids: [ProviderID], mirrored: Bool) -> some View {
        if slots <= 1 {
            NotchSlot(store: store, id: ids.first, mirrored: mirrored)
        } else {
            HStack(spacing: Design.space2 + 2) {
                // Nearest the notch first: the left side is laid out in
                // reverse so its first provider sits against the middle.
                ForEach(mirrored ? ids.reversed() : ids) { id in
                    NotchMiniSlot(store: store, id: id)
                }
            }
            .padding(.horizontal, Design.space2 + 2)
            .frame(maxWidth: .infinity, alignment: mirrored ? .trailing : .leading)
        }
    }
}

/// Mark and figure, and nothing else: what fits when a side holds two or
/// three providers.
struct NotchMiniSlot: View {
    @ObservedObject var store: UsageStore
    let id: ProviderID

    var body: some View {
        HStack(spacing: 4) {
            ProviderGlyph(id: id, size: 13, tint: Color(hex: id.accentHex))
            if let used = store.headlinePercent(for: id) {
                let shown = store.meterMode.shownPercent(fromUsed: used)
                Text("\(Int(shown.rounded()))%")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color(hex: id.accentHex))
            } else if let balance = store.balanceFigure(for: id) {
                // A balance has no percentage; its amount is the reading.
                Text(balance)
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color(hex: id.accentHex))
            } else {
                Text("—")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
    }
}

struct NotchSlot: View {
    @ObservedObject var store: UsageStore
    let id: ProviderID?
    let mirrored: Bool

    var body: some View {
        HStack(spacing: 5) {
            if mirrored {
                figure
                separator
                tick
                glyph
            } else {
                glyph
                tick
                separator
                figure
            }
        }
        .padding(.horizontal, Design.space2 + 2)
        .frame(maxWidth: .infinity, alignment: mirrored ? .trailing : .leading)
    }

    // MARK: Pieces

    @ViewBuilder
    private var glyph: some View {
        if let id {
            // The mark in the brand colour, the same one the figure wears, so
            // each side of the notch reads as one thing in one colour. `tint`
            // only reaches the monochrome marks: Claude stays terracotta and
            // Gemini four-colour either way; Codex turns from white to blue.
            ProviderGlyph(id: id, size: 14, tint: Color(hex: id.accentHex))
        }
    }

    @ViewBuilder
    private var figure: some View {
        if let id, let percent = shownPercent {
            Text("\(Int(percent.rounded()))%")
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                // Raw brand colour: every accent is required to clear 4.5:1 on
                // black, asserted in ProviderRegistryTests.
                .foregroundStyle(Color(hex: id.accentHex))
        } else if id != nil {
            Text("—")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
        }
    }

    @ViewBuilder
    private var tick: some View {
        if let resetsAt {
            Text(QuotaFormat.tick(to: resetsAt))
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    @ViewBuilder
    private var separator: some View {
        if resetsAt != nil, shownPercent != nil {
            Text("·").foregroundStyle(.white.opacity(0.3))
        }
    }

    // MARK: Data

    private var snapshot: UsageSnapshot? {
        guard let id else { return nil }
        return store.states[id]?.snapshot
    }

    /// Follows the same remaining/used preference as the menu-bar glyph — both
    /// are the same glanceable role and disagreeing would be a bug report.
    private var shownPercent: Double? {
        id.flatMap { store.headlinePercent(for: $0) }.map { store.meterMode.shownPercent(fromUsed: $0) }
    }

    private var resetsAt: Date? {
        id.flatMap { store.headlineWindow(for: $0) }?.resetsAt
    }
}


// MARK: - Glow

/// codex-island's halo: a soft coloured shadow round the silhouette and a
/// light that orbits its outline. Cobalt at rest, amber or red past the
/// alert lines; the sweep pauses when nobody can see the island.
struct IslandGlow: View {
    let shape: UnevenRoundedRectangle
    let color: Color
    /// Halo on.
    let ambient: Bool
    /// Orbiting light on.
    let sweeping: Bool
    let expanded: Bool

    var body: some View {
        ZStack {
            if sweeping {
                TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                    let rotation = (context.date.timeIntervalSinceReferenceDate * 100).truncatingRemainder(dividingBy: 360)
                    shape
                        .stroke(
                            AngularGradient(
                                gradient: Gradient(stops: [
                                    .init(color: .clear, location: 0),
                                    .init(color: color.opacity(0), location: 0.55),
                                    .init(color: color, location: 0.78),
                                    .init(color: .white.opacity(0.95), location: 0.92),
                                    .init(color: color.opacity(0), location: 1),
                                ]),
                                center: .center,
                                angle: .degrees(rotation)),
                            lineWidth: 4)
                        .blur(radius: 3)
                }
            }
            shape
                .fill(Color.black)
                .shadow(color: color.opacity(ambient ? 0.35 : 0), radius: 14)
                .shadow(color: expanded ? .black.opacity(0.5) : .clear, radius: 20, y: 10)
        }
        .animation(.easeInOut(duration: 0.45), value: color)
        .animation(.easeInOut(duration: 0.25), value: ambient)
        .allowsHitTesting(false)
    }
}

/// Hosts the island: first click counts, and a two-finger horizontal swipe
/// (or shift-scroll) turns the open panel's pages.
final class IslandHostingView<Content: View>: NSHostingView<Content> {
    weak var coordinator: IslandCoordinator?
    private var swipeX: CGFloat = 0

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func scrollWheel(with event: NSEvent) {
        guard let coordinator, coordinator.expanded else { return super.scrollWheel(with: event) }
        let horizontal = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : (event.modifierFlags.contains(.shift) ? event.scrollingDeltaY : 0)
        switch event.phase {
        case .began: swipeX = 0
        case .changed: swipeX += horizontal
        case .ended:
            if abs(swipeX) > 40 { coordinator.turnPage(swipeX < 0 ? 1 : -1) }
            swipeX = 0
        default:
            if event.phase.isEmpty, abs(horizontal) > 2 { coordinator.turnPage(horizontal < 0 ? 1 : -1) }
        }
    }
}

extension IslandCoordinator {
    func turnPage(_ step: Int) {
        let pages = IslandPanel.Page.allCases
        guard let index = pages.firstIndex(of: bridge.page) else { return }
        let next = min(max(index + step, 0), pages.count - 1)
        guard next != index else { return }
        if pages[next] != .quota { store?.wantLedger() }
        withAnimation(Motion.animation(Motion.pageSwipe)) { bridge.page = pages[next] }
    }
}

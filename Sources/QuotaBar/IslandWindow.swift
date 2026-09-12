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
        panel?.orderOut(nil)
        panel = nil
        expanded = false
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
        let host = FirstMouseHostingView(rootView: IslandView(store: store, coordinator: self))
        // The frame is ours; the content fills whatever it is given.
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel
        layout(expanded: false, animated: false)
        panel.orderFrontRegardless()
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
        let size = Self.size(expanded: expanded, store: store)
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height)
        guard animated else {
            panel.setFrame(frame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = expanded ? 0.34 : 0.26
            // A touch of overshoot on the way open, like the dock's callout.
            context.timingFunction = expanded
                ? CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.04)
                : CAMediaTimingFunction(name: .easeInEaseOut)
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
    @State private var expanded = false
    /// The panel's content fades in a beat after the silhouette starts to
    /// grow, and is gone before it starts to shrink — the shape is the
    /// animation, the content arrives in it.
    @State private var contentVisible = false

    var body: some View {
        ZStack(alignment: .top) {
            silhouette.fill(Color.black)
            if expanded {
                IslandPanel(store: store, notch: notchMetrics)
                    .opacity(contentVisible ? 1 : 0)
                    .offset(y: contentVisible ? 0 : -8)
                    .allowsHitTesting(contentVisible)
            } else if let notch = notchMetrics {
                NotchStrip(store: store, metrics: notch, slots: store.islandSlots)
            } else {
                compactPill
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onHover { hovering in
            coordinator.requestExpanded(hovering) { value in
                expanded = value
                if value {
                    withAnimation(.easeOut(duration: 0.22).delay(0.1)) { contentVisible = true }
                } else {
                    withAnimation(.easeOut(duration: 0.12)) { contentVisible = false }
                }
            }
        }
        .environment(\.colorScheme, .dark)
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
                }
            }
            Spacer(minLength: 0)
            LiveDot(level: store.alertLevel, warn: !store.failingProviders.isEmpty)
        }
        .padding(.horizontal, Design.space3)
        .frame(height: 40)
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

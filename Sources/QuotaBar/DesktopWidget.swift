import AppKit
import SwiftUI
import QuotaCore

/// A card that lives on the desktop, independent of the menu bar.
///
/// Sits at desktop level by default — above the wallpaper and icons, below
/// every window. That is what makes it a widget rather than an overlay: it is
/// there when you clear the screen, and out of the way when you do not.
@MainActor
final class DesktopWidgetCoordinator {
    private var panel: NSPanel?
    private var lastSize = NSSize(width: 240, height: 160)

    func sync(store: UsageStore) {
        if store.widgetEnabled {
            show(store: store)
            applyLevel()
            // The screen may have changed under it.
            reposition()
        } else {
            hide()
        }
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    private func show(store: UsageStore) {
        guard panel == nil else { return }
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: lastSize),
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
        panel.contentView = NSHostingView(
            rootView: DesktopWidgetView(store: store, coordinator: self))
        self.panel = panel
        applyLevel()
        reposition()
        panel.orderFrontRegardless()
    }

    private func applyLevel() {
        guard let panel else { return }
        panel.level = ConfigStore.shared.widgetAlwaysOnTop
            ? .floating
            // Just above the desktop icons, so the widget is part of the
            // desktop rather than something floating over the work.
            : NSWindow.Level(Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
    }

    func setContentSize(_ size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        lastSize = NSSize(width: size.width, height: size.height)
        reposition()
    }

    /// Places the card from the stored fractions, keeping it fully on screen.
    func reposition() {
        guard let panel, let screen = EdgeDockCoordinator.hostScreen else { return }
        let visible = screen.visibleFrame
        let origin = ConfigStore.shared.widgetOrigin
        let x = visible.minX + (visible.width - lastSize.width) * CGFloat(origin.x)
        // Stored top-down; AppKit measures from the bottom.
        let y = visible.maxY - lastSize.height - (visible.height - lastSize.height) * CGFloat(origin.y)
        panel.setFrame(NSRect(x: x, y: y, width: lastSize.width, height: lastSize.height),
                       display: true)
    }

    func move(by translation: CGSize) {
        guard let panel, let screen = EdgeDockCoordinator.hostScreen else { return }
        let visible = screen.visibleFrame
        var frame = panel.frame
        frame.origin.x = min(max(frame.origin.x + translation.width, visible.minX),
                             visible.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y - translation.height, visible.minY),
                             visible.maxY - frame.height)
        panel.setFrame(frame, display: true)
    }

    func persistPosition() {
        guard let panel, let screen = EdgeDockCoordinator.hostScreen else { return }
        let visible = screen.visibleFrame
        let travelX = max(1, visible.width - panel.frame.width)
        let travelY = max(1, visible.height - panel.frame.height)
        ConfigStore.shared.widgetOrigin = (
            x: Double((panel.frame.minX - visible.minX) / travelX),
            y: Double((visible.maxY - panel.frame.maxY) / travelY))
    }
}

struct DesktopWidgetView: View {
    @ObservedObject var store: UsageStore
    var coordinator: DesktopWidgetCoordinator
    @State private var dragging = false

    private var density: WidgetDensity { store.widgetDensity }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.space3) {
            header
            if store.widgetProviders.isEmpty {
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
        .scaleEffect(dragging ? 1.02 : 1)
        .animation(.easeOut(duration: 0.12), value: dragging)
        .fixedSize()
        .background(
            GeometryReader { proxy in
                Color.clear.onChange(of: proxy.size, initial: true) { _, size in
                    coordinator.setContentSize(size)
                }
            })
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged {
                    dragging = true
                    coordinator.move(by: $0.translation)
                }
                .onEnded { _ in
                    dragging = false
                    coordinator.persistPosition()
                })
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
        store.widgetProviders.compactMap { store.states[$0]?.snapshot?.fetchedAt }.max()
    }

    @ViewBuilder
    private var content: some View {
        switch density {
        case .compact:
            HStack(spacing: Design.space3) {
                ForEach(store.widgetProviders) { id in
                    ProviderRing(
                        id: id,
                        percent: percent(id),
                        alerts: store.alertSettings,
                        diameter: 34,
                        showsLabel: false)
                }
            }
        case .standard:
            HStack(alignment: .top, spacing: Design.space4 - 2) {
                ForEach(store.widgetProviders) { id in
                    ProviderRing(
                        id: id,
                        percent: percent(id),
                        alerts: store.alertSettings,
                        diameter: 40)
                }
            }
        case .detailed:
            VStack(alignment: .leading, spacing: Design.space3) {
                ForEach(store.widgetProviders) { id in
                    detailRow(id)
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
                alerts: store.alertSettings,
                diameter: 32,
                showsLabel: false)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(id.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                    Spacer()
                    Text(percent(id).map { QuotaFormat.percent($0) } ?? "—")
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
                            percent: window.usedPercent,
                            tint: window.usedPercent.map(tint) ?? .clear,
                            style: store.meterStyle,
                            height: 4,
                            track: Color.white.opacity(0.15))
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

    private func tint(_ percent: Double) -> Color {
        return Color(hex: UsageRamp.hex(used: percent))
    }
}

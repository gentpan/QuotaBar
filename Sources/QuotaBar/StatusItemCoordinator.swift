import AppKit
import Combine
import QuotaCore

/// The menu-bar item.
///
/// AppKit rather than `MenuBarExtra`: a click opens the menu panel — gone in
/// 0.4, back in 0.5 with only the numbers people check — and SwiftUI's item
/// could only hang a menu or a popover off its primary click. The secondary
/// click keeps refresh, settings and quit.
@MainActor
final class StatusItemCoordinator: NSObject {
    private var item: NSStatusItem?
    private weak var store: UsageStore?
    private var subscriptions = Set<AnyCancellable>()
    private var lastImageKey = ""
    /// True while the glyph plays a reset; the store's renders wait.
    private var celebrating = false

    /// Runs after every store change, on the main queue. The presentation
    /// coordinators hang off it, the way they hung off the SwiftUI label's
    /// `onChange` modifiers before.
    var onStoreChange: (() -> Void)?

    /// The item's button, for anchoring the panel when it opens by shortcut.
    var button: NSStatusBarButton? { item?.isVisible == true ? item?.button : nil }

    func start(store: UsageStore) {
        self.store = store
        // One turn after applicationDidFinishLaunching, not inside it. Created
        // synchronously there, the item's window existed but was never placed
        // — it reported a frame of (0, 0, 38, 0) and drew nowhere. Deferred,
        // the same code lands in the menu bar; a minimal app does not need
        // the deferral, so whatever else this app does at launch is involved.
        // The self-check below covers the case where it happens anyway.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak store] in
            guard let self, let store else { return }
            self.install(store: store, attempt: 1)
        }
    }

    private func install(store: UsageStore, attempt: Int) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = L10n.t("QuotaBar — click for usage, right-click for the menu", "QuotaBar — 点击查看用量，右键打开菜单")
        }
        self.item = item
        render()
        subscriptions.removeAll()
        // `objectWillChange` fires before the mutation lands; one hop to the
        // main queue and the render reads the new values.
        store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.render()
                self?.onStoreChange?()
            }
            .store(in: &subscriptions)

        // Self-check: an item the menu bar never placed has a zero-height
        // window. Rebuild it once rather than run for a day with no icon.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak store, weak item] in
            guard let self, let store, let item, self.item === item else { return }
            let frame = item.button?.window?.frame ?? .zero
            EdgeDockCoordinator.trace("status item: attempt \(attempt) window=\(frame)")
            guard frame.height < 1, attempt < 2 else { return }
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
            self.lastImageKey = ""
            self.install(store: store, attempt: attempt + 1)
        }
    }

    /// Re-renders only when an input changed. The store publishes on every
    /// tick, and swapping an identical image every 30 seconds is a flicker
    /// waiting to happen.
    private func render() {
        guard !celebrating, let store, let item, let button = item.button else { return }
        let stripItems = Self.stripItems(store)
        let key = "\(store.menuBarIconMode.rawValue)|\(stripItems.map { "\($0.id.rawValue)\($0.percent ?? -1)" })|\(store.meterReading)|\(store.menuBarStyle.rawValue)|\(store.alertLevel)|\(store.meterMode.rawValue)|\(store.isPrivacyMasked)"
        guard key != lastImageKey else { return }
        lastImageKey = key
        switch store.menuBarIconMode {
        case .hidden:
            // Gone from the bar; the dock's and island's menus, and opening
            // the app again, are the ways back to Settings.
            item.isVisible = false
        case .logo:
            item.isVisible = true
            button.image = MenuBarIcon.appMark()
        case .text where !store.isPrivacyMasked:
            item.isVisible = true
            button.image = MenuBarIcon.strip(stripItems) ?? MenuBarIcon.appMark()
        case .meter where store.isPrivacyMasked, .text:
            // Someone is watching the screen: the mark, not the numbers.
            item.isVisible = true
            button.image = MenuBarIcon.appMark()
        case .meter:
            item.isVisible = true
            button.image = MenuBarIcon.render(
                reading: store.meterReading,
                style: store.menuBarStyle,
                level: store.alertLevel,
                mode: store.meterMode)
        }
    }

    /// A window reset: the glyph refills from the reading before it to the
    /// one now, drawn in green, holds a moment, then goes back to the
    /// template ink. Only the meter styles have something to refill.
    func playReset(from before: MeterReading) {
        guard !celebrating, let store, let button = item?.button, item?.isVisible == true,
              store.menuBarIconMode == .meter, !store.isPrivacyMasked
        else { return }
        let target = store.meterReading
        let style = store.menuBarStyle
        let mode = store.meterMode
        let green = NSColor(srgbRed: 0.13, green: 0.64, blue: 0.30, alpha: 1)
        celebrating = true
        Task { @MainActor [weak self] in
            let frames = Motion.reduced ? 1 : 24
            for frame in 1...frames {
                let t = Double(frame) / Double(frames)
                let eased = 1 - pow(1 - t, 3)
                button.image = MenuBarIcon.render(
                    reading: Self.blend(before, target, eased), style: style, level: .none, mode: mode, tint: green)
                try? await Task.sleep(for: .milliseconds(30))
            }
            try? await Task.sleep(for: .milliseconds(Motion.reduced ? 1500 : 1100))
            guard let self else { return }
            self.celebrating = false
            self.lastImageKey = ""
            self.render()
        }
    }

    private static func blend(_ from: MeterReading, _ to: MeterReading, _ t: Double) -> MeterReading {
        func mix(_ a: Double?, _ b: Double?) -> Double? {
            guard let b else { return nil }
            guard let a else { return b }
            return min(100, max(0, a + (b - a) * t))
        }
        var reading = MeterReading(short: mix(from.short, to.short), long: mix(from.long, to.long))
        if to.preferred != nil { reading.preferred = mix(from.preferred ?? from.headline, to.preferred) }
        return reading
    }

    /// The focused provider, or the first three enabled, with figures in
    /// the used-or-left mode.
    private static func stripItems(_ store: UsageStore) -> [(id: ProviderID, percent: Double?)] {
        guard store.menuBarIconMode == .text else { return [] }
        let ids = store.selected.map { [$0] } ?? Array(store.enabled.prefix(3))
        return ids.map { id in (id: id, percent: store.headlinePercent(for: id).map { store.meterMode.shownPercent(fromUsed: $0) }) }
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        let secondary = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        if secondary {
            MenuPanelController.shared.close()
            showMenu()
        } else {
            MenuPanelController.shared.toggle(from: item?.button)
        }
    }

    private func showMenu() {
        guard let item else { return }
        let menu = NSMenu()
        menu.addItem(makeItem(L10n.t("Refresh now", "立即刷新"), #selector(refresh), ""))
        menu.addItem(makeItem(L10n.t("Settings…", "设置…"), #selector(openSettings), ","))
        menu.addItem(.separator())
        menu.addItem(makeItem(L10n.t("Quit QuotaBar", "退出 QuotaBar"), #selector(quit), "q"))
        // Attached for this click only: a menu left on the item would also
        // take over the primary click.
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    private func makeItem(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.target = self
        return menuItem
    }

    @objc private func refresh() { store?.refreshAll() }
    @objc private func openSettings() { SettingsWindow.open() }
    @objc private func quit() { NSApp.terminate(nil) }
}

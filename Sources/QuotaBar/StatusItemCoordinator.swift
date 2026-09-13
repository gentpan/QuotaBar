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

    /// A window reset. The glyph stays in the menu bar's own ink — macOS
    /// draws status items in one colour, and a green one read as an error —
    /// and refills smoothly from the reading before the reset to the one
    /// now; the button lights up behind it for a beat, and a highlight runs
    /// across the glyph's own pixels. Only the meter styles have anything
    /// to refill.
    func playReset(from before: MeterReading) {
        guard !celebrating, let store, let button = item?.button, item?.isVisible == true,
              store.menuBarIconMode == .meter, !store.isPrivacyMasked
        else { return }
        let target = store.meterReading
        let style = store.menuBarStyle
        let level = store.alertLevel
        let mode = store.meterMode
        celebrating = true
        Task { @MainActor [weak self] in
            if !Motion.reduced {
                // 60 frames a second for 0.9s: each is a 22pt drawing, cheap
                // enough that the refill reads as motion, not steps.
                let frames = 54
                let start = ProcessInfo.processInfo.systemUptime
                for frame in 1...frames {
                    let t = Double(frame) / Double(frames)
                    let eased = 1 - pow(1 - t, 3)
                    button.image = MenuBarIcon.render(
                        reading: Self.blend(before, target, eased), style: style, level: level, mode: mode)
                    let due = start + 0.9 * t
                    let wait = due - ProcessInfo.processInfo.systemUptime
                    if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                }
                Self.shine(on: button)
                try? await Task.sleep(for: .milliseconds(760))
            }
            guard let self else { return }
            self.celebrating = false
            self.lastImageKey = ""
            self.render()
        }
    }

    /// The beat after the refill: the button's background brightens and
    /// fades, and a band of light crosses the glyph, masked to its pixels so
    /// only the ink shines.
    private static func shine(on button: NSStatusBarButton) {
        guard let image = button.image,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }
        button.wantsLayer = true
        guard let host = button.layer else { return }
        let bounds = host.bounds
        let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let ink = dark ? NSColor.white : NSColor.black

        let glow = CALayer()
        glow.frame = bounds.insetBy(dx: 1, dy: 2)
        glow.cornerRadius = 5
        glow.backgroundColor = ink.withAlphaComponent(0.16).cgColor
        glow.opacity = 0
        host.addSublayer(glow)
        let pulse = CAKeyframeAnimation(keyPath: "opacity")
        pulse.values = [0, 1, 0]
        pulse.keyTimes = [0, 0.3, 1]
        pulse.duration = 0.6
        glow.add(pulse, forKey: "pulse")

        let size = image.size
        let imageFrame = CGRect(
            x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
            width: size.width, height: size.height)
        let band = CAGradientLayer()
        band.frame = imageFrame
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        let light = (dark ? NSColor.white : NSColor(white: 0.55, alpha: 1)).cgColor
        band.colors = [NSColor.clear.cgColor, light, NSColor.clear.cgColor]
        band.locations = [-0.6, -0.3, 0]
        let mask = CALayer()
        mask.frame = band.bounds
        mask.contents = cgImage
        mask.contentsGravity = .resizeAspect
        band.mask = mask
        host.addSublayer(band)
        let run = CABasicAnimation(keyPath: "locations")
        run.fromValue = [-0.6, -0.3, 0]
        run.toValue = [1, 1.3, 1.6]
        run.duration = 0.62
        run.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        band.locations = [1, 1.3, 1.6]
        band.add(run, forKey: "run")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            glow.removeFromSuperlayer()
            band.removeFromSuperlayer()
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

    /// The secondary-click menu: which provider the icon reports, then the
    /// app's own commands. The icon's choice is its own — the dock, island and
    /// desktop cards keep their pins — so the menu bar can report Cursor while
    /// the dock shows every ring.
    private func showMenu() {
        guard let item, let store else { return }
        menuActions = []
        let menu = NSMenu()

        let shown = NSMenuItem(title: L10n.t("Show in Menu Bar", "显示在菜单栏"), action: nil, keyEquivalent: "")
        shown.submenu = providerMenu(store: store)
        menu.addItem(shown)
        menu.addItem(.separator())

        add(menu, L10n.t("Refresh Now", "立即刷新"), "r") { [store] in store.refreshAll() }
        menu.addItem(updateItem(store: store))
        menu.addItem(runItem(store: store))
        add(menu, L10n.t("Feedback…", "反馈…"), "") { SettingsWindow.open(section: .feedback) }
        add(menu, L10n.t("Settings…", "设置…"), ",") { SettingsWindow.open() }
        menu.addItem(.separator())
        add(menu, L10n.t("About QuotaBar", "关于 QuotaBar"), "") { SettingsWindow.open(section: .about) }
        add(menu, L10n.t("Quit QuotaBar", "退出 QuotaBar"), "q") { NSApp.terminate(nil) }

        // Attached for this click only: a menu left on the item would also
        // take over the primary click.
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    /// Automatic, then every enabled provider with its mark and the figure
    /// the icon would show for it; the current choice is ticked.
    private func providerMenu(store: UsageStore) -> NSMenu {
        let menu = NSMenu()
        let automatic = add(menu, L10n.t("Automatic (fullest limit)", "自动（用得最满的额度）"),
                            detail: store.hottestProvider?.id.displayName) { [store] in store.selected = nil }
        automatic.state = store.selected == nil ? .on : .off
        menu.addItem(.separator())
        for id in store.enabled {
            let row = add(menu, id.displayName, detail: reading(for: id, store: store)) { [store] in store.selected = id }
            row.state = store.selected == id ? .on : .off
            if let logo = ProviderGlyph.logo(for: id), let image = logo.image.copy() as? NSImage {
                image.size = NSSize(width: 16, height: 16)
                // Single-colour marks follow the menu's text colour in light
                // and dark menus; brand-coloured ones keep their colour.
                image.isTemplate = logo.isMonochrome
                row.image = image
            }
        }
        return menu
    }

    /// "81% left" or "19% used", as the icon counts; a dash before a reading.
    private func reading(for id: ProviderID, store: UsageStore) -> String {
        guard let used = store.headlinePercent(for: id) else { return "—" }
        let figure = QuotaFormat.percent(store.meterMode.shownPercent(fromUsed: used))
        return store.meterMode == .remaining
            ? L10n.t("\(figure) left", "剩余 \(figure)")
            : L10n.t("\(figure) used", "已用 \(figure)")
    }

    /// Says where an update has got to; every state opens the update card,
    /// which shows what changed and installs it, or says it is up to date.
    private func updateItem(store: UsageStore) -> NSMenuItem {
        let item: NSMenuItem
        switch store.updateStage {
        case .checking:
            item = NSMenuItem(title: L10n.t("Checking for Updates…", "正在检查更新…"), action: nil, keyEquivalent: "")
        case let .downloading(release):
            item = NSMenuItem(title: L10n.t("Downloading \(release.version)…", "正在下载 \(release.version)…"), action: nil, keyEquivalent: "")
        case let .readyToInstall(release), let .available(release):
            item = makeClosureItem(L10n.t("Update to \(release.version)…", "更新到 \(release.version)…"), "") { [store] in
                UpdateWindow.show(store: store)
            }
        case .failed:
            item = makeClosureItem(L10n.t("Update Failed…", "更新失败…"), "") { [store] in
                UpdateWindow.show(store: store)
            }
        case .idle:
            item = makeClosureItem(L10n.t("Check for Updates…", "检查更新…"), "") { [store] in
                store.checkForUpdate(manual: true, presenting: true)
            }
        }
        return item
    }

    /// Quota Run from the menu bar: signing in when this Mac isn't, otherwise
    /// who it is signed in as. Both open Settings → Quota Run, the first
    /// scrolled down to the sign-in card.
    private func runItem(store: UsageStore) -> NSMenuItem {
        if let account = store.run.account {
            return makeClosureItem("Quota Run · @\(account.username)…", "") {
                SettingsWindow.open(section: .run)
            }
        }
        return makeClosureItem(L10n.t("Sign In to Quota Run…", "登录 Quota Run…"), "") {
            SettingsWindow.open(section: .run, anchor: RunSignInCard.anchor)
        }
    }

    private var menuActions: [ClosureTarget] = []

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ key: String, _ action: @escaping () -> Void) -> NSMenuItem {
        let item = makeClosureItem(title, key, action)
        menu.addItem(item)
        return item
    }

    /// A row with a secondary figure set against the menu's right edge.
    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, detail: String?, _ action: @escaping () -> Void) -> NSMenuItem {
        let item = add(menu, title, "", action)
        if let detail {
            let style = NSMutableParagraphStyle()
            style.tabStops = [NSTextTab(textAlignment: .right, location: 230)]
            let text = NSMutableAttributedString(
                string: title,
                attributes: [.font: NSFont.menuFont(ofSize: 0), .paragraphStyle: style])
            text.append(NSAttributedString(
                string: "\t" + detail,
                attributes: [.font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style]))
            item.attributedTitle = text
        }
        return item
    }

    private func makeClosureItem(_ title: String, _ key: String, _ action: @escaping () -> Void) -> NSMenuItem {
        let target = ClosureTarget(action)
        menuActions.append(target)
        let item = NSMenuItem(title: title, action: #selector(ClosureTarget.fire), keyEquivalent: key)
        item.target = target
        return item
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

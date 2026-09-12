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
                self.store?.refreshAll()
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

private struct PanelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct MenuPanelView: View {
    @ObservedObject var store: UsageStore
    @State private var scrollHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 52

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: store.experience.panelDensity == .compact ? 8 : 10) {
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
                    ForEach(store.enabled) { id in
                        ProviderCardView(store: store, id: id)
                    }
                }
                .padding(10)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: PanelHeightKey.self, value: proxy.size.height)
                })
                .animation(Motion.animation(Motion.spring), value: store.experience.expandedCards)
            }
            .scrollIndicators(.never)
            .onPreferenceChange(PanelHeightKey.self) { height in
                scrollHeight = height
                MenuPanelController.shared.setContentHeight(height + footerHeight)
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
                action: L10n.t("Restart to update", "重启安装")) { store.installNow() }
        case let .available(release):
            banner(
                L10n.t("QuotaBar \(release.version) is available", "发现新版本 \(release.version)"),
                action: L10n.t("Download", "下载")) { store.downloadUpdate() }
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
                VStack(alignment: .leading, spacing: 1) {
                    Text(version)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                    refreshLine
                }
                Spacer()
                CalloutButton(symbol: "gearshape", help: L10n.t("Settings (⌘,)", "设置（⌘,）")) {
                    MenuPanelController.shared.close()
                    SettingsWindow.open()
                }
                OptionsMenuButton(store: store)
                    .frame(width: 22, height: 22)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .background(Color(white: 0.06))
    }

    @ViewBuilder
    private var refreshLine: some View {
        let loading = store.enabled.contains { store.isLoading($0) } || store.isComputingCost
        TimelineView(.periodic(from: .now, by: 15)) { context in
            Text(loading ? L10n.t("Refreshing…", "正在刷新…") : nextRefresh(now: context.date))
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.45))
                .contentShape(Rectangle())
                .onTapGesture { store.refreshAll() }
                .help(L10n.t("Refresh now (⌘R)", "立即刷新（⌘R）"))
        }
    }

    private func nextRefresh(now: Date) -> String {
        let seconds = max(0, store.nextRefreshAt.timeIntervalSince(now))
        let minutes = Int((seconds / 60).rounded(.up))
        return minutes <= 1
            ? L10n.t("Next update in a minute", "1 分钟内刷新")
            : L10n.t("Next update in \(minutes)m", "\(minutes) 分钟后刷新")
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
            add(menu, L10n.t("Refresh Now", "立即刷新"), "r") { [store] in store.refreshAll() }
            add(menu, L10n.t("Check for Updates…", "检查更新…"), "") { [store] in store.checkForUpdate() }
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

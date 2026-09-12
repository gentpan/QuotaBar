import AppKit
import SwiftUI
import QuotaCore

/// AppKit lifecycle, not a SwiftUI `App`.
///
/// There is no SwiftUI scene left to show: the menu-bar item is a status item
/// (`StatusItemCoordinator`), the settings window is ours (`SettingsWindow`),
/// and every other surface is an `NSPanel` hosting a SwiftUI view. The
/// intermediate step — a SwiftUI `App` whose only scene was
/// `Settings { EmptyView() }` — put that scene's window on screen at launch,
/// an empty 45×233pt window titled "QuotaBar Settings", because SwiftUI shows
/// the settings scene when it is the only one. Hence the plain delegate.
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// `NSApplication.delegate` is weak; something has to own the delegate.
    private static var shared: AppDelegate?

    private var store: UsageStore?
    private let coordinators = Coordinators()

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        shared = delegate
        app.delegate = delegate
        // `NSApplicationMain`, not `app.run()`: with a bare `run()` the status
        // item's window was created but never placed — it sat at (0, 0, 38, 0)
        // and the accessibility tree showed no status menu bar at all.
        _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
    }

    /// Opening the app while it runs — from Launchpad, Spotlight, or the
    /// Finder — means "show me". With the menu-bar item hidden it is also
    /// the way back to Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        SettingsWindow.open()
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Info.plist carries LSUIElement for the packaged app; setting it here
        // too keeps the dev loop (bare binary, no bundle) out of the Dock.
        NSApp.setActivationPolicy(.accessory)

        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--snapshot") {
            let directory = index + 1 < arguments.count ? arguments[index + 1] : "./snapshots"
            Snapshot.run(directory: directory)
            NSApp.terminate(nil)
        }
        if let index = arguments.firstIndex(of: "--settings-preview") {
            let directory = index + 1 < arguments.count ? arguments[index + 1] : "./settings"
            Snapshot.settingsPreview(directory: directory)
            NSApp.terminate(nil)
        }
        if let index = arguments.firstIndex(of: "--icon-preview") {
            let directory = index + 1 < arguments.count ? arguments[index + 1] : "./icons"
            Snapshot.iconPreview(directory: directory)
            NSApp.terminate(nil)
        }
        if let index = arguments.firstIndex(of: "--theme-preview") {
            let directory = index + 1 < arguments.count ? arguments[index + 1] : "./themes"
            Snapshot.themePreview(directory: directory)
            NSApp.terminate(nil)
        }
        if let index = arguments.firstIndex(of: "--settings-window") {
            // `--settings-window status` opens straight to a section.
            let section = index + 1 < arguments.count ? SettingsSection(rawValue: arguments[index + 1]) : nil
            Diagnostics.settingsWindow(section: section ?? .providers)
            return
        }
        if arguments.contains("--windows") {
            Diagnostics.printWindows()
            return
        }
        if arguments.contains("--cost") {
            Diagnostics.printCost()
            NSApp.terminate(nil)
        }
        if arguments.contains("--ledger") {
            Diagnostics.printLedger()
            NSApp.terminate(nil)
        }
        if arguments.contains("--status") {
            Diagnostics.printStatus()
            NSApp.terminate(nil)
        }
        if arguments.contains("--json") {
            // `QuotaBar --json [--force]`: the limits other tools read,
            // through the last readings when they are under five minutes old.
            Diagnostics.printLimitsJSON(force: arguments.contains("--force"))
            NSApp.terminate(nil)
        }
        if arguments.contains("--credentials") {
            Diagnostics.printCredentials()
            NSApp.terminate(nil)
        }

        let store = UsageStore()
        self.store = store
        SettingsWindow.configure(store: store)
        MenuPanelController.shared.configure(store: store)
        coordinators.start(store: store)
        if arguments.contains("--panel-window") {
            // Opens the menu panel under the top-right of the screen, for
            // looking at it without clicking the item.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                MenuPanelController.shared.open(from: nil)
            }
        }
        if arguments.contains("--share-studio") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { ShareStudio.open(store: store) }
        }
    }
}

/// The surfaces that hang off the store, and the one place that decides
/// which of them to poke when it changes. The status item's store
/// subscription drives it; the revisions are compared here so that a tick
/// does not re-place the dock or re-sync the widget.
@MainActor
final class Coordinators {
    private let status = StatusItemCoordinator()
    private let island = IslandCoordinator()
    private let dock = EdgeDockCoordinator()
    private let widget = DesktopWidgetCoordinator()

    private var presentation: Presentation?
    private var widgetRevision = -1
    private var dockRevision = -1
    private var islandRevision = -1
    private var screenObserver: NSObjectProtocol?

    func start(store: UsageStore) {
        status.onStoreChange = { [weak self, weak store] in
            guard let self, let store else { return }
            self.sync(store: store)
        }
        status.start(store: store)
        sync(store: store)
        // A display plugged in or pulled: whatever screen each surface now
        // belongs on, it goes there.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main)
        { [weak self, weak store] _ in
            guard let self, let store else { return }
            MainActor.assumeIsolated {
                self.dock.relayout()
                self.island.relayout()
                self.widget.sync(store: store)
            }
        }
    }

    /// Only one alternate presentation is live at a time; the menu-bar item
    /// stays regardless, as the settings entry point.
    private var privacyMasked = false
    private var experienceRevision = -1

    private func sync(store: UsageStore) {
        if store.isPrivacyMasked != privacyMasked {
            privacyMasked = store.isPrivacyMasked
            if privacyMasked {
                island.hide()
                dock.hide()
                widget.hide()
                presentation = nil
            } else {
                presentation = nil
                widgetRevision = -1
            }
        }
        if store.experienceRevision != experienceRevision {
            experienceRevision = store.experienceRevision
            GlobalHotkey.shared.action = { [weak self] in
                MenuPanelController.shared.toggle(from: self?.status.button)
            }
            GlobalHotkey.shared.apply(store.experience.hotkey)
            LocalAPIServer.shared.apply(enabled: store.experience.localAPI, store: store)
        }
        guard !privacyMasked else { return }
        let severity = store.islandProviders.compactMap { store.headlinePercent(for: $0) }
            .map { store.alertSettings.level(for: $0) }
            .max() ?? .none
        island.noteSeverity(severity, enabled: store.experience.islandAutoPeek)
        if store.presentation != presentation {
            presentation = store.presentation
            island.sync(store: store)
            dock.sync(store: store)
            widget.sync(store: store)
        }
        if store.widgetRevision != widgetRevision {
            widgetRevision = store.widgetRevision
            widget.sync(store: store)
        }
        if store.dockRevision != dockRevision {
            dockRevision = store.dockRevision
            dock.relayout()
        }
        if store.islandRevision != islandRevision {
            islandRevision = store.islandRevision
            island.relayout()
        }
    }
}

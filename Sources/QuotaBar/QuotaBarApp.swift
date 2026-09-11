import SwiftUI
import AppKit
import QuotaCore

@main
struct QuotaBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = UsageStore()
    private let island = IslandCoordinator()
    private let dock = EdgeDockCoordinator()
    private let widget = DesktopWidgetCoordinator()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(store: store)
        } label: {
            Image(nsImage: MenuBarIcon.render(
                reading: store.meterReading,
                style: store.menuBarStyle,
                level: store.alertLevel,
                mode: store.meterMode))
                .onAppear { syncPresentation() }
                .onChange(of: store.presentation) { _, _ in syncPresentation() }
                .onChange(of: store.widgetRevision) { _, _ in widget.sync(store: store) }
                .onChange(of: store.dockRevision) { _, _ in dock.relayout() }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: store)
        }
    }

    /// Only one alternate presentation is live at a time; the menu-bar item
    /// stays regardless, as the settings entry point.
    private func syncPresentation() {
        island.sync(store: store)
        dock.sync(store: store)
        widget.sync(store: store)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
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
        if arguments.contains("--settings-window") {
            Diagnostics.settingsWindow()
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
    }
}

import AppKit
import SwiftUI
import QuotaCore

/// The settings window, owned here rather than by a SwiftUI `Settings` scene.
///
/// The menu-bar item opens it on a plain click, and AppKit has no supported
/// way to ask a `Settings` scene to open — the `showSettingsWindow:` selector
/// is private and has changed name before. One window for the app's
/// lifetime: closing hides it, so it comes back at the size and place it was
/// left. `WindowChrome`, applied inside `SettingsView`, dresses whichever
/// window hosts it, so the look is the same as under the scene.
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?
    private static weak var store: UsageStore?
    private static let autosaveName = "QuotaBar.Settings"

    static func configure(store: UsageStore) {
        self.store = store
    }

    /// Posted with a `SettingsSection` raw value to turn the open window to it.
    static let showSection = Notification.Name("bar.quota.settings.showSection")
    /// Posted with a view id inside the section just shown, to scroll it into view.
    static let scrollTo = Notification.Name("bar.quota.settings.scrollTo")

    /// Opens Settings at one section, optionally scrolled to a card in it.
    static func open(section: SettingsSection, anchor: String? = nil) {
        open()
        // After the window exists and its view is listening.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: showSection, object: section.rawValue)
            guard let anchor else { return }
            // A beat later: the new section has to be laid out before it can scroll.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                NotificationCenter.default.post(name: scrollTo, object: anchor)
            }
        }
    }

    static func open() {
        guard let store else { return }
        let window = self.window ?? make(store: store)
        self.window = window
        window.makeKeyAndOrderFront(nil)
        // An accessory app is never activated as a side effect, so without
        // this the window orders in behind whatever the user was looking at:
        // from their side the click did nothing.
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Older call sites asked for the front settings window to be brought
    /// forward after SwiftUI created it. Same thing, now.
    static func focus() {
        open()
    }

    private static func make(store: UsageStore) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 840, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        // Title before content: `WindowChrome`, applied inside SettingsView,
        // blanks the title the moment the hosting view lands in the window —
        // the sidebar wordmark is the title — and set afterwards it would
        // come back and sit above the pane.
        window.title = L10n.t("QuotaBar Settings", "QuotaBar 设置")
        window.contentView = NSHostingView(rootView: SettingsView(store: store))
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 840, height: 700)
        if !window.setFrameUsingName(autosaveName) {
            // First open: centred on the screen with the pointer. `center()`
            // picks the main screen, which on a multi-display Mac is
            // routinely the other one.
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
                ?? NSScreen.main
            if let visible = screen?.visibleFrame {
                window.setFrameOrigin(NSPoint(
                    x: visible.midX - window.frame.width / 2,
                    y: visible.midY - window.frame.height / 2))
            }
        }
        window.setFrameAutosaveName(autosaveName)
        return window
    }
}

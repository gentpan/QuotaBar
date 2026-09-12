import AppKit
import QuotaCore

/// Which display the dock, island and widget are put on. A screen is named
/// by its display UUID — stable across reconnects and reboots, unlike the
/// `NSScreenNumber`, which macOS may hand out afresh — and a choice whose
/// display is not connected right now simply reads as automatic.
enum ScreenChoice {
    static func uuid(of screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// The chosen screen, when it is connected. nil means automatic.
    static var chosen: NSScreen? {
        guard let id = ConfigStore.shared.displayScreen else { return nil }
        return NSScreen.screens.first { uuid(of: $0) == id }
    }

    /// Automatic, then every connected screen by the name macOS gives it.
    static var options: [(value: String?, label: String)] {
        [(nil, L10n.t("Automatic", "自动"))] + NSScreen.screens.compactMap { screen in
            uuid(of: screen).map { (Optional($0), screen.localizedName) }
        }
    }

    /// What the picker should show as selected: the choice, or automatic
    /// when its display is away.
    static var selection: String? {
        chosen.flatMap(uuid(of:))
    }
}

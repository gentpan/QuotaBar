import AppKit
import SwiftUI
import QuotaCore

/// Single source of truth for spacing, corner radii and surface treatment.
/// Radii are tiered on purpose — tiles, cards and the panel itself should not
/// all round to the same value — and every card uses a fill *or* a border,
/// never both.
enum Design {
    // 4pt grid.
    static let space1: CGFloat = 4
    static let space2: CGFloat = 8
    static let space3: CGFloat = 12
    static let space4: CGFloat = 16
    static let space6: CGFloat = 24

    // Radius tiers.
    static let radiusField: CGFloat = 7
    static let radiusTile: CGFloat = 8
    static let radiusCard: CGFloat = 10
    static let radiusPanel: CGFloat = 14

    // Settings window metrics. A form only reads as a form when every control
    // in it is the same height and starts at the same x.
    static let fieldHeight: CGFloat = 30
    static let labelColumn: CGFloat = 132
    static let sidebarWidth: CGFloat = 180
    /// Clears the traffic lights once the titlebar is transparent.
    static let titlebarInset: CGFloat = 30

    /// The menu panel is the fourth always-dark surface, after the dock, the
    /// island and the widget — black and pinned, not adaptive, for the same
    /// reason the sidebar is: the app's own surfaces should read as one
    /// family whatever the system appearance. Opaque rather than a material
    /// because the panel must carry its own contrast; it cannot rely on what
    /// sits behind it. Its cards keep their `Color.primary` fills, which
    /// resolve white once `MenuContentView` forces its colour scheme.
    static let panelSurface = Color.black

    /// Warning tint on the panel: CodexIsland's alert amber (#F5A524). It
    /// reads as amber against black without competing with the eleven brand
    /// colours the way system orange does.
    static let panelWarning = Color(hex: "F5A524")

    /// Low-contrast fill used for cards and tiles.
    static let surface = Color.primary.opacity(0.05)
    static let surfaceStrong = Color.primary.opacity(0.08)
    static let track = Color.primary.opacity(0.15)

    /// The settings window's content pane. Opaque, and deliberately not a
    /// vibrancy view: the titlebar composites its own material over anything
    /// translucent beneath it, which laid a 28pt lighter band across the top of
    /// the pane. The black sidebar beside it showed no such band, because an
    /// opaque fill blocks that compositing — so the pane gets one too, and the
    /// window reads as a single surface. The light value is what the vibrancy
    /// resolved to, so nothing else shifts.
    static var settingsBackground: Color {
        // Dark is lifted off pure black on purpose: the sidebar beside it *is*
        // pure black, and at 1C1C1E the two were a hairline apart.
        adaptive(light: "E9E8E8", dark: "242426")
    }

    /// The settings sidebar is an always-dark surface, like the dock and the
    /// widget. Its colours are therefore pinned, not adaptive: `Color.primary`
    /// and `Design.accent` resolve against the *system* appearance and both go
    /// black-on-black in light mode. Same trap as `ProviderGlyph`'s `tint`.
    static let sidebarSurface = Color.black
    static let sidebarInk = Color.white
    static let sidebarInkDim = Color.white.opacity(0.55)

    /// The lit rail segment behind the selected sidebar row. One token because
    /// it is the only hue in the window that is a free choice — it is white
    /// rather than a colour for the same reason `accent` is graphite: the pane
    /// beside it carries eleven provider brand colours and a twelfth competing
    /// hue makes none of them legible.
    static let sidebarGlow = Color.white
    /// One nav row. Taller than a menu row on purpose — the rail segment is a
    /// fraction of the rail's height, and at 30pt it is too short to read as a
    /// travelling light.
    static let sidebarRow: CGFloat = 36

    /// Specular edge on a glass surface, and the well behind a text field.
    /// Both are `Color.primary` derivatives so they invert with the appearance
    /// on their own — a fixed white hairline is invisible in light mode.
    static let glassEdge = Color.primary.opacity(0.12)
    static let fieldFill = Color.primary.opacity(0.04)

    /// Resolves per appearance: graphite-on-white in light mode, and the
    /// inverse in dark mode so the selection block never sinks into the window.
    static var accent: Color {
        adaptive(light: QuotaTheme.accentHex, dark: QuotaTheme.accentDarkHex)
    }

    static var ink: Color {
        adaptive(light: QuotaTheme.inkHex, dark: QuotaTheme.inkDarkHex)
    }

    /// The wordmark's face. Sora ships inside the bundle, in
    /// `Resources/fonts`, declared by `ATSApplicationFontsPath` in Info.plist.
    ///
    /// `Font.custom` falls back to the system font on its own when the family
    /// is not registered, which is exactly what the dev loop needs: it runs a
    /// bare binary with no bundle, so there is nothing to register a font from.
    /// Only ever used for the word "QuotaBar" — body text stays on the system
    /// face, which is what a macOS app should read as.
    static func wordmark(size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        Font.custom("Sora", size: size).weight(weight)
    }

    private static func adaptive(light: String, dark: String) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension View {
    /// Card surface: a fill, no border, no shadow.
    func quotaCard(radius: CGFloat = Design.radiusCard) -> some View {
        padding(Design.space3)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Design.surface))
    }
}


extension NSColor {
    convenience init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1)
    }
}

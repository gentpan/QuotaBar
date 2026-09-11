import AppKit
import SwiftUI
import QuotaCore

/// Renders the dynamic menu-bar icon in the user-selected style.
/// Template (monochrome) normally; tinted orange/red while an alert is active.
enum MenuBarIcon {
    /// `percent` is always the *used* figure — the alert level is derived from
    /// it upstream. `mode` decides whether the glyph fills with that or with
    /// what is left; the tint is unaffected either way.
    /// Convenience for callers with a single figure (previews, settings).
    static func render(
        percent: Double?,
        style: MenuBarStyle,
        level: AlertLevel = .none,
        mode: MeterMode = .remaining) -> NSImage
    {
        render(
            reading: MeterReading(long: percent),
            style: style,
            level: level,
            mode: mode)
    }

    static func render(
        reading: MeterReading,
        style: MenuBarStyle,
        level: AlertLevel = .none,
        mode: MeterMode = .remaining) -> NSImage
    {
        let ink: NSColor = level.hex.map(nsColor) ?? .black
        let trackInk = ink.withAlphaComponent(0.35)

        if style.showsBothHorizons {
            let image = style == .dualBar
                ? renderDualBar(reading, ink: ink, track: trackInk, mode: mode)
                : renderDual(reading, ink: ink, track: trackInk, mode: mode)
            image.isTemplate = level == .none
            return image
        }

        let percent = reading.headline
        // No reading at all stays empty in both modes: a full bar would claim
        // the quota is untouched when we simply do not know.
        let shown = percent.map { mode.shownPercent(fromUsed: $0) }
        let image: NSImage
        switch style {
        case .dual: image = renderDual(reading, ink: ink, track: trackInk, mode: mode)
        case .dualBar: image = renderDualBar(reading, ink: ink, track: trackInk, mode: mode)
        case .bar: image = renderBar(shown, ink: ink, track: trackInk)
        case .ring: image = renderRing(shown, ink: ink, track: trackInk)
        case .columns: image = renderColumns(shown, ink: ink, track: trackInk)
        case .percent: image = renderPercent(shown, ink: ink)
        case .segments: image = renderSegments(shown, ink: ink, track: trackInk)
        case .grid: image = renderGrid(shown, ink: ink, track: trackInk)
        case .battery: image = renderBattery(shown, ink: ink, track: trackInk)
        case .gauge: image = renderGauge(shown, ink: ink, track: trackInk)
        case .ticks: image = renderTicks(shown, ink: ink, track: trackInk)
        }
        image.isTemplate = level == .none
        return image
    }

    private static func nsColor(_ hex: String) -> NSColor {
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        return NSColor(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1)
    }

    /// Draws an unlit cell as an outline instead of a faint fill.
    ///
    /// A faint fill is only distinguishable from a lit one by its alpha, and
    /// once the glyph is tinted for an alert both read as "a coloured block":
    /// an exhausted quota (nothing lit) looked identical to a full one. An
    /// outline is unambiguous at any colour or size.
    private static func strokeCell(_ path: NSBezierPath, _ ink: NSColor) {
        // Heavy enough to survive antialiasing at 22pt; any lighter and an
        // empty meter reads as a blank menu bar.
        ink.withAlphaComponent(0.75).setStroke()
        path.lineWidth = 1.4
        path.stroke()
    }

    private static func fraction(_ percent: Double?) -> CGFloat {
        guard let percent else { return 0 }
        return CGFloat(min(max(percent, 0), 100) / 100)
    }

    // MARK: 横向 — capsule track filled left to right

    private static func renderBar(_ percent: Double?, ink: NSColor, track: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 22, height: 22), flipped: false) { _ in
            let trackPath = NSBezierPath(
                roundedRect: NSRect(x: 3, y: 9, width: 16, height: 5),
                xRadius: 2.5, yRadius: 2.5)
            track.setFill()
            trackPath.fill()

            guard let percent else { return true }
            let fillWidth = max(2, 16 * fraction(percent))
            let fill = NSBezierPath(
                roundedRect: NSRect(x: 3, y: 9, width: min(fillWidth, 16), height: 5),
                xRadius: 2.5, yRadius: 2.5)
            ink.setFill()
            fill.fill()
            return true
        }
    }

    // MARK: 圆形 — activity ring starting at 12 o'clock

    private static func renderRing(_ percent: Double?, ink: NSColor, track: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 22, height: 22), flipped: false) { _ in
            let center = NSPoint(x: 11, y: 11)
            let radius: CGFloat = 7.5

            let trackPath = NSBezierPath()
            trackPath.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            trackPath.lineWidth = 3
            track.setStroke()
            trackPath.stroke()

            guard let percent else { return true }
            let sweep = 360 * fraction(percent)
            guard sweep > 1 else { return true }
            let arc = NSBezierPath()
            arc.appendArc(
                withCenter: center, radius: radius,
                startAngle: 90, endAngle: 90 - sweep, clockwise: true)
            arc.lineWidth = 3
            arc.lineCapStyle = .round
            ink.setStroke()
            arc.stroke()
            return true
        }
    }

    // MARK: 柱形 — four ascending columns, lit left to right (25% each)

    private static func renderColumns(_ percent: Double?, ink: NSColor, track: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 22, height: 22), flipped: false) { _ in
            let heights: [CGFloat] = [7, 10, 13, 16]
            let barWidth: CGFloat = 3.2
            let spacing: CGFloat = 1.4
            let totalWidth = barWidth * 4 + spacing * 3
            var x = (22 - totalWidth) / 2

            let lit: Int
            if let percent {
                lit = percent > 0 ? max(1, Int((fraction(percent) * 4).rounded(.up))) : 0
            } else {
                lit = 0
            }

            for (index, height) in heights.enumerated() {
                let rect = NSRect(x: x, y: 3, width: barWidth, height: height)
                if index < lit {
                    ink.setFill()
                    NSBezierPath(roundedRect: rect, xRadius: 1.6, yRadius: 1.6).fill()
                } else {
                    strokeCell(NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                            xRadius: 1.3, yRadius: 1.3), ink)
                }
                x += barWidth + spacing
            }
            return true
        }
    }

    // MARK: 双层 — short horizon over long horizon

    /// Two stacked five-cell meters: the top row is the short window (5h,
    /// rolling), the bottom the long one (7d, 30d, billing cycle).
    ///
    /// Collapsing both into one figure hides which limit is actually near —
    /// "am I about to be throttled" and "will I run out this week" are
    /// different questions. A plan that reports only one horizon (a Codex Pro
    /// account has no 5-hour window) draws a single centred row rather than an
    /// empty one, which would read as "nothing left".
    private static func renderDual(
        _ reading: MeterReading,
        ink: NSColor,
        track: NSColor,
        mode: MeterMode) -> NSImage
    {
        let count = 5
        let cellWidth: CGFloat = 4.2
        let gap: CGFloat = 1.6
        let totalWidth = cellWidth * CGFloat(count) + gap * CGFloat(count - 1)
        let size = NSSize(width: totalWidth + 4, height: 22)

        let rows: [Double?] = reading.hasBothHorizons
            ? [reading.short, reading.long]
            : [reading.headline]

        return NSImage(size: size, flipped: false) { _ in
            let rowHeight: CGFloat = rows.count > 1 ? 5.5 : 8
            let rowGap: CGFloat = 2.5
            let block = rowHeight * CGFloat(rows.count) + rowGap * CGFloat(rows.count - 1)
            var y = (22 - block) / 2 + block - rowHeight

            for value in rows {
                let lit = steps(value.map { mode.shownPercent(fromUsed: $0) }, of: count)
                var x = (size.width - totalWidth) / 2
                for index in 0..<count {
                    let rect = NSRect(x: x, y: y, width: cellWidth, height: rowHeight)
                    if index < lit {
                        ink.setFill()
                        NSBezierPath(roundedRect: rect, xRadius: 1.1, yRadius: 1.1).fill()
                    } else {
                        strokeCell(NSBezierPath(roundedRect: rect.insetBy(dx: 0.6, dy: 0.6),
                                                xRadius: 0.9, yRadius: 0.9), ink)
                    }
                    x += cellWidth + gap
                }
                y -= rowHeight + rowGap
            }
            return true
        }
    }

    /// Two stacked continuous bars — the same split as `dual`, without the
    /// gradations. Reads as a proportion rather than a count; preferred when
    /// the exact figure matters less than the shape.
    private static func renderDualBar(
        _ reading: MeterReading,
        ink: NSColor,
        track: NSColor,
        mode: MeterMode) -> NSImage
    {
        let width: CGFloat = 17
        let size = NSSize(width: width + 5, height: 22)
        let rows: [Double?] = reading.hasBothHorizons
            ? [reading.short, reading.long]
            : [reading.headline]

        return NSImage(size: size, flipped: false) { _ in
            let rowHeight: CGFloat = rows.count > 1 ? 5.5 : 7
            let rowGap: CGFloat = 3
            let block = rowHeight * CGFloat(rows.count) + rowGap * CGFloat(rows.count - 1)
            var y = (22 - block) / 2 + block - rowHeight
            let x = (size.width - width) / 2
            let radius = rowHeight / 2

            for value in rows {
                let full = NSRect(x: x, y: y, width: width, height: rowHeight)
                track.setFill()
                NSBezierPath(roundedRect: full, xRadius: radius, yRadius: radius).fill()

                if let value {
                    let shown = mode.shownPercent(fromUsed: value)
                    let filled = width * CGFloat(min(max(shown, 0), 100) / 100)
                    // Below a full cap width the rounded rect degenerates, so
                    // anything non-zero draws at least a dot.
                    if filled > 0.5 {
                        let rect = NSRect(x: x, y: y, width: max(filled, rowHeight), height: rowHeight)
                        ink.setFill()
                        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
                    }
                }
                y -= rowHeight + rowGap
            }
            return true
        }
    }

    // MARK: 分段 — five discrete cells, 20% each

    /// Countable gradations: a reader gets an exact figure by counting lit
    /// cells instead of estimating against a continuous fill. Partial cells
    /// are never drawn — a cell lights only once its step is fully reached,
    /// so the glyph never overstates.
    private static func renderSegments(_ percent: Double?, ink: NSColor, track: NSColor) -> NSImage {
        // Five cells, linear. Ten was tried and is worse: at 22pt each cell
        // becomes ~2pt wide, and a filled cell stops being distinguishable
        // from an outlined one — finer gradations bought nothing because the
        // gradations themselves became unreadable.
        //
        // Linear rather than a 3x3 grid: proportion along one axis is read
        // preattentively, while a grid has to be counted in two dimensions.
        let count = 5
        let cellWidth: CGFloat = 4.2
        let gap: CGFloat = 1.6
        let totalWidth = cellWidth * CGFloat(count) + gap * CGFloat(count - 1)
        let size = NSSize(width: totalWidth + 4, height: 22)
        return NSImage(size: size, flipped: false) { _ in
            var x = (size.width - totalWidth) / 2
            let lit = steps(percent, of: count)
            for index in 0..<count {
                let rect = NSRect(x: x, y: 7.5, width: cellWidth, height: 8)
                if index < lit {
                    ink.setFill()
                    NSBezierPath(roundedRect: rect, xRadius: 1.2, yRadius: 1.2).fill()
                } else {
                    strokeCell(NSBezierPath(roundedRect: rect.insetBy(dx: 0.6, dy: 0.6),
                                            xRadius: 1, yRadius: 1), ink)
                }
                x += cellWidth + gap
            }
            return true
        }
    }

    // MARK: 九宫格 — 3x3, fills bottom row first

    private static func renderGrid(_ percent: Double?, ink: NSColor, track: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 22, height: 22), flipped: false) { _ in
            let cell: CGFloat = 5
            let gap: CGFloat = 1.5
            let total = cell * 3 + gap * 2
            let originX = (22 - total) / 2
            let originY = (22 - total) / 2
            let lit = steps(percent, of: 9)
            // Fill bottom-up, left-to-right: reads as a container filling.
            for index in 0..<9 {
                let row = index / 3
                let column = index % 3
                let rect = NSRect(
                    x: originX + CGFloat(column) * (cell + gap),
                    y: originY + CGFloat(row) * (cell + gap),
                    width: cell, height: cell)
                let path = NSBezierPath(roundedRect: rect, xRadius: 1.2, yRadius: 1.2)
                if index < lit {
                    ink.setFill()
                    path.fill()
                } else {
                    strokeCell(NSBezierPath(roundedRect: rect.insetBy(dx: 0.6, dy: 0.6),
                                            xRadius: 1, yRadius: 1), ink)
                }
            }
            return true
        }
    }

    // MARK: 电量 — battery outline with a proportional fill

    private static func renderBattery(_ percent: Double?, ink: NSColor, track: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 24, height: 22), flipped: false) { _ in
            let body = NSRect(x: 2, y: 7, width: 17, height: 9)
            let outline = NSBezierPath(roundedRect: body, xRadius: 2.5, yRadius: 2.5)
            outline.lineWidth = 1.2
            track.setStroke()
            outline.stroke()

            // Terminal nub, so the shape reads as a battery at a glance.
            let nub = NSBezierPath(
                roundedRect: NSRect(x: 19.6, y: 9.6, width: 1.8, height: 3.8),
                xRadius: 0.8, yRadius: 0.8)
            track.setFill()
            nub.fill()

            guard let percent else { return true }
            let inset = body.insetBy(dx: 2, dy: 2)
            let width = inset.width * fraction(percent)
            guard width > 0.5 else { return true }
            let fill = NSBezierPath(
                roundedRect: NSRect(x: inset.minX, y: inset.minY, width: width, height: inset.height),
                xRadius: 1, yRadius: 1)
            ink.setFill()
            fill.fill()
            return true
        }
    }

    // MARK: 仪表 — half dial with graduations at each quarter

    private static func renderGauge(_ percent: Double?, ink: NSColor, track: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 22, height: 22), flipped: false) { _ in
            let center = NSPoint(x: 11, y: 7.5)
            let radius: CGFloat = 7.5

            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: 180, endAngle: 0, clockwise: true)
            arc.lineWidth = 2.4
            track.setStroke()
            arc.stroke()

            // Graduations at 0 / 25 / 50 / 75 / 100.
            for step in 0...4 {
                let angle = 180 - Double(step) * 45
                let radians = angle * .pi / 180
                let inner = radius - 4.2
                let outer = radius - 2.2
                let tick = NSBezierPath()
                tick.move(to: NSPoint(
                    x: center.x + cos(radians) * inner,
                    y: center.y + sin(radians) * inner))
                tick.line(to: NSPoint(
                    x: center.x + cos(radians) * outer,
                    y: center.y + sin(radians) * outer))
                tick.lineWidth = 1
                track.setStroke()
                tick.stroke()
            }

            guard let percent else { return true }
            let sweep = 180 * Double(fraction(percent))
            guard sweep > 1 else { return true }
            let filled = NSBezierPath()
            filled.appendArc(
                withCenter: center, radius: radius,
                startAngle: 180, endAngle: 180 - sweep, clockwise: true)
            filled.lineWidth = 2.4
            filled.lineCapStyle = .round
            ink.setStroke()
            filled.stroke()
            return true
        }
    }

    // MARK: 刻度 — continuous bar with quarter graduations above it

    private static func renderTicks(_ percent: Double?, ink: NSColor, track: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 24, height: 22), flipped: false) { _ in
            let barX: CGFloat = 3
            let barWidth: CGFloat = 18
            let barY: CGFloat = 7

            // Graduations sit directly on top of the bar rather than floating
            // above it, so the glyph reads as one object instead of two.
            for step in 0...4 {
                let x = barX + barWidth * CGFloat(step) / 4
                let isMajor = step % 2 == 0
                let tick = NSBezierPath(rect: NSRect(
                    x: min(x - 0.5, barX + barWidth - 1),
                    y: 12.4,
                    width: 1,
                    height: isMajor ? 3.6 : 2.2))
                track.setFill()
                tick.fill()
            }

            let trackPath = NSBezierPath(
                roundedRect: NSRect(x: barX, y: barY, width: barWidth, height: 5),
                xRadius: 1.5, yRadius: 1.5)
            track.setFill()
            trackPath.fill()

            guard let percent else { return true }
            let width = barWidth * fraction(percent)
            guard width > 0.5 else { return true }
            let fill = NSBezierPath(
                roundedRect: NSRect(x: barX, y: barY, width: width, height: 5),
                xRadius: 1.5, yRadius: 1.5)
            ink.setFill()
            fill.fill()
            return true
        }
    }

    /// Lit cells for a stepped glyph. A cell lights only when its step is
    /// fully reached, except that any non-zero value lights the first one —
    /// otherwise 1% and 0% look identical.
    private static func steps(_ percent: Double?, of count: Int) -> Int {
        guard let percent, percent > 0 else { return 0 }
        let exact = Double(count) * Double(fraction(percent))
        return max(1, min(count, Int(exact.rounded(.down)) + (exact < 1 ? 1 : 0)))
    }

    // MARK: 数字 — monospaced percent text

    private static func renderPercent(_ percent: Double?, ink: NSColor) -> NSImage {
        let text = percent.map { "\(Int($0.rounded()))%" } ?? "--"
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: ink,
            ])
        let textSize = attributed.size()
        let size = NSSize(width: max(20, ceil(textSize.width) + 2), height: 22)
        return NSImage(size: size, flipped: false) { _ in
            attributed.draw(at: NSPoint(
                x: (size.width - textSize.width) / 2,
                y: (size.height - textSize.height) / 2))
            return true
        }
    }
}

extension Color {
    init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

/// Brand logo (thesvg) with SF Symbol fallback.
///
/// Several brand marks ship as a single flat colour — Codex, Kimi, z.ai and
/// OpenCode are black; Cursor, Grok and Manus are white. Drawn as-is, each of
/// them disappears against one of the two appearances. Monochrome marks are
/// therefore detected and drawn as templates so they take the foreground
/// colour; multi-colour marks (Claude, Gemini, DeepSeek, MiniMax) keep theirs.
struct ProviderGlyph: View {
    let id: ProviderID
    var size: CGFloat = 18
    /// Renders the logo as a solid ink silhouette (for selected tiles on accent background).
    var ink: Bool = false
    /// Forces the colour of a monochrome mark.
    ///
    /// Needed wherever the background is not the window's own: the always-dark
    /// surfaces (dock, widget, island) resolve `Color.primary` against the
    /// system appearance, which in light mode is black — and the black marks
    /// (Codex, Cursor, OpenCode, z.ai, Kimi) then vanish into a black panel.
    var tint: Color?

    private var monochromeColour: Color {
        if let tint { return tint }
        return ink ? Design.ink : Color.primary
    }

    var body: some View {
        if tint != nil, let mark = Self.logo(for: id, dark: true) {
            // A mark cut for black surfaces — Kimi's white K without the
            // black tile it ships on, which on a black strip left a mark half
            // the size of its neighbours'. Drawn as-is: it already carries the
            // colours it needs against black.
            Image(nsImage: mark.image)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else if let logo = Self.logo(for: id) {
            if logo.isMonochrome {
                Image(nsImage: logo.image)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .foregroundStyle(monochromeColour)
            } else {
                Image(nsImage: logo.image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .saturation(ink ? 0 : 1)
                    .brightness(ink ? -1 : 0)
            }
        } else {
            Image(systemName: id.symbolName)
                .font(.system(size: size * 0.85, weight: .semibold))
                .foregroundStyle(monochromeColour)
        }
    }

    struct Logo {
        let image: NSImage
        let isMonochrome: Bool
    }

    /// `dark`: the `<id>-dark.png` variant, present only for marks whose
    /// shipping form does not survive a black background; nil otherwise.
    static func logo(for id: ProviderID, dark: Bool = false) -> Logo? {
        let key = "\(id.rawValue)\(dark ? "-dark" : "")"
        if let cached = Self.cache[key] { return cached }
        guard let url = Self.logoURL(for: id, dark: dark), let image = NSImage(contentsOf: url) else {
            return nil
        }
        let logo = Logo(image: image, isMonochrome: Self.isMonochrome(image))
        Self.cache[key] = logo
        return logo
    }

    /// True when every visible pixel is (near-)unsaturated — i.e. the mark
    /// carries no brand colour of its own and is safe to recolour.
    private static func isMonochrome(_ image: NSImage) -> Bool {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else { return false }
        let step = max(1, min(bitmap.pixelsWide, bitmap.pixelsHigh) / 24)
        var sampled = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: step) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: step) {
                guard let color = bitmap.colorAt(x: x, y: y),
                      let rgb = color.usingColorSpace(.sRGB),
                      rgb.alphaComponent > 0.5
                else { continue }
                sampled += 1
                let maxC = max(rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
                let minC = min(rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
                if maxC > 0, (maxC - minC) / maxC > 0.15 { return false }
            }
        }
        return sampled > 0
    }

    private static var cache: [String: Logo] = [:]

    /// Looks in the packaged app bundle first, then the SwiftPM resource bundle (dev runs).
    /// Never touches `Bundle.module`, whose generated accessor traps when the bundle is absent.
    static func logoURL(for id: ProviderID, dark: Bool = false) -> URL? {
        let fileName = "\(id.rawValue)\(dark ? "-dark" : "").png"
        let fm = FileManager.default
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("logos/\(fileName)"))
        }
        candidates.append(
            Bundle.main.bundleURL
                .appendingPathComponent("QuotaBar_QuotaBar.bundle")
                .appendingPathComponent("logos/\(fileName)"))
        return candidates.first { fm.fileExists(atPath: $0.path) }
    }
}

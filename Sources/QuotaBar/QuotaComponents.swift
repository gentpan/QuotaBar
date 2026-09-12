import AppKit
import SwiftUI
import QuotaCore

// MARK: - Motion

/// One motion vocabulary, after codex-island and openusage.
enum Motion {
    /// codex-island's strong ease-out (Emil Kowalski's curve).
    static let strongEaseOut = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.28)
    static let chartSwap = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.22)
    static let hoverFade = Animation.easeOut(duration: 0.12)
    static let pageSwipe = Animation.timingCurve(0.25, 0.82, 0.25, 1, duration: 0.36)
    /// Opening is leisurely, closing is snappy.
    static let openMorph = Animation.spring(response: 0.42, dampingFraction: 0.82)
    static let closeMorph = Animation.spring(response: 0.30, dampingFraction: 0.88)
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.80)

    /// The owner's Reduce Animations switch, or the system's Reduce Motion.
    @MainActor
    static var reduced: Bool {
        ConfigStore.shared.experience.reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    @MainActor
    static func animation(_ animation: Animation) -> Animation? {
        reduced ? nil : animation
    }
}

extension View {
    /// Applies the Reduce Animations preference to everything under it.
    func honoursReducedMotion() -> some View {
        transaction { transaction in
            if Motion.reduced {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
    }
}

private struct BlurModifier: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View { content.blur(radius: radius) }
}

extension AnyTransition {
    /// Blur, scale and fade: two crossfading shapes read as one morph.
    static var chartSwap: AnyTransition {
        .modifier(active: BlurModifier(radius: 3), identity: BlurModifier(radius: 0))
            .combined(with: .opacity)
            .combined(with: .scale(scale: 0.96))
    }

    static var detailReveal: AnyTransition {
        .modifier(active: BlurModifier(radius: 2), identity: BlurModifier(radius: 0))
            .combined(with: .opacity)
            .combined(with: .scale(scale: 0.98, anchor: .top))
    }
}

/// Scales a pressed surface to 0.94 for 110ms: a press that is seen to land.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.94
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.easeOut(duration: 0.11), value: configuration.isPressed)
    }
}

/// A tap target that presses like a button but fires in panels that are
/// never key, where SwiftUI's `Button` does not.
struct Pressable<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var pressed = false

    var body: some View {
        label()
            .scaleEffect(pressed ? 0.94 : 1)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeOut(duration: 0.08)) { pressed = true }
                action()
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(110))
                    withAnimation(.easeOut(duration: 0.11)) { pressed = false }
                }
            }
    }
}

// MARK: - Colours

enum Palette {
    static let live = Color(hex: "3DD68C")
    static let amber = Color(hex: "F5A524")
    static let red = Color(hex: "E5484D")
    static let cobalt = Color(hex: "0047AB")
    /// codex-island's figure colours.
    static let figureAmber = Color(hex: "E8A85A")
    static let figureRed = Color(hex: "E65F5F")
}

// MARK: - Quota row

/// One quota window as every surface draws it: title and pace note, the bar
/// with its even-pace tick, the figure and the reset.
///
/// After openusage: a click on the figure flips used/left everywhere, a
/// click on the reset flips countdown/clock time everywhere, and hovering the
/// bar says where the current rate lands at reset. After codex-island: the
/// urgency can colour the figure instead of the bar.
struct QuotaRowView: View {
    @ObservedObject var store: UsageStore
    let id: ProviderID
    let window: UsageWindow
    var compact = false
    /// Double-click picks this window for the provider's single figure.
    var allowsPick = true

    @State private var hovered = false

    private var used: Double? { window.usedPercent }
    private var pace: WindowPace? { window.pace() }
    private var verdict: PaceVerdict? { pace?.verdict }
    private var experience: ExperiencePrefs { store.experience }

    var body: some View {
        let followed = store.headlineWindow(for: id)?.id == window.id
        let picked = store.pickedHeadlineWindow(for: id) == window.id
        VStack(alignment: .leading, spacing: compact ? 3 : 5) {
            HStack(spacing: 5) {
                Text(window.scope ?? window.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let badge = window.shortLabel, window.scope != nil {
                    Text(badge)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                }
                if followed, used != nil {
                    Image(systemName: picked ? "circle.inset.filled" : "circle")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(picked ? Color(hex: id.accentHex) : .white.opacity(0.35))
                        .help(picked
                            ? L10n.t("The ring follows this window", "圆环按这个窗口显示")
                            : L10n.t("The fullest window, which the ring follows", "用得最满的窗口，圆环按它显示"))
                }
                Spacer(minLength: Design.space2)
                if store.justReset(id, window: window.id) {
                    JustResetChip(color: id.accent)
                } else {
                    paceNote
                }
            }
            meter
            HStack {
                figure
                Spacer(minLength: Design.space2)
                reset
            }
        }
        .modifier(ResetFlash(active: store.justReset(id, window: window.id), color: id.accent))
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(hovered && allowsPick && used != nil ? 0.05 : 0)))
        .padding(.horizontal, -6)
        .padding(.vertical, -4)
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(Motion.hoverFade) { hovered = inside } }
        .onTapGesture(count: 2) {
            guard allowsPick, used != nil else { return }
            withAnimation(Motion.animation(.easeOut(duration: 0.15))) {
                store.setHeadlineWindow(picked ? nil : window.id, for: id)
            }
        }
    }

    // MARK: Pieces

    @ViewBuilder
    private var paceNote: some View {
        switch verdict {
        case .spent:
            flame(L10n.t("Limit reached", "已到上限"), tappable: false)
        case .over:
            if let seconds = pace?.runOutSeconds {
                flame(QuotaFormat.runOutText(in: seconds, format: experience.resetTimeFormat, clock: experience.clockStyle), tappable: true)
            } else {
                flame(nil, tappable: false)
            }
        case .close:
            if let pace {
                Text(L10n.t("~\(Int(max(1, 100 - pace.projectedPercent).rounded()))% spare", "约 \(Int(max(1, 100 - pace.projectedPercent).rounded()))% 余量"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Palette.amber)
                    .help(projectionHelp)
            }
        case .ahead:
            if experience.alwaysShowPace, let pace {
                Text(L10n.t("~\(Int((100 - pace.projectedPercent).rounded()))% left at reset", "重置时约剩 \(Int((100 - pace.projectedPercent).rounded()))%"))
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
            }
        case nil:
            EmptyView()
        }
    }

    private func flame(_ text: String?, tappable: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "flame.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Palette.red)
            if let text {
                Text(text)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if tappable { store.toggleResetFormat() } }
        .help(projectionHelp)
    }

    private var meter: some View {
        let shown = used.map { store.meterMode.shownPercent(fromUsed: $0) }
        return Meter(
            percent: shown,
            tint: fillColor,
            style: store.meterStyle,
            height: compact ? 4 : 5)
            .paceTick(window, mode: store.meterMode, always: experience.alwaysShowPace)
            .help(projectionHelp)
            .animation(Motion.animation(.easeOut(duration: 0.3)), value: shown)
    }

    private var fillColor: Color {
        guard let used else { return .clear }
        switch experience.urgencyStyle {
        case .bar:
            return Color(hex: UsageRamp.hex(used: used))
        case .figure:
            return Color(hex: id.accentHex)
        case .pace:
            switch verdict {
            case .ahead: return Palette.live
            case .close: return Palette.amber
            case .over, .spent: return Palette.red
            case nil:
                // No rate to judge by — a balance, a fresh window: the level.
                if used >= 90 { return Palette.red }
                if used >= 80 { return Palette.amber }
                return Palette.live
            }
        }
    }

    private var figureColor: Color {
        guard experience.urgencyStyle == .figure, let used else { return .white.opacity(0.6) }
        if used >= 90 { return Palette.figureRed }
        if used >= 70 { return Palette.figureAmber }
        return .white
    }

    @ViewBuilder
    private var figure: some View {
        if let used {
            let shown = store.meterMode.shownPercent(fromUsed: used)
            let text = store.meterMode == .used
                ? L10n.t("\(QuotaFormat.percent(shown)) used", "已用 \(QuotaFormat.percent(shown))")
                : L10n.t("\(QuotaFormat.percent(shown)) left", "剩余 \(QuotaFormat.percent(shown))")
            let other = store.meterMode == .used
                ? L10n.t("\(QuotaFormat.percent(100 - used)) left", "剩余 \(QuotaFormat.percent(100 - used))")
                : L10n.t("\(QuotaFormat.percent(used)) used", "已用 \(QuotaFormat.percent(used))")
            Text(text)
                .font(.system(size: 11, weight: experience.urgencyStyle == .figure ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(figureColor)
                .contentTransition(.numericText(value: shown))
                .contentShape(Rectangle())
                .onTapGesture { store.toggleUsedLeft() }
                .help(other)
        } else {
            Text(window.detail ?? "—")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var reset: some View {
        if let resetsAt = window.resetsAt {
            let other = QuotaFormat.resetText(
                to: resetsAt,
                format: experience.resetTimeFormat == .countdown ? .exact : .countdown,
                clock: experience.clockStyle)
            Text(store.resetText(resetsAt))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
                .contentShape(Rectangle())
                .onTapGesture { store.toggleResetFormat() }
                .help(other)
        } else if used != nil, let detail = window.detail {
            Text(detail)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
                .lineLimit(1)
        }
    }

    /// The one number the row does not already show: where the rate lands.
    private var projectionHelp: String {
        guard let pace, let verdict else { return "" }
        let projected = pace.projectedPercent
        switch verdict {
        case .spent: return L10n.t("Limit reached", "已到上限")
        case .ahead: return L10n.t("~\(Int((100 - projected).rounded()))% left at reset", "按当前速度，重置时约剩 \(Int((100 - projected).rounded()))%")
        case .close: return L10n.t("~\(Int(projected.rounded()))% used at reset", "按当前速度，重置时约用掉 \(Int(projected.rounded()))%")
        case .over:
            let over = Int((projected - 100).rounded())
            return over > 0
                ? L10n.t("~\(over)% over the limit at reset", "按当前速度，重置时约超出 \(over)%")
                : L10n.t("~100% used at reset", "按当前速度，重置时正好用完")
        }
    }
}

// MARK: - Pace tick

extension View {
    /// openusage's even-pace tick over a bar, where the window is close to
    /// or past running out (or always, when asked).
    func paceTick(_ window: UsageWindow, mode: MeterMode, always: Bool) -> some View {
        overlay(alignment: .leading) {
            if let pace = window.pace(), let verdict = pace.verdict,
               verdict == .close || verdict == .over || (always && verdict == .ahead)
            {
                GeometryReader { proxy in
                    let fraction = mode == .used ? pace.tickFraction : 1 - pace.tickFraction
                    let x = min(max(proxy.size.width * fraction - 1, 0), proxy.size.width - 2)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.white.opacity(0.85))
                        .frame(width: 2, height: proxy.size.height + 4)
                        .offset(x: x, y: -2)
                }
            }
        }
    }
}

// MARK: - Trend bars

/// Thirty days of tokens as thin bars; hover says the peak and the range.
struct TrendBars: View {
    let days: [ArchiveSummary.Day]
    let accent: Color
    var height: CGFloat = 26
    @State private var hoveredIndex: Int?

    var body: some View {
        let peak = max(1, days.map(\.tokens).max() ?? 1)
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(day.tokens > 0 ? accent.opacity(hoveredIndex == index ? 1 : 0.8) : Color.white.opacity(0.12))
                    .frame(height: day.tokens > 0 ? max(2, height * CGFloat(day.tokens) / CGFloat(peak)) : 2)
                    .onHover { inside in hoveredIndex = inside ? index : (hoveredIndex == index ? nil : hoveredIndex) }
                    .help("\(QuotaFormat.shortDay(day.day))：\(QuotaFormat.compact(day.tokens)) tokens · \(QuotaFormat.money(day.usd))")
            }
        }
        .frame(height: height, alignment: .bottom)
        .help(summaryHelp)
    }

    private var summaryHelp: String {
        guard let first = days.first, let last = days.last,
              let top = days.max(by: { $0.tokens < $1.tokens }), top.tokens > 0
        else { return "" }
        return L10n.t(
            "Peak \(QuotaFormat.shortDay(top.day)) · \(QuotaFormat.compact(top.tokens)) tokens · \(QuotaFormat.shortDay(first.day))–\(QuotaFormat.shortDay(last.day)), from local logs",
            "峰值 \(QuotaFormat.shortDay(top.day)) · \(QuotaFormat.compact(top.tokens)) tokens · \(QuotaFormat.shortDay(first.day))–\(QuotaFormat.shortDay(last.day))，来自本地日志")
    }
}

// MARK: - Model breakdown

/// Models ranked by dollars: name and cost, share and tokens, a share bar.
/// Long tails fold into "Other" — past the top five or under 5%.
struct ModelBreakdownList: View {
    let title: String
    let models: [ModelSpend]
    let counting: TokenCounting

    var body: some View {
        let total = max(0.000_001, models.reduce(0) { $0 + $1.usd })
        let rows = folded(total: total)
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            if rows.isEmpty {
                Text(L10n.t("No data", "暂无数据"))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
            }
            ForEach(rows, id: \.name) { row in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(row.name)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(QuotaFormat.money(row.usd))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    HStack {
                        Text("\(Int((row.usd / total * 100).rounded()))%")
                        Spacer()
                        Text("\(QuotaFormat.compact(row.tokens)) tokens")
                    }
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.1))
                            Capsule().fill(row.color).frame(width: max(2, proxy.size.width * row.usd / total))
                        }
                    }
                    .frame(height: 3)
                }
            }
        }
        .padding(12)
        .frame(width: 260, alignment: .leading)
    }

    private struct Row {
        let name: String
        let usd: Double
        let tokens: Int
        let color: Color
    }

    private func folded(total: Double) -> [Row] {
        var rows: [Row] = []
        var other = (usd: 0.0, tokens: 0)
        for (index, model) in models.enumerated() {
            let share = model.usd / total
            if index < 5, share >= 0.05 {
                rows.append(Row(name: model.model, usd: model.usd, tokens: model.tokens(counting), color: Color(hex: model.source.accentHex)))
            } else {
                other.usd += model.usd
                other.tokens += model.tokens(counting)
            }
        }
        if other.usd > 0 || other.tokens > 0 {
            rows.append(Row(name: L10n.t("Other", "其他"), usd: other.usd, tokens: other.tokens, color: .white.opacity(0.4)))
        }
        return rows
    }
}

/// Shows `content` in a popover after a short hover, for rows whose detail
/// would crowd the card.
struct HoverDetail<Detail: View>: ViewModifier {
    let delay: Double
    let detail: () -> Detail
    @State private var shown = false
    @State private var task: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                task?.cancel()
                if inside {
                    task = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(delay))
                        guard !Task.isCancelled else { return }
                        shown = true
                    }
                } else {
                    shown = false
                }
            }
            .popover(isPresented: $shown, arrowEdge: .leading) {
                detail()
                    .background(Color.black)
                    .environment(\.colorScheme, .dark)
            }
    }
}

extension View {
    func hoverDetail<Detail: View>(delay: Double = 0.45, @ViewBuilder _ detail: @escaping () -> Detail) -> some View {
        modifier(HoverDetail(delay: delay, detail: detail))
    }
}

// MARK: - Transient pill

/// "Copied to clipboard" and friends: a capsule that pops in and out.
struct TransientPill: View {
    let symbol: String
    let text: String
    var tint: Color = Palette.live

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
            Text(text).font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color(white: 0.13)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
        .transition(.scale(scale: 0.85).combined(with: .opacity))
    }
}

// MARK: - Count-up figure

/// codex-island's slot-machine reveal: a money figure counts from where the
/// eye last saw it to the new value over 0.65s, cubic ease-out.
struct CountUpMoney: View {
    let usd: Double
    var font: Font = .system(size: 26, weight: .semibold, design: .monospaced)
    var color: Color = .white
    var compact = false

    @State private var start: Double = 0
    @State private var target: Double = 0
    @State private var began = Date.distantPast
    private static let duration = 0.65

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: !animating)) { context in
            Text(format(value(at: context.date)))
                .font(font)
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .onAppear {
            start = 0
            target = usd
            began = Motion.reduced ? .distantPast : Date()
        }
        .onChange(of: usd) { _, new in
            start = value(at: Date())
            target = new
            began = Motion.reduced ? .distantPast : Date()
        }
    }

    private var animating: Bool { Date().timeIntervalSince(began) < Self.duration }

    private func value(at date: Date) -> Double {
        let t = min(1, max(0, date.timeIntervalSince(began) / Self.duration))
        let eased = 1 - pow(1 - t, 3)
        return start + (target - start) * eased
    }

    private func format(_ value: Double) -> String {
        compact ? QuotaFormat.moneyCompact(value) : QuotaFormat.money(value)
    }
}

// MARK: - Breathing dot

/// codex-island's live dot: teal with a slow 2.4s breath and a halo, a small
/// bump each time fresh data lands; dim and still when inactive.
struct BreathingDot: View {
    var active = true
    var color: Color = Palette.live
    /// Changes when data lands; the dot bumps.
    var pulse: Int = 0
    @State private var bump: CGFloat = 1

    var body: some View {
        Group {
            if active && !Motion.reduced {
                TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                    let phase = context.date.timeIntervalSinceReferenceDate
                    let breath = 0.6 + 0.4 * (sin(phase * 2.6) * 0.5 + 0.5)
                    ZStack {
                        Circle().fill(color.opacity(0.9))
                        Circle()
                            .stroke(color, lineWidth: 1)
                            .scaleEffect(CGFloat(1 + breath * 0.6))
                            .opacity(0.55 * (1 - breath))
                    }
                    .frame(width: 6, height: 6)
                    .shadow(color: color.opacity(0.55), radius: 3)
                }
            } else {
                Circle()
                    .fill(active ? color : Color.white.opacity(0.25))
                    .frame(width: 6, height: 6)
            }
        }
        .frame(width: 6, height: 6)
        .scaleEffect(bump)
        .onChange(of: pulse) { _, _ in
            guard !Motion.reduced else { return }
            withAnimation(Motion.strongEaseOut) { bump = 1.18 }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(140))
                withAnimation(Motion.strongEaseOut) { bump = 1 }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Copy as image

/// Renders a view at 4× into a PNG on the clipboard, after openusage's
/// share screenshot.
@MainActor
enum CardImageExporter {
    static let scale: CGFloat = 4

    static func image<V: View>(_ view: V, scale: CGFloat = 4) -> NSImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let cgImage = renderer.cgImage else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale))
    }

    static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    @discardableResult
    static func copy<V: View>(_ view: V, text: String? = nil) -> Bool {
        guard let image = image(view), let png = pngData(image) else {
            NSSound.beep()
            return false
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        if let text { item.setString(text, forType: .string) }
        return pasteboard.writeObjects([item])
    }
}

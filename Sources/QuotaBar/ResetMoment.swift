import SwiftUI
import QuotaCore

// MARK: - The reset moment, drawn

/// Every piece takes the provider's own colour: Claude's orange, Codex's
/// blue. A reset is that provider's news, and a single green shared by all
/// of them clashed with the rings and bars that already wear those colours.
extension ProviderID {
    var accent: Color { Color(hex: accentHex) }
}

/// What a surface needs to play one reset: the window that had been fullest
/// leads, and the rest are counted.
struct ResetBanner: Equatable {
    let id = UUID()
    let provider: ProviderID
    let name: String
    let others: Int
    let usedBefore: Double
    let usedNow: Double
    let windowID: String

    var leftBefore: Double { max(0, 100 - usedBefore) }
    var leftNow: Double { max(0, 100 - usedNow) }

    init(events: [ResetEvent]) {
        let lead = events.max { $0.previousUsed < $1.previousUsed } ?? events[0]
        provider = lead.provider
        name = lead.name
        others = events.count - 1
        usedBefore = lead.previousUsed
        usedNow = lead.usedNow
        windowID = lead.windowID
    }

    init(provider: ProviderID, name: String, others: Int, usedBefore: Double, usedNow: Double, windowID: String = "") {
        self.provider = provider
        self.name = name
        self.others = others
        self.usedBefore = usedBefore
        self.usedNow = usedNow
        self.windowID = windowID
    }

    var detail: String {
        let base = "\(provider.displayName) · \(name)"
        return others > 0 ? base + L10n.t(" and \(others) more", "，另有 \(others) 个") : base
    }
}

/// A figure that counts from one value to another once it appears.
struct CountUpNumber: View {
    let from: Double
    let to: Double
    var delay: Double = 0.3
    var duration: Double = 1.0
    var settled = false
    @State private var value: Double

    init(from: Double, to: Double, delay: Double = 0.3, duration: Double = 1.0, settled: Bool = false) {
        self.from = from
        self.to = to
        self.delay = delay
        self.duration = duration
        self.settled = settled
        _value = State(initialValue: settled ? to : from)
    }

    var body: some View {
        Text("\(Int(value.rounded()))")
            .contentTransition(.numericText(value: value))
            .monospacedDigit()
            .onAppear {
                guard !settled else { return }
                withAnimation(Motion.animation(.easeOut(duration: duration).delay(delay))) { value = to }
            }
    }
}

/// A ring that draws itself from one fraction to another in the provider's
/// colour — the island's banner and the dock's card open on it.
struct RefillRing: View {
    let color: Color
    let from: Double
    let to: Double
    var lineWidth: CGFloat = 3
    var delay: Double = 0.45
    var settled = false
    @State private var fraction: Double

    init(color: Color, from: Double, to: Double, lineWidth: CGFloat = 3, delay: Double = 0.45, settled: Bool = false) {
        self.color = color
        self.from = from
        self.to = to
        self.lineWidth = lineWidth
        self.delay = delay
        self.settled = settled
        _fraction = State(initialValue: settled ? to : from)
    }

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.14), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.012, min(fraction, 1)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .onAppear {
            guard !settled else { return }
            withAnimation(Motion.animation(.timingCurve(0.22, 0.9, 0.24, 1, duration: 1.0).delay(delay))) { fraction = to }
        }
    }
}

/// The dock's ring when its provider resets: a sweep of the provider's
/// colour runs once round the disc and fades, while two ripples spread from
/// the edge — the ring "filling" whatever the ring itself measures.
struct ResetSweep: View {
    let color: Color
    let diameter: CGFloat
    @State private var sweep: Double = 0
    @State private var sweepOpacity: Double = 1
    @State private var ripple = false
    @State private var ripple2 = false

    var body: some View {
        ZStack {
            rippleRing(ripple)
            rippleRing(ripple2)
            Circle()
                .trim(from: 0, to: sweep)
                .stroke(color, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: color.opacity(0.8), radius: 4)
                .opacity(sweepOpacity)
        }
        .frame(width: diameter, height: diameter)
        .allowsHitTesting(false)
        .onAppear {
            guard !Motion.reduced else { return }
            withAnimation(.timingCurve(0.22, 0.9, 0.24, 1, duration: 0.95).delay(0.1)) { sweep = 1 }
            withAnimation(.easeOut(duration: 1.0).delay(0.95)) { ripple = true }
            withAnimation(.easeOut(duration: 1.0).delay(1.12)) { ripple2 = true }
            withAnimation(.easeIn(duration: 0.6).delay(1.7)) { sweepOpacity = 0 }
        }
    }

    /// Kept inside the strip's 74pt: a 46pt ring grows to at most 62.
    private func rippleRing(_ on: Bool) -> some View {
        Circle()
            .stroke(color, lineWidth: 2)
            .scaleEffect(on ? 1.34 : 1)
            .opacity(on ? 0 : 0.7)
            .opacity(Motion.reduced ? 0 : 1)
    }
}

/// "Just reset" on a row for ten minutes after its window rolled over, in the
/// provider's colour, its arrow turning once as it arrives.
struct JustResetChip: View {
    var color: Color
    var compact = false
    @State private var turned = false
    @State private var shown = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: compact ? 8 : 9, weight: .bold))
                .rotationEffect(.degrees(turned ? -360 : 0))
            Text(L10n.t("Just reset", "刚刚重置"))
                .font(.system(size: compact ? 9 : 10, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.16)))
        .scaleEffect(shown ? 1 : 0.8)
        .opacity(shown ? 1 : 0)
        .onAppear {
            withAnimation(Motion.animation(.spring(response: 0.36, dampingFraction: 0.55))) { shown = true }
            withAnimation(Motion.animation(.timingCurve(0.3, 0.8, 0.3, 1, duration: 0.75).delay(0.1))) { turned = true }
        }
        .help(L10n.t("This window reset a moment ago.", "这个额度窗口刚刚重置。"))
    }
}

/// A row's background lights up in the provider's colour and fades back.
struct ResetFlash: ViewModifier {
    let active: Bool
    let color: Color
    @State private var glow = 0.0

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(color.opacity(glow))
                    .padding(.horizontal, -6)
                    .padding(.vertical, -4))
            .onAppear { if active { flash() } }
            .onChange(of: active) { _, now in if now { flash() } }
    }

    private func flash() {
        guard !Motion.reduced else { return }
        glow = 0
        withAnimation(.easeOut(duration: 0.25)) { glow = 0.2 }
        withAnimation(.easeOut(duration: 1.5).delay(0.3)) { glow = 0 }
    }
}

/// The card that slides out beside the dock's ring: the provider, "just
/// reset", what is left counting up, a bar filling in its colour, and what
/// was left before.
struct ResetCallout: View {
    @ObservedObject var store: UsageStore
    let banner: ResetBanner
    var settled = false
    @State private var fill: Double

    init(store: UsageStore, banner: ResetBanner, settled: Bool = false) {
        self.store = store
        self.banner = banner
        self.settled = settled
        _fill = State(initialValue: settled ? banner.leftNow / 100 : banner.leftBefore / 100)
    }

    private var color: Color { banner.provider.accent }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.space2) {
            HStack(spacing: Design.space2) {
                ProviderGlyph(id: banner.provider, size: 16, tint: .white)
                Text(banner.provider.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: Design.space2)
                JustResetChip(color: color, compact: true)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                CountUpNumber(from: banner.leftBefore, to: banner.leftNow, delay: 0.35, settled: settled)
                    .font(.system(size: 32, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                Text(L10n.t("% left · \(banner.name)", "% 可用 · \(banner.name)"))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.1))
                    Capsule().fill(color).frame(width: max(4, proxy.size.width * fill))
                }
            }
            .frame(height: 5)
            HStack {
                Text(L10n.t("Was \(Int(banner.leftBefore.rounded()))% left", "之前只剩 \(Int(banner.leftBefore.rounded()))%"))
                Spacer(minLength: Design.space2)
                if let resetsAt = store.states[banner.provider]?.snapshot?.windows.first(where: { $0.id == banner.windowID })?.resetsAt {
                    Text(store.resetText(resetsAt))
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.5))
            .monospacedDigit()
        }
        .padding(Design.space4)
        .frame(width: EdgeDockCoordinator.calloutWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Design.radiusPanel + 2, style: .continuous)
                .fill(Color.black.opacity(0.94))
                .overlay(
                    RoundedRectangle(cornerRadius: Design.radiusPanel + 2, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)))
        .environment(\.colorScheme, .dark)
        .onAppear {
            guard !settled else { return }
            withAnimation(Motion.animation(.timingCurve(0.22, 0.9, 0.24, 1, duration: 1.0).delay(0.45))) { fill = banner.leftNow / 100 }
        }
    }
}

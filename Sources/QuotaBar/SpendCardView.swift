import SwiftUI
import QuotaCore

// MARK: - Total spend

/// The card at the top of the menu panel, after openusage's Total Spend:
/// a metric (cost, tokens, cost per million), a period (today, yesterday,
/// 30 days), a ring by CLI with a gap between slices, the total counting up
/// in its middle, and a legend whose rows open the model breakdown on hover.
struct SpendCardView: View {
    @ObservedObject var store: UsageStore
    var forExport = false
    @State private var period: SpendPeriod = .today

    private var metric: SpendMetric { store.experience.spendMetric }
    private var counting: TokenCounting { store.experience.tokenCounting }
    private var spend: SpendBreakdown { store.cost.spend(period) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if !forExport {
                periodPicker
            }
            if store.isComputingCost && !store.cost.hasData {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(L10n.t("Reading local session logs…", "正在读取本地会话日志…"))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .frame(maxWidth: .infinity, minHeight: 90)
            } else if slices.isEmpty {
                Text(L10n.t("Nothing logged in this period.", "这段时间没有记录。"))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity, minHeight: 90)
            } else {
                HStack(spacing: 16) {
                    ring
                        .frame(width: 104, height: 104)
                    legend
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.05)))
        .contextMenu {
            if !forExport {
                Button(L10n.t("Copy as Image", "复制为图片")) { copyImage() }
                Button(L10n.t("Share weekly card…", "分享周用量卡片…")) { ShareStudio.open(store: store) }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            if forExport {
                Text(metric.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text("· \(period.displayName(windowDays: store.cost.windowDays))")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
            } else {
                ForEach(SpendMetric.allCases) { option in
                    Text(option.displayName)
                        .font(.system(size: 11, weight: option == metric ? .semibold : .medium))
                        .foregroundStyle(option == metric ? .white : .white.opacity(0.45))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.white.opacity(option == metric ? 0.12 : 0)))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(Motion.animation(Motion.chartSwap)) {
                                store.updateExperience { $0.spendMetric = option }
                            }
                        }
                }
            }
            Spacer(minLength: 4)
            if !forExport {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.35))
                    .help(sourcesNote)
                CalloutButton(symbol: "square.and.arrow.up", help: L10n.t("Share weekly card", "分享周用量卡片")) {
                    ShareStudio.open(store: store)
                }
                CalloutButton(symbol: "doc.on.doc", help: L10n.t("Copy as image", "复制为图片")) {
                    copyImage()
                }
            }
        }
    }

    private var sourcesNote: String {
        let names = store.cost.spend(.window).contributions.map(\.source.displayName)
        let list = names.isEmpty ? "Claude Code、Codex CLI、OpenCode" : names.joined(separator: "、")
        return L10n.t(
            "From local session logs: \(list). Dollars are estimates at list prices.",
            "来自本地会话日志：\(list)。金额按公开价格估算。")
    }

    private var periodPicker: some View {
        HStack(spacing: 2) {
            ForEach(SpendPeriod.allCases) { option in
                Text(option.displayName(windowDays: store.cost.windowDays))
                    .font(.system(size: 11, weight: option == period ? .semibold : .medium))
                    .foregroundStyle(option == period ? .white : .white.opacity(0.5))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.white.opacity(option == period ? 0.13 : 0)))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(Motion.animation(Motion.spring)) { period = option }
                    }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.06)))
    }

    // MARK: Data

    private struct Slice: Identifiable {
        let source: CostSource
        let value: Double
        let label: String
        var id: String { source.rawValue }
    }

    private var slices: [Slice] {
        CostSource.allCases.compactMap { source -> Slice? in
            let usd = spend.bySource[source] ?? 0
            let tokens = spend.tokens(from: source, counting)
            switch metric {
            case .cost:
                guard usd > 0 else { return nil }
                return Slice(source: source, value: usd, label: QuotaFormat.money(usd))
            case .tokens:
                guard tokens > 0 else { return nil }
                return Slice(source: source, value: Double(tokens), label: QuotaFormat.compact(tokens))
            case .costPerMillion:
                guard usd > 0, tokens > 0 else { return nil }
                let rate = usd / Double(tokens) * 1_000_000
                return Slice(source: source, value: rate, label: QuotaFormat.money(rate))
            }
        }
        .sorted { $0.value > $1.value }
    }

    private var centre: (value: String, unit: String, exact: String) {
        switch metric {
        case .cost:
            return (QuotaFormat.moneyCompact(spend.usd), L10n.t("spent", "花费"), QuotaFormat.money(spend.usd))
        case .tokens:
            let tokens = spend.tokens(counting)
            let compact = QuotaFormat.compact(tokens)
            let unit: String
            switch compact.last {
            case "B": unit = L10n.t("billion", "十亿")
            case "M": unit = L10n.t("million", "百万")
            case "k": unit = L10n.t("thousand", "千")
            case "T": unit = L10n.t("trillion", "万亿")
            default: unit = "tokens"
            }
            let value = compact.last?.isLetter == true ? String(compact.dropLast()) : compact
            return (value, unit, "\(tokens.formatted()) tokens")
        case .costPerMillion:
            let tokens = spend.tokens(counting)
            let rate = tokens > 0 ? spend.usd / Double(tokens) * 1_000_000 : 0
            return (QuotaFormat.money(rate), "MTok", QuotaFormat.money(rate) + " / MTok")
        }
    }

    // MARK: Ring

    private var ring: some View {
        let total = max(0.000_001, slices.reduce(0) { $0 + $1.value })
        var start = 0.0
        let arcs: [(Slice, Double, Double)] = slices.map { slice in
            // Even a tiny share keeps a visible sliver.
            let share = max(slice.value / total, 0.012)
            defer { start += share }
            return (slice, start, min(1, start + share))
        }
        return ZStack {
            ForEach(arcs, id: \.0.id) { slice, from, to in
                RingSector(start: from, end: to)
                    .fill(Color(hex: slice.source.accentHex))
            }
            VStack(spacing: 0) {
                if metric == .cost && !forExport {
                    CountUpMoney(usd: spend.usd, font: .system(size: 15, weight: .semibold, design: .monospaced), compact: true)
                } else {
                    Text(centre.value)
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                }
                Text(centre.unit)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .frame(width: 60)
            .help(centre.exact + (spend.containsEstimates ? L10n.t(" · includes estimates", " · 含估算") : ""))
        }
        .animation(Motion.animation(Motion.spring), value: period)
        .animation(Motion.animation(Motion.spring), value: metric)
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(slices) { slice in
                HStack(spacing: 7) {
                    Circle().fill(Color(hex: slice.source.accentHex)).frame(width: 7, height: 7)
                    Text(slice.source.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(slice.label)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
                .hoverDetail {
                    ModelBreakdownList(
                        title: "\(slice.source.displayName) · \(period.displayName(windowDays: store.cost.windowDays))",
                        models: spend.models.filter { $0.source == slice.source },
                        counting: counting)
                }
            }
        }
    }

    private func copyImage() {
        let card = ShareableCard(store: store) { SpendCardView(store: store, forExport: true) }
        if CardImageExporter.copy(card) {
            store.flashNotice(L10n.t("Copied to clipboard", "已复制到剪贴板"))
        }
    }
}

/// A donut slice with a hairline gap either side and its ends as
/// `animatableData`, so a re-ranked period morphs each CLI's arc into place
/// instead of smearing colours across neighbours.
struct RingSector: Shape {
    var start: Double
    var end: Double
    var innerRatio: CGFloat = 0.64
    var gap: CGFloat = 1.6

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(start, end) }
        set { start = newValue.first; end = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * innerRatio
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let full = end - start >= 0.999
        let gapAngle = full ? 0 : Double(gap / outer)
        let a0 = Angle.radians(start * 2 * .pi - .pi / 2 + gapAngle / 2)
        let a1 = Angle.radians(end * 2 * .pi - .pi / 2 - gapAngle / 2)
        guard a1.radians > a0.radians else { return Path() }
        var path = Path()
        path.addArc(center: centre, radius: outer, startAngle: a0, endAngle: a1, clockwise: false)
        path.addArc(center: centre, radius: inner, startAngle: a1, endAngle: a0, clockwise: true)
        path.closeSubpath()
        return path
    }
}

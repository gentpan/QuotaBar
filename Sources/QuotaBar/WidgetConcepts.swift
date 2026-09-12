import AppKit
import SwiftUI
import QuotaCore

// MARK: - Desktop widget concepts, for choosing before building

/// Six candidate desktop cards in the reference's language — a dark rounded
/// card, a name with a status pill, one large figure, a row of three facts,
/// a strip along the foot — drawn from this Mac's real readings and archive.
/// Rendered off-screen by `QuotaBar --widget-concepts <dir>`; nothing here is
/// wired into the widget yet.
enum WidgetConceptBoard {
    @MainActor
    static func render(directory: String) {
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let store = previewStore()
        let concepts: [(String, String, AnyView)] = [
            ("1", L10n.t("Single provider, big figure", "单个服务商 · 大数字"), AnyView(ConceptFocus(store: store, id: .claude))),
            ("2", L10n.t("Single provider, gauge", "单个服务商 · 环形仪表"), AnyView(ConceptGauge(store: store, id: .grok))),
            ("3", L10n.t("Spend trend, line", "花费趋势 · 折线图"), AnyView(ConceptTrend(store: store))),
            ("4", L10n.t("Day by day, bars", "每日对比 · 柱状图"), AnyView(ConceptDaily(store: store))),
            ("5", L10n.t("Several providers, grid", "多个服务商 · 网格"), AnyView(ConceptGrid(store: store))),
            ("6", L10n.t("Several providers, closest first", "多个服务商 · 紧迫排行"), AnyView(ConceptRanking(store: store))),
        ]
        for (number, title, view) in concepts {
            write(view.padding(28).background(wallpaper), to: url.appendingPathComponent("concept-\(number).png"))
            _ = title
        }
        let board = VStack(alignment: .leading, spacing: 34) {
            ForEach(0..<2, id: \.self) { row in
                HStack(alignment: .top, spacing: 40) {
                    ForEach(0..<3, id: \.self) { column in
                        let item = concepts[row * 3 + column]
                        VStack(alignment: .leading, spacing: 14) {
                            Text(L10n.t("Concept \(item.0): \(item.1)", "方案 \(item.0)：\(item.1)"))
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(.white.opacity(0.9))
                            item.2
                        }
                    }
                }
            }
        }
        .padding(44)
        .background(wallpaper)
        write(board, to: url.appendingPathComponent("widget-concepts.png"))
    }

    private static var wallpaper: some View {
        LinearGradient(colors: [Color(hex: "0E1726"), Color(hex: "3A2A2A"), Color(hex: "0E1726")], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    @MainActor
    private static func write(_ view: some View, to url: URL) {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:])
        else { return }
        try? png.write(to: url)
    }

    /// The last readings, the archive and the trend history this Mac has on disk.
    @MainActor
    private static func previewStore() -> UsageStore {
        let ids: [ProviderID] = [.claude, .codex, .cursor, .grok]
        var states: [ProviderID: ProviderPhase] = [:]
        var history: [ProviderID: [Double]] = [:]
        for id in ids {
            if let cached = SnapshotCache.shared.snapshot(for: id) { states[id] = .loaded(cached) }
            history[id] = UsageHistoryStore.shared.readings(for: id).map(\.percent)
        }
        let archive = UsageArchiveStore.shared.current
        let store = UsageStore.preview(enabled: ids, states: states, cost: archive.costSummary(), ledger: archive.ledger(), history: history)
        store.archive = archive
        for id in ids {
            store.serviceStatus[id] = ServiceStatus(level: .operational, description: "", pageURL: URL(string: "https://quota.bar")!, checkedAt: Date())
        }
        return store
    }
}

// MARK: - Shared chrome

private enum Concept {
    static let card = Color(hex: "1C1D21")
    static let tile = Color.white.opacity(0.05)
    static let green = Color(hex: "3DD68C")
    static let medium = CGSize(width: 344, height: 230)
    static let large = CGSize(width: 344, height: 344)

    static func figureColor(_ used: Double) -> Color {
        used >= 90 ? Palette.figureRed : used >= 70 ? Palette.figureAmber : .white
    }
}

private struct ConceptCard<Content: View>: View {
    var size: CGSize = Concept.medium
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(16)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Concept.card))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
    }
}

private struct ConceptHeader: View {
    let title: String
    var id: ProviderID?
    var plan: String?
    var pill: String = L10n.t("Operational", "运行正常")
    var pillColor: Color = Concept.green

    var body: some View {
        HStack(spacing: 8) {
            if let id {
                ProviderGlyph(id: id, size: 18, tint: .white)
            } else {
                Image(systemName: "chart.bar.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
            }
            Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
            if let plan {
                Text(plan.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.1)))
            }
            Spacer(minLength: 6)
            HStack(spacing: 5) {
                Circle().fill(pillColor).frame(width: 7, height: 7)
                Text(pill).font(.system(size: 11, weight: .medium)).foregroundStyle(pillColor)
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
            .overlay(Capsule().strokeBorder(pillColor.opacity(0.6), lineWidth: 1))
        }
    }
}

private struct ConceptFooter: View {
    let symbol: String
    let text: String
    var trailing: String = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date())
    }()

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
            Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
            Spacer()
            Image(systemName: "clock").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            Text(trailing).font(.system(size: 12, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 12).frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Concept.tile))
    }
}

private struct StatColumn: View {
    let value: String
    let label: String
    var color: Color = .white
    var symbol: String?
    var symbolColor: Color = Concept.green

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(symbolColor) }
                Text(value).font(.system(size: 17, weight: .semibold, design: .monospaced)).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.7)
            }
            Text(label).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Data helpers

@MainActor
private extension UsageStore {
    func conceptWindows(_ id: ProviderID) -> (lead: UsageWindow?, other: UsageWindow?) {
        let windows = states[id]?.snapshot?.windows.filter { $0.usedPercent != nil } ?? []
        let lead = headlineWindow(for: id) ?? windows.first
        let other = windows.first { $0.id != lead?.id && $0.horizon != lead?.horizon && $0.scope == nil }
            ?? windows.first { $0.id != lead?.id }
        return (lead, other)
    }

    func days(_ count: Int) -> [ArchiveSummary.Day] {
        let today = Calendar.current.startOfDay(for: Date())
        let start = Calendar.current.date(byAdding: .day, value: -(count - 1), to: today) ?? today
        return archive.summary(from: start, to: today, counting: experience.tokenCounting).days
    }
}

// MARK: - 1. Single provider, big figure

private struct ConceptFocus: View {
    @ObservedObject var store: UsageStore
    let id: ProviderID

    var body: some View {
        let windows = store.conceptWindows(id)
        let used = windows.lead?.usedPercent ?? 0
        let source = id.costSource
        ConceptCard {
            ConceptHeader(title: id.displayName, id: id, plan: store.states[id]?.snapshot?.planName)
            Spacer(minLength: 10)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(Int((100 - used).rounded()))")
                    .font(.system(size: 52, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Concept.figureColor(used))
                Text("%").font(.system(size: 22, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                Spacer()
            }
            Text(L10n.t("left in \(windows.lead?.title ?? "")", "\(windows.lead?.title ?? "")剩余") + (windows.lead?.resetsAt.map { " · " + QuotaFormat.resetLabel(to: $0) } ?? ""))
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
            Spacer(minLength: 10)
            HStack(spacing: 0) {
                StatColumn(value: windows.other?.usedPercent.map { "\(Int((100 - $0).rounded()))%" } ?? "—", label: windows.other?.scope ?? windows.other?.title ?? "", color: Concept.green)
                Divider().frame(height: 30).overlay(Color.white.opacity(0.12))
                StatColumn(value: source.map { QuotaFormat.usdCompact(store.cost.spend(.today).bySource[$0] ?? 0) } ?? "—", label: L10n.t("Today", "今日花费"))
                Divider().frame(height: 30).overlay(Color.white.opacity(0.12))
                StatColumn(value: source.map { QuotaFormat.compact(store.cost.spend(.today).tokens(from: $0, .all)) } ?? "—", label: L10n.t("Tokens today", "今日 token"))
            }
            Spacer(minLength: 10)
            ConceptFooter(symbol: "person.crop.circle", text: store.states[id]?.snapshot?.account ?? id.displayName)
        }
    }
}

// MARK: - 2. Single provider, gauge

private struct ConceptGauge: View {
    @ObservedObject var store: UsageStore
    let id: ProviderID

    var body: some View {
        let windows = store.conceptWindows(id)
        let used = windows.lead?.usedPercent ?? 0
        let pace = windows.lead?.pace()
        ConceptCard {
            ConceptHeader(title: id.displayName, id: id, plan: store.states[id]?.snapshot?.planName)
            Spacer(minLength: 8)
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(windows.lead?.scope ?? windows.lead?.title ?? "")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text("\(Int((100 - used).rounded()))").font(.system(size: 46, weight: .semibold, design: .monospaced)).foregroundStyle(.white)
                        Text(L10n.t("% left", "% 剩余")).font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                    }
                }
                Spacer()
                ZStack {
                    Circle().trim(from: 0, to: 0.78).stroke(Color.white.opacity(0.1), style: StrokeStyle(lineWidth: 9, lineCap: .round)).rotationEffect(.degrees(129))
                    Circle().trim(from: 0, to: 0.78 * (100 - used) / 100)
                        .stroke(Color(hex: UsageRamp.hex(used: used)), style: StrokeStyle(lineWidth: 9, lineCap: .round)).rotationEffect(.degrees(129))
                    ProviderGlyph(id: id, size: 26, tint: .white)
                }
                .frame(width: 84, height: 84)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                tile(symbol: "clock", value: windows.lead?.resetsAt.map { QuotaFormat.tick(to: $0) } ?? "—", label: L10n.t("to reset", "后重置"))
                tile(symbol: "flame", value: pace?.runOutSeconds.map { QuotaFormat.tick(to: Date().addingTimeInterval($0)) } ?? L10n.t("OK", "够用"), label: L10n.t("runs out", "预计用完"), tint: pace?.verdict == .over ? Palette.red : Concept.green)
                tile(symbol: "calendar", value: windows.other?.usedPercent.map { "\(Int((100 - $0).rounded()))%" } ?? "—", label: windows.other?.scope ?? windows.other?.title ?? "")
            }
            Spacer(minLength: 8)
            ConceptFooter(symbol: "person.crop.circle", text: store.states[id]?.snapshot?.account ?? id.displayName)
        }
    }

    private func tile(symbol: String, value: String, label: String, tint: Color = Concept.green) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
                Text(value).font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.7)
            }
            Text(label).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Concept.tile))
    }
}

// MARK: - 3. Spend trend, line

private struct ConceptTrend: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        let days = store.days(14)
        let week = days.suffix(7).reduce(0) { $0 + $1.usd }
        let today = days.last?.usd ?? 0
        let yesterday = days.dropLast().last?.usd ?? 0
        ConceptCard {
            ConceptHeader(title: L10n.t("Spend", "AI 花费"), pill: L10n.t("Live", "实时"))
            Spacer(minLength: 8)
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.t("Today", "今日")).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                    Text(QuotaFormat.usd(today)).font(.system(size: 34, weight: .semibold, design: .monospaced)).foregroundStyle(.white).minimumScaleFactor(0.6).lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(L10n.t("14 days", "近 14 天")).font(.system(size: 10, design: .monospaced)).foregroundStyle(Concept.green)
                    LineChart(values: days.map(\.usd), color: Concept.green)
                        .frame(width: 140, height: 52)
                }
            }
            Spacer(minLength: 10)
            HStack(spacing: 0) {
                // The archive is per day, so today against yesterday would
                // compare a morning with a whole day; yesterday is shown as is.
                StatColumn(value: QuotaFormat.usdCompact(yesterday), label: L10n.t("yesterday", "昨日"), color: Concept.green)
                Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 30)
                StatColumn(value: QuotaFormat.usdCompact(week), label: L10n.t("7 days", "近 7 天"))
                Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 30)
                StatColumn(value: QuotaFormat.compact(days.last?.tokens ?? 0), label: L10n.t("tokens today", "今日 token"))
            }
            .padding(.vertical, 8)
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            Spacer(minLength: 10)
            ConceptFooter(symbol: "cpu", text: store.cost.topModel ?? "—")
        }
    }
}

private struct LineChart: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            let top = max(values.max() ?? 1, 0.000_1)
            let step = values.count > 1 ? proxy.size.width / CGFloat(values.count - 1) : 0
            let points = values.enumerated().map { CGPoint(x: CGFloat($0.offset) * step, y: proxy.size.height * (1 - CGFloat($0.element / top)) ) }
            ZStack {
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: first)
                    for point in points.dropFirst() { path.addLine(to: point) }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                if let last = points.last {
                    Circle().fill(color).frame(width: 7, height: 7).position(last)
                }
            }
        }
    }
}

// MARK: - 4. Day by day, bars

private struct ConceptDaily: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        let days = store.days(7)
        let peak = max(days.map(\.tokens).max() ?? 1, 1)
        let today = days.last?.tokens ?? 0
        let average = days.dropLast().isEmpty ? 0 : days.dropLast().reduce(0) { $0 + $1.tokens } / max(1, days.count - 1)
        ConceptCard {
            ConceptHeader(title: L10n.t("Tokens", "每日用量"), pill: L10n.t("7 days", "近 7 天"))
            Spacer(minLength: 10)
            HStack(alignment: .bottom, spacing: 7) {
                ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                    let isToday = index == days.count - 1
                    VStack(spacing: 5) {
                        if isToday {
                            Text(QuotaFormat.compact(day.tokens)).font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(Concept.green)
                        }
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(isToday ? Concept.green : Color.white.opacity(0.22))
                            .frame(height: max(4, 74 * CGFloat(day.tokens) / CGFloat(peak)))
                        Text(weekday(day.day)).font(.system(size: 9)).foregroundStyle(.white.opacity(isToday ? 0.9 : 0.45))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 104, alignment: .bottom)
            Spacer(minLength: 10)
            HStack(spacing: 6) {
                StatColumn(value: QuotaFormat.compact(today), label: L10n.t("today", "今日"), color: Concept.green)
                StatColumn(value: QuotaFormat.compact(average), label: L10n.t("daily average", "日均"))
                StatColumn(value: average > 0 ? "\(Int((Double(today) / Double(average) * 100).rounded()))%" : "—", label: L10n.t("of average", "达到日均"))
            }
        }
    }

    private func weekday(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.setLocalizedDateFormatFromTemplate("EEEEE")
        return formatter.string(from: date)
    }
}

// MARK: - 5. Several providers, grid

private struct ConceptGrid: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        ConceptCard(size: Concept.large) {
            ConceptHeader(title: "QuotaBar", pill: L10n.t("All up", "全部正常"))
            Spacer(minLength: 10)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(store.enabled.prefix(4)) { id in
                    let window = store.conceptWindows(id).lead
                    let used = window?.usedPercent ?? 0
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 6) {
                            ProviderGlyph(id: id, size: 14, tint: .white)
                            Text(id.displayName).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                            Spacer()
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text("\(Int((100 - used).rounded()))").font(.system(size: 30, weight: .semibold, design: .monospaced)).foregroundStyle(Concept.figureColor(used))
                            Text("%").font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                        }
                        Meter(percent: 100 - used, tint: Color(hex: UsageRamp.hex(used: used)), style: .stepped, height: 5, track: .white.opacity(0.1))
                        Text(window?.resetsAt.map { QuotaFormat.tick(to: $0) } ?? " ").font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.45))
                    }
                    .padding(11)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Concept.tile))
                }
            }
            Spacer(minLength: 10)
            ConceptFooter(symbol: "square.grid.2x2", text: L10n.t("\(store.enabled.count) providers · left", "\(store.enabled.count) 个服务商 · 剩余"))
        }
    }
}

// MARK: - 6. Several providers, closest first

private struct ConceptRanking: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        let ranked = store.enabled.sorted { (store.conceptWindows($0).lead?.usedPercent ?? -1) > (store.conceptWindows($1).lead?.usedPercent ?? -1) }
        ConceptCard(size: Concept.large) {
            ConceptHeader(title: L10n.t("Closest to the limit", "快用完的排前面"), pill: L10n.t("Live", "实时"))
            Spacer(minLength: 12)
            VStack(spacing: 13) {
                ForEach(Array(ranked.prefix(5).enumerated()), id: \.element) { index, id in
                    let window = store.conceptWindows(id).lead
                    let used = window?.usedPercent ?? 0
                    HStack(spacing: 10) {
                        Text("\(index + 1)").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(.white.opacity(0.35)).frame(width: 12)
                        ProviderGlyph(id: id, size: 18, tint: .white)
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(id.displayName).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                                Spacer()
                                Text(window?.resetsAt.map { QuotaFormat.tick(to: $0) } ?? "").font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.45))
                                Text("\(Int((100 - used).rounded()))%").font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(Concept.figureColor(used)).frame(width: 40, alignment: .trailing)
                            }
                            Meter(percent: 100 - used, tint: Color(hex: UsageRamp.hex(used: used)), style: .continuous, height: 5, track: .white.opacity(0.1))
                                .paceTick(window ?? UsageWindow(title: ""), mode: .remaining, always: false)
                        }
                    }
                }
            }
            Spacer(minLength: 12)
            ConceptFooter(symbol: "flame", text: L10n.t("Sorted by what runs out first", "按剩余从少到多排序"))
        }
    }
}

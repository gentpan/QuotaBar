import AppKit
import SwiftUI
import UniformTypeIdentifiers
import QuotaCore

// MARK: - The usage share card, after codex-island

enum ShareMetric: String, CaseIterable, Identifiable {
    case apiValue
    case tokens

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apiValue: L10n.t("API value", "API 价值")
        case .tokens: L10n.t("Tokens", "Token 数")
        }
    }
}

enum ShareRange: String, CaseIterable, Identifiable {
    case week, month, quarter, year, all

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .week: L10n.t("Last 7 days", "最近 7 天")
        case .month: L10n.t("Last 30 days", "最近 30 天")
        case .quarter: L10n.t("Last 3 months", "最近 3 个月")
        case .year: L10n.t("This year", "今年")
        case .all: L10n.t("All time", "全部时间")
        }
    }

    /// Today and the days before it; three months is a rolling calendar range.
    func interval(now: Date = Date(), firstDay: Date?, calendar: Calendar = .current) -> (Date, Date) {
        let today = calendar.startOfDay(for: now)
        switch self {
        case .week: return (calendar.date(byAdding: .day, value: -6, to: today) ?? today, today)
        case .month: return (calendar.date(byAdding: .day, value: -29, to: today) ?? today, today)
        case .quarter:
            let back = calendar.date(byAdding: .month, value: -3, to: today) ?? today
            return (calendar.date(byAdding: .day, value: 1, to: back) ?? back, today)
        case .year:
            let year = calendar.component(.year, from: today)
            return (calendar.date(from: DateComponents(year: year, month: 1, day: 1)) ?? today, today)
        case .all: return (min(firstDay ?? today, today), today)
        }
    }
}

enum ShareFormat: String, CaseIterable, Identifiable {
    case feed, square, story

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .feed: L10n.t("Feed · 4:5", "动态 · 4:5")
        case .square: L10n.t("Square · 1:1", "方形 · 1:1")
        case .story: L10n.t("Story · 9:16", "故事 · 9:16")
        }
    }

    var size: CGSize {
        switch self {
        case .feed: CGSize(width: 540, height: 675)
        case .square: CGSize(width: 540, height: 540)
        case .story: CGSize(width: 540, height: 960)
        }
    }
}

/// White under $1K (or 100M tokens), black from there, blue from $10K (1B).
enum ShareTier: String, CaseIterable {
    case white, black, blue

    func minimum(_ metric: ShareMetric) -> Double {
        switch self {
        case .white: 0
        case .black: metric == .apiValue ? 1_000 : 100_000_000
        case .blue: metric == .apiValue ? 10_000 : 1_000_000_000
        }
    }

    static func earned(_ value: Double, metric: ShareMetric) -> ShareTier {
        allCases.reversed().first { value >= $0.minimum(metric) } ?? .white
    }

    var displayName: String {
        switch self {
        case .white: L10n.t("White card", "白卡")
        case .black: L10n.t("Black card", "黑卡")
        case .blue: L10n.t("Blue card", "蓝卡")
        }
    }

    var background: Color {
        switch self {
        case .white: Color(red: 0.956, green: 0.946, blue: 0.918)
        case .black: Color(red: 0.035, green: 0.044, blue: 0.052)
        case .blue: Color(red: 0.055, green: 0.17, blue: 0.79)
        }
    }

    var foreground: Color {
        self == .white ? Color(red: 0.10, green: 0.15, blue: 0.19) : Color(red: 0.97, green: 0.96, blue: 0.91)
    }

    func color(for source: CostSource) -> Color {
        switch (self, source) {
        case (.white, .claudeCode): Color(red: 0.75, green: 0.30, blue: 0.20)
        case (.white, .codexCLI): Color(red: 0.12, green: 0.38, blue: 0.79)
        case (.white, .openCode): Color(red: 0.05, green: 0.45, blue: 0.40)
        case (_, .claudeCode): Color(red: 0.96, green: 0.57, blue: 0.42)
        case (_, .codexCLI): Color(red: 0.52, green: 0.80, blue: 0.98)
        case (_, .openCode): Color(red: 0.45, green: 0.90, blue: 0.80)
        }
    }
}

/// The card itself, drawn at 540pt wide and exported at 2× (1080px).
struct UsageShareCard: View {
    let summary: ArchiveSummary
    let metric: ShareMetric
    let range: ShareRange
    let format: ShareFormat
    let signature: String?

    private var value: Double { metric == .apiValue ? summary.usd : Double(summary.tokens) }
    private var tier: ShareTier { ShareTier.earned(value, metric: metric) }

    var body: some View {
        let fg = tier.foreground
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("QuotaBar")
                    .font(Design.wordmark(size: 20, weight: .bold))
                Spacer()
                Text(tier.rawValue.uppercased())
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .tracking(1.6)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .overlay(Capsule().strokeBorder(fg.opacity(0.35), lineWidth: 1))
            }
            Text("\(range.displayName) · \(dateRange)")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(fg.opacity(0.65))
                .padding(.top, 6)

            Spacer(minLength: 18)

            Text(metric == .apiValue ? L10n.t("AI coding, at API prices", "按 API 价格折算的 AI 编码用量") : L10n.t("Tokens through AI coding tools", "AI 编码工具处理的 token"))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(fg.opacity(0.7))
            Text(heroText)
                .font(.system(size: format == .square ? 58 : 66, weight: .semibold, design: .monospaced))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .padding(.top, 2)

            curve
                .frame(height: format == .story ? 210 : (format == .square ? 96 : 150))
                .padding(.top, 16)

            VStack(spacing: 9) {
                ForEach(summary.sources.prefix(4)) { source in
                    HStack(spacing: 10) {
                        Circle().fill(tier.color(for: source.source)).frame(width: 10, height: 10)
                        Text(source.source.displayName)
                            .font(.system(size: 15, weight: .medium))
                        Spacer()
                        Text(metric == .apiValue ? QuotaFormat.usd(source.usd) : "\(QuotaFormat.compact(source.tokens))")
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    }
                }
            }
            .padding(.top, 16)

            Spacer(minLength: 14)

            Rectangle().fill(fg.opacity(0.18)).frame(height: 1)
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(footerFacts)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(fg.opacity(0.7))
                    if let signature, !signature.isEmpty {
                        Text(signature)
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
                Spacer()
                Text("quota.bar")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(fg.opacity(0.6))
            }
            .padding(.top, 12)
        }
        .foregroundStyle(fg)
        .padding(34)
        .frame(width: format.size.width, height: format.size.height, alignment: .topLeading)
        .background(tier.background)
        .environment(\.colorScheme, tier == .white ? .light : .dark)
    }

    private var heroText: String {
        metric == .apiValue ? QuotaFormat.usd(summary.usd) : QuotaFormat.compact(summary.tokens)
    }

    private var dateRange: String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return "\(formatter.string(from: summary.start))–\(formatter.string(from: summary.end))"
    }

    private var footerFacts: String {
        var parts = [L10n.t("\(summary.activeDays) active days", "活跃 \(summary.activeDays) 天")]
        if let top = summary.models.first { parts.append(top.model) }
        if metric == .apiValue { parts.append(L10n.t("estimate, not a bill", "估算值，并非账单")) }
        return parts.joined(separator: " · ")
    }

    /// The running total, drawn as a line over a translucent fill.
    private var curve: some View {
        let points = summary.cumulative(metric == .apiValue ? \.usd : \.tokensDouble)
        return GeometryReader { proxy in
            let top = max(points.last ?? 0, 0.000_001)
            let step = points.count > 1 ? proxy.size.width / CGFloat(points.count - 1) : proxy.size.width
            let path = Path { path in
                for (index, point) in points.enumerated() {
                    let location = CGPoint(x: CGFloat(index) * step, y: proxy.size.height * (1 - CGFloat(point / top)))
                    if index == 0 { path.move(to: location) } else { path.addLine(to: location) }
                }
            }
            ZStack {
                Path { area in
                    area.addPath(path)
                    area.addLine(to: CGPoint(x: CGFloat(max(points.count - 1, 0)) * step, y: proxy.size.height))
                    area.addLine(to: CGPoint(x: 0, y: proxy.size.height))
                    area.closeSubpath()
                }
                .fill(tier.foreground.opacity(0.08))
                path.stroke(tier.foreground.opacity(0.9), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

extension ArchiveSummary.Day {
    var tokensDouble: Double { Double(tokens) }
}

// MARK: - Studio

/// The window where the card is made: pick the metric, range, format and
/// signature, then share, save a 1080px PNG, or copy image and text.
struct ShareStudioView: View {
    @ObservedObject var store: UsageStore
    @State private var metric: ShareMetric = .apiValue
    @State private var range: ShareRange = .week
    @State private var format: ShareFormat = .feed
    @State private var actualSize = false
    @State private var signature: String
    @State private var showsSignature: Bool
    @State private var notice: String?

    init(store: UsageStore) {
        self.store = store
        _signature = State(initialValue: store.experience.shareSignature)
        _showsSignature = State(initialValue: store.experience.shareShowsSignature)
    }

    private var summary: ArchiveSummary {
        let (start, end) = range.interval(firstDay: store.archive.firstDay)
        return store.archive.summary(from: start, to: end, counting: store.experience.tokenCounting)
    }

    private var card: UsageShareCard {
        UsageShareCard(summary: summary, metric: metric, range: range, format: format, signature: showsSignature ? signature : nil)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView([.vertical, .horizontal]) {
                card
                    .scaleEffect(actualSize ? 1 : previewScale, anchor: .topLeading)
                    .frame(
                        width: format.size.width * (actualSize ? 1 : previewScale),
                        height: format.size.height * (actualSize ? 1 : previewScale),
                        alignment: .topLeading)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
                    .padding(28)
                    .animation(Motion.animation(Motion.chartSwap), value: format)
            }
            .scrollIndicators(.never)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(white: 0.11))

            controls
                .frame(width: 280)
                .background(Color(white: 0.16))
        }
        .frame(minWidth: 760, minHeight: 620)
        .environment(\.colorScheme, .dark)
        .onChange(of: signature) { _, value in store.updateExperience { $0.shareSignature = value } }
        .onChange(of: showsSignature) { _, value in store.updateExperience { $0.shareShowsSignature = value } }
    }

    private var previewScale: CGFloat { format == .story ? 0.55 : 0.8 }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.t("Usage card", "用量卡片"))
                .font(.system(size: 16, weight: .semibold))
            if store.isUpdatingArchive {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(L10n.t("Reading local logs…", "正在读取本地日志…"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            picker(L10n.t("Show", "显示"), ShareMetric.allCases, selection: $metric, label: \.displayName)
            picker(L10n.t("Range", "时间范围"), ShareRange.allCases, selection: $range, label: \.displayName)
            picker(L10n.t("Format", "比例"), ShareFormat.allCases, selection: $format, label: \.displayName)

            VStack(alignment: .leading, spacing: 6) {
                Toggle(L10n.t("Sign it", "署名"), isOn: $showsSignature)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                TextField(L10n.t("Your name or @handle", "你的名字或 @账号"), text: $signature)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!showsSignature)
            }

            let tier = ShareTier.earned(metric == .apiValue ? summary.usd : Double(summary.tokens), metric: metric)
            Text(L10n.t(
                "\(tier.displayName): the colour follows the figure — black from \(metric == .apiValue ? "$1K" : "100M"), blue from \(metric == .apiValue ? "$10K" : "1B").",
                "\(tier.displayName)：颜色由数值决定，\(metric == .apiValue ? "$1K" : "1 亿") 起为黑卡，\(metric == .apiValue ? "$10K" : "10 亿") 起为蓝卡。"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(L10n.t("Actual size", "实际大小"), isOn: $actualSize)
                .toggleStyle(.switch)
                .controlSize(.small)

            Spacer()

            if let notice {
                TransientPill(symbol: "checkmark.circle.fill", text: notice)
            }
            ShareButton(items: { shareItems() })
                .frame(height: 30)
            HStack {
                Button(L10n.t("Save PNG…", "保存 PNG…")) { save() }
                Button(L10n.t("Copy", "复制")) { copy() }
            }
            .controlSize(.regular)
            Text(L10n.t("Counted by local calendar day, cache included unless Settings says otherwise. Dollars are estimates at API prices, not a bill. Made on this Mac.", "按本地日历日统计，是否包含缓存以设置为准。金额为按 API 价格的估算，并非订阅账单。全部在本机生成。"))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
    }

    private func picker<T: Hashable & Identifiable>(_ title: String, _ options: [T], selection: Binding<T>, label: KeyPath<T, String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Picker(title, selection: selection) {
                ForEach(options) { option in Text(option[keyPath: label]).tag(option) }
            }
            .labelsHidden()
        }
    }

    // MARK: Output

    private func renderPNG() -> Data? {
        guard let image = CardImageExporter.image(card, scale: 2) else { return nil }
        return CardImageExporter.pngData(image)
    }

    private var caption: String {
        let figure = metric == .apiValue ? QuotaFormat.usd(summary.usd) : "\(QuotaFormat.compact(summary.tokens)) tokens"
        return L10n.t(
            "\(range.displayName): \(figure) of AI coding\(metric == .apiValue ? " at API prices" : ""). Tracked with QuotaBar · https://quota.bar",
            "\(range.displayName)的 AI 编码用量：\(figure)\(metric == .apiValue ? "（按 API 价格估算）" : "")。用 QuotaBar 记录 · https://quota.bar")
    }

    private func shareItems() -> [Any] {
        var items: [Any] = [caption]
        if let png = renderPNG() {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("QuotaBar-usage-\(range.rawValue).png")
            try? png.write(to: url)
            items.insert(url, at: 0)
        }
        return items
    }

    private func save() {
        guard let png = renderPNG() else { NSSound.beep(); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "QuotaBar-usage-\(range.rawValue).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try png.write(to: url)
            flash(L10n.t("Saved", "已保存"))
        } catch {
            NSSound.beep()
        }
    }

    private func copy() {
        guard let png = renderPNG() else { NSSound.beep(); return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        item.setString(caption, forType: .string)
        pasteboard.writeObjects([item])
        flash(L10n.t("Image and text copied", "图片和文案已复制"))
    }

    private func flash(_ text: String) {
        withAnimation(Motion.animation(Motion.spring)) { notice = text }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.8))
            withAnimation(Motion.animation(Motion.spring)) { if notice == text { notice = nil } }
        }
    }
}

/// The macOS share menu, anchored to a real button.
private struct ShareButton: NSViewRepresentable {
    let items: () -> [Any]

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: L10n.t("Share…", "分享…"), target: context.coordinator, action: #selector(Coordinator.share(_:)))
        button.bezelStyle = .rounded
        button.keyEquivalent = "\r"
        button.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.items = items
    }

    func makeCoordinator() -> Coordinator { Coordinator(items: items) }

    final class Coordinator: NSObject {
        var items: () -> [Any]
        init(items: @escaping () -> [Any]) { self.items = items }

        @objc func share(_ sender: NSButton) {
            let picker = NSSharingServicePicker(items: items())
            picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }
}

@MainActor
enum ShareStudio {
    private static var window: NSWindow?

    static func open(store: UsageStore) {
        MenuPanelController.shared.close()
        Task { await store.updateArchive() }
        let window = self.window ?? {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 720),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false)
            window.title = L10n.t("Share Usage Card", "分享用量卡片")
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ShareStudioView(store: store))
            window.center()
            return window
        }()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Once per app version, when there was usage this week, the studio
    /// opens by itself — codex-island's nudge. Never on a first launch.
    private static var nudgeChecked = false

    static func openOnceAfterUpdate(store: UsageStore) {
        guard !nudgeChecked else { return }
        nudgeChecked = true
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !ConfigStore.shared.wasFreshInstall,
              store.experience.shareCardShownForVersion != version
        else { return }
        let week = ShareRange.week.interval(firstDay: nil)
        guard store.archive.summary(from: week.0, to: week.1).hasData else { return }
        store.updateExperience { $0.shareCardShownForVersion = version }
        open(store: store)
    }
}

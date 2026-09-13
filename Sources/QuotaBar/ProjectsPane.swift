import AppKit
import SwiftUI
import QuotaCore

// MARK: - Projects pane: where the tokens went, project by project

/// Which repository each token went to, which CLI and which way of driving it
/// (terminal, desktop app, editor), from this Mac's session logs. Everything
/// here is local; a project reaches quota.run only when its switch is on.
struct ProjectsPane: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var run: RunCenter
    @State private var period: ProjectPeriod = .month
    @State private var selected: String?
    @State private var showAll = false

    var body: some View {
        let overview = store.projectArchive.overview(from: period.start(), to: Date())
        HStack(spacing: Design.space2) {
            GlassSegmented(
                options: ProjectPeriod.allCases.map { (value: $0, label: $0.label) },
                selection: period,
                onSelect: { value in withAnimation(.easeOut(duration: 0.2)) { period = value } })
            .frame(width: 280)
            HelpMark(L10n.t(
                "A project is a Git repository, recognised by its remote, so every checkout and worktree of it counts together; work outside a repository is grouped by folder. Cost is an estimate at list prices. Paths stay on this Mac.",
                "一个项目就是一个 Git 仓库，按远端地址识别，所以同一个仓库的不同目录、worktree 算在一起；不在仓库里的按文件夹分。花费按公开价目估算。路径只留在这台 Mac 上。"))
            Spacer(minLength: 0)
            if store.isUpdatingArchive {
                HStack(spacing: Design.space1 + 2) {
                    ProgressView().controlSize(.mini)
                    Text(L10n.t("Reading session logs…", "正在读取会话日志…"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }

        if !store.projectArchive.fullScanDone {
            placeholder(L10n.t(
                "Reading every session log once to sort it by project. On a large log tree the first pass takes a while.",
                "第一次要把全部会话日志按项目整理一遍，日志很多时要等一会儿。"))
        } else if overview.projects.isEmpty {
            placeholder(L10n.t("No token use in this period.", "这段时间没有用量。"))
        } else {
            ProjectTotalsCard(overview: overview)
            ProjectRankingCard(overview: overview, selected: $selected, showAll: $showAll, run: run)
            if let key = selected ?? overview.projects.first?.id,
               let summary = overview.projects.first(where: { $0.id == key })
            {
                ProjectDetailCard(summary: summary, period: period, run: run)
                    .id(key)
            }
        }
        Color.clear.frame(height: 0).onAppear { store.wantLedger() }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
            .padding(.horizontal, Design.space6)
            .background(RoundedRectangle(cornerRadius: Design.radiusPanel, style: .continuous).fill(Design.surface))
    }
}

enum ProjectPeriod: String, CaseIterable, Hashable {
    case week
    case month
    case quarter
    case year

    var label: String {
        switch self {
        case .week: L10n.t("7 days", "7 天")
        case .month: L10n.t("30 days", "30 天")
        case .quarter: L10n.t("90 days", "90 天")
        case .year: L10n.t("365 days", "365 天")
        }
    }

    var days: Int {
        switch self {
        case .week: 7
        case .month: 30
        case .quarter: 90
        case .year: 365
        }
    }

    func start(now: Date = Date(), calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: now)) ?? now
    }
}

extension CostSource {
    var chartColor: Color { Color(hex: accentHex) }
}

// MARK: Totals

private struct ProjectTotalsCard: View {
    let overview: ProjectOverview

    var body: some View {
        SettingsCard(L10n.t("Overview", "概览")) {
            HStack(alignment: .top, spacing: Design.space4) {
                figure(L10n.t("Projects", "项目"), "\(overview.projects.filter { !$0.info.isUnknown }.count)")
                figure(L10n.t("Est. cost", "等价花费"), QuotaFormat.usd(overview.usd))
                figure(L10n.t("Tokens", "Token"), QuotaFormat.compact(overview.tokens))
                figure(L10n.t("Sessions", "会话"), "\(overview.sessions)")
                figure(L10n.t("Ways of working", "编程方式"), "\(overview.waysOfWorking)")
            }
            ProjectWaysRow(pairs: overview.modePairs)
        }
    }

    private func figure(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "Claude Code · Desktop app", one chip per way of working.
private struct ProjectWaysRow: View {
    let pairs: Set<String>

    var body: some View {
        let items = pairs.sorted().compactMap { pair -> (CostSource, CodingMode)? in
            let parts = pair.split(separator: "|")
            guard parts.count == 2, let source = CostSource(rawValue: String(parts[0])) else { return nil }
            return (source, CodingMode(rawValue: String(parts[1])) ?? .other)
        }
        if !items.isEmpty {
            HStack(spacing: Design.space2) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 5) {
                        Circle().fill(item.0.chartColor).frame(width: 6, height: 6)
                        Text("\(item.0.displayName) · \(item.1.displayName)")
                            .font(.system(size: 11))
                    }
                    .padding(.vertical, 3)
                    .padding(.horizontal, 7)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Design.surface))
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: Ranking

private struct ProjectRankingCard: View {
    let overview: ProjectOverview
    @Binding var selected: String?
    @Binding var showAll: Bool
    @ObservedObject var run: RunCenter

    var body: some View {
        let rows = showAll ? overview.projects : Array(overview.projects.prefix(12))
        let top = overview.projects.first?.usd ?? 0
        SettingsCard(L10n.t("Projects by cost", "项目排行（按花费）")) {
            VStack(spacing: 2) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, summary in
                    row(index + 1, summary, top: top)
                }
            }
            if overview.projects.count > 12 {
                Button(showAll
                       ? L10n.t("Show the top 12", "只看前 12 个")
                       : L10n.t("Show all \(overview.projects.count)", "显示全部 \(overview.projects.count) 个")) {
                    withAnimation(.easeOut(duration: 0.2)) { showAll.toggle() }
                }
                .glassAction(compact: true)
            }
        }
    }

    private func row(_ rank: Int, _ summary: ProjectSummary, top: Double) -> some View {
        let isSelected = (selected ?? overview.projects.first?.id) == summary.id
        let isPublic = run.projectSharing.isPublic(summary.info.key)
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { selected = summary.id }
        } label: {
            HStack(spacing: Design.space3) {
                Text("\(rank)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, alignment: .trailing)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: Design.space1 + 2) {
                        Text(summary.info.displayName)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                        if isPublic {
                            Text(L10n.t("Public", "已公开"))
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Design.switchOn.opacity(0.18)))
                        }
                        Text(subtitle(summary))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    ShareBar(summary: summary, top: top)
                        .frame(height: 6)
                }
                Spacer(minLength: Design.space2)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(QuotaFormat.usd(summary.usd))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    Text("\(QuotaFormat.compact(summary.tokens)) · \(L10n.t("\(summary.sessions) sessions", "\(summary.sessions) 个会话"))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 150, alignment: .trailing)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, Design.space2)
            .background(
                RoundedRectangle(cornerRadius: Design.radiusTile, style: .continuous)
                    .fill(isSelected ? Design.surfaceStrong : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func subtitle(_ summary: ProjectSummary) -> String {
        if summary.info.isUnknown { return L10n.t("started outside any folder", "不在任何项目目录里") }
        if let repo = summary.info.repo { return repo }
        return summary.info.key.hasPrefix("local:")
            ? L10n.t("Git repository without a remote", "没有远端的 Git 仓库")
            : L10n.t("folder", "文件夹")
    }
}

/// The project's cost against the biggest project's, split by CLI.
private struct ShareBar: View {
    let summary: ProjectSummary
    let top: Double

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width * (top > 0 ? summary.usd / top : 0)
            ZStack(alignment: .leading) {
                Capsule().fill(Design.track.opacity(0.5))
                HStack(spacing: 1) {
                    ForEach(summary.sources, id: \.source) { item in
                        Rectangle()
                            .fill(item.source.chartColor)
                            .frame(width: max(1, width * (summary.usd > 0 ? item.share.usd / summary.usd : 0)))
                    }
                }
                .frame(width: max(2, width), alignment: .leading)
                .clipShape(Capsule())
            }
        }
    }
}

// MARK: Detail

private struct ProjectDetailCard: View {
    let summary: ProjectSummary
    let period: ProjectPeriod
    @ObservedObject var run: RunCenter
    @State private var hoveredDay: Int?

    var body: some View {
        SettingsCard(summary.info.displayName) {
            HStack(alignment: .top, spacing: Design.space4) {
                figure(L10n.t("Est. cost", "等价花费"), QuotaFormat.usd(summary.usd))
                figure(L10n.t("Tokens", "Token"), QuotaFormat.compact(summary.tokens))
                figure(L10n.t("Active days", "活跃天数"), "\(summary.activeDays)")
                figure(L10n.t("Active time", "活跃时长"), hours(summary.activeMinutes))
                figure(L10n.t("Per session", "每个会话"), summary.sessions > 0 ? QuotaFormat.usd(summary.usd / Double(summary.sessions)) : "—")
            }
            dailyChart
            HStack(alignment: .top, spacing: Design.space6) {
                breakdown(L10n.t("By tool", "按工具"), summary.sources.map { ($0.source.displayName, $0.share.tokens, $0.source.chartColor) })
                breakdown(L10n.t("By way of working", "按编程方式"), summary.modes.map { ($0.mode.displayName, $0.tokens, Color.primary.opacity(0.55)) })
            }
            models
            WeekHourGrid(values: summary.weekHours)
            if !summary.info.isUnknown {
                ProjectSharingRow(summary: summary, run: run)
            }
        }
    }

    private func figure(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hours(_ minutes: Int) -> String {
        minutes < 60 ? L10n.t("\(minutes) min", "\(minutes) 分钟") : String(format: L10n.t("%.1f h", "%.1f 小时"), Double(minutes) / 60)
    }

    /// One bar per day, dollars; hover a bar for the day's figures.
    private var dailyChart: some View {
        let days = summary.daily
        let peak = max(days.map(\.usd).max() ?? 0, 0.0001)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(hoveredDay.flatMap { days.indices.contains($0) ? days[$0] : nil }.map {
                    "\(QuotaFormat.shortDay($0.day)) · \(QuotaFormat.usd($0.usd)) · \(QuotaFormat.compact($0.tokens))"
                } ?? L10n.t("Cost per day", "每天的花费"))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                Spacer()
            }
            GeometryReader { geometry in
                let gap: CGFloat = days.count > 120 ? 0 : 1
                let width = max(1, (geometry.size.width - gap * CGFloat(max(0, days.count - 1))) / CGFloat(max(1, days.count)))
                HStack(alignment: .bottom, spacing: gap) {
                    ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                        RoundedRectangle(cornerRadius: min(2, width / 2), style: .continuous)
                            .fill(day.usd > 0 ? Design.switchOn.opacity(hoveredDay == index ? 1 : 0.75) : Design.track.opacity(0.4))
                            .frame(width: width, height: max(day.usd > 0 ? 2 : 1, geometry.size.height * day.usd / peak))
                            .onHover { inside in hoveredDay = inside ? index : (hoveredDay == index ? nil : hoveredDay) }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .frame(height: 72)
        }
    }

    private func breakdown(_ title: String, _ items: [(String, Int, Color)]) -> some View {
        let total = max(1, items.reduce(0) { $0 + $1.1 })
        return VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: Design.space2) {
                    Circle().fill(item.2).frame(width: 6, height: 6)
                    Text(item.0).font(.system(size: 12)).lineLimit(1)
                    Spacer(minLength: Design.space2)
                    Text("\(Int((Double(item.1) / Double(total) * 100).rounded()))%")
                        .font(.system(size: 12, design: .monospaced))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var models: some View {
        let list = Array(summary.models.prefix(5))
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.t("Models", "模型")).font(.system(size: 11)).foregroundStyle(.secondary)
                ForEach(list, id: \.model) { model in
                    HStack(spacing: Design.space2) {
                        Circle().fill(model.source.chartColor).frame(width: 6, height: 6)
                        Text(model.model).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                        Spacer(minLength: Design.space2)
                        Text(QuotaFormat.compact(model.tokens)).font(.system(size: 12, design: .monospaced))
                        Text(QuotaFormat.usd(model.usd))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .trailing)
                    }
                }
            }
        }
    }
}

/// Seven rows (Monday first) of 24 hours: when this project gets worked on.
private struct WeekHourGrid: View {
    let values: [[Int]]
    @State private var hovered: (Int, Int)?

    var body: some View {
        let flat = values.flatMap { $0 }.filter { $0 > 0 }.sorted()
        let weekdays = L10n.t("Mon Tue Wed Thu Fri Sat Sun", "一 二 三 四 五 六 日").split(separator: " ").map(String.init)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(hovered.map { "\(weekdays[$0.0]) \($0.1):00 · \(QuotaFormat.compact(values[$0.0][$0.1]))" }
                     ?? L10n.t("When it's worked on (tokens by weekday and hour)", "什么时候在做（按星期和小时的 token）"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            VStack(spacing: 2) {
                ForEach(0..<7, id: \.self) { day in
                    HStack(spacing: 2) {
                        Text(weekdays[day])
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, alignment: .leading)
                        ForEach(0..<24, id: \.self) { hour in
                            let value = day < values.count && hour < values[day].count ? values[day][hour] : 0
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(value > 0 ? Design.switchOn.opacity(level(value, in: flat)) : Design.track.opacity(0.35))
                                .frame(maxWidth: .infinity)
                                .frame(height: 12)
                                .onHover { inside in hovered = inside ? (day, hour) : nil }
                        }
                    }
                }
            }
        }
    }

    private func level(_ value: Int, in sorted: [Int]) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = sorted.firstIndex { $0 >= value } ?? sorted.count - 1
        return 0.25 + 0.75 * Double(rank + 1) / Double(sorted.count)
    }
}

// MARK: Sharing

/// The project's switch for quota.run, its public name, and where it lives
/// there once it is up.
private struct ProjectSharingRow: View {
    let summary: ProjectSummary
    @ObservedObject var run: RunCenter
    @State private var name: String = ""

    var body: some View {
        let key = summary.info.key
        let isPublic = run.projectSharing.isPublic(key)
        VStack(alignment: .leading, spacing: Design.space2) {
            Divider().opacity(0.4)
            HStack(alignment: .center, spacing: Design.space3) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.t("Public on quota.run", "公开到 quota.run"))
                        .font(.system(size: 13, weight: .medium))
                    Text(caption(isPublic: isPublic))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Design.space3)
                if run.account != nil {
                    GlassSwitch(isOn: Binding(
                        get: { run.projectSharing.isPublic(key) },
                        set: { run.setProjectPublic($0, info: summary.info) }))
                }
            }
            if run.account != nil, isPublic {
                HStack(spacing: Design.space2) {
                    Text(L10n.t("Name on quota.run", "公开名称"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    GlassTextField(placeholder: summary.info.displayName, text: $name)
                        .frame(maxWidth: 240)
                        .onSubmit { run.renameProject(summary.info, to: name) }
                    Button(L10n.t("Save", "保存")) { run.renameProject(summary.info, to: name) }
                        .glassAction(compact: true)
                        .disabled(name == run.projectSharing.name(for: summary.info))
                    Spacer(minLength: 0)
                    if let slug = run.projectSharing.slug(for: key), let username = run.account?.username,
                       let url = URL(string: "https://quota.run/\(L10n.isChinese ? "zh/" : "")@\(username)/\(slug)")
                    {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            Label(L10n.t("View on quota.run", "在 quota.run 查看"), systemImage: "arrow.up.right.square")
                        }
                        .glassAction(compact: true)
                    }
                }
            }
        }
        .onAppear { name = run.projectSharing.name(for: summary.info) }
    }

    private func caption(isPublic: Bool) -> String {
        guard run.account != nil else {
            return L10n.t(
                "Sign in to Quota Run first (Settings → Quota Run). Until a project is made public, nothing about it leaves this Mac.",
                "先在「设置 → Quota Run」登录。项目公开之前，关于它的一切都不离开这台 Mac。")
        }
        if isPublic {
            return L10n.t(
                "Shown on your profile and the project board: its name, the repository (\(summary.info.repo ?? "none")), and tokens and cost per day by tool. Never the folder path or anything from the sessions.",
                "会出现在你的主页和项目榜上：名称、仓库（\(summary.info.repo ?? "无")）、每天按工具分的 token 和花费。不会有文件夹路径，也不会有会话里的任何内容。")
        }
        return L10n.t(
            "Private: its tokens still count in your totals as \"other projects\", without a name.",
            "不公开：它的 token 仍然算进你的总量，但只显示为「其他项目」，没有名字。")
    }
}

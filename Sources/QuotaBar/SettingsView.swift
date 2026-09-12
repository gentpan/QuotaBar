import SwiftUI
import ServiceManagement
import QuotaCore

// MARK: - Navigation

/// A sidebar rather than a tab bar.
///
/// Two tabs meant every preference that was not a provider shared one scrolling
/// `Form`: refresh, language, icon style, meter mode, presentation, dock,
/// widget, alerts, launch-at-login, history, updates and about, in a 560pt
/// window. Nothing was findable and the pane never fit.
enum SettingsSection: String, CaseIterable, Identifiable {
    case providers
    case usage
    case status
    case appearance
    case presentation
    case alerts
    case general
    case updates
    case feedback
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .providers: L10n.t("Providers", "服务商")
        case .usage: L10n.t("Usage", "用量统计")
        case .status: L10n.t("Service status", "服务状态")
        case .appearance: L10n.t("Appearance", "外观")
        case .presentation: L10n.t("Presentation", "展示方式")
        case .alerts: L10n.t("Alerts", "提醒")
        case .general: L10n.t("General", "通用")
        case .updates: L10n.t("Updates", "更新")
        case .feedback: L10n.t("Feedback", "反馈")
        case .about: L10n.t("About", "关于")
        }
    }

    var subtitle: String {
        switch self {
        case .providers:
            L10n.t("Which services to track, and how each one signs in.",
                   "要跟踪哪些服务，以及每个服务如何登录。")
        case .usage:
            L10n.t("Tokens from this Mac's CLI session logs: a year grid and the figures behind it.",
                   "本机 CLI 会话日志里的 token 用量：全年热力图，以及各周期的数据量。")
        case .status:
            L10n.t("What each provider's public status page says right now.",
                   "各服务商公开状态页此刻的读数，以及正在发生的事件。")
        case .appearance:
            L10n.t("What the menu-bar glyph looks like and what it counts.",
                   "菜单栏图标长什么样、数的是什么。")
        case .presentation:
            L10n.t("Where the numbers live besides the menu bar.",
                   "除了菜单栏，数字还显示在哪里。")
        case .alerts:
            L10n.t("When to be told a limit is getting close.",
                   "什么时候提醒你额度快用完了。")
        case .general:
            L10n.t("Language, refresh cadence and stored history.",
                   "语言、刷新频率和已记录的历史。")
        case .updates:
            L10n.t("The installed version, and how new ones arrive.",
                   "当前版本，以及新版本如何到来。")
        case .feedback:
            L10n.t("Tell us what broke, or what you want.",
                   "告诉我们哪里不对，或者想要什么。")
        case .about:
            L10n.t("Version, and what this app does with your data.",
                   "版本信息，以及这个应用如何处理你的数据。")
        }
    }

    var symbol: String {
        switch self {
        case .providers: "square.grid.2x2"
        case .usage: "chart.bar.xaxis"
        case .status: "waveform.path.ecg"
        case .appearance: "paintbrush"
        case .presentation: "macwindow"
        case .alerts: "bell"
        case .general: "gearshape"
        case .updates: "arrow.down.circle"
        case .feedback: "text.bubble"
        case .about: "info.circle"
        }
    }
}

// MARK: - Shell

struct SettingsView: View {
    @ObservedObject var store: UsageStore
    /// Off for the snapshot renderer, which does not lay out `ScrollView`
    /// contents — a scrolling pane would render as a single clipped row. It is
    /// also what tells the window it is being rendered off-screen: the vibrancy
    /// backdrop and the glass are AppKit-composited and come out empty, so both
    /// swap to flat fills of the same metrics.
    var scrollable = true

    @State private var section: SettingsSection
    private let initialExpanded: ProviderID?

    init(
        store: UsageStore,
        scrollable: Bool = true,
        section: SettingsSection = .providers,
        expanded: ProviderID? = nil)
    {
        self.store = store
        self.scrollable = scrollable
        self.initialExpanded = expanded
        _section = State(initialValue: section)
    }

    private var isRendering: Bool { !scrollable }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            detail
        }
        // Ideal 840x700 — tall enough that all eleven providers fit without
        // scrolling while collapsed, which is the pane people open this for —
        // but allowed to fill. A fixed height leaves the content 28pt short of
        // a `fullSizeContentView` window and the titlebar's own background
        // shows through as a band across the top of the pane.
        .frame(
            minWidth: 840, idealWidth: 840, maxWidth: .infinity,
            minHeight: 700, idealHeight: 700, maxHeight: .infinity)
        .background(backdrop)
        // `NSHostingView` honours the window's safe area, and a
        // `fullSizeContentView` window's safe area excludes the titlebar. That
        // inset is why the content began 28pt down and the window's own
        // background showed through above it as a second bar.
        .ignoresSafeArea()
        .background(chrome)
        .environment(\.glassDisabled, isRendering)
        .tint(Design.accent)
    }

    private var backdrop: some View {
        Design.settingsBackground
    }

    @ViewBuilder
    private var chrome: some View {
        if !isRendering {
            WindowChrome()
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: Design.space1) {
            identity
                .padding(.horizontal, Design.space3)
                .padding(.bottom, Design.space3)

            nav

            Spacer(minLength: 0)

            buildStamp
        }
        .padding(Design.space2)
        .padding(.top, Design.titlebarInset)
        .frame(width: Design.sidebarWidth)
        .background(Design.sidebarSurface)
    }

    private var identity: some View {
        HStack(spacing: Design.space2 + 2) {
            appIcon
            Text("QuotaBar")
                .font(Design.wordmark(size: 16))
                .foregroundStyle(Design.sidebarInk)
            Spacer(minLength: 0)
        }
    }

    /// Version and packaging time, at the foot of the sidebar rather than under
    /// the name. It answers "is this the build I just made" during a dev loop
    /// and "when did the updater last replace this" afterwards — a reference,
    /// not part of the app's identity, so it sits where references go.
    private var buildStamp: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(Self.version)
            if let built = Self.buildDate {
                Text(built)
            }
        }
        .font(.system(size: 10))
        .monospacedDigit()
        .foregroundStyle(Design.sidebarInkDim)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Design.space3 + 2)
        .padding(.bottom, Design.space2)
    }

    @ViewBuilder
    private var appIcon: some View {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url)
        {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28)
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Design.sidebarInk)
                .frame(width: 28, height: 28)
                .overlay {
                    Image(systemName: "chart.bar.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Design.sidebarSurface)
                }
        }
    }

    /// The rail sits behind the rows rather than beside them, so its bloom
    /// spills under the label the way real light would. It is drawn once for
    /// the whole list: the lit segment travels between rows, so it cannot
    /// belong to any one of them.
    private var nav: some View {
        VStack(spacing: 0) {
            ForEach(SettingsSection.allCases) { item in
                sidebarItem(item)
            }
        }
        .background(alignment: .topLeading) {
            SidebarRail(
                count: SettingsSection.allCases.count,
                index: SettingsSection.allCases.firstIndex(of: section) ?? 0)
        }
    }

    private func sidebarItem(_ item: SettingsSection) -> some View {
        let isSelected = item == section
        return Button {
            section = item
        } label: {
            HStack(spacing: Design.space2 + 2) {
                Image(systemName: item.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 18)
                Text(item.title)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                Spacer(minLength: 0)
                if item == .providers {
                    Text("\(store.enabled.count)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Design.sidebarInkDim)
                }
            }
            .padding(.leading, Design.space3 + 2)
            .padding(.trailing, Design.space2 + 2)
            .frame(height: Design.sidebarRow)
            // No filled block: the rail is what marks the selection, and a
            // block would fight it. Grey to white is the second half of that.
            .foregroundStyle(isSelected ? Design.sidebarGlow : Design.sidebarInkDim)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.25), value: isSelected)
    }

    // MARK: Detail

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(section.title)
                    .font(.system(size: 20, weight: .semibold))
                Text(section.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Design.space6)
            .padding(.top, Design.titlebarInset)
            .padding(.bottom, Design.space4)

            if scrollable {
                // `.never`, not `.hidden`: hidden still flashes the bar
                // whenever the content grows, as it does when a row opens.
                ScrollView { paneBody }
                    .scrollIndicators(.never)
            } else {
                paneBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var paneBody: some View {
        VStack(alignment: .leading, spacing: Design.space3) {
            pane
        }
        .padding(.horizontal, Design.space6)
        .padding(.bottom, Design.space6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassGroup()
    }

    @ViewBuilder
    private var pane: some View {
        switch section {
        case .providers: ProvidersPane(store: store, expanded: initialExpanded)
        case .usage: UsagePane(store: store)
        case .status: StatusPane(store: store)
        case .appearance: AppearancePane(store: store)
        case .presentation: PresentationPane(store: store)
        case .alerts: AlertsPane(store: store)
        case .general: GeneralPane(store: store)
        case .updates: UpdatesPane(store: store)
        case .feedback: FeedbackPane(store: store)
        case .about: AboutPane()
        }
    }

    /// Stamped into Info.plist by `package_app.sh`; absent in the dev loop,
    /// which runs a bare binary with no bundle at all.
    static var buildDate: String? {
        Bundle.main.object(forInfoDictionaryKey: "QBBuildDate") as? String
    }

    static var version: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(version) (\(build))"
    }
}

// MARK: - Service status

/// Every provider on one page: the band, the page's own sentence about
/// what is going on, and when it was last asked. The rows in 服务商 carry
/// the band alone; this is where the sentence fits.
struct StatusPane: View {
    @ObservedObject var store: UsageStore
    /// The row that has been opened to show the page's own sentence.
    @State private var expanded: ProviderID?

    var body: some View {
        // Only the providers with a page. A row saying "none" for the rest
        // was five rows of nothing; the footnote names them once.
        let listed = ProviderID.allCases.filter { StatusPages.page(for: $0) != nil }
        SettingsCard {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(listed) { id in
                    row(id)
                    if id != listed.last {
                        Divider().opacity(0.3)
                    }
                }
            }
        }
        SettingFootnote(L10n.t(
            "Read from each provider's public status page every five minutes, without signing in. Click a row for the page's own account of what is going on. Providers without a page anyone can read are not listed.",
            "每五分钟读取各服务商的公开状态页，无需登录。点击一行可看状态页对当前情况的说明。没有可公开读取状态页的服务商不在此列出。"))
    }

    /// One line per provider — name, band, when it was asked — and the
    /// page's sentence only once the row is opened. A band is enough to
    /// scan the list; the sentence is for the row you stopped at.
    private func row(_ id: ProviderID) -> some View {
        let status = store.serviceStatus[id]
        let isOpen = expanded == id
        return VStack(alignment: .leading, spacing: Design.space2) {
            HStack(spacing: Design.space2 + 2) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(status == nil ? Color.clear : Color.secondary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .frame(width: 10)
                ProviderGlyph(id: id, size: 18)
                    .frame(width: 20)
                Text(id.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .frame(width: 130, alignment: .leading)
                if let status {
                    ServiceStatusBadge(status: status, size: 12, ink: .primary)
                        .frame(width: 96, alignment: .leading)
                    // The provider's own service — claude.ai, the Codex CLI —
                    // over the last 30 days, without opening the row. The
                    // rest of what the page lists waits inside.
                    if let primary = StatusPages.primaryComponent(for: id, in: status.components),
                       let days = store.uptime[primary.id], !days.isEmpty
                    {
                        let recent = Array(days.suffix(30))
                        Text(String(format: "%.2f%%", UptimeDay.uptimePercent(recent)))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .trailing)
                        UptimeStrip(days: recent)
                    } else {
                        Spacer(minLength: Design.space2)
                    }
                    Text(L10n.t(
                        "checked \(QuotaFormat.age(of: status.checkedAt))",
                        "\(QuotaFormat.age(of: status.checkedAt))检查"))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .frame(width: 92, alignment: .trailing)
                } else {
                    Text(L10n.t("Not read yet", "尚未读取"))
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: Design.space2)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard status != nil else { return }
                withAnimation(.snappy(duration: 0.2)) { expanded = isOpen ? nil : id }
                if !isOpen { store.loadUptime(for: id) }
            }

            if isOpen, let status {
                VStack(alignment: .leading, spacing: Design.space2 + 2) {
                    // "Claude Code 运行正常" would only repeat the line under
                    // it; the sentence is worth a line when something is wrong.
                    if status.focus.isEmpty || !status.level.isHealthy {
                        Text(status.description)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    if !status.focus.isEmpty {
                        // The badge above follows the coding services; say
                        // which, and what the rest of the page is reporting.
                        Text(L10n.t(
                            "Status follows \(status.focus.joined(separator: ", "))",
                            "状态按 \(status.focus.joined(separator: "、")) 判断"))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                        ForEach(status.elsewhere, id: \.self) { incident in
                            Text(L10n.t("Elsewhere on the page: \(incident)", "其他组件：\(incident)"))
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                    // Every part the page reports on, each with its band and
                    // — where the page answers for it — its last 90 days.
                    ForEach(status.components) { component in
                        ComponentRow(component: component, days: store.uptime[component.id])
                    }
                    Button {
                        NSWorkspace.shared.open(status.pageURL)
                    } label: {
                        Label(L10n.t("Open the status page", "打开状态页"), systemImage: "arrow.up.right")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(status.pageURL.absoluteString)
                }
                .padding(.leading, 10 + Design.space2 + 2 + 20 + Design.space2 + 2)
                .padding(.bottom, Design.space1)
            }
        }
        .padding(.vertical, Design.space2 + 2)
    }
}

/// One component: name, band, and its 90 days as a strip of ticks with
/// the uptime figure the days add up to.
private struct ComponentRow: View {
    let component: ServiceComponent
    let days: [UptimeDay]?

    var body: some View {
        HStack(spacing: Design.space3) {
            Text(component.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 190, alignment: .leading)
            ServiceStatusBadge(status: ServiceStatus(
                level: component.level, description: component.level.displayName,
                pageURL: URL(string: "https://example.invalid")!, checkedAt: .distantPast), size: 11)
                .frame(width: 80, alignment: .leading)
            // The page keeps 90 days; the owner found that a wall of ticks.
            // The last 30 are shown and the figure covers the same 30 — the
            // figure first, the strip running out to the row's end.
            if let days, !days.isEmpty {
                let recent = Array(days.suffix(30))
                Text(uptimeFigure(recent))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
                UptimeStrip(days: recent)
            } else {
                Spacer(minLength: 0)
            }
        }
    }

    private func uptimeFigure(_ days: [UptimeDay]) -> String {
        String(format: "%.2f%%", UptimeDay.uptimePercent(days))
    }
}

/// 90 ticks, one per day, oldest on the left, in the day's band colour.
private struct UptimeStrip: View {
    let days: [UptimeDay]
    private let gap: CGFloat = 1.5

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, (proxy.size.width - gap * CGFloat(days.count - 1)) / CGFloat(days.count))
            HStack(spacing: gap) {
                ForEach(days.indices, id: \.self) { index in
                    // A clean day in the same green the quota bars start
                    // from, at full strength; the paler tint read as washed out.
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(days[index].level == .operational
                            ? Color(hex: UsageRamp.hex(used: 0))
                            : Color(hex: days[index].level.colorHex))
                        .frame(width: width)
                        .help(help(days[index]))
                }
            }
        }
        .frame(height: 14)
    }

    private func help(_ day: UptimeDay) -> String {
        let date = DateFormatter.localizedString(from: day.date, dateStyle: .medium, timeStyle: .none)
        let events = day.events.isEmpty ? day.level.displayName : day.events.joined(separator: "；")
        return "\(date)：\(events)"
    }
}

// MARK: - Providers

struct ProvidersPane: View {
    @ObservedObject var store: UsageStore

    @State private var filter: Filter = .all
    /// One provider open at a time. Eleven expanded cards was six screens of
    /// scrolling, and the expanded row is also what triggers the keychain read.
    @State private var expanded: ProviderID?

    init(store: UsageStore, expanded: ProviderID? = nil) {
        self.store = store
        _expanded = State(initialValue: expanded)
    }

    enum Filter: Hashable, CaseIterable {
        case all
        case enabled
        case needsSetup

        var label: String {
            switch self {
            case .all: L10n.t("All", "全部")
            case .enabled: L10n.t("Enabled", "已启用")
            case .needsSetup: L10n.t("Needs setup", "待配置")
            }
        }
    }

    private var visible: [ProviderID] {
        ProviderID.allCases.filter { id in
            switch filter {
            case .all: true
            case .enabled: store.isEnabled(id)
            case .needsSetup: !store.isConfigured(id)
            }
        }
    }

    var body: some View {
        if let error = store.credentialError {
            SettingsCard {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        SettingsCard {
            HStack(alignment: .firstTextBaseline) {
                GlassSegmented(
                    options: Filter.allCases.map { (value: $0, label: $0.label) },
                    selection: filter,
                    onSelect: { filter = $0 })
                .frame(width: 300)
                Spacer(minLength: Design.space3)
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: Design.space1) {
                ForEach(visible) { id in
                    ProviderSettingsRow(
                        store: store,
                        id: id,
                        isExpanded: expanded == id,
                        onToggle: {
                            expanded = expanded == id ? nil : id
                        },
                        // Switched on with nothing to read: open the row, so
                        // the next thing seen is how to sign in, not a
                        // spinner that ends in an error.
                        onEnabledUnconfigured: { expanded = id })
                }
            }
        }
    }

    private var summary: String {
        let total = ProviderID.allCases.count
        let on = store.enabled.count
        let ready = ProviderID.allCases.filter { store.isConfigured($0) }.count
        return L10n.t(
            "\(total) providers · \(on) enabled · \(ready) signed in",
            "共 \(total) 个 · 已启用 \(on) 个 · 已登录 \(ready) 个")
    }
}

struct ProviderSettingsRow: View {
    @ObservedObject var store: UsageStore
    let id: ProviderID
    let isExpanded: Bool
    let onToggle: () -> Void
    var onEnabledUnconfigured: () -> Void = {}

    private var configured: Bool { store.isConfigured(id) }
    private var isManual: Bool { id.credentialHint != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                CredentialEditor(store: store, id: id)
                    .padding(.top, Design.space2)
            }
        }
        .padding(Design.space2 + 2)
        .background {
            RoundedRectangle(cornerRadius: Design.radiusCard, style: .continuous)
                .fill(isExpanded ? Design.surfaceStrong : Color.clear)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .animation(.snappy(duration: 0.2), value: isExpanded)
    }

    private var header: some View {
        HStack(spacing: Design.space2 + 2) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 10)

            ProviderGlyph(id: id, size: 18)
                .frame(width: 20)

            Text(id.displayName)
                .font(.system(size: 13, weight: .medium))

            if id.isExperimental {
                Text(L10n.t("Experimental", "实验性"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1))
                    .help(L10n.t(
                        "Built from a public implementation of this service and not yet checked against a live account. Tell us if the numbers look wrong.",
                        "按这个服务的公开实现编写，还没有用真实账号验证过。数字不对请在反馈里告诉我们。"))
            }

            Spacer(minLength: Design.space2)

            // A fixed column, empty when there is nothing to say, so the
            // pills after it line up down the list whatever the badges say.
            Group {
                if let status = store.serviceStatus[id] {
                    ServiceStatusBadge(status: status)
                } else {
                    Color.clear.frame(height: 1)
                }
            }
            .frame(width: 76, alignment: .leading)

            // Also a fixed slot: the row is anchored at its right end, so a
            // pill that varies by a character would shift the badge column
            // with it.
            statusPill
                .frame(width: 68, alignment: .leading)

            GlassSwitch(isOn: Binding(
                get: { store.isEnabled(id) },
                set: { on in
                    store.setEnabled(id, on)
                    if on, !store.isConfigured(id) { onEnabledUnconfigured() }
                }))
                .help(L10n.t("Show in the menu", "在菜单中显示"))
        }
    }

    private var statusPill: some View {
        if !store.isEnabled(id) {
            return StatusPill(text: L10n.t("Off", "已关闭"), tone: .idle)
        }
        if configured {
            return StatusPill(
                text: isManual
                    ? L10n.t("Keychain", "钥匙串")
                    : L10n.t("Auto", "自动"),
                tone: .ready)
        }
        return StatusPill(text: L10n.t("Set up", "待配置"), tone: .attention)
    }
}

/// The expanded half of a provider row.
///
/// A separate view on purpose: its `@State` is seeded in `init` from the
/// keychain, so building it *is* the read. Collapsed rows never construct one,
/// which means opening this window costs zero keychain lookups instead of
/// eleven, and the read that does happen is the direct result of a click.
///
/// Seeding in `init` rather than `onAppear` also keeps the pane renderable by
/// `ImageRenderer`, which cannot service a `@State` write queued from `onAppear`.
private struct CredentialEditor: View {
    @ObservedObject var store: UsageStore
    let id: ProviderID

    @State private var credential: String
    @State private var saved: String
    @State private var reveal = false
    @State private var testPhase: TestPhase = .idle

    init(store: UsageStore, id: ProviderID) {
        self.store = store
        self.id = id
        let value = ConfigStore.shared.credential(for: id) ?? ""
        _credential = State(initialValue: value)
        _saved = State(initialValue: value)
    }

    enum TestPhase {
        case idle
        case running
        case ok(String)
        case failed(String)
    }

    private var provider: any QuotaProvider { ProviderRegistry.make(id) }
    private var isManual: Bool { id.credentialHint != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.space3) {
            Divider().opacity(0.4)

            if store.isEnabled(id), !store.isConfigured(id) {
                HStack(alignment: .top, spacing: Design.space2) {
                    Circle()
                        .fill(Color(hex: "F5A524"))
                        .frame(width: 6, height: 6)
                        .padding(.top, 5)
                    Text(isManual
                        ? (BrowserLogin.supports(id)
                            ? L10n.t("No sign-in found on this Mac. Sign in below, or paste the credential.",
                                     "本机没有找到登录信息。可在下方用浏览器登录，或粘贴凭据。")
                            : L10n.t("No sign-in found on this Mac. Paste the credential below.",
                                     "本机没有找到登录信息。请在下方粘贴凭据。"))
                        : L10n.t("No sign-in found on this Mac. \(id.setupHint)",
                                 "本机没有找到登录信息。\(id.setupHint)"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if isManual {
                SettingRow(L10n.t("Credential", "凭据")) {
                    GlassTextField(
                        placeholder: L10n.t("Token / cookie / API key", "Token / Cookie / API Key"),
                        text: $credential,
                        secure: true,
                        reveal: $reveal,
                        onSubmit: save)
                }
            }

            SettingRow(L10n.t("How to sign in", "如何登录")) {
                VStack(alignment: .leading, spacing: Design.space2) {
                    Text(id.credentialHint ?? id.setupHint)
                    if id == .claude, store.claudeNeedsAuthorization {
                        Text(LocalCredentials.claudeAuthorizationHint)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                // 11pt under a 13pt label: two more points down puts the
                // first line on the label's baseline.
                .padding(.top, Design.rowLabelInset + 2)
            }

            // The page's reading, in full, here rather than behind a link:
            // the owner wants to see it, not be sent to it.
            if let status = store.serviceStatus[id] {
                SettingRow(L10n.t("Service status", "服务状态")) {
                    HStack(spacing: Design.space2) {
                        ServiceStatusBadge(status: status, size: 12, ink: .primary)
                        Text(status.description)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(L10n.t(
                            "· checked \(QuotaFormat.age(of: status.checkedAt))",
                            "· \(QuotaFormat.age(of: status.checkedAt))检查"))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
            }

            actions

            testResult
        }
        // The row itself toggles expansion on tap; without this, clicking into
        // the text field would collapse the thing you are typing into.
        .contentShape(Rectangle())
        .onTapGesture {}
    }

    private var actions: some View {
        HStack(spacing: Design.space2) {
            Spacer().frame(width: Design.labelColumn + Design.space3 - Design.space2)

            if isManual {
                Button(L10n.t("Save", "保存"), action: save)
                    .glassAction(prominent: true)
                    .disabled(credential == saved)
                if !saved.isEmpty {
                    Button(L10n.t("Clear", "清除"), role: .destructive, action: clear)
                        .glassAction()
                }
            }

            if id == .claude, store.claudeNeedsAuthorization {
                Button(L10n.t("Allow keychain access", "授权钥匙串访问")) { store.authorizeClaude() }
                    .glassAction(prominent: true)
            }

            if BrowserLogin.supports(id) {
                Button(L10n.t("Sign in in a browser…", "浏览器登录…")) { BrowserLogin.present(for: id, store: store) }
                    .glassAction(prominent: saved.isEmpty)
            }

            Button(action: test) {
                if case .running = testPhase {
                    Text(L10n.t("Testing…", "测试中…"))
                } else {
                    Text(L10n.t("Test connection", "测试连接"))
                }
            }
            .glassAction()
            .disabled({ if case .running = testPhase { return true }; return false }())

            Spacer(minLength: 0)

            if let url = id.dashboardURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label(L10n.t("Console", "控制台"), systemImage: "arrow.up.right")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(url.absoluteString)
            }
        }
    }

    @ViewBuilder
    private var testResult: some View {
        switch testPhase {
        case .idle, .running:
            EmptyView()
        case let .ok(message):
            resultLabel(message, symbol: "checkmark.circle.fill", colour: .green)
        case let .failed(message):
            resultLabel(message, symbol: "xmark.circle.fill", colour: .red)
                .textSelection(.enabled)
        }
    }

    private func resultLabel(_ message: String, symbol: String, colour: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.space2) {
            Spacer().frame(width: Design.labelColumn + Design.space3 - Design.space2)
            Label(message, systemImage: symbol)
                .font(.system(size: 11))
                .foregroundStyle(colour)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Intents

    private func save() {
        store.setCredential(credential, for: id)
        saved = ConfigStore.shared.credential(for: id) ?? ""
        credential = saved
        testPhase = .idle
    }

    private func clear() {
        store.setCredential("", for: id)
        saved = ""
        credential = ""
        testPhase = .idle
    }

    private func test() {
        testPhase = .running
        // Both caches exist so a refresh does not hit the keychain eleven times
        // a minute, and both would answer this button from a memo up to a
        // minute old. That is exactly wrong here: someone pressing "test" has
        // usually just changed the thing being tested — pasted a cookie, or
        // re-run `claude` to renew an expired session — and a stale "still
        // failing" reads as the app being broken at the moment they are fixing
        // it. This button asks the source, not the memo.
        ConfigStore.shared.invalidateCredentialCache()
        LocalCredentials.invalidateClaudeToken()
        Task {
            do {
                // "Test" is a click, so for Claude it may raise the keychain
                // dialog; a refresh never does.
                if id == .claude { _ = await LocalCredentials.authorizeClaudeAccessAsync() }
                let snapshot = try await provider.fetch(config: ConfigStore.shared)
                let connected = L10n.t("Connected", "连接成功")
                if let percent = snapshot.headlinePercent {
                    testPhase = .ok(
                        "\(connected) — \(QuotaFormat.percent(percent))"
                            + (snapshot.planName.map { " · \($0)" } ?? ""))
                } else if let first = snapshot.windows.first {
                    testPhase = .ok("\(connected) — \(first.detail ?? first.title)")
                } else {
                    testPhase = .ok(connected)
                }
            } catch {
                testPhase = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - Appearance

struct AppearancePane: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        SettingsCard(L10n.t("Menu-bar glyph", "菜单栏图标")) {
            SettingRow(L10n.t("Shows", "显示")) {
                GlassSegmented(
                    options: MenuBarIconMode.allCases.map { (value: $0, label: $0.displayName) },
                    selection: store.menuBarIconMode,
                    onSelect: { store.setMenuBarIconMode($0) })
                .frame(maxWidth: 420)
            }

            switch store.menuBarIconMode {
            case .meter:
                MenuBarStylePicker(
                    selection: store.menuBarStyle,
                    mode: store.meterMode,
                    onSelect: { store.setMenuBarStyle($0) })
            case .text:
                SettingFootnote(L10n.t(
                    "Each provider's mark and its figure — the focused provider alone, or the first three enabled.",
                    "每个服务商的 logo 加数字：选中了服务商时只显示它，否则显示前三个已启用的服务商。"))
            case .logo:
                SettingFootnote(L10n.t(
                    "The app's mark, drawn in the menu bar's own ink. Click it for the menu panel.",
                    "只显示应用标记，按菜单栏自身的颜色绘制。点击打开下拉面板。"))
            case .hidden:
                SettingFootnote(L10n.t(
                    "No menu-bar item. Reach Settings from the dock's or island's right-click menu, or by opening QuotaBar again.",
                    "菜单栏不显示任何图标。可从停靠条或刘海岛的右键菜单打开设置，或再次打开 QuotaBar。"))
            }

            SettingRow(L10n.t("Fills with", "填充口径")) {
                GlassSegmented(
                    options: MeterMode.allCases.map { (value: $0, label: $0.displayName) },
                    selection: store.meterMode,
                    onSelect: { store.setMeterMode($0) })
                .frame(maxWidth: 260)
            }

            SettingRow(L10n.t("Bars", "进度条")) {
                GlassSegmented(
                    options: MeterStyle.allCases.map { (value: $0, label: $0.displayName) },
                    selection: store.meterStyle,
                    onSelect: { store.setMeterStyle($0) })
                .frame(maxWidth: 260)
            }

            SettingFootnote(L10n.t(
                "Used or left applies everywhere; clicking any percentage flips it too.",
                "已用或剩余在所有界面同步生效，点击任意百分比也能切换。"))
            SettingFootnote(L10n.t(
                "The glyph reports whichever provider the panel is focused on. Pick Overview in the panel to have it cover everything enabled.",
                "菜单栏图标显示的是面板中当前选中的服务商。在面板里选「总览」可让它覆盖所有已启用的服务商。"))
        }

        SettingsCard(L10n.t("Figures and bars", "数字与进度条")) {
            SettingRow(L10n.t("Bar colour", "变色方式"), caption: L10n.t("How a bar shows it is close.", "进度条如何提示快用完。")) {
                GlassSegmented(
                    options: UrgencyStyle.allCases.map { (value: $0, label: $0.displayName) },
                    selection: store.experience.urgencyStyle,
                    onSelect: { value in store.updateExperience { $0.urgencyStyle = value } })
                .frame(maxWidth: 360)
            }
            SettingRow(L10n.t("Reset times", "重置时间"), caption: L10n.t("Click any reset label to flip it too.", "点击任意重置时间也能切换。")) {
                GlassSegmented(
                    options: ResetTimeFormat.allCases.map { (value: $0, label: $0.displayName) },
                    selection: store.experience.resetTimeFormat,
                    onSelect: { value in store.updateExperience { $0.resetTimeFormat = value } })
                .frame(maxWidth: 240)
            }
            SettingRow(L10n.t("Clock", "时钟")) {
                GlassSegmented(
                    options: ClockStyle.allCases.map { (value: $0, label: $0.displayName) },
                    selection: store.experience.clockStyle,
                    onSelect: { value in store.updateExperience { $0.clockStyle = value } })
                .frame(maxWidth: 300)
            }
            SettingToggle(
                L10n.t("Always show pacing", "始终显示节奏"), caption: L10n.t("The even-pace tick and a projection on every bar, not only close ones.", "每条进度条都显示匀速刻度和重置时的预计，而不只是余量紧张的。"),
                isOn: Binding(
                    get: { store.experience.alwaysShowPace },
                    set: { value in store.updateExperience { $0.alwaysShowPace = value } }))
            SettingToggle(
                L10n.t("Reduce animations", "减少动画"), caption: L10n.t("Also follows the system's Reduce Motion.", "同时跟随系统的减弱动态效果设置。"),
                isOn: Binding(
                    get: { store.experience.reduceMotion },
                    set: { value in store.updateExperience { $0.reduceMotion = value } }))
        }

        SettingsCard(L10n.t("Menu panel", "下拉面板")) {
            SettingRow(L10n.t("Density", "密度")) {
                GlassSegmented(
                    options: PanelDensity.allCases.map { (value: $0, label: $0.displayName) },
                    selection: store.experience.panelDensity,
                    onSelect: { value in store.updateExperience { $0.panelDensity = value } })
                .frame(maxWidth: 220)
            }
            SettingToggle(
                L10n.t("Translucent", "面板半透明"),
                caption: L10n.t("Lets the desktop show through the panel.", "让桌面透过面板显示出来。"),
                isOn: Binding(
                    get: { store.experience.panelTranslucent },
                    set: { value in store.updateExperience { $0.panelTranslucent = value } }))
            SettingToggle(
                L10n.t("Show total spend", "显示花费卡片"),
                isOn: Binding(
                    get: { store.experience.showSpendCard },
                    set: { value in store.updateExperience { $0.showSpendCard = value } }))
            SettingRow(L10n.t("Shortcut", "全局快捷键"), caption: L10n.t("Opens the panel from anywhere.", "在任何地方打开下拉面板。")) {
                HotkeyRecorder(hotkey: store.experience.hotkey) { hotkey in
                    store.updateExperience { $0.hotkey = hotkey }
                }
            }
            SettingFootnote(L10n.t(
                "Click the menu-bar item to open it; Esc closes, ⌘R refreshes, ⌘, opens Settings. Right-click a card to copy it as an image.",
                "点菜单栏图标打开；Esc 关闭，⌘R 刷新，⌘, 打开设置。右键卡片可复制为图片。"))
        }
    }
}

/// Shows each style as its own glyph at a mid level, so the choice is made on
/// what it will actually look like in the menu bar.
struct MenuBarStylePicker: View {
    let selection: MenuBarStyle
    let mode: MeterMode
    let onSelect: (MenuBarStyle) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: Design.space2), count: 4)

    var body: some View {
        LazyVGrid(columns: columns, spacing: Design.space2) {
            ForEach(MenuBarStyle.allCases) { style in
                Button {
                    onSelect(style)
                } label: {
                    VStack(spacing: Design.space1) {
                        // 34% used, so a stepped glyph shows a partial reading
                        // rather than an all-or-nothing one.
                        Image(nsImage: MenuBarIcon.render(percent: 34, style: style, mode: mode))
                            .frame(height: 22)
                        Text(style.displayName)
                            .font(.system(size: 10))
                            .lineLimit(1)
                        Text(style.steps.map { L10n.t("\($0) steps", "\($0) 格") }
                            ?? L10n.t("continuous", "连续"))
                            .font(.system(size: 9))
                            .foregroundStyle(style == selection ? Design.ink.opacity(0.7) : .secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Design.space2)
                    .background(
                        RoundedRectangle(cornerRadius: Design.radiusTile, style: .continuous)
                            .fill(style == selection ? Design.accent : Design.surfaceStrong))
                    .foregroundStyle(style == selection ? Design.ink : Color.primary)
                }
                .buttonStyle(TileButtonStyle())
                .help(style.displayName)
            }
        }
    }
}

// MARK: - Presentation

struct PresentationPane: View {
    @ObservedObject var store: UsageStore
    /// Re-read when a display comes or goes, so the picker lists what is
    /// actually there.
    @State private var screens = NSScreen.screens

    var body: some View {
        SettingsCard(L10n.t("Where the panel lives", "面板位置")) {
            SettingRow(L10n.t("Style", "样式")) {
                GlassSegmented(
                    options: Presentation.allCases.map { (value: $0, label: $0.displayName) },
                    selection: store.presentation,
                    onSelect: { store.setPresentation($0) })
                .frame(maxWidth: 320)
            }

            // Only a question on a Mac with more than one display.
            if screens.count > 1 {
                SettingRow(
                    L10n.t("Screen", "屏幕"),
                    caption: L10n.t(
                        "Automatic follows the menu bar's screen; the island, the screen with the notch. Desktop cards go along.",
                        "自动跟随菜单栏所在的屏幕，刘海岛跟随带刘海的屏幕。桌面卡片同屏。"))
                {
                    GlassSegmented(
                        options: ScreenChoice.options,
                        selection: ScreenChoice.selection,
                        onSelect: { store.setDisplayScreen($0) })
                    .frame(maxWidth: 440)
                }
            }

            if store.presentation == .island {
                SettingRow(L10n.t("Per side", "每侧显示")) {
                    GlassSegmented(
                        options: [1, 2, 3].map { (value: $0, label: L10n.t("\($0)", "\($0) 个")) },
                        selection: store.islandSlots,
                        onSelect: { store.setIslandSlots($0) })
                    .frame(maxWidth: 200)
                }
                SettingFootnote(L10n.t(
                    "How many providers sit either side of the notch, in the order they are enabled. Hover to open the full panel.",
                    "刘海两侧各显示几个服务商，按启用顺序排列。悬停即从顶部展开完整面板。"))
            SettingToggle(
                L10n.t("Glow", "光晕"), caption: L10n.t("A halo that turns amber or red near the limit, and a light that orbits the outline.", "轮廓外的柔光，接近上限时变琥珀或红色，另有一道光沿轮廓环绕。"),
                isOn: Binding(
                    get: { store.experience.islandGlow },
                    set: { value in store.updateExperience { $0.islandGlow = value } }))
            SettingToggle(
                L10n.t("Low power", "低功耗"), caption: L10n.t("Glow only while refreshing, hovered or alerting.", "只在刷新、悬停或告警时发光。"),
                isOn: Binding(
                    get: { store.experience.lowPowerGlow },
                    set: { value in store.updateExperience { $0.lowPowerGlow = value } }))
            .disabled(!store.experience.islandGlow)
            .opacity(!store.experience.islandGlow ? 0.45 : 1)
            SettingToggle(
                L10n.t("Open when a limit nears", "越线时自动弹出"), caption: L10n.t("Opens for four seconds when a window crosses its warning.", "额度第一次超过告警线时展开 4 秒。"),
                isOn: Binding(
                    get: { store.experience.islandAutoPeek },
                    set: { value in store.updateExperience { $0.islandAutoPeek = value } }))
            SettingRow(L10n.t("Chart", "图表样式"), caption: L10n.t("⌘-click the open panel to cycle.", "在展开的面板上按住 ⌘ 点击也能切换。")) {
                GlassSegmented(
                    options: IslandChartStyle.allCases.map { (value: $0, label: $0.displayName) },
                    selection: store.experience.islandChart,
                    onSelect: { value in store.updateExperience { $0.islandChart = value } })
                .frame(maxWidth: 380)
            }
            }

            if store.presentation == .edgeDock {
                SettingRow(L10n.t("Docked edge", "停靠边缘")) {
                    GlassSegmented(
                        options: DockEdge.allCases.map { (value: $0, label: $0.displayName) },
                        selection: store.dockEdge,
                        onSelect: { store.setDockEdge($0) })
                    .frame(maxWidth: 200)
                }
                SettingToggle(
                    L10n.t("Keep the dock visible", "常驻显示（不自动隐藏）"),
                    isOn: Binding(
                        get: { store.dockAlwaysVisible },
                        set: { store.setDockAlwaysVisible($0) }))
                SettingFootnote(L10n.t(
                    "Drag the dock up or down to move it; the position is remembered. Click a ring to open the panel for that provider.",
                    "上下拖动可移动停靠条，位置会被记住。点击圆环可打开该服务商的完整面板。"))
            }
        }

        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = NSScreen.screens
        }

        SettingsCard(L10n.t("Desktop cards", "桌面卡片")) {
            SettingToggle(
                L10n.t("Show on the desktop", "在桌面显示"),
                isOn: Binding(
                    get: { store.widgetEnabled },
                    set: { store.setWidgetEnabled($0) }))
            ForEach(Array(store.experience.deskCards.enumerated()), id: \.element.id) { index, card in
                DeskCardSettingsRow(store: store, card: card, number: index + 1)
                    .disabled(!store.widgetEnabled)
                    .opacity(store.widgetEnabled ? 1 : 0.45)
            }
            SettingRow(L10n.t("Add", "添加")) {
                HStack(spacing: Design.space2) {
                    GlassMenuButton(
                        title: L10n.t("Add a card", "添加卡片"),
                        systemImage: "plus",
                        items: DeskCardStyle.allCases.map { style in
                            (style.displayName, { store.addDeskCard(style: style, near: store.experience.deskCards.last) })
                        })
                    Button(L10n.t("Restore the default pair", "恢复默认两张")) {
                        store.updateExperience { $0.deskCards = DeskCard.defaults(provider: nil) }
                        if !store.widgetEnabled { store.setWidgetEnabled(true) }
                        store.widgetRevision &+= 1
                    }
                    .glassAction()
                    Spacer(minLength: 0)
                }
            }
            SettingToggle(
                L10n.t("Keep above other windows", "置于其他窗口之上"),
                isOn: Binding(
                    get: { store.widgetAlwaysOnTop },
                    set: { store.setWidgetAlwaysOnTop($0) }))
                .disabled(!store.widgetEnabled)
                .opacity(store.widgetEnabled ? 1 : 0.45)
            SettingToggle(
                L10n.t("Classic card: closest to the limit first", "经典样式按紧迫度排序"),
                isOn: Binding(
                    get: { store.experience.widgetSortsByUrgency },
                    set: { value in store.updateExperience { $0.widgetSortsByUrgency = value } }))
            SettingFootnote(L10n.t(
                "Cards sit on the desktop, below your windows, unless kept above. Drag one to move it, double-click for the menu panel, right-click to change its style, size or provider, or to remove it.",
                "卡片默认位于桌面、在窗口之下，可改为置顶。拖动移动位置，双击打开下拉面板，右键可更换样式、尺寸、服务商或删除。"))
        }
    }
}

/// One desktop card in Settings: its style, size and subject, and a way to
/// remove it.
private struct DeskCardSettingsRow: View {
    @ObservedObject var store: UsageStore
    let card: DeskCard
    let number: Int

    var body: some View {
        SettingRow(L10n.t("Card \(number)", "卡片 \(number)")) {
            HStack(spacing: Design.space2) {
                GlassPopUp(
                    options: DeskCardStyle.allCases.map { (value: $0, label: $0.displayName) },
                    selection: card.style,
                    onSelect: { style in store.updateDeskCard(card.id) { $0.style = style } })
                .frame(width: 118)

                GlassSegmented(
                    options: DeskCardSize.allCases.map { (value: $0, label: $0.shortName) },
                    selection: card.size,
                    onSelect: { size in store.updateDeskCard(card.id) { $0.size = size } })
                .frame(width: 120)

                if card.style.readsLogs {
                    GlassPopUp(
                        options: [(value: CostSource?.none, label: L10n.t("Every CLI", "全部来源"))]
                            + CostSource.allCases.map { (value: Optional($0), label: $0.displayName) },
                        selection: card.source,
                        onSelect: { source in store.updateDeskCard(card.id) { $0.source = source } })
                    .frame(width: 128)
                } else {
                    GlassPopUp(
                        options: [(
                            value: ProviderID?.none,
                            label: card.style.singleProvider
                                ? L10n.t("Follow menu bar", "跟随菜单栏")
                                : L10n.t("Every provider", "全部服务商"))]
                            // A card pinned to a provider since switched off
                            // still names it, rather than showing a blank.
                            + (store.enabled + [card.provider].compactMap { $0 }.filter { !store.enabled.contains($0) })
                                .map { (value: Optional($0), label: $0.displayName) },
                        selection: card.provider,
                        onSelect: { provider in store.updateDeskCard(card.id) { $0.provider = provider } })
                    .frame(width: 128)
                }

                Button {
                    store.removeDeskCard(card.id)
                } label: {
                    Image(systemName: "trash")
                }
                .glassAction(compact: true)
                .help(L10n.t("Remove this card", "删除这张卡片"))
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Alerts

struct AlertsPane: View {
    @ObservedObject var store: UsageStore

    private var enabled: Bool { store.alertSettings.enabled }

    var body: some View {
        SettingsCard(L10n.t("Thresholds", "阈值")) {
            SettingToggle(
                L10n.t("Notify when approaching limits", "接近额度上限时通知"),
                isOn: Binding(
                    get: { store.alertSettings.enabled },
                    set: { value in
                        var settings = store.alertSettings
                        settings.enabled = value
                        store.setAlertSettings(settings)
                    }))

            SettingRow(L10n.t("Warning at", "警告阈值")) {
                GlassSegmented(
                    options: [60, 70, 80, 90].map { (value: $0, label: "\($0)%") },
                    selection: store.alertSettings.warning,
                    onSelect: { value in
                        var settings = store.alertSettings
                        settings.warning = value
                        // Keep critical reachable: a critical below the warning
                        // can never fire.
                        settings.critical = max(settings.critical, value)
                        store.setAlertSettings(settings)
                    })
                .frame(maxWidth: 300)
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.45)
            }

            SettingRow(L10n.t("Critical at", "紧急阈值")) {
                GlassSegmented(
                    options: [80, 85, 90, 95, 99]
                        .filter { $0 >= store.alertSettings.warning }
                        .map { (value: $0, label: "\($0)%") },
                    selection: store.alertSettings.critical,
                    onSelect: { value in
                        var settings = store.alertSettings
                        settings.critical = value
                        store.setAlertSettings(settings)
                    })
                .frame(maxWidth: 340)
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.45)
            }

            SettingFootnote(L10n.t(
                "Only thresholds at or above the warning level are offered — a critical below it can never be reached.",
                "紧急阈值只提供不低于警告阈值的档位，否则永远不会触发。"))
        }

        SettingsCard(L10n.t("Pace", "节奏提醒")) {
            paceToggle(L10n.t("Almost out", "快用完了"), L10n.t("Under 10% left, balances included.", "剩余不到 10%，包括没有重置周期的余额。"), \.almostOut)
            paceToggle(L10n.t("Cutting it close", "余量很紧"), L10n.t("Projected to finish the window with little left.", "按当前速度，重置时所剩无几。"), \.cuttingClose)
            paceToggle(L10n.t("Will run out", "重置前会用完"), L10n.t("Projected to run out before the window resets.", "按当前速度，会在重置前用完。"), \.willRunOut)
            SettingFootnote(L10n.t(
                "Each fires once per crossing and once per reset period. What is already true when QuotaBar starts sets the baseline without a notification.",
                "每次越线只提醒一次，每个重置周期也只提醒一次。QuotaBar 启动时已经成立的情况只作为基线，不会提醒。"))
        }
    }

    private func paceToggle(_ title: String, _ caption: String, _ key: WritableKeyPath<PaceAlertPrefs, Bool>) -> some View {
        SettingToggle(title, caption: caption, isOn: Binding(
            get: { store.experience.paceAlerts[keyPath: key] },
            set: { value in store.updateExperience { $0.paceAlerts[keyPath: key] = value } }))
    }
}

// MARK: - General

struct GeneralPane: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        SettingsCard(L10n.t("Language", "语言")) {
            SettingRow(L10n.t("Interface", "界面语言")) {
                GlassSegmented(
                    options: L10n.Language.allCases.map { (value: $0, label: $0.displayName) },
                    selection: store.language,
                    onSelect: { store.setLanguage($0) })
                .frame(maxWidth: 340)
            }
        }

        SettingsCard(L10n.t("Refresh", "刷新")) {
            SettingRow(L10n.t("Interval", "间隔")) {
                HStack(spacing: Design.space3) {
                    GlassSegmented(
                        // Nothing under five minutes: Anthropic's usage
                        // endpoint rate-limits tighter polling.
                        options: [5, 15, 30].map {
                            (value: $0, label: L10n.t("\($0)m", "\($0) 分"))
                        },
                        selection: store.refreshMinutes,
                        onSelect: { store.setRefreshMinutes($0) })
                    .frame(width: 220)
                    Button(L10n.t("Refresh now", "立即刷新")) { store.refreshAll() }
                        .glassAction()
                    Spacer(minLength: 0)
                }
            }
        }

        SettingsCard(L10n.t("Figures", "数据口径")) {
            SettingRow(L10n.t("Currency", "货币"), caption: L10n.t("Daily reference rates; prices stay in dollars.", "按每日参考汇率换算，价格本身仍以美元计。")) {
                GlassPopUp(
                    options: CurrencyRates.supported.map { code in
                        (value: code, label: "\(CurrencyRates.displayName(for: code)) · \(code)")
                    },
                    selection: store.experience.currency,
                    onSelect: { value in store.updateExperience { $0.currency = value } })
                .frame(width: 200)
            }
            SettingRow(L10n.t("Tokens", "token 统计"), caption: L10n.t("All tokens includes cache reads and writes.", "全部 token 包含缓存读写。")) {
                GlassSegmented(
                    options: TokenCounting.allCases.map { (value: $0, label: $0.displayName) },
                    selection: store.experience.tokenCounting,
                    onSelect: { value in store.updateExperience { $0.tokenCounting = value } })
                .frame(maxWidth: 300)
            }
        }

        SettingsCard(L10n.t("Privacy", "隐私")) {
            SettingToggle(
                L10n.t("Hide usage while the screen is shared", "共享屏幕时隐藏用量"), caption: L10n.t("While a share or recording is on, the menu bar shows only the mark and the dock, island and desktop card step aside.", "共享屏幕或录屏期间，菜单栏只显示 logo，停靠条、刘海岛和桌面卡片暂时隐藏。"),
                isOn: Binding(
                    get: { store.experience.hideWhenSharing },
                    set: { value in store.updateExperience { $0.hideWhenSharing = value } }))
        }

        SettingsCard(L10n.t("Advanced", "高级")) {
            ProxyRow(store: store)
            SettingToggle(
                L10n.t("Local API", "本地接口"), caption: L10n.t("Serves http://127.0.0.1:6736/v1/limits to other tools on this Mac. No credentials, no account names.", "在 http://127.0.0.1:6736/v1/limits 提供额度数据给本机其他工具，不含凭据和账号。"),
                isOn: Binding(
                    get: { store.experience.localAPI },
                    set: { value in store.updateExperience { $0.localAPI = value } }))
            SettingFootnote(L10n.t(
                "From a terminal: /Applications/QuotaBar.app/Contents/MacOS/QuotaBar --json prints the same limits; add --force to skip the five-minute cache.",
                "在终端运行 /Applications/QuotaBar.app/Contents/MacOS/QuotaBar --json 可输出同样的额度数据，加 --force 跳过 5 分钟缓存。"))
        }

        SettingsCard(L10n.t("System", "系统")) {
            LaunchAtLoginToggle()
            SettingRow(
                L10n.t("Trend history", "趋势历史"),
                caption: L10n.t("Backs the sparklines.", "趋势折线的数据来源。"))
            {
                Button(L10n.t("Reset", "重置"), role: .destructive) { store.resetHistory() }
                    .glassAction()
            }
        }
    }
}

struct LaunchAtLoginToggle: View {
    @State private var enabled: Bool
    @State private var available: Bool

    /// Seeded in `init`, not `onAppear` — see `CredentialEditor`. Only
    /// meaningful for a real app bundle; the dev loop runs a bare binary that
    /// `SMAppService` cannot register.
    init() {
        let hasBundle = Bundle.main.bundleIdentifier != nil
        _available = State(initialValue: hasBundle)
        _enabled = State(initialValue: hasBundle && SMAppService.mainApp.status == .enabled)
    }

    var body: some View {
        SettingToggle(L10n.t("Launch at login", "开机自动启动"), isOn: $enabled)
            .disabled(!available)
            .opacity(available ? 1 : 0.45)
            .onChange(of: enabled) { _, on in
                guard available else { return }
                do {
                    if on {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    enabled = SMAppService.mainApp.status == .enabled
                }
            }
    }
}

// MARK: - Updates

struct UpdatesPane: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        SettingsCard(L10n.t("Version", "版本")) {
            SettingRow(L10n.t("Installed", "当前版本")) {
                HStack(spacing: Design.space2) {
                    Text(SettingsView.version)
                        .font(.system(size: 13, design: .monospaced))
                    if let built = SettingsView.buildDate {
                        Text(L10n.t("built \(built)", "构建于 \(built)"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, Design.rowLabelInset)
            }

            SettingRow(L10n.t("Updates", "更新方式")) {
                GlassSegmented(
                    options: UpdatePolicy.allCases.map { (value: $0, label: $0.displayName) },
                    selection: store.updatePolicy,
                    onSelect: { store.setUpdatePolicy($0) })
                .frame(maxWidth: 260)
                .disabled(store.updateIsManagedByHomebrew)
                .opacity(store.updateIsManagedByHomebrew ? 0.45 : 1)
            }

            SettingRow(L10n.t("Check", "检查")) {
                HStack(spacing: Design.space3) {
                    Button(L10n.t("Check now", "立即检查")) { store.checkForUpdate() }
                        .glassAction(prominent: true)
                        .disabled(checking)
                    stage
                    Spacer(minLength: 0)
                }
            }

            SettingToggle(
                L10n.t("Beta updates", "测试版更新"), caption: L10n.t("Also offers pre-releases.", "同时接收预发布版本。"),
                isOn: Binding(
                    get: { store.experience.betaUpdates },
                    set: { value in store.updateExperience { $0.betaUpdates = value } }))
            if store.updateIsManagedByHomebrew {
                SettingFootnote(L10n.t("Updated by Homebrew.", "由 Homebrew 更新。"))
            }
        }
    }

    private var checking: Bool {
        switch store.updateStage {
        case .checking, .downloading: true
        default: false
        }
    }

    /// Where the last check got to, in one line beside the button.
    @ViewBuilder
    private var stage: some View {
        switch store.updateStage {
        case .idle:
            if let checked = store.lastUpdateCheck {
                Text(L10n.t(
                    "Up to date · checked \(QuotaFormat.age(of: checked))",
                    "已是最新 · \(QuotaFormat.age(of: checked))检查"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        case .checking:
            Text(L10n.t("Checking…", "正在检查…"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        case let .available(release):
            if store.updatePolicy == .manual || store.updateIsManagedByHomebrew {
                Text(L10n.t("\(release.version) is available", "有新版本 \(release.version)"))
                    .font(.system(size: 11, weight: .medium))
                if !store.updateIsManagedByHomebrew {
                    Button(L10n.t("Install and relaunch", "安装并重启")) { store.installNow() }
                        .glassAction()
                }
            } else {
                Text(L10n.t("Found \(release.version), downloading…", "发现 \(release.version)，正在下载…"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        case let .downloading(release):
            Text(L10n.t("Downloading \(release.version)…", "正在下载 \(release.version)…"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        case let .readyToInstall(release):
            Text(L10n.t("\(release.version) verified", "\(release.version) 已通过验证"))
                .font(.system(size: 11, weight: .medium))
            Button(L10n.t("Install and relaunch", "安装并重启")) { store.installNow() }
                .glassAction()
        case let .failed(message):
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(Color(hex: "E5484D"))
                .lineLimit(2)
        }
    }
}

// MARK: - Feedback

/// A form, not a mailto: the text goes to quota.bar's own receiver, which
/// files it and opens an issue where it can. Nobody has to sign in.
struct FeedbackPane: View {
    @ObservedObject var store: UsageStore
    @State private var kind: FeedbackKind = .bug
    @State private var message = ""
    @State private var contact = ""
    @State private var includeDiagnostics = true
    @State private var phase: Phase = .idle

    enum Phase: Equatable {
        case idle
        case sending
        case sent(FeedbackReceipt)
        case failed(String)
    }

    private var macos: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion)\(v.patchVersion > 0 ? ".\(v.patchVersion)" : "")"
    }

    private var diagnostics: [String: String] {
        [
            L10n.t("Providers", "服务商"): store.enabled.map(\.displayName).joined(separator: ", "),
            L10n.t("Presentation", "展示方式"): store.presentation.displayName,
            L10n.t("Menu bar", "菜单栏"): store.menuBarIconMode.displayName,
        ]
    }

    private var canSend: Bool {
        message.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 && phase != .sending
    }

    var body: some View {
        SettingsCard {
            SettingRow(L10n.t("Kind", "类型")) {
                GlassSegmented(
                    options: FeedbackKind.allCases.map { (value: $0, label: $0.displayName) },
                    selection: kind,
                    onSelect: { kind = $0 })
                .frame(maxWidth: 300)
            }
            SettingRow(L10n.t("Message", "内容")) {
                TextEditor(text: $message)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(Design.space2)
                    .frame(minHeight: 132)
                    .background(
                        RoundedRectangle(cornerRadius: Design.radiusField, style: .continuous)
                            .fill(Design.fieldFill))
                    .overlay(
                        RoundedRectangle(cornerRadius: Design.radiusField, style: .continuous)
                            .strokeBorder(Design.glassEdge, lineWidth: 1))
            }
            SettingRow(L10n.t("Contact", "联系方式"), caption: L10n.t("Optional.", "选填。")) {
                GlassTextField(
                    placeholder: L10n.t("Email, or where to reply", "邮箱，或其他能回复你的方式"),
                    text: $contact,
                    monospaced: false)
            }
            SettingToggle(
                L10n.t("Include version and setup", "附带版本与配置信息"),
                caption: "QuotaBar \(SettingsView.version) · macOS \(macos) · \(diagnostics.values.joined(separator: " · "))",
                isOn: $includeDiagnostics)
            HStack(spacing: Design.space3) {
                Spacer().frame(width: Design.labelColumn + Design.space3 - Design.space3)
                Button(phase == .sending ? L10n.t("Sending…", "发送中…") : L10n.t("Send", "发送")) { send() }
                    .glassAction(prominent: true)
                    .disabled(!canSend)
                result
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var result: some View {
        switch phase {
        case .idle, .sending:
            EmptyView()
        case let .sent(receipt):
            HStack(spacing: Design.space2) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(L10n.t("Received, thank you. #\(receipt.id)", "已收到，谢谢。编号 \(receipt.id)"))
                    .font(.system(size: 12))
                if let url = receipt.issueURL {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label(L10n.t("View on GitHub", "在 GitHub 上查看"), systemImage: "arrow.up.right")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
        case let .failed(reason):
            HStack(spacing: Design.space2) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                Text(L10n.t("Could not send (\(reason)).", "没发出去（\(reason)）。"))
                    .font(.system(size: 12))
                    .lineLimit(1)
                Button(L10n.t("Open a GitHub issue instead", "改在 GitHub 提交")) {
                    NSWorkspace.shared.open(FeedbackClient.issueURL(
                        kind: kind, message: message, app: SettingsView.version, macos: macos))
                }
                .glassAction()
            }
        }
    }

    private func send() {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        phase = .sending
        let kind = kind, contact = contact, app = SettingsView.version, macos = macos
        let diagnostics = includeDiagnostics ? diagnostics : [:]
        let locale = L10n.t("en", "zh-Hans")
        Task {
            do {
                let receipt = try await FeedbackClient.submit(
                    kind: kind, message: text, contact: contact,
                    app: app, macos: macos, locale: locale, diagnostics: diagnostics)
                phase = .sent(receipt)
                message = ""
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - About

/// The proxy address, applied on Return or with the button.
private struct ProxyRow: View {
    @ObservedObject var store: UsageStore
    @State private var text: String
    @State private var invalid = false

    init(store: UsageStore) {
        self.store = store
        _text = State(initialValue: store.experience.proxy)
    }

    var body: some View {
        SettingRow(L10n.t("Proxy", "代理"), caption: invalid ? L10n.t("Not a proxy address.", "不是有效的代理地址。") : L10n.t("http://, https:// or socks5://; empty is direct.", "支持 http://、https:// 或 socks5://，留空为直连。")) {
            HStack(spacing: Design.space2) {
                GlassTextField(placeholder: "socks5://127.0.0.1:7890", text: $text, onSubmit: apply)
                    .frame(width: 260)
                Button(L10n.t("Apply", "应用"), action: apply)
                    .glassAction()
                Spacer(minLength: 0)
            }
        }
    }

    private func apply() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        invalid = !trimmed.isEmpty && ProxySpec(trimmed) == nil
        guard !invalid else { return }
        store.updateExperience { $0.proxy = trimmed }
    }
}

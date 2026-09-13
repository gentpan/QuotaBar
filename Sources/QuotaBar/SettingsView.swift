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
    case projects
    case run
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
        case .projects: L10n.t("Projects", "项目")
        case .run: "Quota Run"
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
        case .projects:
            L10n.t("Where the tokens went: each repository, CLI and way of working, and which projects are public on quota.run.",
                   "token 用在了哪个项目：每个仓库、每个工具、每种编程方式，以及哪些项目公开到 quota.run。")
        case .run:
            L10n.t("Personal records from every reading, and the opt-in leaderboard.",
                   "每次读数都记成个人纪录；排行榜需要自愿加入。")
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
        case .projects: "folder"
        case .run: "flag.checkered"
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
        .onReceive(NotificationCenter.default.publisher(for: SettingsWindow.showSection)) { note in
            if let raw = note.object as? String, let wanted = SettingsSection(rawValue: raw) { section = wanted }
        }
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
            // Title and explanation on one line, on a shared baseline: the
            // explanation is a gloss on the title, not a second heading. It
            // gives way before the title does when the window is narrow.
            HStack(alignment: .firstTextBaseline, spacing: Design.space3) {
                Text(section.title)
                    .font(.system(size: 20, weight: .semibold))
                    .fixedSize()
                    .layoutPriority(1)
                Text(section.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(section.subtitle)
            }
            .padding(.horizontal, Design.space6)
            .padding(.top, Design.titlebarInset)
            .padding(.bottom, Design.space4)

            if scrollable {
                // `.never`, not `.hidden`: hidden still flashes the bar
                // whenever the content grows, as it does when a row opens.
                ScrollViewReader { reader in
                    ScrollView { paneBody }
                        .scrollIndicators(.never)
                        .onReceive(NotificationCenter.default.publisher(for: SettingsWindow.scrollTo)) { note in
                            guard let anchor = note.object as? String else { return }
                            withAnimation(Motion.animation(.easeOut(duration: 0.25))) {
                                reader.scrollTo(anchor, anchor: .top)
                            }
                        }
                }
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
        case .projects: ProjectsPane(store: store, run: store.run)
        case .run: RunPane(store: store, run: store.run)
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

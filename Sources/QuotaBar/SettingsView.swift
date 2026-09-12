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
                ScrollView { paneBody }
                    .scrollIndicators(.hidden)
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
            "Read from each provider's public status page every five minutes, without signing in. Click a row for the page's own account of what is going on. Not listed: xAI's page refuses automated readers; Z.ai, OpenCode, Antigravity and Qwen Cloud publish none.",
            "每五分钟读取各服务商的公开状态页，无需登录。点击一行可看状态页对当前情况的说明。未列出的：xAI 的页面拒绝自动读取；Z.ai、OpenCode、Antigravity 与 Qwen Cloud 没有公开状态页。"))
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
                    Spacer(minLength: Design.space2)
                    Text(L10n.t(
                        "checked \(QuotaFormat.age(of: status.checkedAt))",
                        "\(QuotaFormat.age(of: status.checkedAt))检查"))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
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
            }

            if isOpen, let status {
                VStack(alignment: .leading, spacing: Design.space2) {
                    Text(status.description)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
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

            Toggle("", isOn: Binding(
                get: { store.isEnabled(id) },
                set: { on in
                    store.setEnabled(id, on)
                    if on, !store.isConfigured(id) { onEnabledUnconfigured() }
                }))
                .labelsHidden()
                // Explicit: an unstyled Toggle is a checkbox on macOS, and the
                // rest of this window is switches.
                .toggleStyle(.switch)
                .controlSize(.small)
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
                .padding(.top, 5)
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
                .frame(maxWidth: 320)
            }

            switch store.menuBarIconMode {
            case .meter:
                MenuBarStylePicker(
                    selection: store.menuBarStyle,
                    mode: store.meterMode,
                    onSelect: { store.setMenuBarStyle($0) })
            case .logo:
                SettingFootnote(L10n.t(
                    "The app's mark, drawn in the menu bar's own ink. Click it for Settings.",
                    "只显示应用标记，按菜单栏自身的颜色绘制。点击打开设置。"))
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
                "Affects the menu-bar glyph only. Percentages inside the panel always show how much has been used.",
                "只影响菜单栏图标。面板内的百分比始终表示已用量。"))
            SettingFootnote(L10n.t(
                "The glyph reports whichever provider the panel is focused on. Pick Overview in the panel to have it cover everything enabled.",
                "菜单栏图标显示的是面板中当前选中的服务商。在面板里选「总览」可让它覆盖所有已启用的服务商。"))
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

    var body: some View {
        SettingsCard(L10n.t("Where the panel lives", "面板位置")) {
            SettingRow(L10n.t("Style", "样式")) {
                GlassSegmented(
                    options: Presentation.allCases.map { (value: $0, label: $0.displayName) },
                    selection: store.presentation,
                    onSelect: { store.setPresentation($0) })
                .frame(maxWidth: 320)
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

        SettingsCard(L10n.t("Desktop widget", "桌面小工具")) {
            SettingToggle(
                L10n.t("Show on the desktop", "在桌面显示"),
                isOn: Binding(
                    get: { store.widgetEnabled },
                    set: { store.setWidgetEnabled($0) }))
            SettingRow(
                L10n.t("Size", "卡片大小"),
                caption: L10n.t("Compact is the small card; detailed the large one.", "紧凑是小卡片，详细是大卡片。"))
            {
                GlassSegmented(
                    options: WidgetDensity.allCases.map { (value: $0, label: $0.displayName) },
                    selection: store.widgetDensity,
                    onSelect: { store.setWidgetDensity($0) })
                .frame(maxWidth: 300)
                .disabled(!store.widgetEnabled)
                .opacity(store.widgetEnabled ? 1 : 0.45)
            }
            SettingRow(
                L10n.t("Shows", "显示范围"),
                caption: L10n.t("Pin one from a ring's full card in the dock.", "在停靠条里点开圆环的完整卡片可钉住一个。"))
            {
                GlassSegmented(
                    options: WidgetScope.allCases.map { (value: $0, label: $0.displayName) },
                    selection: store.widgetScope,
                    onSelect: { store.setWidgetScope($0) })
                .frame(maxWidth: 240)
                .disabled(!store.widgetEnabled)
                .opacity(store.widgetEnabled ? 1 : 0.45)
            }
            SettingToggle(
                L10n.t("Keep above other windows", "置于其他窗口之上"),
                isOn: Binding(
                    get: { store.widgetAlwaysOnTop },
                    set: { store.setWidgetAlwaysOnTop($0) }))
                .disabled(!store.widgetEnabled)
                .opacity(store.widgetEnabled ? 1 : 0.45)
            SettingFootnote(L10n.t(
                "Sits on the desktop, below your windows, unless kept above. Drag it to move; the position is remembered.",
                "默认位于桌面、在窗口之下（可改为置顶）。拖动即可移动，位置会被记住。"))
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
                        options: [1, 2, 5, 15, 30].map {
                            (value: $0, label: L10n.t("\($0)m", "\($0) 分"))
                        },
                        selection: store.refreshMinutes,
                        onSelect: { store.setRefreshMinutes($0) })
                    .frame(width: 320)
                    Button(L10n.t("Refresh now", "立即刷新")) { store.refreshAll() }
                        .glassAction()
                    Spacer(minLength: 0)
                }
            }
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
                .padding(.top, 4)
            }

            SettingRow(
                L10n.t("Updates", "更新方式"),
                caption: L10n.t(
                    "Automatic installs a new build and relaunches as soon as it is found.",
                    "自动：发现新版本就安装并重启；手动：只提醒，点击后安装。"))
            {
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

            if store.updateIsManagedByHomebrew {
                SettingFootnote(L10n.t(
                    "This copy was installed by Homebrew, which owns its updates: run `brew upgrade quotabar`.",
                    "这个副本由 Homebrew 安装，更新由它负责：运行 `brew upgrade quotabar`。"))
            }
            SettingFootnote(L10n.t(
                "A new build replaces this one in place. It is installed only if signed by this app's developer and notarized by Apple.",
                "新版本会原地替换当前的应用；只有经本应用开发者签名并通过 Apple 公证的下载才会被安装。"))
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

// MARK: - About

struct AboutPane: View {
    var body: some View {
        SettingsCard {
            HStack(spacing: Design.space3) {
                if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
                   let image = NSImage(contentsOf: url)
                {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 52, height: 52)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: Design.space2) {
                        Text("QuotaBar")
                            .font(Design.wordmark(size: 17))
                        Text(SettingsView.version)
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Text(L10n.t(
                        "Every AI coding limit, in your menu bar.",
                        "把每个 AI 编码服务的额度都放进菜单栏。"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }

        SettingsCard(L10n.t("Your data", "你的数据")) {
            SettingFootnote(L10n.t(
                "Automatic providers reuse the session your CLI already created. Manually entered tokens are stored in the macOS keychain — never in a file.",
                "自动型服务商复用 CLI 已有的登录会话；手动填写的凭据保存在 macOS 钥匙串中，不写入任何文件。"))
            SettingFootnote(L10n.t(
                "Spend figures are estimates computed locally from the CLIs' session logs at published list prices. They are not a bill.",
                "费用为本地会话日志按官方标价估算的结果，仅供参考，不等于实际账单。"))
        }
    }
}

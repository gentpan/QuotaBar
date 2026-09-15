import SwiftUI
import ServiceManagement
import QuotaCore

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
    /// Lives on the row, not the editor: the button that starts a test sits
    /// in the header, the result it produces under the editor.
    @State private var testPhase: ProviderTestPhase = .idle

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                CredentialEditor(store: store, id: id, testPhase: $testPhase)
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

            // Open, the header carries the row's two quick actions, so they
            // need no line of their own: the console link beside the name,
            // the connection test ahead of the status columns.
            if isExpanded, let url = id.dashboardURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label(L10n.t("Console", "控制台"), systemImage: "arrow.up.right")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(url.absoluteString)
                .transition(.opacity)
            }

            Spacer(minLength: Design.space2)

            if isExpanded {
                // A chip, not a field-height button: in the header it sits
                // among the status badge and the pills, and at 30pt it towered
                // over them and pushed the open row taller than the closed ones.
                Button(action: test) {
                    HStack(spacing: 4) {
                        if case .running = testPhase {
                            ProgressView().controlSize(.mini)
                            Text(L10n.t("Testing…", "测试中…"))
                        } else {
                            Image(systemName: "bolt.horizontal")
                                .font(.system(size: 9, weight: .semibold))
                            Text(L10n.t("Test connection", "测试连接"))
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Design.space2)
                    .frame(height: 20)
                    .background(Capsule().fill(Color.primary.opacity(0.05)))
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled({ if case .running = testPhase { return true }; return false }())
                .transition(.opacity)
            }

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
                .frame(width: 80, alignment: .leading)

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
        let provider = ProviderRegistry.make(id)
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

/// Where a provider row's connection test has got to.
enum ProviderTestPhase {
    case idle
    case running
    case ok(String)
    case failed(String)
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
    @Binding var testPhase: ProviderTestPhase

    init(store: UsageStore, id: ProviderID, testPhase: Binding<ProviderTestPhase>) {
        self.store = store
        self.id = id
        _testPhase = testPhase
        let value = ConfigStore.shared.credential(for: id) ?? ""
        _credential = State(initialValue: value)
        _saved = State(initialValue: value)
    }

    private var isManual: Bool { id.credentialHint != nil }
    /// Saving, clearing, authorising, signing in — what is left for a line of
    /// its own once the test and the console moved into the header.
    private var hasActions: Bool {
        isManual || (id == .claude && store.claudeNeedsAuthorization) || BrowserLogin.supports(id)
    }

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
                    // The label is set down to centre on a 30pt control; this
                    // row is text, so it comes down the same way — one point
                    // more for the 12pt figure under a 13pt label — or its
                    // baseline rides above the label's.
                    .padding(.top, Design.rowLabelInset + 1)
                }
            }

            if hasActions {
                actions
            }

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

            Spacer(minLength: 0)
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

}

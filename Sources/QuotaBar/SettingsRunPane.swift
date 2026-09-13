import AppKit
import SwiftUI
import UniformTypeIdentifiers
import QuotaCore

// MARK: - Quota Run

/// Personal records for everyone, and the leaderboard account for those who
/// sign in. The records come first and never depend on the rest: they are
/// the part that works with no account, and the part most people will use.
struct RunPane: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var run: RunCenter
    /// Pinned by the previews so relative times do not drift.
    var now: Date?

    var body: some View {
        RunRecordsCard(store: store, run: run, now: now ?? Date())
            .onAppear { run.refreshRecords() }
        if let account = run.account {
            RunMembershipCard(run: run, account: account, now: now ?? Date())
            RunProviderAccountsCard(
                run: run, account: account,
                accounts: run.localAccounts.filter { $0.providerID.map(store.enabled.contains) ?? false })
            RunDevicesCard(run: run, account: account, now: now ?? Date())
            RunProfileCard(run: run, account: account)
                // The server's copy re-seeds the fields.
                .id("profile-\(run.editorRevision)")
            RunProjectsCard(run: run, account: account)
                .id("projects-\(run.editorRevision)")
            RunLeaveCard(run: run, account: account)
        } else {
            RunSignInCard(run: run, now: now)
        }
    }
}

// MARK: Records

struct RunRecordsCard: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var run: RunCenter
    let now: Date

    var body: some View {
        SettingsCard(
            L10n.t("Your records", "你的记录"),
            help: L10n.t(
                "Every reading stays on this Mac for 60 days; bests are kept for good. \"Likely verified\" applies Quota Run's rules here — only quota.run decides a result.",
                "每次读数在本机保留 60 天，个人最佳永久保留。「预计可验证」是按 Quota Run 的规则在本机估算的，最终结果以 quota.run 为准。"))
        {
            if run.inProgress.isEmpty && run.bests.isEmpty {
                empty
            } else {
                if !run.inProgress.isEmpty {
                    RunSubheading(L10n.t("In progress", "进行中"))
                    VStack(spacing: Design.space1) {
                        ForEach(run.inProgress) { record in
                            RunProgressRow(record: record, now: now)
                        }
                    }
                }
                if !run.bests.isEmpty {
                    RunSubheading(L10n.t("Personal bests", "个人最佳"))
                        .padding(.top, run.inProgress.isEmpty ? 0 : Design.space1)
                    VStack(spacing: Design.space1) {
                        ForEach(run.bests) { best in
                            RunBestRow(store: store, best: best)
                        }
                    }
                }
            }
        }
    }

    private var empty: some View {
        HStack(alignment: .top, spacing: Design.space3) {
            Image(systemName: "flag.checkered")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(run.recordsReady
                     ? L10n.t("No records yet", "还没有记录")
                     : L10n.t("Reading the ledger…", "正在读取记录…"))
                    .font(.system(size: 13, weight: .medium))
                Text(L10n.t(
                    "Records appear as windows fill. Each reading of a window with a length and a reset time — Codex's week, Claude's 5 hours — becomes part of a run: how long it took to reach 50%, 90% and 100%, and how high it went.",
                    "额度窗口用起来之后，这里就会出现记录。有固定长度和重置时间的窗口（比如 Codex 的一周、Claude 的 5 小时），每次读数都会汇入一轮：多久用到 50%、90% 和 100%，以及最高用到多少。"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Design.space3)
        .background(RoundedRectangle(cornerRadius: Design.radiusTile, style: .continuous).fill(Design.surfaceStrong))
    }
}

private struct RunSubheading: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A provider's mark by raw value, with a neutral stand-in for one this build
/// does not know.
private struct RunGlyph: View {
    let provider: String
    var size: CGFloat = 16
    var tint: Color?

    var body: some View {
        if let id = ProviderID(rawValue: provider) {
            ProviderGlyph(id: id, size: size, tint: tint)
        } else {
            Image(systemName: "questionmark.circle")
                .font(.system(size: size * 0.8))
                .frame(width: size, height: size)
        }
    }
}

enum RunText {
    static func providerName(_ raw: String) -> String {
        ProviderID(rawValue: raw)?.displayName ?? raw
    }

    /// "Codex · Pro 20x".
    static func title(provider: String, plan: String?) -> String {
        [providerName(provider), plan].compactMap { $0 }.joined(separator: " · ")
    }

    static func window(seconds: Int, scope: String?) -> String {
        RunFormat.windowName(seconds: seconds, scope: scope, fallback: scope ?? "")
    }

    /// The local estimate of a run's tier. A run with a reading that named
    /// no provider account is unranked on quota.run unless it is flagged.
    static func tier(_ record: RunRecord) -> String? {
        switch record.tier {
        case .flagged: return L10n.t("would be flagged", "可能被标记存疑")
        case _ where record.unbound:
            return L10n.t("Not bound to an account — won't rank", "未绑定服务商账号，不会上榜")
        case .verified: return L10n.t("likely verified", "预计可验证")
        case .standard: return nil
        }
    }
}

private struct RunProgressRow: View {
    let record: RunRecord
    let now: Date

    var body: some View {
        let elapsed = Int(now.timeIntervalSince1970) - record.windowStart
        HStack(spacing: Design.space3) {
            RunGlyph(provider: record.provider)
            VStack(alignment: .leading, spacing: 2) {
                Text(RunText.title(provider: record.provider, plan: record.plan))
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(L10n.t(
                    "\(RunText.window(seconds: record.windowSeconds, scope: record.scope)) · started \(RunFormat.duration(elapsed)) ago",
                    "\(RunText.window(seconds: record.windowSeconds, scope: record.scope)) · 已开始 \(RunFormat.duration(elapsed))"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Design.space2)
            RunMeter(percent: record.lastPercent, accentHex: ProviderID(rawValue: record.provider)?.accentHex)
                .frame(width: 88, height: 6)
            Text(QuotaFormat.percent(record.lastPercent))
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .frame(minWidth: 48, alignment: .trailing)
        }
        .padding(.horizontal, Design.space3)
        .padding(.vertical, Design.space2)
        .background(RoundedRectangle(cornerRadius: Design.radiusTile, style: .continuous).fill(Design.surfaceStrong))
    }
}

private struct RunMeter: View {
    let percent: Double
    let accentHex: String?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Design.track)
                Capsule()
                    .fill(accentHex.map { Color(hex: $0) } ?? Color.primary)
                    .frame(width: proxy.size.width * CGFloat(min(max(percent, 0), 100) / 100))
            }
        }
    }
}

private struct RunBestRow: View {
    @ObservedObject var store: UsageStore
    let best: PersonalBest
    @State private var copied = false

    private func copy() {
        guard RunShare.copy(best, store: store) else { return }
        withAnimation(.easeOut(duration: 0.15)) { copied = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.easeOut(duration: 0.3)) { copied = false }
        }
    }

    private var detail: String {
        var parts: [String] = []
        if let fastest = best.fastest {
            if let to50 = fastest.secondsTo50 { parts.append(L10n.t("50% in \(RunFormat.duration(to50))", "50% 用时 \(RunFormat.duration(to50))")) }
            if let to90 = fastest.secondsTo90 { parts.append(L10n.t("90% in \(RunFormat.duration(to90))", "90% 用时 \(RunFormat.duration(to90))")) }
        }
        if let peak = best.highestPeak {
            parts.append(L10n.t("peak \(QuotaFormat.percent(peak.peakPercent))", "最高 \(QuotaFormat.percent(peak.peakPercent))"))
        }
        if let tier = (best.fastest ?? best.highestPeak).flatMap(RunText.tier) {
            parts.append(tier)
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: Design.space3) {
            RunGlyph(provider: best.provider)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(RunText.title(provider: best.provider, plan: best.plan)) · \(RunText.window(seconds: best.windowSeconds, scope: best.scope))")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Design.space2)
            VStack(alignment: .trailing, spacing: 1) {
                if let seconds = best.fastest?.secondsTo100 {
                    Text(RunFormat.duration(seconds))
                        .font(.system(size: 14, weight: .semibold))
                        .monospacedDigit()
                    Text(L10n.t("to 100%", "用满 100%"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else if let peak = best.highestPeak {
                    Text(QuotaFormat.percent(peak.peakPercent))
                        .font(.system(size: 14, weight: .semibold))
                        .monospacedDigit()
                    Text(L10n.t("highest", "最高"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize()
            GlassMenuButton(
                title: L10n.t("Share", "分享"),
                systemImage: "square.and.arrow.up",
                items: [
                    (L10n.t("Copy Image", "复制图片"), { copy() }),
                    (L10n.t("Save PNG…", "保存 PNG…"), { RunShare.save(best, store: store) }),
                ])
                .overlay(alignment: .bottom) {
                    // The settings window has no pill of its own; say it here.
                    if copied {
                        Text(L10n.t("Copied", "已复制"))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .offset(y: Design.space3)
                            .transition(.opacity)
                    }
                }
        }
        .padding(.leading, Design.space3)
        .padding(.trailing, Design.space2)
        .padding(.vertical, Design.space2)
        .background(RoundedRectangle(cornerRadius: Design.radiusTile, style: .continuous).fill(Design.surfaceStrong))
    }
}

// MARK: Share card

/// A best as an image: the provider, the plan and the window, and the figure
/// that matters — in the black frame every copied card wears.
struct RunBestShareCard: View {
    let best: PersonalBest

    private var hero: (label: String, value: String) {
        if let seconds = best.fastest?.secondsTo100 {
            return (L10n.t("100% in", "用满 100%"), RunFormat.duration(seconds))
        }
        return (L10n.t("Highest", "最高用到"), QuotaFormat.percent(best.highestPeak?.peakPercent ?? 0))
    }

    private var date: String? {
        guard let run = best.fastest ?? best.highestPeak else { return nil }
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.setLocalizedDateFormatFromTemplate("yMMMd")
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(run.completedAt ?? run.lastObservedAt)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                RunGlyph(provider: best.provider, size: 22, tint: .white)
                Text(RunText.title(provider: best.provider, plan: best.plan))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 8)
                Text(RunText.window(seconds: best.windowSeconds, scope: best.scope))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(hero.label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                Text(hero.value)
                    .font(.system(size: 42, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            HStack(spacing: 14) {
                if let to50 = best.fastest?.secondsTo50 { fact("50%", RunFormat.duration(to50)) }
                if let to90 = best.fastest?.secondsTo90 { fact("90%", RunFormat.duration(to90)) }
                if let peak = best.highestPeak { fact(L10n.t("Peak", "最高"), QuotaFormat.percent(peak.peakPercent)) }
                Spacer(minLength: 0)
                if let date {
                    Text(date)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: Design.radiusCard, style: .continuous).fill(Color.white.opacity(0.07)))
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.9))
        }
    }
}

@MainActor
enum RunShare {
    static func card(_ best: PersonalBest, store: UsageStore) -> some View {
        ShareableCard(store: store) { RunBestShareCard(best: best) }
    }

    /// "Codex · Pro 20x · Weekly window — 100% in 2h 37m", for the text that
    /// travels with the image.
    static func caption(_ best: PersonalBest) -> String {
        let title = "\(RunText.title(provider: best.provider, plan: best.plan)) · \(RunText.window(seconds: best.windowSeconds, scope: best.scope))"
        let figure: String
        if let seconds = best.fastest?.secondsTo100 {
            figure = L10n.t("100% in \(RunFormat.duration(seconds))", "\(RunFormat.duration(seconds)) 用满 100%")
        } else {
            figure = L10n.t("peak \(QuotaFormat.percent(best.highestPeak?.peakPercent ?? 0))", "最高 \(QuotaFormat.percent(best.highestPeak?.peakPercent ?? 0))")
        }
        return "\(title) — \(figure) · Quota Run · https://quota.run"
    }

    @discardableResult
    static func copy(_ best: PersonalBest, store: UsageStore) -> Bool {
        guard CardImageExporter.copy(card(best, store: store), text: caption(best)) else { return false }
        store.flashNotice(L10n.t("Copied to clipboard", "已复制到剪贴板"))
        return true
    }

    static func save(_ best: PersonalBest, store: UsageStore) {
        guard let image = CardImageExporter.image(card(best, store: store), scale: 3),
              let png = CardImageExporter.pngData(image)
        else { NSSound.beep(); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "QuotaBar-\(best.provider)-\(best.windowSeconds / 3_600)h.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try png.write(to: url)
        } catch {
            NSSound.beep()
        }
    }
}

// MARK: Signing in

struct RunSignInCard: View {
    @ObservedObject var run: RunCenter
    /// Pinned by the previews; otherwise the expiry counts down on its own.
    var now: Date?
    @State private var agreed: Bool

    init(run: RunCenter, now: Date? = nil, agreed: Bool = false) {
        self.run = run
        self.now = now
        _agreed = State(initialValue: agreed)
    }

    var body: some View {
        SettingsCard(L10n.t("Sign in to Quota Run", "登录 Quota Run")) {
            SettingFootnote(L10n.t(
                "Quota Run is QuotaBar's opt-in leaderboard at quota.run: how fast a subscription window gets used up, and a public profile with what you build. Nothing is uploaded until you sign in, and then only from one ranked Mac.",
                "Quota Run 是 QuotaBar 的自愿排行榜，在 quota.run 上比谁用满订阅额度窗口更快，并有一个展示你作品的公开主页。登录之前什么都不会上传；登录之后也只从一台计分设备上传。"))

            switch run.signInPhase {
            case let .waiting(code, _, expiresAt):
                RunSignInWaiting(run: run, code: code, expiresAt: expiresAt, now: now)
            case .starting, .approved:
                RunSignInWaiting(run: run, code: nil, expiresAt: nil, now: now)
            case .idle, .denied, .expired, .failed:
                form
            }
        }
    }

    @ViewBuilder
    private var form: some View {
        RunConsent()

        Button {
            agreed.toggle()
        } label: {
            HStack(alignment: .top, spacing: Design.space2) {
                Image(systemName: agreed ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle(agreed ? Color.primary : Color.secondary)
                Text(L10n.t(
                    "I agree to upload what is listed above, including readings from the last 7 days already on this Mac.",
                    "我同意上传上面列出的内容，包括本机已记录的最近 7 天读数。"))
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        HStack(spacing: Design.space3) {
            Button {
                run.signIn()
            } label: {
                Label(L10n.t("Sign In with quota.run", "用 quota.run 登录"), systemImage: "arrow.up.right")
            }
            .glassAction(prominent: true)
            .disabled(!agreed)
            HelpMark(L10n.t(
                "The browser opens quota.run with a code to approve. Already signed in on another Mac? Sign in here with the same account to add this one.",
                "浏览器会打开 quota.run，显示一个待批准的代码。已在别的 Mac 上登录？在这里用同一个账户登录，就能添加这台 Mac。"))
            if let message = run.signInPhase.message {
                RunInlineError(message)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
        }
    }
}

/// The code and the wait: compare, approve in the browser, or call it off.
private struct RunSignInWaiting: View {
    @ObservedObject var run: RunCenter
    /// Nil while quota.run is still being asked for one.
    let code: String?
    let expiresAt: Date?
    let now: Date?
    @Environment(\.glassDisabled) private var rendering

    var body: some View {
        VStack(alignment: .leading, spacing: Design.space3) {
            if let code {
                VStack(alignment: .leading, spacing: Design.space1) {
                    Text(L10n.t("Check that quota.run shows this code", "请确认 quota.run 上显示的是这个代码"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(code)
                        .font(.system(size: 28, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            HStack(spacing: Design.space2) {
                if rendering {
                    // The spinner is an AppKit view the renderer cannot draw.
                    Image(systemName: "hourglass")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(code == nil
                     ? L10n.t("Opening quota.run…", "正在打开 quota.run…")
                     : L10n.t("Waiting for approval in your browser…", "正在等待你在浏览器中批准…"))
                    .font(.system(size: 13))
                if let expiresAt {
                    if let now {
                        expiry(expiresAt, now: now)
                    } else {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            expiry(expiresAt, now: context.date)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: Design.space3) {
                Button {
                    run.openBrowserAgain()
                } label: {
                    Label(L10n.t("Open Browser Again", "重新打开浏览器"), systemImage: "arrow.up.right")
                }
                .glassAction()
                .disabled(code == nil)
                Button(L10n.t("Cancel", "取消")) { run.cancelSignIn() }
                    .glassAction()
                Spacer(minLength: 0)
            }
        }
        .padding(Design.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Design.radiusTile, style: .continuous).fill(Design.surfaceStrong))
    }

    private func expiry(_ date: Date, now: Date) -> some View {
        Text(date > now
             ? L10n.t("· code expires \(RunMembershipCard.relative(date, now: now))", "· 代码\(RunMembershipCard.relative(date, now: now))过期")
             : L10n.t("· code expired", "· 代码已过期"))
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }
}

/// Exactly what leaves the Mac after signing in, and what never does — the
/// contract's principles, in the words the owner agrees to.
private struct RunConsent: View {
    private var uploaded: [String] {
        [
            L10n.t("Provider and plan name", "服务商和套餐名称"),
            L10n.t("Each window's used percent, reset time and when it was read", "每个额度窗口的已用百分比、重置时间和读取时间"),
            L10n.t("The window's length and scope", "窗口长度和适用范围"),
            L10n.t("A one-way digest of the provider account (never the email)", "服务商账号的单向摘要（不含邮箱本身）"),
            L10n.t("Tokens per minute from local CLI logs — counts only", "本地 CLI 日志里每分钟的 token 数，只有数量"),
            L10n.t("Your username, display name, region and this Mac's name", "你的用户名、显示名称、地区和这台 Mac 的名字"),
        ]
    }

    private var never: [String] {
        [
            L10n.t("Credentials, tokens, cookies or API keys", "凭据、令牌、Cookie 或 API Key"),
            L10n.t("Prompts, code or model outputs", "提示词、代码或模型输出"),
            L10n.t("File or project paths", "文件或项目路径"),
            L10n.t("Your account email in the clear", "明文的账号邮箱"),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.space2) {
            HStack(alignment: .top, spacing: Design.space2) {
                list(L10n.t("Uploaded after you sign in", "登录后会上传"), symbol: "arrow.up.circle", items: uploaded)
                list(L10n.t("Never uploaded", "永远不会上传"), symbol: "nosign", items: never)
            }
            .fixedSize(horizontal: false, vertical: true)
            SettingFootnote(L10n.t(
                "You sign in on quota.run with Google, GitHub or an email code; the app never sees a password. Ranked results, each run's usage curve and a heatmap of tokens per day on your profile are public on quota.run (the heatmap can be turned off on the account page); the sign-in email is never shown — not on your profile, not on the boards.",
                "登录在 quota.run 上完成，可用 Google、GitHub 或邮箱验证码，本应用不经手任何密码。上榜的成绩、每一轮的用量曲线和主页上每天 token 用量的热力图会在 quota.run 上公开（热力图可以在账号页关掉）；登录邮箱永远不会公开，不会出现在你的主页或排行榜上。"))
        }
    }

    private func list(_ title: String, symbol: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: Design.space2) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold))
            VStack(alignment: .leading, spacing: Design.space1) {
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("·")
                        Text(item)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(Design.space3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Design.radiusTile, style: .continuous).fill(Design.surfaceStrong))
    }
}

private struct RunInlineError: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Palette.red)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The line beside a button: working, done, or what went wrong.
private struct RunPhaseLabel: View {
    let phase: RunPhase

    var body: some View {
        switch phase {
        case .idle, .working:
            EmptyView()
        case let .done(text):
            Label(text, systemImage: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        case let .failed(text):
            RunInlineError(text)
                .lineLimit(3)
        }
    }
}

// MARK: Signed in

private struct RunMembershipCard: View {
    @ObservedObject var run: RunCenter
    let account: RunAccountState
    let now: Date

    var body: some View {
        SettingsCard {
            HStack(spacing: Design.space3) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("@\(account.username)")
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Text("\(account.displayName) · \(account.region.displayName)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: Design.space2)
                Button {
                    NSWorkspace.shared.open(account.profileURL)
                } label: {
                    Label(L10n.t("View My Profile", "查看我的主页"), systemImage: "arrow.up.right")
                }
                .glassAction()
                .help(account.profileURL.absoluteString)
                Button {
                    NSWorkspace.shared.open(RunAccountState.accountURL())
                } label: {
                    Label(L10n.t("Manage Account on quota.run", "在 quota.run 管理账户"), systemImage: "arrow.up.right")
                }
                .glassAction()
                .help(RunAccountState.accountURL().absoluteString)
            }

            SettingRow(L10n.t("Signs in with", "登录方式")) {
                identities
                    .frame(minHeight: Design.fieldHeight, alignment: .leading)
            }

            SettingRow(L10n.t("Uploads", "上传")) {
                HStack(alignment: .top, spacing: Design.space3) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(status)
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                        if let problem {
                            RunInlineError(problem)
                        }
                    }
                    .padding(.top, Design.rowLabelInset)
                    Spacer(minLength: 0)
                    if run.uploadBlocker == nil {
                        Button(run.isUploading ? L10n.t("Sending…", "发送中…") : L10n.t("Send Now", "立即发送")) {
                            run.uploadIfDue(now: true)
                        }
                        .glassAction()
                        .disabled(run.isUploading)
                    }
                }
            }
        }
    }

    /// Chips in a row, or stacked when three addresses will not fit across.
    @ViewBuilder
    private var identities: some View {
        let list = account.me?.identities ?? []
        if list.isEmpty {
            Text(L10n.t("Google, GitHub or email, on quota.run", "在 quota.run 上用 Google、GitHub 或邮箱"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Design.space2) { chips(list) }
                VStack(alignment: .leading, spacing: Design.space1) { chips(list) }
            }
        }
    }

    private func chips(_ list: [RunIdentity]) -> some View {
        ForEach(list) { identity in
            Text(identity.label)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, Design.space2)
                .padding(.vertical, 2)
                .background(Capsule().fill(Design.surfaceStrong))
                .help(identity.linkedAt.map { L10n.t("Linked \(QuotaFormat.age(of: $0, now: now))", "关联于 \(QuotaFormat.age(of: $0, now: now))") } ?? "")
        }
    }

    private var status: String {
        let sent = run.upload.lastUploadAt.map { L10n.t("Last sent \(QuotaFormat.age(of: $0, now: now))", "上次发送：\(QuotaFormat.age(of: $0, now: now))") }
            ?? L10n.t("Nothing sent yet", "尚未发送")
        return L10n.t("\(sent) · \(run.queued) waiting", "\(sent) · 待发送 \(run.queued) 条")
    }

    private var problem: String? {
        if let blocker = run.uploadBlocker { return blocker }
        guard let error = run.upload.lastError else { return nil }
        if let retry = run.upload.retryAt, retry > now {
            return L10n.t("\(error) Trying again \(Self.relative(retry, now: now)).", "\(error) \(Self.relative(retry, now: now))重试。")
        }
        return error
    }

    static func relative(_ date: Date, now: Date) -> String {
        L10n.t("in \(QuotaFormat.countdown(to: date, from: now))", "\(QuotaFormat.countdown(to: date, from: now))后")
    }
}

/// The provider accounts this Mac reads, and where each stands on quota.run.
/// The email is shown masked and only here; quota.run only ever sees a digest.
struct RunProviderAccountsCard: View {
    @ObservedObject var run: RunCenter
    let account: RunAccountState
    /// This Mac's accounts for the providers that are turned on.
    let accounts: [RunLocalAccount]
    @State private var confirmUnbind: RunLocalAccount?

    var body: some View {
        SettingsCard(
            L10n.t("Provider accounts", "服务商账号"),
            help: L10n.t(
                "Only runs bound to a provider account can rank, and each provider account counts for one Quota account. The email stays on this Mac; quota.run gets a one-way digest.",
                "只有绑定了服务商账号的成绩才能上榜，每个服务商账号只归属一个 Quota 账户。邮箱只留在这台 Mac 上，quota.run 收到的是单向摘要。"))
        {
            if accounts.isEmpty {
                SettingFootnote(L10n.t(
                    "None of your providers has reported which account it is signed in with yet.",
                    "你的服务商还没有报告登录的是哪个账号。"))
            } else {
                VStack(spacing: Design.space1) {
                    ForEach(accounts) { local in
                        row(local)
                    }
                }
            }
            RunPhaseLabel(phase: run.accountsPhase)
        }
        .onAppear { Task { await run.lookupAccounts() } }
        .alert(
            L10n.t("Unbind this provider account?", "解除绑定这个服务商账号？"),
            isPresented: Binding(get: { confirmUnbind != nil }, set: { if !$0 { confirmUnbind = nil } }),
            presenting: confirmUnbind)
        { local in
            Button(L10n.t("Unbind", "解除绑定"), role: .destructive) { run.unbindAccount(local) }
            Button(L10n.t("Cancel", "取消"), role: .cancel) {}
        } message: { local in
            Text(account.standing(of: local.digest).account == nil
                 ? L10n.t(
                     "This Mac stops uploading \(local.masked). Nothing from it is on quota.run yet. Your records on this Mac stay.",
                     "这台 Mac 将停止上传 \(local.masked)。quota.run 上还没有它的任何数据。本机上的个人记录会保留。")
                 : L10n.t(
                     "Deletes the readings and runs of \(local.masked) on quota.run and stops uploading it from this Mac. Your records on this Mac stay.",
                     "将删除 quota.run 上 \(local.masked) 的读数和成绩，并停止从这台 Mac 上传它。本机上的个人记录会保留。"))
        }
    }

    private func row(_ local: RunLocalAccount) -> some View {
        let standing = account.standing(of: local.digest)
        return HStack(spacing: Design.space3) {
            // Marks differ in width; a fixed column keeps the names in line.
            RunGlyph(provider: local.provider)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Design.space2) {
                    Text(RunText.providerName(local.provider))
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .fixedSize()
                    Text(local.masked)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    chip(standing)
                }
                if let detail = detail(standing, local: local) {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Design.space2)
            if case .unbound = standing {
                Button(L10n.t("Bind Again", "重新绑定")) { run.bindAgain(local) }
                    .glassAction(compact: true)
                    .disabled(run.accountsPhase.isWorking)
            } else {
                Button(L10n.t("Unbind…", "解除绑定…"), role: .destructive) { confirmUnbind = local }
                    .glassAction(compact: true)
                    .disabled(run.accountsPhase.isWorking)
            }
        }
        .padding(.horizontal, Design.space3)
        .padding(.vertical, Design.space2)
        .background(RoundedRectangle(cornerRadius: Design.radiusTile, style: .continuous).fill(Design.surfaceStrong))
    }

    @ViewBuilder
    private func chip(_ standing: RunAccountStanding) -> some View {
        switch standing {
        case .notUploaded: StatusPill(text: L10n.t("Not uploaded yet", "尚未上传"), tone: .idle)
        case .bound: StatusPill(text: L10n.t("Bound", "已绑定"), tone: .ready)
        case .verified: StatusPill(text: L10n.t("Account verified", "账号已验证"), tone: .ready)
        case .elsewhere: StatusPill(text: L10n.t("Owned by another Quota account", "归属另一个 Quota 账户"), tone: .attention)
        case .unbound: StatusPill(text: L10n.t("Unbound", "已解除绑定"), tone: .idle)
        }
    }

    private func detail(_ standing: RunAccountStanding, local: RunLocalAccount) -> String? {
        switch standing {
        case .notUploaded:
            return nil
        case let .bound(bound), let .verified(bound):
            return L10n.t(bound.runs == 1 ? "1 run counts" : "\(bound.runs) runs count", "\(bound.runs) 轮成绩计入")
        case .elsewhere:
            return local.isEmail
                ? L10n.t(
                    "Runs from it don't count. Sign in to quota.run with this email to claim it.",
                    "它的成绩不计入。用这个邮箱登录 quota.run 即可认领。")
                : L10n.t("Runs from it don't count while another Quota account owns it.", "在另一个 Quota 账户名下时，它的成绩不计入。")
        case .unbound:
            return L10n.t("This Mac doesn't upload it.", "这台 Mac 不再上传它。")
        }
    }
}

private struct RunDevicesCard: View {
    @ObservedObject var run: RunCenter
    let account: RunAccountState
    let now: Date
    @State private var confirmRemoval: RunDevice?

    private var devices: [RunDevice] {
        account.me?.devices ?? [RunDevice(deviceId: account.deviceId, name: RunCenter.deviceName, ranked: account.ranked, current: true)]
    }

    private var cooldown: Date? {
        guard let date = account.me?.rankedChangeAvailableAt, date > now else { return nil }
        return date
    }

    var body: some View {
        SettingsCard(L10n.t("Ranked device", "计分设备"), help: cooldownNote) {
            VStack(spacing: Design.space1) {
                ForEach(devices) { device in
                    row(device)
                }
            }
            if !account.ranked {
                HStack(spacing: Design.space3) {
                    Button(L10n.t("Make This Mac Ranked", "设为计分设备")) { run.makeThisMacRanked() }
                        .glassAction(prominent: true)
                        .disabled(cooldown != nil || run.devicesPhase.isWorking)
                    if let cooldown {
                        Text(L10n.t("Available \(RunMembershipCard.relative(cooldown, now: now))", "\(RunMembershipCard.relative(cooldown, now: now))可以更换"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
            RunPhaseLabel(phase: run.devicesPhase)
        }
        .alert(
            L10n.t("Remove this Mac from your account?", "从账户中移除这台 Mac？"),
            isPresented: Binding(get: { confirmRemoval != nil }, set: { if !$0 { confirmRemoval = nil } }),
            presenting: confirmRemoval)
        { device in
            Button(L10n.t("Remove", "移除"), role: .destructive) { run.removeDevice(device.deviceId) }
            Button(L10n.t("Cancel", "取消"), role: .cancel) {}
        } message: { device in
            Text(L10n.t("\(device.name) will need to sign in again to upload.", "\(device.name) 之后需要重新登录才能再次上传。"))
        }
    }

    private var cooldownNote: String {
        let base = L10n.t(
            "Only the ranked Mac's readings count on the boards. It can change once every 7 days. To add another Mac, sign in on it with the same account.",
            "只有计分设备的读数计入排行榜，每 7 天最多更换一次。要添加另一台 Mac，在那台 Mac 上用同一个账户登录即可。")
        guard let cooldown else { return base }
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.setLocalizedDateFormatFromTemplate("MMMdjm")
        return base + " " + L10n.t("Next change: \(formatter.string(from: cooldown)).", "下次可更换：\(formatter.string(from: cooldown))。")
    }

    /// "Seen 2m ago · QuotaBar 0.6.0".
    private func detail(_ device: RunDevice) -> String? {
        let parts = [
            device.lastSeenAt.map { L10n.t("Seen \(QuotaFormat.age(of: $0, now: now))", "最近活动：\(QuotaFormat.age(of: $0, now: now))") },
            device.appVersion.map { "QuotaBar \($0)" },
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func row(_ device: RunDevice) -> some View {
        HStack(spacing: Design.space3) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Design.space2) {
                    Text(device.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if device.current || device.deviceId == account.deviceId {
                        Text(L10n.t("This Mac", "本机"))
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Design.surfaceStrong))
                    }
                }
                if let detail = detail(device) {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Design.space2)
            if device.ranked {
                StatusPill(text: L10n.t("Ranked", "计分中"), tone: .ready)
            } else if !(device.current || device.deviceId == account.deviceId) {
                Button(L10n.t("Remove", "移除"), role: .destructive) { confirmRemoval = device }
                    .glassAction(compact: true)
                    .disabled(run.devicesPhase.isWorking)
            }
        }
        .padding(.horizontal, Design.space3)
        .padding(.vertical, Design.space2)
        .background(RoundedRectangle(cornerRadius: Design.radiusTile, style: .continuous).fill(Design.surfaceStrong))
    }
}

private struct RunProfileCard: View {
    @ObservedObject var run: RunCenter
    @State private var displayName: String
    @State private var bio: String
    @State private var region: RunRegion
    @State private var website: String
    @State private var github: String
    @State private var x: String

    init(run: RunCenter, account: RunAccountState) {
        self.run = run
        let user = account.me?.user
        _displayName = State(initialValue: user?.displayName ?? account.displayName)
        _bio = State(initialValue: user?.bio ?? "")
        _region = State(initialValue: user?.region ?? account.region)
        _website = State(initialValue: user?.links.website ?? "")
        _github = State(initialValue: user?.links.github ?? "")
        _x = State(initialValue: user?.links.x ?? "")
    }

    private var problem: String? {
        if displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return L10n.t("A display name is needed.", "请填写显示名称。") }
        if displayName.count > 40 { return L10n.t("Display names are at most 40 characters.", "显示名称最多 40 个字符。") }
        if bio.count > 160 { return L10n.t("The bio is at most 160 characters.", "简介最多 160 个字符。") }
        // Handles are fine — the server expands them — but not another scheme.
        for link in [website, github, x] where !link.trimmingCharacters(in: .whitespaces).isEmpty && !RunProject.isHandleOrHTTPS(link) {
            return L10n.t("Links take a handle or an https:// address.", "链接请填写账号名或 https:// 地址。")
        }
        return nil
    }

    var body: some View {
        SettingsCard(L10n.t("Profile", "个人资料")) {
            SettingRow(L10n.t("Display name", "显示名称")) {
                GlassTextField(placeholder: "", text: $displayName, monospaced: false)
                    .frame(maxWidth: 320)
            }
            SettingRow(L10n.t("Bio", "简介")) {
              VStack(alignment: .trailing, spacing: Design.space1) {
                TextEditor(text: $bio)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(Design.space2)
                    .frame(minHeight: 64)
                    .background(RoundedRectangle(cornerRadius: Design.radiusField, style: .continuous).fill(Design.fieldFill))
                    .overlay(RoundedRectangle(cornerRadius: Design.radiusField, style: .continuous).strokeBorder(Design.glassEdge, lineWidth: 1))
                Text("\(bio.count) / 160")
                    .font(.system(size: 11))
                    .foregroundStyle(bio.count > 160 ? Color.red : Color.secondary)
                    .monospacedDigit()
              }
            }
            SettingRow(L10n.t("Region", "地区")) {
                GlassSegmented(
                    options: RunRegion.allCases.map { (value: $0, label: $0.displayName) },
                    selection: region,
                    onSelect: { region = $0 })
                .frame(maxWidth: 220)
            }
            SettingRow(L10n.t("Website", "网站")) {
                GlassTextField(placeholder: "https://", text: $website)
                    .frame(maxWidth: 320)
            }
            SettingRow("GitHub") {
                GlassTextField(placeholder: L10n.t("username", "用户名"), text: $github)
                    .frame(maxWidth: 320)
            }
            SettingRow("X") {
                GlassTextField(placeholder: "@handle", text: $x)
                    .frame(maxWidth: 320)
            }
            HStack(spacing: Design.space3) {
                // Under the fields it saves, as Feedback's Send is.
                Spacer().frame(width: Design.labelColumn)
                Button(run.profilePhase.isWorking ? L10n.t("Saving…", "正在保存…") : L10n.t("Save Profile", "保存资料")) {
                    run.saveProfile(displayName: displayName, bio: bio, region: region, links: RunLinks(website: website, github: github, x: x))
                }
                .glassAction(prominent: true)
                .disabled(problem != nil || run.profilePhase.isWorking)
                if let problem {
                    RunInlineError(problem)
                } else {
                    RunPhaseLabel(phase: run.profilePhase)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

struct RunProjectsCard: View {
    @ObservedObject var run: RunCenter
    @State private var projects: [RunProject]
    @State private var editing: Int?
    private let saved: [RunProject]

    init(run: RunCenter, account: RunAccountState, editing: Int? = nil) {
        self.run = run
        let list = account.me?.projects ?? []
        saved = list
        _projects = State(initialValue: list)
        _editing = State(initialValue: editing)
    }

    var body: some View {
        SettingsCard(L10n.t("Projects", "项目")) {
            if projects.isEmpty {
                SettingFootnote(L10n.t(
                    "What you build with these tools, shown as cards on your profile. Up to 12.",
                    "用这些工具做出来的东西，会以卡片形式显示在你的主页上，最多 12 个。"))
            }
            VStack(spacing: Design.space1) {
                ForEach(projects.indices, id: \.self) { index in
                    if editing == index {
                        RunProjectEditor(project: $projects[index], onDone: { editing = nil }, onRemove: {
                            projects.remove(at: index)
                            editing = nil
                        })
                    } else {
                        row(index)
                    }
                }
            }
            HStack(spacing: Design.space3) {
                Button {
                    projects.append(RunProject(url: "https://"))
                    editing = projects.count - 1
                } label: {
                    Label(L10n.t("Add Project", "添加项目"), systemImage: "plus")
                }
                .glassAction()
                .disabled(projects.count >= RunProject.limit)
                Button(run.projectsPhase.isWorking ? L10n.t("Saving…", "正在保存…") : L10n.t("Save Projects", "保存项目")) {
                    editing = nil
                    run.saveProjects(projects)
                }
                .glassAction(prominent: true)
                .disabled(projects == saved || run.projectsPhase.isWorking)
                RunPhaseLabel(phase: run.projectsPhase)
                Spacer(minLength: 0)
            }
        }
    }

    private func row(_ index: Int) -> some View {
        let project = projects[index]
        return HStack(alignment: .top, spacing: Design.space3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name.isEmpty ? L10n.t("Untitled", "未命名") : project.name)
                    .font(.system(size: 13, weight: .medium))
                if !project.description.isEmpty {
                    Text(project.description)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(project.url)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: Design.space2)
            HStack(spacing: 3) {
                ForEach(project.builtWith, id: \.self) { provider in
                    RunGlyph(provider: provider, size: 14)
                }
            }
            .padding(.top, 2)
            Button(L10n.t("Edit", "编辑")) { editing = index }
                .glassAction(compact: true)
        }
        .padding(.horizontal, Design.space3)
        .padding(.vertical, Design.space2)
        .background(RoundedRectangle(cornerRadius: Design.radiusTile, style: .continuous).fill(Design.surfaceStrong))
    }
}

private struct RunProjectEditor: View {
    @Binding var project: RunProject
    let onDone: () -> Void
    let onRemove: () -> Void

    private var github: Binding<String> {
        Binding(get: { project.github ?? "" }, set: { project.github = $0.isEmpty ? nil : $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.space2) {
            SettingRow(L10n.t("Name", "名称")) {
                GlassTextField(placeholder: "", text: $project.name, monospaced: false)
            }
            SettingRow(L10n.t("Description", "简介")) {
                HStack(spacing: Design.space2) {
                    GlassTextField(placeholder: "", text: $project.description, monospaced: false)
                    Text("\(project.description.count) / 140")
                        .font(.system(size: 11))
                        .foregroundStyle(project.description.count > 140 ? Color.red : Color.secondary)
                        .monospacedDigit()
                        .fixedSize()
                }
            }
            SettingRow(L10n.t("Address", "网址")) {
                GlassTextField(placeholder: "https://", text: $project.url)
            }
            SettingRow("GitHub") {
                GlassTextField(placeholder: L10n.t("https://github.com/… (optional)", "https://github.com/…（选填）"), text: github)
            }
            SettingRow(L10n.t("Built with", "使用的工具")) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: Design.space1)], alignment: .leading, spacing: Design.space1) {
                    ForEach(ProviderID.allCases) { id in
                        chip(id)
                    }
                }
            }
            HStack(spacing: Design.space3) {
                Spacer().frame(width: Design.labelColumn)
                Button(L10n.t("Done", "完成"), action: onDone)
                    .glassAction()
                Button(L10n.t("Remove", "删除"), role: .destructive, action: onRemove)
                    .glassAction()
                if let problem = project.problem {
                    RunInlineError(problem)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(Design.space3)
        .background(RoundedRectangle(cornerRadius: Design.radiusTile, style: .continuous).fill(Design.surfaceStrong))
    }

    private func chip(_ id: ProviderID) -> some View {
        let on = project.builtWith.contains(id.rawValue)
        return Button {
            if on {
                project.builtWith.removeAll { $0 == id.rawValue }
            } else {
                project.builtWith.append(id.rawValue)
            }
        } label: {
            HStack(spacing: 5) {
                ProviderGlyph(id: id, size: 12, ink: on)
                Text(id.displayName)
                    .font(.system(size: 11, weight: on ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Design.space2)
            .frame(height: 24)
            .foregroundStyle(on ? Design.ink : Color.primary)
            .background(RoundedRectangle(cornerRadius: Design.radiusField - Design.controlInset, style: .continuous).fill(on ? Design.accent : Design.fieldFill))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Two ways out, told apart: this Mac leaves the account, or the account goes.
private struct RunLeaveCard: View {
    @ObservedObject var run: RunCenter
    let account: RunAccountState
    @State private var confirmingDisconnect = false
    @State private var confirmingDelete = false

    private var busy: Bool { run.disconnectPhase.isWorking || run.deletePhase.isWorking }

    var body: some View {
        SettingsCard(L10n.t("Disconnect or delete", "断开或删除")) {
            SettingRow(L10n.t("This Mac", "这台 Mac")) {
                VStack(alignment: .leading, spacing: Design.space2) {
                    HStack(spacing: Design.space3) {
                        Button(run.disconnectPhase.isWorking ? L10n.t("Disconnecting…", "正在断开…") : L10n.t("Disconnect This Mac", "断开这台 Mac")) {
                            confirmingDisconnect = true
                        }
                        .glassAction()
                        .disabled(busy)
                        HelpMark(L10n.t(
                            "Takes this Mac off @\(account.username) and forgets its key. The account, your other Macs and the records on this Mac stay; sign in again any time.",
                            "把这台 Mac 从 @\(account.username) 移除，并清除它的密钥。账户、你的其他 Mac 和本机上的个人记录都会保留，之后随时可以重新登录。"))
                        RunPhaseLabel(phase: run.disconnectPhase)
                        Spacer(minLength: 0)
                    }
                }
                .alert(L10n.t("Disconnect this Mac?", "断开这台 Mac？"), isPresented: $confirmingDisconnect) {
                    Button(L10n.t("Disconnect", "断开")) { run.disconnectThisMac() }
                    Button(L10n.t("Cancel", "取消"), role: .cancel) {}
                } message: {
                    Text(L10n.t(
                        "This Mac stops uploading and forgets its key. If it is the ranked device, the account has none until you choose another on quota.run or sign in on another Mac.",
                        "这台 Mac 会停止上传并清除密钥。如果它是计分设备，在你到 quota.run 上另选一台或在另一台 Mac 上登录之前，账户将没有计分设备。"))
                }
            }
            SettingRow(L10n.t("Account", "账户")) {
                VStack(alignment: .leading, spacing: Design.space2) {
                    HStack(spacing: Design.space3) {
                        Button(run.deletePhase.isWorking ? L10n.t("Deleting…", "正在删除…") : L10n.t("Delete Account…", "删除账户…"), role: .destructive) {
                            confirmingDelete = true
                        }
                        .glassAction()
                        .disabled(busy)
                        HelpMark(L10n.t(
                            "Deletes your profile, projects, runs, Macs, sign-in methods and every reading from quota.run, and forgets this Mac's key. Your records on this Mac stay.",
                            "从 quota.run 删除你的主页、项目、成绩、设备、登录方式和所有读数，并清除这台 Mac 的密钥。本机上的个人记录会保留。"))
                        RunPhaseLabel(phase: run.deletePhase)
                        Spacer(minLength: 0)
                    }
                }
                .alert(L10n.t("Delete your Quota Run account?", "删除你的 Quota Run 账户？"), isPresented: $confirmingDelete) {
                    Button(L10n.t("Delete Account", "删除账户"), role: .destructive) { run.deleteAccount() }
                    Button(L10n.t("Cancel", "取消"), role: .cancel) {}
                } message: {
                    Text(L10n.t(
                        "Everything quota.run holds about @\(account.username) is deleted, on every Mac, and cannot be restored. Signing in again starts from nothing.",
                        "quota.run 上关于 @\(account.username) 的所有数据都会被删除，所有 Mac 都受影响，无法恢复。再次登录需要从头开始。"))
                }
            }
        }
    }
}

import AppKit
import SwiftUI
import QuotaCore

/// The update card's window: one for the app's lifetime, brought forward
/// whenever there is something to say about an update.
@MainActor
enum UpdateWindow {
    private static var window: NSWindow?

    static func show(store: UsageStore) {
        let window = self.window ?? make(store: store)
        self.window = window
        if !window.isVisible {
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
            if let visible = screen?.visibleFrame {
                window.setFrameOrigin(NSPoint(
                    x: visible.midX - window.frame.width / 2,
                    y: visible.midY - window.frame.height / 2 + visible.height * 0.12))
            }
        }
        window.makeKeyAndOrderFront(nil)
        // An accessory app is not activated as a side effect; without this the
        // card orders in behind whatever the owner is looking at.
        NSApp.activate(ignoringOtherApps: true)
    }

    static func close() {
        window?.orderOut(nil)
    }

    private static func make(store: UsageStore) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: UpdateCard.width, height: 420),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = L10n.t("Software Update", "软件更新")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: UpdateCard(store: store))
        host.sizingOptions = [.preferredContentSize]
        window.contentView = host
        return window
    }
}

/// What an update is, when it came out and what changed, with the one
/// button that installs it. The same card whether the update was found on
/// a schedule or asked for.
struct UpdateCard: View {
    @ObservedObject var store: UsageStore
    /// Off for off-screen renders, which draw a ScrollView's content as nothing.
    var scrollable = true
    @State private var showsAll = false

    static let width: CGFloat = 460
    /// How many changes show before "Show all".
    private static let preview = 6

    var body: some View {
        VStack(alignment: .leading, spacing: Design.space4) {
            header
            switch store.updateStage {
            case .checking:
                statusLine(spinner: true, L10n.t("Checking for updates…", "正在检查更新…"))
            case .idle:
                statusLine(symbol: "checkmark.circle.fill", tint: .green,
                           L10n.t("QuotaBar \(SettingsView.version) is the latest version.", "QuotaBar \(SettingsView.version) 已是最新版本。"))
                buttons(primary: nil)
            case let .available(release), let .downloading(release), let .readyToInstall(release):
                notes(for: release)
                progress
                buttons(primary: release)
            case let .failed(message):
                if let release = store.lastRelease { notes(for: release) }
                failure(message)
            }
        }
        .padding(.horizontal, Design.space6)
        .padding(.top, Design.space6 + Design.space4)
        .padding(.bottom, Design.space6)
        .frame(width: Self.width, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Header

    private var release: UpdateRelease? {
        switch store.updateStage {
        case let .available(release), let .downloading(release), let .readyToInstall(release): release
        case .failed: store.lastRelease
        default: nil
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Design.space4) {
            if let url = ProviderGlyph.markURL(named: "quotabar-icon"), let image = NSImage(contentsOfFile: url.path) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var title: String {
        guard let release else { return L10n.t("Software Update", "软件更新") }
        return L10n.t("QuotaBar \(release.version) is available", "QuotaBar \(release.version) 可以更新了")
    }

    private var subtitle: String {
        var parts = [L10n.t("You have \(SettingsView.version)", "当前版本 \(SettingsView.version)")]
        if let date = release?.publishedAt {
            let text = date.formatted(.dateTime.year().month().day().locale(Locale(identifier: L10n.isChinese ? "zh_CN" : "en_US")))
            parts.append(L10n.t("released \(text)", "发布于 \(text)"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Notes

    @ViewBuilder
    private func notes(for release: UpdateRelease) -> some View {
        let parsed = ReleaseNotes.parse(release.notes)
        VStack(alignment: .leading, spacing: Design.space2) {
            Text(L10n.t("What's new", "更新内容"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            if parsed.isEmpty {
                Text(L10n.t("See the changelog for this version.", "这个版本的更新内容见更新日志。"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else if scrollable, showsAll {
                ScrollView { noteList(parsed, limit: nil) }
                    .scrollIndicators(.never)
                    .frame(maxHeight: 300)
            } else {
                noteList(parsed, limit: showsAll ? nil : Self.preview)
            }
            HStack(spacing: Design.space3) {
                if parsed.itemCount > Self.preview {
                    Button(showsAll
                           ? L10n.t("Show fewer", "收起")
                           : L10n.t("Show all \(parsed.itemCount) changes", "显示全部 \(parsed.itemCount) 项"))
                    {
                        withAnimation(Motion.animation(Motion.spring)) { showsAll.toggle() }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                }
                Spacer(minLength: 0)
                Button {
                    NSWorkspace.shared.open(URL(string: L10n.isChinese ? "https://quota.bar/zh/changelog.html" : "https://quota.bar/changelog.html")!)
                } label: {
                    Label(L10n.t("Full changelog", "完整更新日志"), systemImage: "arrow.up.right")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(Design.space3 + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Design.radiusCard, style: .continuous).fill(Design.surface))
    }

    /// The changes, a badge per group, the first `limit` of them.
    private func noteList(_ notes: ReleaseNotes, limit: Int?) -> some View {
        var remaining = limit ?? Int.max
        var shown: [(ReleaseNotes.Group, [String])] = []
        for group in notes.groups where remaining > 0 {
            let items = Array(group.items.prefix(remaining))
            remaining -= items.count
            shown.append((group, items))
        }
        return VStack(alignment: .leading, spacing: Design.space3) {
            if let intro = notes.intro {
                Text(intro).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(shown, id: \.0.id) { group, items in
                VStack(alignment: .leading, spacing: 6) {
                    if !group.title.isEmpty { badge(group) }
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•").foregroundStyle(.tertiary)
                            Text(Self.plain(item))
                                .lineLimit(showsAll ? nil : 3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.system(size: 12))
                    }
                }
            }
        }
    }

    private func badge(_ group: ReleaseNotes.Group) -> some View {
        let tint: Color = switch group.kind {
        case .added: Color(hex: "3DD68C")
        case .style: Color(hex: "5AA9FF")
        case .fixed: Color(hex: "F5A524")
        case .removed: Color(hex: "FF6369")
        case .other: .secondary
        }
        return Text(group.title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.14)))
    }

    /// Backticks are for Markdown readers; the card shows the words.
    static func plain(_ item: String) -> String {
        item.replacingOccurrences(of: "`", with: "")
    }

    // MARK: Progress and buttons

    @ViewBuilder
    private var progress: some View {
        switch store.updateStage {
        case .downloading:
            statusLine(spinner: true, L10n.t("Downloading and verifying…", "正在下载并验证…"))
        case .readyToInstall:
            statusLine(symbol: "checkmark.seal.fill", tint: .green,
                       L10n.t("Downloaded and verified: signed by the developer and notarized by Apple.",
                              "已下载并验证：开发者签名和 Apple 公证都已通过。"))
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func buttons(primary release: UpdateRelease?) -> some View {
        if store.updateIsManagedByHomebrew, release != nil {
            VStack(alignment: .leading, spacing: Design.space2) {
                Text(L10n.t("Homebrew installed this copy, so Homebrew updates it:", "这份是 Homebrew 安装的，请用 Homebrew 更新："))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                HStack {
                    Text("brew upgrade --cask quotabar")
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button(L10n.t("Copy", "拷贝")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("brew upgrade --cask quotabar", forType: .string)
                    }
                    .glassAction(compact: true)
                }
            }
        }
        HStack(spacing: Design.space3) {
            Spacer(minLength: 0)
            Button(release == nil ? L10n.t("Close", "关闭") : L10n.t("Later", "稍后")) { UpdateWindow.close() }
                .glassAction()
                .keyboardShortcut(.cancelAction)
            if release != nil, !store.updateIsManagedByHomebrew {
                Button(installLabel) { store.installNow() }
                    .glassAction(prominent: true)
                    .keyboardShortcut(.defaultAction)
                    .disabled(installing)
            }
        }
    }

    private var installing: Bool {
        if case .downloading = store.updateStage { return store.isInstallRequested }
        return false
    }

    private var installLabel: String {
        installing ? L10n.t("Installing…", "正在安装…") : L10n.t("Install and Relaunch", "安装并重启")
    }

    /// Installing in place failed — no write access to /Applications, say.
    /// The disk image does not need it.
    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: Design.space3) {
            statusLine(symbol: "exclamationmark.triangle.fill", tint: Color(hex: "E5484D"), message)
            Text(L10n.t(
                "You can install it by hand: open the disk image and drag QuotaBar into Applications.",
                "可以手动安装：打开安装包，把 QuotaBar 拖进「应用程序」。"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Design.space3) {
                Spacer(minLength: 0)
                Button(L10n.t("Later", "稍后")) { UpdateWindow.close() }
                    .glassAction()
                    .keyboardShortcut(.cancelAction)
                Button(L10n.t("Try Again", "重试")) { store.installNow() }
                    .glassAction()
                if let release = store.lastRelease {
                    Button(L10n.t("Download Installer", "下载安装包")) { NSWorkspace.shared.open(release.manualDownloadURL) }
                        .glassAction(prominent: true)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func statusLine(spinner: Bool = false, symbol: String? = nil, tint: Color = .secondary, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.space2) {
            if spinner {
                ProgressView().controlSize(.small)
            } else if let symbol {
                Image(systemName: symbol).foregroundStyle(tint)
            }
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

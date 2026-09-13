import AppKit
import SwiftUI
import QuotaCore

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
                    Text(L10n.t("Every AI coding limit, at a glance.", "每个 AI 编码额度，抬眼就看见。"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            Text(Self.summary)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Where to find the project, its author and a person to write to.
            HStack(spacing: Design.space2) {
                AboutLink(title: L10n.t("Website", "网站"), detail: "quota.bar", mark: .symbol("globe"), url: "https://quota.bar")
                AboutLink(title: "GitHub", detail: "gentpan/QuotaBar", mark: .brand("github"), url: Self.repository)
                AboutLink(title: "X", detail: "@gentpan", mark: .brand("x"), url: "https://x.com/gentpan")
                AboutLink(title: L10n.t("Email", "邮件"), detail: "hello@quota.bar", mark: .symbol("envelope"), url: "mailto:hello@quota.bar")
                Spacer(minLength: 0)
            }
            .padding(.top, Design.space1)

            Divider()
                .padding(.top, Design.space1)

            // This copy: when it was made and what it runs on; and whose it is.
            HStack(alignment: .top, spacing: Design.space3) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: Design.space1) {
                        if let updated = Self.updated {
                            Text(L10n.t("Updated \(updated)", "更新于 \(updated)"))
                            Text("·")
                        }
                        TextLink(L10n.t("Changelog", "更新日志"), url: Self.repository + "/blob/main/CHANGELOG.md")
                    }
                    Text(L10n.t("Requires macOS 14 or later", "需要 macOS 14 或更高版本"))
                }
                Spacer(minLength: Design.space2)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(Self.copyright)
                    TextLink(L10n.t("MIT License", "MIT 开源许可"), url: Self.repository + "/blob/main/LICENSE")
                }
            }
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }

        SettingsCard(L10n.t("Your data", "你的数据")) {
            SettingFootnote(L10n.t(
                "Automatic providers reuse the session your CLI already created. Manually entered tokens are stored in the macOS keychain — never in a file.",
                "自动型服务商复用 CLI 已有的登录会话；手动填写的凭据保存在 macOS 钥匙串中，不写入任何文件。"))
            SettingFootnote(L10n.t(
                "Spend figures are estimates computed locally from the CLIs' session logs at published list prices. They are not a bill.",
                "费用为本地会话日志按官方标价估算的结果，仅供参考，不等于实际账单。"))
            VStack(alignment: .leading, spacing: 4) {
                SettingFootnote(L10n.t("QuotaBar connects only to:", "QuotaBar 只会连接这些地方："))
                ForEach(Self.connections, id: \.self) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("·")
                        SettingFootnote(line)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
                SettingFootnote(L10n.t(
                    "With a proxy set, all of it goes through the proxy. Unless you join Quota Run, usage is never sent to QuotaBar's own server.",
                    "设置了代理时，以上请求都经过代理。除非你加入 Quota Run，你的用量不会发送到 QuotaBar 自己的服务器。"))
                    .padding(.top, 2)
            }
        }

        SettingsCard(L10n.t("Acknowledgements", "开源致谢")) {
            SettingFootnote(L10n.t(
                "QuotaBar builds on these open-source projects and this typeface. Thank you.",
                "QuotaBar 参考或使用了以下开源项目和字体，在此致谢。"))
            VStack(spacing: Design.space1) {
                ForEach(Self.credits, id: \.name) { credit in
                    CreditRow(credit: credit)
                }
            }
        }

        // The providers' names and marks appear all over the app; say whose they are.
        SettingFootnote(L10n.t(
            "QuotaBar is an independent app. It is not affiliated with, endorsed or sponsored by Anthropic, OpenAI, Cursor, Google, xAI, GitHub, X or any other company it mentions. Their names and logos belong to their respective owners.",
            "QuotaBar 是独立的第三方应用，与 Anthropic、OpenAI、Cursor、Google、xAI、GitHub、X 以及文中提及的其他公司均无隶属、认可或赞助关系。相关名称和标志归各自所有者所有。"))
            .padding(.horizontal, Design.space1)
    }

    private static let repository = "https://github.com/gentpan/QuotaBar"

    /// What the app is, for someone who landed here without knowing.
    private static var summary: String {
        let count = ProviderID.allCases.count
        return L10n.t(
            "QuotaBar is a menu-bar app for macOS. It gathers the limits, reset times and estimated spend of \(count) AI coding services — Claude Code, Codex, Cursor and more — into the menu bar, the notch island, an edge dock and desktop cards, and tells you before one runs out. Usage is read and worked out on this Mac.",
            "QuotaBar 是一款 macOS 菜单栏应用。它把 Claude Code、Codex、Cursor 等 \(count) 个 AI 编码服务的额度、重置时间和花费估算，集中显示在菜单栏、刘海岛、屏幕边缘停靠条和桌面卡片上，快用完时提前提醒。用量在本机读取和计算。")
    }

    /// Every host the app reaches, and when.
    private static var connections: [String] {
        [
            L10n.t("the usage endpoints of the providers you turn on, with your own session or key;",
                   "你开启的服务商的用量接口，使用你自己的登录会话或密钥；"),
            L10n.t("their public status pages, such as status.claude.com;",
                   "各服务的公开状态页，例如 status.claude.com；"),
            L10n.t("open.er-api.com, once a day, for exchange rates;",
                   "open.er-api.com，每天一次，获取汇率；"),
            L10n.t("GitHub, to check for and download updates and to fetch model prices;",
                   "GitHub，检查和下载更新，以及获取模型价目表；"),
            L10n.t("quota.bar, when you send feedback, and for updates when GitHub can't be reached.",
                   "quota.bar，在你提交反馈时，以及连不上 GitHub 时检查和下载更新。"),
            L10n.t("Quota Run at quota.run, only after you join Quota Run: the readings, token counts and profile its consent screen lists.",
                   "quota.run 上的 Quota Run，仅在你加入 Quota Run 之后：上传加入时同意页面列出的读数、token 数量和个人资料。"),
        ]
    }

    fileprivate struct Credit {
        let name: String
        let author: String
        let license: String
        let use: String
        let url: String
    }

    /// The projects QuotaBar borrowed from or ships, with the licences that
    /// ask for the notice, and the wordmark's typeface.
    private static var credits: [Credit] {
        [
            Credit(name: "codex-island", author: "Eric Park", license: "MIT",
                   use: L10n.t("The notch island's look", "刘海岛的样式与动效"),
                   url: "https://github.com/ericjypark/codex-island"),
            Credit(name: "OpenUsage", author: "Robin Ebers", license: "MIT",
                   use: L10n.t("The menu panel, pace hints and the share card", "下拉面板、用量节奏提示与分享卡片"),
                   url: "https://github.com/robinebers/openusage"),
            Credit(name: "CodexBar", author: "Peter Steinberger", license: "MIT",
                   use: L10n.t("How providers report their usage", "各服务商用量的读取方式"),
                   url: "https://github.com/steipete/CodexBar"),
            Credit(name: "theSVG", author: "thesvg.org", license: "MIT",
                   use: L10n.t("The vector masters of the provider logos", "服务商标志的矢量原图"),
                   url: "https://github.com/GLINCKER/thesvg"),
            Credit(name: "Instrument Sans", author: "The Instrument Sans Project Authors", license: "SIL OFL 1.1",
                   use: L10n.t("The typeface of the QuotaBar wordmark", "QuotaBar 字标所用的字体"),
                   url: "https://github.com/Instrument/instrument-sans"),
        ]
    }

    /// The day this copy was assembled: the packaging stamp, or in the dev
    /// loop, which has no bundle, when the binary was last built.
    private static var updated: String? {
        let date: Date?
        if let stamp = SettingsView.buildDate {
            let parser = DateFormatter()
            parser.locale = Locale(identifier: "en_US_POSIX")
            parser.dateFormat = "yyyy-MM-dd HH:mm"
            date = parser.date(from: stamp)
        } else {
            date = Bundle.main.executableURL
                .flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date }
        }
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    /// The product's name, running to the current year. The company that
    /// holds the copyright is named in LICENSE only.
    private static var copyright: String {
        let first = 2026
        let now = Calendar.current.component(.year, from: Date())
        let years = now > first ? "\(first)–\(now)" : "\(first)"
        return "© \(years) QuotaBar"
    }
}

/// Underlined words that open a page.
private struct TextLink: View {
    let title: String
    let url: String

    init(_ title: String, url: String) {
        self.title = title
        self.url = url
    }

    var body: some View {
        Button {
            if let url = URL(string: url) { NSWorkspace.shared.open(url) }
        } label: {
            Text(title).underline()
        }
        .buttonStyle(.plain)
        .help(url)
    }
}

/// One acknowledged project: what it is, whose, under which licence, and
/// what QuotaBar took from it.
private struct CreditRow: View {
    let credit: AboutPane.Credit

    var body: some View {
        Button {
            if let url = URL(string: credit.url) { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: Design.space2) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: Design.space2) {
                        Text(credit.name)
                            .font(.system(size: 12, weight: .medium))
                        Text("\(credit.author) · \(credit.license)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Text(credit.use)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Design.space3)
            .padding(.vertical, Design.space2)
            .background(
                RoundedRectangle(cornerRadius: Design.radiusTile, style: .continuous)
                    .fill(Design.surfaceStrong))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(credit.url)
    }
}

/// One of the About card's links: a mark, a name and where it goes.
private struct AboutLink: View {
    enum Mark {
        case symbol(String)
        /// A monochrome file in `Resources/brands`, drawn in the text colour.
        case brand(String)
    }

    let title: String
    let detail: String
    let mark: Mark
    let url: String

    var body: some View {
        Button {
            if let url = URL(string: url) { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: Design.space2) {
                glyph
                    .frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Design.space3)
            .padding(.vertical, Design.space2)
            .background(
                RoundedRectangle(cornerRadius: Design.radiusTile, style: .continuous)
                    .fill(Design.surfaceStrong))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(url)
    }

    @ViewBuilder
    private var glyph: some View {
        switch mark {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 12, weight: .medium))
        case .brand(let name):
            if let image = BrandMark.image(named: name) {
                // The marks are drawn edge to edge; 14 of the 16 points sits
                // them at the weight of the globe beside them.
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 14, height: 14)
            } else {
                Image(systemName: "link")
                    .font(.system(size: 12, weight: .medium))
            }
        }
    }
}

/// Third-party marks that are not providers: the About page's GitHub and X.
/// Kept apart from `logos`, which holds the providers' own.
enum BrandMark {
    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor
    static func image(named name: String) -> NSImage? {
        if let cached = cache[name] { return cached }
        let file = "brands/\(name).png"
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent(file))
        }
        // The dev loop's bare binary: SwiftPM copies the folder into a bundle beside it.
        let resourceBundle = Bundle.main.bundleURL.appendingPathComponent("QuotaBar_QuotaBar.bundle")
        candidates.append(resourceBundle.appendingPathComponent(file))
        candidates.append(resourceBundle.appendingPathComponent("Contents/Resources/\(file)"))
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let image = NSImage(contentsOf: url)
        else { return nil }
        image.isTemplate = true
        cache[name] = image
        return image
    }
}

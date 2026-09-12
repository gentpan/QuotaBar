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

            // Where to find the project and its author. Plain links, in a
            // row, each opening in the browser.
            HStack(spacing: Design.space4) {
                AboutLink(title: L10n.t("Website", "网站"), detail: "quota.bar", mark: .symbol("globe"), url: "https://quota.bar")
                AboutLink(title: "GitHub", detail: "gentpan/quotabar", mark: .brand("github"), url: "https://github.com/gentpan/quotabar")
                AboutLink(title: "X", detail: "@gentpan", mark: .brand("x"), url: "https://x.com/gentpan")
                Spacer(minLength: 0)
            }
            .padding(.top, Design.space1)

            Divider()
                .padding(.top, Design.space1)

            // When this copy was made, and whose it is.
            HStack(alignment: .firstTextBaseline, spacing: Design.space2) {
                if let updated = Self.updated {
                    Text(L10n.t("Updated \(updated)", "更新于 \(updated)"))
                }
                Spacer(minLength: Design.space2)
                Text(Self.copyright)
                Button {
                    NSWorkspace.shared.open(URL(string: "https://github.com/gentpan/quotabar/blob/main/LICENSE")!)
                } label: {
                    Text(L10n.t("MIT License", "MIT 开源许可"))
                        .underline()
                }
                .buttonStyle(.plain)
                .help(L10n.t("Read the licence", "查看许可协议"))
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
        }
    }

    /// What the app is, for someone who landed here without knowing.
    private static var summary: String {
        let count = ProviderID.allCases.count
        return L10n.t(
            "QuotaBar is a menu-bar app for macOS. It gathers the limits, reset times and estimated spend of \(count) AI coding services — Claude Code, Codex, Cursor and more — into the menu bar, the notch island, an edge dock and desktop cards, and tells you before one runs out. Usage is read and worked out on this Mac.",
            "QuotaBar 是一款 macOS 菜单栏应用。它把 Claude Code、Codex、Cursor 等 \(count) 个 AI 编码服务的额度、重置时间和花费估算，集中显示在菜单栏、刘海岛、屏幕边缘停靠条和桌面卡片上，快用完时提前提醒。用量在本机读取和计算。")
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

    /// The LICENSE file's holder, running to the current year.
    private static var copyright: String {
        let first = 2026
        let now = Calendar.current.component(.year, from: Date())
        let years = now > first ? "\(first)–\(now)" : "\(first)"
        return L10n.t("© \(years) QuotaBar contributors", "© \(years) QuotaBar 贡献者")
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

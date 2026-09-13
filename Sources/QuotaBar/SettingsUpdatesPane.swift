import SwiftUI
import ServiceManagement
import QuotaCore

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

            SettingRow(
                L10n.t("Updates", "更新方式"),
                caption: L10n.t(
                    "A new version shows what changed first. Nothing is replaced until you click Install and Relaunch; the download is checked for the developer's signature and Apple's notarization.",
                    "发现新版本时先显示更新内容，点「安装并重启」才会替换并重启；下载的安装包会先验证开发者签名和 Apple 公证。"))
            {
                GlassSegmented(
                    options: UpdatePolicy.allCases.map { (value: $0, label: $0.displayName) },
                    selection: store.updatePolicy,
                    onSelect: { store.setUpdatePolicy($0) })
                .frame(maxWidth: 320)
                .disabled(store.updateIsManagedByHomebrew)
                .opacity(store.updateIsManagedByHomebrew ? 0.45 : 1)
            }

            SettingRow(L10n.t("Check", "检查")) {
                HStack(spacing: Design.space3) {
                    Button(L10n.t("Check now", "立即检查")) { store.checkForUpdate(manual: true) }
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
            Text(L10n.t("\(release.version) is available", "有新版本 \(release.version)"))
                .font(.system(size: 11, weight: .medium))
            Button(L10n.t("See What's New", "查看更新")) { UpdateWindow.show(store: store) }
                .glassAction()
        case let .downloading(release):
            Text(L10n.t("Downloading \(release.version)…", "正在下载 \(release.version)…"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        case let .readyToInstall(release):
            Text(L10n.t("\(release.version) downloaded and verified", "\(release.version) 已下载并验证"))
                .font(.system(size: 11, weight: .medium))
            Button(L10n.t("See What's New", "查看更新")) { UpdateWindow.show(store: store) }
                .glassAction()
        case let .failed(message):
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(Color(hex: "E5484D"))
                .lineLimit(2)
            Button(L10n.t("Details", "查看")) { UpdateWindow.show(store: store) }
                .glassAction()
        }
    }
}

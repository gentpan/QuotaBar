import SwiftUI
import ServiceManagement
import QuotaCore

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
            SettingToggle(
                L10n.t("Hide the account in copied images", "复制图片时遮挡账号"),
                caption: L10n.t(
                    "A card copied as an image shows the signed-in address as mosaic tiles. The panel itself still shows it.",
                    "右键「复制为图片」时，卡片上的登录账号显示为马赛克；下拉面板里仍正常显示。"),
                isOn: Binding(
                    get: { store.experience.shareMasksAccount },
                    set: { value in store.updateExperience { $0.shareMasksAccount = value } }))
        }

        SettingsCard(L10n.t("Advanced", "高级")) {
            ProxyRow(store: store)
            SettingToggle(
                L10n.t("Local API", "本地接口"),
                caption: L10n.t(
                    "Serves http://127.0.0.1:6736/v1/limits to other tools on this Mac. No credentials, no account names.\n\nFrom a terminal: /Applications/QuotaBar.app/Contents/MacOS/QuotaBar --json prints the same limits; add --force to skip the five-minute cache.",
                    "在 http://127.0.0.1:6736/v1/limits 提供额度数据给本机其他工具，不含凭据和账号。\n\n在终端运行 /Applications/QuotaBar.app/Contents/MacOS/QuotaBar --json 可输出同样的额度数据，加 --force 跳过 5 分钟缓存。"),
                isOn: Binding(
                    get: { store.experience.localAPI },
                    set: { value in store.updateExperience { $0.localAPI = value } }))
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
        SettingRow(L10n.t("Proxy", "代理"), caption: L10n.t("http://, https:// or socks5://; empty is direct.", "支持 http://、https:// 或 socks5://，留空为直连。")) {
            HStack(spacing: Design.space2) {
                GlassTextField(placeholder: "socks5://127.0.0.1:7890", text: $text, onSubmit: apply)
                    .frame(width: 260)
                Button(L10n.t("Apply", "应用"), action: apply)
                    .glassAction()
                // A mistake stays in sight; only the how-to waits behind the question mark.
                if invalid {
                    Text(L10n.t("Not a proxy address.", "不是有效的代理地址。"))
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
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

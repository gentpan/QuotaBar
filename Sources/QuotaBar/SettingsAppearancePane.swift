import SwiftUI
import ServiceManagement
import QuotaCore

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

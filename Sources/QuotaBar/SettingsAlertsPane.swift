import SwiftUI
import ServiceManagement
import QuotaCore

// MARK: - Alerts

struct AlertsPane: View {
    @ObservedObject var store: UsageStore

    private var enabled: Bool { store.alertSettings.enabled }

    var body: some View {
        SettingsCard(
            L10n.t("Thresholds", "阈值"),
            help: L10n.t(
                "Only thresholds at or above the warning level are offered — a critical below it can never be reached.",
                "紧急阈值只提供不低于警告阈值的档位，否则永远不会触发。"))
        {
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
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.45)
            }

            SettingRow(L10n.t("Critical at", "紧急阈值")) {
                GlassSegmented(
                    options: [80, 85, 90, 95, 99]
                        .filter { $0 >= store.alertSettings.warning }
                        .map { (value: $0, label: "\($0)%") },
                    selection: store.alertSettings.critical,
                    slots: 5,
                    onSelect: { value in
                        var settings = store.alertSettings
                        settings.critical = value
                        store.setAlertSettings(settings)
                    })
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.45)
            }
        }

        SettingsCard(
            L10n.t("Pace", "节奏提醒"),
            help: L10n.t(
                "Each fires once per crossing and once per reset period. What is already true when QuotaBar starts sets the baseline without a notification.",
                "每次越线只提醒一次，每个重置周期也只提醒一次。QuotaBar 启动时已经成立的情况只作为基线，不会提醒。"))
        {
            paceToggle(L10n.t("Almost out", "快用完了"), L10n.t("Under 10% left, balances included.", "剩余不到 10%，包括没有重置周期的余额。"), \.almostOut)
            paceToggle(L10n.t("Cutting it close", "余量很紧"), L10n.t("Projected to finish the window with little left.", "按当前速度，重置时所剩无几。"), \.cuttingClose)
            paceToggle(L10n.t("Will run out", "重置前会用完"), L10n.t("Projected to run out before the window resets.", "按当前速度，会在重置前用完。"), \.willRunOut)
        }

        SettingsCard(
            L10n.t("Resets", "额度重置"),
            help: L10n.t(
                "QuotaBar reads a provider again just after its window resets, so this happens on time rather than at the next refresh.",
                "QuotaBar 会在窗口重置后立刻重新读取该服务商，不用等下一次定时刷新。"))
        {
            SettingToggle(
                L10n.t("Mark the moment a window resets", "额度重置时播放提示"),
                caption: L10n.t(
                    "The island shows a banner, the menu-bar glyph refills, and the row says it just reset for ten minutes.",
                    "刘海岛弹出横幅，菜单栏图标回满，对应的额度行显示「刚刚重置」十分钟。"),
                isOn: Binding(
                    get: { store.experience.resetEffects },
                    set: { value in store.updateExperience { $0.resetEffects = value } }))
            SettingRow(L10n.t("Notify", "系统通知"), caption: L10n.t("After heavy use: only when the window had passed 90%.", "用满后：只在该窗口用过 90% 以上时通知。")) {
                GlassSegmented(
                    options: ResetNotifyMode.allCases.map { (value: $0, label: $0.displayName) },
                    selection: store.experience.resetNotify,
                    onSelect: { mode in store.updateExperience { $0.resetNotify = mode } })
            }
            SettingToggle(
                L10n.t("Early resets given", "赠送的限额重置"),
                caption: L10n.t(
                    "When Codex gives you an early reset, and a day before one runs out unspent.",
                    "Codex 送你限额重置时通知；某一次还没用、离到期不到一天时再提醒一次。"),
                isOn: Binding(
                    get: { store.experience.resetCreditNotify },
                    set: { value in store.updateExperience { $0.resetCreditNotify = value } }))
        }

        SettingsCard(
            L10n.t("Spend", "花费"),
            help: L10n.t(
                "A budget notifies once at 80% and once when it is passed, per day and per calendar month. Spend is estimated from this Mac's CLI logs at public prices — not a bill. Leave a budget empty to turn it off.",
                "预算在用到 80% 和超出时各通知一次，按天和按自然月分别计算。花费按本机 CLI 日志和公开价格估算，不是账单。留空即不设预算。"))
        {
            SettingRow(L10n.t("Daily budget", "每日预算")) {
                BudgetField(store: store, period: .day)
            }
            SettingRow(L10n.t("Monthly budget", "每月预算")) {
                BudgetField(store: store, period: .month)
            }
            SettingRow(
                L10n.t("Balance below", "余额低于"),
                caption: L10n.t(
                    "For prepaid accounts such as DeepSeek: notifies once when the balance drops below this, or can no longer pay for calls, and again after a top-up and the next dip.",
                    "适用于 DeepSeek 等充值型账户：余额低于这个金额、或已不足以调用 API 时通知一次；充值后再次跌破会重新提醒。"))
            {
                BalanceFloorField(store: store)
            }
            SettingToggle(
                L10n.t("Weekly digest", "每周用量周报"),
                caption: L10n.t("Monday morning: last week's spend, tokens and the busiest CLI.", "每周一上午推送上周的花费、token 和用得最多的 CLI。"),
                isOn: Binding(
                    get: { store.experience.weeklyDigest },
                    set: { value in store.updateExperience { $0.weeklyDigest = value } }))
        }
    }

    private func paceToggle(_ title: String, _ caption: String, _ key: WritableKeyPath<PaceAlertPrefs, Bool>) -> some View {
        SettingToggle(title, caption: caption, isOn: Binding(
            get: { store.experience.paceAlerts[keyPath: key] },
            set: { value in store.updateExperience { $0.paceAlerts[keyPath: key] = value } }))
    }
}

/// A budget amount in the currency it is kept in: typed, then saved on
/// Return or when the field loses focus. Empty turns the budget off.
private struct BudgetField: View {
    @ObservedObject var store: UsageStore
    let period: BudgetPeriod
    @State private var text = ""
    @FocusState private var focused: Bool

    private var budget: SpendBudget { store.experience.spendBudget }

    private var stored: Double? {
        period == .day ? budget.daily : budget.monthly
    }

    /// A budget keeps its own currency; a new one takes the display currency.
    private var currency: String {
        budget.isSet ? budget.currency : store.experience.currency
    }

    var body: some View {
        HStack(spacing: Design.space2) {
            Text(CurrencyRates.symbol(for: currency).trimmingCharacters(in: .whitespaces))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(minWidth: 18)
            GlassTextField(placeholder: L10n.t("No budget", "不设置"), text: $text, onSubmit: save)
                .focused($focused)
                .frame(maxWidth: 160)
            Text(CurrencyRates.displayName(for: currency))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .onAppear { text = stored.map(Self.format) ?? "" }
        .onChange(of: focused) { _, isFocused in if !isFocused { save() } }
        // Leaving the page with an unsaved figure still keeps it.
        .onDisappear(perform: save)
    }

    private static func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value)
    }

    private func save() {
        let cleaned = text.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        let value = Double(cleaned).flatMap { $0 > 0 ? $0 : nil }
        guard value != stored else { return }
        let code = currency
        store.updateExperience { prefs in
            if period == .day { prefs.spendBudget.daily = value } else { prefs.spendBudget.monthly = value }
            prefs.spendBudget.currency = code
        }
        text = value.map(Self.format) ?? ""
        store.evaluateSpendNotices()
    }
}

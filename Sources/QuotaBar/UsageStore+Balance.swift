import SwiftUI
@preconcurrency import UserNotifications
import QuotaCore

// MARK: - Low balance

extension UsageStore {
    /// Records a prepaid balance as it is read, and, where the credential can
    /// only ask for the balance, fills in usage from how it has fallen.
    func withBalanceEstimate(_ id: ProviderID, _ snapshot: UsageSnapshot) -> UsageSnapshot {
        guard var sheet = snapshot.balance else { return snapshot }
        BalanceHistoryStore.shared.record(id, balances: sheet.balances, at: snapshot.fetchedAt)
        guard !sheet.hasUsage else { return snapshot }
        BalanceEstimate.apply(to: &sheet, readings: BalanceHistoryStore.shared.readings(for: id))
        var estimated = snapshot
        estimated.balance = sheet
        return estimated
    }

    /// After each reading: a prepaid account that has dipped below the floor
    /// set in Settings → Alerts, or can no longer pay for a call. Once per dip;
    /// a top-up clears it.
    func evaluateBalanceNotices() {
        let floor = experience.balanceFloor
        let sheets = reported.compactMapValues(\.balance)
        let result = LowBalanceCheck.evaluate(
            sheets: sheets, floor: floor,
            rate: { CurrencyRates.shared.rate(for: $0) },
            notified: experience.balanceFloorNotified)
        if result.low != experience.balanceFloorNotified {
            updateExperience { $0.balanceFloorNotified = result.low }
        }
        guard notificationsReady else { return }
        for alert in result.alerts {
            post(lowBalance: alert, balance: sheets[alert.provider]?.balanceLine ?? "")
        }
    }

    private func post(lowBalance alert: LowBalanceAlert, balance: String) {
        let content = UNMutableNotificationContent()
        content.title = L10n.t("\(alert.provider.displayName) balance", "\(alert.provider.displayName) 余额")
        let floor = QuotaFormat.amount(alert.floor, code: alert.currency)
        content.body = alert.cannotPay
            ? L10n.t("\(balance) left, not enough to pay for API calls. Top up to keep them working.", "余额 \(balance)，已不足以调用 API，请及时充值。")
            : L10n.t("\(balance) left, below the \(floor) you set.", "余额 \(balance)，低于你设置的 \(floor)。")
        content.threadIdentifier = "bar.quota.balance"
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "bar.quota.balance.\(alert.provider.rawValue).\(Int(Date().timeIntervalSince1970))",
            content: content, trigger: nil))
    }
}

/// The floor in Settings: an amount in the currency it is kept in, saved on
/// Return or when the field loses focus. Empty turns the alert off.
struct BalanceFloorField: View {
    @ObservedObject var store: UsageStore
    @State private var text = ""
    @FocusState private var focused: Bool

    private var floor: BalanceFloor { store.experience.balanceFloor }

    /// A floor keeps its own currency; a new one takes the display currency.
    private var currency: String {
        floor.isSet ? floor.currency : store.experience.currency
    }

    var body: some View {
        HStack(spacing: Design.space2) {
            Text(CurrencyRates.symbol(for: currency).trimmingCharacters(in: .whitespaces))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(minWidth: 18)
            GlassTextField(placeholder: L10n.t("No alert", "不提醒"), text: $text, onSubmit: save)
                .focused($focused)
                .frame(maxWidth: 160)
            Text(CurrencyRates.displayName(for: currency))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .onAppear { text = floor.amount.map(Self.format) ?? "" }
        .onChange(of: focused) { _, isFocused in if !isFocused { save() } }
        .onDisappear(perform: save)
    }

    private static func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value)
    }

    private func save() {
        let cleaned = text.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        let value = Double(cleaned).flatMap { $0 > 0 ? $0 : nil }
        guard value != floor.amount else { return }
        let code = currency
        store.updateExperience { prefs in
            prefs.balanceFloor = BalanceFloor(amount: value, currency: code)
            // A new floor judges every account afresh.
            prefs.balanceFloorNotified = []
        }
        text = value.map(Self.format) ?? ""
        store.evaluateBalanceNotices()
    }
}

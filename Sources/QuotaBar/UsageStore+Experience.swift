import AppKit
@preconcurrency import UserNotifications
import QuotaCore

/// What 0.5 adds to the store: the new preferences, the archive, currency,
/// screen-share masking, pace notifications and first-launch detection.
extension UsageStore {
    func startExperience() {
        Task { await CurrencyRates.shared.refreshIfNeeded(); self.objectWillChange.send() }
        restartCaptureWatch()
        detectProvidersOnFirstLaunch()
    }

    /// Changes preferences in one write and applies what they affect.
    func updateExperience(_ body: (inout ExperiencePrefs) -> Void) {
        let before = experience
        var next = experience
        body(&next)
        guard next != before else { return }
        config.experience = next
        experience = next
        if next.proxy != before.proxy { HTTP.configureProxy(next.proxy) }
        if next.hideWhenSharing != before.hideWhenSharing { restartCaptureWatch() }
        if next.currency != before.currency {
            Task { await CurrencyRates.shared.refreshIfNeeded(); self.objectWillChange.send() }
        }
        if next.tokenCounting != before.tokenCounting { tick &+= 1 }
        if next.hiddenWindows != before.hiddenWindows { reapplyHiddenWindows() }
        experienceRevision &+= 1
    }

    // MARK: Order

    /// Moves a provider up or down the order every surface lists them in.
    func moveProvider(_ id: ProviderID, by offset: Int) {
        config.moveEnabled(id, by: offset)
        enabled = config.enabledProviders
        dockRevision &+= 1
        islandRevision &+= 1
        widgetRevision &+= 1
    }

    /// The order a surface's providers were dragged into, saved as the
    /// order every surface lists them in.
    func arrangeProviders(_ arranged: [ProviderID]) {
        config.arrangeEnabled(arranged)
        guard config.enabledProviders != enabled else { return }
        enabled = config.enabledProviders
        dockRevision &+= 1
        islandRevision &+= 1
        widgetRevision &+= 1
    }

        // MARK: Card expansion

    func isCardExpanded(_ id: ProviderID) -> Bool {
        experience.expandedCards.contains(id.rawValue)
    }

    func toggleCardExpanded(_ id: ProviderID) {
        updateExperience { prefs in
            if let index = prefs.expandedCards.firstIndex(of: id.rawValue) {
                prefs.expandedCards.remove(at: index)
            } else {
                prefs.expandedCards.append(id.rawValue)
            }
        }
    }

    // MARK: Figures

    /// A token count in the chosen counting.
    func tokens(all: Int, billable: Int) -> Int {
        experience.tokenCounting == .all ? all : billable
    }

    func resetText(_ date: Date) -> String {
        QuotaFormat.resetText(to: date, format: experience.resetTimeFormat, clock: experience.clockStyle)
    }

    func toggleResetFormat() {
        updateExperience { $0.resetTimeFormat = $0.resetTimeFormat == .countdown ? .exact : .countdown }
    }

    func toggleUsedLeft() {
        setMeterMode(meterMode == .used ? .remaining : .used)
    }

    // MARK: Archive

    /// Folds the latest logs into the archive, off the main actor.
    func updateArchive() async {
        await refreshCostNow()
    }

    // MARK: Screen sharing

    func restartCaptureWatch() {
        captureTask?.cancel()
        captureTask = nil
        guard experience.hideWhenSharing, ScreenCaptureProbe.isAvailable else {
            if isPrivacyMasked { isPrivacyMasked = false }
            return
        }
        captureTask = Task { [weak self] in
            while !Task.isCancelled {
                let captured = ScreenCaptureProbe.isScreenCaptured()
                if let self, self.isPrivacyMasked != captured { self.isPrivacyMasked = captured }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: First launch

    /// A fresh install turns on exactly the providers this Mac has a sign-in
    /// for, after openusage; an upgrade never changes what is on.
    func detectProvidersOnFirstLaunch() {
        guard !experience.providersDetected else { return }
        guard config.wasFreshInstall else {
            updateExperience { $0.providersDetected = true; $0.welcomeDismissed = true }
            return
        }
        Task { [config] in
            let found = await Task.detached(priority: .utility) {
                ProviderID.allCases.filter { ProviderRegistry.make($0).isConfigured(config: config) }
            }.value
            if !found.isEmpty {
                for id in ProviderID.allCases where self.isEnabled(id) != found.contains(id) {
                    self.setEnabled(id, found.contains(id))
                }
            }
            self.updateExperience { $0.providersDetected = true }
        }
    }

    // MARK: Pace notifications

    enum PaceAlertKind: String, CaseIterable {
        case almostOut, cuttingClose, willRunOut

        var title: String {
            switch self {
            case .almostOut: L10n.t("Almost out", "快用完了")
            case .cuttingClose: L10n.t("Cutting it close", "余量很紧")
            case .willRunOut: L10n.t("Will run out", "重置前会用完")
            }
        }
    }

    /// Fires on a new crossing only, and once per reset period; a condition
    /// already true at launch sets the baseline without notifying.
    func evaluatePaceAlerts() {
        let prefs = experience.paceAlerts
        var active: [String: Date] = [:]
        var fresh: [(PaceAlertKind, ProviderID, UsageWindow)] = []
        for id in enabled {
            guard let snapshot = states[id]?.snapshot else { continue }
            for window in snapshot.windows {
                guard let used = window.usedPercent else { continue }
                let verdict = window.pace()?.verdict
                var kinds: [PaceAlertKind] = []
                if prefs.almostOut, used >= 90 { kinds.append(.almostOut) }
                if prefs.cuttingClose, verdict == .close { kinds.append(.cuttingClose) }
                if prefs.willRunOut, verdict == .over { kinds.append(.willRunOut) }
                for kind in kinds {
                    let key = "\(id.rawValue)|\(window.id)|\(kind.rawValue)"
                    let period = window.resetsAt ?? .distantFuture
                    active[key] = period
                    if paceNotified[key] != period { fresh.append((kind, id, window)) }
                }
            }
        }
        let firstPass = !paceBaselineTaken
        paceNotified = active
        paceBaselineTaken = true
        guard !firstPass, notificationsReady, notificationsAvailable, !fresh.isEmpty else { return }
        for (kind, id, window) in fresh {
            let content = UNMutableNotificationContent()
            content.title = kind.title
            content.subtitle = "\(id.displayName) · \(window.scope ?? window.title)"
            content.body = paceBody(kind, window)
            content.threadIdentifier = "bar.quota.pace"
            UNUserNotificationCenter.current().add(UNNotificationRequest(
                identifier: "bar.quota.pace.\(id.rawValue).\(window.id).\(kind.rawValue)",
                content: content,
                trigger: nil))
        }
    }

    private func paceBody(_ kind: PaceAlertKind, _ window: UsageWindow) -> String {
        let used = window.usedPercent ?? 0
        switch kind {
        case .almostOut:
            return L10n.t("\(QuotaFormat.percent(100 - used)) left in this window.", "这个窗口只剩 \(QuotaFormat.percent(100 - used))。")
        case .cuttingClose:
            return L10n.t("Projected to finish with little left.", "按当前速度，重置时所剩无几。")
        case .willRunOut:
            if let seconds = window.pace()?.runOutSeconds {
                return QuotaFormat.runOutText(in: seconds, format: experience.resetTimeFormat, clock: experience.clockStyle)
            }
            return L10n.t("Projected to run out before it resets.", "按当前速度，会在重置前用完。")
        }
    }
}

// MARK: - Desktop cards

extension UsageStore {
    func updateDeskCard(_ id: String, _ body: (inout DeskCard) -> Void) {
        updateExperience { prefs in
            guard let index = prefs.deskCards.firstIndex(where: { $0.id == id }) else { return }
            body(&prefs.deskCards[index])
        }
        widgetRevision &+= 1
    }

    // MARK: A card's menu

    /// The windows a provider's card shows before it is expanded, the owner's
    /// choice applied.
    func upFrontWindows(for id: ProviderID) -> [UsageWindow] {
        states[id]?.snapshot?.upFrontWindows(
            for: id, picked: pickedHeadlineWindow(for: id), shown: experience.cardWindows[id.rawValue]) ?? []
    }

    /// Shows a window on the card or folds it away. The first change starts
    /// from what the card showed, so ticking one window keeps the others.
    func setCardWindow(_ windowID: String, upFront: Bool, for id: ProviderID) {
        var list = upFrontWindows(for: id).map(\.id)
        list.removeAll { $0 == windowID }
        if upFront { list.append(windowID) }
        guard !list.isEmpty else { return }
        updateExperience { $0.cardWindows[id.rawValue] = list }
    }

    func resetCardWindows(for id: ProviderID) {
        updateExperience { $0.cardWindows[id.rawValue] = nil }
    }

    /// Every window the provider reported, hidden ones included — what the
    /// card's menu lists.
    func reportedWindows(for id: ProviderID) -> [UsageWindow] {
        (reported[id] ?? states[id]?.snapshot)?.windows ?? []
    }

    func isWindowHidden(_ windowID: String, for id: ProviderID) -> Bool {
        experience.hiddenWindows[id.rawValue]?.contains(windowID) == true
    }

    /// Hides a window everywhere the provider shows, or brings it back. The
    /// last window still showing cannot be hidden.
    func setWindowHidden(_ windowID: String, _ hidden: Bool, for id: ProviderID) {
        let reportedIDs = reportedWindows(for: id).map(\.id)
        // Ids the provider no longer reports are dropped as the list changes.
        var list = (experience.hiddenWindows[id.rawValue] ?? []).filter { reportedIDs.contains($0) && $0 != windowID }
        if hidden { list.append(windowID) }
        guard list.count < reportedIDs.count else { return }
        updateExperience { $0.hiddenWindows[id.rawValue] = list.isEmpty ? nil : list }
    }

    func showAllWindows(for id: ProviderID) {
        updateExperience { $0.hiddenWindows[id.rawValue] = nil }
    }

    /// A big-figure card for one provider, shown on the desktop even if the
    /// provider had been hidden there.
    func addDeskCard(for id: ProviderID) {
        if experience.isHidden(id, on: .desktop) { setHidden(false, id, on: .desktop) }
        updateExperience { prefs in
            prefs.deskCards.append(DeskCard(style: .focus, provider: id, x: 0.8, y: 0.1))
        }
        if !widgetEnabled { setWidgetEnabled(true) }
        widgetRevision &+= 1
    }

    /// A new big-figure card, offset from the one it was asked from.
    func addDeskCard(style: DeskCardStyle = .focus, near card: DeskCard? = nil) {
        updateExperience { prefs in
            let x = card.map { $0.x > 0.5 ? $0.x - 0.22 : $0.x + 0.22 } ?? 0.8
            prefs.deskCards.append(DeskCard(style: style, size: .medium, x: x, y: card?.y ?? 0.1))
        }
        if !widgetEnabled { setWidgetEnabled(true) }
        widgetRevision &+= 1
    }

    func removeDeskCard(_ id: String) {
        updateExperience { $0.deskCards.removeAll { $0.id == id } }
        widgetRevision &+= 1
    }
}

// MARK: - Budgets and the weekly digest

extension UsageStore {
    /// After each re-read of the logs: a budget crossed since the last
    /// notification, and last week's digest once it is due.
    func evaluateSpendNotices() {
        guard logsReady else { return }
        let budget = experience.spendBudget
        let alerts = BudgetCheck.alerts(
            budget: budget, daily: cost.daily,
            rate: CurrencyRates.shared.rate(for: budget.currency),
            notified: experience.budgetNotified)
        if !alerts.isEmpty {
            updateExperience { $0.budgetNotified = Array(($0.budgetNotified + alerts.map(\.key)).suffix(24)) }
            if notificationsReady {
                for alert in alerts { post(budget: alert, currency: budget.currency) }
            }
        }

        if experience.weeklyDigest, let week = WeeklyDigest.dueWeek(lastSent: experience.weeklyDigestSent) {
            updateExperience { $0.weeklyDigestSent = week.key }
            let summary = archive.summary(from: week.start, to: week.end, counting: experience.tokenCounting)
            if summary.hasData, notificationsReady { post(digest: summary) }
        }
    }

    private func post(budget alert: BudgetAlert, currency: String) {
        let spent = QuotaFormat.amount(alert.spent, code: currency)
        let limit = QuotaFormat.amount(alert.limit, code: currency)
        let share = Int((alert.spent / alert.limit * 100).rounded())
        let content = UNMutableNotificationContent()
        content.title = L10n.t("Spend budget", "花费预算")
        switch (alert.period, alert.level) {
        case (.day, 100):
            content.body = L10n.t("Today's spend is \(spent), over the daily budget of \(limit).", "今天已花费 \(spent)，超出每日预算 \(limit)。")
        case (.day, _):
            content.body = L10n.t("Today's spend is \(spent), \(share)% of the daily budget of \(limit).", "今天已花费 \(spent)，达到每日预算 \(limit) 的 \(share)%。")
        case (.month, 100):
            content.body = L10n.t("This month's spend is \(spent), over the monthly budget of \(limit).", "本月已花费 \(spent)，超出每月预算 \(limit)。")
        case (.month, _):
            content.body = L10n.t("This month's spend is \(spent), \(share)% of the monthly budget of \(limit).", "本月已花费 \(spent)，达到每月预算 \(limit) 的 \(share)%。")
        }
        content.threadIdentifier = "bar.quota.budget"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "bar.quota.budget.\(alert.key)", content: content, trigger: nil))
    }

    private func post(digest summary: ArchiveSummary) {
        let content = UNMutableNotificationContent()
        content.title = L10n.t("Last week", "上周用量")
        var parts = [
            L10n.t("\(QuotaFormat.money(summary.usd)) spent", "花费 \(QuotaFormat.money(summary.usd))"),
            "\(QuotaFormat.compact(summary.tokens)) tokens",
        ]
        if let top = summary.sources.first, summary.usd > 0 {
            let share = Int((top.usd / summary.usd * 100).rounded())
            parts.append(L10n.t("\(top.source.displayName) \(share)%", "\(top.source.displayName) 占 \(share)%"))
        }
        content.body = parts.joined(separator: " · ")
        content.threadIdentifier = "bar.quota.digest"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "bar.quota.digest.\(summary.start.timeIntervalSince1970)", content: content, trigger: nil))
    }
}

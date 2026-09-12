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
        experienceRevision &+= 1
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
        guard !isUpdatingArchive else { return }
        isUpdatingArchive = true
        let updated = await Task.detached(priority: .utility) {
            UsageArchiveStore.shared.update()
        }.value
        archive = updated
        isUpdatingArchive = false
        ShareStudio.openOnceAfterUpdate(store: self)
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

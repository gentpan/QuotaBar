import Foundation
@preconcurrency import UserNotifications
import QuotaCore

// MARK: - The reset moment

extension UsageStore {
    /// How long a row keeps saying "just reset".
    static let justResetSpan: TimeInterval = 10 * 60

    /// Windows that reset between the previous reading and this one. Only
    /// fresh ones count: a cached reading replaced hours after its reset is
    /// not news.
    func noteResets(_ events: [ResetEvent], before: MeterReading) {
        let fresh = events.filter(\.isFresh)
        guard !fresh.isEmpty else { return }
        let until = Date().addingTimeInterval(Self.justResetSpan)
        for event in fresh { recentResets[event.id] = until }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.justResetSpan + 1))
            self?.recentResets = self?.recentResets.filter { $0.value > Date() } ?? [:]
        }
        notifyResets(fresh)
        guard experience.resetEffects, !isPrivacyMasked else { return }
        onResets?(fresh, before)
    }

    /// Whether a row should say it reset a moment ago.
    func justReset(_ id: ProviderID, window windowID: String) -> Bool {
        guard experience.resetEffects, let until = recentResets["\(id.rawValue)|\(windowID)"] else { return false }
        return until > Date()
    }

    private func notifyResets(_ events: [ResetEvent]) {
        let mode = experience.resetNotify
        let due = events.filter { mode.shouldNotify($0) }
        guard !due.isEmpty, notificationsReady, notificationsAvailable, !isPrivacyMasked else { return }
        for event in due {
            let content = UNMutableNotificationContent()
            content.title = L10n.t("Limit reset", "额度已重置")
            content.subtitle = "\(event.provider.displayName) · \(event.name)"
            let left = QuotaFormat.percent(100 - event.usedNow)
            content.body = event.followedHeavyUse
                ? L10n.t("\(left) left again — carry on.", "又有 \(left) 可用了，可以继续用。")
                : L10n.t("\(left) left.", "现在剩余 \(left)。")
            content.threadIdentifier = "bar.quota.reset"
            UNUserNotificationCenter.current().add(UNNotificationRequest(
                identifier: "bar.quota.reset.\(event.id).\(Int(event.resetAt.timeIntervalSince1970))",
                content: content,
                trigger: nil))
        }
    }

    /// Reads a provider again just after its next window resets, so the
    /// moment shows when it happens rather than at the next scheduled
    /// refresh. A provider that still reports the passed reset time gets up
    /// to three more reads a minute apart.
    func scheduleResetCheck() {
        resetCheckTask?.cancel()
        let now = Date()
        var due: [(id: ProviderID, at: Date)] = []
        for id in enabled {
            guard let snapshot = states[id]?.snapshot else { continue }
            if let next = ResetDetector.nextCheck(for: snapshot, after: now) {
                due.append((id, next))
            }
            if let overdue = snapshot.windows.compactMap(\.resetsAt).filter({ $0 <= now && now.timeIntervalSince($0) < 300 }).max() {
                let key = "\(id.rawValue)|\(Int(overdue.timeIntervalSince1970))"
                let tries = resetRetries[key, default: 0]
                if tries < 3 {
                    resetRetries[key] = tries + 1
                    due.append((id, now.addingTimeInterval(60)))
                }
            }
        }
        resetRetries = resetRetries.filter { key, _ in
            guard let stamp = key.split(separator: "|").last.flatMap({ Double($0) }) else { return false }
            return now.timeIntervalSince1970 - stamp < 900
        }
        guard let first = due.map(\.at).min() else { return }
        // Everything resetting within the same minute is read together.
        let ids = Set(due.filter { $0.at <= first.addingTimeInterval(60) }.map(\.id))
        resetCheckTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, first.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            for id in ids where self.isEnabled(id) { self.refresh(id) }
        }
    }

    /// `QuotaBar --simulate-reset <provider>`: plays the moment for that
    /// provider's fullest window a few seconds after launch, as if it had
    /// just reset, without touching the reading.
    func simulateReset(_ id: ProviderID) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self else { return }
            let window = self.headlineWindow(for: id) ?? self.states[id]?.snapshot?.windows.first
            let name = window.map { $0.scope ?? $0.title } ?? L10n.t("5-hour", "5 小时")
            var before = self.meterReading
            before.preferred = 96
            before.short = 96
            before.long = max(before.long ?? 0, 96)
            let event = ResetEvent(
                provider: id, windowID: window?.id ?? name, name: name,
                previousUsed: 96, usedNow: window?.usedPercent ?? 0,
                resetAt: Date(), noticedAt: Date())
            self.recentResets[event.id] = Date().addingTimeInterval(Self.justResetSpan)
            self.onResets?([event], before)
        }
    }
}

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

// MARK: - Resets the account is given

extension UsageStore {
    /// A reset given since the reading before, and a reset about to run out
    /// unspent — Codex hands them out every so often and each lasts about a
    /// month. A reminder is remembered even while notifications are off, so
    /// turning them on does not bring back a day of old ones.
    func noteResetCredits(_ id: ProviderID, previous: UsageSnapshot?, current: ResetCredits?) {
        let notices = ResetCreditCheck.notices(
            provider: id, previous: previous, current: current, notified: experience.resetCreditNotified)
        guard !notices.isEmpty else { return }
        let reminders = notices.compactMap { notice -> String? in
            if case .expiring = notice.kind { return notice.key }
            return nil
        }
        if !reminders.isEmpty {
            updateExperience { $0.resetCreditNotified = Array(($0.resetCreditNotified + reminders).suffix(24)) }
        }
        guard experience.resetCreditNotify, notificationsReady, notificationsAvailable, !isPrivacyMasked else { return }
        for notice in notices { post(notice, credits: current) }
    }

    private func post(_ notice: ResetCreditNotice, credits: ResetCredits?) {
        let content = UNMutableNotificationContent()
        content.subtitle = notice.provider.displayName
        switch notice.kind {
        case let .given(count):
            content.title = L10n.t("An early reset for you", "收到新的限额重置")
            var body = L10n.t(
                "\(notice.provider.displayName) gave you \(count) early reset\(count == 1 ? "" : "s"); \(notice.available) available now.",
                "\(notice.provider.displayName) 送你 \(count) 次限额重置，现在共 \(notice.available) 次可用。")
            if let soonest = credits?.upcomingExpirations().first {
                body += L10n.t(
                    " The soonest expires in \(QuotaFormat.countdown(to: soonest)).",
                    "最早的 \(QuotaFormat.countdown(to: soonest))后到期。")
            }
            content.body = body
        case let .expiring(credit):
            content.title = L10n.t("An early reset is about to expire", "限额重置快过期了")
            let name = credit.title ?? L10n.t("An early reset", "一次限额重置")
            content.body = L10n.t(
                "\(name) \(QuotaFormat.creditExpiry(credit, format: .countdown)), unspent. Use it with /usage in the Codex CLI.",
                "\(name) \(QuotaFormat.creditExpiry(credit, format: .countdown))，还没用。可以在 Codex CLI 里用 /usage 兑换。")
        }
        content.threadIdentifier = "bar.quota.reset-credit"
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "bar.quota.reset-credit.\(notice.key)", content: content, trigger: nil))
    }

    /// The row's help: each given reset with what it resets and when it runs
    /// out, in the reset rows' format.
    func resetCreditHelp(_ credits: ResetCredits) -> String {
        var lines = [L10n.t(
            "Early resets reset your usage limits before their time. \(credits.applicable ?? 0) apply to the window limiting you right now.",
            "限额重置可以提前重置用量限制。当前正在限流的窗口可用 \(credits.applicable ?? 0) 次。")]
        if let earned = credits.totalEarned {
            lines.append(L10n.t("\(earned) given in all.", "累计获得 \(earned) 次。"))
        }
        lines += QuotaFormat.creditLines(
            credits.credits, format: experience.resetTimeFormat, clock: experience.clockStyle)
        return lines.joined(separator: "\n")
    }
}

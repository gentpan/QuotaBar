import Foundation
import QuotaCore

/// The upload: after each refresh, what the ledger holds past the cursor and
/// the activity minutes since the last one, from the ranked Mac only.
///
/// There is no queue beyond the ledger itself. A reading taken offline is
/// simply past the cursor until a send goes through; one that ages past the
/// server's seven days is stepped over (`RunUploadPlan`), and so is one
/// without a provider account digest or with one the owner unbound. Failures back off
/// from a minute to an hour; a refused key stops the upload until `/me`
/// works again, because resending with a key the server rejects only adds
/// noise to its logs.
extension RunCenter {
    /// Why nothing is going up, when that is the case — for the status line.
    var uploadBlocker: String? {
        guard let account else { return nil }
        if upload.stopped {
            return upload.lastError ?? L10n.t("Stopped: the key was not accepted.", "已停止：密钥未被接受。")
        }
        if !account.ranked {
            return L10n.t(
                "Paused: another Mac is the ranked device, so this one's readings would not count.",
                "已暂停：计分设备是另一台 Mac，这台的读数不计入成绩。")
        }
        return nil
    }

    /// Sends one batch if this Mac should and it is time. `now: true` is the
    /// page's "Send now": it skips the minute between sends, not the backoff.
    func uploadIfDue(now manual: Bool = false) {
        guard !isInert, let account, account.ranked, !upload.stopped, !isUploading else { return }
        let now = Date()
        if let retryAt = upload.retryAt, retryAt > now {
            scheduleUpload(at: retryAt)
            return
        }
        if !manual, let last = upload.lastAttemptAt, now.timeIntervalSince(last) < RunUploadPlan.minimumInterval {
            scheduleUpload(at: last.addingTimeInterval(RunUploadPlan.minimumInterval))
            return
        }
        let batch = RunUploadPlan.batch(
            readings: ledger.readings(after: upload.sentSeq),
            activity: UsageArchiveStore.shared.recentActivity,
            state: upload,
            excluded: account.excludedDigests,
            now: now)
        guard !batch.isEmpty else {
            // Only readings that will never go were waiting — stale, or
            // with no account to rank under: step past them without a request.
            updateUpload {
                $0.sentSeq = batch.sentSeq
                $0.activityMinute = batch.activityMinute
            }
            updateQueued()
            return
        }
        guard let client = client() else {
            updateUpload {
                $0.lastError = L10n.t(
                    "This Mac's Quota Run key is not in the keychain.",
                    "钥匙串里找不到这台 Mac 的 Quota Run 密钥。")
            }
            return
        }
        setUploading(true)
        updateUpload { $0.lastAttemptAt = now }
        Task {
            do {
                let receipt = try await client.upload(RunUploadBody(snapshots: batch.snapshots, activity: batch.activity))
                updateUpload {
                    $0.sentSeq = batch.sentSeq
                    $0.activityMinute = batch.activityMinute
                    $0.lastUploadAt = Date()
                    $0.lastError = nil
                    $0.failures = 0
                    $0.retryAt = nil
                    $0.lastAccepted = receipt.accepted
                    $0.lastRejected = receipt.rejected.count
                }
                if batch.hasMore { scheduleUpload(at: Date().addingTimeInterval(RunUploadPlan.minimumInterval)) }
                afterUpload(digests: Set(batch.snapshots.compactMap(\.accountDigest)))
            } catch let error as QuotaRunError where error.isAuthFailure {
                updateUpload {
                    $0.stopped = true
                    $0.lastError = error.errorDescription
                }
            } catch {
                let failures = upload.failures + 1
                // A 429 says how long to wait; never come back sooner.
                let wait = max(RunUploadPlan.backoff(failures: failures), (error as? QuotaRunError)?.retryAfter ?? 0)
                let retryAt = Date().addingTimeInterval(wait)
                updateUpload {
                    $0.failures = failures
                    $0.retryAt = retryAt
                    $0.lastError = (error as? QuotaRunError)?.errorDescription ?? error.localizedDescription
                }
                scheduleUpload(at: retryAt)
            }
            setUploading(false)
            updateQueued()
        }
    }

    /// One pending wake-up at a time; a refresh in the meantime may send
    /// sooner, and the wake-up then finds nothing due.
    private func scheduleUpload(at date: Date) {
        retryTask?.cancel()
        let delay = max(1, date.timeIntervalSinceNow)
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.uploadIfDue()
        }
    }
}

// MARK: - Usage by project

/// Tokens per day by project, CLI, mode and model go up from every Mac on the
/// account (each Mac's logs are its own work). Recent days go again every ten
/// minutes; a change to which projects are public sends every day again, a
/// month at a time, so nothing taken private stays on quota.run.
extension RunCenter {
    func uploadUsageIfDue(now manual: Bool = false) {
        guard !isInert, account != nil, !upload.stopped, !isUploadingUsage else { return }
        let archiveStore = UsageArchiveStore.shared.projects
        guard archiveStore.current.fullScanDone else { return }
        let sharing = projectSharing
        var pending = upload.usagePending
        if upload.usageRevision != sharing.revision {
            // A new list: everything again, newest first.
            pending = RunUsagePlan.allDays(in: archiveStore.current)
            updateUpload {
                $0.usagePending = pending
                $0.usageRevision = sharing.revision
            }
        }
        if pending.isEmpty {
            let stale = upload.usageSentAt.map { Date().timeIntervalSince($0) >= RunUsagePlan.interval } ?? true
            guard stale || manual else { return }
            pending = RunUsagePlan.recent()
        }
        guard let client = client() else { return }
        let batch = Array(pending.prefix(RunUsagePlan.batchDays))
        isUploadingUsage = true
        Task {
            let body = await Task.detached(priority: .utility) {
                RunUsagePlan.body(days: batch, archive: archiveStore.current.canonical(), sharing: sharing)
            }.value
            do {
                let receipt = try await client.uploadUsage(body)
                noteProjectSlugs(receipt)
                updateUpload {
                    $0.usagePending.removeAll { batch.contains($0) }
                    $0.usageSentAt = Date()
                    $0.usageError = nil
                }
            } catch let error as QuotaRunError where error.isAuthFailure {
                updateUpload {
                    $0.stopped = true
                    $0.lastError = error.errorDescription
                }
            } catch {
                updateUpload { $0.usageError = (error as? QuotaRunError)?.errorDescription ?? error.localizedDescription }
            }
            isUploadingUsage = false
            if !upload.usagePending.isEmpty, upload.usageError == nil {
                usageTask?.cancel()
                usageTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(RunUploadPlan.minimumInterval))
                    guard !Task.isCancelled else { return }
                    self?.uploadUsageIfDue()
                }
            }
        }
    }
}

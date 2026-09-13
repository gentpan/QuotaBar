import AppKit
import SystemConfiguration
import QuotaCore

/// Where a Quota Run action has got to, for the line beside its button.
enum RunPhase: Equatable {
    case idle
    case working
    case done(String)
    case failed(String)

    var isWorking: Bool { self == .working }
}

/// Signing in through the browser, from the button to an approved Mac.
///
/// `denied`, `expired` and `failed` are where an attempt ends without an
/// account: the key is already gone again, the button is back, and the state
/// only carries the sentence to show beside it.
enum RunSignIn: Equatable {
    case idle
    /// Creating the key and asking quota.run for a code.
    case starting
    /// The code is shown and the browser is open; polling.
    case waiting(userCode: String, verifyURL: URL, expiresAt: Date)
    case approved
    case denied
    case expired
    case failed(String)

    /// An attempt is under way: no second one, and the form stays hidden.
    var isBusy: Bool {
        switch self {
        case .starting, .waiting, .approved: true
        case .idle, .denied, .expired, .failed: false
        }
    }

    /// What to say where the attempt ended.
    var message: String? {
        switch self {
        case .denied:
            L10n.t("The request was denied on quota.run. Nothing was connected.", "已在 quota.run 上拒绝了这次请求，没有连接任何账户。")
        case .expired:
            L10n.t("The code expired before it was approved. Sign in again for a new one.", "代码在批准之前已过期，请重新登录获取新代码。")
        case let .failed(text): text
        case .idle, .starting, .waiting, .approved: nil
        }
    }
}

/// Quota Run on this Mac: the personal records, which need nothing, and the
/// account, which this Mac has only after the owner signs in.
///
/// Its own object rather than more `@Published` on the store: the status item
/// redraws on every store change, and nothing here should make it.
@MainActor
final class RunCenter: ObservableObject {
    // MARK: Records

    @Published private(set) var inProgress: [RunRecord] = []
    @Published private(set) var bests: [PersonalBest] = []
    /// False until the ledger has been read once, so the page can tell
    /// "nothing yet" from "still reading".
    @Published private(set) var recordsReady = false

    // MARK: Membership

    @Published private(set) var account: RunAccountState?
    @Published private(set) var upload = RunUploadState()
    /// Readings the server would still take that have not gone yet.
    @Published private(set) var queued = 0
    @Published private(set) var isUploading = false
    /// Bumped when the server's copy of the profile or projects arrives, so
    /// the editors take it — including the addresses it expanded.
    @Published private(set) var editorRevision = 0

    @Published private(set) var signInPhase: RunSignIn = .idle
    @Published var profilePhase: RunPhase = .idle
    @Published var projectsPhase: RunPhase = .idle
    @Published var devicesPhase: RunPhase = .idle
    @Published var disconnectPhase: RunPhase = .idle
    @Published var deletePhase: RunPhase = .idle
    @Published var accountsPhase: RunPhase = .idle

    // MARK: Provider accounts

    /// The account each provider last reported, masked and digested — the
    /// email or id itself is not kept. In memory only: seeded from the
    /// snapshot cache, then from every successful refresh.
    @Published private(set) var localAccounts: [RunLocalAccount] = []
    private var lookingUp = false

    // MARK: Projects

    /// Which projects are public on quota.run, and their names there.
    @Published private(set) var projectSharing = ProjectSharingPrefs()
    var isUploadingUsage = false
    var usageTask: Task<Void, Never>?

    /// Previews and the off-screen renderer: sample data, no files, no key,
    /// no network.
    let isInert: Bool
    let ledger: RunLedgerStore
    private let stateURL: URL?
    private var signer: RunSigner?
    private var computedSeq = -1
    private var computing = false
    private var computeAgain = false
    var retryTask: Task<Void, Never>?
    private var dailyTask: Task<Void, Never>?
    private var signInTask: Task<Void, Never>?
    /// Bumped by every start and cancel, so an attempt that was called off
    /// cannot touch the keychain or the state a newer one owns.
    private var signInAttempt = 0

    init() {
        isInert = false
        ledger = RunLedgerStore.shared
        let url = AppSupport.directory.appendingPathComponent("quota-run.json")
        stateURL = url
        let file = RunStateFile.load(from: url)
        account = file.account
        upload = file.upload
        projectSharing = ProjectSharingStore.shared.current
        for id in ProviderID.allCases {
            if let snapshot = SnapshotCache.shared.snapshot(for: id) { noteAccount(id, snapshot) }
        }
    }

    private init(inert ledger: RunLedgerStore, account: RunAccountState?, upload: RunUploadState) {
        isInert = true
        self.ledger = ledger
        stateURL = nil
        self.account = account
        self.upload = upload
    }

    /// An empty centre for stores that must not touch anything.
    static func inert() -> RunCenter {
        let center = RunCenter(inert: RunLedgerStore(fileURL: nil), account: nil, upload: RunUploadState())
        center.recordsReady = true
        return center
    }

    /// After launch: the records, and — for a member — who this Mac is to the
    /// server, then once a day.
    func start() {
        guard !isInert else { return }
        Task {
            // Let the first refresh land before the ledger is walked.
            try? await Task.sleep(for: .seconds(3))
            refreshRecords()
        }
        dailyTask?.cancel()
        dailyTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let account = self.account,
                   account.meFetchedAt.map({ Date().timeIntervalSince($0) > 86_400 }) ?? true
                {
                    await self.refreshMe()
                }
                try? await Task.sleep(for: .seconds(3_600))
            }
        }
    }

    // MARK: Recording

    /// The store's success path. Cheap: the ledger appends in memory and
    /// writes a few seconds later.
    func record(_ id: ProviderID, _ snapshot: UsageSnapshot) {
        guard !isInert else { return }
        ledger.record(provider: id, snapshot: snapshot)
        noteAccount(id, snapshot)
    }

    /// A refresh that names no account leaves the last one standing, as the
    /// ledger does within a period.
    private func noteAccount(_ id: ProviderID, _ snapshot: UsageSnapshot) {
        guard let name = snapshot.account, let local = RunLocalAccount(provider: id, account: name) else { return }
        guard !localAccounts.contains(local) else { return }
        localAccounts = RunLocalAccount.merge(localAccounts, with: local)
    }

    /// After every refresh: new readings go into the records, and to the
    /// server when this Mac is the one that counts.
    func afterRefresh() {
        guard !isInert else { return }
        refreshRecords()
        uploadIfDue()
        uploadUsageIfDue()
    }

    /// Makes a project public on quota.run or takes it off; every day is sent
    /// again under the new list.
    func setProjectPublic(_ on: Bool, info: ProjectInfo) {
        guard !isInert else { return }
        projectSharing = ProjectSharingStore.shared.update { $0.setPublic(on, info: info) }
        uploadUsageIfDue(now: true)
    }

    func renameProject(_ info: ProjectInfo, to name: String) {
        guard !isInert else { return }
        projectSharing = ProjectSharingStore.shared.update { $0.rename(info.key, to: name, info: info) }
        uploadUsageIfDue(now: true)
    }

    func noteProjectSlugs(_ receipt: RunUsageReceipt) {
        let slugs = Dictionary(receipt.projects.map { ($0.id, $0.slug) }, uniquingKeysWith: { first, _ in first })
        guard slugs != projectSharing.slugs else { return }
        projectSharing = ProjectSharingStore.shared.update { $0.slugs = slugs }
    }

    /// Works the runs and bests out again, off the main actor, when anything
    /// was recorded since the last time.
    func refreshRecords(force: Bool = false) {
        guard !isInert else { return }
        guard !computing else { computeAgain = true; return }
        let seq = ledger.lastSeq
        guard force || seq != computedSeq else { return }
        computing = true
        let ledger = ledger
        Task {
            let result = await Task.detached(priority: .utility) { () -> ([RunRecord], [PersonalBest]) in
                let current = ledger.current
                let minutes = UsageArchiveStore.shared.recentActivity
                let archive = UsageArchiveStore.shared.current
                let runs = RunMath.runs(from: current.readings) { source, from, to in
                    RunCenter.hasActivity(source: source, from: from, to: to, minutes: minutes, archive: archive)
                }
                let bests = RunMath.bests(from: runs, keeping: current.bests)
                ledger.setBests(bests)
                return (RunMath.inProgress(runs, now: Int(Date().timeIntervalSince1970)), bests)
            }.value
            inProgress = result.0
            bests = result.1
            recordsReady = true
            computedSeq = seq
            computing = false
            updateQueued()
            if computeAgain {
                computeAgain = false
                refreshRecords()
            }
        }
    }

    /// Rule 5 for the local estimate: the minutes while they cover the run,
    /// and past the two days they hold, whether that CLI logged anything on
    /// the days the run spans — coarser, and only ever an estimate.
    nonisolated static func hasActivity(source: String, from: Int, to: Int, minutes: ActivityMinutes, archive: UsageArchive) -> Bool {
        if let scanned = minutes.scannedAt, Double(from) >= scanned.timeIntervalSince1970 - ActivityMinutes.horizon {
            return minutes.hasTokens(source: source, from: from, to: to)
        }
        guard let cost = CostSource.allCases.first(where: { $0.runSource == source }) else { return false }
        let calendar = Calendar.current
        var day = calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(from)))
        let last = Date(timeIntervalSince1970: TimeInterval(to))
        while day <= last {
            if archive.days[UsageArchive.dayKey(day)]?[cost.rawValue]?.values.contains(where: { $0.allTokens > 0 }) == true {
                return true
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return false
    }

    // MARK: State

    func persist() {
        guard let stateURL else { return }
        RunStateFile(account: account, upload: upload).save(to: stateURL)
    }

    func updateUpload(_ change: (inout RunUploadState) -> Void) {
        var next = upload
        change(&next)
        guard next != upload else { return }
        upload = next
        persist()
    }

    private func updateAccount(_ change: (inout RunAccountState) -> Void) {
        guard var next = account else { return }
        change(&next)
        guard next != account else { return }
        account = next
        persist()
    }

    func setUploading(_ on: Bool) {
        isUploading = on
    }

    func updateQueued() {
        guard let account else { queued = 0; return }
        let clock = Int(Date().timeIntervalSince1970)
        queued = ledger.readings(after: upload.sentSeq).reduce(0) {
            $0 + (RunUploadPlan.isUploadable($1, excluded: account.excludedDigests, clock: clock) ? 1 : 0)
        }
    }

    /// The client for this Mac's key, loading the key the first time.
    func client() -> QuotaRunClient? {
        guard !isInert, let account else { return nil }
        if signer == nil { signer = RunDeviceKey.load()?.signer }
        guard let signer else { return nil }
        return QuotaRunClient(signer: signer, deviceId: account.deviceId)
    }

    private var missingKey: String {
        L10n.t(
            "This Mac's Quota Run key is not in the keychain. Disconnect this Mac and sign in again.",
            "钥匙串里找不到这台 Mac 的 Quota Run 密钥。请断开这台 Mac，然后重新登录。")
    }

    static var deviceName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    private static func message(_ error: Error) -> String {
        (error as? QuotaRunError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: Signing in

    /// A new key, connected through the browser. The key is created only now
    /// — not when the page opens, not for someone who never signs in — and
    /// deleted again unless quota.run approves it.
    func signIn() {
        guard !isInert, account == nil, !signInPhase.isBusy else { return }
        signInAttempt &+= 1
        let attempt = signInAttempt
        signInPhase = .starting
        signInTask = Task { [weak self] in
            await self?.connect(attempt: attempt)
        }
    }

    func openBrowserAgain() {
        guard case let .waiting(_, url, _) = signInPhase else { return }
        NSWorkspace.shared.open(url)
    }

    /// Calls the attempt off here and now: the key goes at once, and the
    /// attempt, finding itself superseded, leaves everything alone.
    func cancelSignIn() {
        guard signInPhase.isBusy, account == nil else { return }
        signInAttempt &+= 1
        signInTask?.cancel()
        signInTask = nil
        RunDeviceKey.delete()
        signInPhase = .idle
    }

    private func connect(attempt: Int) async {
        // Cancelled before the task got to run: no key at all.
        guard attempt == signInAttempt else { return }
        let key: RunSigner
        do {
            key = try RunDeviceKey.create().signer
        } catch {
            signInPhase = .failed(L10n.t("The keychain refused to store this Mac's key.", "钥匙串拒绝保存这台 Mac 的密钥。"))
            return
        }
        let client = QuotaRunClient(signer: key)
        do {
            let start = try await client.connectStart(deviceName: Self.deviceName, appVersion: Self.appVersion)
            guard attempt == signInAttempt else { return }
            signInPhase = .waiting(userCode: start.userCode, verifyURL: start.verifyURL, expiresAt: start.expiresAt)
            NSWorkspace.shared.open(start.verifyURL)

            var wait = start.interval
            // One poll past the expiry, so an approval at the last second
            // still lands; after that quota.run would only say "expired".
            var last = false
            while true {
                try await Task.sleep(for: .seconds(wait))
                guard attempt == signInAttempt else { return }
                if Date() >= start.expiresAt {
                    if last { throw RunSignInEnd.expired }
                    last = true
                }
                let status: RunConnectStatus
                do {
                    status = try await client.connectPoll(requestId: start.requestId)
                    wait = start.interval
                } catch let error as QuotaRunError where error.code == "network" || error.status == 429 || error.status >= 500 {
                    // Offline for a moment, or asked to slow down: keep the
                    // code on screen and ask again later.
                    wait = max(start.interval, error.retryAfter ?? start.interval * 2)
                    continue
                }
                guard attempt == signInAttempt else {
                    if case let .approved(registration) = status { Self.disconnectAbandoned(key: key, deviceId: registration.deviceId) }
                    return
                }
                switch status {
                case .pending: continue
                case .denied: throw RunSignInEnd.denied
                case .expired: throw RunSignInEnd.expired
                case let .approved(registration):
                    signer = key
                    account = RunAccountState(
                        username: registration.user.username,
                        displayName: registration.user.displayName,
                        region: registration.user.region,
                        deviceId: registration.deviceId,
                        joinedAt: Date(),
                        ranked: registration.ranked)
                    // From the start of the ledger: the upload skips what is
                    // past the server's seven days on its own.
                    upload = RunUploadState()
                    persist()
                    signInPhase = .approved
                    signInTask = nil
                    await refreshMe()
                    uploadIfDue()
                    return
                }
            }
        } catch {
            guard attempt == signInAttempt else { return }
            RunDeviceKey.delete()
            signInTask = nil
            switch error {
            case RunSignInEnd.denied: signInPhase = .denied
            case RunSignInEnd.expired: signInPhase = .expired
            case is CancellationError: signInPhase = .idle
            default: signInPhase = .failed(Self.message(error))
            }
        }
    }

    private enum RunSignInEnd: Error {
        case denied
        case expired
    }

    /// Approved just after Cancel: the Mac was added all the same, so take it
    /// off the account again rather than leave a device nothing can sign for.
    private nonisolated static func disconnectAbandoned(key: RunSigner, deviceId: String) {
        Task.detached(priority: .utility) {
            try? await QuotaRunClient(signer: key, deviceId: deviceId).disconnectCurrentDevice()
        }
    }

    /// Who this Mac is to the server: the profile, the devices and which of
    /// them counts.
    func refreshMe() async {
        guard let client = client() else {
            if account != nil { updateUpload { $0.lastError = missingKey } }
            return
        }
        do {
            let me = try await client.me()
            updateAccount { state in
                state.me = me
                state.meFetchedAt = Date()
                state.username = me.user.username
                state.displayName = me.user.displayName
                state.region = me.user.region
                if let current = me.currentDevice { state.ranked = current.ranked }
            }
            editorRevision &+= 1
            // The key works again — a stop from an earlier refusal is over.
            if upload.stopped { updateUpload { $0.stopped = false; $0.lastError = nil; $0.failures = 0 } }
            updateQueued()
            await lookupAccounts(force: true)
        } catch let error as QuotaRunError where error.isAuthFailure {
            updateUpload { $0.stopped = true; $0.lastError = Self.message(error) }
        } catch let error as QuotaRunError where error.clockSkew != nil {
            updateUpload { $0.lastError = Self.message(error) }
        } catch {
            // A daily check that could not reach the server changes nothing.
        }
    }

    // MARK: Profile, projects, devices

    func saveProfile(displayName: String, bio: String, region: RunRegion, links: RunLinks) {
        guard let client = client() else { profilePhase = .failed(missingKey); return }
        profilePhase = .working
        let body = QuotaRunClient.ProfileBody(
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            bio: bio.trimmingCharacters(in: .whitespacesAndNewlines), region: region, links: links)
        Task {
            do {
                let user = try await client.updateProfile(body)
                updateAccount { state in
                    state.displayName = user.displayName
                    state.region = user.region
                    if state.me != nil { state.me?.user = user } else { state.me = RunMe(user: user) }
                }
                // The server expands a bare handle into an address; show
                // what it kept.
                editorRevision &+= 1
                profilePhase = .done(L10n.t("Saved", "已保存"))
            } catch {
                profilePhase = .failed(Self.message(error))
            }
        }
    }

    func saveProjects(_ projects: [RunProject]) {
        guard let client = client() else { projectsPhase = .failed(missingKey); return }
        if let problem = projects.lazy.compactMap(\.problem).first {
            projectsPhase = .failed(problem)
            return
        }
        projectsPhase = .working
        Task {
            do {
                let saved = try await client.updateProjects(Array(projects.prefix(RunProject.limit)))
                updateAccount { $0.me?.projects = saved }
                editorRevision &+= 1
                projectsPhase = .done(L10n.t("Saved", "已保存"))
            } catch {
                projectsPhase = .failed(Self.message(error))
            }
        }
    }

    func makeThisMacRanked() {
        guard let account, let client = client() else { devicesPhase = .failed(missingKey); return }
        devicesPhase = .working
        Task {
            do {
                let change = try await client.setRanked(deviceId: account.deviceId)
                applyDevices(change.devices)
                updateAccount { $0.me?.rankedChangeAvailableAt = change.rankedChangeAvailableAt }
                devicesPhase = .idle
                uploadIfDue()
            } catch let error as QuotaRunError where error.code == "cooldown" {
                if let availableAt = error.availableAt { updateAccount { $0.me?.rankedChangeAvailableAt = availableAt } }
                devicesPhase = .failed(Self.message(error))
            } catch {
                devicesPhase = .failed(Self.message(error))
            }
        }
    }

    func removeDevice(_ deviceId: String) {
        guard let client = client() else { devicesPhase = .failed(missingKey); return }
        devicesPhase = .working
        Task {
            do {
                applyDevices(try await client.deleteDevice(deviceId))
                devicesPhase = .idle
            } catch {
                devicesPhase = .failed(Self.message(error))
            }
        }
    }

    private func applyDevices(_ devices: [RunDevice]) {
        updateAccount { state in
            state.me?.devices = devices
            if let current = devices.first(where: { $0.current || $0.deviceId == state.deviceId }) {
                state.ranked = current.ranked
            }
        }
    }

    // MARK: Provider accounts

    /// Asks quota.run where this Mac's provider accounts stand. `force` skips
    /// the ten minutes between lookups, not the two between forced ones.
    func lookupAccounts(force: Bool = false) async {
        guard !isInert, !lookingUp, let account, !localAccounts.isEmpty else { return }
        if let checked = account.accountsCheckedAt {
            let since = Date().timeIntervalSince(checked)
            if since < (force ? 120 : 600) { return }
        }
        guard let client = client() else { return }
        lookingUp = true
        defer { lookingUp = false }
        let digests = localAccounts.map(\.digest)
        do {
            let answers = try await client.lookupAccounts(digests: digests)
            updateAccount { $0.apply(answers, at: Date()) }
        } catch {
            // Tried: wait the usual time before asking again. The key's own
            // troubles surface through the upload and `/me`.
            updateAccount { $0.accountsCheckedAt = Date() }
        }
    }

    /// After an upload went through: look again when it carried an account
    /// quota.run did not know yet, so a first binding shows at once.
    func afterUpload(digests: Set<String>) {
        guard let account else { return }
        let fresh = digests.contains { account.accountLookups[$0] == nil }
        Task { await lookupAccounts(force: fresh) }
    }

    /// Unbinds a provider account: quota.run deletes this user's readings and
    /// runs for it, and this Mac stops uploading it. One never uploaded only
    /// goes on the list.
    func unbindAccount(_ local: RunLocalAccount) {
        guard let account, !accountsPhase.isWorking else { return }
        let digest = local.digest
        // On the list first, so an upload in the meantime leaves it out.
        updateAccount { $0.excludedDigests.insert(digest) }
        updateQueued()
        guard let bound = account.accountLookups[digest] else {
            accountsPhase = .idle
            return
        }
        guard let client = client() else {
            updateAccount { $0.excludedDigests.remove(digest) }
            updateQueued()
            accountsPhase = .failed(missingKey)
            return
        }
        accountsPhase = .working
        Task {
            do {
                let remaining = try await client.unbindAccount(id: bound.id)
                updateAccount { state in
                    state.accountLookups.removeValue(forKey: digest)
                    state.me?.providerAccounts = remaining
                }
                accountsPhase = .idle
            } catch let error as QuotaRunError where error.code == "account_not_found" {
                // Already gone on quota.run. A bare 404 — a server without
                // the endpoint — is a failure like any other.
                updateAccount { state in
                    state.accountLookups.removeValue(forKey: digest)
                    state.me?.providerAccounts.removeAll { $0.id == bound.id }
                }
                accountsPhase = .idle
            } catch {
                updateAccount { $0.excludedDigests.remove(digest) }
                updateQueued()
                accountsPhase = .failed(Self.message(error))
            }
        }
    }

    /// Takes a provider account off the list: its next readings upload again.
    func bindAgain(_ local: RunLocalAccount) {
        guard account != nil else { return }
        updateAccount { $0.excludedDigests.remove(local.digest) }
        accountsPhase = .idle
        updateQueued()
        uploadIfDue()
    }

    // MARK: Leaving

    /// Takes this Mac off the account, then forgets the key and the account
    /// here. The account, its other Macs and the records on this Mac stay.
    func disconnectThisMac() {
        guard account != nil, !disconnectPhase.isWorking, !deletePhase.isWorking else { return }
        disconnectPhase = .working
        Task {
            guard let client = client() else {
                // No key, no way to ask the server for anything. Staying
                // signed in on this Mac would only strand the page, so forget
                // it here and say plainly what is left behind.
                forgetMembership()
                disconnectPhase = .idle
                signInPhase = .failed(L10n.t(
                    "Disconnected on this Mac. Its key was missing, so quota.run still lists this Mac; remove it from your account on quota.run.",
                    "已在本机断开。由于找不到本机密钥，quota.run 上仍列着这台 Mac；请在 quota.run 的账户页面里移除它。"))
                return
            }
            do {
                try await client.disconnectCurrentDevice()
            } catch let error as QuotaRunError where error.isAuthFailure || error.status == 404 {
                // Already removed on quota.run, or the account is gone:
                // nothing left to undo but what is here.
            } catch {
                disconnectPhase = .failed(Self.message(error))
                return
            }
            forgetMembership()
            disconnectPhase = .idle
        }
    }

    /// Deletes everything the server holds, then the key and the account on
    /// this Mac. The records stay: they were never the server's.
    func deleteAccount() {
        guard account != nil, !deletePhase.isWorking, !disconnectPhase.isWorking else { return }
        deletePhase = .working
        Task {
            let unreachable = L10n.t(
                "Signed out on this Mac, but quota.run could not be asked to delete your account from here: this Mac's key is missing or no longer accepted. Delete it from the account page on quota.run, or write to hello@quota.bar.",
                "已在本机退出，但无法从这里请求 quota.run 删除你的账户：本机密钥丢失或已不被接受。请在 quota.run 的账户页面删除，或发邮件到 hello@quota.bar。")
            guard let client = client() else {
                forgetMembership()
                deletePhase = .idle
                signInPhase = .failed(unreachable)
                return
            }
            do {
                try await client.deleteAccount()
            } catch let error as QuotaRunError where error.status == 404 {
                // Already gone on the server.
            } catch let error as QuotaRunError where error.isAuthFailure {
                // This key was removed from the account, which may well
                // still exist: say where to finish.
                forgetMembership()
                deletePhase = .idle
                signInPhase = .failed(unreachable)
                return
            } catch {
                deletePhase = .failed(Self.message(error))
                return
            }
            forgetMembership()
            deletePhase = .idle
        }
    }

    /// The account, the key and the upload cursor — not the records.
    func forgetMembership() {
        retryTask?.cancel()
        RunDeviceKey.delete()
        signer = nil
        account = nil
        signInPhase = .idle
        upload = RunUploadState()
        queued = 0
        persist()
    }
}

// MARK: - Previews

extension RunCenter {
    enum PreviewState {
        case records
        /// Not signed in, over an empty ledger.
        case signIn
        /// The code on screen, waiting for the browser.
        case signingIn
        case signedIn
    }

    /// Sample records and a sample account, built through the same
    /// arithmetic as the real thing so the page shows numbers that add up.
    static func preview(_ state: PreviewState, now: Date) -> RunCenter {
        let clock = Int(now.timeIntervalSince1970)
        let week = 604_800
        let fiveHours = 18_000
        func series(_ provider: String, plan: String, seconds: Int, reset: Int, points: [(Int, Double)], digest: String? = "sample") -> [RunReading] {
            points.map { offset, used in
                RunReading(
                    provider: provider, plan: plan, accountDigest: digest,
                    windowKey: RunMath.windowKey(seconds: seconds, scope: nil),
                    windowTitle: RunMath.canonicalTitle(seconds: seconds, scope: nil, fallback: ""),
                    windowSeconds: seconds, usedPercent: used, resetsAt: reset,
                    observedAt: reset - seconds + offset)
            }
        }
        let weekReset = RunMath.roundedReset(clock + 3 * 86_400)
        var readings: [RunReading] = []
        // Codex's current week, a little over a third in.
        readings += series("codex", plan: "Pro 20x", seconds: week, reset: weekReset, points: [(3_600, 4), (40_000, 18), (250_000, 36.5)])
        // Last week's Codex run: full in 2h 37m, read closely enough to verify.
        readings += series("codex", plan: "Pro 20x", seconds: week, reset: weekReset - week, points: [
            (600, 6), (1_800, 28), (2_460, 51), (3_600, 64), (4_800, 77), (6_000, 85), (7_200, 90.5), (8_400, 96), (9_420, 100), (10_000, 100),
        ])
        // Claude's 5 hours, running now and three runs back.
        let hourReset = RunMath.roundedReset(clock + 7_200)
        readings += series("claude", plan: "Max 20x", seconds: fiveHours, reset: hourReset, points: [(1_200, 22), (10_000, 64)])
        readings += series("claude", plan: "Max 20x", seconds: fiveHours, reset: hourReset - 3 * fiveHours, points: [
            (300, 12), (1_500, 44), (2_100, 58), (5_400, 90), (8_100, 99.6),
        ])
        // Cursor from before it reported an account: a record that would not rank.
        readings += series("cursor", plan: "Pro", seconds: 2_592_000, reset: RunMath.roundedReset(clock + 9 * 86_400), points: [(86_400, 12), (1_500_000, 61)], digest: nil)
        let runs = RunMath.runs(from: readings) { _, _, _ in true }

        let previewAccounts = Self.previewProviderAccounts(now: now)
        var account: RunAccountState?
        if state == .signedIn {
            let me = RunMe(
                user: RunUser(
                    username: "gentpan", displayName: "Peter Pan",
                    bio: L10n.t("Builds QuotaBar. Burns Codex weeks.", "在做 QuotaBar，常把 Codex 一周额度用光。"),
                    region: .china,
                    links: RunLinks(website: "https://quota.bar", github: "gentpan", x: "@gentpan"),
                    joinedAt: now.addingTimeInterval(-12 * 86_400)),
                devices: [
                    RunDevice(deviceId: "d1", name: "Peter's MacBook Pro", ranked: true, lastSeenAt: now.addingTimeInterval(-120), current: true, appVersion: "0.6.0"),
                    RunDevice(deviceId: "d2", name: "Mac Studio", ranked: false, lastSeenAt: now.addingTimeInterval(-3 * 86_400), appVersion: "0.5.3"),
                ],
                rankedChangeAvailableAt: now.addingTimeInterval(4 * 86_400),
                lastUploadAt: now.addingTimeInterval(-180),
                projects: [
                    RunProject(name: "QuotaBar", url: "https://quota.bar", description: L10n.t("Every AI coding limit, at a glance.", "每个 AI 编码额度，抬眼就看见。"), github: "https://github.com/gentpan/QuotaBar", builtWith: ["codex", "claude"]),
                    RunProject(name: "notch-kit", url: "https://notch.dev", description: L10n.t("A notch island for any app.", "给任何应用加一个刘海岛。"), builtWith: ["claude"]),
                ],
                identities: [
                    RunIdentity(id: "i1", provider: "github", email: "peter@quota.bar", name: "gentpan", linkedAt: now.addingTimeInterval(-12 * 86_400)),
                    RunIdentity(id: "i2", provider: "email", email: "peter@quota.bar", linkedAt: now.addingTimeInterval(-2 * 86_400)),
                ],
                providerAccounts: previewAccounts.lookups.values.sorted { $0.provider < $1.provider })
            account = RunAccountState(
                username: "gentpan", displayName: "Peter Pan", region: .china, deviceId: "d1",
                joinedAt: now.addingTimeInterval(-12 * 86_400), ranked: true, me: me, meFetchedAt: now)
        }
        var upload = RunUploadState()
        upload.lastUploadAt = now.addingTimeInterval(-180)
        let center = RunCenter(inert: RunLedgerStore(fileURL: nil), account: account, upload: upload)
        if state == .records || state == .signedIn {
            center.inProgress = RunMath.inProgress(runs, now: clock)
            center.bests = RunMath.bests(from: runs)
        }
        if state == .signingIn {
            center.signInPhase = .waiting(
                userCode: "KXPT-7M4Q",
                verifyURL: URL(string: "https://quota.run/connect?code=KXPT-7M4Q")!,
                expiresAt: now.addingTimeInterval(8 * 60 + 20))
        }
        if state == .signedIn {
            center.localAccounts = previewAccounts.local
            center.account?.accountLookups = previewAccounts.lookups
        }
        center.queued = state == .signedIn ? 3 : 0
        center.recordsReady = true
        return center
    }
}

extension RunCenter {
    /// Sample provider accounts: Codex verified by the sign-in email, Claude
    /// bound, Cursor owned by another Quota account.
    static func previewProviderAccounts(now: Date) -> (local: [RunLocalAccount], lookups: [String: RunProviderAccount]) {
        let samples: [(ProviderID, String, RunProviderAccount.Status, Bool, Int)] = [
            (.codex, "peter@quota.bar", .owned, true, 14),
            (.claude, "pan.builds@icloud.com", .owned, false, 6),
            (.cursor, "studio@gmail.com", .elsewhere, false, 0),
        ]
        var local: [RunLocalAccount] = []
        var lookups: [String: RunProviderAccount] = [:]
        for (index, sample) in samples.enumerated() {
            guard let account = RunLocalAccount(provider: sample.0, account: sample.1) else { continue }
            local.append(account)
            lookups[account.digest] = RunProviderAccount(
                id: String(account.digest.prefix(16)), provider: sample.0.rawValue,
                firstSeenAt: now.addingTimeInterval(-Double(12 - index * 3) * 86_400), lastSeenAt: now.addingTimeInterval(-300),
                status: sample.2, verifiedByEmail: sample.3, runs: sample.4)
        }
        return (local, lookups)
    }

    /// Every standing at once, for the renderer: the signed-in samples plus
    /// an account not uploaded yet and one unbound on this Mac.
    func previewEveryStanding() {
        guard isInert else { return }
        let extra = [
            RunLocalAccount(provider: .zai, account: "8f2c61d0-4b7a-4e0f-9d2e-31c5a7b9e204"),
            RunLocalAccount(provider: .kimi, account: "peter@quota.bar"),
        ].compactMap { $0 }
        for local in extra { localAccounts = RunLocalAccount.merge(localAccounts, with: local) }
        if let unbound = extra.last { account?.excludedDigests.insert(unbound.digest) }
    }
}

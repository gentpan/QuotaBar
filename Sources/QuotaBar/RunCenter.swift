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

/// Quota Run on this Mac: the personal records, which need nothing, and the
/// membership, which exists only after the owner joins.
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
    @Published private(set) var pairCode: RunPairCode?
    /// Bumped when the server's copy of the profile or projects arrives, so
    /// the editors take it — including the addresses it expanded.
    @Published private(set) var editorRevision = 0

    @Published var joinPhase: RunPhase = .idle
    @Published var profilePhase: RunPhase = .idle
    @Published var projectsPhase: RunPhase = .idle
    @Published var devicesPhase: RunPhase = .idle
    @Published var pairPhase: RunPhase = .idle
    @Published var leavePhase: RunPhase = .idle

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

    init() {
        isInert = false
        ledger = RunLedgerStore.shared
        let url = AppSupport.directory.appendingPathComponent("quota-run.json")
        stateURL = url
        let file = RunStateFile.load(from: url)
        account = file.account
        upload = file.upload
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
    }

    /// After every refresh: new readings go into the records, and to the
    /// server when this Mac is the one that counts.
    func afterRefresh() {
        guard !isInert else { return }
        refreshRecords()
        uploadIfDue()
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
        guard account != nil else { queued = 0; return }
        let oldest = Int(Date().timeIntervalSince1970) - RunUploadPlan.maximumAge
        queued = ledger.readings(after: upload.sentSeq).reduce(0) { $0 + ($1.observedAt >= oldest ? 1 : 0) }
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
            "This Mac's Quota Run key is not in the keychain. Leave and join again, or pair this Mac.",
            "钥匙串里找不到这台 Mac 的 Quota Run 密钥。请退出后重新加入，或用配对码添加这台 Mac。")
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

    // MARK: Joining

    func join(username: String, displayName: String, region: RunRegion) {
        register { client in
            try await client.register(
                username: username, displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                region: region, deviceName: Self.deviceName, appVersion: Self.appVersion)
        }
    }

    func join(pairCode: String) {
        register { client in
            try await client.register(pairCode: pairCode, deviceName: Self.deviceName, appVersion: Self.appVersion)
        }
    }

    /// A new key, registered. The key is created only now — not when the page
    /// opens, not for someone who never joins — and deleted again if the
    /// server says no.
    private func register(_ call: @escaping (QuotaRunClient) async throws -> RunRegistration) {
        guard !isInert, account == nil, !joinPhase.isWorking else { return }
        joinPhase = .working
        Task {
            do {
                let key: (signer: RunSigner, kind: RunDeviceKey.Kind)
                do {
                    key = try RunDeviceKey.create()
                } catch {
                    joinPhase = .failed(L10n.t("The keychain refused to store this Mac's key.", "钥匙串拒绝保存这台 Mac 的密钥。"))
                    return
                }
                let registration = try await call(QuotaRunClient(signer: key.signer))
                signer = key.signer
                account = RunAccountState(
                    username: registration.user.username,
                    displayName: registration.user.displayName,
                    region: registration.user.region,
                    deviceId: registration.deviceId,
                    joinedAt: Date(),
                    ranked: registration.ranked)
                // From the start of the ledger: the upload skips what is past
                // the server's seven days on its own.
                upload = RunUploadState()
                persist()
                joinPhase = .idle
                await refreshMe()
                uploadIfDue()
            } catch {
                RunDeviceKey.delete()
                joinPhase = .failed(Self.message(error))
            }
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

    func pair() {
        guard let client = client() else { pairPhase = .failed(missingKey); return }
        pairPhase = .working
        Task {
            do {
                pairCode = try await client.pair()
                pairPhase = .idle
            } catch {
                pairPhase = .failed(Self.message(error))
            }
        }
    }

    // MARK: Leaving

    /// Deletes everything the server holds, then the key and the membership
    /// on this Mac. The records stay: they were never the server's.
    func leave() {
        guard account != nil, !leavePhase.isWorking else { return }
        leavePhase = .working
        Task {
            if let client = client() {
                do {
                    try await client.deleteAccount()
                } catch let error as QuotaRunError where error.isAuthFailure || error.status == 404 {
                    // Already gone on the server, or this key was removed
                    // there: nothing left to delete but what is here.
                } catch {
                    leavePhase = .failed(Self.message(error))
                    return
                }
            } else {
                // No key, no way to ask the server for anything. Staying
                // joined on this Mac would only strand the page, so forget it
                // here and say plainly what is left behind.
                forgetMembership()
                leavePhase = .idle
                joinPhase = .failed(L10n.t(
                    "Left on this Mac. Its key was missing, so quota.run could not be asked to delete your data; leave from another joined Mac, or write to hello@quota.bar.",
                    "已在本机退出。由于找不到本机密钥，无法请求 quota.run 删除你的数据；请在另一台已加入的 Mac 上退出，或发邮件到 hello@quota.bar。"))
                return
            }
            forgetMembership()
            leavePhase = .idle
        }
    }

    /// The membership, the key and the upload cursor — not the records.
    func forgetMembership() {
        retryTask?.cancel()
        RunDeviceKey.delete()
        signer = nil
        account = nil
        pairCode = nil
        upload = RunUploadState()
        queued = 0
        persist()
    }
}

// MARK: - Previews

extension RunCenter {
    enum PreviewState {
        case records
        case join
        case joined
    }

    /// Sample records and a sample membership, built through the same
    /// arithmetic as the real thing so the page shows numbers that add up.
    static func preview(_ state: PreviewState, now: Date) -> RunCenter {
        let clock = Int(now.timeIntervalSince1970)
        let week = 604_800
        let fiveHours = 18_000
        func series(_ provider: String, plan: String, seconds: Int, reset: Int, points: [(Int, Double)]) -> [RunReading] {
            points.map { offset, used in
                RunReading(
                    provider: provider, plan: plan, accountDigest: "sample",
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
        readings += series("cursor", plan: "Pro", seconds: 2_592_000, reset: RunMath.roundedReset(clock + 9 * 86_400), points: [(86_400, 12), (1_500_000, 61)])
        let runs = RunMath.runs(from: readings) { _, _, _ in true }

        var account: RunAccountState?
        if state == .joined {
            let me = RunMe(
                user: RunUser(
                    username: "gentpan", displayName: "Peter Pan",
                    bio: L10n.t("Builds QuotaBar. Burns Codex weeks.", "在做 QuotaBar，常把 Codex 一周额度用光。"),
                    region: .china,
                    links: RunLinks(website: "https://quota.bar", github: "gentpan", x: "@gentpan"),
                    joinedAt: now.addingTimeInterval(-12 * 86_400)),
                devices: [
                    RunDevice(deviceId: "d1", name: "Peter's MacBook Pro", ranked: true, lastSeenAt: now.addingTimeInterval(-120), current: true),
                    RunDevice(deviceId: "d2", name: "Mac Studio", ranked: false, lastSeenAt: now.addingTimeInterval(-3 * 86_400)),
                ],
                rankedChangeAvailableAt: now.addingTimeInterval(4 * 86_400),
                lastUploadAt: now.addingTimeInterval(-180),
                projects: [
                    RunProject(name: "QuotaBar", url: "https://quota.bar", description: L10n.t("Every AI coding limit, at a glance.", "每个 AI 编码额度，抬眼就看见。"), github: "https://github.com/gentpan/QuotaBar", builtWith: ["codex", "claude"]),
                    RunProject(name: "notch-kit", url: "https://notch.dev", description: L10n.t("A notch island for any app.", "给任何应用加一个刘海岛。"), builtWith: ["claude"]),
                ])
            account = RunAccountState(
                username: "gentpan", displayName: "Peter Pan", region: .china, deviceId: "d1",
                joinedAt: now.addingTimeInterval(-12 * 86_400), ranked: true, me: me, meFetchedAt: now)
        }
        var upload = RunUploadState()
        upload.lastUploadAt = now.addingTimeInterval(-180)
        let center = RunCenter(inert: RunLedgerStore(fileURL: nil), account: account, upload: upload)
        if state != .join {
            center.inProgress = RunMath.inProgress(runs, now: clock)
            center.bests = RunMath.bests(from: runs)
        }
        center.queued = state == .joined ? 3 : 0
        center.recordsReady = true
        return center
    }
}

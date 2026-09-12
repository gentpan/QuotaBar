import SwiftUI
import AppKit
import Network
@preconcurrency import UserNotifications
import QuotaCore

enum ProviderPhase: Sendable {
    case loading
    case loaded(UsageSnapshot)
    /// Last refresh failed but we still have earlier numbers. Shown with a
    /// staleness badge — silently serving old data is how a user ends up
    /// trusting a figure from an expired session.
    case stale(UsageSnapshot, error: String)
    case failed(String)

    var snapshot: UsageSnapshot? {
        switch self {
        case let .loaded(snapshot), let .stale(snapshot, _): snapshot
        case .loading, .failed: nil
        }
    }

    var errorMessage: String? {
        switch self {
        case let .stale(_, error), let .failed(error): error
        case .loading, .loaded: nil
        }
    }
}

@MainActor
final class UsageStore: ObservableObject {
    @Published var enabled: [ProviderID]
    @Published var states: [ProviderID: ProviderPhase] = [:]
    /// Claude Code's session lives in another app's keychain item, and macOS
    /// wants the user's say-so before this app may read it. True while that
    /// is outstanding; the panel and the settings row show the button then.
    @Published private(set) var claudeNeedsAuthorization = false
    /// Persisted, because it decides what the menu-bar glyph reports — a
    /// choice that silently reverted on every launch would make the icon
    /// change meaning without the user doing anything.
    @Published var selected: ProviderID? {
        didSet {
            guard selected != oldValue else { return }
            config.selected = selected
        }
    }
    @Published var refreshMinutes: Int
    @Published var menuBarStyle: MenuBarStyle
    @Published var menuBarIconMode: MenuBarIconMode
    @Published var meterMode: MeterMode
    @Published var meterStyle: MeterStyle
    @Published var presentation: Presentation
    @Published var alertSettings: AlertSettings
    @Published var language: L10n.Language
    @Published var cost: CostSummary = .empty
    /// True while the first scan is running. On a heavy log tree that is tens
    /// of seconds, and a blank space for that long reads as "this feature is
    /// broken" rather than "still working".
    @Published var isComputingCost = false
    /// The year-to-date ledger behind the usage pane. Built only once that
    /// pane has been opened — it walks the same log tree as `cost`, and
    /// someone who never looks at the grid should not pay for it — and then
    /// kept fresh on the refresh cycle alongside the spend summary.
    @Published var ledger: UsageLedger = .empty
    @Published var isComputingLedger = false
    private var ledgerWanted = false
    /// How far an update has got. Checked once per launch — often enough for
    /// a tool people leave running, and it avoids hammering an unauthenticated
    /// API that rate-limits by IP.
    @Published var updateStage: Updater.Stage = .idle
    /// When the feed was last asked, so the pane can say "checked 3m ago"
    /// instead of leaving an idle stage to mean anything.
    @Published var lastUpdateCheck: Date?
    private var updatePollTask: Task<Void, Never>?
    /// Staged bundle, verified and waiting for the user to restart.
    private var stagedUpdate: URL?
    /// Recorded headline readings per provider, mirrored here so the detail
    /// sparkline redraws when a refresh lands.
    @Published var history: [ProviderID: [Double]] = [:]
    /// Bumped whenever a refresh completes so relative timestamps re-render.
    @Published var tick: Int = 0
    /// Providers whose credentials currently resolve. Computed off the main
    /// actor because `isConfigured` may reach into the keychain, which blocks
    /// while macOS asks the user to authorize access — never do that in a
    /// SwiftUI `body`.
    @Published var configured: Set<ProviderID> = []

    /// Latest reading of each provider's public status page, for the ones
    /// that have one. Absent until the page has answered once; a failed poll
    /// keeps the previous reading rather than blanking the chip.
    @Published var serviceStatus: [ProviderID: ServiceStatus] = [:]
    private var statusTask: Task<Void, Never>?
    /// 90-day histories by component id, fetched when a 服务状态 row opens.
    @Published var uptime: [String: [UptimeDay]] = [:]
    private var uptimeLoading: Set<String> = []

    private var lastAlertLevel: AlertLevel = .none
    private var notificationsReady = false

    private let config = ConfigStore.shared
    private var autoRefreshTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var netMonitor: NWPathMonitor?
    private var lastNetStatus: NWPath.Status?
    private var systemObservers: [NSObjectProtocol] = []

    /// Builds a store wired to the real config but with no timers, network
    /// calls or notification prompts — used by `--snapshot` and previews.
    static func preview(
        enabled: [ProviderID],
        states: [ProviderID: ProviderPhase],
        cost: CostSummary = .empty,
        ledger: UsageLedger = .empty,
        history: [ProviderID: [Double]] = [:]) -> UsageStore
    {
        let store = UsageStore(inert: true)
        store.enabled = enabled
        store.states = states
        store.cost = cost
        store.ledger = ledger
        store.history = history
        store.selected = nil
        return store
    }

    private init(inert: Bool) {
        self.enabled = []
        self.refreshMinutes = ConfigStore.shared.refreshMinutes
        self.menuBarStyle = ConfigStore.shared.menuBarStyle
        self.menuBarIconMode = ConfigStore.shared.menuBarIconMode
        self.meterMode = ConfigStore.shared.meterMode
        self.meterStyle = ConfigStore.shared.meterStyle
        self.presentation = .menuBar
        self.alertSettings = ConfigStore.shared.alerts
        self.language = ConfigStore.shared.language
        self.selected = nil
    }

    init() {
        self.enabled = ConfigStore.shared.enabledProviders
        self.refreshMinutes = ConfigStore.shared.refreshMinutes
        self.menuBarStyle = ConfigStore.shared.menuBarStyle
        self.menuBarIconMode = ConfigStore.shared.menuBarIconMode
        self.meterMode = ConfigStore.shared.meterMode
        self.meterStyle = ConfigStore.shared.meterStyle
        self.presentation = ConfigStore.shared.presentation
        self.alertSettings = ConfigStore.shared.alerts
        self.language = ConfigStore.shared.language
        // Restore the focused provider, dropping it if it is no longer enabled.
        let saved = ConfigStore.shared.selected
        self.selected = saved.flatMap {
            ConfigStore.shared.enabledProviders.contains($0) ? $0 : nil
        }
        for id in enabled {
            history[id] = UsageHistoryStore.shared.readings(for: id).map(\.percent)
        }
        prepareNotifications()
        refreshConfigured()
        checkForUpdate()
        startUpdatePolling()
        startAutoRefresh()
        startClock()
        startSystemObservers()
        startStatusPolling()
        refreshAll()
    }

    deinit {
        autoRefreshTask?.cancel()
        clockTask?.cancel()
        statusTask?.cancel()
        updatePollTask?.cancel()
        netMonitor?.cancel()
    }

    // MARK: Derived state

    /// Per-horizon readings driving the menu-bar glyph.
    ///
    /// Follows whatever the panel is focused on: a selected provider reports
    /// only its own windows, while the overview aggregates across everything
    /// enabled. Switching provider in the panel therefore switches what the
    /// menu bar is telling you about.
    var meterReading: MeterReading {
        let sources: [ProviderID] = selected.map { [$0] } ?? enabled
        var reading = MeterReading.across(sources.compactMap { states[$0]?.snapshot })
        // One provider on show: its single figure is the window the owner
        // picked for it, here as everywhere else.
        if let selected, config.headlineWindow(for: selected) != nil {
            reading.preferred = headlinePercent(for: selected)
        }
        return reading
    }

    // MARK: Headline window

    /// The window a provider's single figure follows — on the ring, the
    /// island, the widget, the menu — the owner's pick from its card, else
    /// the fullest window.
    func headlinePercent(for id: ProviderID) -> Double? {
        states[id]?.snapshot?.headlinePercent(preferring: config.headlineWindow(for: id))
    }

    func headlineWindow(for id: ProviderID) -> UsageWindow? {
        states[id]?.snapshot?.headlineWindow(preferring: config.headlineWindow(for: id))
    }

    /// The pick itself, whether or not the provider currently reports it.
    func pickedHeadlineWindow(for id: ProviderID) -> String? {
        config.headlineWindow(for: id)
    }

    func setHeadlineWindow(_ windowID: String?, for id: ProviderID) {
        config.setHeadlineWindow(windowID, for: id)
        objectWillChange.send()
    }

    /// Highest reading overall, for anything that shows a single figure.
    var headlinePercent: Double? {
        meterReading.headline
    }

    var alertLevel: AlertLevel {
        alertSettings.level(for: headlinePercent ?? 0)
    }

    /// The enabled provider currently closest to its limit (for alert captions).
    var hottestProvider: (id: ProviderID, percent: Double)? {
        var best: (ProviderID, Double)?
        for id in enabled {
            guard let percent = states[id]?.snapshot?.headlinePercent else { continue }
            if best == nil || percent > best!.1 { best = (id, percent) }
        }
        return best
    }

    /// Providers whose most recent refresh failed — surfaced in the footer so a
    /// dead credential is visible without opening every tile.
    var failingProviders: [ProviderID] {
        enabled.filter { states[$0]?.errorMessage != nil }
    }

    func isLoading(_ id: ProviderID) -> Bool {
        if case .loading = states[id] { return true }
        return false
    }

    func isEnabled(_ id: ProviderID) -> Bool {
        enabled.contains(id)
    }

    // MARK: Refreshing

    func refreshAll() {
        refresh(enabled.filter { !isLoading($0) })
        refreshCost()
    }

    func refresh(_ id: ProviderID) {
        guard !isLoading(id) else { return }
        refresh([id])
    }

    /// Fetches every provider concurrently and applies each result the moment
    /// it lands. Waiting for the whole group would let one provider sitting on
    /// its 20s timeout hold the entire panel hostage.
    private func refresh(_ ids: [ProviderID]) {
        guard !ids.isEmpty else { return }
        for id in ids { markLoading(id) }
        Task { [config] in
            await withTaskGroup(of: (ProviderID, Result<UsageSnapshot, Error>).self) { group in
                for id in ids {
                    group.addTask {
                        do {
                            return (id, .success(try await ProviderRegistry.make(id).fetch(config: config)))
                        } catch {
                            return (id, .failure(error))
                        }
                    }
                }
                for await (id, result) in group {
                    self.apply(id, result)
                }
            }
            self.finishRefresh()
            self.refreshConfigured()
        }
    }

    // MARK: Status pages

    /// Every five minutes, independent of the quota cadence: an incident
    /// lasts hours, and the pages rate-limit by IP.
    private func startStatusPolling() {
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshServiceStatus()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    /// Every provider with a feed, enabled or not: the settings list shows
    /// them all, and eight small requests every five minutes is nothing.
    func refreshServiceStatus(_ only: [ProviderID]? = nil) async {
        let ids = (only ?? StatusPages.supported).filter { StatusPages.page(for: $0) != nil }
        guard !ids.isEmpty else { return }
        let fresh = await withTaskGroup(of: (ProviderID, ServiceStatus?).self) { group in
            for id in ids {
                group.addTask { (id, await StatusPages.fetch(id)) }
            }
            var out: [ProviderID: ServiceStatus] = [:]
            for await (id, status) in group {
                if let status { out[id] = status }
            }
            return out
        }
        for (id, status) in fresh {
            serviceStatus[id] = status
            // The one strip a closed row shows; the rest load when it opens.
            if let primary = StatusPages.primaryComponent(for: id, in: status.components) {
                loadUptime(for: id, only: primary.id)
            }
        }
    }

    /// Fetches the 90-day history of every component the page lists — or of
    /// the one named — once.
    func loadUptime(for id: ProviderID, only component: String? = nil) {
        guard let status = serviceStatus[id] else { return }
        let wanted = status.components.filter { component == nil || $0.id == component }
        for component in wanted where uptime[component.id] == nil && !uptimeLoading.contains(component.id) {
            uptimeLoading.insert(component.id)
            Task {
                let days = await StatusPages.uptime(for: id, component: component.id)
                if let days { self.uptime[component.id] = days }
                self.uptimeLoading.remove(component.id)
            }
        }
    }

    private func markLoading(_ id: ProviderID) {
        // Keep showing the previous numbers while a refresh is in flight; only
        // a provider with nothing yet gets the spinner.
        if states[id]?.snapshot == nil {
            states[id] = .loading
        }
    }

    private func apply(_ id: ProviderID, _ result: Result<UsageSnapshot, Error>) {
        switch result {
        case let .success(snapshot):
            states[id] = .loaded(snapshot)
            if let percent = snapshot.headlinePercent {
                UsageHistoryStore.shared.record(id, percent: percent)
                history[id] = UsageHistoryStore.shared.readings(for: id).map(\.percent)
            }
        case let .failure(error):
            let message = error.localizedDescription
            if let previous = states[id]?.snapshot {
                states[id] = .stale(previous, error: message)
            } else {
                states[id] = .failed(message)
            }
        }
    }

    private func finishRefresh() {
        tick &+= 1
        evaluateAlerts()
    }

    /// Re-evaluates which providers have usable credentials.
    func refreshConfigured() {
        Task { [config] in
            let (ready, claudeWaiting) = await Task.detached(priority: .utility) {
                let ready = Set(ProviderID.allCases.filter {
                    ProviderRegistry.make($0).isConfigured(config: config)
                })
                // Non-interactive, like every keychain read off a timer.
                let waiting = LocalCredentials.claudeCredentialState() == .needsAuthorization
                return (ready, waiting)
            }.value
            self.configured = ready
            self.claudeNeedsAuthorization = claudeWaiting
        }
    }

    func isConfigured(_ id: ProviderID) -> Bool {
        configured.contains(id)
    }

    /// Raises the keychain dialog for Claude Code's item — the only place the
    /// app ever does — then reads again. Wire it to a button, nothing else.
    func authorizeClaude() {
        Task {
            _ = await LocalCredentials.authorizeClaudeAccessAsync()
            refresh(.claude)
            refreshConfigured()
        }
    }

    /// Only meaningful for a packaged build: the dev binary has no version.
    private var currentVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    func checkForUpdate() {
        guard config.checksForUpdates, let current = currentVersion else { return }
        // A download or a staged bundle is further along than a check.
        switch updateStage {
        case .downloading, .readyToInstall: return
        default: break
        }
        let feed = config.updateFeed
        updateStage = .checking
        Task {
            let release = await Updater.check(feed: feed, currentVersion: current)
            self.lastUpdateCheck = Date()
            if let release {
                self.updateStage = .available(release)
                // Automatic: straight on to the download, and from there to
                // the install. Not for a Homebrew-owned copy, which brew
                // upgrades and would otherwise fight over.
                if self.updatePolicy == .automatic, !self.updateIsManagedByHomebrew {
                    self.downloadUpdate()
                }
            } else {
                self.updateStage = .idle
            }
        }
    }

    /// Every six hours after launch: the app is left running for weeks, and
    /// a check only at launch would find a release a month late.
    private func startUpdatePolling() {
        updatePollTask?.cancel()
        updatePollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(6 * 3600))
                guard !Task.isCancelled else { return }
                self?.checkForUpdate()
            }
        }
    }

    /// Downloads and verifies, leaving the bundle staged for a restart —
    /// or, under the automatic policy, installing and relaunching at once.
    func downloadUpdate() {
        guard case let .available(release) = updateStage else { return }
        updateStage = .downloading(release)
        Task {
            do {
                let staged = try await Updater.stage(release)
                self.stagedUpdate = staged
                self.updateStage = .readyToInstall(release)
                if self.updatePolicy == .automatic, !self.updateIsManagedByHomebrew {
                    self.installUpdate()
                }
            } catch {
                self.updateStage = .failed(error.localizedDescription)
            }
        }
    }

    /// One click from "available" to relaunched, for the manual policy.
    func installNow() {
        switch updateStage {
        case .available: downloadUpdate()
        case .readyToInstall: installUpdate()
        default: break
        }
    }

    /// Swaps the bundle and relaunches. Only reachable once a download has
    /// passed verification.
    func installUpdate() {
        guard let staged = stagedUpdate else { return }
        do {
            try Updater.install(staged: staged)
            NSApplication.shared.terminate(nil)
        } catch {
            updateStage = .failed(error.localizedDescription)
        }
    }

    /// Homebrew owns the install; replacing the bundle behind its back would
    /// desync its metadata.
    var updateIsManagedByHomebrew: Bool { Updater.isManagedByHomebrew() }

    var checksForUpdates: Bool { config.checksForUpdates }
    var updatePolicy: UpdatePolicy { config.updatePolicy }

    func setUpdatePolicy(_ policy: UpdatePolicy) {
        config.updatePolicy = policy
        objectWillChange.send()
        // Switching to automatic with a release already found: finish it.
        if policy == .automatic { installNow() }
    }

    var dockEdge: DockEdge { config.dockEdge }
    var widgetEnabled: Bool { config.widgetEnabled }
    var widgetDensity: WidgetDensity { config.widgetDensity }
    var widgetAlwaysOnTop: Bool { config.widgetAlwaysOnTop }

    /// Bumped so the coordinators re-evaluate; the widget is independent of
    /// `presentation`, so it needs its own signal.
    @Published var widgetRevision = 0

    func setWidgetEnabled(_ on: Bool) {
        config.widgetEnabled = on
        widgetRevision &+= 1
    }

    func setWidgetDensity(_ density: WidgetDensity) {
        config.widgetDensity = density
        widgetRevision &+= 1
    }

    func setWidgetAlwaysOnTop(_ on: Bool) {
        config.widgetAlwaysOnTop = on
        widgetRevision &+= 1
    }
    var dockAlwaysVisible: Bool { config.dockAlwaysVisible }

    var islandSlots: Int { config.islandSlots }

    // MARK: Pins

    /// A surface pinned to one provider shows that provider alone. The
    /// menu-bar glyph's equivalent is `selected`.
    var islandPin: ProviderID? { config.islandPin }
    var dockPin: ProviderID? { config.dockPin }
    var widgetPin: ProviderID? { config.widgetPin }
    var widgetScope: WidgetScope { config.widgetScope }

    var islandProviders: [ProviderID] { config.providers(pinnedTo: islandPin) }
    var dockProviders: [ProviderID] { config.providers(pinnedTo: dockPin) }
    var widgetProviders: [ProviderID] {
        widgetScope == .pinned ? config.providers(pinnedTo: widgetPin) : enabled
    }

    func setIslandPin(_ id: ProviderID?) {
        config.islandPin = id
        objectWillChange.send()
        islandRevision &+= 1
    }

    func setDockPin(_ id: ProviderID?) {
        config.dockPin = id
        objectWillChange.send()
        dockRevision &+= 1
    }

    /// Pinning to the card also puts the card into its pinned scope; there
    /// is no point pinning one and showing all.
    func setWidgetPin(_ id: ProviderID?) {
        config.widgetPin = id
        config.widgetScope = id == nil ? .all : .pinned
        objectWillChange.send()
        widgetRevision &+= 1
    }

    func setWidgetScope(_ scope: WidgetScope) {
        config.widgetScope = scope
        objectWillChange.send()
        widgetRevision &+= 1
    }

    // MARK: Screen

    var displayScreen: String? { config.displayScreen }

    /// Every surface moves: the dock and island re-place themselves, the
    /// widget goes to the same screen at its stored fractions.
    func setDisplayScreen(_ id: String?) {
        config.displayScreen = id
        objectWillChange.send()
        dockRevision &+= 1
        islandRevision &+= 1
        widgetRevision &+= 1
    }

    /// Bumped when the island's strip changes width, so the coordinator
    /// re-places the panel.
    @Published var islandRevision = 0

    func setIslandSlots(_ slots: Int) {
        config.islandSlots = slots
        objectWillChange.send()
        islandRevision &+= 1
    }

    /// Bumped when a setting moves the dock, so the coordinator re-places
    /// the window. Re-assigning `presentation` to itself did nothing: SwiftUI's
    /// `onChange` compares values, and an unchanged value is not a change —
    /// the strip mirrored its corners for the new edge and stayed put.
    @Published var dockRevision = 0

    func setDockEdge(_ edge: DockEdge) {
        config.dockEdge = edge
        objectWillChange.send()
        dockRevision &+= 1
    }

    func setDockAlwaysVisible(_ on: Bool) {
        config.dockAlwaysVisible = on
        objectWillChange.send()
        dockRevision &+= 1
    }
    var updateFeedValue: String { config.updateFeed.configValue }

    func setChecksForUpdates(_ on: Bool) {
        config.checksForUpdates = on
        objectWillChange.send()
        if on { checkForUpdate() } else { updateStage = .idle }
    }

    /// Returns false when the value is not a usable source, so the field can
    /// say so instead of silently storing something that never resolves.
    @discardableResult
    func setUpdateFeed(_ value: String) -> Bool {
        guard let feed = UpdateFeed(configValue: value) else { return false }
        config.updateFeed = feed
        objectWillChange.send()
        checkForUpdate()
        return true
    }

    func refreshCost() {
        guard !isComputingCost else { return }
        isComputingCost = true
        Task {
            // Refresh published model prices before scanning, so a newly
            // released model is not priced through a stale prefix guess.
            await PricingCatalog.shared.refreshIfNeeded()
            // Pure local file IO over thousands of session logs; keep it off
            // the main actor.
            let summary = await Task.detached(priority: .utility) {
                CostEstimator.summary()
            }.value
            self.cost = summary
            self.isComputingCost = false
            if self.ledgerWanted { await self.buildLedger() }
        }
    }

    /// The usage pane asks for the ledger the first time it appears.
    func wantLedger() {
        guard !ledgerWanted else { return }
        ledgerWanted = true
        // A spend scan already running will build the ledger when it
        // finishes; otherwise start now.
        guard !isComputingCost else { return }
        Task { await buildLedger() }
    }

    private func buildLedger() async {
        guard !isComputingLedger else { return }
        isComputingLedger = true
        let built = await Task.detached(priority: .utility) {
            CostEstimator.ledger()
        }.value
        ledger = built
        isComputingLedger = false
    }

    // MARK: Alerts

    func setAlertSettings(_ settings: AlertSettings) {
        let normalized = settings.normalized()
        alertSettings = normalized
        config.alerts = normalized
        evaluateAlerts()
    }

    /// Notifications need a bundle identifier; the dev loop runs the bare
    /// binary, where `UNUserNotificationCenter.current()` would trap.
    private var notificationsAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    private func prepareNotifications() {
        guard notificationsAvailable else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
                Task { @MainActor in self?.notificationsReady = granted }
            }
    }

    /// Edge-triggered: notify only when the level rises, so a steady 90%
    /// doesn't spam the Notification Center.
    private func evaluateAlerts() {
        let level = alertLevel
        defer { lastAlertLevel = level }
        guard notificationsReady, level > lastAlertLevel, let hot = hottestProvider else { return }
        let content = UNMutableNotificationContent()
        content.title = "QuotaBar"
        let percent = Int(hot.percent.rounded())
        content.body = L10n.t(
            "\(hot.id.displayName) used \(percent)% — \(level.displayName.lowercased())",
            "\(hot.id.displayName) 已用 \(percent)% —— \(level.displayName)")
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "bar.quota.alert.\(level.rawValue)",
            content: content,
            trigger: nil))
    }

    // MARK: Settings

    func setEnabled(_ id: ProviderID, _ on: Bool) {
        config.setEnabled(id, on)
        if on {
            if !enabled.contains(id) { enabled.append(id) }
            history[id] = UsageHistoryStore.shared.readings(for: id).map(\.percent)
            if selected == nil && enabled.count == 1 { selected = id }
            refresh(id)
            Task { await refreshServiceStatus([id]) }
        } else {
            enabled.removeAll { $0 == id }
            states[id] = nil
            if selected == id { selected = enabled.first }
        }
    }

    func setRefreshMinutes(_ minutes: Int) {
        refreshMinutes = minutes
        config.refreshMinutes = minutes
        startAutoRefresh()
    }

    func setMenuBarStyle(_ style: MenuBarStyle) {
        menuBarStyle = style
        config.menuBarStyle = style
    }

    func setMenuBarIconMode(_ mode: MenuBarIconMode) {
        menuBarIconMode = mode
        config.menuBarIconMode = mode
    }

    func setMeterMode(_ mode: MeterMode) {
        meterMode = mode
        config.meterMode = mode
    }

    func setMeterStyle(_ style: MeterStyle) {
        meterStyle = style
        config.meterStyle = style
    }

    func setPresentation(_ presentation: Presentation) {
        self.presentation = presentation
        config.presentation = presentation
    }

    func setLanguage(_ language: L10n.Language) {
        self.language = language
        config.language = language
        // Every visible string is resolved through L10n at render time, so a
        // redraw is all that is needed.
        objectWillChange.send()
        tick &+= 1
    }

    func setCredential(_ value: String, for id: ProviderID) {
        config.setCredential(value, for: id)
        // A replaced credential may be a different account entirely, which
        // would splice two unrelated series into one trend line.
        UsageHistoryStore.shared.clear(id)
        history[id] = []
        refreshConfigured()
        if isEnabled(id) { refresh(id) }
    }

    /// Wipes every recorded trend line.
    func resetHistory() {
        UsageHistoryStore.shared.clearAll()
        history = [:]
        tick &+= 1
    }

    var credentialError: String? { config.lastCredentialError }

    // MARK: Timers and system events

    private func startAutoRefresh() {
        autoRefreshTask?.cancel()
        let minutes = max(1, refreshMinutes)
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double(minutes) * 60))
                guard let self, !Task.isCancelled else { return }
                self.refreshAll()
            }
        }
    }

    /// Drives the "resets in …" / "updated … ago" labels between refreshes.
    private func startClock() {
        clockTask?.cancel()
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, !Task.isCancelled else { return }
                self.tick &+= 1
            }
        }
    }

    /// Refresh shortly after wake and when the network recovers, mirroring
    /// codex-island's resilience without probing into the post-wake burst.
    private func startSystemObservers() {
        let center = NSWorkspace.shared.notificationCenter
        systemObservers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                self?.refreshAll()
            }
        })
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let previous = self.lastNetStatus
                self.lastNetStatus = path.status
                guard path.status == .satisfied,
                      let previous, previous != .satisfied else { return }
                try? await Task.sleep(for: .seconds(3))
                self.refreshAll()
            }
        }
        monitor.start(queue: DispatchQueue(label: "bar.quota.network"))
        netMonitor = monitor
    }
}

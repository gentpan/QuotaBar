import Foundation

public struct QuotaConfig: Codable, Sendable, Equatable {
    public var enabled: [ProviderID]
    public var refreshMinutes: Int
    public var menuBarStyle: MenuBarStyle
    public var meterMode: MeterMode
    public var presentation: Presentation
    public var alerts: AlertSettings
    public var language: L10n.Language
    /// Which provider the panel — and therefore the menu-bar glyph — is
    /// focused on. nil means the overview, where the glyph aggregates.
    public var selected: ProviderID?
    /// Where to look for updates: `owner/repo` for GitHub, or a URL for a
    /// JSON endpoint you host.
    public var updateFeed: String
    public var checksForUpdates: Bool
    public var dockEdge: DockEdge
    /// Vertical placement of the dock as a fraction of the screen, 0 at the
    /// top. Remembered so the strip stays out of whatever the user keeps at
    /// the middle of that edge.
    public var dockPosition: Double
    /// When false the strip hides itself until the pointer reaches the edge.
    public var dockAlwaysVisible: Bool
    /// The desktop widget is independent of `presentation`: it sits alongside
    /// the menu bar rather than replacing it.
    public var widgetEnabled: Bool
    public var widgetDensity: WidgetDensity
    /// Position as fractions of the screen so it survives a resolution change.
    public var widgetX: Double
    public var widgetY: Double
    /// Desktop level by default — a widget that floats over every window is a
    /// different thing, and an intrusive one.
    public var widgetAlwaysOnTop: Bool

    /// Only ever populated by decoding a pre-Keychain config file. `ConfigStore`
    /// drains it into the keychain on load and rewrites the file without it;
    /// it is never encoded, so the plaintext cannot come back.
    public var legacyCredentials: [ProviderID: String]

    /// True when the file carried a `credentials` key at all — including an
    /// empty one. Set so the store rewrites the file once and the key stops
    /// appearing next to a keychain-backed install.
    var hasLegacyCredentialKey = false

    public init(
        enabled: [ProviderID] = [.codex, .claude],
        refreshMinutes: Int = 5,
        menuBarStyle: MenuBarStyle = .dualBar,
        meterMode: MeterMode = .remaining,
        presentation: Presentation = .menuBar,
        alerts: AlertSettings = AlertSettings(),
        language: L10n.Language = .system,
        selected: ProviderID? = nil,
        updateFeed: String = UpdateFeed.default.configValue,
        checksForUpdates: Bool = true,
        dockEdge: DockEdge = .right,
        dockPosition: Double = 0.5,
        dockAlwaysVisible: Bool = false,
        widgetEnabled: Bool = false,
        widgetDensity: WidgetDensity = .standard,
        widgetX: Double = 0.82,
        widgetY: Double = 0.12,
        widgetAlwaysOnTop: Bool = false,
        legacyCredentials: [ProviderID: String] = [:])
    {
        self.enabled = enabled
        self.refreshMinutes = refreshMinutes
        self.menuBarStyle = menuBarStyle
        self.meterMode = meterMode
        self.presentation = presentation
        self.alerts = alerts
        self.language = language
        self.selected = selected
        self.updateFeed = updateFeed
        self.checksForUpdates = checksForUpdates
        self.dockEdge = dockEdge
        self.dockPosition = dockPosition
        self.dockAlwaysVisible = dockAlwaysVisible
        self.widgetEnabled = widgetEnabled
        self.widgetDensity = widgetDensity
        self.widgetX = widgetX
        self.widgetY = widgetY
        self.widgetAlwaysOnTop = widgetAlwaysOnTop
        self.legacyCredentials = legacyCredentials
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, refreshMinutes, menuBarStyle, meterMode, presentation, alerts, language
        case selected, updateFeed, checksForUpdates
        case dockEdge, dockPosition, dockAlwaysVisible
        case widgetEnabled, widgetDensity, widgetX, widgetY, widgetAlwaysOnTop
        case legacyCredentials = "credentials"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = QuotaConfig()
        // Every field is decoded leniently. `decodeIfPresent` only tolerates a
        // *missing* key — an unrecognised enum value throws, which would fail
        // the whole file and silently reset every other preference. That can
        // happen from a hand-edited config, or from running an older build
        // after a newer one wrote a value it does not know.
        enabled = QuotaConfig.decodeProviders(from: container) ?? defaults.enabled
        refreshMinutes = (try? container.decodeIfPresent(Int.self, forKey: .refreshMinutes))
            ?? defaults.refreshMinutes
        menuBarStyle = QuotaConfig.decodeEnum(from: container, forKey: .menuBarStyle)
            ?? defaults.menuBarStyle
        meterMode = QuotaConfig.decodeEnum(from: container, forKey: .meterMode) ?? defaults.meterMode
        presentation = QuotaConfig.decodeEnum(from: container, forKey: .presentation)
            ?? defaults.presentation
        alerts = ((try? container.decodeIfPresent(AlertSettings.self, forKey: .alerts))
            ?? defaults.alerts).normalized()
        language = QuotaConfig.decodeEnum(from: container, forKey: .language) ?? defaults.language
        // nil is meaningful here (the overview), so an absent or unreadable
        // value simply means "no provider focused".
        selected = QuotaConfig.decodeEnum(from: container, forKey: .selected)
        updateFeed = (try? container.decodeIfPresent(String.self, forKey: .updateFeed))
            ?? defaults.updateFeed
        checksForUpdates = (try? container.decodeIfPresent(Bool.self, forKey: .checksForUpdates))
            ?? defaults.checksForUpdates
        dockEdge = QuotaConfig.decodeEnum(from: container, forKey: .dockEdge) ?? defaults.dockEdge
        // Clamped: a stored value outside 0...1 would park the strip off-screen.
        dockPosition = min(max(
            (try? container.decodeIfPresent(Double.self, forKey: .dockPosition))
                ?? defaults.dockPosition, 0), 1)
        dockAlwaysVisible = (try? container.decodeIfPresent(Bool.self, forKey: .dockAlwaysVisible))
            ?? defaults.dockAlwaysVisible
        widgetEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .widgetEnabled))
            ?? defaults.widgetEnabled
        widgetDensity = QuotaConfig.decodeEnum(from: container, forKey: .widgetDensity)
            ?? defaults.widgetDensity
        widgetX = min(max(
            (try? container.decodeIfPresent(Double.self, forKey: .widgetX)) ?? defaults.widgetX, 0), 1)
        widgetY = min(max(
            (try? container.decodeIfPresent(Double.self, forKey: .widgetY)) ?? defaults.widgetY, 0), 1)
        widgetAlwaysOnTop = (try? container.decodeIfPresent(Bool.self, forKey: .widgetAlwaysOnTop))
            ?? defaults.widgetAlwaysOnTop
        legacyCredentials = QuotaConfig.decodeLegacyCredentials(from: container)
        hasLegacyCredentialKey = container.contains(.legacyCredentials)
    }

    /// Decodes a string-backed enum, returning nil for a missing key *or* an
    /// unrecognised value, so the caller can fall back to its default.
    private static func decodeEnum<T: RawRepresentable>(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys) -> T? where T.RawValue == String
    {
        guard let raw = try? container.decodeIfPresent(String.self, forKey: key) else { return nil }
        return T(rawValue: raw)
    }

    /// Drops provider ids this build does not recognise instead of discarding
    /// the whole list — a newer build's extra provider must not wipe the
    /// user's other selections.
    private static func decodeProviders(
        from container: KeyedDecodingContainer<CodingKeys>) -> [ProviderID]?
    {
        guard let values = try? container.decodeIfPresent([String].self, forKey: .enabled)
        else { return nil }
        return values.compactMap(ProviderID.init(rawValue:))
    }

    /// Older files store the credential map two different ways: Swift's own
    /// `Codable` output for a dictionary keyed by a `String`-raw-value enum is
    /// a *flat array* (`["cursor", "secret", ...]`), while a hand-edited file
    /// is normally a JSON object. Accept both — a credential that fails to
    /// decode here is one that silently never reaches the keychain.
    private static func decodeLegacyCredentials(
        from container: KeyedDecodingContainer<CodingKeys>) -> [ProviderID: String]
    {
        if let object = try? container.decodeIfPresent(
            [String: String].self, forKey: .legacyCredentials)
        {
            return object.reduce(into: [:]) { result, pair in
                if let id = ProviderID(rawValue: pair.key) { result[id] = pair.value }
            }
        }
        if let flat = try? container.decodeIfPresent([String].self, forKey: .legacyCredentials) {
            var result: [ProviderID: String] = [:]
            for index in stride(from: 0, to: flat.count - 1, by: 2) {
                if let id = ProviderID(rawValue: flat[index]) { result[id] = flat[index + 1] }
            }
            return result
        }
        return [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(refreshMinutes, forKey: .refreshMinutes)
        try container.encode(menuBarStyle, forKey: .menuBarStyle)
        try container.encode(meterMode, forKey: .meterMode)
        try container.encode(presentation, forKey: .presentation)
        try container.encode(alerts, forKey: .alerts)
        try container.encode(language, forKey: .language)
        try container.encodeIfPresent(selected, forKey: .selected)
        try container.encode(updateFeed, forKey: .updateFeed)
        try container.encode(checksForUpdates, forKey: .checksForUpdates)
        try container.encode(dockEdge, forKey: .dockEdge)
        try container.encode(dockPosition, forKey: .dockPosition)
        try container.encode(dockAlwaysVisible, forKey: .dockAlwaysVisible)
        try container.encode(widgetEnabled, forKey: .widgetEnabled)
        try container.encode(widgetDensity, forKey: .widgetDensity)
        try container.encode(widgetX, forKey: .widgetX)
        try container.encode(widgetY, forKey: .widgetY)
        try container.encode(widgetAlwaysOnTop, forKey: .widgetAlwaysOnTop)
        // `legacyCredentials` intentionally omitted.
    }
}

/// Preferences live in ~/.config/quotabar/config.json (0600); manually entered
/// credentials live in the login keychain. Nothing secret is written to disk.
public final class ConfigStore: @unchecked Sendable {
    public static let shared = ConfigStore()

    private let lock = NSLock()
    private var config: QuotaConfig
    private let credentials: CredentialStorage
    /// Memoized keychain reads. `SecItemCopyMatching` blocks the calling thread
    /// whenever macOS decides to ask the user to authorize access, so it must
    /// not be hit once per refresh — let alone once per SwiftUI render.
    private var credentialCache: [ProviderID: String?] = [:]
    public let fileURL: URL

    /// Set when the keychain rejects a write, so Settings can explain why a
    /// credential did not stick instead of appearing to save it.
    public private(set) var lastCredentialError: String?

    public init(fileURL: URL? = nil, credentials: CredentialStorage = KeychainStorage()) {
        let url = fileURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/quotabar/config.json")
        self.fileURL = url
        self.credentials = credentials
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(QuotaConfig.self, from: data)
        {
            self.config = decoded
        } else {
            self.config = QuotaConfig()
        }
        L10n.override = config.language
        migrateLegacyCredentials()
    }

    /// Moves any plaintext credentials from an older config file into the
    /// keychain, then rewrites the file without them.
    private func migrateLegacyCredentials() {
        let pending = config.legacyCredentials.filter {
            !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !pending.isEmpty else {
            // Nothing to move, but drop a leftover (possibly empty) key so the
            // file matches what this version writes.
            if config.hasLegacyCredentialKey {
                config.hasLegacyCredentialKey = false
                save(config)
            }
            return
        }
        var migrated: [ProviderID] = []
        for (id, value) in pending where credentials.write(value, account: id.rawValue) {
            migrated.append(id)
            credentialCache[id] = value
        }
        for id in migrated {
            config.legacyCredentials[id] = nil
        }
        if migrated.count < pending.count {
            lastCredentialError = L10n.t(
                "Some credentials could not be moved to the keychain and are still in config.json.",
                "部分凭据无法写入钥匙串，仍留在 config.json 中。")
        }
        // Rewrite unconditionally: encoding drops `legacyCredentials` entirely,
        // so this is what actually erases the plaintext from disk.
        config.hasLegacyCredentialKey = false
        save(config)
    }

    public var snapshot: QuotaConfig {
        lock.lock(); defer { lock.unlock() }
        return config
    }

    public var enabledProviders: [ProviderID] {
        lock.lock(); defer { lock.unlock() }
        return config.enabled
    }

    public func isEnabled(_ id: ProviderID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return config.enabled.contains(id)
    }

    public func setEnabled(_ id: ProviderID, _ on: Bool) {
        lock.lock()
        if on, !config.enabled.contains(id) {
            config.enabled.append(id)
        } else if !on {
            config.enabled.removeAll { $0 == id }
        }
        let snapshot = config
        lock.unlock()
        save(snapshot)
    }

    // MARK: Credentials (keychain-backed)

    public func credential(for id: ProviderID) -> String? {
        lock.lock()
        if let cached = credentialCache[id] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let read = credentials.read(account: id.rawValue)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (read?.isEmpty == false) ? read : nil

        lock.lock()
        credentialCache[id] = value
        lock.unlock()
        return value
    }

    public func setCredential(_ value: String?, for id: ProviderID) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            lastCredentialError = credentials.delete(account: id.rawValue)
                ? nil
                : L10n.t("Could not remove the credential from the keychain.", "无法从钥匙串中删除该凭据。")
        } else {
            lastCredentialError = credentials.write(trimmed, account: id.rawValue)
                ? nil
                : L10n.t("Could not save the credential to the keychain.", "无法将该凭据写入钥匙串。")
        }
        lock.lock()
        credentialCache[id] = trimmed.isEmpty ? String?.none : trimmed
        lock.unlock()
    }

    /// Drops the memoized reads so the next lookup goes back to the keychain.
    public func invalidateCredentialCache() {
        lock.lock()
        credentialCache.removeAll()
        lock.unlock()
    }

    // MARK: Preferences

    public var refreshMinutes: Int {
        get {
            lock.lock(); defer { lock.unlock() }
            return config.refreshMinutes
        }
        set { mutate { $0.refreshMinutes = max(1, newValue) } }
    }

    public var presentation: Presentation {
        get {
            lock.lock(); defer { lock.unlock() }
            return config.presentation
        }
        set { mutate { $0.presentation = newValue } }
    }

    public var alerts: AlertSettings {
        get {
            lock.lock(); defer { lock.unlock() }
            return config.alerts
        }
        set { mutate { $0.alerts = newValue.normalized() } }
    }

    public var menuBarStyle: MenuBarStyle {
        get {
            lock.lock(); defer { lock.unlock() }
            return config.menuBarStyle
        }
        set { mutate { $0.menuBarStyle = newValue } }
    }

    public var meterMode: MeterMode {
        get {
            lock.lock(); defer { lock.unlock() }
            return config.meterMode
        }
        set { mutate { $0.meterMode = newValue } }
    }

    /// Falls back to the default feed when the stored value is malformed, so
    /// a bad edit disables nothing.
    public var updateFeed: UpdateFeed {
        get {
            lock.lock(); defer { lock.unlock() }
            return UpdateFeed(configValue: config.updateFeed) ?? .default
        }
        set { mutate { $0.updateFeed = newValue.configValue } }
    }

    public var checksForUpdates: Bool {
        get {
            lock.lock(); defer { lock.unlock() }
            return config.checksForUpdates
        }
        set { mutate { $0.checksForUpdates = newValue } }
    }

    public var dockEdge: DockEdge {
        get {
            lock.lock(); defer { lock.unlock() }
            return config.dockEdge
        }
        set { mutate { $0.dockEdge = newValue } }
    }

    public var dockPosition: Double {
        get {
            lock.lock(); defer { lock.unlock() }
            return config.dockPosition
        }
        set { mutate { $0.dockPosition = min(max(newValue, 0), 1) } }
    }

    public var dockAlwaysVisible: Bool {
        get {
            lock.lock(); defer { lock.unlock() }
            return config.dockAlwaysVisible
        }
        set { mutate { $0.dockAlwaysVisible = newValue } }
    }

    public var widgetEnabled: Bool {
        get {
            lock.lock(); defer { lock.unlock() }
            return config.widgetEnabled
        }
        set { mutate { $0.widgetEnabled = newValue } }
    }

    public var widgetDensity: WidgetDensity {
        get {
            lock.lock(); defer { lock.unlock() }
            return config.widgetDensity
        }
        set { mutate { $0.widgetDensity = newValue } }
    }

    public var widgetAlwaysOnTop: Bool {
        get {
            lock.lock(); defer { lock.unlock() }
            return config.widgetAlwaysOnTop
        }
        set { mutate { $0.widgetAlwaysOnTop = newValue } }
    }

    public var widgetOrigin: (x: Double, y: Double) {
        get {
            lock.lock(); defer { lock.unlock() }
            return (config.widgetX, config.widgetY)
        }
        set {
            mutate {
                $0.widgetX = min(max(newValue.x, 0), 1)
                $0.widgetY = min(max(newValue.y, 0), 1)
            }
        }
    }

    public var language: L10n.Language {
        get {
            lock.lock(); defer { lock.unlock() }
            return config.language
        }
        set {
            mutate { $0.language = newValue }
            L10n.override = newValue
        }
    }

    /// Which provider the panel — and therefore the menu-bar glyph — is
    /// focused on. nil means the overview, where the glyph aggregates.
    public var selected: ProviderID? {
        get {
            lock.lock(); defer { lock.unlock() }
            return config.selected
        }
        set { mutate { $0.selected = newValue } }
    }

    private func mutate(_ body: (inout QuotaConfig) -> Void) {
        lock.lock()
        body(&config)
        let snapshot = config
        lock.unlock()
        save(snapshot)
    }

    private func save(_ snapshot: QuotaConfig) {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: fileURL, options: [.atomic])
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path)
        } catch {
            FileHandle.standardError.write(Data("QuotaBar: failed to save config: \(error)\n".utf8))
        }
    }
}

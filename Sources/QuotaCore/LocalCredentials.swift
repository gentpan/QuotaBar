import Foundation
import Security

/// Readers for credentials stored locally by provider CLIs (no passwords, reuse existing sessions).
public enum LocalCredentials {
    private static let home = FileManager.default.homeDirectoryForCurrentUser

    /// The Claude lookup is memoized briefly: a refresh cycle and a settings
    /// render should share one keychain round trip, and a re-login should
    /// still be picked up within the minute.
    private static let keychainTTL: TimeInterval = 60
    private static let memo = TokenMemo()

    final class TokenMemo: @unchecked Sendable {
        private let lock = NSLock()
        private var value: ClaudeLookup?
        private var storedAt: Date = .distantPast

        func cached(ttl: TimeInterval) -> ClaudeLookup? {
            lock.lock(); defer { lock.unlock() }
            guard Date().timeIntervalSince(storedAt) < ttl else { return nil }
            return value
        }

        func store(_ lookup: ClaudeLookup) {
            lock.lock()
            value = lookup
            storedAt = Date()
            lock.unlock()
        }

        func invalidate() {
            lock.lock()
            storedAt = .distantPast
            lock.unlock()
        }
    }

    /// Forces the next Claude lookup to go back to the keychain.
    public static func invalidateClaudeToken() {
        memo.invalidate()
    }

    // MARK: Codex (~/.codex/auth.json)

    public struct CodexAuth: Sendable {
        public let accessToken: String
        public let accountId: String?
    }

    public static func codexAuth() -> CodexAuth? {
        let url = home.appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String, !accessToken.isEmpty
        else { return nil }
        return CodexAuth(accessToken: accessToken, accountId: tokens["account_id"] as? String)
    }

    // MARK: Claude (Keychain item written by Claude Code)

    /// What a lookup of Claude Code's keychain item found.
    public enum ClaudeCredentialState: Sendable, Equatable {
        /// A token was read.
        case available
        /// The item is there, but macOS would put up its keychain dialog
        /// before handing it over, and no user action has asked for that yet.
        case needsAuthorization
        /// No item, or an item without a usable token: Claude Code has not
        /// signed in on this Mac.
        case missing
    }

    struct ClaudeLookup: Sendable, Equatable {
        let state: ClaudeCredentialState
        let token: String?
    }

    /// Shown wherever the app is waiting on the user's say-so.
    public static var claudeAuthorizationHint: String {
        L10n.t(
            "Claude Code keeps its session in the keychain, and macOS asks before another app may read it. Press “Allow keychain access” and choose Always Allow in the dialog.",
            "Claude Code 的会话存在钥匙串里，macOS 会在其他应用读取前询问一次。点「授权钥匙串访问」，在弹窗里选「始终允许」。")
    }

    /// Never prompts. Background refreshes call this every cycle, and a
    /// keychain dialog that pops up on a timer — every minute, for as long as
    /// the user keeps declining it — is exactly what this guards against.
    /// When macOS would have asked, the answer is `nil` and
    /// `claudeCredentialState()` reports `.needsAuthorization`; the dialog is
    /// only ever raised by `authorizeClaudeAccess()`, from a button.
    public static func claudeOAuthToken() -> String? {
        probeClaude().token
    }

    public static func claudeCredentialState() -> ClaudeCredentialState {
        probeClaude().state
    }

    /// The one place the keychain dialog is allowed. Call it from a user
    /// action; it blocks the calling thread for as long as the dialog is up.
    /// A decline is remembered like any other answer, so the next refresh
    /// stays quiet and the button simply remains available.
    @discardableResult
    public static func authorizeClaudeAccess() -> Bool {
        let lookup = readClaudeOAuthToken(interactive: true)
        memo.store(lookup)
        return lookup.state == .available
    }

    /// `authorizeClaudeAccess()` off the cooperative pool: the dialog can sit
    /// there for minutes, and a pinned executor thread would be a poor trade
    /// for one keychain read.
    public static func authorizeClaudeAccessAsync() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: authorizeClaudeAccess())
            }
        }
    }

    private static func probeClaude() -> ClaudeLookup {
        if let cached = memo.cached(ttl: keychainTTL) { return cached }
        let lookup = readClaudeOAuthToken(interactive: false)
        memo.store(lookup)
        return lookup
    }

    private static func readClaudeOAuthToken(interactive: Bool) -> ClaudeLookup {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status: OSStatus = interactive
            ? SecItemCopyMatching(query as CFDictionary, &result)
            : KeychainUI.withoutPrompts { SecItemCopyMatching(query as CFDictionary, &result) }
        return classify(status: status, data: result as? Data)
    }

    /// Pure, so the status mapping is pinned by tests without a keychain.
    static func classify(status: OSStatus, data: Data?) -> ClaudeLookup {
        switch status {
        case errSecSuccess:
            let token = data.flatMap(extractClaudeToken)
            return ClaudeLookup(state: token == nil ? .missing : .available, token: token)
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            // -25308 is what the documentation promises for a suppressed
            // dialog; -25293 is what macOS 27 actually returns (measured on
            // an item this process is not trusted for). -128 is the user
            // pressing Deny on the interactive path.
            return ClaudeLookup(state: .needsAuthorization, token: nil)
        default:
            return ClaudeLookup(state: .missing, token: nil)
        }
    }

    static func extractClaudeToken(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let oauth = root["claudeAiOauth"] as? [String: Any],
           let token = oauth["accessToken"] as? String, !token.isEmpty
        {
            return token
        }
        if let token = root["accessToken"] as? String, !token.isEmpty { return token }
        return nil
    }

    /// Legacy login-keychain items have no per-query "no UI" switch — the
    /// `kSecUseAuthenticationUI` keys only govern data-protection items. The
    /// process-wide `SecKeychainSetUserInteractionAllowed` is what works:
    /// measured on macOS 27, a read that would have prompted returns in 9 ms
    /// with `errSecAuthFailed` and no dialog. It has carried a deprecation
    /// since 10.10 ("SecKeychain is deprecated") with nothing offered in its
    /// place, so it is bound through `dlsym` rather than the declared symbol:
    /// the warning would otherwise sit in every build. The C signature is
    /// stable — `(Boolean) -> OSStatus`.
    enum KeychainUI {
        private typealias SetInteraction = @convention(c) (UInt8) -> OSStatus
        private typealias GetInteraction = @convention(c) (UnsafeMutablePointer<UInt8>) -> OSStatus

        // RTLD_DEFAULT; the macro does not import.
        private static let handle = UnsafeMutableRawPointer(bitPattern: -2)
        private static let set: SetInteraction? = dlsym(handle, "SecKeychainSetUserInteractionAllowed")
            .map { unsafeBitCast($0, to: SetInteraction.self) }
        private static let get: GetInteraction? = dlsym(handle, "SecKeychainGetUserInteractionAllowed")
            .map { unsafeBitCast($0, to: GetInteraction.self) }
        // The switch is process-global, so two callers must not interleave
        // their save/restore.
        private static let lock = NSLock()

        static var isInteractionAllowed: Bool {
            guard let get else { return true }
            var value: UInt8 = 1
            _ = get(&value)
            return value != 0
        }

        /// Runs `body` with the keychain dialog suppressed, then puts the
        /// switch back the way it was. Without the symbols (never, on macOS)
        /// it runs `body` as-is — the old behaviour, which may prompt.
        static func withoutPrompts<T>(_ body: () -> T) -> T {
            lock.lock(); defer { lock.unlock() }
            guard let set, let get else { return body() }
            var previous: UInt8 = 1
            _ = get(&previous)
            _ = set(0)
            defer { _ = set(previous) }
            return body()
        }
    }

    // MARK: Gemini (~/.gemini/oauth_creds.json written by Gemini CLI)

    public static func geminiAccessToken() -> String? {
        let url = home.appendingPathComponent(".gemini/oauth_creds.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = root["access_token"] as? String, !token.isEmpty
        else { return nil }
        return token
    }

    // MARK: OpenCode (~/.local/share/opencode/auth.json written by the opencode CLI)

    /// The opencode CLI stores provider API keys in the clear, keyed by
    /// provider slug. `opencode-go` is the coding plan QuotaBar tracks.
    public static func openCodeGoKey() -> String? {
        readOpenCodeKey("opencode-go")
    }

    static func readOpenCodeKey(_ slug: String) -> String? {
        let candidates = [
            home.appendingPathComponent(".local/share/opencode/auth.json"),
            home.appendingPathComponent(".config/opencode/auth.json"),
        ]
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entry = root[slug] as? [String: Any],
                  let key = entry["key"] as? String, !key.isEmpty
            else { continue }
            return key
        }
        return nil
    }

    // MARK: Cursor (Cursor.app → state.vscdb signed-in session)

    public struct CursorSession: Sendable {
        /// The value cursor.com expects in its WorkosCursorSessionToken cookie:
        /// the user id and the JWT joined by "::", url-encoded at send time.
        public let sessionCookie: String
        public let email: String?
    }

    /// Reads the session Cursor.app already established, from the SQLite
    /// key/value store it keeps under Application Support. No keychain, no
    /// decryption — the values are stored in the clear.
    ///
    /// The cookie cursor.com wants is not the bare JWT but `sub::JWT`; the
    /// bare token is rejected. `sub` is a claim inside the JWT, so the two
    /// halves come from one value.
    public static func cursorSession() -> CursorSession? {
        let db = home
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
            .path
        guard let token = SQLiteRead.firstString(
            inFile: db,
            query: "SELECT value FROM ItemTable WHERE key = ?",
            bind: "cursorAuth/accessToken"),
            !token.isEmpty
        else { return nil }
        let email = SQLiteRead.firstString(
            inFile: db,
            query: "SELECT value FROM ItemTable WHERE key = ?",
            bind: "cursorAuth/cachedEmail")
        return makeCursorSession(accessToken: token, email: email)
    }

    /// Pure assembly step, split out so it can be tested without a database:
    /// pulls `sub` from the JWT and pairs it with the token.
    public static func makeCursorSession(accessToken: String, email: String?) -> CursorSession? {
        guard let sub = jwtClaim(accessToken, "sub"), !sub.isEmpty else { return nil }
        let trimmedEmail = email?.trimmingCharacters(in: .whitespacesAndNewlines)
        return CursorSession(
            sessionCookie: "\(sub)::\(accessToken)",
            email: (trimmedEmail?.isEmpty == false) ? trimmedEmail : nil)
    }

    /// Decodes a single string claim from a JWT payload without verifying the
    /// signature — this only reads a token the user's own app already trusts.
    static func jwtClaim(_ jwt: String, _ name: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Restore base64 padding stripped by the JWT encoding.
        while payload.count % 4 != 0 { payload.append("=") }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object[name] as? String
    }

    // MARK: Grok (~/.grok/auth.json written by the grok CLI)

    public static func grokAccessToken() -> String? {
        let candidates = [
            home.appendingPathComponent(".grok/auth.json"),
            home.appendingPathComponent(".config/grok/auth.json"),
        ]
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if let token = grokToken(in: root) { return token }
        }
        return nil
    }

    /// Two shapes. Early grok CLIs wrote a flat file with the token at the
    /// top level. 1.0.x keys the file by issuer —
    /// `"https://auth.x.ai::<client-id>": { "key": …, "expires_at": …, … }`
    /// — and the bearer the billing endpoint wants is `key` (verified against
    /// `cli-chat-proxy.grok.com/v1/billing`: 200 with it). Entries whose
    /// `expires_at` has passed are ranked last rather than dropped: an expired
    /// token gets a 401 and the "sign in again" message, which is the truth,
    /// where "not configured" would send the user hunting for a file that is
    /// right there. The CLI refreshes the entry on its next run; the app does
    /// not touch `refresh_token` — that is the CLI's session to rotate.
    static func grokToken(in root: [String: Any], now: Date = Date()) -> String? {
        for key in ["access_token", "accessToken", "token", "api_key"] {
            if let token = root[key] as? String, !token.isEmpty { return token }
        }
        var live: [(expires: Date, token: String)] = []
        var expired: [(expires: Date, token: String)] = []
        for value in root.values {
            guard let entry = value as? [String: Any],
                  let token = entry["key"] as? String, !token.isEmpty
            else { continue }
            let expires = Dates.parseISO(entry["expires_at"] as? String) ?? .distantFuture
            if expires > now { live.append((expires, token)) } else { expired.append((expires, token)) }
        }
        // The one that lives longest, then the one that expired most recently.
        return live.max(by: { $0.expires < $1.expires })?.token
            ?? expired.max(by: { $0.expires < $1.expires })?.token
    }
}

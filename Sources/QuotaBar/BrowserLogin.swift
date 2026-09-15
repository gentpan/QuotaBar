import AppKit
import WebKit
import QuotaCore

/// Sign in to a cookie provider without leaving the app: a window with a
/// web view on the provider's own site. The moment the session cookie the
/// provider's API wants shows up in the web view's jar — or, for a console
/// that keeps it in local storage, the session token there — it is stored
/// as the credential and the window closes. Nothing is read from the user's other
/// browsers — this is the in-app equivalent of CodexBar's "open the site
/// and wait for the cookie", without touching Chrome's or Safari's stores.
@MainActor
final class BrowserLogin: NSObject, WKNavigationDelegate, NSWindowDelegate {
    struct Target {
        let url: URL
        /// The cookie whose arrival means the sign-in finished.
        let cookie: String
        let domain: String
        /// Store every cookie for the domain as a Cookie header, for the
        /// consoles that want the whole session rather than one token.
        var wholeHeader = false
        /// A console that keeps its sign-in in local storage rather than a
        /// cookie: the key to read once the page is on `domain`.
        var localStorageKey: String?
    }

    static func target(for id: ProviderID) -> Target? {
        switch id {
        case .cursor:
            Target(url: URL(string: "https://cursor.com/dashboard")!, cookie: "WorkosCursorSessionToken", domain: "cursor.com")
        case .kimi:
            Target(url: URL(string: "https://www.kimi.com/code/console")!, cookie: "kimi-auth", domain: "kimi.com")
        case .alibaba:
            Target(url: URL(string: "https://bailian.console.aliyun.com/cn-beijing/?tab=model#/efm/coding_plan")!,
                   cookie: "login_aliyunid_ticket", domain: "aliyun.com", wholeHeader: true)
        case .mimo:
            Target(url: URL(string: "https://platform.xiaomimimo.com/#/console/balance")!,
                   cookie: "api-platform_serviceToken", domain: "xiaomimimo.com", wholeHeader: true)
        case .deepseek:
            // The platform console signs in on its own page and keeps the
            // session as `userToken` in local storage — the token its usage
            // page sends, and the one that shows each key's usage.
            Target(url: URL(string: "https://platform.deepseek.com/usage")!,
                   cookie: "", domain: "platform.deepseek.com", localStorageKey: "userToken")
        case .qwen:
            Target(url: URL(string: "https://home.qwencloud.com/billing/subscription/token-plan-individual")!,
                   cookie: "login_aliyunid_ticket", domain: "qwencloud.com", wholeHeader: true)
        default:
            nil
        }
    }

    static func supports(_ id: ProviderID) -> Bool { target(for: id) != nil }

    private static var current: BrowserLogin?

    private let id: ProviderID
    private let target: Target
    private weak var store: UsageStore?
    private var window: NSWindow?
    private var webView: WKWebView?
    private var poll: Task<Void, Never>?
    private var finished = false

    private init(id: ProviderID, target: Target, store: UsageStore) {
        self.id = id
        self.target = target
        self.store = store
    }

    static func present(for id: ProviderID, store: UsageStore) {
        guard let target = target(for: id) else { return }
        current?.close()
        let login = BrowserLogin(id: id, target: target, store: store)
        current = login
        login.show()
    }

    private func show() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 960, height: 720), configuration: configuration)
        // Some sign-in pages refuse an embedded web view by its user agent;
        // Safari's own is what they expect from a Mac.
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        webView.navigationDelegate = self
        webView.load(URLRequest(url: target.url))
        self.webView = webView

        let window = NSWindow(
            contentRect: webView.frame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.title = L10n.t("Sign in to \(id.displayName)", "登录 \(id.displayName)")
        window.contentView = webView
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Cookies set by scripts after the page settles never trigger a
        // navigation; look every second and a half as well.
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1500))
                await self?.checkCookies()
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { await checkCookies() }
    }

    private func checkCookies() async {
        guard !finished, let webView else { return }
        if let key = target.localStorageKey {
            await checkLocalStorage(key, in: webView)
            return
        }
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        guard let match = cookies.first(where: {
            $0.name == target.cookie && $0.domain.contains(target.domain) && !$0.value.isEmpty
        }) else { return }
        if target.wholeHeader {
            let header = cookies
                .filter { $0.domain.contains(target.domain) && !$0.value.isEmpty }
                .map { "\($0.name)=\($0.value)" }
                .joined(separator: "; ")
            finish(with: header)
        } else {
            finish(with: match.value)
        }
    }

    /// Reads the key on the console's own origin only: before sign-in the
    /// page may be elsewhere (a login host, a QR page), where the key is
    /// absent or means something else. The stored value is sometimes the
    /// JSON `{"value": "…"}` it is wrapped in; the token alone is kept.
    private func checkLocalStorage(_ key: String, in webView: WKWebView) async {
        guard webView.url?.host == target.domain else { return }
        let script = """
        (() => {
          const raw = localStorage.getItem(\(String(reflecting: key)));
          if (!raw) return null;
          try {
            const parsed = JSON.parse(raw);
            if (parsed && typeof parsed === 'object' && typeof parsed.value === 'string') return parsed.value;
            if (typeof parsed === 'string') return parsed;
          } catch (e) {}
          return raw;
        })()
        """
        guard let value = try? await webView.evaluateJavaScript(script) as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        finish(with: value)
    }

    private func finish(with value: String) {
        finished = true
        store?.setCredential(value, for: id)
        store?.refreshConfigured()
        store?.refresh(id)
        close()
    }

    private func close() {
        poll?.cancel()
        poll = nil
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        window?.delegate = nil
        window?.orderOut(nil)
        window = nil
        webView = nil
        if Self.current === self { Self.current = nil }
    }

    func windowWillClose(_ notification: Notification) {
        close()
    }
}

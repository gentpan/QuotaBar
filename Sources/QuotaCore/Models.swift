import Foundation

// MARK: - Presentation

public enum Presentation: String, Codable, CaseIterable, Identifiable, Sendable {
    case menuBar
    case island
    case edgeDock

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .menuBar: L10n.t("Menu bar only", "仅菜单栏")
        case .island: L10n.t("Notch island", "刘海岛")
        case .edgeDock: L10n.t("Edge dock", "边缘停靠")
        }
    }
}

// MARK: - Menu bar icon styles

public enum MenuBarStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case bar
    case ring
    case columns
    case percent
    /// Discrete styles: the gradations are countable, so the reading is exact
    /// rather than estimated off a continuous fill.
    case dual
    case dualBar
    case segments
    case grid
    case battery
    case gauge
    case ticks

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .bar: L10n.t("Bar", "横条")
        case .ring: L10n.t("Ring", "圆环")
        case .columns: L10n.t("Columns", "柱形")
        case .percent: L10n.t("Percent", "数字")
        case .dual: L10n.t("Dual cells", "双层分段")
        case .dualBar: L10n.t("Dual bars", "双层横条")
        case .segments: L10n.t("Segments", "分段")
        case .grid: L10n.t("Grid", "九宫格")
        case .battery: L10n.t("Battery", "电量")
        case .gauge: L10n.t("Gauge", "仪表")
        case .ticks: L10n.t("Scale", "刻度")
        }
    }

    /// True when the glyph draws the short and long horizons as separate
    /// meters rather than collapsing them into one figure.
    public var showsBothHorizons: Bool { self == .dual || self == .dualBar }

    /// How many steps the glyph resolves. `nil` means continuous.
    public var steps: Int? {
        switch self {
        case .dual, .segments: 5
        case .grid: 9
        case .columns: 4
        case .dualBar, .bar, .ring, .percent, .battery, .gauge, .ticks: nil
        }
    }
}

// MARK: - What the meter fills with

/// Whether the menu-bar meter fills with what is left or what is spent.
///
/// Defaults to `.remaining`: an almost-empty bar reads as "nothing left" to
/// anyone who has ever looked at a battery or a signal indicator, which is the
/// opposite of what a low *usage* figure means.
public enum MeterMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case remaining
    case used

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .remaining: L10n.t("Remaining", "剩余")
        case .used: L10n.t("Used", "已用")
        }
    }

    /// Converts a used-percentage into the value the icon should show.
    public func shownPercent(fromUsed used: Double) -> Double {
        let clamped = min(max(used, 0), 100)
        return self == .remaining ? 100 - clamped : clamped
    }
}

/// Whether the desktop card shows every enabled provider or the pinned one.
public enum WidgetScope: String, Codable, CaseIterable, Identifiable, Sendable {
    case all
    case pinned

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .all: L10n.t("All", "全部")
        case .pinned: L10n.t("Pinned one", "钉住的一个")
        }
    }
}

/// What the menu-bar item shows: a reading, the app's own mark, or nothing.
public enum MenuBarIconMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case meter
    /// openusage's text strip: each provider's mark and its figure.
    case text
    case logo
    case hidden

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .meter: L10n.t("Reading", "用量图标")
        case .text: L10n.t("Marks and figures", "logo 加数字")
        case .logo: L10n.t("Logo", "应用 Logo")
        case .hidden: L10n.t("Hidden", "隐藏")
        }
    }
}

/// What happens when a newer build is found.
public enum UpdatePolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Download and verify in the background as soon as a version is found,
    /// so Install and Relaunch on the update card is instant. Nothing is
    /// replaced until that click. (Raw value kept: stored configs say "automatic".)
    case automatic
    /// Show the card and download only once Install and Relaunch is clicked.
    case manual

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .automatic: L10n.t("Download in background", "后台下载")
        case .manual: L10n.t("Download when I install", "安装时再下载")
        }
    }
}

/// How a quota bar is drawn: one filled capsule, or a row of segments that
/// light up in turn — codex-island's "阶梯", which the owner prefers.
public enum MeterStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case continuous
    case stepped

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .continuous: L10n.t("Continuous", "连续")
        case .stepped: L10n.t("Stepped", "阶梯")
        }
    }
}

// MARK: - Brand theme

/// Neutral accent, deliberately: the panel already carries eleven provider
/// brand colours, and a twelfth competing hue makes none of them legible.
///
/// The pair inverts between appearances — a graphite selection block would
/// disappear into a dark window, so dark mode gets a light block with dark
/// ink instead.
public enum QuotaTheme {
    public nonisolated(unsafe) static var accentHex = "3F3F46"
    /// Text drawn on top of the accent. Kept in step with it, or the selected
    /// tile becomes unreadable.
    public nonisolated(unsafe) static var inkHex = "FFFFFF"

    public nonisolated(unsafe) static var accentDarkHex = "E4E4E7"
    public nonisolated(unsafe) static var inkDarkHex = "18181B"

    private static func channels(_ hex: String) -> (Double, Double, Double) {
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        return (
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255)
    }

    /// WCAG relative luminance, so the floor means the same thing for every hue
    /// — a plain average calls yellow and blue equally bright.
    public static func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
        func linear(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    public static func luminance(hex: String) -> Double {
        let (r, g, b) = channels(hex)
        return luminance(r, g, b)
    }

    /// WCAG contrast ratio of a colour against pure black — the ground the
    /// notch strip, the dock and the widget all draw on.
    ///
    /// Every `accentHex` is required to clear 4.5:1 here (`ProviderRegistryTests`).
    /// Enforcing it as an invariant beats lifting the colour at draw time: a
    /// brand colour that has to be altered to be readable is the wrong brand
    /// colour, and silently mutating it hides that from whoever picked it.
    public static func contrastOnBlack(hex: String) -> Double {
        contrast(hex, against: "000000")
    }

    /// WCAG contrast ratio between two colours.
    public static func contrast(_ a: String, against b: String) -> Double {
        let ya = luminance(hex: a)
        let yb = luminance(hex: b)
        return (max(ya, yb) + 0.05) / (min(ya, yb) + 0.05)
    }
}

/// How much the desktop widget shows.
public enum WidgetDensity: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Rings only — the smallest thing that still says which provider.
    case compact
    /// Rings with their figures.
    case standard
    /// Adds a row per quota window.
    case detailed

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .compact: L10n.t("Compact", "紧凑")
        case .standard: L10n.t("Standard", "标准")
        case .detailed: L10n.t("Detailed", "详细")
        }
    }
}

/// Which screen edge the dock attaches to.
public enum DockEdge: String, Codable, CaseIterable, Identifiable, Sendable {
    case right
    case left

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .right: L10n.t("Right", "右侧")
        case .left: L10n.t("Left", "左侧")
        }
    }
}

// MARK: - Provider identity

public enum ProviderID: String, CaseIterable, Codable, Sendable, Identifiable {
    case codex
    case claude
    case cursor
    case kimi
    case zai
    case opencodeGo = "opencode-go"
    case minimax
    case gemini
    case manus
    case deepseek
    case grok
    case antigravity
    case qwen
    case alibaba
    case volcengine
    case zhipu
    case moonshot
    case copilot
    case openrouter
    case mimo
    case qoder
    case windsurf
    case kiro

    public var id: String { rawValue }

    /// Written from public implementations and not yet confirmed against a
    /// live account; Settings says so beside the name.
    public var isExperimental: Bool {
        switch self {
        case .alibaba, .volcengine, .zhipu, .moonshot, .openrouter, .mimo, .qoder, .windsurf, .kiro: true
        default: false
        }
    }

    /// Brand names stay untranslated in both languages.
    public var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .cursor: "Cursor"
        case .kimi: "Kimi Code"
        case .zai: "z.ai"
        case .opencodeGo: "OpenCode Go"
        case .minimax: "MiniMax"
        case .gemini: "Gemini"
        case .manus: "Manus"
        case .deepseek: "DeepSeek"
        case .grok: "Grok"
        case .antigravity: "Antigravity"
        case .qwen: "Qwen Cloud"
        case .alibaba: L10n.t("Alibaba Coding Plan", "阿里云百炼")
        case .volcengine: L10n.t("Volcengine Ark", "火山方舟")
        case .zhipu: L10n.t("Zhipu GLM", "智谱 GLM")
        case .moonshot: L10n.t("Moonshot API", "Kimi 开放平台")
        case .copilot: "GitHub Copilot"
        case .openrouter: "OpenRouter"
        case .mimo: L10n.t("Xiaomi MiMo", "小米 MiMo")
        case .qoder: "Qoder"
        case .windsurf: "Windsurf"
        case .kiro: "Kiro"
        }
    }

    /// SF Symbol placeholder used as the provider glyph in the menu grid.
    public var symbolName: String {
        switch self {
        case .codex: "terminal"
        case .claude: "sparkles"
        case .cursor: "cursorarrow.rays"
        // Not `textformat`: SF Symbols localises that one, so the fallback
        // draws the literal word "格式" under a Chinese locale.
        case .kimi: "moon.stars"
        case .zai: "z.square"
        case .opencodeGo: "curlybraces"
        case .minimax: "square.stack.3d.up"
        case .gemini: "star"
        case .manus: "hand.raised"
        case .deepseek: "magnifyingglass"
        case .grok: "bolt"
        case .antigravity: "arrow.up.circle"
        case .qwen: "cloud"
        case .alibaba: "cloud.fill"
        case .volcengine: "mountain.2"
        case .zhipu: "circle.hexagongrid"
        case .moonshot: "moon"
        case .copilot: "person.2.wave.2"
        case .openrouter: "arrow.triangle.branch"
        case .mimo: "m.square"
        case .qoder: "q.circle"
        case .windsurf: "wind"
        case .kiro: "k.circle"
        }
    }

    /// Hex accent color used for progress bars / underlines (CodexBar-style per-provider tint).
    public var accentHex: String {
        switch self {
        case .codex: "0A84FF"
        case .claude: "D97757"
        case .cursor: "30B6A5"
        case .kimi: "FF7A45"
        case .zai: "8E8EF7"
        case .opencodeGo: "5B8DEF"
        case .minimax: "E5484D"
        case .gemini: "4285F4"
        case .manus: "B08968"
        case .deepseek: "4D9F7B"
        case .grok: "22C55E"
        case .antigravity: "8AB4F8"
        case .qwen: "C084FC"
        case .alibaba: "FF7A1A"
        case .volcengine: "5B9BFF"
        case .zhipu: "7C95FF"
        case .moonshot: "C8C8D0"
        case .copilot: "B79CFF"
        case .openrouter: "8F9BFF"
        case .mimo: "FF7A00"
        case .qoder: "34D399"
        case .windsurf: "4FE3B8"
        case .kiro: "B08CFF"
        }
    }

    /// Web console where the user can manage the account / grab credentials.
    public var dashboardURL: URL? {
        switch self {
        case .codex: URL(string: "https://chatgpt.com/codex")
        case .claude: URL(string: "https://claude.ai")
        case .cursor: URL(string: "https://cursor.com/dashboard")
        case .kimi: URL(string: "https://www.kimi.com/code/console")
        case .zai: URL(string: "https://z.ai/manage-apikey/coding-plan/personal/my-plan")
        case .opencodeGo: URL(string: "https://opencode.ai")
        case .minimax: URL(string: "https://platform.minimax.io/user-center/payment/coding-plan")
        case .gemini: URL(string: "https://gemini.google.com")
        case .manus: URL(string: "https://manus.im")
        case .deepseek: URL(string: "https://platform.deepseek.com/usage")
        case .grok: URL(string: "https://grok.com")
        case .antigravity: URL(string: "https://antigravity.google")
        case .qwen: URL(string: "https://home.qwencloud.com/billing/subscription/token-plan-individual")
        case .alibaba: URL(string: "https://bailian.console.aliyun.com/cn-beijing/?tab=model#/efm/coding_plan")
        case .volcengine: URL(string: "https://console.volcengine.com/ark/region:ark+cn-beijing/openManagement")
        case .zhipu: URL(string: "https://bigmodel.cn/coding-plan/personal/usage")
        case .moonshot: URL(string: "https://platform.moonshot.cn/console/account")
        case .copilot: URL(string: "https://github.com/settings/copilot")
        case .openrouter: URL(string: "https://openrouter.ai/settings/credits")
        case .mimo: URL(string: "https://platform.xiaomimimo.com/#/console/balance")
        case .qoder: URL(string: "https://qoder.com/account/usage")
        case .windsurf: URL(string: "https://windsurf.com/subscription/usage")
        case .kiro: URL(string: "https://app.kiro.dev/account/usage")
        }
    }

    /// nil = credentials are discovered locally (CLI login files / Keychain).
    public var credentialHint: String? {
        switch self {
        case .codex, .claude, .gemini, .antigravity:
            return nil
        case .qwen:
            return L10n.t(
                "Full Cookie header from home.qwencloud.com, signed in (DevTools → Network → any request → Cookie).",
                "home.qwencloud.com 登录后的完整 Cookie 头（开发者工具 → 网络 → 任一请求 → Cookie）。")
        case .grok:
            return L10n.t(
                "Optional override; otherwise read from ~/.grok/auth.json (grok CLI login).",
                "可选覆盖；留空则读取 ~/.grok/auth.json（grok CLI 登录后生成）。")
        case .cursor:
            return L10n.t(
                "Automatic if Cursor.app is signed in. Otherwise paste the WorkosCursorSessionToken cookie (DevTools → Application → Cookies → cursor.com).",
                "已登录 Cursor.app 时自动读取；否则粘贴 WorkosCursorSessionToken cookie（开发者工具 → 应用 → Cookie → cursor.com）。")
        case .kimi:
            return L10n.t(
                "kimi-auth cookie JWT (DevTools → Application → Cookies → kimi.com).",
                "kimi-auth cookie 的 JWT（开发者工具 → 应用 → Cookie → kimi.com）。")
        case .zai:
            return L10n.t("API key (z.ai → API Keys).", "API Key（z.ai → API Keys）。")
        case .opencodeGo:
            return L10n.t(
                "Automatic if the opencode CLI is signed in. Otherwise paste a session token or Cookie header from opencode.ai.",
                "已登录 opencode CLI 时自动读取；否则粘贴 opencode.ai 的会话 token 或 Cookie 头。")
        case .minimax:
            return L10n.t(
                "API token or full Cookie header from platform.minimax.io.",
                "platform.minimax.io 的 API token 或完整 Cookie 头。")
        case .manus:
            return L10n.t("Session token (Bearer) from manus.im.", "manus.im 的会话 token（Bearer）。")
        case .deepseek:
            return L10n.t(
                "An API key (platform.deepseek.com → API Keys) shows only the balance. For this month's spend and every key's and model's usage, choose Sign in in a browser… and sign in to the DeepSeek console; the sign-in is kept in place of the key.",
                "填 API Key（platform.deepseek.com → API Keys）只能看到余额。想看本月消费和每个 Key、每个模型的用量，点「浏览器登录…」登录 DeepSeek 开放平台即可，登录凭证会替换掉 API Key。")
        case .alibaba:
            return L10n.t(
                "Full Cookie header from bailian.console.aliyun.com (or the international Model Studio console), signed in.",
                "bailian.console.aliyun.com 登录后的完整 Cookie 头（国际站 Model Studio 控制台也可以）。")
        case .zhipu:
            return L10n.t("API key (bigmodel.cn → API Keys).", "API Key（bigmodel.cn → API Keys）。")
        case .moonshot:
            return L10n.t("API key (platform.moonshot.cn → API Keys).", "API Key（platform.moonshot.cn → API Keys）。")
        case .copilot:
            return L10n.t(
                "Optional; otherwise the GitHub CLI's sign-in is used (`gh auth login`).",
                "可选；留空则使用 GitHub CLI 的登录（`gh auth login`）。")
        case .openrouter:
            return L10n.t(
                "API key (openrouter.ai → Keys) for the credits and that key's spend, or a provisioning key (Settings → Provisioning Keys) for every key's spend.",
                "API Key（openrouter.ai → Keys）显示余额和这个 Key 的花费；填管理密钥（Settings → Provisioning Keys）可以看到所有 Key 的花费。")
        case .mimo:
            return L10n.t(
                "Full Cookie header from platform.xiaomimimo.com, signed in (needs api-platform_serviceToken and userId).",
                "platform.xiaomimimo.com 登录后的完整 Cookie 头（需含 api-platform_serviceToken 和 userId）。")
        case .qoder:
            return L10n.t("Full Cookie header from qoder.com, signed in.", "qoder.com 登录后的完整 Cookie 头。")
        case .volcengine, .windsurf, .kiro:
            return nil
        }
    }

    /// How to make an automatic provider discover its session.
    public var setupHint: String {
        switch self {
        case .codex: return L10n.t("Sign in with the Codex CLI (`codex`) first.", "请先用 Codex CLI（`codex`）登录。")
        case .claude: return L10n.t(
            "Run `claude` once and sign in to create the OAuth session.",
            "运行一次 `claude` 并登录以生成 OAuth 会话。")
        case .gemini: return L10n.t("Sign in with the Gemini CLI (`gemini`) first.", "请先用 Gemini CLI（`gemini`）登录。")
        case .grok: return L10n.t(
            "Sign in with the grok CLI or paste a token in Settings.",
            "用 grok CLI 登录，或在设置中粘贴 token。")
        case .antigravity: return L10n.t(
            "Open Antigravity and sign in once; its token is read from ~/.gemini.",
            "打开 Antigravity 并登录一次，令牌会从 ~/.gemini 读取。")
        case .volcengine: return L10n.t(
            "Install arkcli and run `arkcli auth login`.",
            "安装 arkcli 并运行 `arkcli auth login` 登录。")
        case .windsurf: return L10n.t(
            "Open Windsurf and sign in once; the plan it caches on this Mac is read.",
            "打开 Windsurf 并登录一次，会读取它在本机缓存的套餐信息。")
        case .kiro: return L10n.t(
            "Install kiro-cli and sign in (`kiro-cli login`).",
            "安装 kiro-cli 并登录（`kiro-cli login`）。")
        case .copilot: return L10n.t(
            "Sign in with the GitHub CLI (`gh auth login`), or paste a token in Settings.",
            "用 GitHub CLI 登录（`gh auth login`），或在设置里粘贴 token。")
        default: return credentialHint ?? ""
        }
    }
}

// MARK: - Window titles

/// Turns a provider-reported window length into a human title, so a rolling
/// window is never mislabeled by a hardcoded guess.
public enum WindowTitle {
    public static func forSeconds(_ seconds: Int) -> String {
        guard seconds > 0 else { return L10n.t("Quota", "额度") }
        switch seconds {
        case 604_800:
            return L10n.t("Weekly window", "周窗口")
        case 86_400:
            return L10n.t("Daily window", "日窗口")
        case 2_592_000, 2_678_400, 2_628_000:
            return L10n.t("Monthly window", "月窗口")
        default:
            break
        }
        if seconds % 86_400 == 0 {
            let days = seconds / 86_400
            return L10n.t("\(days)-day window", "\(days) 天窗口")
        }
        if seconds % 3600 == 0 {
            let hours = seconds / 3600
            return L10n.t("\(hours)-hour window", "\(hours) 小时窗口")
        }
        let minutes = max(1, seconds / 60)
        return L10n.t("\(minutes)-minute window", "\(minutes) 分钟窗口")
    }

    public static func forMinutes(_ minutes: Int) -> String {
        forSeconds(minutes * 60)
    }

    /// Compact badge form: "5h", "7d", "30d", "45m". Untranslated on purpose —
    /// these read the same in both languages and have to fit a small pill.
    public static func short(_ seconds: Int) -> String? {
        guard seconds > 0 else { return nil }
        if seconds % 86_400 == 0 { return "\(seconds / 86_400)d" }
        if seconds % 3_600 == 0 { return "\(seconds / 3_600)h" }
        if seconds >= 60 { return "\(seconds / 60)m" }
        return "\(seconds)s"
    }
}

// MARK: - Usage models

public struct UsageWindow: Sendable, Identifiable {
    public var id: String
    public var title: String
    /// 0...100, nil when the provider only reports absolute values.
    public var usedPercent: Double?
    /// Human-readable absolute numbers, e.g. "$12.30 / $20.00" or "820 / 1000 credits".
    public var detail: String?
    public var resetsAt: Date?
    /// True for the window the provider says is currently governing requests.
    public var isActive: Bool
    /// Window length as reported by the provider, when it reports one. Drives
    /// the compact "5h" / "7d" badge; nil for billing-cycle or balance rows
    /// that have no fixed length.
    public var windowSeconds: Int?
    /// What the window is scoped to — a model or a metered feature — when it
    /// applies to less than the whole account.
    public var scope: String?

    public init(
        title: String,
        usedPercent: Double? = nil,
        detail: String? = nil,
        resetsAt: Date? = nil,
        isActive: Bool = false,
        windowSeconds: Int? = nil,
        scope: String? = nil)
    {
        self.id = title
        self.title = title
        self.usedPercent = usedPercent.map { min(max($0, 0), 100) }
        self.detail = detail
        self.resetsAt = resetsAt
        self.isActive = isActive
        self.windowSeconds = windowSeconds
        self.scope = scope
    }

    /// Badge text, when the provider reported a window length.
    public var shortLabel: String? {
        windowSeconds.flatMap(WindowTitle.short)
    }

    /// How consumption compares with the pace that would exactly exhaust the
    /// window as it resets.
    ///
    /// Derived from the window's own length, its reset time and the current
    /// figure — no usage history needed, so it works on the first refresh
    /// after launch.
    public func pace(now: Date = .now) -> WindowPace? {
        guard let usedPercent,
              let windowSeconds, windowSeconds > 0,
              let resetsAt
        else { return nil }
        let remaining = resetsAt.timeIntervalSince(now)
        // Outside the window: either it has reset, or the provider reported a
        // reset further out than the window is long.
        guard remaining > 0, remaining <= Double(windowSeconds) else { return nil }

        let elapsed = Double(windowSeconds) - remaining
        guard elapsed > 60 else { return nil }  // too early to say anything

        let expected = elapsed / Double(windowSeconds) * 100
        let rate = usedPercent / elapsed  // percent per second
        let exhaustsIn = rate > 0 ? (100 - usedPercent) / rate : .infinity

        return WindowPace(
            expectedPercent: expected,
            actualPercent: usedPercent,
            secondsToExhaustion: exhaustsIn.isFinite ? exhaustsIn : nil,
            secondsToReset: remaining)
    }

    /// Which question this window answers.
    public var horizon: WindowHorizon {
        guard let seconds = windowSeconds else {
            // Billing cycles and balances have no fixed length; they are about
            // running out over a period, not about being throttled right now.
            return .long
        }
        return seconds < 86_400 ? .short : .long
    }
}

/// Whether usage is ahead of, behind, or on the pace that would exhaust a
/// window exactly as it resets.
public struct WindowPace: Sendable, Equatable {
    /// What the figure would be at this point if consumption were even.
    public var expectedPercent: Double
    public var actualPercent: Double
    /// Projected time to 100% at the current rate; nil when nothing has been
    /// used and the projection is meaningless.
    public var secondsToExhaustion: Double?
    public var secondsToReset: Double

    public init(
        expectedPercent: Double,
        actualPercent: Double,
        secondsToExhaustion: Double?,
        secondsToReset: Double)
    {
        self.expectedPercent = expectedPercent
        self.actualPercent = actualPercent
        self.secondsToExhaustion = secondsToExhaustion
        self.secondsToReset = secondsToReset
    }

}

/// Quota windows split into two questions a glance should answer separately:
/// "am I about to be throttled" and "will I run out this period".
public enum WindowHorizon: Sendable, CaseIterable {
    /// Under a day — 5-hour and rolling windows.
    case short
    /// A day or more, plus billing cycles with no fixed length.
    case long
}

/// What the menu-bar glyph draws. Kept separate from any one provider: the
/// icon answers for the account as a whole, so each horizon takes the highest
/// reading across everything enabled.
public struct MeterReading: Sendable, Equatable {
    public var short: Double?
    public var long: Double?

    public init(short: Double? = nil, long: Double? = nil) {
        self.short = short
        self.long = long
    }

    /// The owner's pick for the one provider on show, when there is one:
    /// what `headline` answers instead of the fuller horizon, while both
    /// horizons stay as they are for the two-arc styles.
    public var preferred: Double? = nil

    /// What a single-meter style shows — the pick, else whichever horizon is
    /// closest to its limit, since that is the one that will bite first.
    public var headline: Double? {
        if let preferred { return preferred }
        switch (short, long) {
        case let (s?, l?): return max(s, l)
        case let (s?, nil): return s
        case let (nil, l?): return l
        case (nil, nil): return nil
        }
    }

    public var hasBothHorizons: Bool { short != nil && long != nil }

    /// Highest reading per horizon across a set of snapshots.
    public static func across(_ snapshots: [UsageSnapshot]) -> MeterReading {
        var reading = MeterReading()
        for window in snapshots.flatMap(\.windows) {
            guard let percent = window.usedPercent else { continue }
            switch window.horizon {
            case .short: reading.short = max(reading.short ?? 0, percent)
            case .long: reading.long = max(reading.long ?? 0, percent)
            }
        }
        return reading
    }
}

/// Credits that let the user reset a rate-limit window early, when the plan
/// grants them.
public struct ResetCredits: Sendable, Equatable {
    /// How many the account holds.
    public var available: Int
    /// How many apply to the window that is currently limiting — often 0 while
    /// nothing is actually throttled.
    public var applicable: Int?
    /// Every reset the account has been given, spent and expired ones too.
    /// Known only once the credit list has been read.
    public var totalEarned: Int?
    /// The available credits the list names, soonest deadline first, ones
    /// that never expire last. The list may name fewer than `available`, and
    /// is empty when it could not be read.
    public var credits: [ResetCredit]

    public init(available: Int, applicable: Int? = nil, totalEarned: Int? = nil, credits: [ResetCredit] = []) {
        self.available = available
        self.applicable = applicable
        self.totalEarned = totalEarned
        self.credits = credits
    }

    /// Worth a row: something to spend, or a history of being given some.
    public var isShown: Bool { available > 0 || (totalEarned ?? 0) > 0 }

    /// The deadlines still ahead: a cached reading keeps ones that have passed.
    public func upcomingExpirations(now: Date = .now) -> [Date] {
        credits.compactMap(\.expiresAt).filter { $0 > now }.sorted()
    }
}

/// One reset the account was given: "Full reset (Weekly + 5 hr)", when it
/// came and when it runs out.
public struct ResetCredit: Sendable, Equatable, Codable {
    public var id: String?
    public var title: String?
    public var grantedAt: Date?
    /// Nil for a credit that does not expire.
    public var expiresAt: Date?

    public init(id: String? = nil, title: String? = nil, grantedAt: Date? = nil, expiresAt: Date? = nil) {
        self.id = id
        self.title = title
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
    }
}

public struct UsageSnapshot: Sendable {
    public var planName: String?
    public var account: String?
    public var windows: [UsageWindow]
    public var fetchedAt: Date
    /// Early-reset credits, when the provider reports them.
    public var resetCredits: ResetCredits?
    /// A prepaid account's balance, spend and keys; see `BalanceSheet`.
    public var balance: BalanceSheet?

    public init(
        planName: String? = nil,
        account: String? = nil,
        windows: [UsageWindow] = [],
        fetchedAt: Date = .now,
        resetCredits: ResetCredits? = nil,
        balance: BalanceSheet? = nil)
    {
        self.planName = planName
        self.account = account
        self.windows = UsageSnapshot.uniquingIDs(windows)
        self.fetchedAt = fetchedAt
        self.resetCredits = resetCredits
        self.balance = balance
    }

    /// `ForEach` needs stable unique ids; two providers legitimately report two
    /// windows with the same title (e.g. per-model weekly limits).
    private static func uniquingIDs(_ windows: [UsageWindow]) -> [UsageWindow] {
        var seen: [String: Int] = [:]
        return windows.map { window in
            var copy = window
            let count = (seen[window.title] ?? 0) + 1
            seen[window.title] = count
            if count > 1 { copy.id = "\(window.title)#\(count)" }
            return copy
        }
    }

    /// Highest used percent across windows — drives the menu-bar meter and grid underline.
    public var headlinePercent: Double? {
        windows.compactMap(\.usedPercent).max()
    }

    /// The window `headlinePercent` came from — what its reset time belongs to.
    public var headlineWindow: UsageWindow? {
        windows
            .filter { $0.usedPercent != nil }
            .max { ($0.usedPercent ?? 0) < ($1.usedPercent ?? 0) }
    }

    /// The window a single figure stands for: the one the owner picked for
    /// this provider, while the provider still reports it with a figure,
    /// else the fullest — the one that bites first.
    public func headlineWindow(preferring windowID: String?) -> UsageWindow? {
        if let windowID, let picked = windows.first(where: { $0.id == windowID && $0.usedPercent != nil }) {
            return picked
        }
        return headlineWindow
    }

    public func headlinePercent(preferring windowID: String?) -> Double? {
        headlineWindow(preferring: windowID)?.usedPercent
    }
}

// MARK: - Errors

public enum ProviderError: LocalizedError, Sendable {
    case notConfigured(hint: String)
    /// The credential exists but macOS wants the user's permission before
    /// this app may read it (Claude Code's keychain item).
    case needsAuthorization(hint: String)
    case unauthorized
    case rateLimited
    case http(Int)
    case badResponse
    case network(String)

    public var errorDescription: String? {
        switch self {
        case let .notConfigured(hint):
            return L10n.t("Not configured. \(hint)", "尚未配置。\(hint)")
        case let .needsAuthorization(hint):
            return L10n.t("Needs your permission. \(hint)", "需要授权。\(hint)")
        case .unauthorized:
            return L10n.t(
                "Session expired — sign in again with the provider CLI or update the credential in Settings.",
                "会话已过期 —— 请重新用服务商 CLI 登录，或在设置中更新凭据。")
        case .rateLimited:
            return L10n.t(
                "Rate limited by the provider. Try again in a few minutes.",
                "被服务商限流，请几分钟后重试。")
        case let .http(code):
            return L10n.t("Provider returned HTTP \(code).", "服务商返回 HTTP \(code)。")
        case .badResponse:
            return L10n.t("Provider response could not be parsed.", "无法解析服务商返回的数据。")
        case let .network(message):
            return L10n.t("Network error: \(message)", "网络错误：\(message)")
        }
    }
}

// MARK: - Provider protocol

public protocol QuotaProvider: Sendable {
    var id: ProviderID { get }
    /// Whether the required credentials can be resolved right now.
    func isConfigured(config: ConfigStore) -> Bool
    func fetch(config: ConfigStore) async throws -> UsageSnapshot
}

// MARK: - Formatting helpers

public enum QuotaFormat {
    /// "2h 14m", "3d 2h", "45m", "20s"
    public static func countdown(to date: Date, from now: Date = .now) -> String {
        let interval = date.timeIntervalSince(now)
        guard interval > 0 else { return L10n.t("now", "已重置") }
        let total = Int(interval)
        let days = total / 86_400
        let hours = (total % 86_400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return L10n.t("\(days)d \(hours)h", "\(days) 天 \(hours) 小时") }
        if hours > 0 { return L10n.t("\(hours)h \(minutes)m", "\(hours) 小时 \(minutes) 分") }
        if minutes > 0 { return L10n.t("\(minutes)m", "\(minutes) 分钟") }
        return L10n.t("\(total)s", "\(total) 秒")
    }

    /// "39m", "2h 14m", "5d 17h" — the compact form for the notch strip.
    ///
    /// Not `countdown`, which returns a localised phrase ("5 天 17 小时"). The
    /// strip has roughly 60pt per side between the notch and the menu bar's own
    /// items; the Chinese form does not fit and would truncate mid-number.
    public static func tick(to date: Date, from now: Date = .now) -> String {
        let interval = date.timeIntervalSince(now)
        guard interval > 0 else { return "0m" }
        let total = Int(interval)
        let days = total / 86_400
        let hours = (total % 86_400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(total)s"
    }

    /// Full phrase for a window's reset time, in both languages.
    ///
    /// Composing this at the call site produced "resets in now" / "已重置后重置"
    /// once the reset moment had passed, because `countdown` already returns a
    /// complete phrase in that case.
    public static func resetLabel(to date: Date, from now: Date = .now) -> String {
        guard date > now else { return L10n.t("reset due", "已到重置时间") }
        return L10n.t(
            "resets in \(countdown(to: date, from: now))",
            "\(countdown(to: date, from: now))后重置")
    }

    /// "3 minutes ago" — how old a snapshot is.
    public static func age(of date: Date, now: Date = .now) -> String {
        let seconds = Int(max(0, now.timeIntervalSince(date)))
        if seconds < 60 { return L10n.t("just now", "刚刚") }
        let minutes = seconds / 60
        if minutes < 60 { return L10n.t("\(minutes)m ago", "\(minutes) 分钟前") }
        let hours = minutes / 60
        if hours < 24 { return L10n.t("\(hours)h ago", "\(hours) 小时前") }
        return L10n.t("\(hours / 24)d ago", "\(hours / 24) 天前")
    }

    public static func percent(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded.truncatingRemainder(dividingBy: 1) == 0
            ? "\(Int(rounded))%"
            : String(format: "%.1f%%", rounded)
    }

    public static func dollars(cents: Int) -> String {
        String(format: "$%.2f", Double(cents) / 100)
    }

    /// Grouped so a four-figure total stays readable ("$4,557.33").
    ///
    /// Built from a decimal formatter with the "$" prefixed by hand rather than
    /// `.currency`: the currency style inserts a space after the symbol in some
    /// locales ("$ 8.40"), and the amount is in dollars regardless of where the
    /// user is.
    public static func usd(_ value: Double) -> String {
        let magnitude = usdFormatter.string(from: NSNumber(value: abs(value)))
            ?? String(format: "%.2f", abs(value))
        return value < 0 ? "-$\(magnitude)" : "$\(magnitude)"
    }

    private static let usdFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.decimalSeparator = "."
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    /// "$13.4K" — fits a figure into the middle of a ring, where the full
    /// grouped form would not.
    public static func usdCompact(_ value: Double) -> String {
        switch abs(value) {
        case 1_000_000...: String(format: "$%.1fM", value / 1_000_000)
        case 10_000...: String(format: "$%.1fK", value / 1_000)
        case 1_000...: String(format: "$%.2fK", value / 1_000)
        default: usd(value)
        }
    }

    /// "8/26" — compact axis label for the daily chart.
    public static func shortDay(_ date: Date) -> String {
        shortDayFormatter.string(from: date)
    }

    private static let shortDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return formatter
    }()

    /// 1_234_567 → "1.2M", 51_578_900_000 → "51.6B".
    /// Token counts reach the billions over a month, so stopping at M prints
    /// unreadable figures like "51578.9M".
    public static func compact(_ count: Int) -> String {
        switch Double(count) {
        case 1_000_000_000_000...: String(format: "%.1fT", Double(count) / 1_000_000_000_000)
        case 1_000_000_000...: String(format: "%.1fB", Double(count) / 1_000_000_000)
        case 1_000_000...: String(format: "%.1fM", Double(count) / 1_000_000)
        case 1_000...: String(format: "%.0fk", Double(count) / 1_000)
        default: "\(count)"
        }
    }
}

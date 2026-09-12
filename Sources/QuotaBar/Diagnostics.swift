import AppKit
import SwiftUI
import Foundation
import QuotaCore

/// `QuotaBar --cost` — prints the real cost estimate as text.
///
/// The panel shows these numbers inside a chart; when they look wrong, this is
/// how you see the underlying figures (including how many duplicate rows were
/// discarded) without attaching a debugger to a menu-bar agent.
enum Diagnostics {
    /// `QuotaBar --windows` — dumps every window each enabled provider
    /// reports, with its length. Used to decide what a multi-meter menu-bar
    /// glyph should actually show.
    ///
    /// Terminates from inside the task rather than blocking the main thread;
    /// blocking in `applicationDidFinishLaunching` deadlocks the SwiftUI app.
    /// Opens the settings pane in a real window: `QuotaBar --settings-window`.
    ///
    /// `--settings-preview` shows layout but never material: glass and vibrancy
    /// are composited by the window server, so they exist only on screen. This
    /// is how you look at them without clicking through the menu bar, and it is
    /// also the only way to see the AppKit controls the renderer replaces with
    /// yellow placeholders.
    /// Held for the process lifetime. A local `NSWindow` has no owner under ARC
    /// — `makeKeyAndOrderFront` does not retain it — so without this the window
    /// is deallocated before it ever draws, and the app looks like it ignored
    /// the flag.
    @MainActor private static var debugWindow: NSWindow?

    @MainActor
    static func settingsWindow() {
        // After SwiftUI has finished building its scenes. Creating the window
        // from inside `applicationDidFinishLaunching` gets it ordered out again
        // as the MenuBarExtra scene comes up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { build() }
    }

    @MainActor
    private static func build() {
        // An accessory app is never activated as a side effect, and this one
        // wants to be looked at.
        NSApp.setActivationPolicy(.regular)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 840, height: 700),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.contentView = NSHostingView(rootView: SettingsView(store: UsageStore()))
        window.isReleasedWhenClosed = false
        // Floating, because the point of this flag is to look at the window:
        // activating an accessory process does not reliably outrank whatever
        // app happened to be frontmost.
        window.level = .floating
        // Not `center()` — it picks whichever screen is "main", which on a
        // multi-display Mac is routinely not the one you are looking at.
        if let screen = NSScreen.screens.first {
            let visible = screen.visibleFrame
            window.setFrameOrigin(NSPoint(
                x: visible.midX - window.frame.width / 2,
                y: visible.midY - window.frame.height / 2))
        }
        debugWindow = window
        window.makeKeyAndOrderFront(nil)
        // Same ordering rule as `SettingsWindow.focus()`: activating before the
        // window is on screen does nothing.
        DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
        FileHandle.standardOutput.write(Data("settings window: \(window.frame)\n".utf8))
    }

    static func printWindows() {
        Task { @MainActor in
            let config = ConfigStore.shared
            for id in config.enabledProviders {
                var out = "\n\(id.displayName)\n"
                do {
                    let snapshot = try await ProviderRegistry.make(id).fetch(config: config)
                    if let plan = snapshot.planName { out += "  plan: \(plan)\n" }
                    if let credits = snapshot.resetCredits {
                        out += "  resetCredits: \(credits.available)\n"
                    }
                    for window in snapshot.windows {
                        let length = window.windowSeconds.map { "\($0)s = \(WindowTitle.short($0) ?? "?")" }
                            ?? "(no fixed length)"
                        let percent = window.usedPercent.map { String(format: "%.0f%%", $0) } ?? "-"
                        out += "  [\(length)] \(percent)"
                        if let scope = window.scope { out += "  scope=\(scope)" }
                        if window.isActive { out += "  ACTIVE" }
                        out += "  — \(window.title)\n"
                    }
                } catch {
                    out += "  失败: \(error.localizedDescription)\n"
                }
                FileHandle.standardOutput.write(Data(out.utf8))
            }
            NSApp.terminate(nil)
        }
    }

    /// `--ledger`: the year-to-date ledger behind the usage pane, with the
    /// scan time — the first read of a big log tree is the number to watch.
    static func printLedger() {
        let started = Date()
        let ledger = CostEstimator.ledger()
        let elapsed = Date().timeIntervalSince(started)
        var out = "Scanned \(ledger.year) in \(String(format: "%.2f", elapsed))s\n"
        out += "Year     \(QuotaFormat.compact(ledger.total())) tokens over \(ledger.activeDays()) active days"
        out += "  (\(ledger.deduplicated) duplicates dropped)\n"
        for period in LedgerPeriod.allCases {
            let sum = ledger.sum(period)
            out += String(format: "%-8@ %@ tokens  %@  in %@ out %@ cache-read %@ cache-write %@\n",
                          period.rawValue as NSString,
                          QuotaFormat.compact(sum.tokens) as NSString,
                          QuotaFormat.usd(sum.usd) as NSString,
                          QuotaFormat.compact(sum.input) as NSString,
                          QuotaFormat.compact(sum.output) as NSString,
                          QuotaFormat.compact(sum.cacheRead) as NSString,
                          QuotaFormat.compact(sum.cacheWrite) as NSString)
        }
        for item in ledger.sources {
            out += "  \(item.source.displayName): \(QuotaFormat.compact(item.tokens)) tokens, "
            out += "\(ledger.activeDays(.source(item.source))) active days\n"
        }
        for item in ledger.models().prefix(10) {
            out += "    \(item.model) [\(item.source.displayName)]: \(QuotaFormat.compact(item.tokens))\n"
        }
        FileHandle.standardOutput.write(Data(out.utf8))
    }

    static func printCost() {
        // The panel refreshes this on its own cycle; the CLI has to ask.
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await PricingCatalog.shared.refreshIfNeeded()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 30)

        let started = Date()
        let cost = CostEstimator.summary()
        let elapsed = Date().timeIntervalSince(started)

        var out = ""
        let catalog = PricingCatalog.shared
        out += "Pricing: \(catalog.isLoaded ? "\(catalog.modelCount) models from catalog" : "built-in table only")\n"
        out += "Scanned in \(String(format: "%.2f", elapsed))s\n"
        out += "Today    \(QuotaFormat.usd(cost.todayUSD))  ·  \(QuotaFormat.compact(cost.todayTokens)) tokens\n"
        out += "30 days  \(QuotaFormat.usd(cost.windowUSD))  ·  \(QuotaFormat.compact(cost.windowTokens)) tokens\n"
        out += "Top model: \(cost.topModel ?? "—")\n"
        for period in SpendPeriod.allCases {
            let spend = cost.spend(period)
            out += "\n[\(period.displayName(windowDays: cost.windowDays))] "
            out += "\(QuotaFormat.usd(spend.usd))  \(QuotaFormat.compact(spend.tokens)) tokens\n"
            for item in spend.contributions {
                let kind = item.source.isEstimated ? "估算" : "自报"
                out += "    \(item.source.displayName) (\(kind)): \(QuotaFormat.usd(item.usd))\n"
            }
        }
        out += "Duplicate rows discarded: \(cost.deduplicated)\n"
        for (source, amount) in cost.windowBySource.sorted(by: { $0.value > $1.value }) {
            out += "  \(source.displayName): \(QuotaFormat.usd(amount))\n"
        }
        if let peak = cost.peakDay {
            out += "Peak: \(QuotaFormat.shortDay(peak.day)) \(QuotaFormat.usd(peak.usd))\n"
        }
        out += "\nDaily:\n"
        let scale = cost.daily.map(\.usd).max() ?? 1
        for day in cost.daily {
            let width = scale > 0 ? Int((day.usd / scale * 40).rounded()) : 0
            out += String(
                format: "  %@  %9@  %@\n",
                QuotaFormat.shortDay(day.day),
                QuotaFormat.usd(day.usd) as NSString,
                String(repeating: "█", count: width))
        }
        FileHandle.standardOutput.write(Data(out.utf8))
    }
}

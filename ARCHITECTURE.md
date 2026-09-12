# QuotaBar

macOS 14+ menu-bar app that shows how much of each AI coding provider's quota is
used and when each window resets. Swift 6 toolchain, SwiftUI `MenuBarExtra`, no
third-party dependencies.

- `Sources/QuotaCore` — provider protocol, HTTP/date helpers, config + keychain,
  credential readers, cost estimator, one file per provider group.
- `Sources/QuotaBar` — the SwiftUI app: usage store, menu-bar icon, panel,
  settings, notch island.
- `Tests/QuotaCoreTests` — everything testable lives in QuotaCore.

## Build

**A full Xcode toolchain is required.** CommandLineTools does not ship the
`SwiftUIMacros` plugin, so `@State` fails to expand and the build dies with
`external macro implementation type ... could not be found`.

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
swift build && swift test
./Scripts/package_app.sh   # builds QuotaBar.app in place, ad-hoc signed
```

`package_app.sh` signs with a Developer ID certificate when one is present
(hardened runtime + secure timestamp, which is what notarization requires) and
falls back to ad-hoc otherwise. `NOTARIZE=1` additionally submits to Apple and
staples the ticket; it needs a `notarytool` keychain profile. The script prints
the Gatekeeper verdict at the end — do not assume a build is distributable
because it compiled.

`Scripts/release.sh` wraps that into a full release (zip + SHA-256 + Homebrew
cask) and hard-fails if `spctl` still rejects the bundle — a build that only
works on the developer's own Mac must never ship.

Distribution is Developer ID only. The App Store sandbox forbids reading
`~/.codex` / `~/.claude` and other apps' keychain items, which is the entire
feature set, so `Resources/QuotaBar.entitlements` is deliberately empty and the
app runs unsandboxed.

`Scripts/dev.sh` runs the bare debug binary — fast, but there is no bundle, so
`Bundle.main.bundleIdentifier` is nil. Anything gated on a bundle (notifications,
`SMAppService`, `AppIcon.icns`) must degrade instead of trapping.

## Looking at the UI

```bash
.build/debug/QuotaBar --snapshot ./snapshots
```

Renders the panel off-screen to PNGs (both languages, four states) — the app is
a menu-bar agent, so there is no window to screenshot. CI runs this as a smoke
test. Two `ImageRenderer` limitations to read past; neither reflects the
running app:

- `ScrollView` contents are not laid out — panels render with `scrollable: false`.
- AppKit-backed controls (`.borderless` buttons, `ProgressView`, `Toggle`,
  `SecureField`) come out as yellow placeholder glyphs.

The settings window renders separately:

```bash
.build/debug/QuotaBar --settings-preview ./settings
```

One PNG per section, both languages, both appearances, plus one with a provider
expanded. Every `@State` in `SettingsView` is seeded from `init` rather than
`onAppear` precisely so this works — `ImageRenderer` runs outside a SwiftUI
update transaction and traps on a change queued from `onAppear`. Glass and
vibrancy are composited by AppKit and do not survive the renderer, so the
preview substitutes flat fills of the same metrics: read it for spacing,
alignment and truncation, and judge the material on screen.

## Rules

### Bilingual UI

Every user-visible string goes through `L10n.t("English", "中文")`. There is no
`.strings` bundle on purpose: `package_app.sh` assembles the app by hand and the
dev loop runs the bare binary, so a `Bundle.module` lookup would behave
differently between the two. Brand names (`ProviderID.displayName`) stay
untranslated.

### Changelog

Every change to the app itself (a feature, a visual change, a bug fix) gets a
line in `CHANGELOG.md`, in Chinese, under 未发布 and the day's date, in the
same commit or the one right after. A release moves those lines under its
version heading. Server moves, the site and build tooling are not recorded.

The log is also shown where people look: the "recent updates" blocks in
`README.md` and `README.zh-CN.md`, the home page's 更新日志 section and
`web/changelog.html` are generated from it, with the commit calendar in
`Assets/readme/`. After editing the changelog run
`python3 Scripts/sync_changelog.py` and commit what it rewrites;
`deploy_site.sh` runs it before every publish. Never edit between the
`<!-- changelog:start -->` markers by hand.

### Credentials

Manually entered tokens/cookies/API keys go to the **login keychain only**, via
`ConfigStore.setCredential`. Never write a secret to `config.json`; `QuotaConfig`
decodes a legacy `credentials` key purely to drain it into the keychain and
never encodes it back. Automatic providers (Codex, Claude, Gemini) read the
session the user's CLI already created — never prompt for a password. Claude's
item is read with `SecItemCopyMatching` first (dialog suppressed process-wide), and
when that would have asked, with `security find-generic-password -w`: Claude Code
writes the item with the same tool, so the item always trusts it, and the read is
silent regardless of this build's signature. The dialog is a last resort behind a
button. `QuotaBar --credentials` prints which read answered.

### Config decoding is per-field lenient

`decodeIfPresent` tolerates a *missing* key but throws on an unrecognised
value, which fails the whole file and silently resets every other preference.
Enum fields therefore go through `decodeEnum`, and `enabled` through
`decodeProviders`, which drops ids this build does not know rather than
discarding the list. This matters on downgrade: a newer build writes a style
or a provider an older one cannot parse. Covered by `ConfigResilienceTests`.

### Dictionaries keyed by an enum do not encode as objects

`Codable` flattens `[ProviderID: T]` into an array (`["codex", value, ...]`),
not an object. This already bit `config.json` and `history.json`. Key persisted
dictionaries by `String` and, if the file shipped before, keep a reader for the
old flat-array form.

### Window rows carry structure, not a sentence

A `UsageWindow` reports `windowSeconds` and `scope` separately from its
`title`. The UI renders the length as a badge ("5h", "7d") and the scope as the
only caption, so an account-wide window gets no caption at all — repeating
"whole account" on every row is filler. Providers that know the length must set
`windowSeconds`; `title` stays as the full label for accessibility and for rows
with no fixed length (balances, billing cycles).

### Provider parsing

Split every provider into a networking `fetch` and a pure `static parse(_ data:)`,
then pin the parser with a recorded response in `ProviderParsingTests`. Derive
window labels from what the API reports (`WindowTitle.forSeconds`) — never
hardcode "5-hour window"; the same field is a weekly window on other plans.
Scrub account identifiers out of recorded fixtures.

### Cost estimation

`CostEstimator` reads the CLIs' own session logs. Two things are easy to get
wrong and are covered by tests:

- **Deduplicate.** Claude Code writes the same assistant turn into every session
  file that replays it; over half the rows in a real tree are duplicates. Key on
  `(message.id, requestId)`.
- **Do not double-charge cached input.** Codex reports `input_tokens` inclusive
  of `cached_input_tokens`.

**Prices come from `PricingCatalog`, not the table in `Cost.swift`.** That
table is the offline fallback only. It prefix-matches, which is actively wrong
for models it has never seen: this developer's Codex usage is `gpt-5.6-sol`,
which matched `gpt-5` at $1.25/$10 against a real $4/$20 and understated that
provider threefold. The catalog matches exact ids (plus a date-stamp strip) and
never prefix-matches. Tests that pin the fallback must inject an empty catalog,
or they assert against whatever prices this machine happens to have fetched.

Anthropic charges 1.25x input for a 5-minute cache write and 2x for a 1-hour
one; the catalog publishes only the 5-minute figure, so the long one is derived.
When touching the fallback table, re-check numbers against the `claude-api`
skill rather than memory, and keep the most specific marker first (`sonnet-5`
before `sonnet`).

### Pace

`UsageWindow.pace()` needs no history: window length, reset time and the current
figure are enough. Note that "will exhaust before reset" and "is ahead of pace"
are the *same predicate* under linear extrapolation — the algebra reduces to
`used > 100 * elapsed / length`. Both names are kept because one reads better,
not because one is stricter; `WindowPaceTests` pins the equivalence so nobody
later treats them as different signals.

**The scan is over tens of gigabytes.** A real Codex tree measured 30GB across
112 files, next to 1GB of Claude logs — and the rows that matter are 0.2% of
those bytes. The hot path therefore never builds a `String` per line: it scans
raw bytes with `memchr`/`memmem` and only materialises `Data` for lines that
match. Codex records are matched on the first 8KB only (its `type` field sits
near the start); Claude's must be searched in full because `usage` comes after
the message content. Files are parsed in parallel, largest first. Together these
took a cold scan from 278s to 36s — do not undo them casually, and re-measure
with `QuotaBar --cost` if you touch the scanner.

`ChunkBoundaryTests` exists because every other fixture in the suite is a few
hundred bytes and never crosses a read block. Keep it.

Results are memoised in memory by (path, mtime, size), so steady-state refreshes
are free — but the cost is paid again on every launch. A persistent cache is the
remaining win if that matters.

### Staleness is never silent

A failed refresh keeps the previous numbers as `.stale(snapshot, error:)`, which
renders a banner. Do not collapse it back into `.loaded` — that is how a user
ends up trusting a figure from an expired session.

### Updating

`Updater` downloads a release, verifies it, and only then swaps the bundle.
**Verification is the point of the feature.** An updater that installs what it
downloaded is a remote-code-execution path, so a staged bundle is installed
only when `codesign` reports our own `TeamIdentifier` *and* `spctl` accepts it
(which covers notarization). This is stronger than a self-managed signing key —
an attacker would need the Developer ID certificate, not just the download URL.
`UpdateVerificationTests` builds a real unsigned bundle and asserts it is
refused; do not weaken that test into a stub.

Homebrew installs are detected via `/opt/homebrew/Caskroom/quotabar` and are
never replaced in place — doing so desyncs brew's metadata and the next
`brew upgrade` fights it. Those users are pointed at `brew upgrade` instead.

The feed is configurable: `owner/repo` means GitHub's releases API, anything
with a scheme is a JSON endpoint returning `{"version", "url", "notes"}`. A
malformed stored value falls back to the default rather than silently becoming
a feed that never resolves.

### Alternate presentations

Three surfaces beyond the menu bar, in `IslandWindow`, `EdgeDock` and
`DesktopWidget`. `presentation` picks at most one of the notch island and the
edge dock; the desktop widget is an independent toggle, since it sits alongside
the menu bar rather than replacing it — hence `widgetRevision` as its own
change signal.

Never resize one of these panels with `setFrame(_:display:animate:)`. It steps
the resize on a **blocking** run-loop loop — measured at 341ms of stalled main
thread for the dock's reveal, against 0.6ms for `animator().setFrame` inside an
`NSAnimationContext` — and it relayouts the hosting view on every step, so the
SwiftUI content cannot animate at all while it runs. The panel frame and the
content it holds must also share one clock (`EdgeDockCoordinator.slide`), or
the content swaps instantly and the frame catches up afterwards.

Two sources drive the dock's frame: the hover transition, and a `GeometryReader`
reporting the strip's measured height. The second used to land an un-animated
`setFrame` one layout pass into the first, cutting the reveal off partway — the
animation still completed, so it looked fine in a log and stuttered on screen.
The strip's height is *computed*, not measured — `n` rings, their gaps and the
padding. Measuring it meant the reveal began before the measurement existed, so
it animated toward a placeholder 200pt and was re-aimed to 332pt four
milliseconds later: two animations, to different y as well as different heights,
and the panel visibly changed course. `setContentHeight` now only corrects the
figure for next time and never re-aims mid-slide.

Two more things the reveal needs, both of which look like the animation fighting
itself when they are missing. The content is `.fixedSize()` and pinned to the
docked edge, so the panel growing around it *reveals* it rather than laying it
out again on every frame — otherwise the four rings are squeezed into the
handle's 92pt at the start and relax over the next 240ms. And the black is one
shape owned by the container, not one per state: cross-fading a small black
capsule through a large black panel reads as two shapes arguing over the same
corner. The radius is clamped to the shape it is drawn in, so a single 20pt
value is the panel's corner at 74pt wide and the handle's pill edge at 18.

`QUOTABAR_DOCK_TRACE=1` logs every frame request and decision;
`QUOTABAR_DOCK_SLIDE=2` stretches the reveal, because at 0.24s a screen capture
lands either side of it and never in the middle. Both are how the above was
found rather than guessed at.

`DockSlide.decide` is the rule that fixed the interruption and is pinned by
`DockSlideTests`: re-applying the frame already pending is a no-op, a hover
transition animates, and anything else snaps. Compare against the *pending*
frame, never `panel.frame` — mid-slide that reports an in-between value and
never compares equal.

There is deliberately no mid-slide case. A slide is never re-aimed, because
re-aiming four milliseconds in is a second animation rather than a correction;
`setContentHeight` holds content-driven resizes until the slide finishes
instead. The cost is that a provider toggled during the 240ms reveal leaves the
strip its old height until the next one. Do not "fix" that by letting a resize
join the slide — that policy and the hold contradict each other, and whichever
runs first makes the other unreachable.

Two more rules these share. Floating panels that show information beside
something else (the dock's hover callout) get their own panel with
`ignoresMouseEvents = true`: widening the host panel to contain them leaves a
transparent region that swallows clicks meant for the window underneath.
Positions are stored as fractions of `visibleFrame`, clamped on both read and
write, so a resolution change or a hand-edited config cannot park a panel
off-screen.

In the dock, a **single click picks** which provider the menu-bar glyph reports
and a **double click opens** the panel. A single click used to do both, so
choosing what the icon means also threw a window at you. The pick needs to be
visible, hence `ProviderRing.selected` — drawn with negative padding so the
marker is larger than the cell without changing its size, since the dock
computes its own height from `cellHeight` and a taller cell desyncs the panel.
The two-tap gesture must be attached *before* the one-tap: SwiftUI resolves the
higher count first only in that order.

The desktop widget defaults to desktop level — above the icons, below every
window. Floating it over the user's work is a different and more intrusive
thing, so it is opt-in.

### The usage ramp

`UsageRamp.hex(used:)` is the one place a usage percentage becomes a colour on
the always-dark surfaces — the dock's rings and handle, the desktop widget, the
notch strip, the hover callout. It replaced a three-step green/amber/red mapping
that had been copied into six views, plus a seventh copy in the snapshot
renderer with `80` and `95` written into it while every other copy read the
user's own thresholds.

**Anchored to fixed percentages, not to `AlertSettings`.** Colour answers "how
hot am I" and has to mean the same thing on two machines and in two
screenshots; the thresholds answer "interrupt me" and keep driving
notifications and the menu-bar glyph's monochrome/tinted gate. Binding the two
together made one number two colours depending on a setting.

Nine stops five points apart spanning 50→90, flat outside that, with straight
sRGB mixing in between. Mixing sRGB across the *whole* green→red span would cut
through the neutral axis and go muddy at the midpoint; across one 5pt step the
worst departure from the continuous OKLCH path is ΔE00 ≈ 1.6, under the ~2.3
just-noticeable difference. Ten-point stops break 3 and band visibly.

Three properties are load-bearing and each has a test:

- **Relative luminance falls the whole way**, 0.423 → 0.167. That is the
  "deeper" the ramp was asked for, and it is the only channel a red-green
  colourblind viewer keeps — a hue sweep alone is the classic failure case.
  Between stops the fall is not quite strict: rounding to 8 bits per channel
  puts a ~4.2e-3 ceiling on a reversal, so the test allows 0.005 rather than
  asserting strict monotonicity. The cause is rounding and nothing subtler.
- **Every colour clears 4.3:1 on black and 3.4:1 on the panel.** The ring's
  own track is a different matter: white at 14% over the disc fill composites
  to `#353535`, and the red end sits at 2.54:1 against it. Left alone
  deliberately — dimming the track to win that ratio would weaken the arc-length
  channel, which is the more reliable one, and WCAG contrast is a
  luminance-only metric that understates a saturated red against a neutral grey.
  The boundary carrying the reading is arc against panel.
- **The colour keys off used percent, never the displayed figure.** The dock
  handle fills by `MeterMode`, so in remaining mode a long bar means plenty
  left. Hand the ramp `shownPercent` and a nearly-empty quota draws full and
  green. There is no `Optional` overload either: no reading is not 0% used, and
  0 is the brightest green on the scale — call sites guard and keep their own
  neutral.

The middle of the ramp is olive (`#A8A81E` at 65%). Any ramp whose luminance
falls the whole way has to pass through it: sRGB's chroma ceiling in the yellow
band is 0.135 against the 0.194 the ends carry. Avoiding it needs a luminance
bump at yellow, which is the opposite of "deeper". Do not "fix" the dip.

The menu panel and the menu-bar glyph deliberately stay on the discrete levels.
The panel's bars fall back to the *provider's brand colour* below the warning
threshold rather than to green, which is a different mapping; and the glyph is
monochrome until a threshold on purpose, because the menu bar is shared space.
`--snapshot` writes `usage-ramp.png` for inspecting the ramp itself.

### The wordmark

The word "QuotaBar" is set in Sora; everything else stays on the system face,
which is what a macOS app should read as. The font ships inside the bundle —
`Sources/QuotaBar/Resources/fonts`, copied by `package_app.sh`, declared by
`ATSApplicationFontsPath` in Info.plist — because it is not a system font and
assuming it is installed would mean the wordmark silently differs per machine.

`Design.wordmark` is the only call site. `Font.custom` falls back to the system
font on its own when the family is not registered, which is what the dev loop
gets: a bare binary has no bundle to register a font from, so the snapshots
render the fallback and that is correct rather than broken.

Sora is SIL OFL 1.1, so `OFL.txt` ships beside it — the licence requires the
font to travel with its text. The copyright line came out of the font's own
name table rather than from memory.

### Design tokens

Spacing, radii and surfaces come from `Design` in `DesignTokens.swift`. Radius
tiers are deliberate (tile / card / panel); do not flatten them. Cards use a
fill **or** a border, never both, and no gradients or glassmorphism.

The accent is a neutral graphite **and inverts between appearances**
(`QuotaTheme.accentHex` / `accentDarkHex`): a dark selection block sinks into a
dark window, so dark mode gets a light block with dark ink. It is neutral on
purpose — the panel already carries thirteen provider brand colours and a fourteenth
competing hue makes none of them legible. `QuotaBar --theme-preview <dir>`
renders the panel across candidate accents if it ever needs revisiting.

The glyph reports whichever provider the panel is focused on — `selected` in
the config, persisted, because it decides what the icon means and a choice that
reset on every launch would change that silently. An unknown or since-disabled
id falls back to the overview, which aggregates across everything enabled.

The glyph is driven by a `MeterReading`, not one number: quota windows split
into a **short** horizon (under a day — 5-hour, rolling) and a **long** one (a
day or more, plus billing cycles with no fixed length), each taking the highest
reading across enabled providers. `dual` draws them as two stacked rows and is
the default; every other style collapses them to `headline` (the higher of the
two). Collapsing hides which limit is actually near — a real account here reads
31% short against 100% long, and a single meter shows only the 100%.

A plan may report just one horizon (a Codex Pro account has no 5-hour window),
so `dual` falls back to a single centred row rather than drawing an empty one,
which would read as "nothing left".

Nine menu-bar glyphs live in `MenuBarIcon`. Four of them are *stepped*
(`dual` 5, `segments` 5, `grid` 9, `columns` 4) and declare it via
`MenuBarStyle.steps`: their gradations are countable, so the reading is exact
rather than estimated off a continuous fill.

Prefer linear gradations. A 3x3 `grid` is the most distinctive glyph but the
least readable: proportion along one axis is preattentive, while a grid has to
be counted in two dimensions. Ten segments were also tried and are worse than
five — at 22pt each cell falls to ~2pt and a filled cell stops being
distinguishable from an outlined one, so the finer gradations bought nothing. A stepped glyph
lights a cell only once its step is fully reached — except that any non-zero
value lights the first cell, or 1% and 0% look identical. **Unlit cells are
drawn as outlines, never as a faint fill**: alpha alone stops distinguishing
them once the glyph is tinted for an alert, and an exhausted quota then looks
identical to a full one. `QuotaBar
--icon-preview <dir>` renders every style across nine levels plus the Settings
picker, in both appearances.

Opening Settings takes two steps, not one: `openSettings()` followed by
`SettingsWindow.focus()`. The call alone does create the window, but an
accessory app is never activated as a side effect, so it is ordered in behind
whatever the user was looking at and the menu just closes with nothing visible.
Activating *before* the window exists does nothing — hence the runloop hop.
The legacy `showSettingsWindow:` selector does not work here at all; do not
reach for it.

The panel does not scroll. Only the notch island does, because it lives in a
fixed-size floating `NSPanel`; a clipped menu-bar panel hides the numbers the
app exists to show.

**`MenuBarExtra(.window)` measures its popover once and never again.** That once
is the first render — before any provider has answered, when the detail section
is sitting on its 210pt floor — so the window is 418pt from then on, for every
provider, and reopening it does not re-measure. Real content runs 429pt to
624pt, so the `VStack` was permanently over-committed and drew the footer on top
of the last quota row. `MenuPanel.fit` pushes the measured height back into the
panel, found by level (`.popUpMenu` is the popover's own; the dock, island and
widget are `.statusBar`, Settings is `.normal`), anchored on the top edge
because a popover hangs from the menu bar.

Two things that look optional and are not. The content needs
`.fixedSize(horizontal: false, vertical: true)`: without it a `VStack` too tall
for its window overlaps its own children rather than overflowing, *and* the
measurement is circular — the window constrains the content, the content
reports the constrained height, and the resize is a no-op. And the request is
clamped to `visibleFrame.height`, since a panel taller than the screen is worse
than a short one.

Collapsed, the island is a **notch strip** on a notched Mac: the figures sit in
the dead space either side of the notch rather than in a pill beside it. The two
sides are mirrored — figure on the outer edge, mark against the notch — so the
pair reads outward from the middle. Only two providers fit, which is the notch's
constraint and not a choice: the strip has to clear the app's own menus on one
side and the status items on the other, hence the 132pt `sideWidth`. On a screen
with no notch (`safeAreaInsets.top == 0`, most external displays) it falls back
to the old centred pill — a strip built around a zero-width notch is just a bar
sitting on top of the menu bar's own items.

The strip shows a reset countdown next to each figure, via `QuotaFormat.tick`
rather than `countdown`: the latter returns a localised phrase ("5 天 17 小时")
that does not fit in 60pt and truncates mid-number.

The figure takes the provider's own `accentHex`, and that colour is **not**
lifted for contrast at draw time. Every accent is instead required to clear
4.5:1 against black, asserted in `ProviderRegistryTests` — an accent that has to
be altered to be readable is the wrong accent, and mutating it at runtime would
ship a colour nobody chose. (The near-black *logos* are a different problem, and
the one `ProviderGlyph`'s `tint` solves.)

Snapshots render light **and** dark (`-dark` suffix). Dark mode needs
`NSAppearance.performAsCurrentDrawingAppearance` — adaptive colours resolve
against the drawing appearance, which `ImageRenderer` does not inherit from the
SwiftUI environment. The menu panel's two variants now come out identical,
because the panel is dark in both (below). On macOS 27, `ImageRenderer` draws
AppKit-backed controls — `Toggle`, `TextField`, `ProgressView`, a disabled
`Button` — as a yellow "prohibited" placeholder rather than skipping them as
it did on 26; the layout is still readable, but the settings screenshot on
the site has to come from a real window now.

### The menu panel is always dark

Since 0.3.3 the popover no longer follows the system appearance: it is the
fourth always-dark surface after the dock, the island and the widget, and the
last one that was still adaptive. The mechanism is the pair the widget and the
island already use — `.environment(\.colorScheme, .dark)` on the root, so
everything SwiftUI draws (`Color.primary` fills, the adaptive accent, the
material) resolves dark — plus `PanelAppearance`, which pins the *window's*
`NSAppearance` to `darkAqua` from `viewDidMoveToWindow`. The second half
matters: the popover's rounded corners and the vibrancy under the content are
AppKit's, drawn in the window's own appearance, and black content in a light
window leaves a light hairline round the corners.

The palette is the app's own dark family — `Design.panelSurface` is black,
like the sidebar and the dock, so the surfaces read as one — with one value
borrowed from CodexIsland (MIT): its alert amber `#F5A524` as
`Design.panelWarning`, replacing system orange for the warning dot, the
failure rows and the footer's "failed to update" line. It reads as amber
against black without adding a twelfth hue that competes with the provider
brand colours. The settings window keeps its adaptive tokens; nothing there
changed.

### The dock stays black

Glass on the edge dock and its callout was tried during 0.4 and taken out
the same day. Measured over a white window, `.regular` glass with a 70%
black tint rendered at 74% white (RGB 189) — `tint` colours the glass, it
does not cover it; a 62% ink fill laid over the glass got the strip down to
RGB ~53 but it still read as translucent grey, and the owner's call was
"不要透明的，需要黑色的". The dock and the callout are flat `Color.black`,
and the strip forces `.environment(\.colorScheme, .dark)` so nothing inside
it resolves against the system appearance.

Two dock fixes from the same session: `setDockEdge` / `setDockAlwaysVisible`
used to "nudge" the coordinator by re-assigning `presentation` to itself,
which `onChange` ignores — the strip mirrored its corners for the new edge
and the window stayed on the old one. `dockRevision` is the real signal, and
`EdgeDockCoordinator.relayout()` snaps the window (and re-sides the callout)
when it changes.

### 0.4: the menu-bar item is a status item, and there is no dropdown

The popover is gone. A click on the menu-bar item opens the settings window;
a secondary click (right or control) shows 刷新 / 设置… / 退出. The item is an
AppKit `NSStatusItem` (`StatusItemCoordinator`) because SwiftUI's
`MenuBarExtra` can only hang a menu or a popover off its primary click.

That took the app off the SwiftUI `App` lifecycle altogether. The half-way
house — an `App` whose only scene was `Settings { EmptyView() }` — showed
that scene's window at launch: a 45×233pt empty window titled "QuotaBar
Settings", because SwiftUI presents the settings scene when it is the only
one. `QuotaBarApp.swift` is now a plain `@main` `NSApplicationDelegate`
that owns the `UsageStore` and the coordinators; the settings window is
`SettingsWindow` (one `NSWindow` for the app's lifetime, `WindowChrome` still
dresses it), and the `openSettings` environment action is gone from every
call site.

The status item has one measured quirk. Created synchronously inside
`applicationDidFinishLaunching`, its window existed but was never placed —
frame (0, 0, 38, 0), nothing drawn, no status menu bar in the accessibility
tree — while a 30-line AppKit app doing the same thing was placed at once.
Creating it one turn later works, and `install(store:attempt:)` re-checks
after 1.5s and rebuilds the item once if the window is still zero-height.
The cause was not run down; the self-check is the guarantee. (Accessibility
reports "1 menu bar" for this process even when the item is on screen, so
`count of menu bars` is not a usable check — the button's window frame is.)

Also in this pass: the dock has the same three-item context menu, the
selected ring is marked by a short white bar on the strip's inboard side
(the halo round the ring and the block behind ring-plus-figure both read
as decoration), the strip's vertical insets are 18/14 to make the visible
margins even, and the callout heads with the provider name, a plan chip
("PRO", "MAX 20X" — Claude's tier comes from `rateLimitTier` in Claude
Code's own keychain item) and the account when the provider reports one.

### The settings window

It is the one surface that opts into Liquid Glass, and the only place the
project's "a fill *or* a border, never both" rule is broken — a glass edge is
what separates a translucent card from the translucent thing behind it.

Scope is deliberate. The menu panel, the edge dock, the notch island and the
desktop widget stay on the flat `Design` surfaces: they sit over arbitrary
wallpaper and have to carry their own contrast, so glass there would put the
user's desktop behind the numbers the app exists to show. A settings window is
always in front of its own backdrop, so it can afford it.

`glassEffect` is macOS 26; the deployment target is macOS 14. Every call site
goes through `glassSurface` / `glassGroup` / `glassAction` in `GlassStyle.swift`
rather than scattering `if #available` through the layout — below 26 they fall
back to a frosted material with the same metrics, so nothing shifts.

Navigation is a sidebar, not a tab bar. Two tabs meant eleven preferences that
were not providers shared one scrolling `Form` in a 560pt window, and nothing
was findable.

The window is one surface: a black sidebar running the full height, and an
opaque light-grey pane beside it. Two things are load-bearing there.

`NSHostingView` honours the window's safe area, and a `fullSizeContentView`
window's safe area *excludes* the titlebar — so the content began 28pt down and
the window's own background showed through above it as a second bar across the
top of the pane. `.ignoresSafeArea()` on the settings root is what fills it. The
window's `backgroundColor` is also black, so if AppKit ever leaves a strip
uncovered again it reads as sidebar rather than as a title bar.

The traffic lights need two more things once the content fills the window, and
both were found by dumping the window's view tree rather than guessing — three
rounds of plausible-sounding guesses (the safe area, `titleVisibility`, raising
the button's own superview) all missed.

The buttons are never hidden. The runtime reported
`hidden=false alpha=1.0 frame={{9,6},{14,16}}` while nothing was on screen: they
were *covered*. A window's theme frame lists its children back to front, and it
read `["NSTitlebarContainerView", "AppKitWindowHostingView<…>"]` — the hosting
view sat above the titlebar. Raising every sibling that is not the content view
puts it back, and it has to be **deferred one runloop turn**, because
`viewDidMoveToWindow` fires while the view is still being installed and SwiftUI
re-raises its own view afterwards.

Raising the container brings its backdrop with it, which is a lighter strip over
the content — the same band by another route. Inside is
`NSTitlebarView → NSTitlebarBackgroundView → NSVisualEffectView`, and the three
`_NSTheme*Widget` buttons are siblings of `NSTitlebarBackgroundView`, not
children. So hiding that one view removes the strip and keeps the buttons.
Matching a private class name is deliberate and fails safe: a rename brings the
strip back, not a crash.

`titleVisibility = .hidden` is *not* used — on macOS 26 it collapses the whole
titlebar and takes the buttons with it. `title = ""` empties the label and
leaves the titlebar in place.

The pane is a flat fill, not an `NSVisualEffectView`. Vibrancy there bought a
faint desktop tint under the glass and cost the seam above.

The sidebar is an always-dark surface, so its colours are pinned rather than
adaptive — `Color.primary` and `Design.accent` resolve against the *system*
appearance and both go black-on-black in light mode, the same trap as the
provider logos.

Selection is `SidebarRail`, not a filled block: a hairline rail with a lit
segment that travels to the selected row. Three layers make it read as light
rather than as a painted tick — the rail and the segment both faded out at
their ends, a blurred bloom, and a horizontal bleed feathered on all four
sides. Drop any one and the effect collapses into a rectangle. The rail is
drawn once for the whole list and sits *behind* the rows so the bleed falls
under the label; it cannot belong to a row, since travelling between them is
its whole job. The travel is a spring with visible overshoot, because the
original is `cubic-bezier(0.37, 1.95, 0.66, 0.56)` and the 1.95 *is* the
overshoot — a timing curve would only approximate it.

Providers are an accordion, one open at a time. That is not only about the
length of the list: the expanded row is what constructs `CredentialEditor`, and
building it *is* the keychain read. Opening the window costs zero lookups
instead of eleven, and the read that does happen is the direct result of a
click. Do not hoist that read back up into the list.

Controls come from `SettingRow` (fixed `Design.labelColumn`), `SettingToggle`
(switch at the far right, as macOS does it) and `GlassSegmented`. The segmented
control is ours rather than `.pickerStyle(.segmented)` because AppKit paints its
selection in the *system* accent, which fights the eleven provider brand colours
the rest of the app is careful to stay out of the way of.

### Credential sources

Six ways a provider gets its credential, in order of preference:

1. **CLI login file** — Codex (`~/.codex/auth.json`), Gemini, Grok, OpenCode Go
   (`~/.local/share/opencode/auth.json`), Antigravity
   (`~/.gemini/jetski-standalone-oauth-token`, read only: the app refreshes it
   while it runs, and refreshing it here would need the app's own OAuth
   client), read in the clear.
2. **Another app's keychain item** — Claude Code.
3. **Another app's local session store** — Cursor keeps its signed-in session
   in `state.vscdb`, a plain SQLite file (`SQLiteRead`). Not the cookie jar,
   which only holds the in-app browser's third-party cookies. The cookie
   cursor.com wants is `sub::JWT`, not the bare token — `sub` is a claim inside
   the JWT, and the composite is percent-encoded into the cookie.
4. **Manual paste** — the fallback for everything, stored in the keychain.

An automatic reader is always tried *after* a manually pasted credential, so a
user can override a stale local session. A provider that has both an automatic
reader and a manual fallback keeps its `credentialHint` non-nil.

There is no OAuth-in-app path: of the eleven providers only Google (Gemini)
permits third-party client registration, and it is already covered by the CLI
login file. Do not embed another CLI's `client_id`, and never a `client_secret`.

### The keychain dialog

Reading Claude Code's item (`Claude Code-credentials`) is the one keychain
access that can put up macOS's "wants to access your keychain" dialog, and the
rule is: **never from a timer, only from a button.** `LocalCredentials` probes
the item with user interaction switched off and reports `.needsAuthorization`
instead of prompting; `authorizeClaudeAccess()` — wired to "Allow keychain
access" in the panel and the settings row, and to "Test connection" — is the
only interactive read. Before this, the 60-second refresh re-raised the dialog
every minute for as long as the user kept declining.

What was learned getting there, all measured on macOS 27:

- The item's ACL is a list of trusted applications. "Always Allow" records
  the requesting app by its *designated requirement* when it is signed with a
  stable identity, and by **cdhash** when it is ad-hoc signed — and every
  rebuild is a new cdhash. The owner's item had accumulated 27 entries, 21 of
  them dead cdhashes for dev builds, one designated-requirement entry for the
  Developer ID build. Dev builds will always be re-asked; the release will not.
- The partition list (`teamid:…`) matters too and is set by the same dialog.
  Inspect both with `security dump-keychain -a ~/Library/Keychains/login.keychain-db`
  (attributes and ACL only; `-d` would dump secrets — never that).
- `kSecUseAuthenticationUI` does nothing for legacy login-keychain items; the
  switch that works is the process-wide `SecKeychainSetUserInteractionAllowed`.
  A read that would have prompted then returns in 9 ms with `errSecAuthFailed`
  (-25293), not the documented `errSecInteractionNotAllowed` (-25308); the
  mapping accepts both, plus `errSecUserCanceled` from a declined dialog.
- That function is deprecated since 10.10 with no replacement for this use,
  so it is bound through `dlsym` to keep the build at zero warnings. The
  switch is process-global; `KeychainUI.withoutPrompts` serialises callers
  and restores the previous value, which a test pins.

### Universal binary

`swift build` alone produces the host architecture. 0.3.2 shipped arm64-only
while the README promised Intel; `package_app.sh` now passes
`--arch arm64 --arch x86_64` (`UNIVERSAL=0` to skip). The macOS 27 toolchain
prints a deprecation notice for the x86_64 slice — informational, the slice
still builds and links.

## Adding a provider

1. Implement `QuotaProvider` in `QuotaCore/Providers/`, with a pure `parse`.
2. Add the `ProviderID` case: display name, SF Symbol, accent hex, dashboard
   URL, `credentialHint` (nil for automatic providers), `setupHint`. The symbol
   is asserted to resolve *and* to be locale-stable: an invented name renders as
   nothing (`braces` shipped for OpenCode Go; it is `curlybraces`), and SF
   Symbols localises a few marks — `textformat` draws the word "格式" in
   Chinese, which shipped as Kimi's fallback.
3. Register it in `ProviderRegistry.make`.
4. Drop a logo PNG at `Sources/QuotaBar/Resources/logos/<rawValue>.png` and keep
   the SVG master in `Assets/`.
5. Add a fixture test.

`ProviderRegistryTests` asserts every case has complete metadata, so a missing
piece fails the suite rather than shipping a blank tile.

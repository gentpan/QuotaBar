<div align="center">

<img src="Assets/icon.png" alt="QuotaBar" width="112" height="112">

# QuotaBar

**Every AI coding limit, in your menu bar.**

[![CI](https://github.com/gentpan/quotabar/actions/workflows/ci.yml/badge.svg)](https://github.com/gentpan/quotabar/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/gentpan/quotabar?color=6ee02b&label=release)](https://github.com/gentpan/quotabar/releases/latest)
[![macOS](https://img.shields.io/badge/macOS-14%2B-black)](https://github.com/gentpan/quotabar/releases/latest)
[![License](https://img.shields.io/badge/license-MIT-black)](LICENSE)

A menu-bar app that reads how much of each AI coding provider's quota you have
used and when each window resets. Eleven providers, no servers, no accounts.

[Download](https://github.com/gentpan/quotabar/releases/latest) ·
[Website](web/) ·
[Architecture](ARCHITECTURE.md)

</div>

---

## Install

```bash
brew tap gentpan/tap
brew trust gentpan/tap      # Homebrew 6 gates third-party taps
brew install --cask quotabar
```

Or download the `.dmg` from [Releases](https://github.com/gentpan/quotabar/releases/latest)
and drag `QuotaBar.app` into `/Applications`. Builds are signed with a Developer ID
certificate and notarized by Apple, so Gatekeeper opens them without a detour.

Requires macOS 14 (Sonoma) or later. Apple Silicon and Intel.

## Providers

| Provider | Source | Credential |
|---|---|---|
| Codex | `~/.codex/auth.json` OAuth → `chatgpt.com/backend-api/wham/usage` | automatic |
| Claude | Claude Code keychain item → `api.anthropic.com/api/oauth/usage` | automatic |
| Gemini | `~/.gemini/oauth_creds.json` → `cloudcode-pa.googleapis.com` | automatic |
| Grok | `~/.grok/auth.json` → `cli-chat-proxy.grok.com/v1/billing` | automatic / manual |
| Cursor | Cursor's own `state.vscdb` session → `cursor.com/api/usage-summary` | automatic / manual |
| OpenCode Go | `~/.local/share/opencode/auth.json` → `opencode.ai/zen/go/v1/usage` | automatic / manual |
| Kimi Code | `kimi.com` billing gateway | manual `kimi-auth` JWT |
| z.ai | `api.z.ai/api/monitor/usage/quota/limit` | manual API key |
| MiniMax | `api.minimax.io` coding-plan remains | manual token / cookie |
| Manus | `api.manus.im` credits | manual session token |
| DeepSeek | `api.deepseek.com/user/balance` | manual API key |

**Nothing leaves your Mac.** Automatic providers reuse the session your CLI already
created — the app never asks for a password. Manually entered tokens go to the **macOS
login keychain**, never to a file. Preferences live in `~/.config/quotabar/config.json`
(mode `0600`) and contain no secrets. There is no analytics, no telemetry and no server
of ours anywhere in the path.

**One dialog, once.** Claude is the only provider whose session lives in *another app's*
keychain item, so macOS asks before QuotaBar may read it. The app never raises that
dialog from a background refresh — only from the **Allow keychain access** button in the
panel or in Settings. Choose **Always Allow** and it stays quiet. (Unsigned development
builds are asked again after every rebuild: macOS remembers them by code hash, not by
identity. The notarized release is remembered by identity.)

## What it does

**In the menu bar**
- Eleven glyph styles, four of them *stepped* — the gradations are countable, so the
  reading is exact rather than estimated off a continuous fill.
- The glyph splits into a **short** horizon (5-hour, rolling) and a **long** one (weekly,
  billing cycles), because collapsing them hides which limit is actually near.
- It reports whichever provider the panel is focused on; pick Overview to aggregate.

**In the panel**
- Per-window percent bars with absolute numbers, reset countdowns, and a badge for the
  window currently governing requests.
- **Pace**: window length, reset time and the current figure are enough to say "runs out
  in 2d 13h" without any history.
- Trend sparkline per provider.
- Local spend estimate for Claude Code, Codex CLI and OpenCode — today and a trailing
  30 days, a per-day bar chart with the peak called out, the model most of the money went
  to, and a split per CLI.
- **Stale data is labelled.** A failed refresh keeps the last good numbers and says how
  old they are, rather than silently serving a reading from an expired session.

**Elsewhere on screen**
- A **notch strip** on notched Macs: the figures sit in the dead space either side of the
  notch, mirrored, each with a reset countdown.
- An **edge dock** that hides itself until the pointer reaches the screen edge.
- A **desktop widget** that sits above the icons and below your windows.

**Housekeeping**
- Auto refresh (1/2/5/15/30 min), plus refresh on wake and on network recovery.
- Threshold notifications, edge-triggered so a steady 90% does not spam.
- In-app updates from GitHub or a JSON feed you host — installed **only** if the download
  is signed by this app's developer and notarized by Apple.
- Bilingual UI (English / 简体中文), following the system language by default.

## Build & run

Requires macOS 14+ and a **full Xcode toolchain** — CommandLineTools alone lacks the
SwiftUI macro plugin, so the build fails on `@State`.

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
swift build && swift test
./Scripts/package_app.sh   # builds QuotaBar.app in place
open QuotaBar.app
```

The app is a menu-bar agent, so there is no window to screenshot. Render the surfaces
off-screen instead — CI runs the first two as smoke tests:

```bash
.build/debug/QuotaBar --snapshot ./snapshots         # panel, dock, notch strip
.build/debug/QuotaBar --settings-preview ./settings  # every settings section
.build/debug/QuotaBar --icon-preview ./icons         # all eleven menu-bar styles
```

Glass, vibrancy and springs only exist on screen — `ImageRenderer` draws none of them.
For those, open the real thing:

```bash
.build/debug/QuotaBar --settings-window
QUOTABAR_DOCK_TRACE=1 QUOTABAR_DOCK_SLIDE=2 ./QuotaBar.app/Contents/MacOS/QuotaBar
```

## Distribution

Developer ID only, not the App Store — the sandbox forbids reading `~/.codex`,
`~/.claude` and another app's keychain item, which is the entire feature set.

`package_app.sh` picks its signing tier automatically:

| What you have | What others get |
|---|---|
| Nothing | Ad-hoc signature — runs on your Mac only. Others see *"QuotaBar is damaged"*. |
| Developer ID certificate | Hardened runtime. Others see *"Apple cannot check it for malicious software"*. |
| Certificate + notarization | Gatekeeper accepts it — the normal *"downloaded from the internet"* prompt. |

Store a notarization credential once (needs an
[app-specific password](https://appleid.apple.com)):

```bash
xcrun notarytool store-credentials QuotaBar \
  --apple-id you@example.com --team-id <YOUR_TEAM_ID>
```

### Cutting a release

```bash
./Scripts/release.sh
```

Notarizes, staples, zips with `ditto` (which preserves the ticket), builds a signed and
notarized `.dmg`, computes both SHA-256s, and writes a ready-to-commit Homebrew cask to
`dist/quotabar.rb`. It **refuses to produce a release if Gatekeeper still rejects the
bundle**, so a half-signed build cannot reach users by accident.

## First run

1. Open Settings → **服务商 / Providers** and enable what you use.
2. Automatic providers need the matching CLI signed in (`codex`, `claude`, `gemini`,
   `grok`) or the app running (Cursor).
3. Manual providers: paste the token described under each row, then use **Test
   connection** — it bypasses every cache and asks the source directly.

Upgrading from a build that stored credentials in `config.json`? They are moved into the
keychain on first launch and erased from the file.

## Spend estimates

Computed locally from `~/.claude/projects/**/*.jsonl`,
`~/.codex/sessions/**/rollout-*.jsonl` and OpenCode's own database, priced from a live
catalog that matches exact model ids. They are an estimate for orientation, **not a
bill** — they cannot see plan-included usage, discounts, or anything that happened
outside these CLIs.

Two things are easy to get wrong here and are pinned by tests: Claude Code writes the
same assistant turn into every session file that replays it (deduplicated on
`message.id` + `requestId`), and Codex reports `input_tokens` inclusive of
`cached_input_tokens` (not double-charged).

## Architecture

- `Sources/QuotaCore` — provider protocol, HTTP/date helpers, config + keychain store,
  credential readers, cost estimator, pricing catalog, updater, one file per provider
  group.
- `Sources/QuotaBar` — the SwiftUI `MenuBarExtra` app: usage store, menu-bar glyph,
  panel, settings, notch island, edge dock, desktop widget.
- `Tests/QuotaCoreTests` — parser fixtures, cost regressions, config migration, updater
  verification. Everything testable lives in QuotaCore.
- `web/` — the marketing site. Static, no build step.

Adding a provider, and every design decision worth knowing before changing one:
[ARCHITECTURE.md](ARCHITECTURE.md).

## Credits

A clean-room Swift implementation, inspired by
[steipete/CodexBar](https://github.com/steipete/CodexBar) (MIT).
Provider brand marks via [GLINCKER/thesvg](https://github.com/GLINCKER/thesvg); SVG
masters kept in `Assets/logos-src-*.svg`. The wordmark is set in
[Sora](https://github.com/sora-xor/sora-font) (SIL OFL 1.1).

QuotaBar is an independent third-party app. It is not affiliated with, endorsed by, or
sponsored by OpenAI, Anthropic, Cursor, Google, xAI, or any other provider it displays.
Trademarks belong to their respective owners.

## License

MIT — see [LICENSE](LICENSE).

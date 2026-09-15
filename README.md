<div align="center">

<img src="Assets/icon.png" alt="QuotaBar" width="112" height="112">

# QuotaBar

**Every AI coding limit, at a glance — in the menu bar, the notch, at the screen's edge or on the desktop.**

[![Release](https://img.shields.io/github/v/release/gentpan/QuotaBar?color=6ee02b&label=release)](https://github.com/gentpan/QuotaBar/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/gentpan/QuotaBar/total?color=6ee02b&label=downloads)](https://github.com/gentpan/QuotaBar/releases)
[![Stars](https://img.shields.io/github/stars/gentpan/QuotaBar?style=flat&color=f5c518&label=stars)](https://github.com/gentpan/QuotaBar/stargazers)
[![Last commit](https://img.shields.io/github/last-commit/gentpan/QuotaBar?color=black&label=last%20commit)](https://github.com/gentpan/QuotaBar/commits/main)
[![Commit activity](https://img.shields.io/github/commit-activity/m/gentpan/QuotaBar?color=black&label=commits)](https://github.com/gentpan/QuotaBar/graphs/commit-activity)
[![CI](https://github.com/gentpan/QuotaBar/actions/workflows/ci.yml/badge.svg)](https://github.com/gentpan/QuotaBar/actions/workflows/ci.yml)
[![macOS](https://img.shields.io/badge/macOS-14%2B-black)](https://github.com/gentpan/QuotaBar/releases/latest)
[![License](https://img.shields.io/badge/license-MIT-black)](LICENSE)

QuotaBar is a macOS menu-bar app that shows how much of each AI coding service's quota
you have used, when each window resets, and roughly what it has cost — for twenty-three
providers, read and worked out on your own Mac. No account, no telemetry.

[Download](https://github.com/gentpan/QuotaBar/releases/latest) ·
[Website](https://quota.bar) ·
[Changelog](CHANGELOG.en.md) ·
[Architecture](ARCHITECTURE.md)

**English** · [简体中文](README.zh-CN.md)

</div>

---

## Install

```bash
brew tap gentpan/tap
brew trust gentpan/tap      # Homebrew 6 gates third-party taps
brew install --cask quotabar
```

Or download the `.dmg` from [Releases](https://github.com/gentpan/QuotaBar/releases/latest)
and drag `QuotaBar.app` into `/Applications`. Builds are signed with a Developer ID
certificate and notarized by Apple, so Gatekeeper opens them without a detour.

Requires macOS 14 (Sonoma) or later. Apple Silicon and Intel. The interface is in
English and Simplified Chinese and follows the system language unless you pick one.

## Recent updates

<!-- changelog:start -->
<!-- Generated from CHANGELOG.en.md by Scripts/sync_changelog.py. Do not edit by hand. -->

Latest release **0.5.6** (2026-09-16) · [full changelog](CHANGELOG.en.md)

<details open>
<summary><b>2026-09-16</b> · 0.5.6 · 12 style · 3 fixed</summary>

**Style**

- On the island's overview page the Share usage card button moves to the top right corner as the share icon alone; nothing sits under the spend bars.
- The island overview's spend bars per tool are stepped, like the quota page's; with three tools the bars and gaps are a little shorter, so the panel stays the same height.
- In the open island the quota tiles and the usage page's figures sit about 2pt lower, a little further from the provider's title and closer to the footer rule, so the blank above and below them is about even; the panel keeps its height.
- Usage and spend split by tool now say "Codex" rather than "Codex CLI", OpenAI's own name for it.
- The website, GitHub, X and email links in Settings → About drop their names and arrows: the icon and the address, nothing more.
- The Quota Run settings page's subtitle uses the same word for records as the rest of the page (Chinese only).
- Every segmented switch in Settings is sized by how many options it holds, 100pt each, so the switches in a card line up; a longer label, as in English, widens its switch to fit instead of being cut off.
- Check now in Settings → Updates is an outlined button like Refresh now; the filled style is kept for steps that change something, such as installing, saving or signing in.
- The acknowledgements list in Settings → About drops its arrows, like the links above it.
- The Closest to the limit desktop card lists from just under its title, rather than centring the list and leaving a gap above it.
- The open island shows the plan's own windows and leaves out a single model's limit such as GPT-5.3-Codex-Spark: Codex Plus shows its 5-hour and weekly bars, Pro its weekly bar alone, as codex-island does. A provider that only reports per-model limits still shows them.
- In the open island a provider with a single window, such as Codex Pro's week, has its bar across the whole column, ending where a pair of tiles ends; Ring and Numeric tiles sit against the left edge under the provider's title rather than centred.

**Fixed**

- The medium Ring gauge desktop card ran its account row about 23pt past the card's bottom edge; its ring and gaps are a little smaller at that size and everything fits.
- In the Provider grid desktop card a balance tile such as DeepSeek's was shorter than the quota tiles beside it; the balance now takes the percentage's size and the tiles match.
- The classic desktop widget and the edge dock's rings always showed used, against the remaining reading of the bars beside them and the menu bar; they now follow Fill basis in Appearance.

</details>

<details>
<summary><b>2026-09-15</b> · 0.5.6 · 1 added · 5 style · 1 fixed</summary>

**Added**

- With the island or the edge dock folded, a quota down to its last 15% makes the outline flash, brightening and dimming, as codex-island does: amber within 15%, red within 5%, and it stops once the quota refills. It goes by the whole percentage shown on screen and ignores the alert thresholds and the notification switch; with Reduce Animations on, the outline stays lit instead of flashing.

**Style**

- The open island no longer draws a halo, an orbiting light or a drop shadow round the panel, and its window is no bigger than the panel, so a window screenshot has no blank band at the sides and bottom; the folded island keeps its glow.
- "Synced N minutes ago" showed twice in the open island, at the top and again at the bottom; it is now bottom right only, with a new Refresh now button beside it that turns into a spinner and "Refreshing…" while it works. The page dots stay centred.
- The open island is one height throughout: switching between Bar, Stepped, Trend, Numeric and Ring, or between the Quota, Usage and Overview pages, no longer changes it. The height is set by the tallest content, about 26pt less than before, so there is no band of black under the bars; shorter styles are centred in it, which also moves the rings clear of the provider's title. The overview's spend bars and share button sit a little closer so three tools fit.
- The island's Trend style drops the "trend · last N refreshes" caption that crowded the reset line, and the line now follows the used-or-remaining switch, reading the same way as the figure and the bars.
- The QuotaBar wordmark at the top left of the open island has the app's mark before it, in the same white as the text.

**Fixed**

- Quitting now saves the local Quota Run records at once. A change used to be written five seconds later, and quitting within those five seconds lost it.

</details>

<details>
<summary><b>2026-09-15</b> · 0.5.5 · 1 style</summary>

**Style**

- The usage share card's address, bottom right, is Quota Run's: signed in to Quota Run with Sign it on, it is your profile, quota.run/@username; signed out it is quota.run alone with the signature before it, rather than a quota.bar/name address that leads nowhere. Signed in, the share window says which profile the card shows in place of the signature field.

</details>

<!-- changelog:end -->

## Activity

<p align="center">
  <img src="Assets/readme/activity.svg" alt="Commits per day over the last 26 weeks" width="760">
</p>

<p align="center">
  <a href="https://star-history.com/#gentpan/QuotaBar&Date">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=gentpan/QuotaBar&type=Date&theme=dark">
      <img alt="Star history" src="https://api.star-history.com/svg?repos=gentpan/QuotaBar&type=Date" width="760">
    </picture>
  </a>
</p>

## Providers

| Provider | Source | Credential |
|---|---|---|
| Codex | `~/.codex/auth.json` OAuth → `chatgpt.com/backend-api/wham/usage` | automatic |
| Claude | Claude Code keychain item → `api.anthropic.com/api/oauth/usage` | automatic |
| Gemini | `~/.gemini/oauth_creds.json` → `cloudcode-pa.googleapis.com` | automatic |
| Grok | `~/.grok/auth.json` → `cli-chat-proxy.grok.com/v1/billing` | automatic / manual |
| Antigravity | `~/.gemini/jetski-standalone-oauth-token` → `cloudcode-pa.googleapis.com` | automatic |
| Cursor | Cursor's own `state.vscdb` session → `cursor.com/api/usage-summary` | automatic / manual |
| OpenCode Go | `~/.local/share/opencode/auth.json` → `opencode.ai/zen/go/v1/usage` | automatic / manual |
| Kimi Code | `kimi.com` billing gateway | manual `kimi-auth` JWT |
| z.ai | `api.z.ai/api/monitor/usage/quota/limit` | manual API key |
| MiniMax | `api.minimax.io` coding-plan remains | manual token / cookie |
| Manus | `api.manus.im` credits | manual session token |
| DeepSeek | `api.deepseek.com/user/balance` | manual API key |
| Qwen Cloud | `home.qwencloud.com` console → token plan usage | manual Cookie header |
| GitHub Copilot | GitHub CLI sign-in (`gh auth token`) → `api.github.com/copilot_internal/user` | automatic / manual |
| 阿里云百炼 Coding Plan *(experimental)* | Bailian console gateway → coding plan quota | Cookie header / in-app sign-in |
| 火山方舟 *(experimental)* | `arkcli usage plan --format json` | automatic (arkcli login) |
| 智谱 GLM *(experimental)* | `open.bigmodel.cn/api/monitor/usage/quota/limit` | manual API key |
| Kimi 开放平台 *(experimental)* | `api.moonshot.cn/v1/users/me/balance` | manual API key |
| OpenRouter *(experimental)* | `openrouter.ai/api/v1/credits` + `/key` | manual API key |
| 小米 MiMo *(experimental)* | `platform.xiaomimimo.com/api/v1` balance + token plan | Cookie header / in-app sign-in |
| Qoder *(experimental)* | `qoder.com/api/v2/me/usages/big_model_credits` | manual Cookie header |
| Windsurf *(experimental)* | Windsurf's own `state.vscdb` cached plan | automatic |
| Kiro *(experimental)* | `kiro-cli` session → AWS `GetUsageLimits` | automatic |

*Experimental* providers are built from the services' own consoles and CLIs but have not
yet been checked against a live account; they are labelled as such in Settings.

**No dialog, normally.** Claude is the only provider whose session lives in *another
app's* keychain item. QuotaBar reads it the way Claude Code itself does — through
`/usr/bin/security`, which every item that tool writes trusts — so macOS has nothing to
ask, whatever the build is signed with. Only if that read is refused does the
**Allow keychain access** button appear, and the dialog is never raised from a background
refresh — only from that button.

## Where the numbers show

**Menu bar and panel**
- Eleven glyph styles, four of them *stepped* so the reading can be counted rather than
  estimated; or a text reading, the logo alone, or nothing.
- The glyph splits a **short** horizon (5-hour, rolling) from a **long** one (weekly,
  billing cycles), because collapsing them hides which limit is actually near.
- Click it for the panel: a spend card on top — spend, tokens or cost per million
  tokens, for today, yesterday or 30 days, split by CLI — then one card per provider
  with its two most important windows; the rest, the trend, 30-day spend and the status
  page fold out beneath.
- Click any percentage to flip between used and left, any reset time between a countdown
  and the clock. Right-click a card to copy it as an image.
- `Esc` closes, `⌘R` refreshes everything, `⌘,` opens Settings. A global hotkey can open
  it from anywhere.

**Notch island** — on notched Macs the figures sit either side of the notch. Hover to open
three pages (limits, usage, overview) with five chart styles. A soft glow turns amber and
red as a limit nears, and the island peeks out on its own the first time one crosses the
warning line. A low-power mode glows only when something happens.

**Edge dock** — hides until the pointer reaches the screen edge. Double-click a window
(5-hour, weekly, a model's own) to choose what its ring shows.

**Desktop cards** — as many as you like, sitting on the desktop below your windows or
kept above them: big figure, gauge, spend trend, day by day, provider grid, closest to the
limit, and the classic list, each in small, medium or large. Drag to move, double-click
for the panel, right-click to change style, size or provider.

With two screens, choose which one the island, dock and cards appear on.

## Pace, alerts and spend

- **Pace.** A thin tick on every bar marks where even use would be by now. A window on
  course to finish tight says so; one on course to run out shows a flame and when.
- **Alerts.** Warning and critical thresholds, plus *almost out*, *cutting it close* and
  *will run out* — each fires once per crossing and once per reset period.
- **Resets.** QuotaBar reads a provider again the moment a window resets, and marks it
  in that provider's colour: the dock slides out and sweeps the ring full with a card
  beside it, the island opens a "limit reset" banner, the menu-bar glyph refills with a
  sheen, and the row says it just reset; a notification follows if the window had been
  used past 90%.
- **Spend.** Estimated locally from Claude Code, Codex CLI and OpenCode session logs, in
  dollars or one of ten other currencies at daily reference rates, counting all tokens or
  input and output only. QuotaBar keeps its own day-by-model archive, so the figures do
  not shrink when a CLI prunes old logs.
- **Usage page.** A year heatmap and volume chart in Settings.
- **Share card.** Your last 7 days, 30 days, 3 months, year or all time, by API value or
  tokens; the card turns black past $1,000 and blue past $10,000. 4:5, 1:1 or 9:16, saved
  as a 1080-pixel PNG or copied.
- **Service status.** The providers' own status pages, judged by the coding components —
  Claude Code, the Codex CLI — with 30 days of history in Settings.

## Your data

Automatic providers reuse the session your CLI already created — the app never asks for a
password. Manually entered tokens go to the **macOS login keychain**, never to a file.
Preferences live in `~/.config/quotabar/config.json` (mode `0600`) and contain no
secrets. There is no analytics and no telemetry.

QuotaBar connects only to:

- the usage endpoints of the providers you turn on, with your own session or key;
- their public status pages, such as `status.claude.com`;
- `open.er-api.com`, once a day, for exchange rates;
- GitHub, to check for and download updates and to fetch model prices (LiteLLM's catalog);
- `quota.bar`, only when you send feedback.

With a proxy set (HTTP, HTTPS or SOCKS5), all of it goes through the proxy. Your usage is
never sent to a server of ours. While a screen share or recording is on, QuotaBar can
hide the figures and leave only its mark in the menu bar.

## For other tools

Turn on **Local API** in Settings → General and QuotaBar serves JSON on this Mac only:

```bash
curl http://127.0.0.1:6736/v1/limits   # every window, percent and reset
curl http://127.0.0.1:6736/v1/spend    # dollars and tokens: today, yesterday, 30 days
```

No credentials, no account names. From a terminal, the same limits without the app open:

```bash
/Applications/QuotaBar.app/Contents/MacOS/QuotaBar --json          # cached up to five minutes
/Applications/QuotaBar.app/Contents/MacOS/QuotaBar --json --force  # ask every provider now
```

## First run

1. On a fresh install QuotaBar turns on only the providers whose tools it finds signed in
   on this Mac, and a welcome card in the panel says how many.
2. Automatic providers need the matching CLI signed in (`codex`, `claude`, `gemini`,
   `grok`, `gh`) or the app installed (Cursor, Windsurf).
3. Manual providers: open Settings → **Providers**, paste the token described under the
   row, then **Test connection** — it bypasses every cache and asks the source directly.

The panel refreshes every 5, 15 or 30 minutes, on wake, and when the network comes back;
the footer's button refreshes everything at once. Upgrading from a build that stored
credentials in `config.json`? They are moved into the keychain on first launch and erased
from the file.

## Build & run

Requires macOS 14+ and a **full Xcode toolchain** — CommandLineTools alone lacks the
SwiftUI macro plugin, so the build fails on `@State`.

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
swift build && swift test
UNIVERSAL=0 ./Scripts/package_app.sh   # QuotaBar.app in place; drop UNIVERSAL=0 for Intel too
open QuotaBar.app
```

The app is a menu-bar agent, so there is little to screenshot. Render the surfaces
off-screen instead — CI runs the first two as smoke tests. Add `--lang en` or `--lang zh`
to render one language:

```bash
.build/debug/QuotaBar --snapshot ./snapshots             # panel, dock, notch strip
.build/debug/QuotaBar --settings-preview ./settings      # every settings section, both languages
.build/debug/QuotaBar --icon-preview ./icons             # all eleven menu-bar styles
.build/debug/QuotaBar --island-preview ./island          # island pages and chart styles
.build/debug/QuotaBar --widget-concepts ./cards          # every desktop card, every size
```

Glass, vibrancy and springs only exist on screen — `ImageRenderer` draws none of them.
For those, open the real thing:

```bash
.build/debug/QuotaBar --settings-window about
.build/debug/QuotaBar --panel-window
QUOTABAR_DOCK_TRACE=1 QUOTABAR_DOCK_SLIDE=2 ./QuotaBar.app/Contents/MacOS/QuotaBar
```

For a single provider: `QuotaBar --provider claude`; for the status pages:
`QuotaBar --status`.

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
bundle**, so a half-signed build cannot reach users by accident. The app updates itself
only from a download signed by this app's developer and notarized by Apple.

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

- `Sources/QuotaCore` — provider protocol, HTTP helpers, config and keychain store,
  credential readers, cost estimator and usage archive, pricing catalog, status pages,
  updater, one file per provider group.
- `Sources/QuotaBar` — the app: an AppKit status item and panels hosting SwiftUI — usage
  store, menu-bar glyph, panel, settings, notch island, edge dock, desktop cards, share
  card, local API.
- `Tests/QuotaCoreTests` — parser fixtures, cost regressions, config migration, updater
  verification. Everything testable lives in QuotaCore.
- `site/index.html` — the website's template, every piece of copy written as
  `[[English||中文]]`; `Scripts/sync_changelog.py` builds it into `web/` (English at the
  root, Chinese under `web/zh/`). `web/` is what gets deployed.

Adding a provider, and every design decision worth knowing before changing one:
[ARCHITECTURE.md](ARCHITECTURE.md). Every change to the app is logged, dated, in
[CHANGELOG.en.md](CHANGELOG.en.md) (English) and [CHANGELOG.md](CHANGELOG.md) (Chinese).

## Acknowledgements

QuotaBar builds on these open-source projects and this typeface. Thank you.

| Project | Author | License | What QuotaBar took |
|---|---|---|---|
| [codex-island](https://github.com/ericjypark/codex-island) | Eric Park | MIT | The notch island's look and motion |
| [OpenUsage](https://github.com/robinebers/openusage) | Robin Ebers | MIT | The menu panel, pace hints and the share card |
| [CodexBar](https://github.com/steipete/CodexBar) | Peter Steinberger | MIT | How providers report their usage; QuotaBar is a clean-room Swift implementation inspired by it |
| [theSVG](https://github.com/GLINCKER/thesvg) | thesvg.org | MIT | The vector masters of the provider logos, kept in `Assets/logos-src-*.svg` |
| [Instrument Sans](https://github.com/Instrument/instrument-sans) | The Instrument Sans Project Authors | SIL OFL 1.1 | The typeface of the QuotaBar wordmark and the website |

QuotaBar is an independent third-party app. It is not affiliated with, endorsed by, or
sponsored by Anthropic, OpenAI, Cursor, Google, xAI, GitHub, X or any other company it
mentions. Their names and logos belong to their respective owners.

## License

MIT — see [LICENSE](LICENSE).

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

Latest release **0.5.1** (2026-09-13) · **3** changes in development · [full changelog](CHANGELOG.en.md)

<details open>
<summary><b>2026-09-13</b> · Unreleased · 2 added · 1 style</summary>

**Added**

- The edge dock scrolls when there are more providers than the screen can hold: the strip grows until it is 24 pt from the top and bottom of the screen, and the rest of the rings scroll inside it with the wheel or trackpad. The system scroller is replaced by a 2 pt line on the inboard side, faint at rest, brighter while scrolling, fading back once it stops; where there are more rings above or below, the ends fade into the black. Scrolling puts away the hover card, cards line up with their ring allowing for the scroll, and when a limit resets its ring is scrolled into view first.
- Provider cards in the panel can be dragged into a new order: the card lifts slightly and follows the pointer, trades places with a neighbour once it is halfway over it while the others slide aside, and settles into its slot on release. The new order is used by the dock, the notch island and desktop cards too. Clicks inside a card (used or left, reset times and so on) still work, since a drag starts only after a few points of movement, and releasing outside the panel still settles the card and saves the order.

**Style**

- The About page's GitHub link shows the repository's new name, gentpan/QuotaBar, and the feedback and update-check addresses use it too.

</details>

<details>
<summary><b>2026-09-13</b> · 0.5.1 · 3 added · 7 style · 3 fixed</summary>

**Added**

- Providers can be hidden per place instead of turned off: the panel, the edge dock, the notch island and desktop cards each choose which providers they show. A hidden provider is still read, still alerts and still counts towards spend; only turning it off stops reading it. Settings → Presentation has a new "What each place shows" card, one row per provider, where clicking a place's tag shows or hides it there. You can also right-click a card in the panel and choose "Hide from Panel", or right-click a dock icon and choose "Hide from the dock".
- When providers are hidden, the bottom of the panel says "N hidden here" with their icons; "Reveal" brings them back one at a time or opens Settings to manage them. The dock's right-click menu lists its hidden providers too.
- In-app updates check and download from the quota.bar server when GitHub can't be reached, so networks that block GitHub still get updates. The download must still carry the developer's signature and Apple's notarization before it installs. The About page's "Your data" list of connections now includes it.

**Style**

- The refresh note in the panel footer reads "Updated just now" for a minute after "Refresh Everything" or an automatic refresh, then "Auto-refresh in Xm"; hovering shows when it last updated, when it refreshes next and the interval. It used to say "refresh in 5m" the moment a refresh finished, which looked as if the button had done nothing.
- The pacing note now reads "~8% left at reset" instead of the vaguer "about 8% to spare". Hovering spells out the working, for example "87% of this window has passed and 80% is used. At this rate it reaches about 92% by the reset, leaving 8%."
- Service status says "Service OK" instead of "Running normally". Hovering the dot or the label names the source — for example "From the official status page status.claude.com, judged by Claude Code and Claude API, checked 3m ago" — to make clear it reflects the provider's own service status, not your login or quota reading.
- Approaching the edge dock now opens just the icons, without popping the card beside them. Once the dock has fully opened, pointing at an icon shows that provider's card, and moving between icons switches the card straight away. With "Keep open" on, hovering an icon shows its card at once.
- The edge dock opens in two moves: the small capsule first grows wider, then taller, with the rings fading and sliding in inside the shape rather than spilling past the black. Closing reverses it: shorter first, then narrow again.
- The QuotaBar wordmark changes from Sora to Instrument Sans SemiBold across the settings sidebar, the About page, the panel, the notch island, share cards and copied images; the About page's acknowledgements now credit Instrument Sans.
- The usage share card window no longer has a separate grey title bar: the title bar is transparent and the card preview and the settings beside it run to the top of the window, one piece like the Settings window. The card and the heading on the right keep clear of the traffic-light buttons and line up with each other.

**Fixed**

- In English, the "Keychain" tag in Settings → Providers broke over two lines ("Keychai" / "n"): the tag's slot is wider and the text stays on one line.
- Pacing gave wild estimates right after a window began — 3% used three minutes into a 5-hour window was projected to run out. It now waits until at least 5% of the window, and no less than 15 minutes, has passed before saying how much will be left, that it will run out, or when; a window already used up still shows at once.
- The edge dock jumped off the screen edge for an instant when it opened on hover, leaving a gap. The window no longer changes size as the dock opens and closes; only the black shape grows inside it, flush to the edge throughout, and the undrawn transparent area lets the pointer through.

</details>

<details>
<summary><b>2026-09-13</b> · 0.5.0 · 40 added · 10 style · 13 fixed</summary>

**Added**

- The panel is back: left-click the menu bar icon to open it, right-click for Refresh, Settings and Quit. A spend card sits at the top, a card per provider below, and the footer shows the version, the countdown to the next refresh, Settings and an options menu. Esc closes it, ⌘R refreshes, ⌘, opens Settings.
- Spend card: switch between spend, tokens and spend per million tokens, and between today, yesterday and the last 30 days. The ring is coloured by source, the figure in the middle rolls to its new value, and hovering a source shows the breakdown by model.
- Provider cards show the two most important windows by default. The other windows, limit reset counts, the 30-day usage trend, today's, yesterday's and 30-day spend, and links to the status page and console fold away under a disclosure arrow, which remembers whether it was open.
- Bars show pacing: a thin tick marks where steady use would put you right now. When it will be tight the bar says roughly how much will be left; when the window will run out before it resets it shows a flame and when; a window already used up says "Limit reached". Hover a bar to see what the usage will be at reset at the current rate.
- Click a percentage to switch between used and left, click a reset time to switch between a countdown and the exact time; every view follows.
- Right-click a provider card or the spend card to copy it as an image, at 4× resolution, with a "Copied" confirmation.
- Weekly usage share card: API value or token count over the last 7 days, 30 days, 3 months, this year or all time. Past $1,000 the card turns black, past $10,000 blue. Choose 4:5, 1:1 or 9:16 and a byline; share through the system, save a 1080 px PNG, or copy the image and the text.
- Usage archive: QuotaBar keeps its own record of tokens and spend per model per day, so totals don't shrink when Claude Code clears old logs.
- At launch the last saved readings show first while fresh ones load in the background.
- On first install QuotaBar detects the tools you're already signed in to, turns on just those providers, and shows a welcome card you can dismiss.
- Usage can hide while the screen is shared or recorded: the menu bar shows only the mark, and the dock, notch island and desktop cards step aside.
- Three pacing notifications — almost out, cutting it close, will run out before the reset — each at most once per window.
- Spend can be shown in yuan, Hong Kong dollars, yen, euros and more, with exchange rates updated daily.
- Token counts can include cache or count only input and output.
- Provider requests can go through an HTTP or SOCKS5 proxy.
- Notch island glow: a soft cobalt halo around the black outline that shades to amber or red near the warning line, with a light that travels around the edge. Low power mode glows only on refresh, hover or a warning; the animation pauses while a full-screen app covers the island. The glow doesn't block clicks.
- The notch island pops open when a limit first crosses the warning line, for about 4 seconds.
- The notch island panel has three pages — limits, usage, overview — turned with a two-finger swipe or the dots at the bottom. The overview shows today's and 30-day spend, each source's share, and opens the share card.
- The notch island's limit charts come in five styles — bars, rings, steps, figures, trend line — switched from the tabs at the bottom or with ⌘-click on the panel.
- The sync dot breathes slowly and gives a small hop whenever new data arrives.
- Desktop card: in detailed mode the bars gain pacing ticks and reset countdowns, with today's and 30-day spend at the bottom; standard mode shows the reset countdown under each ring; cards can sort by what runs out first.
- Global shortcut: record a key combination in Settings to open the panel from anywhere.
- Local API: once on, other tools on this Mac can read limits from http://127.0.0.1:6736/v1/limits, without credentials or account names; `QuotaBar --json` prints the same data in a terminal.
- Beta updates: once on, pre-releases arrive too.
- New in Settings: bar colour, reset time format, 12- or 24-hour clock, always show pacing, reduce animations, panel density, show the spend card, notch island glow and low power, pop open past the warning line, notch island chart style, sort the desktop card by urgency, the three pacing notifications, currency, token counting, hide usage while the screen is shared, proxy, and the local API.
- The Usage page and the panel both open the usage share card, and after an update it opens once by itself if there has been usage this week.
- New "Marks and figures" menu bar mode: the selected provider alone if one is selected, otherwise the logos and percentages of the first three enabled providers.
- Right-click a provider card to move it up or down; the dock, notch island, desktop cards and panel all follow the same order.
- The panel can be translucent, letting the desktop show through.
- 10 new providers, 23 in all: Alibaba Coding Plan, Volcengine Ark, Zhipu GLM (China), Moonshot API balance, GitHub Copilot, OpenRouter, Xiaomi MiMo, Qoder, Windsurf and Kiro. Copilot uses the GitHub CLI's sign-in; Volcengine Ark reads arkcli; Windsurf and Kiro read their signed-in desktop apps; Alibaba Coding Plan and Xiaomi MiMo can sign in through the in-app browser. All but Copilot are marked "Experimental" until verified with real accounts. Copilot, Windsurf and Moonshot API have public status pages wired up.
- New diagnostic command `QuotaBar --provider <provider>` fetches one provider's reading on its own.
- Desktop cards, several at once: six new styles — big figure, gauge, spend trend, day by day, provider grid, closest first — plus the original classic style. Each card can be small, medium or large, show a chosen provider or spend source, and remembers its own position. Right-click a card to change its style, size or provider, add a card or remove it; double-click to open the panel. The desktop widget section in Settings becomes a list of cards, with "Add a card" and "Restore the default pair". If the desktop widget was on, it is replaced in place by the default pair: a big figure for the main provider with a spend trend below.
- "Refresh Everything" in the panel footer rereads every provider, service status and local logs, and reloads sign-in credentials, with a spinner while it runs. ⌘R and Refresh in the options menu do the same; the button at the top right of a single card still refreshes just that provider.
- The About page is redone: GitHub and X links with their own brand marks, a mail link to hello@quota.bar, a short description of the app, and at the bottom the update date, a link to the changelog, the requirement (macOS 14 or later), © 2026 QuotaBar and the MIT licence. "Your data" lists every address the app connects to; new "Acknowledgements" credit the authors and licences of codex-island, OpenUsage, CodexBar, theSVG and the Sora font; a closing trademark note says QuotaBar isn't affiliated with any provider, GitHub or X. The tagline matches the website: "Every AI coding limit, at a glance".
- Reset moments: when a window such as the 5-hour or weekly one resets, QuotaBar rereads that provider right at the reset time instead of waiting for the next scheduled refresh (if the provider hasn't rolled over yet it retries each minute, up to 3 times). Colours always follow the provider — Claude orange, Codex blue — while the menu bar stays black and white.
- Reset moments · menu bar icon: the meter refills smoothly, the button glows briefly underneath, and a highlight sweeps across the icon from left to right.
- Reset moments · edge dock: the dock slides out, a light arc in the provider's colour sweeps that ring full and sends two ripples outward, and the ring swells slightly. A "Just reset" card slides out beside it, the percentage left rolling to its new value and the bar filling, noting how little was left before. It closes after about 3 seconds, or stays while the pointer is over it.
- Reset moments · notch island: a row springs open like the Dynamic Island, a mini ring draws full, and it shows "Limit reset" with the provider and window name, the figure rolling and the glow in the provider's colour, closing after about 4 seconds.
- Reset moments · panel and cards: the window's row flashes in the provider's colour and fades back, a "Just reset" tag pops in with its arrow turning once, and stays for ten minutes; the desktop card's status corner also reads "Just reset" for a while.
- Reset notifications: off, after heavy use (the default, only when the window had passed 90%) or always. Resets that happened while the app was closed don't send a late notification. Settings → Alerts has a new "Resets" card; `QuotaBar --simulate-reset claude` previews the effect from a terminal.

**Style**

- The rows in the dock's hover card use the new shared limit row, with pacing and click-to-switch.
- "Menu bar" in Presentation is renamed "Menu bar only"; dates on share cards and exact reset times follow the interface language.
- The panel footer is one line: the version followed by when it next refreshes.
- The footer of copied images shows the QuotaBar app icon on its green tile with the name on the left and the address quota.bar alone on the right, instead of "QuotaBar · quota.bar".
- The spend card header is rebuilt: on the left a pull-down title chooses between spend, tokens and spend per million tokens; on the right, info, share and copy are three buttons of one size in a row, and info shows where the data comes from. The three icons are scaled into the same box, share a height, and sit on the pull-down title's centre line.
- Buttons shrink slightly when pressed, with one animation curve throughout; charts switch with a light blur. "Reduce animations" is supported and the system's Reduce motion setting is followed.
- In English the desktop card size switch in Settings reads S / M / L instead of truncating Medium to "Med..."; the multi-provider desktop card footer reads "4 providers · % left", the big figure card has a space between the window name and "left", and the English wording of the "Screen" explanation is rewritten.
- The Settings window's controls share one style: pop-up menus, segmented controls, buttons and text fields are all 30 pt tall with the same corner radius, fill and hairline border, and line up in a row. The desktop card style, provider and currency choices use the new pop-up control, which opens with the current item over the control and ticked, its text aligned with the control; "Add a card" becomes a matching button with a chevron.
- Switches in Settings are green when on instead of dark grey. Switch rows with a single-line title are as tall as field rows, row spacing inside a card is consistent, and labels on the left sit centred against the controls on the right.
- The usage share card window's pop-ups, byline field, switches and Share, Save and Copy buttons use the same control style.

**Fixed**

- Flipping a card to its usage side, the notch island's usage page and the Usage page each took ten-odd seconds the first time after every launch; they're now worked out from the local archive and show at once.
- The spend card took about 8 seconds to show a figure after launch; it now reads the local archive at launch in about 2 ms, and in the background rereads only logs changed in the last two days, about 30 ms each time after.
- Flipping a card soon after launch could wrongly say "Nothing logged locally yet."
- Memory grew during long runs: a session log still being written was cached again on every refresh. Each file is now cached once, and files no longer scanned are released.
- The dock no longer recomputes the card size each time the card moves between rings, so switching is smoother.
- Codex's plan chip couldn't tell the two Pro plans apart; it now shows PRO 5X or PRO 20X from the plan identifier the API returns.
- The shortest refresh interval is now 5 minutes, to stay under the Anthropic usage API's rate limit; 1- and 2-minute settings in older configs become 5 minutes.
- After switching the interface language, window names, plan descriptions and error messages stayed in the old language until the next automatic refresh; switching language now rereads every provider and service status straight away.
- Saved readings record the language they were fetched in, so launching in a different language no longer shows old text in the other one (the first launch after upgrading reads fresh instead of using the old cache).
- Service status in the Chinese interface no longer shows the status page's English headline (such as All Systems Operational) but a Chinese status level; incident names keep the status page's own wording.
- The source list in the English spend explanation used Chinese enumeration commas; it now uses commas or enumeration commas by language.
- Before any reading, desktop cards drew the gauge ring, provider grid and ranking bars full and green, with pacing "OK"; they now draw empty, with dashes for the figures and pacing.
- The About page's network note missed one address: the model price list also comes from GitHub (LiteLLM's price list). It's now listed.

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

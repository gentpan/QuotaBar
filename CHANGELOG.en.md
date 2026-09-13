# Changelog

New features, style changes and fixes in the QuotaBar app, newest first by version and day.
Server moves, the website, and build or release scripts don't change the app itself and aren't recorded here.

## Unreleased

### 2026-09-13

#### Added

- The right-click menu on a provider card in the panel gains three groups of quick settings. "Limits on the Card" ticks which limits show and which fold under the disclosure arrow, remembered per provider, with Restore Default, and the last one cannot be unticked. "Ring Follows" picks the window the dock ring, notch island and menu bar follow, the same choice as double-clicking a window. "Show In" ticks whether the provider appears in the panel, the dock, the notch island and desktop cards, plus "Menu Bar Shows Only" this provider and "Add a Desktop Card" for it. "Hide from Panel" and "Ring follows the fullest window" fold into these groups.
- Updates come as an update card: when a new version is found, a card shows its number, the version you have, the release date and what changed (in the interface's language, grouped into added, style and fixed, with Show all and a link to the full changelog). Install and Relaunch downloads it, checks the developer's signature and Apple's notarization, then replaces the app and relaunches; the app no longer relaunches without asking. The Updates setting becomes "Download in background" (downloaded and verified as soon as it is found, so installing is instant) or "Download when I install". If replacing the app fails, for example without write access to Applications, the card says why and offers Try Again and Download Installer. The menu bar's right-click menu, the panel's banner and the Updates page all open the card, which opens by itself once per version per launch.

#### Style

- An expanded row in Settings → Providers no longer gives "Test connection" and "Console" a line of their own: "Console" follows the provider's name and "Test connection" sits on the right ahead of the service status, level with the name; the test's result still appears below. Providers that need Save, browser sign-in or keychain authorisation keep those buttons on a line below.
- Each Settings section's title and its explanation now share one line, on a common baseline, instead of stacking; in a narrow window the explanation is cut short first, with the full text on hover.
- "Test connection" in a provider row's header is a small chip with an icon, about as tall as the status pills, instead of a 30 pt button that made an open row taller than a closed one; in the open row, the service status text now lines up with its label, where it sat about 7 pt higher.
- Provider cards show the limits that fit the plan: Codex shows the plan's own limits — the 5-hour and the week on plans that have a 5-hour limit, the week alone on Pro, which has none — with GPT-5.3-Codex-Spark's limits under the disclosure arrow; Claude shows the 5-hour, the week and Fable. The window the ring follows is always shown. Other providers are unchanged.

## 0.5.3 · 2026-09-13

### 2026-09-13

#### Added

- The menu bar icon's right-click menu is redone. A new "Show in Menu Bar" submenu offers "Automatic (fullest limit)" or any enabled provider, each with its mark and the figure the icon would show (left or used), the current choice ticked; the choice is the menu bar's own, and the dock, notch island and desktop cards keep theirs. The menu also gains "Check for Updates…" (which reads "Update to x.y.z…" when one is available and "Restart to Update to x.y.z" once downloaded), "Feedback…" and "About QuotaBar", alongside Refresh Now (⌘R), Settings (⌘,) and Quit (⌘Q).

#### Fixed

- With automatic update checks turned off, "Check now" on the Updates page and "Check for Updates…" in the panel's options menu did nothing; a check you ask for now runs regardless of that switch.

## 0.5.2 · 2026-09-13

### 2026-09-13

#### Added

- The edge dock scrolls when there are more providers than the screen can hold: the strip grows until it is 24 pt from the top and bottom of the screen, and the rest of the rings scroll inside it with the wheel or trackpad. The system scroller is replaced by a 2 pt line on the inboard side, faint at rest, brighter while scrolling, fading back once it stops; where there are more rings above or below, the ends fade into the black. Scrolling puts away the hover card, cards line up with their ring allowing for the scroll, and when a limit resets its ring is scrolled into view first.
- Provider cards in the panel can be dragged into a new order: the card lifts slightly and follows the pointer, trades places with a neighbour once it is halfway over it while the others slide aside, and settles into its slot on release. The new order is used by the dock, the notch island and desktop cards too. Clicks inside a card (used or left, reset times and so on) still work, since a drag starts only after a few points of movement, and releasing outside the panel still settles the card and saves the order.

#### Style

- The About page's GitHub link shows the repository's new name, gentpan/QuotaBar, and the feedback and update-check addresses use it too.

## 0.5.1 · 2026-09-13

### 2026-09-13

#### Added

- Providers can be hidden per place instead of turned off: the panel, the edge dock, the notch island and desktop cards each choose which providers they show. A hidden provider is still read, still alerts and still counts towards spend; only turning it off stops reading it. Settings → Presentation has a new "What each place shows" card, one row per provider, where clicking a place's tag shows or hides it there. You can also right-click a card in the panel and choose "Hide from Panel", or right-click a dock icon and choose "Hide from the dock".
- When providers are hidden, the bottom of the panel says "N hidden here" with their icons; "Reveal" brings them back one at a time or opens Settings to manage them. The dock's right-click menu lists its hidden providers too.
- In-app updates check and download from the quota.bar server when GitHub can't be reached, so networks that block GitHub still get updates. The download must still carry the developer's signature and Apple's notarization before it installs. The About page's "Your data" list of connections now includes it.

#### Style

- The refresh note in the panel footer reads "Updated just now" for a minute after "Refresh Everything" or an automatic refresh, then "Auto-refresh in Xm"; hovering shows when it last updated, when it refreshes next and the interval. It used to say "refresh in 5m" the moment a refresh finished, which looked as if the button had done nothing.
- The pacing note now reads "~8% left at reset" instead of the vaguer "about 8% to spare". Hovering spells out the working, for example "87% of this window has passed and 80% is used. At this rate it reaches about 92% by the reset, leaving 8%."
- Service status says "Service OK" instead of "Running normally". Hovering the dot or the label names the source — for example "From the official status page status.claude.com, judged by Claude Code and Claude API, checked 3m ago" — to make clear it reflects the provider's own service status, not your login or quota reading.
- Approaching the edge dock now opens just the icons, without popping the card beside them. Once the dock has fully opened, pointing at an icon shows that provider's card, and moving between icons switches the card straight away. With "Keep open" on, hovering an icon shows its card at once.
- The edge dock opens in two moves: the small capsule first grows wider, then taller, with the rings fading and sliding in inside the shape rather than spilling past the black. Closing reverses it: shorter first, then narrow again.
- The QuotaBar wordmark changes from Sora to Instrument Sans SemiBold across the settings sidebar, the About page, the panel, the notch island, share cards and copied images; the About page's acknowledgements now credit Instrument Sans.
- The usage share card window no longer has a separate grey title bar: the title bar is transparent and the card preview and the settings beside it run to the top of the window, one piece like the Settings window. The card and the heading on the right keep clear of the traffic-light buttons and line up with each other.

#### Fixed

- In English, the "Keychain" tag in Settings → Providers broke over two lines ("Keychai" / "n"): the tag's slot is wider and the text stays on one line.
- Pacing gave wild estimates right after a window began — 3% used three minutes into a 5-hour window was projected to run out. It now waits until at least 5% of the window, and no less than 15 minutes, has passed before saying how much will be left, that it will run out, or when; a window already used up still shows at once.
- The edge dock jumped off the screen edge for an instant when it opened on hover, leaving a gap. The window no longer changes size as the dock opens and closes; only the black shape grows inside it, flush to the edge throughout, and the undrawn transparent area lets the pointer through.

## 0.5.0 · 2026-09-13

### 2026-09-13

#### Added

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

#### Style

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

#### Fixed

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

### 2026-09-12

#### Added

- Double-click a window in the hover card (5-hour, weekly, or a per-model limit such as Fable) and the rings, notch island, desktop card and menu bar reading all follow that window. Double-click again to go back to whichever is most used. The window being followed has a dot beside its name, solid in the provider's colour when chosen by hand.
- Presentation has a new "Screen" option: with several displays, choose which one shows the dock, notch island and desktop cards; the default is automatic. If the chosen display is unplugged it falls back to the default, and windows reposition when displays come and go.
- Each row of the service status page shows the main service's 30-day uptime and status bar even when folded: Claude Code for Claude, the CLI for Codex, the IDE for Cursor, the Open API for Kimi, the API service for DeepSeek.
- Service status marks look only at the services used for coding: Claude Code and Claude API for Claude; the CLI, the VS Code extension, the Codex API, Codex Web and the desktop app for Codex; the IDE, the CLI and cloud agents for Cursor. Incidents in other components of a status page (such as Claude Cowork) no longer turn the mark yellow, and are listed separately under "Elsewhere on the page" when a status row is opened.
- New diagnostic command `QuotaBar --status` lists the components each provider's status mark is based on and incidents in other components.
- New diagnostic command `QuotaBar --credentials` shows whether each local credential can be read and how, without printing any secrets.

#### Style

- The Settings window no longer flashes a scroll bar on the right, including when a service status row opens.

#### Fixed

- Codex's status couldn't find the CLI component: the OpenAI status page's summary leaves it out, so the full component list is now read when it's missing.
- After reinstalling or updating, opening the app asked again for keychain access to "Claude Code-credentials". It now reads through the system's own security tool, the same way Claude Code does, so a change in the app's signature no longer prompts again.

## 0.4.0 · 2026-09-12

#### Added

- Service status: reads the public status pages of Claude, OpenAI (Codex), Cursor, Manus, MiniMax, Kimi, DeepSeek and Gemini every five minutes, no sign-in needed. Outages show in the hover card and in Settings.
- New "Service status" page in Settings: a row per provider that opens to show each component's status and the last 30 days of uptime.
- New "Usage" page in Settings: a year-long heat map and token usage from local Claude Code, Codex CLI and OpenCode session logs.
- New providers Antigravity and Qwen Cloud.
- Cursor adds the Grok Bot limit; the Grok and Claude cards show the signed-in account.
- The notch island is redone: one to three providers on each side of the notch, opening from the top into the full panel on hover. The panel's footer switches between stepped and continuous bars, used or left, and limits or usage.
- Click a ring in the dock to open the full card, where a provider can be pinned to the menu bar, notch island, dock or desktop card.
- The dock's right-click menu adds Refresh Now, Keep open and Show every provider.
- The hover card flips over to show usage: today, 7, 14 and 30 days with daily averages, and hovering a column shows that day's value.
- The refresh button on the hover card refreshes just that provider, spinning while it does.
- The menu bar icon can show the reading, the white QuotaBar logo, or nothing.
- Clicking the menu bar icon opens the Settings window directly instead of a menu.
- Turning on a provider you haven't signed in to opens it with sign-in instructions. Cursor and Kimi can sign in through the in-app browser.
- Updates can download, install and relaunch automatically, or be installed by hand; the Updates page shows the current version.
- Feedback page: send feedback straight to quota.bar, no sign-in needed.
- The About page links the website, GitHub and X.
- Bars in Settings default to the stepped style, with the continuous style still available.
- The desktop card can show every provider or just a pinned one.

#### Style

- The dock's corner radius is 14 pt, and the square-corner option is gone.
- Logos in the dock's rings are larger; the percentage under each ring is gone, and the selected provider has a green dot under its ring.
- The dock is offset towards the screen edge to make up for the display's own black border, so it looks centred.
- Dock rings grow slightly on hover, and the card glides between rings.
- Logos and figures on either side of the notch island share the provider's colour.
- Kimi's logo loses its black backing; Qwen and Antigravity get their official brand logos.
- Buttons in Settings are uniformly taller and wider; status marks in the provider list line up in a column.
- The usage statistics card is light.
- Uptime bars use the same green as limit bars, with the uptime figure in front of the bar.
- The desktop card shows each provider by window, with at most two bars.

#### Fixed

- Buttons in the hover card highlighted but did nothing when clicked.
- The dock showed a blank strip when opening and jumped up as a whole when closing.
- Uptime bar colours and uptime percentages were wrong, showing good days in red.
- After changing the docking edge, the dock stayed on the old side.
- The newer Grok CLI's sign-in file couldn't be read, so Grok always showed as not set up.
- A leftover record of an old Homebrew install made the app think it was Homebrew-managed and refuse in-app updates.

## 0.3.3 · 2026-09-12

#### Added

- Universal binary, running natively on both Apple silicon and Intel Macs.

#### Fixed

- Background refreshes brought up the Claude keychain dialog every minute. It now asks only when you click "Allow keychain access".

## 0.3.2 · 2026-08-31

#### Style

- Usage colour is a continuous ramp: green up to 50%, through gold and orange, to red at 90%.
- The app name QuotaBar is set in Sora.
- The Settings window is one surface, without what looked like an extra title bar at the top.

#### Fixed

- The Settings window's close, minimise and zoom buttons had disappeared.
- The menu panel's height stuck at its empty first-open state, cutting off the content.

## 0.3.1 · 2026-08-29

#### Added

- The Settings window has a sidebar with sections.
- When closed, the notch island sits on either side of the notch with readings and reset countdowns.
- Click a ring in the dock to select a provider, double-click to open the panel.
- Cursor's usage for a specific model shows on its own row.

#### Style

- The selection in the Settings sidebar is a band of light that moves.
- The closed dock shows a handle that fills from the bottom in steps to the current usage.

#### Fixed

- Cursor showed 100% when 54% had been used.
- The closed dock was nearly invisible and hard to click.
- Single-colour logos on the dock, notch island and desktop card turned black in light mode and vanished.
- The dock's opening animation stuttered, moving in several jumps.

## 0.3.0 · 2026-08-29

#### Added

- The dock: a column of provider rings at the screen edge, showing that provider's limit card on hover.
- Desktop widget in three sizes, on the desktop layer by default or optionally on top.
- Spend breakdown: switch between today, yesterday and the last 30 days, with a ring by source. OpenCode joins as a third source.
- Prices update daily from a public price list, with a built-in price table as the offline fallback.
- Limit pacing: works out whether the current rate will run the window out before it resets.
- In-app updates: downloads are checked for signature and notarization before they install.

#### Fixed

- A maxed-out limit filled the whole trend chart, hiding any change.
- The panel's height jumped when switching providers.
- Unknown models were matched to cheap prices, putting spend well below the real figure.

## 0.2.4 · 2026-08-27

#### Added

- The menu bar icon shows the short and long windows on two lines.
- The menu bar icon follows the provider selected in the panel, and remembers the choice.

#### Fixed

- With alert colours, an exhausted limit and a full one looked the same.
- Alert colours were too pale and washed out in the menu bar.

## 0.2.3 · 2026-08-27

#### Added

- Limit windows are labelled by length, such as 5h or 7d.
- Codex's limit reset count is shown.

## 0.2.2 · 2026-08-27

#### Added

- Cursor and OpenCode Go sign-ins are read from this Mac automatically, no pasting needed.

#### Fixed

- OpenCode Go was parsed wrongly and never had data.

## 0.2.1 · 2026-08-27

#### Fixed

- After clicking Settings the window opened behind other windows, as if nothing had happened.

## 0.2.0 · 2026-08-27

#### Added

- Five new menu bar icon styles: grid, segmented bar, battery, gauge and scale. Settings shows the icons themselves to choose from.
- A notarized DMG installer.

#### Style

- The accent colour changes from fluorescent green to a neutral graphite.
- The panel grows with its content instead of cutting it off.

#### Fixed

- Reset times could read "resets in reset".
- One unrecognised value in config.json reset every setting.

## 0.1.0 · 2026-08-27

#### Added

- First release: limits and reset times for 11 AI coding services in the menu bar.
- English and Chinese interface, following the system language.
- Manually entered credentials are stored only in the system keychain.
- Daily spend chart comparing today with the last 30 days.
- Log scanning about 7.7× faster.

#### Fixed

- Claude Code usage was counted twice, putting spend at about double the real figure.
- Codex cached input was billed twice.
- Limits are named by window length, so Pro plans are no longer mislabelled as a 5-hour window.

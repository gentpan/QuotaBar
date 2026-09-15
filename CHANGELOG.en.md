# Changelog

New features, style changes and fixes in the QuotaBar app, newest first by version and day.
Server moves, the website, and build or release scripts don't change the app itself and aren't recorded here.

## Unreleased

### 2026-09-16

#### Style

- On the island's overview page the Share usage card button moves to the top right corner as the share icon alone; nothing sits under the spend bars.
- The island overview's spend bars per tool are stepped, like the quota page's; with three tools the bars and gaps are a little shorter, so the panel stays the same height.
- In the open island the quota tiles and the usage page's figures sit about 2pt lower, a little further from the provider's title and closer to the footer rule, so the blank above and below them is about even; the panel keeps its height.
- Usage and spend split by tool now say "Codex" rather than "Codex CLI", OpenAI's own name for it.
- The website, GitHub, X and email links in Settings → About drop their names and arrows: the icon and the address, nothing more.
- The Quota Run settings page's subtitle uses the same word for records as the rest of the page (Chinese only).

#### Fixed

- The medium Ring gauge desktop card ran its account row about 23pt past the card's bottom edge; its ring and gaps are a little smaller at that size and everything fits.
- In the Provider grid desktop card a balance tile such as DeepSeek's was shorter than the quota tiles beside it; the balance now takes the percentage's size and the tiles match.
- The classic desktop widget and the edge dock's rings always showed used, against the remaining reading of the bars beside them and the menu bar; they now follow Fill basis in Appearance.

### 2026-09-15

#### Added

- With the island or the edge dock folded, a quota down to its last 15% makes the outline flash, brightening and dimming, as codex-island does: amber within 15%, red within 5%, and it stops once the quota refills. It goes by the whole percentage shown on screen and ignores the alert thresholds and the notification switch; with Reduce Animations on, the outline stays lit instead of flashing.

#### Style

- The open island no longer draws a halo, an orbiting light or a drop shadow round the panel, and its window is no bigger than the panel, so a window screenshot has no blank band at the sides and bottom; the folded island keeps its glow.
- "Synced N minutes ago" showed twice in the open island, at the top and again at the bottom; it is now bottom right only, with a new Refresh now button beside it that turns into a spinner and "Refreshing…" while it works. The page dots stay centred.
- The open island is one height throughout: switching between Bar, Stepped, Trend, Numeric and Ring, or between the Quota, Usage and Overview pages, no longer changes it. The height is set by the tallest content, about 26pt less than before, so there is no band of black under the bars; shorter styles are centred in it, which also moves the rings clear of the provider's title. The overview's spend bars and share button sit a little closer so three tools fit.
- The island's Trend style drops the "trend · last N refreshes" caption that crowded the reset line, and the line now follows the used-or-remaining switch, reading the same way as the figure and the bars.
- The QuotaBar wordmark at the top left of the open island has the app's mark before it, in the same white as the text.

#### Fixed

- Quitting now saves the local Quota Run records at once. A change used to be written five seconds later, and quitting within those five seconds lost it.

## 0.5.5 · 2026-09-15

### 2026-09-15

#### Style

- The usage share card's address, bottom right, is Quota Run's: signed in to Quota Run with Sign it on, it is your profile, quota.run/@username; signed out it is quota.run alone with the signature before it, rather than a quota.bar/name address that leads nowhere. Signed in, the share window says which profile the card shows in place of the signature field.

## 0.5.4 · 2026-09-15

### 2026-09-15

#### Added

- Copy as Image now shows the signed-in account on a provider card as mosaic tiles, so the email address stays out of the picture. The tiles are one fixed pattern that says nothing about the account, not even its length. Turn it off under Settings → General → Privacy with "Hide the account in copied images"; the panel itself still shows the address.
- A provider card's right-click menu has Hide Limits, for a limit you never use, such as Codex's GPT-5.3-Codex-Spark. A hidden limit is gone from the card and from under its arrow; the ring, the notch island, desktop cards and the menu bar stop following it, and it sends no almost-out alerts. Each provider remembers its own, a language switch keeps them, and Show All brings them back; the last limit cannot be hidden. The dock ring's right-click menu has it too. The local `/v1/limits` endpoint still returns every limit. (#2)
- Codex's Early resets row has an Expires line under it: when each banked reset runs out, soonest first, such as "5d 18h · 18d 23h · 19d 22h", with the rest counted past three. Like the limit rows, a click switches between countdown and clock time, and hovering shows the other. Resets that never expire are not listed. The dock ring's detail shows the line too. (#3)
- Early resets Codex gives out are read in full. The row shows how many the account has been given in all, and stays once the last one is spent; hovering lists each one's name, such as "Full reset (Weekly + 5 hr)", and when it runs out. A notification says when a new one arrives, with how many are available and when the soonest expires, and another comes once for each one still unspent a day before it runs out. Turn them off under Settings → Alerts → Resets with "Early resets given". The list is read at most once an hour, and again at once when the count changes or one of them expires.
- Prepaid providers no longer show an empty bar. DeepSeek, Moonshot API, OpenRouter and Xiaomi MiMo cards show each currency's balance in large figures, split into paid and granted when there is a grant and in red when it is too low for API calls. Below it is recent usage for Today, 7 days, 30 days or All: the spend and a chart of bars or a line — hours for today, days for 7 and 30 days, months for all — with the style switched at the top right and remembered, and each bar's figures on hover. Where the provider gives the detail (OpenRouter with a provisioning key, for one), usage by API key or by model sits under the chart, the top three listed and a key opening to its own figures. The dock's hover card shows the same. A Big figure or Gauge desktop card on a prepaid provider becomes a balance card — the balance in large figures, spend today, over 7 and over 30 days, and on the large card the 30-day chart — and the Provider grid and Closest first cards show the balance without a bar. The notch island and the menu bar's right-click menu show the balance instead of a dash. A copied image shows 30 days of spend and the chart, without key names. MiMo's monthly Token Plan keeps its bar.
- Recent usage with nothing but an API key: DeepSeek's, Moonshot API's and Xiaomi MiMo's APIs answer with the balance only, so QuotaBar keeps each balance it reads and works out the spend today, over 7 and 30 days and in all from how it fell, charted like the rest; the card says "about" and since when it has been keeping count. A rise is taken as a top-up and not counted.
- Low balance alerts: Settings → Alerts → Spend has "Balance below", an amount in the currency it is set in (empty for none). A DeepSeek, Moonshot API, OpenRouter or Xiaomi MiMo account that drops below it, or can no longer pay for API calls, sends one notification; balances in several currencies are added up at the day's rates, and after a top-up the next dip notifies again.
- OpenRouter with a provisioning key lists every key on the account with its spend; with an ordinary API key it shows the credits and that key's own spend. OpenRouter counts by its own calendar day, week and month, so its 7 and 30 days are this week and this month.

#### Fixed

- Alibaba Coding Plan kept saying the session had expired when it had not. The Bailian console now writes its sec_token differently, so QuotaBar never found the token its request needs; an API key saved in place of the Cookie header read the same way, and so did any reply with "login" in it. The token is found in the new page, the request uses the console's current API name, an account without a Coding Plan is told so (Alibaba Cloud now sells Token Plan, which can't be read yet), and an API key in the field is called out with Sign in in a browser… or the Cookie header as the fix — for Qwen Cloud, Xiaomi MiMo and Qoder too. After trying the China and international sites, the reason given is the one that says most.
- DeepSeek said "Provider response could not be parsed" on every API key and never showed a balance. The account balance now shows, split into paid and granted when there is a grant; an account holding both CNY and USD gets a row for each, and a balance too low for API calls says so. (#1)
- Grok showed Weekly credits and Grok Build as two identical bars. When the week's credits all went to one product, that product's bar had the same figure and reset as the total; it is no longer shown twice. Credits spread over several products are still listed one by one. (#2)
- ⌘V did nothing in Settings' text fields, so pasting an API key looked like the field refused input. ⌘V, ⌘C, ⌘X, ⌘A and ⌘Z now work in Settings and the app's other windows, and ⌘W closes the window.

### 2026-09-14

#### Added

- A new Projects page in Settings works out which project each token from this Mac's Claude Code, Codex and OpenCode session logs went to. A project is a Git repository, recognised by its remote, so every checkout and worktree of it counts together; work outside a repository is grouped by folder, and a folder with a repository's name is folded into it. For 7, 30, 90 or 365 days it shows an overview (projects, estimated cost, tokens, sessions, ways of working) and the projects ranked by cost with a bar split by CLI. Opening a project shows cost per day as bars (hover for the day), the split by CLI and by way of working (terminal, desktop app, editor, SDK), its top models, and a weekday-by-hour activity grid. Folder paths never leave the Mac.
- Projects on Quota Run: signed in, each project has a Public on quota.run switch, off for every project until turned on, a public name, and a button to open its page once it is up. This Mac uploads tokens per day by project, CLI, way of working and model: public projects with their name and repository, all others folded together as other projects without a name; paths and session content are never uploaded. quota.run prices the tokens itself at list rates. Changing a switch or a name sends every day again, so a project turned off comes down from the site right away. The consent sheet lists this upload too.

### 2026-09-13

#### Added

- The menu bar icon's right-click menu and the panel's More menu gain a Quota Run item: Sign In to Quota Run… when this Mac isn't signed in, opening Settings scrolled straight to the sign-in card, or Quota Run · @username… once it is, opening the Quota Run page.
- The right-click menu on a provider card in the panel gains three groups of quick settings. "Limits on the Card" ticks which limits show and which fold under the disclosure arrow, remembered per provider, with Restore Default, and the last one cannot be unticked. "Ring Follows" picks the window the dock ring, notch island and menu bar follow, the same choice as double-clicking a window. "Show In" ticks whether the provider appears in the panel, the dock, the notch island and desktop cards, plus "Menu Bar Shows Only" this provider and "Add a Desktop Card" for it. "Hide from Panel" and "Ring follows the fullest window" fold into these groups.
- Updates come as an update card: when a new version is found, a card shows its number, the version you have, the release date and what changed (in the interface's language, grouped into added, style and fixed, with Show all and a link to the full changelog). Install and Relaunch downloads it, checks the developer's signature and Apple's notarization, then replaces the app and relaunches; the app no longer relaunches without asking. The Updates setting becomes "Download in background" (downloaded and verified as soon as it is found, so installing is instant) or "Download when I install". If replacing the app fails, for example without write access to Applications, the card says why and offers Try Again and Download Installer. The menu bar's right-click menu, the panel's banner and the Updates page all open the card, which opens by itself once per version per launch.
- Spend budgets: Settings → Alerts has a new Spend card with a daily and a monthly budget (in the currency chosen when set; empty means none). A notification comes once at 80% and once when a budget is passed, per day and per calendar month.
- Weekly digest: after 9 on Monday morning, a notification with last week's spend, token count and the busiest CLI's share; nothing is sent for a week without usage. It can be turned off under Settings → Alerts → Spend.
- A reset calendar: Settings → Usage opens with "Resets in the next 7 days", listing by day when each enabled provider's windows start again (today, tomorrow, then dates and times) with how much is left or used, amber or red when close to the limit.
- The dock rings' right-click menu gains the same three groups as a panel card's: Limits on the Card, Ring Follows and Show In.
- Quota Run: a new Quota Run page in Settings. Without an account, every reading goes into a local run ledger (60 days) showing windows in progress and personal bests — fastest to 100%, time to 50% and 90%, highest peak — and a best can be copied or saved as a share image. To compete, tick the list of what is uploaded and choose Sign In with quota.run: the app opens the browser and shows a code; sign in on quota.run with Google, GitHub or an email code (picking a username the first time), check the code and approve this Mac. The app never handles a password or a third-party token. This Mac then signs with a key in the Secure Enclave and, as the ranked device, uploads quota readings and per-minute token counts to quota.run; the server computes results and ranks, shown at quota.run and on a public profile at quota.run/@username. Signed in, the page shows @username, how the account signs in and each Mac's QuotaBar version; edit a profile and up to 12 projects, or open the account page with Manage Account on quota.run. Another Mac joins by signing in with the same account, the ranked device changes once every 7 days, Disconnect This Mac keeps the account and local records, and Delete Account removes everything on quota.run, each after a confirmation. Ranked results, each run's usage curve and the profile's heatmap of tokens per day are public on quota.run (the heatmap can be turned off on the account page), while the sign-in email is used only to sign in and never shown on a profile or board; the consent text says so. Credentials, tokens, prompts, code, file paths and plain emails are never uploaded, and nothing at all is uploaded without joining. The About page's list of connections includes Quota Run.
- Quota Run provider accounts: only readings that say which provider account they come from are uploaded and ranked, and the app uploads only a one-way digest of the account email, which never leaves the Mac. Each Codex, Claude or other provider account belongs to one Quota Run account: the first to upload it, unless another account signs in with that same email and claims it, which shows Account verified on its runs. Settings → Quota Run gains a Provider Accounts card listing the account each provider is signed in with on this Mac (email masked) and its status — Not uploaded yet, Bound, Account verified, or Owned by another Quota Run account with how to claim it — with Unbind (after a confirmation, deletes that account's readings and runs on quota.run and stops uploading it from this Mac) and Bind Again. Personal bests mark a run without a bound account as "Not bound to an account — won't rank".

#### Style

- Explanations in Settings no longer sit under every setting: the grey text that crowded the label column and often broke onto two lines is now a small question mark by the title that shows the explanation on hover (or click), and a card's general notes sit behind a question mark by its heading. A wrong proxy address is still called out beside the field, the bio and project description counters sit by their fields, and "optional" moved into the placeholders.
- An expanded row in Settings → Providers no longer gives "Test connection" and "Console" a line of their own: "Console" follows the provider's name and "Test connection" sits on the right ahead of the service status, level with the name; the test's result still appears below. Providers that need Save, browser sign-in or keychain authorisation keep those buttons on a line below.
- Each Settings section's title and its explanation now share one line, on a common baseline, instead of stacking; in a narrow window the explanation is cut short first, with the full text on hover.
- "Test connection" in a provider row's header is a small chip with an icon, about as tall as the status pills, instead of a 30 pt button that made an open row taller than a closed one; in the open row, the service status text now lines up with its label, where it sat about 7 pt higher.
- Provider cards show the limits that fit the plan: Codex shows the plan's own limits — the 5-hour and the week on plans that have a 5-hour limit, the week alone on Pro, which has none — with GPT-5.3-Codex-Spark's limits under the disclosure arrow; Claude shows the 5-hour, the week and Fable. The window the ring follows is always shown. Other providers are unchanged.
- Dragging a provider card near the top or bottom of the panel's list scrolls the list, faster nearer the edge, with the card staying under the pointer, so a card can reach either end of a long list.

#### Fixed

- Switching the interface language lost the choices of what the ring follows and which limits a card shows: they are kept by window name, and window names change with the language ("周窗口" and "Weekly window"). The reread in the new language now carries each choice over to the same window's new name.
- The local API (127.0.0.1:6736) answers only requests addressed to 127.0.0.1 or localhost and refuses cross-site origins, so a web page cannot read the figures through DNS rebinding; anything else gets 403.
- After switching Codex, Claude or another CLI to a different account, the next reading could pass for a reset — the other account's usage is lower and its reset time different — with a reset banner and notification, and the trend line joined the two accounts. A reading from a different account than last time is no longer a reset, and that provider's trend starts afresh.

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

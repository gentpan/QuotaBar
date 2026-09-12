<div align="center">

<img src="Assets/icon.png" alt="QuotaBar" width="112" height="112">

# QuotaBar

**Every AI coding limit, at a glance — in the menu bar, the notch, at the screen's edge or on the desktop.**

[![Release](https://img.shields.io/github/v/release/gentpan/quotabar?color=6ee02b&label=release)](https://github.com/gentpan/quotabar/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/gentpan/quotabar/total?color=6ee02b&label=downloads)](https://github.com/gentpan/quotabar/releases)
[![Stars](https://img.shields.io/github/stars/gentpan/quotabar?style=flat&color=f5c518&label=stars)](https://github.com/gentpan/quotabar/stargazers)
[![Last commit](https://img.shields.io/github/last-commit/gentpan/quotabar?color=black&label=last%20commit)](https://github.com/gentpan/quotabar/commits/main)
[![Commit activity](https://img.shields.io/github/commit-activity/m/gentpan/quotabar?color=black&label=commits)](https://github.com/gentpan/quotabar/graphs/commit-activity)
[![CI](https://github.com/gentpan/quotabar/actions/workflows/ci.yml/badge.svg)](https://github.com/gentpan/quotabar/actions/workflows/ci.yml)
[![macOS](https://img.shields.io/badge/macOS-14%2B-black)](https://github.com/gentpan/quotabar/releases/latest)
[![License](https://img.shields.io/badge/license-MIT-black)](LICENSE)

QuotaBar is a macOS menu-bar app that shows how much of each AI coding service's quota
you have used, when each window resets, and roughly what it has cost — for twenty-three
providers, read and worked out on your own Mac. No account, no telemetry.

[Download](https://github.com/gentpan/quotabar/releases/latest) ·
[Website](https://quota.bar) ·
[Changelog](CHANGELOG.md) ·
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

Or download the `.dmg` from [Releases](https://github.com/gentpan/quotabar/releases/latest)
and drag `QuotaBar.app` into `/Applications`. Builds are signed with a Developer ID
certificate and notarized by Apple, so Gatekeeper opens them without a detour.

Requires macOS 14 (Sonoma) or later. Apple Silicon and Intel. The interface is in
English and Simplified Chinese and follows the system language unless you pick one.

## Recent updates

<!-- changelog:start -->
<!-- Generated from CHANGELOG.md by Scripts/sync_changelog.py. Do not edit by hand. -->

Latest release **0.5.0** (2026-09-13) · **4** changes in development · [full changelog](CHANGELOG.md) (kept in Chinese)

<details open>
<summary><b>2026-09-13</b> · Unreleased · 3 style · 1 fixed</summary>

**Style**

- 边缘停靠条的展开改为两段：小胶囊先横向拉宽，再纵向拉高，圆环在形状里淡入滑出，不会露在黑色区域外；收起时先缩短高度，再收窄回胶囊。
- 字标 QuotaBar 的字体从 Sora 换成 Instrument Sans 半粗，设置侧边栏、关于页、下拉面板、刘海岛、分享卡片和复制图片的底栏都跟着换；关于页开源致谢里的字体一并改为 Instrument Sans。
- 分享用量卡片窗口不再有单独的灰色标题栏：标题栏改为透明，卡片预览和右侧设置一直铺到窗口顶部，和设置窗口一样是一整块；卡片和右侧标题避开左上角的红绿灯按钮并上下对齐。

**Fixed**

- 边缘停靠条悬停展开时会先瞬间离开屏幕边缘、露出一条缝隙：窗口不再在展开和收起时改变尺寸，只让黑色形状在窗口里生长，全程贴着屏幕边缘；没画出来的透明区域让鼠标直接穿透。

</details>

<details>
<summary><b>2026-09-13</b> · 0.5.0 · 40 added · 10 style · 13 fixed</summary>

**Added**

- 下拉面板回归：左键点菜单栏图标打开，右键仍是刷新、设置、退出。面板顶部是花费卡片，下面每个服务商一张卡片，底部显示版本、下次刷新倒计时、设置和选项菜单。按 Esc 关闭，⌘R 刷新，⌘, 打开设置。
- 花费卡片：可切换花费、Token、每百万 token 花费三种口径，以及今日、昨日、近 30 天。环形图按来源分色，中间数字滚动变化，悬停来源查看按模型的明细。
- 服务商卡片默认只显示最重要的两个额度窗口，其余窗口、限额重置次数、30 天用量趋势、今日昨日 30 天花费、状态页和控制台链接收在展开箭头里，展开状态会被记住。
- 进度条加入节奏判断：细竖线标出匀速使用时此刻应在的位置。预计余量很紧时显示约多少余量，预计重置前用完时显示火苗和用完时间，已经用完显示已到上限。悬停进度条查看按当前速度重置时的用量。
- 点击百分比在已用和剩余之间切换，点击重置时间在倒计时和具体时刻之间切换，所有界面同步生效。
- 右键服务商卡片或花费卡片可复制为图片，按 4 倍分辨率放进剪贴板，并弹出已复制提示。
- 周用量分享卡：按 API 价值或 token 数展示最近 7 天、30 天、3 个月、今年或全部时间，金额满 1000 美元变黑卡，满 1 万美元变蓝卡。可选 4:5、1:1、9:16 比例和署名，支持系统分享、保存 1080 像素 PNG、复制图片和文案。
- 用量存档：QuotaBar 自己保存每天每个模型的 token 与花费，Claude Code 清理旧日志后统计也不会变少。
- 启动时先显示上次保存的读数，再在后台刷新。
- 首次安装时自动检测本机已登录的工具，只开启对应服务商，并显示一张可关闭的欢迎卡片。
- 共享屏幕或录屏时可隐藏用量：菜单栏只显示 logo，停靠条、刘海岛和桌面卡片暂时隐藏。
- 三种节奏通知：快用完、余量很紧、重置前会用完，同一周期只提醒一次。
- 花费可显示为人民币、港币、日元、欧元等货币，汇率每天更新一次。
- token 统计口径可选包含缓存或仅输入和输出。
- 服务商请求可走 HTTP 或 SOCKS5 代理。
- 刘海岛光晕：黑色轮廓外一圈钴蓝柔光，接近告警线时渐变成琥珀色或红色，一道光沿轮廓环绕。可开启低功耗模式，只在刷新、悬停或告警时发光；刘海岛被全屏应用遮住时自动暂停动画。光晕区域不挡住鼠标点击。
- 刘海岛越线自动弹出：额度第一次超过告警线时，刘海岛自动展开约 4 秒再收回。
- 刘海岛面板分为额度、用量、总览三页，双指左右滑动或点底部圆点翻页。总览页显示今日和近 30 天花费、各来源占比，并可打开分享卡片。
- 刘海岛额度图表有条形、圆环、阶梯、数字、趋势线五种样式，点底部标签或在面板上按住 ⌘ 点击切换。
- 同步状态点改为缓慢呼吸，每次拿到新数据时轻跳一下。
- 桌面卡片：详细模式的进度条加上节奏刻度和重置倒计时，底部显示今日和近 30 天花费；标准模式在圆环下显示重置倒计时；可按紧迫度排序。
- 全局快捷键：在设置里录制一个组合键，在任何地方打开下拉面板。
- 本地接口：开启后本机其他工具可以从 http://127.0.0.1:6736/v1/limits 读取额度，不含凭据和账号；终端运行 `QuotaBar --json` 输出同样的数据。
- 测试版更新：开启后同时接收预发布版本。
- 设置页新增：变色方式、重置时间格式、12 或 24 小时制、始终显示节奏、减少动画、面板密度、显示花费卡片、刘海岛光晕与低功耗、越线自动弹出、刘海岛图表样式、桌面卡片按紧迫度排序、三种节奏提醒、货币、token 统计口径、共享屏幕时隐藏用量、代理、本地接口。
- 用量统计页和下拉面板都能打开用量分享卡片，版本更新后如果本周有用量会自动打开一次。
- 菜单栏新增"logo 加数字"模式：选中了服务商时只显示它，否则显示前三个已启用服务商的 logo 和百分比。
- 右键服务商卡片可以上移、下移，停靠条、刘海岛、桌面卡片和面板按同一顺序排列。
- 下拉面板可设为半透明，让桌面透过面板显示。
- 新增 10 个服务商，共 23 个：阿里云百炼 Coding Plan、火山方舟、智谱 GLM（国内站）、Kimi 开放平台余额、GitHub Copilot、OpenRouter、小米 MiMo、Qoder、Windsurf、Kiro。Copilot 直接使用本机 GitHub CLI 的登录；火山方舟读 arkcli，Windsurf、Kiro 读本机已登录的客户端；阿里云百炼和小米 MiMo 支持在应用内浏览器登录。除 Copilot 外暂时标为"实验性"，等真实账号验证。Copilot、Windsurf、Kimi 开放平台接入了公开状态页。
- 新增诊断命令 `QuotaBar --provider <服务商>`，单独拉取一个服务商的读数。
- 桌面卡片支持多张：大数字、环形仪表、花费趋势、每日对比、服务商网格、紧迫排行六种新样式，加上原来的经典样式；每张可选小、中、大三种尺寸，可指定服务商或统计来源，位置分别记住。右键卡片可更换样式、尺寸、服务商、添加卡片或删除，双击打开下拉面板。设置里的桌面小工具改为卡片列表，可添加卡片或恢复默认两张。原来开着桌面小工具的，会在原位置换成默认的两张：主服务商大数字，下面是花费趋势。
- 面板页脚新增"全部刷新"按钮：重新读取所有服务商、服务状态和本地日志，并重新读取登录凭据，刷新期间转圈。⌘R 和选项菜单里的刷新也改为全部刷新。单张卡片右上角的按钮仍只刷新该服务商。
- 关于页重做：GitHub 和 X 链接换上各自的品牌图标，新增邮件链接 hello@quota.bar；加入一段程序介绍；底部显示更新日期、更新日志入口、系统要求（macOS 14 或更高）、版权 © 2026 QuotaBar 和 MIT 开源许可；"你的数据"里列出 App 会连接的全部地址；新增"开源致谢"，列出 codex-island、OpenUsage、CodexBar、theSVG 和 Sora 字体的作者与许可；页尾加上与各服务商及 GitHub、X 无隶属关系的商标声明；标语改为"每个 AI 编码额度，抬眼就看见"，与官网一致。
- 额度重置时刻：5 小时、每周等额度窗口重置后，QuotaBar 会在重置时间点自动重新读取该服务商，不用等下一次定时刷新（服务商还没翻篇时每分钟再试，最多 3 次）。颜色一律跟随服务商（Claude 橙、Codex 蓝），菜单栏保持黑白。
- 额度重置 · 菜单栏图标：进度平滑回满，按钮底下亮一下，再有一道高光从左往右扫过图标。
- 额度重置 · 边缘停靠条：自动滑出，对应服务商的圆环被品牌色的光弧扫满一圈并向外扩散两圈波纹，圆环轻轻放大；旁边滑出「刚刚重置」卡片，可用百分比滚动到新值、进度条填满，并写明之前只剩多少；约 3 秒后收回，鼠标停在上面则保持打开。
- 额度重置 · 刘海岛：像灵动岛一样带回弹展开一行，迷你圆环画满，显示「额度已重置」、服务商和窗口名，数字滚动，光晕用服务商的颜色，约 4 秒后收回。
- 额度重置 · 下拉面板和卡片：对应额度行先用品牌色亮一下再淡回，「刚刚重置」标签弹出、箭头转一圈，保留十分钟；桌面卡片右上角的状态也暂时换成「刚刚重置」。
- 重置通知：可选关闭、用满后（默认，只在该窗口用过 90% 以上时）或每次。应用关闭期间发生的旧重置不会补发提示。设置 → 提醒新增「额度重置」卡片；终端运行 `QuotaBar --simulate-reset claude` 可以预览效果。

**Style**

- 停靠条悬浮卡片的额度行换成新的共用额度行，带节奏提示和点击切换。
- 展示方式里的"菜单栏"改名为"仅菜单栏"，分享卡片和具体重置时间的日期跟随界面语言显示。
- 面板页脚改为一行：版本号后面接下次自动刷新的时间。
- 复制为图片的底栏改为：左侧是绿色底的 QuotaBar 应用图标加名称，右侧单独放网址 quota.bar，不再写成"QuotaBar · quota.bar"。
- 花费卡片头部重构：左侧改为下拉标题，点开在花费、Token、每百万 token 花费之间选择；右侧说明、分享、复制改为三个同样大小、对齐的按钮，点说明会显示数据来源。三个图标缩放到同一个方框内，高度一致，并与左侧下拉标题的中心线对齐。
- 按钮按下时轻微缩小，动画曲线统一；图表切换时带轻微模糊过渡。支持"减少动画"，并跟随系统的减弱动态效果设置。
- 设置里桌面卡片的尺寸切换在英文界面下改为 S / M / L，不再把 Medium 截成 Med...；桌面多服务商卡片英文底栏写作"4 providers · % left"，大数字卡片的窗口名和"left"之间补上空格；"屏幕"说明的英文措辞重写。
- 设置窗口的控件统一为一套样式：下拉选择、分段切换、按钮、输入框同为 30pt 高，同样的圆角、底色和细边框，放在一行里高度对齐。桌面卡片的样式与服务商、货币选择改为新的下拉控件，点开时当前项叠在控件上并打勾，文字与控件对齐；"添加卡片"改为同款带箭头的按钮。
- 设置里的开关打开时显示为绿色，不再是深灰。只有一行标题的开关行与输入行等高，卡片内的行距一致；左侧标签与右侧控件垂直居中。
- 分享用量卡片窗口的下拉、署名输入框、开关和分享、保存、复制按钮换成同一套控件样式。

**Fixed**

- 卡片翻到用量背面、刘海岛用量页、用量统计页在每次启动后第一次打开要等十来秒：现在直接从本地存档算出，打开即显示。
- 启动后花费卡片要等约 8 秒才有数字：现在启动时从本地存档读出，约 2 毫秒；后台只补读最近两天改动过的日志，之后每次约 30 毫秒。
- 启动后很快翻到卡片背面，会误显示"本地还没有记录"。
- 长时间运行时内存持续增长：正在写入的会话日志每次刷新都会多缓存一份，现在每个文件只保留一份，不再扫描到的文件会被释放。
- 停靠条在圆环之间切换卡片时不再每次重新计算卡片尺寸，切换更顺。
- Codex 的套餐标签分不清两种 Pro：现在按接口返回的套餐标识显示为 PRO 5X 或 PRO 20X。
- 刷新间隔最低改为 5 分钟，避免 Anthropic 用量接口限流；旧配置里的 1 分钟、2 分钟会自动改为 5 分钟。
- 切换界面语言后，额度窗口名称、套餐说明、错误信息仍停留在原来的语言，要等下次自动刷新才变：现在切换语言会立刻重新读取所有服务商和服务状态。
- 上次保存的读数会记录它是用哪种语言取得的，换了语言启动时不再显示另一种语言的旧文字（升级后首次启动会先读取一次，不沿用旧缓存）。
- 中文界面的服务状态不再显示状态页的英文标题（如 All Systems Operational），改为中文状态级别；具体事件名称仍保留状态页原文。
- 英文界面花费说明里的来源列表用了中文顿号，现在按语言使用逗号或顿号。
- 桌面卡片在还没有读数时，仪表环、服务商网格和排行进度条会画成满格绿色，节奏格显示"够用"：现在画成空的，数字和节奏显示横线。
- 关于页的联网说明漏写了一项：模型价目表也是从 GitHub 获取的（LiteLLM 价目表），现在已补上。

</details>

<details>
<summary><b>2026-09-12</b> · 0.5.0 · 6 added · 1 style · 2 fixed</summary>

**Added**

- 悬浮卡片里双击某个额度窗口（5 小时、周窗口，或 Fable 这类按模型的额度），圆环、刘海岛、桌面卡片和菜单栏读数都改按这个窗口显示。再双击一次恢复为用得最满的那个。正在跟随的窗口名旁有圆点，手动选中时为品牌色实心点。
- 展示方式新增「屏幕」选项：接了多块显示器时，可以选择停靠条、刘海岛和桌面卡片显示在哪块屏幕，默认自动。所选屏幕拔掉后自动回到默认，插拔显示器时各窗口会重新定位。
- 服务状态页的每一行在折叠时就显示主服务最近 30 天的在线率和状态条。Claude 取 Claude Code，Codex 取 CLI，Cursor 取 IDE，Kimi 取 Open API，DeepSeek 取 API 服务。
- 服务状态标记改为只看写代码相关的服务：Claude 看 Claude Code 和 Claude API，Codex 看 CLI、VS Code 插件、Codex API、Codex Web 和桌面端，Cursor 看 IDE、CLI 和云端 Agent。状态页其他组件的事件（如 Claude Cowork）不再让标记变黄，展开服务状态行时单独列在「其他组件」下。
- 新增诊断命令 `QuotaBar --status`，列出各服务商状态标记依据的组件和其他组件的事件。
- 新增诊断命令 `QuotaBar --credentials`，显示各本机凭据能否读到以及读取方式，不输出密钥。

**Style**

- 设置页不再闪出右侧滚动条，展开服务状态行时也不会。

**Fixed**

- Codex 的状态读不到 CLI 组件：OpenAI 状态页的汇总接口不含 CLI，现在缺少时会补读完整组件列表。
- 重装或更新后，打开应用又弹出「Claude Code-credentials」钥匙串授权对话框。现在改为通过系统自带的 security 工具读取，与 Claude Code 自己的读取方式相同，不再因应用签名变化而重复询问。

</details>

<!-- changelog:end -->

## Activity

<p align="center">
  <img src="Assets/readme/activity.svg" alt="Commits per day over the last 26 weeks" width="760">
</p>

<p align="center">
  <a href="https://star-history.com/#gentpan/quotabar&Date">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=gentpan/quotabar&type=Date&theme=dark">
      <img alt="Star history" src="https://api.star-history.com/svg?repos=gentpan/quotabar&type=Date" width="760">
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
- `web/` — the website. Static, no build step.

Adding a provider, and every design decision worth knowing before changing one:
[ARCHITECTURE.md](ARCHITECTURE.md). Every change to the app is logged, dated, in
[CHANGELOG.md](CHANGELOG.md).

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

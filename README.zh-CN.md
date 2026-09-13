<div align="center">

<img src="Assets/icon.png" alt="QuotaBar" width="112" height="112">

# QuotaBar

**每个 AI 编码额度，抬眼就看见——在菜单栏、刘海、屏幕边缘或桌面上。**

[![Release](https://img.shields.io/github/v/release/gentpan/QuotaBar?color=6ee02b&label=%E7%89%88%E6%9C%AC)](https://github.com/gentpan/QuotaBar/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/gentpan/QuotaBar/total?color=6ee02b&label=%E4%B8%8B%E8%BD%BD)](https://github.com/gentpan/QuotaBar/releases)
[![Stars](https://img.shields.io/github/stars/gentpan/QuotaBar?style=flat&color=f5c518&label=%E6%98%9F%E6%A0%87)](https://github.com/gentpan/QuotaBar/stargazers)
[![Last commit](https://img.shields.io/github/last-commit/gentpan/QuotaBar?color=black&label=%E6%9C%80%E8%BF%91%E6%8F%90%E4%BA%A4)](https://github.com/gentpan/QuotaBar/commits/main)
[![Commit activity](https://img.shields.io/github/commit-activity/m/gentpan/QuotaBar?color=black&label=%E6%8F%90%E4%BA%A4)](https://github.com/gentpan/QuotaBar/graphs/commit-activity)
[![CI](https://github.com/gentpan/QuotaBar/actions/workflows/ci.yml/badge.svg)](https://github.com/gentpan/QuotaBar/actions/workflows/ci.yml)
[![macOS](https://img.shields.io/badge/macOS-14%2B-black)](https://github.com/gentpan/QuotaBar/releases/latest)
[![License](https://img.shields.io/badge/license-MIT-black)](LICENSE)

QuotaBar 是一款 macOS 菜单栏应用，显示每个 AI 编码服务的额度用了多少、各个窗口何时重置、
大约花了多少钱。支持 23 个服务商，全部在你自己的 Mac 上读取和计算。无需注册账号，没有任何统计上报。

[下载](https://github.com/gentpan/QuotaBar/releases/latest) ·
[官网](https://quota.bar) ·
[更新日志](CHANGELOG.md) ·
[架构说明](ARCHITECTURE.md)

[English](README.md) · **简体中文**

</div>

---

## 安装

```bash
brew tap gentpan/tap
brew trust gentpan/tap      # Homebrew 6 需要先信任第三方 tap
brew install --cask quotabar
```

也可以从 [Releases](https://github.com/gentpan/QuotaBar/releases/latest) 下载 `.dmg`，
把 `QuotaBar.app` 拖进「应用程序」。安装包使用 Developer ID 证书签名并经过 Apple 公证，
Gatekeeper 可以直接打开。

需要 macOS 14（Sonoma）或更高版本，支持 Apple 芯片和 Intel。界面提供英文和简体中文，
默认跟随系统语言，也可以在设置里指定。

## 最近更新

<!-- changelog:start -->
<!-- 由 Scripts/sync_changelog.py 从 CHANGELOG.md 生成，请勿手改。 -->

最新版本 **0.5.3**（2026-09-13） · 开发中 **12** 项改动尚未发布 · [完整更新日志](CHANGELOG.md)

<details open>
<summary><b>2026-09-13</b> · 未发布 · 新增 6 · 样式 4 · 修复 2</summary>

**新增**

- 下拉面板服务商卡片的右键菜单新增三组快捷设置：「卡片上显示的额度」逐项勾选哪些额度显示在外面、哪些收进展开箭头（每个服务商分别记住，可恢复默认，最后一项不能取消）；「圆环跟随的额度」选择停靠条圆环、刘海岛和菜单栏跟随的窗口，与双击窗口是同一个设置；「显示位置」勾选这个服务商是否出现在下拉面板、停靠条、刘海岛和桌面卡片，另有「菜单栏只显示此服务商」和「添加一张此服务商的桌面卡片」。原来的「在下拉面板中隐藏」和「圆环改回按最满的窗口显示」并入这几组。
- 在线更新改为更新卡片：发现新版本时弹出一张卡片，显示新版本号、当前版本、发布日期和这一版的更新内容（按界面语言显示中文或英文，分新增、样式、修复，可展开全部并打开完整更新日志），点「安装并重启」后下载、验证开发者签名和 Apple 公证，完成后自动替换并重启；不会再不打招呼就重启。「更新方式」改为「后台下载」（发现后先在后台下载验证好，点安装即刻完成）和「安装时再下载」。原地替换失败（例如没有「应用程序」文件夹的写入权限）时，卡片说明原因并提供「重试」和「下载安装包」。菜单栏右键菜单、面板顶部横幅和设置里的更新页都打开这张卡片；同一版本每次启动只自动弹出一次。
- 花费预算提醒：设置 → 提醒新增「花费」卡片，可设每日预算和每月预算（按设置时选的货币，留空即不设），花费用到 80% 和超出时各发一次通知，按天和按自然月分别计算。
- 每周用量周报：每周一上午 9 点后推送一条通知，写明上周的花费、token 数和用得最多的 CLI 所占比例；上周没有用量时不发。可在设置 → 提醒 →「花费」里关闭。
- 额度重置日历：设置 → 用量统计顶部新增「接下来 7 天的额度重置」，按天列出已开启服务商的每个额度窗口什么时候重置（今天、明天、具体日期和时间），以及当前剩余或已用，快用完的标成橙色或红色。
- 停靠条圆环的右键菜单也加上「卡片上显示的额度」「圆环跟随的额度」「显示位置」三组，和下拉面板卡片的右键菜单一致。

**样式**

- 设置 → 服务商里展开一行时，「测试连接」和「控制台」不再单独占一行：「控制台」紧跟在服务商名字后面，「测试连接」放在右侧服务状态之前，与名字水平对齐；测试结果仍显示在展开内容下方。需要保存凭据、浏览器登录或授权钥匙串的服务商，这些按钮仍在下方一行。
- 设置窗口右侧每个分区的标题和说明文字改为同一行显示，按文字基线对齐，不再上下两行；窗口太窄时说明文字先截断，鼠标悬停可看全文。
- 服务商行标题里的「测试连接」改为小胶囊按钮（带图标，和状态标签差不多高），不再是 30pt 高的大按钮，展开的行不会比收起时高出一截；展开内容里「服务状态」一行的文字与左侧标签对齐，之前比标签高出约 7pt。
- 服务商卡片默认显示的额度按套餐调整：Codex 只显示套餐本身的额度，有 5 小时限制的套餐显示 5 小时和周窗口，没有 5 小时限制的 Pro 套餐只显示周窗口，GPT-5.3-Codex-Spark 的额度收进展开箭头；Claude 显示 5 小时、周窗口和 Fable 三项。圆环正在跟随的窗口始终显示在外面。其他服务商不变。

**修复**

- 切换界面语言后，「圆环跟随的额度」和「卡片上显示的额度」这两项选择会失效：额度窗口的名字随语言变化（「周窗口」和「Weekly window」），选择是按名字记住的。现在切换语言重新读取时，会把选择对应到同一个窗口的新名字上。
- 本地接口（127.0.0.1:6736）只回应发给 127.0.0.1 或 localhost 的请求，并拒绝来自其他网站的跨站请求，防止网页通过 DNS 重绑定读到用量数字；其他请求返回 403。

</details>

<details>
<summary><b>2026-09-13</b> · 0.5.3 · 新增 1 · 修复 1</summary>

**新增**

- 菜单栏图标的右键菜单重做：新增「显示在菜单栏」，可选「自动（用得最满的额度）」或任一已开启的服务商，每项带 logo 和图标会显示的读数（剩余或已用），当前选择打勾；这个选择只影响菜单栏，停靠条、刘海岛、桌面卡片仍按各自的设置显示。菜单还新增「检查更新…」（有新版本时显示「更新到 x.y.z…」，下载好后显示「重新启动以更新到 x.y.z」）、「反馈…」和「关于 QuotaBar」，保留立即刷新（⌘R）、设置（⌘,）和退出（⌘Q）。

**修复**

- 关闭了自动检查更新时，更新页的「立即检查」和面板选项菜单里的「检查更新…」点了没有反应：手动检查现在不受自动检查开关限制。

</details>

<details>
<summary><b>2026-09-13</b> · 0.5.2 · 新增 2 · 样式 1</summary>

**新增**

- 边缘停靠条在服务商太多、屏幕放不下时可以滚动：条子最高到屏幕上下各留 24pt，其余圆环用滚轮或触控板在条子里滚动。系统滚动条换成内侧一条 2pt 的细线，静止时很淡，滚动时稍亮，停下后淡回去；上下还有更多圆环时，两端渐隐到黑色。滚动时悬停卡片先收起，悬停卡片与圆环的对齐会算上滚动距离；额度重置时，对应的圆环会先自动滚到可见处。
- 下拉面板里的服务商卡片可以按住拖动排序：拖动时卡片微微浮起、跟着鼠标走，经过相邻卡片一半时两张互换位置，其他卡片滑开让位；松手后卡片落位，新顺序同时用于停靠条、刘海岛和桌面卡片。卡片里的点击（切换已用和剩余、重置时间等）不受影响，移动超过几个点才开始拖动；在面板外松手也会正常落位并保存。

**样式**

- 关于页的 GitHub 链接显示为仓库的新名字 gentpan/QuotaBar，反馈、更新检查等地址也一并换成新地址。

</details>

<!-- changelog:end -->

## 项目动态

<p align="center">
  <img src="Assets/readme/activity.zh.svg" alt="近 26 周每天的提交次数" width="760">
</p>

<p align="center">
  <a href="https://star-history.com/#gentpan/QuotaBar&Date">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=gentpan/QuotaBar&type=Date&theme=dark">
      <img alt="星标增长曲线" src="https://api.star-history.com/svg?repos=gentpan/QuotaBar&type=Date" width="760">
    </picture>
  </a>
</p>

## 服务商

| 服务商 | 数据来源 | 凭据 |
|---|---|---|
| Codex | `~/.codex/auth.json` OAuth → `chatgpt.com/backend-api/wham/usage` | 自动 |
| Claude | Claude Code 钥匙串项 → `api.anthropic.com/api/oauth/usage` | 自动 |
| Gemini | `~/.gemini/oauth_creds.json` → `cloudcode-pa.googleapis.com` | 自动 |
| Grok | `~/.grok/auth.json` → `cli-chat-proxy.grok.com/v1/billing` | 自动 / 手动 |
| Antigravity | `~/.gemini/jetski-standalone-oauth-token` → `cloudcode-pa.googleapis.com` | 自动 |
| Cursor | Cursor 自己的 `state.vscdb` 会话 → `cursor.com/api/usage-summary` | 自动 / 手动 |
| OpenCode Go | `~/.local/share/opencode/auth.json` → `opencode.ai/zen/go/v1/usage` | 自动 / 手动 |
| Kimi Code | `kimi.com` 计费网关 | 手动填写 `kimi-auth` JWT |
| z.ai | `api.z.ai/api/monitor/usage/quota/limit` | 手动填写 API Key |
| MiniMax | `api.minimax.io` 编码套餐余量 | 手动填写 token / Cookie |
| Manus | `api.manus.im` 额度 | 手动填写会话 token |
| DeepSeek | `api.deepseek.com/user/balance` | 手动填写 API Key |
| Qwen Cloud | `home.qwencloud.com` 控制台 → token 套餐用量 | 手动填写 Cookie 请求头 |
| GitHub Copilot | GitHub CLI 登录 (`gh auth token`) → `api.github.com/copilot_internal/user` | 自动 / 手动 |
| 阿里云百炼 Coding Plan *（实验性）* | 百炼控制台网关 → 编码套餐额度 | Cookie 请求头 / 应用内登录 |
| 火山方舟 *（实验性）* | `arkcli usage plan --format json` | 自动（arkcli 登录） |
| 智谱 GLM *（实验性）* | `open.bigmodel.cn/api/monitor/usage/quota/limit` | 手动填写 API Key |
| Kimi 开放平台 *（实验性）* | `api.moonshot.cn/v1/users/me/balance` | 手动填写 API Key |
| OpenRouter *（实验性）* | `openrouter.ai/api/v1/credits` + `/key` | 手动填写 API Key |
| 小米 MiMo *（实验性）* | `platform.xiaomimimo.com/api/v1` 余额 + token 套餐 | Cookie 请求头 / 应用内登录 |
| Qoder *（实验性）* | `qoder.com/api/v2/me/usages/big_model_credits` | 手动填写 Cookie 请求头 |
| Windsurf *（实验性）* | Windsurf 自己的 `state.vscdb` 缓存套餐 | 自动 |
| Kiro *（实验性）* | `kiro-cli` 会话 → AWS `GetUsageLimits` | 自动 |

标为*实验性*的服务商按各家控制台和命令行工具的接口实现，但还没有用真实账号验证过，
设置里会同样标注。

**正常情况下不会弹窗。** Claude 是唯一一个把登录会话存放在*另一个应用*钥匙串项里的服务商。
QuotaBar 和 Claude Code 自己一样，通过 `/usr/bin/security` 读取；该工具写入的每个钥匙串项都信任它，
所以无论安装包用什么签名，macOS 都不需要询问。只有这次读取被拒绝时，才会出现
**允许访问钥匙串** 按钮；后台刷新从不弹出系统对话框，只有点这个按钮时才会。

## 在哪里看额度

**菜单栏与下拉面板**
- 11 种图标样式，其中 4 种是*阶梯*式，格数可以直接数出来，读数更准；也可以只显示文字、
  只显示 logo，或完全隐藏。
- 图标把**短周期**（5 小时滚动窗口）和**长周期**（每周、账单周期）分开显示，
  合在一起就看不出到底是哪个额度快用完了。
- 点击图标打开面板。顶部是花费卡片，可切换花费、token 数或每百万 token 花费，
  时间可选今日、昨日或 30 天，并按命令行工具拆分。下面每个服务商一张卡片，
  显示最重要的两个额度窗口；其余窗口、趋势、30 天花费和状态页收在展开区里。
- 点任意百分比在已用和剩余之间切换，点重置时间在倒计时和具体时刻之间切换。
  右键卡片可以复制为图片。
- `Esc` 关闭，`⌘R` 全部刷新，`⌘,` 打开设置。还可以设置全局快捷键，在任何地方打开面板。

**刘海岛**：带刘海的 Mac 上，数字显示在刘海两侧。鼠标悬停展开，有额度、用量、总览三页，
图表有五种样式。额度接近告警线时，光晕从蓝色渐变为琥珀色和红色；第一次越过告警线时，
刘海岛会自动弹出。低功耗模式下只在有变化时发光。

**屏幕边缘停靠条**：平时隐藏，鼠标移到屏幕边缘时出现。双击某个窗口（5 小时、每周、
某个模型单独的额度），选择圆环显示哪一个。

**桌面卡片**：数量不限，默认放在桌面上、窗口下方，也可以保持在最前。有大数字、仪表、
花费趋势、每日对比、服务商网格、快用完排行和经典列表几种样式，每种都有小、中、大三个尺寸。
拖动可移动，双击打开面板，右键可更换样式、尺寸或服务商。

接了两块屏幕时，可以选择刘海岛、停靠条和桌面卡片显示在哪块屏幕上。

## 节奏、提醒与花费

- **节奏**：每条进度条上有一条细竖线，标出匀速使用时此刻应在的位置。预计余量很紧时会提示；
  预计重置前用完时显示火苗和用完时间。
- **提醒**：告警和严重两档阈值，外加"快用完""余量很紧""重置前会用完"三种节奏提醒；
  每次越线只提醒一次，每个重置周期也只提醒一次。
- **额度重置**：窗口一重置，QuotaBar 立刻重新读取该服务商，并用该服务商的颜色标出来：
  停靠条滑出、圆环被扫满并弹出卡片，刘海岛展开「额度已重置」横幅，菜单栏图标回满并闪过一道高光，
  对应额度行显示「刚刚重置」；如果该窗口之前用过 90% 以上，还会发一条通知。
- **花费**：根据 Claude Code、Codex CLI 和 OpenCode 的本地会话日志估算，可以显示为美元或
  另外 10 种货币（每天更新参考汇率），token 可选全部计入或只算输入和输出。
  QuotaBar 自己按天、按模型保存存档，命令行工具清理旧日志后统计也不会变少。
- **用量页**：设置里有全年热力图和用量图表。
- **分享卡片**：最近 7 天、30 天、3 个月、今年或全部时间的用量，按 API 价值或 token 数展示；
  超过 1000 美元变黑卡，超过 1 万美元变蓝卡。比例可选 4:5、1:1、9:16，
  可保存为 1080 像素 PNG 或直接复制。
- **服务状态**：读取各服务商官方状态页，按写代码相关的组件判断（例如 Claude Code、Codex CLI），
  设置里可以查看 30 天记录。

## 你的数据

自动型服务商复用命令行工具已有的登录会话，应用不会向你索要密码。手动填写的 token 保存在
**macOS 登录钥匙串**中，不写入任何文件。偏好设置保存在 `~/.config/quotabar/config.json`
（权限 `0600`），其中不含任何密钥。没有统计，也没有遥测。

QuotaBar 只会连接这些地方：

- 你开启的服务商的用量接口，使用你自己的登录会话或密钥；
- 各服务的公开状态页，例如 `status.claude.com`；
- `open.er-api.com`，每天一次，获取汇率；
- GitHub，检查和下载更新，以及获取模型价目表（LiteLLM 的价目表）；
- `quota.bar`，仅在你提交反馈时。

设置了代理（HTTP、HTTPS 或 SOCKS5）时，以上请求都经过代理。你的用量不会发送到我们的服务器。
共享屏幕或录屏时，QuotaBar 可以隐藏数字，菜单栏只留下 logo。

## 给其他工具用

在「设置 → 通用」里打开**本地接口**，QuotaBar 会在本机提供 JSON 数据，只对这台 Mac 开放：

```bash
curl http://127.0.0.1:6736/v1/limits   # 所有额度窗口、百分比和重置时间
curl http://127.0.0.1:6736/v1/spend    # 今日、昨日、30 天的花费和 token 数
```

接口不包含任何凭据和账号名。也可以不打开应用，直接在终端获取同样的额度数据：

```bash
/Applications/QuotaBar.app/Contents/MacOS/QuotaBar --json          # 最多使用 5 分钟内的缓存
/Applications/QuotaBar.app/Contents/MacOS/QuotaBar --json --force  # 立即向每个服务商重新获取
```

## 首次使用

1. 全新安装时，QuotaBar 只开启本机已登录工具对应的服务商，并在面板里用一张欢迎卡片告诉你开启了几个。
2. 自动型服务商需要对应的命令行工具已登录（`codex`、`claude`、`gemini`、`grok`、`gh`），
   或已安装对应应用（Cursor、Windsurf）。
3. 手动型服务商：打开「设置 → 服务商」，按该行下方的说明粘贴 token，然后点**测试连接**，
   它会跳过所有缓存，直接向数据源请求。

面板每 5、15 或 30 分钟自动刷新，唤醒后和网络恢复时也会刷新；页脚的按钮可以一次刷新全部。
如果你从把凭据存在 `config.json` 里的旧版本升级，首次启动时凭据会迁移到钥匙串，并从文件中删除。

## 构建与运行

需要 macOS 14+ 和**完整的 Xcode 工具链**。只装 CommandLineTools 缺少 SwiftUI 宏插件，
编译会在 `@State` 处失败。

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
swift build && swift test
UNIVERSAL=0 ./Scripts/package_app.sh   # 在当前目录生成 QuotaBar.app；去掉 UNIVERSAL=0 会同时构建 Intel 版
open QuotaBar.app
```

这是一个菜单栏应用，没什么窗口可截图，可以离屏渲染各个界面，CI 会把前两条作为冒烟测试。
加上 `--lang en` 或 `--lang zh` 可以只渲染一种语言：

```bash
.build/debug/QuotaBar --snapshot ./snapshots             # 面板、停靠条、刘海条
.build/debug/QuotaBar --settings-preview ./settings      # 设置的每个分区，中英文各一份
.build/debug/QuotaBar --icon-preview ./icons             # 11 种菜单栏图标样式
.build/debug/QuotaBar --island-preview ./island          # 刘海岛各页与图表样式
.build/debug/QuotaBar --widget-concepts ./cards          # 每种桌面卡片的每个尺寸
```

毛玻璃、半透明材质和弹簧动画只在屏幕上存在，`ImageRenderer` 画不出来。要看这些效果，
请打开真实窗口：

```bash
.build/debug/QuotaBar --settings-window about
.build/debug/QuotaBar --panel-window
QUOTABAR_DOCK_TRACE=1 QUOTABAR_DOCK_SLIDE=2 ./QuotaBar.app/Contents/MacOS/QuotaBar
```

单独测试某个服务商：`QuotaBar --provider claude`；查看状态页：`QuotaBar --status`。

## 分发

只通过 Developer ID 分发，不上架 App Store。沙盒禁止读取 `~/.codex`、`~/.claude`
和其他应用的钥匙串项，而这正是全部功能所依赖的。

`package_app.sh` 会自动选择签名等级：

| 你有什么 | 其他用户看到什么 |
|---|---|
| 什么都没有 | 临时签名，只能在你自己的 Mac 上运行。其他人会看到*"QuotaBar 已损坏"*。 |
| Developer ID 证书 | 启用强化运行时。其他人会看到*"Apple 无法检查其是否包含恶意软件"*。 |
| 证书 + 公证 | Gatekeeper 放行，只有常规的*"从互联网下载"*提示。 |

公证凭据只需保存一次（需要一个 [App 专用密码](https://appleid.apple.com)）：

```bash
xcrun notarytool store-credentials QuotaBar \
  --apple-id you@example.com --team-id <YOUR_TEAM_ID>
```

### 发布新版本

```bash
./Scripts/release.sh
```

脚本会公证、装订票据、用 `ditto` 打包 zip（保留票据），构建签名并公证的 `.dmg`，
计算两者的 SHA-256，并把可直接提交的 Homebrew cask 写到 `dist/quotabar.rb`。
**如果 Gatekeeper 仍然拒绝这个安装包，脚本会拒绝生成发布**，签名不完整的版本不会误发给用户。
应用内更新只安装由本应用开发者签名并经 Apple 公证的下载包。

## 花费估算

根据本地的 `~/.claude/projects/**/*.jsonl`、`~/.codex/sessions/**/rollout-*.jsonl`
和 OpenCode 自己的数据库计算，价格来自按模型 ID 精确匹配的实时价目表。结果仅供参考，
**不是账单**：套餐内包含的用量、折扣，以及这些命令行工具之外发生的用量都统计不到。

有两处很容易算错，已经用测试固定下来：Claude Code 会把同一条助手回复写进每个重放它的会话文件
（按 `message.id` + `requestId` 去重）；Codex 报告的 `input_tokens` 已经包含
`cached_input_tokens`（不会重复计费）。

## 代码结构

- `Sources/QuotaCore`：服务商协议、HTTP 工具、配置与钥匙串存储、凭据读取、花费估算与用量存档、
  价目表、状态页、更新器，每组服务商一个文件。
- `Sources/QuotaBar`：应用本体，由 AppKit 状态栏项和面板承载 SwiftUI 界面，包括用量数据、
  菜单栏图标、下拉面板、设置、刘海岛、停靠条、桌面卡片、分享卡片和本地接口。
- `Tests/QuotaCoreTests`：解析样例、花费回归、配置迁移、更新校验。所有可测试的逻辑都在 QuotaCore 里。
- `site/index.html`：官网模板，所有文案写成 `[[English||中文]]`，由 `Scripts/sync_changelog.py`
  生成到 `web/`（英文在根目录，中文在 `web/zh/`）。部署的是 `web/`。

新增服务商的方法，以及修改前值得了解的设计决策，见 [ARCHITECTURE.md](ARCHITECTURE.md)。
应用的每次改动都按日期记录在 [CHANGELOG.md](CHANGELOG.md)（英文版 [CHANGELOG.en.md](CHANGELOG.en.md)）。

## 开源致谢

QuotaBar 参考或使用了以下开源项目和字体，在此致谢。

| 项目 | 作者 | 许可 | QuotaBar 参考或使用的部分 |
|---|---|---|---|
| [codex-island](https://github.com/ericjypark/codex-island) | Eric Park | MIT | 刘海岛的样式与动效 |
| [OpenUsage](https://github.com/robinebers/openusage) | Robin Ebers | MIT | 下拉面板、用量节奏提示与分享卡片 |
| [CodexBar](https://github.com/steipete/CodexBar) | Peter Steinberger | MIT | 各服务商用量的读取方式；QuotaBar 受其启发，用 Swift 独立重新实现 |
| [theSVG](https://github.com/GLINCKER/thesvg) | thesvg.org | MIT | 服务商标志的矢量原图，保存在 `Assets/logos-src-*.svg` |
| [Instrument Sans](https://github.com/Instrument/instrument-sans) | The Instrument Sans Project Authors | SIL OFL 1.1 | QuotaBar 字标和官网所用的字体 |

QuotaBar 是独立的第三方应用，与 Anthropic、OpenAI、Cursor、Google、xAI、GitHub、X
以及文中提及的其他公司均无隶属、认可或赞助关系。相关名称和标志归各自所有者所有。

## 许可

MIT，详见 [LICENSE](LICENSE)。

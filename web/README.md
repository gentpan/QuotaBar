# QuotaBar 官网

静态站，中英双语：英文在根目录，中文在 `zh/`。两种语言的首页都从同一个模板
`site/index.html` 生成，文案在模板里写成 `[[English||中文]]`；改文案、改版式都改
模板，然后运行 `python3 Scripts/sync_changelog.py`（`deploy_site.sh` 部署前会自动跑）。

```
web/
  index.html       英文首页（生成）
  changelog.html   英文更新日志，来自 CHANGELOG.en.md（生成）
  zh/index.html    中文首页（生成）
  zh/changelog.html 中文更新日志，来自 CHANGELOG.md（生成）
  styles.css  replica.css  app.js  replica.js    两种语言共用；脚本按 <html lang> 取文案
  assets/          真机截图（settings.png / settings-zh.png）、分享图（og.jpg / og-zh.jpg）、
                   应用图标、服务商 logo、Instrument Sans 字体
```

安装包不在这里：服务器上的 `download/` 由 `Scripts/publish_release.sh` 上传，部署时排除。

本地预览：

```bash
python3 -m http.server 8080 --directory web   # 然后打开 http://localhost:8080/ 与 /zh/
```

## 关于视觉

配色、字阶、间距和阴影取自 `onlook.cam-DESIGN.md` 里那套设计系统
（近黑画布、克制的高对比排版、分层微阴影）。**代码是重新写的** ——
没有复制 onlook.cam 的 `styles.css` 或 `app.js`，页面文案、截图和信息
架构都是 QuotaBar 自己的。

首屏壁纸是 macOS Mojave 的沙丘（白天、夜晚各一张 WebP）。Dock 里是 QuotaBar 读额度的
几个桌面应用：Claude、ChatGPT（Codex）、Cursor 的图标从装在 Mac 上的应用导出
（`assets/dock/`，裁到 824 的图标网格），Grok 用站点里的 Grok 标志做成同规格的黑底图标。
停靠条和桌面卡片都能拖动，位置记在本地（`qb-dock`、`qb-deskcard-pos`）。

## 截图怎么来的

全是真机截取的运行中的应用，不是模型图：

| 文件 | 内容 |
|---|---|
| `panel.png` | 菜单面板，选中 Codex |
| `dock.png` | 展开的边缘停靠条 |
| `notch.png` | 刘海条 |
| `settings.png` | 设置窗口 |

换新版后重新截一遍即可，尺寸不必对齐 —— 页面按百分比布局。

## 字体

字标和正文的西文用 Instrument Sans（SIL OFL 1.1，可变字体，字重 400–700、字宽
75–100），随站点分发，许可全文在 `assets/fonts/OFL.txt`；中文落到各平台的系统中文
字体（Mac 上是苹方）。页面顶部模仿 macOS 的菜单栏和刘海岛、停靠条等仿真组件保留系统字体。

#!/usr/bin/env python3
"""Puts the changelogs where people look, builds the website, draws the commit calendar.

    python3 Scripts/sync_changelog.py

From CHANGELOG.md (Chinese), CHANGELOG.en.md (English) and `git log`:

- the "recent updates" block in README.md (English) and README.zh-CN.md, between
  <!-- changelog:start --> and <!-- changelog:end -->;
- the website in both languages: English at the root, Chinese under /zh/.
  site/index.html is the template — every piece of copy is written there as
  [[English||中文]] — and becomes web/index.html and web/zh/index.html, with the
  recent-updates block and the provider strip filled in; web/changelog.html and
  web/zh/changelog.html are the whole log as a page;
- Assets/readme/activity.svg and activity.zh.svg, 26 weeks of commits;
- the provider strip, provider count and download links, from ProviderID in
  Sources/QuotaCore/Models.swift, the app's logos and the latest release.

Run it after every CHANGELOG edit; deploy_site.sh runs it before publishing.
Standard library only, so it runs on a stock Mac and in CI.
"""

import datetime
import html
import math
import pathlib
import re
import shutil
import struct
import subprocess
import zlib
from collections import Counter

ROOT = pathlib.Path(__file__).resolve().parent.parent
REPO = "https://github.com/gentpan/QuotaBar"
RECENT_DAYS = 3
SITE_PREVIEW_ITEMS = 5
WEEKS = 26

KIND_EN = {"新增": "Added", "样式": "Style", "修复": "Fixed", "删除": "Removed", "移除": "Removed"}
# Badge colour per kind on the website: added green, style blue, fixed amber,
# removed red; anything else neutral. Both changelogs' headings map.
KIND_CLASS = {"新增": "add", "样式": "style", "修复": "fix", "删除": "remove", "移除": "remove",
              "Added": "add", "Style": "style", "Fixed": "fix", "Removed": "remove"}
DOWNLOAD = "https://quota.bar/download/QuotaBar-{version}.dmg"
GITHUB_DOWNLOAD = "https://github.com/gentpan/QuotaBar/releases/download/v{version}/QuotaBar-{version}.dmg"

# The two languages of the website. English lives at the root, Chinese under
# /zh/, so every page-relative asset path in the Chinese copy climbs one level.
LANGS = {
    "en": {"lang": "en", "dir": "", "root": "", "url": "https://quota.bar/",
           "en_url": "./", "zh_url": "zh/", "other_url": "zh/"},
    "zh": {"lang": "zh-CN", "dir": "zh/", "root": "../", "url": "https://quota.bar/zh/",
           "en_url": "../", "zh_url": "./", "other_url": "../"},
}


def kind_class(kind):
    return KIND_CLASS.get(kind, "other")


def release_commit(version):
    """(short, full) hash of a release: its tag, else the commit that cut it."""
    def run(*args):
        return subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True).stdout.strip()
    full = run("rev-list", "-n", "1", f"v{version}") or run(
        "log", "-1", "--format=%H", "-E", f"--grep=^(Release|QuotaBar|Bump to) v?{re.escape(version)}$")
    return (full[:7], full) if full else (None, None)


# ── CHANGELOG.md ──────────────────────────────────────────────────────────

def parse(text):
    """Releases, newest first: each with its days, each day with its groups.

    "## 未发布" holds "### YYYY-MM-DD" days; "## 0.4.0 · 2026-09-12" holds its
    groups directly, which count as one day on the release date.
    """
    releases, release, day, group = [], None, None, None
    intro = []
    for line in text.splitlines():
        heading = re.match(r"^## (.+)$", line)
        dated = re.match(r"^### (\d{4}-\d{2}-\d{2})\s*$", line)
        kind = re.match(r"^#### (.+)$", line)
        if heading:
            title = heading.group(1).strip()
            version = re.match(r"^v?([\d.]+)\s*·\s*(\d{4}-\d{2}-\d{2})$", title)
            release = {
                "version": version.group(1) if version else None,
                "date": version.group(2) if version else None,
                "title": version.group(1) if version else title,
                "days": [],
            }
            releases.append(release)
            day = {"date": release["date"], "groups": []} if version else None
            if day:
                release["days"].append(day)
            group = None
        elif dated and release is not None:
            # A release that kept its dated days: drop the empty day that
            # stood in for the release date.
            if release["days"] and not release["days"][-1]["groups"]:
                release["days"].pop()
            day = {"date": dated.group(1), "groups": []}
            release["days"].append(day)
            group = None
        elif kind and day is not None:
            group = {"kind": kind.group(1).strip(), "items": []}
            day["groups"].append(group)
        elif line.startswith("- ") and group is not None:
            group["items"].append(line[2:].strip())
        elif line.startswith("  ") and line.strip() and group is not None and group["items"]:
            group["items"][-1] += line.strip()
        elif release is None and line.strip() and not line.startswith("#"):
            intro.append(line.strip())
    for release in releases:
        release["days"] = [d for d in release["days"] if any(g["items"] for g in d["groups"])]
    return intro, [r for r in releases if r["days"]]


def day_entries(releases):
    """Every day, newest first, with the release it belongs to."""
    days = [(release, day) for release in releases for day in release["days"]]
    days.sort(key=lambda pair: pair[1]["date"] or "", reverse=True)
    return days


def item_count(day):
    return sum(len(g["items"]) for g in day["groups"])


def counts(day, en):
    parts = []
    for g in day["groups"]:
        n = len(g["items"])
        if en:
            parts.append(f"{n} {KIND_EN.get(g['kind'], g['kind']).lower()}")
        else:
            parts.append(f"{g['kind']} {n}")
    return " · ".join(parts)


def latest_release(releases):
    return next((r for r in releases if r["version"]), None)


def unreleased(releases):
    return next((r for r in releases if not r["version"]), None)


# ── README ────────────────────────────────────────────────────────────────

def readme_block(releases, en):
    latest = latest_release(releases)
    pending = unreleased(releases)
    pending_count = sum(item_count(d) for d in pending["days"]) if pending else 0
    lines = ["<!-- changelog:start -->"]
    lines.append("<!-- Generated from CHANGELOG.en.md by Scripts/sync_changelog.py. Do not edit by hand. -->"
                 if en else "<!-- 由 Scripts/sync_changelog.py 从 CHANGELOG.md 生成，请勿手改。 -->")
    head = []
    if latest:
        head.append(f"Latest release **{latest['version']}** ({latest['date']})" if en
                    else f"最新版本 **{latest['version']}**（{latest['date']}）")
    if pending_count:
        head.append(f"**{pending_count}** changes in development" if en
                    else f"开发中 **{pending_count}** 项改动尚未发布")
    head.append("[full changelog](CHANGELOG.en.md)" if en else "[完整更新日志](CHANGELOG.md)")
    lines += ["", " · ".join(head), ""]
    for index, (release, day) in enumerate(day_entries(releases)[:RECENT_DAYS]):
        label = release["version"] or ("Unreleased" if en else "未发布")
        opened = " open" if index == 0 else ""
        lines.append(f"<details{opened}>")
        lines.append(f"<summary><b>{day['date']}</b> · {label} · {counts(day, en)}</summary>")
        lines.append("")
        for g in day["groups"]:
            lines.append(f"**{KIND_EN.get(g['kind'], g['kind']) if en else g['kind']}**")
            lines.append("")
            lines += [f"- {item}" for item in g["items"]]
            lines.append("")
        lines.append("</details>")
        lines.append("")
    lines.append("<!-- changelog:end -->")
    return "\n".join(lines)


def replace_block(path, block, start="<!-- changelog:start -->", end="<!-- changelog:end -->"):
    text = path.read_text(encoding="utf-8")
    pattern = re.compile(re.escape(start) + r".*?" + re.escape(end), re.S)
    if not pattern.search(text):
        raise SystemExit(f"{path.relative_to(ROOT)}: no {start} … {end} markers")
    updated = pattern.sub(lambda _: block, text, count=1)
    if updated != text:
        path.write_text(updated, encoding="utf-8")
        return True
    return False


# ── Website ───────────────────────────────────────────────────────────────

def inline(text):
    """Escapes an entry and turns `code` into <code>."""
    return re.sub(r"`([^`]+)`", r"<code>\1</code>", html.escape(text, quote=False))


def pick(en, zh, lang):
    return en if lang == "en" else zh


def site_block(releases, lang):
    t = lambda en, zh: pick(en, zh, lang)
    latest = latest_release(releases)
    days = day_entries(releases)
    newest = days[0][1]["date"] if days else ""
    version = latest["version"] if latest else "—"
    lines = [
        "<!-- changelog:start -->",
        "  " + t("<!-- Generated from CHANGELOG.en.md by Scripts/sync_changelog.py. Do not edit by hand. -->",
                 "<!-- 由 Scripts/sync_changelog.py 从 CHANGELOG.md 生成，请勿手改。 -->"),
        '  <section id="changelog" class="band" style="padding-top:0">',
        '    <div class="shell">',
        '      <div class="section-head">',
        "        <h2>" + t("Changelog", "更新日志") + "</h2>",
        "        <p>" + t(f"Current version {version} · last updated {newest}. What changed, day by day.",
                          f"当前版本 {version} · 最近更新于 {newest}。每天改了什么，都记在这里。") + "</p>",
        "      </div>",
        '      <div class="log">',
    ]
    for release, day in days[:RECENT_DAYS]:
        label = release["version"] or t("Unreleased", "未发布")
        lines.append('        <article class="log__day">')
        lines.append(f'          <header class="log__head"><time datetime="{day["date"]}">{day["date"]}</time>'
                     f'<span class="log__tag">{html.escape(label)}</span></header>')
        lines.append(f'          <p class="log__counts">{html.escape(counts(day, en=lang == "en"))}</p>')
        lines.append('          <ul class="log__list">')
        shown = 0
        for g in day["groups"]:
            for item in g["items"]:
                if shown == SITE_PREVIEW_ITEMS:
                    break
                lines.append(f'            <li><span class="badge badge--{kind_class(g["kind"])}">{html.escape(g["kind"])}</span>{inline(item)}</li>')
                shown += 1
        lines.append("          </ul>")
        rest = item_count(day) - shown
        if rest > 0:
            more = t(f"{rest} more →", f"还有 {rest} 项 →")
            lines.append(f'          <a class="log__more" href="changelog.html#d-{day["date"]}">{more}</a>')
        lines.append("        </article>")
    lines += [
        "      </div>",
        '      <p class="log__all"><a href="changelog.html">' + t("Full changelog →", "查看完整更新日志 →") + "</a></p>",
        "    </div>",
        "  </section>",
        "  <!-- changelog:end -->",
    ]
    return "\n".join(lines)


def site_page(intro, releases, lang, v, analytics):
    """The whole changelog as a page, in one language."""
    t = lambda en, zh: pick(en, zh, lang)
    info = LANGS[lang]
    root = info["root"]
    latest = latest_release(releases)
    download = DOWNLOAD.format(version=latest["version"]) if latest else f"{REPO}/releases/latest"
    source = "CHANGELOG.en.md" if lang == "en" else "CHANGELOG.md"
    out = [
        "<!doctype html>",
        f'<html lang="{info["lang"]}">',
        "<head>",
        '<meta charset="utf-8">',
        '<meta name="viewport" content="width=device-width, initial-scale=1">',
        "<title>" + t("Changelog — QuotaBar", "更新日志 — QuotaBar") + "</title>",
        '<meta name="description" content="' + t("Every QuotaBar version, day by day: new features, style changes and fixes.",
                                                  "QuotaBar 每个版本、每一天的功能新增、样式调整和问题修复。") + '">',
        '<meta name="theme-color" content="#101112">',
    ]
    if lang == "en":
        out.append('<script>try{var l=localStorage.getItem("qb-lang"),n=navigator.languages&&navigator.languages[0]?navigator.languages[0]:navigator.language;'
                   'if(l==="zh"?true:!l&&/^zh\\b/i.test(String(n)))location.replace("zh/changelog.html"+location.hash)}catch(e){}</script>')
    out += [
        f'<link rel="canonical" href="{info["url"]}changelog.html">',
        '<link rel="alternate" hreflang="en" href="https://quota.bar/changelog.html">',
        '<link rel="alternate" hreflang="zh-CN" href="https://quota.bar/zh/changelog.html">',
        '<link rel="alternate" hreflang="x-default" href="https://quota.bar/changelog.html">',
        f'<link rel="icon" type="image/png" sizes="256x256" href="{root}assets/icon.png{v}">',
        f'<link rel="icon" sizes="48x48" href="/favicon.ico{v}">',
        f'<link rel="apple-touch-icon" sizes="180x180" href="{root}assets/apple-touch-icon.png{v}">',
        f'<link rel="stylesheet" href="{root}styles.css{v}">',
    ]
    if analytics:
        out.append(analytics)
    out += [
        "<!-- " + t(f"Generated from {source} by Scripts/sync_changelog.py. Do not edit by hand.",
                    f"由 Scripts/sync_changelog.py 从 {source} 生成，请勿手改。") + " -->",
        "</head>",
        '<body class="logpage">',
        '<header class="logbar">',
        '  <div class="shell logbar__inner">',
        f'    <a class="logbar__brand wordmark" href="./"><img src="{root}assets/icon.png{v}" alt="" width="22" height="22">QuotaBar</a>',
        '    <nav class="logbar__links">',
        '      <a href="./">' + t("Home", "首页") + "</a>",
        f'      <a href="{download}" download>' + t("Download", "下载") + "</a>",
        f'      <a href="{REPO}/blob/main/{source}">' + t("View on GitHub", "在 GitHub 上查看") + "</a>",
        f'      <a href="{info["other_url"]}changelog.html" hreflang="{t("zh-CN", "en")}" lang="{t("zh-CN", "en")}" data-lang="{t("zh", "en")}">'
        + t("简体中文", "English") + "</a>",
        "    </nav>",
        "  </div>",
        "</header>",
        '<main class="shell logdoc">',
        '  <header class="logdoc__head">',
        "    <h1>" + t("Changelog", "更新日志") + "</h1>",
        f"    <p class=\"logdoc__intro\">{html.escape(' '.join(intro) if lang == 'en' else ''.join(intro))}</p>",
        '    <p class="logdoc__legend">' + "".join(
            f'<span class="badge badge--{c}">{t(en, zh)}</span>'
            for en, zh, c in (("Added", "新增", "add"), ("Style", "样式", "style"), ("Fixed", "修复", "fix"), ("Removed", "删除", "remove"))) + "</p>",
        "  </header>",
        '  <ol class="tl">',
    ]
    for release in releases:
        anchor = f"v-{release['version']}" if release["version"] else "unreleased"
        newest = max((d["date"] for d in release["days"]), default=release["date"] or "")
        out.append(f'    <li class="tl__release{"" if release["version"] else " is-pending"}" id="{anchor}">')
        out.append('      <div class="tl__meta">')
        if release["version"]:
            out.append(f'        <a class="tl__version" href="#{anchor}">{release["version"]}</a>')
            out.append(f'        <time datetime="{release["date"]}">{release["date"]}</time>')
            short, full = release_commit(release["version"])
            if short:
                tip = t("View this release's commit on GitHub", "在 GitHub 上查看这次发布的提交")
                out.append(f'        <a class="tl__hash" href="{REPO}/commit/{full}" title="{tip}">{short}</a>')
        else:
            out.append(f'        <a class="tl__version" href="#{anchor}">{html.escape(release["title"])}</a>')
            out.append(f'        <time datetime="{newest}">{newest}</time>')
            tip = t("Not released yet — see the latest commits on main", "还没发布，看 main 分支上的最新提交")
            out.append(f'        <a class="tl__hash is-live" href="{REPO}/commits/main" title="{tip}">' + t("In progress", "开发中") + "</a>")
        out.append("      </div>")
        out.append('      <div class="tl__body">')
        for day in release["days"]:
            out.append(f'        <section class="tl__day" id="d-{day["date"]}">')
            if not release["version"] or len(release["days"]) > 1:
                out.append(f'          <h3><time datetime="{day["date"]}">{day["date"]}</time></h3>')
            for g in day["groups"]:
                out.append('          <div class="tl__group">')
                out.append(f'            <span class="badge badge--{kind_class(g["kind"])}">{html.escape(g["kind"])}</span>')
                out.append("            <ul>")
                out += [f"              <li>{inline(item)}</li>" for item in g["items"]]
                out.append("            </ul>")
                out.append("          </div>")
            out.append("        </section>")
        out.append("      </div>")
        out.append("    </li>")
    out.append("  </ol>")
    current = (t(f" · Current version {latest['version']}", f" · 当前版本 {latest['version']}") if latest else "")
    out += [
        "</main>",
        '<footer class="footer">',
        '  <div class="shell">',
        f'    <p class="footer__fine">© {datetime.date.today().year} QuotaBar · <a href="{REPO}/blob/main/LICENSE">'
        + t("MIT License", "MIT 许可证") + "</a>" + current + "</p>",
        "  </div>",
        "</footer>",
        f'<script src="{root}app.js{v}"></script>',
        "</body>",
        "</html>",
        "",
    ]
    return "\n".join(out)


def render_template(template, lang, values):
    """[[English||中文]] picks a side, then {{name}} fills in a value.

    A block holds exactly one ||: a script inside one has to do without the
    operator, or the split lands in the wrong place — checked, not trusted."""
    def choose(match):
        body = match.group(1)
        if body.count("||") != 1:
            line = template[:match.start()].count("\n") + 1
            raise SystemExit(f"site/index.html:{line}: a [[…||…]] block needs exactly one ||")
        en, zh = body.split("||")
        return en if lang == "en" else zh
    text = re.sub(r"\[\[((?:(?!\[\[|\]\]).)*)\]\]", choose, template, flags=re.S)
    for leftover in ("[[", "]]"):
        if leftover in text:
            line = text[:text.index(leftover)].count("\n") + 1
            raise SystemExit(f"site/index.html: unbalanced {leftover} (line {line} of the {lang} page)")

    def fill(match):
        name = match.group(1)
        if name not in values:
            raise SystemExit(f"site/index.html: no value for {{{{{name}}}}}")
        return str(values[name])
    return re.sub(r"\{\{(\w+)\}\}", fill, text)


# ── Commit calendar ───────────────────────────────────────────────────────

def commit_days():
    dates = subprocess.run(
        ["git", "log", "--format=%ad", "--date=short"],
        cwd=ROOT, capture_output=True, text=True, check=True).stdout.split()
    return Counter(dates)


def activity_svg(per_day, today, en):
    cell, gap, left, top = 11, 3, 30, 18
    step = cell + gap
    # Columns are weeks starting Sunday, the last one holding today.
    end = today + datetime.timedelta(days=(5 - today.weekday()) % 7)  # the Saturday ending this week
    start = end - datetime.timedelta(days=WEEKS * 7 - 1)
    days = [start + datetime.timedelta(days=i) for i in range(WEEKS * 7)]
    window = {d: per_day.get(d.isoformat(), 0) for d in days if d <= today}
    total = sum(window.values())
    peak = max(window.values(), default=0)
    palette = ["rgba(139,148,158,0.18)", "#9be9a8", "#40c463", "#30a14e", "#216e39"]

    def level(n):
        return 0 if n == 0 or peak == 0 else max(1, min(4, math.ceil(4 * n / peak)))

    width = left + WEEKS * step
    height = top + 7 * step + 40
    font = 'font-family="-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,PingFang SC,sans-serif"'
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}" role="img">']
    title = (f"{total} commits in the last {WEEKS} weeks" if en else f"近 {WEEKS} 周共 {total} 次提交")
    parts.append(f"<title>{title}</title>")
    parts.append(f'<g {font} font-size="9" fill="#8b949e">')
    months_en = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    last_month = None
    for w in range(WEEKS):
        first = days[w * 7]
        if first.month != last_month and first.day <= 7:
            label = months_en[first.month - 1] if en else f"{first.month}月"
            parts.append(f'<text x="{left + w * step}" y="{top - 6}">{label}</text>')
            last_month = first.month
        elif last_month is None:
            last_month = first.month
    for row, label in ((1, "Mon" if en else "一"), (3, "Wed" if en else "三"), (5, "Fri" if en else "五")):
        parts.append(f'<text x="0" y="{top + row * step + cell - 2}">{label}</text>')
    parts.append("</g>")
    for i, d in enumerate(days):
        if d > today:
            continue
        n = window[d]
        x, y = left + (i // 7) * step, top + (i % 7) * step
        tip = f"{n} commits on {d.isoformat()}" if en else f"{d.isoformat()}：{n} 次提交"
        parts.append(f'<rect x="{x}" y="{y}" width="{cell}" height="{cell}" rx="2" fill="{palette[level(n)]}"><title>{tip}</title></rect>')
    # The legend under the grid on the right, the caption on its own line
    # below: side by side they collide in English.
    base = top + 7 * step + 14
    caption = (f"{total} commits in the last {WEEKS} weeks · through {today.isoformat()}" if en
               else f"近 {WEEKS} 周共 {total} 次提交 · 截至 {today.isoformat()}")
    parts.append(f'<g {font} font-size="10" fill="#8b949e">')
    parts.append(f'<text x="{left}" y="{base + 16}">{caption}</text>')
    legend_x = width - 5 * step - 34
    parts.append(f'<text x="{legend_x - 4}" y="{base}" text-anchor="end">{"Less" if en else "少"}</text>')
    for k in range(5):
        parts.append(f'<rect x="{legend_x + k * step}" y="{base - cell + 1}" width="{cell}" height="{cell}" rx="2" fill="{palette[k]}"/>')
    parts.append(f'<text x="{legend_x + 5 * step + 2}" y="{base}">{"More" if en else "多"}</text>')
    parts.append("</g></svg>")
    return "\n".join(parts) + "\n"


# ── Providers ─────────────────────────────────────────────────────────────

def providers():
    """(raw id, English name, Chinese name) in ProviderID's order."""
    models = (ROOT / "Sources" / "QuotaCore" / "Models.swift").read_text(encoding="utf-8")
    body = re.search(r"public enum ProviderID\b[^{]*\{(.*?)\n    public var ", models, re.S).group(1)
    cases = []
    for name, raw in re.findall(r"^\s*case (\w+)(?: = \"([^\"]+)\")?\s*$", body, re.M):
        cases.append((name, raw or name))
    names = {}
    block = models[models.index("public enum ProviderID"):]
    block = block[block.index("public var displayName"):]
    block = block[:block.index("\n    }\n")]
    for name, value in re.findall(r"case \.(\w+): (.+)", block):
        pair = re.findall(r'"([^"]*)"', value)
        names[name] = (pair[0], pair[-1]) if pair else (name, name)
    return [(raw, *names.get(name, (name, name))) for name, raw in cases]


def png_tone(path):
    """(monochrome, dark) for a logo. Monochrome marks carry no colour of their
    own, so the site draws them white; dark coloured ones (Qoder's) would vanish
    on the dark page and get a light backing. Reads 8-bit, non-interlaced
    RGB/RGBA PNGs, which is what the app ships."""
    data = path.read_bytes()
    pos, idat, width, height, colour = 8, b"", 0, 0, 6
    while pos < len(data):
        length, kind = struct.unpack(">I4s", data[pos:pos + 8])
        chunk = data[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            width, height, depth, colour, _, _, interlace = struct.unpack(">IIBBBBB", chunk)
            if depth != 8 or interlace or colour not in (2, 6):
                return False, False
        elif kind == b"IDAT":
            idat += chunk
        pos += 12 + length
    channels = 4 if colour == 6 else 3
    raw = zlib.decompress(idat)
    stride = width * channels
    previous = bytearray(stride)
    sampled = coloured = 0
    brightness = 0
    for y in range(height):
        start = y * (stride + 1)
        kind, row = raw[start], bytearray(raw[start + 1:start + 1 + stride])
        for i in range(stride):
            left = row[i - channels] if i >= channels else 0
            up = previous[i]
            corner = previous[i - channels] if i >= channels else 0
            if kind == 1:
                row[i] = (row[i] + left) & 255
            elif kind == 2:
                row[i] = (row[i] + up) & 255
            elif kind == 3:
                row[i] = (row[i] + (left + up) // 2) & 255
            elif kind == 4:
                p = left + up - corner
                pa, pb, pc = abs(p - left), abs(p - up), abs(p - corner)
                row[i] = (row[i] + (left if pa <= pb and pa <= pc else up if pb <= pc else corner)) & 255
        previous = row
        if y % 4:
            continue
        for x in range(0, width, 4):
            px = row[x * channels:x * channels + channels]
            if channels == 4 and px[3] < 128:
                continue
            sampled += 1
            hi, lo = max(px[:3]), min(px[:3])
            brightness += hi
            if hi and (hi - lo) / hi > 0.18:
                coloured += 1
    if not sampled:
        return False, False
    mono = coloured / sampled <= 0.05
    return mono, not mono and brightness / sampled < 64


def copy_logos():
    """Copies the app's logos into web/assets/logos; (raw id, en, zh, tone) for those that exist."""
    logos = ROOT / "Sources" / "QuotaBar" / "Resources" / "logos"
    target = ROOT / "web" / "assets" / "logos"
    target.mkdir(parents=True, exist_ok=True)
    found = []
    for raw, en, zh in providers():
        # A mark cut for dark surfaces wins where there is one (Kimi's).
        source = logos / f"{raw}-dark.png"
        if not source.exists():
            source = logos / f"{raw}.png"
        if not source.exists():
            continue
        copy = target / f"{raw}.png"
        if not copy.exists() or copy.read_bytes() != source.read_bytes():
            shutil.copyfile(source, copy)
        mono, dark = png_tone(source)
        found.append((raw, en, zh, " is-mono" if mono else " is-dark" if dark else ""))
    return found


def site_providers(logos, count, lang, v):
    """The scrolling strip of provider logos, in one language."""
    root = LANGS[lang]["root"]
    t = lambda en, zh: pick(en, zh, lang)
    items = [f'<li class="prov"><img class="prov__logo{tone}" src="{root}assets/logos/{raw}.png{v}" alt="" width="24" height="24" loading="lazy" decoding="async"><span>{html.escape(t(en, zh))}</span></li>'
             for raw, en, zh, tone in logos]
    strip = "\n".join(f"          {item}" for item in items)
    return "\n".join([
        "<!-- providers:start -->",
        "  " + t("<!-- Generated by Scripts/sync_changelog.py from ProviderID and the app's logos. Do not edit by hand. -->",
                 "<!-- 由 Scripts/sync_changelog.py 从 ProviderID 与应用内的 logo 生成，请勿手改。 -->"),
        f'  <section id="providers" class="providers" aria-label="{t("Supported providers", "支持的服务商")}">',
        '    <p class="providers__head">' + t(f'<b class="provider-count">{count}</b> AI coding services supported',
                                                f'支持 <b class="provider-count">{count}</b> 个 AI 编码服务') + "</p>",
        '    <div class="providers__track">',
        # The list twice, for a loop with no seam; the copy is hidden from
        # assistive tech.
        '      <ul class="providers__row">',
        strip,
        "      </ul>",
        '      <ul class="providers__row" aria-hidden="true">',
        strip,
        "      </ul>",
        "    </div>",
        "  </section>",
        "  <!-- providers:end -->",
    ])


def write_if_changed(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and path.read_text(encoding="utf-8") == content:
        return False
    path.write_text(content, encoding="utf-8")
    return True


def main():
    import argparse
    parser = argparse.ArgumentParser(description="Sync the changelogs into the READMEs, build the website, draw the activity chart.")
    parser.add_argument("--changelog", default=str(ROOT / "CHANGELOG.md"),
                        help="read this Chinese changelog instead, e.g. the committed copy while other edits are pending")
    parser.add_argument("--changelog-en", default=str(ROOT / "CHANGELOG.en.md"),
                        help="read this English changelog instead")
    args = parser.parse_args()
    intro_zh, releases_zh = parse(pathlib.Path(args.changelog).read_text(encoding="utf-8"))
    intro_en, releases_en = parse(pathlib.Path(args.changelog_en).read_text(encoding="utf-8"))
    changed = []
    if replace_block(ROOT / "README.md", readme_block(releases_en, en=True)):
        changed.append("README.md")
    if replace_block(ROOT / "README.zh-CN.md", readme_block(releases_zh, en=False)):
        changed.append("README.zh-CN.md")

    # The asset token deploy_site.sh last stamped, kept so a local run doesn't
    # churn every URL back to a stale value.
    home = ROOT / "web" / "index.html"
    current = home.read_text(encoding="utf-8") if home.exists() else ""
    token = re.search(r"styles\.css\?v=([A-Za-z0-9]+)", current)
    stamp = token.group(1) if token else "dev"
    template = (ROOT / "site" / "index.html").read_text(encoding="utf-8")
    analytics = re.search(r'<script defer src="https://tongji[^"]*"[^>]*></script>', template)
    logos = copy_logos()
    count = len(providers())
    latest = latest_release(releases_zh)
    version = latest["version"] if latest else "0.0.0"
    for lang, intro, releases in (("en", intro_en, releases_en), ("zh", intro_zh, releases_zh)):
        info = LANGS[lang]
        values = dict(info, v=stamp, count=count, version=version,
                      dmg=DOWNLOAD.format(version=version), github_dmg=GITHUB_DOWNLOAD.format(version=version),
                      providers=site_providers(logos, count, lang, f"?v={stamp}"),
                      changelog=site_block(releases, lang))
        page = render_template(template, lang, values)
        note = ("<!-- Built from site/index.html by Scripts/sync_changelog.py: edit the template, not this file. -->"
                if lang == "en" else "<!-- 由 Scripts/sync_changelog.py 从 site/index.html 生成：改模板，不要改这个文件。 -->")
        page = page.replace("<!doctype html>\n", f"<!doctype html>\n{note}\n", 1)
        out = ROOT / "web" / info["dir"] / "index.html"
        if write_if_changed(out, page):
            changed.append(str(out.relative_to(ROOT)))
        out = ROOT / "web" / info["dir"] / "changelog.html"
        if write_if_changed(out, site_page(intro, releases, lang, f"?v={stamp}", analytics.group(0) if analytics else None)):
            changed.append(str(out.relative_to(ROOT)))
    # The calendar runs through yesterday: a finished day does not change, so
    # running this again after today's commits leaves the chart alone rather
    # than redrawing it with every commit that records the redraw.
    per_day, today = commit_days(), datetime.date.today() - datetime.timedelta(days=1)
    for name, en in (("activity.svg", True), ("activity.zh.svg", False)):
        if write_if_changed(ROOT / "Assets" / "readme" / name, activity_svg(per_day, today, en)):
            changed.append(f"Assets/readme/{name}")
    print("已更新：" + "、".join(changed) if changed else "已是最新")


if __name__ == "__main__":
    main()

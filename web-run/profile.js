/* Quota Run（quota.run）的个人主页：u.html，Caddy 把 /@username 改写到它（本地预览用 u.html?user=）。
 *
 * 读 /users/<username>：头部（首字母头像、名字、@username、简介、链接、加入时间），数字条，
 * 活跃度（每天 token 用量的热力图；关联了 GitHub 登录的再加一张 GitHub 贡献热力图），
 * 最好成绩表（每张榜一行，到 50/90/100% 的用时、名次、百分位、级别，链到那张榜的全部赛季），
 * 最近几轮画成小赛道，项目卡片（填了 GitHub 仓库的带星标、语言和近 52 周提交）。用户不存在时是 404 状态。
 * GitHub 的数据另读 /users/<username>/github，服务端还在取（pending）时隔几秒再读。
 * 共用的格式、链接、热力图和接口在 common.js（window.QuotaRun）。
 */
(function () {
  "use strict";

  var Q = window.QuotaRun;
  if (!Q || Q.PAGE !== "profile") return;
  var t = Q.t, esc = Q.esc, $ = Q.$, each = Q.each, ZH = Q.ZH, clock = Q.clock, has = Q.has;
  var params = new URLSearchParams(location.search);
  var main = $("main");

  function readUsername() {
    var match = location.pathname.match(/\/@([^\/]+)\/?$/);
    var raw = match ? match[1] : params.get("user") || "";
    try { raw = decodeURIComponent(raw); } catch (e) { /* 原样用 */ }
    return raw.trim().replace(/^@/, "").toLowerCase();
  }

  function setHead(user) {
    var head = document.head;
    function link(rel, href, lang) {
      var el = document.createElement("link");
      el.rel = rel;
      el.href = href;
      if (lang) el.hreflang = lang;
      head.appendChild(el);
    }
    function meta(attr, key, value) {
      var el = head.querySelector("meta[" + attr + '="' + key + '"]');
      if (!el) { el = document.createElement("meta"); el.setAttribute(attr, key); head.appendChild(el); }
      el.setAttribute("content", value);
    }
    var en = "https://quota.run/@" + user.username;
    var zh = "https://quota.run/zh/@" + user.username;
    var name = (user.displayName || user.username) + " (@" + user.username + ")";
    document.title = name + " · Quota Run";
    link("canonical", ZH ? zh : en);
    link("alternate", en, "en");
    link("alternate", zh, "zh-CN");
    link("alternate", en, "x-default");
    meta("property", "og:url", ZH ? zh : en);
    meta("property", "og:title", name + " · Quota Run");
    if (user.bio) {
      meta("name", "description", user.bio);
      meta("property", "og:description", user.bio);
    }
  }

  // 语言切换去另一种语言的同一个人
  function langLink(username) {
    if (/\/@[^\/]+\/?$/.test(location.pathname)) {
      each(document.querySelectorAll("a.run-lang"), function (a) {
        a.setAttribute("href", (ZH ? "/@" : "/zh/@") + encodeURIComponent(username) + location.search);
      });
    } else {
      Q.setLangLinks(location.search);
    }
  }

  /* ── 最好成绩 ─────────────────────────────────────────────────────── */

  // 接口给的 percentile 就是 ceil(名次 ÷ 人数 × 100)，没有时自己算
  function topPercent(best) {
    var p = Number(best.percentile);
    if (p >= 1) return Math.round(p);
    var rank = Number(best.rank), runners = Number(best.runners);
    return rank && runners ? Math.max(1, Math.ceil(rank / runners * 100)) : null;
  }

  // 每张榜一行：速度那条给用时和名次；只有峰值（从没用满过）时显示峰值
  function groupBests(bests) {
    var rows = [], byKey = {};
    bests.forEach(function (b) {
      var key = Q.boardKey(b);
      if (!byKey[key]) { byKey[key] = { board: b, speed: null, peak: null }; rows.push(byKey[key]); }
      byKey[key][b.metric === "peak" ? "peak" : "speed"] = b;
    });
    return rows;
  }

  function bestsTable(bests) {
    var rows = groupBests(bests);
    return '<div class="tablewrap"><table class="bests">' +
      '<caption class="sr-only">' + t("Personal bests, ranked across all seasons", "最好成绩，名次按全部赛季算") + "</caption>" +
      "<thead><tr>" +
        '<th scope="col">' + t("Board", "榜单") + "</th>" +
        '<th scope="col" class="num">' + t("To 50%", "到 50%") + "</th>" +
        '<th scope="col" class="num">' + t("To 90%", "到 90%") + "</th>" +
        '<th scope="col" class="num">' + t("To 100%", "用满用时") + "</th>" +
        '<th scope="col" class="num">' + t("Rank", "名次") + "</th>" +
        '<th scope="col" class="num">' + t("Percentile", "百分位") + "</th>" +
        '<th scope="col">' + t("Tier", "级别") + "</th>" +
      "</tr></thead><tbody>" +
      rows.map(function (row) {
        var b = row.speed || row.peak;
        var speed = !!row.speed;
        var to100 = speed ? (has(b.secondsTo100) ? b.secondsTo100 : b.value) : null;
        var rank = Number(b.rank);
        var top = topPercent(b);
        var href = Q.boardHref(row.board, { season: "all", metric: speed ? "" : "peak" });
        return "<tr>" +
          '<th scope="row"><a class="board-cell" href="' + esc(href) + '">' + Q.logo(b.provider, 20) +
            '<span class="board-cell__text"><b>' + esc(Q.boardName(b)) + "</b><small>" + esc(Q.windowLabel(b.windowSeconds, b.windowKey, b.windowTitle)) + "</small></span></a></th>" +
          '<td class="num mono">' + Q.hours(b.secondsTo50) + "</td>" +
          '<td class="num mono">' + Q.hours(b.secondsTo90) + "</td>" +
          '<td class="num mono best">' + (speed ? clock(to100) : '<span class="dim">' + t("peak ", "峰值 ") + "</span>" + Q.percent(b.value)) + "</td>" +
          '<td class="num mono">' + (rank ? "#" + rank + '<span class="dim">' + (b.runners ? " / " + Q.number(b.runners) : "") + "</span>" : "—") + "</td>" +
          '<td class="num">' + (top ? (ZH ? "前 " + top + "%" : "Top " + top + "%") : "—") + "</td>" +
          '<td><span class="tiercell">' + Q.tierTag(b.tier) + Q.accountMark(b.accountVerified) + "</span></td></tr>";
      }).join("") + "</tbody></table></div>";
  }

  /* ── 最近几轮：小赛道 ─────────────────────────────────────────────── */

  function runRow(run) {
    var W = Number(run.windowSeconds) || 604800;
    var pct = function (x) { return Math.max(0, Math.min(100, Number(x) / W * 100)).toFixed(2) + "%"; };
    var now = Date.now() / 1000;
    var start = Number(run.windowStart) || (run.resetsAt ? Number(run.resetsAt) - W : null);
    var live = !has(run.secondsTo100) && run.resetsAt && Number(run.resetsAt) > now;
    var segs = "";
    if (has(run.secondsTo100)) segs += '<span class="tseg seg100" style="width:' + pct(run.secondsTo100) + '"></span>';
    if (has(run.secondsTo90)) segs += '<span class="tseg seg90" style="width:' + pct(run.secondsTo90) + '"></span>';
    if (has(run.secondsTo50)) segs += '<span class="tseg seg50" style="width:' + pct(run.secondsTo50) + '"></span>';
    var nowMark = live && start ? '<span class="track__now" style="left:' + pct(now - start) + '"></span>' : "";
    var days = W >= 3 * 86400 ? Math.round(W / 86400) : 0;
    var grid = "";
    if (days && days <= 31) for (var d = 1; d < days; d += days > 10 ? 7 : 1) grid += '<i style="left:' + pct(d * 86400) + '"></i>';
    var when = Q.toDate(run.completedAt) || Q.toDate(run.lastObservedAt) || Q.toDate(run.resetsAt);
    var value = live
      ? '<span class="live"><i aria-hidden="true"></i>' + t("In progress", "进行中") + "</span><small>" + t("now ", "现在 ") + Q.percent(run.peakPercent) + "</small>"
      : has(run.secondsTo100)
        ? clock(run.secondsTo100) + "<small>" + t("to 100%", "用满用时") + "</small>"
        : Q.percent(run.peakPercent) + "<small>" + t("peak", "峰值") + "</small>";
    var sr = [];
    if (has(run.secondsTo50)) sr.push(t("50% at ", "50% 用时 ") + clock(run.secondsTo50));
    if (has(run.secondsTo90)) sr.push(t("90% at ", "90% 用时 ") + clock(run.secondsTo90));
    return '<li class="runrow">' +
      '<span class="board-cell">' + Q.logo(run.provider, 20) + '<span class="board-cell__text"><b>' + esc(Q.boardName({ provider: run.provider, planLabel: run.planLabel || run.plan })) + "</b><small>" +
        esc(Q.windowLabel(run.windowSeconds, run.windowKey, run.windowTitle)) + "</small></span></span>" +
      '<span class="track" aria-hidden="true"><span class="track__grid">' + grid + '</span><span class="track__base"></span>' + segs + nowMark + "</span>" +
      '<span class="runrow__value mono">' + value + "</span>" +
      '<span class="runrow__meta"><span class="tiercell">' + Q.tierTag(run.tier) + Q.accountMark(run.accountVerified) + "</span>" + '<span class="dim">' + Q.timeTag(when) + "</span></span>" +
      (sr.length ? '<span class="sr-only">' + esc(sr.join(ZH ? "，" : ", ")) + "</span>" : "") +
      "</li>";
  }

  /* ── 活跃度：token 用量和 GitHub 贡献的热力图 ─────────────────────── */

  function statList(items) {
    return '<dl class="hmstats">' + items.filter(Boolean).map(function (item) {
      return '<div class="hmstat"><dt>' + item[0] + '</dt><dd class="mono">' + item[1] + "</dd></div>";
    }).join("") + "</dl>";
  }

  // 活动分钟的来源是本地日志属于哪个命令行工具
  var SOURCE_NAMES = { claude: "Claude Code", codex: "Codex", opencode: "OpenCode" };

  function streakText(n) { return ZH ? Q.number(n) + " 天" : Q.number(n) + (n === 1 ? " day" : " days"); }

  function activityCard(activity) {
    var values = {}, sources = {};
    (activity.days || []).forEach(function (day) {
      values[day.date] = Number(day.tokens) || 0;
      sources[day.date] = day.sources || {};
    });
    var s = Q.heatStats(values, activity.to);
    var tip = function (date, value) {
      var parts = Object.keys(sources[date] || {}).map(function (id) {
        return esc(SOURCE_NAMES[id] || id) + " " + esc(Q.compact(sources[date][id]));
      });
      return "<b>" + (value > 0 ? esc(Q.compact(value)) + " tokens" : t("No tokens", "没有用量")) + "</b> · " + esc(Q.calendarDate(date)) +
        (parts.length ? "<small>" + parts.join(" · ") + "</small>" : "");
    };
    var empty = !(activity.days || []).length;
    return '<article class="hmcard">' +
      '<header class="hmcard__head"><div class="hmcard__title"><h3>' + t("AI coding usage", "AI 编程用量") + "</h3>" +
        '<p class="hint">' + t("Tokens per day from the ranked Mac's Claude Code, Codex and OpenCode logs", "每天的 token 数，来自计分 Mac 上 Claude Code、Codex、OpenCode 的本地日志") + "</p></div>" +
        statList([
          [t("Last year", "近一年"), esc(Q.compact(activity.totalTokens != null ? activity.totalTokens : s.total))],
          [t("Active days", "活跃天数"), Q.number(s.activeDays)],
          [t("Longest streak", "最长连续"), streakText(s.longest)],
          [t("Current streak", "当前连续"), streakText(s.current)],
          s.best ? [t("Best day", "单日最高"), esc(Q.compact(s.best.value)) + ' <span class="dim">' + esc(Q.calendarDate(s.best.date, true)) + "</span>"] : null,
        ]) +
      "</header>" +
      Q.heatmap({
        to: activity.to, values: values, tip: tip,
        label: ZH ? "近一年每天的 token 用量，共 " + Q.compact(s.total) + "，活跃 " + s.activeDays + " 天" : "Tokens per day over the last year: " + Q.compact(s.total) + " in total, " + s.activeDays + " active days",
        note: empty
          ? t("Nothing yet — days fill in as the ranked Mac uploads token counts.", "还没有数据：计分的 Mac 上传 token 数后按天填上。")
          : esc(ZH ? "按 " + activity.timezone + " 分日" : "Days in " + activity.timezone),
      }) +
      "</article>";
  }

  function githubSkeleton(brief) {
    return '<article class="hmcard" id="githubCard">' +
      '<header class="hmcard__head"><div class="hmcard__title"><h3 class="hmcard__gh">' + Q.ICONS.github + '<a href="' + esc(brief.url) + '" rel="me nofollow noopener">' + esc(brief.login) + "</a></h3>" +
        '<p class="hint">' + t("GitHub contributions", "GitHub 贡献") + "</p></div></header>" +
      '<div class="hmcard__loading" aria-hidden="true"><span class="skel skel--block"></span></div>' +
      '<p class="sr-only" role="status">' + t("Loading GitHub contributions…", "正在读取 GitHub 贡献…") + "</p>" +
      "</article>";
  }

  function githubCard(data, brief) {
    var login = data.login || brief.login;
    var url = data.url || brief.url;
    var head = '<header class="hmcard__head"><div class="hmcard__title"><h3 class="hmcard__gh">' + Q.ICONS.github +
      '<a href="' + esc(url) + '" rel="me nofollow noopener">' + esc(login) + "</a></h3>" +
      '<p class="hint">' + t("GitHub contributions", "GitHub 贡献") + (data.fetchedAt ? " · " + t("updated ", "更新于 ") + Q.timeTag(Q.toDate(data.fetchedAt)) : "") + "</p></div>";
    var cal = data.calendar;
    if (!cal || !cal.to) {
      return '<article class="hmcard" id="githubCard">' + head + "</header>" +
        '<p class="hmcard__empty">' + (data.pending
          ? t("Still fetching from GitHub…", "还在从 GitHub 读取…")
          : t("GitHub's contribution calendar couldn't be read just now. It's tried again in a few minutes.", "暂时没读到 GitHub 的贡献日历，过几分钟会再试。")) + "</p></article>";
    }
    var values = {};
    (cal.days || []).forEach(function (day) { values[day.date] = Number(day.count) || 0; });
    var s = Q.heatStats(values, cal.to);
    var totals = data.totals;
    var tip = function (date, value) {
      var n = ZH ? Q.number(value) + " 次贡献" : Q.number(value) + (value === 1 ? " contribution" : " contributions");
      return "<b>" + (value > 0 ? esc(n) : t("No contributions", "没有贡献")) + "</b> · " + esc(Q.calendarDate(date));
    };
    return '<article class="hmcard" id="githubCard">' + head +
      statList([
        [t("Last year", "近一年"), Q.number(cal.total)],
        totals ? [t("Commits", "提交"), Q.number(totals.commits)] : null,
        totals ? [t("Pull requests", "PR"), Q.number(totals.pullRequests)] : null,
        totals ? [t("Reviews", "代码评审"), Q.number(totals.reviews)] : null,
        totals ? [t("Issues", "Issue"), Q.number(totals.issues)] : null,
        [t("Longest streak", "最长连续"), streakText(s.longest)],
        [t("Current streak", "当前连续"), streakText(s.current)],
      ]) + "</header>" +
      Q.heatmap({
        to: cal.to, values: values, tip: tip,
        label: ZH ? "近一年 GitHub 贡献 " + cal.total + " 次" : cal.total + " GitHub contributions in the last year",
        note: totals && totals.private
          ? esc(ZH ? "含 " + Q.number(totals.private) + " 次私有仓库贡献（只计数）" : "Includes " + Q.number(totals.private) + " private contributions (counts only)")
          : t("Public contributions as GitHub shows them", "按 GitHub 公开显示的贡献计"),
      }) +
      "</article>";
  }

  /* ── 项目 ─────────────────────────────────────────────────────────── */

  var REPO_PATH = /^\/([^\/]+)\/([^\/]+?)(?:\.git)?(?:\/.*)?$/;

  function repoKey(project) {
    var github = Q.safeLink("github", project.github);
    var m = github && REPO_PATH.exec(github.pathname);
    return m ? (m[1] + "/" + m[2]).toLowerCase() : "";
  }

  // 近 52 周每周提交数的小柱子
  function commitBars(weeks) {
    var max = Math.max.apply(null, weeks.concat(1));
    var bar = 3, gap = 1, h = 24;
    var rects = weeks.map(function (n, i) {
      var height = n > 0 ? Math.max(2, Math.round(n / max * h)) : 1;
      return '<rect x="' + i * (bar + gap) + '" y="' + (h - height) + '" width="' + bar + '" height="' + height + '" rx="0.5" class="' + (n > 0 ? "cb__on" : "cb__off") + '"></rect>';
    }).join("");
    var width = weeks.length * (bar + gap) - gap;
    return '<svg class="cb" aria-hidden="true" width="' + width + '" height="' + h + '" viewBox="0 0 ' + width + " " + h + '">' + rects + "</svg>";
  }

  function repoStats(repo) {
    if (!repo) return "";
    if (repo.missing) return '<p class="project__repo dim">' + t("That repository isn't public on GitHub.", "GitHub 上找不到这个公开仓库。") + "</p>";
    var bits = [];
    if (has(repo.stars)) bits.push('<span title="' + esc(t("Stars", "星标")) + '">' + Q.ICONS.star + esc(Q.compact(repo.stars)) + "</span>");
    if (has(repo.forks)) bits.push('<span title="' + esc(t("Forks", "分叉")) + '">' + Q.ICONS.fork + esc(Q.compact(repo.forks)) + "</span>");
    if (repo.language) bits.push("<span>" + esc(repo.language) + "</span>");
    if (repo.archived) bits.push('<span class="tag">' + t("Archived", "已归档") + "</span>");
    if (repo.pushedAt) bits.push('<span class="dim">' + t("pushed ", "推送于 ") + Q.timeTag(Q.toDate(repo.pushedAt)) + "</span>");
    var activity = Array.isArray(repo.weeks)
      ? '<div class="project__commits">' + commitBars(repo.weeks) + '<span class="dim">' +
        (ZH ? "近 52 周 " + Q.number(repo.commits) + " 次提交" : Q.number(repo.commits) + " commits in 52 weeks") + "</span></div>"
      : "";
    return '<div class="project__repo"><p class="project__meta">' + bits.join("") + "</p>" + activity + "</div>";
  }

  function projectCard(project) {
    var url = Q.safeLink("website", project.url);
    var github = Q.safeLink("github", project.github);
    var built = (project.builtWith || []).filter(function (id) { return typeof id === "string"; });
    var name = esc(project.name || (url ? Q.hostOf(url) : ""));
    return '<article class="project" data-repo="' + esc(repoKey(project)) + '">' +
      '<h3 class="project__name">' + (url ? '<a href="' + esc(url.href) + '" rel="nofollow ugc noopener">' + name + '<svg aria-hidden="true" width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M6 3.5h6.5V10M12.5 3.5 4 12"/></svg></a>' : name) + "</h3>" +
      (url ? '<p class="project__host">' + esc(Q.hostOf(url)) + "</p>" : "") +
      (project.description ? '<p class="project__desc">' + esc(project.description) + "</p>" : "") +
      '<div class="project__stats"></div>' +
      '<div class="project__foot">' +
      (built.length
        ? '<span class="project__built"><span>' + t("Built with", "用到的 AI") + "</span>" +
          built.map(function (id) { return '<span title="' + esc(Q.providerName(id)) + '">' + Q.logo(id, 16) + '<span class="sr-only">' + esc(Q.providerName(id)) + "</span></span>"; }).join("") + "</span>"
        : "<span></span>") +
      (github ? '<a class="project__gh" href="' + esc(github.href) + '" rel="nofollow ugc noopener">' + Q.ICONS.github + "GitHub</a>" : "") +
      "</div></article>";
  }

  /* ── 整页 ─────────────────────────────────────────────────────────── */

  function render(user) {
    setHead(user);
    var links = user.links || {};
    var linkItems = Q.LINK_KINDS.map(function (entry) {
      var kind = entry.kind;
      var url = Q.safeLink(kind, links[kind]);
      if (!url) return "";
      var label = Q.linkLabel(kind, url);
      var name = Q.linkName(kind);
      return '<li><a href="' + esc(url.href) + '" rel="me nofollow ugc noopener" title="' + esc(name + " · " + url.href) + '">' +
        (Q.ICONS[kind] || Q.ICONS.link) + "<span>" + esc(label) + "</span>" +
        (label === name || kind === "website" || kind === "blog" ? "" : '<span class="sr-only">' + esc(ZH ? "（" + name + "）" : " (" + name + ")") + "</span>") + "</a></li>";
    }).join("");
    var joined = Q.toDate(user.joinedAt);
    var meta = ["@" + esc(user.username)];
    if (Q.regionLabel(user.region)) meta.push(esc(Q.regionLabel(user.region)));
    if (joined) meta.push(ZH ? esc(Q.MONTH_FORMAT.format(joined)) + "加入" : "Joined " + esc(Q.MONTH_FORMAT.format(joined)));
    var stats = user.stats || {};
    var bests = user.bests || [];
    var projects = user.projects || [];
    var recent = user.recent || [];

    main.innerHTML =
      '<header class="phead">' + Q.avatar(user, "av--xl") +
        '<div class="phead__text">' +
          '<h1 class="phead__name">' + esc(user.displayName || user.username) + "</h1>" +
          '<p class="phead__meta">' + meta.map(function (m) { return "<span>" + m + "</span>"; }).join("") + "</p>" +
          (user.bio ? '<p class="phead__bio">' + esc(user.bio) + "</p>" : "") +
          (linkItems ? '<ul class="phead__links">' + linkItems + "</ul>" : "") +
        "</div>" +
        '<div class="phead__actions">' +
          '<button type="button" class="btn" id="shareCopy" data-done="' + esc(t("Link copied", "链接已复制")) + '">' + Q.ICONS.link + "<span>" + t("Copy profile link", "复制主页链接") + "</span></button>" +
          '<a class="btn" href="' + esc(Q.homeHref()) + '">' + t("Leaderboard", "排行榜") + "</a>" +
        "</div>" +
      "</header>" +
      '<dl class="kpis kpis--4 psec">' +
        [[t("Runs", "轮次"), stats.runs], [t("Verified runs", "已验证轮次"), stats.verifiedRuns], [t("Providers", "服务商"), stats.providers], [t("Active days", "活跃天数"), stats.activeDays]]
          .map(function (pair) { return '<div class="kpi"><dt>' + pair[0] + '</dt><dd class="kpi__v">' + Q.number(pair[1]) + "</dd></div>"; }).join("") +
      "</dl>" +
      (user.activity || user.github
        ? '<section class="psec" aria-labelledby="activityHeading">' +
            '<div class="psec__head"><h2 id="activityHeading">' + t("Activity", "活跃度") + '</h2><p class="hint">' + t("The last 53 weeks, one square a day", "近 53 周，一格一天") + "</p></div>" +
            '<div class="hmcards">' + (user.activity ? activityCard(user.activity) : "") + (user.github ? githubSkeleton(user.github) : "") + "</div>" +
          "</section>"
        : "") +
      '<section class="psec" aria-labelledby="bestsHeading">' +
        '<div class="psec__head"><h2 id="bestsHeading">' + t("Personal bests", "最好成绩") + '</h2><p class="hint">' + t("Ranked across all seasons and regions", "名次按全部赛季、全部地区算") + "</p></div>" +
        (bests.length ? bestsTable(bests)
          : Q.stateBox("empty", t("No ranked runs yet", "还没有上榜的成绩"), t("Bests show up here after the first full window from the ranked Mac.", "计分的那台 Mac 跑完第一个额度窗口后，成绩会出现在这里。"), "")) +
      "</section>" +
      '<section class="psec" aria-labelledby="recentHeading">' +
        '<div class="psec__head"><h2 id="recentHeading">' + t("Recent runs", "最近几轮") + '</h2><p class="hint">' + t("Each bar is one whole quota window", "每一条都是一整个额度窗口") + "</p></div>" +
        (recent.length ? '<ol class="runs">' + recent.map(runRow).join("") + "</ol>" +
          '<ul class="legend"><li><i class="swatch-bar seg50"></i>0 → 50%</li><li><i class="swatch-bar seg90"></i>50 → 90%</li><li><i class="swatch-bar seg100"></i>90 → 100%</li></ul>'
          : Q.stateBox("empty", t("No runs yet", "还没有记录"), "", "")) +
      "</section>" +
      (projects.length
        ? '<section class="psec" aria-labelledby="projectsHeading"><div class="psec__head"><h2 id="projectsHeading">' + t("Projects", "在做的项目") + "</h2></div>" +
          '<div class="projects">' + projects.map(projectCard).join("") + "</div></section>"
        : "");

    var copy = $("shareCopy");
    copy.addEventListener("click", function () { Q.copyText(Q.SHARE.replace(/zh\/$/, "") + (ZH ? "zh/" : "") + "@" + user.username, copy); });
    Q.heatmapReady(main);
    if (user.github || projects.some(repoKey)) loadGithub(user, 0);
  }

  // GitHub 的贡献日历和仓库数据：服务端第一次取时可能回 pending，隔几秒再读，最多读六次
  var githubTimer = null;
  function loadGithub(user, attempt) {
    clearTimeout(githubTimer);
    Q.getJSON("/users/" + encodeURIComponent(user.username) + "/github").then(function (data) {
      if (!data) return;
      var card = $("githubCard");
      var ready = !data.pending || (data.calendar && data.calendar.to);
      var lastTry = attempt >= 5;
      if (card && user.github && (ready || lastTry)) {
        card.outerHTML = githubCard(ready ? data : Object.assign({}, data, { pending: false }), user.github);
        Q.heatmapReady($("githubCard"));
      }
      var byRepo = {};
      (data.repos || []).forEach(function (repo) { if (repo.repo) byRepo[String(repo.repo).toLowerCase()] = repo; });
      each(main.querySelectorAll(".project[data-repo]"), function (el) {
        var key = el.getAttribute("data-repo");
        var slot = el.querySelector(".project__stats");
        if (key && slot && byRepo[key]) slot.innerHTML = repoStats(byRepo[key]);
      });
      if (data.pending && !lastTry) githubTimer = setTimeout(function () { loadGithub(user, attempt + 1); }, 3000);
    }).catch(function () {
      var card = $("githubCard");
      if (card && user.github) card.outerHTML = githubCard({}, user.github);
    });
  }

  function notFound(username) {
    document.title = t("Runner not found · Quota Run", "找不到这个用户 · Quota Run");
    var robots = document.createElement("meta");
    robots.name = "robots";
    robots.content = "noindex";
    document.head.appendChild(robots);
    main.innerHTML = '<section class="nf">' +
      '<p class="nf__code mono">404</p>' +
      '<h1 class="nf__title">' + (username
        ? (ZH ? "没有叫 <span class=\"mono\">@" + esc(username) + "</span> 的用户" : "No runner called <span class=\"mono\">@" + esc(username) + "</span>")
        : t("Which runner?", "要看谁的主页？")) + "</h1>" +
      '<p class="nf__text">' + (username
        ? t("The link may have a typo, or they left Quota Run — leaving deletes the profile with everything else.", "可能链接拼错了，也可能对方已经退出 Quota Run——退出时主页和其他数据一起删除。")
        : t("Profiles live at quota.run/@username.", "个人主页的地址是 quota.run/@用户名。")) + "</p>" +
      '<div class="nf__actions"><a class="btn btn--primary" href="' + esc(Q.homeHref()) + '">' + t("See the leaderboard", "去看排行榜") + "</a>" +
      '<a class="link" href="' + esc(Q.pageHref("rules")) + '">' + t("How Quota Run works", "Quota Run 怎么玩") + "</a></div>" +
      "</section>";
  }

  function load() {
    var username = readUsername();
    langLink(username);
    function done() { Q.setBusy(main, false); }
    if (!Q.USERNAME.test(username)) { notFound(username); done(); return; }
    Q.getJSON("/users/" + encodeURIComponent(username)).then(function (user) {
      if (!user || !user.username) throw Object.assign(new Error("not found"), { status: 404 });
      render(user);
      done();
    }).catch(function (error) {
      if (error && error.status === 404) notFound(username);
      else main.innerHTML = Q.errorBox(t("Couldn't load this profile.", "主页没加载出来。"));
      done();
    });
  }

  main.addEventListener("click", function (event) {
    if (event.target.closest("[data-retry]")) { Q.setBusy(main, true); load(); }
  });

  load();
})();

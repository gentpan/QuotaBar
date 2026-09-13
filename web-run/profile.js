/* Quota Run（quota.run）的个人主页：u.html，Caddy 把 /@username 改写到它（本地预览用 u.html?user=）。
 *
 * 读 /users/<username>：头部（首字母头像、名字、@username、简介、链接、加入时间），数字条，
 * 最好成绩表（每张榜一行，到 50/90/100% 的用时、名次、百分位、级别，链到那张榜的全部赛季），
 * 最近几轮画成小赛道，项目卡片。用户不存在时是 404 状态。
 * 共用的格式、链接和接口在 common.js（window.QuotaRun）。
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

  /* ── 项目 ─────────────────────────────────────────────────────────── */

  function projectCard(project) {
    var url = Q.safeLink("website", project.url);
    var github = Q.safeLink("github", project.github);
    var built = (project.builtWith || []).filter(function (id) { return typeof id === "string"; });
    var name = esc(project.name || (url ? Q.hostOf(url) : ""));
    return '<article class="project">' +
      '<h3 class="project__name">' + (url ? '<a href="' + esc(url.href) + '" rel="nofollow ugc noopener">' + name + '<svg aria-hidden="true" width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M6 3.5h6.5V10M12.5 3.5 4 12"/></svg></a>' : name) + "</h3>" +
      (url ? '<p class="project__host">' + esc(Q.hostOf(url)) + "</p>" : "") +
      (project.description ? '<p class="project__desc">' + esc(project.description) + "</p>" : "") +
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
    var linkItems = ["website", "github", "x"].map(function (kind) {
      var url = Q.safeLink(kind, links[kind]);
      if (!url) return "";
      var label = kind === "website" ? Q.hostOf(url) : kind === "github" ? "github.com" + url.pathname.replace(/\/$/, "") : "@" + url.pathname.replace(/^\/|\/$/g, "");
      return '<li><a href="' + esc(url.href) + '" rel="me nofollow ugc noopener">' + Q.ICONS[kind] + "<span>" + esc(label) + "</span></a></li>";
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

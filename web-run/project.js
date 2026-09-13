/* Quota Run 的项目页（project.html），Caddy 把 /@username/slug 改写到它（本地预览用 project.html?user=&slug=）。
 *
 * 读 /users/<username>/projects/<slug>：名称、作者、仓库、名次；数字卡片；每天的花费（30/90/365 天，按工具分段）；
 * 一年的花费热力图；工具占比环；编程方式和模型；GitHub 仓库的星标和近 52 周提交；同一个仓库的其他公开者；
 * 以及一张可以下载的分享图。订阅 /live：作者有新的上传就重读。
 */
(function () {
  "use strict";

  var Q = window.QuotaRun, U = window.QuotaUI;
  if (!Q || !U || Q.PAGE !== "project") return;
  var t = Q.t, esc = Q.esc, ZH = Q.ZH, $ = Q.$;
  var params = new URLSearchParams(location.search);
  var main = $("main");
  var range = 90;
  var detail = null;

  function readPath() {
    var match = location.pathname.match(/\/@([^\/]+)\/([^\/]+)\/?$/);
    var user = match ? match[1] : params.get("user") || "";
    var slug = match ? match[2] : params.get("slug") || "";
    try { user = decodeURIComponent(user); slug = decodeURIComponent(slug); } catch (e) { /* 原样 */ }
    return { user: user.replace(/^@/, "").toLowerCase(), slug: slug.toLowerCase() };
  }

  var where = readPath();
  // 页面带 <base href="/">：页内锚点（跳到正文）要写成当前地址加 #，否则会跳去首页
  Q.each(document.querySelectorAll('a[href^="#"]'), function (a) { a.setAttribute("href", location.pathname + location.search + a.getAttribute("href")); });

  function setHead(data) {
    var name = data.project.name + " · @" + data.owner.username;
    document.title = name + " · Quota Run";
    var path = "@" + data.owner.username + "/" + data.project.slug;
    [["canonical", "https://quota.run/" + (ZH ? "zh/" : "") + path], ["alternate", "https://quota.run/" + path, "en"], ["alternate", "https://quota.run/zh/" + path, "zh-CN"]].forEach(function (item) {
      var link = document.createElement("link");
      link.rel = item[0];
      link.href = item[1];
      if (item[2]) link.hreflang = item[2];
      document.head.appendChild(link);
    });
    Q.each(document.querySelectorAll("a.run-lang"), function (a) {
      a.setAttribute("href", Q.LOCAL ? Q.ROOT + (ZH ? "" : "zh/") + "project.html" + location.search : (ZH ? "/" : "/zh/") + path + location.search);
    });
  }

  function hoursText(minutes) {
    var h = (Number(minutes) || 0) / 60;
    return ZH ? (h < 10 ? h.toFixed(1) : Math.round(h)) + " 小时" : (h < 10 ? h.toFixed(1) : Math.round(h)) + " h";
  }

  function rankChip(label, rank) {
    if (!rank || !rank.rank) return "";
    return '<span class="rank-chip">' + esc(label) + " <b>#" + rank.rank + '</b><span class="dim">/ ' + Q.number(rank.projects) + "</span></span>";
  }

  function isoMinus(to, n) {
    return new Date(new Date(to + "T00:00:00Z").getTime() - n * 86400000).toISOString().slice(0, 10);
  }

  function drawDaily() {
    var to = detail.to;
    var stacks = U.dailyStacks(detail.days, isoMinus(to, range - 1), to);
    U.columns($("projectDaily"), { dates: stacks.dates, stacks: stacks.stacks, height: 220, label: t("Cost per day by tool", "每天按工具的花费") });
    Q.each(document.querySelectorAll("#rangeSeg button"), function (b) { b.setAttribute("aria-pressed", String(Number(b.getAttribute("data-value")) === range)); });
  }

  function repoCard(repo) {
    if (!repo) return "";
    var gh = repo.github;
    var stats = "";
    if (gh && !gh.missing) {
      stats = '<p class="page__meta">' +
        (gh.stars != null ? "<span>" + Q.ICONS.star + " " + esc(Q.compact(gh.stars)) + "</span>" : "") +
        (gh.forks != null ? "<span>" + Q.ICONS.fork + " " + esc(Q.compact(gh.forks)) + "</span>" : "") +
        (gh.language ? "<span>" + esc(gh.language) + "</span>" : "") +
        (gh.pushedAt ? "<span>" + t("pushed ", "推送于 ") + Q.timeTag(Q.toDate(gh.pushedAt)) + "</span>" : "") + "</p>" +
        (gh.description ? '<p class="muted">' + esc(gh.description) + "</p>" : "") +
        (Array.isArray(gh.weeks) ? '<div id="commitChart"></div><p class="card__sub">' + esc(ZH ? "仓库近 52 周共 " + Q.number(gh.commits) + " 次提交（所有人）" : Q.number(gh.commits) + " commits in 52 weeks, everyone's") + "</p>" : "");
    } else if (gh && gh.missing) {
      stats = '<p class="muted">' + t("The repository isn't public on GitHub.", "GitHub 上找不到这个公开仓库。") + "</p>";
    }
    return '<section class="card" aria-labelledby="repoTitle"><div class="card__head"><h2 class="card__title" id="repoTitle">' + t("Repository", "仓库") + "</h2>" +
      (detail.project.repoVerified ? U.verifiedMark(t("Owner's repository", "作者本人的仓库")) : "") + "</div>" +
      '<a class="link-quiet" href="' + esc(repo.url) + '" rel="nofollow ugc noopener">' + esc(repo.key) + "</a>" + stats + "</section>";
  }

  function contributorsCard(list) {
    if (!list || list.length < 2) return "";
    return '<section class="card" aria-labelledby="peopleTitle"><div class="card__head"><h2 class="card__title" id="peopleTitle">' + t("Everyone on this repository", "同一个仓库的公开者") + '</h2><span class="card__sub">' + t("365 days", "近一年") + "</span></div>" +
      '<ol class="contributors">' + list.map(function (c, i) {
        return '<li class="' + (c.self ? "is-self" : "") + '"><span class="mono dim">' + (i + 1) + "</span>" +
          '<a class="runner" href="' + esc(Q.projectHref(c.username, c.slug)) + '">' + Q.avatar(c, "av--sm") + '<span class="runner__text"><b>' + esc(c.displayName || c.username) + "</b><small>@" + esc(c.username) + "</small></span></a>" +
          '<span class="mono">' + esc(U.money(c.costUSD)) + "</span></li>";
      }).join("") + "</ol></section>";
  }

  function modesCard(modes) {
    var total = modes.reduce(function (s, m) { return s + m.costUSD; }, 0) || 1;
    return '<section class="card" aria-labelledby="modesTitle"><div class="card__head"><h2 class="card__title" id="modesTitle">' + t("Ways of working", "编程方式") + "</h2></div>" +
      '<table class="models"><caption class="sr-only">' + t("Cost by tool and way of working", "按工具和编程方式的花费") + "</caption><tbody>" + modes.map(function (m) {
        return "<tr><td>" + '<i class="dot dot--' + esc(m.tool) + '" aria-hidden="true"></i> ' + esc(U.toolName(m.tool)) + " · " + esc(U.modeName(m.mode)) + '</td><td class="num">' + Math.round(m.costUSD / total * 100) + '%</td><td class="num">' + esc(U.money(m.costUSD)) + "</td></tr>";
      }).join("") + "</tbody></table></section>";
  }

  function modelsCard(models) {
    return '<section class="card" aria-labelledby="modelsTitle"><div class="card__head"><h2 class="card__title" id="modelsTitle">' + t("Models", "模型") + "</h2></div>" +
      '<table class="models"><caption class="sr-only">' + t("Cost by model", "按模型的花费") + "</caption><tbody>" + models.map(function (m) {
        return '<tr><td><i class="dot dot--' + esc(m.tool) + '" aria-hidden="true"></i> <span class="mono">' + esc(m.model) + '</span></td><td class="num">' + esc(Q.compact(m.tokens)) + '</td><td class="num">' + esc(U.money(m.costUSD)) + "</td></tr>";
      }).join("") + "</tbody></table></section>";
  }

  function render(data) {
    detail = data;
    setHead(data);
    var all = data.totals.all;
    var project = data.project;
    main.innerHTML =
      '<header class="phead2">' +
        '<div class="phead2__title">' +
          '<p class="eyebrow"><span class="eyebrow__dot" aria-hidden="true"></span>' + t("Project", "项目") + "</p>" +
          "<h1>" + esc(project.name) + "</h1>" +
          '<p class="page__meta"><span>' + t("by ", "作者 ") + '<a class="link-quiet" href="' + esc(Q.profileHref(data.owner.username)) + '">' + esc(data.owner.displayName) + " @" + esc(data.owner.username) + "</a></span>" +
            (project.repo ? '<span><a class="pcard__repo" href="https://' + esc(project.repo) + '" rel="nofollow ugc noopener">' + Q.ICONS.github + esc(project.repo) + "</a></span>" : "") +
            (data.firstDate ? "<span>" + esc(ZH ? Q.calendarDate(data.firstDate, true) + " 起" : "Since " + Q.calendarDate(data.firstDate, true)) + "</span>" : "") +
          "</p>" +
          '<div class="kit-row">' + rankChip(t("This week", "本周项目榜"), data.ranks.week) + rankChip(t("365 days", "近一年项目榜"), data.ranks.all) + "</div>" +
        "</div>" +
        '<div class="page__actions"><span id="projectLive"></span>' +
          '<button type="button" class="btn" id="copyLink" data-done="' + esc(t("Link copied", "链接已复制")) + '">' + Q.ICONS.link + "<span>" + t("Copy link", "复制链接") + "</span></button>" +
          '<button type="button" class="btn btn--primary" id="shareImage">' + Q.ICONS.download + "<span>" + t("Share image", "生成分享图") + "</span></button>" +
        "</div>" +
      "</header>" +
      '<div class="ui-sec">' + U.tiles([
        { label: t("Cost, 365 days", "近一年花费"), value: all.costUSD, format: "money", key: "pj-cost" },
        { label: "Token", value: all.tokens, format: "compact", key: "pj-tokens" },
        { label: t("Sessions", "会话"), value: all.sessions, format: "number", key: "pj-sessions" },
        { label: t("Active days", "活跃天数"), value: all.activeDays, format: "number", key: "pj-days" },
        { label: t("This week", "本周花费"), value: data.totals.week.costUSD, format: "money", key: "pj-week" },
      ]) + "</div>" +
      '<p class="card__sub ui-sec__note">' + esc(ZH ? "活跃时长 " + hoursText(all.activeMinutes) + " · 当前连续 " + data.streaks.current + " 天 · 最长连续 " + data.streaks.longest + " 天" :
        hoursText(all.activeMinutes) + " active · current streak " + U.days(data.streaks.current) + " · longest " + U.days(data.streaks.longest)) + "</p>" +
      '<section class="card ui-sec" aria-labelledby="dailyTitle"><div class="card__head"><div><h2 class="card__title" id="dailyTitle">' + t("Cost per day", "每天的花费") + '</h2><p class="card__sub">' + t("By tool", "按工具分段") + "</p></div>" +
        '<div class="kit-row">' + U.toolLegend() + '<div class="seg range-seg" id="rangeSeg" role="group" aria-label="' + esc(t("Range", "范围")) + '">' +
        [30, 90, 365].map(function (n) { return '<button type="button" data-value="' + n + '" aria-pressed="' + (n === range) + '">' + (ZH ? n + " 天" : n + " days") + "</button>"; }).join("") + "</div></div></div>" +
        '<div id="projectDaily"></div></section>' +
      '<section class="card ui-sec" aria-labelledby="heatTitle"><div class="card__head"><h2 class="card__title" id="heatTitle">' + t("A year of work", "一年里哪天在做") + '</h2></div><div id="projectHeat"></div></section>' +
      '<div class="ui-grid ui-grid--3 ui-sec">' +
        '<section class="card" aria-labelledby="toolsTitle"><div class="card__head"><h2 class="card__title" id="toolsTitle">' + t("Tools", "工具") + '</h2><span class="card__sub">' + t("365 days", "近一年") + '</span></div><div id="projectTools"></div></section>' +
        modesCard(data.modes || []) + modelsCard(data.models || []) + "</div>" +
      ((data.repo || (data.contributors || []).length > 1) ? '<div class="ui-grid ui-grid--2 ui-sec">' + repoCard(data.repo) + contributorsCard(data.contributors) + "</div>" : "");

    $("projectLive").innerHTML = U.pill();
    drawDaily();
    var values = {};
    (data.days || []).forEach(function (d) { values[d.date] = d.costUSD; });
    $("projectHeat").innerHTML = Q.heatmap({
      to: data.to, values: values,
      tip: function (date, value) { return "<b>" + (value > 0 ? esc(U.money(value)) : t("Nothing", "没有用量")) + "</b> · " + esc(Q.calendarDate(date)); },
      label: t("Cost per day over the last year", "近一年每天的花费"),
      note: t("Each square is a day's cost", "每一格是那天的花费"),
    });
    Q.heatmapReady($("projectHeat"));
    U.donut($("projectTools"), {
      items: (data.tools || []).map(function (x) { return { id: x.tool, label: U.toolName(x.tool), color: U.toolColor(x.tool), value: x.costUSD }; }),
      caption: t("365 days", "近一年"), stack: true, label: t("Cost by tool", "按工具的花费"),
    });
    var gh = data.repo && data.repo.github;
    if (gh && Array.isArray(gh.weeks) && $("commitChart")) {
      var end = new Date();
      var dates = gh.weeks.map(function (_, i) { return new Date(end.getTime() - (gh.weeks.length - 1 - i) * 7 * 86400000).toISOString().slice(0, 10); });
      U.columns($("commitChart"), { dates: dates, stacks: [{ id: "commits", label: t("Commits", "提交"), color: "#16a34a", values: gh.weeks }], height: 120,
        format: function (n) { return Q.number(Math.round(n)); }, label: t("Commits per week", "每周提交数") });
    }
    U.countUp(main, true);
    Q.setBusy(main, false);
  }

  function notFound() {
    document.title = t("Project not found · Quota Run", "找不到这个项目 · Quota Run");
    main.innerHTML = '<section class="ui-sec">' + Q.stateBox("empty", t("No public project here", "这里没有公开的项目"),
      t("The link may have a typo, or the owner took the project private — that removes it from quota.run at once.", "可能链接拼错了，也可能作者把项目改回了不公开——改回不公开会立刻从 quota.run 撤下。"),
      '<a class="btn btn--primary" href="' + esc(Q.pageHref("projects")) + '">' + t("See the project board", "去看项目榜") + "</a>" +
      (where.user ? '<a class="link" href="' + esc(Q.profileHref(where.user)) + '">@' + esc(where.user) + "</a>" : "")) + "</section>";
    Q.setBusy(main, false);
  }

  function load() {
    if (!Q.USERNAME.test(where.user) || !/^[a-z0-9-]{1,48}$/.test(where.slug)) { notFound(); return; }
    Q.getJSON("/users/" + encodeURIComponent(where.user) + "/projects/" + encodeURIComponent(where.slug), !!detail).then(function (data) {
      if (!data || !data.project) throw Object.assign(new Error("not found"), { status: 404 });
      var fresh = !detail;
      if (fresh) render(data);
      else {
        detail = data;
        var tiles = main.querySelector(".tiles");
        if (tiles) tiles.outerHTML = U.tiles([
          { label: t("Cost, 365 days", "近一年花费"), value: data.totals.all.costUSD, format: "money", key: "pj-cost" },
          { label: "Token", value: data.totals.all.tokens, format: "compact", key: "pj-tokens" },
          { label: t("Sessions", "会话"), value: data.totals.all.sessions, format: "number", key: "pj-sessions" },
          { label: t("Active days", "活跃天数"), value: data.totals.all.activeDays, format: "number", key: "pj-days" },
          { label: t("This week", "本周花费"), value: data.totals.week.costUSD, format: "money", key: "pj-week" },
        ]);
        drawDaily();
        U.countUp(main);
      }
    }).catch(function (error) {
      if (error && error.status === 404) notFound();
      else { main.innerHTML = Q.errorBox(t("Couldn't load this project.", "项目没加载出来。")); Q.setBusy(main, false); }
    });
  }

  /* ── 分享图：1200 × 630，白底，名称、作者、花费、工具占比和近 30 天的柱子 ── */

  function shareImage() {
    var d = detail;
    var canvas = document.createElement("canvas");
    canvas.width = 1200;
    canvas.height = 630;
    var c = canvas.getContext("2d");
    var font = '"Instrument Sans", "PingFang SC", system-ui, sans-serif';
    c.fillStyle = "#ffffff";
    c.fillRect(0, 0, 1200, 630);
    c.strokeStyle = "#e5e7eb";
    c.lineWidth = 2;
    c.strokeRect(1, 1, 1198, 628);
    c.fillStyle = "#16a34a";
    c.beginPath(); c.arc(72, 76, 8, 0, Math.PI * 2); c.fill();
    c.fillStyle = "#6b7280";
    c.font = "600 24px " + font;
    c.fillText("Quota Run · " + t("Project", "项目"), 92, 84);
    c.fillStyle = "#111827";
    c.font = "600 64px " + font;
    c.fillText(d.project.name.slice(0, 28), 64, 180);
    c.fillStyle = "#6b7280";
    c.font = "400 28px " + font;
    c.fillText("@" + d.owner.username + (d.project.repo ? "  ·  " + d.project.repo : ""), 64, 228);
    c.fillStyle = "#111827";
    c.font = "600 80px " + font;
    c.fillText(U.money(d.totals.all.costUSD), 64, 350);
    c.fillStyle = "#6b7280";
    c.font = "400 28px " + font;
    c.fillText(Q.compact(d.totals.all.tokens) + " token  ·  " + (ZH ? d.totals.all.activeDays + " 天" : d.totals.all.activeDays + " days") + "  ·  " + t("365 days", "近一年"), 64, 400);
    var total = (d.tools || []).reduce(function (s, x) { return s + x.costUSD; }, 0) || 1;
    var x = 64;
    U.TOOLS.forEach(function (tool) {
      var item = (d.tools || []).filter(function (it) { return it.tool === tool.id; })[0];
      if (!item) return;
      var w = Math.max(4, 520 * item.costUSD / total - 4);
      c.fillStyle = tool.color;
      c.fillRect(x, 452, w, 16);
      x += w + 4;
    });
    x = 64;
    c.font = "400 22px " + font;
    U.TOOLS.forEach(function (tool) {
      var item = (d.tools || []).filter(function (it) { return it.tool === tool.id; })[0];
      if (!item) return;
      c.fillStyle = tool.color;
      c.beginPath(); c.arc(x + 7, 506, 7, 0, Math.PI * 2); c.fill();
      c.fillStyle = "#374151";
      var label = tool.name + " " + Math.round(item.costUSD / total * 100) + "%";
      c.fillText(label, x + 22, 514);
      x += c.measureText(label).width + 52;
    });
    var byDate = {};
    (d.days || []).forEach(function (day) { byDate[day.date] = day.costUSD; });
    var bars = [];
    for (var i = 29; i >= 0; i--) bars.push(byDate[isoMinus(d.to, i)] || 0);
    var max = Math.max.apply(null, bars.concat(0.01));
    bars.forEach(function (v, i) {
      var h = 260 * v / max;
      c.fillStyle = v > 0 ? "#16a34a" : "#f3f4f6";
      c.fillRect(680 + i * 16, 520 - Math.max(v > 0 ? 4 : 2, h), 12, Math.max(v > 0 ? 4 : 2, h));
    });
    c.fillStyle = "#9ca3af";
    c.font = "400 22px " + font;
    c.fillText(t("Cost per day, last 30 days", "近 30 天每天的花费"), 680, 568);
    c.fillText("quota.run", 1030, 590);
    canvas.toBlob(function (blob) {
      if (!blob) return;
      var url = URL.createObjectURL(blob);
      var a = document.createElement("a");
      a.href = url;
      a.download = "quota-run-" + d.owner.username + "-" + d.project.slug + ".png";
      document.body.appendChild(a);
      a.click();
      a.remove();
      setTimeout(function () { URL.revokeObjectURL(url); }, 2000);
    }, "image/png");
  }

  main.addEventListener("click", function (event) {
    var seg = event.target.closest("#rangeSeg button[data-value]");
    if (seg) { range = Number(seg.getAttribute("data-value")); drawDaily(); return; }
    if (event.target.closest("#copyLink")) {
      Q.copyText("https://quota.run/" + (ZH ? "zh/" : "") + "@" + detail.owner.username + "/" + detail.project.slug, $("copyLink"));
      return;
    }
    if (event.target.closest("#shareImage")) { shareImage(); return; }
    if (event.target.closest("[data-retry]")) load();
  });

  var refresh = U.debounce(load, 900);
  U.connect(function (name, data) { if (name === "usage" && data && detail && data.username === detail.owner.username) refresh(); });
  load();
})();

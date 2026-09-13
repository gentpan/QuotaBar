/* Quota Run（quota.run）的排行榜：index.html。
 *
 * 左栏是榜单列表（/boards），右边是一张榜：标题、筛选、数字条（/leaderboard 的 summary），
 * 和四个视图——成绩单（颁奖台 + 表格 + 对比托盘）、赛道（每人一条跨整个窗口的跑道）、
 * 对比（/runs/<runId> 的用量曲线 + 逐项对比）、服务商（/insights，按窗口占比摆在一起）。
 * 看的是哪张榜、哪个视图、按什么排、哪个赛季和地区、只看已验证、在比谁，全都写在地址里，
 * 复制出去就是同一个画面。一个榜单都没有时，换成「怎么加入」的说明。
 * 共用的格式、链接和接口在 common.js（window.QuotaRun）。
 */
(function () {
  "use strict";

  var Q = window.QuotaRun;
  if (!Q || Q.PAGE !== "leaderboard") return;
  var t = Q.t, esc = Q.esc, $ = Q.$, each = Q.each, ZH = Q.ZH, clock = Q.clock, has = Q.has;

  var VIEWS = ["sheet", "track", "compare", "providers"];
  var METRICS = ["speed", "to90", "to50", "peak"];
  var MAX_COMPARE = 4;
  var PAGE_ROWS = 50;
  var PAGE_LANES = 20;
  var LIMIT = 200;
  var BOARD_RE = /^([a-z0-9-]{1,40}):([a-z0-9]{0,60}):(\d{1,8}:[^\n]{0,80})$/;

  var dom = {
    sideLabel: $("sideBoardsLabel"), side: $("sideBoards"), sideProviders: $("sideProviders"),
    sideMine: $("sideMine"), sideMineSub: $("sideMineSub"),
    app: $("boardApp"), join: $("joinPanel"),
    logo: $("boardLogo"), title: $("boardTitle"), sub: $("boardSub"),
    season: $("fSeason"), region: $("fRegion"), verified: $("fVerified"), copy: $("copyLink"),
    kpis: $("kpis"), tabs: document.querySelector(".tabs"), metricSeg: $("metricSeg"), scaleSeg: $("scaleSeg"),
    views: { sheet: $("view-sheet"), track: $("view-track"), compare: $("view-compare"), providers: $("view-providers") },
    provBody: $("provBody"), tray: $("tray"),
  };
  var SHEET_SKELETON = dom.views.sheet.innerHTML;

  var state = readURL(location.search);
  var me = null;            // 登录着的用户名
  var boards = null;        // /boards
  var data = null;          // 当前榜单的 /leaderboard
  var scale = "share";      // 服务商视图：按窗口占比 / 按实际时长
  var expanded = { sheet: false, track: false };
  var seq = 0;
  var cache = {};
  var failed = {};

  /* ── 地址 ─────────────────────────────────────────────────────────── */

  function readURL(search) {
    var p = new URLSearchParams(search);
    var board = null;
    var m = BOARD_RE.exec(p.get("board") || "");
    if (m) {
      board = { provider: m[1], plan: m[2], windowKey: m[3] };
    } else if (/^[a-z0-9-]{1,40}$/.test(p.get("provider") || "") && /^\d{1,8}:[^\n]{0,80}$/.test(p.get("window") || "")) {
      // 早先分享出去的 ?provider=&plan=&window= 链接
      board = { provider: p.get("provider"), plan: /^[a-z0-9]{0,60}$/.test(p.get("plan") || "") ? p.get("plan") || "" : "", windowKey: p.get("window") };
    }
    var seen = {};
    return {
      board: board,
      view: VIEWS.indexOf(p.get("view")) >= 0 ? p.get("view") : "sheet",
      metric: METRICS.indexOf(p.get("metric")) >= 0 ? p.get("metric") : "speed",
      season: /^(last|all)$/.test(p.get("season") || "") ? p.get("season") : "current",
      region: /^(global|china)$/.test(p.get("region") || "") ? p.get("region") : "",
      verified: p.get("tier") === "verified",
      compare: (p.get("compare") || "").split(",").map(function (u) { return u.trim().replace(/^@/, "").toLowerCase(); })
        .filter(function (u) {
          if (!Q.USERNAME.test(u) || seen[u]) return false;
          seen[u] = true;
          return true;
        }).slice(0, MAX_COMPARE),
    };
  }

  function urlPairs(extra) {
    return Object.assign({
      board: state.board ? Q.boardKey(state.board) : "",
      view: state.view === "sheet" ? "" : state.view,
      metric: state.metric === "speed" ? "" : state.metric,
      season: state.season === "current" ? "" : state.season,
      region: state.region,
      tier: state.verified ? "verified" : "",
      compare: state.compare.join(","),
    }, extra || {});
  }

  function writeURL(push) {
    var q = Q.query(Q.demoPairs(urlPairs()));
    var url = location.pathname + (q ? "?" + q : "");
    if (url !== location.pathname + location.search) {
      try { history[push ? "pushState" : "replaceState"](null, "", url); } catch (e) { /* file:// 下有的浏览器不让改 */ }
    }
    Q.setLangLinks(q ? "?" + q : "");
    dom.sideProviders.setAttribute("href", Q.homeHref(urlPairs({ view: "providers", compare: "" })));
  }

  function shareURL() {
    var q = Q.query(urlPairs());
    return Q.SHARE + (q ? "?" + q : "");
  }

  /* ── 数据 ─────────────────────────────────────────────────────────── */

  function get(path) {
    if (!cache[path]) {
      var load = Q.getJSON(path);
      cache[path] = load;
      delete failed[path];
      load.then(function (value) { load.value = value || {}; }, function () {
        if (cache[path] === load) delete cache[path];
        failed[path] = true;
      });
    }
    return cache[path];
  }

  function ready(path) { return !!(cache[path] && "value" in cache[path]); }
  function value(path) { return ready(path) ? cache[path].value : null; }

  function boardsPath() {
    return "/boards?" + Q.query({ season: Q.seasonParam(state.season), region: state.region });
  }

  function boardPath(metric, season) {
    var b = state.board;
    return "/leaderboard?" + Q.query({
      provider: b.provider, plan: b.plan, window: b.windowKey, metric: metric || state.metric,
      season: Q.seasonParam(season || state.season), region: state.region, tier: state.verified ? "verified" : "all", limit: LIMIT,
    });
  }

  function insightsPath() {
    return "/insights?" + Q.query({ season: Q.seasonParam(state.season), region: state.region });
  }

  function runPath(id) { return "/runs/" + encodeURIComponent(id); }

  function sameBoard(a, b) {
    return !!(a && b) && a.provider === b.provider && String(a.plan || "") === String(b.plan || "") && a.windowKey === b.windowKey;
  }

  function boardInfo() {
    var b = state.board || {};
    var listed = (boards || []).filter(function (x) { return sameBoard(x, b); })[0];
    return Object.assign({}, b, listed || {}, (data && data.board) || {});
  }

  function entries() { return (data && data.entries) || []; }
  function summary() { return (data && data.summary) || null; }

  function entryOf(username) {
    return entries().filter(function (e) { return e.username === username; })[0] || null;
  }

  // 选中要比的人，按名次排
  function picked() {
    return state.compare.map(entryOf).filter(Boolean).sort(function (a, b) { return a.rank - b.rank; });
  }

  /* ── 数值 ─────────────────────────────────────────────────────────── */

  function splits(e) {
    return {
      to50: e.secondsTo50, to90: e.secondsTo90,
      to100: has(e.secondsTo100) ? e.secondsTo100 : state.metric === "speed" ? e.value : null,
      peak: has(e.peakPercent) ? e.peakPercent : state.metric === "peak" ? e.value : null,
    };
  }

  function valueOf(e, metric) {
    metric = metric || state.metric;
    var s = splits(e);
    var v = metric === "peak" ? s.peak : metric === "to90" ? s.to90 : metric === "to50" ? s.to50 : s.to100;
    return has(v) ? Number(v) : Number(e.value);
  }

  function formatValue(v, metric, withSeconds) {
    return (metric || state.metric) === "peak" ? Q.percent(v) : clock(v, withSeconds);
  }

  function gapText(e, first, withSeconds) {
    var d = valueOf(e) - valueOf(first);
    if (state.metric === "peak") {
      var pts = Math.round(Math.abs(d) * 10) / 10;
      return pts ? (d < 0 ? "−" : "+") + pts + t(" pts", " 个点") : "0";
    }
    return Q.gap(d, withSeconds);
  }

  function place(rank) {
    if (ZH) return "第 " + rank + " 名";
    var n = Number(rank), tens = n % 100;
    var suffix = tens > 10 && tens < 14 ? "th" : { 1: "st", 2: "nd", 3: "rd" }[n % 10] || "th";
    return n + suffix;
  }

  function rankText(rank) { return rank < 10 ? "0" + rank : String(rank); }

  function metricName(metric) {
    return { speed: t("Time to 100%", "用满用时"), to90: t("Time to 90%", "到 90% 用时"), to50: t("Time to 50%", "到 50% 用时"), peak: t("Highest peak", "最高峰值") }[metric];
  }

  function you() { return '<span class="tag tag--you">' + t("you", "你") + "</span>"; }

  function who(e, extraClass) {
    return '<div class="who' + (extraClass ? " " + extraClass : "") + '">' +
      '<a class="who__link" href="' + esc(Q.profileHref(e.username)) + '">' + Q.avatar(e) +
      '<span class="who__name">' + esc(e.displayName || e.username) + "</span>" +
      (extraClass === "who--row" ? '<span class="who__handle">@' + esc(e.username) + "</span>" : "") + "</a>" +
      Q.accountMark(e.accountVerified) + (e.username === me ? you() : "") + "</div>";
  }

  /* ── 左栏 ─────────────────────────────────────────────────────────── */

  function sideSkeleton() {
    Q.setBusy(dom.side, true);
    var one = '<span class="bd bd--skel" aria-hidden="true"><span class="skel skel--logo"></span><span class="bd__text"><span class="skel skel--line"></span><span class="skel skel--short"></span></span></span>';
    dom.side.innerHTML = one + one + one + one;
  }

  function renderSide(broken) {
    Q.setBusy(dom.side, false);
    // 重画会丢焦点：键盘用户刚点的那一项，重画后把焦点放回当前榜单
    var hadFocus = dom.side.contains(document.activeElement);
    dom.sideLabel.textContent = dom.sideLabel.getAttribute("data-" + state.season) || dom.sideLabel.textContent;
    var list = (boards || []).slice();
    if (state.board && !list.some(function (b) { return sameBoard(b, state.board); })) list.push(boardInfo());
    if (!list.length) {
      dom.side.innerHTML = '<p class="side__none">' + (broken
        ? t("Boards show up here once the service answers.", "服务恢复后，榜单会出现在这里。")
        : t("No boards yet. The first full window opens one.", "还没有榜单，有人跑完第一个窗口就有了。")) + "</p>";
    } else {
      var keep = { metric: state.metric === "speed" ? "" : state.metric, season: state.season === "current" ? "" : state.season, region: state.region, tier: state.verified ? "verified" : "", view: state.view === "sheet" || state.view === "providers" ? "" : state.view };
      dom.side.innerHTML = list.map(function (b) {
        var on = state.view !== "providers" && sameBoard(b, state.board);
        return '<a class="bd" href="' + esc(Q.boardHref(b, keep)) + '" data-board="' + esc(Q.boardKey(b)) + '"' + (on ? ' aria-current="page"' : "") + ">" +
          Q.logo(b.provider, 16) +
          '<span class="bd__text"><b>' + esc(Q.boardName(b)) + "</b><small>" + esc(Q.windowLabel(b.windowSeconds, b.windowKey, b.windowTitle)) + "</small></span>" +
          '<span class="bd__n mono">' + (has(b.runners) ? Q.number(b.runners) : "") + "</span></a>";
      }).join("");
      if (hadFocus) {
        var current = dom.side.querySelector('[aria-current="page"]');
        if (current) current.focus();
      }
    }
    if (state.view === "providers") dom.sideProviders.setAttribute("aria-current", "page");
    else dom.sideProviders.removeAttribute("aria-current");
  }

  function renderMine() {
    if (me) {
      dom.sideMine.setAttribute("href", Q.profileHref(me));
      dom.sideMineSub.textContent = "@" + me;
    } else {
      dom.sideMine.setAttribute("href", Q.pageHref("login", { next: Q.currentPath() }));
      dom.sideMineSub.textContent = dom.sideMine.getAttribute("data-sub-out");
    }
  }

  /* ── 标题、筛选、数字条 ───────────────────────────────────────────── */

  function syncControls() {
    dom.season.value = state.season;
    dom.region.value = state.region;
    dom.verified.checked = state.verified;
    each(dom.metricSeg.querySelectorAll("button"), function (b) { b.setAttribute("aria-pressed", String(b.getAttribute("data-metric") === state.metric)); });
    each(dom.scaleSeg.querySelectorAll("button"), function (b) { b.setAttribute("aria-pressed", String(b.getAttribute("data-scale") === scale)); });
    each(dom.tabs.querySelectorAll('[role="tab"]'), function (tab) {
      var on = tab.getAttribute("data-view") === state.view;
      tab.setAttribute("aria-selected", String(on));
      tab.setAttribute("tabindex", on ? "0" : "-1");
    });
    VIEWS.forEach(function (v) { dom.views[v].hidden = v !== state.view; });
    dom.metricSeg.hidden = state.view === "compare" || state.view === "providers";
    dom.scaleSeg.hidden = state.view !== "providers";
  }

  function seasonLine() {
    if (state.season === "all") return t("All seasons", "全部赛季");
    if (state.season === "last") return Q.isoWeek(Date.now() - 7 * 86400000) + " · " + t("last week", "上周");
    var left = Math.max(0, Q.weekStart(Date.now()) + 7 * 86400 - Date.now() / 1000);
    var d = Math.floor(left / 86400), h = Math.floor(left % 86400 / 3600);
    return Q.isoWeek(Date.now()) + " · " + (ZH ? "本周还剩 " + (d ? d + " 天 " : "") + h + " 小时" : (d ? d + "d " : "") + h + "h left this week");
  }

  function renderHeader() {
    var b = boardInfo();
    if (!b.provider) return;
    var name = Q.boardName(b) + " · " + Q.windowLabel(b.windowSeconds, b.windowKey, b.windowTitle);
    dom.logo.innerHTML = Q.logo(b.provider, 32);
    dom.title.textContent = name;
    document.title = name + t(" · Quota Run leaderboard", " · Quota Run 排行榜");
    var updated = Q.toDate(data && data.updatedAt);
    dom.sub.innerHTML = esc(seasonLine()) + (updated ? " · " + (ZH ? Q.timeTag(updated) + "更新" : "updated " + Q.timeTag(updated)) : "");
  }

  function kpi(key, html, flat) {
    var el = dom.kpis.querySelector('[data-k="' + key + '"]');
    el.innerHTML = html;
    el.classList.toggle("is-flat", !!flat);
  }

  function renderKpis() {
    var keys = ["runners", "fastest", "median", "completed", "verified"];
    if (!data) {
      keys.forEach(function (k) { kpi(k, '<span class="skel skel--value"></span>'); kpi(k + "Note", ""); });
      return;
    }
    var s = summary();
    if (!s) {
      keys.forEach(function (k) { kpi(k, "—"); kpi(k + "Note", ""); });
      return;
    }
    var prevLabel = state.season === "last" ? t(" vs the week before", "比前一周") : t(" vs last week", "比上周");

    kpi("runners", Q.number(s.runners));
    if (has(s.runnersPrev)) {
      var d = s.runners - s.runnersPrev;
      var delta = (d < 0 ? "−" : "+") + Q.number(Math.abs(d));
      kpi("runnersNote", ZH ? prevLabel + " " + delta : delta + prevLabel, d <= 0);
    } else {
      kpi("runnersNote", state.season === "all" ? t("across all seasons", "历届合计") : "", true);
    }

    if (s.fastest) {
      kpi("fastest", esc(clock(s.fastest.seconds)));
      kpi("fastestNote", '<a href="' + esc(Q.profileHref(s.fastest.username)) + '">@' + esc(s.fastest.username) + "</a>");
    } else {
      kpi("fastest", "—");
      kpi("fastestNote", t("no one yet", "还没有人"), true);
    }

    kpi("median", esc(clock(s.medianSecondsTo100)));
    if (has(s.medianSecondsTo100) && has(s.medianSecondsTo100Prev)) {
      var diff = s.medianSecondsTo100 - s.medianSecondsTo100Prev;
      var than = state.season === "last" ? t("the week before", "前一周") : t("last week", "上周");
      if (Math.abs(diff) < 60) kpi("medianNote", ZH ? "和" + than + "持平" : "Same as " + than, true);
      else if (diff < 0) kpi("medianNote", ZH ? "比" + than + "快 " + Q.approx(diff) : Q.approx(diff) + " faster than " + than);
      else kpi("medianNote", ZH ? "比" + than + "慢 " + Q.approx(diff) : Q.approx(diff) + " slower than " + than, true);
    } else {
      kpi("medianNote", "", true);
    }

    kpi("completed", Q.share(s.completedShare));
    kpi("completedNote", has(s.completed) ? (ZH ? Q.number(s.completed) + " 人" : Q.number(s.completed) + (s.completed === 1 ? " runner" : " runners")) : "");

    kpi("verified", Q.share(s.verifiedShare));
    kpi("verifiedNote", has(s.accountVerifiedShare) ? t("Account verified ", "账号已核实 ") + Q.share(s.accountVerifiedShare) : "");
  }

  /* ── 空榜、出错、加载 ─────────────────────────────────────────────── */

  function emptyBoard() {
    var narrowed = state.verified || state.region;
    var title = narrowed ? t("No runs match these filters", "没有符合筛选条件的成绩")
      : state.season === "current" ? t("No runs on this board this week", "这张榜本周还没有成绩")
      : t("No runs on this board yet", "这张榜还没有成绩");
    return Q.stateBox("empty", title,
      t("Results appear once someone who joined Quota Run reaches the line on this plan. To take part, turn it on in QuotaBar → Settings → Quota Run.",
        "有加入 Quota Run 的人在这个套餐上跑到这条线，成绩就会出现在这里。想参加，在 QuotaBar 的「设置」→「Quota Run」里打开。"),
      (narrowed ? '<button type="button" class="btn" data-clear>' + t("Show everyone", "清除筛选") + "</button>" : "") +
      '<a class="btn btn--primary" href="' + esc(document.querySelector(".join__actions .btn--primary").getAttribute("href")) + '" download>' + Q.ICONS.download + t("Download QuotaBar", "下载 QuotaBar") + "</a>" +
      '<a class="link" href="' + esc(Q.pageHref("rules")) + '">' + t("How it works", "规则说明") + "</a>");
  }

  function showFailure() {
    var box = Q.errorBox(state.view === "providers" ? t("Couldn't load the provider comparison.", "服务商对比没加载出来。") : t("Couldn't load this leaderboard.", "排行榜没加载出来。"));
    var view = dom.views[state.view];
    if (state.view === "providers") dom.provBody.innerHTML = box;
    else view.innerHTML = box;
    Q.setBusy(view, false);
    dom.tray.hidden = true;
  }

  function showJoin() {
    dom.app.hidden = true;
    dom.join.hidden = false;
    $("joinSeason").textContent = Q.isoWeek(Date.now());
    var demoLink = $("joinDemo");
    if (Q.DEMO) demoLink.hidden = true;
    else demoLink.setAttribute("href", Q.homeHref({ demo: "1" }));
    document.title = t("Quota Run — who hits 100% first · QuotaBar", "Quota Run 排行榜 — 谁先把额度用满 · QuotaBar");
  }

  function showApp() {
    dom.app.hidden = false;
    dom.join.hidden = true;
  }

  /* ── 成绩单 ───────────────────────────────────────────────────────── */

  function podium(list) {
    var m = state.metric;
    var labels = { speed: ["to50", "to90"], to90: ["to50", "to100"], to50: ["to90", "to100"], peak: ["to50", "to100"] }[m];
    var names = { to50: "50%", to90: "90%", to100: "100%" };
    return '<div class="podium">' + [0, 1, 2].map(function (i) {
      var e = list[i];
      if (!e) {
        return '<div class="pod pod--open"><div class="pos">' + place(i + 1) + '</div><p class="pod__open">' + t("Open spot", "虚位以待") + "</p></div>";
      }
      var s = splits(e);
      var parts = labels.map(function (k) { return "<span>" + names[k] + " " + (k === "to100" ? clock(s[k]) : Q.hours(s[k])) + "</span>"; });
      if (i === 0) {
        if (m !== "peak") parts.push("<span>" + t("peak ", "峰值 ") + Q.percent(s.peak) + "</span>");
      } else {
        parts.push('<span class="gap">' + gapText(e, list[0], true) + "</span>");
      }
      return '<div class="pod' + (i === 0 ? " pod--first" : "") + '">' +
        '<div class="pos">' + place(e.rank) + "</div>" + who(e, "who--pod") +
        '<div class="time mono">' + formatValue(valueOf(e), m, true) + "</div>" +
        '<div class="split mono">' + parts.join("") + "</div></div>";
    }).join("") + "</div>";
  }

  function sheetRow(e, first, maxRuns, full) {
    var s = splits(e);
    var m = state.metric;
    var chosen = state.compare.indexOf(e.username) >= 0;
    var runs = Number(e.seasonRuns);
    return "<tr" + (e.username === me ? ' class="is-me"' : "") + ">" +
      '<td class="c-cmp"><input type="checkbox" class="check" data-u="' + esc(e.username) + '"' + (chosen ? " checked" : "") + (!chosen && full ? " disabled" : "") +
        ' aria-label="' + esc(t("Compare ", "对比 ") + (e.displayName || e.username)) + '"></td>' +
      '<td class="c-rank mono">' + rankText(e.rank) + "</td>" +
      '<td class="c-who">' + who(e, "who--row") + "</td>" +
      '<td class="num mono' + (m === "to50" ? " best" : "") + '">' + (m === "to50" ? clock(s.to50) : Q.hours(s.to50)) + "</td>" +
      '<td class="num mono' + (m === "to90" ? " best" : "") + '">' + (m === "to90" ? clock(s.to90) : Q.hours(s.to90)) + "</td>" +
      '<td class="num mono' + (m === "speed" ? " best" : "") + '">' + clock(s.to100) + "</td>" +
      (m === "peak" ? '<td class="num mono best">' + Q.percent(s.peak) + "</td>" : "") +
      '<td class="num mono">' + (e === first ? "—" : gapText(e, first)) + "</td>" +
      '<td class="num mono c-runs">' + (has(e.seasonRuns) ? runs + '<span class="bar" aria-hidden="true"><i style="width:' + Math.round(runs / maxRuns * 100) + '%"></i></span>' : "—") + "</td>" +
      '<td class="c-tier">' + Q.tierTag(e.tier) + "</td></tr>";
  }

  function renderSheet() {
    var view = dom.views.sheet;
    var list = entries();
    Q.setBusy(view, false);
    if (!list.length) { view.innerHTML = emptyBoard(); return; }
    var m = state.metric;
    var first = list[0];
    var maxRuns = Math.max.apply(null, list.map(function (e) { return Number(e.seasonRuns) || 0; }).concat([1]));
    var full = picked().length >= MAX_COMPARE;
    var shown = expanded.sheet ? list : list.slice(0, PAGE_ROWS);
    var mine = !expanded.sheet && me ? list.slice(PAGE_ROWS).filter(function (e) { return e.username === me; })[0] : null;
    var cols = 9 + (m === "peak" ? 1 : 0);
    var b = boardInfo();
    view.innerHTML = podium(list) +
      '<div class="tablewrap"><table class="sheet">' +
      '<caption class="sr-only">' + esc(Q.boardName(b) + " · " + metricName(m) + " · " + seasonLine()) + "</caption>" +
      "<thead><tr>" +
        '<th scope="col" class="c-cmp">' + t("Compare", "对比") + "</th>" +
        '<th scope="col" class="c-rank">' + t("Rank", "名次") + "</th>" +
        '<th scope="col">' + t("Runner", "参赛者") + "</th>" +
        '<th scope="col" class="num">' + t("To 50%", "到 50%") + "</th>" +
        '<th scope="col" class="num">' + t("To 90%", "到 90%") + "</th>" +
        '<th scope="col" class="num">' + t("To 100%", "用满用时") + "</th>" +
        (m === "peak" ? '<th scope="col" class="num">' + t("Peak", "峰值") + "</th>" : "") +
        '<th scope="col" class="num">' + t("Gap", "差距") + "</th>" +
        '<th scope="col" class="num">' + (state.season === "all" ? t("Runs", "轮次") : t("Season runs", "本季轮次")) + "</th>" +
        '<th scope="col">' + t("Tier", "级别") + "</th>" +
      "</tr></thead><tbody>" +
      shown.map(function (e) { return sheetRow(e, first, maxRuns, full); }).join("") +
      (mine ? '<tr class="gaprow" aria-hidden="true"><td colspan="' + cols + '">⋯</td></tr>' + sheetRow(mine, first, maxRuns, full) : "") +
      "</tbody></table></div>" +
      (list.length > PAGE_ROWS && !expanded.sheet
        ? '<div class="more"><button type="button" class="btn" data-more="sheet">' + (ZH ? "显示全部 " + list.length + " 人" : "Show all " + list.length + " runners") + "</button></div>"
        : "") +
      (list.length >= LIMIT ? '<p class="more hint">' + (ZH ? "只列出前 " + LIMIT + " 名。" : "Only the top " + LIMIT + " are listed.") + "</p>" : "");
  }

  function syncChecks() {
    var full = picked().length >= MAX_COMPARE;
    each(dom.views.sheet.querySelectorAll("input.check"), function (box) {
      box.checked = state.compare.indexOf(box.getAttribute("data-u")) >= 0;
      box.disabled = !box.checked && full;
    });
  }

  function renderTray() {
    var chosen = picked();
    var show = state.view === "sheet" && entries().length > 0 && chosen.length > 0;
    dom.tray.hidden = !show;
    if (!show) return;
    var n = chosen.length;
    dom.tray.innerHTML =
      '<span class="tray__count">' + (ZH ? "已选 " + n + " 人" : n + " selected") + "</span>" +
      '<ul class="tray__chips">' + chosen.map(function (e) {
        return '<li class="chip">' + Q.avatar(e, "av--sm") + "<span>@" + esc(e.username) + "</span>" +
          '<button type="button" class="chip__x" data-unpick="' + esc(e.username) + '" aria-label="' + esc(t("Remove @" + e.username, "移除 @" + e.username)) + '">' + Q.ICONS.close + "</button></li>";
      }).join("") + "</ul>" +
      '<span class="tray__hint">' + (n >= MAX_COMPARE ? t("Up to 4 at a time, plus the board median", "最多 4 人，再加上本榜中位数") : t("Compared along with the board median", "再加上本榜中位数一起比较")) + "</span>" +
      '<button type="button" class="btn btn--primary tray__go" data-go="compare">' +
        (ZH ? (n === 1 ? "和中位数对比" : "对比这 " + n + " 人") : (n === 1 ? "Compare with the median" : "Compare these " + n)) + "</button>";
  }

  /* ── 赛道 ─────────────────────────────────────────────────────────── */

  function ticks(W) {
    var steps = [3600, 7200, 10800, 21600, 43200, 86400, 172800, 259200, 604800, 1209600];
    var step = steps.filter(function (s) { return W / s <= 10; })[0] || 2592000;
    var at = [];
    for (var x = 0; x < W - 1; x += step) at.push(x);
    return { step: step, at: at };
  }

  function tickLabel(x, step) {
    if (step >= 86400) { var d = x / 86400 + 1; return ZH ? "第 " + d + " 天" : "Day " + d; }
    var h = x / 3600 + 1;
    return ZH ? "第 " + h + " 小时" : "Hour " + h;
  }

  function stepText(step) {
    if (step % 604800 === 0) return step === 604800 ? t("one column per week", "每格一周") : ZH ? "每格 " + step / 604800 + " 周" : "one column per " + step / 604800 + " weeks";
    if (step % 86400 === 0) return step === 86400 ? t("one column per day", "每格一天") : ZH ? "每格 " + step / 86400 + " 天" : "one column per " + step / 86400 + " days";
    return step === 3600 ? t("one column per hour", "每格一小时") : ZH ? "每格 " + step / 3600 + " 小时" : "one column per " + step / 3600 + " hours";
  }

  function pct(x, W) { return Math.max(0, Math.min(100, Number(x) / W * 100)); }
  function at(p) { return p.toFixed(2) + "%"; }

  // 中位数那一轮：榜上有就直接用，没有就读 /runs/<medianRunId>
  function medianRun(onReady) {
    var s = summary();
    if (!s || !s.medianRunId) return null;
    var hit = entries().filter(function (e) { return e.runId === s.medianRunId; })[0];
    if (hit && state.metric === "speed") {
      return { secondsTo50: hit.secondsTo50, secondsTo90: hit.secondsTo90, secondsTo100: hit.secondsTo100, peakPercent: 100, completedAt: hit.achievedAt, runId: hit.runId, username: hit.username };
    }
    var path = runPath(s.medianRunId);
    if (ready(path)) return value(path).run || null;
    if (failed[path]) return null;
    get(path).then(onReady, onReady);
    return "pending";
  }

  function laneTrack(s, W, grid) {
    var segs = "";
    if (has(s.to100)) segs += '<span class="tseg seg100" style="width:' + at(pct(s.to100, W)) + '"></span>';
    if (has(s.to90)) segs += '<span class="tseg seg90" style="width:' + at(pct(s.to90, W)) + '"></span>';
    if (has(s.to50)) segs += '<span class="tseg seg50" style="width:' + at(pct(s.to50, W)) + '"></span>';
    var end = has(s.to100) ? s.to100 : has(s.to90) ? s.to90 : s.to50;
    var flag = "";
    if (has(end)) {
      var p = pct(end, W);
      flag = '<span class="flag mono' + (p > 86 ? " flag--in" : "") + '" style="left:' + at(p) + '">' + (has(s.to100) ? "100%" : t("peak ", "峰值 ") + Q.percent(s.peak)) + "</span>";
    }
    return '<span class="track" aria-hidden="true">' + grid + '<span class="track__base"></span>' + segs + flag + "</span>";
  }

  function laneText(s) {
    var parts = [];
    if (has(s.to50)) parts.push(t("50% at ", "50% 用时 ") + clock(s.to50));
    if (has(s.to90)) parts.push(t("90% at ", "90% 用时 ") + clock(s.to90));
    parts.push(has(s.to100) ? t("100% at ", "用满用时 ") + clock(s.to100) : t("peak ", "峰值 ") + Q.percent(s.peak));
    return '<span class="sr-only">' + esc(parts.join(ZH ? "，" : ", ")) + "</span>";
  }

  function renderTrack() {
    var view = dom.views.track;
    var list = entries();
    Q.setBusy(view, false);
    if (!list.length) { view.innerHTML = emptyBoard(); return; }
    var W = Number(boardInfo().windowSeconds) || 604800;
    var tk = ticks(W);
    var grid = '<span class="track__grid">' + tk.at.map(function (x) { return '<i style="left:' + at(pct(x, W)) + '"></i>'; }).join("") + '<i class="end"></i></span>';
    var withDate = state.season === "all";
    var m = state.metric;

    function lane(e) {
      var s = splits(e);
      return '<li class="lane' + (e.rank === 1 ? " lane--top" : "") + (e.username === me ? " is-me" : "") + '">' +
        '<span class="lane__rank mono">' + rankText(e.rank) + "</span>" +
        who(e, "who--lane") + laneTrack(s, W, grid) +
        '<span class="lane__time mono">' + formatValue(valueOf(e), m) + "<small>" + esc(Q.moment(Q.toDate(e.achievedAt), withDate)) + "</small></span>" +
        laneText(s) + "</li>";
    }

    var shown = expanded.track ? list : list.slice(0, PAGE_LANES);
    var mine = !expanded.track && me ? list.slice(PAGE_LANES).filter(function (e) { return e.username === me; })[0] : null;
    var med = medianRun(function () { if (state.view === "track" && data) renderTrack(); });
    var medianLane = "";
    if (med === "pending") {
      medianLane = '<li class="lane lane--median" aria-hidden="true"><span class="lane__rank">' + t("Med", "中位") + '</span><span class="skel skel--line"></span><span class="skel skel--line"></span><span></span></li>';
    } else if (med) {
      var ms = { to50: med.secondsTo50, to90: med.secondsTo90, to100: med.secondsTo100, peak: med.peakPercent };
      medianLane = '<li class="lane lane--median">' +
        '<span class="lane__rank">' + t("Med", "中位") + "</span>" +
        '<span class="who who--lane"><span class="who__name">' + t("Board median", "本榜中位数") + "</span></span>" +
        laneTrack(ms, W, grid) +
        '<span class="lane__time mono">' + clock(ms.to100) + "<small>" + esc(Q.moment(Q.toDate(med.completedAt), withDate)) + "</small></span>" +
        laneText(ms) + "</li>";
    }

    view.innerHTML =
      '<div class="lanes__head" aria-hidden="true"><span>' + t("Rank", "名次") + "</span><span>" + t("Runner", "参赛者") + "</span>" +
        '<span class="lanes__scale' + (tk.at.length > 7 ? " is-dense" : "") + '">' + tk.at.map(function (x) {
          return '<span style="left:' + at(pct(x, W)) + '">' + tickLabel(x, tk.step) + "</span>";
        }).join("") + "</span>" +
        '<span class="lanes__right">' + metricName(m) + "</span></div>" +
      '<ol class="lanes" aria-label="' + esc(t("Runners across the window", "每位参赛者在窗口里的进度")) + '">' +
        shown.map(lane).join("") +
        (mine ? '<li class="lane lane--gap" aria-hidden="true">⋯</li>' + lane(mine) : "") +
        medianLane + "</ol>" +
      (list.length > PAGE_LANES && !expanded.track
        ? '<div class="more"><button type="button" class="btn" data-more="track">' + (ZH ? "显示全部 " + list.length + " 条赛道" : "Show all " + list.length + " lanes") + "</button></div>"
        : "") +
      '<ul class="legend">' +
        '<li><i class="swatch-bar seg50"></i>0 → 50%</li>' +
        '<li><i class="swatch-bar seg90"></i>50 → 90%</li>' +
        '<li><i class="swatch-bar seg100"></i>90 → 100%</li>' +
        "<li>" + (ZH ? "整条赛道 = " + Q.windowSpan(W) + "的额度窗口，" + stepText(tk.step) : "The whole track is the " + Q.windowSpan(W) + " window, " + stepText(tk.step)) + "</li>" +
      "</ul>";
  }

  /* ── 对比 ─────────────────────────────────────────────────────────── */

  var SPAN_STEPS = [900, 1800, 3600, 7200, 10800, 21600, 43200, 86400, 172800, 259200, 604800];
  var chartSeries = null;

  function niceSpan(want, W) {
    want = Math.max(Math.min(want, W), Math.min(W, 1800));
    for (var i = 0; i < SPAN_STEPS.length; i++) {
      var step = SPAN_STEPS[i];
      var n = Math.ceil(want / step - 1e-9);
      if (n <= 8) return { span: Math.min(n * step, W), step: step };
    }
    return { span: W, step: Math.ceil(W / 8) };
  }

  function axisLabel(x, step) {
    if (step >= 86400) return Math.round(x / 86400) + "d";
    if (step >= 3600) return Math.round(x / 3600) + "h";
    return clock(x);
  }

  function spanText(span) {
    if (span % 86400 === 0) return ZH ? span / 86400 + " 天" : span / 86400 + (span === 86400 ? " day" : " days");
    if (span % 3600 === 0) return ZH ? span / 3600 + " 小时" : span / 3600 + (span === 3600 ? " hour" : " hours");
    return Q.approx(span);
  }

  function endOf(series) {
    var r = series.run, readings = series.readings || [];
    if (has(r.secondsTo100)) return r.secondsTo100;
    return readings.length ? readings[readings.length - 1].t : r.secondsTo90 || r.secondsTo50 || 0;
  }

  function drawChart() {
    var figure = $("curveChart");
    if (!figure || !chartSeries) return;
    var W = Number(boardInfo().windowSeconds) || 604800;
    var width = Math.max(260, Math.round(figure.clientWidth));
    var height = 260, left = 44, right = 16, top = 12, bottom = 28;
    var maxT = 0;
    chartSeries.forEach(function (s) { maxT = Math.max(maxT, endOf(s)); });
    var sp = niceSpan(maxT * 1.08 || W, W);
    var span = sp.span;
    var plotW = width - left - right, plotH = height - top - bottom;
    var x = function (v) { return left + Math.min(Math.max(v, 0), span) / span * plotW; };
    var y = function (p) { return top + (1 - Math.min(Math.max(p, 0), 100) / 100) * plotH; };
    var f = function (n) { return Math.round(n * 10) / 10; };

    var grid = [0, 50, 90, 100].map(function (p) {
      return '<line class="grid' + (p === 50 || p === 90 ? " grid--dash" : "") + '" x1="' + left + '" x2="' + (width - right) + '" y1="' + f(y(p)) + '" y2="' + f(y(p)) + '"/>' +
        '<text class="axis" x="' + (left - 8) + '" y="' + f(y(p) + 4) + '" text-anchor="end">' + (p ? p + "%" : "0") + "</text>";
    }).join("");
    var xs = [];
    for (var v = 0; v <= span + 1; v += sp.step) xs.push(v);
    if (xs[xs.length - 1] < span - sp.step / 2) xs.push(span);
    grid += xs.map(function (v, i) {
      var px = x(v);
      var anchor = i === 0 ? "start" : px > width - right - 20 ? "end" : "middle";
      return (i ? '<line class="grid" x1="' + f(px) + '" x2="' + f(px) + '" y1="' + top + '" y2="' + (height - bottom) + '"/>' : "") +
        '<text class="axis" x="' + f(i === 0 ? left : Math.min(px, width - right)) + '" y="' + (height - 8) + '" text-anchor="' + anchor + '">' + axisLabel(v, sp.step) + "</text>";
    }).join("");

    var lines = chartSeries.map(function (s) {
      var pts = [];
      var readings = s.readings || [];
      for (var i = 0; i < readings.length; i++) {
        var r = readings[i];
        if (r.t > span) {
          var prev = readings[i - 1];
          if (prev) pts.push([span, prev.p + (r.p - prev.p) * (span - prev.t) / Math.max(1, r.t - prev.t)]);
          break;
        }
        pts.push([r.t, r.p]);
      }
      if (pts.length && pts[0][0] > 0) pts.unshift([pts[0][0], pts[0][1]]);
      var line = '<polyline class="curve ' + s.cls + '" points="' + pts.map(function (p) { return f(x(p[0])) + "," + f(y(p[1])); }).join(" ") + '"/>';
      var to100 = s.run.secondsTo100;
      var dot = has(to100) && to100 <= span ? '<circle class="dot ' + s.cls + '" cx="' + f(x(to100)) + '" cy="' + f(y(100)) + '" r="4"/>' : "";
      return line + dot;
    }).join("");

    var desc = chartSeries.map(function (s) {
      var r = s.run;
      return s.label + (has(r.secondsTo100) ? t(": 100% at ", "：用满用时 ") + clock(r.secondsTo100) : t(": peak ", "：峰值 ") + Q.percent(r.peakPercent));
    }).join(ZH ? "；" : "; ");

    figure.innerHTML = '<svg class="chart__svg" width="' + width + '" height="' + height + '" viewBox="0 0 ' + width + " " + height + '" role="img" aria-labelledby="curveSvgTitle curveSvgDesc">' +
      '<title id="curveSvgTitle">' + esc(t("Usage curves", "用量曲线")) + "</title><desc id=\"curveSvgDesc\">" + esc(desc) + "</desc>" +
      grid + lines + "</svg>";
    var hint = $("curveHint");
    if (hint) {
      hint.textContent = ZH
        ? "同一个 " + Q.windowSpan(W) + "窗口里，额度是怎么一路被用掉的" + (span < W ? "（显示前 " + spanText(span) + "）" : "")
        : "How the quota was used up across the same " + Q.windowSpan(W) + " window" + (span < W ? " (first " + spanText(span) + " shown)" : "");
    }
  }

  function delta(a, b, kind) {
    if (!has(a) || !has(b)) return { text: "", cls: "" };
    var d = Number(b) - Number(a);
    if (kind === "count") return { text: d ? (d > 0 ? "+" : "−") + Math.abs(d) : "0", cls: d > 0 ? "delta-good" : d < 0 ? "delta-bad" : "" };
    if (kind === "pct") return { text: (d >= 0 ? "+" : "−") + Math.round(Math.abs(d) * 10) / 10 + t(" pts", " 个点"), cls: d > 0 ? "delta-good" : d < 0 ? "delta-bad" : "" };
    return { text: Q.gap(d), cls: d > 0 ? "delta-bad" : d < 0 ? "delta-good" : "" };
  }

  function sub(a, b) { return has(a) && has(b) ? Number(a) - Number(b) : null; }

  function compareTable(cols, runners, best) {
    var anyPeak = cols.some(function (c) { return has(c.peak) && c.peak < 100; });
    var rows = [
      [t("To 50%", "到 50%"), function (c) { return c.to50; }, "split"],
      ["50 → 90%", function (c) { return sub(c.to90, c.to50); }, "split"],
      ["90 → 100%", function (c) { return sub(c.to100, c.to90); }, "split"],
      [t("To 100%", "用满用时"), function (c) { return c.to100; }, "time"],
    ];
    if (anyPeak) rows.push([t("Peak", "峰值"), function (c) { return c.peak; }, "pct"]);
    rows.push([state.season === "all" ? t("Runs", "轮次") : t("Season runs", "本季轮次"), function (c) { return c.runs; }, "count"]);
    if (best) rows.push([t("Best ever", "历史最好"), function (c) { return c.best; }, "time"]);
    rows.push([t("Board percentile", "本榜百分位"), function (c) { return c.percentile; }, "top"]);
    rows.push([t("Tier", "级别"), function (c) { return c.tier; }, "tier"]);

    var two = cols.length === 2;
    function cell(v, kind) {
      if (kind === "tier") return v ? Q.tierTag(v) : "—";
      if (!has(v)) return "—";
      if (kind === "time") return clock(v);
      if (kind === "split") return Q.hours(v);
      if (kind === "pct") return Q.percent(v);
      if (kind === "top") return ZH ? "前 " + v + "%" : "Top " + v + "%";
      return Q.number(v);
    }
    var head = "<tr><th scope=\"col\"><span class=\"sr-only\">" + t("Measure", "项目") + "</span></th>" +
      cols.map(function (c) { return '<th scope="col" class="num">' + esc(c.label) + "</th>"; }).join("") +
      (two ? '<th scope="col" class="num">' + t("Diff", "差") + "</th>" : "") + "</tr>";
    var body = rows.map(function (row) {
      var kind = row[2];
      var base = row[1](cols[0]);
      return '<tr><th scope="row">' + row[0] + "</th>" + cols.map(function (c, i) {
        var v = row[1](c);
        var d = i > 0 && !two && kind !== "tier" && kind !== "top" ? delta(base, v, kind) : null;
        return '<td class="num mono">' + cell(v, kind) + (d && d.text ? '<small class="' + d.cls + '">' + d.text + "</small>" : "") + "</td>";
      }).join("") +
        (two ? (function () {
          if (kind === "tier" || kind === "top") return "<td></td>";
          var d = delta(base, row[1](cols[1]), kind);
          return '<td class="num mono ' + d.cls + '">' + d.text + "</td>";
        })() : "") + "</tr>";
    }).join("");
    return '<div class="tablewrap"><table class="mt' + (two ? "" : " mt--many") + '"><thead>' + head + "</thead><tbody>" + body + "</tbody></table></div>";
  }

  function renderCompare() {
    var view = dom.views.compare;
    var list = entries();
    Q.setBusy(view, false);
    if (!list.length) { view.innerHTML = emptyBoard(); chartSeries = null; return; }

    var chosen = picked();
    if (!chosen.length) {
      chosen = [list[0]];
      var mine = me && entryOf(me);
      if (mine && mine !== list[0]) chosen.push(mine);
      else if (list[1]) chosen.push(list[1]);
      state.compare = chosen.map(function (e) { return e.username; });
      writeURL(false);
    }
    var s = summary() || {};
    var runners = s.runners || list.length;
    var medianPath = s.medianRunId ? runPath(s.medianRunId) : null;
    // 历史最好：全部赛季的速度榜（已经在看全部赛季时，用满用时就是它）
    var bestPath = state.season === "all" ? null : boardPath("speed", "all");
    var paths = chosen.map(function (e) { return e.runId ? runPath(e.runId) : null; }).concat([medianPath, bestPath]).filter(Boolean);
    var waiting = paths.filter(function (p) { return !ready(p) && !failed[p]; });
    var key = state.compare.join(",") + "|" + Q.boardKey(state.board) + "|" + state.season + state.region + state.verified;

    if (waiting.length) {
      Promise.all(waiting.map(function (p) { return get(p).catch(function () { return null; }); })).then(function () {
        if (state.view === "compare" && data && key === state.compare.join(",") + "|" + Q.boardKey(state.board) + "|" + state.season + state.region + state.verified) renderCompare();
      });
    }

    var classes = ["c1", "c2", "c3", "c4"];
    var series = [];
    chosen.forEach(function (e, i) {
      var r = e.runId && value(runPath(e.runId));
      if (r && r.readings) series.push({ cls: classes[i], label: "@" + e.username, run: r.run || e, readings: r.readings });
    });
    var med = medianPath && value(medianPath);
    if (med && med.readings) series.push({ cls: "cm", label: t("Board median", "本榜中位数"), run: med.run, readings: med.readings });

    var allTime = bestPath ? value(bestPath) : null;
    var bestOf = function (username, current) {
      if (!allTime) return null;
      var hit = (allTime.entries || []).filter(function (x) { return x.username === username; })[0];
      var v = hit ? (has(hit.secondsTo100) ? hit.secondsTo100 : hit.value) : null;
      return has(v) && has(current) ? Math.min(v, current) : has(v) ? v : current;
    };

    var cols = chosen.map(function (e) {
      var sp = splits(e);
      return {
        label: "@" + e.username, to50: sp.to50, to90: sp.to90, to100: sp.to100, peak: sp.peak, runs: e.seasonRuns,
        best: bestOf(e.username, sp.to100), percentile: Math.max(1, Math.ceil(e.rank / runners * 100)), tier: e.tier,
      };
    });
    if (cols.length === 1 && med && med.run) {
      cols.push({ label: t("Median", "中位数"), to50: med.run.secondsTo50, to90: med.run.secondsTo90, to100: med.run.secondsTo100, peak: med.run.peakPercent, runs: null, best: null, percentile: 50, tier: null });
    }

    var meFirst = me && chosen.length > 1 && chosen[0].rank === 1 && chosen.some(function (e) { return e.username === me && e.rank !== 1; });
    var tableHint = meFirst ? t("Where you lose time against first place", "你和第 1 名差在哪一段")
      : cols.length === 2 && chosen.length === 1 ? t("Against the board median", "和本榜中位数比")
      : ZH ? "每一段都和 @" + chosen[0].username + " 比" : "Each stage against @" + chosen[0].username;

    var available = list.filter(function (e) { return state.compare.indexOf(e.username) < 0; });
    var legend = '<ul class="legend legend--chart">' + chosen.map(function (e, i) {
      return '<li><span class="swatch ' + classes[i] + '" aria-hidden="true"></span>@' + esc(e.username) +
        '<span class="muted">' + (ZH ? " 第 " + e.rank + " 名" : " #" + e.rank) + (e.username === me ? t(" (you)", "（你）") : "") + "</span>" +
        '<button type="button" class="legend__x" data-unpick="' + esc(e.username) + '" aria-label="' + esc(t("Remove @" + e.username + " from the comparison", "从对比中移除 @" + e.username)) + '">' + Q.ICONS.close + "</button></li>";
    }).join("") +
      (medianPath ? '<li><span class="swatch cm" aria-hidden="true"></span>' + t("Board median", "本榜中位数") + "</li>" : "") +
      (chosen.length < MAX_COMPARE && available.length
        ? '<li class="legend__add"><label class="select select--sm"><span class="sr-only">' + t("Add a runner to compare", "添加对比的参赛者") + "</span>" +
          '<select data-add><option value="">' + t("+ Add runner", "+ 添加对比") + "</option>" +
          available.slice(0, LIMIT).map(function (e) { return '<option value="' + esc(e.username) + '">' + rankText(e.rank) + " · " + esc(e.displayName || e.username) + " @" + esc(e.username) + "</option>"; }).join("") +
          "</select></label></li>"
        : "") + "</ul>";

    var pendingChart = chosen.some(function (e) { return e.runId && !ready(runPath(e.runId)) && !failed[runPath(e.runId)]; }) || (medianPath && !ready(medianPath) && !failed[medianPath]);
    var noCurves = !pendingChart && !series.length;
    var wide = cols.length > 2;

    view.innerHTML = '<div class="cmpgrid' + (wide ? " cmpgrid--stack" : "") + '">' +
      '<section class="panel" aria-labelledby="curveTitle">' +
        '<h2 class="panel__title" id="curveTitle">' + t("Usage curves", "用量曲线") + "</h2>" +
        '<p class="hint" id="curveHint">' + t("How the quota was used up across the same window", "同一个窗口里，额度是怎么一路被用掉的") + "</p>" +
        '<figure class="chart" id="curveChart">' + (pendingChart ? '<span class="skel skel--block"></span>' : noCurves ? '<p class="chart__none">' + t("No usage curves for these runs.", "这几轮没有用量曲线。") + "</p>" : "") + "</figure>" +
        legend +
      "</section>" +
      '<section class="panel" aria-labelledby="sideTitle">' +
        '<h2 class="panel__title" id="sideTitle">' + t("Side by side", "逐项对比") + "</h2>" +
        '<p class="hint">' + esc(tableHint) + "</p>" +
        compareTable(cols, runners, !!bestPath) +
      "</section></div>";

    chartSeries = pendingChart || noCurves ? null : series;
    drawChart();
  }

  /* ── 服务商对比 ───────────────────────────────────────────────────── */

  var LOG_MIN = 1800, LOG_MAX = 32 * 86400;
  function logPos(seconds) {
    var v = Math.min(Math.max(Number(seconds), LOG_MIN), LOG_MAX);
    return (Math.log(v) - Math.log(LOG_MIN)) / (Math.log(LOG_MAX) - Math.log(LOG_MIN)) * 100;
  }

  function renderProviders() {
    var path = insightsPath();
    Q.setBusy(dom.views.providers, !ready(path));
    if (!ready(path)) {
      var row = '<li class="prov-row prov-row--skel" aria-hidden="true"><span class="skel skel--line"></span><span class="skel skel--line"></span><span class="skel skel--short"></span><span class="skel skel--short"></span><span class="skel skel--short"></span></li>';
      dom.provBody.innerHTML = '<ul class="prov">' + row + row + row + row + "</ul>";
      get(path).then(function () {
        if (state.view === "providers") renderProviders();
      }, function () {
        if (state.view !== "providers") return;
        Q.setBusy(dom.views.providers, false);
        dom.provBody.innerHTML = Q.errorBox(t("Couldn't load the provider comparison.", "服务商对比没加载出来。"));
      });
      return;
    }
    var list = (value(path).boards || []).slice();
    if (!list.length) {
      dom.provBody.innerHTML = Q.stateBox("empty", t("Nothing to compare yet", "还没有可以比的"), t("Plans show up here once people finish their first windows.", "有人跑完第一个窗口，套餐就会出现在这里。"), "");
      return;
    }
    var time = scale === "time";
    var pos = function (seconds, W) { return time ? logPos(seconds) : pct(seconds, W); };
    list.sort(function (a, b) {
      var x = has(a.medianSeconds) ? (time ? a.medianSeconds : a.medianSeconds / a.windowSeconds) : -1;
      var y = has(b.medianSeconds) ? (time ? b.medianSeconds : b.medianSeconds / b.windowSeconds) : -1;
      return y - x || b.runners - a.runners;
    });

    var timeTicks = [[3600, "1h"], [18000, "5h"], [86400, "1d"], [604800, "7d"], [2592000, "30d"]];
    var scaleHead = time
      ? '<span class="prov__scale prov__scale--abs">' + timeTicks.map(function (tk) { var p = logPos(tk[0]); return '<span style="left:' + at(p) + '"' + (p > 90 ? ' class="end"' : "") + ">" + tk[1] + "</span>"; }).join("") + "</span>"
      : '<span class="prov__scale"><span>0%</span><span>25%</span><span>50%</span><span>75%</span><span>' + t("100% of window", "100% 窗口") + "</span></span>";
    var gridLines = time
      ? timeTicks.map(function (tk) { return '<i style="left:' + at(logPos(tk[0])) + '"></i>'; }).join("")
      : "<i style=\"left:0%\"></i><i style=\"left:25%\"></i><i style=\"left:50%\"></i><i style=\"left:75%\"></i><i style=\"left:100%\"></i>";

    var rows = list.map(function (b) {
      var W = Number(b.windowSeconds) || 1;
      var bar = "";
      var sr = [];
      if (has(b.p10Seconds) && has(b.p90Seconds)) {
        var a = pos(b.p10Seconds, W), z = pos(b.p90Seconds, W);
        bar += '<span class="hbar__range" style="left:' + at(a) + ";width:" + at(Math.max(0.5, z - a)) + '"></span>';
      }
      if (time) bar += '<span class="hbar__window" style="left:' + at(logPos(W)) + '" title="' + esc(t("End of the window", "窗口结束")) + '"></span>';
      if (has(b.medianSeconds)) bar += '<span class="hbar__med" style="left:' + at(pos(b.medianSeconds, W)) + '"></span>';
      if (has(b.fastestSeconds)) bar += '<span class="hbar__fast" style="left:' + at(pos(b.fastestSeconds, W)) + '"></span>';
      if (has(b.fastestSeconds)) sr.push(t("fastest ", "最快 ") + clock(b.fastestSeconds) + " (" + Math.round(b.fastestSeconds / W * 100) + "%)");
      if (has(b.p10Seconds) && has(b.p90Seconds)) sr.push(t("middle 80% ", "中间 80% 的人 ") + Math.round(b.p10Seconds / W * 100) + "–" + Math.round(b.p90Seconds / W * 100) + "%");
      if (has(b.medianSeconds)) sr.push(t("median ", "中位数 ") + clock(b.medianSeconds) + " (" + Math.round(b.medianSeconds / W * 100) + "%)");
      if (!sr.length) bar += '<span class="hbar__none">' + t("No one has finished yet", "还没有人用满") + "</span>";
      var byRegion = b.medianByRegion || {};
      var current = sameBoard(b, state.board);
      return '<li><a class="prov-row' + (current ? " is-current" : "") + '" href="' + esc(Q.boardHref(b)) + '" data-board="' + esc(Q.boardKey(b)) + '">' +
        '<span class="prov-row__name">' + Q.logo(b.provider, 16) + "<b>" + esc(Q.boardName(b)) + "</b><small>" + esc(Q.windowLabel(b.windowSeconds, b.windowKey, b.windowTitle)) + "</small></span>" +
        '<span class="hbar"><span class="hbar__grid" aria-hidden="true">' + gridLines + "</span>" + bar +
          (sr.length ? '<span class="sr-only">' + esc(sr.join(ZH ? "，" : ", ")) + "</span>" : "") + "</span>" +
        '<span class="prov-row__num mono" data-label="' + esc(t("Runners", "参赛者")) + '">' + Q.number(b.runners) + "</span>" +
        '<span class="prov-row__num mono" data-label="' + esc(t("Finished", "用满的人")) + '">' + Q.share(b.completedShare) + "</span>" +
        '<span class="prov-row__region mono" data-label="' + esc(t("Median · Global / China", "中位 · 国际 / 中国")) + '">' + Q.short(byRegion.global) + " <span>/</span> " + Q.short(byRegion.china) + "</span>" +
        "</a></li>";
    }).join("");

    dom.provBody.innerHTML =
      '<div class="prov-row prov-row--head" aria-hidden="true"><span>' + t("Plan and window", "套餐与窗口") + "</span>" + scaleHead +
        '<span class="num">' + t("Runners", "参赛者") + '</span><span class="num">' + t("Finished", "用满的人") + '</span><span class="num">' + t("Median · Global / China", "中位 · 国际 / 中国") + "</span></div>" +
      '<ul class="prov">' + rows + "</ul>" +
      '<ul class="legend">' +
        '<li><i class="swatch-dot"></i>' + t("Fastest", "最快的人") + "</li>" +
        '<li><i class="swatch-tick"></i>' + t("Median", "中位数") + "</li>" +
        '<li><i class="swatch-bar swatch-bar--range"></i>' + t("Middle 80% of runners", "中间 80% 的人") + "</li>" +
        (time ? '<li><i class="swatch-tick swatch-tick--window"></i>' + t("End of the window", "窗口结束") + "</li>" : "") +
        "<li>" + t("Pick a row to open that board", "点任一行打开那个榜单") + "</li>" +
      "</ul>";
  }

  /* ── 画面 ─────────────────────────────────────────────────────────── */

  function renderView() {
    syncControls();
    renderSide();
    if (state.view === "providers") {
      dom.tray.hidden = true;
      renderProviders();
      return;
    }
    if (!data) return;
    if (state.view === "sheet") renderSheet();
    else if (state.view === "track") renderTrack();
    else renderCompare();
    renderTray();
  }

  function skeletonView() {
    if (state.view === "providers") return;
    var view = dom.views[state.view];
    Q.setBusy(view, true);
    view.innerHTML = SHEET_SKELETON;
    dom.tray.hidden = true;
  }

  function loadBoard(mine) {
    var path = boardPath();
    if (!ready(path)) {
      data = null;
      renderHeader();
      renderKpis();
      skeletonView();
    }
    get(path).then(function (res) {
      if (mine !== seq) return;
      data = res || {};
      // 地址里要比的人不在这张榜上（换了筛选），就从名单里去掉
      if (entries().length && state.compare.length) {
        var kept = state.compare.filter(entryOf);
        if (kept.length !== state.compare.length) { state.compare = kept; writeURL(false); }
      }
      renderHeader();
      renderKpis();
      renderView();
    }, function () {
      if (mine !== seq) return;
      data = null;
      renderHeader();
      renderKpis();
      each(dom.kpis.querySelectorAll(".kpi__v"), function (el) { el.textContent = "—"; });
      showFailure();
    });
  }

  function load(push) {
    var mine = ++seq;
    expanded = { sheet: false, track: false };
    syncControls();
    writeURL(push);
    var path = boardsPath();
    if (!ready(path)) sideSkeleton();
    get(path).then(function (res) {
      if (mine !== seq) return;
      boards = (res && res.boards) || [];
      if (!state.board && boards.length) {
        var b = boards[0];
        state.board = { provider: b.provider, plan: String(b.plan || ""), windowKey: b.windowKey };
        writeURL(false);
      }
      renderSide();
      if (!state.board) { showJoin(); return; }
      showApp();
      if (state.view === "providers") renderProviders();
      loadBoard(mine);
    }, function () {
      if (mine !== seq) return;
      boards = [];
      renderSide(true);
      showApp();
      if (state.board) { loadBoard(mine); return; }
      dom.logo.innerHTML = "";
      dom.title.textContent = "Quota Run";
      dom.sub.textContent = seasonLine();
      each(dom.kpis.querySelectorAll(".kpi__v"), function (el) { el.textContent = "—"; });
      showFailure();
    });
  }

  function setView(view, push) {
    if (view === state.view) return;
    state.view = view;
    writeURL(push !== false);
    renderView();
  }

  function openBoard(key, view) {
    var m = BOARD_RE.exec(key || "");
    if (!m) return;
    state.board = { provider: m[1], plan: m[2], windowKey: m[3] };
    state.view = view || (state.view === "providers" ? "sheet" : state.view);
    state.compare = [];
    load(true);
    var top = dom.app.getBoundingClientRect().top;
    if (top < 0) window.scrollBy(0, top - 16);
  }

  function toggleCompare(username, on) {
    var list = state.compare.filter(function (u) { return u !== username; });
    if (on && list.length < MAX_COMPARE) list.push(username);
    state.compare = list;
    writeURL(false);
  }

  /* ── 事件 ─────────────────────────────────────────────────────────── */

  function plainClick(event) {
    return event.button === 0 && !event.metaKey && !event.ctrlKey && !event.shiftKey && !event.altKey;
  }

  dom.side.addEventListener("click", function (event) {
    var link = event.target.closest("a[data-board]");
    if (!link || !plainClick(event)) return;
    event.preventDefault();
    openBoard(link.getAttribute("data-board"));
  });

  dom.sideProviders.addEventListener("click", function (event) {
    if (!plainClick(event) || !state.board) return;
    event.preventDefault();
    setView("providers");
  });

  dom.tabs.addEventListener("click", function (event) {
    var tab = event.target.closest('[role="tab"]');
    if (tab) setView(tab.getAttribute("data-view"));
  });

  dom.tabs.addEventListener("keydown", function (event) {
    var tabs = Array.prototype.slice.call(dom.tabs.querySelectorAll('[role="tab"]'));
    var index = tabs.indexOf(document.activeElement);
    if (index < 0) return;
    var next = { ArrowRight: index + 1, ArrowLeft: index - 1, Home: 0, End: tabs.length - 1 }[event.key];
    if (next == null) return;
    event.preventDefault();
    var tab = tabs[(next + tabs.length) % tabs.length];
    setView(tab.getAttribute("data-view"));
    tab.focus();
  });

  dom.metricSeg.addEventListener("click", function (event) {
    var button = event.target.closest("button[data-metric]");
    if (!button || button.getAttribute("data-metric") === state.metric) return;
    state.metric = button.getAttribute("data-metric");
    load(false);
  });

  dom.scaleSeg.addEventListener("click", function (event) {
    var button = event.target.closest("button[data-scale]");
    if (!button) return;
    scale = button.getAttribute("data-scale");
    syncControls();
    renderProviders();
  });

  dom.season.addEventListener("change", function () { state.season = dom.season.value; load(false); });
  dom.region.addEventListener("change", function () { state.region = dom.region.value; load(false); });
  dom.verified.addEventListener("change", function () { state.verified = dom.verified.checked; load(false); });

  dom.copy.addEventListener("click", function () { Q.copyText(shareURL(), dom.copy); });

  dom.app.addEventListener("change", function (event) {
    var box = event.target.closest("input.check[data-u]");
    if (box) {
      toggleCompare(box.getAttribute("data-u"), box.checked);
      syncChecks();
      renderTray();
      return;
    }
    var add = event.target.closest("select[data-add]");
    if (add && add.value) {
      toggleCompare(add.value, true);
      renderCompare();
      var again = dom.views.compare.querySelector("select[data-add]");
      if (again) again.focus();
    }
  });

  dom.app.addEventListener("click", function (event) {
    var target = event.target;
    var el;
    if ((el = target.closest("[data-retry]"))) {
      cache = {};
      failed = {};
      load(false);
    } else if ((el = target.closest("[data-more]"))) {
      expanded[el.getAttribute("data-more")] = true;
      renderView();
    } else if ((el = target.closest("[data-unpick]"))) {
      var username = el.getAttribute("data-unpick");
      toggleCompare(username, false);
      if (state.view === "compare") {
        renderCompare();
      } else {
        syncChecks();
        renderTray();
        var chip = dom.tray.querySelector(".chip__x") || dom.views.sheet.querySelector('input.check[data-u="' + username + '"]');
        if (chip) chip.focus();
      }
    } else if ((el = target.closest("[data-go]"))) {
      setView(el.getAttribute("data-go"));
      dom.tabs.querySelector('[data-view="compare"]').focus();
    } else if ((el = target.closest("[data-clear]"))) {
      state.region = "";
      state.verified = false;
      load(false);
    } else if ((el = target.closest("a.prov-row[data-board]")) && plainClick(event)) {
      event.preventDefault();
      openBoard(el.getAttribute("data-board"), "sheet");
    }
  });

  window.addEventListener("popstate", function () {
    state = readURL(location.search);
    load(false);
  });

  var resizeTimer = 0;
  window.addEventListener("resize", function () {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(function () { if (state.view === "compare") drawChart(); }, 120);
  });

  Q.session().then(function (s) {
    var user = Q.signedInUser(s);
    me = user ? user.username : null;
    renderMine();
    if (data && state.view !== "providers") renderView();
  }, function () { renderMine(); });

  renderMine();
  load(false);
})();

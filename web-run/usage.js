/* Quota Run 的用量榜（usage.html，线上是 /usage）。
 *
 * 读 /usage/boards：数字卡片（上榜人数、总花费、总 token、会话），每天的花费柱状图（按工具分段）和工具占比环，
 * 前三名的领奖台卡片，其余名次的表（名次变化、工具占比条、主要项目、核实比例），以及「正在发生」的实时动态。
 * 订阅 /live：有人的用量涨了或者榜单前十变了，就重读榜单，数字滚动到新值，换了名次的行平移到新位置。
 * 筛选写进地址栏：?period=week|last|month|all&metric=cost|tokens|streak|active&tool=&region=&verified=0。
 */
(function () {
  "use strict";

  var Q = window.QuotaRun, U = window.QuotaUI;
  if (!Q || !U || Q.PAGE !== "usage") return;
  var t = Q.t, esc = Q.esc, ZH = Q.ZH, $ = Q.$;
  var params = new URLSearchParams(location.search);
  var main = $("main"), body = $("usageBody");
  var PERIODS = ["week", "last", "month", "all"], METRICS = ["cost", "tokens", "streak", "active"];
  var state = {
    period: PERIODS.indexOf(params.get("period")) >= 0 ? params.get("period") : "week",
    metric: METRICS.indexOf(params.get("metric")) >= 0 ? params.get("metric") : "cost",
    tool: ["claude", "codex", "opencode"].indexOf(params.get("tool")) >= 0 ? params.get("tool") : "",
    region: ["global", "china"].indexOf(params.get("region")) >= 0 ? params.get("region") : "",
    verified: params.get("verified") !== "0",
  };
  var board = null;
  var shape = "";          // 上一次画出来的是哪一组筛选；变了就整页重画，没变就只更新数字和名次
  var feed = [];
  var loading = null;

  /* ── 筛选 ─────────────────────────────────────────────────────────── */

  function syncControls() {
    [["periodSeg", state.period], ["metricSeg", state.metric]].forEach(function (pair) {
      Q.each($(pair[0]).querySelectorAll("button"), function (b) { b.setAttribute("aria-pressed", String(b.getAttribute("data-value") === pair[1])); });
    });
    $("toolSelect").value = state.tool;
    $("regionSelect").value = state.region;
    $("verifiedSwitch").checked = state.verified;
  }

  function writeAddress() {
    var pairs = { period: state.period === "week" ? "" : state.period, metric: state.metric === "cost" ? "" : state.metric,
      tool: state.tool, region: state.region, verified: state.verified ? "" : "0" };
    var q = Q.query(Q.demoPairs(pairs));
    try { history.replaceState(null, "", location.pathname + (q ? "?" + q : "")); } catch (e) { /* file:// */ }
    Q.setLangLinks(q ? "?" + q : "");
  }

  function onFilter() {
    syncControls();
    writeAddress();
    load(false);
  }

  [["periodSeg", "period"], ["metricSeg", "metric"]].forEach(function (pair) {
    $(pair[0]).addEventListener("click", function (event) {
      var button = event.target.closest("button[data-value]");
      if (!button) return;
      state[pair[1]] = button.getAttribute("data-value");
      onFilter();
    });
  });
  $("toolSelect").addEventListener("change", function (e) { state.tool = e.target.value; onFilter(); });
  $("regionSelect").addEventListener("change", function (e) { state.region = e.target.value; onFilter(); });
  $("verifiedSwitch").addEventListener("change", function (e) { state.verified = e.target.checked; onFilter(); });

  /* ── 文案 ─────────────────────────────────────────────────────────── */

  function periodText() {
    return { week: t("this week", "本周"), last: t("last week", "上周"), month: t("this month", "本月"), all: t("the last 365 days", "近一年") }[state.period];
  }

  function valueFormat() {
    return state.metric === "cost" ? "money" : state.metric === "tokens" ? "compact" : "days";
  }

  function valueText(entry) {
    return state.metric === "cost" ? U.money(entry.value) : state.metric === "tokens" ? Q.compact(entry.value) : U.days(entry.value);
  }

  function metricLabel() {
    return { cost: t("Cost", "花费"), tokens: "Token", streak: t("Streak", "连续天数"), active: t("Active days", "活跃天数") }[state.metric];
  }

  /* ── 画面 ─────────────────────────────────────────────────────────── */

  function tilesHTML(summary) {
    return U.tiles([
      { label: t("On the board", "上榜人数"), value: summary.runners, format: "number", key: "tile-runners" },
      { label: ZH ? periodText() + "总花费" : "Cost " + periodText(), value: summary.costUSD, format: "money", key: "tile-cost" },
      { label: ZH ? periodText() + "总 token" : "Tokens " + periodText(), value: summary.tokens, format: "compact", key: "tile-tokens" },
      { label: t("Sessions", "会话"), value: summary.sessions, format: "number", key: "tile-sessions" },
    ]);
  }

  function runner(entry, size) {
    return '<a class="runner" href="' + esc(Q.profileHref(entry.username)) + '">' + Q.avatar(entry, size || "") +
      '<span class="runner__text"><b>' + esc(entry.displayName || entry.username) + "</b><small>@" + esc(entry.username) +
      (Q.regionLabel(entry.region) ? " · " + esc(Q.regionLabel(entry.region)) : "") + "</small></span></a>";
  }

  function projectLink(entry) {
    if (!entry.topProject) return '<span class="dim">—</span>';
    return '<a class="link-quiet" href="' + esc(Q.projectHref(entry.username, entry.topProject.slug)) + '">' + esc(entry.topProject.name) + "</a>";
  }

  function verifiedShare(entry) {
    if (entry.verifiedShare == null || entry.verifiedShare === 0) return '<span class="dim">' + t("Not verified", "未核实") + "</span>";
    return entry.verifiedShare >= 0.995 ? U.verifiedMark(t("All verified", "全部核实")) : '<span class="muted">' + Q.share(entry.verifiedShare) + "</span>";
  }

  function podiumCard(entry) {
    return '<article class="card podium__card podium--' + entry.rank + '" data-key="' + esc(entry.username) + '">' +
      '<div class="card__head"><span class="podium__rank" aria-label="' + esc(ZH ? "第 " + entry.rank + " 名" : "Rank " + entry.rank) + '">' + entry.rank + "</span>" + U.change(entry) + "</div>" +
      runner(entry, "av--lg") +
      '<p class="podium__value" data-count="' + (Number(entry.value) || 0) + '" data-format="' + valueFormat() + '" data-key="pv-' + esc(entry.username) + '">' + esc(valueText(entry)) + "</p>" +
      '<p class="card__sub">' + (state.metric === "cost" ? esc(Q.compact(entry.tokens)) + " token" : esc(U.money(entry.costUSD))) + " · " + esc(U.days(entry.activeDays)) + "</p>" +
      U.split(entry.tools) +
      '<div class="card__foot"><span>' + (entry.topProject ? t("Mostly on ", "主要在做 ") + projectLink(entry) : t("No public project", "没有公开项目")) + "</span>" + verifiedShare(entry) + "</div>" +
      "</article>";
  }

  function rowHTML(entry) {
    return '<tr class="rank-row" data-key="' + esc(entry.username) + '">' +
      '<td class="num mono rank-cell">' + entry.rank + "</td>" +
      "<td>" + U.change(entry) + "</td>" +
      '<th scope="row">' + runner(entry, "av--sm") + "</th>" +
      '<td class="num mono strong" data-count="' + (Number(entry.value) || 0) + '" data-format="' + valueFormat() + '" data-key="rv-' + esc(entry.username) + '">' + esc(valueText(entry)) + "</td>" +
      (state.metric !== "cost" ? '<td class="num mono">' + esc(U.money(entry.costUSD)) + "</td>" : "") +
      (state.metric !== "tokens" ? '<td class="num mono">' + esc(Q.compact(entry.tokens)) + "</td>" : "") +
      '<td class="num mono">' + Q.number(entry.activeDays) + "</td>" +
      '<td class="tools-cell">' + U.split(entry.tools, "96px") + "</td>" +
      "<td>" + projectLink(entry) + "</td>" +
      '<td class="num">' + verifiedShare(entry) + "</td>" +
      "</tr>";
  }

  function tableHTML(entries) {
    if (!entries.length) return "";
    return '<div class="tablewrap"><table class="ranks">' +
      '<caption class="sr-only">' + esc(ZH ? "用量榜，第 4 名之后" : "Usage board from fourth place") + "</caption>" +
      "<thead><tr>" +
        '<th scope="col" class="num">#</th><th scope="col"><span class="sr-only">' + t("Change", "变化") + "</span></th>" +
        '<th scope="col">' + t("Runner", "用户") + "</th>" +
        '<th scope="col" class="num">' + esc(metricLabel()) + "</th>" +
        (state.metric !== "cost" ? '<th scope="col" class="num">' + t("Cost", "花费") + "</th>" : "") +
        (state.metric !== "tokens" ? '<th scope="col" class="num">Token</th>' : "") +
        '<th scope="col" class="num">' + t("Days", "天数") + "</th>" +
        '<th scope="col">' + t("Tools", "工具") + "</th>" +
        '<th scope="col">' + t("Top project", "主要项目") + "</th>" +
        '<th scope="col" class="num">' + t("Verified", "已核实") + "</th>" +
      '</tr></thead><tbody id="rankRows">' + entries.map(rowHTML).join("") + "</tbody></table></div>";
  }

  function feedHTML() {
    if (!feed.length) return '<ul class="feed"><li class="feed__empty">' + t("Waiting for the next upload…", "等下一次上传…") + "</li></ul>";
    return '<ul class="feed" aria-live="polite">' + feed.map(function (item, i) {
      return '<li class="' + (i === 0 && item.fresh ? "is-new" : "") + '">' + item.icon + '<span class="feed__text">' + item.html + '</span><span class="feed__time">' + Q.timeTag(item.at) + "</span></li>";
    }).join("") + "</ul>";
  }

  // 筛选条下面一行：最新的一条动态滑进来
  function tickerHTML() {
    var item = feed[0];
    if (!item) return '<span class="ticker__idle">' + t("Live: new uploads show up here the moment they arrive.", "实时：有新的上传，这里马上就会出现。") + "</span>";
    return '<span class="ticker__item' + (item.fresh ? " is-new" : "") + '">' + item.icon + '<span class="feed__text">' + item.html + '</span><span class="feed__time">' + Q.timeTag(item.at) + "</span></span>";
  }

  function emptyHTML() {
    return Q.stateBox("empty",
      state.verified ? t("No verified usage here yet", "这里还没有核实过的用量") : t("No usage here yet", "这里还没有用量"),
      t("Sign in to Quota Run from QuotaBar on your Mac. Usage goes up by project from every signed-in Mac; a day counts as verified when that day's quota readings rose.",
        "在 Mac 上的 QuotaBar 里登录 Quota Run，每台登录的 Mac 都会按项目上传用量；那天的额度读数确实涨了，那天的用量就算已核实。"),
      '<a class="btn btn--primary" href="https://quota.bar' + (ZH ? "/zh/" : "/") + '">' + t("Get QuotaBar", "下载 QuotaBar") + "</a>" +
      (state.verified ? '<button type="button" class="btn" data-unverified>' + t("Show all usage", "看全部用量") + "</button>" : ""));
  }

  function render(data) {
    var entries = data.entries || [];
    var summary = data.summary || {};
    var podium = entries.slice(0, 3), rest = entries.slice(3);
    body.innerHTML =
      '<div class="ticker" id="ticker" aria-hidden="true">' + tickerHTML() + "</div>" +
      tilesHTML(summary) +
      '<div class="ui-grid ui-grid--chart ui-sec">' +
        '<section class="card" aria-labelledby="dailyTitle"><div class="card__head"><div><h2 class="card__title" id="dailyTitle">' + t("Cost per day", "每天的花费") + '</h2><p class="card__sub">' + esc(ZH ? "按工具分段，" + periodText() : "By tool, " + periodText()) + "</p></div>" + U.toolLegend() + '</div><div id="dailyChart"></div></section>' +
        '<section class="card" aria-labelledby="toolsTitle"><div class="card__head"><h2 class="card__title" id="toolsTitle">' + t("Where it went", "花在了哪个工具") + '</h2></div><div id="toolsDonut"></div></section>' +
      "</div>" +
      (entries.length
        ? '<section class="ui-sec" aria-labelledby="podiumTitle"><div class="ui-sec__head"><h2 id="podiumTitle">' + esc(ZH ? periodText() + "前三" : "Top three " + periodText()) + '</h2><p class="hint">' + esc(ZH ? "按" + metricLabel() + "排名" : "Ranked by " + metricLabel().toLowerCase()) + (state.verified ? t(", verified usage only", "，只算已核实的用量") : "") + '</p></div><div class="podium" id="podium">' + podium.map(podiumCard).join("") + "</div></section>" +
          '<section class="ui-sec" aria-labelledby="restTitle"><div class="ui-sec__head"><h2 id="restTitle">' + t("Everyone else", "其余名次") + '</h2><p class="hint">' + esc(ZH ? "共 " + Q.number(summary.runners) + " 人" : Q.number(summary.runners) + " on the board") + "</p></div>" +
            (rest.length ? tableHTML(rest) : '<p class="muted">' + t("Only three so far.", "目前只有这三位。") + "</p>") + "</section>" +
          '<section class="ui-sec" aria-labelledby="feedTitle"><div class="ui-sec__head"><h2 id="feedTitle">' + t("Happening now", "正在发生") + '</h2><p class="hint">' + t("Uploads and quota readings as they arrive", "上传和额度读数，到一条显示一条") + '</p></div><div id="feedBox">' + feedHTML() + "</div></section>"
        : '<div class="ui-sec">' + emptyHTML() + "</div>");
    var stacks = U.dailyStacks(summary.daily, (summary.daily[0] || {}).date || data.from, (summary.daily[summary.daily.length - 1] || {}).date || data.to);
    U.columns($("dailyChart"), { dates: stacks.dates, stacks: stacks.stacks, height: 200, label: t("Cost per day by tool", "每天按工具的花费") });
    U.donut($("toolsDonut"), {
      items: (summary.byTool || []).map(function (item) { return { id: item.tool, label: U.toolName(item.tool), color: U.toolColor(item.tool), value: item.costUSD }; })
        .sort(function (a, b) { return U.TOOLS.map(function (x) { return x.id; }).indexOf(a.id) - U.TOOLS.map(function (x) { return x.id; }).indexOf(b.id); }),
      caption: periodText(), label: t("Cost by tool", "按工具的花费"), stack: true,
    });
    U.countUp(body, true);
  }

  // 同一组筛选下的实时刷新：数字滚动、行平移、变了的行闪一下；图表不带入场动画重画
  function update(data, previous) {
    var entries = data.entries || [];
    var before = {};
    (previous.entries || []).forEach(function (e) { before[e.username] = e; });
    var structure = entries.slice(0, 3).map(function (e) { return e.username; }).join(",") !== (previous.entries || []).slice(0, 3).map(function (e) { return e.username; }).join(",")
      || !$("podium") !== !entries.length;
    if (!$("podium") || !entries.length) { render(data); return; }
    var ticker = $("ticker");
    if (ticker) ticker.innerHTML = tickerHTML();
    var tiles = body.querySelector(".tiles");
    tiles.outerHTML = tilesHTML(data.summary);
    var podium = $("podium");
    U.flip(podium, function () { podium.innerHTML = entries.slice(0, 3).map(podiumCard).join(""); });
    var rows = $("rankRows");
    if (rows) U.flip(rows, function () { rows.innerHTML = entries.slice(3).map(rowHTML).join(""); });
    else if (entries.length > 3) { render(data); return; }
    Q.each(main.querySelectorAll("[data-key]"), function (node) {
      var key = node.getAttribute("data-key");
      var old = before[key];
      var now = entries.filter(function (e) { return e.username === key; })[0];
      if (old && now && (old.value !== now.value || old.rank !== now.rank)) node.classList.add(node.tagName === "TR" ? "is-flash" : "is-flash");
    });
    U.countUp(body);
    var stacks = U.dailyStacks(data.summary.daily, (data.summary.daily[0] || {}).date, (data.summary.daily[data.summary.daily.length - 1] || {}).date);
    U.columns($("dailyChart"), { dates: stacks.dates, stacks: stacks.stacks, height: 200, animate: false, label: t("Cost per day by tool", "每天按工具的花费") });
    U.donut($("toolsDonut"), {
      items: (data.summary.byTool || []).map(function (item) { return { id: item.tool, label: U.toolName(item.tool), color: U.toolColor(item.tool), value: item.costUSD }; }),
      caption: periodText(), label: t("Cost by tool", "按工具的花费"), stack: true,
    });
    return structure;
  }

  function currentShape() {
    return [state.period, state.metric, state.tool, state.region, state.verified].join("|");
  }

  function load(live) {
    var q = "?" + Q.query({ period: state.period, metric: state.metric, tool: state.tool, region: state.region, verified: state.verified ? "1" : "0", limit: 100 });
    var wanted = currentShape();
    Q.setBusy(main, true);
    var request = loading = Q.getJSON("/usage/boards" + q, live).then(function (data) {
      if (request !== loading || wanted !== currentShape()) return;
      var previous = board;
      board = data;
      if (live && previous && shape === wanted) update(data, previous);
      else render(data);
      shape = wanted;
      Q.setBusy(main, false);
    }).catch(function () {
      if (request !== loading) return;
      body.innerHTML = Q.errorBox(t("Couldn't load the usage board.", "用量榜没加载出来。"));
      Q.setBusy(main, false);
    });
  }

  /* ── 实时 ─────────────────────────────────────────────────────────── */

  var refresh = U.debounce(function () { load(true); }, 700);

  function pushFeed(item) {
    feed.forEach(function (old) { old.fresh = false; });
    item.fresh = true;
    feed.unshift(item);
    feed = feed.slice(0, 8);
    var box = $("feedBox");
    if (box) box.innerHTML = feedHTML();
    var ticker = $("ticker");
    if (ticker) ticker.innerHTML = tickerHTML();
  }

  function who(data) {
    return '<a class="link-quiet" href="' + esc(Q.profileHref(data.username)) + '"><b>' + esc(data.displayName || data.username) + "</b></a>";
  }

  U.connect(function (name, data) {
    if (!data) return;
    if (name === "usage") {
      var delta = data.deltaUSD ? ' <span class="chg chg--up">+' + esc(U.money(data.deltaUSD)) + "</span>" : "";
      var tools = Object.keys(data.byTool || {}).sort(function (a, b) { return data.byTool[b] - data.byTool[a]; });
      pushFeed({ at: Q.toDate(data.at) || new Date(), icon: '<i class="dot dot--' + esc(tools[0] || "claude") + '" aria-hidden="true"></i>',
        html: who(data) + (ZH ? " 今天花到 " : " is at ") + "<b>" + esc(U.money(data.costUSD)) + "</b>" + (ZH ? "" : " today") + delta });
      refresh();
    } else if (name === "board") {
      refresh();
    } else if (name === "reading") {
      pushFeed({ at: Q.toDate(data.at) || new Date(), icon: Q.logo(data.provider, 16),
        html: who(data) + (ZH ? " 的 " : "'s ") + esc(Q.providerName(data.provider) + (data.planLabel ? " " + data.planLabel : "")) + " " +
          esc(Q.windowLabel(data.windowSeconds, data.windowKey)) + (ZH ? " 用到 " : " at ") + "<b>" + esc(Q.percent(data.usedPercent)) + "</b>" });
    }
  });

  // 动态里的「几秒前」隔一会儿自己更新
  setInterval(function () {
    var box = $("feedBox");
    if (box && feed.length) { feed.forEach(function (item) { item.fresh = false; }); box.innerHTML = feedHTML(); }
  }, 30000);

  main.addEventListener("click", function (event) {
    if (event.target.closest("[data-retry]")) load(false);
    if (event.target.closest("[data-unverified]")) { state.verified = false; onFilter(); }
  });

  $("usageLive").innerHTML = U.pill();
  syncControls();
  if (Q.LOCAL || Q.DEMO) Q.setLangLinks(location.search);
  load(false);
})();

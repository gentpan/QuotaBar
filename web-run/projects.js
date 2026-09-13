/* Quota Run 的项目榜（projects.html，线上是 /projects）。
 *
 * 读 /usage/projects：数字卡片（公开项目数、总花费、总 token），每个项目一张卡片——名次、名称和作者、仓库（本人仓库的打勾）、
 * 花费、token 和会话、工具占比条、近 14 天走势、和上一段比的涨跌。点卡片进项目页。
 * 订阅 /live：有人上传用量就重读，卡片按新名次平移，数字滚动。筛选：?period=week|last|month|all&tool=。
 */
(function () {
  "use strict";

  var Q = window.QuotaRun, U = window.QuotaUI;
  if (!Q || !U || Q.PAGE !== "projects") return;
  var t = Q.t, esc = Q.esc, ZH = Q.ZH, $ = Q.$;
  var params = new URLSearchParams(location.search);
  var main = $("main"), body = $("projectsBody");
  var state = {
    period: ["week", "last", "month", "all"].indexOf(params.get("period")) >= 0 ? params.get("period") : "week",
    tool: ["claude", "codex", "opencode"].indexOf(params.get("tool")) >= 0 ? params.get("tool") : "",
  };
  var shape = "", data = null, loading = null;

  function periodText() {
    return { week: t("this week", "本周"), last: t("last week", "上周"), month: t("this month", "本月"), all: t("the last 365 days", "近一年") }[state.period];
  }

  function sync() {
    Q.each($("periodSeg").querySelectorAll("button"), function (b) { b.setAttribute("aria-pressed", String(b.getAttribute("data-value") === state.period)); });
    $("toolSelect").value = state.tool;
    var q = Q.query(Q.demoPairs({ period: state.period === "week" ? "" : state.period, tool: state.tool }));
    try { history.replaceState(null, "", location.pathname + (q ? "?" + q : "")); } catch (e) { /* file:// */ }
    Q.setLangLinks(q ? "?" + q : "");
  }

  $("periodSeg").addEventListener("click", function (event) {
    var button = event.target.closest("button[data-value]");
    if (!button) return;
    state.period = button.getAttribute("data-value");
    sync();
    load(false);
  });
  $("toolSelect").addEventListener("change", function (event) { state.tool = event.target.value; sync(); load(false); });

  function growth(entry) {
    if (entry.growth == null) return state.period === "all" ? "" : '<span class="chg chg--new">' + t("New", "新") + "</span>";
    var pct = Math.round(entry.growth * 100);
    var dir = pct > 0 ? "is-up" : pct < 0 ? "is-down" : "";
    return '<span class="growth ' + dir + '" title="' + esc(t("Against the period before", "和上一段相比")) + '">' + (pct > 0 ? "+" : pct < 0 ? "−" : "") + Math.abs(pct) + "%</span>";
  }

  function repoLine(project) {
    if (!project.repo) return "";
    return '<a class="pcard__repo" href="https://' + esc(project.repo) + '" rel="nofollow ugc noopener">' + Q.ICONS.github + esc(project.repo.replace(/^github\.com\//, "")) + "</a>" +
      (project.repoVerified ? " " + U.verifiedMark(t("Owner's repository", "作者本人的仓库")) : "");
  }

  function card(entry) {
    var href = Q.projectHref(entry.owner.username, entry.project.slug);
    return '<article class="card" data-key="' + esc(entry.owner.username + "/" + entry.project.slug) + '">' +
      '<div class="card__head"><div class="pcard__name"><a href="' + esc(href) + '"><h3 class="card__title">' + esc(entry.project.name) + "</h3></a>" +
        '<span class="card__sub">' + t("by ", "作者 ") + '<a class="link-quiet" href="' + esc(Q.profileHref(entry.owner.username)) + '">@' + esc(entry.owner.username) + "</a></span></div>" +
        '<span class="pcard__rank" aria-label="' + esc(ZH ? "第 " + entry.rank + " 名" : "Rank " + entry.rank) + '">#' + entry.rank + "</span></div>" +
      (entry.project.repo ? "<div>" + repoLine(entry.project) + "</div>" : "") +
      '<div class="pcard__value"><div><p class="pcard__big" data-count="' + entry.costUSD + '" data-format="money" data-key="pc-' + esc(entry.project.id) + '">' + esc(U.money(entry.costUSD)) + "</p>" +
        '<p class="card__sub">' + esc(Q.compact(entry.tokens)) + " token · " + esc(ZH ? entry.sessions + " 个会话" : entry.sessions + " sessions") + " · " + esc(U.days(entry.activeDays)) + "</p></div>" +
        U.spark(entry.spark, { width: 96, height: 32 }) + "</div>" +
      U.split(entry.tools) +
      '<div class="card__foot"><span>' + (entry.tools || []).map(function (tool) { return '<i class="dot dot--' + esc(tool.tool) + '" aria-hidden="true"></i> ' + esc(U.toolName(tool.tool)); }).join("  ") + "</span>" + growth(entry) + "</div>" +
      "</article>";
  }

  function render(board) {
    var entries = board.entries || [];
    body.innerHTML = U.tiles([
      { label: t("Public projects", "公开项目"), value: board.summary.projects, format: "number", key: "pt-projects" },
      { label: ZH ? periodText() + "总花费" : "Cost " + periodText(), value: board.summary.costUSD, format: "money", key: "pt-cost" },
      { label: ZH ? periodText() + "总 token" : "Tokens " + periodText(), value: board.summary.tokens, format: "compact", key: "pt-tokens" },
    ]) +
    '<div class="ui-sec">' + (entries.length
      ? '<div class="pcards" id="projectCards">' + entries.map(card).join("") + "</div>"
      : Q.stateBox("empty", t("No public projects here yet", "这里还没有公开的项目"),
        t("In QuotaBar, open Settings → Projects, pick a project and turn on Public on quota.run. It shows up here after the next upload.",
          "在 QuotaBar 里打开「设置 → 项目」，选一个项目，打开「公开到 quota.run」，下一次上传后就会出现在这里。"), "")) + "</div>";
    U.countUp(body, !data);
  }

  function update(board) {
    var cards = $("projectCards");
    if (!cards || !(board.entries || []).length) { render(board); return; }
    var tiles = body.querySelector(".tiles");
    tiles.outerHTML = U.tiles([
      { label: t("Public projects", "公开项目"), value: board.summary.projects, format: "number", key: "pt-projects" },
      { label: ZH ? periodText() + "总花费" : "Cost " + periodText(), value: board.summary.costUSD, format: "money", key: "pt-cost" },
      { label: ZH ? periodText() + "总 token" : "Tokens " + periodText(), value: board.summary.tokens, format: "compact", key: "pt-tokens" },
    ]);
    var before = {};
    (data.entries || []).forEach(function (e) { before[e.project.id] = e.costUSD; });
    U.flip(cards, function () { cards.innerHTML = board.entries.map(card).join(""); });
    board.entries.forEach(function (e) {
      if (before[e.project.id] != null && before[e.project.id] !== e.costUSD) {
        var node = cards.querySelector('[data-key="' + CSS.escape(e.owner.username + "/" + e.project.slug) + '"]');
        if (node) node.classList.add("is-flash");
      }
    });
    U.countUp(body);
  }

  function load(live) {
    var wanted = state.period + "|" + state.tool;
    Q.setBusy(main, true);
    var request = loading = Q.getJSON("/usage/projects?" + Q.query({ period: state.period, tool: state.tool, limit: 60 }), live).then(function (board) {
      if (request !== loading) return;
      if (live && data && shape === wanted) update(board);
      else render(board);
      data = board;
      shape = wanted;
      Q.setBusy(main, false);
    }).catch(function () {
      if (request !== loading) return;
      body.innerHTML = Q.errorBox(t("Couldn't load the project board.", "项目榜没加载出来。"));
      Q.setBusy(main, false);
    });
  }

  var refresh = U.debounce(function () { load(true); }, 900);
  U.connect(function (name) { if (name === "usage") refresh(); });
  main.addEventListener("click", function (event) { if (event.target.closest("[data-retry]")) load(false); });

  $("projectsLive").innerHTML = U.pill();
  sync();
  load(false);
})();

/* Quota Run 的组件页（kit.html，线上是 /kit）：徽章、数字卡片、卡片、图表、标签和实时组件，全用本页编的示例数据。
 * 不读接口；「实时」一节自己每隔几秒编一条动态、打乱一次名次，演示数字滚动和换位动画。
 */
(function () {
  "use strict";

  var Q = window.QuotaRun, U = window.QuotaUI;
  if (!Q || !U || Q.PAGE !== "kit") return;
  var t = Q.t, esc = Q.esc, ZH = Q.ZH, $ = Q.$;
  var body = $("kitBody");

  // 固定的伪随机，每次打开都一样
  var seed = 7;
  function rand() { seed = (seed * 16807) % 2147483647; return (seed - 1) / 2147483646; }

  function iso(daysAgo) { return new Date(Date.now() - daysAgo * 86400000).toISOString().slice(0, 10); }

  var DAYS = [];
  for (var i = 59; i >= 0; i--) {
    var weekend = new Date(Date.now() - i * 86400000).getUTCDay() % 6 === 0;
    var base = rand() < (weekend ? 0.45 : 0.9) ? 60 + rand() * 260 : 0;
    DAYS.push({ date: iso(i), byTool: base ? { claude: Math.round(base * 0.6), codex: Math.round(base * 0.34), opencode: rand() < 0.2 ? Math.round(base * 0.06) : 0 } : {} });
  }

  function badge(id, tier, tiers, value, next) {
    var def = { streak: [7, 30, 100], spend: [100, 1000, 10000], bigday: [1e8, 5e8, 1e9], tools: [2, 3], ways: [3, 5], verified: [7, 30, 100], projects: [1, 3, 10],
      opensource: [1], nightowl: [25], weekend: [30], podium: [10, 3, 1], speedrun: [1, 10, 50], github: [500, 2000, 5000] }[id];
    return { id: id, tier: tier, tiers: tiers || def.length, thresholds: def, value: value, next: next === undefined ? (tier < def.length ? def[tier] : null) : next };
  }

  var BADGE_SET = [
    badge("streak", 2, 3, 41), badge("spend", 3, 3, 18420), badge("bigday", 1, 3, 213000000), badge("tools", 2, 2, 3), badge("ways", 1, 2, 4),
    badge("verified", 2, 3, 64), badge("projects", 1, 3, 2), badge("opensource", 1, 1, 1), badge("nightowl", 1, 1, 31), badge("weekend", 0, 1, 12),
    badge("podium", 2, 3, 3), badge("speedrun", 0, 3, 0), badge("github", 3, 3, 5295),
  ];

  var RUNNERS = [
    { username: "hweiss", displayName: "Hannah Weiss", region: "global", value: 3581, tools: [{ tool: "claude", costUSD: 2300 }, { tool: "codex", costUSD: 1281 }] },
    { username: "linxiao", displayName: "林晓", region: "china", value: 3169, tools: [{ tool: "claude", costUSD: 1400 }, { tool: "codex", costUSD: 1769 }] },
    { username: "peter", displayName: "Peter", region: "global", value: 2912, tools: [{ tool: "claude", costUSD: 2400 }, { tool: "opencode", costUSD: 512 }] },
    { username: "devon", displayName: "Devon Park", region: "global", value: 2490, tools: [{ tool: "codex", costUSD: 2490 }] },
    { username: "mika", displayName: "Mika Laine", region: "global", value: 2104, tools: [{ tool: "claude", costUSD: 1804 }, { tool: "codex", costUSD: 300 }] },
  ];

  function section(id, title, note, content) {
    return '<section class="ui-sec kit-block" aria-labelledby="' + id + '"><div class="ui-sec__head"><h2 id="' + id + '">' + title + '</h2><p class="hint">' + note + "</p></div>" + content + "</section>";
  }

  function rankRow(r, i) {
    return '<li class="rank-row" data-key="' + r.username + '"><span class="mono dim">' + (i + 1) + "</span>" +
      '<span class="runner">' + Q.avatar(r, "av--sm") + '<span class="runner__text"><b>' + esc(r.displayName) + "</b><small>@" + esc(r.username) + "</small></span></span>" +
      '<span class="mono strong" data-count="' + r.value + '" data-format="money" data-key="kit-' + r.username + '">' + esc(U.money(r.value)) + "</span></li>";
  }

  body.innerHTML =
    section("kitBadges", t("Badges", "徽章"), t("Earned in tiers; dashed ones are still to win. Hover for what's next.", "分档获得；虚线的是还没拿到的。把鼠标放上去看下一档要求。"),
      '<div class="badges">' + BADGE_SET.map(U.badgeChip).join("") + "</div>" +
      '<div class="medals">' + U.sortBadges(BADGE_SET).map(U.medal).join("") + "</div>") +

    section("kitTiles", t("Figures", "数字卡片"), t("Numbers roll to their new value when they change.", "数字变化时滚动到新值。"),
      U.tiles([
        { label: t("Cost this week", "本周花费"), value: 81920, format: "money", delta: { text: t("+18% on last week", "比上周 +18%"), dir: 1 }, spark: DAYS.slice(-14).map(function (d) { return (d.byTool.claude || 0) + (d.byTool.codex || 0); }) },
        { label: "Token", value: 56530000000, format: "compact", delta: { text: t("−4% on last week", "比上周 −4%"), dir: -1 } },
        { label: t("Longest streak", "最长连续"), value: 41, format: "days" },
        { label: t("On the board", "上榜人数"), value: 142, format: "number", delta: { text: t("+12 this week", "本周 +12"), dir: 1 } },
      ]) + '<div class="kit-row"><button type="button" class="btn" id="replayTiles">' + t("Roll the numbers again", "再滚一次") + "</button></div>") +

    section("kitCards", t("Cards", "卡片"), t("Bordered, never shadowed; the first place gets the green edge.", "描边不加阴影；第一名是绿色描边。"),
      '<div class="podium">' + RUNNERS.slice(0, 3).map(function (r, i) {
        return '<article class="card podium__card podium--' + (i + 1) + '"><div class="card__head"><span class="podium__rank">' + (i + 1) + "</span>" + U.change({ change: [2, -1, null][i], new: i === 2 }) + "</div>" +
          '<span class="runner">' + Q.avatar(r, "av--lg") + '<span class="runner__text"><b>' + esc(r.displayName) + "</b><small>@" + esc(r.username) + "</small></span></span>" +
          '<p class="podium__value">' + esc(U.money(r.value)) + '</p><p class="card__sub">' + esc(Q.compact(r.value * 690000)) + " token · " + esc(U.days(5 - i)) + "</p>" + U.split(r.tools) +
          '<div class="card__foot"><span>' + t("Mostly on ", "主要在做 ") + '<span class="link-quiet">Tidewire</span></span>' + U.verifiedMark(t("All verified", "全部核实")) + "</div></article>";
      }).join("") + "</div>" +
      '<div class="pcards">' + ["QuotaBar", "Tidewire", "rust-raft"].map(function (name, i) {
        var spark = DAYS.slice(-14).map(function (d) { return (d.byTool.claude || 0) * (1 - i * 0.2); });
        return '<article class="card"><div class="card__head"><div class="pcard__name"><h3 class="card__title">' + esc(name) + '</h3><span class="card__sub">' + t("by ", "作者 ") + "@peter</span></div><span class=\"pcard__rank\">#" + (i + 1) + "</span></div>" +
          '<div><span class="pcard__repo">' + Q.ICONS.github + "gentpan/" + esc(name) + "</span> " + (i === 0 ? U.verifiedMark(t("Owner's repository", "作者本人的仓库")) : "") + "</div>" +
          '<div class="pcard__value"><div><p class="pcard__big">' + esc(U.money(4210 - i * 1100)) + '</p><p class="card__sub">' + esc(Q.compact(3.1e9 - i * 7e8)) + " token · " + (ZH ? (40 - i * 9) + " 个会话" : (40 - i * 9) + " sessions") + "</p></div>" + U.spark(spark, { width: 96, height: 32 }) + "</div>" +
          U.split([{ tool: "claude", costUSD: 3 - i }, { tool: "codex", costUSD: 1 + i }]) +
          '<div class="card__foot"><span><i class="dot dot--claude"></i> Claude Code  <i class="dot dot--codex"></i> Codex</span><span class="growth ' + (i === 1 ? "is-down" : "is-up") + '">' + (i === 1 ? "−12%" : "+" + (35 - i * 10) + "%") + "</span></div></article>";
      }).join("") + "</div>") +

    section("kitCharts", t("Charts", "图表"), t("Hover a column, move along the line, point at a slice.", "悬停柱子、沿着折线移动、指向环形的一段。"),
      '<div class="ui-grid ui-grid--chart"><div class="card"><div class="card__head"><div><h3 class="card__title">' + t("Stacked columns", "叠放柱状图") + '</h3><p class="card__sub">' + t("Cost per day by tool, 60 days", "近 60 天每天按工具的花费") + "</p></div>" + U.toolLegend() + '</div><div id="kitColumns"></div></div>' +
        '<div class="card"><div class="card__head"><h3 class="card__title">' + t("Ring", "环形占比") + '</h3></div><div id="kitDonut"></div></div></div>' +
      '<div class="ui-grid ui-grid--2"><div class="card"><div class="card__head"><div><h3 class="card__title">' + t("Line with crosshair", "折线与十字线") + '</h3><p class="card__sub">' + t("Community cost per day", "社区每天的总花费") + '</p></div></div><div id="kitLine"></div></div>' +
        '<div class="card"><div class="card__head"><h3 class="card__title">' + t("Heatmap", "热力图") + '</h3></div><div id="kitHeat"></div></div></div>') +

    section("kitMarks", t("Marks", "标记"), t("Small pieces that carry state next to names and numbers.", "跟在名字和数字旁边、说明状态的小部件。"),
      '<div class="kit-row">' + U.change({ change: 4 }) + U.change({ change: -2 }) + U.change({ change: 0 }) + U.change({ new: true }) +
        U.verifiedMark() + '<span class="tag tag--ok">' + t("Verified", "已验证") + '</span><span class="tag">' + t("Standard", "标准") + "</span>" +
        U.pill("live") + U.pill("retry") + U.pill("connecting") + "</div>" +
      '<div class="kit-row">' + U.toolLegend() + U.split([{ tool: "claude", costUSD: 6 }, { tool: "codex", costUSD: 3 }, { tool: "opencode", costUSD: 1 }], "160px") + U.spark([3, 5, 4, 8, 7, 11, 9, 14], { width: 120, height: 28 }) + "</div>") +

    section("kitLive", t("Live", "实时"), t("A made-up feed: every few seconds someone's day grows and the ranking reshuffles.", "编出来的动态：每隔几秒有人的用量涨了，名次重新排。"),
      '<div class="ticker" id="kitTicker"></div>' +
      '<div class="ui-grid ui-grid--2"><div class="card"><div class="card__head"><h3 class="card__title">' + t("Ranking", "名次") + "</h3>" + U.pill("live") + '</div><ol class="contributors" id="kitRanks">' + RUNNERS.map(rankRow).join("") + "</ol></div>" +
        '<div class="card"><div class="card__head"><h3 class="card__title">' + t("Feed", "动态") + '</h3></div><ul class="feed" id="kitFeed"><li class="feed__empty">' + t("Waiting…", "等待中…") + "</li></ul></div></div>");

  $("kitLive").innerHTML = U.pill("live");

  // 图表
  var stacks = U.dailyStacks(DAYS, DAYS[0].date, DAYS[DAYS.length - 1].date);
  U.columns($("kitColumns"), { dates: stacks.dates, stacks: stacks.stacks, height: 220, label: t("Cost per day by tool", "每天按工具的花费") });
  var totals = { claude: 0, codex: 0, opencode: 0 };
  DAYS.forEach(function (d) { Object.keys(d.byTool).forEach(function (k) { totals[k] += d.byTool[k]; }); });
  U.donut($("kitDonut"), { items: U.TOOLS.map(function (tool) { return { id: tool.id, label: tool.name, color: tool.color, value: totals[tool.id] }; }), caption: t("60 days", "近 60 天"), stack: true });
  var community = [];
  var level = 40000;
  for (var k = 0; k < 90; k++) { level = Math.max(8000, level + (rand() - 0.42) * 6000); community.push(Math.round(level)); }
  U.line($("kitLine"), { dates: community.map(function (_, i) { return iso(89 - i); }), values: community, height: 200 });
  var heat = {};
  for (var h = 0; h < 371; h++) if (rand() < 0.7) heat[iso(h)] = Math.round(rand() * rand() * 400);
  $("kitHeat").innerHTML = Q.heatmap({ to: iso(0), values: heat, tip: function (date, value) { return "<b>" + esc(U.money(value)) + "</b> · " + esc(Q.calendarDate(date)); }, label: "" });
  Q.heatmapReady($("kitHeat"));
  U.countUp(body, true);

  $("replayTiles").addEventListener("click", function () {
    Q.each(body.querySelectorAll("#kitTiles ~ * [data-count], .tiles [data-count]"), function (el) { el.removeAttribute("data-key"); });
    var tiles = body.querySelector(".tiles");
    var clone = tiles.cloneNode(true);
    tiles.replaceWith(clone);
    U.countUp(clone, true);
  });

  // 实时演示
  var feed = [];
  function tick() {
    var r = RUNNERS[Math.floor(rand() * RUNNERS.length)];
    var add = Math.round(20 + rand() * 480);
    r.value += add;
    feed.unshift({ r: r, add: add, at: new Date() });
    feed = feed.slice(0, 6);
    var html = function (item, fresh) {
      return '<li class="' + (fresh ? "is-new" : "") + '"><i class="dot dot--' + esc(item.r.tools[0].tool) + '" aria-hidden="true"></i><span class="feed__text"><b>' + esc(item.r.displayName) + "</b>" +
        (ZH ? " 今天花到 " : " is at ") + "<b>" + esc(U.money(item.r.value)) + '</b> <span class="chg chg--up">+' + esc(U.money(item.add)) + '</span></span><span class="feed__time">' + Q.timeTag(item.at) + "</span></li>";
    };
    $("kitFeed").innerHTML = feed.map(function (item, i) { return html(item, i === 0); }).join("");
    $("kitTicker").innerHTML = '<span class="ticker__item is-new">' + html(feed[0], false).replace(/^<li class="[^"]*">|<\/li>$/g, "") + "</span>";
    var ranks = $("kitRanks");
    RUNNERS.sort(function (a, b) { return b.value - a.value; });
    U.flip(ranks, function () { ranks.innerHTML = RUNNERS.map(rankRow).join(""); });
    var row = ranks.querySelector('[data-key="' + r.username + '"]');
    if (row) row.classList.add("is-flash");
    U.countUp(ranks);
  }
  setInterval(tick, 3200);
  setTimeout(tick, 800);
})();

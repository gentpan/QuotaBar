/* Quota Run 的组件层：徽章、数字卡片、图表、提示浮层、名次换位动画、实时连接。
 *
 * 在 common.js 之后加载，挂在 window.QuotaUI 上，给用量榜、项目榜、项目页、个人主页和组件页用。
 * 图表是手写的 SVG：柱子最宽 24px、数据端 4px 圆角、叠放的段之间留 2px 白缝；折线 2px、下面 10% 的底色；
 * 悬停有十字线或整列高亮和提示；工具色按 Claude Code、Codex、OpenCode 的固定顺序，跟着工具走，不跟名次走。
 * 没有依赖，没有构建步骤。
 */
(function () {
  "use strict";

  var Q = window.QuotaRun;
  if (!Q) return;
  var t = Q.t, esc = Q.esc, ZH = Q.ZH;
  var REDUCED = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var SVGNS = "http://www.w3.org/2000/svg";

  /* ── 工具、编程方式、金额 ─────────────────────────────────────────── */

  var TOOLS = [
    { id: "claude", name: "Claude Code", color: "#d97757" },
    { id: "codex", name: "Codex", color: "#2563eb" },
    { id: "opencode", name: "OpenCode", color: "#0d9488" },
  ];
  var TOOL_BY_ID = {};
  TOOLS.forEach(function (tool) { TOOL_BY_ID[tool.id] = tool; });

  function toolName(id) { return TOOL_BY_ID[id] ? TOOL_BY_ID[id].name : String(id || ""); }
  function toolColor(id) { return TOOL_BY_ID[id] ? TOOL_BY_ID[id].color : "#9ca3af"; }

  var MODES = {
    cli: [t("Terminal", "命令行")], desktop: [t("Desktop app", "桌面版")], ide: [t("Editor", "编辑器插件")],
    sdk: ["SDK"], cloud: [t("Cloud", "云端")], other: [t("Other", "其他")],
  };
  function modeName(id) { return MODES[id] ? MODES[id][0] : String(id || ""); }

  var USD = new Intl.NumberFormat("en-US", { style: "currency", currency: "USD", maximumFractionDigits: 0 });
  var USD_CENTS = new Intl.NumberFormat("en-US", { style: "currency", currency: "USD", minimumFractionDigits: 2, maximumFractionDigits: 2 });
  var USD_COMPACT = new Intl.NumberFormat("en-US", { style: "currency", currency: "USD", notation: "compact", maximumFractionDigits: 1 });

  // $0.42、$86、$1,284、$12.4K、$3.1M
  function money(value) {
    var n = Number(value) || 0;
    if (n > 0 && n < 10) return USD_CENTS.format(n);
    if (n < 10000) return USD.format(n);
    return USD_COMPACT.format(n);
  }

  function days(n) { return ZH ? Q.number(n) + " 天" : Q.number(n) + (Number(n) === 1 ? " day" : " days"); }

  /* ── 图标（线性，16 格，和 common.js 的一套） ─────────────────────── */

  function icon(path) {
    return '<svg aria-hidden="true" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">' + path + "</svg>";
  }
  var ICONS = {
    streak: icon('<path d="M12 3c1 3 4 4.5 4 8.5A4 4 0 0 1 8 11.5c0-1.5.6-2.6 1.5-3.5.2 1.5 1 2.5 2 2.5C11 8 11 5.5 12 3z"/><path d="M12 21a6 6 0 0 0 6-6"/><path d="M6 15a6 6 0 0 0 6 6"/>'),
    spend: icon('<circle cx="12" cy="12" r="9"/><path d="M15 9.5c-.5-1-1.6-1.5-3-1.5-1.7 0-3 .9-3 2s1.3 1.7 3 2 3 .9 3 2-1.3 2-3 2c-1.4 0-2.5-.5-3-1.5M12 6.5v11"/>'),
    bigday: icon('<path d="M13 2 4 14h7l-1 8 9-12h-7z"/>'),
    tools: icon('<path d="m12 3 9 5-9 5-9-5z"/><path d="m3 13 9 5 9-5"/>'),
    ways: icon('<rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/>'),
    verified: icon('<path d="M12 3 5 6v5c0 4.5 3 8.5 7 10 4-1.5 7-5.5 7-10V6z"/><path d="m9 12 2 2 4-4"/>'),
    projects: icon('<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>'),
    opensource: icon('<circle cx="6" cy="5" r="2"/><circle cx="6" cy="19" r="2"/><circle cx="18" cy="8" r="2"/><path d="M6 7v10M18 10c0 4-6 3-12 7"/>'),
    nightowl: icon('<path d="M20 14.5A8 8 0 0 1 9.5 4 8 8 0 1 0 20 14.5z"/>'),
    weekend: icon('<rect x="3" y="5" width="18" height="16" rx="2"/><path d="M3 10h18M8 3v4M16 3v4M15 15h2"/>'),
    podium: icon('<path d="M8 21h8M12 17v4M7 4h10v5a5 5 0 0 1-10 0z"/><path d="M7 6H4a3 3 0 0 0 3 4M17 6h3a3 3 0 0 1-3 4"/>'),
    speedrun: icon('<circle cx="12" cy="13" r="8"/><path d="M12 9v4l2.5 2.5M10 2h4"/>'),
    github: icon('<path d="M9 19c-4.5 1.5-4.5-2.5-6-3m12 5v-3.5c0-1 .1-1.4-.5-2 2.8-.3 5.5-1.4 5.5-6a4.6 4.6 0 0 0-1.3-3.2 4.2 4.2 0 0 0-.1-3.2s-1.1-.3-3.5 1.3a12 12 0 0 0-6.2 0C6.5 2.8 5.4 3.1 5.4 3.1a4.2 4.2 0 0 0-.1 3.2A4.6 4.6 0 0 0 4 9.5c0 4.6 2.7 5.7 5.5 6-.6.6-.6 1.2-.5 2V21"/>'),
    check: icon('<path d="m5 12 5 5 9-10"/>'),
    up: '<svg aria-hidden="true" width="12" height="12" viewBox="0 0 12 12" fill="currentColor"><path d="M6 2.5 10 8H2z"/></svg>',
    down: '<svg aria-hidden="true" width="12" height="12" viewBox="0 0 12 12" fill="currentColor"><path d="M6 9.5 2 4h8z"/></svg>',
  };

  /* ── 徽章 ─────────────────────────────────────────────────────────── */

  // 名称和每一档的说明；门槛由接口给（badges[].thresholds），这里只负责把数字说成话
  var BADGES = {
    streak: { name: [t("Streak", "连续作战")], desc: function (n) { return ZH ? "连续 " + n + " 天有用量" : n + " days in a row"; } },
    spend: { name: [t("Big spender", "烧钱大户")], desc: function (n) { return ZH ? "累计等价花费 " + money(n) : money(n) + " spent in all"; } },
    bigday: { name: [t("Big day", "单日爆发")], desc: function (n) { return ZH ? "一天用掉 " + Q.compact(n) + " token" : Q.compact(n) + " tokens in a day"; } },
    tools: { name: [t("Polyglot", "多工具")], desc: function (n) { return ZH ? "用过 " + n + " 种 AI 编程工具" : n + " AI coding tools used"; } },
    ways: { name: [t("Every way", "多种姿势")], desc: function (n) { return ZH ? n + " 种编程方式（工具 × 入口）" : n + " ways of working (tool × app)"; } },
    verified: { name: [t("Verified", "用量核实")], desc: function (n) { return ZH ? n + " 天的用量有额度读数核实" : n + " days of usage verified by quota readings"; } },
    projects: { name: [t("Builder", "项目公开")], desc: function (n) { return ZH ? "公开 " + n + " 个项目" : n + " public projects"; } },
    opensource: { name: [t("Open source", "开源作者")], desc: function () { return t("A public project in your own GitHub repository", "公开了自己 GitHub 仓库里的项目"); } },
    nightowl: { name: [t("Night owl", "夜猫子")], desc: function (n) { return ZH ? "近 90 天 " + n + "% 的 token 在凌晨 0–5 点" : n + "% of 90 days' tokens between midnight and 5am"; } },
    weekend: { name: [t("Weekend warrior", "周末也在写")], desc: function (n) { return ZH ? "近 90 天 " + n + "% 的花费在周末" : n + "% of 90 days' cost on weekends"; } },
    podium: { name: [t("Podium", "上榜")], desc: function (n) { return ZH ? "周用量榜前 " + n + " 名" : "Top " + n + " on a weekly usage board"; }, lower: true },
    speedrun: { name: [t("Speedrunner", "额度速通")], desc: function (n) { return ZH ? n + " 轮额度用满" : n + " windows used up"; } },
    github: { name: [t("Committer", "GitHub 活跃")], desc: function (n) { return ZH ? "近一年 GitHub 贡献 " + Q.number(n) + " 次" : Q.number(n) + " GitHub contributions in a year"; } },
  };

  function badgeName(b) { return BADGES[b.id] ? BADGES[b.id].name[0] : b.id; }

  // 已拿到的：说当前这一档；没拿到的：说第一档要什么
  function badgeDesc(b) {
    var def = BADGES[b.id];
    if (!def) return "";
    var limit = b.tier > 0 ? b.thresholds[b.tier - 1] : b.thresholds[0];
    return def.desc(limit);
  }

  function badgeTip(b) {
    var def = BADGES[b.id];
    var parts = [badgeDesc(b)];
    if (b.value != null && def && b.id !== "opensource") {
      parts.push(ZH ? "现在：" + (b.id === "spend" ? money(b.value) : b.id === "bigday" ? Q.compact(b.value) : b.id === "podium" ? "第 " + b.value + " 名" : Q.number(b.value)) :
        "Now: " + (b.id === "spend" ? money(b.value) : b.id === "bigday" ? Q.compact(b.value) : b.id === "podium" ? "#" + b.value : Q.number(b.value)));
    }
    if (b.next != null && def) parts.push(ZH ? "下一档：" + def.desc(b.next) : "Next: " + def.desc(b.next));
    return parts.join(ZH ? "；" : ". ");
  }

  function badgeChip(b) {
    var locked = !b.tier;
    var cls = "badge" + (locked ? " badge--locked" : b.tier >= 3 || b.tier === b.tiers ? " badge--t3" : b.tier === 2 ? " badge--t2" : "");
    var tier = b.tiers > 1 && b.tier ? '<span class="badge__tier">' + ["", "I", "II", "III"][b.tier] + "</span>" : "";
    return '<span class="' + cls + '" title="' + esc(badgeTip(b)) + '"><span class="badge__icon">' + (ICONS[b.id] || ICONS.check) + "</span>" + esc(badgeName(b)) + tier + "</span>";
  }

  function progress(b) {
    if (b.next == null || b.value == null) return b.tier ? 1 : 0;
    if (BADGES[b.id] && BADGES[b.id].lower) return b.value ? Math.min(1, b.next / b.value) : 0;
    return Math.max(0, Math.min(1, b.value / b.next));
  }

  function medal(b) {
    var locked = !b.tier;
    var cls = "medal" + (locked ? " medal--locked" : b.tier === b.tiers ? " medal--t3" : b.tier === 2 ? " medal--t2" : "");
    var pips = "";
    for (var i = 0; i < b.tiers; i++) pips += '<i class="' + (i < b.tier ? "on" : "") + '"></i>';
    return '<div class="' + cls + '" title="' + esc(badgeTip(b)) + '">' +
      '<span class="medal__icon">' + (ICONS[b.id] || ICONS.check) + "</span>" +
      '<span class="medal__name">' + esc(badgeName(b)) + "</span>" +
      '<span class="medal__desc">' + esc(badgeDesc(b)) + "</span>" +
      (b.tiers > 1 ? '<span class="medal__pips" aria-label="' + esc(ZH ? "第 " + b.tier + " 档，共 " + b.tiers + " 档" : "Tier " + b.tier + " of " + b.tiers) + '">' + pips + "</span>" : "") +
      (b.next != null ? '<span class="medal__progress" aria-hidden="true"><i style="width:' + Math.round(progress(b) * 100) + '%"></i></span>' : "") +
      "</div>";
  }

  // 拿到的在前，档位高的在前
  function sortBadges(list) {
    return (list || []).slice().sort(function (a, b) { return (b.tier / (b.tiers || 1)) - (a.tier / (a.tiers || 1)); });
  }

  /* ── 数字卡片与数字滚动 ───────────────────────────────────────────── */

  var FORMATS = { money: money, compact: Q.compact, number: Q.number, days: days };

  // items: {label, value, format: "money"|"compact"|"number"|"days", delta: {text, dir}, spark: [..]}
  function tiles(items) {
    return '<dl class="tiles" style="--tiles:' + items.length + '">' + items.map(function (item) {
      var fmt = FORMATS[item.format] || Q.number;
      return '<div class="tile"><dt class="tile__label">' + esc(item.label) + "</dt>" +
        '<dd class="tile__value" data-count="' + (Number(item.value) || 0) + '" data-format="' + (item.format || "number") + '"' + (item.key ? ' data-key="' + esc(item.key) + '"' : "") + ">" + esc(fmt(item.value)) + "</dd>" +
        (item.delta ? '<dd class="tile__delta ' + (item.delta.dir > 0 ? "is-up" : item.delta.dir < 0 ? "is-down" : "") + '">' + esc(item.delta.text) + "</dd>" : "") +
        (item.spark ? '<dd class="tile__spark">' + spark(item.spark, { width: 120, height: 24 }) + "</dd>" : "") +
        "</div>";
    }).join("") + "</dl>";
  }

  // [data-count] 的数字从上一次显示的值滚到新值；第一次从 0 滚起
  var shown = new WeakMap();
  function countUp(root, fromZero) {
    Q.each((root || document).querySelectorAll("[data-count]"), function (el) {
      var to = Number(el.getAttribute("data-count")) || 0;
      var fmt = FORMATS[el.getAttribute("data-format")] || Q.number;
      var from = shown.has(el) ? shown.get(el) : (fromZero ? 0 : to);
      var key = el.getAttribute("data-key");
      if (key && countUp.memory[key] != null) from = countUp.memory[key];
      if (key) countUp.memory[key] = to;
      shown.set(el, to);
      if (REDUCED || from === to) { el.textContent = fmt(to); return; }
      var start = performance.now(), duration = 700;
      function frame(now) {
        var p = Math.min(1, (now - start) / duration);
        var eased = 1 - Math.pow(1 - p, 3);
        var value = from + (to - from) * eased;
        el.textContent = fmt(Number.isInteger(to) && Number.isInteger(from) && fmt !== money ? Math.round(value) : value);
        if (p < 1) requestAnimationFrame(frame);
      }
      requestAnimationFrame(frame);
    });
  }
  countUp.memory = {};

  /* ── 提示浮层 ─────────────────────────────────────────────────────── */

  var tipEl = null;
  function showTip(html, x, y) {
    if (!tipEl) {
      tipEl = document.createElement("div");
      tipEl.className = "tip";
      tipEl.setAttribute("role", "tooltip");
      document.body.appendChild(tipEl);
    }
    tipEl.innerHTML = html;
    tipEl.hidden = false;
    var w = tipEl.offsetWidth, h = tipEl.offsetHeight;
    var left = Math.max(8, Math.min(window.innerWidth - w - 8, x + 12));
    var top = y - h - 12 < 8 ? y + 16 : y - h - 12;
    tipEl.style.transform = "translate(" + Math.round(left) + "px," + Math.round(top) + "px)";
  }
  function hideTip() { if (tipEl) tipEl.hidden = true; }
  window.addEventListener("scroll", hideTip, { passive: true });

  function tipRows(rows) {
    return "<ul>" + rows.map(function (row) {
      return '<li><i class="dot" style="background:' + row.color + '"></i><span>' + esc(row.label) + "</span><span>" + esc(row.value) + "</span></li>";
    }).join("") + "</ul>";
  }

  /* ── 刻度 ─────────────────────────────────────────────────────────── */

  function niceMax(value) {
    if (!(value > 0)) return 1;
    var exp = Math.pow(10, Math.floor(Math.log10(value)));
    var f = value / exp;
    var nice = f <= 1 ? 1 : f <= 2 ? 2 : f <= 2.5 ? 2.5 : f <= 5 ? 5 : 10;
    return nice * exp;
  }

  function el(tag, attrs) {
    var node = document.createElementNS(SVGNS, tag);
    Object.keys(attrs || {}).forEach(function (k) { node.setAttribute(k, attrs[k]); });
    return node;
  }

  // 容器变宽变窄时重画；每个容器只挂一个观察者
  var observers = new WeakMap();
  function whenResized(box, draw) {
    if (!window.ResizeObserver) return;
    var old = observers.get(box);
    if (old) old.disconnect();
    var last = box.clientWidth, timer = null;
    var ro = new ResizeObserver(function () {
      if (Math.abs(box.clientWidth - last) < 4) return;
      last = box.clientWidth;
      clearTimeout(timer);
      timer = setTimeout(function () { draw(false); }, 120);
    });
    ro.observe(box);
    observers.set(box, ro);
  }

  function shortDate(date) { return Q.calendarDate(date, true); }

  /* ── 叠放柱状图：每天一根，按工具分段 ─────────────────────────────── */

  // options: {dates: ["2026-09-01", ...], stacks: [{id, label, color, values: []}], format, height, label}
  function columns(box, options) {
    function draw(animate) {
      var width = Math.max(240, box.clientWidth || 600);
      var height = options.height || 200;
      var m = { top: 8, right: 4, bottom: 24, left: 48 };
      var dates = options.dates || [];
      var stacks = (options.stacks || []).filter(function (s) { return s.values.some(function (v) { return v > 0; }); });
      var fmt = options.format || money;
      var totals = dates.map(function (_, i) { return stacks.reduce(function (sum, s) { return sum + (Number(s.values[i]) || 0); }, 0); });
      var max = niceMax(Math.max.apply(null, totals.concat(0)));
      box.innerHTML = "";
      box.classList.add("chart");
      if (!dates.length || !stacks.length) {
        box.innerHTML = '<div class="chart__empty">' + t("Nothing in this range yet", "这段时间还没有数据") + "</div>";
        return;
      }
      var svg = el("svg", { viewBox: "0 0 " + width + " " + height, height: height, role: "img", "aria-label": options.label || "" });
      var plotW = width - m.left - m.right, plotH = height - m.top - m.bottom;
      [0, 0.5, 1].forEach(function (f) {
        var y = m.top + plotH - plotH * f;
        svg.appendChild(el("line", { x1: m.left, x2: width - m.right, y1: y, y2: y, class: f === 0 ? "chart__axis" : "chart__grid" }));
        var label = el("text", { x: m.left - 8, y: y + 4, "text-anchor": "end", class: "chart__tick" });
        label.textContent = fmt(max * f);
        svg.appendChild(label);
      });
      var slot = plotW / dates.length;
      var bar = Math.max(1, Math.min(24, slot * 0.72));
      var gap = dates.length > 60 ? 1 : 2;
      [0, Math.floor((dates.length - 1) / 2), dates.length - 1].forEach(function (i, n, list) {
        if (n > 0 && i === list[n - 1]) return;
        var label = el("text", { x: m.left + slot * i + slot / 2, y: height - 6, "text-anchor": n === 0 ? "start" : n === 2 ? "end" : "middle", class: "chart__tick" });
        label.textContent = shortDate(dates[i]);
        svg.appendChild(label);
      });
      var groups = [];
      dates.forEach(function (date, i) {
        var g = el("g", { class: "chart__col" });
        var x = m.left + slot * i + (slot - bar) / 2;
        var y = m.top + plotH;
        var drawn = stacks.filter(function (s) { return s.values[i] > 0; });
        drawn.forEach(function (s, k) {
          var h = plotH * s.values[i] / max;
          var top = k === drawn.length - 1;
          var segH = Math.max(top ? 1 : 0, h - (top ? 0 : gap));
          var r = top ? Math.min(4, bar / 2, segH) : 0;
          var yTop = y - h;
          var d = "M" + x + "," + y + "V" + (yTop + r) + (r ? "Q" + x + "," + yTop + " " + (x + r) + "," + yTop + "H" + (x + bar - r) + "Q" + (x + bar) + "," + yTop + " " + (x + bar) + "," + (yTop + r) : "H" + (x + bar)) + "V" + y + "Z";
          if (!top) d = "M" + x + "," + y + "V" + (y - segH) + "H" + (x + bar) + "V" + y + "Z";
          var path = el("path", { d: d, fill: s.color });
          if (animate && !REDUCED) { path.setAttribute("class", "grow"); path.style.animationDelay = Math.min(400, i * 8) + "ms"; }
          g.appendChild(path);
          y -= h;
        });
        g.appendChild(el("rect", { x: m.left + slot * i, y: m.top, width: slot, height: plotH, class: "chart__hit" }));
        g.addEventListener("mousemove", function (event) {
          box.classList.add("is-hovering");
          groups.forEach(function (other) { other.classList.toggle("is-on", other === g); });
          var rows = stacks.filter(function (s) { return s.values[i] > 0; }).reverse().map(function (s) { return { color: s.color, label: s.label, value: fmt(s.values[i]) }; });
          showTip("<b>" + esc(fmt(totals[i])) + "</b> · " + esc(Q.calendarDate(date)) + (rows.length > 1 ? tipRows(rows) : rows.length ? " · " + esc(rows[0].label) : ""), event.clientX, event.clientY);
        });
        groups.push(g);
        svg.appendChild(g);
      });
      svg.addEventListener("mouseleave", function () {
        box.classList.remove("is-hovering");
        groups.forEach(function (g) { g.classList.remove("is-on"); });
        hideTip();
      });
      box.appendChild(svg);
    }
    draw(options.animate !== false);
    whenResized(box, draw);
  }

  /* ── 折线：一条线加 10% 底色，十字线跟着鼠标 ─────────────────────── */

  // options: {dates, values, format, height, color, label}
  function line(box, options) {
    function draw(animate) {
      var width = Math.max(240, box.clientWidth || 600);
      var height = options.height || 180;
      var m = { top: 12, right: 12, bottom: 24, left: 48 };
      var dates = options.dates || [], values = options.values || [];
      var fmt = options.format || money;
      var color = options.color || "#16a34a";
      box.innerHTML = "";
      box.classList.add("chart");
      if (values.length < 2) {
        box.innerHTML = '<div class="chart__empty">' + t("Nothing in this range yet", "这段时间还没有数据") + "</div>";
        return;
      }
      var max = niceMax(Math.max.apply(null, values.concat(0)));
      var plotW = width - m.left - m.right, plotH = height - m.top - m.bottom;
      var svg = el("svg", { viewBox: "0 0 " + width + " " + height, height: height, role: "img", "aria-label": options.label || "" });
      [0, 0.5, 1].forEach(function (f) {
        var y = m.top + plotH - plotH * f;
        svg.appendChild(el("line", { x1: m.left, x2: width - m.right, y1: y, y2: y, class: f === 0 ? "chart__axis" : "chart__grid" }));
        var label = el("text", { x: m.left - 8, y: y + 4, "text-anchor": "end", class: "chart__tick" });
        label.textContent = fmt(max * f);
        svg.appendChild(label);
      });
      function px(i) { return m.left + plotW * i / (values.length - 1); }
      function py(v) { return m.top + plotH - plotH * (Number(v) || 0) / max; }
      var d = values.map(function (v, i) { return (i ? "L" : "M") + px(i).toFixed(1) + "," + py(v).toFixed(1); }).join("");
      svg.appendChild(el("path", { d: d + "L" + px(values.length - 1) + "," + (m.top + plotH) + "L" + m.left + "," + (m.top + plotH) + "Z", fill: color, class: "chart__wash" }));
      var path = el("path", { d: d, stroke: color, class: "chart__line" + (animate && !REDUCED ? " draw" : "") });
      svg.appendChild(path);
      [0, values.length - 1].forEach(function (i, n) {
        var label = el("text", { x: px(i), y: height - 6, "text-anchor": n ? "end" : "start", class: "chart__tick" });
        label.textContent = shortDate(dates[i]);
        svg.appendChild(label);
      });
      var last = values.length - 1;
      svg.appendChild(el("circle", { cx: px(last), cy: py(values[last]), r: 4, fill: color, class: "chart__dot" }));
      var cross = el("line", { y1: m.top, y2: m.top + plotH, class: "chart__cross", visibility: "hidden" });
      var dot = el("circle", { r: 4, fill: color, class: "chart__dot", visibility: "hidden" });
      svg.appendChild(cross);
      svg.appendChild(dot);
      var hit = el("rect", { x: m.left, y: 0, width: plotW, height: height, class: "chart__hit" });
      hit.addEventListener("mousemove", function (event) {
        var rect = svg.getBoundingClientRect();
        var scale = width / rect.width;
        var i = Math.max(0, Math.min(last, Math.round(((event.clientX - rect.left) * scale - m.left) / plotW * last)));
        cross.setAttribute("x1", px(i));
        cross.setAttribute("x2", px(i));
        dot.setAttribute("cx", px(i));
        dot.setAttribute("cy", py(values[i]));
        cross.setAttribute("visibility", "visible");
        dot.setAttribute("visibility", "visible");
        showTip("<b>" + esc(fmt(values[i])) + "</b> · " + esc(Q.calendarDate(dates[i])), event.clientX, event.clientY);
      });
      hit.addEventListener("mouseleave", function () {
        cross.setAttribute("visibility", "hidden");
        dot.setAttribute("visibility", "hidden");
        hideTip();
      });
      svg.appendChild(hit);
      box.appendChild(svg);
      if (animate && !REDUCED) path.style.setProperty("--len", Math.ceil(path.getTotalLength()));
    }
    draw(options.animate !== false);
    whenResized(box, draw);
  }

  /* ── 环形：占比，段之间留白缝，图例和环互相高亮 ───────────────────── */

  // options: {items: [{id, label, color, value}], format, center, caption, label}
  function donut(box, options) {
    var items = (options.items || []).filter(function (item) { return item.value > 0; });
    var total = items.reduce(function (sum, item) { return sum + item.value; }, 0);
    var fmt = options.format || money;
    box.classList.add("donut");
    if (options.stack) box.classList.add("donut--stack");
    if (!total) {
      box.innerHTML = '<div class="chart__empty">' + t("Nothing yet", "还没有数据") + "</div>";
      return;
    }
    var r = 52, c = 2 * Math.PI * r, offset = 0;
    var segs = items.map(function (item, i) {
      var len = c * item.value / total;
      var gap = items.length > 1 ? Math.min(3, len / 3) : 0;
      var seg = '<circle class="donut__seg" data-i="' + i + '" cx="70" cy="70" r="' + r + '" fill="none" stroke="' + item.color + '" stroke-width="16" stroke-dasharray="' + Math.max(0.01, len - gap).toFixed(2) + " " + (c - len + gap).toFixed(2) + '" stroke-dashoffset="' + (-offset).toFixed(2) + '" transform="rotate(-90 70 70)"></circle>';
      offset += len;
      return seg;
    }).join("");
    box.innerHTML =
      '<svg viewBox="0 0 140 140" role="img" aria-label="' + esc(options.label || "") + '">' +
        '<circle cx="70" cy="70" r="' + r + '" fill="none" stroke="#f3f4f6" stroke-width="16"></circle>' + segs +
        '<text class="donut__center" x="70" y="70" text-anchor="middle">' + esc(options.center != null ? options.center : fmt(total)) + "</text>" +
        '<text class="donut__caption" x="70" y="88" text-anchor="middle">' + esc(options.caption || "") + "</text>" +
      "</svg>" +
      '<ul class="donut__list">' + items.map(function (item, i) {
        return '<li data-i="' + i + '"><i class="dot" style="background:' + item.color + '"></i><b>' + esc(item.label) + "</b><span>" + Math.round(item.value / total * 100) + "% · " + esc(fmt(item.value)) + "</span></li>";
      }).join("") + "</ul>";
    function highlight(i) {
      box.classList.toggle("is-hovering", i != null);
      Q.each(box.querySelectorAll("[data-i]"), function (node) { node.classList.toggle("is-on", node.getAttribute("data-i") === String(i)); });
    }
    Q.each(box.querySelectorAll("[data-i]"), function (node) {
      node.addEventListener("mouseenter", function () { highlight(node.getAttribute("data-i")); });
      node.addEventListener("mouseleave", function () { highlight(null); });
    });
  }

  /* ── 迷你走势 ─────────────────────────────────────────────────────── */

  function spark(values, options) {
    options = options || {};
    var w = options.width || 96, h = options.height || 24;
    var list = (values || []).map(function (v) { return Number(v) || 0; });
    if (list.length < 2) return "";
    var max = Math.max.apply(null, list.concat(0)) || 1;
    var pts = list.map(function (v, i) { return [(w * i / (list.length - 1)).toFixed(1), (h - 2 - (h - 4) * v / max).toFixed(1)]; });
    var d = pts.map(function (p, i) { return (i ? "L" : "M") + p[0] + "," + p[1]; }).join("");
    var lastPoint = pts[pts.length - 1];
    return '<svg class="spark" width="' + w + '" height="' + h + '" viewBox="0 0 ' + w + " " + h + '" aria-hidden="true">' +
      '<path class="spark__wash" d="' + d + "L" + w + "," + h + "L0," + h + 'Z"></path><path d="' + d + '"></path>' +
      '<circle cx="' + lastPoint[0] + '" cy="' + lastPoint[1] + '" r="3"></circle></svg>';
  }

  /* ── 工具占比条、名次变化、已核实 ─────────────────────────────────── */

  // tools: [{tool, costUSD}]
  function split(tools, width) {
    var total = (tools || []).reduce(function (sum, item) { return sum + (Number(item.costUSD) || 0); }, 0);
    if (!total) return '<span class="split" aria-hidden="true"></span>';
    var ordered = TOOLS.map(function (tool) { return (tools || []).filter(function (item) { return item.tool === tool.id; })[0]; }).filter(Boolean);
    var label = ordered.map(function (item) { return toolName(item.tool) + " " + Math.round(item.costUSD / total * 100) + "%"; }).join(", ");
    return '<span class="split"' + (width ? ' style="width:' + width + '"' : "") + ' role="img" aria-label="' + esc(label) + '" title="' + esc(label) + '">' +
      ordered.map(function (item) { return '<i class="' + esc(item.tool) + '" style="width:' + (item.costUSD / total * 100).toFixed(1) + '%"></i>'; }).join("") + "</span>";
  }

  function change(entry) {
    if (entry.new) return '<span class="chg chg--new">' + t("New", "新上榜") + "</span>";
    if (entry.change == null) return '<span class="chg chg--same" aria-hidden="true">·</span>';
    if (entry.change > 0) return '<span class="chg chg--up" title="' + esc(ZH ? "比上一段前进 " + entry.change + " 名" : "Up " + entry.change) + '">' + ICONS.up + entry.change + "</span>";
    if (entry.change < 0) return '<span class="chg chg--down" title="' + esc(ZH ? "比上一段后退 " + -entry.change + " 名" : "Down " + -entry.change) + '">' + ICONS.down + -entry.change + "</span>";
    return '<span class="chg chg--same" title="' + esc(t("Same place", "名次没变")) + '">=</span>';
  }

  function verifiedMark(text) {
    return '<span class="verified-mark">' + ICONS.verified + esc(text || t("Verified", "已核实")) + "</span>";
  }

  function toolLegend(ids) {
    return '<ul class="legend-row">' + TOOLS.filter(function (tool) { return !ids || ids.indexOf(tool.id) >= 0; }).map(function (tool) {
      return '<li><i class="dot" style="background:' + tool.color + '"></i>' + esc(tool.name) + "</li>";
    }).join("") + "</ul>";
  }

  // 接口的 days: [{date, byTool: {claude: 1.2}}] → 柱状图的 dates 和 stacks，缺的日子补 0
  function dailyStacks(dayList, from, to, key) {
    key = key || "byTool";
    var byDate = {};
    (dayList || []).forEach(function (day) { byDate[day.date] = day; });
    var dates = [];
    var start = new Date(from + "T00:00:00Z").getTime(), end = new Date(to + "T00:00:00Z").getTime();
    for (var ms = start; ms <= end; ms += 86400000) dates.push(new Date(ms).toISOString().slice(0, 10));
    var stacks = TOOLS.map(function (tool) {
      return { id: tool.id, label: tool.name, color: tool.color, values: dates.map(function (d) { return byDate[d] && byDate[d][key] ? Number(byDate[d][key][tool.id]) || 0 : 0; }) };
    });
    return { dates: dates, stacks: stacks };
  }

  /* ── 名次换位动画（FLIP） ─────────────────────────────────────────── */

  // 先记下每行的位置，mutate() 重画之后，把新行从旧位置平移过去
  function flip(container, mutate) {
    var before = {};
    Q.each(container.querySelectorAll("[data-key]"), function (node) { before[node.getAttribute("data-key")] = node.getBoundingClientRect().top; });
    mutate();
    if (REDUCED) return;
    Q.each(container.querySelectorAll("[data-key]"), function (node) {
      var key = node.getAttribute("data-key");
      if (before[key] == null) return;
      var dy = before[key] - node.getBoundingClientRect().top;
      if (Math.abs(dy) < 1) return;
      node.style.transform = "translateY(" + dy + "px)";
      node.style.transition = "none";
      requestAnimationFrame(function () {
        requestAnimationFrame(function () {
          node.style.transition = "transform 600ms cubic-bezier(0.2, 0.8, 0.2, 1)";
          node.style.transform = "";
        });
      });
    });
  }

  /* ── 实时连接 ─────────────────────────────────────────────────────── */

  var liveState = "connecting";
  var LIVE_TEXT = { live: t("Live", "实时"), retry: t("Reconnecting", "重连中"), connecting: t("Connecting", "连接中"), off: t("Paused", "已暂停") };

  // 页面后画出来的状态标记也跟着当前的连接状态
  function pill(state) {
    var shownState = state || liveState;
    return '<span class="live-pill" ' + (state ? "" : "data-live-pill ") + 'data-state="' + shownState + '" role="status"><i aria-hidden="true"></i><span>' + LIVE_TEXT[shownState] + "</span></span>";
  }

  function setPill(state) {
    liveState = state;
    var text = LIVE_TEXT[state];
    Q.each(document.querySelectorAll("[data-live-pill]"), function (node) {
      node.setAttribute("data-state", state);
      node.lastChild.textContent = text;
    });
  }

  // onEvent(name, data)：usage、board、reading。示例模式下由 demo.js 定时编造事件
  function connect(onEvent) {
    if (Q.DEMO) {
      return new Promise(function (resolve) {
        Q.getJSON("/stats").catch(function () {}).then(function () {
          setPill("live");
          resolve(window.QuotaRunDemo && window.QuotaRunDemo.live ? window.QuotaRunDemo.live(onEvent) : null);
        });
      });
    }
    if (!window.EventSource) { setPill("off"); return Promise.resolve(null); }
    var source = new EventSource(Q.API + "/live");
    source.addEventListener("hello", function () { setPill("live"); });
    source.addEventListener("open", function () { setPill("live"); });
    source.addEventListener("error", function () { setPill(source.readyState === 2 ? "off" : "retry"); });
    ["usage", "board", "reading"].forEach(function (name) {
      source.addEventListener(name, function (event) {
        var data = null;
        try { data = JSON.parse(event.data); } catch (e) { return; }
        onEvent(name, data);
      });
    });
    return Promise.resolve(source);
  }

  // 同一类事件接连到来时只刷新一次
  function debounce(fn, wait) {
    var timer = null;
    return function () {
      clearTimeout(timer);
      timer = setTimeout(fn, wait);
    };
  }

  window.QuotaUI = {
    TOOLS: TOOLS, ICONS: ICONS, BADGES: BADGES, toolName: toolName, toolColor: toolColor, modeName: modeName, money: money, days: days,
    badgeChip: badgeChip, medal: medal, badgeName: badgeName, badgeDesc: badgeDesc, sortBadges: sortBadges,
    tiles: tiles, countUp: countUp, showTip: showTip, hideTip: hideTip, tipRows: tipRows,
    columns: columns, line: line, donut: donut, spark: spark, split: split, change: change, verifiedMark: verifiedMark,
    toolLegend: toolLegend, dailyStacks: dailyStacks, flip: flip, pill: pill, setPill: setPill, connect: connect, debounce: debounce,
    REDUCED: REDUCED,
  };
})();

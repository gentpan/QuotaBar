/* 让重建出来的刘海岛面板、停靠条和桌面卡片动起来，停靠条悬停出卡片。
 *
 * 颜色用的是应用里同一条连续色标 —— 同样的 9 个 stop、同样的 sRGB 混合，
 * 所以页面上看到的绿/金/橙/红就是装上之后会看到的那几个。
 *
 * 读数写在 HTML 的 data-used 上，不是这里生成的：脚本没跑时页面依然是
 * 正确的最终状态，只是不会动。内容不该挂在脚本上。
 */
(function () {
  "use strict";

  // 现取，不缓存：用户中途打开「减弱动态效果」时才不会读到过期的判断。
  var motion = window.matchMedia("(prefers-reduced-motion: reduce)");
  function reduced() { return motion.matches; }

  /* ── 用量色标（与 Sources/QuotaCore/UsageRamp.swift 同一份数据）──── */
  var STOPS = ["34C759", "4FC447", "82B91F", "A8A81E", "BF961C",
               "D0801B", "DE6418", "E83A1A", "DC2626"];
  //             50        55        60        65        70        75        80        85        90

  function channels(hex) {
    var v = parseInt(hex, 16);
    return [(v >> 16) & 255, (v >> 8) & 255, v & 255];
  }

  function rampHex(used) {
    var p = Math.min(Math.max(used, 0), 100);
    // 两个平台段也要带 #：少了它就是无效的 CSS 颜色声明，浏览器整条丢掉，
    // 而 ≤50% 和 ≥90% 恰恰是最常出现的两种状态。
    if (p <= 50) return "#" + STOPS[0];
    if (p >= 90) return "#" + STOPS[8];
    var x = (p - 50) / 5, i = Math.floor(x), t = x - i;
    var a = channels(STOPS[i]), b = channels(STOPS[i + 1]), out = "";
    for (var c = 0; c < 3; c++) {
      var n = Math.round(a[c] + (b[c] - a[c]) * t);
      out += (n < 16 ? "0" : "") + n.toString(16);
    }
    return "#" + out.toUpperCase();
  }

  /* ── 图片路径 ───────────────────────────────────────────────────── */
  // 指纹由 deploy_site.sh 统一改写（和 index.html、styles.css 里的字体一样）。
  // 写死 ?v=1 的话，指纹一升级，JS 渲染出的这些图不会跟着刷新。
  var LOGO = "assets/logos/";
  var LOGOV = "?v=2acc9baf";
  /* ── 停靠条悬停卡片的内容 ────────────────────────────────────────
   * 行标题取 scope ?? title，和 ProviderCallout.row 一致：有作用域就显示
   * 作用域名（Fable），否则显示窗口名（周窗口）。
   */
  var CALLOUT = {
    codex: { name: "Codex", logo: "codex.png", plan: "PRO", acct: "you@example.com", status: "轻微故障", warn: true, rows: [
      { title: "周窗口", used: 36, reset: "5 天 16 小时后重置" },
      { title: "GPT-5.3-Codex-Spark", used: 0, reset: "4 小时 59 分后重置" },
    ]},
    claude: { name: "Claude", logo: "claude.png", colour: true, plan: "MAX 20X", acct: "you@example.com", status: "服务正常", rows: [
      { title: "5 小时窗口", used: 18, reset: "2 小时 41 分后重置" },
      { title: "周窗口", used: 58, reset: "4 天 9 小时后重置" },
      { title: "Fable", used: 10, reset: "4 天 9 小时后重置" },
    ]},
    cursor: { name: "Cursor", logo: "cursor.png", plan: "PRO PLUS", acct: "you@example.com", status: "服务正常", rows: [
      { title: "月度套餐", used: 86, reset: "9 天 2 小时后重置", detail: "$17.20 / $20.00" },
      { title: "Grok Bot", used: 2, reset: "6 天 21 小时后重置" },
    ]},
    "opencode-go": { name: "OpenCode Go", logo: "opencode-go.png", plan: "GO", acct: "you@example.com", rows: [
      { title: "周窗口", used: 84, reset: "3 天 4 小时后重置" },
    ]},
  };

  function esc(v) { return String(v).replace(/[<>&]/g, ""); }

  /* ── 把读数画上去 ───────────────────────────────────────────────── */
  function paint(el, used) {
    var colour = rampHex(used);
    var fill = el.querySelector(".qb-steps__fill");
    if (fill) {
      fill.style.width = used + "%";
      // 岛面板图块的条是品牌色，不随读数变色；停靠条卡片里的走色标。
      if (!fill.classList.contains("is-brand")) {
        fill.style.background = "repeating-linear-gradient(90deg," + colour + " 0 5px,transparent 5px 7px)";
      }
    }
    // 岛面板图块的数字：白色，到了提醒档才变琥珀 / 红，和应用里一样
    var ipct = el.querySelector(".qb-ipct");
    if (ipct) {
      ipct.textContent = Math.round(used);
      ipct.style.color = used >= 85 ? "#E65F5F" : used >= 60 ? "#E8A85A" : "#fff";
    }
    var arc = el.querySelector(".qb-ring__arc");
    if (arc) {
      var len = arc.getTotalLength ? arc.getTotalLength() : 132;
      arc.style.strokeDasharray = len;
      arc.style.strokeDashoffset = len * (1 - used / 100);
      arc.style.stroke = colour;
    }
    var pct = el.querySelector(".qb-ring__pct");
    if (pct) pct.textContent = Math.round(used) + "%";
  }

  var readings = [];
  function collect() {
    readings = [];
    Array.prototype.forEach.call(document.querySelectorAll("[data-used]"), function (el) {
      var v = parseFloat(el.getAttribute("data-used"));
      readings.push({ el: el, used: v, base: v });
    });
  }

  function settle() {
    readings.forEach(function (r) { paint(r.el, r.used); });
    Array.prototype.forEach.call(document.querySelectorAll(".qb"), function (n) {
      n.classList.add("is-live");
    });
  }

  function animateIn() {
    if (reduced()) { settle(); return; }
    readings.forEach(function (r) { paint(r.el, 0); });
    void document.body.offsetHeight;
    settle();
  }

  collect();

  /* ── 首次进入视口时再跑，滚到才看得见 ───────────────────────────── */
  if (reduced()) {
    settle();
  } else if ("IntersectionObserver" in window && readings.length) {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (!e.isIntersecting) return;
        animateIn();
        io.disconnect();
      });
    }, { rootMargin: "0px 0px -10% 0px" });
    io.observe(document.querySelector(".qb-island") || readings[0].el);
    setTimeout(function () { if (readings.length) settle(); }, 2500);
  } else {
    setTimeout(animateIn, 120);
  }

  /* ── 轻微游走，像真的在刷新 ─────────────────────────────────────
   * 在各自基准值附近 ±3 个百分点晃，不是单调爬升 —— 页面开着不动的话，
   * 爬升会让每一条最后都顶到红色，反倒比静态更不像真的。
   */
  if (!reduced()) {
    setInterval(function () {
      if (document.hidden) return;
      readings.forEach(function (r) {
        var drift = (Math.random() - 0.45) * 1.6;
        r.used = Math.min(r.base + 3, Math.max(r.base - 3, r.used + drift));
        r.used = Math.min(100, Math.max(0, r.used));
        paint(r.el, r.used);
      });
    }, 3200);
  }

  /* ── 停靠条的悬停卡片 ───────────────────────────────────────────── */
  var dock = document.querySelector(".qb-dock");
  if (dock) {
    var callout = document.createElement("div");
    callout.className = "qb-callout";
    callout.setAttribute("aria-hidden", "true");
    dock.appendChild(callout);

    function calloutMarkup(id) {
      var d = CALLOUT[id];
      if (!d) return "";
      // 头部与应用的 ProviderCallout 一致：名字、套餐芯片，下一行账号与服务状态；
      // 进度条是阶梯式的（应用默认的 MeterStyle）。
      return '<div class="qb-callout__head">' +
          '<img class="' + (d.colour ? "is-colour" : "") + '" src="' + LOGO + d.logo + LOGOV + '" alt="">' +
          "<span>" + esc(d.name) + "</span>" +
          (d.plan ? '<em class="qb-chip">' + esc(d.plan) + "</em>" : "") +
        "</div>" +
        '<div class="qb-callout__sub">' +
          '<span class="qb-callout__acct">' + esc(d.acct || "") + "</span>" +
          (d.status ? '<span class="qb-status' + (d.warn ? " qb-status--warn" : "") + '"><i></i>' + esc(d.status) + "</span>" : "") +
        "</div>" +
        d.rows.map(function (r) {
          var c = rampHex(r.used);
          return '<div class="qb-crow" data-used="' + r.used + '">' +
            '<div class="qb-crow__top">' +
              '<span class="qb-crow__title">' + esc(r.title) + "</span>" +
              '<span class="qb-crow__reset">' + esc(r.reset) + "</span>" +
            "</div>" +
            '<span class="qb-steps qb-steps--sm"><span class="qb-steps__fill" style="width:' +
              Math.max(3, r.used) + "%;background:repeating-linear-gradient(90deg," + c + " 0 5px,transparent 5px 7px)" + '"></span></span>' +
            '<span class="qb-crow__used">' +
              (r.detail ? esc(r.detail) + " · " : "") + "已用 " + r.used + "%</span>" +
          "</div>";
        }).join("");
    }

    var rings = dock.querySelectorAll(".qb-ring[data-id]");
    function show(ring) {
      var id = ring.getAttribute("data-id");
      callout.innerHTML = calloutMarkup(id);
      // 垂直居中对齐这一格，和应用里把气泡对准圆环中心是同一件事
      var top = ring.offsetTop + ring.offsetHeight / 2;
      callout.style.top = top + "px";
      callout.style.transform = "translateY(-50%)";
      callout.classList.add("is-on");
      Array.prototype.forEach.call(rings, function (r) {
        r.classList.toggle("is-hot", r === ring);
      });
    }
    function hide() {
      callout.classList.remove("is-on");
      Array.prototype.forEach.call(rings, function (r) { r.classList.remove("is-hot"); });
    }

    Array.prototype.forEach.call(rings, function (ring) {
      ring.addEventListener("mouseenter", function () { show(ring); });
      ring.addEventListener("focus", function () { show(ring); });
      ring.setAttribute("tabindex", "0");
    });
    dock.addEventListener("mouseleave", hide);
    dock.addEventListener("focusout", function (e) {
      if (!dock.contains(e.relatedTarget)) hide();
    });
  }

})();

/* ── 桌面卡片：和应用一样的 7 种样式、3 种尺寸 ─────────────────────────
 * 版式、字号、颜色照 Sources/QuotaBar/DeskCardViews.swift：卡片底 #1C1D21、
 * 1px 白色 9% 描边、中卡 344×224 / 大卡 344×344 / 小卡 170×170，数字用等宽字，
 * 剩余多少按用量上色（≥70% 琥珀、≥90% 红）。右键卡片或点右上角的「⋯」
 * 换样式、尺寸和服务商，按住拖动位置；选择记在本地。
 */
(function () {
  "use strict";
  var host = document.querySelector(".desktop__widget");
  if (!host) return;

  var LOGO = "assets/logos/";
  var V = (document.querySelector('link[href^="styles.css"]') || { getAttribute: function () { return ""; } })
    .getAttribute("href").replace(/^[^?]*/, "");
  var GREEN = "#3DD68C", AMBER = "#F5A524";

  var P = {
    claude: { name: "Claude", logo: "claude.png", colour: true, plan: "MAX 20X", acct: "you@example.com",
      status: ["服务正常", GREEN], spend: "$38.20", tokens: "41.2M",
      windows: [{ t: "5 小时窗口", used: 18, reset: "2 小时 41 分", s: "2时41分" }, { t: "周窗口", used: 58, reset: "4 天 9 小时", s: "4天9时" },
                { t: "Fable", used: 10, reset: "4 天 9 小时", s: "4天9时" }] },
    codex: { name: "Codex", logo: "codex.png", plan: "PRO 20X", acct: "you@example.com",
      status: ["轻微故障", AMBER], spend: "$12.75", tokens: "18.6M",
      windows: [{ t: "周窗口", used: 36, reset: "5 天 16 小时", s: "5天16时" }, { t: "GPT-5.3-Codex-Spark", used: 0, reset: "4 小时 59 分", s: "4时59分" }] },
    cursor: { name: "Cursor", logo: "cursor.png", plan: "PRO PLUS", acct: "you@example.com",
      status: ["服务正常", GREEN],
      windows: [{ t: "月度套餐", used: 86, reset: "9 天 2 小时", s: "9天2时" }, { t: "Grok Bot", used: 2, reset: "6 天 21 小时", s: "6天21时" }] },
    grok: { name: "Grok", logo: "grok.png", acct: "you@example.com",
      windows: [{ t: "周窗口", used: 11, reset: "3 天 21 小时", s: "3天21时" }] },
  };
  var ORDER = ["codex", "claude", "cursor", "grok"];
  var SPEND14 = [22, 31, 18, 44, 39, 27, 52, 36, 61, 48, 33, 57, 42, 38.2];
  var TOKENS7 = [18.4, 9.1, 51.6, 22.3, 47.9, 58.8, 41.2];
  var DAYS = ["一", "二", "三", "四", "五", "六", "日"];
  var STYLES = [["focus", "大数字"], ["gauge", "环形仪表"], ["trend", "花费趋势"], ["daily", "每日对比"],
                ["grid", "服务商网格"], ["ranking", "紧迫排行"], ["classic", "经典"]];
  var SIZES = [["small", "小"], ["medium", "中"], ["large", "大"]];
  var SINGLE = { focus: true, gauge: true };
  var DEFAULT = { style: "focus", size: "medium", provider: "claude" };

  var state = load();
  function load() {
    try {
      var s = JSON.parse(localStorage.getItem("qb-deskcard") || "null");
      if (s && s.style && s.size && P[s.provider]) return s;
    } catch (e) { /* 用默认 */ }
    return { style: DEFAULT.style, size: DEFAULT.size, provider: DEFAULT.provider };
  }
  function save() { try { localStorage.setItem("qb-deskcard", JSON.stringify(state)); } catch (e) { /* 忽略 */ } }

  function esc(v) { return String(v).replace(/[<>&"]/g, ""); }
  function left(u) { return Math.round(100 - u); }
  function figure(u) { return u >= 90 ? "#E65F5F" : u >= 70 ? "#E8A85A" : "#fff"; }
  function ramp(u) {
    var stops = ["34C759", "4FC447", "82B91F", "A8A81E", "BF961C", "D0801B", "DE6418", "E83A1A", "DC2626"];
    var p = Math.min(Math.max(u, 0), 100);
    if (p <= 50) return "#" + stops[0];
    if (p >= 90) return "#" + stops[8];
    var x = (p - 50) / 5, i = Math.floor(x), t = x - i, out = "";
    for (var c = 0; c < 3; c++) {
      var a = parseInt(stops[i].substr(c * 2, 2), 16), b = parseInt(stops[i + 1].substr(c * 2, 2), 16);
      var n = Math.round(a + (b - a) * t);
      out += (n < 16 ? "0" : "") + n.toString(16);
    }
    return "#" + out;
  }
  function logo(id, size) {
    var d = P[id];
    return '<img class="dc-logo' + (d.colour ? " is-colour" : "") + '" src="' + LOGO + d.logo + V + '" alt="" width="' + size + '" height="' + size + '">';
  }

  var ICON = {
    person: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3"><circle cx="8" cy="8" r="6.4"/><circle cx="8" cy="6.6" r="2.2"/><path d="M4 12.4c1-1.6 2.4-2.3 4-2.3s3 .7 4 2.3"/></svg>',
    clock: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3"><circle cx="8" cy="8" r="6.2"/><path d="M8 4.6V8l2.2 1.4"/></svg>',
    flame: '<svg viewBox="0 0 16 16" fill="currentColor"><path d="M8.6 1.5c.3 2-1 3-2 4.2C5.6 6.9 4.5 8.1 4.5 10a3.5 3.5 0 0 0 7 0c0-1.4-.6-2.3-1.1-3 .1 1-.3 1.8-1 2.1.4-2.6-.6-5.4-1.8-7.6z"/></svg>',
    calendar: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3"><rect x="2.5" y="3.5" width="11" height="10" rx="2"/><path d="M2.5 6.8h11M5.5 2v3M10.5 2v3"/></svg>',
    cpu: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3"><rect x="4" y="4" width="8" height="8" rx="1.5"/><path d="M6.5 1.8V4M9.5 1.8V4M6.5 12v2.2M9.5 12v2.2M1.8 6.5H4M1.8 9.5H4M12 6.5h2.2M12 9.5h2.2"/></svg>',
    dollar: '<svg viewBox="0 0 16 16"><circle cx="8" cy="8" r="7" fill="#fff"/><path d="M9.8 5.6c-.4-.6-1.1-.9-1.9-.9-1.1 0-1.9.6-1.9 1.4 0 2 3.9 1 3.9 3.1 0 .9-.9 1.5-2 1.5-.9 0-1.7-.4-2.1-1M8 3.6v1.1M8 10.7v1.2" fill="none" stroke="#1C1D21" stroke-width="1.3" stroke-linecap="round"/></svg>',
    bars: '<svg viewBox="0 0 16 16" fill="#fff"><rect x="2" y="7" width="2.4" height="7" rx=".6"/><rect x="5.6" y="3" width="2.4" height="11" rx=".6"/><rect x="9.2" y="5" width="2.4" height="9" rx=".6"/><rect x="12.8" y="9" width="1.6" height="5" rx=".6"/><rect x="1" y="14.2" width="14" height="1" rx=".5"/></svg>',
    grid: '<svg viewBox="0 0 16 16" fill="#fff"><rect x="1.5" y="1.5" width="5.5" height="5.5" rx="1.4"/><rect x="9" y="1.5" width="5.5" height="5.5" rx="1.4"/><rect x="1.5" y="9" width="5.5" height="5.5" rx="1.4"/><rect x="9" y="9" width="5.5" height="5.5" rx="1.4"/></svg>',
  };

  function header(title, o) {
    o = o || {};
    var mark = o.id ? logo(o.id, o.compact ? 15 : 18) : '<span class="dc-sym">' + ICON[o.symbol] + "</span>";
    var plan = o.plan && !o.compact ? '<em class="dc-plan">' + esc(o.plan) + "</em>" : "";
    var pill = "";
    if (o.pill) {
      pill = o.compact
        ? '<i class="dc-dot" style="background:' + o.pill[1] + '" title="' + esc(o.pill[0]) + '"></i>'
        : '<span class="dc-pill" style="color:' + o.pill[1] + ';border-color:' + o.pill[1] + '99"><i style="background:' + o.pill[1] + '"></i>' + esc(o.pill[0]) + "</span>";
    }
    return '<div class="dc-head">' + mark + '<b class="dc-title">' + esc(title) + "</b>" + plan + '<span class="dc-sp"></span>' + pill + "</div>";
  }
  function stat(value, label, colour) {
    return '<div class="dc-stat"><b style="color:' + (colour || "#fff") + '">' + esc(value) + "</b><span>" + esc(label) + "</span></div>";
  }
  function stats(list, boxed) {
    return '<div class="dc-stats' + (boxed ? " is-boxed" : "") + '">' + list.join('<i class="dc-div"></i>') + "</div>";
  }
  function footer(icon, text) {
    return '<div class="dc-foot"><span class="dc-ic">' + ICON[icon] + "</span><span class=\"dc-foot__t\">" + esc(text) +
      '</span><span class="dc-sp"></span><span class="dc-ic dc-dim">' + ICON.clock + '</span><span class="dc-mono dc-dim">04:21</span></div>';
  }
  function steps(u, h) {
    return '<span class="dc-steps" style="height:' + h + 'px"><span style="width:' + Math.max(3, left(u)) +
      "%;background:repeating-linear-gradient(90deg," + ramp(u) + " 0 5px,transparent 5px 7px)\"></span></span>";
  }
  function bar(u, h) {
    return '<span class="dc-bar" style="height:' + h + 'px"><span style="width:' + Math.max(1.5, left(u)) + "%;background:" + ramp(u) + '"></span></span>';
  }
  function windowLines(d) {
    return '<div class="dc-lines">' + d.windows.slice(1, 4).map(function (w) {
      return '<div class="dc-line"><div class="dc-line__top"><span>' + esc(w.t) + '</span><span class="dc-sp"></span><span class="dc-mono dc-dim">' +
        esc(w.s) + '</span><b class="dc-mono" style="color:' + figure(w.used) + '">' + left(w.used) + "%</b></div>" + steps(w.used, 4) + "</div>";
    }).join("") + "</div>";
  }
  function line(values, w, h) {
    var top = Math.max.apply(null, values), step = w / (values.length - 1);
    var pts = values.map(function (v, i) { return [i * step, 3 + (h - 6) * (1 - v / top)]; });
    var d = pts.map(function (p, i) { return (i ? "L" : "M") + p[0].toFixed(1) + " " + p[1].toFixed(1); }).join(" ");
    var last = pts[pts.length - 1];
    return '<svg class="dc-line-chart" viewBox="-4 0 ' + (w + 8) + " " + h + '" width="' + (w + 8) + '" height="' + h + '" aria-hidden="true">' +
      '<path d="' + d + '" fill="none" stroke="' + GREEN + '" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" pathLength="1" class="dc-draw"/>' +
      '<circle cx="' + last[0] + '" cy="' + last[1] + '" r="3.5" fill="' + GREEN + '"/></svg>';
  }
  function gaugeSVG(u, size, inner) {
    var r = size / 2 - 6, c = 2 * Math.PI * r, arc = 0.78, track = c * arc, fill = Math.max(0.01, arc * left(u) / 100) * c;
    return '<div class="dc-gauge" style="width:' + size + "px;height:" + size + 'px">' +
      '<svg viewBox="0 0 ' + size + " " + size + '" width="' + size + '" height="' + size + '"><g transform="rotate(129 ' + size / 2 + " " + size / 2 + ')">' +
      '<circle cx="' + size / 2 + '" cy="' + size / 2 + '" r="' + r + '" fill="none" stroke="rgba(255,255,255,.1)" stroke-width="9" stroke-linecap="round" stroke-dasharray="' + track + " " + c + '"/>' +
      '<circle class="dc-gauge__arc" cx="' + size / 2 + '" cy="' + size / 2 + '" r="' + r + '" fill="none" stroke="' + ramp(u) + '" stroke-width="9" stroke-linecap="round" stroke-dasharray="' + fill + " " + c + '"/>' +
      "</g></svg><div class=\"dc-gauge__in\">" + inner + "</div></div>";
  }

  var render = {
    focus: function (s) {
      var d = P[s.provider], lead = d.windows[0], other = d.windows[1], compact = s.size === "small";
      var h = header(d.name, { id: s.provider, plan: d.plan, pill: d.status, compact: compact });
      var big = '<div class="dc-figure' + (compact ? " is-sm" : "") + '"><b style="color:' + figure(lead.used) + '">' + left(lead.used) + "</b><span>%</span></div>";
      if (compact) return h + '<span class="dc-flex"></span>' + big + '<p class="dc-cap">' + esc(lead.t) + " · " + esc(lead.reset) + "</p>";
      return h + '<span class="dc-flex"></span>' + big +
        '<p class="dc-cap">' + esc(lead.t) + "剩余 · " + esc(lead.reset) + "后重置</p>" + '<span class="dc-flex"></span>' +
        stats([
          stat(other ? left(other.used) + "%" : "—", other ? other.t : "—", GREEN),
          d.spend ? stat(d.spend, "今日花费") : stat(lead.used >= 70 ? "偏快" : "—", "节奏"),
          d.tokens ? stat(d.tokens, "今日 token") : stat(lead.reset, "后重置"),
        ]) + (s.size === "large" ? windowLines(d) : "") + '<span class="dc-flex"></span>' + footer("person", d.acct);
    },
    gauge: function (s) {
      var d = P[s.provider], lead = d.windows[0], other = d.windows[1];
      if (s.size === "small") {
        return header(d.name, { id: s.provider, pill: d.status, compact: true }) + '<span class="dc-flex"></span>' +
          '<div class="dc-center">' + gaugeSVG(lead.used, 92, '<b class="dc-mono">' + left(lead.used) + "%</b>" + logo(s.provider, 12)) + "</div>" +
          '<span class="dc-flex"></span><p class="dc-cap is-center">' + esc(lead.t) + " · " + esc(lead.reset) + "</p>";
      }
      function tile(icon, value, label, tint) {
        return '<div class="dc-tile"><div><span class="dc-ic" style="color:' + (tint || GREEN) + '">' + ICON[icon] + '</span><b class="dc-mono">' + esc(value) + "</b></div><span>" + esc(label) + "</span></div>";
      }
      return header(d.name, { id: s.provider, plan: d.plan, pill: d.status }) + '<span class="dc-flex"></span>' +
        '<div class="dc-row"><div><p class="dc-cap is-top">' + esc(lead.t) + '</p><div class="dc-figure is-md"><b style="color:' + figure(lead.used) + '">' +
        left(lead.used) + "</b><span>% 剩余</span></div></div><span class=\"dc-sp\"></span>" + gaugeSVG(lead.used, 78, logo(s.provider, 24)) + "</div>" +
        '<span class="dc-flex"></span><div class="dc-tiles">' +
        tile("clock", lead.s, "后重置") + tile("flame", lead.used >= 80 ? "2天3时" : "够用", "预计用完", lead.used >= 80 ? "#E5484D" : GREEN) +
        tile("calendar", other ? left(other.used) + "%" : "—", other ? other.t : "—") + "</div>" +
        (s.size === "large" ? windowLines(d) : "") + '<span class="dc-flex"></span>' + footer("person", d.acct);
    },
    trend: function (s) {
      var h = header("AI 花费", { symbol: "dollar", pill: ["实时", GREEN], compact: s.size === "small" });
      if (s.size === "small") {
        return h + '<span class="dc-flex"></span><p class="dc-cap is-top">今日</p><b class="dc-money is-sm">$38.20</b>' +
          '<span class="dc-flex"></span>' + line(SPEND14, 136, 30) + '<p class="dc-cap dc-mono">近 7 天 $331</p>';
      }
      var money = '<div><p class="dc-cap is-top">今日</p><b class="dc-money">$38.20</b></div>';
      var body = s.size === "medium"
        ? '<div class="dc-row is-bottom">' + money + '<span class="dc-sp"></span><div class="dc-trend"><span class="dc-mono dc-green">近 14 天</span>' + line(SPEND14, 140, 52) + "</div></div>"
        : '<div class="dc-row">' + money + '</div><span class="dc-flex"></span><span class="dc-mono dc-green dc-small">近 30 天</span>' + line(SPEND14.concat(SPEND14.slice(0, 16)), 304, 70);
      return h + '<span class="dc-flex"></span>' + body + '<span class="dc-flex"></span>' +
        stats([stat("$42.10", "昨日", GREEN), stat("$331", "近 7 天"), stat("41.2M", "今日 token")], true) +
        '<span class="dc-flex"></span>' + footer("cpu", "claude-opus-5");
    },
    daily: function (s) {
      var many = s.size === "large", values = many ? TOKENS7.concat(TOKENS7) : TOKENS7, peak = Math.max.apply(null, values);
      var h = header("每日用量", { symbol: "bars", pill: [many ? "近 14 天" : "近 7 天", GREEN], compact: s.size === "small" });
      function bars(height, labels) {
        return '<div class="dc-bars" style="height:' + (height + (labels ? 16 : 0)) + 'px">' + values.map(function (v, i) {
          var today = i === values.length - 1;
          return '<div class="dc-bars__col">' +
            '<i style="position:relative;height:' + Math.max(3, height * v / peak) + "px;background:" + (today ? GREEN : "rgba(255,255,255,.22)") + '">' +
            (labels && today ? '<b class="dc-mono dc-green">' + v + "M</b>" : "") + "</i>" +
            (labels ? "<span" + (today ? ' class="is-today"' : "") + ">" + (many ? String(i + 1) : DAYS[i]) + "</span>" : "") + "</div>";
        }).join("") + "</div>";
      }
      if (s.size === "small") {
        return h + '<span class="dc-flex"></span><b class="dc-money is-sm dc-green">41.2M</b><p class="dc-cap is-tight">今日 token</p>' +
          '<span class="dc-flex"></span>' + bars(46, false);
      }
      return h + '<span class="dc-flex"></span>' + bars(many ? 150 : 74, true) + '<span class="dc-flex"></span>' +
        stats([stat("41.2M", "今日", GREEN), stat("36.4M", "日均"), stat("113%", "达到日均")]) +
        (many ? '<span class="dc-flex"></span>' + footer("cpu", "claude-opus-5") : "");
    },
    grid: function (s) {
      var ids = s.size === "small" ? ORDER.slice(0, 2) : ORDER;
      var h = header("QuotaBar", { symbol: "grid", pill: ["1 个故障", AMBER], compact: s.size === "small" });
      if (s.size === "small") {
        return h + '<span class="dc-flex"></span><div class="dc-rows">' + ids.map(function (id) {
          var u = P[id].windows[0].used;
          return '<div class="dc-crow"><div>' + logo(id, 13) + "<span>" + P[id].name + '</span><span class="dc-sp"></span><b class="dc-mono" style="color:' + figure(u) + '">' + left(u) + "%</b></div>" + steps(u, 4) + "</div>";
        }).join("") + '</div><span class="dc-flex"></span>';
      }
      var big = s.size === "large";
      return h + '<span class="dc-flex"></span><div class="dc-grid' + (big ? " is-big" : "") + '">' + ids.map(function (id) {
        var w = P[id].windows[0];
        return '<div class="dc-gtile"><div class="dc-gtile__head">' + logo(id, big ? 14 : 12) + (big ? "<span>" + P[id].name + "</span>" : "") + "</div>" +
          '<div class="dc-figure is-grid' + (big ? " is-big" : "") + '"><b style="color:' + figure(w.used) + '">' + left(w.used) + "</b><span>%</span></div>" +
          steps(w.used, big ? 5 : 4) + '<span class="dc-mono dc-dim dc-small">' + esc(w.s) + "</span></div>";
      }).join("") + '</div><span class="dc-flex"></span>' + footer("grid", ORDER.length + " 个服务商 · 剩余");
    },
    ranking: function (s) {
      var compact = s.size === "small";
      var ranked = ORDER.slice().sort(function (a, b) { return P[b].windows[0].used - P[a].windows[0].used; }).slice(0, s.size === "large" ? 5 : 3);
      var h = header(compact ? "快用完" : "快用完的排前面", { symbol: "flame", pill: ["实时", GREEN], compact: compact });
      return h + '<span class="dc-flex"></span><div class="dc-rank' + (compact ? " is-sm" : "") + '">' + ranked.map(function (id, i) {
        var w = P[id].windows[0];
        return '<div class="dc-rank__row">' + (compact ? "" : '<span class="dc-rank__n dc-mono">' + (i + 1) + "</span>") + logo(id, compact ? 14 : 18) +
          '<div class="dc-rank__body"><div><b>' + P[id].name + '</b><span class="dc-sp"></span>' + (compact ? "" : '<span class="dc-mono dc-dim dc-small">' + esc(w.s) + "</span>") +
          '<b class="dc-mono dc-rank__pct" style="color:' + figure(w.used) + '">' + left(w.used) + "%</b></div>" + bar(w.used, compact ? 4 : 5) + "</div></div>";
      }).join("") + '</div><span class="dc-flex"></span>' + (s.size === "large" ? footer("flame", "按剩余从少到多排序") : "");
    },
    classic: function (s) {
      var ids = s.size === "small" ? ORDER.slice(0, 2) : ORDER;
      function ring(id) {
        var u = P[id].windows[0].used, r = 19, c = 2 * Math.PI * r;
        return '<div class="dc-ring"><div class="dc-ring__disc"><svg viewBox="0 0 46 46" width="46" height="46"><circle cx="23" cy="23" r="' + r + '" fill="none" stroke="rgba(255,255,255,.14)" stroke-width="3"/>' +
          '<circle cx="23" cy="23" r="' + r + '" fill="none" stroke="' + ramp(u) + '" stroke-width="3" stroke-linecap="round" stroke-dasharray="' + Math.max(0.5, c * u / 100) + " " + c + '" transform="rotate(-90 23 23)"/></svg>' +
          logo(id, 22) + '</div><b class="dc-mono">' + Math.round(u) + "%</b></div>";
      }
      return '<div class="dc-head"><b class="dc-title wordmark">QuotaBar</b><span class="dc-sp"></span><span class="dc-dim dc-small">刚刚</span></div>' +
        '<span class="dc-flex"></span><div class="dc-rings">' + ids.map(ring).join("") + "</div><span class=\"dc-flex\"></span>" +
        (s.size === "large" ? '<div class="dc-lines">' + ORDER.map(function (id) {
          var w = P[id].windows[0];
          return '<div class="dc-line"><div class="dc-line__top"><span>' + P[id].name + " · " + esc(w.t) + '</span><span class="dc-sp"></span><b class="dc-mono" style="color:' + figure(w.used) + '">' + left(w.used) + "%</b></div>" + steps(w.used, 4) + "</div>";
        }).join("") + "</div><span class=\"dc-flex\"></span>" : "");
    },
  };

  /* ── 挂到页面上 ─────────────────────────────────────────────────── */
  host.className = "desktop__widget dc-host";
  host.removeAttribute("aria-label");
  host.innerHTML = '<div class="dc" tabindex="0" role="group" aria-label="QuotaBar 桌面卡片，右键或点右上角按钮更换样式">' +
    '<div class="dc-body"></div><button class="dc-more" type="button" aria-label="卡片设置" aria-haspopup="menu">' +
    '<svg viewBox="0 0 16 16" width="14" height="14" fill="currentColor"><circle cx="3.5" cy="8" r="1.4"/><circle cx="8" cy="8" r="1.4"/><circle cx="12.5" cy="8" r="1.4"/></svg></button></div>' +
    '<p class="dc-hint">右键卡片，或点右上角 ⋯ 换样式和尺寸</p>';
  var card = host.querySelector(".dc"), body = host.querySelector(".dc-body"), more = host.querySelector(".dc-more"), hint = host.querySelector(".dc-hint");
  try { if (localStorage.getItem("qb-deskcard-hinted")) hint.hidden = true; } catch (e) { /* 忽略 */ }

  function paint(animate) {
    card.setAttribute("data-size", state.size);
    card.setAttribute("data-style", state.style);
    var html = render[state.style](state);
    if (!animate || window.matchMedia("(prefers-reduced-motion: reduce)").matches) { body.innerHTML = html; return; }
    card.classList.add("is-swapping");
    setTimeout(function () {
      body.innerHTML = html;
      card.classList.remove("is-swapping");
    }, 140);
  }
  paint(false);

  /* ── 设置菜单：和 macOS 右键菜单一样的层级 ───────────────────────── */
  var menu = document.createElement("div");
  menu.className = "dc-menu";
  menu.setAttribute("role", "menu");
  menu.hidden = true;
  document.body.appendChild(menu);

  function item(label, checked, action, disabled) {
    return '<button type="button" role="menuitemradio" aria-checked="' + (checked ? "true" : "false") + '"' + (disabled ? " disabled" : "") +
      ' data-action="' + action + '"><span class="dc-menu__check">' + (checked ? "✓" : "") + "</span>" + label + "</button>";
  }
  function sub(label, inner) {
    return '<div class="dc-menu__sub"><button type="button" class="dc-menu__parent" aria-haspopup="menu"><span class="dc-menu__check"></span>' + label +
      '<span class="dc-menu__chev">›</span></button><div class="dc-menu dc-menu--sub" role="menu">' + inner + "</div></div>";
  }
  function buildMenu() {
    menu.innerHTML =
      '<p class="dc-menu__label">桌面卡片</p>' +
      sub("样式", STYLES.map(function (s) { return item(s[1], state.style === s[0], "style:" + s[0]); }).join("")) +
      sub("尺寸", SIZES.map(function (s) { return item(s[1], state.size === s[0], "size:" + s[0]); }).join("")) +
      sub("服务商", ORDER.map(function (id) { return item(P[id].name, SINGLE[state.style] && state.provider === id, "provider:" + id, !SINGLE[state.style]); }).join("")) +
      "<hr>" + '<button type="button" data-action="reset"><span class="dc-menu__check"></span>恢复默认</button>';
  }
  function openMenu(x, y) {
    buildMenu();
    menu.hidden = false;
    var w = menu.offsetWidth, h = menu.offsetHeight;
    menu.style.left = Math.min(x, window.innerWidth - w - 8) + "px";
    menu.style.top = Math.min(y, window.innerHeight - h - 8) + "px";
    card.classList.add("is-menu");
    try { localStorage.setItem("qb-deskcard-hinted", "1"); } catch (e) { /* 忽略 */ }
    hint.hidden = true;
    var first = menu.querySelector("button");
    if (first) first.focus({ preventScroll: true });
  }
  function closeMenu() {
    if (menu.hidden) return;
    menu.hidden = true;
    card.classList.remove("is-menu");
  }
  card.addEventListener("contextmenu", function (e) { e.preventDefault(); openMenu(e.clientX, e.clientY); });
  more.addEventListener("click", function (e) {
    e.stopPropagation();
    var r = more.getBoundingClientRect();
    if (menu.hidden) openMenu(r.left, r.bottom + 6); else closeMenu();
  });
  menu.addEventListener("click", function (e) {
    var b = e.target.closest("button[data-action]");
    if (!b || b.disabled) return;
    var parts = b.getAttribute("data-action").split(":");
    if (parts[0] === "reset") { state = { style: DEFAULT.style, size: DEFAULT.size, provider: DEFAULT.provider }; }
    else { state[parts[0]] = parts[1]; }
    save();
    closeMenu();
    paint(true);
  });
  menu.addEventListener("keydown", function (e) {
    var items = Array.prototype.slice.call(menu.querySelectorAll("button:not([disabled])")).filter(function (b) { return b.offsetParent !== null; });
    var i = items.indexOf(document.activeElement);
    if (e.key === "ArrowDown" || e.key === "ArrowUp") { e.preventDefault(); items[(i + (e.key === "ArrowDown" ? 1 : -1) + items.length) % items.length].focus(); }
    if (e.key === "Escape") { closeMenu(); card.focus(); }
  });
  document.addEventListener("pointerdown", function (e) { if (!menu.hidden && !menu.contains(e.target) && e.target !== more && !more.contains(e.target)) closeMenu(); });
  var lastWidth = window.innerWidth;
  window.addEventListener("resize", function () {
    // 只在窗口真的变宽变窄时收起；有些浏览器加载后会补发一次 resize
    if (window.innerWidth !== lastWidth) { lastWidth = window.innerWidth; closeMenu(); }
  });
  window.addEventListener("scroll", closeMenu, { passive: true });
  card.addEventListener("keydown", function (e) {
    if ((e.key === "Enter" || e.key === " " || (e.shiftKey && e.key === "F10")) && e.target === card) {
      e.preventDefault();
      var r = card.getBoundingClientRect();
      openMenu(r.left + 16, r.top + 16);
    }
  });

  /* ── 拖动：和应用里一样按住就能挪，只在桌面这一屏里 ───────────────── */
  var desk = document.querySelector(".desktop");
  var drag = null;
  card.addEventListener("pointerdown", function (e) {
    if (e.button !== 0 || e.target.closest(".dc-more")) return;
    var hostRect = host.getBoundingClientRect(), deskRect = desk.getBoundingClientRect();
    drag = { id: e.pointerId, x: e.clientX, y: e.clientY, left: hostRect.left - deskRect.left, top: hostRect.top - deskRect.top, moved: false, desk: deskRect };
  });
  window.addEventListener("pointermove", function (e) {
    if (!drag || e.pointerId !== drag.id) return;
    var dx = e.clientX - drag.x, dy = e.clientY - drag.y;
    if (!drag.moved && Math.abs(dx) + Math.abs(dy) < 4) return;
    if (!drag.moved) { drag.moved = true; card.setPointerCapture(e.pointerId); card.classList.add("is-dragging"); }
    var w = host.offsetWidth, h = host.offsetHeight;
    var left = Math.min(Math.max(drag.left + dx, 8), drag.desk.width - w - 8);
    var top = Math.min(Math.max(drag.top + dy, 40), drag.desk.height - h - 8);
    host.style.left = left + "px";
    host.style.top = top + "px";
    host.style.bottom = "auto";
  });
  window.addEventListener("pointerup", function (e) {
    if (!drag || e.pointerId !== drag.id) return;
    card.classList.remove("is-dragging");
    drag = null;
  });
})();

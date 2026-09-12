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

/* 让重建出来的界面动起来。
 *
 * 颜色用的是应用里同一条连续色标 —— 同样的 9 个 stop、同样的 sRGB 混合，
 * 所以页面上看到的绿/金/橙/红就是装上之后会看到的那几个。
 */
(function () {
  "use strict";

  var reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

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
    if (p <= 50) return STOPS[0];
    if (p >= 90) return STOPS[8];
    var x = (p - 50) / 5;
    var i = Math.floor(x);
    var t = x - i;
    var a = channels(STOPS[i]);
    var b = channels(STOPS[i + 1]);
    var out = "";
    for (var c = 0; c < 3; c++) {
      var n = Math.round(a[c] + (b[c] - a[c]) * t);
      out += (n < 16 ? "0" : "") + n.toString(16);
    }
    return out.toUpperCase();
  }

  /* ── 应用读数到一个元素 ──────────────────────────────────────────── */
  function paint(el, used) {
    var colour = "#" + rampHex(used);
    var fill = el.querySelector(".qb-bar__fill, .qb-tile__fill");
    if (fill) {
      fill.style.width = used + "%";
      fill.style.background = colour;
    }
    var arc = el.querySelector(".qb-ring__arc");
    if (arc) {
      var len = arc.getTotalLength ? arc.getTotalLength() : 132;
      arc.style.strokeDasharray = len;
      arc.style.strokeDashoffset = len * (1 - used / 100);
      arc.style.stroke = colour;
    }
    var pct = el.querySelector(".qb-win__pct, .qb-ring__pct");
    if (pct) {
      pct.textContent = Math.round(used) + "%";
      if (pct.classList.contains("qb-win__pct")) pct.style.color = colour;
    }
  }

  var readings = [];
  Array.prototype.forEach.call(document.querySelectorAll("[data-used]"), function (el) {
    readings.push({ el: el, used: parseFloat(el.getAttribute("data-used")) });
  });

  /* 折线要知道自己多长才能画出来 */
  Array.prototype.forEach.call(document.querySelectorAll(".qb-spark__box path"), function (p) {
    var len = p.getTotalLength();
    p.style.setProperty("--len", len);
  });

  function settle() {
    readings.forEach(function (r) { paint(r.el, r.used); });
    Array.prototype.forEach.call(document.querySelectorAll(".qb"), function (n) {
      n.classList.add("is-live");
    });
  }

  if (reduced) {
    settle();
  } else {
    // 先归零，回流一次，再放到真值 —— 否则起止在同一帧里，浏览器不插值
    readings.forEach(function (r) { paint(r.el, 0); });
    void document.body.offsetHeight;
    // 等它进入视口再跑，滚到才看得见
    if ("IntersectionObserver" in window && readings.length) {
      var io = new IntersectionObserver(function (entries) {
        entries.forEach(function (e) {
          if (!e.isIntersecting) return;
          settle();
          io.disconnect();
        });
      }, { rootMargin: "0px 0px -10% 0px" });
      io.observe(readings[0].el.closest(".qb") || readings[0].el);
      // 兜底：视口从未合成过（后台标签页）时观察器不回调
      setTimeout(settle, 2500);
    } else {
      setTimeout(settle, 120);
    }
  }

  /* ── 轻微游走，像真的在刷新 ──────────────────────────────────────
   * 在各自基准值附近 ±3 个百分点晃，不是单调爬升 —— 页面开着不动的话，
   * 爬升会让每一条最后都顶到红色，反倒比静态更不像真的。
   */
  if (!reduced && readings.length) {
    readings.forEach(function (r) { r.base = r.used; });
    setInterval(function () {
      if (document.hidden) return;
      readings.forEach(function (r) {
        var drift = (Math.random() - 0.45) * 1.6;
        r.used = Math.min(100, Math.max(0, Math.min(r.base + 3, Math.max(r.base - 3, r.used + drift))));
        paint(r.el, r.used);
      });
    }, 3200);
  }
})();

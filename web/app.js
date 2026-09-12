/* QuotaBar 落地页的一点交互。没有依赖，没有构建步骤。 */
(function () {
  "use strict";

  /* 每次用的时候现取。只在加载时取一次的话，用户中途打开「减弱动态效果」，
     CSS 那边的 transition: none 立刻生效，而这边还在等一个永远不会来的
     transitionend。 */
  var motion = window.matchMedia("(prefers-reduced-motion: reduce)");
  function reduced() { return motion.matches; }

  /* ── 菜单栏时钟 ───────────────────────────────────────────────────
   * 访客自己的本地时间，按其系统语言排版：zh-CN 得到「周六 05:48」，
   * en-US 得到「Sat 05:48」——就是 macOS 菜单栏右上角那一行。每分钟对齐
   * 一次，不用每秒重排。写死的时间和访客手表对不上，比没有更糟。
   */
  var clock = document.getElementById("menubarClock");
  if (clock) {
    var format;
    try {
      format = new Intl.DateTimeFormat(navigator.language || "zh-CN", {
        weekday: "short", hour: "2-digit", minute: "2-digit", hour12: false,
      });
    } catch (e) {
      format = null;
    }
    function tick() {
      var now = new Date();
      var text = format
        ? format.format(now)
        : now.toTimeString().slice(0, 5);
      // 某些引擎会在 24 小时制里把 0 点写成 24:xx
      text = text.replace(/24:(\d\d)/, "00:$1");
      // 中文排版把星期和时间连着写（周六07:04）；菜单栏里两者之间有一个空格
      text = text.replace(/([^\s\d])(\d{1,2}:\d\d)/, "$1 $2");
      clock.textContent = text;
      clock.setAttribute("datetime", now.toISOString());
      // 下一次正好在整分钟
      setTimeout(tick, 60000 - (now.getSeconds() * 1000 + now.getMilliseconds()) + 50);
    }
    tick();
  }

  /* ── FAQ 手风琴 ───────────────────────────────────────────────────
   * <details> 自带开合但没有过渡。这里接管：把面板高度从 0 动到实测
   * 高度，收起时反过来，并把 open 属性的移除推迟到动画结束——否则
   * 内容会在第一帧就消失，动画等于没有。
   */
  var accordions = document.querySelectorAll(".qa");
  // 只有真的接管了，才让 CSS 把答案折起来（见 styles.css 的 .qa-anim）。
  if (accordions.length) document.documentElement.classList.add("qa-anim");

  Array.prototype.forEach.call(accordions, function (qa) {
    var summary = qa.querySelector(".qa__q");
    var panel = qa.querySelector(".qa__a");
    var animating = false;

    function heightOf() {
      return panel.firstElementChild.getBoundingClientRect().height + "px";
    }

    /* transitionend 不保证到达 —— 减弱动态效果会让时长归零，后台标签页也
       可能从不合成。没有兜底，animating 会永远停在 true，这一条本次会话
       就再也点不开了。 */
    function onSettled(fn) {
      var fired = false;
      function once() {
        if (fired) return;
        fired = true;
        clearTimeout(timer);
        panel.removeEventListener("transitionend", once);
        fn();
      }
      var timer = setTimeout(once, 420);
      panel.addEventListener("transitionend", once);
    }

    /* <details> 也会被浏览器自己展开：页内查找命中隐藏文字、锚点定位都会。
       那条路径不经过下面的点击处理器，面板高度还停在 0，答案就成了隐形的。 */
    qa.addEventListener("toggle", function () {
      if (animating) return;
      panel.style.height = qa.open ? "auto" : "0px";
    });
    if (qa.open) panel.style.height = "auto";

    summary.addEventListener("click", function (event) {
      event.preventDefault();
      if (animating) return;

      if (reduced()) {
        qa.open = !qa.open;
        panel.style.height = qa.open ? "auto" : "0px";
        return;
      }

      if (!qa.open) {
        animating = true;             // 先立起来，好让下面的 toggle 监听器让路
        qa.open = true;
        panel.style.height = "0px";
        // 强制回流，否则起始值和目标值在同一帧里，浏览器不会插值
        void panel.offsetHeight;
        panel.style.height = heightOf();
        onSettled(function () {
          panel.style.height = "auto";   // 之后内容变高也能跟上
          animating = false;
        });
      } else {
        animating = true;
        panel.style.height = heightOf();
        void panel.offsetHeight;
        panel.style.height = "0px";
        onSettled(function () {
          qa.open = false;              // 收完再撤 open，内容才不会提前消失
          animating = false;
        });
      }
    });
  });

  /* ── 进场 ────────────────────────────────────────────────────────
   * 藏起来这件事写在 CSS 里，且只在这里加上 .reveal 之后才生效。这样
   * JS 若没跑到，元素就是普通可见的——页面绝不会因为一个观察器没触发
   * 而整屏空白。另设一道兜底：两秒内还没点亮的一律点亮，覆盖标签页
   * 在后台从未合成、观察器因此永不回调的情况。
   */
  var revealables = document.querySelectorAll(
    ".section-head, .feature, .card, .showcase, .faq > *"
  );

  function showAll() {
    Array.prototype.forEach.call(revealables, function (el) {
      el.classList.add("is-in");
    });
  }

  if (revealables.length) {
    Array.prototype.forEach.call(revealables, function (el, i) {
      el.setAttribute("data-reveal", "");
      el.style.transitionDelay = (i % 3) * 70 + "ms";
    });

    if (reduced() || !("IntersectionObserver" in window)) {
      showAll();
    } else {
      document.documentElement.classList.add("reveal");
      var io = new IntersectionObserver(
        function (entries) {
          entries.forEach(function (entry) {
            if (!entry.isIntersecting) return;
            entry.target.classList.add("is-in");
            io.unobserve(entry.target);
          });
        },
        { rootMargin: "0px 0px -12% 0px" }
      );
      Array.prototype.forEach.call(revealables, function (el) { io.observe(el); });
      setTimeout(showAll, 2000);
    }
  }

  /* ── Dock 的邻位放大 ──────────────────────────────────────────────
   * macOS 的 Dock 会带动相邻图标，只放大指针正下方那一个像贴纸。
   * 距离用图标中心算，两格以外不再受影响。
   */
  var dock = document.getElementById("dock");
  if (dock && !reduced() && window.matchMedia("(hover: hover)").matches) {
    var tiles = dock.querySelectorAll(".dock__tile");

    dock.addEventListener("mousemove", function (event) {
      Array.prototype.forEach.call(tiles, function (tile) {
        var box = tile.getBoundingClientRect();
        var distance = Math.abs(event.clientX - (box.left + box.width / 2));
        var falloff = Math.max(0, 1 - distance / (box.width * 2.2));
        var scale = 1 + falloff * falloff * 0.42;
        tile.style.transform = "translateY(" + falloff * -11 + "px) scale(" + scale + ")";
      });
    });

    dock.addEventListener("mouseleave", function () {
      Array.prototype.forEach.call(tiles, function (tile) { tile.style.transform = ""; });
    });
  }
})();

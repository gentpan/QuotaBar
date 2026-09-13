/* Quota Run（quota.run）：排行榜（index.html）和个人主页（u.html，Caddy 把 /@username 改写到它）。
 *
 * 只读同源的公开接口 /api/v1（契约见 docs/quota-run.md）。?demo=1 用下面内置的
 * 示例数据，不发任何请求——从 file:// 打开、或者服务端还没上线时，也能预览整页。
 * 文案按 <html lang> 取；数字、时长、相对时间也按页面语言排。没有依赖，没有构建步骤。
 */
(function () {
  "use strict";

  var ZH = /^zh/i.test(document.documentElement.lang);
  var script = document.currentScript;
  var SRC = script ? script.src : "";
  // 站点根目录和资源指纹都从脚本自己的地址取：中文页在下一层，/@username 又是改写出来的路径
  var ROOT = SRC.replace(/run\.js(\?.*)?$/, "");
  var V = (SRC.match(/\?v=[A-Za-z0-9]+/) || [""])[0];
  var API = "/api/v1";
  var params = new URLSearchParams(location.search);
  var DEMO = params.get("demo") === "1";
  var PAGE = document.body.getAttribute("data-run-page");
  // 本地预览没有 Caddy 的改写，/@username 打不开，个人主页链接改走 u.html?user=
  var LOCAL = location.protocol === "file:" || /^(localhost|127\.0\.0\.1|\[::1\])$/.test(location.hostname);
  var USERNAME = /^[a-z0-9][a-z0-9_-]{2,19}$/;

  var PROVIDERS = {};
  try { PROVIDERS = JSON.parse(document.getElementById("run-providers").textContent); } catch (e) { /* 没有就用原始 id */ }

  function t(en, zh) { return ZH ? zh : en; }
  function each(list, fn) { Array.prototype.forEach.call(list, fn); }
  function $(id) { return document.getElementById(id); }

  var ENTITIES = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" };
  function esc(value) {
    return String(value == null ? "" : value).replace(/[&<>"']/g, function (c) { return ENTITIES[c]; });
  }

  /* ── 格式 ─────────────────────────────────────────────────────────── */

  var NUMBER = new Intl.NumberFormat(ZH ? "zh-CN" : "en-US");
  function number(n) { return n == null || isNaN(n) ? "—" : NUMBER.format(n); }

  // 「2h 37m」「1d 3h 12m」「45m」；中文「2 小时 37 分」「1 天 3 小时 12 分」「45 分钟」，和应用里的写法一致
  function duration(seconds) {
    var s = Math.max(0, Math.round(Number(seconds) || 0));
    if (s < 60) return ZH ? s + " 秒" : s + "s";
    var d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60);
    if (!d && !h) return ZH ? m + " 分钟" : m + "m";
    var parts = [];
    if (d) parts.push(ZH ? d + " 天" : d + "d");
    parts.push(ZH ? h + " 小时" : h + "h");
    parts.push(ZH ? m + " 分" : m + "m");
    return parts.join(" ");
  }

  function percent(value) {
    var v = Math.round((Number(value) || 0) * 10) / 10;
    return (v % 1 ? v.toFixed(1) : String(v)) + "%";
  }

  // 接口里的时间是 Unix 秒；也接受毫秒和 ISO 字符串
  function toDate(value) {
    if (value == null || value === "") return null;
    var n = Number(value);
    var date = isNaN(n) ? new Date(value) : new Date(n < 1e12 ? n * 1000 : n);
    return isNaN(date.getTime()) ? null : date;
  }

  var DAY_FORMAT = new Intl.DateTimeFormat(ZH ? "zh-CN" : "en-US", { month: ZH ? "long" : "short", day: "numeric" });
  var YEAR_FORMAT = new Intl.DateTimeFormat(ZH ? "zh-CN" : "en-US", { year: "numeric", month: ZH ? "long" : "short", day: "numeric" });
  var MONTH_FORMAT = new Intl.DateTimeFormat(ZH ? "zh-CN" : "en-US", { year: "numeric", month: ZH ? "long" : "short" });
  var FULL_FORMAT = new Intl.DateTimeFormat(ZH ? "zh-CN" : "en-US", { dateStyle: "medium", timeStyle: "short" });

  function relative(date) {
    if (!date) return "—";
    var diff = (Date.now() - date.getTime()) / 1000;
    if (diff < 60) return t("just now", "刚刚");
    if (diff < 3600) return ZH ? Math.floor(diff / 60) + " 分钟前" : Math.floor(diff / 60) + "m ago";
    if (diff < 86400) return ZH ? Math.floor(diff / 3600) + " 小时前" : Math.floor(diff / 3600) + "h ago";
    if (diff < 7 * 86400) return ZH ? Math.floor(diff / 86400) + " 天前" : Math.floor(diff / 86400) + "d ago";
    return (date.getFullYear() === new Date().getFullYear() ? DAY_FORMAT : YEAR_FORMAT).format(date);
  }

  function timeTag(date, text) {
    if (!date) return '<span class="run-dim">—</span>';
    return '<time datetime="' + date.toISOString() + '" title="' + esc(FULL_FORMAT.format(date)) + '">' + esc(text || relative(date)) + "</time>";
  }

  // ISO-8601 周（UTC），赛季就是它：2026-W37
  function isoWeek(ms) {
    var d = new Date(ms);
    var day = d.getUTCDay() || 7;
    var thursday = Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate() + 4 - day);
    var year = new Date(thursday).getUTCFullYear();
    var week = Math.ceil(((thursday - Date.UTC(year, 0, 1)) / 86400000 + 1) / 7);
    return year + "-W" + (week < 10 ? "0" : "") + week;
  }
  function weekStart(ms) {
    var d = new Date(ms);
    var day = d.getUTCDay() || 7;
    return Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate() - day + 1) / 1000;
  }

  function seasonLabel(season) {
    if (!season || season === "all") return t("All time", "全部时间");
    if (season === "current" || season === isoWeek(Date.now())) return t("This week", "本周");
    if (season === isoWeek(Date.now() - 7 * 86400000)) return t("Last week", "上周");
    return String(season);
  }

  /* ── 服务商、窗口、头像、徽章 ──────────────────────────────────────── */

  function providerName(id) {
    var p = PROVIDERS[id];
    return p ? (ZH ? p.zh : p.en) : String(id || "");
  }

  function logo(id, size) {
    size = size || 20;
    if (!PROVIDERS[id] || !/^[a-z0-9-]+$/.test(id)) {
      return '<span class="run-logo run-logo--letter" aria-hidden="true" style="width:' + size + "px;height:" + size + 'px">' + esc(String(id || "?").charAt(0).toUpperCase()) + "</span>";
    }
    var tone = PROVIDERS[id].tone ? " is-" + PROVIDERS[id].tone : "";
    return '<img class="run-logo' + tone + '" src="' + ROOT + "assets/logos/" + id + ".png" + V + '" alt="" width="' + size + '" height="' + size + '" loading="lazy" decoding="async">';
  }

  // 窗口名从长度算，不用接口里那句英文 windowTitle：「Weekly」「周额度」「5 小时」；带范围的窗口（按模型分的）把范围名接在后面
  function windowLabel(seconds, key, title) {
    var s = Number(seconds) || 0;
    var label;
    if (s === 604800) label = t("Weekly", "周额度");
    else if (s === 86400) label = t("Daily", "日额度");
    else if (s >= 28 * 86400 && s <= 31 * 86400) label = t("Monthly", "月额度");
    else if (s && s % 86400 === 0) label = ZH ? s / 86400 + " 天" : s / 86400 + "-day";
    else if (s && s % 3600 === 0) label = ZH ? s / 3600 + " 小时" : s / 3600 + "-hour";
    else if (s) label = duration(s);
    else label = title || "";
    var k = String(key || "");
    var scope = k.indexOf(":") >= 0 ? k.slice(k.indexOf(":") + 1) : "";
    return scope ? label + " · " + scope : label;
  }

  function boardName(b) {
    return providerName(b.provider) + (b.planLabel ? " " + b.planLabel : "");
  }

  function metricLabel(metric) {
    return metric === "peak" ? t("Highest peak", "最高峰值") : t("Fastest to 100%", "最快用满");
  }

  function hue(text) {
    var h = 0;
    for (var i = 0; i < text.length; i++) h = (h * 31 + text.charCodeAt(i)) >>> 0;
    return h % 360;
  }

  function avatar(person, extra) {
    var name = String(person.displayName || person.username || "?").trim();
    var initial = (Array.from ? Array.from(name)[0] : name.charAt(0)) || "?";
    return '<span class="run-avatar' + (extra ? " " + extra : "") + '" style="--hue:' + hue(String(person.username || name)) + '" aria-hidden="true">' + esc(initial.toUpperCase()) + "</span>";
  }

  var CHECK = '<svg aria-hidden="true" width="10" height="10" viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M2.5 6.4 5 8.8l4.5-5.3"/></svg>';

  function tierBadge(tier) {
    return tier === "verified"
      ? '<span class="badge run-tier run-tier--verified">' + CHECK + t("Verified", "已验证") + "</span>"
      : '<span class="badge run-tier run-tier--standard">' + t("Standard", "标准") + "</span>";
  }

  // 「账号已核实」：服务商账号的邮箱和这个人在 quota.run 上验证过的登录邮箱一致（accountVerified）。
  // 不是级别，只是级别旁边一枚小图标；名字给读屏，一句话放在 title 里当提示
  var ACCOUNT_ICON = '<svg aria-hidden="true" width="12" height="12" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><circle cx="6" cy="5" r="2.6"/><path d="M1.5 14c0-2.6 2-4.5 4.5-4.5 1.1 0 2.1.3 2.9 1"/><path d="m9.8 11.6 1.9 1.9 3.3-3.7"/></svg>';

  function accountVerifiedText() {
    return t("The provider account's email matches a verified sign-in on quota.run", "服务商账号的邮箱与 quota.run 上验证过的登录邮箱一致");
  }

  function accountMark(verified, inline) {
    if (!verified) return "";
    return '<span class="run-acct' + (inline ? " run-acct--inline" : "") + '" role="img" aria-label="' + esc(t("Account verified", "账号已核实")) +
      '" title="' + esc(accountVerifiedText()) + '">' + ACCOUNT_ICON + "</span>";
  }

  function tierCell(tier, verified) {
    return '<span class="run-tiercell">' + tierBadge(tier) + accountMark(verified) + "</span>";
  }

  function regionLabel(region) {
    return region === "china" ? t("China", "中国") : region === "global" ? t("Global", "国际") : "";
  }

  /* ── 链接 ─────────────────────────────────────────────────────────── */

  function profileHref(username) {
    var u = encodeURIComponent(username);
    if (LOCAL) return ROOT + (ZH ? "zh/" : "") + "u.html?user=" + u + (DEMO ? "&demo=1" : "");
    return (ZH ? "/zh/@" : "/@") + u + (DEMO ? "?demo=1" : "");
  }

  function query(pairs) {
    var q = new URLSearchParams();
    Object.keys(pairs).forEach(function (k) { if (pairs[k] !== "" && pairs[k] != null) q.set(k, pairs[k]); });
    // 窗口键里的冒号不必转义，链接更好读
    return q.toString().replace(/%3A/gi, ":");
  }

  function boardHref(b, metric, season) {
    return ROOT + (ZH ? "zh/" : "") + (LOCAL ? "index.html" : "") + "?" + query({
      provider: b.provider, plan: b.plan, window: b.windowKey,
      metric: metric === "peak" ? "peak" : "", season: season || "", demo: DEMO ? "1" : "",
    });
  }

  function demoHref() {
    var q = new URLSearchParams(location.search);
    q.set("demo", "1");
    return location.href.replace(/[?#].*$/, "") + "?" + q.toString().replace(/%3A/gi, ":");
  }

  // 只放行 https 链接；GitHub 和 X 也接受裸用户名
  function safeLink(kind, value) {
    var v = String(value || "").trim();
    if (!v) return null;
    if (!/^https:\/\//i.test(v)) {
      var handle = v.replace(/^@/, "");
      if (kind === "github" && /^[A-Za-z0-9-]{1,39}$/.test(handle)) v = "https://github.com/" + handle;
      else if (kind === "x" && /^[A-Za-z0-9_]{1,15}$/.test(handle)) v = "https://x.com/" + handle;
      else return null;
    }
    try {
      var url = new URL(v);
      return url.protocol === "https:" ? url : null;
    } catch (e) {
      return null;
    }
  }

  function hostOf(url) {
    return (url.host.replace(/^www\./, "") + url.pathname.replace(/\/$/, "")).slice(0, 48);
  }

  /* ── 数据：真接口或示例 ───────────────────────────────────────────── */

  function api(path) {
    return fetch(API + path, { headers: { Accept: "application/json" }, credentials: "omit" }).then(function (response) {
      return response.json().catch(function () { return null; }).then(function (body) {
        if (!response.ok) {
          var error = new Error((body && body.message) || "HTTP " + response.status);
          error.status = response.status;
          throw error;
        }
        return body;
      });
    });
  }

  // 登录后的接口（会话 Cookie）：带上同源 Cookie，JSON 进出。浏览器在 POST/PUT/DELETE 上自己带 Origin。
  // 出错时抛出的 Error 带 status、code（接口里的 error）和整个回应体 data；网络不通时 status 为 0。
  function request(method, path, body) {
    var init = { method: method, credentials: "same-origin", headers: { Accept: "application/json" } };
    if (body !== undefined) {
      init.headers["Content-Type"] = "application/json";
      init.body = JSON.stringify(body);
    }
    return fetch(API + path, init).then(function (response) {
      return response.text().then(function (text) {
        var data = null;
        try { data = text ? JSON.parse(text) : null; } catch (e) { /* 不是 JSON */ }
        if (!response.ok) {
          var error = new Error((data && data.message) || "HTTP " + response.status);
          error.status = response.status;
          error.code = (data && data.error) || "";
          error.data = data || {};
          throw error;
        }
        return data;
      });
    }, function () {
      var error = new Error("Couldn't reach quota.run.");
      error.status = 0;
      error.code = "network";
      error.data = {};
      throw error;
    });
  }

  // 登录、账号、连接三页的地址。线上 Caddy 把 /login 映射到 login.html；本地预览没有 Caddy，直接走文件
  function pageHref(page, pairs) {
    var q = new URLSearchParams();
    Object.keys(pairs || {}).forEach(function (k) { if (pairs[k] !== "" && pairs[k] != null) q.set(k, pairs[k]); });
    if (DEMO) q.set("demo", "1");
    var s = q.toString();
    var base = LOCAL ? ROOT + (ZH ? "zh/" : "") + page + ".html" : (ZH ? "/zh/" : "/") + page;
    return base + (s ? "?" + s : "");
  }

  function homeHref() {
    return ROOT + (ZH ? "zh/" : "") + (LOCAL ? "index.html" : "") + (DEMO ? "?demo=1" : "");
  }

  // 当前页的路径和查询串，登录回来时要回到这里
  function currentPath() {
    return location.pathname + location.search;
  }

  /* ── 顶栏右侧：登录 / @username ──────────────────────────────────── */

  var sessionLoad = null;

  function session(refresh) {
    if (!sessionLoad || refresh) sessionLoad = DEMO ? Promise.resolve(demoSession()) : request("GET", "/session");
    return sessionLoad;
  }

  function demoSession() {
    var out = { signedIn: false, needsSignup: false, identity: null, user: null, suggestedUsername: null, suggestedDisplayName: null };
    if (params.get("session") === "out") return out;
    if (PAGE === "login") {
      if (params.get("step") !== "signup") return out;
      return { signedIn: true, needsSignup: true, identity: { provider: "github", email: "noor@example.com", name: "Noor Haddad" }, user: null, suggestedUsername: "noorh", suggestedDisplayName: "Noor Haddad" };
    }
    return { signedIn: true, needsSignup: false, identity: { provider: "github", email: "peter@example.com", name: "Peter" }, user: { username: "peter", displayName: "Peter", region: "global" }, suggestedUsername: null, suggestedDisplayName: null };
  }

  function renderAccountLink(s) {
    var link = $("runAccount");
    if (!link) return;
    var user = s && s.signedIn && !s.needsSignup && s.user;
    link.removeAttribute("aria-current");
    if (user && user.username) {
      link.textContent = "@" + user.username;
      link.setAttribute("href", pageHref("account"));
      link.setAttribute("data-state", "in");
      link.setAttribute("title", t("Your account", "你的账号"));
      if (PAGE === "account") link.setAttribute("aria-current", "page");
    } else {
      link.textContent = t("Sign in", "登录");
      link.setAttribute("data-state", "out");
      link.removeAttribute("title");
      if (PAGE === "login") {
        link.setAttribute("href", location.href);
        link.setAttribute("aria-current", "page");
      } else {
        link.setAttribute("href", pageHref("login", { next: currentPath() }));
      }
    }
    link.hidden = false;
  }

  function accountLink() {
    var link = $("runAccount");
    if (!link) return;
    // 排行榜会随筛选改地址：点下去的那一刻再取当前路径
    link.addEventListener("click", function () {
      if (link.getAttribute("data-state") === "out" && PAGE !== "login") link.setAttribute("href", pageHref("login", { next: currentPath() }));
    });
    session().then(renderAccountLink, function () { renderAccountLink(null); });
  }

  function copyText(text, button) {
    function done() {
      var label = button.querySelector("span");
      if (!label) return;
      var before = label.getAttribute("data-label") || label.textContent;
      label.setAttribute("data-label", before);
      label.textContent = button.getAttribute("data-done") || t("Copied", "已复制");
      button.classList.add("is-done");
      setTimeout(function () { label.textContent = before; button.classList.remove("is-done"); }, 1800);
    }
    function fallback() {
      var area = document.createElement("textarea");
      area.value = text;
      area.setAttribute("readonly", "");
      area.style.position = "fixed";
      area.style.opacity = "0";
      document.body.appendChild(area);
      area.select();
      try { document.execCommand("copy"); done(); } catch (e) { /* 复制不了就算了 */ }
      document.body.removeChild(area);
    }
    if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(text).then(done, fallback);
    else fallback();
  }

  function stateBox(kind, title, text, actions) {
    return '<div class="run-state run-state--' + kind + '"' + (kind === "error" ? ' role="alert"' : "") + ">" +
      '<p class="run-state__title">' + title + "</p>" +
      (text ? '<p class="run-state__text">' + text + "</p>" : "") +
      (actions ? '<div class="run-state__actions">' + actions + "</div>" : "") + "</div>";
  }

  function errorBox(title) {
    return stateBox("error", title,
      t("The Quota Run service didn't answer. It may be restarting, or not live yet.", "Quota Run 的服务没有响应，可能在重启，也可能还没上线。"),
      '<button type="button" class="run-btn" data-retry>' + t("Try again", "重试") + "</button>" +
      (DEMO ? "" : '<a class="run-demo" href="' + esc(demoHref()) + '">' + t("Preview with demo data", "用示例数据预览") + "</a>"));
  }

  function setBusy(el, busy) { el.setAttribute("aria-busy", busy ? "true" : "false"); }

  /* ── 排行榜 ───────────────────────────────────────────────────────── */

  function leaderboardPage() {
    var form = $("runFilters");
    var chips = $("runBoards");
    var body = $("runBody");
    var title = $("runTitle");
    var copy = $("runCopy");
    var loadingHTML = body.innerHTML;
    var clean = function (v) { return /^[a-z0-9-]{1,40}$/.test(v || "") ? v : ""; };

    var state = {
      provider: clean(params.get("provider")),
      plan: /^[a-z0-9]{0,40}$/.test(params.get("plan") || "") ? params.get("plan") || "" : "",
      window: /^\d{1,8}:[^\n]{0,80}$/.test(params.get("window") || "") ? params.get("window") : "",
      metric: params.get("metric") === "peak" ? "peak" : "speed",
      season: /^(last|all)$/.test(params.get("season") || "") ? params.get("season") : "current",
      region: /^(global|china)$/.test(params.get("region") || "") ? params.get("region") : "",
      verified: params.get("tier") === "verified",
    };
    if (!state.provider || !state.window) state.provider = "";
    var boards = [];
    var shown = null;   // 当前榜单的描述，来自 /boards 或 /leaderboard 的回应
    var seq = 0;

    $("runSeason").textContent = " · " + isoWeek(Date.now());

    function seasonParam() {
      if (state.season === "last") return isoWeek(Date.now() - 7 * 86400000);
      return state.season;
    }

    function sameBoard(b) {
      return b && b.provider === state.provider && String(b.plan || "") === state.plan && b.windowKey === state.window;
    }

    function syncForm() {
      each(form.elements.metric, function (r) { r.checked = r.value === state.metric; });
      each(form.elements.season, function (r) { r.checked = r.value === state.season; });
      each(form.elements.region, function (r) { r.checked = r.value === state.region; });
      form.elements.verified.checked = state.verified;
    }

    function writeURL() {
      var q = query({
        provider: state.provider, plan: state.provider ? state.plan : "", window: state.provider ? state.window : "",
        metric: state.metric === "peak" ? "peak" : "", season: state.season === "current" ? "" : state.season,
        region: state.region, tier: state.verified ? "verified" : "", demo: DEMO ? "1" : "",
      });
      var url = location.href.replace(/[?#].*$/, "") + (q ? "?" + q : "") + location.hash;
      try { history.replaceState(null, "", url); } catch (e) { /* file:// 下有的浏览器不让改 */ }
      each(document.querySelectorAll("a.run-lang"), function (a) {
        var base = a.getAttribute("data-base") || a.getAttribute("href").replace(/[?#].*$/, "");
        a.setAttribute("data-base", base);
        a.setAttribute("href", base + (q ? "?" + q : ""));
      });
    }

    function renderChips() {
      setBusy(chips, false);
      // 重画会丢焦点：键盘用户刚按下的那个按钮，重画后把焦点放回被选中的那个
      var hadFocus = chips.contains(document.activeElement);
      var list = boards.slice();
      if (state.provider && shown && !list.some(sameBoard)) list.push(shown);
      if (!list.length) {
        chips.innerHTML = '<p class="run-dim run-chips__none">' + t("No boards this week yet.", "本周还没有榜单。") + "</p>";
        return;
      }
      chips.innerHTML = list.map(function (b, i) {
        var runners = b.runners != null
          ? (ZH ? " · " + number(b.runners) + " 人" : " · " + number(b.runners) + (b.runners === 1 ? " runner" : " runners"))
          : "";
        return '<button type="button" class="run-chip" data-i="' + i + '" aria-pressed="' + (sameBoard(b) ? "true" : "false") + '">' +
          logo(b.provider, 22) +
          '<span class="run-chip__text"><b>' + esc(boardName(b)) + "</b><small>" + esc(windowLabel(b.windowSeconds, b.windowKey, b.windowTitle)) + esc(runners) + "</small></span></button>";
      }).join("");
      each(chips.querySelectorAll(".run-chip"), function (button) {
        button.addEventListener("click", function () {
          var b = list[Number(button.getAttribute("data-i"))];
          if (sameBoard(b)) return;
          choose(b);
          renderChips();
          loadBoard();
        });
      });
      if (hadFocus) {
        var pressed = chips.querySelector('[aria-pressed="true"]');
        if (pressed) pressed.focus();
      }
    }

    function choose(b) {
      state.provider = b.provider;
      state.plan = String(b.plan || "");
      state.window = b.windowKey;
      shown = b;
    }

    function renderTitle(b, extra) {
      if (!b) return;
      title.innerHTML = logo(b.provider, 32) +
        "<div><h3>" + esc(boardName(b)) + " · " + esc(windowLabel(b.windowSeconds, b.windowKey, b.windowTitle)) + "</h3>" +
        "<p>" + esc(metricLabel(state.metric)) + " · " + esc(seasonLabel(seasonParam())) + (extra || "") + "</p></div>";
    }

    function renderEntries(data) {
      var entries = (data && data.entries) || [];
      var board = (data && data.board) || shown || {};
      if (board.provider) shown = Object.assign({}, shown || {}, board);
      var runners = shown && shown.runners != null
        ? " · " + (ZH ? number(shown.runners) + " 位参赛者" : number(shown.runners) + (shown.runners === 1 ? " runner" : " runners"))
        : "";
      var updated = toDate(data && data.updatedAt);
      renderTitle(shown, esc(runners) + (updated ? ' · <span class="run-nowrap">' + t("updated ", "") + timeTag(updated) + t("", "更新") + "</span>" : ""));

      if (!entries.length) {
        body.innerHTML = stateBox("empty",
          state.verified ? t("No verified runs here yet", "这里还没有已验证的成绩") : t("No runs yet", "还没有人上榜"),
          t("No runs yet — join from QuotaBar → Settings → Quota Run, and your next full window puts you here.",
            "这里还空着——在 QuotaBar 的「设置」→「Quota Run」里加入，下一次把额度用满，你就在这儿了。") +
          (state.verified || state.region ? " " + t("Or widen the filters above.", "也可以放宽上面的筛选。") : ""),
          "");
        return;
      }

      var speed = state.metric !== "peak";
      var best = Number(entries[0].value) || 1;
      var rows = entries.map(function (e) {
        var isPercent = e.unit ? e.unit === "percent" : !speed;
        var v = Number(e.value) || 0;
        var share = isPercent ? v : (v ? best / v * 100 : 0);
        var rank = Number(e.rank) || 0;
        var date = toDate(e.achievedAt);
        return '<tr class="run-row' + (rank && rank <= 3 ? " is-top is-top-" + rank : "") + '">' +
          '<td class="lb-rank"><span class="run-rank">' + esc(rank || "—") + "</span></td>" +
          '<td class="lb-runner"><a class="run-runner" href="' + esc(profileHref(e.username)) + '">' + avatar(e) +
          '<span class="run-runner__names"><span class="run-runner__name">' + esc(e.displayName || e.username) + "</span>" +
          '<span class="run-runner__handle">@' + esc(e.username) + "</span>" +
          '<span class="run-runner__handle run-narrow">' + (e.tier === "verified" ? t("Verified", "已验证") : t("Standard", "标准")) + accountMark(e.accountVerified, true) + " · " + esc(relative(date)) + "</span></span></a></td>" +
          '<td class="lb-value"><span class="run-value">' + esc(isPercent ? percent(v) : duration(v)) + "</span>" +
          '<span class="run-meter" aria-hidden="true"><i style="width:' + Math.max(3, Math.min(100, share)).toFixed(1) + '%"></i></span></td>' +
          '<td class="lb-tier">' + tierCell(e.tier, e.accountVerified) + "</td>" +
          '<td class="lb-when">' + timeTag(date) + "</td></tr>";
      }).join("");

      body.innerHTML = '<div class="run-table-wrap"><table class="run-table">' +
        "<caption class=\"sr-only\">" + esc(boardName(shown || {}) + " · " + metricLabel(state.metric)) + "</caption>" +
        '<thead><tr><th scope="col" class="lb-rank">' + t("Rank", "名次") + '</th><th scope="col" class="lb-runner">' + t("Runner", "参赛者") +
        '</th><th scope="col" class="lb-value">' + (speed ? t("Time to 100%", "用满用时") : t("Peak", "峰值")) +
        '</th><th scope="col" class="lb-tier">' + t("Tier", "级别") + '</th><th scope="col" class="lb-when">' + (speed ? t("Hit 100%", "用满于") : t("Reached", "达到于")) +
        "</th></tr></thead><tbody>" + rows + "</tbody></table></div>" +
        (entries.length >= 100 ? '<p class="run-foot">' + t("Top 100 shown.", "只显示前 100 名。") + "</p>" : "");
    }

    function loadBoard() {
      var mine = ++seq;
      setBusy(body, true);
      if (body.querySelector("table")) body.classList.add("is-stale");
      else body.innerHTML = loadingHTML;
      writeURL();
      renderTitle(shown);
      var request = {
        provider: state.provider, plan: state.plan, window: state.window, metric: state.metric,
        season: seasonParam(), region: state.region, tier: state.verified ? "verified" : "all", limit: 100,
      };
      var load = DEMO ? Promise.resolve(demo.leaderboard(request)) : api("/leaderboard?" + query(request));
      load.then(function (data) {
        if (mine !== seq) return;
        body.classList.remove("is-stale");
        setBusy(body, false);
        renderEntries(data);
        renderChips();
      }, function () {
        if (mine !== seq) return;
        body.classList.remove("is-stale");
        setBusy(body, false);
        body.innerHTML = errorBox(t("Couldn't load this leaderboard.", "排行榜没加载出来。"));
      });
    }

    function loadBoards() {
      setBusy(chips, true);
      var load = DEMO ? Promise.resolve(demo.boards(state.region))
        : api("/boards?" + query({ region: state.region, season: seasonParam() }));
      return load.then(function (data) {
        boards = (data && data.boards) || [];
        var match = boards.filter(sameBoard)[0];
        if (match) shown = match;
      });
    }

    function start() {
      loadBoards().then(function () {
        if (!state.provider && boards.length) choose(boards[0]);
        renderChips();
        if (state.provider) {
          loadBoard();
        } else {
          writeURL();
          setBusy(body, false);
          title.innerHTML = "<div><h3>Quota Run</h3><p>" + esc(seasonLabel("current")) + " · " + isoWeek(Date.now()) + "</p></div>";
          body.innerHTML = stateBox("empty", t("No runs yet this week", "本周还没有人上榜"),
            t("No runs yet — join from QuotaBar → Settings → Quota Run. Boards appear as soon as someone finishes a window.",
              "这里还空着——在 QuotaBar 的「设置」→「Quota Run」里加入。有人跑完一个额度窗口，榜单就出现了。"), "");
        }
      }, function () {
        setBusy(chips, false);
        chips.innerHTML = '<p class="run-dim run-chips__none">' + t("Boards will show up here once the service answers.", "服务恢复后，榜单会出现在这里。") + "</p>";
        title.innerHTML = "<div><h3>Quota Run</h3><p>" + esc(seasonLabel("current")) + " · " + isoWeek(Date.now()) + "</p></div>";
        setBusy(body, false);
        body.innerHTML = errorBox(t("Couldn't load the leaderboard.", "排行榜没加载出来。"));
      });
    }

    function loadStats() {
      var load = DEMO ? Promise.resolve(demo.stats()) : api("/stats");
      load.then(function (s) {
        each(document.querySelectorAll("#runStats [data-stat]"), function (dd) {
          dd.textContent = number(s && s[dd.getAttribute("data-stat")]);
        });
      }, function () { /* 数字留着「—」，错误在榜单那里说 */ });
    }

    form.addEventListener("change", function (event) {
      var before = state.region + "|" + state.season;
      state.metric = form.elements.metric.value === "peak" ? "peak" : "speed";
      state.season = form.elements.season.value || "current";
      state.region = form.elements.region.value || "";
      state.verified = form.elements.verified.checked;
      // 榜单列表按地区和赛季给：这两个变了，先换列表再读榜
      if (state.region + "|" + state.season !== before) {
        loadBoards().then(function () { renderChips(); loadBoard(); }, function () { loadBoard(); });
      } else {
        loadBoard();
      }
    });

    body.addEventListener("click", function (event) {
      if (event.target.closest("[data-retry]")) { loadStats(); start(); }
    });

    copy.addEventListener("click", function () { copyText(location.href.replace(/[?&]demo=1/, "").replace(/\?$/, ""), copy); });

    syncForm();
    loadStats();
    start();
  }

  /* ── 个人主页 ─────────────────────────────────────────────────────── */

  var ICONS = {
    website: '<svg aria-hidden="true" width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4"><circle cx="8" cy="8" r="6.3"/><path d="M1.8 8h12.4M8 1.7c1.8 1.8 2.6 3.9 2.6 6.3S9.8 12.5 8 14.3C6.2 12.5 5.4 10.4 5.4 8S6.2 3.5 8 1.7z"/></svg>',
    github: '<svg aria-hidden="true" width="14" height="14" viewBox="0 0 16 16" fill="currentColor"><path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z"/></svg>',
    x: '<svg aria-hidden="true" width="13" height="13" viewBox="0 0 16 16" fill="currentColor"><path d="M12.2 1h2.3L9.5 6.8 15.4 15h-4.6L7.2 10.2 3 15H.7l5.4-6.2L.4 1h4.7l3.3 4.4L12.2 1zm-.8 12.6h1.3L4.5 2.3H3.1l8.3 11.3z"/></svg>',
  };
  var COPY_ICON = '<svg aria-hidden="true" width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="5.5" y="5.5" width="8" height="8" rx="1.8"/><path d="M10.5 3.5v-.3A1.7 1.7 0 0 0 8.8 1.5H3.2a1.7 1.7 0 0 0-1.7 1.7v5.6a1.7 1.7 0 0 0 1.7 1.7h.3"/></svg>';

  function readUsername() {
    var match = location.pathname.match(/\/@([^\/]+)\/?$/);
    var raw = match ? match[1] : params.get("user") || "";
    try { raw = decodeURIComponent(raw); } catch (e) { /* 原样用 */ }
    return raw.trim().replace(/^@/, "").toLowerCase();
  }

  function setHead(user) {
    var head = document.head;
    function link(rel, href, lang) {
      var el = document.createElement("link");
      el.rel = rel;
      el.href = href;
      if (lang) el.hreflang = lang;
      head.appendChild(el);
    }
    function meta(attr, key, value) {
      var el = head.querySelector("meta[" + attr + '="' + key + '"]');
      if (!el) { el = document.createElement("meta"); el.setAttribute(attr, key); head.appendChild(el); }
      el.setAttribute("content", value);
    }
    var en = "https://quota.run/@" + user.username;
    var zh = "https://quota.run/zh/@" + user.username;
    var name = (user.displayName || user.username) + " (@" + user.username + ")";
    document.title = name + " · Quota Run";
    link("canonical", ZH ? zh : en);
    link("alternate", en, "en");
    link("alternate", zh, "zh-CN");
    link("alternate", en, "x-default");
    meta("property", "og:url", ZH ? zh : en);
    meta("property", "og:title", name + " · Quota Run");
    if (user.bio) {
      meta("name", "description", user.bio);
      meta("property", "og:description", user.bio);
    }
  }

  function profileLangLink(username) {
    each(document.querySelectorAll("a.run-lang"), function (a) {
      var href;
      if (/\/@[^\/]+\/?$/.test(location.pathname)) href = (ZH ? "/@" : "/zh/@") + encodeURIComponent(username) + location.search;
      else href = a.getAttribute("href").replace(/[?#].*$/, "") + location.search;
      a.setAttribute("href", href);
    });
  }

  function statsList(stats, cls) {
    var s = stats || {};
    return '<dl class="run-stats ' + (cls || "") + '">' +
      [[t("Runs", "轮次"), s.runs], [t("Verified runs", "已验证轮次"), s.verifiedRuns], [t("Providers", "服务商"), s.providers], [t("Active days", "活跃天数"), s.activeDays]]
        .map(function (pair) { return "<div><dt>" + pair[0] + "</dt><dd>" + number(pair[1]) + "</dd></div>"; }).join("") +
      "</dl>";
  }

  // 接口给的 percentile 就是 ceil(名次 ÷ 人数 × 100)，没有时自己算
  function topPercent(best) {
    var p = Number(best.percentile);
    if (p >= 1) return Math.round(p);
    var rank = Number(best.rank), runners = Number(best.runners);
    return rank && runners ? Math.max(1, Math.ceil(rank / runners * 100)) : null;
  }

  function bestCard(best) {
    var peak = best.unit ? best.unit === "percent" : best.metric === "peak";
    var achieved = toDate(best.achievedAt);
    var top = topPercent(best);
    var rank = Number(best.rank);
    var rankLine = rank
      ? (ZH
        ? "第 <b>" + rank + "</b> 名" + (best.runners ? " · 共 " + number(best.runners) + " 人" : "") + (top ? " · 前 " + top + "%" : "")
        : "<b>#" + rank + "</b>" + (best.runners ? " of " + number(best.runners) : "") + (top ? " · Top " + top + "%" : ""))
      : t("Not ranked", "未上榜");
    // 名次是跨赛季、跨地区、跨级别算的，所以链到「全部时间」那张榜
    return '<a class="run-best' + (rank && rank <= 3 ? " is-podium" : "") + '" href="' + esc(boardHref(best, best.metric, "all")) + '">' +
      '<span class="run-best__head">' + logo(best.provider, 24) +
      '<span><b>' + esc(boardName(best)) + "</b><small>" + esc(windowLabel(best.windowSeconds, best.windowKey, best.windowTitle)) + " · " + esc(metricLabel(best.metric)) + "</small></span></span>" +
      '<span class="run-best__value">' + esc(peak ? percent(best.value) : duration(best.value)) + "</span>" +
      '<span class="run-best__rank">' + rankLine + "</span>" +
      '<span class="run-best__foot">' + tierCell(best.tier, best.accountVerified) + '<span class="run-dim">' + (achieved ? timeTag(achieved) : esc(seasonLabel(best.season))) + "</span></span></a>";
  }

  function projectCard(project) {
    var url = safeLink("website", project.url);
    var github = safeLink("github", project.github);
    var built = (project.builtWith || []).filter(function (id) { return typeof id === "string"; });
    var name = esc(project.name || (url ? hostOf(url) : ""));
    return '<article class="run-project">' +
      "<h3>" + (url ? '<a href="' + esc(url.href) + '" rel="nofollow ugc noopener">' + name + '<span class="run-ext" aria-hidden="true">↗</span></a>' : name) + "</h3>" +
      (project.description ? "<p>" + esc(project.description) + "</p>" : "") +
      (url ? '<p class="run-project__host">' + esc(hostOf(url)) + "</p>" : "") +
      '<div class="run-project__foot">' +
      (built.length
        ? '<span class="run-built"><span>' + t("Built with", "用到的 AI") + "</span>" +
          built.map(function (id) { return '<span class="run-built__item" title="' + esc(providerName(id)) + '">' + logo(id, 18) + '<span class="sr-only">' + esc(providerName(id)) + "</span></span>"; }).join("") + "</span>"
        : "<span></span>") +
      (github ? '<a class="run-project__gh" href="' + esc(github.href) + '" rel="nofollow ugc noopener">' + ICONS.github + "GitHub</a>" : "") +
      "</div></article>";
  }

  function runsTable(runs) {
    var now = Date.now();
    var rows = runs.map(function (run) {
      var reset = toDate(run.resetsAt);
      var live = reset && reset.getTime() > now && run.secondsTo100 == null;
      var when = toDate(run.completedAt) || toDate(run.lastObservedAt) || toDate(run.observedAt) || reset;
      var board = { provider: run.provider, planLabel: run.planLabel || run.plan };
      return "<tr>" +
        '<td class="rr-board"><span class="run-boardcell">' + logo(run.provider, 20) + "<span><b>" + esc(boardName(board)) + "</b><small>" +
        esc(windowLabel(run.windowSeconds, run.windowKey, run.windowTitle)) + "</small></span></span></td>" +
        '<td class="rr-peak"><span class="run-value">' + (run.peakPercent == null ? "—" : esc(percent(run.peakPercent))) + "</span></td>" +
        '<td class="rr-full">' + (live ? '<span class="run-live"><i aria-hidden="true"></i>' + t("In progress", "进行中") + "</span>"
          : run.secondsTo100 == null ? '<span class="run-dim">—</span>' : '<span class="run-value">' + esc(duration(run.secondsTo100)) + "</span>") + "</td>" +
        '<td class="rr-tier">' + tierCell(run.tier, run.accountVerified) + "</td>" +
        '<td class="rr-when">' + timeTag(when) + "</td></tr>";
    }).join("");
    return '<div class="run-panel"><div class="run-table-wrap"><table class="run-table run-table--runs"><thead><tr>' +
      '<th scope="col" class="rr-board">' + t("Board", "榜单") + '</th><th scope="col" class="rr-peak">' + t("Peak", "峰值") +
      '</th><th scope="col" class="rr-full">' + t("Time to 100%", "用满用时") + '</th><th scope="col" class="rr-tier">' + t("Tier", "级别") +
      '</th><th scope="col" class="rr-when">' + t("When", "时间") + "</th></tr></thead><tbody>" + rows + "</tbody></table></div></div>";
  }

  function renderProfile(main, user) {
    setHead(user);
    var links = user.links || {};
    var linkItems = ["website", "github", "x"].map(function (kind) {
      var url = safeLink(kind, links[kind]);
      if (!url) return "";
      var label = kind === "website" ? hostOf(url) : kind === "github" ? "github.com" + url.pathname.replace(/\/$/, "") : "@" + url.pathname.replace(/^\/|\/$/g, "");
      return '<li><a href="' + esc(url.href) + '" rel="me nofollow ugc noopener">' + ICONS[kind] + "<span>" + esc(label) + "</span></a></li>";
    }).join("");
    var joined = toDate(user.joinedAt);
    var meta = ["@" + esc(user.username)];
    if (regionLabel(user.region)) meta.push(esc(regionLabel(user.region)));
    if (joined) meta.push(ZH ? esc(MONTH_FORMAT.format(joined)) + " 加入" : "Joined " + esc(MONTH_FORMAT.format(joined)));
    var share = "quota.run/@" + user.username;

    var bests = user.bests || [];
    var projects = user.projects || [];
    var recent = user.recent || [];

    main.innerHTML =
      '<section class="run-me">' +
        '<div class="run-me__id">' + avatar(user, "run-avatar--xl") +
          '<div class="run-me__names"><p class="run-eyebrow"><i aria-hidden="true"></i>' + t("Quota Run profile", "Quota Run 主页") + "</p>" +
          "<h1>" + esc(user.displayName || user.username) + "</h1>" +
          '<p class="run-me__meta">' + meta.map(function (m) { return "<span>" + m + "</span>"; }).join("") + "</p></div>" +
        "</div>" +
        (user.bio ? '<p class="run-me__bio">' + esc(user.bio) + "</p>" : "") +
        (linkItems ? '<ul class="run-me__links">' + linkItems + "</ul>" : "") +
        '<div class="run-share">' +
          '<p class="run-share__label">' + t("Share this profile", "分享这个主页") + "</p>" +
          '<div class="run-share__row"><code>' + esc(share) + "</code>" +
          '<button type="button" class="run-copy" id="shareCopy" data-done="' + t("Copied", "已复制") + '">' + COPY_ICON + "<span>" + t("Copy", "复制") + "</span></button></div>" +
          '<p class="run-share__hint">' + t("Readings from one ranked Mac, results worked out by the server.", "成绩只取一台计分 Mac 的读数，由服务器计算。") + "</p>" +
        "</div>" +
      "</section>" +
      statsList(user.stats, "run-stats--profile") +
      '<section class="run-sec" aria-labelledby="bestsHeading"><div class="run-sec__head"><h2 id="bestsHeading">' + t("Personal bests", "最好成绩") + "</h2>" +
        '<a class="run-more" href="' + esc(ROOT + (ZH ? "zh/" : "") + (LOCAL ? "index.html" : "") + (DEMO ? "?demo=1" : "")) + '">' + t("All boards →", "全部榜单 →") + "</a></div>" +
        (bests.length ? '<div class="run-bests">' + bests.map(bestCard).join("") + "</div>"
          : stateBox("empty", t("No ranked runs yet", "还没有上榜的成绩"), t("Bests show up here after the first full window from the ranked Mac.", "计分的那台 Mac 跑完第一个额度窗口后，成绩会出现在这里。"), "")) +
      "</section>" +
      (projects.length
        ? '<section class="run-sec" aria-labelledby="projectsHeading"><div class="run-sec__head"><h2 id="projectsHeading">' + t("Projects", "在做的项目") + "</h2></div>" +
          '<div class="run-projects">' + projects.map(projectCard).join("") + "</div></section>"
        : "") +
      '<section class="run-sec" aria-labelledby="recentHeading"><div class="run-sec__head"><h2 id="recentHeading">' + t("Recent runs", "最近几轮") + "</h2></div>" +
        (recent.length ? runsTable(recent) : stateBox("empty", t("No runs yet", "还没有记录"), "", "")) +
      "</section>";

    var copy = $("shareCopy");
    if (copy) copy.addEventListener("click", function () { copyText("https://" + share, copy); });
  }

  function notFound(main, username) {
    document.title = t("Runner not found · Quota Run", "找不到这个用户 · Quota Run");
    var robots = document.createElement("meta");
    robots.name = "robots";
    robots.content = "noindex";
    document.head.appendChild(robots);
    main.innerHTML = '<section class="run-404">' +
      '<p class="run-404__code">404</p>' +
      "<h1>" + (username
        ? t("No runner called ", "没有叫 ") + '<span class="run-404__name">@' + esc(username) + "</span>" + t("", " 的用户")
        : t("Which runner?", "要看谁的主页？")) + "</h1>" +
      "<p>" + (username
        ? t("The link may have a typo, or they left Quota Run — leaving deletes the profile with everything else.", "可能链接拼错了，也可能对方已经退出 Quota Run——退出时主页和其他数据一起删除。")
        : t("Profiles live at quota.run/@username.", "个人主页的地址是 quota.run/@用户名。")) + "</p>" +
      '<a class="run-btn" href="' + esc(ROOT + (ZH ? "zh/" : "") + (LOCAL ? "index.html" : "") + (DEMO ? "?demo=1" : "")) + '">' + t("See the leaderboard", "去看排行榜") + "</a>" +
      "</section>";
  }

  function profilePage() {
    var main = $("profile");
    var username = readUsername();
    profileLangLink(username);
    function done() { setBusy(main, false); }
    if (!USERNAME.test(username)) { notFound(main, username); done(); return; }
    function load() {
      var request = DEMO ? Promise.resolve(demo.user(username)) : api("/users/" + encodeURIComponent(username));
      request.then(function (user) {
        if (!user) throw Object.assign(new Error("not found"), { status: 404 });
        renderProfile(main, user);
        done();
      }).catch(function (error) {
        if (error && error.status === 404) notFound(main, username);
        else main.innerHTML = errorBox(t("Couldn't load this profile.", "主页没加载出来。"));
        done();
      });
    }
    main.addEventListener("click", function (event) {
      if (event.target.closest("[data-retry]")) { setBusy(main, true); load(); }
    });
    load();
  }

  /* ── 示例数据（?demo=1）────────────────────────────────────────────
   * 形状照接口契约；数字按种子生成，每次打开都一样。时间相对「现在」，
   * 所以「3 小时前」永远是真的三小时前。 */
  var demo = (function () {
    var NOW = Math.floor(Date.now() / 1000);
    var WEEK = weekStart(Date.now());

    var PEOPLE = [
      ["peter", "Peter", "global"], ["linxiao", "林晓", "china"], ["mika", "Mika Laine", "global"],
      ["sora", "Sora Tanaka", "global"], ["hweiss", "Hannah Weiss", "global"], ["chenyu", "陈宇", "china"],
      ["devon", "Devon Park", "global"], ["ayaan", "Ayaan Rao", "global"], ["juno", "juno", "global"],
      ["kasia", "Kasia Nowak", "global"], ["wangwei", "王玮", "china"], ["tomas", "Tomás Ruiz", "global"],
      ["rin_dev", "Rin", "global"], ["oskar", "Oskar Berg", "global"], ["lea-m", "Léa Martin", "global"],
      ["zhouyu", "周屿", "china"], ["yuki", "Yuki Mori", "global"], ["baozi", "包子", "china"],
    ];

    var BOARDS = [
      { provider: "codex", plan: "pro20x", planLabel: "Pro 20x", windowKey: "604800:", windowSeconds: 604800, windowTitle: "Weekly window", runners: 386, fastest: 98460, me: 4 },
      { provider: "claude", plan: "max20x", planLabel: "Max 20x", windowKey: "18000:", windowSeconds: 18000, windowTitle: "5-hour window", runners: 342, fastest: 4380, me: 7 },
      { provider: "claude", plan: "max20x", planLabel: "Max 20x", windowKey: "604800:", windowSeconds: 604800, windowTitle: "Weekly window", runners: 211, fastest: 131400, me: 2 },
      { provider: "cursor", plan: "proplus", planLabel: "Pro+", windowKey: "2592000:", windowSeconds: 2592000, windowTitle: "Monthly window", runners: 57, fastest: 386000, me: 3 },
    ];

    function rng(seedText) {
      var a = hue(seedText) * 7919 + seedText.length;
      return function () {
        a = (a + 0x6d2b79f5) | 0;
        var x = Math.imul(a ^ (a >>> 15), 1 | a);
        x = (x + Math.imul(x ^ (x >>> 7), 61 | x)) ^ x;
        return ((x ^ (x >>> 14)) >>> 0) / 4294967296;
      };
    }

    function publicBoard(b, region) {
      var share = region === "china" ? 0.31 : region === "global" ? 0.69 : 1;
      return { provider: b.provider, plan: b.plan, planLabel: b.planLabel, windowKey: b.windowKey, windowSeconds: b.windowSeconds, windowTitle: b.windowTitle, runners: Math.round(b.runners * share), season: isoWeek(Date.now()) };
    }

    function accountVerified(username, provider) {
      return username === "peter" ? provider !== "claude" : hue(username + ":" + provider) % 3 !== 0;
    }

    function findBoard(o) {
      return BOARDS.filter(function (b) { return b.provider === o.provider && b.plan === o.plan && b.windowKey === o.window; })[0];
    }

    function leaderboard(o) {
      var b = findBoard(o);
      if (!b) return { board: { provider: o.provider, plan: o.plan, planLabel: o.plan, windowKey: o.window, windowSeconds: Number(String(o.window).split(":")[0]) }, season: o.season, metric: o.metric, entries: [], updatedAt: NOW - 140 };
      var season = o.season === "current" ? "current" : o.season === "all" ? "all" : "last";
      var rand = rng(b.provider + b.plan + b.windowKey + o.metric + season);
      var people = PEOPLE.slice(1);
      for (var i = people.length - 1; i > 0; i--) {
        var j = Math.floor(rand() * (i + 1));
        var swap = people[i]; people[i] = people[j]; people[j] = swap;
      }
      people = people.slice(0, 14);
      people.splice(season === "current" && o.metric === "speed" ? b.me - 1 : Math.floor(rand() * 9), 0, PEOPLE[0]);

      var span = season === "current" ? Math.max(3600, NOW - WEEK) : season === "last" ? 604800 : 60 * 86400;
      var from = season === "current" ? WEEK : season === "last" ? WEEK - 604800 : NOW - span;
      var value = b.fastest * (season === "last" ? 1.08 : season === "all" ? 0.84 : 1);
      var peak = 100;
      var entries = people.map(function (p, index) {
        var e = { username: p[0], displayName: p[1], region: p[2] };
        if (o.metric === "peak") {
          if (index >= 5) peak = Math.max(62, peak - (0.5 + Math.floor(rand() * 5) * 0.5));
          e.value = peak;
          e.unit = "percent";
          e.peakPercent = peak;
        } else {
          if (index) value *= 1.025 + rand() * 0.08;
          e.value = Math.round(value);
          e.unit = "seconds";
          e.peakPercent = 100;
        }
        e.tier = p[0] === "peter" || rand() < 0.7 ? "verified" : "standard";
        e.achievedAt = Math.round(from + rand() * span);
        // 不动随机序列（别的数字保持原样）：按人名和服务商定下来；peter 的 Claude 账号只绑定、没核实，和示例账号页一致
        e.accountVerified = accountVerified(p[0], b.provider);
        return e;
      });
      // 峰值并列时，先到的排前面
      if (o.metric === "peak") {
        entries.sort(function (x, y) { return y.value - x.value || x.achievedAt - y.achievedAt; });
      }
      entries = entries.filter(function (e) {
        return (!o.region || e.region === o.region) && (o.tier !== "verified" || e.tier === "verified");
      });
      entries.forEach(function (e, index) { e.rank = index + 1; delete e.region; });
      return { board: publicBoard(b, o.region), season: o.season, metric: o.metric, entries: entries, updatedAt: NOW - 140 };
    }

    function boards(region) {
      return { boards: BOARDS.map(function (b) { return publicBoard(b, region); }) };
    }

    function stats() {
      return { users: 1284, runs: 9312, verifiedRuns: 6127, providers: 9, updatedAt: NOW - 140 };
    }

    function run(board, peak, to100, tier, endAgo, extra) {
      var b = BOARDS[board];
      return Object.assign({
        provider: b.provider, plan: b.plan, planLabel: b.planLabel, windowKey: b.windowKey, windowSeconds: b.windowSeconds,
        peakPercent: peak, secondsTo50: to100 ? Math.round(to100 * 0.46) : null, secondsTo90: to100 ? Math.round(to100 * 0.88) : null,
        secondsTo100: to100, tier: tier, completedAt: to100 ? NOW - endAgo : null, lastObservedAt: NOW - endAgo,
        resetsAt: NOW - endAgo + (to100 ? 0 : 3600), season: isoWeek((NOW - endAgo) * 1000), accountVerified: false,
      }, extra || {});
    }

    function best(board, metric, value, rank, tier, verified) {
      var b = BOARDS[board];
      var runners = b.runners;
      return {
        provider: b.provider, plan: b.plan, planLabel: b.planLabel, windowKey: b.windowKey, windowSeconds: b.windowSeconds, windowTitle: b.windowTitle,
        metric: metric, unit: metric === "peak" ? "percent" : "seconds", value: value, rank: rank, runners: runners,
        percentile: Math.max(1, Math.ceil(rank / runners * 100)), tier: tier, accountVerified: !!verified, season: isoWeek(Date.now()),
      };
    }

    // 示例主页上的最好成绩取自示例榜单里同一个人的那一行，两页对得上
    function mine(board, metric) {
      var b = BOARDS[board];
      // 主页上的名次跨赛季算，对应「全部时间」那张榜
      var rows = leaderboard({ provider: b.provider, plan: b.plan, window: b.windowKey, metric: metric, season: "all", region: "", tier: "all" }).entries;
      var e = rows.filter(function (row) { return row.username === "peter"; })[0];
      return Object.assign(best(board, metric, e.value, e.rank, e.tier, e.accountVerified), { achievedAt: e.achievedAt });
    }

    function user(username) {
      if (username === "peter") {
        var bests = [mine(0, "speed"), mine(1, "speed"), mine(2, "peak"), mine(3, "speed")];
        return {
          username: "peter", displayName: "Peter", region: "global", joinedAt: NOW - 38 * 86400,
          bio: "Building QuotaBar. Burns a Codex week by Wednesday, mostly on purpose.",
          links: { website: "https://quota.bar", github: "gentpan", x: "" },
          stats: { runs: 86, verifiedRuns: 71, providers: 3, activeDays: 41 },
          bests: bests,
          // Codex 和 Cursor 账号核实过，Claude 账号只绑定（见 account.js 的示例账号）
          recent: [
            run(0, 64, null, "verified", 1800, { resetsAt: NOW + 3 * 86400 + 7200, completedAt: null, accountVerified: true }),
            run(1, 100, Math.round(bests[1].value * 1.09), "verified", 3 * 3600 + 600),
            run(1, 100, Math.round(bests[1].value * 1.24), "verified", 26 * 3600),
            run(1, 91, null, "standard", 2 * 86400 + 5400),
            run(3, 100, bests[3].value, "verified", 4 * 86400, { accountVerified: true }),
            run(2, 100, 412300, "verified", 6 * 86400 + 3600),
          ],
          projects: [
            { name: "QuotaBar", url: "https://quota.bar", github: "https://github.com/gentpan/QuotaBar", description: "Every AI coding limit, at a glance — in the macOS menu bar, the notch and on desktop cards.", builtWith: ["codex", "claude"] },
            { name: "Tidewire", url: "https://tidewire.example", github: "", description: "A small sync engine for local-first notes. Conflict-free merges, no server required.", builtWith: ["claude", "cursor"] },
            { name: "shiori-cli", url: "https://shiori.example/cli", github: "https://github.com/example/shiori-cli", description: "Bookmarks from the terminal, searchable offline, synced as plain Markdown.", builtWith: ["codex"] },
          ],
        };
      }
      var person = PEOPLE.filter(function (p) { return p[0] === username; })[0];
      if (!person) return null;
      var rand = rng(username);
      var first = Math.floor(rand() * BOARDS.length);
      var second = (first + 1 + Math.floor(rand() * (BOARDS.length - 1))) % BOARDS.length;
      var r1 = 1 + Math.floor(rand() * 15), r2 = 3 + Math.floor(rand() * 40);
      return {
        username: person[0], displayName: person[1], region: person[2], joinedAt: NOW - Math.round((10 + rand() * 50) * 86400),
        bio: "", links: {},
        stats: { runs: 12 + Math.floor(rand() * 60), verifiedRuns: 8 + Math.floor(rand() * 30), providers: 2, activeDays: 6 + Math.floor(rand() * 30) },
        bests: [
          best(first, "speed", Math.round(BOARDS[first].fastest * (1.05 + r1 * 0.04)), r1, rand() < 0.7 ? "verified" : "standard", accountVerified(username, BOARDS[first].provider)),
          best(second, "peak", 100 - (r2 > 10 ? 1.5 : 0), r2, "verified", accountVerified(username, BOARDS[second].provider)),
        ],
        recent: [
          run(first, 100, Math.round(BOARDS[first].fastest * 1.2), "verified", 5 * 3600, { accountVerified: accountVerified(username, BOARDS[first].provider) }),
          run(second, 97.5, null, "standard", 2 * 86400, { accountVerified: accountVerified(username, BOARDS[second].provider) }),
          run(first, 100, Math.round(BOARDS[first].fastest * 1.31), "verified", 5 * 86400, { accountVerified: accountVerified(username, BOARDS[first].provider) }),
        ],
        projects: [],
      };
    }

    return { leaderboard: leaderboard, boards: boards, stats: stats, user: user };
  })();

  // 登录、账号、连接三页由 account.js 画，共用这里的格式、链接、会话和示例开关
  window.QuotaRun = {
    ZH: ZH, ROOT: ROOT, V: V, API: API, DEMO: DEMO, LOCAL: LOCAL, PAGE: PAGE, PROVIDERS: PROVIDERS, USERNAME: USERNAME,
    t: t, esc: esc, each: each, $: $, number: number, toDate: toDate, relative: relative, timeTag: timeTag,
    providerName: providerName, logo: logo, avatar: avatar, regionLabel: regionLabel, safeLink: safeLink,
    stateBox: stateBox, copyText: copyText, request: request, pageHref: pageHref, homeHref: homeHref,
    profileHref: profileHref, currentPath: currentPath, session: session, renderAccountLink: renderAccountLink, demoSession: demoSession,
    FULL_FORMAT: FULL_FORMAT, YEAR_FORMAT: YEAR_FORMAT, ICONS: ICONS, ACCOUNT_ICON: ACCOUNT_ICON, accountVerifiedText: accountVerifiedText,
  };

  accountLink();
  if (PAGE === "leaderboard") leaderboardPage();
  else if (PAGE === "profile") profilePage();
})();

/* Quota Run（quota.run）的公共部分：每一页都先加载它。
 *
 * 管的事：页面语言与站点根目录、格式（时长、百分比、日期）、服务商名和 logo、头像与徽章、
 * 站内链接（本地 file:// 预览没有 Caddy 的改写，链接改走 .html 文件）、公开接口与登录接口、
 * 顶栏右侧的「登录 / @username」、语言切换记住选择、复制链接，以及 ?demo=1 的示例数据
 * （demo.js 只在示例模式下按需加载，线上访客不下载它）。
 * 契约见 docs/quota-run.md。没有依赖，没有构建步骤。
 */
(function () {
  "use strict";

  var ZH = /^zh/i.test(document.documentElement.lang);
  var script = document.currentScript;
  var SRC = script ? script.src : "";
  // 站点根目录和资源指纹都从脚本自己的地址取：中文页在下一层，/@username 又是改写出来的路径
  var ROOT = SRC.replace(/common\.js(\?.*)?$/, "");
  var V = (SRC.match(/\?v=[A-Za-z0-9]+/) || [""])[0];
  var API = "/api/v1";
  var params = new URLSearchParams(location.search);
  var DEMO = params.get("demo") === "1";
  var PAGE = document.body.getAttribute("data-run-page");
  var LOCAL = location.protocol === "file:" || /^(localhost|127\.0\.0\.1|\[::1\])$/.test(location.hostname);
  var USERNAME = /^[a-z0-9][a-z0-9_-]{2,19}$/;
  var SHARE = "https://quota.run/" + (ZH ? "zh/" : "");
  // 示例模式下跟着链接走的开关：空榜、未登录、接口出错
  var DEMO_KEEP = ["empty", "session", "fail"];

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
  function has(n) { return n != null && n !== "" && !isNaN(n); }
  function pad(n) { return (n < 10 ? "0" : "") + n; }

  // 成绩的写法和设计稿一致：「1d 03:21」「16:02」（小时:分钟），带秒「1d 03:21:08」
  function clock(seconds, withSeconds) {
    if (!has(seconds)) return "—";
    var s = Math.max(0, Math.round(Number(seconds)));
    if (!withSeconds) s = Math.round(s / 60) * 60;
    var d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60);
    var tail = withSeconds ? ":" + pad(s % 60) : "";
    return d ? d + "d " + pad(h) + ":" + pad(m) + tail : h + ":" + pad(m) + tail;
  }

  // 分段用时（到 50%、到 90%、50 → 90%）照设计稿写成总小时数「26:02」；超过 99 小时才换成「5d 03:10」
  function hours(seconds) {
    if (!has(seconds)) return "—";
    var m = Math.round(Math.max(0, Number(seconds)) / 60);
    return m >= 100 * 60 ? clock(seconds) : Math.floor(m / 60) + ":" + pad(m % 60);
  }

  // 差距：「+1:29」「−0:12」；带秒「+1:29:16」
  function gap(seconds, withSeconds) {
    if (!has(seconds)) return "—";
    var s = Math.round(Number(seconds));
    return (s < 0 ? "−" : "+") + clock(Math.abs(s), withSeconds);
  }

  // 服务商对比里的中位数：「3d 20h」，不到一天「3:33」
  function short(seconds) {
    if (!has(seconds)) return "—";
    var s = Math.max(0, Math.round(Number(seconds)));
    var d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600);
    return d ? d + "d " + pad(h) + "h" : clock(s);
  }

  // 大概多久：「3h」「45m」「1d 2h」；中文「3 小时」「45 分钟」「1 天 2 小时」
  function approx(seconds) {
    var s = Math.max(0, Math.round(Math.abs(Number(seconds) || 0)));
    var d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60);
    if (d) return ZH ? d + " 天" + (h ? " " + h + " 小时" : "") : d + "d" + (h ? " " + h + "h" : "");
    if (h) { h = Math.round(s / 3600); return ZH ? h + " 小时" : h + "h"; }
    if (m) return ZH ? m + " 分钟" : m + "m";
    return ZH ? s + " 秒" : s + "s";
  }

  function percent(value, digits) {
    if (!has(value)) return "—";
    var v = Math.round(Number(value) * 10) / 10;
    return (v % 1 && digits !== 0 ? v.toFixed(1) : String(Math.round(v))) + "%";
  }

  function share(fraction) {
    return has(fraction) ? Math.round(Number(fraction) * 100) + "%" : "—";
  }

  // 接口里的时间是 Unix 秒；也接受毫秒和 ISO 字符串
  function toDate(value) {
    if (value == null || value === "") return null;
    var n = Number(value);
    var date = isNaN(n) ? new Date(value) : new Date(n < 1e12 ? n * 1000 : n);
    return isNaN(date.getTime()) ? null : date;
  }

  var LOCALE = ZH ? "zh-CN" : "en-US";
  var DAY_FORMAT = new Intl.DateTimeFormat(LOCALE, { month: ZH ? "long" : "short", day: "numeric" });
  var YEAR_FORMAT = new Intl.DateTimeFormat(LOCALE, { year: "numeric", month: ZH ? "long" : "short", day: "numeric" });
  var MONTH_FORMAT = new Intl.DateTimeFormat(LOCALE, { year: "numeric", month: ZH ? "long" : "short" });
  var FULL_FORMAT = new Intl.DateTimeFormat(LOCALE, { dateStyle: "medium", timeStyle: "short" });
  var WEEKDAY_FORMAT = new Intl.DateTimeFormat(LOCALE, { weekday: "short" });

  // 赛道右侧的小字：本周、上周写「周二 03:21」，全部赛季写「9月8日 03:21」
  function moment(date, withDate) {
    if (!date) return "";
    var hm = pad(date.getHours()) + ":" + pad(date.getMinutes());
    return (withDate ? DAY_FORMAT.format(date) : WEEKDAY_FORMAT.format(date)) + " " + hm;
  }

  function relative(date) {
    if (!date) return "—";
    var diff = (Date.now() - date.getTime()) / 1000;
    if (diff < 60) return t("just now", "刚刚");
    if (diff < 3600) return ZH ? Math.floor(diff / 60) + " 分钟前" : Math.floor(diff / 60) + " min ago";
    if (diff < 86400) return ZH ? Math.floor(diff / 3600) + " 小时前" : Math.floor(diff / 3600) + " h ago";
    if (diff < 7 * 86400) return ZH ? Math.floor(diff / 86400) + " 天前" : Math.floor(diff / 86400) + " d ago";
    return (date.getFullYear() === new Date().getFullYear() ? DAY_FORMAT : YEAR_FORMAT).format(date);
  }

  function timeTag(date, text) {
    if (!date) return '<span class="dim">—</span>';
    return '<time datetime="' + date.toISOString() + '" title="' + esc(FULL_FORMAT.format(date)) + '">' + esc(text || relative(date)) + "</time>";
  }

  // ISO-8601 周（UTC），赛季就是它：2026-W37
  function isoWeek(ms) {
    var d = new Date(ms);
    var day = d.getUTCDay() || 7;
    var thursday = Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate() + 4 - day);
    var year = new Date(thursday).getUTCFullYear();
    var week = Math.ceil(((thursday - Date.UTC(year, 0, 1)) / 86400000 + 1) / 7);
    return year + "-W" + pad(week);
  }
  function weekStart(ms) {
    var d = new Date(ms);
    var day = d.getUTCDay() || 7;
    return Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate() - day + 1) / 1000;
  }

  // 发给接口的赛季：「上周」直接写成那一周，新旧服务端都认
  function seasonParam(season) {
    if (season === "last") return isoWeek(Date.now() - 7 * 86400000);
    return season === "all" ? "all" : "current";
  }

  /* ── 服务商、窗口、头像、徽章 ──────────────────────────────────────── */

  function providerName(id) {
    var p = PROVIDERS[id];
    return p ? (ZH ? p.zh : p.en) : String(id || "");
  }

  // 浅色站点用应用里的浅色 logo；只有白色字形的（Cursor、Grok…）标成 light，用 CSS 反相成深色
  function logo(id, size) {
    size = size || 20;
    if (!PROVIDERS[id] || !/^[a-z0-9-]+$/.test(id)) {
      return '<span class="logo logo--letter logo--' + size + '" aria-hidden="true">' + esc(String(id || "?").charAt(0).toUpperCase()) + "</span>";
    }
    var tone = PROVIDERS[id].tone ? " is-" + PROVIDERS[id].tone : "";
    return '<img class="logo logo--' + size + tone + '" src="' + ROOT + "assets/logos/" + id + ".png" + V + '" alt="" width="' + size + '" height="' + size + '" decoding="async">';
  }

  // 窗口名从长度算，不用接口里那句英文 windowTitle：「Weekly」「周额度」「5 小时」；带范围的窗口把范围名接在后面
  function windowLabel(seconds, key, title) {
    var s = Number(seconds) || 0;
    var label;
    if (s === 604800) label = t("Weekly", "周额度");
    else if (s === 86400) label = t("Daily", "日额度");
    else if (s >= 28 * 86400 && s <= 31 * 86400) label = t("Monthly", "月额度");
    else if (s && s % 86400 === 0) label = ZH ? s / 86400 + " 天" : s / 86400 + "-day";
    else if (s && s % 3600 === 0) label = ZH ? s / 3600 + " 小时" : s / 3600 + "-hour";
    else if (s) label = approx(s);
    else label = title || "";
    var k = String(key || "");
    var scope = k.indexOf(":") >= 0 ? k.slice(k.indexOf(":") + 1) : "";
    return scope ? label + " · " + scope : label;
  }

  // 「7 天」「5 小时」「30 天」：说明文字里的窗口长度
  function windowSpan(seconds) {
    var s = Number(seconds) || 0;
    if (s >= 86400 && s % 86400 === 0) return ZH ? s / 86400 + " 天" : s / 86400 + "-day";
    if (s >= 3600 && s % 3600 === 0) return ZH ? s / 3600 + " 小时" : s / 3600 + "-hour";
    return approx(s);
  }

  function boardName(b) {
    return providerName(b.provider) + (b.planLabel ? " " + b.planLabel : "");
  }

  function boardKey(b) {
    return b.provider + ":" + (b.plan || "") + ":" + b.windowKey;
  }

  function initial(person) {
    var name = String(person.displayName || person.username || "?").trim();
    return ((Array.from ? Array.from(name)[0] : name.charAt(0)) || "?").toUpperCase();
  }

  function avatar(person, extra) {
    return '<span class="av' + (extra ? " " + extra : "") + '" aria-hidden="true">' + esc(initial(person)) + "</span>";
  }

  function tierTag(tier) {
    return tier === "verified"
      ? '<span class="tag tag--ok">' + t("Verified", "已验证") + "</span>"
      : '<span class="tag">' + t("Standard", "标准") + "</span>";
  }

  // 「账号已核实」：服务商账号的邮箱和这个人在 quota.run 上验证过的登录邮箱一致（accountVerified）。
  // 不是级别，只是名字或级别旁边一行小字；解释放在 title 里
  var ACCOUNT_ICON = '<svg aria-hidden="true" width="12" height="12" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><circle cx="6" cy="5" r="2.6"/><path d="M1.5 14c0-2.6 2-4.5 4.5-4.5 1.1 0 2.1.3 2.9 1"/><path d="m9.8 11.6 1.9 1.9 3.3-3.7"/></svg>';

  function accountVerifiedText() {
    return t("The provider account's email matches a verified sign-in on quota.run", "服务商账号的邮箱与 quota.run 上验证过的登录邮箱一致");
  }

  function accountMark(verified) {
    if (!verified) return "";
    return '<span class="acct" title="' + esc(accountVerifiedText()) + '">' + t("Account verified", "账号已核实") + "</span>";
  }

  function regionLabel(region) {
    return region === "china" ? t("China", "中国") : region === "global" ? t("Global", "国际") : "";
  }

  /* ── 链接 ─────────────────────────────────────────────────────────── */

  function query(pairs) {
    var q = new URLSearchParams();
    Object.keys(pairs).forEach(function (k) { if (pairs[k] !== "" && pairs[k] != null) q.set(k, pairs[k]); });
    // 榜单键里的冒号、对比名单里的逗号不转义，链接更好读
    return q.toString().replace(/%3A/gi, ":").replace(/%2C/gi, ",");
  }

  function demoPairs(pairs) {
    pairs = Object.assign({}, pairs || {});
    if (DEMO) {
      pairs.demo = "1";
      DEMO_KEEP.forEach(function (k) { if (params.get(k) && pairs[k] == null) pairs[k] = params.get(k); });
    }
    return pairs;
  }

  function profileHref(username) {
    var u = encodeURIComponent(username);
    var q = query(demoPairs({}));
    if (LOCAL) return ROOT + (ZH ? "zh/" : "") + "u.html?" + query(demoPairs({ user: username }));
    return (ZH ? "/zh/@" : "/@") + u + (q ? "?" + q : "");
  }

  function homeHref(pairs) {
    var q = query(demoPairs(pairs));
    return ROOT + (ZH ? "zh/" : "") + (LOCAL ? "index.html" : "") + (q ? "?" + q : "");
  }

  function boardHref(b, extra) {
    return homeHref(Object.assign({ board: boardKey(b) }, extra || {}));
  }

  // 登录、账号、连接、规则页的地址。线上 Caddy 把 /login 映射到 login.html；本地预览没有 Caddy，直接走文件
  function pageHref(page, pairs) {
    var q = query(demoPairs(pairs));
    var base = LOCAL ? ROOT + (ZH ? "zh/" : "") + page + ".html" : (ZH ? "/zh/" : "/") + page;
    return base + (q ? "?" + q : "");
  }

  function demoHref() {
    var q = new URLSearchParams(location.search);
    q.set("demo", "1");
    return location.href.replace(/[?#].*$/, "") + "?" + q.toString().replace(/%3A/gi, ":").replace(/%2C/gi, ",");
  }

  // 当前页的路径和查询串，登录回来时要回到这里
  function currentPath() {
    return location.pathname + location.search;
  }

  // 另一种语言的同一页；查询串由各页自己给
  function langHref(search) {
    var file = PAGE === "leaderboard" ? "index.html" : PAGE === "profile" ? "u.html" : PAGE + ".html";
    var base = LOCAL
      ? ROOT + (ZH ? "" : "zh/") + file
      : (ZH ? "/" : "/zh/") + (PAGE === "leaderboard" ? "" : PAGE === "profile" ? "u.html" : PAGE);
    return base + (search || "");
  }

  function setLangLinks(search) {
    each(document.querySelectorAll("a.run-lang"), function (a) { a.setAttribute("href", langHref(search)); });
  }

  // 主页上的链接，顺序与接口 links 的键一致。handle：从地址里取出显示用的账号名（取不出就显示平台名）
  var LINK_KINDS = [
    { kind: "website", en: "Website", zh: "网站" },
    { kind: "blog", en: "Blog", zh: "博客" },
    { kind: "github", en: "GitHub", zh: "GitHub", handle: /^\/([^\/]+)\/?$/ },
    { kind: "gitlab", en: "GitLab", zh: "GitLab", handle: /^\/([^\/]+)\/?$/ },
    { kind: "x", en: "X", zh: "X", handle: /^\/([^\/]+)\/?$/, at: true },
    { kind: "bluesky", en: "Bluesky", zh: "Bluesky", handle: /^\/profile\/([^\/]+)\/?$/, at: true },
    { kind: "mastodon", en: "Mastodon", zh: "Mastodon" },
    { kind: "linkedin", en: "LinkedIn", zh: "LinkedIn" },
    { kind: "youtube", en: "YouTube", zh: "YouTube" },
    { kind: "telegram", en: "Telegram", zh: "Telegram" },
    { kind: "huggingface", en: "Hugging Face", zh: "Hugging Face" },
    { kind: "bilibili", en: "Bilibili", zh: "哔哩哔哩" },
    { kind: "zhihu", en: "Zhihu", zh: "知乎" },
    { kind: "juejin", en: "Juejin", zh: "掘金" },
    { kind: "v2ex", en: "V2EX", zh: "V2EX" },
    { kind: "weibo", en: "Weibo", zh: "微博" },
    { kind: "xiaohongshu", en: "Xiaohongshu", zh: "小红书" },
  ];

  function linkKind(kind) {
    for (var i = 0; i < LINK_KINDS.length; i++) if (LINK_KINDS[i].kind === kind) return LINK_KINDS[i];
    return null;
  }

  function linkName(kind) {
    var k = linkKind(kind);
    return k ? t(k.en, k.zh) : String(kind || "");
  }

  // 主页上链接旁边的字：网站、博客写域名；GitHub、X 这类写账号名；其余写平台名
  function linkLabel(kind, url) {
    var k = linkKind(kind);
    if (kind === "website" || kind === "blog") return hostOf(url);
    if (kind === "mastodon") {
      var m = /^\/@([^\/]+)\/?$/.exec(url.pathname);
      if (m) return "@" + decodeURIComponent(m[1]) + "@" + url.host;
    }
    var match = k && k.handle ? k.handle.exec(url.pathname) : null;
    if (match) {
      var name = decodeURIComponent(match[1]);
      return k.at ? "@" + name : name;
    }
    return linkName(kind);
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

  /* ── 接口 ─────────────────────────────────────────────────────────── */

  function api(path) {
    return fetch(API + path, { headers: { Accept: "application/json" }, credentials: "omit" }).then(function (response) {
      return response.json().catch(function () { return null; }).then(function (body) {
        if (!response.ok) {
          var error = new Error((body && body.message) || "HTTP " + response.status);
          error.status = response.status;
          error.code = (body && body.error) || "";
          throw error;
        }
        return body;
      });
    });
  }

  // 示例数据只在 ?demo=1 时加载：demo.js 按接口的路径和查询串答复，形状照契约
  var demoLoad = null;
  function demo() {
    if (!demoLoad) {
      demoLoad = new Promise(function (resolve, reject) {
        if (window.QuotaRunDemo) { resolve(window.QuotaRunDemo); return; }
        var tag = document.createElement("script");
        tag.src = ROOT + "demo.js" + V;
        tag.onload = function () { resolve(window.QuotaRunDemo); };
        tag.onerror = function () { reject(new Error("demo.js didn't load")); };
        document.head.appendChild(tag);
      });
    }
    return demoLoad;
  }

  // 公开接口：真接口，或者示例
  function getJSON(path) {
    return DEMO ? demo().then(function (d) { return d.get(path); }) : api(path);
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

  function signedInUser(s) {
    return s && s.signedIn && !s.needsSignup && s.user && s.user.username ? s.user : null;
  }

  function renderAccountLink(s) {
    var link = $("runAccount");
    if (!link) return;
    var user = signedInUser(s);
    link.removeAttribute("aria-current");
    if (user) {
      link.innerHTML = avatar(user, "av--sm") + '<span class="nav__handle">@' + esc(user.username) + "</span>";
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

  // 顶栏和页内写死的站内链接：本地预览走 .html 文件；示例模式带着 demo=1 继续逛
  function localLinks() {
    each(document.querySelectorAll("a[data-local]"), function (a) {
      var file = a.getAttribute("data-local");
      var page = file.replace(/\.html$/, "");
      var hash = a.getAttribute("data-hash");
      a.setAttribute("href", (page === "index" ? homeHref() : pageHref(page)) + (hash ? "#" + hash : ""));
    });
  }

  // 切换语言：记住选择（英文页据此决定要不要跳去 /zh/），并停在同一个位置
  function langMemory() {
    each(document.querySelectorAll("a[data-lang]"), function (link) {
      link.addEventListener("click", function () {
        try { localStorage.setItem("qb-lang", link.getAttribute("data-lang")); } catch (e) { /* 忽略 */ }
        if (location.hash) link.setAttribute("href", link.getAttribute("href").replace(/#.*$/, "") + location.hash);
      });
    });
  }

  /* ── 小部件 ───────────────────────────────────────────────────────── */

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
      area.className = "sr-only";
      document.body.appendChild(area);
      area.select();
      try { document.execCommand("copy"); done(); } catch (e) { /* 复制不了就算了 */ }
      document.body.removeChild(area);
    }
    if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(text).then(done, fallback);
    else fallback();
  }

  function stateBox(kind, title, text, actions) {
    return '<div class="state state--' + kind + '"' + (kind === "error" ? ' role="alert"' : "") + ">" +
      '<p class="state__title">' + title + "</p>" +
      (text ? '<p class="state__text">' + text + "</p>" : "") +
      (actions ? '<div class="state__actions">' + actions + "</div>" : "") + "</div>";
  }

  function errorBox(title) {
    return stateBox("error", title,
      t("The Quota Run service didn't answer. It may be restarting, or not live yet.", "Quota Run 的服务没有响应，可能在重启，也可能还没上线。"),
      '<button type="button" class="btn" data-retry>' + t("Try again", "重试") + "</button>" +
      (DEMO ? "" : '<a class="link" href="' + esc(demoHref()) + '">' + t("Preview with demo data", "用示例数据预览") + "</a>"));
  }

  function setBusy(el, busy) { if (el) el.setAttribute("aria-busy", busy ? "true" : "false"); }

  /* ── 热力图：近 53 周，一格一天（个人主页的 token 用量和 GitHub 贡献共用） ── */

  var DAY_MS = 86400000;
  var HEAT = { cell: 12, step: 16, left: 32, top: 20 };
  var COMPACT = new Intl.NumberFormat(LOCALE, { notation: "compact", maximumFractionDigits: 1 });
  var CAL_FORMAT = new Intl.DateTimeFormat(LOCALE, { year: "numeric", month: ZH ? "long" : "short", day: "numeric", weekday: "short", timeZone: "UTC" });
  var CAL_SHORT = new Intl.DateTimeFormat(LOCALE, { month: ZH ? "long" : "short", day: "numeric", timeZone: "UTC" });
  var MONTH_SHORT = new Intl.DateTimeFormat(LOCALE, { month: "short", timeZone: "UTC" });
  var heatTips = {};
  var heatCount = 0;

  function compact(n) { return has(n) ? COMPACT.format(Number(n)) : "—"; }

  // 接口里的日期是不带时区的「2026-09-12」，按 UTC 零点换成毫秒来算，显示时也按 UTC 格式化
  function dayMs(date) {
    var m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(date || ""));
    return m ? Date.UTC(+m[1], +m[2] - 1, +m[3]) : NaN;
  }
  function dayKey(ms) { return new Date(ms).toISOString().slice(0, 10); }
  function calendarDate(date, short) { var ms = dayMs(date); return isNaN(ms) ? "" : (short ? CAL_SHORT : CAL_FORMAT).format(new Date(ms)); }

  // 画出来的范围：从 52 周前的星期一到 to 那天
  function heatRange(to) {
    var end = dayMs(to);
    if (isNaN(end)) end = Date.UTC(new Date().getFullYear(), new Date().getMonth(), new Date().getDate());
    var weekday = (new Date(end).getUTCDay() + 6) % 7;
    return { start: end - (weekday + 52 * 7) * DAY_MS, end: end };
  }

  // 范围里的合计、有数的天数、最长连续、当前连续（今天还是 0 就从昨天往回数）、单日最高
  function heatStats(values, to) {
    var range = heatRange(to);
    var total = 0, active = 0, longest = 0, run = 0, best = null;
    for (var ms = range.start; ms <= range.end; ms += DAY_MS) {
      var v = Number(values[dayKey(ms)]) || 0;
      total += v;
      if (v > 0) {
        active += 1;
        run += 1;
        longest = Math.max(longest, run);
        if (!best || v > best.value) best = { date: dayKey(ms), value: v };
      } else {
        run = 0;
      }
    }
    var current = 0;
    var day = range.end;
    if (!(Number(values[dayKey(day)]) > 0)) day -= DAY_MS;
    while (day >= range.start && Number(values[dayKey(day)]) > 0) { current += 1; day -= DAY_MS; }
    return { total: total, activeDays: active, longest: longest, current: current, best: best };
  }

  // values：{ "2026-09-12": 数 }；tip(date, value) 给悬停提示的文字；label 给读屏的一句话
  function heatmap(options) {
    var values = options.values || {};
    var range = heatRange(options.to);
    var id = "hm" + (++heatCount);
    heatTips[id] = options.tip;
    var positive = Object.keys(values).map(function (k) { return Number(values[k]); }).filter(function (v) { return v > 0; }).sort(function (a, b) { return a - b; });
    function quantile(p) { return positive[Math.floor(p * (positive.length - 1))]; }
    var cuts = positive.length ? [quantile(0.25), quantile(0.5), quantile(0.75)] : [];
    function level(v) {
      if (!(v > 0)) return 0;
      return v <= cuts[0] ? 1 : v <= cuts[1] ? 2 : v <= cuts[2] ? 3 : 4;
    }
    var weeks = Math.floor(Math.round((range.end - range.start) / DAY_MS) / 7) + 1;
    var width = HEAT.left + weeks * HEAT.step - (HEAT.step - HEAT.cell);
    var height = HEAT.top + 7 * HEAT.step - (HEAT.step - HEAT.cell);
    var parts = [];
    var lastLabel = -3;
    for (var w = 0; w < weeks; w++) {
      var monday = range.start + w * 7 * DAY_MS;
      for (var d = 0; d < 7; d++) {
        var ms = monday + d * DAY_MS;
        if (ms > range.end) break;
        var key = dayKey(ms);
        var date = new Date(ms);
        // 这一列里有某月 1 号就在上面写月份；第一列只在离下一个月份足够远时写
        if (date.getUTCDate() === 1 && w - lastLabel >= 3 && w < weeks - 1) {
          parts.push('<text class="hm__lbl" x="' + (HEAT.left + w * HEAT.step) + '" y="' + (HEAT.top - 8) + '">' + esc(ZH ? date.getUTCMonth() + 1 + "月" : MONTH_SHORT.format(date)) + "</text>");
          lastLabel = w;
        }
        var v = Number(values[key]) || 0;
        parts.push('<rect class="hm__c hm__c--' + level(v) + '" x="' + (HEAT.left + w * HEAT.step) + '" y="' + (HEAT.top + d * HEAT.step) + '" width="' + HEAT.cell + '" height="' + HEAT.cell + '" rx="2" data-d="' + key + '" data-v="' + v + '"></rect>');
      }
      if (w === 0 && lastLabel !== 0 && new Date(monday).getUTCDate() <= 10) {
        parts.unshift('<text class="hm__lbl" x="' + HEAT.left + '" y="' + (HEAT.top - 8) + '">' + esc(ZH ? new Date(monday).getUTCMonth() + 1 + "月" : MONTH_SHORT.format(new Date(monday))) + "</text>");
        lastLabel = 0;
      }
    }
    [[0, t("Mon", "一")], [2, t("Wed", "三")], [4, t("Fri", "五")]].forEach(function (row) {
      parts.push('<text class="hm__lbl" x="0" y="' + (HEAT.top + row[0] * HEAT.step + HEAT.cell - 2) + '">' + row[1] + "</text>");
    });
    var legend = [0, 1, 2, 3, 4].map(function (n) { return '<i class="hm__c hm__c--' + n + '"></i>'; }).join("");
    return '<div class="hm" data-hm="' + id + '">' +
      '<div class="hm__scroll"><svg class="hm__svg" role="img" aria-label="' + esc(options.label || "") + '" width="' + width + '" height="' + height + '" viewBox="0 0 ' + width + " " + height + '">' + parts.join("") + "</svg></div>" +
      '<div class="hm__foot">' + (options.note ? '<span class="hm__note">' + options.note + "</span>" : "<span></span>") +
      '<span class="hm__legend" aria-hidden="true"><span>' + t("Less", "少") + "</span>" + legend + "<span>" + t("More", "多") + "</span></span></div></div>";
  }

  // 画完以后：窄屏先滚到最近几周
  function heatmapReady(root) {
    each((root || document).querySelectorAll(".hm__scroll"), function (box) { box.scrollLeft = box.scrollWidth; });
  }

  var heatTip = null;
  function showHeatTip(cell) {
    var box = cell.closest("[data-hm]");
    var tip = box && heatTips[box.getAttribute("data-hm")];
    if (!tip) return;
    if (!heatTip) {
      heatTip = document.createElement("div");
      heatTip.className = "hm-tip";
      heatTip.setAttribute("role", "tooltip");
      document.body.appendChild(heatTip);
    }
    heatTip.innerHTML = tip(cell.getAttribute("data-d"), Number(cell.getAttribute("data-v")));
    heatTip.hidden = false;
    var r = cell.getBoundingClientRect();
    var w = heatTip.offsetWidth, h = heatTip.offsetHeight;
    var x = Math.max(8, Math.min(window.innerWidth - w - 8, r.left + r.width / 2 - w / 2));
    var y = r.top - h - 8 < 8 ? r.bottom + 8 : r.top - h - 8;
    heatTip.style.transform = "translate(" + Math.round(x) + "px," + Math.round(y) + "px)";
  }
  function hideHeatTip() { if (heatTip) heatTip.hidden = true; }

  document.addEventListener("mouseover", function (event) {
    var cell = event.target.closest && event.target.closest("[data-hm] rect[data-d]");
    if (cell) showHeatTip(cell); else if (heatTip && !heatTip.hidden && !event.target.closest("[data-hm]")) hideHeatTip();
  });
  document.addEventListener("click", function (event) {
    var cell = event.target.closest && event.target.closest("[data-hm] rect[data-d]");
    if (cell) showHeatTip(cell); else hideHeatTip();
  });
  document.addEventListener("mouseleave", hideHeatTip);
  window.addEventListener("scroll", hideHeatTip, { passive: true });
  document.addEventListener("scroll", function (event) { if (event.target.classList && event.target.classList.contains("hm__scroll")) hideHeatTip(); }, true);

  var ICONS = {
    website: '<svg aria-hidden="true" width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4"><circle cx="8" cy="8" r="6.3"/><path d="M1.8 8h12.4M8 1.7c1.8 1.8 2.6 3.9 2.6 6.3S9.8 12.5 8 14.3C6.2 12.5 5.4 10.4 5.4 8S6.2 3.5 8 1.7z"/></svg>',
    blog: '<svg aria-hidden="true" width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M10.5 2.5 13.5 5.5 6 13H3v-3z"/><path d="M9 4l3 3"/></svg>',
    star: '<svg aria-hidden="true" width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linejoin="round"><path d="M8 1.9l1.9 3.9 4.2.6-3 3 .7 4.2L8 11.6l-3.8 2 .7-4.2-3-3 4.2-.6z"/></svg>',
    fork: '<svg aria-hidden="true" width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"><circle cx="4.5" cy="3.5" r="1.5"/><circle cx="11.5" cy="3.5" r="1.5"/><circle cx="8" cy="12.5" r="1.5"/><path d="M4.5 5v1.5A1.5 1.5 0 0 0 6 8h4a1.5 1.5 0 0 0 1.5-1.5V5M8 8v3"/></svg>',
    github: '<svg aria-hidden="true" width="16" height="16" viewBox="0 0 16 16" fill="currentColor"><path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z"/></svg>',
    x: '<svg aria-hidden="true" width="16" height="16" viewBox="0 0 16 16" fill="currentColor"><path d="M12.2 1h2.3L9.5 6.8 15.4 15h-4.6L7.2 10.2 3 15H.7l5.4-6.2L.4 1h4.7l3.3 4.4L12.2 1zm-.8 12.6h1.3L4.5 2.3H3.1l8.3 11.3z"/></svg>',
    link: '<svg aria-hidden="true" width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M6.5 9.5a3 3 0 0 0 4.2 0l2.3-2.3a3 3 0 0 0-4.2-4.2l-.9.9"/><path d="M9.5 6.5a3 3 0 0 0-4.2 0L3 8.8A3 3 0 0 0 7.2 13l.9-.9"/></svg>',
    close: '<svg aria-hidden="true" width="12" height="12" viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"><path d="M3 3l6 6M9 3 3 9"/></svg>',
    download: '<svg aria-hidden="true" width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M8 2.5v8M4.5 7 8 10.5 11.5 7M3 13.5h10"/></svg>',
  };

  // 其他脚本共用的格式、链接、会话和示例开关
  window.QuotaRun = {
    ZH: ZH, ROOT: ROOT, V: V, API: API, DEMO: DEMO, LOCAL: LOCAL, PAGE: PAGE, PROVIDERS: PROVIDERS, USERNAME: USERNAME, SHARE: SHARE,
    t: t, esc: esc, each: each, $: $, has: has, pad: pad, number: number, clock: clock, hours: hours, gap: gap, short: short, approx: approx,
    percent: percent, share: share, toDate: toDate, relative: relative, timeTag: timeTag, moment: moment,
    isoWeek: isoWeek, weekStart: weekStart, seasonParam: seasonParam,
    providerName: providerName, logo: logo, windowLabel: windowLabel, windowSpan: windowSpan, boardName: boardName, boardKey: boardKey,
    avatar: avatar, initial: initial, tierTag: tierTag, accountMark: accountMark, regionLabel: regionLabel, safeLink: safeLink, hostOf: hostOf,
    LINK_KINDS: LINK_KINDS, linkName: linkName, linkLabel: linkLabel,
    query: query, demoPairs: demoPairs, profileHref: profileHref, homeHref: homeHref, boardHref: boardHref, pageHref: pageHref, demoHref: demoHref,
    currentPath: currentPath, langHref: langHref, setLangLinks: setLangLinks,
    api: api, getJSON: getJSON, request: request, session: session, signedInUser: signedInUser,
    renderAccountLink: renderAccountLink, demoSession: demoSession,
    stateBox: stateBox, errorBox: errorBox, copyText: copyText, setBusy: setBusy,
    compact: compact, calendarDate: calendarDate, heatmap: heatmap, heatmapReady: heatmapReady, heatStats: heatStats,
    FULL_FORMAT: FULL_FORMAT, YEAR_FORMAT: YEAR_FORMAT, MONTH_FORMAT: MONTH_FORMAT,
    ICONS: ICONS, ACCOUNT_ICON: ACCOUNT_ICON, accountVerifiedText: accountVerifiedText,
  };

  localLinks();
  langMemory();
  if (LOCAL || DEMO) setLangLinks(location.search);
  accountLink();
})();

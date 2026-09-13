/* Quota Run（quota.run）：登录（login.html）、我的账号（account.html）、连接 Mac（connect.html）。
 *
 * 排在 run.js 后面加载，借用它挂在 window.QuotaRun 上的格式、链接、会话和示例开关。
 * 接口是同源的 /api/v1，靠 qr_session 这枚 HttpOnly Cookie 认人（契约见 docs/quota-run.md 的
 * 「Web session」）：所有请求带 same-origin 凭据，写请求发 JSON，浏览器自己带 Origin。
 * ?demo=1 走本文件末尾的示例服务端，不发任何请求：
 *   login.html?demo=1               三种登录方式
 *   login.html?demo=1&step=code     填验证码（邮箱填 limit@example.com 可以看限流倒计时）
 *   login.html?demo=1&step=signup   新账号起用户名（peter、mika 已被占用，admin 是保留名）
 *   account.html?demo=1             已登录：两台 Mac、四个服务商账号（核实、绑定、归别人）、两种登录方式、两个项目
 *                                   （&cooldown=0 去掉换计分冷却，&accounts=0 看没有服务商账号时的样子）
 *   connect.html?demo=1&code=K7PM-4XQD  待批准的连接请求（&state=expired|used|denied|invalid 看其他状态）
 * 没有依赖，没有构建步骤。
 */
(function () {
  "use strict";

  var Q = window.QuotaRun;
  if (!Q) return;
  var ZH = Q.ZH, DEMO = Q.DEMO, LOCAL = Q.LOCAL, PAGE = Q.PAGE;
  var t = Q.t, esc = Q.esc, $ = Q.$, each = Q.each;
  var params = new URLSearchParams(location.search);
  var LANG = ZH ? "zh" : "en";
  var EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
  var MAX_PROJECTS = 12;

  /* ── 错误码 → 双语提示。认不出的码用接口给的英文句子 ───────────────── */

  var MESSAGES = {
    network: ["Couldn't reach quota.run. Check your connection and try again.", "连不上 quota.run，检查一下网络再试。"],
    not_signed_in: ["You're signed out. Sign in again to continue.", "登录已失效，请重新登录。"],
    needs_signup: ["Finish creating your account first.", "请先完成注册。"],
    bad_origin: ["This request didn't come from a quota.run page. Reload and try again.", "请求不是从 quota.run 的页面发出的，刷新后再试。"],
    invalid_email: ["That doesn't look like an email address.", "这看起来不是一个邮箱地址。"],
    rate_limited: ["Too many attempts. Wait a moment and try again.", "操作太频繁，稍等一会儿再试。"],
    email_unavailable: ["Email codes can't be sent right now. Try GitHub or Google, or come back later.", "现在发不了验证码邮件。可以先用 GitHub 或 Google，或者稍后再来。"],
    code_invalid: ["That code isn't right. Use the newest email.", "验证码不对，请用最新一封邮件里的。"],
    code_expired: ["That code has expired. Send a new one.", "验证码已过期，请重新发送。"],
    too_many_attempts: ["Too many wrong codes. Send a new one.", "错的次数太多了，请重新发送验证码。"],
    identity_in_use: ["That sign-in already belongs to another Quota Run account. Sign in with it and delete that account first, or use a different one.", "这个登录方式已经属于另一个 Quota Run 账号。先用它登录并删除那个账号，或者换一个。"],
    invalid_username: ["That username doesn't fit the rules below.", "这个用户名不符合下面的规则。"],
    username_taken: ["That username is taken.", "这个用户名已经被占用了。"],
    invalid_region: ["Choose a region.", "请选择地区。"],
    already_signed_up: ["This sign-in already has an account.", "这个登录方式已经有账号了。"],
    last_identity: ["That's your only sign-in method, so it can't be removed.", "这是你唯一的登录方式，不能移除。"],
    connect_code_invalid: ["No Mac is waiting with that code.", "没有 Mac 在用这个连接码等待。"],
    connect_code_used: ["That code has already been used.", "这个连接码已经用过了。"],
    cooldown: ["The ranked Mac changed less than 7 days ago.", "计分 Mac 距上次更换还不到 7 天。"],
    invalid_display_name: ["The display name can be at most 40 characters.", "显示名称最多 40 个字符。"],
    invalid_bio: ["The bio can be at most 160 characters.", "简介最多 160 个字符。"],
    invalid_links: ["Links must be https:// addresses; GitHub and X also take a username.", "链接必须是 https:// 地址；GitHub 和 X 也可以只填用户名。"],
    too_many_projects: ["At most 12 projects.", "最多 12 个项目。"],
    device_not_found: ["That Mac is no longer on your account.", "这台 Mac 已经不在你的账号里了。"],
    account_not_found: ["That provider account is no longer bound to your account.", "这个服务商账号已经不在你的账号里了。"],
    body_too_large: ["That's too much to save at once.", "一次保存的内容太多了。"],
    oauth_denied: ["Sign-in was cancelled, so nothing was shared. Pick a method to try again.", "登录已取消，没有共享任何信息。可以再选一种方式试试。"],
    oauth_state: ["That sign-in took too long or was opened in another browser. Please try again.", "这次登录超时了，或者是在另一个浏览器里打开的，请再试一次。"],
    oauth_failed: ["The provider didn't finish signing you in. Please try again.", "服务商那边没有完成登录，请再试一次。"],
    provider_unavailable: ["That sign-in method isn't available right now. Try another one.", "这种登录方式暂时不可用，换一种试试。"],
  };

  function explain(error) {
    var pair = error && MESSAGES[error.code];
    if (pair) return ZH ? pair[1] : pair[0];
    return (error && error.message) || t("Something went wrong. Please try again.", "出了点问题，请再试一次。");
  }

  function retryAfter(error) {
    var n = Math.ceil(Number(error && error.data && error.data.retryAfter));
    return n > 0 && n < 86400 ? n : 60;
  }

  /* ── 小工具 ──────────────────────────────────────────────────────── */

  var call = function (method, path, body) {
    return DEMO ? demo.handle(method, path, body) : Q.request(method, path, body);
  };

  function getSession(refresh) {
    return DEMO ? Promise.resolve(demo.session()) : Q.session(refresh);
  }

  function say(el, text, kind) {
    if (!el) return;
    el.textContent = text || "";
    if (el.classList.contains("acc-alert")) el.hidden = !text;
    if (kind) el.setAttribute("data-kind", kind);
    else el.removeAttribute("data-kind");
  }

  function busy(button, on) {
    if (!button) return;
    button.disabled = !!on;
    button.classList.toggle("is-busy", !!on);
    if (on) button.setAttribute("aria-busy", "true");
    else button.removeAttribute("aria-busy");
  }

  // 「重新发送」按钮的倒计时：文案取自按钮上的 data-label / data-wait / data-unit
  function countdown(button, seconds) {
    clearInterval(button._timer);
    var end = Date.now() + seconds * 1000;
    function tick() {
      var left = Math.ceil((end - Date.now()) / 1000);
      if (left <= 0) {
        clearInterval(button._timer);
        button.disabled = false;
        button.textContent = button.getAttribute("data-label");
        return;
      }
      button.disabled = true;
      button.textContent = button.getAttribute("data-wait") + left + button.getAttribute("data-unit");
    }
    tick();
    button._timer = setInterval(tick, 1000);
  }

  // next 只收站内相对路径：以 / 开头、不是 //，也不带反斜杠（有的浏览器把 /\ 当成 //）
  function validNext(raw) {
    if (typeof raw !== "string" || raw.charAt(0) !== "/" || raw.charAt(1) === "/" || /[\\\s\x00-\x1f]/.test(raw)) return null;
    return raw;
  }

  // 顶栏的语言切换带上当前查询串（next、连接码）；/@username 那种改写路径这三页没有
  function langLinks() {
    each(document.querySelectorAll("a.run-lang"), function (a) {
      var base = LOCAL ? Q.ROOT + (ZH ? "" : "zh/") + PAGE + ".html" : (ZH ? "/" : "/zh/") + PAGE;
      a.setAttribute("href", base + location.search);
    });
  }

  function replaceQuery(mutate) {
    var q = new URLSearchParams(location.search);
    mutate(q);
    var s = q.toString().replace(/%2F/gi, "/");
    try { history.replaceState(null, "", location.pathname + (s ? "?" + s : "") + location.hash); } catch (e) { /* file:// 下有的浏览器不让改 */ }
    langLinks();
  }

  function toLogin(next) {
    location.replace(Q.pageHref("login", { next: next || Q.currentPath() }));
  }

  function dateTime(value) {
    var date = Q.toDate(value);
    return date ? Q.FULL_FORMAT.format(date) : "";
  }

  function dayOf(value) {
    var date = Q.toDate(value);
    return date ? Q.YEAR_FORMAT.format(date) : "";
  }

  function clone(value) { return value == null ? value : JSON.parse(JSON.stringify(value)); }

  /* ── 图标（线性，和 run.js 的一套） ──────────────────────────────────── */

  var SVG = '<svg aria-hidden="true" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round">';
  var ICON = {
    mac: SVG + '<rect x="4" y="4.5" width="16" height="11" rx="1.6"/><path d="M2.5 19h19"/></svg>',
    mail: SVG + '<rect x="3" y="5" width="18" height="14" rx="2"/><path d="m3.5 6.5 8.5 6.5 8.5-6.5"/></svg>',
    github: '<svg aria-hidden="true" width="18" height="18" viewBox="0 0 16 16" fill="currentColor"><path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z"/></svg>',
    google: '<svg aria-hidden="true" width="18" height="18" viewBox="0 0 18 18"><path fill="#4285F4" d="M17.64 9.2c0-.64-.06-1.25-.16-1.84H9v3.48h4.84a4.14 4.14 0 0 1-1.8 2.72v2.26h2.92c1.7-1.57 2.68-3.88 2.68-6.62z"/><path fill="#34A853" d="M9 18c2.43 0 4.47-.8 5.96-2.18l-2.92-2.26c-.8.54-1.84.86-3.04.86-2.34 0-4.33-1.58-5.04-3.7H.96v2.33A9 9 0 0 0 9 18z"/><path fill="#FBBC05" d="M3.96 10.72A5.41 5.41 0 0 1 3.68 9c0-.6.1-1.18.28-1.72V4.95H.96A9 9 0 0 0 0 9c0 1.45.35 2.83.96 4.05l3-2.33z"/><path fill="#EA4335" d="M9 3.58c1.32 0 2.5.45 3.44 1.35l2.58-2.58A9 9 0 0 0 .96 4.95l3 2.33C4.67 5.16 6.66 3.58 9 3.58z"/></svg>',
    up: '<svg aria-hidden="true" width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="m4 10 4-4 4 4"/></svg>',
    down: '<svg aria-hidden="true" width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="m4 6 4 4 4-4"/></svg>',
    x: '<svg aria-hidden="true" width="12" height="12" viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"><path d="M3 3l6 6M9 3 3 9"/></svg>',
    check: '<svg aria-hidden="true" width="12" height="12" viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M2.5 6.4 5 8.8l4.5-5.3"/></svg>',
    ok: SVG + '<circle cx="12" cy="12" r="9"/><path d="m8 12.3 2.7 2.7L16 9.5"/></svg>',
    stop: SVG + '<circle cx="12" cy="12" r="9"/><path d="m9 9 6 6M15 9l-6 6"/></svg>',
    clock: SVG + '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/></svg>',
    used: SVG + '<rect x="5" y="10.5" width="14" height="9.5" rx="2"/><path d="M8 10.5V8a4 4 0 0 1 8 0v2.5"/></svg>',
  };

  function providerLabel(id) {
    return id === "github" ? "GitHub" : id === "google" ? "Google" : id === "email" ? t("Email", "邮箱") : String(id || "");
  }

  /* ── 登录 ─────────────────────────────────────────────────────────── */

  function loginPage() {
    var card = $("loginCard");
    var steps = { methods: $("stepMethods"), code: $("stepCode"), signup: $("stepSignup") };
    var defaultNext = ZH ? "/zh/account" : "/account";
    var next = validNext(params.get("next"));
    // 回到登录页自己会绕圈
    if (next && /^\/(zh\/)?login(\.html)?([?#]|$)/.test(next)) next = null;
    var email = "";
    var verifying = false;

    function destination() {
      return next || Q.pageHref("account");
    }

    function showStep(name, focus) {
      Object.keys(steps).forEach(function (key) { steps[key].hidden = key !== name; });
      $("loginLoading").hidden = true;
      card.setAttribute("aria-busy", "false");
      if (focus) {
        var el = steps[name].querySelector(focus);
        if (el) el.focus();
      }
    }

    function routeSession(s, focus) {
      Q.renderAccountLink(s);
      if (s && s.signedIn && !s.needsSignup && s.user) {
        location.replace(destination());
        return;
      }
      if (s && s.signedIn && s.needsSignup) {
        showSignup(s, focus);
        return;
      }
      if (DEMO && params.get("step") === "code") {
        email = "you@example.com";
        $("codeEmail").textContent = email;
        showStep("code");
        countdown($("codeResend"), 42);
        return;
      }
      showStep("methods", focus ? "#emailInput" : null);
    }

    // ── 登录方式 ──
    var queryError = params.get("error");
    if (queryError) {
      say($("methodsError"), MESSAGES[queryError] ? explain({ code: queryError }) : t("Sign-in didn't finish. Please try again.", "登录没有完成，请再试一次。"));
    }

    ["github", "google"].forEach(function (provider) {
      var link = $(provider === "github" ? "oauthGithub" : "oauthGoogle");
      link.setAttribute("href", Q.API + "/auth/" + provider + "/start?next=" + encodeURIComponent(next || defaultNext));
      if (DEMO) {
        link.addEventListener("click", function (event) {
          event.preventDefault();
          location.assign(Q.pageHref("login", { step: "signup", next: next }));
        });
      }
    });

    call("GET", "/auth/providers").then(function (p) {
      if (!p) return;
      var github = p.github !== false, google = p.google !== false, mail = p.email !== false;
      $("oauthGithub").hidden = !github;
      $("oauthGoogle").hidden = !google;
      $("oauthButtons").hidden = !github && !google;
      $("emailForm").hidden = !mail;
      $("emailDivider").hidden = !mail || (!github && !google);
      if (!github && !google && !mail) {
        say($("methodsError"), t("Sign-in isn't available right now. Please come back a little later.", "现在暂时无法登录，请稍后再来。"));
      }
    }, function () { /* 读不到配置就三种都摆出来，点了再说 */ });

    function sendCode(address, button, errorEl) {
      busy(button, true);
      say(errorEl, "");
      return call("POST", "/auth/email/start", { email: address, lang: LANG }).then(function () {
        busy(button, false);
        email = address;
        return 0;
      }, function (error) {
        busy(button, false);
        if (error.code === "rate_limited") {
          var wait = retryAfter(error);
          say(errorEl, ZH ? "验证码发得太频繁了，" + wait + " 秒后再试。" : "Too many codes requested. Try again in " + wait + " seconds.");
          return wait;
        }
        say(errorEl, explain(error));
        return -1;
      });
    }

    $("emailForm").addEventListener("submit", function (event) {
      event.preventDefault();
      var input = $("emailInput");
      var address = input.value.trim();
      if (!EMAIL.test(address)) {
        input.setAttribute("aria-invalid", "true");
        say($("methodsError"), explain({ code: "invalid_email" }));
        input.focus();
        return;
      }
      input.removeAttribute("aria-invalid");
      sendCode(address, $("emailSubmit"), $("methodsError")).then(function (result) {
        if (result !== 0) return;
        $("codeEmail").textContent = address;
        $("codeInput").value = "";
        say($("codeError"), "");
        showStep("code", "#codeInput");
        countdown($("codeResend"), 60);
      });
    });

    // ── 验证码 ──
    var codeInput = $("codeInput");

    function verify() {
      var code = codeInput.value.replace(/\D/g, "");
      if (code.length !== 6) {
        codeInput.setAttribute("aria-invalid", "true");
        say($("codeError"), t("Enter the 6 digits from the email.", "请输入邮件里的 6 位数字。"));
        codeInput.focus();
        return;
      }
      if (verifying) return;
      verifying = true;
      codeInput.removeAttribute("aria-invalid");
      busy($("codeSubmit"), true);
      say($("codeError"), "");
      call("POST", "/auth/email/verify", { email: email, code: code }).then(function (result) {
        return getSession(true).then(function (s) {
          routeSession(s, true);
        }, function () {
          if (result && result.needsSignup === false) location.replace(destination());
          else routeSession({ signedIn: true, needsSignup: true, identity: { provider: "email", email: email } }, true);
        });
      }).catch(function (error) {
        say($("codeError"), explain(error));
        codeInput.setAttribute("aria-invalid", "true");
        codeInput.select();
      }).then(function () {
        verifying = false;
        busy($("codeSubmit"), false);
      });
    }

    codeInput.addEventListener("input", function () {
      var digits = codeInput.value.replace(/\D/g, "").slice(0, 6);
      if (digits !== codeInput.value) codeInput.value = digits;
      if (digits.length === 6) verify();
    });
    $("codeForm").addEventListener("submit", function (event) { event.preventDefault(); verify(); });

    $("codeResend").addEventListener("click", function () {
      var button = $("codeResend");
      sendCode(email, button, $("codeError")).then(function (result) {
        if (result === 0) {
          countdown(button, 60);
          say($("codeStatus"), t("A new code is on its way.", "新的验证码已发出。"));
          codeInput.value = "";
          codeInput.focus();
        } else if (result > 0) {
          countdown(button, result);
        }
      });
    });

    $("codeBack").addEventListener("click", function () {
      $("emailInput").value = email;
      say($("codeError"), "");
      showStep("methods", "#emailInput");
    });

    // ── 起用户名 ──
    var usernameInput = $("usernameInput");
    var usernameStatus = $("usernameStatus");
    var check = { name: "", result: null, timer: 0, seq: 0 };

    function suggest(raw) {
      var name = String(raw || "").toLowerCase().replace(/[^a-z0-9_-]+/g, "-").replace(/^[^a-z0-9]+/, "").slice(0, 20);
      return Q.USERNAME.test(name) ? name : "";
    }

    function setCheck(kind, text) {
      usernameStatus.className = "acc-check" + (kind ? " is-" + kind : "");
      usernameStatus.innerHTML = text ? (kind === "ok" ? ICON.check : "") + "<span>" + esc(text) + "</span>" : "";
    }

    function reasonText(reason, name) {
      if (reason === "reserved") return t("That name is reserved for the site.", "这个名字是站点保留的。");
      if (reason === "taken") return t("@" + name + " is taken.", "@" + name + " 已经被占用了。");
      if (reason === "short") return t("At least 3 characters.", "至少 3 个字符。");
      return t("Use lower-case letters, digits, “-” and “_”, starting with a letter or digit.", "只能用小写字母、数字、“-” 和 “_”，并以字母或数字开头。");
    }

    function localReason(name) {
      if (!name) return "empty";
      if (/^[a-z0-9][a-z0-9_-]{0,1}$/.test(name)) return "short";
      return Q.USERNAME.test(name) ? null : "invalid";
    }

    function checkUsername(delay) {
      var name = usernameInput.value;
      var mine = ++check.seq;
      clearTimeout(check.timer);
      check.result = null;
      check.name = name;
      var reason = localReason(name);
      usernameInput.removeAttribute("aria-invalid");
      if (reason === "empty") { setCheck("", ""); return; }
      if (reason) {
        check.result = { available: false, reason: reason };
        setCheck("bad", reasonText(reason, name));
        return;
      }
      setCheck("wait", t("Checking…", "正在检查…"));
      check.timer = setTimeout(function () {
        call("GET", "/usernames/" + encodeURIComponent(name)).then(function (result) {
          if (mine !== check.seq) return;
          check.result = result;
          if (result && result.available) setCheck("ok", t("@" + name + " is available", "@" + name + " 可以用"));
          else setCheck("bad", reasonText(result && result.reason, name));
        }, function () {
          if (mine === check.seq) setCheck("", "");   // 查不到就等提交时由服务端判断
        });
      }, delay == null ? 350 : delay);
    }

    usernameInput.addEventListener("input", function () {
      var lower = usernameInput.value.toLowerCase().replace(/\s+/g, "");
      if (lower !== usernameInput.value) {
        var at = usernameInput.selectionStart;
        usernameInput.value = lower;
        try { usernameInput.setSelectionRange(at, at); } catch (e) { /* 忽略 */ }
      }
      checkUsername();
    });

    function showSignup(s, focus) {
      var who = s.identity || {};
      var address = who.email || who.name || "";
      $("signupWho").innerHTML = address
        ? t("Welcome! You're joining with ", "欢迎！你正在用 ") + "<b>" + esc(address) + "</b>" +
          (who.provider ? (ZH ? "（" + esc(providerLabel(who.provider)) + "）" : " (" + esc(providerLabel(who.provider)) + ")") : "") +
          t(". Last step: how you'll appear on Quota Run.", "加入。最后一步：你在 Quota Run 上叫什么。")
        : t("Welcome! Last step: how you'll appear on Quota Run.", "欢迎！最后一步：你在 Quota Run 上叫什么。");
      if (!usernameInput.value) usernameInput.value = suggest(s.suggestedUsername);
      var nameInput = $("displayNameInput");
      if (!nameInput.value) nameInput.value = String(s.suggestedDisplayName || who.name || "").slice(0, 40);
      var form = $("signupForm");
      if (!form.querySelector('input[name="region"]:checked')) {
        form.querySelector('input[name="region"][value="' + (ZH ? "china" : "global") + '"]').checked = true;
      }
      showStep("signup", focus ? "#usernameInput" : null);
      if (usernameInput.value) checkUsername(0);
    }

    $("signupForm").addEventListener("submit", function (event) {
      event.preventDefault();
      var form = event.currentTarget;
      var name = usernameInput.value.trim();
      var region = (form.querySelector('input[name="region"]:checked') || {}).value;
      var reason = localReason(name);
      say($("signupError"), "");
      if (reason || (check.result && check.name === name && !check.result.available)) {
        usernameInput.setAttribute("aria-invalid", "true");
        if (reason === "empty") setCheck("bad", t("Choose a username.", "请起一个用户名。"));
        else if (reason) setCheck("bad", reasonText(reason, name));
        usernameInput.focus();
        return;
      }
      if (!region) {
        say($("signupError"), explain({ code: "invalid_region" }));
        return;
      }
      var button = $("signupSubmit");
      busy(button, true);
      var displayName = $("displayNameInput").value.trim() || name;
      call("POST", "/signup", { username: name, displayName: displayName, region: region }).then(function (result) {
        var user = (result && result.user) || { username: name, displayName: displayName, region: region };
        Q.renderAccountLink({ signedIn: true, needsSignup: false, user: user });
        location.replace(destination());
      }, function (error) {
        busy(button, false);
        if (error.code === "already_signed_up") { location.replace(destination()); return; }
        if (error.code === "username_taken" || error.code === "invalid_username") {
          check.result = { available: false, reason: error.code === "username_taken" ? "taken" : "invalid" };
          setCheck("bad", error.code === "username_taken" ? reasonText("taken", name) : explain(error));
          usernameInput.setAttribute("aria-invalid", "true");
          usernameInput.focus();
          return;
        }
        if (error.status === 401) { showStep("methods"); say($("methodsError"), explain(error)); return; }
        say($("signupError"), explain(error));
      });
    });

    $("signupCancel").addEventListener("click", function () {
      var button = $("signupCancel");
      busy(button, true);
      call("POST", "/auth/logout").catch(function () { /* 退不掉也回到登录方式 */ }).then(function () {
        busy(button, false);
        usernameInput.value = "";
        $("displayNameInput").value = "";
        setCheck("", "");
        Q.renderAccountLink(null);
        showStep("methods", "#emailInput");
      });
    });

    getSession().then(function (s) { routeSession(s, false); }, function () { routeSession(null, false); });
  }

  /* ── 我的账号 ──────────────────────────────────────────────────────── */

  function accountPage() {
    var main = $("account");
    var app = $("accApp");
    var problem = $("accProblem");
    var accountPath = ZH ? "/zh/account" : "/account";
    var me = null;
    var projects = [];
    var confirmMac = null;
    var confirmIdentity = null;

    function goLogin() { toLogin(LOCAL || DEMO ? Q.currentPath() : accountPath); }

    // 任何一次操作回 401 / needs_signup：会话没了，回登录页
    function lostSession(error) {
      if (error && (error.status === 401 || error.code === "not_signed_in" || error.code === "needs_signup")) {
        goLogin();
        return true;
      }
      return false;
    }

    function status(form, text, kind) {
      var el = form.querySelector(".acc-status");
      say(el, text, kind);
    }

    // ── 顶部 ──
    function renderHead() {
      var user = me.user;
      $("accAvatar").innerHTML = Q.avatar(user, "run-avatar--xl");
      $("accName").textContent = user.displayName || user.username;
      var meta = ["@" + esc(user.username)];
      if (Q.regionLabel(user.region)) meta.push(esc(Q.regionLabel(user.region)));
      var joined = dayOf(user.joinedAt);
      if (joined) meta.push(ZH ? esc(joined) + " 加入" : "Joined " + esc(joined));
      $("accMeta").innerHTML = meta.map(function (m) { return "<span>" + m + "</span>"; }).join("");
      $("accProfileLink").setAttribute("href", Q.profileHref(user.username));
      $("deleteUsername").textContent = user.username;
      document.title = "@" + user.username + " · " + t("Your account · Quota Run", "我的账号 · Quota Run");
    }

    // ── 公开主页 ──
    var profileForm = $("profileForm");

    function fillProfile() {
      var user = me.user, links = user.links || {};
      profileForm.elements.displayName.value = user.displayName || "";
      profileForm.elements.bio.value = user.bio || "";
      each(profileForm.elements.region, function (r) { r.checked = r.value === user.region; });
      profileForm.elements.website.value = links.website || "";
      profileForm.elements.github.value = links.github || "";
      profileForm.elements.x.value = links.x || "";
      bioCount();
    }

    function bioCount() {
      $("pfBioCount").textContent = profileForm.elements.bio.value.length + " / 160";
    }

    profileForm.elements.bio.addEventListener("input", bioCount);
    profileForm.addEventListener("input", function () { status(profileForm, ""); });

    profileForm.addEventListener("submit", function (event) {
      event.preventDefault();
      var f = profileForm.elements;
      each(profileForm.querySelectorAll("[aria-invalid]"), function (el) { el.removeAttribute("aria-invalid"); });
      var website = f.website.value.trim();
      if (website && !/^https:\/\/[^\s]+\.[^\s]+$/i.test(website)) {
        f.website.setAttribute("aria-invalid", "true");
        f.website.focus();
        status(profileForm, t("The website has to start with https://.", "网站地址要以 https:// 开头。"), "error");
        return;
      }
      var body = {
        displayName: f.displayName.value.trim(),
        bio: f.bio.value.trim(),
        region: (profileForm.querySelector('input[name="region"]:checked') || {}).value || me.user.region,
        links: { website: website, github: f.github.value.trim(), x: f.x.value.trim() },
      };
      var button = profileForm.querySelector('button[type="submit"]');
      busy(button, true);
      status(profileForm, "");
      call("PUT", "/profile", body).then(function (result) {
        busy(button, false);
        me.user = Object.assign({}, me.user, (result && result.user) || body);
        renderHead();
        fillProfile();
        Q.renderAccountLink({ signedIn: true, needsSignup: false, user: me.user });
        status(profileForm, t("Saved.", "已保存。"), "ok");
      }, function (error) {
        busy(button, false);
        if (lostSession(error)) return;
        if (error.code === "invalid_links") {
          var field = /links\.(website|github|x)/.exec(error.message || "");
          if (field) { f[field[1]].setAttribute("aria-invalid", "true"); f[field[1]].focus(); }
        }
        status(profileForm, explain(error), "error");
      });
    });

    // ── 项目 ──
    var projectsForm = $("projectsForm");
    var projectsList = $("projectsList");
    var PROVIDER_IDS = Object.keys(Q.PROVIDERS);

    function field(id, label, control, extra) {
      return '<div class="acc-field">' + (label ? '<div class="acc-label-row"><label class="acc-label" for="' + id + '">' + label + "</label>" + (extra || "") + "</div>" : "") + control + "</div>";
    }

    function projectEditor(p, i) {
      var id = "pj" + i;
      var n = i + 1;
      var built = p.builtWith || [];
      var title = p.name ? esc(p.name) : t("Project ", "项目 ") + n;
      var chips = built.map(function (pid) {
        return '<li class="acc-chip">' + Q.logo(pid, 16) + "<span>" + esc(Q.providerName(pid)) + "</span>" +
          '<button type="button" class="acc-chip__x" data-act="unbuilt" data-provider="' + esc(pid) + '" aria-label="' + esc(t("Remove ", "移除 ") + Q.providerName(pid)) + '">' + ICON.x + "</button></li>";
      }).join("");
      var options = PROVIDER_IDS.filter(function (pid) { return built.indexOf(pid) < 0; }).map(function (pid) {
        return '<option value="' + esc(pid) + '">' + esc(Q.providerName(pid)) + "</option>";
      }).join("");
      return '<fieldset class="acc-project" data-i="' + i + '">' +
        '<legend class="sr-only">' + t("Project ", "项目 ") + n + "</legend>" +
        '<div class="acc-project__head"><span class="acc-project__title" data-title>' + title + "</span>" +
          '<div class="acc-project__tools">' +
            '<button type="button" class="acc-icon-btn" data-act="up"' + (i === 0 ? " disabled" : "") + ' aria-label="' + esc(t("Move project " + n + " up", "把项目 " + n + " 上移")) + '">' + ICON.up + "</button>" +
            '<button type="button" class="acc-icon-btn" data-act="down"' + (i === projects.length - 1 ? " disabled" : "") + ' aria-label="' + esc(t("Move project " + n + " down", "把项目 " + n + " 下移")) + '">' + ICON.down + "</button>" +
            '<button type="button" class="acc-link acc-link--danger" data-act="remove" aria-label="' + esc(t("Remove project " + n, "移除项目 " + n)) + '">' + t("Remove", "移除") + "</button>" +
          "</div></div>" +
        '<div class="acc-grid">' +
          field(id + "-name", t("Name", "名称"), '<input class="acc-input" id="' + id + '-name" data-field="name" type="text" maxlength="40" required value="' + esc(p.name) + '">') +
          field(id + "-url", t("Link", "链接"), '<input class="acc-input" id="' + id + '-url" data-field="url" type="url" inputmode="url" spellcheck="false" placeholder="https://" required value="' + esc(p.url) + '">') +
        "</div>" +
        field(id + "-desc", t("Description", "简介"), '<textarea class="acc-input acc-textarea acc-textarea--sm" id="' + id + '-desc" data-field="description" rows="2" maxlength="140">' + esc(p.description) + "</textarea>",
          '<span class="acc-count" data-count aria-hidden="true">' + String(p.description || "").length + " / 140</span>") +
        '<div class="acc-grid">' +
          field(id + "-gh", t("GitHub repository <span class=\"acc-optional\">optional</span>", "GitHub 仓库 <span class=\"acc-optional\">选填</span>"),
            '<input class="acc-input" id="' + id + '-gh" data-field="github" type="text" spellcheck="false" autocapitalize="off" placeholder="owner/repo" value="' + esc(p.github) + '">') +
          field(id + "-built", t("Built with", "用到的 AI"),
            (chips ? '<ul class="acc-chips">' + chips + "</ul>" : "") +
            (options ? '<select class="acc-input acc-select" id="' + id + '-built" data-act="built"><option value="">' + t("Add a provider…", "添加服务商…") + "</option>" + options + "</select>" : "")) +
        "</div>" +
      "</fieldset>";
    }

    function renderProjects(focus) {
      projectsList.innerHTML = projects.length
        ? projects.map(projectEditor).join("")
        : '<p class="acc-empty">' + t("No projects yet. Add what you're building and it shows up on your profile.", "还没有项目。加上你正在做的东西，它会出现在你的主页上。") + "</p>";
      $("projectsCount").textContent = projects.length + " / " + MAX_PROJECTS;
      $("projectAdd").disabled = projects.length >= MAX_PROJECTS;
      if (focus) {
        var el = projectsList.querySelector(focus);
        if (el) el.focus();
      }
    }

    function indexOf(el) {
      var box = el.closest(".acc-project");
      return box ? Number(box.getAttribute("data-i")) : -1;
    }

    projectsList.addEventListener("input", function (event) {
      var el = event.target;
      var key = el.getAttribute("data-field");
      var i = indexOf(el);
      if (!key || i < 0) return;
      projects[i][key] = el.value;
      el.removeAttribute("aria-invalid");
      var box = el.closest(".acc-project");
      if (key === "name") box.querySelector("[data-title]").textContent = el.value.trim() || t("Project ", "项目 ") + (i + 1);
      if (key === "description") box.querySelector("[data-count]").textContent = el.value.length + " / 140";
      status(projectsForm, "");
    });

    projectsList.addEventListener("change", function (event) {
      var el = event.target;
      if (el.getAttribute("data-act") !== "built" || !el.value) return;
      var i = indexOf(el);
      projects[i].builtWith = (projects[i].builtWith || []).concat(el.value).slice(0, 16);
      renderProjects('.acc-project[data-i="' + i + '"] [data-act="built"]');
      status(projectsForm, "");
    });

    projectsList.addEventListener("click", function (event) {
      var button = event.target.closest("button[data-act]");
      if (!button) return;
      var i = indexOf(button);
      var act = button.getAttribute("data-act");
      if (act === "up" && i > 0) {
        projects.splice(i - 1, 0, projects.splice(i, 1)[0]);
        renderProjects('.acc-project[data-i="' + (i - 1) + '"] [data-act="' + (i - 1 === 0 ? "down" : "up") + '"]');
      } else if (act === "down" && i < projects.length - 1) {
        projects.splice(i + 1, 0, projects.splice(i, 1)[0]);
        renderProjects('.acc-project[data-i="' + (i + 1) + '"] [data-act="' + (i + 1 === projects.length - 1 ? "up" : "down") + '"]');
      } else if (act === "remove") {
        projects.splice(i, 1);
        renderProjects(projects.length ? '.acc-project[data-i="' + Math.max(0, i - 1) + '"] input' : null);
        if (!projects.length) $("projectAdd").focus();
      } else if (act === "unbuilt") {
        var pid = button.getAttribute("data-provider");
        projects[i].builtWith = (projects[i].builtWith || []).filter(function (id) { return id !== pid; });
        renderProjects('.acc-project[data-i="' + i + '"] [data-act="built"]');
      } else {
        return;
      }
      status(projectsForm, "");
    });

    $("projectAdd").addEventListener("click", function () {
      if (projects.length >= MAX_PROJECTS) return;
      projects.push({ name: "", url: "", description: "", github: "", builtWith: [] });
      renderProjects('.acc-project[data-i="' + (projects.length - 1) + '"] input');
    });

    function projectProblem(p) {
      if (!String(p.name || "").trim()) return ["name", t("needs a name", "缺少名称")];
      if (!/^https:\/\/[^\s@\/]+\.[^\s@\/]+(\/\S*)?$/i.test(String(p.url || "").trim())) return ["url", t("needs a link starting with https://", "链接要以 https:// 开头")];
      var gh = String(p.github || "").trim();
      if (gh && !/^[A-Za-z0-9-]+\/[A-Za-z0-9._-]+$/.test(gh) && !/^https:\/\/(www\.)?github\.com\/\S+$/i.test(gh)) return ["github", t("GitHub has to be owner/repo or a github.com link", "GitHub 要写成 owner/repo 或 github.com 链接")];
      return null;
    }

    projectsForm.addEventListener("submit", function (event) {
      event.preventDefault();
      for (var i = 0; i < projects.length; i++) {
        var bad = projectProblem(projects[i]);
        if (bad) {
          var input = projectsList.querySelector('.acc-project[data-i="' + i + '"] [data-field="' + bad[0] + '"]');
          if (input) { input.setAttribute("aria-invalid", "true"); input.focus(); }
          status(projectsForm, t("Project " + (i + 1) + " " + bad[1] + ".", "项目 " + (i + 1) + " " + bad[1] + "。"), "error");
          return;
        }
      }
      var body = { projects: projects.map(function (p) {
        return { name: p.name.trim(), url: p.url.trim(), description: String(p.description || "").trim(), github: String(p.github || "").trim() || null, builtWith: p.builtWith || [] };
      }) };
      var button = projectsForm.querySelector('button[type="submit"]');
      busy(button, true);
      status(projectsForm, "");
      call("PUT", "/projects", body).then(function (result) {
        busy(button, false);
        me.projects = (result && result.projects) || body.projects;
        projects = clone(me.projects).map(normalizeProject);
        renderProjects();
        status(projectsForm, t("Saved.", "已保存。"), "ok");
      }, function (error) {
        busy(button, false);
        if (lostSession(error)) return;
        var index = error.data && typeof error.data.index === "number" ? error.data.index : -1;
        if (error.code === "invalid_project" && index >= 0) {
          var first = projectsList.querySelector('.acc-project[data-i="' + index + '"] input');
          if (first) first.focus();
          status(projectsForm, ZH ? "项目 " + (index + 1) + " 有一项不符合要求：" + (error.message || "") : error.message, "error");
          return;
        }
        status(projectsForm, explain(error), "error");
      });
    });

    function normalizeProject(p) {
      return { name: p.name || "", url: p.url || "", description: p.description || "", github: p.github || "", builtWith: Array.isArray(p.builtWith) ? p.builtWith.slice() : [] };
    }

    // ── Mac ──
    var macsList = $("macsList");

    function cooldownUntil() {
      var at = Q.toDate(me.rankedChangeAvailableAt);
      return at && at.getTime() > Date.now() ? at : null;
    }

    function cooldownText(at) {
      var when = esc(Q.FULL_FORMAT.format(at));
      return ZH ? "计分刚换过，" + when + " 之后才能再换到另一台 Mac。" : "The ranking moved recently. You can move it to another Mac after " + when + ".";
    }

    function renderMacs(focus) {
      var devices = me.devices || [];
      var hasRanked = devices.some(function (d) { return d.ranked; });
      var until = hasRanked ? cooldownUntil() : null;
      if (!devices.length) {
        macsList.innerHTML = '<li class="acc-empty">' + t("No Macs yet. Sign in from QuotaBar on a Mac and it shows up here; the first one becomes your ranked Mac.", "还没有 Mac。在 Mac 上的 QuotaBar 里登录，它就会出现在这里；第一台自动成为计分 Mac。") + "</li>";
        return;
      }
      macsList.innerHTML = devices.map(function (d) {
        var id = esc(d.deviceId);
        var name = esc(d.name || t("Unnamed Mac", "未命名的 Mac"));
        var seen = Q.toDate(d.lastSeenAt);
        var meta = [];
        if (d.appVersion) meta.push("QuotaBar " + esc(d.appVersion));
        meta.push(seen ? t("last seen ", "最近在线 ") + Q.timeTag(seen) : t("not seen yet", "还没上线过"));
        var actions;
        if (confirmMac === d.deviceId) {
          actions = '<div class="acc-confirm" role="group" aria-label="' + esc(t("Confirm removing ", "确认移除 ") + (d.name || "")) + '">' +
            '<span class="acc-confirm__text">' + (d.ranked
              ? t("Remove your ranked Mac? Nothing will count until you choose another.", "移除计分 Mac？在选出另一台之前，成绩都不会计入。")
              : t("Remove this Mac? It stops uploading.", "移除这台 Mac？它会停止上传。")) + "</span>" +
            '<button type="button" class="acc-btn acc-btn--sm acc-btn--danger" data-act="remove-yes" data-id="' + id + '">' + t("Remove", "移除") + "</button>" +
            '<button type="button" class="acc-btn acc-btn--sm acc-btn--quiet" data-act="remove-no" data-id="' + id + '">' + t("Cancel", "取消") + "</button></div>";
        } else {
          actions = (d.ranked ? "" : '<button type="button" class="acc-btn acc-btn--sm" data-act="rank" data-id="' + id + '"' + (until ? ' disabled aria-describedby="cool-' + id + '"' : "") + ">" + t("Make ranked", "设为计分") + "</button>") +
            '<button type="button" class="acc-btn acc-btn--sm acc-btn--quiet" data-act="remove" data-id="' + id + '" aria-label="' + esc(t("Remove ", "移除 ") + (d.name || "")) + '">' + t("Remove", "移除") + "</button>";
        }
        return '<li class="acc-row' + (d.ranked ? " is-ranked" : "") + '" data-id="' + id + '">' +
          '<span class="acc-row__icon">' + ICON.mac + "</span>" +
          '<div class="acc-row__main">' +
            '<p class="acc-row__title"><span class="acc-row__name">' + name + "</span>" +
              (d.ranked ? '<span class="badge acc-badge-ranked">' + ICON.check + t("Ranked", "计分") + "</span>" : "") + "</p>" +
            '<p class="acc-row__meta">' + meta.join(" · ") + "</p>" +
            (!d.ranked && until ? '<p class="acc-row__note" id="cool-' + id + '">' + cooldownText(until) + "</p>" : "") +
          "</div>" +
          '<div class="acc-row__actions">' + actions + "</div></li>";
      }).join("");
      if (focus) {
        var el = macsList.querySelector(focus);
        if (el) el.focus();
      }
    }

    macsList.addEventListener("click", function (event) {
      var button = event.target.closest("button[data-act]");
      if (!button) return;
      var id = button.getAttribute("data-id");
      var act = button.getAttribute("data-act");
      var sel = function (a) { return 'button[data-act="' + a + '"][data-id="' + CSS.escape(id) + '"]'; };
      say($("macsError"), "");
      if (act === "remove") { confirmMac = id; renderMacs(sel("remove-no")); return; }
      if (act === "remove-no") { confirmMac = null; renderMacs(sel("remove")); return; }
      busy(button, true);
      var request = act === "rank"
        ? call("POST", "/devices/ranked", { deviceId: id })
        : call("DELETE", "/devices/" + encodeURIComponent(id));
      request.then(function (result) {
        confirmMac = null;
        if (result && result.devices) me.devices = result.devices;
        if (result && "rankedChangeAvailableAt" in result) me.rankedChangeAvailableAt = result.rankedChangeAvailableAt;
        renderMacs();
        $("macsHeading").focus();
      }, function (error) {
        busy(button, false);
        if (lostSession(error)) return;
        if (error.code === "cooldown") {
          if (error.data.availableAt) me.rankedChangeAvailableAt = error.data.availableAt;
          var at = Q.toDate(error.data.availableAt);
          renderMacs();
          say($("macsError"), at ? (ZH ? "计分 Mac 距上次更换还不到 7 天，" + Q.FULL_FORMAT.format(at) + " 之后可以再换。" : "The ranked Mac changed less than 7 days ago. You can change it again after " + Q.FULL_FORMAT.format(at) + ".") : explain(error));
          return;
        }
        if (error.code === "device_not_found") {
          confirmMac = null;
          me.devices = (me.devices || []).filter(function (d) { return d.deviceId !== id; });
          renderMacs();
        }
        say($("macsError"), explain(error));
      });
    });

    // ── 服务商账号 ──
    // 契约里的 providerAccount：{id, provider, firstSeenAt, lastSeenAt, status: owned|elsewhere, verifiedByEmail, runs}。
    // 服务端只有账号摘要，没有邮箱：同一个服务商绑了几个账号时，用 id 的前 8 位区分
    var accountList = $("providerAccountList");
    var confirmAccount = null;

    function renderProviderAccounts(focus) {
      var list = me.providerAccounts || [];
      if (!list.length) {
        accountList.innerHTML = '<li class="acc-empty">' + t("No provider accounts yet. They appear after QuotaBar uploads its first readings.", "还没有服务商账号。QuotaBar 第一次上传读数后，它们会出现在这里。") + "</li>";
        return;
      }
      var perProvider = {};
      list.forEach(function (a) { perProvider[a.provider] = (perProvider[a.provider] || 0) + 1; });
      accountList.innerHTML = list.map(function (a) {
        var id = esc(a.id);
        var name = Q.providerName(a.provider);
        var elsewhere = a.status === "elsewhere";
        var verified = !elsewhere && a.verifiedByEmail;
        var badge = elsewhere
          ? '<span class="badge acc-badge-elsewhere">' + t("Owned by another Quota account", "归另一个 Quota 账号") + "</span>"
          : verified
            ? '<span class="badge run-acctbadge" title="' + esc(Q.accountVerifiedText()) + '">' + Q.ACCOUNT_ICON + t("Account verified", "账号已核实") + "</span>"
            : '<span class="badge acc-badge-bound">' + t("Bound", "已绑定") + "</span>";
        var meta = [];
        var since = dayOf(a.firstSeenAt);
        if (since) meta.push(ZH ? esc(since) + " 绑定" : "Bound since " + esc(since));
        var seen = Q.toDate(a.lastSeenAt);
        if (seen) meta.push(t("last upload ", "最近上传 ") + Q.timeTag(seen));
        var runs = Number(a.runs) || 0;
        meta.push(ZH ? Q.number(runs) + " 轮成绩" : Q.number(runs) + (runs === 1 ? " run" : " runs"));
        var label = name + (perProvider[a.provider] > 1 ? " " + String(a.id || "").slice(0, 8) : "");
        var actions;
        if (confirmAccount === a.id) {
          actions = '<div class="acc-confirm" role="group" aria-label="' + esc(t("Confirm unbinding ", "确认解除绑定 ") + label) + '">' +
            '<span class="acc-confirm__text">' + esc(ZH
              ? "解除绑定 " + name + "？你在 quota.run 上来自这个账号的读数和成绩会被删除。仍登录着它的 Mac 下次上传时会重新绑定，除非也在 QuotaBar 里解除绑定。"
              : "Unbind " + name + "? Your readings and runs from this account are deleted from quota.run. A Mac still signed in to it binds it again on its next upload, unless you unbind it in QuotaBar too.") + "</span>" +
            '<button type="button" class="acc-btn acc-btn--sm acc-btn--danger" data-act="unbind-yes" data-id="' + id + '">' + t("Unbind", "解除绑定") + "</button>" +
            '<button type="button" class="acc-btn acc-btn--sm acc-btn--quiet" data-act="unbind-no" data-id="' + id + '">' + t("Cancel", "取消") + "</button></div>";
        } else {
          actions = '<button type="button" class="acc-btn acc-btn--sm acc-btn--quiet" data-act="unbind" data-id="' + id + '" aria-label="' + esc(t("Unbind ", "解除绑定 ") + label) + '">' + t("Unbind", "解除绑定") + "</button>";
        }
        return '<li class="acc-row acc-row--account' + (verified ? " is-verified" : elsewhere ? " is-elsewhere" : "") + '" data-id="' + id + '">' +
          '<span class="acc-row__icon acc-row__icon--logo">' + Q.logo(a.provider, 24) + "</span>" +
          '<div class="acc-row__main">' +
            '<p class="acc-row__title"><span class="acc-row__name">' + esc(name) + "</span>" +
              (perProvider[a.provider] > 1 ? '<span class="acc-row__tag" title="' + esc(t("Account id", "账号编号")) + '">' + esc(String(a.id || "").slice(0, 8)) + "</span>" : "") +
              badge + "</p>" +
            '<p class="acc-row__meta">' + meta.join(" · ") + "</p>" +
            (elsewhere ? '<p class="acc-row__note">' + t("Runs from it don't count. Sign in with the email of that provider account to claim it.", "它的成绩不计入。用这个服务商账号的邮箱登录 quota.run，就能认领。") + "</p>" : "") +
          "</div>" +
          '<div class="acc-row__actions">' + actions + "</div></li>";
      }).join("");
      if (focus) {
        var el = accountList.querySelector(focus);
        if (el) el.focus();
      }
    }

    accountList.addEventListener("click", function (event) {
      var button = event.target.closest("button[data-act]");
      if (!button) return;
      var id = button.getAttribute("data-id");
      var act = button.getAttribute("data-act");
      var sel = function (a) { return 'button[data-act="' + a + '"][data-id="' + CSS.escape(id) + '"]'; };
      say($("providerAccountsError"), "");
      if (act === "unbind") { confirmAccount = id; renderProviderAccounts(sel("unbind-no")); return; }
      if (act === "unbind-no") { confirmAccount = null; renderProviderAccounts(sel("unbind")); return; }
      busy(button, true);
      call("DELETE", "/accounts/" + encodeURIComponent(id)).then(function (result) {
        confirmAccount = null;
        me.providerAccounts = (result && result.providerAccounts) || (me.providerAccounts || []).filter(function (a) { return a.id !== id; });
        renderProviderAccounts();
        $("providerAccountsHeading").focus();
      }, function (error) {
        busy(button, false);
        if (lostSession(error)) return;
        confirmAccount = null;
        if (error.code === "account_not_found") {
          me.providerAccounts = (me.providerAccounts || []).filter(function (a) { return a.id !== id; });
        }
        renderProviderAccounts();
        say($("providerAccountsError"), explain(error));
      });
    });

    // ── 登录方式 ──
    var identityList = $("identityList");

    function renderIdentities(focus) {
      var list = me.identities || [];
      var last = list.length <= 1;
      identityList.innerHTML = list.map(function (item) {
        var id = esc(item.id);
        var icon = item.provider === "github" ? ICON.github : item.provider === "google" ? ICON.google : ICON.mail;
        var detail = [];
        if (item.email) detail.push(esc(item.email));
        if (item.name && item.provider !== "email" && item.name !== item.email) detail.push(esc(item.name));
        var linked = dayOf(item.linkedAt);
        if (linked) detail.push(ZH ? esc(linked) + " 绑定" : "linked " + esc(linked));
        var actions;
        if (confirmIdentity === item.id) {
          actions = '<div class="acc-confirm" role="group" aria-label="' + esc(t("Confirm removing ", "确认移除 ") + providerLabel(item.provider)) + '">' +
            '<span class="acc-confirm__text">' + t("Remove this sign-in method?", "移除这种登录方式？") + "</span>" +
            '<button type="button" class="acc-btn acc-btn--sm acc-btn--danger" data-act="remove-yes" data-id="' + id + '">' + t("Remove", "移除") + "</button>" +
            '<button type="button" class="acc-btn acc-btn--sm acc-btn--quiet" data-act="remove-no" data-id="' + id + '">' + t("Cancel", "取消") + "</button></div>";
        } else {
          actions = '<button type="button" class="acc-btn acc-btn--sm acc-btn--quiet" data-act="remove" data-id="' + id + '"' +
            (last ? ' disabled aria-describedby="identityLast"' : "") +
            ' aria-label="' + esc(t("Remove ", "移除 ") + providerLabel(item.provider) + (item.email ? " " + item.email : "")) + '">' + t("Remove", "移除") + "</button>";
        }
        return '<li class="acc-row">' +
          '<span class="acc-row__icon acc-row__icon--' + esc(item.provider) + '">' + icon + "</span>" +
          '<div class="acc-row__main"><p class="acc-row__title"><span class="acc-row__name">' + esc(providerLabel(item.provider)) + "</span></p>" +
          '<p class="acc-row__meta">' + detail.join(" · ") + "</p></div>" +
          '<div class="acc-row__actions">' + actions + "</div></li>";
      }).join("") +
        (last ? '<li class="acc-row__note acc-row__note--list" id="identityLast">' + t("Your only sign-in method can't be removed. Link another one first.", "唯一的登录方式不能移除，先绑定另一种。") + "</li>" : "");
      if (focus) {
        var el = identityList.querySelector(focus);
        if (el) el.focus();
      }
    }

    identityList.addEventListener("click", function (event) {
      var button = event.target.closest("button[data-act]");
      if (!button) return;
      var id = button.getAttribute("data-id");
      var act = button.getAttribute("data-act");
      var sel = function (a) { return 'button[data-act="' + a + '"][data-id="' + CSS.escape(id) + '"]'; };
      say($("identitiesError"), "");
      if (act === "remove") { confirmIdentity = id; renderIdentities(sel("remove-no")); return; }
      if (act === "remove-no") { confirmIdentity = null; renderIdentities(sel("remove")); return; }
      busy(button, true);
      call("DELETE", "/identities/" + encodeURIComponent(id)).then(function (result) {
        confirmIdentity = null;
        me.identities = (result && result.identities) || (me.identities || []).filter(function (item) { return item.id !== id; });
        renderIdentities();
        $("signinHeading").focus();
      }, function (error) {
        busy(button, false);
        if (lostSession(error)) return;
        confirmIdentity = null;
        renderIdentities();
        say($("identitiesError"), explain(error));
      });
    });

    function setupLinks(available) {
      [["github", "linkGithub"], ["google", "linkGoogle"]].forEach(function (pair) {
        var link = $(pair[1]);
        link.setAttribute("href", Q.API + "/auth/" + pair[0] + "/start?link=1&next=" + encodeURIComponent(accountPath));
        link.hidden = available[pair[0]] === false;
      });
      $("linkEmailToggle").hidden = available.email === false;
    }

    if (DEMO) {
      each([$("linkGithub"), $("linkGoogle")], function (link) {
        link.addEventListener("click", function (event) {
          event.preventDefault();
          say($("identitiesError"), t("Demo: on quota.run this goes to the provider and comes back here with the new sign-in linked.", "示例：线上会跳到服务商授权，回来时新的登录方式就绑好了。"), "info");
        });
      });
    }

    var linkEmail = { address: "", verifying: false };
    var linkBox = $("linkEmail");
    var linkEmailForm = $("linkEmailForm");
    var linkCodeForm = $("linkCodeForm");
    var linkStatus = $("linkStatus");

    function linkReset() {
      linkEmailForm.hidden = false;
      linkCodeForm.hidden = true;
      $("linkEmailInput").value = "";
      $("linkCodeInput").value = "";
      say(linkStatus, "");
    }

    $("linkEmailToggle").addEventListener("click", function () {
      var open = linkBox.hidden;
      linkBox.hidden = !open;
      $("linkEmailToggle").setAttribute("aria-expanded", open ? "true" : "false");
      if (open) { linkReset(); $("linkEmailInput").focus(); }
    });

    function linkSend(button) {
      busy(button, true);
      say(linkStatus, "");
      return call("POST", "/auth/email/start", { email: linkEmail.address, lang: LANG, link: true }).then(function () {
        busy(button, false);
        return 0;
      }, function (error) {
        busy(button, false);
        if (lostSession(error)) return -1;
        if (error.code === "rate_limited") {
          var wait = retryAfter(error);
          say(linkStatus, ZH ? "验证码发得太频繁了，" + wait + " 秒后再试。" : "Too many codes requested. Try again in " + wait + " seconds.", "error");
          return wait;
        }
        say(linkStatus, explain(error), "error");
        return -1;
      });
    }

    linkEmailForm.addEventListener("submit", function (event) {
      event.preventDefault();
      var input = $("linkEmailInput");
      var address = input.value.trim();
      if (!EMAIL.test(address)) {
        input.setAttribute("aria-invalid", "true");
        say(linkStatus, explain({ code: "invalid_email" }), "error");
        input.focus();
        return;
      }
      input.removeAttribute("aria-invalid");
      linkEmail.address = address;
      linkSend(linkEmailForm.querySelector('button[type="submit"]')).then(function (result) {
        if (result !== 0) return;
        $("linkCodeEmail").textContent = address;
        linkEmailForm.hidden = true;
        linkCodeForm.hidden = false;
        $("linkCodeInput").focus();
        countdown($("linkResend"), 60);
      });
    });

    function linkVerify() {
      var input = $("linkCodeInput");
      var code = input.value.replace(/\D/g, "");
      if (code.length !== 6) {
        input.setAttribute("aria-invalid", "true");
        say(linkStatus, t("Enter the 6 digits from the email.", "请输入邮件里的 6 位数字。"), "error");
        input.focus();
        return;
      }
      if (linkEmail.verifying) return;
      linkEmail.verifying = true;
      var button = linkCodeForm.querySelector('button[type="submit"]');
      busy(button, true);
      say(linkStatus, "");
      call("POST", "/auth/email/verify", { email: linkEmail.address, code: code }).then(function () {
        return call("GET", "/me").then(function (data) {
          me = data;
          renderIdentities();
          renderProviderAccounts();   // 绑了新邮箱，服务端会重新核对哪些服务商账号的邮箱对得上
        }, function () { /* 已经绑上了，列表下次刷新再更新 */ });
      }).then(function () {
        linkBox.hidden = true;
        $("linkEmailToggle").setAttribute("aria-expanded", "false");
        say($("identitiesError"), t("Email linked. You can sign in with it now.", "邮箱已绑定，现在可以用它登录了。"), "ok");
        $("signinHeading").focus();
      }, function (error) {
        if (lostSession(error)) return;
        input.setAttribute("aria-invalid", "true");
        say(linkStatus, explain(error), "error");
        input.select();
      }).then(function () {
        linkEmail.verifying = false;
        busy(button, false);
      });
    }

    $("linkCodeInput").addEventListener("input", function () {
      var input = $("linkCodeInput");
      var digits = input.value.replace(/\D/g, "").slice(0, 6);
      if (digits !== input.value) input.value = digits;
      if (digits.length === 6) linkVerify();
    });
    linkCodeForm.addEventListener("submit", function (event) { event.preventDefault(); linkVerify(); });
    $("linkResend").addEventListener("click", function () {
      var button = $("linkResend");
      linkSend(button).then(function (result) {
        if (result === 0) { countdown(button, 60); say(linkStatus, t("A new code is on its way.", "新的验证码已发出。"), "ok"); }
        else if (result > 0) countdown(button, result);
      });
    });
    $("linkCancel").addEventListener("click", function () {
      linkBox.hidden = true;
      $("linkEmailToggle").setAttribute("aria-expanded", "false");
      $("linkEmailToggle").focus();
    });

    // ── 退出、删除 ──
    each(document.querySelectorAll("[data-signout]"), function (button) {
      button.addEventListener("click", function () {
        busy(button, true);
        call("POST", "/auth/logout").then(function () {
          Q.renderAccountLink(null);
          location.assign(DEMO ? Q.homeHref() + "&session=out" : Q.homeHref());
        }, function (error) {
          busy(button, false);
          if (lostSession(error)) return;
          say($("accBanner"), explain(error));
          $("accBanner").scrollIntoView({ block: "center" });
        });
      });
    });

    var deleteForm = $("deleteForm");
    var deleteInput = $("deleteInput");
    deleteInput.addEventListener("input", function () {
      $("deleteSubmit").disabled = deleteInput.value.trim().toLowerCase() !== me.user.username;
    });
    deleteForm.addEventListener("submit", function (event) {
      event.preventDefault();
      if (deleteInput.value.trim().toLowerCase() !== me.user.username) return;
      var button = $("deleteSubmit");
      busy(button, true);
      call("DELETE", "/account").then(function () {
        var username = me.user.username;
        Q.renderAccountLink(null);
        app.hidden = true;
        problem.hidden = false;
        problem.innerHTML = Q.stateBox("done", t("Account deleted", "账号已删除"),
          esc(ZH ? "@" + username + " 在 quota.run 上的主页、项目、成绩、Mac 和登录方式都已删除。Mac 上的 QuotaBar 会停止上传，本地纪录还在。"
            : "Everything about @" + username + " is gone from quota.run: profile, projects, runs, Macs and sign-in methods. QuotaBar on your Macs stops uploading and keeps its local records."),
          '<a class="run-btn" href="' + esc(Q.homeHref() + (DEMO ? "&session=out" : "")) + '">' + t("Back to the leaderboard", "回到排行榜") + "</a>");
        problem.querySelector(".run-state__title").setAttribute("tabindex", "-1");
        problem.querySelector(".run-state__title").focus();
        window.scrollTo(0, 0);
      }, function (error) {
        busy(button, false);
        $("deleteSubmit").disabled = false;
        if (lostSession(error)) return;
        status(deleteForm, explain(error), "error");
      });
    });

    // ── 起步 ──
    each(["macsHeading", "providerAccountsHeading", "signinHeading"], function (id) { $(id).setAttribute("tabindex", "-1"); });

    var bannerCode = params.get("error");
    if (bannerCode) {
      say($("accBanner"), MESSAGES[bannerCode] ? explain({ code: bannerCode }) : t("That didn't work. Please try again.", "没有成功，请再试一次。"));
      replaceQuery(function (q) { q.delete("error"); });
    }

    call("GET", "/auth/providers").then(function (p) { setupLinks(p || {}); }, function () { setupLinks({}); });
    setupLinks({});

    function start() {
      main.setAttribute("aria-busy", "true");
      call("GET", "/me").then(function (data) {
        me = data || {};
        me.user = me.user || {};
        projects = (me.projects || []).map(normalizeProject);
        renderHead();
        fillProfile();
        renderProjects();
        renderMacs();
        renderProviderAccounts();
        renderIdentities();
        Q.renderAccountLink({ signedIn: true, needsSignup: false, user: me.user });
        $("accLoading").hidden = true;
        problem.hidden = true;
        app.hidden = false;
        main.setAttribute("aria-busy", "false");
        if (location.hash) {
          var target = document.getElementById(location.hash.slice(1));
          if (target) target.scrollIntoView();
        }
      }, function (error) {
        if (lostSession(error)) return;
        $("accLoading").hidden = true;
        main.setAttribute("aria-busy", "false");
        problem.hidden = false;
        problem.innerHTML = Q.stateBox("error", t("Couldn't load your account.", "账号没加载出来。"), esc(explain(error)),
          '<button type="button" class="run-btn" data-retry>' + t("Try again", "重试") + "</button>");
      });
    }

    problem.addEventListener("click", function (event) {
      if (event.target.closest("[data-retry]")) {
        problem.hidden = true;
        $("accLoading").hidden = false;
        start();
      }
    });

    start();
  }

  /* ── 连接 Mac ──────────────────────────────────────────────────────── */

  function normalizeCode(raw) {
    var clean = String(raw || "").toUpperCase().replace(/[^A-Z0-9]/g, "");
    return clean.length === 8 ? clean.slice(0, 4) + "-" + clean.slice(4) : clean;
  }

  function connectPage() {
    var card = $("connectCard");
    var loadingHTML = card.innerHTML;
    var user = null;
    var ticker = 0;
    var eyebrow = '<p class="run-eyebrow"><i aria-hidden="true"></i>Quota Run</p>';

    function done() { card.setAttribute("aria-busy", "false"); }

    function focusTitle() {
      var h = card.querySelector("h1");
      if (h) { h.setAttribute("tabindex", "-1"); h.focus(); }
    }

    function signedInLine() {
      return '<p class="acc-signed">' + t("Signed in as ", "当前账号 ") + "<b>@" + esc(user.username) + "</b> · " +
        '<button type="button" class="acc-link" data-act="switch">' + t("Use another account", "换一个账号") + "</button></p>";
    }

    function spell(code) {
      return '<span aria-hidden="true">' + esc(code) + '</span><span class="sr-only">' + esc(code.split("").join(" ")) + "</span>";
    }

    function result(kind, icon, title, text, actions) {
      clearInterval(ticker);
      card.innerHTML = '<div class="acc-result acc-result--' + kind + '">' +
        '<span class="acc-result__icon">' + icon + "</span>" +
        '<h1 class="acc-title">' + title + "</h1>" +
        (text ? '<p class="acc-lede">' + text + "</p>" : "") +
        (actions ? '<div class="acc-result__actions">' + actions + "</div>" : "") +
        "</div>" + signedInLine();
      done();
      focusTitle();
    }

    var manageLink = function () { return '<a class="acc-btn" href="' + esc(Q.pageHref("account") + "#macs") + '">' + t("Manage your Macs", "管理你的 Mac") + "</a>"; };
    var homeLink = function () { return '<a class="acc-btn acc-btn--quiet" href="' + esc(Q.homeHref()) + '">' + t("See the leaderboard", "去看排行榜") + "</a>"; };
    var anotherButton = function () { return '<button type="button" class="acc-btn acc-btn--quiet" data-act="another">' + t("Enter another code", "输入其他连接码") + "</button>"; };

    function expired(code) {
      result("muted", ICON.clock, t("This code has expired", "这个连接码已过期"),
        (code ? '<span class="acc-mono acc-strike">' + esc(code) + "</span> · " : "") +
          t("Codes last 10 minutes. In QuotaBar, choose “Sign in with quota.run” again to get a new one.", "连接码 10 分钟内有效。在 QuotaBar 里重新点「用 quota.run 登录」，会拿到一个新的。"),
        anotherButton() + homeLink());
    }

    function used() {
      result("muted", ICON.used, t("This code has already been used", "这个连接码已经用过了"),
        t("Each code connects one Mac, once. If that was you, the Mac is already on your account.", "每个连接码只能连接一台 Mac、用一次。如果刚才是你自己连的，那台 Mac 已经在你的账号里了。"),
        manageLink() + anotherButton());
    }

    function denied(fresh) {
      result("muted", ICON.stop, fresh ? t("Request denied", "已拒绝") : t("This request was denied", "这个请求已被拒绝"),
        t("That Mac won't be connected. QuotaBar on it stops waiting and deletes the key it made. If you didn't start this, there's nothing else to do.", "那台 Mac 不会连到你的账号。它上面的 QuotaBar 会停止等待，并删掉刚生成的密钥。如果不是你发起的，不用再做什么。"),
        homeLink());
    }

    function entry(errorText, value) {
      clearInterval(ticker);
      card.innerHTML = eyebrow +
        '<h1 class="acc-title">' + t("Connect a Mac", "连接一台 Mac") + "</h1>" +
        '<p class="acc-lede">' + t("Type the code QuotaBar shows on the Mac you're signing in on.", "输入要登录的那台 Mac 上 QuotaBar 显示的连接码。") + "</p>" +
        '<form class="acc-form" id="codeEntry" novalidate>' +
          '<div class="acc-field"><label class="acc-label" for="connectCode">' + t("Connection code", "连接码") + "</label>" +
          '<input class="acc-input acc-input--usercode" id="connectCode" name="code" type="text" autocomplete="off" autocapitalize="characters" spellcheck="false" maxlength="9" placeholder="ABCD-EFGH" value="' + esc(value || "") + '" aria-describedby="' + (errorText ? "connectCodeError " : "") + 'connectCodeHint"' + (errorText ? ' aria-invalid="true"' : "") + ">" +
          (errorText ? '<p class="acc-check is-bad" id="connectCodeError" role="alert">' + errorText + "</p>" : "") +
          '<p class="acc-hint" id="connectCodeHint">' + t("8 letters and digits, like ABCD-EFGH. Codes last 10 minutes.", "8 位字母和数字，形如 ABCD-EFGH，10 分钟内有效。") + "</p></div>" +
          '<button class="acc-btn acc-btn--primary acc-btn--block" type="submit">' + t("Continue", "继续") + "</button>" +
        "</form>" + signedInLine();
      done();
      var input = $("connectCode");
      input.addEventListener("input", function () {
        var clean = input.value.toUpperCase().replace(/[^A-Z0-9]/g, "").slice(0, 8);
        var shown = clean.length > 4 ? clean.slice(0, 4) + "-" + clean.slice(4) : clean;
        if (shown !== input.value) input.value = shown;
      });
      $("codeEntry").addEventListener("submit", function (event) {
        event.preventDefault();
        var code = normalizeCode(input.value);
        if (code.length !== 9) {
          entry(t("Enter all 8 characters of the code.", "请输入完整的 8 位连接码。"), input.value);
          $("connectCode").focus();
          return;
        }
        replaceQuery(function (q) { q.set("code", code); q.delete("state"); });
        load(code);
      });
      if (errorText || !value) input.focus();
    }

    function pending(r) {
      var code = normalizeCode(r.userCode);
      var expires = Q.toDate(r.expiresAt);
      var platform = r.platform === "macos" ? "macOS" : esc(r.platform || "");
      var meta = [];
      if (r.appVersion) meta.push("QuotaBar " + esc(r.appVersion));
      if (platform) meta.push(platform);
      var asked = Q.toDate(r.createdAt);
      if (asked) meta.push(t("asked ", "发起于 ") + Q.timeTag(asked));
      card.innerHTML = eyebrow +
        '<h1 class="acc-title">' + t("Connect this Mac?", "连接这台 Mac？") + "</h1>" +
        '<p class="acc-lede">' + t("QuotaBar on a Mac asked to join your account. Approve only if you started this yourself, just now.", "有一台 Mac 上的 QuotaBar 请求加入你的账号。只有是你自己刚刚发起的，才批准。") + "</p>" +
        '<div class="acc-device">' +
          '<span class="acc-row__icon acc-device__icon">' + ICON.mac + "</span>" +
          '<div class="acc-device__text"><p class="acc-device__name">' + esc(r.deviceName || t("Unnamed Mac", "未命名的 Mac")) + "</p>" +
          '<p class="acc-row__meta">' + meta.join(" · ") + "</p></div>" +
        "</div>" +
        '<div class="acc-codebox">' +
          '<p class="acc-label" id="codeLabel">' + t("Check that this matches the code in QuotaBar", "核对一下，和 QuotaBar 里显示的连接码一致") + "</p>" +
          '<p class="acc-usercode" aria-labelledby="codeLabel">' + spell(code) + "</p>" +
          '<p class="acc-hint" id="connectExpiry" aria-live="off"></p>' +
        "</div>" +
        '<div class="acc-alert acc-alert--error" id="connectError" role="alert" hidden></div>' +
        '<div class="acc-stack">' +
          '<button type="button" class="acc-btn acc-btn--primary acc-btn--block" data-act="approve">' + esc(t("Connect this Mac to @", "把这台 Mac 连接到 @") + user.username) + "</button>" +
          '<button type="button" class="acc-btn acc-btn--quiet acc-btn--block" data-act="deny">' + t("Deny", "拒绝") + "</button>" +
        "</div>" +
        '<p class="acc-foot-note">' + t("A connected Mac signs its readings with a key that never leaves it. You can remove it from your account at any time.", "连接后，这台 Mac 用一把不出本机的密钥给读数签名。随时可以在账号页里移除。") + "</p>" +
        signedInLine();
      done();

      function tick() {
        var el = $("connectExpiry");
        if (!el || !expires) return;
        var left = Math.floor((expires.getTime() - Date.now()) / 1000);
        if (left <= 0) { expired(code); return; }
        var mm = Math.floor(left / 60), ss = left % 60;
        var clock = mm + ":" + (ss < 10 ? "0" : "") + ss;
        el.textContent = ZH ? "还有 " + clock + " 过期" : "Expires in " + clock;
      }
      clearInterval(ticker);
      tick();
      if (expires) ticker = setInterval(tick, 1000);

      card.querySelector('[data-act="approve"]').addEventListener("click", function (event) { decide(code, "approve", event.currentTarget); });
      card.querySelector('[data-act="deny"]').addEventListener("click", function (event) { decide(code, "deny", event.currentTarget); });
    }

    function decide(code, action, button) {
      each(card.querySelectorAll(".acc-stack button"), function (b) { b.disabled = true; });
      busy(button, true);
      say($("connectError"), "");
      call("POST", "/connect/" + encodeURIComponent(code) + "/" + action).then(function (r) {
        if (action === "deny") { denied(true); return; }
        var name = "<b>" + esc((r && r.deviceName) || t("This Mac", "这台 Mac")) + "</b>";
        result("ok", ICON.ok, t("Connected. You can go back to QuotaBar.", "已连接，可以回到 QuotaBar 了。"),
          r && r.ranked
            ? (ZH ? name + " 现在是你的计分 Mac，它的读数会计入排行榜。" : name + " is now your ranked Mac: its readings count on the boards.")
            : (ZH ? name + " 已连到 @" + esc(user.username) + "。计分 Mac 没有变，成绩仍按原来那台算；想换的话去账号页。" : name + " is connected to @" + esc(user.username) + ". Your ranked Mac hasn't changed, so its readings are still the ones that count. You can change that on your account page."),
          manageLink() + homeLink());
      }, function (error) {
        if (error.status === 401 || error.code === "needs_signup") { toLogin(); return; }
        if (error.code === "connect_code_used") { used(); return; }
        if (error.code === "connect_code_invalid") { expired(code); return; }
        each(card.querySelectorAll(".acc-stack button"), function (b) { b.disabled = false; });
        busy(button, false);
        say($("connectError"), explain(error));
      });
    }

    function load(code) {
      clearInterval(ticker);
      card.setAttribute("aria-busy", "true");
      card.innerHTML = loadingHTML;
      call("GET", "/connect/" + encodeURIComponent(code)).then(function (r) {
        r = r || {};
        var expires = Q.toDate(r.expiresAt);
        if (r.status === "approved") used();
        else if (r.status === "denied") denied(false);
        else if (r.status === "expired" || (expires && expires.getTime() <= Date.now())) expired(code);
        else pending(Object.assign({ userCode: code }, r));
      }, function (error) {
        if (error.status === 401 || error.code === "needs_signup") { toLogin(); return; }
        if (error.code === "connect_code_used") { used(); return; }
        if (error.status === 404 || error.code === "connect_code_invalid") {
          entry(esc(ZH ? "没有 Mac 在用 " + code + " 等待连接。和 QuotaBar 里的核对一下，或者在 QuotaBar 里重新开始。"
            : "No Mac is waiting with " + code + ". Check it against QuotaBar, or start again there."), code);
          return;
        }
        done();
        card.innerHTML = Q.stateBox("error", t("Couldn't load this request.", "连接请求没加载出来。"), esc(explain(error)),
          '<button type="button" class="run-btn" data-act="retry">' + t("Try again", "重试") + "</button>");
      });
    }

    card.addEventListener("click", function (event) {
      var button = event.target.closest("button[data-act]");
      if (!button) return;
      var act = button.getAttribute("data-act");
      if (act === "another") {
        replaceQuery(function (q) { q.delete("code"); q.delete("state"); });
        entry("", "");
      } else if (act === "retry") {
        load(normalizeCode(new URLSearchParams(location.search).get("code")));
      } else if (act === "switch") {
        busy(button, true);
        call("POST", "/auth/logout").catch(function () { /* 照样去登录页 */ }).then(function () { toLogin(); });
      }
    });

    getSession().then(function (s) {
      if (!s || !s.signedIn || s.needsSignup || !s.user) { toLogin(); return; }
      user = s.user;
      var code = normalizeCode(params.get("code"));
      if (code.length === 9) load(code);
      else entry(code ? t("That doesn't look like a full code.", "这不像是完整的连接码。") : "", code);
    }, function (error) {
      if (error && error.status === 401) { toLogin(); return; }
      done();
      card.innerHTML = Q.stateBox("error", t("Couldn't check whether you're signed in.", "没能确认登录状态。"), esc(explain(error)),
        '<button type="button" class="run-btn" onclick="location.reload()">' + t("Try again", "重试") + "</button>");
    });
  }

  /* ── 示例服务端（?demo=1）──────────────────────────────────────────
   * 形状照契约，状态只在内存里，刷新就回到初始。每个回应延迟一小会，
   * 按钮的忙碌状态看得见。 */
  var demo = (function () {
    var NOW = Math.floor(Date.now() / 1000);
    var RESERVED = "account admin api app about auth connect help leaderboard login logout me profile quota quotabar register run settings signup support u user users www zh en".split(" ");
    var TAKEN = ["peter", "linxiao", "mika", "sora", "hweiss", "chenyu", "devon", "juno"];
    var state = {
      session: Q.demoSession(),
      linking: false,
      me: {
        user: { username: "peter", displayName: "Peter", bio: "Building QuotaBar. Burns a Codex week by Wednesday, mostly on purpose.", region: "global", joinedAt: NOW - 38 * 86400,
          links: { website: "https://quota.bar", github: "https://github.com/gentpan", x: "" } },
        devices: [
          { deviceId: "dev_7f3a91", name: "Peter's MacBook Pro", ranked: true, lastSeenAt: NOW - 240, current: false, appVersion: "0.5.3" },
          { deviceId: "dev_29c1e4", name: "Mac Studio", ranked: false, lastSeenAt: NOW - 2 * 86400 - 3600, current: false, appVersion: "0.5.2" },
        ],
        rankedChangeAvailableAt: params.get("cooldown") === "0" ? null : NOW + 3 * 86400 + 5400,
        lastUploadAt: NOW - 240,
        projects: [
          { name: "QuotaBar", url: "https://quota.bar", description: "Every AI coding limit, at a glance — in the macOS menu bar, the notch and on desktop cards.", github: "https://github.com/gentpan/QuotaBar", builtWith: ["codex", "claude"] },
          { name: "Tidewire", url: "https://tidewire.example", description: "A small sync engine for local-first notes. Conflict-free merges, no server required.", github: "", builtWith: ["claude", "cursor"] },
        ],
        identities: [
          { id: "idn_gh01", provider: "github", email: "peter@example.com", name: "Peter", linkedAt: NOW - 38 * 86400 },
          { id: "idn_em02", provider: "email", email: "peter@example.com", name: null, linkedAt: NOW - 12 * 86400 },
        ],
        // 和 run.js 的示例主页对得上：Codex、Cursor 核实过，Claude 只绑定；第二个 Codex 账号（工作账号）归别人
        providerAccounts: params.get("accounts") === "0" ? [] : [
          { id: "3f9a2c71d04be815", provider: "codex", firstSeenAt: NOW - 37 * 86400, lastSeenAt: NOW - 240, status: "owned", verifiedByEmail: true, runs: 41 },
          { id: "b27e5d0c9a61f344", provider: "claude", firstSeenAt: NOW - 36 * 86400, lastSeenAt: NOW - 3 * 3600, status: "owned", verifiedByEmail: false, runs: 38 },
          { id: "0c4d81e6f2a97b53", provider: "cursor", firstSeenAt: NOW - 20 * 86400, lastSeenAt: NOW - 4 * 86400, status: "owned", verifiedByEmail: true, runs: 7 },
          { id: "e81b36a4c7d0f229", provider: "codex", firstSeenAt: NOW - 6 * 86400, lastSeenAt: NOW - 2 * 86400 - 3600, status: "elsewhere", verifiedByEmail: false, runs: 0 },
        ],
      },
      connect: { status: params.get("state") || "pending", deviceName: "Mac mini", platform: "macos", appVersion: "0.5.3", createdAt: NOW - 48, expiresAt: NOW + 552 },
    };

    function later(fn) {
      return new Promise(function (resolve, reject) {
        setTimeout(function () {
          try { resolve(clone(fn())); } catch (error) { reject(error); }
        }, 380);
      });
    }

    function fail(status, code, message, extra) {
      var error = new Error(message);
      error.status = status;
      error.code = code;
      error.data = Object.assign({ error: code, message: message }, extra || {});
      throw error;
    }

    function signedIn() {
      if (!state.session.signedIn) fail(401, "not_signed_in", "Sign in first.");
      if (state.session.needsSignup) fail(403, "needs_signup", "Choose a username first.");
    }

    function handle(method, path, body) {
      body = body || {};
      return later(function () {
        var m;
        if (method === "GET" && path === "/session") return state.session;
        if (method === "GET" && path === "/auth/providers") return { github: true, google: true, email: true };
        if (method === "POST" && path === "/auth/logout") {
          state.session = { signedIn: false, needsSignup: false, identity: null, user: null };
          return null;
        }
        if (method === "POST" && path === "/auth/email/start") {
          if (!EMAIL.test(body.email || "")) fail(400, "invalid_email", "That is not an email address.");
          if (body.email === "limit@example.com") fail(429, "rate_limited", "Too many codes.", { retryAfter: 42 });
          state.linking = !!body.link;
          return { sent: true, expiresAt: NOW + 600 };
        }
        if (method === "POST" && path === "/auth/email/verify") {
          if (body.code === "000000") fail(400, "code_invalid", "The code is not right.");
          if (state.linking) {
            if (body.email === "mika@example.com") fail(409, "identity_in_use", "This email belongs to another account.");
            state.me.identities.push({ id: "idn_" + Date.now().toString(36), provider: "email", email: body.email, name: null, linkedAt: Math.floor(Date.now() / 1000) });
            return { linked: true };
          }
          state.session = { signedIn: true, needsSignup: true, identity: { provider: "email", email: body.email, name: null }, user: null, suggestedUsername: String(body.email).split("@")[0], suggestedDisplayName: "" };
          return { signedIn: true, needsSignup: true };
        }
        if (method === "GET" && (m = /^\/usernames\/(.+)$/.exec(path))) {
          var name = decodeURIComponent(m[1]);
          if (!Q.USERNAME.test(name)) return { available: false, reason: "invalid" };
          if (RESERVED.indexOf(name) >= 0) return { available: false, reason: "reserved" };
          if (TAKEN.indexOf(name) >= 0) return { available: false, reason: "taken" };
          return { available: true, reason: null };
        }
        if (method === "POST" && path === "/signup") {
          if (!state.session.signedIn) fail(401, "not_signed_in", "Sign in first.");
          if (!Q.USERNAME.test(body.username || "") || RESERVED.indexOf(body.username) >= 0) fail(400, "invalid_username", "That username is not allowed.");
          if (TAKEN.indexOf(body.username) >= 0) fail(409, "username_taken", "That username is taken.");
          var user = { username: body.username, displayName: body.displayName, region: body.region };
          state.session = Object.assign({}, state.session, { needsSignup: false, user: user });
          return { user: user };
        }
        if (method === "GET" && path === "/me") { signedIn(); return state.me; }
        if (method === "PUT" && path === "/profile") {
          signedIn();
          if ((body.displayName || "").length > 40) fail(400, "invalid_display_name", "displayName is at most 40 characters.");
          Object.assign(state.me.user, { displayName: body.displayName || state.me.user.username, bio: body.bio, region: body.region });
          var links = body.links || {};
          state.me.user.links = {
            website: links.website || "",
            github: links.github && !/^https:/.test(links.github) ? "https://github.com/" + links.github.replace(/^@/, "") : links.github || "",
            x: links.x && !/^https:/.test(links.x) ? "https://x.com/" + links.x.replace(/^@/, "") : links.x || "",
          };
          return { user: state.me.user };
        }
        if (method === "PUT" && path === "/projects") {
          signedIn();
          state.me.projects = (body.projects || []).map(function (p) {
            return Object.assign({}, p, { github: p.github && !/^https:/.test(p.github) ? "https://github.com/" + p.github : p.github || null });
          });
          return { projects: state.me.projects };
        }
        if (method === "POST" && path === "/devices/ranked") {
          signedIn();
          var hasRanked = state.me.devices.some(function (d) { return d.ranked; });
          var until = state.me.rankedChangeAvailableAt;
          if (hasRanked && until && until * 1000 > Date.now()) fail(409, "cooldown", "The ranked device changed less than 7 days ago.", { availableAt: until });
          state.me.devices.forEach(function (d) { d.ranked = d.deviceId === body.deviceId; });
          if (hasRanked) state.me.rankedChangeAvailableAt = Math.floor(Date.now() / 1000) + 7 * 86400;
          return { devices: state.me.devices, rankedChangeAvailableAt: state.me.rankedChangeAvailableAt };
        }
        if (method === "DELETE" && (m = /^\/devices\/(.+)$/.exec(path))) {
          signedIn();
          state.me.devices = state.me.devices.filter(function (d) { return d.deviceId !== decodeURIComponent(m[1]); });
          return { devices: state.me.devices };
        }
        if (method === "DELETE" && (m = /^\/accounts\/(.+)$/.exec(path))) {
          signedIn();
          var accountId = decodeURIComponent(m[1]);
          if (!state.me.providerAccounts.some(function (a) { return a.id === accountId; })) fail(404, "account_not_found", "No provider account with that id.");
          state.me.providerAccounts = state.me.providerAccounts.filter(function (a) { return a.id !== accountId; });
          return { providerAccounts: state.me.providerAccounts };
        }
        if (method === "DELETE" && (m = /^\/identities\/(.+)$/.exec(path))) {
          signedIn();
          if (state.me.identities.length <= 1) fail(409, "last_identity", "An account keeps at least one sign-in.");
          state.me.identities = state.me.identities.filter(function (item) { return item.id !== decodeURIComponent(m[1]); });
          return { identities: state.me.identities };
        }
        if (method === "DELETE" && path === "/account") {
          signedIn();
          state.session = { signedIn: false, needsSignup: false, identity: null, user: null };
          return null;
        }
        if ((m = /^\/connect\/([^\/]+)(?:\/(approve|deny))?$/.exec(path))) {
          signedIn();
          var c = state.connect;
          if (c.status === "invalid") fail(404, "connect_code_invalid", "No connect request with that code.");
          if (method === "GET") return Object.assign({ userCode: normalizeCode(decodeURIComponent(m[1])) }, c);
          if (c.status === "approved" || c.status === "used") fail(409, "connect_code_used", "That code has already been used.");
          if (c.status === "expired") fail(404, "connect_code_invalid", "That code has expired.");
          if (m[2] === "deny") { c.status = "denied"; return { status: "denied" }; }
          c.status = "approved";
          return { deviceName: c.deviceName, ranked: false };
        }
        fail(404, "not_found", "Demo: no fixture for " + method + " " + path);
      });
    }

    if (state.connect.status === "used") state.connect.status = "approved";
    return { handle: handle, session: function () { return state.session; } };
  })();

  langLinks();
  if (PAGE === "login") loginPage();
  else if (PAGE === "account") accountPage();
  else if (PAGE === "connect") connectPage();
})();

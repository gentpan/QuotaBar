/* Quota Run 的示例数据（?demo=1）。common.js 只在示例模式下按需加载这个文件。
 *
 * 按公开接口的路径和查询串作答，形状照 docs/quota-run.md：/boards、/leaderboard（含 summary 和
 * to90/to50）、/runs/<runId>（用量曲线）、/insights、/users/<username>、/stats。
 * 人和成绩按种子生成，每次打开都一样；时间相对「现在」。Codex Pro 20x 本周的前六名与设计稿一致。
 *   &empty=1   没有任何榜单（线上刚开张时访客看到的样子）
 *   &fail=1    接口出错
 */
(function () {
  "use strict";

  var Q = window.QuotaRun;
  var params = new URLSearchParams(location.search);
  var NOW = Math.floor(Date.now() / 1000);
  var WEEK = Q.weekStart(Date.now());
  var EMPTY = params.get("empty") === "1";
  var FAIL = params.get("fail") === "1";
  var SEASONS = ["current", "last", "all"];

  function hashText(text) {
    var h = 2166136261;
    for (var i = 0; i < text.length; i++) { h ^= text.charCodeAt(i); h = Math.imul(h, 16777619); }
    return h >>> 0;
  }

  function rng(seed) {
    var a = hashText(seed);
    return function () {
      a = (a + 0x6d2b79f5) | 0;
      var x = Math.imul(a ^ (a >>> 15), 1 | a);
      x = (x + Math.imul(x ^ (x >>> 7), 61 | x)) ^ x;
      return ((x ^ (x >>> 14)) >>> 0) / 4294967296;
    };
  }

  var ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
  function makeRunId(seed) {
    var r = rng("run:" + seed), s = "";
    for (var i = 0; i < 12; i++) s += ALPHABET.charAt(Math.floor(r() * 64));
    return s;
  }

  /* ── 人 ───────────────────────────────────────────────────────────── */

  var FIXED = [
    ["hweiss", "Hannah Weiss", "global"], ["ayaan", "Ayaan Rao", "global"], ["mika", "Mika Laine", "global"],
    ["peter", "Peter", "global"], ["linxiao", "林晓", "china"], ["devon", "Devon Park", "global"],
  ];
  var MORE = [
    ["sora", "Sora Tanaka", "global"], ["chenyu", "陈宇", "china"], ["juno", "juno", "global"], ["kasia", "Kasia Nowak", "global"],
    ["wangwei", "王玮", "china"], ["tomas", "Tomás Ruiz", "global"], ["rin_dev", "Rin", "global"], ["oskar", "Oskar Berg", "global"],
    ["lea-m", "Léa Martin", "global"], ["zhouyu", "周屿", "china"], ["yuki", "Yuki Mori", "global"], ["baozi", "包子", "china"],
  ];
  var GIVEN = ["Alex", "Sam", "Priya", "Marco", "Nina", "Omar", "Lena", "Diego", "Ivy", "Theo", "Maya", "Felix", "Aiko", "Jonas", "Sara", "Luca", "Noor", "Ravi", "Elena", "Kai", "Zoe", "Hugo", "Mei", "Arjun"];
  var FAMILY = ["Kim", "Silva", "Novak", "Chen", "Haddad", "Berg", "Okafor", "Rossi", "Sato", "Patel", "Müller", "Costa", "Lind", "Moreau", "Ito", "Khan"];
  var CN_GIVEN = ["子涵", "浩然", "思远", "雨桐", "一鸣", "欣怡", "俊杰", "晓峰", "嘉怡", "宇航", "梓萱", "文博"];
  var CN_FAMILY = ["李", "王", "张", "刘", "陈", "杨", "赵", "黄", "周", "吴", "徐", "孙"];
  var CN_PINYIN = ["li", "wang", "zhang", "liu", "chen", "yang", "zhao", "huang", "zhou", "wu", "xu", "sun"];

  var PEOPLE = FIXED.concat(MORE);
  var PERSON = {};
  PEOPLE.forEach(function (p) { PERSON[p[0]] = p; });
  (function () {
    var r = rng("people");
    while (PEOPLE.length < 1100) {
      var china = r() < 0.3, username, name;
      if (china) {
        var f = Math.floor(r() * CN_FAMILY.length);
        name = CN_FAMILY[f] + CN_GIVEN[Math.floor(r() * CN_GIVEN.length)];
        username = CN_PINYIN[f] + (10 + Math.floor(r() * 990));
      } else {
        var g = GIVEN[Math.floor(r() * GIVEN.length)], fam = FAMILY[Math.floor(r() * FAMILY.length)], style = r();
        name = g + " " + fam;
        username = (style < 0.4 ? g + fam.charAt(0) : style < 0.7 ? g + "_" + fam : g.charAt(0) + fam)
          .toLowerCase().normalize("NFD").replace(/[^a-z0-9_]/g, "");
      }
      if (PERSON[username]) username = (username + (10 + Math.floor(r() * 90))).slice(0, 20);
      if (PERSON[username] || !Q.USERNAME.test(username)) continue;
      var person = [username, name, china ? "china" : "global"];
      PERSON[username] = person;
      PEOPLE.push(person);
    }
  })();

  /* ── 榜单 ─────────────────────────────────────────────────────────── */

  // fast / med / p90：用满时已过去的窗口比例；done：用满的人占比
  var BOARDS = [
    { provider: "codex", plan: "pro20x", planLabel: "Pro 20x", windowKey: "604800:", windowSeconds: 604800, windowTitle: "Weekly window", runners: 386, fast: 0.163, med: 0.32, p90: 0.68, done: 0.61 },
    { provider: "codex", plan: "plus", planLabel: "Plus", windowKey: "18000:", windowSeconds: 18000, windowTitle: "5-hour window", runners: 298, fast: 0.3, med: 0.62, p90: 0.88, done: 0.7 },
    { provider: "claude", plan: "max20x", planLabel: "Max 20x", windowKey: "18000:", windowSeconds: 18000, windowTitle: "5-hour window", runners: 342, fast: 0.38, med: 0.71, p90: 0.86, done: 0.83 },
    { provider: "claude", plan: "max20x", planLabel: "Max 20x", windowKey: "604800:", windowSeconds: 604800, windowTitle: "Weekly window", runners: 211, fast: 0.18, med: 0.44, p90: 0.76, done: 0.58 },
    { provider: "cursor", plan: "proplus", planLabel: "Pro+", windowKey: "2592000:", windowSeconds: 2592000, windowTitle: "Monthly window", runners: 57, fast: 0.15, med: 0.38, p90: 0.77, done: 0.47 },
    { provider: "grok", plan: "supergrok", planLabel: "SuperGrok", windowKey: "604800:", windowSeconds: 604800, windowTitle: "Weekly window", runners: 23, fast: 0.21, med: 0.55, p90: 0.81, done: 0.39 },
  ];

  // 设计稿里的前六名：[用满, 到 50%, 到 90%, 级别, 账号已核实, 本季轮次]
  var MOCK_TOP = {
    hweiss: [98468, 57720, 85200, "verified", true, 3],
    ayaan: [103824, 72660, 93720, "verified", false, 2],
    mika: [113282, 52800, 98100, "standard", false, 1],
    peter: [119640, 72000, 106200, "verified", true, 4],
    linxiao: [129180, 76680, 111720, "verified", false, 2],
    devon: [134580, 71220, 119400, "verified", false, 5],
  };

  function publicBoard(b) {
    return { provider: b.provider, plan: b.plan, planLabel: b.planLabel, windowKey: b.windowKey, windowSeconds: b.windowSeconds, windowTitle: b.windowTitle };
  }

  function findBoard(provider, plan, windowKey) {
    return BOARDS.filter(function (b) { return b.provider === provider && b.plan === (plan || "") && b.windowKey === windowKey; })[0];
  }

  var populations = {};

  // 一张榜在一个赛季里的全部参赛者，每人一条最好的成绩（示例里速度和峰值取同一轮）
  function population(b, season) {
    var key = Q.boardKey(b) + "|" + season;
    if (populations[key]) return populations[key];
    var r = rng(key);
    var W = b.windowSeconds;
    var size = Math.round(b.runners * { current: 1, last: 0.89, before: 0.84, all: 2.3 }[season]);
    var slow = { current: 1, last: 1.03, before: 1.05, all: 0.94 }[season];
    var mock = b.provider === "codex" && b.plan === "pro20x" && season === "current";

    // 洗牌抽人；设计稿那张榜上固定的六个人排在最前，别的榜上把他们（或者只有 peter）插进随机的位置
    var pool = PEOPLE.slice(FIXED.length);
    for (var i = pool.length - 1; i > 0; i--) {
      var j = Math.floor(r() * (i + 1));
      var swap = pool[i]; pool[i] = pool[j]; pool[j] = swap;
    }
    var people;
    if (mock) {
      people = FIXED.concat(pool).slice(0, size);
    } else {
      people = pool.slice(0, size - 1);
      (b.provider === "codex" || b.provider === "claude" ? FIXED : [PERSON.peter]).forEach(function (guest) {
        people.splice(Math.floor(r() * people.length * (guest[0] === "peter" ? 0.35 : 0.8)), 0, guest);
      });
      people = people.slice(0, size);
    }

    // 按排位均匀取 u，再用幂次把中位数压到 med：base + (1 − base)·0.5^k = med
    var base = mock ? 136000 / W : b.fast * slow;
    var k = Math.log(Math.max(0.01, (b.med * slow - base) / (1 - base))) / Math.log(0.5);
    var completers = Math.round(size * b.done);
    var start = WEEK - { current: 0, last: 1, before: 2, all: 8 }[season] * 604800;

    var rows = people.map(function (p, index) {
      // 全部赛季里，这六个人的历史最好比本周快一点
      var fixed = (mock || (season === "all" && b.provider === "codex" && b.plan === "pro20x")) && MOCK_TOP[p[0]];
      var factor = mock ? 1 : 0.9 + r() * 0.06;
      var rec = { username: p[0], displayName: p[1], region: p[2] };
      var done = fixed || index < completers || p[0] === "peter";
      var to100 = null, peak;
      if (fixed) {
        to100 = Math.round(fixed[0] * factor);
      } else if (done) {
        var u = Math.min(0.95, (index + r() * 0.9) / Math.max(1, completers));
        to100 = Math.round(W * (base + (1 - base) * Math.pow(u, k)));
      }
      if (to100 != null) {
        peak = 100;
        rec.secondsTo100 = to100;
        rec.secondsTo50 = fixed ? Math.round(fixed[1] * factor) : Math.round(to100 * (0.44 + r() * 0.2));
        rec.secondsTo90 = fixed ? Math.round(fixed[2] * factor) : Math.round(to100 * (0.8 + r() * 0.12));
      } else {
        peak = Math.round((52 + r() * 47.5) * 2) / 2;
        var reach = W * (0.35 + r() * 0.6);
        rec.secondsTo50 = Math.round(reach * (0.4 + r() * 0.3));
        rec.secondsTo90 = peak >= 90 ? Math.round(reach * (0.85 + r() * 0.1)) : null;
        rec.secondsTo100 = null;
        rec.lastSeconds = Math.round(reach);
      }
      rec.peakPercent = peak;
      rec.tier = fixed ? fixed[3] : p[0] === "peter" ? "verified" : r() < 0.71 ? "verified" : "standard";
      rec.accountVerified = fixed ? fixed[4] : p[0] === "peter" ? b.provider !== "claude" : r() < 0.62 && rec.tier === "verified" ? true : r() < 0.12;
      rec.seasonRuns = fixed ? fixed[5] : 1 + Math.floor(Math.pow(r(), 1.8) * 5);
      if (season === "all") rec.seasonRuns += 3 + Math.floor(r() * 12);
      rec.windowStart = Math.round(start + r() * (season === "current" ? Math.max(3600, NOW - WEEK - (to100 || 0)) : 6 * 86400));
      rec.runId = makeRunId(key + "|" + p[0]);
      return rec;
    });
    rows.board = b;
    rows.season = season;
    populations[key] = rows;
    return rows;
  }

  var byRunId = null;
  function runIndex() {
    if (byRunId) return byRunId;
    byRunId = {};
    BOARDS.forEach(function (b) {
      SEASONS.forEach(function (season) {
        population(b, season).forEach(function (rec) { byRunId[rec.runId] = { board: b, season: season, rec: rec }; });
      });
    });
    return byRunId;
  }

  function metricValue(rec, metric) {
    return metric === "to90" ? rec.secondsTo90 : metric === "to50" ? rec.secondsTo50 : metric === "peak" ? rec.peakPercent : rec.secondsTo100;
  }

  function ranked(rows, metric) {
    var list = rows.filter(function (rec) { return metricValue(rec, metric) != null; });
    list.sort(function (a, b) {
      return metric === "peak"
        ? b.peakPercent - a.peakPercent || (a.windowStart + (a.secondsTo100 || a.lastSeconds)) - (b.windowStart + (b.secondsTo100 || b.lastSeconds))
        : metricValue(a, metric) - metricValue(b, metric) || a.windowStart - b.windowStart;
    });
    return list;
  }

  function filtered(rows, region, tier) {
    return rows.filter(function (rec) { return (!region || rec.region === region) && (tier !== "verified" || rec.tier === "verified"); });
  }

  function seasonOf(raw) {
    if (!raw || raw === "current" || raw === Q.isoWeek(Date.now())) return "current";
    if (raw === "all") return "all";
    return "last";
  }

  function seasonName(season) {
    return season === "all" ? "all" : Q.isoWeek(Date.now() - (season === "last" ? 7 : 0) * 86400000);
  }

  function entry(rec, rank, metric) {
    var value = metricValue(rec, metric);
    return {
      rank: rank, username: rec.username, displayName: rec.displayName, value: value,
      unit: metric === "peak" ? "percent" : "seconds", tier: rec.tier, accountVerified: rec.accountVerified,
      achievedAt: metric === "peak" ? rec.windowStart + (rec.secondsTo100 || rec.lastSeconds) : rec.windowStart + value,
      peakPercent: rec.peakPercent, runId: rec.runId,
      secondsTo50: rec.secondsTo50, secondsTo90: rec.secondsTo90, secondsTo100: rec.secondsTo100, seasonRuns: rec.seasonRuns,
    };
  }

  function lowerMedian(sorted) {
    return sorted.length ? sorted[Math.floor((sorted.length - 1) / 2)] : null;
  }

  function summary(rows, prevRows) {
    var done = ranked(rows, "speed");
    var median = lowerMedian(done);
    var verified = rows.filter(function (rec) { return rec.tier === "verified"; }).length;
    var acct = rows.filter(function (rec) { return rec.accountVerified; }).length;
    var prevDone = prevRows ? ranked(prevRows, "speed") : null;
    var prevMedian = prevDone ? lowerMedian(prevDone) : null;
    var n = rows.length;
    return {
      runners: n,
      runnersPrev: prevRows ? prevRows.length : null,
      fastest: done.length ? { username: done[0].username, displayName: done[0].displayName, seconds: done[0].secondsTo100, runId: done[0].runId } : null,
      medianSecondsTo100: median ? median.secondsTo100 : null,
      medianSecondsTo100Prev: prevMedian ? prevMedian.secondsTo100 : null,
      medianRunId: median ? median.runId : null,
      completed: done.length,
      completedShare: n ? done.length / n : null,
      verifiedShare: n ? verified / n : null,
      accountVerifiedShare: n ? acct / n : null,
    };
  }

  /* ── 各个接口 ─────────────────────────────────────────────────────── */

  function boards(q) {
    var season = seasonOf(q.get("season"));
    var region = q.get("region") || "";
    if (EMPTY) return { boards: [] };
    var list = BOARDS.map(function (b) {
      return Object.assign(publicBoard(b), { runners: filtered(population(b, season), region, "all").length, season: seasonName(season) });
    }).filter(function (b) { return b.runners > 0; });
    list.sort(function (a, b) { return b.runners - a.runners; });
    return { boards: list };
  }

  function leaderboard(q) {
    var metric = q.get("metric") || "speed";
    if (["speed", "to90", "to50", "peak"].indexOf(metric) < 0) throw status(400, "invalid_metric");
    var season = seasonOf(q.get("season"));
    var region = q.get("region") || "";
    var tier = q.get("tier") || "all";
    var limit = Math.min(200, Number(q.get("limit")) || 100);
    var b = findBoard(q.get("provider"), q.get("plan"), q.get("window"));
    var meta = b ? publicBoard(b) : { provider: q.get("provider"), plan: q.get("plan") || "", planLabel: null, windowKey: q.get("window"), windowSeconds: Number(String(q.get("window")).split(":")[0]) || 0, windowTitle: null };
    var rows = b && !EMPTY ? filtered(population(b, season), region, tier) : [];
    var prev = b && !EMPTY && season !== "all" ? filtered(population(b, season === "current" ? "last" : "before"), region, tier) : null;
    var list = ranked(rows, metric).slice(0, limit);
    return {
      board: Object.assign(meta, { runners: rows.length, season: seasonName(season) }),
      season: seasonName(season), metric: metric,
      entries: list.map(function (rec, i) { return entry(rec, i + 1, metric); }),
      summary: summary(rows, season === "all" ? null : prev || []),
      updatedAt: NOW - 140,
    };
  }

  // 用量曲线：从窗口开始（或加入时）到用满，大约每 20 分钟一条读数，最多 240 个点
  function readings(board, rec) {
    var r = rng("readings:" + rec.runId);
    var end = rec.secondsTo100 != null ? rec.secondsTo100 : rec.lastSeconds;
    var knots = [[0, 0], [rec.secondsTo50, 50]];
    if (rec.secondsTo90 != null) knots.push([rec.secondsTo90, 90]);
    knots.push([end, rec.secondsTo100 != null ? 99.6 : rec.peakPercent]);
    var step = Math.max(300, end / 110);
    var first = Math.round(r() * Math.min(step * 2, rec.secondsTo50 * 0.2));
    var out = [];
    var last = 0;
    for (var t = first; t < end; t += step * (0.6 + r() * 0.8)) {
      var i = 1;
      while (i < knots.length - 1 && t > knots[i][0]) i++;
      var a = knots[i - 1], c = knots[i];
      var p = a[1] + (c[1] - a[1]) * (t - a[0]) / Math.max(1, c[0] - a[0]);
      p = Math.max(last, Math.min(c[1], p + (r() - 0.5) * 0.7));
      last = p;
      out.push({ t: Math.round(t), p: Math.round(p * 10) / 10 });
    }
    // 跨过 50 / 90 / 用满的第一条读数原样保留
    out = out.filter(function (x) { return !(x.p >= 50 && x.t < rec.secondsTo50) && !(rec.secondsTo90 != null && x.p >= 90 && x.t < rec.secondsTo90); });
    [[rec.secondsTo50, 50], [rec.secondsTo90, 90]].forEach(function (mark) {
      if (mark[0] != null) out.push({ t: mark[0], p: mark[1] });
    });
    out.push({ t: end, p: rec.secondsTo100 != null ? 100 : rec.peakPercent });
    out.sort(function (x, y) { return x.t - y.t; });
    for (var n = 1; n < out.length; n++) out[n].p = Math.max(out[n].p, out[n - 1].p);
    while (out.length > 240) out.splice(1 + Math.floor(r() * (out.length - 3)), 1);
    return out;
  }

  function run(id) {
    var found = runIndex()[id];
    if (!found || EMPTY) throw status(404, "run_not_found");
    var b = found.board, rec = found.rec;
    return {
      run: Object.assign(publicBoard(b), {
        runId: rec.runId, username: rec.username, displayName: rec.displayName,
        windowStart: rec.windowStart, resetsAt: rec.windowStart + b.windowSeconds, season: seasonName(found.season === "all" ? "last" : found.season),
        tier: rec.tier, accountVerified: rec.accountVerified, peakPercent: rec.peakPercent,
        secondsTo50: rec.secondsTo50, secondsTo90: rec.secondsTo90, secondsTo100: rec.secondsTo100,
        completedAt: rec.secondsTo100 != null ? rec.windowStart + rec.secondsTo100 : null,
      }),
      readings: readings(b, rec),
    };
  }

  function nearest(sorted, q) {
    return sorted.length ? sorted[Math.max(0, Math.ceil(q * sorted.length) - 1)] : null;
  }

  function insights(q) {
    var season = seasonOf(q.get("season"));
    var region = q.get("region") || "";
    if (EMPTY) return { season: seasonName(season), boards: [], updatedAt: NOW - 140 };
    var list = BOARDS.map(function (b) {
      var all = population(b, season);
      var rows = filtered(all, region, "all");
      var times = ranked(rows, "speed").map(function (rec) { return rec.secondsTo100; });
      function regionMedian(name) {
        var own = ranked(filtered(all, name, "all"), "speed").map(function (rec) { return rec.secondsTo100; });
        return lowerMedian(own);
      }
      return Object.assign(publicBoard(b), {
        runners: rows.length, completed: times.length, completedShare: rows.length ? times.length / rows.length : null,
        fastestSeconds: times.length ? times[0] : null, p10Seconds: nearest(times, 0.1), medianSeconds: lowerMedian(times), p90Seconds: nearest(times, 0.9),
        medianByRegion: { global: regionMedian("global"), china: regionMedian("china") },
      });
    }).filter(function (b) { return b.runners > 0; });
    list.sort(function (a, b) { return b.runners - a.runners; });
    return { season: seasonName(season), boards: list, updatedAt: NOW - 140 };
  }

  function stats() {
    return EMPTY ? { users: 0, runs: 0, verifiedRuns: 0, providers: 0, updatedAt: NOW } : { users: 1284, runs: 9312, verifiedRuns: 6127, providers: 9, updatedAt: NOW - 140 };
  }

  // 个人主页：最好成绩按全部赛季排名（速度、峰值各一条），最近几轮取本周和上周
  function user(username) {
    var person = PERSON[username];
    if (!person || EMPTY) throw status(404, "user_not_found");
    var bests = [], recent = [];
    BOARDS.forEach(function (b) {
      var all = population(b, "all");
      ["speed", "peak"].forEach(function (metric) {
        var list = ranked(all, metric);
        for (var i = 0; i < list.length; i++) {
          if (list[i].username !== username) continue;
          var rec = list[i];
          bests.push(Object.assign(publicBoard(b), {
            metric: metric, value: metricValue(rec, metric), unit: metric === "peak" ? "percent" : "seconds",
            rank: i + 1, runners: all.length, percentile: Math.max(1, Math.ceil((i + 1) * 100 / all.length)),
            tier: rec.tier, accountVerified: rec.accountVerified, season: seasonName("last"),
            achievedAt: rec.windowStart + (rec.secondsTo100 || rec.lastSeconds), runId: rec.runId,
            secondsTo50: rec.secondsTo50, secondsTo90: rec.secondsTo90, secondsTo100: rec.secondsTo100,
          }));
          break;
        }
      });
      ["current", "last"].forEach(function (season) {
        population(b, season).forEach(function (rec) {
          if (rec.username !== username) return;
          var end = rec.windowStart + (rec.secondsTo100 || rec.lastSeconds);
          recent.push(Object.assign(publicBoard(b), {
            runId: rec.runId, season: seasonName(season), windowStart: rec.windowStart, resetsAt: rec.windowStart + b.windowSeconds,
            peakPercent: rec.peakPercent, secondsTo50: rec.secondsTo50, secondsTo90: rec.secondsTo90, secondsTo100: rec.secondsTo100,
            completedAt: rec.secondsTo100 != null ? end : null, lastObservedAt: Math.min(NOW - 300, end), tier: rec.tier, accountVerified: rec.accountVerified,
          }));
        });
      });
    });
    // 一轮进行中的：窗口还没结束，也还没用满
    if (username === "peter") {
      var codex = BOARDS[0];
      recent.push(Object.assign(publicBoard(codex), {
        runId: makeRunId("live"), season: seasonName("current"), windowStart: NOW - 2 * 86400 - 7200, resetsAt: NOW - 2 * 86400 - 7200 + codex.windowSeconds,
        peakPercent: 64, secondsTo50: 132000, secondsTo90: null, secondsTo100: null, completedAt: null, lastObservedAt: NOW - 240,
        tier: "verified", accountVerified: true,
      }));
    }
    recent.sort(function (a, b) { return b.lastObservedAt - a.lastObservedAt; });
    var r = rng("user:" + username);
    var mine = username === "peter";
    return {
      username: person[0], displayName: person[1], region: person[2],
      joinedAt: NOW - Math.round((mine ? 38 : 10 + r() * 50) * 86400),
      bio: mine ? "Building QuotaBar. Burns a Codex week by Wednesday, mostly on purpose." : "",
      links: mine ? { website: "https://quota.bar", github: "https://github.com/gentpan", x: "" } : {},
      stats: mine ? { runs: 86, verifiedRuns: 71, providers: 3, activeDays: 41 }
        : { runs: 12 + Math.floor(r() * 60), verifiedRuns: 8 + Math.floor(r() * 30), providers: 2, activeDays: 6 + Math.floor(r() * 30) },
      bests: bests,
      recent: recent.slice(0, 8),
      projects: mine ? [
        { name: "QuotaBar", url: "https://quota.bar", github: "https://github.com/gentpan/QuotaBar", description: "Every AI coding limit, at a glance — in the macOS menu bar, the notch and on desktop cards.", builtWith: ["codex", "claude"] },
        { name: "Tidewire", url: "https://tidewire.example", github: "", description: "A small sync engine for local-first notes. Conflict-free merges, no server required.", builtWith: ["claude", "cursor"] },
        { name: "shiori-cli", url: "https://shiori.example/cli", github: "https://github.com/example/shiori-cli", description: "Bookmarks from the terminal, searchable offline, synced as plain Markdown.", builtWith: ["codex"] },
      ] : [],
    };
  }

  function status(code, error) {
    var e = new Error("Demo: " + error);
    e.status = code;
    e.code = error;
    return e;
  }

  function answer(path) {
    var at = path.indexOf("?");
    var route = at < 0 ? path : path.slice(0, at);
    var q = new URLSearchParams(at < 0 ? "" : path.slice(at + 1));
    var m;
    if (FAIL) throw status(503, "unavailable");
    if (route === "/boards") return boards(q);
    if (route === "/leaderboard") return leaderboard(q);
    if (route === "/insights") return insights(q);
    if (route === "/stats") return stats();
    if ((m = /^\/runs\/([A-Za-z0-9_-]{1,40})$/.exec(route))) return run(m[1]);
    if ((m = /^\/users\/([^\/]+)$/.exec(route))) return user(decodeURIComponent(m[1]));
    throw status(404, "not_found");
  }

  window.QuotaRunDemo = {
    get: function (path) {
      return new Promise(function (resolve, reject) {
        setTimeout(function () {
          try { resolve(JSON.parse(JSON.stringify(answer(path)))); } catch (error) { reject(error); }
        }, 120);
      });
    },
  };
})();

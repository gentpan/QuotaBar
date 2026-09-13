/* Quota Run 的示例数据（?demo=1）。common.js 只在示例模式下按需加载这个文件。
 *
 * 按公开接口的路径和查询串作答，形状照 docs/quota-run.md：/boards、/leaderboard（含 summary 和
 * to90/to50）、/runs/<runId>（用量曲线）、/insights、/users/<username>（含热力图）、/users/<username>/github、/stats。
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
      links: mine ? { website: "https://quota.bar", blog: "https://blog.example.com", github: "https://github.com/gentpan", x: null,
        bluesky: "https://bsky.app/profile/peter.example.com", mastodon: "https://mastodon.example/@peter" } : {},
      activity: activityOf(username),
      github: mine ? { login: "gentpan", url: "https://github.com/gentpan" } : null,
      badges: badgesOf(username),
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

  /* ── 用量：看板、项目、个人与项目页、实时事件 ─────────────────────── */

  var TOOL_IDS = ["claude", "codex", "opencode"];
  var MODE_IDS = ["desktop", "cli", "ide", "sdk"];
  var MODELS = { claude: ["claude-opus-5", "claude-sonnet-5", "claude-fable-5-1"], codex: ["gpt-5.6-codex", "gpt-5.6-sol"], opencode: ["opencode"] };
  var PROJECT_NAMES = ["Tidewire", "shiori-cli", "openimg", "atlas-api", "pixel-forge", "ledger-sync", "nebula-ui", "kit-cli", "rust-raft",
    "mdx-blog", "taskboard", "vector-kv", "ai-notes", "edge-proxy", "field-app", "data-pipe", "tiny-lsp", "render-farm"];
  var USAGE_COUNT = 180;
  var LIVE_BONUS = {};
  var usageMemo = {};

  function utcToday() {
    var d = new Date();
    return new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate()));
  }
  function iso(date) { return date.toISOString().slice(0, 10); }
  function addDays(date, n) { return new Date(date.getTime() + n * 86400000); }

  // 每个参与用量榜的人：日均花费、忙碌程度、工具偏好、公开的项目
  var usagePeople = null;
  function usersForUsage() {
    if (usagePeople) return usagePeople;
    usagePeople = PEOPLE.slice(0, USAGE_COUNT).map(function (p, index) {
      var r = rng("usage:" + p[0]);
      var mine = p[0] === "peter";
      var scale = mine ? 420 : Math.pow(r(), 2.4) * 900 + 8;
      var weights = mine ? [0.62, 0.34, 0.04] : [r() + 0.2, r() * 0.9, r() < 0.3 ? r() * 0.4 : 0];
      var total = weights[0] + weights[1] + weights[2];
      var projects = [];
      var count = mine ? 2 : r() < 0.55 ? 1 + Math.floor(r() * 3) : 0;
      for (var i = 0; i < count; i++) {
        var name = mine ? ["QuotaBar", "Tidewire"][i] : PROJECT_NAMES[Math.floor(r() * PROJECT_NAMES.length)];
        if (projects.some(function (x) { return x.name === name; })) continue;
        var slug = name.toLowerCase().replace(/[^a-z0-9]+/g, "-");
        var repoOwner = mine ? "gentpan" : p[0];
        var shared = !mine && r() < 0.25;   // 有些项目是好几个人一起做的同一个仓库
        projects.push({ id: "r" + String(index) + "p" + i, name: name, slug: slug, share: i === 0 ? 0.6 : 0.3,
          repo: r() < 0.8 ? "github.com/" + (shared ? "tidewire-labs" : repoOwner) + "/" + name : null, repoVerified: !shared && r() < 0.7 });
      }
      return { username: p[0], displayName: p[1], region: p[2], index: index, scale: scale, busy: mine ? 0.85 : 0.25 + r() * 0.65,
        weights: weights.map(function (w) { return w / total; }), verified: mine ? 0.85 : r(), projects: projects };
    });
    return usagePeople;
  }

  // 一个人一天：按工具分的花费、token、会话、分钟、是否核实，以及按项目分的花费
  function usageDay(person, key) {
    var memoKey = person.username + "|" + key;
    var day = usageMemo[memoKey];
    if (!day) {
      var r = rng("day:" + memoKey);
      var date = new Date(key + "T00:00:00Z");
      var age = (utcToday() - date) / 86400000;
      var weekend = date.getUTCDay() === 0 || date.getUTCDay() === 6;
      var active = age >= 0 && r() < person.busy * (weekend ? 0.6 : 1) * (age > 250 ? 0.4 : 1);
      day = { date: key, tools: {} };
      if (active) {
        var cost = person.scale * (0.2 + Math.pow(r(), 1.6) * 1.8);
        TOOL_IDS.forEach(function (tool, i) {
          var c = cost * person.weights[i] * (0.6 + r() * 0.8);
          if (c < 0.05) return;
          day.tools[tool] = { cost: c, tokens: Math.round(c * (tool === "codex" ? 520000 : 780000)), sessions: 1 + Math.floor(r() * 6),
            minutes: 10 + Math.floor(r() * 240), verified: tool !== "opencode" && r() < person.verified, mode: MODE_IDS[Math.floor(r() * (tool === "opencode" ? 2 : 4))] };
        });
      }
      usageMemo[memoKey] = day;
    }
    var bonus = LIVE_BONUS[person.username] && LIVE_BONUS[person.username][key];
    if (!bonus) return day;
    var copy = { date: key, tools: JSON.parse(JSON.stringify(day.tools)) };
    var claude = copy.tools.claude || (copy.tools.claude = { cost: 0, tokens: 0, sessions: 1, minutes: 5, verified: true, mode: "desktop" });
    claude.cost += bonus;
    claude.tokens += Math.round(bonus * 780000);
    return copy;
  }

  function dayTotals(day, tool, verifiedOnly) {
    var out = { cost: 0, tokens: 0, sessions: 0, minutes: 0, verifiedCost: 0, byTool: {} };
    Object.keys(day.tools).forEach(function (id) {
      var t = day.tools[id];
      if (tool && id !== tool) return;
      if (verifiedOnly && !t.verified) return;
      out.cost += t.cost;
      out.tokens += t.tokens;
      out.sessions += t.sessions;
      out.minutes += t.minutes;
      if (t.verified) out.verifiedCost += t.cost;
      out.byTool[id] = (out.byTool[id] || 0) + t.cost;
    });
    return out;
  }

  function periodRange(period) {
    var today = utcToday();
    var monday = addDays(today, -((today.getUTCDay() + 6) % 7));
    if (period === "last") return [addDays(monday, -7), addDays(monday, -1), [addDays(monday, -14), addDays(monday, -8)]];
    if (period === "month") {
      var first = new Date(Date.UTC(today.getUTCFullYear(), today.getUTCMonth(), 1));
      var last = new Date(Date.UTC(today.getUTCFullYear(), today.getUTCMonth() + 1, 0));
      var prevLast = addDays(first, -1);
      return [first, last, [new Date(Date.UTC(prevLast.getUTCFullYear(), prevLast.getUTCMonth(), 1)), prevLast]];
    }
    if (period === "all") return [addDays(today, -364), today, null];
    return [monday, addDays(monday, 6), [addDays(monday, -7), addDays(monday, -1)]];
  }

  function eachDate(from, to, fn) {
    for (var d = from; d <= to; d = addDays(d, 1)) fn(iso(d));
  }

  function round2(n) { return Math.round(n * 100) / 100; }

  function streakOf(person, tool, verifiedOnly) {
    var today = utcToday();
    var cursor = dayTotals(usageDay(person, iso(today)), tool, verifiedOnly).tokens > 0 ? today : addDays(today, -1);
    var n = 0;
    while (n < 400 && dayTotals(usageDay(person, iso(cursor)), tool, verifiedOnly).tokens > 0) { n++; cursor = addDays(cursor, -1); }
    return n;
  }

  function totalsFor(person, from, to, tool, verifiedOnly) {
    var out = { cost: 0, tokens: 0, days: 0, sessions: 0, verifiedCost: 0, byTool: {}, projects: {} };
    eachDate(from, to, function (key) {
      var d = dayTotals(usageDay(person, key), tool, verifiedOnly);
      if (!d.tokens) return;
      out.cost += d.cost;
      out.tokens += d.tokens;
      out.sessions += d.sessions;
      out.verifiedCost += d.verifiedCost;
      out.days += 1;
      Object.keys(d.byTool).forEach(function (id) { out.byTool[id] = (out.byTool[id] || 0) + d.byTool[id]; });
    });
    return out;
  }

  function rankPeople(metric, from, to, tool, region, verifiedOnly) {
    return usersForUsage().filter(function (p) { return !region || p.region === region; }).map(function (p) {
      var total = totalsFor(p, from, to, tool, verifiedOnly);
      var value = metric === "tokens" ? total.tokens : metric === "active" ? total.days : metric === "streak" ? (total.tokens ? streakOf(p, tool, verifiedOnly) : 0) : total.cost;
      return { person: p, total: total, value: value };
    }).filter(function (row) { return row.value > 0; }).sort(function (a, b) { return b.value - a.value || b.total.tokens - a.total.tokens; });
  }

  function usageBoard(q) {
    var metric = q.get("metric") || "cost", period = q.get("period") || "week";
    var tool = q.get("tool") || null, region = q.get("region") || null, verified = q.get("verified") !== "0";
    var limit = Math.min(200, Number(q.get("limit")) || 100);
    var range = periodRange(period);
    var ranked = rankPeople(metric, range[0], range[1], tool, region, verified);
    var previous = {};
    if (range[2] && metric !== "streak") {
      rankPeople(metric, range[2][0], range[2][1], tool, region, verified).forEach(function (row, i) { previous[row.person.username] = i + 1; });
    }
    var entries = ranked.slice(0, limit).map(function (row, i) {
      var p = row.person, before = previous[p.username];
      var top = p.projects[0];
      return {
        rank: i + 1, username: p.username, displayName: p.displayName, region: p.region,
        value: metric === "cost" ? round2(row.value) : row.value, unit: { cost: "usd", tokens: "tokens", streak: "days", active: "days" }[metric],
        costUSD: round2(row.total.cost), tokens: row.total.tokens, activeDays: row.total.days, sessions: row.total.sessions,
        verifiedShare: row.total.cost ? Math.round(row.total.verifiedCost / row.total.cost * 10000) / 10000 : null,
        tools: Object.keys(row.total.byTool).map(function (id) { return { tool: id, costUSD: round2(row.total.byTool[id]) }; }).sort(function (a, b) { return b.costUSD - a.costUSD; }),
        topProject: top ? { name: top.name, slug: top.slug } : null,
        change: before ? before - (i + 1) : null, new: Object.keys(previous).length > 0 && !before,
      };
    });
    var chartFrom = period === "all" ? addDays(utcToday(), -89) : range[0];
    var chartTo = period === "all" ? utcToday() : range[1];
    var daily = [];
    eachDate(chartFrom, chartTo, function (key) {
      var sum = { date: key, costUSD: 0, tokens: 0, byTool: {} };
      ranked.forEach(function (row) {
        var d = dayTotals(usageDay(row.person, key), tool, verified);
        sum.costUSD += d.cost;
        sum.tokens += d.tokens;
        Object.keys(d.byTool).forEach(function (id) { sum.byTool[id] = round2((sum.byTool[id] || 0) + d.byTool[id]); });
      });
      sum.costUSD = round2(sum.costUSD);
      daily.push(sum);
    });
    var byTool = {};
    daily.forEach(function (d) { Object.keys(d.byTool).forEach(function (id) { byTool[id] = round2((byTool[id] || 0) + d.byTool[id]); }); });
    return {
      metric: metric, period: period, from: iso(range[0]), to: iso(range[1]), tool: tool, region: region, verified: verified, entries: entries,
      summary: {
        runners: ranked.length, costUSD: round2(ranked.reduce(function (s, r) { return s + r.total.cost; }, 0)),
        tokens: ranked.reduce(function (s, r) { return s + r.total.tokens; }, 0), sessions: ranked.reduce(function (s, r) { return s + r.total.sessions; }, 0),
        byTool: Object.keys(byTool).map(function (id) { return { tool: id, costUSD: byTool[id] }; }).sort(function (a, b) { return b.costUSD - a.costUSD; }),
        daily: daily,
      },
      updatedAt: NOW,
    };
  }

  // 一个项目一天的份额：第一个项目占六成，别的三成，按日期稍微摆动
  function projectDay(person, project, key) {
    var d = usageDay(person, key);
    var r = rng("pd:" + project.id + key)();
    var out = { date: key, tools: {} };
    Object.keys(d.tools).forEach(function (id) {
      var t = d.tools[id], f = project.share * (0.7 + r * 0.6);
      out.tools[id] = { cost: t.cost * f, tokens: Math.round(t.tokens * f), sessions: Math.max(1, Math.round(t.sessions * f)), minutes: Math.round(t.minutes * f), verified: t.verified, mode: t.mode };
    });
    return out;
  }

  function projectRows(from, to, tool) {
    var rows = [];
    usersForUsage().forEach(function (p) {
      p.projects.forEach(function (project) {
        var total = { cost: 0, tokens: 0, sessions: 0, minutes: 0, days: 0, byTool: {} };
        eachDate(from, to, function (key) {
          var d = dayTotals(projectDay(p, project, key), tool, false);
          if (!d.tokens) return;
          total.cost += d.cost; total.tokens += d.tokens; total.sessions += d.sessions; total.minutes += d.minutes; total.days += 1;
          Object.keys(d.byTool).forEach(function (id) { total.byTool[id] = (total.byTool[id] || 0) + d.byTool[id]; });
        });
        if (total.tokens) rows.push({ person: p, project: project, total: total });
      });
    });
    return rows.sort(function (a, b) { return b.total.cost - a.total.cost; });
  }

  function projectBrief(project) {
    return { id: project.id, name: project.name, slug: project.slug, repo: project.repo, repoVerified: project.repoVerified };
  }

  function projectBoard(q) {
    var period = q.get("period") || "week", tool = q.get("tool") || null;
    var range = periodRange(period);
    var rows = projectRows(range[0], range[1], tool);
    var before = {};
    if (range[2]) projectRows(range[2][0], range[2][1], tool).forEach(function (row) { before[row.project.id] = row.total.cost; });
    var today = utcToday();
    return {
      period: period, from: iso(range[0]), to: iso(range[1]), tool: tool,
      entries: rows.slice(0, Math.min(100, Number(q.get("limit")) || 50)).map(function (row, i) {
        var spark = [];
        for (var k = 13; k >= 0; k--) spark.push(round2(dayTotals(projectDay(row.person, row.project, iso(addDays(today, -k))), tool, false).cost));
        return {
          rank: i + 1, project: projectBrief(row.project), owner: { username: row.person.username, displayName: row.person.displayName },
          costUSD: round2(row.total.cost), tokens: row.total.tokens, sessions: row.total.sessions, activeMinutes: row.total.minutes, activeDays: row.total.days,
          tools: Object.keys(row.total.byTool).map(function (id) { return { tool: id, costUSD: round2(row.total.byTool[id]) }; }).sort(function (a, b) { return b.costUSD - a.costUSD; }),
          growth: before[row.project.id] ? Math.round((row.total.cost / before[row.project.id] - 1) * 10000) / 10000 : null,
          spark: spark,
        };
      }),
      summary: { projects: rows.length, costUSD: round2(rows.reduce(function (s, r) { return s + r.total.cost; }, 0)), tokens: rows.reduce(function (s, r) { return s + r.total.tokens; }, 0) },
      updatedAt: NOW,
    };
  }

  // 个人或项目的一年：日序列、窗口合计、连续、工具、方式、模型
  function yearOf(dayFn) {
    var today = utcToday(), from = addDays(today, -370);
    var list = [], tools = {}, modes = {}, models = {};
    eachDate(from, today, function (key) {
      var d = dayFn(key);
      var sum = { date: key, costUSD: 0, tokens: 0, sessions: 0, activeMinutes: 0, verifiedCostUSD: 0, byTool: {} };
      Object.keys(d.tools).forEach(function (id) {
        var t = d.tools[id];
        sum.costUSD += t.cost; sum.tokens += t.tokens; sum.sessions += t.sessions; sum.activeMinutes += t.minutes;
        if (t.verified) sum.verifiedCostUSD += t.cost;
        sum.byTool[id] = round2(t.cost);
        tools[id] = tools[id] || { tool: id, costUSD: 0, tokens: 0 };
        tools[id].costUSD += t.cost; tools[id].tokens += t.tokens;
        var mk = id + "|" + t.mode;
        modes[mk] = modes[mk] || { tool: id, mode: t.mode, costUSD: 0, tokens: 0 };
        modes[mk].costUSD += t.cost; modes[mk].tokens += t.tokens;
        MODELS[id].forEach(function (model, n) {
          var share = MODELS[id].length === 1 ? 1 : n === 0 ? 0.7 : 0.3 / (MODELS[id].length - 1);
          models[model] = models[model] || { model: model, tool: id, costUSD: 0, tokens: 0 };
          models[model].costUSD += t.cost * share; models[model].tokens += Math.round(t.tokens * share);
        });
      });
      if (sum.tokens) {
        sum.costUSD = round2(sum.costUSD);
        sum.verifiedCostUSD = round2(sum.verifiedCostUSD);
        list.push(sum);
      }
    });
    function windowTotals(a, b) {
      var picked = list.filter(function (d) { return d.date >= iso(a) && d.date <= iso(b); });
      return { costUSD: round2(picked.reduce(function (s, d) { return s + d.costUSD; }, 0)), tokens: picked.reduce(function (s, d) { return s + d.tokens; }, 0),
        sessions: picked.reduce(function (s, d) { return s + d.sessions; }, 0), activeMinutes: picked.reduce(function (s, d) { return s + d.activeMinutes; }, 0),
        activeDays: picked.length, verifiedCostUSD: round2(picked.reduce(function (s, d) { return s + d.verifiedCostUSD; }, 0)) };
    }
    var active = {};
    list.forEach(function (d) { active[d.date] = true; });
    var longest = 0, run = 0;
    eachDate(from, today, function (key) { run = active[key] ? run + 1 : 0; longest = Math.max(longest, run); });
    var current = 0, cursor = active[iso(today)] ? today : addDays(today, -1);
    while (active[iso(cursor)]) { current++; cursor = addDays(cursor, -1); }
    var week = periodRange("week"), month = periodRange("month");
    function values(map) { return Object.keys(map).map(function (k) { var v = map[k]; v.costUSD = round2(v.costUSD); return v; }).sort(function (a, b) { return b.costUSD - a.costUSD; }); }
    return {
      from: iso(from), to: iso(today), days: list,
      totals: { week: windowTotals(week[0], week[1]), month: windowTotals(month[0], month[1]), all: windowTotals(addDays(today, -364), today) },
      streaks: { current: current, longest: longest },
      tools: values(tools), modes: values(modes), models: values(models).slice(0, 10),
    };
  }

  function userUsage(username) {
    var person = usersForUsage().filter(function (p) { return p.username === username; })[0];
    if (!person) {
      if (!PERSON[username]) throw status(404, "user_not_found");
      return { username: username, timezone: "UTC", from: iso(addDays(utcToday(), -370)), to: iso(utcToday()), days: [],
        totals: { week: {}, month: {}, all: { costUSD: 0, tokens: 0 } }, streaks: { current: 0, longest: 0 }, ranks: { week: { rank: null, runners: 0 }, all: { rank: null, runners: 0 } },
        tools: [], modes: [], models: [], projects: [], updatedAt: NOW };
    }
    var year = yearOf(function (key) { return usageDay(person, key); });
    var week = usageBoard(new URLSearchParams("period=week&limit=200")), all = usageBoard(new URLSearchParams("period=all&limit=200"));
    function rankIn(board) { var e = board.entries.filter(function (x) { return x.username === username; })[0]; return { rank: e ? e.rank : null, runners: board.summary.runners }; }
    var boardRanks = {};
    projectBoard(new URLSearchParams("period=week&limit=100")).entries.forEach(function (e) { boardRanks[e.project.id] = e.rank; });
    var today = utcToday();
    var projects = person.projects.map(function (project) {
      var py = yearOf(function (key) { return projectDay(person, project, key); });
      var spark = [];
      for (var k = 29; k >= 0; k--) {
        var key = iso(addDays(today, -k));
        var hit = py.days.filter(function (d) { return d.date === key; })[0];
        spark.push(hit ? hit.costUSD : 0);
      }
      return Object.assign(projectBrief(project), { costUSD: py.totals.all.costUSD, tokens: py.totals.all.tokens, sessions: py.totals.all.sessions,
        activeMinutes: py.totals.all.activeMinutes, weekCostUSD: py.totals.week.costUSD, lastDate: py.days.length ? py.days[py.days.length - 1].date : null,
        tools: py.tools.map(function (x) { return x.tool; }), rank: boardRanks[project.id] || null, spark: spark });
    });
    return Object.assign(year, { username: username, timezone: "Asia/Shanghai", ranks: { week: rankIn(week), all: rankIn(all) }, projects: projects, updatedAt: NOW });
  }

  function projectDetail(username, slug) {
    var person = usersForUsage().filter(function (p) { return p.username === username; })[0];
    var project = person && person.projects.filter(function (x) { return x.slug === String(slug).toLowerCase(); })[0];
    if (!project) throw status(404, "project_not_found");
    var year = yearOf(function (key) { return projectDay(person, project, key); });
    function rankIn(period) {
      var board = projectBoard(new URLSearchParams("period=" + period + "&limit=100"));
      var e = board.entries.filter(function (x) { return x.project.id === project.id; })[0];
      return { rank: e ? e.rank : null, projects: board.summary.projects };
    }
    var contributors = [];
    if (project.repo) {
      usersForUsage().forEach(function (p) {
        p.projects.forEach(function (x) {
          if (x.repo && x.repo.toLowerCase() === project.repo.toLowerCase()) {
            contributors.push({ username: p.username, displayName: p.displayName, slug: x.slug, name: x.name, repoVerified: x.repoVerified,
              costUSD: yearOf(function (key) { return projectDay(p, x, key); }).totals.all.costUSD, self: x.id === project.id });
          }
        });
      });
      contributors.sort(function (a, b) { return b.costUSD - a.costUSD; });
    }
    var github = project.repo && /^github\.com\//i.test(project.repo) ? {
      repo: project.repo.slice("github.com/".length), url: "https://" + project.repo, description: "A demo repository", stars: 180 + person.index * 7,
      forks: 12 + person.index, language: ["TypeScript", "Swift", "Rust", "Go", "Python"][person.index % 5], pushedAt: NOW - 7200, archived: false,
      weeks: Array.from({ length: 52 }, function (_, i) { return i < 12 ? 0 : Math.floor(rng("w" + project.id + i)() * 60); }), commits: 1400, fetchedAt: NOW - 3600,
    } : null;
    return Object.assign(year, {
      project: projectBrief(project), owner: { username: person.username, displayName: person.displayName, region: person.region },
      firstDate: year.days.length ? year.days[0].date : null, lastDate: year.days.length ? year.days[year.days.length - 1].date : null,
      ranks: { week: rankIn("week"), all: rankIn("all") },
      repo: project.repo ? { key: project.repo, url: "https://" + project.repo, github: github } : null,
      contributors: contributors, updatedAt: NOW,
    });
  }

  // 徽章：和服务端同样的门槛
  var BADGE_RULES = [["streak", [7, 30, 100]], ["spend", [100, 1000, 10000]], ["bigday", [1e8, 5e8, 1e9]], ["tools", [2, 3]], ["ways", [3, 5]],
    ["verified", [7, 30, 100]], ["projects", [1, 3, 10]], ["opensource", [1]], ["nightowl", [25]], ["weekend", [30]], ["podium", [10, 3, 1], true],
    ["speedrun", [1, 10, 50]], ["github", [500, 2000, 5000]]];

  function badgesOf(username) {
    var usage = userUsage(username);
    var person = usersForUsage().filter(function (p) { return p.username === username; })[0];
    var r = rng("badges:" + username);
    var values = {
      streak: usage.streaks.longest, spend: Math.floor(usage.totals.all.costUSD || 0),
      bigday: usage.days.reduce(function (m, d) { return Math.max(m, d.tokens); }, 0), tools: usage.tools.length, ways: usage.modes.length,
      verified: usage.days.filter(function (d) { return d.verifiedCostUSD > 0; }).length, projects: person ? person.projects.length : 0,
      opensource: person ? person.projects.filter(function (x) { return x.repoVerified; }).length : 0,
      nightowl: Math.floor(r() * 40), weekend: Math.floor(r() * 45), podium: usage.ranks.week.rank, speedrun: Math.floor(r() * 30), github: username === "peter" ? 5295 : Math.floor(r() * 3000),
    };
    return BADGE_RULES.map(function (rule) {
      var value = values[rule[0]], lower = !!rule[2];
      var tier = lower ? (value == null ? 0 : rule[1].filter(function (limit) { return value <= limit; }).length) : rule[1].filter(function (limit) { return (value || 0) >= limit; }).length;
      return { id: rule[0], value: value == null ? null : value, tier: tier, tiers: rule[1].length, thresholds: rule[1], next: tier < rule[1].length ? rule[1][tier] : null, lowerIsBetter: lower };
    });
  }

  // 实时：每隔两三秒有人的用量涨了，偶尔有一条额度读数
  function live(onEvent) {
    var timer = null, stopped = false;
    function tick() {
      if (stopped) return;
      var people = usersForUsage();
      var r = Math.random();
      var person = r < 0.35 ? people[Math.floor(Math.random() * 12)] : people[Math.floor(Math.random() * people.length)];
      var key = iso(utcToday());
      LIVE_BONUS[person.username] = LIVE_BONUS[person.username] || {};
      var add = person.scale * (0.02 + Math.random() * 0.12);
      LIVE_BONUS[person.username][key] = (LIVE_BONUS[person.username][key] || 0) + add;
      var day = dayTotals(usageDay(person, key), null, false);
      onEvent("usage", { username: person.username, displayName: person.displayName, date: key, costUSD: round2(day.cost), tokens: day.tokens, byTool: day.byTool, deltaUSD: round2(add), at: Math.floor(Date.now() / 1000) });
      var board = usageBoard(new URLSearchParams("period=week&limit=10"));
      onEvent("board", { board: "cost:week:verified", entries: board.entries.map(function (e) { return { rank: e.rank, username: e.username, displayName: e.displayName, value: e.value }; }), summary: { runners: board.summary.runners, costUSD: board.summary.costUSD }, at: Math.floor(Date.now() / 1000) });
      if (Math.random() < 0.3) {
        var b = BOARDS[Math.floor(Math.random() * 3)];
        onEvent("reading", { username: person.username, displayName: person.displayName, provider: b.provider, planLabel: b.planLabel, windowKey: b.windowKey, windowSeconds: b.windowSeconds, usedPercent: Math.round(40 + Math.random() * 60), observedAt: Math.floor(Date.now() / 1000), tier: "verified", at: Math.floor(Date.now() / 1000) });
      }
      timer = setTimeout(tick, 2200 + Math.random() * 2600);
    }
    timer = setTimeout(tick, 1200);
    return { close: function () { stopped = true; clearTimeout(timer); } };
  }

  /* ── 个人主页的热力图与 GitHub ───────────────────────────────────── */

  function localDay(ms) {
    var d = new Date(ms);
    return d.getFullYear() + "-" + Q.pad(d.getMonth() + 1) + "-" + Q.pad(d.getDate());
  }

  // 从 52 周前的星期一到今天，按浏览器的时区分日；忙的人工作日几乎天天有用量，周末少一些
  function eachDay(fn) {
    var today = new Date();
    today.setHours(12, 0, 0, 0);
    var back = (today.getDay() + 6) % 7 + 52 * 7;
    for (var i = back; i >= 0; i--) {
      var d = new Date(today);
      d.setDate(today.getDate() - i);
      fn(d, i);
    }
    var first = new Date(today);
    first.setDate(today.getDate() - back);
    return { from: localDay(first.getTime()), to: localDay(today.getTime()) };
  }

  function activityOf(username) {
    var r = rng("activity:" + username);
    var busy = username === "peter" ? 0.8 : 0.35 + r() * 0.3;
    var scale = username === "peter" ? 2.2e6 : 4e5 + r() * 8e5;
    var days = [], total = 0;
    var range = eachDay(function (d, back) {
      var weekend = d.getDay() === 0 || d.getDay() === 6;
      // 一年前刚开始用，越近越勤
      if (r() > busy * (weekend ? 0.5 : 1) * (back > 280 ? 0.35 : back > 150 ? 0.75 : 1)) return;
      var sources = { claude: Math.round(Math.pow(r(), 2) * scale) + 1800 };
      if (r() < 0.65) sources.codex = Math.round(Math.pow(r(), 2) * scale * 0.7) + 900;
      if (r() < 0.08) sources.opencode = Math.round(r() * 1.5e5) + 400;
      var tokens = Object.keys(sources).reduce(function (sum, k) { return sum + sources[k]; }, 0);
      var sorted = {};
      Object.keys(sources).sort(function (a, b) { return sources[b] - sources[a]; }).forEach(function (k) { sorted[k] = sources[k]; });
      total += tokens;
      days.push({ date: localDay(d.getTime()), tokens: tokens, sources: sorted });
    });
    var zone = "UTC";
    try { zone = Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC"; } catch (e) { /* 老浏览器 */ }
    return { timezone: zone, from: range.from, to: range.to, days: days, totalTokens: total };
  }

  function githubOf(username) {
    if (username !== "peter") return { login: null, url: null, calendar: null, totals: null, repos: [], pending: false, fetchedAt: null };
    var r = rng("github:" + username);
    var days = [], total = 0;
    var range = eachDay(function (d) {
      var weekend = d.getDay() === 0 || d.getDay() === 6;
      if (r() > (weekend ? 0.45 : 0.82)) return;
      var count = Math.max(1, Math.round(Math.pow(r(), 2.2) * 60));
      total += count;
      days.push({ date: localDay(d.getTime()), count: count });
    });
    var weeks = [];
    for (var w = 0; w < 52; w++) weeks.push(w < 20 ? 0 : Math.round(r() * r() * 90));
    var commits = weeks.reduce(function (a, b) { return a + b; }, 0);
    return {
      login: "gentpan", url: "https://github.com/gentpan",
      calendar: { total: total, from: range.from, to: range.to, days: days },
      totals: { commits: Math.round(total * 0.82), pullRequests: Math.round(total * 0.06), issues: Math.round(total * 0.03), reviews: Math.round(total * 0.05), private: Math.round(total * 0.2) },
      repos: [
        { repo: "gentpan/QuotaBar", url: "https://github.com/gentpan/QuotaBar", description: "Every AI coding limit, at a glance", stars: 1284, forks: 63, language: "Swift", pushedAt: NOW - 3 * 3600, archived: false, weeks: weeks, commits: commits, fetchedAt: NOW - 1800 },
        { repo: "example/shiori-cli", missing: true, fetchedAt: NOW - 1800 },
      ],
      pending: false,
      fetchedAt: NOW - 1800,
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
    if (route === "/usage/boards") return usageBoard(q);
    if (route === "/usage/projects") return projectBoard(q);
    if ((m = /^\/users\/([^\/]+)\/usage$/.exec(route))) return userUsage(decodeURIComponent(m[1]));
    if ((m = /^\/users\/([^\/]+)\/projects\/([^\/]+)$/.exec(route))) return projectDetail(decodeURIComponent(m[1]), decodeURIComponent(m[2]));
    if ((m = /^\/users\/([^\/]+)\/github$/.exec(route))) {
      user(decodeURIComponent(m[1]));   // 没这个人时同样 404
      return githubOf(decodeURIComponent(m[1]));
    }
    if ((m = /^\/users\/([^\/]+)$/.exec(route))) return user(decodeURIComponent(m[1]));
    throw status(404, "not_found");
  }

  window.QuotaRunDemo = {
    live: live,
    get: function (path) {
      return new Promise(function (resolve, reject) {
        setTimeout(function () {
          try { resolve(JSON.parse(JSON.stringify(answer(path)))); } catch (error) { reject(error); }
        }, 120);
      });
    },
  };
})();

#!/usr/bin/env python3
"""Quota Run 排行榜服务：quota.bar/api/run/v1 的后端。

契约以 docs/quota-run.md 为准（签名、规范串、数据模型、run 与 tier 规则、每个接口的
JSON）。这里只依赖标准库和 cryptography（主机上已装 43.x），数据放 SQLite（WAL）。

应用只上传读数（snapshot）和每分钟 token 数（activity），成绩全部由服务端算：
读数进来时只重算受影响的 run，榜单和个人页从 runs 表查询，公开 GET 在内存里缓存 30 秒。

环境变量：
  QUOTA_RUN_PORT         监听端口，默认 8788（只绑 127.0.0.1，由 Caddy 反代 /api/run/*）
  QUOTA_RUN_DB           数据库路径，默认 /var/lib/quotabar-run/run.db
  QUOTA_RUN_SECRET_FILE  账号摘要的 HMAC 密钥，默认 /etc/quotabar-run.secret；
                         不存在时生成 32 字节随机数的 hex（权限 0600）
"""
import base64
import binascii
import hashlib
import hmac
import json
import math
import os
import re
import secrets
import sqlite3
import sys
import threading
import time
import traceback
from contextlib import contextmanager
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qsl, unquote, urlsplit

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec

API_PREFIX = "/api/run/v1"
DEFAULT_PORT = 8788
DEFAULT_DB = "/var/lib/quotabar-run/run.db"
DEFAULT_SECRET_FILE = "/etc/quotabar-run.secret"

# —— 请求与签名 ——
MAX_BODY = 1_000_000          # 契约的 1 MB；Caddy 那边另设 2 MB 兜底，好让这里回 JSON 的 413
DRAIN_LIMIT = 4_000_000       # 超限的请求体先读掉这么多再回 413，免得对端写一半收到 RST
CLOCK_SKEW = 300
NONCE_TTL = 600
PAIR_CODE_TTL = 600
PAIR_CODE_LENGTH = 8
PAIR_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"  # 去掉 I L O 0 1，念给另一台 Mac 时不会看错
RANKED_COOLDOWN = 7 * 86400
CACHE_TTL = 30

# 令牌桶：(容量, 每补一个令牌的秒数)。write 是契约里的「每台设备 10 秒一次、突发 5」；
# register 没有设备号，只能按来源 IP；public 是给公开 GET 的宽松上限，防止换查询串绕开缓存
DEFAULT_LIMITS = {"write": (5, 10.0), "register": (5, 10.0), "public": (240, 0.25)}

# —— 读数 ——
MAX_SNAPSHOTS = 500
MAX_ACTIVITY = 1440
OBSERVED_MAX_AGE = 7 * 86400
OBSERVED_MAX_AHEAD = 300

# —— run 与 tier ——
RANKABLE_MIN_SECONDS = 3_600
RANKABLE_MAX_SECONDS = 2_764_800
RESET_ROUNDING = 300
FULL_THRESHOLD = 99.5
MAX_DROP = 2.0
MAX_JUMP = 60.0
JUMP_WINDOW = 300
MAX_GAP = 1_200
MAX_FIRST_PERCENT = 50.0
ACTIVITY_REQUIRED = frozenset({"codex", "claude"})
EPSILON = 1e-9                # 浮点减法（62.1 - 2.1）不能把恰好 60 分算成超过 60

USERNAME_RE = re.compile(r"[a-z0-9][a-z0-9_-]{2,19}")
RESERVED_USERNAMES = frozenset(
    "admin api app about help leaderboard run quota quotabar settings support www zh en "
    "me user users login logout signup register profile u".split())
REGIONS = ("global", "china")
PROVIDER_RE = re.compile(r"[a-z0-9_-]{1,32}")
DIGEST_RE = re.compile(r"[0-9a-f]{64}")
B64URL_RE = re.compile(r"[A-Za-z0-9_-]+")
SEASON_RE = re.compile(r"(\d{4})-W(\d{2})")
WINDOW_KEY_RE = re.compile(r"\d{1,9}:[^\x00-\x1f]{0,80}")
DEVICE_ID_RE = re.compile(r"[A-Za-z0-9_-]{1,64}")
GITHUB_HANDLE_RE = re.compile(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})")
GITHUB_REPO_RE = re.compile(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})/[A-Za-z0-9._-]{1,100}")
X_HANDLE_RE = re.compile(r"[A-Za-z0-9_]{1,15}")
BIDI_CONTROLS = set("\u200e\u200f\u202a\u202b\u202c\u202d\u202e\u2066\u2067\u2068\u2069")


class ApiError(Exception):
    def __init__(self, status, code, message, **extra):
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message
        self.extra = extra

    def payload(self):
        return {"error": self.code, "message": self.message, **self.extra}


class Rejected(Exception):
    """单条读数不合格：记进 rejected，不影响同批其他读数。"""


class Request:
    __slots__ = ("method", "path", "query", "headers", "body", "ip")

    def __init__(self, method, path, query, headers, body, ip):
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
        self.ip = ip


class Response:
    def __init__(self, status, payload=None, public=False, headers=None):
        self.status = status
        self.payload = payload
        self.public = public
        self.headers = headers or {}
        self._encoded = None

    def encoded(self):
        if self._encoded is None:
            self._encoded = b"" if self.payload is None else json.dumps(
                self.payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        return self._encoded


# —— 纯函数：编码、校验、run 计算 ——

def b64url_decode(text):
    """契约规定 base64url 不带填充；带 = 或非法字符一律当作无效。"""
    if not isinstance(text, str) or not B64URL_RE.fullmatch(text) or len(text) % 4 == 1:
        return None
    try:
        return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))
    except (binascii.Error, ValueError):
        return None


def canonical_string(method, path, timestamp, nonce, body):
    return "\n".join([
        "quota-run-v1", method.upper(), path, timestamp, nonce,
        hashlib.sha256(body or b"").hexdigest(),
    ]).encode("utf-8")


def season_of(timestamp):
    year, week, _ = datetime.fromtimestamp(timestamp, timezone.utc).isocalendar()
    return f"{year}-W{week:02d}"


def normalize_plan(plan):
    return re.sub(r"[^a-z0-9]", "", plan.lower()) if plan else ""


def as_number(value):
    # JSON 里的 true/false 在 Python 里是 int 的子类，不能当数字收
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    if isinstance(value, float) and not math.isfinite(value):
        return None
    return value


def as_int(value, floor=False):
    number = as_number(value)
    if number is None:
        return None
    if isinstance(number, float):
        if floor:
            return math.floor(number)
        if not number.is_integer():
            return None
    return int(number)


def has_control(text):
    return any(ord(ch) < 32 or ord(ch) == 127 for ch in text)


def clean_text(value, limit, multiline=False):
    """去掉控制字符和双向文本控制符（防止名字里倒转显示），超长则抛 ValueError。"""
    if value is None:
        return ""
    if not isinstance(value, str):
        raise ValueError
    text = value.replace("\r\n", "\n")
    kept = []
    for ch in text:
        if ch in BIDI_CONTROLS:
            continue
        if ord(ch) < 32 or ord(ch) == 127:
            if multiline and ch == "\n":
                kept.append(ch)
            else:
                kept.append(" ")
            continue
        kept.append(ch)
    text = "".join(kept).strip()
    if len(text) > limit:
        raise ValueError
    return text


def https_url(value, limit=300, hosts=None):
    if not isinstance(value, str):
        return None
    url = value.strip()
    if not url or len(url) > limit or any(ch.isspace() or ord(ch) < 32 for ch in url):
        return None
    try:
        parts = urlsplit(url)
        host = parts.hostname
    except ValueError:
        return None
    # 带 user:pass@ 的地址常被用来伪装目标站点，一律不收
    if parts.scheme != "https" or not host or "." not in host or "@" in parts.netloc:
        return None
    if hosts is not None and host.lower() not in hosts:
        return None
    return url


def normalize_username(value):
    if not isinstance(value, str):
        return None
    name = value.strip().lstrip("@").casefold()
    if not USERNAME_RE.fullmatch(name) or name in RESERVED_USERNAMES:
        return None
    return name


def summarize_run(readings, window_start):
    """readings 是按时间排好的 [(observedAt, usedPercent)]。

    返回峰值、到 50/90/100% 的秒数，以及 tier 规则 2（单调）、3（合理）、4（覆盖）
    的结果；规则 1 和 5 要查库，由调用方补上。
    """
    first_at, first_used = readings[0]
    peak = max(used for _, used in readings)
    peak_at = next(at for at, used in readings if used >= peak)

    def first_index(threshold):
        for index, (_, used) in enumerate(readings):
            if used >= threshold:
                return index
        return None

    def seconds(index):
        # 校验时允许 observedAt 比 windowStart 早 300 秒（时钟误差），这里不让它变负数
        return None if index is None else max(0, readings[index][0] - window_start)

    full_index = first_index(FULL_THRESHOLD)
    to_100 = seconds(full_index)

    monotonic = True
    highest = -math.inf
    for _, used in readings:
        if used < highest - MAX_DROP - EPSILON:
            monotonic = False
            break
        highest = max(highest, used)

    # 规则 3 看的是任意两条相距不到 5 分钟的读数，不只是相邻的：三条读数 30+35 也算跳变
    plausible = True
    low = 0
    for j, (at_j, used_j) in enumerate(readings):
        while readings[low][0] <= at_j - JUMP_WINDOW:
            low += 1
        if low < j and used_j - min(used for _, used in readings[low:j]) > MAX_JUMP + EPSILON:
            plausible = False
            break

    end_index = full_index if full_index is not None else len(readings) - 1
    covered = first_used <= MAX_FIRST_PERCENT and all(
        readings[k + 1][0] - readings[k][0] <= MAX_GAP for k in range(end_index))

    return {
        "peak_percent": float(peak),
        "peak_at": peak_at,
        "seconds_to_50": seconds(first_index(50.0)),
        "seconds_to_90": seconds(first_index(90.0)),
        "seconds_to_100": to_100,
        "completed_at": None if to_100 is None else window_start + to_100,
        "first_observed_at": first_at,
        "last_observed_at": readings[-1][0],
        "end_at": readings[end_index][0],
        "monotonic": monotonic,
        "plausible": plausible,
        "covered": covered,
    }


def validate_snapshot(item, now):
    if not isinstance(item, dict):
        raise Rejected("invalid_snapshot")
    provider = item.get("provider")
    if not isinstance(provider, str) or not PROVIDER_RE.fullmatch(provider):
        raise Rejected("invalid_provider")
    plan = item.get("plan")
    if plan is not None:
        if not isinstance(plan, str) or len(plan) > 60 or has_control(plan):
            raise Rejected("invalid_plan")
        plan = plan.strip() or None
    digest = item.get("accountDigest")
    if digest is not None:
        if not isinstance(digest, str) or not DIGEST_RE.fullmatch(digest.lower()):
            raise Rejected("invalid_account_digest")
        digest = digest.lower()
    raw_seconds = item.get("windowSeconds")
    window_seconds = 0 if raw_seconds is None else as_int(raw_seconds)
    if window_seconds is None or not 0 <= window_seconds <= 400 * 86400:
        raise Rejected("invalid_window_seconds")
    scope = item.get("scope")
    if scope is not None:
        if not isinstance(scope, str) or len(scope) > 80 or has_control(scope):
            raise Rejected("invalid_scope")
        scope = scope or None
    if item.get("windowKey") != f"{window_seconds}:{scope or ''}":
        raise Rejected("invalid_window_key")
    title = item.get("windowTitle")
    if title is not None and (not isinstance(title, str) or len(title) > 80 or has_control(title)):
        raise Rejected("invalid_window_title")
    used = as_number(item.get("usedPercent"))
    if used is None or not 0 <= used <= 100:
        raise Rejected("invalid_used_percent")
    resets_at = item.get("resetsAt")
    if resets_at is not None:
        resets_at = as_int(resets_at, floor=True)
        if resets_at is None or not 0 < resets_at < 10 ** 11:
            raise Rejected("invalid_resets_at")
    observed_at = as_int(item.get("observedAt"), floor=True)
    if observed_at is None:
        raise Rejected("invalid_observed_at")
    if not now - OBSERVED_MAX_AGE <= observed_at <= now + OBSERVED_MAX_AHEAD:
        raise Rejected("observed_at_out_of_range")
    if item.get("source") not in ("api", "local"):
        raise Rejected("invalid_source")
    rankable = resets_at is not None and RANKABLE_MIN_SECONDS <= window_seconds <= RANKABLE_MAX_SECONDS
    if rankable and not (resets_at - window_seconds - CLOCK_SKEW <= observed_at <= resets_at + CLOCK_SKEW):
        # 观察时间落在自己声称的窗口之外：多半是过期的 resetsAt，算进 run 会得出负的用时
        raise Rejected("outside_window")
    bucket = None
    if resets_at is not None:
        bucket = (resets_at + RESET_ROUNDING // 2) // RESET_ROUNDING * RESET_ROUNDING
    return {
        "provider": provider, "plan": plan, "plan_norm": normalize_plan(plan), "digest": digest,
        "window_key": item["windowKey"], "window_title": title, "window_seconds": window_seconds,
        "scope": scope, "used_percent": float(used), "resets_at": resets_at, "resets_bucket": bucket,
        "rankable": rankable, "observed_at": observed_at, "source": item["source"],
    }


def validate_activity(item, now):
    if not isinstance(item, dict):
        return None
    minute = as_int(item.get("minute"), floor=True)
    source = item.get("source")
    tokens = as_int(item.get("tokens"), floor=True)
    if minute is None or tokens is None or not isinstance(source, str) or not PROVIDER_RE.fullmatch(source):
        return None
    minute -= minute % 60
    if not now - OBSERVED_MAX_AGE - 60 <= minute <= now + OBSERVED_MAX_AHEAD or not 0 <= tokens <= 10 ** 12:
        return None
    return minute, source, tokens


def load_secret(path):
    """读 HMAC 密钥；文件不存在就生成一个。密钥内容从不打印。"""
    try:
        with open(path, encoding="utf-8") as handle:
            text = handle.read().strip()
    except FileNotFoundError:
        directory = os.path.dirname(path)
        if directory:
            os.makedirs(directory, exist_ok=True)
        text = secrets.token_hex(32)
        try:
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:  # 另一个进程刚好先写了，用它的
            return load_secret(path)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text + "\n")
    if len(text) < 32:
        raise SystemExit(f"{path}: secret is too short")
    try:
        return bytes.fromhex(text)
    except ValueError:
        return text.encode("utf-8")


SCHEMA_V1 = """
BEGIN;
CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY,
    username TEXT NOT NULL UNIQUE,
    display_name TEXT NOT NULL,
    bio TEXT NOT NULL DEFAULT '',
    region TEXT NOT NULL,
    website TEXT,
    github TEXT,
    x TEXT,
    joined_at INTEGER NOT NULL,
    ranked_changed_at INTEGER,
    last_upload_at INTEGER
);
CREATE TABLE IF NOT EXISTS devices (
    id TEXT PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    public_key BLOB NOT NULL UNIQUE,
    name TEXT NOT NULL,
    platform TEXT NOT NULL,
    app_version TEXT NOT NULL DEFAULT '',
    ranked INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,
    last_seen_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS devices_user ON devices(user_id);
-- scope 是设备号；注册请求还没有设备号，用公钥的哈希
CREATE TABLE IF NOT EXISTS nonces (
    scope TEXT NOT NULL,
    nonce TEXT NOT NULL,
    seen_at INTEGER NOT NULL,
    PRIMARY KEY (scope, nonce)
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS nonces_seen ON nonces(seen_at);
-- 配对码只存 SHA-256，按哈希查找不会泄露码本身的时序信息
CREATE TABLE IF NOT EXISTS pair_codes (
    code_hash TEXT PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    expires_at INTEGER NOT NULL
);
-- 一个服务商账号摘要（HMAC 后）出现在哪些用户名下；多于一个即为争议
CREATE TABLE IF NOT EXISTS account_bindings (
    account_hmac TEXT NOT NULL,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    first_seen_at INTEGER NOT NULL,
    PRIMARY KEY (account_hmac, user_id)
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS bindings_user ON account_bindings(user_id);
-- counted：收到时这台设备是不是计分设备。换计分设备不会回溯改写历史
CREATE TABLE IF NOT EXISTS snapshots (
    id INTEGER PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    device_id TEXT NOT NULL,
    counted INTEGER NOT NULL,
    provider TEXT NOT NULL,
    plan TEXT,
    plan_norm TEXT NOT NULL,
    account_hmac TEXT,
    window_key TEXT NOT NULL,
    window_title TEXT,
    window_seconds INTEGER NOT NULL,
    scope TEXT,
    used_percent REAL NOT NULL,
    resets_at INTEGER,
    resets_bucket INTEGER,
    rankable INTEGER NOT NULL,
    observed_at INTEGER NOT NULL,
    source TEXT NOT NULL,
    received_at INTEGER NOT NULL,
    UNIQUE (device_id, provider, window_key, observed_at)
);
CREATE INDEX IF NOT EXISTS snapshots_run
    ON snapshots(user_id, provider, plan_norm, window_key, resets_bucket, observed_at);
CREATE INDEX IF NOT EXISTS snapshots_account ON snapshots(account_hmac) WHERE account_hmac IS NOT NULL;
CREATE INDEX IF NOT EXISTS snapshots_user_day ON snapshots(user_id, observed_at);
CREATE TABLE IF NOT EXISTS activity (
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    device_id TEXT NOT NULL,
    counted INTEGER NOT NULL,
    source TEXT NOT NULL,
    minute INTEGER NOT NULL,
    tokens INTEGER NOT NULL,
    PRIMARY KEY (device_id, source, minute)
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS activity_user ON activity(user_id, source, minute);
CREATE TABLE IF NOT EXISTS runs (
    id INTEGER PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    provider TEXT NOT NULL,
    plan_norm TEXT NOT NULL,
    plan_label TEXT,
    window_key TEXT NOT NULL,
    window_seconds INTEGER NOT NULL,
    window_title TEXT,
    resets_bucket INTEGER NOT NULL,
    resets_at INTEGER NOT NULL,
    window_start INTEGER NOT NULL,
    season TEXT NOT NULL,
    peak_percent REAL NOT NULL,
    peak_at INTEGER NOT NULL,
    seconds_to_50 INTEGER,
    seconds_to_90 INTEGER,
    seconds_to_100 INTEGER,
    completed_at INTEGER,
    first_observed_at INTEGER NOT NULL,
    last_observed_at INTEGER NOT NULL,
    readings INTEGER NOT NULL,
    tier TEXT NOT NULL,
    flag_reason TEXT,
    updated_at INTEGER NOT NULL,
    UNIQUE (user_id, provider, plan_norm, window_key, resets_bucket)
);
CREATE INDEX IF NOT EXISTS runs_board ON runs(provider, plan_norm, window_key, season);
CREATE INDEX IF NOT EXISTS runs_user ON runs(user_id, last_observed_at);
CREATE INDEX IF NOT EXISTS runs_season ON runs(season);
CREATE TABLE IF NOT EXISTS projects (
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    position INTEGER NOT NULL,
    name TEXT NOT NULL,
    url TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    github TEXT,
    built_with TEXT NOT NULL DEFAULT '[]',
    PRIMARY KEY (user_id, position)
) WITHOUT ROWID;
INSERT INTO schema_version(version) VALUES (1);
COMMIT;
"""

MIGRATIONS = [(1, SCHEMA_V1)]

RUN_KEY_COLUMNS = "user_id, provider, plan_norm, window_key, resets_bucket"
RUN_KEY_WHERE = "user_id = ? AND provider = ? AND plan_norm = ? AND window_key = ? AND resets_bucket = ?"


class RunService:
    """全部业务逻辑。HTTP 层只负责把请求拆成 Request、把 Response 写回去。

    一条 SQLite 连接加一把锁：流量很小，串行化最省心，也让「读数写入 + run 重算」
    天然处在同一个事务里。clock 可注入，测试用假时钟推进时间。
    """

    def __init__(self, db_path, secret, clock=time.time, cache_ttl=CACHE_TTL, limits=None):
        directory = os.path.dirname(db_path)
        if directory:
            os.makedirs(directory, exist_ok=True)
        self.secret = secret
        self.clock = clock
        self.cache_ttl = cache_ttl
        self.limits = dict(DEFAULT_LIMITS, **(limits or {}))
        self.lock = threading.RLock()
        self.db = sqlite3.connect(db_path, check_same_thread=False, isolation_level=None)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA journal_mode = WAL")
        self.db.execute("PRAGMA synchronous = NORMAL")
        self.db.execute("PRAGMA foreign_keys = ON")
        self.db.execute("PRAGMA busy_timeout = 5000")
        self._buckets = {}
        self._cache = {}
        self._last_purge = 0
        self.migrate()

    def close(self):
        with self.lock:
            self.db.close()

    def now(self):
        return int(self.clock())

    def migrate(self):
        with self.lock:
            self.db.execute("CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL)")
            current = self.db.execute("SELECT COALESCE(MAX(version), 0) FROM schema_version").fetchone()[0]
            for version, script in MIGRATIONS:
                if version > current:
                    self.db.executescript(script)

    @contextmanager
    def transaction(self):
        self.db.execute("BEGIN IMMEDIATE")
        try:
            yield
        except BaseException:
            self.db.execute("ROLLBACK")
            raise
        self.db.execute("COMMIT")

    # —— 入口与路由 ——

    def handle(self, request):
        try:
            with self.lock:
                return self._route(request)
        except ApiError as error:
            headers = {}
            if error.status == 429 and "retryAfter" in error.extra:
                headers["Retry-After"] = str(error.extra["retryAfter"])
            return Response(error.status, error.payload(), headers=headers)
        except Exception:
            traceback.print_exc(file=sys.stderr)
            return Response(500, {"error": "internal", "message": "Something went wrong on the server."})

    def _route(self, request):
        if not request.path.startswith(API_PREFIX + "/"):
            raise ApiError(404, "not_found", "No such endpoint.")
        route = request.path[len(API_PREFIX):]
        method = request.method
        if method == "GET":
            if route in ("/stats", "/boards", "/leaderboard") or route.startswith("/users/"):
                return self._public(request, route)
            if route == "/me":
                return Response(200, self.me(self.authenticate(request)))
        elif method == "POST":
            if route == "/register":
                return self.register(request)
            if route == "/snapshots":
                return Response(200, self.post_snapshots(request, self.authenticate_write(request)))
            if route == "/devices/ranked":
                return Response(200, self.set_ranked(request, self.authenticate_write(request)))
            if route == "/pair":
                return Response(200, self.create_pair_code(self.authenticate_write(request)))
        elif method == "PUT":
            if route == "/profile":
                return Response(200, self.put_profile(request, self.authenticate_write(request)))
            if route == "/projects":
                return Response(200, self.put_projects(request, self.authenticate_write(request)))
        elif method == "DELETE":
            if route == "/account":
                self.delete_account(self.authenticate_write(request))
                return Response(204)
            if route.startswith("/devices/"):
                device_id = route[len("/devices/"):]
                return Response(200, self.delete_device(device_id, self.authenticate_write(request)))
        raise ApiError(404, "not_found", "No such endpoint.")

    def _public(self, request, route):
        self.take_token("ip:" + request.ip, "public")
        key = route + "?" + "&".join(f"{k}={v}" for k, v in sorted(request.query.items()))
        now = self.clock()
        cached = self._cache.get(key)
        if cached and cached[0] > now:
            return cached[1]
        try:
            if route == "/stats":
                response = Response(200, self.stats(), public=True)
            elif route == "/boards":
                response = Response(200, self.boards(request.query), public=True)
            elif route == "/leaderboard":
                response = Response(200, self.leaderboard(request.query), public=True)
            else:
                response = Response(200, self.profile(unquote(route[len("/users/"):])), public=True)
        except ApiError as error:
            if error.status != 404:
                raise
            response = Response(404, error.payload(), public=True)
        if self.cache_ttl > 0:
            if len(self._cache) > 5000:
                self._cache.clear()
            self._cache[key] = (now + self.cache_ttl, response)
        return response

    # —— 鉴权、防重放、限流 ——

    def verify_signature(self, request, public_key_raw, scope):
        headers = request.headers
        timestamp = headers.get("x-quota-timestamp", "")
        nonce = headers.get("x-quota-nonce", "")
        signature = headers.get("x-quota-signature", "")
        if not (timestamp and nonce and signature):
            raise ApiError(401, "missing_signature",
                           "Signed requests need X-Quota-Timestamp, X-Quota-Nonce and X-Quota-Signature.")
        if not re.fullmatch(r"\d{1,12}", timestamp):
            raise ApiError(401, "invalid_timestamp", "X-Quota-Timestamp must be Unix seconds.")
        now = self.now()
        if abs(now - int(timestamp)) > CLOCK_SKEW:
            raise ApiError(401, "timestamp_skew",
                           "The request timestamp is more than 300 seconds from the server clock.",
                           serverTime=now)
        nonce_bytes = b64url_decode(nonce)
        if nonce_bytes is None or len(nonce_bytes) != 16:
            raise ApiError(401, "invalid_nonce", "X-Quota-Nonce must be 16 bytes of unpadded base64url.")
        signature_der = b64url_decode(signature)
        if signature_der is None or len(signature_der) > 80:
            raise ApiError(401, "invalid_signature", "The request signature does not verify.")
        message = canonical_string(request.method, request.path, timestamp, nonce, request.body)
        try:
            key = ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), public_key_raw)
            key.verify(signature_der, message, ec.ECDSA(hashes.SHA256()))
        except (InvalidSignature, ValueError, TypeError):
            raise ApiError(401, "invalid_signature", "The request signature does not verify.") from None
        self._purge(now)
        # 签名通过后才登记 nonce：伪造请求烧不掉别人的 nonce
        try:
            self.db.execute("INSERT INTO nonces(scope, nonce, seen_at) VALUES (?, ?, ?)",
                            (scope, nonce_bytes.hex(), now))
        except sqlite3.IntegrityError:
            raise ApiError(401, "nonce_reused", "This nonce was already used.") from None

    def authenticate(self, request):
        device_id = request.headers.get("x-quota-device", "")
        if not device_id:
            raise ApiError(401, "missing_device", "X-Quota-Device is required.")
        row = self.db.execute("SELECT * FROM devices WHERE id = ?", (device_id,)).fetchone()
        if row is None:
            raise ApiError(401, "unknown_device", "This device is not registered.")
        self.verify_signature(request, bytes(row["public_key"]), row["id"])
        self.db.execute("UPDATE devices SET last_seen_at = ? WHERE id = ?", (self.now(), row["id"]))
        return dict(row)

    def authenticate_write(self, request):
        device = self.authenticate(request)
        # 先验签再扣令牌：拿不到私钥的人不能把别人的额度耗光
        self.take_token("device:" + device["id"], "write")
        return device

    def take_token(self, key, kind):
        burst, interval = self.limits[kind]
        now = self.clock()
        tokens, last = self._buckets.get(key, (float(burst), now))
        tokens = min(float(burst), tokens + max(0.0, now - last) / interval)
        if tokens < 1.0:
            self._buckets[key] = (tokens, now)
            raise ApiError(429, "rate_limited", "Too many requests; slow down.",
                           retryAfter=max(1, math.ceil((1.0 - tokens) * interval)))
        self._buckets[key] = (tokens - 1.0, now)
        if len(self._buckets) > 20000:
            for stale in [k for k, (_, seen) in self._buckets.items() if now - seen > 3600]:
                del self._buckets[stale]

    def _purge(self, now):
        if now - self._last_purge < 60:
            return
        self._last_purge = now
        self.db.execute("DELETE FROM nonces WHERE seen_at < ?", (now - NONCE_TTL,))
        self.db.execute("DELETE FROM pair_codes WHERE expires_at < ?", (now,))

    def account_hmac(self, digest):
        # 只存 HMAC：数据库泄露也不能拿常见邮箱去撞出是谁
        return hmac.new(self.secret, digest.encode("ascii"), hashlib.sha256).hexdigest()

    # —— 注册、配对、设备 ——

    def register(self, request):
        body = parse_json_object(request.body)
        public_key = b64url_decode(body.get("publicKey"))
        if public_key is None or len(public_key) != 65 or public_key[0] != 4:
            raise ApiError(400, "invalid_public_key", "publicKey must be a 65-byte X9.63 P-256 point in base64url.")
        self.verify_signature(request, public_key, "key:" + hashlib.sha256(public_key).hexdigest()[:40])
        self.take_token("register:" + request.ip, "register")
        if body.get("platform") != "macos":
            raise ApiError(400, "invalid_platform", "platform must be \"macos\".")
        try:
            device_name = clean_text(body.get("deviceName"), 60) or "Mac"
            app_version = clean_text(body.get("appVersion"), 40)
        except ValueError:
            raise ApiError(400, "invalid_device", "deviceName is at most 60 characters, appVersion at most 40.") from None
        now = self.now()
        with self.transaction():
            if self.db.execute("SELECT 1 FROM devices WHERE public_key = ?", (public_key,)).fetchone():
                raise ApiError(409, "key_registered", "This public key is already registered.")
            pair_code = body.get("pairCode")
            if pair_code not in (None, ""):
                code = re.sub(r"[\s-]", "", pair_code).upper() if isinstance(pair_code, str) else ""
                row = None
                if len(code) == PAIR_CODE_LENGTH:
                    row = self.db.execute(
                        "SELECT user_id FROM pair_codes WHERE code_hash = ? AND expires_at >= ?",
                        (hashlib.sha256(code.encode()).hexdigest(), now)).fetchone()
                if row is None:
                    raise ApiError(404, "pair_code_invalid", "The pairing code is wrong or has expired.")
                user_id = row["user_id"]
                self.db.execute("DELETE FROM pair_codes WHERE user_id = ?", (user_id,))
                ranked = False
            else:
                username = normalize_username(body.get("username"))
                if username is None:
                    raise ApiError(400, "invalid_username",
                                   "Usernames are 3–20 characters of a–z, 0–9, _ and -, starting with a letter or digit, and not reserved.")
                region = body.get("region")
                if region not in REGIONS:
                    raise ApiError(400, "invalid_region", "region must be \"global\" or \"china\".")
                try:
                    display_name = clean_text(body.get("displayName"), 40) or username
                except ValueError:
                    raise ApiError(400, "invalid_display_name", "displayName is at most 40 characters.") from None
                if self.db.execute("SELECT 1 FROM users WHERE username = ?", (username,)).fetchone():
                    raise ApiError(409, "username_taken", "That username is taken.")
                user_id = self.db.execute(
                    "INSERT INTO users(username, display_name, region, joined_at) VALUES (?, ?, ?, ?)",
                    (username, display_name, region, now)).lastrowid
                ranked = True
            device_id = secrets.token_urlsafe(16)
            self.db.execute(
                "INSERT INTO devices(id, user_id, public_key, name, platform, app_version, ranked, created_at, last_seen_at)"
                " VALUES (?, ?, ?, ?, 'macos', ?, ?, ?, ?)",
                (device_id, user_id, public_key, device_name, app_version, int(ranked), now, now))
            user = self.user_row(user_id)
        self._cache.clear()
        return Response(201, {
            "user": {"username": user["username"], "displayName": user["display_name"], "region": user["region"]},
            "deviceId": device_id,
            "ranked": ranked,
        })

    def create_pair_code(self, device):
        now = self.now()
        code = "".join(secrets.choice(PAIR_ALPHABET) for _ in range(PAIR_CODE_LENGTH))
        with self.transaction():
            # 同一时间只留一个有效码，旧码作废
            self.db.execute("DELETE FROM pair_codes WHERE user_id = ?", (device["user_id"],))
            self.db.execute("INSERT INTO pair_codes(code_hash, user_id, expires_at) VALUES (?, ?, ?)",
                            (hashlib.sha256(code.encode()).hexdigest(), device["user_id"], now + PAIR_CODE_TTL))
        return {"code": code, "expiresAt": now + PAIR_CODE_TTL}

    def set_ranked(self, request, device):
        body = parse_json_object(request.body)
        target = body.get("deviceId")
        if not isinstance(target, str) or not DEVICE_ID_RE.fullmatch(target):
            raise ApiError(400, "invalid_device", "deviceId is required.")
        now = self.now()
        with self.transaction():
            row = self.db.execute("SELECT ranked FROM devices WHERE id = ? AND user_id = ?",
                                  (target, device["user_id"])).fetchone()
            if row is None:
                raise ApiError(404, "device_not_found", "No such device on this account.")
            if not row["ranked"]:
                available = self.ranked_available_at(self.user_row(device["user_id"]))
                if available is not None:
                    raise ApiError(409, "cooldown", "The ranked device can change once every 7 days.",
                                   availableAt=available)
                self.db.execute("UPDATE devices SET ranked = (id = ?) WHERE user_id = ?", (target, device["user_id"]))
                self.db.execute("UPDATE users SET ranked_changed_at = ? WHERE id = ?", (now, device["user_id"]))
        return {"devices": self.devices_payload(device["user_id"], device["id"]),
                "rankedChangeAvailableAt": self.ranked_available_at(self.user_row(device["user_id"]))}

    def delete_device(self, device_id, device):
        if not DEVICE_ID_RE.fullmatch(device_id):
            raise ApiError(404, "device_not_found", "No such device on this account.")
        if device_id == device["id"]:
            raise ApiError(409, "current_device", "A device cannot remove itself; use DELETE /account to leave.")
        with self.transaction():
            row = self.db.execute("SELECT ranked FROM devices WHERE id = ? AND user_id = ?",
                                  (device_id, device["user_id"])).fetchone()
            if row is None:
                raise ApiError(404, "device_not_found", "No such device on this account.")
            if row["ranked"]:
                # 每个账号必须恰好一台计分设备；先换计分设备（受冷却期约束）再删
                raise ApiError(409, "ranked_device", "Make another Mac the ranked device before removing this one.")
            self.db.execute("DELETE FROM devices WHERE id = ?", (device_id,))
            self.db.execute("DELETE FROM nonces WHERE scope = ?", (device_id,))
        self._buckets.pop("device:" + device_id, None)
        return {"devices": self.devices_payload(device["user_id"], device["id"])}

    def delete_account(self, device):
        user_id = device["user_id"]
        with self.transaction():
            device_ids = [r[0] for r in self.db.execute("SELECT id FROM devices WHERE user_id = ?", (user_id,))]
            hmacs = [r[0] for r in self.db.execute(
                "SELECT account_hmac FROM account_bindings WHERE user_id = ?", (user_id,))]
            self.db.executemany("DELETE FROM nonces WHERE scope = ?", [(d,) for d in device_ids])
            for table in ("snapshots", "activity", "runs", "projects", "pair_codes", "account_bindings", "devices"):
                self.db.execute(f"DELETE FROM {table} WHERE user_id = ?", (user_id,))
            self.db.execute("DELETE FROM users WHERE id = ?", (user_id,))
            # 这个人走了，和他共用服务商账号的其他人不再有争议，他们的 run 要重算
            keys = set()
            for account in hmacs:
                keys.update(self.run_keys_for_account(account))
            now = self.now()
            for key in keys:
                self.recompute_run(key, now)
        for device_id in device_ids:
            self._buckets.pop("device:" + device_id, None)
        self._cache.clear()

    # —— 读数与 run ——

    def post_snapshots(self, request, device):
        body = parse_json_object(request.body)
        snapshots = body.get("snapshots")
        activity = body.get("activity")
        snapshots = [] if snapshots is None else snapshots
        activity = [] if activity is None else activity
        if not isinstance(snapshots, list) or not isinstance(activity, list):
            raise ApiError(400, "invalid_body", "snapshots and activity must be arrays.")
        if len(snapshots) > MAX_SNAPSHOTS:
            raise ApiError(400, "too_many_snapshots", f"At most {MAX_SNAPSHOTS} snapshots per request.")
        if len(activity) > MAX_ACTIVITY:
            raise ApiError(400, "too_many_activity", f"At most {MAX_ACTIVITY} activity minutes per request.")
        now = self.now()
        user_id = device["user_id"]
        counted = int(bool(device["ranked"]))
        accepted = duplicates = 0
        rejected = []
        run_keys = set()
        active_ranges = {}
        with self.transaction():
            for item in activity:
                entry = validate_activity(item, now)
                if entry is None:
                    continue  # 契约里 rejected 只报读数；坏的活动分钟直接丢掉
                minute, source, tokens = entry
                self.db.execute(
                    "INSERT INTO activity(user_id, device_id, counted, source, minute, tokens) VALUES (?, ?, ?, ?, ?, ?)"
                    " ON CONFLICT(device_id, source, minute) DO UPDATE SET tokens = MAX(tokens, excluded.tokens)",
                    (user_id, device["id"], counted, source, minute, tokens))
                if counted and tokens > 0 and source in ACTIVITY_REQUIRED:
                    low, high = active_ranges.get(source, (minute, minute))
                    active_ranges[source] = (min(low, minute), max(high, minute))
            for index, item in enumerate(snapshots):
                try:
                    snap = validate_snapshot(item, now)
                except Rejected as reason:
                    rejected.append({"index": index, "reason": str(reason)})
                    continue
                account = self.account_hmac(snap["digest"]) if snap["digest"] else None
                cursor = self.db.execute(
                    "INSERT OR IGNORE INTO snapshots(user_id, device_id, counted, provider, plan, plan_norm, account_hmac,"
                    " window_key, window_title, window_seconds, scope, used_percent, resets_at, resets_bucket, rankable,"
                    " observed_at, source, received_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    (user_id, device["id"], counted, snap["provider"], snap["plan"], snap["plan_norm"], account,
                     snap["window_key"], snap["window_title"], snap["window_seconds"], snap["scope"],
                     snap["used_percent"], snap["resets_at"], snap["resets_bucket"], int(snap["rankable"]),
                     snap["observed_at"], snap["source"], now))
                if cursor.rowcount != 1:
                    duplicates += 1
                    continue
                accepted += 1
                if account:
                    self.bind_account(account, user_id, now, run_keys)
                if counted and snap["rankable"]:
                    run_keys.add((user_id, snap["provider"], snap["plan_norm"], snap["window_key"], snap["resets_bucket"]))
            # 新到的活动分钟只可能把 standard 升成 verified；verified 和 flagged 不受影响
            for source, (low, high) in active_ranges.items():
                rows = self.db.execute(
                    f"SELECT {RUN_KEY_COLUMNS} FROM runs WHERE user_id = ? AND provider = ? AND tier = 'standard'"
                    " AND first_observed_at < ? AND COALESCE(completed_at, last_observed_at) >= ?",
                    (user_id, source, high + 60, low))
                run_keys.update(tuple(row) for row in rows)
            for key in run_keys:
                self.recompute_run(key, now)
            self.db.execute("UPDATE users SET last_upload_at = ? WHERE id = ?", (now, user_id))
        return {"accepted": accepted, "duplicates": duplicates, "rejected": rejected}

    def bind_account(self, account, user_id, now, run_keys):
        cursor = self.db.execute(
            "INSERT OR IGNORE INTO account_bindings(account_hmac, user_id, first_seen_at) VALUES (?, ?, ?)",
            (account, user_id, now))
        if cursor.rowcount != 1:
            return
        owners = self.db.execute("SELECT COUNT(*) FROM account_bindings WHERE account_hmac = ?", (account,)).fetchone()[0]
        if owners > 1:
            # 新出现争议：所有用这个账号的人（包括之前的用户）的 run 都要重算成 flagged
            run_keys.update(self.run_keys_for_account(account))

    def run_keys_for_account(self, account):
        rows = self.db.execute(
            f"SELECT DISTINCT {RUN_KEY_COLUMNS} FROM snapshots WHERE account_hmac = ? AND counted = 1 AND rankable = 1",
            (account,))
        return {tuple(row) for row in rows}

    def recompute_run(self, key, now):
        user_id, provider, plan_norm, window_key, _ = key
        rows = self.db.execute(
            "SELECT observed_at, used_percent, resets_at, window_seconds, window_title, plan, account_hmac"
            f" FROM snapshots WHERE {RUN_KEY_WHERE} AND counted = 1 AND rankable = 1 ORDER BY observed_at, id",
            key).fetchall()
        if not rows:
            self.db.execute(f"DELETE FROM runs WHERE {RUN_KEY_WHERE}", key)
            return
        window_seconds = rows[0]["window_seconds"]
        # 同一组里 resetsAt 可能有几秒抖动；取最早的，windowStart 也最早，用时只会算长不会算短
        resets_at = min(row["resets_at"] for row in rows)
        window_start = resets_at - window_seconds
        summary = summarize_run([(row["observed_at"], row["used_percent"]) for row in rows], window_start)

        accounts = {row["account_hmac"] for row in rows}
        bound = len(accounts) == 1 and None not in accounts
        known = [account for account in accounts if account]
        disputed = False
        if known:
            marks = ",".join("?" * len(known))
            disputed = self.db.execute(
                f"SELECT 1 FROM account_bindings WHERE account_hmac IN ({marks}) AND user_id != ? LIMIT 1",
                (*known, user_id)).fetchone() is not None
        active = True
        if provider in ACTIVITY_REQUIRED:
            # 活动按分钟取整：与第一条读数所在分钟有重叠的那一分钟也算
            active = self.db.execute(
                "SELECT 1 FROM activity WHERE user_id = ? AND source = ? AND counted = 1 AND tokens > 0"
                " AND minute > ? AND minute <= ? LIMIT 1",
                (user_id, provider, summary["first_observed_at"] - 60, summary["end_at"])).fetchone() is not None

        reasons = []
        if not summary["monotonic"]:
            reasons.append("drop")
        if not summary["plausible"]:
            reasons.append("jump")
        if disputed:
            reasons.append("disputed")
        if reasons:
            tier = "flagged"
        elif bound and summary["covered"] and active:
            tier = "verified"
        else:
            tier = "standard"
        plan_label = next((row["plan"] for row in reversed(rows) if row["plan"]), None)
        window_title = next((row["window_title"] for row in reversed(rows) if row["window_title"]), None)
        self.db.execute(
            "INSERT INTO runs(user_id, provider, plan_norm, plan_label, window_key, window_seconds, window_title,"
            " resets_bucket, resets_at, window_start, season, peak_percent, peak_at, seconds_to_50, seconds_to_90,"
            " seconds_to_100, completed_at, first_observed_at, last_observed_at, readings, tier, flag_reason, updated_at)"
            " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
            " ON CONFLICT(user_id, provider, plan_norm, window_key, resets_bucket) DO UPDATE SET"
            " plan_label = excluded.plan_label, window_seconds = excluded.window_seconds,"
            " window_title = excluded.window_title, resets_at = excluded.resets_at,"
            " window_start = excluded.window_start, season = excluded.season,"
            " peak_percent = excluded.peak_percent, peak_at = excluded.peak_at,"
            " seconds_to_50 = excluded.seconds_to_50, seconds_to_90 = excluded.seconds_to_90,"
            " seconds_to_100 = excluded.seconds_to_100, completed_at = excluded.completed_at,"
            " first_observed_at = excluded.first_observed_at, last_observed_at = excluded.last_observed_at,"
            " readings = excluded.readings, tier = excluded.tier, flag_reason = excluded.flag_reason,"
            " updated_at = excluded.updated_at",
            (user_id, provider, plan_norm, plan_label, window_key, window_seconds, window_title, key[4], resets_at,
             window_start, season_of(window_start), summary["peak_percent"], summary["peak_at"],
             summary["seconds_to_50"], summary["seconds_to_90"], summary["seconds_to_100"], summary["completed_at"],
             summary["first_observed_at"], summary["last_observed_at"], len(rows), tier,
             ",".join(reasons) or None, now))

    # —— 个人资料与项目 ——

    def put_profile(self, request, device):
        body = parse_json_object(request.body)
        user = self.user_row(device["user_id"])
        updates = {}
        # 缺省的字段保持原值；显式传 null 或空串才清空
        if "displayName" in body:
            try:
                updates["display_name"] = clean_text(body["displayName"], 40) or user["username"]
            except ValueError:
                raise ApiError(400, "invalid_display_name", "displayName is at most 40 characters.") from None
        if "bio" in body:
            try:
                updates["bio"] = clean_text(body["bio"], 160, multiline=True)
            except ValueError:
                raise ApiError(400, "invalid_bio", "bio is at most 160 characters.") from None
        if "region" in body:
            if body["region"] not in REGIONS:
                raise ApiError(400, "invalid_region", "region must be \"global\" or \"china\".")
            updates["region"] = body["region"]
        if "links" in body:
            links = body["links"] or {}
            if not isinstance(links, dict):
                raise ApiError(400, "invalid_links", "links must be an object.")
            for field in ("website", "github", "x"):
                if field in links:
                    updates[field] = profile_link(field, links[field])
        if updates:
            assignments = ", ".join(f"{column} = ?" for column in updates)
            self.db.execute(f"UPDATE users SET {assignments} WHERE id = ?", (*updates.values(), user["id"]))
            self._cache.clear()
        return {"user": private_user(self.user_row(user["id"]))}

    def put_projects(self, request, device):
        body = parse_json_object(request.body)
        projects = body.get("projects")
        if not isinstance(projects, list):
            raise ApiError(400, "invalid_projects", "projects must be an array.")
        if len(projects) > 12:
            raise ApiError(400, "too_many_projects", "At most 12 projects.")
        rows = [validate_project(index, item) for index, item in enumerate(projects)]
        with self.transaction():
            self.db.execute("DELETE FROM projects WHERE user_id = ?", (device["user_id"],))
            self.db.executemany(
                "INSERT INTO projects(user_id, position, name, url, description, github, built_with)"
                " VALUES (?, ?, ?, ?, ?, ?, ?)",
                [(device["user_id"], index, *row) for index, row in enumerate(rows)])
        self._cache.clear()
        return {"projects": self.projects_payload(device["user_id"])}

    # —— 查询 ——

    def user_row(self, user_id):
        return self.db.execute("SELECT * FROM users WHERE id = ?", (user_id,)).fetchone()

    def ranked_available_at(self, user):
        """冷却中返回可以再换的时间；现在就能换则为 null。首台设备自动成为计分设备，不算一次更换。"""
        changed = user["ranked_changed_at"]
        if changed is None or self.now() >= changed + RANKED_COOLDOWN:
            return None
        return changed + RANKED_COOLDOWN

    def devices_payload(self, user_id, current_id):
        rows = self.db.execute(
            "SELECT id, name, ranked, last_seen_at FROM devices WHERE user_id = ? ORDER BY created_at, rowid", (user_id,))
        return [{"deviceId": row["id"], "name": row["name"], "ranked": bool(row["ranked"]),
                 "lastSeenAt": row["last_seen_at"], "current": row["id"] == current_id} for row in rows]

    def projects_payload(self, user_id):
        rows = self.db.execute(
            "SELECT name, url, description, github, built_with FROM projects WHERE user_id = ? ORDER BY position",
            (user_id,))
        return [{"name": row["name"], "url": row["url"], "description": row["description"],
                 "github": row["github"], "builtWith": json.loads(row["built_with"])} for row in rows]

    def me(self, device):
        user = self.user_row(device["user_id"])
        return {
            "user": private_user(user),
            "devices": self.devices_payload(user["id"], device["id"]),
            "rankedChangeAvailableAt": self.ranked_available_at(user),
            "lastUploadAt": user["last_upload_at"],
            "projects": self.projects_payload(user["id"]),
        }

    def stats(self):
        users = self.db.execute("SELECT COUNT(*) FROM users").fetchone()[0]
        row = self.db.execute(
            "SELECT COUNT(*), COALESCE(SUM(tier = 'verified'), 0), COUNT(DISTINCT provider)"
            " FROM runs WHERE tier != 'flagged'").fetchone()
        return {"users": users, "runs": row[0], "verifiedRuns": row[1], "providers": row[2], "updatedAt": self.now()}

    def parse_season(self, value):
        if value in (None, "", "current"):
            return season_of(self.now())
        if value == "all":
            return "all"
        match = SEASON_RE.fullmatch(value)
        if match:
            try:
                datetime.fromisocalendar(int(match.group(1)), int(match.group(2)), 1)
                return value
            except ValueError:
                pass
        raise ApiError(400, "invalid_season", "season is \"current\", \"all\" or an ISO week like 2026-W37.")

    def boards(self, query):
        season = self.parse_season(query.get("season"))
        region = parse_region(query.get("region"))
        where, params = ["r.tier != 'flagged'"], []
        if season != "all":
            where.append("r.season = ?")
            params.append(season)
        if region:
            where.append("u.region = ?")
            params.append(region)
        # SQLite 的「单个 MAX() 时裸列取自那一行」：标签和标题取最近一次 run 的
        rows = self.db.execute(
            "SELECT r.provider, r.plan_norm, r.window_key, COUNT(DISTINCT r.user_id) AS runners,"
            " MAX(r.last_observed_at) AS latest, r.plan_label, r.window_seconds, r.window_title"
            " FROM runs r JOIN users u ON u.id = r.user_id"
            f" WHERE {' AND '.join(where)} GROUP BY r.provider, r.plan_norm, r.window_key"
            " ORDER BY runners DESC, r.provider, r.plan_norm, r.window_key", params)
        return {"boards": [{
            "provider": row["provider"], "plan": row["plan_norm"], "planLabel": row["plan_label"],
            "windowKey": row["window_key"], "windowSeconds": row["window_seconds"],
            "windowTitle": row["window_title"], "runners": row["runners"], "season": season,
        } for row in rows]}

    def board_meta(self, provider, plan_norm, window_key, season, region):
        where = ["r.provider = ?", "r.plan_norm = ?", "r.window_key = ?", "r.tier != 'flagged'"]
        params = [provider, plan_norm, window_key]
        if season != "all":
            where.append("r.season = ?")
            params.append(season)
        if region:
            where.append("u.region = ?")
            params.append(region)
        runners = self.db.execute(
            f"SELECT COUNT(DISTINCT r.user_id) FROM runs r JOIN users u ON u.id = r.user_id WHERE {' AND '.join(where)}",
            params).fetchone()[0]
        label = self.db.execute(
            "SELECT plan_label, window_seconds, window_title FROM runs WHERE provider = ? AND plan_norm = ?"
            " AND window_key = ? AND tier != 'flagged' ORDER BY last_observed_at DESC LIMIT 1",
            (provider, plan_norm, window_key)).fetchone()
        return {
            "provider": provider, "plan": plan_norm,
            "planLabel": label["plan_label"] if label else None,
            "windowKey": window_key,
            "windowSeconds": label["window_seconds"] if label else int(window_key.split(":", 1)[0]),
            "windowTitle": label["window_title"] if label else None,
            "runners": runners, "season": season,
        }

    def best_runs(self, provider, plan_norm, window_key, metric, season, region, tier):
        """每人一条最好成绩，按榜单顺序排好。"""
        if metric == "speed":
            inner = "r.seconds_to_100 ASC, r.completed_at ASC, r.id ASC"
            outer = "seconds_to_100 ASC, completed_at ASC, id ASC"
        else:
            inner = "r.peak_percent DESC, COALESCE(r.completed_at, r.last_observed_at) ASC, r.id ASC"
            outer = "peak_percent DESC, COALESCE(completed_at, last_observed_at) ASC, id ASC"
        where = ["r.provider = ?", "r.plan_norm = ?", "r.window_key = ?", "r.tier != 'flagged'"]
        params = [provider, plan_norm, window_key]
        if metric == "speed":
            where.append("r.seconds_to_100 IS NOT NULL")
        if season != "all":
            where.append("r.season = ?")
            params.append(season)
        if region:
            where.append("u.region = ?")
            params.append(region)
        if tier == "verified":
            where.append("r.tier = 'verified'")
        return self.db.execute(
            "SELECT * FROM (SELECT r.*, u.username, u.display_name,"
            f" ROW_NUMBER() OVER (PARTITION BY r.user_id ORDER BY {inner}) AS best"
            f" FROM runs r JOIN users u ON u.id = r.user_id WHERE {' AND '.join(where)})"
            f" WHERE best = 1 ORDER BY {outer}", params).fetchall()

    def leaderboard(self, query):
        provider = query.get("provider", "")
        if not PROVIDER_RE.fullmatch(provider):
            raise ApiError(400, "invalid_provider", "provider is required.")
        plan_norm = normalize_plan(query.get("plan", ""))[:60]
        window_key = query.get("window", "")
        if not WINDOW_KEY_RE.fullmatch(window_key):
            raise ApiError(400, "invalid_window", "window is a window key like 604800:.")
        metric = query.get("metric") or "speed"
        if metric not in ("speed", "peak"):
            raise ApiError(400, "invalid_metric", "metric is \"speed\" or \"peak\".")
        season = self.parse_season(query.get("season"))
        region = parse_region(query.get("region"))
        tier = query.get("tier") or "all"
        if tier not in ("all", "verified"):
            raise ApiError(400, "invalid_tier", "tier is \"all\" or \"verified\".")
        raw_limit = query.get("limit") or "100"
        if not raw_limit.isdigit() or int(raw_limit) < 1:
            raise ApiError(400, "invalid_limit", "limit is a positive integer.")
        limit = min(int(raw_limit), 200)
        rows = self.best_runs(provider, plan_norm, window_key, metric, season, region, tier)[:limit]
        return {
            "board": self.board_meta(provider, plan_norm, window_key, season, region),
            "season": season,
            "metric": metric,
            "entries": [entry_payload(rank, row, metric) for rank, row in enumerate(rows, start=1)],
            "updatedAt": self.now(),
        }

    def profile(self, raw_username):
        username = normalize_username(raw_username)
        user = None
        if username is not None:
            user = self.db.execute("SELECT * FROM users WHERE username = ?", (username,)).fetchone()
        if user is None:
            raise ApiError(404, "user_not_found", "No such user.")
        user_id = user["id"]
        bests = []
        boards = self.db.execute(
            "SELECT DISTINCT provider, plan_norm, window_key FROM runs WHERE user_id = ? AND tier != 'flagged'"
            " ORDER BY provider, plan_norm, window_key", (user_id,)).fetchall()
        for board in boards:
            for metric in ("speed", "peak"):
                # 个人页的名次按全部赛季、全部地区、全部 tier 算
                ranking = self.best_runs(board[0], board[1], board[2], metric, "all", None, "all")
                for rank, row in enumerate(ranking, start=1):
                    if row["user_id"] != user_id:
                        continue
                    runners = len(ranking)
                    bests.append({
                        "provider": row["provider"], "plan": row["plan_norm"], "planLabel": row["plan_label"],
                        "windowKey": row["window_key"], "windowSeconds": row["window_seconds"],
                        "windowTitle": row["window_title"], "metric": metric,
                        "value": row["seconds_to_100"] if metric == "speed" else row["peak_percent"],
                        "unit": "seconds" if metric == "speed" else "percent",
                        "rank": rank, "runners": runners,
                        "percentile": max(1, math.ceil(rank * 100 / runners)),
                        "tier": row["tier"], "season": row["season"],
                        "achievedAt": row["completed_at"] if metric == "speed" else row["peak_at"],
                    })
                    break
        recent = self.db.execute(
            "SELECT * FROM runs WHERE user_id = ? AND tier != 'flagged' ORDER BY last_observed_at DESC, id DESC LIMIT 20",
            (user_id,)).fetchall()
        totals = self.db.execute(
            "SELECT COUNT(*), COALESCE(SUM(tier = 'verified'), 0), COUNT(DISTINCT provider)"
            " FROM runs WHERE user_id = ? AND tier != 'flagged'", (user_id,)).fetchone()
        active_days = self.db.execute(
            "SELECT COUNT(*) FROM (SELECT minute / 86400 AS day FROM activity WHERE user_id = ? AND counted = 1"
            " AND tokens > 0 UNION SELECT observed_at / 86400 FROM snapshots WHERE user_id = ? AND counted = 1)",
            (user_id, user_id)).fetchone()[0]
        return {
            "username": user["username"],
            "displayName": user["display_name"],
            "bio": user["bio"],
            "region": user["region"],
            "joinedAt": user["joined_at"],
            "links": links_payload(user),
            "projects": self.projects_payload(user_id),
            "bests": bests,
            "recent": [run_payload(row) for row in recent],
            "stats": {"runs": totals[0], "verifiedRuns": totals[1], "providers": totals[2], "activeDays": active_days},
        }


# —— 响应形状 ——

def links_payload(user):
    return {"website": user["website"], "github": user["github"], "x": user["x"]}


def private_user(user):
    return {"username": user["username"], "displayName": user["display_name"], "bio": user["bio"],
            "region": user["region"], "links": links_payload(user), "joinedAt": user["joined_at"]}


def run_payload(row):
    # 公开的 run 不带设备号和账号摘要
    return {
        "provider": row["provider"], "plan": row["plan_norm"], "planLabel": row["plan_label"],
        "windowKey": row["window_key"], "windowSeconds": row["window_seconds"], "windowTitle": row["window_title"],
        "season": row["season"], "windowStart": row["window_start"], "resetsAt": row["resets_at"],
        "peakPercent": row["peak_percent"], "secondsTo50": row["seconds_to_50"], "secondsTo90": row["seconds_to_90"],
        "secondsTo100": row["seconds_to_100"], "completedAt": row["completed_at"],
        "lastObservedAt": row["last_observed_at"], "tier": row["tier"],
    }


def entry_payload(rank, row, metric):
    speed = metric == "speed"
    return {
        "rank": rank, "username": row["username"], "displayName": row["display_name"],
        "value": row["seconds_to_100"] if speed else row["peak_percent"],
        "unit": "seconds" if speed else "percent",
        "tier": row["tier"],
        "achievedAt": row["completed_at"] if speed else row["peak_at"],
        "peakPercent": row["peak_percent"],
    }


def parse_region(value):
    # 契约：region 是过滤条件，不传表示所有人；all 作为「不过滤」的同义词也收下
    if value in (None, "", "all"):
        return None
    if value not in REGIONS:
        raise ApiError(400, "invalid_region", "region is \"global\" or \"china\".")
    return value


def _reject_constant(name):
    raise ValueError(name)


def parse_json_object(body):
    try:
        value = json.loads(body.decode("utf-8"), parse_constant=_reject_constant)
    except (UnicodeDecodeError, ValueError, RecursionError):
        raise ApiError(400, "invalid_json", "The request body must be a JSON object.") from None
    if not isinstance(value, dict):
        raise ApiError(400, "invalid_json", "The request body must be a JSON object.")
    return value


def profile_link(field, value):
    """个人链接统一存成 https 地址；GitHub 和 X 也接受账号名（可带 @）。"""
    if value is None or (isinstance(value, str) and not value.strip()):
        return None
    text = value.strip().lstrip("@") if isinstance(value, str) else None
    if field == "website":
        url = https_url(value, limit=200)
    elif field == "github":
        url = f"https://github.com/{text}" if text and GITHUB_HANDLE_RE.fullmatch(text) else \
            https_url(value, limit=200, hosts={"github.com", "www.github.com"})
    else:
        url = f"https://x.com/{text}" if text and X_HANDLE_RE.fullmatch(text) else \
            https_url(value, limit=200, hosts={"x.com", "www.x.com", "twitter.com", "www.twitter.com"})
    if url is None:
        raise ApiError(400, "invalid_links", f"links.{field} must be an https:// URL or a handle.")
    return url


def validate_project(index, item):
    def fail(message):
        raise ApiError(400, "invalid_project", f"Project {index + 1}: {message}", index=index)

    if not isinstance(item, dict):
        fail("must be an object.")
    try:
        name = clean_text(item.get("name"), 40)
    except ValueError:
        fail("name is at most 40 characters.")
    if not name:
        fail("name is required.")
    url = https_url(item.get("url"))
    if url is None:
        fail("url must be an https:// URL.")
    try:
        description = clean_text(item.get("description"), 140)
    except ValueError:
        fail("description is at most 140 characters.")
    github = item.get("github")
    if github in (None, ""):
        github = None
    elif isinstance(github, str) and GITHUB_REPO_RE.fullmatch(github.strip()):
        github = f"https://github.com/{github.strip()}"
    else:
        github = https_url(github, hosts={"github.com", "www.github.com"})
        if github is None:
            fail("github must be owner/repo or an https://github.com URL.")
    built_with = item.get("builtWith") or []
    if not isinstance(built_with, list) or len(built_with) > 16 or not all(
            isinstance(p, str) and PROVIDER_RE.fullmatch(p) for p in built_with):
        fail("builtWith is a list of provider ids.")
    return name, url, description, github, json.dumps(list(dict.fromkeys(built_with)))


# —— HTTP ——

class BodyTooLarge(Exception):
    pass


def client_ip(handler):
    # Caddy 会把真实来源追加到 X-Forwarded-For 末尾；取最后一个，客户端自己伪造的前缀不起作用
    forwarded = handler.headers.get("X-Forwarded-For", "")
    if forwarded:
        return forwarded.split(",")[-1].strip()
    return handler.client_address[0]


class Handler(BaseHTTPRequestHandler):
    server_version = "quotabar-run/1"
    sys_version = ""
    timeout = 30  # 慢速连接不能一直占着线程

    def log_message(self, fmt, *args):  # 只记来源 IP、请求行和状态码，不记请求头和请求体
        if not getattr(self.server, "quiet", False):
            sys.stderr.write("%s %s\n" % (client_ip(self), fmt % args))

    def do_GET(self):
        self._dispatch()

    def do_POST(self):
        self._dispatch()

    def do_PUT(self):
        self._dispatch()

    def do_DELETE(self):
        self._dispatch()

    def _dispatch(self):
        path, _, query = self.path.partition("?")
        try:
            body = self._read_body()
        except BodyTooLarge:
            self.close_connection = True
            return self._send(Response(413, {"error": "body_too_large", "message": "Request bodies are limited to 1 MB."}))
        except (ValueError, OSError):
            self.close_connection = True
            return self._send(Response(400, {"error": "invalid_body", "message": "The request body could not be read."}))
        params = {}
        for name, value in parse_qsl(query, keep_blank_values=True):
            params.setdefault(name, value)
        headers = {name.lower(): value for name, value in self.headers.items()}
        request = Request(self.command, path, params, headers, body, client_ip(self))
        self._send(self.server.service.handle(request))

    def _read_body(self):
        if "chunked" in self.headers.get("Transfer-Encoding", "").lower():
            return self._read_chunked()
        header = self.headers.get("Content-Length")
        if header is None:
            return b""
        if not header.strip().isdigit():
            raise ValueError("bad Content-Length")
        length = int(header)
        if length > MAX_BODY:
            self._drain(length)
            raise BodyTooLarge
        body = self.rfile.read(length)
        if len(body) != length:
            raise ValueError("short body")
        return body

    def _read_chunked(self):
        body = bytearray()
        while True:
            line = self.rfile.readline(1024)
            size = int(line.split(b";", 1)[0].strip() or b"x", 16)
            if size == 0:
                while self.rfile.readline(1024) not in (b"\r\n", b"\n", b""):
                    pass
                return bytes(body)
            if len(body) + size > MAX_BODY:
                raise BodyTooLarge
            body += self.rfile.read(size)
            self.rfile.readline(1024)

    def _drain(self, length):
        remaining = min(length, DRAIN_LIMIT)
        while remaining > 0:
            chunk = self.rfile.read(min(remaining, 65536))
            if not chunk:
                break
            remaining -= len(chunk)

    def _send(self, response):
        data = response.encoded() if response.status != 204 else b""
        self.send_response(response.status)
        if response.status != 204:
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", f"public, max-age={CACHE_TTL}" if response.public else "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        for name, value in response.headers.items():
            self.send_header(name, value)
        if self.close_connection:
            self.send_header("Connection", "close")
        self.end_headers()
        if data:
            self.wfile.write(data)


class RunHTTPServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, service, quiet=False):
        self.service = service
        self.quiet = quiet
        super().__init__(address, Handler)


def main():
    port = int(os.environ.get("QUOTA_RUN_PORT") or DEFAULT_PORT)
    db_path = os.environ.get("QUOTA_RUN_DB") or DEFAULT_DB
    secret_file = os.environ.get("QUOTA_RUN_SECRET_FILE") or DEFAULT_SECRET_FILE
    service = RunService(db_path, load_secret(secret_file))
    server = RunHTTPServer(("127.0.0.1", port), service)
    print(f"quota run on 127.0.0.1:{port}, db={db_path}", file=sys.stderr)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        service.close()


if __name__ == "__main__":
    main()

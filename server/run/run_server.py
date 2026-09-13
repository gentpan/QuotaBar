#!/usr/bin/env python3
"""Quota Run 排行榜服务：quota.run/api/v1 的后端。

契约以 docs/quota-run.md 为准（签名、规范串、数据模型、run 与 tier 规则、每个接口的
JSON）。这里只依赖标准库和 cryptography（主机上已装 43.x），数据放 SQLite（WAL）。

应用只上传读数（snapshot）和每分钟 token 数（activity），成绩全部由服务端算：
读数进来时只重算受影响的 run，榜单和个人页从 runs 表查询，公开 GET 在内存里缓存 30 秒。

账号在 quota.run 网页上建：GitHub / Google 登录或邮箱验证码，会话是 qr_session cookie；
Mac 通过 connect（类似 OAuth 设备流，绑定设备公钥）加入账号，应用里不输入任何账号信息。

环境变量（线上写在 /etc/quotabar-run.env）：
  QUOTA_RUN_PORT         监听端口，默认 8788（只绑 127.0.0.1，由 Caddy 在 quota.run 反代 /api/*）
  QUOTA_RUN_DB           数据库路径，默认 /var/lib/quotabar-run/run.db
  QUOTA_RUN_SECRET_FILE  账号摘要和邮箱验证码的 HMAC 密钥，默认 /etc/quotabar-run.secret；
                         不存在时生成 32 字节随机数的 hex（权限 0600）
  QUOTA_RUN_ORIGIN       站点来源，默认 https://quota.run；OAuth 回调地址、Origin 校验、connect 链接都用它
  QUOTA_RUN_GITHUB_CLIENT_ID / QUOTA_RUN_GITHUB_CLIENT_SECRET   GitHub 登录（两个都有才启用）
  QUOTA_RUN_GOOGLE_CLIENT_ID / QUOTA_RUN_GOOGLE_CLIENT_SECRET   Google 登录（两个都有才启用）
  QUOTA_RUN_SMTP_HOST / _PORT / _USER / _PASSWORD, QUOTA_RUN_MAIL_FROM
                         邮箱验证码（HOST 和 MAIL_FROM 都有才启用；465 直接 TLS，其他端口 STARTTLS）
  QUOTA_RUN_GITHUB_TOKEN 选填：取个人主页的 GitHub 贡献日历和提交数用的令牌（不需要任何权限）。
                         没有时日历从 github.com 的公开页面读，只有贡献总数，没有提交、PR 的分项
  QUOTA_RUN_INSECURE_COOKIES=1  cookie 去掉 Secure（本机 http 测试）
  QUOTA_RUN_DEV_LOGIN=1         POST /auth/dev 直接以某个邮箱登录（仅限本机测试）
  QUOTA_RUN_DEVICE_SIGNUP=1     重新打开 POST /register（仅限本机测试）
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
import smtplib
import sqlite3
import ssl
import sys
import threading
import time
import traceback
import urllib.error
import urllib.request
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from email.message import EmailMessage
from email.utils import formatdate, make_msgid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qsl, quote, unquote, urlencode, urlsplit
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec

API_PREFIX = "/api/v1"
# 早期版本挂在 quota.bar/api/run/v1；两个前缀都认，签名始终按实际收到的路径校验。
API_PREFIXES = ("/api/v1", "/api/run/v1")
DEFAULT_PORT = 8788
DEFAULT_DB = "/var/lib/quotabar-run/run.db"
DEFAULT_SECRET_FILE = "/etc/quotabar-run.secret"
DEFAULT_ORIGIN = "https://quota.run"

# —— 请求与签名 ——
MAX_BODY = 1_000_000          # 契约的 1 MB；Caddy 那边另设 2 MB 兜底，好让这里回 JSON 的 413
DRAIN_LIMIT = 4_000_000       # 超限的请求体先读掉这么多再回 413，免得对端写一半收到 RST
CLOCK_SKEW = 300
NONCE_TTL = 600
RANKED_COOLDOWN = 7 * 86400
CACHE_TTL = 30

# —— connect（Mac 加入账号）——
CONNECT_TTL = 600
CONNECT_GRACE = 600           # 过期后再留 10 分钟：轮询能看到 expired / approved，而不是直接 404
CONNECT_INTERVAL = 3
USER_CODE_LENGTH = 8
USER_CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"  # 去掉 I L O 0 1，对照浏览器里的码时不会看错

# —— 网页会话、OAuth、邮箱验证码 ——
SESSION_COOKIE = "qr_session"
SESSION_TTL = 30 * 86400
SESSION_REFRESH = 86400       # 滑动续期，一天最多续一次，免得每个请求都写库
OAUTH_COOKIE = "qr_oauth"
OAUTH_COOKIE_PATH = "/api/v1/auth"
OAUTH_TTL = 600
EMAIL_CODE_TTL = 600
EMAIL_CODE_GRACE = 3600       # 过期的码多留一小时，verify 才能回 code_expired 而不是 code_invalid
EMAIL_MAX_ATTEMPTS = 5
# 发码的滑动窗口：(次数, 秒)。同一地址 60 秒一次、每小时 6 次；同一 IP 每小时 20 次
EMAIL_WINDOWS = {"address_minute": (1, 60), "address_hour": (6, 3600), "ip_hour": (20, 3600)}
HTTP_TIMEOUT = 10
SMTP_TIMEOUT = 20
USER_AGENT = "quota-run/1"

GITHUB_AUTHORIZE_URL = "https://github.com/login/oauth/authorize"
GITHUB_TOKEN_URL = "https://github.com/login/oauth/access_token"
GITHUB_USER_URL = "https://api.github.com/user"
GITHUB_EMAILS_URL = "https://api.github.com/user/emails"
GOOGLE_AUTHORIZE_URL = "https://accounts.google.com/o/oauth2/v2/auth"
GOOGLE_TOKEN_URL = "https://oauth2.googleapis.com/token"
GOOGLE_USERINFO_URL = "https://openidconnect.googleapis.com/v1/userinfo"

# —— 个人主页：用量热力图与 GitHub ——
HEATMAP_WEEKS = 53            # 热力图从 52 周前那个星期一画到今天
GITHUB_API = "https://api.github.com"
GITHUB_GRAPHQL_URL = "https://api.github.com/graphql"
GITHUB_CONTRIBUTIONS_URL = "https://github.com/users/{login}/contributions"
GITHUB_TTL = 6 * 3600         # 贡献日历和仓库数据六小时取一次
GITHUB_RETRY = 15 * 60        # 取失败了十五分钟后再试，这期间照旧给上一份
GITHUB_PENDING_RETRY = 120    # commit_activity 回 202（GitHub 还在算）时两分钟后再取
GITHUB_WAIT = 8               # 第一次有人看、手里还没有数据时，请求最多等这么久
GITHUB_UNUSED = 14 * 86400    # 两周没人看的缓存清掉
GITHUB_WORKERS = 6
MAX_GITHUB_REPOS = 12
GITHUB_QUERY = (
    "query($login: String!) { user(login: $login) { contributionsCollection {"
    " contributionCalendar { totalContributions weeks { contributionDays { date contributionCount } } }"
    " totalCommitContributions totalPullRequestContributions totalIssueContributions"
    " totalPullRequestReviewContributions restrictedContributionsCount } } }")

# 令牌桶：(容量, 每补一个令牌的秒数)。write 是契约里的「每台设备 10 秒一次、突发 5」，网页会话按账号同样算；
# register 没有设备号，只能按来源 IP（connect/start 共用）；poll 是 connect 轮询（应用每 3 秒一次）；
# auth 管 OAuth 起跳、验证码校验、注册用户名这类登录动作；lookup 管用户名查重和 connect 码查询；
# public 是给公开 GET 的宽松上限，防止换查询串绕开缓存
DEFAULT_LIMITS = {"write": (5, 10.0), "register": (5, 10.0), "poll": (20, 2.0), "auth": (20, 6.0),
                  "lookup": (60, 1.0), "public": (240, 0.25)}

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
    "account admin api app about auth connect help leaderboard login logout me profile quota quotabar "
    "register run settings signup support u user users www zh en".split())
EMAIL_RE = re.compile(
    r"[a-z0-9.!#$%&'*+/=?^_`{|}~-]{1,64}@[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+")
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
TIMEZONE_RE = re.compile(r"[A-Za-z0-9_+-]{1,32}(?:/[A-Za-z0-9_+-]{1,32}){0,2}")
MASTODON_HANDLE_RE = re.compile(
    r"@?([A-Za-z0-9_]{1,30})@((?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63})", re.I)

# \u4e2a\u4eba\u4e3b\u9875\u7684\u94fe\u63a5\uff0c\u6309\u4e3b\u9875\u4e0a\u7684\u987a\u5e8f\uff1a\u952e \u2192 (\u5141\u8bb8\u7684\u4e3b\u673a\uff0c\u7b80\u5199\u7684\u6b63\u5219\uff0c\u7b80\u5199\u6362\u6210\u5730\u5740\u7684\u6a21\u677f)\u3002
# \u4e3b\u673a\u4e3a None \u7684\u6536\u4efb\u610f https \u5730\u5740\uff1bwebsite\u3001github\u3001x \u6709\u81ea\u5df1\u7684\u5217\uff0c\u5176\u4f59\u653e\u5728 users.links_json\u3002
LINK_KINDS = {
    "website": (None, None, None),
    "blog": (None, None, None),
    "github": (frozenset({"github.com", "www.github.com"}), GITHUB_HANDLE_RE, "https://github.com/{}"),
    "gitlab": (frozenset({"gitlab.com", "www.gitlab.com"}), re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,254}"),
               "https://gitlab.com/{}"),
    "x": (frozenset({"x.com", "www.x.com", "twitter.com", "www.twitter.com"}), X_HANDLE_RE, "https://x.com/{}"),
    "bluesky": (frozenset({"bsky.app"}), re.compile(r"(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}", re.I),
                "https://bsky.app/profile/{}"),
    "mastodon": (None, None, None),   # \u5b9e\u4f8b\u5404\u4e0d\u76f8\u540c\uff0c\u4efb\u610f https \u5730\u5740\uff1b@name@host \u53e6\u5916\u6362\u7b97
    "linkedin": (frozenset({"linkedin.com", "www.linkedin.com", "cn.linkedin.com"}), re.compile(r"[A-Za-z0-9-]{3,100}"),
                 "https://www.linkedin.com/in/{}"),
    "youtube": (frozenset({"youtube.com", "www.youtube.com", "m.youtube.com"}), re.compile(r"[A-Za-z0-9._-]{3,30}"),
                "https://www.youtube.com/@{}"),
    "telegram": (frozenset({"t.me", "telegram.me"}), re.compile(r"[A-Za-z0-9_]{5,32}"), "https://t.me/{}"),
    "huggingface": (frozenset({"huggingface.co"}), re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,95}"),
                    "https://huggingface.co/{}"),
    "bilibili": (frozenset({"space.bilibili.com", "bilibili.com", "www.bilibili.com", "b23.tv"}), re.compile(r"\d{1,20}"),
                 "https://space.bilibili.com/{}"),
    "zhihu": (frozenset({"zhihu.com", "www.zhihu.com"}), re.compile(r"[A-Za-z0-9_-]{1,64}"),
              "https://www.zhihu.com/people/{}"),
    "juejin": (frozenset({"juejin.cn"}), re.compile(r"\d{1,24}"), "https://juejin.cn/user/{}"),
    "v2ex": (frozenset({"v2ex.com", "www.v2ex.com"}), re.compile(r"[A-Za-z0-9_]{1,32}"), "https://www.v2ex.com/member/{}"),
    "weibo": (frozenset({"weibo.com", "www.weibo.com", "weibo.cn", "m.weibo.cn"}), re.compile(r"\d{5,20}"),
              "https://weibo.com/u/{}"),
    "xiaohongshu": (frozenset({"xiaohongshu.com", "www.xiaohongshu.com", "xhslink.com"}), None, None),
}
LINK_COLUMNS = ("website", "github", "x")


class ApiError(Exception):
    def __init__(self, status, code, message, **extra):
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message
        self.extra = extra

    def payload(self):
        return {"error": self.code, "message": self.message, **self.extra}


class OAuthFailure(Exception):
    """向 GitHub / Google 换令牌或取用户信息失败；消息里不带令牌和响应内容。"""


class Rejected(Exception):
    """单条读数不合格：记进 rejected，不影响同批其他读数。"""


MISSING = object()


class Request:
    __slots__ = ("method", "path", "query", "headers", "body", "ip", "cookies", "set_cookies", "session")

    def __init__(self, method, path, query, headers, body, ip, cookies=None):
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
        self.ip = ip
        self.cookies = cookies or {}
        self.set_cookies = []      # 处理过程中要下发的 Set-Cookie（续期、登录、登出），出口统一加到响应上
        self.session = MISSING     # current_session 查过一次就缓存在这里


class Response:
    def __init__(self, status, payload=None, public=False, headers=None, cookies=None):
        self.status = status
        self.payload = payload
        self.public = public
        self.headers = headers or {}
        self.cookies = list(cookies or ())  # 每项是一整条 Set-Cookie，可以有多条
        self._encoded = None

    def encoded(self):
        if self._encoded is None:
            self._encoded = b"" if self.payload is None else json.dumps(
                self.payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        return self._encoded


class Actor:
    """共用接口的调用方：设备签名（device_id 有值）或已有账号的网页会话（session 有值）。"""
    __slots__ = ("user_id", "device_id", "session")

    def __init__(self, user_id, device_id=None, session=None):
        self.user_id = user_id
        self.device_id = device_id
        self.session = session


class Settings:
    """线上配置，来自环境变量。repr 里只说哪些登录方式可用，不带任何密钥。"""

    def __init__(self, origin=DEFAULT_ORIGIN, insecure_cookies=False, github_client_id="", github_client_secret="",
                 google_client_id="", google_client_secret="", smtp_host="", smtp_port=0, smtp_user="",
                 smtp_password="", mail_from="", github_token=""):
        self.origin = (origin or DEFAULT_ORIGIN).strip().rstrip("/")
        self.insecure_cookies = bool(insecure_cookies)
        self.github_client_id = github_client_id or ""
        self.github_client_secret = github_client_secret or ""
        self.google_client_id = google_client_id or ""
        self.google_client_secret = google_client_secret or ""
        self.smtp_host = smtp_host or ""
        self.smtp_port = int(smtp_port or 0)
        self.smtp_user = smtp_user or ""
        self.smtp_password = smtp_password or ""
        self.mail_from = mail_from or ""
        self.github_token = github_token or ""

    @classmethod
    def from_env(cls, env=None):
        env = os.environ if env is None else env

        def get(name):
            return (env.get(name) or "").strip()

        port = get("QUOTA_RUN_SMTP_PORT")
        return cls(
            origin=get("QUOTA_RUN_ORIGIN") or DEFAULT_ORIGIN,
            insecure_cookies=get("QUOTA_RUN_INSECURE_COOKIES") == "1",
            github_client_id=get("QUOTA_RUN_GITHUB_CLIENT_ID"),
            github_client_secret=get("QUOTA_RUN_GITHUB_CLIENT_SECRET"),
            google_client_id=get("QUOTA_RUN_GOOGLE_CLIENT_ID"),
            google_client_secret=get("QUOTA_RUN_GOOGLE_CLIENT_SECRET"),
            smtp_host=get("QUOTA_RUN_SMTP_HOST"),
            smtp_port=int(port) if port.isdigit() else 0,
            smtp_user=get("QUOTA_RUN_SMTP_USER"),
            smtp_password=env.get("QUOTA_RUN_SMTP_PASSWORD") or "",
            mail_from=get("QUOTA_RUN_MAIL_FROM"),
            github_token=get("QUOTA_RUN_GITHUB_TOKEN"),
        )

    @property
    def github(self):
        return bool(self.github_client_id and self.github_client_secret)

    @property
    def google(self):
        return bool(self.google_client_id and self.google_client_secret)

    @property
    def email(self):
        return bool(self.smtp_host and self.mail_from)

    def __repr__(self):
        return (f"Settings(origin={self.origin!r}, github={self.github}, google={self.google}, "
                f"email={self.email}, github_token={bool(self.github_token)}, insecure_cookies={self.insecure_cookies})")


def urllib_http(method, url, headers=None, body=None):
    """默认的出站 HTTP：向 GitHub、Google 换令牌和取用户信息，以及取个人主页的 GitHub 公开数据。返回 (状态码, 响应体)。

    测试注入假的同签名函数，不连外网。
    """
    request = urllib.request.Request(url, data=body, headers=headers or {}, method=method)
    try:
        with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT) as response:
            return response.status, response.read(MAX_BODY)
    except urllib.error.HTTPError as error:
        try:
            return error.code, error.read(MAX_BODY)
        finally:
            error.close()


class SmtpMailer:
    """默认发信：465 端口直接 TLS，其他端口 STARTTLS。在后台线程里发，不占服务锁和请求线程。"""

    def __init__(self, settings):
        self.host = settings.smtp_host
        self.port = settings.smtp_port or 587
        self.user = settings.smtp_user
        self.password = settings.smtp_password
        self.sender = settings.mail_from

    def __call__(self, to, subject, text):
        threading.Thread(target=self.send, args=(to, subject, text), daemon=True).start()

    def send(self, to, subject, text):
        message = EmailMessage()
        message["From"] = self.sender
        message["To"] = to
        message["Subject"] = subject
        message["Date"] = formatdate(usegmt=True)
        domain = self.sender.rpartition("@")[2].strip(" >") or None
        message["Message-ID"] = make_msgid(domain=domain)
        message.set_content(text)
        context = ssl.create_default_context()
        try:
            if self.port == 465:
                client = smtplib.SMTP_SSL(self.host, self.port, timeout=SMTP_TIMEOUT, context=context)
            else:
                client = smtplib.SMTP(self.host, self.port, timeout=SMTP_TIMEOUT)
            with client:
                if self.port != 465:
                    client.starttls(context=context)
                if self.user:
                    client.login(self.user, self.password)
                client.send_message(message)
        except Exception as error:  # noqa: BLE001 — 后台线程里的任何失败都只记一行
            # 不打印收件人、验证码和服务器回显，只留错误类型和 SMTP 状态码
            code = getattr(error, "smtp_code", "")
            print(f"mail: sending a code failed: {type(error).__name__} {code}".rstrip(), file=sys.stderr)


# —— 纯函数：编码、校验、run 计算 ——

def b64url_encode(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


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


def username_base(text):
    """把 GitHub 登录名或邮箱 @ 前面那段整理成用户名的样子，只用来给注册页一个建议。"""
    if not isinstance(text, str):
        return ""
    text = text.partition("+")[0].casefold()
    base = re.sub(r"[^a-z0-9_-]+", "-", text)
    base = re.sub(r"-{2,}", "-", base).strip("_-")[:20].rstrip("_-")
    if 0 < len(base) < 3:
        base += "-run"
    return base


def normalize_email(value):
    """邮箱身份的 subject：去首尾空白、转小写。只收常见的 ASCII 地址，超过 254 个字符不收。"""
    if not isinstance(value, str):
        return None
    email = value.strip().lower()
    if len(email) > 254 or not EMAIL_RE.fullmatch(email):
        return None
    return email


def normalize_user_code(value):
    """connect 码查找时忽略大小写、空格和连字符。"""
    if not isinstance(value, str):
        return None
    code = re.sub(r"[\s-]", "", unquote(value)).upper()
    if len(code) != USER_CODE_LENGTH or any(ch not in USER_CODE_ALPHABET for ch in code):
        return None
    return code


def format_user_code(code):
    return f"{code[:4]}-{code[4:]}"


def safe_next(value):
    """登录后的去处只能是站内相对路径：以 / 开头、不是 //，也不带反斜杠和空白（有的浏览器把 /\\ 当成 //）。"""
    if (not isinstance(value, str) or not value.startswith("/") or value.startswith("//") or "\\" in value
            or len(value) > 512 or any(ch.isspace() or ord(ch) < 32 or ord(ch) == 127 for ch in value)):
        return "/account"
    return value


def with_query(path, text):
    """在相对路径上追加查询参数，保留原有的查询串和 # 片段。"""
    path, hash_mark, fragment = path.partition("#")
    return path + ("&" if "?" in path else "?") + text + hash_mark + fragment


def token_hash(token):
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def key_scope(public_key):
    # 还没有设备号的签名请求（register、connect）把 nonce 挂在公钥哈希名下
    return "key:" + hashlib.sha256(public_key).hexdigest()[:40]


def clip_text(value, limit):
    """外部来的名字（GitHub、Google）：清掉控制字符，超长截断而不是报错。"""
    if not isinstance(value, str):
        return None
    try:
        text = clean_text(value[: limit * 4], limit * 4)
    except ValueError:
        return None
    return text[:limit].strip() or None


def parse_cookies(header):
    """Cookie 请求头拆成 dict；同名的取第一个（浏览器把路径更具体的放在前面）。"""
    cookies = {}
    for part in (header or "").split(";"):
        name, sep, value = part.partition("=")
        name = name.strip()
        if sep and name and name not in cookies:
            cookies[name] = value.strip().strip('"')
    return cookies


def email_code_message(code, lang):
    """验证码邮件：纯文本，不带任何链接。"""
    if lang == "zh":
        return (f"Quota Run 验证码：{code}",
                f"你的 Quota Run 登录验证码是：\n\n    {code}\n\n"
                "验证码 10 分钟内有效。\n\n"
                "如果不是你本人申请的，忽略这封邮件即可，什么都不会发生。\n")
    return (f"Your Quota Run code: {code}",
            f"Your Quota Run sign-in code is:\n\n    {code}\n\n"
            "It expires in 10 minutes.\n\n"
            "If you did not ask for this code, you can ignore this email; nothing will happen.\n")


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


def account_digest(provider, account):
    """应用端的账号摘要（契约 Signing → Account digest）。服务端只拿登录邮箱算它，用来比对邮箱认领。"""
    text = f"quota-run-account-v1\n{provider}\n{account.strip().lower()}"
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


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

SCHEMA_V2 = """
BEGIN;
-- 配对码被 connect 取代
DROP TABLE IF EXISTS pair_codes;
-- 登录身份：(provider, subject) 唯一；user_id 为空表示还没注册用户名（会话处于 needs signup）
CREATE TABLE IF NOT EXISTS identities (
    id TEXT PRIMARY KEY,
    user_id INTEGER REFERENCES users(id) ON DELETE CASCADE,
    provider TEXT NOT NULL,
    subject TEXT NOT NULL,
    email TEXT,
    email_verified INTEGER NOT NULL DEFAULT 0,
    name TEXT,
    login TEXT,
    linked_at INTEGER NOT NULL,
    last_used_at INTEGER NOT NULL,
    UNIQUE (provider, subject)
);
CREATE INDEX IF NOT EXISTS identities_user ON identities(user_id);
CREATE INDEX IF NOT EXISTS identities_verified_email ON identities(email) WHERE email_verified = 1;
-- 会话只存令牌的 SHA-256
CREATE TABLE IF NOT EXISTS sessions (
    token_hash TEXT PRIMARY KEY,
    identity_id TEXT NOT NULL REFERENCES identities(id) ON DELETE CASCADE,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    refreshed_at INTEGER NOT NULL
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS sessions_identity ON sessions(identity_id);
CREATE INDEX IF NOT EXISTS sessions_expiry ON sessions(expires_at);
-- 每个地址同时只有一个有效码，存 HMAC-SHA256(密钥, email + code)
CREATE TABLE IF NOT EXISTS email_codes (
    email TEXT PRIMARY KEY,
    code_hmac TEXT NOT NULL,
    expires_at INTEGER NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,
    link_user_id INTEGER REFERENCES users(id) ON DELETE CASCADE
) WITHOUT ROWID;
-- OAuth 的 state 只存哈希；verifier 是 PKCE 换令牌时要用的，10 分钟后删
CREATE TABLE IF NOT EXISTS oauth_states (
    state_hash TEXT PRIMARY KEY,
    provider TEXT NOT NULL,
    verifier TEXT NOT NULL,
    next TEXT NOT NULL,
    link_user_id INTEGER REFERENCES users(id) ON DELETE CASCADE,
    created_at INTEGER NOT NULL
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS oauth_states_created ON oauth_states(created_at);
-- connect 请求：码只存 SHA-256；批准时建设备，device_id 记在这里给轮询取
CREATE TABLE IF NOT EXISTS connect_requests (
    id TEXT PRIMARY KEY,
    code_hash TEXT NOT NULL UNIQUE,
    public_key BLOB NOT NULL,
    device_name TEXT NOT NULL,
    platform TEXT NOT NULL,
    app_version TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'denied')),
    user_id INTEGER REFERENCES users(id) ON DELETE CASCADE,
    device_id TEXT,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS connect_requests_key ON connect_requests(public_key);
CREATE INDEX IF NOT EXISTS connect_requests_expiry ON connect_requests(expires_at);
INSERT INTO schema_version(version) VALUES (2);
COMMIT;
"""

def migrate_v3(service):
    """服务商账号的归属：account_owners 表、绑定的服务商和最近上传时间、run 的 account_verified。

    要按新规则重算已有的 run（Python 里算），所以不是一段 SQL 脚本：整个升级放在一个事务里，
    中途失败就整体回滚，下次启动重来。
    """
    db = service.db
    now = service.now()
    with service.transaction():
        db.execute(
            "CREATE TABLE IF NOT EXISTS account_owners ("
            " account_hmac TEXT PRIMARY KEY,"
            " provider TEXT NOT NULL,"
            " user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,"
            " via TEXT NOT NULL CHECK (via IN ('first', 'email')),"
            " claimed_at INTEGER NOT NULL"
            ") WITHOUT ROWID")
        db.execute("CREATE INDEX IF NOT EXISTS account_owners_user ON account_owners(user_id)")
        db.execute("ALTER TABLE account_bindings ADD COLUMN provider TEXT NOT NULL DEFAULT ''")
        db.execute("ALTER TABLE account_bindings ADD COLUMN last_seen_at INTEGER NOT NULL DEFAULT 0")
        db.execute("ALTER TABLE runs ADD COLUMN account_verified INTEGER NOT NULL DEFAULT 0")
        # 下面要用 recompute_run 重算，它按最新的 runs 表结构写，所以后来加的列在这里先补上
        ensure_run_public_ids(db)
        # 绑定只来自计分读数；之前非计分设备的读数也建过绑定，这里去掉（读数本身保留）
        db.execute(
            "DELETE FROM account_bindings WHERE NOT EXISTS (SELECT 1 FROM snapshots s"
            " WHERE s.account_hmac = account_bindings.account_hmac AND s.user_id = account_bindings.user_id"
            " AND s.counted = 1)")
        db.execute(
            "UPDATE account_bindings SET"
            " provider = COALESCE((SELECT s.provider FROM snapshots s WHERE s.account_hmac = account_bindings.account_hmac"
            "   AND s.user_id = account_bindings.user_id ORDER BY s.id LIMIT 1), ''),"
            " last_seen_at = MAX(first_seen_at, COALESCE((SELECT MAX(s.received_at) FROM snapshots s"
            "   WHERE s.account_hmac = account_bindings.account_hmac AND s.user_id = account_bindings.user_id), 0))")
        # 每个账号最早绑定的人先按 first 拥有；同一秒绑定的按用户号小的
        db.execute(
            "INSERT OR IGNORE INTO account_owners(account_hmac, provider, user_id, via, claimed_at)"
            " SELECT b.account_hmac, b.provider, b.user_id, 'first', b.first_seen_at FROM account_bindings b"
            " WHERE NOT EXISTS (SELECT 1 FROM account_bindings e WHERE e.account_hmac = b.account_hmac"
            "   AND (e.first_seen_at < b.first_seen_at OR (e.first_seen_at = b.first_seen_at AND e.user_id < b.user_id)))")
        run_keys = set()
        users = [row[0] for row in db.execute(
            "SELECT user_id FROM account_bindings GROUP BY user_id ORDER BY MIN(first_seen_at), user_id")]
        for user_id in users:
            service.check_claims(user_id, now, run_keys)
        # 已有的 run 和计分读数能组成的 run 都按新规则重算（没有读数的 run 会被删掉）
        run_keys.update(tuple(row) for row in db.execute(f"SELECT {RUN_KEY_COLUMNS} FROM runs"))
        run_keys.update(tuple(row) for row in db.execute(
            f"SELECT DISTINCT {RUN_KEY_COLUMNS} FROM snapshots WHERE counted = 1 AND rankable = 1"))
        for key in run_keys:
            service.recompute_run(key, now)
        db.execute("INSERT INTO schema_version(version) VALUES (3)")


def new_run_id():
    # 9 个随机字节正好是 12 个 base64url 字符，不带填充
    return secrets.token_urlsafe(9)


def ensure_run_public_ids(db):
    """runs.public_id：公开接口里的 runId，不透明、重算不变。可重复执行：列已在就只补空值。"""
    columns = {row[1] for row in db.execute("PRAGMA table_info(runs)")}
    if "public_id" not in columns:
        db.execute("ALTER TABLE runs ADD COLUMN public_id TEXT")
    used = {row[0] for row in db.execute("SELECT public_id FROM runs WHERE public_id IS NOT NULL")}
    for (run_id,) in db.execute("SELECT id FROM runs WHERE public_id IS NULL").fetchall():
        public_id = new_run_id()
        while public_id in used:
            public_id = new_run_id()
        used.add(public_id)
        db.execute("UPDATE runs SET public_id = ? WHERE id = ?", (public_id, run_id))
    db.execute("CREATE UNIQUE INDEX IF NOT EXISTS runs_public_id ON runs(public_id)")


def migrate_v4(service):
    """给每条 run 一个公开 id（/runs/<runId>、榜单条目和个人页里的 runId）。"""
    with service.transaction():
        ensure_run_public_ids(service.db)
        service.db.execute("INSERT INTO schema_version(version) VALUES (4)")


def migrate_v5(service):
    """个人主页：更多链接、热力图用的时区、两个显示开关，以及 GitHub 公开数据的缓存。"""
    db = service.db
    with service.transaction():
        # 可重复执行：已经有的列不再加
        columns = {row[1] for row in db.execute("PRAGMA table_info(users)")}
        for column, definition in (("links_json", "TEXT NOT NULL DEFAULT '{}'"), ("timezone", "TEXT"),
                                   ("show_activity", "INTEGER NOT NULL DEFAULT 1"),
                                   ("show_github", "INTEGER NOT NULL DEFAULT 1")):
            if column not in columns:
                db.execute(f"ALTER TABLE users ADD COLUMN {column} {definition}")
        # key 是 user:<GitHub 数字 id> 或 repo:<owner/name 小写>；payload 是整理好的 JSON。
        # retry_at 之前不再去取（失败退避、GitHub 还在算）；used_at 是最近一次有人看的时间
        db.execute(
            "CREATE TABLE IF NOT EXISTS github_cache ("
            " key TEXT PRIMARY KEY, payload TEXT, fetched_at INTEGER NOT NULL DEFAULT 0,"
            " retry_at INTEGER NOT NULL DEFAULT 0, used_at INTEGER NOT NULL DEFAULT 0"
            ") WITHOUT ROWID")
        db.execute("INSERT INTO schema_version(version) VALUES (5)")


MIGRATIONS = [(1, SCHEMA_V1), (2, SCHEMA_V2), (3, migrate_v3), (4, migrate_v4), (5, migrate_v5)]

PUBLIC_TIERS = "('verified', 'standard')"   # flagged 和 unranked 不上榜、不进个人页和统计
PROVIDER_ACCOUNT_ID_RE = re.compile(r"[0-9a-f]{16}")
MAX_LOOKUP_DIGESTS = 20
RUN_ID_RE = re.compile(r"[A-Za-z0-9_-]{12}")
MAX_CURVE_POINTS = 240
CURVE_THRESHOLDS = (50.0, 90.0, FULL_THRESHOLD)
MAX_LEADERBOARD_LIMIT = 200

# 每人一条最好成绩的排序，{p} 是表别名前缀（子查询里 runs 和 users 都有 id 列）。
# speed / to90 / to50 只看达到该线的 run；overall 是摘要和 insights 用的「速度最好的一条」：
# 到 100% 的按速度在前，没到的排在后面（峰值高的、早观察到的在前），这样没跑完的人也算进人数
BEST_ORDERS = {
    "speed": "{p}seconds_to_100 ASC, {p}completed_at ASC, {p}id ASC",
    "to90": "{p}seconds_to_90 ASC, {p}window_start + {p}seconds_to_90 ASC, {p}id ASC",
    "to50": "{p}seconds_to_50 ASC, {p}window_start + {p}seconds_to_50 ASC, {p}id ASC",
    "peak": "{p}peak_percent DESC, COALESCE({p}completed_at, {p}last_observed_at) ASC, {p}id ASC",
    # 跑完的之间和 speed 完全同序（CASE 对它们都是 NULL），摘要里的 fastest 就是速度榜第一
    "overall": "{p}seconds_to_100 IS NULL, {p}seconds_to_100 ASC, {p}completed_at ASC,"
               " CASE WHEN {p}seconds_to_100 IS NULL THEN {p}peak_percent END DESC,"
               " CASE WHEN {p}seconds_to_100 IS NULL THEN {p}last_observed_at END ASC, {p}id ASC",
}
METRIC_COLUMNS = {"speed": "seconds_to_100", "to90": "seconds_to_90", "to50": "seconds_to_50"}

RUN_KEY_COLUMNS = "user_id, provider, plan_norm, window_key, resets_bucket"
RUN_KEY_WHERE = "user_id = ? AND provider = ? AND plan_norm = ? AND window_key = ? AND resets_bucket = ?"


class RunService:
    """全部业务逻辑。HTTP 层只负责把请求拆成 Request、把 Response 写回去。

    一条 SQLite 连接加一把锁：流量很小，串行化最省心，也让「读数写入 + run 重算」
    天然处在同一个事务里。clock 可注入，测试用假时钟推进时间。
    http（向 GitHub、Google 发请求）和 mailer（发验证码）也可注入：测试不连外网、不发信。
    """

    def __init__(self, db_path, secret, clock=time.time, cache_ttl=CACHE_TTL, limits=None, settings=None,
                 http=None, mailer=None, device_signup=False, dev_login=False):
        directory = os.path.dirname(db_path)
        if directory:
            os.makedirs(directory, exist_ok=True)
        self.secret = secret
        self.clock = clock
        self.cache_ttl = cache_ttl
        self.limits = dict(DEFAULT_LIMITS, **(limits or {}))
        self.email_windows = dict(EMAIL_WINDOWS)
        self.settings = settings or Settings()
        self.http = http or urllib_http
        if mailer is None and self.settings.email:
            mailer = SmtpMailer(self.settings)
        self.mailer = mailer
        self.device_signup = device_signup
        self.dev_login = dev_login
        self.listen_host = None   # RunHTTPServer 填上；/auth/dev 只在 127.0.0.1 上开
        self._windows = {}
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
        self._github_jobs = {}    # 正在后台取的 GitHub 缓存键 → 线程，同一个键同时只取一次
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
                    if callable(script):
                        script(self)
                    else:
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
            prefix = next((p for p in API_PREFIXES if request.path.startswith(p + "/")), None)
            if prefix is None:
                raise ApiError(404, "not_found", "No such endpoint.")
            route = request.path[len(prefix):]
            if request.method == "GET" and route in ("/auth/github/callback", "/auth/google/callback"):
                # 回调要向 GitHub / Google 发请求，不能整段占着锁；它自己分段加锁
                response = self.oauth_callback(request, route.split("/")[2])
            elif request.method == "GET" and route.startswith("/users/") and route.endswith("/github") \
                    and route.count("/") == 3:
                # 可能要等 GitHub 的数据，同样自己分段加锁
                response = self.user_github(request, unquote(route[len("/users/"):-len("/github")]))
            else:
                with self.lock:
                    response = self._route(request, route)
        except ApiError as error:
            headers = {}
            if error.status == 429 and "retryAfter" in error.extra:
                headers["Retry-After"] = str(error.extra["retryAfter"])
            response = Response(error.status, error.payload(), headers=headers)
        except Exception:
            traceback.print_exc(file=sys.stderr)
            return Response(500, {"error": "internal", "message": "Something went wrong on the server."})
        if request.set_cookies:
            # 公开 GET 的响应对象是缓存共用的，不能原地改；带 cookie 的一律另建一个
            response = Response(response.status, response.payload, headers=response.headers,
                                cookies=response.cookies + request.set_cookies)
        return response

    def _route(self, request, route):
        method = request.method
        self._purge(self.now())
        if method == "GET":
            if (route in ("/stats", "/boards", "/leaderboard", "/insights") or route.startswith("/users/")
                    or (route.startswith("/runs/") and route.count("/") == 2)):
                return self._public(request, route)
            if route == "/me":
                return Response(200, self.me(self.actor(request)))
            if route == "/session":
                return Response(200, self.session_payload(request))
            if route == "/auth/providers":
                return Response(200, self.providers())
            if route in ("/auth/github/start", "/auth/google/start"):
                return self.oauth_start(request, route.split("/")[2])
            if route.startswith("/usernames/"):
                return Response(200, self.username_availability(request, route[len("/usernames/"):]))
            if route.startswith("/connect/") and route.count("/") == 2:
                return Response(200, self.connect_info(request, route[len("/connect/"):]))
        elif method == "POST":
            if route == "/register" and self.device_signup:
                return self.register(request)
            if route == "/snapshots":
                return Response(200, self.post_snapshots(request, self.authenticate_write(request)))
            if route == "/devices/ranked":
                return Response(200, self.set_ranked(request, self.actor(request, write=True)))
            if route == "/accounts/lookup":
                return Response(200, self.lookup_accounts(request))
            if route == "/connect/start":
                return self.connect_start(request)
            if route == "/connect/poll":
                return Response(200, self.connect_poll(request))
            if route.startswith("/connect/") and route.count("/") == 3:
                code, _, action = route[len("/connect/"):].partition("/")
                if action == "approve":
                    return Response(200, self.connect_approve(request, code))
                if action == "deny":
                    return Response(200, self.connect_deny(request, code))
            if route == "/auth/logout":
                return self.logout(request)
            if route == "/auth/email/start":
                return self.email_start(request)
            if route == "/auth/email/verify":
                return self.email_verify(request)
            if route == "/auth/dev" and self.dev_login_enabled():
                return Response(200, self.dev_sign_in(request))
            if route == "/signup":
                return self.signup(request)
        elif method == "PUT":
            if route == "/profile":
                return Response(200, self.put_profile(request, self.actor(request, write=True)))
            if route == "/projects":
                return Response(200, self.put_projects(request, self.actor(request, write=True)))
        elif method == "DELETE":
            if route == "/account":
                self.delete_account(request, self.actor(request, write=True))
                return Response(204)
            if route == "/devices/current":
                self.delete_current_device(self.authenticate_write(request))
                return Response(204)
            if route.startswith("/devices/"):
                device_id = route[len("/devices/"):]
                return Response(200, self.delete_device(device_id, self.actor(request, write=True)))
            if route.startswith("/identities/"):
                return Response(200, self.delete_identity(request, route[len("/identities/"):]))
            if route.startswith("/accounts/"):
                account_id = route[len("/accounts/"):]
                return Response(200, self.delete_provider_account(account_id, self.actor(request, write=True)))
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
            elif route == "/insights":
                response = Response(200, self.insights(request.query), public=True)
            elif route.startswith("/runs/"):
                response = Response(200, self.run_detail(unquote(route[len("/runs/"):])), public=True)
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

    def actor(self, request, write=False):
        """共用接口：带设备签名头的按设备验签（旧规则不变），否则要已有账号的网页会话。"""
        if "x-quota-device" in request.headers or "x-quota-signature" in request.headers:
            device = self.authenticate_write(request) if write else self.authenticate(request)
            return Actor(device["user_id"], device["id"])
        session = self.require_session(request)
        if write:
            self.take_token(f"user:{session['user_id']}", "write")
        return Actor(session["user_id"], None, session)

    # —— 网页会话 ——

    def cookie(self, name, value, path, max_age):
        secure = "" if self.settings.insecure_cookies else " Secure;"
        return f"{name}={value}; Path={path}; HttpOnly;{secure} SameSite=Lax; Max-Age={max_age}"

    def current_session(self, request):
        """cookie 对应的有效会话，连同它的身份（i.* 的列，id 是身份 id）；没有则 None。

        滑动续期：距上次续期满一天才顺延 30 天，并重新下发 cookie。无效或过期的 cookie 顺手清掉。
        """
        if request.session is not MISSING:
            return request.session
        request.session = None
        token = request.cookies.get(SESSION_COOKIE)
        if not token:
            return None
        now = self.now()
        row = None
        raw = b64url_decode(token)
        if raw is not None and len(raw) == 32:
            row = self.db.execute(
                "SELECT s.token_hash, s.expires_at, s.refreshed_at, i.* FROM sessions s"
                " JOIN identities i ON i.id = s.identity_id WHERE s.token_hash = ?", (token_hash(token),)).fetchone()
        if row is None or row["expires_at"] <= now:
            if row is not None:
                self.db.execute("DELETE FROM sessions WHERE token_hash = ?", (row["token_hash"],))
            request.set_cookies.append(self.cookie(SESSION_COOKIE, "", "/", 0))
            return None
        if now - row["refreshed_at"] >= SESSION_REFRESH:
            self.db.execute("UPDATE sessions SET expires_at = ?, refreshed_at = ? WHERE token_hash = ?",
                            (now + SESSION_TTL, now, row["token_hash"]))
            request.set_cookies.append(self.cookie(SESSION_COOKIE, token, "/", SESSION_TTL))
        request.session = dict(row)
        return request.session

    def check_origin(self, request):
        # 会话靠 cookie，浏览器会自动带上；不是 GET 的请求必须来自 quota.run 自己的页面（防 CSRF）
        if request.method != "GET" and request.headers.get("origin") != self.settings.origin:
            raise ApiError(403, "bad_origin", "This request must come from the Quota Run site.")

    def require_session(self, request, account=True):
        session = self.current_session(request)
        if session is None:
            raise ApiError(401, "not_signed_in", "Sign in on quota.run first.")
        self.check_origin(request)
        if account and session["user_id"] is None:
            raise ApiError(403, "needs_signup", "Choose a username to finish signing up.")
        return session

    def start_session(self, request, identity_id, now):
        old = request.cookies.get(SESSION_COOKIE)
        if old:
            self.db.execute("DELETE FROM sessions WHERE token_hash = ?", (token_hash(old),))
        token = b64url_encode(secrets.token_bytes(32))
        self.db.execute(
            "INSERT INTO sessions(token_hash, identity_id, created_at, expires_at, refreshed_at) VALUES (?, ?, ?, ?, ?)",
            (token_hash(token), identity_id, now, now + SESSION_TTL, now))
        request.set_cookies[:] = [c for c in request.set_cookies if not c.startswith(SESSION_COOKIE + "=")]
        request.set_cookies.append(self.cookie(SESSION_COOKIE, token, "/", SESSION_TTL))
        request.session = MISSING

    def dev_login_enabled(self):
        # 仅限本机测试。线上服务同样只监听 127.0.0.1（Caddy 反代），所以还要求站点来源是本机地址，
        # 误把 QUOTA_RUN_DEV_LOGIN=1 写进线上配置也打不开
        host = urlsplit(self.settings.origin).hostname
        return bool(self.dev_login and self.listen_host == "127.0.0.1" and host in ("localhost", "127.0.0.1"))

    def take_windows(self, rules, message):
        """按次数的滑动窗口（发验证码这种按小时计的限额）。rules 是 [(key, 次数, 秒)]，全部通过才各记一次。"""
        now = self.clock()
        wait = 0
        for key, count, period in rules:
            stamps = [stamp for stamp in self._windows.get(key, ()) if stamp > now - period]
            self._windows[key] = stamps
            if len(stamps) >= count:
                wait = max(wait, math.ceil(stamps[-count] + period - now))
        if wait:
            raise ApiError(429, "rate_limited", message, retryAfter=max(1, wait))
        for key, _, _ in rules:
            self._windows[key].append(now)
        if len(self._windows) > 20000:
            for stale in [k for k, stamps in self._windows.items() if not stamps or stamps[-1] < now - 3600]:
                del self._windows[stale]

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
        self.db.execute("DELETE FROM sessions WHERE expires_at <= ?", (now,))
        self.db.execute("DELETE FROM email_codes WHERE expires_at < ?", (now - EMAIL_CODE_GRACE,))
        self.db.execute("DELETE FROM oauth_states WHERE created_at < ?", (now - OAUTH_TTL,))
        self.db.execute("DELETE FROM connect_requests WHERE expires_at < ?", (now - CONNECT_GRACE,))
        self.db.execute("DELETE FROM github_cache WHERE used_at < ?", (now - GITHUB_UNUSED,))

    def account_hmac(self, digest):
        # 只存 HMAC：数据库泄露也不能拿常见邮箱去撞出是谁
        return hmac.new(self.secret, digest.encode("ascii"), hashlib.sha256).hexdigest()

    # —— 注册、connect、设备 ——

    def body_public_key(self, body):
        public_key = b64url_decode(body.get("publicKey"))
        if public_key is None or len(public_key) != 65 or public_key[0] != 4:
            raise ApiError(400, "invalid_public_key", "publicKey must be a 65-byte X9.63 P-256 point in base64url.")
        return public_key

    def device_fields(self, body):
        if body.get("platform") != "macos":
            raise ApiError(400, "invalid_platform", "platform must be \"macos\".")
        try:
            return clean_text(body.get("deviceName"), 60) or "Mac", clean_text(body.get("appVersion"), 40)
        except ValueError:
            raise ApiError(400, "invalid_device", "deviceName is at most 60 characters, appVersion at most 40.") from None

    def register(self, request):
        """用户名直接注册（只在 QUOTA_RUN_DEVICE_SIGNUP=1 时开放，给本机测试用）。"""
        body = parse_json_object(request.body)
        public_key = self.body_public_key(body)
        self.verify_signature(request, public_key, key_scope(public_key))
        self.take_token("register:" + request.ip, "register")
        device_name, app_version = self.device_fields(body)
        now = self.now()
        with self.transaction():
            if self.db.execute("SELECT 1 FROM devices WHERE public_key = ?", (public_key,)).fetchone():
                raise ApiError(409, "key_registered", "This public key is already registered.")
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
            device_id = self.insert_device(user_id, public_key, device_name, app_version, True, now)
            user = self.user_row(user_id)
        self._cache.clear()
        return Response(201, {"user": user_brief(user), "deviceId": device_id, "ranked": True})

    def insert_device(self, user_id, public_key, name, app_version, ranked, now):
        device_id = secrets.token_urlsafe(16)
        self.db.execute(
            "INSERT INTO devices(id, user_id, public_key, name, platform, app_version, ranked, created_at, last_seen_at)"
            " VALUES (?, ?, ?, ?, 'macos', ?, ?, ?, ?)",
            (device_id, user_id, public_key, name, app_version, int(ranked), now, now))
        return device_id

    def has_ranked_device(self, user_id):
        return self.db.execute("SELECT 1 FROM devices WHERE user_id = ? AND ranked = 1", (user_id,)).fetchone() is not None

    def connect_start(self, request):
        body = parse_json_object(request.body)
        public_key = self.body_public_key(body)
        self.verify_signature(request, public_key, key_scope(public_key))
        self.take_token("register:" + request.ip, "register")
        device_name, app_version = self.device_fields(body)
        now = self.now()
        with self.transaction():
            if self.db.execute("SELECT 1 FROM devices WHERE public_key = ?", (public_key,)).fetchone():
                raise ApiError(409, "key_registered", "This public key is already registered.")
            # 同一把钥匙重新开始时，之前没批的码作废
            self.db.execute("DELETE FROM connect_requests WHERE public_key = ? AND status = 'pending'", (public_key,))
            while True:
                code = "".join(secrets.choice(USER_CODE_ALPHABET) for _ in range(USER_CODE_LENGTH))
                code_hash = hashlib.sha256(code.encode()).hexdigest()
                if not self.db.execute("SELECT 1 FROM connect_requests WHERE code_hash = ?", (code_hash,)).fetchone():
                    break
            request_id = secrets.token_urlsafe(16)
            self.db.execute(
                "INSERT INTO connect_requests(id, code_hash, public_key, device_name, platform, app_version, status,"
                " created_at, expires_at) VALUES (?, ?, ?, ?, 'macos', ?, 'pending', ?, ?)",
                (request_id, code_hash, public_key, device_name, app_version, now, now + CONNECT_TTL))
        user_code = format_user_code(code)
        language = "/zh" if body.get("lang") == "zh" else ""
        return Response(201, {
            "requestId": request_id,
            "userCode": user_code,
            "verifyURL": f"{self.settings.origin}{language}/connect?code={user_code}",
            "expiresAt": now + CONNECT_TTL,
            "interval": CONNECT_INTERVAL,
        })

    def connect_poll(self, request):
        body = parse_json_object(request.body)
        public_key = self.body_public_key(body)
        self.verify_signature(request, public_key, key_scope(public_key))
        self.take_token("poll:" + request.ip, "poll")
        request_id = body.get("requestId")
        row = None
        if isinstance(request_id, str) and DEVICE_ID_RE.fullmatch(request_id):
            row = self.db.execute("SELECT * FROM connect_requests WHERE id = ?", (request_id,)).fetchone()
        # 请求号属于别的钥匙时和不存在一样回 404：请求号不能被拿去冒领别人批准的设备
        if row is None or not hmac.compare_digest(bytes(row["public_key"]), public_key):
            raise ApiError(404, "connect_request_invalid", "No such connect request for this key.")
        if row["status"] == "denied":
            return {"status": "denied"}
        if row["status"] == "approved":
            device = self.db.execute(
                "SELECT d.ranked, u.username, u.display_name, u.region FROM devices d JOIN users u ON u.id = d.user_id"
                " WHERE d.id = ? AND d.public_key = ?", (row["device_id"], public_key)).fetchone()
            if device is None:  # 批准后还没取到，设备就在网页上被删了
                return {"status": "expired"}
            return {"status": "approved", "user": user_brief(device), "deviceId": row["device_id"],
                    "ranked": bool(device["ranked"])}
        if row["expires_at"] <= self.now():
            return {"status": "expired"}
        return {"status": "pending"}

    def find_connect(self, raw_code):
        code = normalize_user_code(raw_code)
        if code is None:
            return None
        return self.db.execute("SELECT * FROM connect_requests WHERE code_hash = ?",
                               (hashlib.sha256(code.encode()).hexdigest(),)).fetchone()

    def connect_info(self, request, raw_code):
        self.require_session(request)
        self.take_token("lookup:" + request.ip, "lookup")
        row = self.find_connect(raw_code)
        if row is None:
            raise ApiError(404, "connect_code_invalid", "The code is wrong or has expired.")
        status = row["status"]
        if status == "pending" and row["expires_at"] <= self.now():
            status = "expired"
        code = normalize_user_code(raw_code)
        return {"userCode": format_user_code(code), "deviceName": row["device_name"], "platform": row["platform"],
                "appVersion": row["app_version"], "createdAt": row["created_at"], "expiresAt": row["expires_at"],
                "status": status}

    def pending_connect(self, request, raw_code):
        session = self.require_session(request)
        self.take_token(f"user:{session['user_id']}", "write")
        row = self.find_connect(raw_code)
        if row is None or (row["status"] == "pending" and row["expires_at"] <= self.now()):
            raise ApiError(404, "connect_code_invalid", "The code is wrong or has expired.")
        if row["status"] != "pending":
            raise ApiError(409, "connect_code_used", "This code was already used.")
        return session, row

    def connect_approve(self, request, raw_code):
        now = self.now()
        with self.transaction():
            session, row = self.pending_connect(request, raw_code)
            public_key = bytes(row["public_key"])
            if self.db.execute("SELECT 1 FROM devices WHERE public_key = ?", (public_key,)).fetchone():
                raise ApiError(409, "connect_code_used", "This Mac is already connected.")
            user_id = session["user_id"]
            # 账号当前没有计分设备时，新连上的 Mac 直接成为计分设备（不算一次更换）
            ranked = not self.has_ranked_device(user_id)
            device_id = self.insert_device(user_id, public_key, row["device_name"], row["app_version"], ranked, now)
            self.db.execute("UPDATE connect_requests SET status = 'approved', user_id = ?, device_id = ? WHERE id = ?",
                            (user_id, device_id, row["id"]))
        return {"deviceName": row["device_name"], "ranked": ranked}

    def connect_deny(self, request, raw_code):
        with self.transaction():
            session, row = self.pending_connect(request, raw_code)
            self.db.execute("UPDATE connect_requests SET status = 'denied', user_id = ? WHERE id = ?",
                            (session["user_id"], row["id"]))
        return {"status": "denied"}

    def set_ranked(self, request, actor):
        body = parse_json_object(request.body)
        target = body.get("deviceId")
        if not isinstance(target, str) or not DEVICE_ID_RE.fullmatch(target):
            raise ApiError(400, "invalid_device", "deviceId is required.")
        now = self.now()
        with self.transaction():
            row = self.db.execute("SELECT ranked FROM devices WHERE id = ? AND user_id = ?",
                                  (target, actor.user_id)).fetchone()
            if row is None:
                raise ApiError(404, "device_not_found", "No such device on this account.")
            if not row["ranked"]:
                # 冷却期只管「从一台换到另一台」；账号眼下没有计分设备时随时可以指定
                available = self.ranked_available_at(self.user_row(actor.user_id))
                if available is not None:
                    raise ApiError(409, "cooldown", "The ranked device can change once every 7 days.",
                                   availableAt=available)
                self.db.execute("UPDATE devices SET ranked = (id = ?) WHERE user_id = ?", (target, actor.user_id))
                self.db.execute("UPDATE users SET ranked_changed_at = ? WHERE id = ?", (now, actor.user_id))
        return {"devices": self.devices_payload(actor.user_id, actor.device_id),
                "rankedChangeAvailableAt": self.ranked_available_at(self.user_row(actor.user_id))}

    def forget_device(self, device_id):
        self.db.execute("DELETE FROM devices WHERE id = ?", (device_id,))
        self.db.execute("DELETE FROM nonces WHERE scope = ?", (device_id,))
        self._buckets.pop("device:" + device_id, None)

    def delete_device(self, device_id, actor):
        if not DEVICE_ID_RE.fullmatch(device_id):
            raise ApiError(404, "device_not_found", "No such device on this account.")
        signed = actor.device_id is not None
        if signed and device_id == actor.device_id:
            raise ApiError(409, "current_device", "Use DELETE /devices/current to disconnect this Mac.")
        with self.transaction():
            row = self.db.execute("SELECT ranked FROM devices WHERE id = ? AND user_id = ?",
                                  (device_id, actor.user_id)).fetchone()
            if row is None:
                raise ApiError(404, "device_not_found", "No such device on this account.")
            if row["ranked"] and signed:
                # 设备签名不能删计分设备（先换，受冷却期约束）；网页会话可以删任何一台
                raise ApiError(409, "ranked_device", "Make another Mac the ranked device before removing this one.")
            self.forget_device(device_id)
        return {"devices": self.devices_payload(actor.user_id, actor.device_id)}

    def delete_current_device(self, device):
        # 这台 Mac 离开账号；它若是计分设备，账号暂时没有计分设备。已上传的读数留在账号上
        with self.transaction():
            self.forget_device(device["id"])

    def delete_account(self, request, actor):
        user_id = actor.user_id
        with self.transaction():
            device_ids = [r[0] for r in self.db.execute("SELECT id FROM devices WHERE user_id = ?", (user_id,))]
            owned = [tuple(r) for r in self.db.execute(
                "SELECT account_hmac, provider FROM account_owners WHERE user_id = ?", (user_id,))]
            self.db.executemany("DELETE FROM nonces WHERE scope = ?", [(d,) for d in device_ids])
            # 主页上取过的 GitHub 贡献日历一并删掉；仓库数据不属于某个人，留给两周无人看后的清理
            self.db.execute(
                "DELETE FROM github_cache WHERE key IN (SELECT 'user:' || subject FROM identities"
                " WHERE user_id = ? AND provider = 'github')", (user_id,))
            # identities 删掉时 sessions 跟着级联删除；email_codes、oauth_states 里的 link_user_id 同样级联
            for table in ("snapshots", "activity", "runs", "projects", "account_owners", "account_bindings", "devices",
                          "connect_requests", "identities"):
                self.db.execute(f"DELETE FROM {table} WHERE user_id = ?", (user_id,))
            self.db.execute("DELETE FROM users WHERE id = ?", (user_id,))
            # 他拥有的服务商账号交给下一个上传过它的人，那个人的 run 要重算
            keys = set()
            now = self.now()
            for account, provider in owned:
                self.assign_next_owner(account, provider, now, keys)
            for key in keys:
                self.recompute_run(key, now)
        for device_id in device_ids:
            self._buckets.pop("device:" + device_id, None)
        if actor.session is not None:
            request.set_cookies.append(self.cookie(SESSION_COOKIE, "", "/", 0))
        self._cache.clear()

    # —— 登录：身份、会话、注册用户名 ——

    def providers(self):
        return {"google": self.settings.google, "github": self.settings.github, "email": self.mailer is not None}

    def identities_payload(self, user_id):
        rows = self.db.execute(
            "SELECT id, provider, email, name, login, linked_at FROM identities WHERE user_id = ? ORDER BY linked_at, rowid",
            (user_id,))
        return [{"id": row["id"], "provider": row["provider"], "email": row["email"], "name": row["name"],
                 "login": row["login"], "linkedAt": row["linked_at"]} for row in rows]

    def save_identity(self, provider, subject, email, verified, name, login, now):
        """按 (provider, subject) 新建或更新身份（邮箱、名字以登录时提供方给的为准），返回 dict。"""
        row = self.db.execute("SELECT id FROM identities WHERE provider = ? AND subject = ?",
                              (provider, subject)).fetchone()
        if row is None:
            identity_id = secrets.token_urlsafe(16)
            self.db.execute(
                "INSERT INTO identities(id, user_id, provider, subject, email, email_verified, name, login,"
                " linked_at, last_used_at) VALUES (?, NULL, ?, ?, ?, ?, ?, ?, ?, ?)",
                (identity_id, provider, subject, email, int(verified), name, login, now, now))
        else:
            identity_id = row["id"]
            self.db.execute(
                "UPDATE identities SET email = ?, email_verified = ?, name = ?, login = ?, last_used_at = ? WHERE id = ?",
                (email, int(verified), name, login, now, identity_id))
        return dict(self.db.execute("SELECT * FROM identities WHERE id = ?", (identity_id,)).fetchone())

    def verified_email_owner(self, email):
        """已验证邮箱正好属于一个账号时返回该账号；没有或有多个都不自动关联。"""
        rows = self.db.execute(
            "SELECT DISTINCT user_id FROM identities WHERE email = ? AND email_verified = 1 AND user_id IS NOT NULL",
            (email,)).fetchall()
        return rows[0][0] if len(rows) == 1 else None

    def sign_in_identity(self, request, provider, subject, email, verified, name, login, now):
        identity = self.save_identity(provider, subject, email, verified, name, login, now)
        if identity["user_id"] is None and verified and email:
            owner = self.verified_email_owner(email)
            if owner is not None:
                self.db.execute("UPDATE identities SET user_id = ?, linked_at = ? WHERE id = ?",
                                (owner, now, identity["id"]))
                identity["user_id"] = owner
        if identity["user_id"] is not None:
            # 登录时提供方可能刚把邮箱标成已验证，或者身份刚自动挂上账号：重新看邮箱认领
            self.recheck_claims(identity["user_id"], now)
        self.start_session(request, identity["id"], now)
        return identity

    def link_identity(self, user_id, provider, subject, email, verified, name, login, now):
        row = self.db.execute("SELECT id, user_id FROM identities WHERE provider = ? AND subject = ?",
                              (provider, subject)).fetchone()
        if row is not None and row["user_id"] not in (None, user_id):
            raise ApiError(409, "identity_in_use", "That sign-in already belongs to another account.")
        identity = self.save_identity(provider, subject, email, verified, name, login, now)
        if identity["user_id"] is None:
            self.db.execute("UPDATE identities SET user_id = ?, linked_at = ? WHERE id = ?",
                            (user_id, now, identity["id"]))
        self.recheck_claims(user_id, now)

    def suggest_username(self, *sources):
        base = next((b for b in map(username_base, sources) if b), "") or "runner"
        candidates = [base] + [base[:20 - len(str(n))].rstrip("_-") + str(n) for n in range(2, 100)]
        for name in candidates:
            if (USERNAME_RE.fullmatch(name) and name not in RESERVED_USERNAMES and not
                    self.db.execute("SELECT 1 FROM users WHERE username = ?", (name,)).fetchone()):
                return name
        return None

    def session_payload(self, request):
        session = self.current_session(request)
        if session is None:
            return {"signedIn": False, "needsSignup": False, "identity": None, "user": None,
                    "suggestedUsername": None, "suggestedDisplayName": None}
        user = self.user_row(session["user_id"]) if session["user_id"] is not None else None
        payload = {
            "signedIn": True,
            "needsSignup": user is None,
            "identity": {"provider": session["provider"], "email": session["email"], "name": session["name"]},
            "user": user_brief(user) if user else None,
            "suggestedUsername": None,
            "suggestedDisplayName": None,
        }
        if user is None:
            local = (session["email"] or "").partition("@")[0]
            payload["suggestedUsername"] = self.suggest_username(session["login"], local)
            payload["suggestedDisplayName"] = clip_text(session["name"] or session["login"] or local, 40)
        return payload

    def username_availability(self, request, raw):
        self.take_token("lookup:" + request.ip, "lookup")
        name = unquote(raw).strip().lstrip("@").casefold()
        reason = None
        if not USERNAME_RE.fullmatch(name):
            reason = "invalid"
        elif name in RESERVED_USERNAMES:
            reason = "reserved"
        elif self.db.execute("SELECT 1 FROM users WHERE username = ?", (name,)).fetchone():
            reason = "taken"
        return {"available": reason is None, "reason": reason}

    def signup(self, request):
        session = self.require_session(request, account=False)
        self.take_token("auth:" + request.ip, "auth")
        body = parse_json_object(request.body)
        if session["user_id"] is not None:
            raise ApiError(409, "already_signed_up", "This sign-in already has an account.")
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
        now = self.now()
        with self.transaction():
            if self.db.execute("SELECT 1 FROM users WHERE username = ?", (username,)).fetchone():
                raise ApiError(409, "username_taken", "That username is taken.")
            user_id = self.db.execute(
                "INSERT INTO users(username, display_name, region, joined_at) VALUES (?, ?, ?, ?)",
                (username, display_name, region, now)).lastrowid
            self.db.execute("UPDATE identities SET user_id = ?, linked_at = ? WHERE id = ?",
                            (user_id, now, session["id"]))
            self.recheck_claims(user_id, now)
        self._cache.clear()
        return Response(201, {"user": private_user(self.user_row(user_id))})

    def delete_identity(self, request, identity_id):
        session = self.require_session(request)
        user_id = session["user_id"]
        self.take_token(f"user:{user_id}", "write")
        with self.transaction():
            ids = [r[0] for r in self.db.execute(
                "SELECT id FROM identities WHERE user_id = ? ORDER BY linked_at, rowid", (user_id,))]
            if identity_id not in ids:
                raise ApiError(404, "identity_not_found", "No such sign-in method on this account.")
            if len(ids) == 1:
                raise ApiError(409, "last_identity", "An account needs at least one way to sign in.")
            if identity_id == session["id"]:
                # 删的正是这次登录用的方式：当前会话改挂到剩下的身份上，不把人踢出去；
                # 用它登录的其他会话随身份一起删掉
                keep = next(i for i in ids if i != identity_id)
                self.db.execute("UPDATE sessions SET identity_id = ? WHERE token_hash = ?",
                                (keep, session["token_hash"]))
            self.db.execute("DELETE FROM identities WHERE id = ?", (identity_id,))
        return {"identities": self.identities_payload(user_id)}

    def logout(self, request):
        self.check_origin(request)
        token = request.cookies.get(SESSION_COOKIE)
        if token:
            self.db.execute("DELETE FROM sessions WHERE token_hash = ?", (token_hash(token),))
        request.set_cookies.append(self.cookie(SESSION_COOKIE, "", "/", 0))
        return Response(204)

    def dev_sign_in(self, request):
        self.check_origin(request)
        body = parse_json_object(request.body)
        email = normalize_email(body.get("email"))
        if email is None:
            raise ApiError(400, "invalid_email", "That email address does not look right.")
        with self.transaction():
            identity = self.sign_in_identity(request, "email", email, email, True, None, None, self.now())
        return {"signedIn": True, "needsSignup": identity["user_id"] is None}

    # —— 邮箱验证码 ——

    def email_code_hmac(self, email, code):
        return hmac.new(self.secret, (email + code).encode("utf-8"), hashlib.sha256).hexdigest()

    def email_start(self, request):
        self.check_origin(request)
        if self.mailer is None:
            raise ApiError(503, "email_unavailable", "Email sign-in is not available right now.")
        body = parse_json_object(request.body)
        email = normalize_email(body.get("email"))
        if email is None:
            raise ApiError(400, "invalid_email", "That email address does not look right.")
        lang = "zh" if body.get("lang") == "zh" else "en"
        link_user_id = None
        if body.get("link") is True:
            link_user_id = self.require_session(request)["user_id"]
        windows = self.email_windows
        self.take_windows([
            ("email-minute:" + email, *windows["address_minute"]),
            ("email-hour:" + email, *windows["address_hour"]),
            ("email-ip:" + request.ip, *windows["ip_hour"]),
        ], "Too many codes requested; try again later.")
        now = self.now()
        code = f"{secrets.randbelow(1_000_000):06d}"
        # 新码替换旧码（连同错误次数和关联模式）
        self.db.execute(
            "INSERT OR REPLACE INTO email_codes(email, code_hmac, expires_at, attempts, created_at, link_user_id)"
            " VALUES (?, ?, ?, 0, ?, ?)",
            (email, self.email_code_hmac(email, code), now + EMAIL_CODE_TTL, now, link_user_id))
        subject, text = email_code_message(code, lang)
        self.mailer(email, subject, text)
        return Response(202, {"sent": True, "expiresAt": now + EMAIL_CODE_TTL})

    def email_verify(self, request):
        self.check_origin(request)
        self.take_token("auth:" + request.ip, "auth")
        body = parse_json_object(request.body)
        email = normalize_email(body.get("email"))
        code = re.sub(r"[\s-]", "", body.get("code")) if isinstance(body.get("code"), str) else ""
        row = None
        if email is not None:
            row = self.db.execute("SELECT * FROM email_codes WHERE email = ?", (email,)).fetchone()
        if row is None:
            raise ApiError(400, "code_invalid", "That code is not right.")
        if row["attempts"] >= EMAIL_MAX_ATTEMPTS:
            raise ApiError(429, "too_many_attempts", "Too many wrong codes; ask for a new one.")
        now = self.now()
        if row["expires_at"] <= now:
            raise ApiError(400, "code_expired", "That code has expired; ask for a new one.")
        expected = self.email_code_hmac(email, code if re.fullmatch(r"[0-9]{6}", code) else "")
        if not hmac.compare_digest(expected, row["code_hmac"]):
            # 自动提交模式下这条 UPDATE 立即生效，随后抛出的错误不会把它回滚
            self.db.execute("UPDATE email_codes SET attempts = attempts + 1 WHERE email = ?", (email,))
            raise ApiError(400, "code_invalid", "That code is not right.")
        self.db.execute("DELETE FROM email_codes WHERE email = ?", (email,))
        with self.transaction():
            link_user = row["link_user_id"]
            session = self.current_session(request) if link_user is not None else None
            # 关联模式只对发起关联的那个账号的会话生效；换了浏览器验证就按普通登录处理
            if session is not None and session["user_id"] == link_user:
                self.link_identity(link_user, "email", email, email, True, None, None, now)
                return Response(200, {"linked": True})
            identity = self.sign_in_identity(request, "email", email, email, True, None, None, now)
        return Response(200, {"signedIn": True, "needsSignup": identity["user_id"] is None})

    # —— GitHub / Google OAuth ——

    def redirect_uri(self, provider):
        return f"{self.settings.origin}{API_PREFIX}/auth/{provider}/callback"

    def redirect(self, path):
        return Response(302, headers={"Location": self.settings.origin + path})

    def login_redirect(self, error, next_path):
        login = "/zh/login" if next_path.startswith("/zh/") else "/login"
        params = ({"error": error} if error else {}) | {"next": next_path}
        return self.redirect(login + "?" + urlencode(params))

    def oauth_start(self, request, provider):
        self.take_token("auth:" + request.ip, "auth")
        next_path = safe_next(request.query.get("next"))
        if not getattr(self.settings, provider):
            return self.login_redirect("provider_unavailable", next_path)
        link_user_id = None
        if request.query.get("link") in ("1", "true"):
            session = self.current_session(request)
            if session is not None and session["user_id"] is not None:
                link_user_id = session["user_id"]
        state = secrets.token_urlsafe(32)
        verifier = secrets.token_urlsafe(48)
        challenge = b64url_encode(hashlib.sha256(verifier.encode("ascii")).digest())
        self.db.execute(
            "INSERT INTO oauth_states(state_hash, provider, verifier, next, link_user_id, created_at)"
            " VALUES (?, ?, ?, ?, ?, ?)", (token_hash(state), provider, verifier, next_path, link_user_id, self.now()))
        if provider == "github":
            url = GITHUB_AUTHORIZE_URL + "?" + urlencode({
                "client_id": self.settings.github_client_id, "redirect_uri": self.redirect_uri(provider),
                "scope": "read:user user:email", "state": state,
                "code_challenge": challenge, "code_challenge_method": "S256"})
        else:
            url = GOOGLE_AUTHORIZE_URL + "?" + urlencode({
                "client_id": self.settings.google_client_id, "redirect_uri": self.redirect_uri(provider),
                "response_type": "code", "scope": "openid email profile", "state": state,
                "code_challenge": challenge, "code_challenge_method": "S256", "prompt": "select_account"})
        request.set_cookies.append(self.cookie(OAUTH_COOKIE, state, OAUTH_COOKIE_PATH, OAUTH_TTL))
        return Response(302, headers={"Location": url})

    def oauth_callback(self, request, provider):
        request.set_cookies.append(self.cookie(OAUTH_COOKIE, "", OAUTH_COOKIE_PATH, 0))
        with self.lock:
            now = self.now()
            self._purge(now)
            state = request.query.get("state") or ""
            cookie_state = request.cookies.get(OAUTH_COOKIE) or ""
            row = None
            if state:
                row = self.db.execute("SELECT * FROM oauth_states WHERE state_hash = ?", (token_hash(state),)).fetchone()
                if row is not None:
                    self.db.execute("DELETE FROM oauth_states WHERE state_hash = ?", (row["state_hash"],))
            valid = (row is not None and row["provider"] == provider and row["created_at"] > now - OAUTH_TTL
                     and cookie_state and hmac.compare_digest(cookie_state.encode(), state.encode()))
            next_path = row["next"] if valid else "/account"
            if request.query.get("error"):
                return self.login_redirect("oauth_denied", next_path)
            if not valid:
                return self.login_redirect("oauth_state", next_path)
            link_user_id = row["link_user_id"]
            if link_user_id is not None:
                session = self.current_session(request)
                if session is None or session["user_id"] != link_user_id:
                    return self.login_redirect("oauth_state", next_path)
            if not getattr(self.settings, provider):
                return self.login_redirect("provider_unavailable", next_path)
            code = request.query.get("code") or ""
            verifier = row["verifier"]
        if not code:
            return self.login_redirect("oauth_failed", next_path)
        try:
            fetch = self.fetch_github if provider == "github" else self.fetch_google
            profile = fetch(code, verifier)
        except Exception as error:  # noqa: BLE001 — 网络、JSON、字段缺失都算 oauth_failed
            # 只记提供方和错误类型：code、令牌和响应内容都不进日志
            print(f"oauth {provider}: sign-in failed: {type(error).__name__}", file=sys.stderr)
            return self.login_redirect("oauth_failed", next_path)
        with self.lock:
            now = self.now()
            with self.transaction():
                if link_user_id is not None:
                    if self.user_row(link_user_id) is None:
                        return self.login_redirect("oauth_state", next_path)
                    try:
                        self.link_identity(link_user_id, provider, *profile, now)
                    except ApiError:
                        return self.redirect(with_query(next_path, "error=identity_in_use"))
                    return self.redirect(next_path)
                identity = self.sign_in_identity(request, provider, *profile, now)
        if identity["user_id"] is None:
            return self.login_redirect(None, next_path)
        return self.redirect(next_path)

    def provider_json(self, method, url, headers, body=None):
        status, raw = self.http(method, url, dict(headers, **{"Accept": "application/json", "User-Agent": USER_AGENT}), body)
        if status != 200:
            raise OAuthFailure(f"HTTP {status}")
        return json.loads(raw.decode("utf-8"))

    def fetch_github(self, code, verifier):
        """返回 (subject, email, verified, name, login)。访问令牌只在这个函数里用一次。"""
        form = urlencode({"client_id": self.settings.github_client_id,
                          "client_secret": self.settings.github_client_secret,
                          "code": code, "redirect_uri": self.redirect_uri("github"),
                          "code_verifier": verifier}).encode("ascii")
        grant = self.provider_json("POST", GITHUB_TOKEN_URL,
                                   {"Content-Type": "application/x-www-form-urlencoded"}, form)
        token = grant.get("access_token") if isinstance(grant, dict) else None
        if not isinstance(token, str) or not token:
            raise OAuthFailure("no access token")
        auth = {"Authorization": f"Bearer {token}", "X-GitHub-Api-Version": "2022-11-28"}
        user = self.provider_json("GET", GITHUB_USER_URL, auth)
        subject = user.get("id") if isinstance(user, dict) else None
        if isinstance(subject, bool) or not isinstance(subject, int):
            raise OAuthFailure("no user id")
        login = clip_text(user.get("login"), 39)
        email = None
        try:
            emails = self.provider_json("GET", GITHUB_EMAILS_URL, auth)
        except (OAuthFailure, ValueError):
            emails = []
        for item in emails if isinstance(emails, list) else []:
            if isinstance(item, dict) and item.get("primary") is True and item.get("verified") is True:
                email = normalize_email(item.get("email"))
                break
        name = clip_text(user.get("name"), 80) or login
        return str(subject), email, email is not None, name, login

    def fetch_google(self, code, verifier):
        form = urlencode({"client_id": self.settings.google_client_id,
                          "client_secret": self.settings.google_client_secret,
                          "code": code, "redirect_uri": self.redirect_uri("google"),
                          "grant_type": "authorization_code", "code_verifier": verifier}).encode("ascii")
        grant = self.provider_json("POST", GOOGLE_TOKEN_URL,
                                   {"Content-Type": "application/x-www-form-urlencoded"}, form)
        token = grant.get("access_token") if isinstance(grant, dict) else None
        if not isinstance(token, str) or not token:
            raise OAuthFailure("no access token")
        info = self.provider_json("GET", GOOGLE_USERINFO_URL, {"Authorization": f"Bearer {token}"})
        subject = info.get("sub") if isinstance(info, dict) else None
        if not isinstance(subject, str) or not subject or len(subject) > 255:
            raise OAuthFailure("no subject")
        email = normalize_email(info.get("email"))
        verified = email is not None and info.get("email_verified") in (True, "true")
        return subject, email, verified, clip_text(info.get("name"), 80), None

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
        seen_accounts = {}
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
                    if counted and account not in seen_accounts:
                        self.bind_account(account, snap["provider"], user_id, now)
                    seen_accounts.setdefault(account, snap["provider"])
                if counted and snap["rankable"]:
                    run_keys.add((user_id, snap["provider"], snap["plan_norm"], snap["window_key"], snap["resets_bucket"]))
            if seen_accounts:
                self.db.executemany(
                    "UPDATE account_bindings SET last_seen_at = MAX(last_seen_at, ?) WHERE account_hmac = ? AND user_id = ?",
                    [(now, account, user_id) for account in seen_accounts])
                self.check_claims(user_id, now, run_keys, accounts=set(seen_accounts))
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

    # —— 服务商账号：绑定与归属 ——

    def bind_account(self, account, provider, user_id, now):
        """计分读数第一次带上这个账号时建绑定；账号还没有主人就归这个人（邮箱对得上记 email，否则 first）。

        已经有主人时什么都不改：这个人的 run 重算时自然是 account_elsewhere，主人的 run 不受影响。
        """
        cursor = self.db.execute(
            "INSERT OR IGNORE INTO account_bindings(account_hmac, user_id, first_seen_at, provider, last_seen_at)"
            " VALUES (?, ?, ?, ?, ?)", (account, user_id, now, provider, now))
        if cursor.rowcount != 1:
            return
        via = "email" if self.email_matches(user_id, account, provider) else "first"
        self.db.execute(
            "INSERT OR IGNORE INTO account_owners(account_hmac, provider, user_id, via, claimed_at) VALUES (?, ?, ?, ?, ?)",
            (account, provider, user_id, via, now))

    def verified_emails(self, user_id):
        # 只有已验证的登录邮箱算数（邮箱验证码身份天然已验证，Google 看 email_verified，GitHub 只取已验证的主邮箱）
        rows = self.db.execute(
            "SELECT DISTINCT email FROM identities WHERE user_id = ? AND email_verified = 1 AND email IS NOT NULL",
            (user_id,))
        return {row[0].strip().lower() for row in rows if row[0] and row[0].strip()}

    def email_hmacs(self, emails, provider):
        return {self.account_hmac(account_digest(provider, email)) for email in emails}

    def email_matches(self, user_id, account, provider):
        return account in self.email_hmacs(self.verified_emails(user_id), provider)

    def check_claims(self, user_id, now, run_keys, accounts=None):
        """用这个人已验证的登录邮箱比对他绑定的账号，对得上就按 email 认领。

        email 胜过 first：账号从别人那里转过来，双方这个账号的 run 都进 run_keys 等着重算；
        已经是 email 认领的账号不会被抢走。accounts 给了就只看这几个。返回有没有改动。
        """
        emails = self.verified_emails(user_id)
        if not emails:
            return False
        expected = {}
        changed = False
        rows = self.db.execute(
            "SELECT b.account_hmac, b.provider, o.user_id AS owner, o.via FROM account_bindings b"
            " LEFT JOIN account_owners o ON o.account_hmac = b.account_hmac WHERE b.user_id = ?"
            " ORDER BY b.first_seen_at, b.account_hmac", (user_id,)).fetchall()
        for row in rows:
            account, provider = row["account_hmac"], row["provider"]
            if accounts is not None and account not in accounts:
                continue
            if provider not in expected:
                expected[provider] = self.email_hmacs(emails, provider)
            if account not in expected[provider] or row["via"] == "email":
                continue
            if row["owner"] is None:
                self.db.execute(
                    "INSERT INTO account_owners(account_hmac, provider, user_id, via, claimed_at)"
                    " VALUES (?, ?, ?, 'email', ?)", (account, provider, user_id, now))
            else:
                self.db.execute("UPDATE account_owners SET user_id = ?, via = 'email', claimed_at = ? WHERE account_hmac = ?",
                                (user_id, now, account))
                if row["owner"] != user_id:
                    run_keys.update(self.run_keys_for_account(account, row["owner"]))
            run_keys.update(self.run_keys_for_account(account, user_id))
            changed = True
        if changed:
            self._cache.clear()
        return changed

    def recheck_claims(self, user_id, now):
        """登录身份新增、关联、验证或注册完成时调用：认领后立即重算受影响的 run。"""
        run_keys = set()
        if self.check_claims(user_id, now, run_keys):
            for key in run_keys:
                self.recompute_run(key, now)

    def assign_next_owner(self, account, provider, now, run_keys):
        """主人解绑或删号后，账号交给剩下绑定过它的人：邮箱对得上的优先（按 email），
        否则按最早上传的（first）。没人绑定就不再有主人。"""
        binders = [row[0] for row in self.db.execute(
            "SELECT user_id FROM account_bindings WHERE account_hmac = ? ORDER BY first_seen_at, user_id", (account,))]
        if not binders:
            return
        claimant = next((user for user in binders if self.email_matches(user, account, provider)), None)
        owner = claimant if claimant is not None else binders[0]
        self.db.execute(
            "INSERT OR REPLACE INTO account_owners(account_hmac, provider, user_id, via, claimed_at) VALUES (?, ?, ?, ?, ?)",
            (account, provider, owner, "email" if claimant is not None else "first", now))
        run_keys.update(self.run_keys_for_account(account, owner))
        self._cache.clear()

    def run_keys_for_account(self, account, user_id=None):
        sql = f"SELECT DISTINCT {RUN_KEY_COLUMNS} FROM snapshots WHERE account_hmac = ? AND counted = 1 AND rankable = 1"
        params = (account,)
        if user_id is not None:
            sql += " AND user_id = ?"
            params = (account, user_id)
        return {tuple(row) for row in self.db.execute(sql, params)}

    def provider_accounts_payload(self, user_id, accounts=None):
        """这个人绑定的服务商账号，{account_hmac: providerAccount}，按最早上传排序。"""
        runs = dict(self.db.execute(
            "SELECT s.account_hmac, COUNT(DISTINCT r.id) FROM runs r JOIN snapshots s"
            " ON s.user_id = r.user_id AND s.provider = r.provider AND s.plan_norm = r.plan_norm"
            " AND s.window_key = r.window_key AND s.resets_bucket = r.resets_bucket"
            f" WHERE r.user_id = ? AND r.tier IN {PUBLIC_TIERS} AND s.counted = 1 AND s.rankable = 1"
            " AND s.account_hmac IS NOT NULL GROUP BY s.account_hmac", (user_id,)).fetchall())
        rows = self.db.execute(
            "SELECT b.account_hmac, b.provider, b.first_seen_at, b.last_seen_at, o.user_id AS owner, o.via"
            " FROM account_bindings b LEFT JOIN account_owners o ON o.account_hmac = b.account_hmac"
            " WHERE b.user_id = ? ORDER BY b.first_seen_at, b.account_hmac", (user_id,))
        result = {}
        for row in rows:
            if accounts is not None and row["account_hmac"] not in accounts:
                continue
            owned = row["owner"] == user_id
            result[row["account_hmac"]] = {
                "id": row["account_hmac"][:16], "provider": row["provider"],
                "firstSeenAt": row["first_seen_at"], "lastSeenAt": row["last_seen_at"],
                "status": "owned" if owned else "elsewhere",
                "verifiedByEmail": owned and row["via"] == "email",
                "runs": runs.get(row["account_hmac"], 0),
            }
        return result

    def lookup_accounts(self, request):
        # 只收设备签名：摘要只有应用算得出来，网页没有
        device = self.authenticate(request)
        self.take_token("lookup:device:" + device["id"], "lookup")
        body = parse_json_object(request.body)
        digests = body.get("digests")
        if (not isinstance(digests, list) or len(digests) > MAX_LOOKUP_DIGESTS
                or not all(isinstance(d, str) and DIGEST_RE.fullmatch(d) for d in digests)):
            raise ApiError(400, "invalid_digests",
                           f"digests is a list of at most {MAX_LOOKUP_DIGESTS} lower-case hex SHA-256 digests.")
        hmacs = [self.account_hmac(digest) for digest in digests]
        accounts = self.provider_accounts_payload(device["user_id"], set(hmacs))
        return {"accounts": [{"digest": digest, "account": accounts.get(account)}
                             for digest, account in zip(digests, hmacs)]}

    def delete_provider_account(self, account_id, actor):
        """解绑：删掉这个人这个账号的读数和 run 以及绑定；他是主人的话，账号交给下一个上传过它的人。"""
        if not PROVIDER_ACCOUNT_ID_RE.fullmatch(account_id):
            raise ApiError(404, "account_not_found", "No such provider account on this account.")
        user_id = actor.user_id
        now = self.now()
        with self.transaction():
            rows = self.db.execute(
                "SELECT b.account_hmac, b.provider, o.user_id AS owner FROM account_bindings b"
                " LEFT JOIN account_owners o ON o.account_hmac = b.account_hmac"
                " WHERE b.user_id = ? AND substr(b.account_hmac, 1, 16) = ?", (user_id, account_id)).fetchall()
            if not rows:
                raise ApiError(404, "account_not_found", "No such provider account on this account.")
            run_keys = set()
            for row in rows:
                account = row["account_hmac"]
                # 一条 run 里混着别的账号的读数时，只删这个账号的读数，run 按剩下的重算
                run_keys.update(tuple(r) for r in self.db.execute(
                    f"SELECT DISTINCT {RUN_KEY_COLUMNS} FROM snapshots WHERE user_id = ? AND account_hmac = ?"
                    " AND resets_bucket IS NOT NULL", (user_id, account)))
                self.db.execute("DELETE FROM snapshots WHERE user_id = ? AND account_hmac = ?", (user_id, account))
                self.db.execute("DELETE FROM account_bindings WHERE user_id = ? AND account_hmac = ?", (user_id, account))
                if row["owner"] == user_id:
                    self.db.execute("DELETE FROM account_owners WHERE account_hmac = ?", (account,))
                    self.assign_next_owner(account, row["provider"], now, run_keys)
            for key in run_keys:
                self.recompute_run(key, now)
        self._cache.clear()
        return {"providerAccounts": list(self.provider_accounts_payload(user_id).values())}

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
        no_account = None in accounts
        known = [account for account in accounts if account]
        owners = {}
        if known:
            marks = ",".join("?" * len(known))
            owners = {row[0]: (row[1], row[2]) for row in self.db.execute(
                f"SELECT account_hmac, user_id, via FROM account_owners WHERE account_hmac IN ({marks})", known)}
        # 规则 1：每条读数的账号都归这个人；有一个归了别人就是 account_elsewhere
        elsewhere = any(account in owners and owners[account][0] != user_id for account in known)
        owned = not no_account and all(owners.get(account, (None,))[0] == user_id for account in known)
        account_verified = owned and all(owners[account][1] == "email" for account in known)
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
        if elsewhere:
            reasons.append("account_elsewhere")
        if reasons:
            tier = "flagged"
        elif no_account:
            tier = "unranked"
        elif owned and summary["covered"] and active:
            tier = "verified"
        else:
            tier = "standard"
        if no_account:
            reasons.append("no_account")
        plan_label = next((row["plan"] for row in reversed(rows) if row["plan"]), None)
        window_title = next((row["window_title"] for row in reversed(rows) if row["window_title"]), None)
        self.db.execute(
            "INSERT INTO runs(user_id, provider, plan_norm, plan_label, window_key, window_seconds, window_title,"
            " resets_bucket, resets_at, window_start, season, peak_percent, peak_at, seconds_to_50, seconds_to_90,"
            " seconds_to_100, completed_at, first_observed_at, last_observed_at, readings, tier, flag_reason,"
            " account_verified, updated_at, public_id)"
            " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
            # public_id 只在新建时给：重算不换 runId，网页上的链接和对比一直有效
            " ON CONFLICT(user_id, provider, plan_norm, window_key, resets_bucket) DO UPDATE SET"
            " public_id = COALESCE(runs.public_id, excluded.public_id),"
            " plan_label = excluded.plan_label, window_seconds = excluded.window_seconds,"
            " window_title = excluded.window_title, resets_at = excluded.resets_at,"
            " window_start = excluded.window_start, season = excluded.season,"
            " peak_percent = excluded.peak_percent, peak_at = excluded.peak_at,"
            " seconds_to_50 = excluded.seconds_to_50, seconds_to_90 = excluded.seconds_to_90,"
            " seconds_to_100 = excluded.seconds_to_100, completed_at = excluded.completed_at,"
            " first_observed_at = excluded.first_observed_at, last_observed_at = excluded.last_observed_at,"
            " readings = excluded.readings, tier = excluded.tier, flag_reason = excluded.flag_reason,"
            " account_verified = excluded.account_verified, updated_at = excluded.updated_at",
            (user_id, provider, plan_norm, plan_label, window_key, window_seconds, window_title, key[4], resets_at,
             window_start, season_of(window_start), summary["peak_percent"], summary["peak_at"],
             summary["seconds_to_50"], summary["seconds_to_90"], summary["seconds_to_100"], summary["completed_at"],
             summary["first_observed_at"], summary["last_observed_at"], len(rows), tier,
             ",".join(reasons) or None, int(account_verified), now, new_run_id()))

    # —— 个人资料与项目 ——

    def put_profile(self, request, actor):
        body = parse_json_object(request.body)
        user = self.user_row(actor.user_id)
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
            # 没传的链接保持原值；认不出的键忽略（应用只认 website、github、x，只会传这三个）
            extra = json.loads(user["links_json"] or "{}")
            for field in LINK_KINDS:
                if field not in links:
                    continue
                url = profile_link(field, links[field])
                if field in LINK_COLUMNS:
                    updates[field] = url
                elif url is None:
                    extra.pop(field, None)
                else:
                    extra[field] = url
            updates["links_json"] = json.dumps({k: extra[k] for k in LINK_KINDS if extra.get(k)}, separators=(",", ":"))
        if "timezone" in body:
            updates["timezone"] = profile_timezone(body["timezone"])
        for field, column in (("showActivity", "show_activity"), ("showGithub", "show_github")):
            if field in body:
                if not isinstance(body[field], bool):
                    raise ApiError(400, "invalid_profile", f"{field} must be true or false.")
                updates[column] = int(body[field])
        if updates:
            assignments = ", ".join(f"{column} = ?" for column in updates)
            self.db.execute(f"UPDATE users SET {assignments} WHERE id = ?", (*updates.values(), user["id"]))
            self._cache.clear()
        return {"user": private_user(self.user_row(user["id"]))}

    def put_projects(self, request, actor):
        body = parse_json_object(request.body)
        projects = body.get("projects")
        if not isinstance(projects, list):
            raise ApiError(400, "invalid_projects", "projects must be an array.")
        if len(projects) > 12:
            raise ApiError(400, "too_many_projects", "At most 12 projects.")
        rows = [validate_project(index, item) for index, item in enumerate(projects)]
        with self.transaction():
            self.db.execute("DELETE FROM projects WHERE user_id = ?", (actor.user_id,))
            self.db.executemany(
                "INSERT INTO projects(user_id, position, name, url, description, github, built_with)"
                " VALUES (?, ?, ?, ?, ?, ?, ?)",
                [(actor.user_id, index, *row) for index, row in enumerate(rows)])
        self._cache.clear()
        return {"projects": self.projects_payload(actor.user_id)}

    # —— 查询 ——

    def user_row(self, user_id):
        return self.db.execute("SELECT * FROM users WHERE id = ?", (user_id,)).fetchone()

    def ranked_available_at(self, user):
        """冷却中返回可以再换的时间；现在就能换则为 null。首台设备自动成为计分设备，不算一次更换；
        账号眼下没有计分设备时（计分设备被删或断开了）随时可以指定，也返回 null。"""
        changed = user["ranked_changed_at"]
        if changed is None or self.now() >= changed + RANKED_COOLDOWN or not self.has_ranked_device(user["id"]):
            return None
        return changed + RANKED_COOLDOWN

    def devices_payload(self, user_id, current_id):
        rows = self.db.execute(
            "SELECT id, name, ranked, last_seen_at, app_version FROM devices WHERE user_id = ? ORDER BY created_at, rowid",
            (user_id,))
        # 网页会话没有「当前设备」，current_id 为 None，全部是 false
        return [{"deviceId": row["id"], "name": row["name"], "ranked": bool(row["ranked"]),
                 "lastSeenAt": row["last_seen_at"], "current": current_id is not None and row["id"] == current_id,
                 "appVersion": row["app_version"]} for row in rows]

    def projects_payload(self, user_id):
        rows = self.db.execute(
            "SELECT name, url, description, github, built_with FROM projects WHERE user_id = ? ORDER BY position",
            (user_id,))
        return [{"name": row["name"], "url": row["url"], "description": row["description"],
                 "github": row["github"], "builtWith": json.loads(row["built_with"])} for row in rows]

    def me(self, actor):
        user = self.user_row(actor.user_id)
        return {
            "user": private_user(user),
            "devices": self.devices_payload(user["id"], actor.device_id),
            "rankedChangeAvailableAt": self.ranked_available_at(user),
            "lastUploadAt": user["last_upload_at"],
            "projects": self.projects_payload(user["id"]),
            "identities": self.identities_payload(user["id"]),
            "providerAccounts": list(self.provider_accounts_payload(user["id"]).values()),
        }

    def stats(self):
        users = self.db.execute("SELECT COUNT(*) FROM users").fetchone()[0]
        row = self.db.execute(
            "SELECT COUNT(*), COALESCE(SUM(tier = 'verified'), 0), COUNT(DISTINCT provider)"
            f" FROM runs WHERE tier IN {PUBLIC_TIERS}").fetchone()
        return {"users": users, "runs": row[0], "verifiedRuns": row[1], "providers": row[2], "updatedAt": self.now()}

    def parse_season(self, value):
        if value in (None, "", "current"):
            return season_of(self.now())
        if value == "last":
            # 七天前所在的 ISO 周一定是上一周
            return season_of(self.now() - 7 * 86400)
        if value == "all":
            return "all"
        match = SEASON_RE.fullmatch(value)
        if match:
            try:
                datetime.fromisocalendar(int(match.group(1)), int(match.group(2)), 1)
                return value
            except ValueError:
                pass
        raise ApiError(400, "invalid_season", "season is \"current\", \"last\", \"all\" or an ISO week like 2026-W37.")

    def boards(self, query):
        season = self.parse_season(query.get("season"))
        region = parse_region(query.get("region"))
        where, params = [f"r.tier IN {PUBLIC_TIERS}"], []
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
        where = ["r.provider = ?", "r.plan_norm = ?", "r.window_key = ?", f"r.tier IN {PUBLIC_TIERS}"]
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
            f" AND window_key = ? AND tier IN {PUBLIC_TIERS} ORDER BY last_observed_at DESC LIMIT 1",
            (provider, plan_norm, window_key)).fetchone()
        return {
            "provider": provider, "plan": plan_norm,
            "planLabel": label["plan_label"] if label else None,
            "windowKey": window_key,
            "windowSeconds": label["window_seconds"] if label else int(window_key.split(":", 1)[0]),
            "windowTitle": label["window_title"] if label else None,
            "runners": runners, "season": season,
        }

    def run_filters(self, season, region=None, tier=None, board=None):
        """公开查询的公共条件：只有 verified/standard；board 是 (provider, plan_norm, window_key)。
        region 条件用到 users 表，调用方要 JOIN users u。"""
        where, params = [f"r.tier IN {PUBLIC_TIERS}"], []
        if board is not None:
            where += ["r.provider = ?", "r.plan_norm = ?", "r.window_key = ?"]
            params += list(board)
        if season != "all":
            where.append("r.season = ?")
            params.append(season)
        if region:
            where.append("u.region = ?")
            params.append(region)
        if tier == "verified":
            where.append("r.tier = 'verified'")
        return where, params

    def best_runs(self, provider, plan_norm, window_key, metric, season, region, tier):
        """每人一条最好成绩，按榜单顺序排好（metric 见 BEST_ORDERS）。"""
        where, params = self.run_filters(season, region, tier, (provider, plan_norm, window_key))
        if metric in METRIC_COLUMNS:
            where.append(f"r.{METRIC_COLUMNS[metric]} IS NOT NULL")
        order = BEST_ORDERS[metric]
        return self.db.execute(
            "SELECT * FROM (SELECT r.*, u.username, u.display_name, u.region,"
            f" ROW_NUMBER() OVER (PARTITION BY r.user_id ORDER BY {order.format(p='r.')}) AS best"
            f" FROM runs r JOIN users u ON u.id = r.user_id WHERE {' AND '.join(where)})"
            f" WHERE best = 1 ORDER BY {order.format(p='')}", params).fetchall()

    def season_runs(self, board, season):
        """seasonRuns：每人在这个榜、这个赛季（all 为全部赛季）可见的 run 数，一次 GROUP BY 查完。"""
        where, params = self.run_filters(season, board=board)
        return dict(self.db.execute(
            f"SELECT r.user_id, COUNT(*) FROM runs r WHERE {' AND '.join(where)} GROUP BY r.user_id", params).fetchall())

    def board_summary(self, board, season, region, tier):
        """榜单上方的摘要：每人速度最好的一条（没跑完的也算人数），上一周同样算一遍做对比。"""
        rows = self.best_runs(*board, "overall", season, region, tier)
        completed = [row for row in rows if row["seconds_to_100"] is not None]
        median = lower_median(completed)
        previous = previous_season(season)
        runners_prev = median_prev = None
        if previous is not None:
            prev_rows = self.best_runs(*board, "overall", previous, region, tier)
            runners_prev = len(prev_rows)
            prev_median = lower_median([row for row in prev_rows if row["seconds_to_100"] is not None])
            median_prev = prev_median["seconds_to_100"] if prev_median else None
        fastest = completed[0] if completed else None
        runners = len(rows)
        return {
            "runners": runners,
            "runnersPrev": runners_prev,
            "fastest": None if fastest is None else {
                "username": fastest["username"], "displayName": fastest["display_name"],
                "seconds": fastest["seconds_to_100"], "runId": fastest["public_id"]},
            "medianSecondsTo100": median["seconds_to_100"] if median else None,
            "medianSecondsTo100Prev": median_prev,
            "medianRunId": median["public_id"] if median else None,
            "completed": len(completed),
            "completedShare": share(len(completed), runners),
            "verifiedShare": share(sum(row["tier"] == "verified" for row in rows), runners),
            "accountVerifiedShare": share(sum(bool(row["account_verified"]) for row in rows), runners),
        }

    def leaderboard(self, query):
        provider = query.get("provider", "")
        if not PROVIDER_RE.fullmatch(provider):
            raise ApiError(400, "invalid_provider", "provider is required.")
        plan_norm = normalize_plan(query.get("plan", ""))[:60]
        window_key = query.get("window", "")
        if not WINDOW_KEY_RE.fullmatch(window_key):
            raise ApiError(400, "invalid_window", "window is a window key like 604800:.")
        metric = query.get("metric") or "speed"
        if metric not in ("speed", "to90", "to50", "peak"):
            raise ApiError(400, "invalid_metric", "metric is \"speed\", \"to90\", \"to50\" or \"peak\".")
        season = self.parse_season(query.get("season"))
        region = parse_region(query.get("region"))
        tier = query.get("tier") or "all"
        if tier not in ("all", "verified"):
            raise ApiError(400, "invalid_tier", "tier is \"all\" or \"verified\".")
        raw_limit = query.get("limit") or "100"
        if not raw_limit.isdigit() or int(raw_limit) < 1:
            raise ApiError(400, "invalid_limit", "limit is a positive integer.")
        limit = min(int(raw_limit), MAX_LEADERBOARD_LIMIT)
        board = (provider, plan_norm, window_key)
        rows = self.best_runs(*board, metric, season, region, tier)[:limit]
        counts = self.season_runs(board, season)
        return {
            "board": self.board_meta(provider, plan_norm, window_key, season, region),
            "season": season,
            "metric": metric,
            "entries": [entry_payload(rank, row, metric, counts.get(row["user_id"], 0))
                        for rank, row in enumerate(rows, start=1)],
            "summary": self.board_summary(board, season, region, tier),
            "updatedAt": self.now(),
        }

    def insights(self, query):
        """服务商对比：每个榜每人速度最好的一条，一次查询取完再在内存里分组。

        medianByRegion 不受 region 过滤影响（它本身就是按地区拆开的）；其余字段按 region 过滤。
        """
        season = self.parse_season(query.get("season"))
        region = parse_region(query.get("region"))
        where, params = self.run_filters(season)
        order = BEST_ORDERS["overall"].format(p="r.")
        board_cols = "r.provider, r.plan_norm, r.window_key"
        # 标签、窗口长度和标题取这个赛季里最近一条 run 的（和 /boards 一样）
        latest = f"OVER (PARTITION BY {board_cols} ORDER BY r.last_observed_at DESC, r.id DESC)"
        rows = self.db.execute(
            "SELECT * FROM (SELECT r.provider, r.plan_norm, r.window_key, r.seconds_to_100, u.region,"
            f" ROW_NUMBER() OVER (PARTITION BY {board_cols}, r.user_id ORDER BY {order}) AS best,"
            f" FIRST_VALUE(r.plan_label) {latest} AS label, FIRST_VALUE(r.window_seconds) {latest} AS seconds,"
            f" FIRST_VALUE(r.window_title) {latest} AS title"
            f" FROM runs r JOIN users u ON u.id = r.user_id WHERE {' AND '.join(where)})"
            " WHERE best = 1", params).fetchall()
        groups = {}
        for row in rows:
            groups.setdefault((row["provider"], row["plan_norm"], row["window_key"]), []).append(row)
        boards = []
        for (provider, plan_norm, window_key), members in groups.items():
            selected = [row for row in members if region is None or row["region"] == region]
            if not selected:
                continue
            seconds = sorted(row["seconds_to_100"] for row in selected if row["seconds_to_100"] is not None)
            by_region = {name: nearest_rank(sorted(row["seconds_to_100"] for row in members
                                                   if row["region"] == name and row["seconds_to_100"] is not None), 50)
                         for name in REGIONS}
            meta = members[0]
            boards.append({
                "provider": provider, "plan": plan_norm, "planLabel": meta["label"],
                "windowKey": window_key, "windowSeconds": meta["seconds"], "windowTitle": meta["title"],
                "runners": len(selected), "completed": len(seconds),
                "completedShare": share(len(seconds), len(selected)),
                "fastestSeconds": seconds[0] if seconds else None,
                "p10Seconds": nearest_rank(seconds, 10),
                "medianSeconds": nearest_rank(seconds, 50),
                "p90Seconds": nearest_rank(seconds, 90),
                "medianByRegion": by_region,
            })
        boards.sort(key=lambda item: (-item["runners"], item["provider"], item["plan"], item["windowKey"]))
        return {"season": season, "boards": boards, "updatedAt": self.now()}

    def run_detail(self, run_id):
        """一条公开 run 和它的用量曲线（计分、可计分的读数，和 recompute_run 取的是同一批）。"""
        row = None
        if RUN_ID_RE.fullmatch(run_id):
            row = self.db.execute(
                "SELECT r.*, u.username, u.display_name FROM runs r JOIN users u ON u.id = r.user_id"
                f" WHERE r.public_id = ? AND r.tier IN {PUBLIC_TIERS}", (run_id,)).fetchone()
        if row is None:
            raise ApiError(404, "run_not_found", "No such run.")
        key = (row["user_id"], row["provider"], row["plan_norm"], row["window_key"], row["resets_bucket"])
        readings = self.db.execute(
            f"SELECT observed_at, used_percent FROM snapshots WHERE {RUN_KEY_WHERE} AND counted = 1 AND rankable = 1"
            " ORDER BY observed_at, id", key).fetchall()
        # 和 secondsTo* 一样不让 t 变负数（允许的时钟误差会让第一条读数略早于 windowStart）
        points = [(max(0, at - row["window_start"]), used) for at, used in readings]
        return {
            "run": {
                "runId": row["public_id"], "username": row["username"], "displayName": row["display_name"],
                "provider": row["provider"], "plan": row["plan_norm"], "planLabel": row["plan_label"],
                "windowKey": row["window_key"], "windowSeconds": row["window_seconds"],
                "windowTitle": row["window_title"], "windowStart": row["window_start"], "resetsAt": row["resets_at"],
                "season": row["season"], "tier": row["tier"], "accountVerified": bool(row["account_verified"]),
                "peakPercent": row["peak_percent"], "secondsTo50": row["seconds_to_50"],
                "secondsTo90": row["seconds_to_90"], "secondsTo100": row["seconds_to_100"],
                "completedAt": row["completed_at"],
            },
            "readings": [{"t": t, "p": used} for t, used in downsample_readings(points)],
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
            f"SELECT DISTINCT provider, plan_norm, window_key FROM runs WHERE user_id = ? AND tier IN {PUBLIC_TIERS}"
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
                        "tier": row["tier"], "accountVerified": bool(row["account_verified"]), "season": row["season"],
                        "achievedAt": row["completed_at"] if metric == "speed" else row["peak_at"],
                        "runId": row["public_id"], "secondsTo50": row["seconds_to_50"],
                        "secondsTo90": row["seconds_to_90"], "secondsTo100": row["seconds_to_100"],
                    })
                    break
        recent = self.db.execute(
            f"SELECT * FROM runs WHERE user_id = ? AND tier IN {PUBLIC_TIERS} ORDER BY last_observed_at DESC, id DESC LIMIT 20",
            (user_id,)).fetchall()
        totals = self.db.execute(
            "SELECT COUNT(*), COALESCE(SUM(tier = 'verified'), 0), COUNT(DISTINCT provider)"
            f" FROM runs WHERE user_id = ? AND tier IN {PUBLIC_TIERS}", (user_id,)).fetchone()
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
            "activity": self.activity_payload(user) if user["show_activity"] else None,
            "github": self.github_brief(user),
        }

    # —— 个人主页：用量热力图 ——

    def activity_payload(self, user):
        """近 53 周每天的 token 数（计分设备上传的活动分钟），按这个人的时区分日；只列有用量的日子。"""
        name, zone = effective_timezone(user)
        today = datetime.fromtimestamp(self.now(), zone).date()
        first = today - timedelta(days=today.weekday() + (HEATMAP_WEEKS - 1) * 7)
        # 往前多取一天：时区偏移最多 14 小时，按 UTC 算的起点不能把第一天的前半截漏掉
        since = int(datetime(first.year, first.month, first.day, tzinfo=timezone.utc).timestamp()) - 86400
        # 按 15 分钟一桶汇总再换算日期：半点、三刻的时区（印度、尼泊尔）也分得准，行数又比按分钟少得多
        rows = self.db.execute(
            "SELECT minute / 900 AS bucket, source, SUM(tokens) FROM activity"
            " WHERE user_id = ? AND counted = 1 AND tokens > 0 AND minute >= ?"
            " GROUP BY bucket, source", (user["id"], since)).fetchall()
        offsets = {}
        days = {}
        for bucket, source, tokens in rows:
            start = bucket * 900
            hour = start // 3600
            if hour not in offsets:
                offsets[hour] = int(datetime.fromtimestamp(hour * 3600, timezone.utc).astimezone(zone)
                                    .utcoffset().total_seconds())
            date = datetime.fromtimestamp(start + offsets[hour], timezone.utc).date()
            if first <= date <= today:
                sources = days.setdefault(date, {})
                sources[source] = sources.get(source, 0) + tokens
        return {
            "timezone": name,
            "from": first.isoformat(),
            "to": today.isoformat(),
            "days": [{"date": date.isoformat(), "tokens": sum(sources.values()),
                      "sources": dict(sorted(sources.items(), key=lambda item: -item[1]))}
                     for date, sources in sorted(days.items())],
            "totalTokens": sum(sum(sources.values()) for sources in days.values()),
        }

    # —— 个人主页：GitHub ——

    def github_identity(self, user_id):
        """这个账号最近关联的 GitHub 登录身份：(数字 id, 登录名)。只认登录过的身份，不认主页上手填的 GitHub 链接。"""
        row = self.db.execute(
            "SELECT subject, login FROM identities WHERE user_id = ? AND provider = 'github'"
            " ORDER BY linked_at DESC, rowid DESC LIMIT 1", (user_id,)).fetchone()
        return (row["subject"], row["login"]) if row else None

    def github_brief(self, user):
        identity = self.github_identity(user["id"]) if user["show_github"] else None
        if identity is None:
            return None
        cached = self.github_cached("user:" + identity[0])
        login = (cached or {}).get("login") or identity[1]
        return {"login": login, "url": f"https://github.com/{login}"} if login else None

    def github_cached(self, key):
        row = self.db.execute("SELECT payload FROM github_cache WHERE key = ?", (key,)).fetchone()
        return json.loads(row["payload"]) if row and row["payload"] else None

    def user_github(self, request, raw_username):
        """GET /users/<username>/github：GitHub 贡献日历（只对关联了 GitHub 登录的人）和主页项目里各仓库的数据。

        数据在 github_cache 里，过期了在后台线程里重取，不占服务锁；手里一份都没有时这个请求最多等 GITHUB_WAIT 秒，
        还没取到就回 pending，页面过一会儿再来。
        """
        with self.lock:
            self.take_token("ip:" + request.ip, "public")
            username = normalize_username(raw_username)
            user = self.db.execute("SELECT * FROM users WHERE username = ?", (username,)).fetchone() \
                if username else None
            if user is None:
                return Response(404, ApiError(404, "user_not_found", "No such user.").payload(), public=True)
            identity = self.github_identity(user["id"]) if user["show_github"] else None
            repos = []
            for project in self.projects_payload(user["id"]):
                repo = github_repo(project["github"])
                if repo and repo.lower() not in {r.lower() for r in repos}:
                    repos.append(repo)
            repos = repos[:MAX_GITHUB_REPOS]
            keys = (["user:" + identity[0]] if identity else []) + ["repo:" + repo.lower() for repo in repos]
            now = self.now()
            rows = {row["key"]: row for row in self.db.execute(
                f"SELECT * FROM github_cache WHERE key IN ({','.join('?' * len(keys))})", keys)} if keys else {}
            if keys:
                # 记下有人看过（一小时最多写一次），两周没人看的由 _purge 清掉
                self.db.executemany(
                    "INSERT INTO github_cache(key, used_at) VALUES (?, ?) ON CONFLICT(key) DO UPDATE"
                    " SET used_at = excluded.used_at WHERE github_cache.used_at < excluded.used_at - 3600",
                    [(key, now) for key in keys])
            jobs = {}
            for key in keys:
                row = rows.get(key)
                due = row is None or (row["fetched_at"] + GITHUB_TTL <= now and row["retry_at"] <= now) \
                    or (row["payload"] is None and row["retry_at"] <= now)
                if due:
                    target = (identity[0], identity[1]) if key.startswith("user:") else repos[
                        [r.lower() for r in repos].index(key[len("repo:"):])]
                    jobs[key] = self.start_github_job(key, target)
            waiting = [jobs[key] for key in keys if key in jobs and (rows.get(key) is None or rows[key]["payload"] is None)]
        deadline = time.monotonic() + GITHUB_WAIT
        for job in waiting:
            job.join(max(0.0, deadline - time.monotonic()))
        with self.lock:
            payloads = {key: self.github_cached(key) for key in keys}
        pending = any(key in jobs and jobs[key].is_alive() and payloads[key] is None for key in keys)
        body = {"login": None, "url": None, "calendar": None, "totals": None, "repos": [], "pending": pending}
        fetched = []
        if identity:
            data = payloads["user:" + identity[0]]
            if data:
                body.update(login=data.get("login"), url=data.get("url"), calendar=data.get("calendar"),
                            totals=data.get("totals"))
                fetched.append(data.get("fetchedAt") or 0)
            else:
                body.update(login=identity[1], url=f"https://github.com/{identity[1]}" if identity[1] else None)
        for repo in repos:
            data = payloads["repo:" + repo.lower()]
            if data:
                body["repos"].append(dict(data, repo=data.get("repo") or repo))
                fetched.append(data.get("fetchedAt") or 0)
        body["fetchedAt"] = min(fetched) if fetched else None
        return Response(200, body, public=not pending)

    def start_github_job(self, key, target):
        job = self._github_jobs.get(key)
        if job is None or not job.is_alive():
            job = threading.Thread(target=self.refresh_github, args=(key, target), daemon=True)
            self._github_jobs[key] = job
            job.start()
        return job

    def refresh_github(self, key, target):
        """后台线程：取一份 GitHub 数据写进缓存。取失败保留上一份，GITHUB_RETRY 之后再试。"""
        retry = GITHUB_RETRY
        payload = None
        try:
            if key.startswith("user:"):
                payload = self.fetch_github_profile(*target)
            else:
                payload, pending = self.fetch_github_repo(target)
                if pending:
                    retry = GITHUB_PENDING_RETRY
        except Exception as error:  # noqa: BLE001 — 网络、JSON、页面改版都只记一行
            print(f"github: refreshing {key.partition(':')[0]} failed: {type(error).__name__}", file=sys.stderr)
        with self.lock:
            now = self.now()
            if payload is not None:
                payload["fetchedAt"] = now
                # 仓库数据还缺提交统计（GitHub 在算）时照样存下，但 fetched_at 不算数，两分钟后再取
                fetched_at = now if retry != GITHUB_PENDING_RETRY else 0
                self.db.execute(
                    "INSERT INTO github_cache(key, payload, fetched_at, retry_at, used_at) VALUES (?, ?, ?, ?, ?)"
                    " ON CONFLICT(key) DO UPDATE SET payload = excluded.payload, fetched_at = excluded.fetched_at,"
                    " retry_at = excluded.retry_at",
                    (key, json.dumps(payload, separators=(",", ":")), fetched_at, now + retry if not fetched_at else 0, now))
                if key.startswith("user:"):
                    # GitHub 上改过名：身份里的登录名跟着改
                    self.db.execute("UPDATE identities SET login = ? WHERE provider = 'github' AND subject = ?",
                                    (payload.get("login"), key[len("user:"):]))
                self._cache.clear()
            else:
                self.db.execute(
                    "INSERT INTO github_cache(key, retry_at, used_at) VALUES (?, ?, ?)"
                    " ON CONFLICT(key) DO UPDATE SET retry_at = excluded.retry_at", (key, now + retry, now))

    def github_headers(self, accept="application/vnd.github+json"):
        headers = {"Accept": accept, "User-Agent": USER_AGENT, "X-GitHub-Api-Version": "2022-11-28"}
        if self.settings.github_token:
            headers["Authorization"] = f"Bearer {self.settings.github_token}"
        elif self.settings.github:
            # 没有令牌时用 OAuth 应用的 client id / secret：公开数据每小时 5000 次，不用的话按 IP 只有 60 次
            pair = f"{self.settings.github_client_id}:{self.settings.github_client_secret}".encode("utf-8")
            headers["Authorization"] = "Basic " + base64.b64encode(pair).decode("ascii")
        return headers

    def github_json(self, method, url, body=None, allow=(200,)):
        headers = self.github_headers()
        if body is not None:
            headers["Content-Type"] = "application/json"
        status, raw = self.http(method, url, headers, body)
        if status not in allow:
            raise OAuthFailure(f"HTTP {status}")
        return status, (json.loads(raw.decode("utf-8")) if raw else None)

    def fetch_github_profile(self, subject, known_login):
        """按数字 id 取当前登录名（改过名也跟得上），再取近一年的贡献日历；有令牌时连提交、PR 等分项一起取。"""
        status, user = self.github_json("GET", f"{GITHUB_API}/user/{quote(subject, safe='')}", allow=(200, 404))
        if status == 404:
            return {"login": None, "url": None, "calendar": None, "totals": None, "gone": True}
        login = user.get("login") if isinstance(user, dict) else None
        if not isinstance(login, str) or not GITHUB_HANDLE_RE.fullmatch(login):
            raise OAuthFailure("no login")
        calendar = totals = None
        if self.settings.github_token:
            try:
                calendar, totals = self.fetch_github_graphql(login)
            except (OAuthFailure, ValueError, KeyError, TypeError):
                calendar = totals = None
        if calendar is None:
            calendar = self.fetch_github_calendar_page(login)
        return {"login": login, "url": f"https://github.com/{login}", "calendar": calendar, "totals": totals}

    def fetch_github_graphql(self, login):
        body = json.dumps({"query": GITHUB_QUERY, "variables": {"login": login}}).encode("utf-8")
        _, data = self.github_json("POST", GITHUB_GRAPHQL_URL, body)
        collection = data["data"]["user"]["contributionsCollection"]
        days = [(day["date"], int(day["contributionCount"]))
                for week in collection["contributionCalendar"]["weeks"] for day in week["contributionDays"]]
        calendar = calendar_payload(days)
        totals = {"commits": int(collection["totalCommitContributions"]),
                  "pullRequests": int(collection["totalPullRequestContributions"]),
                  "issues": int(collection["totalIssueContributions"]),
                  "reviews": int(collection["totalPullRequestReviewContributions"]),
                  "private": int(collection["restrictedContributionsCount"])}
        return calendar, totals

    def fetch_github_calendar_page(self, login):
        """没有令牌时读 github.com 公开的贡献日历页面（HTML），只拿到每天的贡献数。"""
        headers = {"Accept": "text/html", "User-Agent": USER_AGENT}
        status, raw = self.http("GET", GITHUB_CONTRIBUTIONS_URL.format(login=quote(login, safe="")), headers)
        if status != 200:
            raise OAuthFailure(f"HTTP {status}")
        days = parse_contribution_page(raw.decode("utf-8", "replace"))
        if len(days) < 300:   # 一年少说 365 格；太少说明页面改版了，不能当成真数据
            raise OAuthFailure("calendar layout")
        return calendar_payload(days)

    def fetch_github_repo(self, repo):
        """仓库的星标、分叉、语言、最近推送，以及近 52 周每周的提交数。返回 (payload, 提交统计是否还在算)。"""
        status, meta = self.github_json("GET", f"{GITHUB_API}/repos/{repo}", allow=(200, 404, 451))
        if status != 200:
            return {"repo": repo, "missing": True}, False
        payload = {
            "repo": meta.get("full_name") if isinstance(meta.get("full_name"), str) else repo,
            "url": meta.get("html_url") if https_url(meta.get("html_url"), hosts={"github.com"}) else f"https://github.com/{repo}",
            "description": clip_text(meta.get("description"), 200),
            "stars": as_int(meta.get("stargazers_count")),
            "forks": as_int(meta.get("forks_count")),
            "language": clip_text(meta.get("language"), 40),
            "pushedAt": iso_seconds(meta.get("pushed_at")),
            "archived": meta.get("archived") is True,
            "weeks": None,
            "commits": None,
        }
        status, weeks = self.github_json("GET", f"{GITHUB_API}/repos/{repo}/stats/commit_activity", allow=(200, 202, 204))
        if status == 202:
            return payload, True
        counts = [as_int(week.get("total")) or 0 for week in weeks if isinstance(week, dict)] \
            if isinstance(weeks, list) else []
        counts = ([0] * 52 + counts)[-52:]
        payload.update(weeks=counts, commits=sum(counts))
        return payload, False


# —— 响应形状 ——

def links_payload(user):
    """全部链接，按主页上的顺序；没填的是 null。"""
    try:
        extra = json.loads(user["links_json"] or "{}")
    except ValueError:
        extra = {}
    return {kind: (user[kind] if kind in LINK_COLUMNS else extra.get(kind)) or None for kind in LINK_KINDS}


def user_brief(user):
    return {"username": user["username"], "displayName": user["display_name"], "region": user["region"]}


def private_user(user):
    return {"username": user["username"], "displayName": user["display_name"], "bio": user["bio"],
            "region": user["region"], "links": links_payload(user), "joinedAt": user["joined_at"],
            "timezone": user["timezone"], "showActivity": bool(user["show_activity"]),
            "showGithub": bool(user["show_github"])}


def effective_timezone(user):
    """热力图按这个时区分日：自己选的，没选时中国区按 Asia/Shanghai，其余按 UTC。返回 (名字, ZoneInfo)。"""
    for name in (user["timezone"], "Asia/Shanghai" if user["region"] == "china" else "UTC"):
        if name:
            try:
                return name, ZoneInfo(name)
            except (ZoneInfoNotFoundError, ValueError):
                continue
    return "UTC", timezone.utc


def run_payload(row):
    # 公开的 run 不带设备号和账号摘要
    return {
        "runId": row["public_id"],
        "provider": row["provider"], "plan": row["plan_norm"], "planLabel": row["plan_label"],
        "windowKey": row["window_key"], "windowSeconds": row["window_seconds"], "windowTitle": row["window_title"],
        "season": row["season"], "windowStart": row["window_start"], "resetsAt": row["resets_at"],
        "peakPercent": row["peak_percent"], "secondsTo50": row["seconds_to_50"], "secondsTo90": row["seconds_to_90"],
        "secondsTo100": row["seconds_to_100"], "completedAt": row["completed_at"],
        "lastObservedAt": row["last_observed_at"], "tier": row["tier"],
        "accountVerified": bool(row["account_verified"]),
    }


def entry_payload(rank, row, metric, season_runs):
    if metric == "peak":
        value, unit, achieved_at = row["peak_percent"], "percent", row["peak_at"]
    else:
        value, unit = row[METRIC_COLUMNS[metric]], "seconds"
        # 到 100% 就是 completedAt；到 90/50% 是 windowStart 加上用时，也就是首次达到那条线的读数时间
        achieved_at = row["completed_at"] if metric == "speed" else row["window_start"] + value
    return {
        "rank": rank, "username": row["username"], "displayName": row["display_name"],
        "value": value,
        "unit": unit,
        "tier": row["tier"],
        "accountVerified": bool(row["account_verified"]),
        "achievedAt": achieved_at,
        "peakPercent": row["peak_percent"],
        "runId": row["public_id"],
        "secondsTo50": row["seconds_to_50"],
        "secondsTo90": row["seconds_to_90"],
        "secondsTo100": row["seconds_to_100"],
        "seasonRuns": season_runs,
    }


def previous_season(season):
    """ISO 周的上一周；all（或无法往前的周）返回 None。"""
    match = SEASON_RE.fullmatch(season or "")
    if not match:
        return None
    try:
        monday = datetime.fromisocalendar(int(match.group(1)), int(match.group(2)), 1)
        year, week, _ = (monday - timedelta(days=7)).isocalendar()
    except (ValueError, OverflowError):
        return None
    return f"{year}-W{week:02d}"


def share(count, total):
    """0–1 的比例，保留 4 位小数；分母为 0（这个筛选下没人）时是 null。"""
    return round(count / total, 4) if total else None


def lower_median(rows):
    """已按用时排好的行里取下中位数那一行（偶数个取前一个），空列表返回 None。"""
    return rows[(len(rows) - 1) // 2] if rows else None


def nearest_rank(values, percent):
    """最近秩百分位：排好序的 values 里第 ⌈percent × n / 100⌉ 个（至少第 1 个）。整数运算，免得 0.1 × 30 算出 3.0000000000000004。"""
    if not values:
        return None
    rank = max(1, (percent * len(values) + 99) // 100)
    return values[rank - 1]


def downsample_readings(points, limit=MAX_CURVE_POINTS):
    """曲线最多 limit 个点：保留第一条、最后一条和首次达到 50/90/99.5% 的读数，其余按下标均匀抽取。"""
    count = len(points)
    if count <= limit:
        return list(points)
    keep = {0, count - 1}
    for threshold in CURVE_THRESHOLDS:
        index = next((i for i, (_, used) in enumerate(points) if used >= threshold), None)
        if index is not None:
            keep.add(index)
    rest = [i for i in range(count) if i not in keep]
    slots = limit - len(keep)
    if slots == 1:
        keep.add(rest[len(rest) // 2])
    elif slots > 1:
        # rest 比 slots 多，步长 ≥ 1，向下取整后下标互不相同
        keep.update(rest[k * (len(rest) - 1) // (slots - 1)] for k in range(slots))
    return [points[i] for i in sorted(keep)]


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
    """个人链接统一存成 https 地址。有简写的平台也接受账号名（可带 @），Mastodon 接受 @name@实例。"""
    if value is None or (isinstance(value, str) and not value.strip()):
        return None
    hosts, handle_re, template = LINK_KINDS[field]
    url = None
    if isinstance(value, str):
        text = value.strip()
        mastodon = MASTODON_HANDLE_RE.fullmatch(text) if field == "mastodon" else None
        handle = text.lstrip("@")
        if mastodon:
            url = f"https://{mastodon.group(2).lower()}/@{mastodon.group(1)}"
        elif handle_re is not None and handle_re.fullmatch(handle):
            url = template.format(handle)
        else:
            url = https_url(text, limit=200, hosts=hosts)
    if url is None:
        kind = "an https:// URL or a handle" if handle_re is not None or field == "mastodon" else "an https:// URL"
        raise ApiError(400, "invalid_links", f"links.{field} must be {kind}.")
    return url


def profile_timezone(value):
    """IANA 时区名（Asia/Shanghai）；null 或空串清空，回到按地区的默认值。"""
    if value is None or value == "":
        return None
    if isinstance(value, str) and TIMEZONE_RE.fullmatch(value) and ".." not in value:
        try:
            ZoneInfo(value)
            return value
        except (ZoneInfoNotFoundError, ValueError):
            pass
    raise ApiError(400, "invalid_timezone", "timezone must be an IANA time zone name such as Asia/Shanghai.")


CALENDAR_CELL_RE = re.compile(r"<td\b[^>]*\bContributionCalendar-day\b[^>]*>")
CALENDAR_DATE_RE = re.compile(r'\bdata-date="(\d{4}-\d{2}-\d{2})"')
CALENDAR_ID_RE = re.compile(r'\bid="([^"]+)"')
CALENDAR_TIP_RE = re.compile(r'<tool-tip\b[^>]*\bfor="([^"]+)"[^>]*>([^<]*)</tool-tip>')
CALENDAR_COUNT_RE = re.compile(r"\s*(\d[\d,]*)\s+contributions?\b")


def parse_contribution_page(html):
    """github.com/users/<login>/contributions：每个格子是带 data-date 的 td，数字在 for 指向它的 tool-tip 里
    （「12 contributions on May 1st.」「No contributions on …」）。返回 [(日期, 贡献数)]。"""
    tips = {}
    for cell_id, text in CALENDAR_TIP_RE.findall(html):
        match = CALENDAR_COUNT_RE.match(text)
        tips[cell_id] = int(match.group(1).replace(",", "")) if match else 0
    days = []
    for tag in CALENDAR_CELL_RE.findall(html):
        date, cell_id = CALENDAR_DATE_RE.search(tag), CALENDAR_ID_RE.search(tag)
        if date:
            days.append((date.group(1), tips.get(cell_id.group(1), 0) if cell_id else 0))
    return days


def calendar_payload(days):
    """[(日期, 贡献数)] → {total, from, to, days}；days 只列有贡献的日子，按日期排。"""
    ordered = sorted((date, count) for date, count in days if count >= 0)
    if not ordered:
        return {"total": 0, "from": None, "to": None, "days": []}
    return {"total": sum(count for _, count in ordered), "from": ordered[0][0], "to": ordered[-1][0],
            "days": [{"date": date, "count": count} for date, count in ordered if count > 0]}


def github_repo(url):
    """项目里存的 https://github.com/owner/repo（可能带 .git 或更深的路径）→ owner/repo；不是仓库地址返回 None。"""
    if not isinstance(url, str):
        return None
    parts = urlsplit(url)
    if parts.hostname not in ("github.com", "www.github.com"):
        return None
    segments = [s for s in parts.path.split("/") if s]
    if len(segments) < 2:
        return None
    repo = f"{segments[0]}/{segments[1].removesuffix('.git')}"
    return repo if GITHUB_REPO_RE.fullmatch(repo) else None


def iso_seconds(value):
    """GitHub 的 2026-09-10T12:00:00Z → Unix 秒。"""
    if not isinstance(value, str):
        return None
    try:
        return int(datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp())
    except ValueError:
        return None


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
    # Caddy 会把真实来源追加到 X-Forwarded-For 末尾；取最后一个，客户端自己伪造的前缀不起作用。
    # 只信本机反代转来的这个头：直接连进来的请求自己带的 X-Forwarded-For 不算数
    peer = handler.client_address[0]
    forwarded = handler.headers.get("X-Forwarded-For", "")
    if forwarded and peer in ("127.0.0.1", "::1"):
        return forwarded.split(",")[-1].strip() or peer
    return peer


class Handler(BaseHTTPRequestHandler):
    server_version = "quotabar-run/1"
    sys_version = ""
    timeout = 30  # 慢速连接不能一直占着线程

    def log_message(self, fmt, *args):  # 只记来源 IP、请求行和状态码，不记请求头和请求体
        if not getattr(self.server, "quiet", False):
            sys.stderr.write("%s %s\n" % (client_ip(self), fmt % args))

    def log_request(self, code="-", size="-"):
        # 请求行里的查询串可能带 OAuth 回调的 code 和 state，日志只记方法和不带查询串的路径
        path = (getattr(self, "path", "") or "").partition("?")[0]
        self.log_message('"%s %s" %s', getattr(self, "command", "") or "-", path, getattr(code, "value", code))

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
        cookies = parse_cookies("; ".join(self.headers.get_all("Cookie") or ()))
        request = Request(self.command, path, params, headers, body, client_ip(self), cookies)
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
        if data:
            self.send_header("Content-Type", "application/json; charset=utf-8")
        if response.status != 204:
            self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", f"public, max-age={CACHE_TTL}" if response.public else "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        for name, value in response.headers.items():
            self.send_header(name, value)
        for cookie in response.cookies:
            self.send_header("Set-Cookie", cookie)
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
        service.listen_host = address[0]
        super().__init__(address, Handler)


def main():
    env = os.environ
    port = int(env.get("QUOTA_RUN_PORT") or DEFAULT_PORT)
    db_path = env.get("QUOTA_RUN_DB") or DEFAULT_DB
    secret_file = env.get("QUOTA_RUN_SECRET_FILE") or DEFAULT_SECRET_FILE
    settings = Settings.from_env(env)

    def flag(name):
        return (env.get(name) or "").strip() == "1"

    service = RunService(db_path, load_secret(secret_file), settings=settings,
                         device_signup=flag("QUOTA_RUN_DEVICE_SIGNUP"), dev_login=flag("QUOTA_RUN_DEV_LOGIN"))
    server = RunHTTPServer(("127.0.0.1", port), service)
    # 只打印哪些登录方式可用，不打印任何 client id、密钥或 SMTP 账号
    print(f"quota run on 127.0.0.1:{port}, db={db_path}, origin={settings.origin}, "
          f"github={settings.github}, google={settings.google}, email={service.mailer is not None}", file=sys.stderr)
    if service.dev_login and not service.dev_login_enabled():
        print("QUOTA_RUN_DEV_LOGIN=1 ignored: it needs a local QUOTA_RUN_ORIGIN (http://localhost:… or http://127.0.0.1:…)",
              file=sys.stderr)
    elif service.dev_login_enabled():
        print("local testing: POST /auth/dev is on", file=sys.stderr)
    if service.device_signup:
        print("local testing: POST /register is on", file=sys.stderr)
    if settings.insecure_cookies:
        print("local testing: cookies are sent without Secure", file=sys.stderr)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        service.close()


if __name__ == "__main__":
    main()

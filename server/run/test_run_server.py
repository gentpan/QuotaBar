"""Quota Run 服务端测试。

在进程内起一个真实的 HTTP 服务（临时数据库、临时密钥、假时钟），用 cryptography 生成
P-256 密钥，像应用那样签名请求；网页那一侧用带 cookie 罐的 Browser 模拟。GitHub、Google
和发信都换成假的，不连外网。运行：

    python3 -m unittest server/run/test_run_server.py      # 仓库根目录
    cd server/run && python3 -m unittest                   # 或者在本目录
"""
import base64
import contextlib
import datetime
import hashlib
import http.client
import io
import json
import os
import re
import secrets
import sqlite3
import sys
import tempfile
import threading
import unittest
from unittest import mock
from urllib.parse import parse_qs, parse_qsl, urlencode, urlsplit

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import run_server  # noqa: E402
from cryptography.hazmat.primitives import hashes, serialization  # noqa: E402
from cryptography.hazmat.primitives.asymmetric import ec  # noqa: E402

NOW = 1_789_560_000            # 2026-09-16 12:00 UTC，星期三，ISO 周 2026-W38
FIVE_HOURS = 18_000
DAY = 86_400
# 两小时从 0 涨到 100%，每 10 分钟一条
FAST = [(minute, round(minute * 100 / 120, 1)) for minute in range(0, 121, 10)]

ORIGIN = "http://localhost:8080"
GITHUB_SECRET = "github-client-secret-for-tests"
GOOGLE_SECRET = "google-client-secret-for-tests"
DEFAULT = object()


class Clock:
    def __init__(self, now):
        self.value = float(now)

    def __call__(self):
        return self.value

    def advance(self, seconds):
        self.value += seconds


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def account_digest(provider, account):
    text = "quota-run-account-v1\n" + provider + "\n" + account.strip().lower()
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def reading(used, observed_at, resets_at, window=FIVE_HOURS, provider="claude", plan="Max 20x",
            digest=None, scope=None, title="5-hour window", source="api"):
    return {
        "provider": provider, "plan": plan, "accountDigest": digest,
        "windowKey": f"{window}:{scope or ''}", "windowTitle": title, "windowSeconds": window,
        "scope": scope, "usedPercent": used, "resetsAt": resets_at, "observedAt": observed_at, "source": source,
    }


def series(start, points, window=FIVE_HOURS, **fields):
    """points 是 [(开窗后第几分钟, 百分比)]。"""
    return [reading(used, start + minute * 60, start + window, window=window, **fields) for minute, used in points]


class Headers(dict):
    """响应头（小写键）；同名的 Set-Cookie 可能有多条，单独放在 set_cookies 里。"""
    set_cookies = ()


class FakeMailer:
    def __init__(self):
        self.sent = []

    def __call__(self, to, subject, text):
        self.sent.append((to, subject, text))

    def code(self, index=-1):
        return re.search(r"\d{6}", self.sent[index][1]).group(0)


class FakeProviders:
    """假的 GitHub 和 Google：记下每次调用，按 URL 回 JSON。"""
    GITHUB_TOKEN = "gho_secret_token_value"
    GOOGLE_TOKEN = "ya29.secret-token-value"

    def __init__(self):
        self.calls = []
        self.token_status = 200
        self.token_error = False
        self.github_user = {"id": 101, "login": "Octo-Cat", "name": "Octo Cat"}
        self.github_emails = [{"email": "other@example.com", "primary": False, "verified": True},
                              {"email": "Octo@Example.com", "primary": True, "verified": True}]
        self.google_user = {"sub": "google-sub-1", "email": "gee@example.com", "email_verified": True,
                            "name": "Gee Gee"}
        # 其他地址（GitHub 的公开数据）：URL → 函数(method, headers, body) → (状态码, 响应体 bytes)
        self.routes = {}

    def forms(self, url):
        return [dict(parse_qsl(call["body"].decode("ascii"))) for call in self.calls if call["url"] == url]

    def __call__(self, method, url, headers=None, body=None):
        headers = dict(headers or {})
        self.calls.append({"method": method, "url": url, "headers": headers, "body": body})

        def reply(status, payload):
            return status, json.dumps(payload).encode("utf-8")

        if url in (run_server.GITHUB_TOKEN_URL, run_server.GOOGLE_TOKEN_URL):
            if method != "POST":
                return reply(405, {})
            if self.token_status != 200:
                return reply(self.token_status, {"error": "invalid_grant"})
            if self.token_error:
                return reply(200, {"error": "bad_verification_code"})
            token = self.GITHUB_TOKEN if url == run_server.GITHUB_TOKEN_URL else self.GOOGLE_TOKEN
            return reply(200, {"access_token": token, "token_type": "bearer"})
        if url in (run_server.GITHUB_USER_URL, run_server.GITHUB_EMAILS_URL):
            if headers.get("Authorization") != f"Bearer {self.GITHUB_TOKEN}":
                return reply(401, {})
            return reply(200, self.github_user if url == run_server.GITHUB_USER_URL else self.github_emails)
        if url == run_server.GOOGLE_USERINFO_URL:
            if headers.get("Authorization") != f"Bearer {self.GOOGLE_TOKEN}":
                return reply(401, {})
            return reply(200, self.google_user)
        if url in self.routes:
            return self.routes[url](method, headers, body)
        return reply(404, {})


class Mac:
    """一台装了 QuotaBar 的 Mac：自己的 P-256 私钥，按契约签名每个请求。"""

    def __init__(self, test):
        self.test = test
        self.key = ec.generate_private_key(ec.SECP256R1())
        self.device_id = None
        self.digest = None
        self.browser = None

    @property
    def public_key(self):
        raw = self.key.public_key().public_bytes(serialization.Encoding.X962,
                                                 serialization.PublicFormat.UncompressedPoint)
        return b64url(raw)

    def call(self, method, route, payload=None, *, raw=None, timestamp=None, nonce=None,
             signed_body=None, key=None, query=None):
        path = run_server.API_PREFIX + route
        body = raw if raw is not None else (b"" if payload is None else json.dumps(payload).encode("utf-8"))
        timestamp = str(int(self.test.clock()) if timestamp is None else timestamp)
        nonce = nonce or b64url(secrets.token_bytes(16))
        # 规范串在这里独立拼一遍，不借用服务端的函数，这样测试才能发现两边不一致
        message = "\n".join(["quota-run-v1", method, path, timestamp, nonce,
                             hashlib.sha256(body if signed_body is None else signed_body).hexdigest()])
        signature = (key or self.key).sign(message.encode("utf-8"), ec.ECDSA(hashes.SHA256()))
        headers = {"Content-Type": "application/json", "X-Quota-Timestamp": timestamp,
                   "X-Quota-Nonce": nonce, "X-Quota-Signature": b64url(signature)}
        if self.device_id:
            headers["X-Quota-Device"] = self.device_id
        return self.test.http(method, route, body, headers, query)

    def register(self, username, region="global", display_name=None):
        status, data, _ = self.call("POST", "/register", {
            "username": username, "displayName": display_name or str(username).title(), "region": region,
            "publicKey": self.public_key, "deviceName": "Studio", "platform": "macos", "appVersion": "0.6.0"})
        if status == 201:
            self.device_id = data["deviceId"]
            self.digest = account_digest("claude", f"{data['user']['username']}@example.com")
        return status, data

    def start_connect(self, name="Studio", **extra):
        return self.call("POST", "/connect/start", {
            "publicKey": self.public_key, "deviceName": name, "platform": "macos", "appVersion": "0.6.0", **extra})

    def poll(self, request_id):
        return self.call("POST", "/connect/poll", {"requestId": request_id, "publicKey": self.public_key})

    def upload(self, snapshots, activity=None):
        status, data, _ = self.call("POST", "/snapshots", {"snapshots": snapshots, "activity": activity or []})
        self.test.assertEqual(status, 200, data)
        return data

    def run(self, start, points=FAST, provider="claude", with_activity=True, digest="default", **fields):
        """上传一整段读数，默认附上活动分钟和账号摘要，正好满足 verified。"""
        digest = self.digest if digest == "default" else digest
        activity = [{"minute": start + 300, "source": provider, "tokens": 1200}] if with_activity else []
        return self.upload(series(start, points, provider=provider, digest=digest, **fields), activity)


class Browser:
    """quota.run 页面那一侧：一个 cookie 罐，非 GET 请求默认带上站点的 Origin。"""

    def __init__(self, test, origin=ORIGIN, ip=None):
        self.test = test
        self.origin = origin
        self.ip = ip
        self.jar = {}   # 名字 → (值, Path)

    def cookie(self, name):
        entry = self.jar.get(name)
        return entry[0] if entry else None

    def call(self, method, route, payload=None, *, query=None, origin=DEFAULT, prefix=run_server.API_PREFIX):
        path = prefix + route
        headers = {}
        cookies = [f"{name}={value}" for name, (value, scope) in self.jar.items()
                   if path == scope or path.startswith(scope.rstrip("/") + "/")]
        if cookies:
            headers["Cookie"] = "; ".join(cookies)
        if origin is DEFAULT:
            origin = None if method == "GET" else self.origin
        if origin:
            headers["Origin"] = origin
        if self.ip:
            headers["X-Forwarded-For"] = self.ip
        body = b"" if payload is None else json.dumps(payload).encode("utf-8")
        if body:
            headers["Content-Type"] = "application/json"
        status, data, response_headers = self.test.http(method, route, body, headers, query, prefix=prefix)
        for line in response_headers.set_cookies:
            parts = [part.strip() for part in line.split(";")]
            name, _, value = parts[0].partition("=")
            attributes = {k.lower(): v for k, _, v in (part.partition("=") for part in parts[1:])}
            if attributes.get("max-age") == "0":
                self.jar.pop(name, None)
            else:
                self.jar[name] = (value, attributes.get("path", "/"))
        return status, data, response_headers


def location(headers):
    """302 的 Location 拆成 (路径, 查询参数 dict)。"""
    parts = urlsplit(headers["location"])
    return parts.scheme + "://" + parts.netloc + parts.path, {k: v[0] for k, v in parse_qs(parts.query).items()}


def cookie_line(headers, name):
    lines = [line for line in headers.set_cookies if line.startswith(name + "=")]
    return lines[-1] if lines else None


class ServerTestCase(unittest.TestCase):
    def service_options(self):
        settings = run_server.Settings(origin=ORIGIN, github_client_id="gh-client", github_client_secret=GITHUB_SECRET,
                                       google_client_id="google-client", google_client_secret=GOOGLE_SECRET)
        return {"settings": settings, "http": self.providers, "mailer": self.mailer,
                "device_signup": True, "dev_login": True}

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.clock = Clock(NOW)
        self.db_path = os.path.join(self.tmp.name, "run.db")
        self.providers = FakeProviders()
        self.mailer = FakeMailer()
        secret = run_server.load_secret(os.path.join(self.tmp.name, "secret"))
        generous = (100_000, 1.0)
        self.service = run_server.RunService(self.db_path, secret, clock=self.clock, cache_ttl=0,
                                             limits={kind: generous for kind in run_server.DEFAULT_LIMITS},
                                             **self.service_options())
        self.server = run_server.RunHTTPServer(("127.0.0.1", 0), self.service, quiet=True)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.02}, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.service.close()
        self.tmp.cleanup()

    def http(self, method, route, body=b"", headers=None, query=None, prefix=run_server.API_PREFIX):
        path = prefix + route
        if query:
            path += "?" + urlencode(query)
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=20)
        try:
            connection.request(method, path, body=body or None, headers=headers or {})
            response = connection.getresponse()
            raw = response.read()
            data = json.loads(raw) if raw else None
            result = Headers({k.lower(): v for k, v in response.getheaders()})
            result.set_cookies = response.msg.get_all("Set-Cookie") or []
            return response.status, data, result
        finally:
            connection.close()

    def get(self, route, **query):
        status, data, _ = self.http("GET", route, query=query or None)
        return status, data

    def board(self, **query):
        params = {"provider": "claude", "plan": "max20x", "window": f"{FIVE_HOURS}:"}
        params.update(query)
        status, data = self.get("/leaderboard", **params)
        self.assertEqual(status, 200, data)
        return data

    # —— 账号与 Mac ——

    def signed_in(self, email, **options):
        browser = Browser(self, **options)
        status, data, _ = browser.call("POST", "/auth/dev", {"email": email})
        self.assertEqual(status, 200, data)
        return browser

    def account(self, username, region="global", email=None):
        browser = self.signed_in(email or f"{username}@example.com")
        status, data, _ = browser.call("POST", "/signup", {
            "username": username, "displayName": username.title(), "region": region})
        self.assertEqual(status, 201, data)
        return browser

    def connect(self, browser, name="Studio"):
        mac = Mac(self)
        status, start, _ = mac.start_connect(name)
        self.assertEqual(status, 201, start)
        status, data, _ = browser.call("POST", f"/connect/{start['userCode']}/approve")
        self.assertEqual(status, 200, data)
        status, data, _ = mac.poll(start["requestId"])
        self.assertEqual((status, data["status"]), (200, "approved"), data)
        mac.device_id = data["deviceId"]
        mac.browser = browser
        return mac

    def joined(self, username, region="global"):
        mac = self.connect(self.account(username, region))
        mac.digest = account_digest("claude", f"{username}@example.com")
        return mac

    def paired(self, mac):
        other = self.connect(mac.browser, name="Air")
        other.digest = mac.digest
        return other

    def oauth_start(self, browser, provider, **query):
        status, _, headers = browser.call("GET", f"/auth/{provider}/start", query=query or None)
        self.assertEqual(status, 302)
        url, params = location(headers)
        return url, params

    def oauth_callback(self, browser, provider, state, **query):
        status, _, headers = browser.call("GET", f"/auth/{provider}/callback",
                                          query={"code": "the-provider-code", "state": state, **query})
        self.assertEqual(status, 302)
        return location(headers)

    def query(self, sql, params=()):
        connection = sqlite3.connect(self.db_path)
        try:
            return connection.execute(sql, params).fetchall()
        finally:
            connection.close()

    def dump(self):
        connection = sqlite3.connect(self.db_path)
        try:
            return "\n".join(connection.iterdump())
        finally:
            connection.close()

    def run_tiers(self):
        return [row[0] for row in self.query("SELECT tier FROM runs ORDER BY id")]


class RegistrationTests(ServerTestCase):
    def test_register_first_device_is_ranked(self):
        mac = Mac(self)
        status, data = mac.register("Peter_01", display_name="Peter")
        self.assertEqual(status, 201)
        self.assertEqual(data["user"], {"username": "peter_01", "displayName": "Peter", "region": "global"})
        self.assertTrue(data["ranked"])
        status, me, headers = mac.call("GET", "/me")
        self.assertEqual(status, 200)
        self.assertEqual(headers["cache-control"], "no-store")
        self.assertEqual(me["user"]["username"], "peter_01")
        self.assertEqual(me["devices"], [{"deviceId": mac.device_id, "name": "Studio", "ranked": True,
                                          "lastSeenAt": NOW, "current": True, "appVersion": "0.6.0"}])
        self.assertIsNone(me["rankedChangeAvailableAt"])
        self.assertIsNone(me["lastUploadAt"])
        self.assertEqual(me["projects"], [])
        self.assertEqual(me["identities"], [])

    def test_username_rules_and_taken(self):
        for bad in ["ab", "-abc", "_abc", "admin", "Leaderboard", "connect", "auth", "account", "a" * 21,
                    "has space", "ümlaut", "", None]:
            status, data = Mac(self).register(bad)
            self.assertEqual((status, data["error"]), (400, "invalid_username"), bad)
        self.assertEqual(Mac(self).register("abc")[0], 201)
        status, data = Mac(self).register("ABC")
        self.assertEqual((status, data["error"]), (409, "username_taken"))
        status, data = Mac(self).register("valid-name", region="mars")
        self.assertEqual((status, data["error"]), (400, "invalid_region"))

    def test_same_key_cannot_register_twice(self):
        mac = self.joined("first")
        mac.device_id = None
        status, data = mac.register("second")
        self.assertEqual((status, data["error"]), (409, "key_registered"))

    def test_signature_checks(self):
        mac = self.joined("signer")
        self.assertEqual(mac.call("GET", "/me")[0], 200)

        status, data, _ = mac.call("PUT", "/profile", {"bio": "sent"}, signed_body=b'{"bio": "signed"}')
        self.assertEqual((status, data["error"]), (401, "invalid_signature"))

        status, data, _ = mac.call("GET", "/me", key=ec.generate_private_key(ec.SECP256R1()))
        self.assertEqual((status, data["error"]), (401, "invalid_signature"))

        status, data, _ = mac.call("GET", "/me", timestamp=NOW - 301)
        self.assertEqual((status, data["error"]), (401, "timestamp_skew"))
        self.assertEqual(mac.call("GET", "/me", timestamp=NOW + 299)[0], 200)

        nonce = b64url(secrets.token_bytes(16))
        self.assertEqual(mac.call("GET", "/me", nonce=nonce)[0], 200)
        status, data, _ = mac.call("GET", "/me", nonce=nonce)
        self.assertEqual((status, data["error"]), (401, "nonce_reused"))

        status, data, _ = mac.call("GET", "/me", nonce=base64.urlsafe_b64encode(secrets.token_bytes(16)).decode())
        self.assertEqual((status, data["error"]), (401, "invalid_nonce"))

        headers = {"X-Quota-Timestamp": str(NOW), "X-Quota-Nonce": b64url(secrets.token_bytes(16)),
                   "X-Quota-Signature": "AAAA"}
        status, data, _ = self.http("GET", "/me", headers=headers)
        self.assertEqual((status, data["error"]), (401, "missing_device"))
        mac.device_id = "not-a-device"
        status, data, _ = mac.call("GET", "/me")
        self.assertEqual((status, data["error"]), (401, "unknown_device"))

    def test_register_signature_uses_body_public_key(self):
        mac = Mac(self)
        impostor = ec.generate_private_key(ec.SECP256R1())
        status, data, _ = mac.call("POST", "/register", {
            "username": "impostor", "region": "global", "publicKey": mac.public_key, "deviceName": "Mac",
            "platform": "macos", "appVersion": "1"}, key=impostor)
        self.assertEqual((status, data["error"]), (401, "invalid_signature"))

    def test_ranked_switch_has_seven_day_cooldown(self):
        first = self.joined("switcher")
        second = self.paired(first)
        status, data, _ = second.call("POST", "/devices/ranked", {"deviceId": second.device_id})
        self.assertEqual(status, 200, data)
        self.assertEqual([d["ranked"] for d in data["devices"]], [False, True])
        self.assertEqual(data["rankedChangeAvailableAt"], NOW + 7 * DAY)

        status, data, _ = first.call("POST", "/devices/ranked", {"deviceId": first.device_id})
        self.assertEqual((status, data["error"], data["availableAt"]), (409, "cooldown", NOW + 7 * DAY))
        _, me, _ = first.call("GET", "/me")
        self.assertEqual(me["rankedChangeAvailableAt"], NOW + 7 * DAY)
        # 已经是计分设备时再设一次不算更换
        self.assertEqual(second.call("POST", "/devices/ranked", {"deviceId": second.device_id})[0], 200)

        self.clock.advance(7 * DAY - 1)
        self.assertEqual(first.call("POST", "/devices/ranked", {"deviceId": first.device_id})[0], 409)
        self.clock.advance(1)
        status, data, _ = first.call("POST", "/devices/ranked", {"deviceId": first.device_id})
        self.assertEqual(status, 200, data)
        self.assertEqual([d["ranked"] for d in data["devices"]], [True, False])

        status, data, _ = first.call("POST", "/devices/ranked", {"deviceId": "nope"})
        self.assertEqual((status, data["error"]), (404, "device_not_found"))

    def test_remove_device(self):
        first = self.joined("remover")
        second = self.paired(first)
        status, data, _ = first.call("DELETE", f"/devices/{first.device_id}")
        self.assertEqual((status, data["error"]), (409, "current_device"))
        status, data, _ = second.call("DELETE", f"/devices/{first.device_id}")
        self.assertEqual((status, data["error"]), (409, "ranked_device"))
        status, data, _ = first.call("DELETE", f"/devices/{second.device_id}")
        self.assertEqual(status, 200, data)
        self.assertEqual(len(data["devices"]), 1)
        self.assertEqual(second.call("GET", "/me")[1]["error"], "unknown_device")


class DefaultConfigurationTests(ServerTestCase):
    """什么都没配置时（线上默认）：没有 register、没有 dev 登录、各登录方式都关着。"""

    def service_options(self):
        return {}

    def test_register_and_pairing_are_gone(self):
        status, data = Mac(self).register("someone")
        self.assertEqual((status, data["error"]), (404, "not_found"))
        mac = Mac(self)
        self.assertEqual(mac.call("POST", "/pair")[0], 404)
        status, data, _ = self.http("POST", "/auth/dev", json.dumps({"email": "a@example.com"}).encode(),
                                    {"Origin": run_server.DEFAULT_ORIGIN})
        self.assertEqual((status, data["error"]), (404, "not_found"))

    def test_providers_and_email_unavailable(self):
        self.assertEqual(self.get("/auth/providers"), (200, {"google": False, "github": False, "email": False}))
        browser = Browser(self, origin=run_server.DEFAULT_ORIGIN)
        status, data, _ = browser.call("POST", "/auth/email/start", {"email": "a@example.com", "lang": "en"})
        self.assertEqual((status, data["error"]), (503, "email_unavailable"))
        for provider in ("github", "google"):
            url, params = self.oauth_start(browser, provider, next="/zh/account")
            self.assertEqual(url, "https://quota.run/zh/login")
            self.assertEqual(params, {"error": "provider_unavailable", "next": "/zh/account"})

    def test_dev_login_needs_a_local_origin(self):
        # 线上同样只监听 127.0.0.1：误开 QUOTA_RUN_DEV_LOGIN 时，站点来源不是本机地址也不生效
        self.service.dev_login = True
        self.assertFalse(self.service.dev_login_enabled())
        status, _, _ = self.http("POST", "/auth/dev", json.dumps({"email": "a@example.com"}).encode(),
                                 {"Origin": run_server.DEFAULT_ORIGIN})
        self.assertEqual(status, 404)
        self.service.settings = run_server.Settings(origin="http://127.0.0.1:5173")
        self.assertTrue(self.service.dev_login_enabled())
        self.service.listen_host = "0.0.0.0"
        self.assertFalse(self.service.dev_login_enabled())

    def test_settings_from_environment(self):
        settings = run_server.Settings.from_env({
            "QUOTA_RUN_ORIGIN": "http://localhost:3000/", "QUOTA_RUN_GITHUB_CLIENT_ID": "gh-id-value",
            "QUOTA_RUN_GITHUB_CLIENT_SECRET": "gh-secret-value", "QUOTA_RUN_GOOGLE_CLIENT_ID": "g",
            "QUOTA_RUN_SMTP_PASSWORD": "smtp-password-value",
            "QUOTA_RUN_SMTP_HOST": "smtp.example.com", "QUOTA_RUN_SMTP_PORT": "465",
            "QUOTA_RUN_MAIL_FROM": "Quota Run <codes@example.com>", "QUOTA_RUN_INSECURE_COOKIES": "1"})
        self.assertEqual(settings.origin, "http://localhost:3000")
        self.assertEqual((settings.github, settings.google, settings.email), (True, False, True))
        self.assertEqual((settings.smtp_port, settings.insecure_cookies), (465, True))
        for secret in ("gh-id-value", "gh-secret-value", "smtp-password-value"):
            self.assertNotIn(secret, repr(settings))
        defaults = run_server.Settings.from_env({})
        self.assertEqual((defaults.origin, defaults.insecure_cookies, defaults.email), ("https://quota.run", False, False))


class ConnectTests(ServerTestCase):
    def test_connect_happy_path(self):
        browser = self.account("connector")
        mac = Mac(self)
        status, start, _ = mac.start_connect("Studio", lang="zh")
        self.assertEqual(status, 201, start)
        self.assertRegex(start["userCode"], r"^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{4}-[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{4}$")
        self.assertEqual(start["verifyURL"], f"{ORIGIN}/zh/connect?code={start['userCode']}")
        self.assertEqual((start["expiresAt"], start["interval"]), (NOW + 600, 3))
        self.assertEqual(mac.poll(start["requestId"])[1], {"status": "pending"})

        typed = start["userCode"].lower().replace("-", "%20")
        status, info, headers = browser.call("GET", f"/connect/{typed}")
        self.assertEqual(status, 200, info)
        self.assertEqual(headers["cache-control"], "no-store")
        self.assertEqual(info, {"userCode": start["userCode"], "deviceName": "Studio", "platform": "macos",
                                "appVersion": "0.6.0", "createdAt": NOW, "expiresAt": NOW + 600, "status": "pending"})

        status, data, _ = browser.call("POST", f"/connect/{start['userCode']}/approve")
        self.assertEqual((status, data), (200, {"deviceName": "Studio", "ranked": True}))
        for _ in range(2):  # 批准后重复轮询仍然拿到同样的结果
            status, poll, _ = mac.poll(start["requestId"])
            self.assertEqual(status, 200)
            self.assertEqual(poll, {"status": "approved", "deviceId": poll["deviceId"], "ranked": True,
                                    "user": {"username": "connector", "displayName": "Connector", "region": "global"}})
        mac.device_id = poll["deviceId"]
        _, me, _ = mac.call("GET", "/me")
        self.assertEqual(me["devices"], [{"deviceId": mac.device_id, "name": "Studio", "ranked": True,
                                          "lastSeenAt": NOW, "current": True, "appVersion": "0.6.0"}])
        self.assertEqual(browser.call("GET", f"/connect/{start['userCode']}")[1]["status"], "approved")

        # 码只能用一次
        for action in ("approve", "deny"):
            status, data, _ = browser.call("POST", f"/connect/{start['userCode']}/{action}")
            self.assertEqual((status, data["error"]), (409, "connect_code_used"))
        # 已经连上的钥匙不能再开始
        mac.device_id = None
        status, data, _ = mac.start_connect()
        self.assertEqual((status, data["error"]), (409, "key_registered"))

        # 第二台 Mac 不是计分设备；英文界面的链接没有 /zh
        second = Mac(self)
        _, start, _ = second.start_connect("Air")
        self.assertEqual(start["verifyURL"], f"{ORIGIN}/connect?code={start['userCode']}")
        status, data, _ = browser.call("POST", f"/connect/{start['userCode']}/approve")
        self.assertEqual((status, data), (200, {"deviceName": "Air", "ranked": False}))
        self.assertFalse(second.poll(start["requestId"])[1]["ranked"])

    def test_connect_denied(self):
        browser = self.account("denier")
        mac = Mac(self)
        _, start, _ = mac.start_connect()
        status, data, _ = browser.call("POST", f"/connect/{start['userCode']}/deny")
        self.assertEqual((status, data), (200, {"status": "denied"}))
        self.assertEqual(mac.poll(start["requestId"])[1], {"status": "denied"})
        status, data, _ = browser.call("POST", f"/connect/{start['userCode']}/approve")
        self.assertEqual((status, data["error"]), (409, "connect_code_used"))
        self.assertEqual(self.query("SELECT COUNT(*) FROM devices")[0][0], 0)

    def test_connect_expires(self):
        browser = self.account("latecomer")
        mac = Mac(self)
        _, start, _ = mac.start_connect()
        self.clock.advance(600)
        self.assertEqual(mac.poll(start["requestId"])[1], {"status": "expired"})
        self.assertEqual(browser.call("GET", f"/connect/{start['userCode']}")[1]["status"], "expired")
        status, data, _ = browser.call("POST", f"/connect/{start['userCode']}/approve")
        self.assertEqual((status, data["error"]), (404, "connect_code_invalid"))
        # 过了宽限期整行清掉
        self.clock.advance(601)
        status, data, _ = mac.poll(start["requestId"])
        self.assertEqual((status, data["error"]), (404, "connect_request_invalid"))
        status, data, _ = browser.call("GET", f"/connect/{start['userCode']}")
        self.assertEqual((status, data["error"]), (404, "connect_code_invalid"))
        self.assertEqual(self.query("SELECT COUNT(*) FROM connect_requests")[0][0], 0)

    def test_poll_is_bound_to_the_key(self):
        browser = self.account("keyholder")
        mac = Mac(self)
        _, start, _ = mac.start_connect()
        browser.call("POST", f"/connect/{start['userCode']}/approve")

        thief = Mac(self)
        status, data, _ = thief.poll(start["requestId"])
        self.assertEqual((status, data["error"]), (404, "connect_request_invalid"))
        status, data, _ = thief.call("POST", "/connect/poll", {"requestId": start["requestId"],
                                                               "publicKey": mac.public_key})
        self.assertEqual((status, data["error"]), (401, "invalid_signature"))
        status, data, _ = mac.poll("no-such-request")
        self.assertEqual((status, data["error"]), (404, "connect_request_invalid"))
        nonce = b64url(secrets.token_bytes(16))
        body = {"requestId": start["requestId"], "publicKey": mac.public_key}
        self.assertEqual(mac.call("POST", "/connect/poll", body, nonce=nonce)[0], 200)
        status, data, _ = mac.call("POST", "/connect/poll", body, nonce=nonce)
        self.assertEqual((status, data["error"]), (401, "nonce_reused"))

    def test_restarting_replaces_the_old_code(self):
        browser = self.account("restarter")
        mac = Mac(self)
        _, first, _ = mac.start_connect()
        _, second, _ = mac.start_connect()
        self.assertNotEqual(first["userCode"], second["userCode"])
        status, data, _ = browser.call("POST", f"/connect/{first['userCode']}/approve")
        self.assertEqual((status, data["error"]), (404, "connect_code_invalid"))
        self.assertEqual(browser.call("POST", f"/connect/{second['userCode']}/approve")[0], 200)

    def test_connect_page_needs_an_account_session(self):
        mac = Mac(self)
        _, start, _ = mac.start_connect()
        code = start["userCode"]
        anonymous = Browser(self)
        for method, route in (("GET", f"/connect/{code}"), ("POST", f"/connect/{code}/approve"),
                              ("POST", f"/connect/{code}/deny")):
            status, data, _ = anonymous.call(method, route)
            self.assertEqual((status, data["error"]), (401, "not_signed_in"), route)
        pending = self.signed_in("pending@example.com")
        status, data, _ = pending.call("POST", f"/connect/{code}/approve")
        self.assertEqual((status, data["error"]), (403, "needs_signup"))
        browser = self.account("approver")
        status, data, _ = browser.call("POST", f"/connect/{code}/approve", origin="https://evil.example")
        self.assertEqual((status, data["error"]), (403, "bad_origin"))
        status, data, _ = browser.call("GET", "/connect/ABCD-EFG1")
        self.assertEqual((status, data["error"]), (404, "connect_code_invalid"))
        self.assertEqual(mac.poll(start["requestId"])[1], {"status": "pending"})

    def test_connect_start_validation(self):
        mac = Mac(self)
        status, data, _ = mac.call("POST", "/connect/start", {
            "publicKey": mac.public_key, "deviceName": "Mac", "platform": "macos", "appVersion": "1"},
            key=ec.generate_private_key(ec.SECP256R1()))
        self.assertEqual((status, data["error"]), (401, "invalid_signature"))
        status, data, _ = mac.start_connect(platform="windows")
        self.assertEqual((status, data["error"]), (400, "invalid_platform"))
        status, data, _ = mac.start_connect("n" * 61)
        self.assertEqual((status, data["error"]), (400, "invalid_device"))
        status, data, _ = mac.call("POST", "/connect/start", {"publicKey": "AAAA", "platform": "macos"})
        self.assertEqual((status, data["error"]), (400, "invalid_public_key"))
        self.service.limits["register"] = (2, 10.0)
        self.assertEqual(Mac(self).start_connect()[0], 201)
        self.assertEqual(Mac(self).start_connect()[0], 201)
        self.assertEqual(Mac(self).start_connect()[0], 429)


class SessionTests(ServerTestCase):
    def test_cookie_flags_and_sliding_expiry(self):
        browser = Browser(self)
        status, data, headers = browser.call("POST", "/auth/dev", {"email": "Slider@Example.com"})
        self.assertEqual((status, data), (200, {"signedIn": True, "needsSignup": True}))
        self.assertEqual(headers["cache-control"], "no-store")
        line = cookie_line(headers, "qr_session")
        self.assertRegex(line, r"^qr_session=[A-Za-z0-9_-]{43}; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=2592000$")
        token = browser.cookie("qr_session")
        stored = self.query("SELECT token_hash, expires_at FROM sessions")
        self.assertEqual(stored, [(hashlib.sha256(token.encode()).hexdigest(), NOW + 30 * DAY)])
        self.assertNotIn(token, self.dump())

        self.clock.advance(DAY - 1)
        _, data, headers = browser.call("GET", "/session")
        self.assertTrue(data["signedIn"])
        self.assertEqual(headers.set_cookies, [])
        self.clock.advance(1)
        _, _, headers = browser.call("GET", "/session")
        self.assertEqual(cookie_line(headers, "qr_session"), line)
        self.assertEqual(self.query("SELECT expires_at FROM sessions")[0][0], NOW + DAY + 30 * DAY)

        self.clock.advance(30 * DAY)
        status, data, headers = browser.call("GET", "/session")
        self.assertEqual((status, data["signedIn"]), (200, False))
        self.assertTrue(cookie_line(headers, "qr_session").endswith("Max-Age=0"))
        self.assertIsNone(browser.cookie("qr_session"))
        status, data, _ = browser.call("GET", "/me")
        self.assertEqual((status, data["error"]), (401, "not_signed_in"))

    def test_insecure_cookies_for_local_http(self):
        self.service.settings.insecure_cookies = True
        _, _, headers = Browser(self).call("POST", "/auth/dev", {"email": "local@example.com"})
        self.assertRegex(cookie_line(headers, "qr_session"), r"; Path=/; HttpOnly; SameSite=Lax; Max-Age=2592000$")

    def test_origin_is_checked_on_session_writes(self):
        browser = self.account("origin")
        for origin in (None, "https://evil.example", "https://quota.run", ORIGIN + "/"):
            status, data, _ = browser.call("PUT", "/profile", {"bio": "x"}, origin=origin)
            self.assertEqual((status, data["error"]), (403, "bad_origin"), origin)
        self.assertEqual(browser.call("PUT", "/profile", {"bio": "x"})[0], 200)
        self.assertEqual(browser.call("GET", "/me", origin=None)[0], 200)
        for method, route, body in (("POST", "/auth/logout", None), ("POST", "/signup", {}),
                                    ("POST", "/auth/email/start", {"email": "a@example.com"}),
                                    ("POST", "/auth/email/verify", {"email": "a@example.com", "code": "123456"}),
                                    ("POST", "/auth/dev", {"email": "a@example.com"}),
                                    ("DELETE", "/account", None)):
            status, data, _ = browser.call(method, route, body, origin="https://evil.example")
            self.assertEqual((status, data["error"]), (403, "bad_origin"), route)
        self.assertEqual(browser.call("GET", "/me")[0], 200)

    def test_needs_signup_gating(self):
        browser = self.signed_in("newcomer@example.com")
        for method, route, body in (("GET", "/me", None), ("PUT", "/profile", {"bio": "x"}),
                                    ("PUT", "/projects", {"projects": []}), ("POST", "/devices/ranked", {"deviceId": "x"}),
                                    ("DELETE", "/devices/abc", None), ("DELETE", "/account", None),
                                    ("DELETE", "/identities/abc", None), ("GET", "/connect/ABCD-EFGH", None)):
            status, data, _ = browser.call(method, route, body)
            self.assertEqual((status, data["error"]), (403, "needs_signup"), route)
        status, data, _ = browser.call("GET", "/session")
        self.assertEqual((status, data), (200, {
            "signedIn": True, "needsSignup": True,
            "identity": {"provider": "email", "email": "newcomer@example.com", "name": None},
            "user": None, "suggestedUsername": "newcomer", "suggestedDisplayName": "newcomer"}))
        self.assertEqual(browser.call("GET", "/usernames/newcomer")[1], {"available": True, "reason": None})

        anonymous = Browser(self)
        for method, route in (("GET", "/me"), ("PUT", "/profile"), ("POST", "/signup"), ("DELETE", "/account")):
            status, data, _ = anonymous.call(method, route, {})
            self.assertEqual((status, data["error"]), (401, "not_signed_in"), route)
        self.assertEqual(anonymous.call("GET", "/session")[1]["signedIn"], False)

        status, data, _ = browser.call("POST", "/signup", {"username": "newcomer", "displayName": "", "region": "china"})
        self.assertEqual(status, 201, data)
        self.assertEqual(data["user"], {"username": "newcomer", "displayName": "newcomer", "bio": "", "region": "china",
                                        "links": dict.fromkeys(run_server.LINK_KINDS), "joinedAt": NOW,
                                        "timezone": None, "showActivity": True, "showGithub": True})
        self.assertEqual(browser.call("GET", "/me")[0], 200)
        _, data, _ = browser.call("GET", "/session")
        self.assertEqual((data["needsSignup"], data["user"], data["suggestedUsername"]),
                         (False, {"username": "newcomer", "displayName": "newcomer", "region": "china"}, None))
        self.assertEqual(self.get("/users/newcomer")[0], 200)

    def test_logout(self):
        browser = self.account("leaving")
        status, data, headers = browser.call("POST", "/auth/logout")
        self.assertEqual((status, data), (204, None))
        self.assertTrue(cookie_line(headers, "qr_session").endswith("Max-Age=0"))
        self.assertEqual(self.query("SELECT COUNT(*) FROM sessions")[0][0], 0)
        self.assertEqual(browser.call("GET", "/me")[1]["error"], "not_signed_in")
        self.assertEqual(browser.call("POST", "/auth/logout")[0], 204)  # 没登录也可以登出

    def test_early_prefix_carries_the_session(self):
        browser = self.account("prefixed")
        status, data, _ = browser.call("GET", "/me", prefix="/api/run/v1")
        self.assertEqual((status, data["user"]["username"]), (200, "prefixed"))


class SignupTests(ServerTestCase):
    def test_username_availability(self):
        self.account("taken1")
        cases = {"fresh-name": None, "ab": "invalid", "-abc": "invalid", "a" * 21: "invalid", "has%20space": "invalid",
                 "Admin": "reserved", "connect": "reserved", "auth": "reserved", "account": "reserved",
                 "TAKEN1": "taken", "@taken1": "taken"}
        for name, reason in cases.items():
            status, data, headers = self.http("GET", f"/usernames/{name}")
            self.assertEqual((status, data), (200, {"available": reason is None, "reason": reason}), name)
            self.assertEqual(headers["cache-control"], "no-store")
        self.service.limits["lookup"] = (2, 10.0)
        self.assertEqual(self.get("/usernames/one-more")[0], 200)
        self.assertEqual(self.get("/usernames/two-more")[0], 200)
        status, data = self.get("/usernames/three-more")
        self.assertEqual((status, data["error"]), (429, "rate_limited"))

    def test_signup_validation(self):
        self.account("occupied")
        browser = self.signed_in("joiner@example.com")
        for body, expected in (
                ({"username": "no", "region": "global"}, (400, "invalid_username")),
                ({"username": "support", "region": "global"}, (400, "invalid_username")),
                ({"username": "joiner", "region": "mars"}, (400, "invalid_region")),
                ({"username": "joiner", "region": "global", "displayName": "d" * 41}, (400, "invalid_display_name")),
                ({"username": "Occupied", "region": "global"}, (409, "username_taken"))):
            status, data, _ = browser.call("POST", "/signup", body)
            self.assertEqual((status, data["error"]), expected, body)
        status, data, _ = browser.call("POST", "/signup", {"username": "Joiner", "displayName": "J", "region": "global"})
        self.assertEqual((status, data["user"]["username"]), (201, "joiner"))
        status, data, _ = browser.call("POST", "/signup", {"username": "joiner2", "region": "global"})
        self.assertEqual((status, data["error"]), (409, "already_signed_up"))
        self.assertEqual(self.query("SELECT COUNT(*) FROM users")[0][0], 2)

    def test_suggested_username(self):
        def suggestion(email):
            return self.signed_in(email).call("GET", "/session")[1]["suggestedUsername"]

        self.assertEqual(suggestion("Peter.Tang+quota@example.com"), "peter-tang")
        self.account("peter-tang", email="peter@example.org")
        self.assertEqual(suggestion("peter.tang@example.net"), "peter-tang2")
        self.assertEqual(suggestion("ab@example.com"), "ab-run")
        self.assertEqual(suggestion("admin@example.com"), "admin2")
        self.assertEqual(suggestion("__@example.com"), "runner")


class EmailTests(ServerTestCase):
    def test_email_sign_in(self):
        browser = Browser(self)
        status, data, headers = browser.call("POST", "/auth/email/start", {"email": " Person@Example.com ", "lang": "en"})
        self.assertEqual((status, data), (202, {"sent": True, "expiresAt": NOW + 600}))
        self.assertEqual(headers.set_cookies, [])
        to, subject, text = self.mailer.sent[-1]
        code = self.mailer.code()
        self.assertEqual((to, subject), ("person@example.com", f"Your Quota Run code: {code}"))
        self.assertIn(code, text)
        self.assertIn("10 minutes", text)
        self.assertNotIn("http", text)
        expected = run_server.hmac.new(self.service.secret, f"person@example.com{code}".encode(), hashlib.sha256).hexdigest()
        self.assertEqual(self.query("SELECT code_hmac, attempts FROM email_codes"), [(expected, 0)])

        status, data, headers = browser.call("POST", "/auth/email/verify", {"email": "person@example.com", "code": code})
        self.assertEqual((status, data), (200, {"signedIn": True, "needsSignup": True}))
        self.assertIsNotNone(cookie_line(headers, "qr_session"))
        self.assertEqual(self.query("SELECT COUNT(*) FROM email_codes")[0][0], 0)
        self.assertEqual(self.query("SELECT provider, subject, email, email_verified FROM identities"),
                         [("email", "person@example.com", "person@example.com", 1)])
        # 码只能用一次
        status, data, _ = Browser(self).call("POST", "/auth/email/verify", {"email": "person@example.com", "code": code})
        self.assertEqual((status, data["error"]), (400, "code_invalid"))

        # 同一个地址再登录是同一个身份；中文邮件
        self.clock.advance(60)
        again = Browser(self)
        again.call("POST", "/auth/email/start", {"email": "person@example.com", "lang": "zh"})
        _, subject, text = self.mailer.sent[-1]
        self.assertEqual(subject, f"Quota Run 验证码：{self.mailer.code()}")
        self.assertIn("10 分钟", text)
        self.assertEqual(again.call("POST", "/auth/email/verify",
                                    {"email": "person@example.com", "code": self.mailer.code()})[0], 200)
        self.assertEqual(self.query("SELECT COUNT(*) FROM identities")[0][0], 1)
        self.assertEqual(self.query("SELECT COUNT(*) FROM sessions")[0][0], 2)

    def test_wrong_codes_then_too_many_attempts(self):
        browser = Browser(self)
        browser.call("POST", "/auth/email/start", {"email": "guess@example.com", "lang": "en"})
        code = self.mailer.code()
        wrong = f"{(int(code) + 1) % 1_000_000:06d}"
        for attempt in (wrong, wrong, "abc", "", wrong):
            status, data, _ = browser.call("POST", "/auth/email/verify", {"email": "guess@example.com", "code": attempt})
            self.assertEqual((status, data["error"]), (400, "code_invalid"))
        status, data, _ = browser.call("POST", "/auth/email/verify", {"email": "guess@example.com", "code": code})
        self.assertEqual((status, data["error"]), (429, "too_many_attempts"))
        # 新码重新计数
        self.clock.advance(60)
        browser.call("POST", "/auth/email/start", {"email": "guess@example.com", "lang": "en"})
        status, data, _ = browser.call("POST", "/auth/email/verify",
                                       {"email": "guess@example.com", "code": self.mailer.code()[:3] + " " + self.mailer.code()[3:]})
        self.assertEqual(status, 200, data)

    def test_codes_expire_and_are_replaced(self):
        browser = Browser(self)
        browser.call("POST", "/auth/email/start", {"email": "slow@example.com", "lang": "en"})
        old = self.mailer.code()
        self.clock.advance(600)
        status, data, _ = browser.call("POST", "/auth/email/verify", {"email": "slow@example.com", "code": old})
        self.assertEqual((status, data["error"]), (400, "code_expired"))
        status, data, _ = browser.call("POST", "/auth/email/verify", {"email": "nobody@example.com", "code": old})
        self.assertEqual((status, data["error"]), (400, "code_invalid"))

        browser.call("POST", "/auth/email/start", {"email": "slow@example.com", "lang": "en"})
        first = self.mailer.code()
        self.clock.advance(60)
        browser.call("POST", "/auth/email/start", {"email": "slow@example.com", "lang": "en"})
        second = self.mailer.code()
        if first != second:
            status, data, _ = browser.call("POST", "/auth/email/verify", {"email": "slow@example.com", "code": first})
            self.assertEqual((status, data["error"]), (400, "code_invalid"))
        self.assertEqual(browser.call("POST", "/auth/email/verify", {"email": "slow@example.com", "code": second})[0], 200)

    def test_rate_limits(self):
        browser = Browser(self)
        start = {"email": "busy@example.com", "lang": "en"}
        self.assertEqual(browser.call("POST", "/auth/email/start", start)[0], 202)
        status, data, headers = browser.call("POST", "/auth/email/start", start)
        self.assertEqual((status, data["error"], data["retryAfter"], headers["retry-after"]),
                         (429, "rate_limited", 60, "60"))
        for _ in range(5):
            self.clock.advance(60)
            self.assertEqual(browser.call("POST", "/auth/email/start", start)[0], 202)
        self.clock.advance(60)
        status, data, _ = browser.call("POST", "/auth/email/start", start)
        self.assertEqual((status, data["retryAfter"]), (429, 3600 - 360))
        self.assertEqual(len(self.mailer.sent), 6)

        self.clock.advance(3600)
        for index in range(20):
            status, data, _ = browser.call("POST", "/auth/email/start", {"email": f"p{index}@example.com"})
            self.assertEqual(status, 202, (index, data))
        status, data, _ = browser.call("POST", "/auth/email/start", {"email": "p20@example.com"})
        self.assertEqual((status, data["error"]), (429, "rate_limited"))
        other_ip = Browser(self, ip="203.0.113.9")
        self.assertEqual(other_ip.call("POST", "/auth/email/start", {"email": "p20@example.com"})[0], 202)

    def test_invalid_email_and_unavailable(self):
        browser = Browser(self)
        for email in ("nope", "a@b", "x" * 250 + "@example.com", "a b@example.com", "a@example.com\nBcc: x@y.z", None):
            status, data, _ = browser.call("POST", "/auth/email/start", {"email": email, "lang": "en"})
            self.assertEqual((status, data["error"]), (400, "invalid_email"), email)
        self.assertEqual(self.mailer.sent, [])
        self.assertTrue(self.get("/auth/providers")[1]["email"])
        self.service.mailer = None
        status, data, _ = browser.call("POST", "/auth/email/start", {"email": "a@example.com", "lang": "en"})
        self.assertEqual((status, data["error"]), (503, "email_unavailable"))
        self.assertEqual(self.get("/auth/providers")[1], {"google": True, "github": True, "email": False})

    def test_link_an_email_to_the_account(self):
        browser = self.account("linker")
        status, data, _ = browser.call("POST", "/auth/email/start",
                                       {"email": "work@example.com", "lang": "en", "link": True})
        self.assertEqual(status, 202, data)
        status, data, headers = browser.call("POST", "/auth/email/verify",
                                             {"email": "work@example.com", "code": self.mailer.code()})
        self.assertEqual((status, data), (200, {"linked": True}))
        self.assertIsNone(cookie_line(headers, "qr_session"))
        _, me, _ = browser.call("GET", "/me")
        self.assertEqual([(i["provider"], i["email"]) for i in me["identities"]],
                         [("email", "linker@example.com"), ("email", "work@example.com")])
        # 以后用这个地址登录就是这个账号
        other = self.signed_in("work@example.com")
        self.assertEqual(other.call("GET", "/me")[1]["user"]["username"], "linker")

        # 已经属于别的账号的地址不能关联
        self.account("someone")
        browser.call("POST", "/auth/email/start", {"email": "someone@example.com", "lang": "en", "link": True})
        status, data, _ = browser.call("POST", "/auth/email/verify",
                                       {"email": "someone@example.com", "code": self.mailer.code()})
        self.assertEqual((status, data["error"]), (409, "identity_in_use"))

        # 关联要登录；换个浏览器验证就是普通登录，不会关联到发起的账号上
        status, data, _ = Browser(self).call("POST", "/auth/email/start",
                                             {"email": "x@example.com", "lang": "en", "link": True})
        self.assertEqual((status, data["error"]), (401, "not_signed_in"))
        browser.call("POST", "/auth/email/start", {"email": "stolen@example.com", "lang": "en", "link": True})
        status, data, _ = Browser(self).call("POST", "/auth/email/verify",
                                             {"email": "stolen@example.com", "code": self.mailer.code()})
        self.assertEqual((status, data), (200, {"signedIn": True, "needsSignup": True}))
        self.assertEqual(len(browser.call("GET", "/me")[1]["identities"]), 2)


class OAuthTests(ServerTestCase):
    def test_github_sign_in_and_sign_up(self):
        browser = Browser(self)
        url, params = self.oauth_start(browser, "github", next="/zh/account")
        self.assertEqual(url, run_server.GITHUB_AUTHORIZE_URL)
        self.assertEqual({k: v for k, v in params.items() if k not in ("state", "code_challenge")}, {
            "client_id": "gh-client", "redirect_uri": f"{ORIGIN}/api/v1/auth/github/callback",
            "scope": "read:user user:email", "code_challenge_method": "S256"})
        state = params["state"]
        self.assertEqual(browser.cookie("qr_oauth"), state)
        self.assertEqual(browser.jar["qr_oauth"][1], "/api/v1/auth")
        self.assertNotIn(state, self.dump())

        status, _, headers = browser.call("GET", "/auth/github/callback", query={"code": "the-provider-code", "state": state})
        self.assertEqual(status, 302)
        self.assertEqual(headers["location"], f"{ORIGIN}/zh/login?next=%2Fzh%2Faccount")
        self.assertEqual(headers["cache-control"], "no-store")
        self.assertRegex(cookie_line(headers, "qr_oauth"),
                         r"^qr_oauth=; Path=/api/v1/auth; HttpOnly; Secure; SameSite=Lax; Max-Age=0$")
        self.assertIsNotNone(browser.cookie("qr_session"))

        form = self.providers.forms(run_server.GITHUB_TOKEN_URL)[0]
        self.assertEqual({k: v for k, v in form.items() if k != "code_verifier"}, {
            "client_id": "gh-client", "client_secret": GITHUB_SECRET, "code": "the-provider-code",
            "redirect_uri": f"{ORIGIN}/api/v1/auth/github/callback"})
        self.assertEqual(b64url(hashlib.sha256(form["code_verifier"].encode()).digest()), params["code_challenge"])
        self.assertEqual(self.providers.calls[0]["headers"]["Accept"], "application/json")

        _, session, _ = browser.call("GET", "/session")
        self.assertEqual(session, {
            "signedIn": True, "needsSignup": True,
            "identity": {"provider": "github", "email": "octo@example.com", "name": "Octo Cat"},
            "user": None, "suggestedUsername": "octo-cat", "suggestedDisplayName": "Octo Cat"})
        status, data, _ = browser.call("POST", "/signup", {"username": "octo-cat", "displayName": "Octo", "region": "global"})
        self.assertEqual(status, 201, data)

        # 第二次登录直接回到 next
        again = Browser(self)
        _, params = self.oauth_start(again, "github")
        url, query = self.oauth_callback(again, "github", params["state"])
        self.assertEqual((url, query), (f"{ORIGIN}/account", {}))
        _, me, _ = again.call("GET", "/me")
        self.assertEqual(me["user"]["username"], "octo-cat")
        self.assertEqual([(i["provider"], i["email"], i["name"]) for i in me["identities"]],
                         [("github", "octo@example.com", "Octo Cat")])
        self.assertEqual(self.query("SELECT subject, login FROM identities"), [("101", "Octo-Cat")])

        text = self.dump()
        for secret in (FakeProviders.GITHUB_TOKEN, GITHUB_SECRET, "the-provider-code", params["state"]):
            self.assertNotIn(secret, text)
        self.assertEqual(self.query("SELECT COUNT(*) FROM oauth_states")[0][0], 0)

    def test_state_must_match_the_cookie(self):
        browser = Browser(self)
        _, params = self.oauth_start(browser, "github", next="/account")
        url, query = self.oauth_callback(browser, "github", "not-the-state")
        self.assertEqual((url, query), (f"{ORIGIN}/login", {"error": "oauth_state", "next": "/account"}))

        # 另一个浏览器（没有 qr_oauth cookie）拿着真的 state 也不行，而且 state 用过即作废
        stranger = Browser(self)
        url, query = self.oauth_callback(stranger, "github", params["state"])
        self.assertEqual(query["error"], "oauth_state")
        url, query = self.oauth_callback(browser, "github", params["state"])
        self.assertEqual(query["error"], "oauth_state")

        # 过期、换了提供方
        _, params = self.oauth_start(browser, "github")
        self.clock.advance(600)
        self.assertEqual(self.oauth_callback(browser, "github", params["state"])[1]["error"], "oauth_state")
        _, params = self.oauth_start(browser, "github")
        browser.jar["qr_oauth"] = (params["state"], "/api/v1/auth")
        self.assertEqual(self.oauth_callback(browser, "google", params["state"])[1]["error"], "oauth_state")

        self.assertEqual(self.providers.calls, [])
        self.assertIsNone(browser.cookie("qr_session"))
        self.assertEqual(self.query("SELECT COUNT(*) FROM sessions")[0][0], 0)

    def test_denied_and_failed(self):
        browser = Browser(self)
        _, params = self.oauth_start(browser, "google", next="/zh/connect?code=ABCD-EFGH")
        status, _, headers = browser.call("GET", "/auth/google/callback",
                                          query={"error": "access_denied", "state": params["state"]})
        self.assertEqual(status, 302)
        url, query = location(headers)
        self.assertEqual((url, query), (f"{ORIGIN}/zh/login",
                                        {"error": "oauth_denied", "next": "/zh/connect?code=ABCD-EFGH"}))
        self.assertIsNone(browser.cookie("qr_session"))

        self.providers.token_status = 401
        _, params = self.oauth_start(browser, "github")
        self.assertEqual(self.oauth_callback(browser, "github", params["state"])[1],
                         {"error": "oauth_failed", "next": "/account"})
        self.providers.token_status = 200
        self.providers.token_error = True
        _, params = self.oauth_start(browser, "github")
        self.assertEqual(self.oauth_callback(browser, "github", params["state"])[1]["error"], "oauth_failed")
        self.providers.token_error = False
        self.providers.github_user = {"login": "no-id"}
        _, params = self.oauth_start(browser, "github")
        self.assertEqual(self.oauth_callback(browser, "github", params["state"])[1]["error"], "oauth_failed")

        # 配置被去掉后
        self.service.settings.github_client_secret = ""
        url, query = self.oauth_start(browser, "github", next="/account")
        self.assertEqual((url, query), (f"{ORIGIN}/login", {"error": "provider_unavailable", "next": "/account"}))
        self.assertFalse(self.get("/auth/providers")[1]["github"])
        self.assertIsNone(browser.cookie("qr_session"))

    def test_next_must_be_a_relative_path(self):
        browser = Browser(self)
        for unsafe in ("//evil.example", "https://evil.example/", "/\\evil.example", "account", "/a b", ""):
            _, params = self.oauth_start(browser, "github", next=unsafe)
            self.assertEqual(self.oauth_callback(browser, "github", params["state"])[0], f"{ORIGIN}/login")
            browser.jar.clear()
        self.assertEqual({row[0] for row in self.query("SELECT DISTINCT i.provider FROM identities i")}, {"github"})
        self.assertEqual(run_server.safe_next("/zh/account?tab=macs"), "/zh/account?tab=macs")
        self.assertEqual(run_server.safe_next("//evil"), "/account")

    def test_github_verified_email_links_to_existing_account(self):
        owner = self.account("octo", email="octo@example.com")
        browser = Browser(self)
        _, params = self.oauth_start(browser, "github")
        self.assertEqual(self.oauth_callback(browser, "github", params["state"])[0], f"{ORIGIN}/account")
        _, me, _ = browser.call("GET", "/me")
        self.assertEqual(me["user"]["username"], "octo")
        self.assertEqual([i["provider"] for i in owner.call("GET", "/me")[1]["identities"]], ["email", "github"])

    def test_github_unverified_email_is_not_linked(self):
        self.account("octo", email="octo@example.com")
        self.providers.github_emails = [{"email": "octo@example.com", "primary": True, "verified": False}]
        browser = Browser(self)
        _, params = self.oauth_start(browser, "github")
        self.assertEqual(self.oauth_callback(browser, "github", params["state"])[0], f"{ORIGIN}/login")
        _, session, _ = browser.call("GET", "/session")
        self.assertEqual((session["needsSignup"], session["identity"]["email"]), (True, None))

    def test_google_sign_in(self):
        self.account("gee", email="gee@example.com")
        browser = Browser(self)
        url, params = self.oauth_start(browser, "google", next="/zh/account")
        self.assertEqual(url, run_server.GOOGLE_AUTHORIZE_URL)
        self.assertEqual({k: v for k, v in params.items() if k not in ("state", "code_challenge")}, {
            "client_id": "google-client", "redirect_uri": f"{ORIGIN}/api/v1/auth/google/callback",
            "response_type": "code", "scope": "openid email profile", "code_challenge_method": "S256",
            "prompt": "select_account"})
        self.assertEqual(self.oauth_callback(browser, "google", params["state"]), (f"{ORIGIN}/zh/account", {}))
        form = self.providers.forms(run_server.GOOGLE_TOKEN_URL)[0]
        self.assertEqual((form["grant_type"], form["client_secret"], form["code"]),
                         ("authorization_code", GOOGLE_SECRET, "the-provider-code"))
        self.assertEqual(b64url(hashlib.sha256(form["code_verifier"].encode()).digest()), params["code_challenge"])
        _, me, _ = browser.call("GET", "/me")
        self.assertEqual(me["user"]["username"], "gee")
        self.assertEqual(me["identities"][1], {"id": me["identities"][1]["id"], "provider": "google",
                                               "email": "gee@example.com", "name": "Gee Gee", "login": None,
                                               "linkedAt": NOW})
        self.assertNotIn(FakeProviders.GOOGLE_TOKEN, self.dump())

    def test_google_unverified_email_is_not_linked(self):
        self.account("gee", email="gee@example.com")
        self.providers.google_user = dict(self.providers.google_user, email_verified=False)
        browser = Browser(self)
        _, params = self.oauth_start(browser, "google")
        self.assertEqual(self.oauth_callback(browser, "google", params["state"]),
                         (f"{ORIGIN}/login", {"next": "/account"}))
        _, session, _ = browser.call("GET", "/session")
        self.assertEqual((session["needsSignup"], session["identity"]["provider"], session["suggestedUsername"]),
                         (True, "google", "gee2"))
        # 注册之后，这个未验证的邮箱也不会把别人的 Google 身份自动挂过来
        self.assertEqual(self.query("SELECT email_verified FROM identities WHERE provider = 'google'"), [(0,)])

    def test_link_mode(self):
        browser = self.account("linky")
        _, params = self.oauth_start(browser, "github", link="1", next="/account")
        self.assertEqual(self.oauth_callback(browser, "github", params["state"]), (f"{ORIGIN}/account", {}))
        _, me, _ = browser.call("GET", "/me")
        self.assertEqual([i["provider"] for i in me["identities"]], ["email", "github"])
        session_count = self.query("SELECT COUNT(*) FROM sessions")[0][0]
        self.assertEqual(session_count, 1)

        # 已在别的账号上的身份
        rival = self.account("rival")
        _, params = self.oauth_start(rival, "github", link="1", next="/zh/account#methods")
        status, _, headers = rival.call("GET", "/auth/github/callback",
                                        query={"code": "the-provider-code", "state": params["state"]})
        self.assertEqual(headers["location"], f"{ORIGIN}/zh/account?error=identity_in_use#methods")
        self.assertEqual([i["provider"] for i in rival.call("GET", "/me")[1]["identities"]], ["email"])

        # 发起关联后登出，回调时会话不在了
        _, params = self.oauth_start(browser, "google", link="1")
        browser.call("POST", "/auth/logout")
        self.assertEqual(self.oauth_callback(browser, "google", params["state"])[1]["error"], "oauth_state")
        self.assertEqual(self.query("SELECT COUNT(*) FROM identities WHERE provider = 'google'")[0][0], 0)

    def test_callback_logs_leave_out_the_query(self):
        buffer = io.StringIO()
        self.server.quiet = False
        try:
            with contextlib.redirect_stderr(buffer):
                self.http("GET", "/auth/github/callback", query={"code": "log-secret-code", "state": "log-secret-state"})
        finally:
            self.server.quiet = True
        self.assertIn('"GET /api/v1/auth/github/callback" 302', buffer.getvalue())
        self.assertNotIn("log-secret", buffer.getvalue())


class SharedEndpointTests(ServerTestCase):
    def test_me_profile_and_projects_with_a_session(self):
        mac = self.joined("webby")
        browser = mac.browser
        status, me, headers = browser.call("GET", "/me")
        self.assertEqual(status, 200, me)
        self.assertEqual(headers["cache-control"], "no-store")
        self.assertEqual(me["devices"], [{"deviceId": mac.device_id, "name": "Studio", "ranked": True,
                                          "lastSeenAt": NOW, "current": False, "appVersion": "0.6.0"}])
        identity = me["identities"][0]
        self.assertEqual(identity, {"id": identity["id"], "provider": "email", "email": "webby@example.com",
                                    "name": None, "login": None, "linkedAt": NOW})
        status, data, _ = browser.call("PUT", "/profile", {"displayName": "Web By", "links": {"github": "gentpan"}})
        self.assertEqual((status, data["user"]["displayName"]), (200, "Web By"))
        status, data, _ = browser.call("PUT", "/projects", {"projects": [{"name": "Site", "url": "https://web.by"}]})
        self.assertEqual((status, len(data["projects"])), (200, 1))
        _, me, _ = mac.call("GET", "/me")
        self.assertEqual((me["user"]["displayName"], len(me["projects"]), me["devices"][0]["current"]),
                         ("Web By", 1, True))
        self.assertEqual(me["identities"], [identity])

    def test_ranked_rules_with_a_session(self):
        first = self.joined("ranker")
        browser = first.browser
        second = self.paired(first)
        status, data, _ = browser.call("POST", "/devices/ranked", {"deviceId": second.device_id})
        self.assertEqual((status, [d["ranked"] for d in data["devices"]]), (200, [False, True]))
        self.assertEqual(data["rankedChangeAvailableAt"], NOW + 7 * DAY)
        status, data, _ = browser.call("POST", "/devices/ranked", {"deviceId": first.device_id})
        self.assertEqual((status, data["error"]), (409, "cooldown"))

        # 网页会话可以删计分设备；之后账号没有计分设备，不受冷却期限制
        status, data, _ = browser.call("DELETE", f"/devices/{second.device_id}")
        self.assertEqual((status, data["devices"]), (200, [{"deviceId": first.device_id, "name": "Studio",
                                                           "ranked": False, "lastSeenAt": NOW, "current": False,
                                                           "appVersion": "0.6.0"}]))
        self.assertIsNone(browser.call("GET", "/me")[1]["rankedChangeAvailableAt"])
        status, data, _ = browser.call("POST", "/devices/ranked", {"deviceId": first.device_id})
        self.assertEqual((status, [d["ranked"] for d in data["devices"]]), (200, [True]))
        self.assertEqual(second.call("GET", "/me")[1]["error"], "unknown_device")

        # 有计分设备时再连上的 Mac 不计分；计分设备离开后再连上的计分
        third = self.connect(browser, name="Third")
        self.assertEqual(self.query("SELECT ranked FROM devices WHERE id = ?", (third.device_id,)), [(0,)])
        self.assertEqual(first.call("DELETE", "/devices/current")[0], 204)
        fourth = self.connect(browser, name="Fourth")
        self.assertEqual(self.query("SELECT ranked FROM devices WHERE id = ?", (fourth.device_id,)), [(1,)])
        self.assertEqual(self.query("SELECT COUNT(*) FROM devices WHERE ranked = 1")[0][0], 1)
        status, data, _ = browser.call("DELETE", "/devices/nope")
        self.assertEqual((status, data["error"]), (404, "device_not_found"))

    def test_disconnect_this_mac(self):
        first = self.joined("leaverer")
        second = self.paired(first)
        first.upload(series(NOW - 3600, [(0, 1), (10, 5)], digest=first.digest))
        status, data, headers = first.call("DELETE", "/devices/current")
        self.assertEqual((status, data), (204, None))
        self.assertEqual(first.call("GET", "/me")[1]["error"], "unknown_device")
        _, me, _ = second.call("GET", "/me")
        self.assertEqual(([d["deviceId"] for d in me["devices"]], me["rankedChangeAvailableAt"]),
                         ([second.device_id], None))
        self.assertEqual(self.query("SELECT COUNT(*) FROM snapshots")[0][0], 2)  # 读数留在账号上
        # 同一把钥匙可以重新连接
        first.device_id = None
        self.assertEqual(first.start_connect()[0], 201)
        # 会话没有「当前设备」
        status, data, _ = first.browser.call("DELETE", "/devices/current")
        self.assertEqual((status, data["error"]), (401, "missing_device"))

    def test_delete_account_with_a_session(self):
        mac = self.joined("goner")
        browser = mac.browser
        _, params = self.oauth_start(browser, "github", link="1")
        self.oauth_callback(browser, "github", params["state"])
        other_session = self.signed_in("goner@example.com")
        pending = Mac(self)
        _, start, _ = pending.start_connect()
        browser.call("POST", f"/connect/{start['userCode']}/deny")
        browser.call("POST", "/auth/email/start", {"email": "later@example.com", "lang": "en", "link": True})
        user_id = self.query("SELECT id FROM users WHERE username = 'goner'")[0][0]

        status, data, _ = browser.call("DELETE", "/account", origin=None)
        self.assertEqual((status, data["error"]), (403, "bad_origin"))
        status, data, headers = browser.call("DELETE", "/account")
        self.assertEqual((status, data), (204, None))
        self.assertTrue(cookie_line(headers, "qr_session").endswith("Max-Age=0"))
        for table in ("identities", "devices", "connect_requests"):
            self.assertEqual(self.query(f"SELECT COUNT(*) FROM {table} WHERE user_id = ?", (user_id,))[0][0], 0, table)
        for table in ("sessions", "email_codes", "oauth_states", "users", "identities"):
            self.assertEqual(self.query(f"SELECT COUNT(*) FROM {table}")[0][0], 0, table)
        self.assertEqual(mac.call("GET", "/me")[1]["error"], "unknown_device")
        self.assertEqual(other_session.call("GET", "/me")[1]["error"], "not_signed_in")
        self.assertEqual(self.get("/users/goner")[0], 404)

    def test_remove_sign_in_methods(self):
        browser = self.account("methods")
        _, me, _ = browser.call("GET", "/me")
        email_identity = me["identities"][0]["id"]
        status, data, _ = browser.call("DELETE", f"/identities/{email_identity}")
        self.assertEqual((status, data["error"]), (409, "last_identity"))
        status, data, _ = browser.call("DELETE", "/identities/unknown")
        self.assertEqual((status, data["error"]), (404, "identity_not_found"))

        _, params = self.oauth_start(browser, "github", link="1")
        self.oauth_callback(browser, "github", params["state"])
        stranger = self.account("stranger")
        _, stranger_me, _ = stranger.call("GET", "/me")
        status, data, _ = browser.call("DELETE", f"/identities/{stranger_me['identities'][0]['id']}")
        self.assertEqual((status, data["error"]), (404, "identity_not_found"))

        # 删掉这次登录用的邮箱：当前会话保留，用这个邮箱登录的其他会话失效
        elsewhere = self.signed_in("methods@example.com")
        status, data, _ = browser.call("DELETE", f"/identities/{email_identity}")
        self.assertEqual(status, 200, data)
        self.assertEqual([i["provider"] for i in data["identities"]], ["github"])
        self.assertEqual(browser.call("GET", "/me")[0], 200)
        self.assertEqual(browser.call("GET", "/session")[1]["identity"]["provider"], "github")
        self.assertEqual(elsewhere.call("GET", "/me")[1]["error"], "not_signed_in")
        status, data, _ = browser.call("DELETE", f"/identities/{data['identities'][0]['id']}")
        self.assertEqual((status, data["error"]), (409, "last_identity"))
        # 邮箱身份删掉以后，再用这个邮箱登录是新身份，需要注册
        self.assertTrue(self.signed_in("methods@example.com").call("GET", "/session")[1]["needsSignup"])


class PrefixTests(ServerTestCase):
    def test_the_early_prefix_still_answers(self):
        """quota.run/api/v1 is the address; the first builds used /api/run/v1 on quota.bar."""
        for prefix in run_server.API_PREFIXES:
            connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=20)
            try:
                connection.request("GET", prefix + "/stats")
                self.assertEqual(connection.getresponse().status, 200)
            finally:
                connection.close()


class SnapshotTests(ServerTestCase):
    def test_dedupe_and_validation(self):
        mac = self.joined("uploader")
        start = NOW - 4 * 3600
        good = series(start, [(0, 1), (10, 5), (20, 9)], digest=mac.digest)
        bad = [
            dict(good[0], usedPercent=120),
            dict(good[0], observedAt=NOW - 8 * DAY),
            dict(good[0], observedAt=NOW + 400),
            dict(good[0], windowKey="18000:weekly"),
            dict(good[0], source="web"),
            dict(good[0], provider="Claude!"),
            dict(good[0], accountDigest="not-hex"),
            dict(good[0], observedAt=start - 3600),
            dict(good[0], usedPercent=True),
            "not an object",
        ]
        result = mac.upload(good + [good[1]] + bad)
        self.assertEqual(result["accepted"], 3)
        self.assertEqual(result["duplicates"], 1)
        self.assertEqual(result["rejected"], [
            {"index": 4, "reason": "invalid_used_percent"},
            {"index": 5, "reason": "observed_at_out_of_range"},
            {"index": 6, "reason": "observed_at_out_of_range"},
            {"index": 7, "reason": "invalid_window_key"},
            {"index": 8, "reason": "invalid_source"},
            {"index": 9, "reason": "invalid_provider"},
            {"index": 10, "reason": "invalid_account_digest"},
            {"index": 11, "reason": "outside_window"},
            {"index": 12, "reason": "invalid_used_percent"},
            {"index": 13, "reason": "invalid_snapshot"},
        ])
        again = mac.upload(good)
        self.assertEqual((again["accepted"], again["duplicates"]), (0, 3))
        _, me, _ = mac.call("GET", "/me")
        self.assertEqual(me["lastUploadAt"], NOW)

        # 非计分窗口（没有 resetsAt 的余额）照收，但不生成 run
        balance = dict(good[0], windowKey="0:", windowSeconds=None, resetsAt=None, observedAt=NOW - 60)
        self.assertEqual(mac.upload([balance])["accepted"], 1)
        self.assertEqual(len(self.run_tiers()), 1)

        status, data, _ = mac.call("POST", "/snapshots", {"snapshots": good * 200})
        self.assertEqual((status, data["error"]), (400, "too_many_snapshots"))
        status, data, _ = mac.call("POST", "/snapshots", {"snapshots": [], "activity": [{}] * 1441})
        self.assertEqual((status, data["error"]), (400, "too_many_activity"))
        status, data, _ = mac.call("POST", "/snapshots", raw=b"{nope")
        self.assertEqual((status, data["error"]), (400, "invalid_json"))
        status, data, _ = mac.call("POST", "/snapshots", raw=b'{"snapshots": [{"usedPercent": NaN}]}')
        self.assertEqual((status, data["error"]), (400, "invalid_json"))

    def test_snapshots_need_a_device_signature(self):
        mac = self.joined("sessionupload")
        status, data, _ = mac.browser.call("POST", "/snapshots", {"snapshots": []})
        self.assertEqual((status, data["error"]), (401, "missing_device"))

    def test_non_ranked_device_readings_are_ignored(self):
        first = self.joined("rankedone")
        second = self.paired(first)
        result = second.run(NOW - 4 * 3600)
        self.assertEqual(result["accepted"], len(FAST))
        self.assertEqual(self.board()["entries"], [])
        self.assertEqual(self.get("/boards")[1]["boards"], [])
        self.assertEqual(self.get("/stats")[1]["runs"], 0)
        self.assertEqual(self.run_tiers(), [])


class RunTests(ServerTestCase):
    def test_verified_run_ranks_on_speed_board(self):
        mac = self.joined("sprinter")
        start = NOW - 4 * 3600
        mac.run(start)
        board = self.board()
        self.assertEqual(board["season"], "2026-W38")
        self.assertEqual(board["metric"], "speed")
        self.assertEqual(board["board"], {
            "provider": "claude", "plan": "max20x", "planLabel": "Max 20x", "windowKey": "18000:",
            "windowSeconds": FIVE_HOURS, "windowTitle": "5-hour window", "runners": 1, "season": "2026-W38"})
        run_id = self.query("SELECT public_id FROM runs")[0][0]
        self.assertRegex(run_id, r"^[A-Za-z0-9_-]{12}$")
        self.assertEqual(board["entries"], [{
            "rank": 1, "username": "sprinter", "displayName": "Sprinter", "value": 7200, "unit": "seconds",
            "tier": "verified", "accountVerified": True, "achievedAt": start + 7200, "peakPercent": 100.0,
            "runId": run_id, "secondsTo50": 3600, "secondsTo90": 6600, "secondsTo100": 7200, "seasonRuns": 1}])
        self.assertEqual(len(self.board(tier="verified")["entries"]), 1)

        status, boards = self.get("/boards", region="global")
        self.assertEqual(status, 200)
        self.assertEqual([(b["provider"], b["plan"], b["windowKey"], b["runners"]) for b in boards["boards"]],
                         [("claude", "max20x", "18000:", 1)])
        stats = self.get("/stats")[1]
        self.assertEqual((stats["users"], stats["runs"], stats["verifiedRuns"], stats["providers"]), (1, 1, 1, 1))

        profile = self.get("/users/sprinter")[1]
        recent = profile["recent"][0]
        self.assertEqual((recent["secondsTo50"], recent["secondsTo90"], recent["secondsTo100"]), (3600, 6600, 7200))
        self.assertEqual((recent["windowStart"], recent["completedAt"]), (start, start + 7200))
        # 账号摘要正好是注册邮箱算出来的：按 email 认领，run 带 accountVerified
        self.assertTrue(recent["accountVerified"])
        self.assertEqual([b["accountVerified"] for b in profile["bests"]], [True, True])
        self.assertEqual(recent["runId"], run_id)
        self.assertEqual([(b["metric"], b["runId"], b["secondsTo50"], b["secondsTo90"], b["secondsTo100"])
                          for b in profile["bests"]],
                         [("speed", run_id, 3600, 6600, 7200), ("peak", run_id, 3600, 6600, 7200)])

    def test_gap_over_twenty_minutes_is_standard(self):
        mac = self.joined("gappy")
        points = [(0, 0), (10, 10), (40, 40), (60, 60), (80, 80), (100, 100)]
        mac.run(NOW - 4 * 3600, points)
        self.assertEqual(self.run_tiers(), ["standard"])
        self.assertEqual(self.board()["entries"][0]["tier"], "standard")
        self.assertEqual(self.board(tier="verified")["entries"], [])

    def test_missing_account_digest_is_unranked(self):
        mac = self.joined("nodigest")
        mac.run(NOW - 4 * 3600, digest=None)
        self.assertEqual(self.query("SELECT tier, flag_reason, account_verified FROM runs"), [("unranked", "no_account", 0)])
        self.assert_hidden_everywhere("nodigest")
        self.assertEqual(mac.call("GET", "/me")[1]["providerAccounts"], [])
        # 一条 run 里只要有一条读数没有摘要就不计名次
        mixed = self.joined("mixed")
        start = NOW - 3 * 3600
        mixed.upload(series(start, FAST[:6], digest=mixed.digest) + series(start, FAST[6:], digest=None),
                     [{"minute": start + 300, "source": "claude", "tokens": 5}])
        self.assertEqual(self.query("SELECT tier, flag_reason FROM runs ORDER BY id"),
                         [("unranked", "no_account"), ("unranked", "no_account")])
        self.assertEqual(self.board()["entries"], [])
        # 回落也有、摘要也缺：算 flagged，原因都记上
        dropper = self.joined("dropnone")
        dropper.run(NOW - 2 * 3600, [(0, 0), (10, 30), (20, 20), (30, 40)], digest=None)
        self.assertEqual(self.query("SELECT tier, flag_reason FROM runs ORDER BY id")[-1], ("flagged", "drop,no_account"))

    def test_starting_above_half_is_standard(self):
        mac = self.joined("latestart")
        mac.run(NOW - 4 * 3600, [(0, 55), (10, 70), (20, 85), (30, 100)])
        self.assertEqual(self.run_tiers(), ["standard"])

    def test_activity_arriving_later_upgrades_to_verified(self):
        mac = self.joined("lazyuploader")
        start = NOW - 4 * 3600
        mac.run(start, with_activity=False)
        self.assertEqual(self.run_tiers(), ["standard"])
        # 别的来源的 token 不算 Claude 的活动
        mac.upload([], [{"minute": start + 600, "source": "codex", "tokens": 50}])
        self.assertEqual(self.run_tiers(), ["standard"])
        mac.upload([], [{"minute": start + 7300, "source": "claude", "tokens": 50}])
        self.assertEqual(self.run_tiers(), ["standard"])  # 在 100% 之后，不算
        mac.upload([], [{"minute": start + 600, "source": "claude", "tokens": 50}])
        self.assertEqual(self.run_tiers(), ["verified"])

    def test_providers_without_activity_rule_can_verify(self):
        mac = self.joined("cursorfan")
        mac.digest = account_digest("cursor", "cursorfan@example.com")
        mac.run(NOW - 4 * 3600, provider="cursor", plan="Pro", with_activity=False)
        self.assertEqual(self.run_tiers(), ["verified"])

    def test_drop_of_more_than_two_points_is_flagged(self):
        mac = self.joined("dropper")
        mac.run(NOW - 4 * 3600, [(0, 0), (10, 30), (20, 27.5), (30, 60), (40, 100)])
        self.assert_flagged_everywhere("dropper", "drop")

    def test_sixty_points_in_under_five_minutes_is_flagged(self):
        mac = self.joined("jumper")
        mac.run(NOW - 4 * 3600, [(0, 0), (2, 30), (4, 65), (10, 80), (20, 100)])
        self.assert_flagged_everywhere("jumper", "jump")

    def test_shared_provider_account_is_owned_by_one_user(self):
        first = self.joined("owner")
        second = self.joined("borrower")
        second.digest = first.digest   # owner@example.com 的账号：owner 按 email 拥有
        start = NOW - 4 * 3600
        first.run(start)
        self.assertEqual(self.run_tiers(), ["verified"])
        second.run(start + 600)
        self.assertEqual(self.query("SELECT tier, flag_reason FROM runs ORDER BY id"),
                         [("verified", None), ("flagged", "account_elsewhere")])
        self.assertEqual([(e["username"], e["accountVerified"]) for e in self.board()["entries"]], [("owner", True)])
        self.assertEqual(len(self.get("/users/owner")[1]["recent"]), 1)
        self.assertEqual(self.get("/users/borrower")[1]["recent"], [])
        # 借用的一方离开，主人不受影响
        self.assertEqual(second.call("DELETE", "/account")[0], 204)
        self.assertEqual(self.run_tiers(), ["verified"])
        self.assertEqual([e["username"] for e in self.board()["entries"]], ["owner"])

    def assert_hidden_everywhere(self, username):
        self.assertEqual(self.board()["entries"], [])
        self.assertEqual(self.board(metric="peak")["entries"], [])
        self.assertEqual(self.get("/boards")[1]["boards"], [])
        profile = self.get(f"/users/{username}")[1]
        self.assertEqual((profile["bests"], profile["recent"], profile["stats"]["runs"]), ([], [], 0))
        stats = self.get("/stats")[1]
        self.assertEqual((stats["runs"], stats["providers"]), (0, 0))

    def assert_flagged_everywhere(self, username, reason):
        rows = self.query("SELECT tier, flag_reason FROM runs")
        self.assertEqual(rows, [("flagged", reason)])
        self.assert_hidden_everywhere(username)

    def test_peak_board_orders_by_peak_then_earlier_finish(self):
        start = NOW - 4 * 3600
        self.joined("eighty").run(start, [(0, 0), (10, 40), (20, 80)])
        self.joined("latepeak").run(start, [(0, 0), (10, 50), (20, 95), (30, 95)])
        self.joined("earlypeak").run(start, [(0, 0), (10, 50), (20, 95)])
        self.joined("full").run(start, [(0, 0), (10, 50), (20, 99.6), (60, 100)])
        board = self.board(metric="peak")
        self.assertEqual([(e["rank"], e["username"], e["value"], e["unit"]) for e in board["entries"]], [
            (1, "full", 100.0, "percent"), (2, "earlypeak", 95.0, "percent"),
            (3, "latepeak", 95.0, "percent"), (4, "eighty", 80.0, "percent")])
        self.assertEqual(board["entries"][0]["achievedAt"], start + 3600)
        speed = self.board()["entries"]
        self.assertEqual([(e["username"], e["value"]) for e in speed], [("full", 1200)])
        self.assertEqual(len(self.board(metric="peak", limit="2")["entries"]), 2)

    def test_seasons_and_one_entry_per_user(self):
        last_week = NOW - int(6.5 * DAY)       # 2026-09-10 00:00 UTC，W37
        this_week = NOW - 4 * 3600
        fast = [(0, 0), (20, 35), (40, 70), (60, 100)]
        slow = [(minute, round(minute * 100 / 180, 1)) for minute in range(0, 181, 15)]
        alice = self.joined("alice")
        alice.run(last_week, fast)
        alice.run(this_week)
        self.joined("bob").run(this_week, slow)

        current = self.board(season="current")
        self.assertEqual([(e["username"], e["value"]) for e in current["entries"]], [("alice", 7200), ("bob", 10800)])
        previous = self.board(season="2026-W37")
        self.assertEqual([(e["username"], e["value"]) for e in previous["entries"]], [("alice", 3600)])
        self.assertEqual(previous["board"]["runners"], 1)
        everything = self.board(season="all")
        self.assertEqual([(e["username"], e["value"]) for e in everything["entries"]], [("alice", 3600), ("bob", 10800)])
        self.assertEqual(everything["season"], "all")
        self.assertEqual(self.get("/leaderboard", provider="claude", plan="max20x", window="18000:",
                                  season="2026-W99")[0], 400)
        self.assertEqual(self.get("/boards", season="2026-W37")[1]["boards"][0]["runners"], 1)

    def test_region_filter(self):
        start = NOW - 4 * 3600
        self.joined("globe", region="global").run(start)
        self.joined("dragon", region="china").run(start)
        names = lambda **q: [e["username"] for e in self.board(**q)["entries"]]  # noqa: E731
        self.assertEqual(sorted(names()), ["dragon", "globe"])
        self.assertEqual(names(region="china"), ["dragon"])
        self.assertEqual(names(region="global"), ["globe"])
        self.assertEqual(self.get("/boards", region="china")[1]["boards"][0]["runners"], 1)
        self.assertEqual(self.get("/leaderboard", provider="claude", window="18000:", region="mars")[0], 400)


def to_full(minutes, step=10):
    """从 0 匀速涨到 100%，第 minutes 分钟到顶，每 step 分钟一条。"""
    return [(minute, round(minute * 100 / minutes, 1)) for minute in range(0, minutes + 1, step)]


class ComparisonTests(ServerTestCase):
    """多视图榜单的对比数据：to90/to50 榜、条目附加字段、summary、/runs/<runId>、/insights。"""

    def run_ids(self, username):
        return [row[0] for row in self.query(
            "SELECT r.public_id FROM runs r JOIN users u ON u.id = r.user_id WHERE u.username = ? ORDER BY r.window_start",
            (username,))]

    def summary_fixture(self):
        """本周（W38）：alice 两条（3600 / 12000），bob 7200（standard），carol 10800（china，账号不是 email 认领），
        dave 没跑完（china），erin 14400（standard）。上周（W37）：alice 1800，frank 5400。"""
        start = NOW - 4 * 3600
        last_week = NOW - int(6.5 * DAY)
        alice = self.joined("alice")
        alice.run(last_week, [(0, 0), (10, 35), (20, 70), (30, 100)])
        alice.run(start, [(0, 0), (20, 35), (40, 70), (60, 100)])
        alice.run(NOW - 10 * 3600, [(0, 0), (10, 30), (20, 55)] + [(m, 55 + (m - 20) / 4) for m in range(30, 201, 10)])
        self.joined("bob").run(start, [(0, 0), (30, 30), (60, 60), (90, 90), (120, 100)])
        carol = self.joined("carol", region="china")
        carol.digest = account_digest("claude", "carol-work@example.com")
        carol.run(start, to_full(180))
        self.joined("dave", region="china").run(start, [(0, 0), (10, 50), (20, 80)])
        self.joined("erin").run(start, [(0, 0), (40, 40), (80, 60), (160, 90), (240, 100)])
        self.joined("frank").run(last_week, to_full(90))

    def test_to90_and_to50_boards_with_entry_extras(self):
        self.summary_fixture()
        alice_prev, alice_slow, alice_fast = self.run_ids("alice")
        self.assertEqual(self.query("SELECT tier FROM runs r JOIN users u ON u.id = r.user_id WHERE u.username IN"
                                    " ('bob', 'erin') ORDER BY u.username"), [("standard",), ("standard",)])

        speed = self.board()
        self.assertEqual([(e["username"], e["value"], e["seasonRuns"]) for e in speed["entries"]],
                         [("alice", 3600, 2), ("bob", 7200, 1), ("carol", 10800, 1), ("erin", 14400, 1)])
        self.assertEqual(speed["entries"][0]["runId"], alice_fast)

        to90 = self.board(metric="to90")
        self.assertEqual(to90["metric"], "to90")
        self.assertEqual([(e["rank"], e["username"], e["value"], e["unit"]) for e in to90["entries"]], [
            (1, "alice", 3600, "seconds"), (2, "bob", 5400, "seconds"), (3, "erin", 9600, "seconds"),
            (4, "carol", 10200, "seconds")])

        to50 = self.board(metric="to50")
        self.assertEqual([(e["username"], e["value"]) for e in to50["entries"]],
                         [("dave", 600), ("alice", 1200), ("bob", 3600), ("erin", 4800), ("carol", 5400)])
        # 每人按这个指标取最好的一条：alice 到 50% 最快的是那条慢的
        alice = to50["entries"][1]
        self.assertEqual(alice, {
            "rank": 2, "username": "alice", "displayName": "Alice", "value": 1200, "unit": "seconds",
            "tier": "verified", "accountVerified": True, "achievedAt": NOW - 10 * 3600 + 1200, "peakPercent": 100.0,
            "runId": alice_slow, "secondsTo50": 1200, "secondsTo90": 9600, "secondsTo100": 12000, "seasonRuns": 2})
        dave = to50["entries"][0]
        self.assertEqual((dave["secondsTo90"], dave["secondsTo100"], dave["peakPercent"]), (None, None, 80.0))

        everything = self.board(metric="to50", season="all")
        self.assertEqual([(e["username"], e["seasonRuns"]) for e in everything["entries"]][:2],
                         [("dave", 1), ("alice", 3)])
        self.assertEqual(self.board(metric="peak")["entries"][0]["seasonRuns"], 2)
        self.assertEqual(self.board(metric="to90", region="china")["entries"][0]["username"], "carol")
        self.assertEqual(len(self.board(metric="to50", limit="500")["entries"]), 5)  # 超过 200 按 200 算
        status, data = self.get("/leaderboard", provider="claude", plan="max20x", window="18000:", metric="to100")
        self.assertEqual((status, data["error"]), (400, "invalid_metric"))

    def test_threshold_ties_go_to_the_earlier_achievement(self):
        # grace 先上传（run id 小），但 heidi 的窗口早开一小时，同样 90 分钟到 90%，先达到
        self.joined("grace").run(NOW - 4 * 3600, to_full(100))
        self.joined("heidi").run(NOW - 5 * 3600, to_full(100))
        for metric in ("to90", "to50", "speed"):
            entries = self.board(metric=metric)["entries"]
            self.assertEqual([e["username"] for e in entries], ["heidi", "grace"], metric)
            self.assertEqual(entries[0]["value"], entries[1]["value"], metric)
            self.assertLess(entries[0]["achievedAt"], entries[1]["achievedAt"])

    def test_summary_numbers_and_previous_week(self):
        self.summary_fixture()
        bob_run = self.run_ids("bob")[0]
        alice_prev, _, alice_fast = self.run_ids("alice")

        current = self.board()["summary"]
        self.assertEqual(current, {
            "runners": 5, "runnersPrev": 2,
            "fastest": {"username": "alice", "displayName": "Alice", "seconds": 3600, "runId": alice_fast},
            "medianSecondsTo100": 7200, "medianSecondsTo100Prev": 1800, "medianRunId": bob_run,
            "completed": 4, "completedShare": 0.8, "verifiedShare": 0.6, "accountVerifiedShare": 0.8})
        # summary 与 metric 无关
        self.assertEqual(self.board(metric="to50")["summary"], current)
        self.assertEqual(self.board(metric="peak")["summary"], current)

        verified = self.board(tier="verified")["summary"]
        self.assertEqual(verified, {
            "runners": 3, "runnersPrev": 2,
            "fastest": {"username": "alice", "displayName": "Alice", "seconds": 3600, "runId": alice_fast},
            "medianSecondsTo100": 3600, "medianSecondsTo100Prev": 1800, "medianRunId": alice_fast,
            "completed": 2, "completedShare": 0.6667, "verifiedShare": 1.0, "accountVerifiedShare": 0.6667})

        china = self.board(region="china")["summary"]
        self.assertEqual((china["runners"], china["completed"], china["medianSecondsTo100"], china["fastest"]["username"],
                          china["runnersPrev"], china["medianSecondsTo100Prev"]), (2, 1, 10800, "carol", 0, None))
        self.assertEqual((china["completedShare"], china["verifiedShare"], china["accountVerifiedShare"]), (0.5, 1.0, 0.5))

        everything = self.board(season="all")["summary"]
        self.assertEqual((everything["runners"], everything["completed"], everything["medianSecondsTo100"],
                          everything["fastest"]["seconds"], everything["runnersPrev"], everything["medianSecondsTo100Prev"]),
                         (6, 5, 7200, 1800, None, None))

        last = self.board(season="last")
        self.assertEqual(last["season"], "2026-W37")
        self.assertEqual(last["summary"], {
            "runners": 2, "runnersPrev": 0,
            "fastest": {"username": "alice", "displayName": "Alice", "seconds": 1800, "runId": alice_prev},
            "medianSecondsTo100": 1800, "medianSecondsTo100Prev": None, "medianRunId": alice_prev,
            "completed": 2, "completedShare": 1.0, "verifiedShare": 1.0, "accountVerifiedShare": 1.0})

        empty = self.board(provider="codex", plan="pro")
        self.assertEqual(empty["entries"], [])
        self.assertEqual(empty["summary"], {
            "runners": 0, "runnersPrev": 0, "fastest": None, "medianSecondsTo100": None,
            "medianSecondsTo100Prev": None, "medianRunId": None, "completed": 0,
            "completedShare": None, "verifiedShare": None, "accountVerifiedShare": None})

    def test_season_last(self):
        self.assertEqual(self.service.parse_season("last"), "2026-W37")
        self.clock.value = 1_789_344_000          # 2026-09-14 00:00 UTC，W38 的第一秒
        self.assertEqual((self.service.parse_season("current"), self.service.parse_season("last")),
                         ("2026-W38", "2026-W37"))
        self.clock.value = 1_789_343_999          # 前一秒还是 W37
        self.assertEqual(self.service.parse_season("last"), "2026-W36")
        self.clock.value = NOW
        self.joined("lastweek").run(NOW - int(6.5 * DAY))
        self.assertEqual([(b["provider"], b["season"]) for b in self.get("/boards", season="last")[1]["boards"]],
                         [("claude", "2026-W37")])
        self.assertEqual(self.get("/boards")[1]["boards"], [])
        self.assertEqual([e["username"] for e in self.board(season="last")["entries"]], ["lastweek"])
        insights = self.get("/insights", season="last")[1]
        self.assertEqual((insights["season"], len(insights["boards"])), ("2026-W37", 1))
        status, data = self.get("/insights", season="previous")
        self.assertEqual((status, data["error"]), (400, "invalid_season"))

    def test_run_detail_and_downsampled_curve(self):
        mac = self.joined("curve")
        start = NOW - FIVE_HOURS
        # 每分钟一条，300 条：第 140 分钟 50%，252 分钟 90%，279 分钟 99.64%
        points = [(minute, min(100.0, round(minute * 100 / 280, 2))) for minute in range(300)]
        mac.run(start, points)
        (run_id,) = self.run_ids("curve")
        status, data, headers = self.http("GET", f"/runs/{run_id}")
        self.assertEqual(status, 200, data)
        self.assertEqual(headers["cache-control"], "public, max-age=30")
        self.assertEqual(data["run"], {
            "runId": run_id, "username": "curve", "displayName": "Curve", "provider": "claude", "plan": "max20x",
            "planLabel": "Max 20x", "windowKey": "18000:", "windowSeconds": FIVE_HOURS, "windowTitle": "5-hour window",
            "windowStart": start, "resetsAt": start + FIVE_HOURS, "season": "2026-W38", "tier": "verified",
            "accountVerified": True, "peakPercent": 100.0, "secondsTo50": 140 * 60, "secondsTo90": 252 * 60,
            "secondsTo100": 279 * 60, "completedAt": start + 279 * 60})
        readings = data["readings"]
        self.assertEqual(len(readings), 240)
        self.assertEqual(readings[0], {"t": 0, "p": 0.0})
        self.assertEqual(readings[-1], {"t": 299 * 60, "p": 100.0})
        times = [r["t"] for r in readings]
        self.assertEqual(times, sorted(set(times)))
        for seconds, used in ((140 * 60, 50.0), (252 * 60, 90.0), (279 * 60, 99.64)):
            self.assertIn({"t": seconds, "p": used}, readings)
        self.assertTrue(all(set(r) == {"t", "p"} for r in readings))
        self.assertEqual(json.dumps(data).count("@example.com"), 0)
        self.assertNotIn(mac.device_id, json.dumps(data))

        # 非计分设备的读数不进曲线
        spare = self.paired(mac)
        spare.upload(series(start, [(0.5, 55.0), (299.5, 100.0)], digest=mac.digest))
        self.assertEqual(self.get(f"/runs/{run_id}")[1]["readings"], readings)
        short = self.joined("short")
        short.run(NOW - 4 * 3600, [(0, 0), (10, 40)])
        detail = self.get(f"/runs/{self.run_ids('short')[0]}")[1]
        self.assertEqual(detail["readings"], [{"t": 0, "p": 0.0}, {"t": 600, "p": 40.0}])
        self.assertEqual((detail["run"]["secondsTo50"], detail["run"]["completedAt"]), (None, None))

    def test_run_not_found(self):
        self.joined("dropper").run(NOW - 4 * 3600, [(0, 0), (10, 30), (20, 27.5), (30, 60)])
        self.joined("nodigest").run(NOW - 4 * 3600, digest=None)
        self.assertEqual(self.run_tiers(), ["flagged", "unranked"])
        for run_id in [row[0] for row in self.query("SELECT public_id FROM runs")] + ["AAAAAAAAAAAA", "short", "a" * 13]:
            status, data, headers = self.http("GET", f"/runs/{run_id}")
            self.assertEqual((status, data["error"]), (404, "run_not_found"), run_id)
            self.assertEqual(headers["cache-control"], "public, max-age=30")
        self.assertEqual(self.get("/runs/AAAAAAAAAAAA/readings")[1]["error"], "not_found")

    def test_run_id_is_stable_across_recomputes(self):
        mac = self.joined("steady")
        start = NOW - 4 * 3600
        mac.run(start, FAST[:6], with_activity=False)
        (run_id,) = self.run_ids("steady")
        self.assertEqual(self.board(metric="peak")["entries"][0]["runId"], run_id)
        self.assertEqual(self.get(f"/runs/{run_id}")[1]["run"]["tier"], "standard")
        mac.run(start, FAST[6:], with_activity=False)                     # 更多读数：重算
        mac.upload([], [{"minute": start + 600, "source": "claude", "tokens": 5}])  # 活动升级：再重算
        self.assertEqual(self.run_ids("steady"), [run_id])
        detail = self.get(f"/runs/{run_id}")[1]
        self.assertEqual((detail["run"]["tier"], detail["run"]["secondsTo100"], len(detail["readings"])),
                         ("verified", 7200, len(FAST)))
        self.assertEqual(self.board()["entries"][0]["runId"], run_id)
        # 变成 flagged 时 id 还在，只是不公开；回落的读数删掉后又是同一个 id
        mac.upload(series(start, [(125, 50)]))
        self.assertEqual((self.run_tiers(), self.run_ids("steady")), (["flagged"], [run_id]))
        self.assertEqual(self.get(f"/runs/{run_id}")[0], 404)
        with self.service.lock:
            self.service.db.execute("DELETE FROM snapshots WHERE observed_at = ?", (start + 125 * 60,))
            self.service.recompute_run(tuple(self.query(
                f"SELECT {run_server.RUN_KEY_COLUMNS} FROM runs")[0]), NOW)
        self.assertEqual(self.get(f"/runs/{run_id}")[1]["run"]["runId"], run_id)

    def test_insights(self):
        start = NOW - 4 * 3600
        self.joined("glo1").run(start, to_full(60))
        self.joined("glo2").run(start, to_full(120))
        self.joined("glo3").run(start, [(0, 0), (10, 40)])
        self.joined("chn1", region="china").run(start, to_full(90))
        self.joined("chn2", region="china").run(start, to_full(150))
        codex = self.joined("codexer")
        codex.digest = account_digest("codex", "codexer@example.com")
        codex.run(start, to_full(60), provider="codex", plan="Pro")
        flagged = self.joined("flaggy")
        flagged.digest = account_digest("cursor", "flaggy@example.com")
        flagged.run(start, [(0, 0), (10, 30), (20, 20)], provider="cursor", plan="Pro", with_activity=False)

        status, data, headers = self.http("GET", "/insights")
        self.assertEqual(status, 200, data)
        self.assertEqual(headers["cache-control"], "public, max-age=30")
        self.assertEqual((data["season"], data["updatedAt"]), ("2026-W38", NOW))
        self.assertEqual(data["boards"], [
            {"provider": "claude", "plan": "max20x", "planLabel": "Max 20x", "windowKey": "18000:",
             "windowSeconds": FIVE_HOURS, "windowTitle": "5-hour window", "runners": 5, "completed": 4,
             "completedShare": 0.8, "fastestSeconds": 3600, "p10Seconds": 3600, "medianSeconds": 5400,
             "p90Seconds": 9000, "medianByRegion": {"global": 3600, "china": 5400}},
            {"provider": "codex", "plan": "pro", "planLabel": "Pro", "windowKey": "18000:",
             "windowSeconds": FIVE_HOURS, "windowTitle": "5-hour window", "runners": 1, "completed": 1,
             "completedShare": 1.0, "fastestSeconds": 3600, "p10Seconds": 3600, "medianSeconds": 3600,
             "p90Seconds": 3600, "medianByRegion": {"global": 3600, "china": None}},
        ])
        china = self.get("/insights", region="china")[1]["boards"]
        self.assertEqual([(b["provider"], b["runners"], b["completed"], b["completedShare"], b["fastestSeconds"],
                           b["p10Seconds"], b["medianSeconds"], b["p90Seconds"], b["medianByRegion"]) for b in china],
                         [("claude", 2, 2, 1.0, 5400, 5400, 5400, 9000, {"global": 3600, "china": 5400})])
        self.assertEqual(self.get("/insights", season="all")[1]["boards"][0]["runners"], 5)
        self.assertEqual(self.get("/insights", region="mars")[0], 400)

        # 和其他公开接口一样缓存、限流
        late = self.joined("late")
        self.service.cache_ttl = 30
        self.get("/insights")
        late.run(start, to_full(60), provider="codex", plan="Pro", digest=account_digest("codex", "late@example.com"))
        self.assertEqual(self.get("/insights")[1]["boards"][1]["runners"], 1)
        self.clock.advance(31)
        self.assertEqual(self.get("/insights")[1]["boards"][1]["runners"], 2)
        self.service.limits["public"] = (1, 1000.0)
        run_id = self.run_ids("glo1")[0]
        self.assertEqual(self.get(f"/runs/{run_id}")[0], 200)
        status, data = self.get(f"/runs/{run_id}")
        self.assertEqual((status, data["error"]), (429, "rate_limited"))


class ProviderAccountTests(ServerTestCase):
    """服务商账号：先绑定的人拥有，登录邮箱对得上的认领，解绑，应用查询状态。"""
    START = NOW - 4 * 3600

    def owner_rows(self):
        return self.query("SELECT u.username, o.via FROM account_owners o JOIN users u ON u.id = o.user_id"
                          " ORDER BY o.account_hmac")

    def owner_of(self, digest):
        return self.query("SELECT u.username, o.via FROM account_owners o JOIN users u ON u.id = o.user_id"
                          " WHERE o.account_hmac = ?", (self.service.account_hmac(digest),))

    def tiers_by_user(self):
        return dict(self.query("SELECT u.username, r.tier FROM runs r JOIN users u ON u.id = r.user_id"))

    def account_id(self, digest):
        return self.service.account_hmac(digest)[:16]

    def link_email(self, browser, email):
        status, data, _ = browser.call("POST", "/auth/email/start", {"email": email, "lang": "en", "link": True})
        self.assertEqual(status, 202, data)
        status, data, _ = browser.call("POST", "/auth/email/verify", {"email": email, "code": self.mailer.code()})
        self.assertEqual((status, data), (200, {"linked": True}))

    def link_oauth(self, browser, provider):
        _, params = self.oauth_start(browser, provider, link="1", next="/account")
        self.assertEqual(self.oauth_callback(browser, provider, params["state"]), (f"{ORIGIN}/account", {}))

    def test_first_binder_owns_and_others_are_flagged(self):
        shared = account_digest("claude", "team@example.com")
        alice = self.joined("alice")
        bob = self.joined("bob")
        alice.run(self.START, digest=shared)
        self.assertEqual(self.owner_rows(), [("alice", "first")])
        self.assertEqual(self.query("SELECT tier, account_verified FROM runs"), [("verified", 0)])
        _, me, _ = alice.call("GET", "/me")
        self.assertEqual(me["providerAccounts"], [{
            "id": self.account_id(shared), "provider": "claude", "firstSeenAt": NOW, "lastSeenAt": NOW,
            "status": "owned", "verifiedByEmail": False, "runs": 1}])

        self.clock.advance(600)
        bob.run(self.START + 600, digest=shared)
        self.assertEqual(self.owner_rows(), [("alice", "first")])
        self.assertEqual(self.tiers_by_user(), {"alice": "verified", "bob": "flagged"})
        self.assertEqual(self.query("SELECT flag_reason FROM runs WHERE tier = 'flagged'"), [("account_elsewhere",)])
        self.assertEqual([(e["username"], e["tier"], e["accountVerified"]) for e in self.board()["entries"]],
                         [("alice", "verified", False)])
        self.assertEqual(self.get("/users/bob")[1]["bests"], [])
        _, bob_me, _ = bob.browser.call("GET", "/me")
        self.assertEqual(bob_me["providerAccounts"], [{
            "id": self.account_id(shared), "provider": "claude", "firstSeenAt": NOW + 600, "lastSeenAt": NOW + 600,
            "status": "elsewhere", "verifiedByEmail": False, "runs": 0}])

        # 主人再上传：lastSeenAt 前移，归属不变
        self.clock.advance(600)
        alice.upload(series(self.START, [(130, 100)], digest=shared))
        self.assertEqual(alice.call("GET", "/me")[1]["providerAccounts"][0]["lastSeenAt"], NOW + 1200)
        self.assertEqual(self.owner_rows(), [("alice", "first")])

        # 主人删号：账号交给下一个上传过它的人，他的 run 重算
        self.assertEqual(alice.call("DELETE", "/account")[0], 204)
        self.assertEqual(self.owner_rows(), [("bob", "first")])
        self.assertEqual(self.tiers_by_user(), {"bob": "verified"})
        self.assertEqual([e["username"] for e in self.board()["entries"]], ["bob"])

    def test_non_ranked_device_does_not_bind(self):
        first = self.joined("rankedmac")
        second = self.paired(first)
        second.run(self.START, digest=account_digest("claude", "elsewhere@example.com"))
        self.assertEqual(self.query("SELECT COUNT(*) FROM account_bindings")[0][0], 0)
        self.assertEqual(self.owner_rows(), [])
        self.assertEqual(first.call("GET", "/me")[1]["providerAccounts"], [])

    def test_email_claim_moves_ownership_and_is_never_taken_over(self):
        shared = account_digest("claude", "Team@Example.com ")
        alice = self.joined("alice")
        bob = self.joined("bob")
        carol = self.joined("carol")
        alice.run(self.START, digest=shared)
        bob.run(self.START, digest=shared)
        self.assertEqual(self.tiers_by_user(), {"alice": "verified", "bob": "flagged"})

        # bob 关联了 team@example.com：邮箱认领胜过先绑定，alice 的 run 变 flagged
        self.clock.advance(60)
        self.link_email(bob.browser, "team@example.com")
        self.assertEqual(self.owner_rows(), [("bob", "email")])
        self.assertEqual(self.tiers_by_user(), {"alice": "flagged", "bob": "verified"})
        self.assertEqual(self.query("SELECT u.username, r.flag_reason, r.account_verified FROM runs r"
                                    " JOIN users u ON u.id = r.user_id ORDER BY u.username"),
                         [("alice", "account_elsewhere", 0), ("bob", None, 1)])
        self.assertEqual([(e["username"], e["accountVerified"]) for e in self.board()["entries"]], [("bob", True)])
        self.assertEqual(self.get("/users/alice")[1]["recent"], [])
        account = bob.call("GET", "/me")[1]["providerAccounts"][0]
        self.assertEqual((account["status"], account["verifiedByEmail"], account["runs"]), ("owned", True, 1))
        account = alice.call("GET", "/me")[1]["providerAccounts"][0]
        self.assertEqual((account["status"], account["verifiedByEmail"], account["runs"]), ("elsewhere", False, 0))

        # 先绑定的一方再上传也抢不回来
        self.clock.advance(60)
        alice.upload(series(self.START, [(130, 100)], digest=shared))
        self.assertEqual(self.owner_rows(), [("bob", "email")])

        # 另一个账号也有这个已验证邮箱（GitHub 主邮箱），上传后同样抢不走 email 认领
        self.providers.github_emails = [{"email": "team@example.com", "primary": True, "verified": True}]
        self.link_oauth(carol.browser, "github")
        carol.run(self.START, digest=shared)
        self.assertEqual(self.owner_rows(), [("bob", "email")])
        self.assertEqual(self.tiers_by_user(), {"alice": "flagged", "bob": "verified", "carol": "flagged"})

    def test_claim_is_rechecked_when_a_verified_identity_is_linked(self):
        octo = account_digest("claude", "octo@example.com")
        rival = self.joined("rival")
        linker = self.joined("linker")
        rival.run(self.START, digest=octo)
        linker.run(self.START, digest=octo)
        self.assertEqual(self.tiers_by_user(), {"rival": "verified", "linker": "flagged"})
        # GitHub 的主邮箱 Octo@Example.com（已验证）在上传之后才关联上
        self.link_oauth(linker.browser, "github")
        self.assertEqual(self.owner_rows(), [("linker", "email")])
        self.assertEqual(self.tiers_by_user(), {"rival": "flagged", "linker": "verified"})
        self.assertTrue(self.board()["entries"][0]["accountVerified"])

    def test_unverified_google_email_does_not_claim(self):
        gee = account_digest("claude", "gee@example.com")
        holder = self.joined("holder")
        claimer = self.joined("claimer")
        holder.run(self.START, digest=gee)
        claimer.run(self.START, digest=gee)
        self.providers.google_user = dict(self.providers.google_user, email_verified=False)
        self.link_oauth(claimer.browser, "google")
        self.assertEqual(self.owner_rows(), [("holder", "first")])
        self.assertEqual(self.tiers_by_user(), {"holder": "verified", "claimer": "flagged"})
        # 之后用这个 Google 登录时邮箱已验证：身份更新后重新认领
        self.providers.google_user = dict(self.providers.google_user, email_verified=True)
        browser = Browser(self)
        _, params = self.oauth_start(browser, "google")
        self.oauth_callback(browser, "google", params["state"])
        self.assertEqual(browser.call("GET", "/me")[1]["user"]["username"], "claimer")
        self.assertEqual(self.owner_rows(), [("claimer", "email")])
        self.assertEqual(self.tiers_by_user(), {"holder": "flagged", "claimer": "verified"})

    def test_upload_claims_an_account_first_owned_elsewhere(self):
        digest = account_digest("claude", "newcomer@example.com")
        early = self.joined("early")
        early.run(self.START, digest=digest)
        newcomer = self.joined("newcomer")
        self.assertEqual(self.owner_rows(), [("early", "first")])   # 还没上传过，注册本身不认领
        newcomer.run(self.START)
        self.assertEqual(self.owner_rows(), [("newcomer", "email")])
        self.assertEqual(self.tiers_by_user(), {"early": "flagged", "newcomer": "verified"})

    def test_lookup(self):
        known = account_digest("claude", "looker@example.com")
        other = account_digest("codex", "someone-else@example.com")
        looker = self.joined("looker")
        stranger = self.joined("stranger")
        stranger.run(self.START, provider="codex", plan="Pro", digest=other)
        looker.run(self.START)
        status, data, headers = looker.call("POST", "/accounts/lookup", {"digests": [known, other, known]})
        self.assertEqual(status, 200, data)
        self.assertEqual(headers["cache-control"], "no-store")
        account = {"id": self.account_id(known), "provider": "claude", "firstSeenAt": NOW, "lastSeenAt": NOW,
                   "status": "owned", "verifiedByEmail": True, "runs": 1}
        # 别人上传过、自己没上传过的也是 null，不透露归属
        self.assertEqual(data, {"accounts": [{"digest": known, "account": account},
                                             {"digest": other, "account": None},
                                             {"digest": known, "account": account}]})
        self.assertEqual(looker.call("POST", "/accounts/lookup", {"digests": []})[1], {"accounts": []})
        for body in ({}, {"digests": known}, {"digests": [known.upper()]}, {"digests": [known[:63]]},
                     {"digests": [7]}, {"digests": [known] * 21}, {"digests": [known + "0"]}):
            status, data, _ = looker.call("POST", "/accounts/lookup", body)
            self.assertEqual((status, data["error"]), (400, "invalid_digests"), body)
        self.assertEqual(looker.call("POST", "/accounts/lookup", {"digests": [known] * 20})[0], 200)
        # 网页会话不能查（网页没有摘要）
        status, data, _ = looker.browser.call("POST", "/accounts/lookup", {"digests": [known]})
        self.assertEqual((status, data["error"]), (401, "missing_device"))

    def test_unbind_passes_ownership_on(self):
        mine = account_digest("claude", "alice@example.com")
        extra = account_digest("cursor", "alice-extra@example.com")
        alice = self.joined("alice")
        carol = self.joined("carol")
        bob = self.joined("bob")
        alice.run(self.START)                                   # alice 按 email 拥有
        alice.run(NOW - 10 * 3600, provider="cursor", plan="Pro", with_activity=False, digest=extra)  # 按 first
        self.clock.advance(60)
        carol.run(self.START, digest=mine)                      # carol 先于 bob 上传
        self.clock.advance(60)
        # bob 的 GitHub 主邮箱也是 alice@example.com（已验证）
        self.providers.github_emails = [{"email": "alice@example.com", "primary": True, "verified": True}]
        self.link_oauth(bob.browser, "github")
        bob.run(self.START, digest=mine)
        self.assertEqual(self.owner_of(mine), [("alice", "email")])
        self.assertEqual(self.query("SELECT COUNT(*) FROM runs WHERE tier = 'flagged'")[0][0], 2)
        alice_id = self.query("SELECT id FROM users WHERE username = 'alice'")[0][0]
        bob_id = bob.call("GET", "/me")[1]["providerAccounts"][0]["id"]

        # 格式不对、不是自己绑定的 id 都是 404
        for bad in (bob_id[:15], "zzzzzzzzzzzzzzzz", self.account_id(extra)):
            status, data, _ = bob.call("DELETE", f"/accounts/{bad}")
            self.assertEqual((status, data["error"]), (404, "account_not_found"), bad)

        status, data, _ = alice.call("DELETE", f"/accounts/{self.account_id(mine)}")
        self.assertEqual(status, 200, data)
        self.assertEqual([(a["id"], a["provider"], a["status"], a["runs"]) for a in data["providerAccounts"]],
                         [(self.account_id(extra), "cursor", "owned", 1)])
        account = self.service.account_hmac(mine)
        self.assertEqual(self.query("SELECT COUNT(*) FROM snapshots WHERE user_id = ? AND account_hmac = ?",
                                    (alice_id, account))[0][0], 0)
        self.assertEqual(self.query("SELECT COUNT(*) FROM account_bindings WHERE user_id = ? AND account_hmac = ?",
                                    (alice_id, account))[0][0], 0)
        self.assertEqual(self.query("SELECT provider FROM runs WHERE user_id = ?", (alice_id,)), [("cursor",)])
        # 邮箱对得上的 bob 优先于更早上传的 carol
        self.assertEqual(self.owner_of(mine), [("bob", "email")])
        self.assertEqual(self.tiers_by_user(), {"alice": "verified", "bob": "verified", "carol": "flagged"})
        self.assertEqual({e["username"]: e["accountVerified"] for e in self.board()["entries"]}, {"bob": True})
        status, data, _ = alice.call("DELETE", f"/accounts/{self.account_id(mine)}")
        self.assertEqual((status, data["error"]), (404, "account_not_found"))

        # 网页会话也能解绑（要站点 Origin）；bob 走了以后轮到 carol（按 first）
        status, data, _ = bob.browser.call("DELETE", f"/accounts/{bob_id}", origin="https://evil.example")
        self.assertEqual((status, data["error"]), (403, "bad_origin"))
        status, data, _ = bob.browser.call("DELETE", f"/accounts/{bob_id}")
        self.assertEqual((status, data), (200, {"providerAccounts": []}))
        self.assertEqual(self.owner_of(mine), [("carol", "first")])
        self.assertEqual({e["username"] for e in self.board()["entries"]}, {"carol"})

        # 最后一个人解绑，账号不再有主人
        self.assertEqual(carol.call("DELETE", f"/accounts/{self.account_id(mine)}")[0], 200)
        self.assertEqual(self.owner_of(mine), [])
        self.assertEqual(self.owner_of(extra), [("alice", "first")])

    def test_unbind_uses_the_write_rate_limit(self):
        mac = self.joined("hurried")
        mac.run(self.START)
        self.service.limits["write"] = (1, 10.0)
        self.assertEqual(mac.call("DELETE", "/accounts/0000000000000000")[1]["error"], "account_not_found")
        status, data, _ = mac.call("DELETE", f"/accounts/{self.account_id(mac.digest)}")
        self.assertEqual((status, data["error"]), (429, "rate_limited"))

    def test_public_cache_is_cleared_when_ownership_moves(self):
        shared = account_digest("claude", "cache@example.com")
        first = self.joined("firstcache")
        claimer = self.joined("claimer")
        first.run(self.START, digest=shared)
        claimer.run(self.START, digest=shared)
        self.service.cache_ttl = 30
        self.assertEqual([e["username"] for e in self.board()["entries"]], ["firstcache"])
        self.link_email(claimer.browser, "cache@example.com")
        self.assertEqual([e["username"] for e in self.board()["entries"]], ["claimer"])


class ProfileTests(ServerTestCase):
    def test_profile_projects_and_bests(self):
        mac = self.joined("builder")
        status, data, _ = mac.call("PUT", "/profile", {
            "displayName": "The Builder", "bio": "Ships things.", "region": "china",
            "links": {"website": "https://builder.dev", "github": "@gentpan", "x": "https://x.com/gentpan"}})
        self.assertEqual(status, 200, data)
        self.assertEqual(data["user"]["links"], dict(dict.fromkeys(run_server.LINK_KINDS), website="https://builder.dev",
                                                     github="https://github.com/gentpan", x="https://x.com/gentpan"))
        status, data, _ = mac.call("PUT", "/profile", {"links": {"website": "http://builder.dev"}})
        self.assertEqual((status, data["error"]), (400, "invalid_links"))
        status, data, _ = mac.call("PUT", "/profile", {"bio": "x" * 161})
        self.assertEqual((status, data["error"]), (400, "invalid_bio"))

        projects = [
            {"name": "QuotaBar", "url": "https://quota.bar", "description": "Menu bar quotas.",
             "github": "gentpan/QuotaBar", "builtWith": ["codex", "claude"]},
            {"name": "Side thing", "url": "https://example.com/side", "builtWith": []},
        ]
        status, data, _ = mac.call("PUT", "/projects", {"projects": projects})
        self.assertEqual(status, 200, data)
        self.assertEqual(data["projects"][0], {"name": "QuotaBar", "url": "https://quota.bar",
                                               "description": "Menu bar quotas.",
                                               "github": "https://github.com/gentpan/QuotaBar",
                                               "builtWith": ["codex", "claude"]})
        for broken, code in [
            ([dict(projects[0], url="http://quota.bar")], "invalid_project"),
            ([dict(projects[0], url="https://user:pw@quota.bar")], "invalid_project"),
            ([dict(projects[0], name="n" * 41)], "invalid_project"),
            ([dict(projects[0], description="d" * 141)], "invalid_project"),
            ([projects[1]] * 13, "too_many_projects"),
        ]:
            status, data, _ = mac.call("PUT", "/projects", {"projects": broken})
            self.assertEqual((status, data["error"]), (400, code))

        start = NOW - 4 * 3600
        mac.run(start)
        rival = self.joined("rival")
        rival.run(start, [(minute, round(minute * 100 / 180, 1)) for minute in range(0, 181, 15)])

        status, profile, headers = self.http("GET", "/users/Builder")
        self.assertEqual(status, 200)
        self.assertEqual(headers["cache-control"], "public, max-age=30")
        self.assertEqual((profile["username"], profile["displayName"], profile["bio"], profile["region"]),
                         ("builder", "The Builder", "Ships things.", "china"))
        self.assertEqual(profile["joinedAt"], NOW)
        self.assertEqual(len(profile["projects"]), 2)
        speed = [b for b in profile["bests"] if b["metric"] == "speed"]
        peak = [b for b in profile["bests"] if b["metric"] == "peak"]
        self.assertEqual((speed[0]["value"], speed[0]["rank"], speed[0]["runners"], speed[0]["percentile"]),
                         (7200, 1, 2, 50))
        self.assertEqual((speed[0]["tier"], speed[0]["season"], speed[0]["planLabel"]), ("verified", "2026-W38", "Max 20x"))
        self.assertEqual((peak[0]["value"], peak[0]["rank"]), (100.0, 1))
        self.assertEqual(len(profile["recent"]), 1)
        self.assertEqual(profile["stats"], {"runs": 1, "verifiedRuns": 1, "providers": 1, "activeDays": 1})
        rival_speed = [b for b in self.get("/users/rival")[1]["bests"] if b["metric"] == "speed"][0]
        self.assertEqual((rival_speed["rank"], rival_speed["percentile"]), (2, 100))

        text = json.dumps(profile)
        for secret in (mac.device_id, mac.digest, self.service.account_hmac(mac.digest), "builder@example.com"):
            self.assertNotIn(secret, text)
        board_text = json.dumps(self.board())
        self.assertNotIn(mac.device_id, board_text)
        self.assertNotIn(mac.digest, board_text)
        self.assertNotIn("@example.com", board_text)

        status, data, headers = self.http("GET", "/users/nobody-here")
        self.assertEqual((status, data["error"]), (404, "user_not_found"))
        self.assertEqual(headers["cache-control"], "public, max-age=30")

        _, me, _ = mac.call("GET", "/me")
        self.assertEqual(len(me["projects"]), 2)


def contribution_page(end, counts, cells=365):
    """github.com/users/<login>/contributions 的样子：每天一个 td，数字在 for 指向它的 tool-tip 里。"""
    tds, tips = [], []
    for i in range(cells):
        day = (end - datetime.timedelta(days=cells - 1 - i)).isoformat()
        n = counts.get(day, 0)
        cell = f"contribution-day-component-{i % 7}-{i // 7}"
        tds.append(f'<td tabindex="0" data-ix="{i // 7}" style="width: 10px" data-date="{day}" id="{cell}"'
                   f' data-level="{min(n, 4)}" role="gridcell" data-view-component="true" class="ContributionCalendar-day"></td>')
        text = f"{n:,} contribution{'' if n == 1 else 's'} on May 1st." if n else "No contributions on May 1st."
        tips.append(f'<tool-tip id="tooltip-{i}" for="{cell}" popover="manual" data-type="label" class="sr-only">{text}</tool-tip>')
    return ('<table class="ContributionCalendar-grid"><tbody><tr>' + "".join(tds) + "</tr></tbody></table>"
            + "".join(tips)).encode("utf-8")


class ProfilePageTests(ServerTestCase):
    def wait_github(self):
        for job in list(self.service._github_jobs.values()):
            job.join(10)

    def test_more_links_time_zone_and_switches(self):
        mac = self.joined("linker")
        browser = mac.browser
        status, data, _ = browser.call("PUT", "/profile", {"links": {
            "blog": "https://blog.linker.dev/", "gitlab": "@linker", "bluesky": "@linker.bsky.social",
            "mastodon": "@linker@Hachyderm.io", "linkedin": "linker-dev", "youtube": "@linkerdev",
            "telegram": "linker_dev", "huggingface": "linker", "bilibili": "123456", "zhihu": "linker",
            "juejin": "4096", "v2ex": "linker", "weibo": "1234567890",
            "xiaohongshu": "https://www.xiaohongshu.com/user/profile/5f00", "unknown": "ignored"}})
        self.assertEqual(status, 200, data)
        expected = dict(
            dict.fromkeys(run_server.LINK_KINDS), blog="https://blog.linker.dev/", gitlab="https://gitlab.com/linker",
            bluesky="https://bsky.app/profile/linker.bsky.social", mastodon="https://hachyderm.io/@linker",
            linkedin="https://www.linkedin.com/in/linker-dev", youtube="https://www.youtube.com/@linkerdev",
            telegram="https://t.me/linker_dev", huggingface="https://huggingface.co/linker",
            bilibili="https://space.bilibili.com/123456", zhihu="https://www.zhihu.com/people/linker",
            juejin="https://juejin.cn/user/4096", v2ex="https://www.v2ex.com/member/linker",
            weibo="https://weibo.com/u/1234567890", xiaohongshu="https://www.xiaohongshu.com/user/profile/5f00")
        self.assertEqual(data["user"]["links"], expected)
        self.assertEqual(list(data["user"]["links"]), list(run_server.LINK_KINDS))

        # 应用只认 website、github、x，也只传这三个：其余链接保持原样
        status, data, _ = mac.call("PUT", "/profile", {"links": {"website": "https://linker.dev", "github": None, "x": None}})
        expected["website"] = "https://linker.dev"
        self.assertEqual((status, data["user"]["links"]), (200, expected))
        status, data, _ = browser.call("PUT", "/profile", {"links": {"blog": "", "weibo": None}})
        expected.update(blog=None, weibo=None)
        self.assertEqual((status, data["user"]["links"]), (200, expected))
        for field, value in (("linkedin", "https://evil.example/in/linker"), ("xiaohongshu", "linker"),
                             ("blog", "http://blog.linker.dev"), ("mastodon", "http://hachyderm.io/@linker"),
                             ("bilibili", "https://user:pw@space.bilibili.com/1"), ("telegram", 42)):
            status, data, _ = browser.call("PUT", "/profile", {"links": {field: value}})
            self.assertEqual((status, data["error"]), (400, "invalid_links"), field)
            self.assertIn(f"links.{field} ", data["message"])
        self.assertEqual(self.get("/users/linker")[1]["links"], expected)

        status, data, _ = browser.call("PUT", "/profile", {"timezone": "Asia/Kolkata", "showActivity": False,
                                                           "showGithub": False})
        self.assertEqual(status, 200, data)
        self.assertEqual((data["user"]["timezone"], data["user"]["showActivity"], data["user"]["showGithub"]),
                         ("Asia/Kolkata", False, False))
        for body, code in (({"timezone": "Mars/Olympus_Mons"}, "invalid_timezone"),
                           ({"timezone": "../../etc/passwd"}, "invalid_timezone"), ({"timezone": 8}, "invalid_timezone"),
                           ({"showActivity": "yes"}, "invalid_profile"), ({"showGithub": 1}, "invalid_profile")):
            status, data, _ = browser.call("PUT", "/profile", body)
            self.assertEqual((status, data["error"]), (400, code), body)
        self.assertEqual(browser.call("GET", "/me")[1]["user"]["timezone"], "Asia/Kolkata")
        self.assertIsNone(browser.call("PUT", "/profile", {"timezone": ""})[1]["user"]["timezone"])
        public = self.get("/users/linker")[1]
        self.assertEqual((public["activity"], public["github"]), (None, None))
        self.assertNotIn("timezone", public)

    def test_activity_heatmap(self):
        mac = self.joined("heater", region="china")
        other = self.paired(mac)                 # 不计分的那台：它的活动分钟不算
        evening = NOW - 3600                     # 2026-09-16 11:00 UTC，上海 19:00
        early = NOW - 18 * 3600 - 30 * 60        # 2026-09-15 17:30 UTC，上海已经是 16 日 01:30
        monday = NOW - 2 * DAY                   # 2026-09-14
        mac.upload([], [{"minute": evening, "source": "claude", "tokens": 1000},
                        {"minute": evening + 60, "source": "claude", "tokens": 20},
                        {"minute": early, "source": "codex", "tokens": 500},
                        {"minute": monday, "source": "claude", "tokens": 200},
                        {"minute": monday + 60, "source": "codex", "tokens": 0}])
        other.upload([], [{"minute": evening, "source": "codex", "tokens": 99_999}])

        activity = self.get("/users/heater")[1]["activity"]
        # 从 52 周前的星期一画到今天（上海时间）
        self.assertEqual({key: activity[key] for key in ("timezone", "from", "to", "totalTokens")},
                         {"timezone": "Asia/Shanghai", "from": "2025-09-15", "to": "2026-09-16", "totalTokens": 1720})
        self.assertEqual(activity["days"], [
            {"date": "2026-09-14", "tokens": 200, "sources": {"claude": 200}},
            {"date": "2026-09-16", "tokens": 1520, "sources": {"claude": 1020, "codex": 500}}])

        mac.browser.call("PUT", "/profile", {"timezone": "UTC"})
        days = self.get("/users/heater")[1]["activity"]["days"]
        self.assertEqual([(d["date"], d["tokens"]) for d in days], [("2026-09-14", 200), ("2026-09-15", 500), ("2026-09-16", 1020)])

        # 半点的时区：UTC 18:45 在加尔各答已经是 16 日 00:15，17:30 还是 15 日 23:00
        mac.upload([], [{"minute": NOW - 17 * 3600 - 15 * 60, "source": "codex", "tokens": 7}])
        mac.browser.call("PUT", "/profile", {"timezone": "Asia/Kolkata"})
        days = self.get("/users/heater")[1]["activity"]["days"]
        self.assertEqual([(d["date"], d["tokens"]) for d in days], [("2026-09-14", 200), ("2026-09-15", 500), ("2026-09-16", 1027)])

        mac.browser.call("PUT", "/profile", {"showActivity": False})
        self.assertIsNone(self.get("/users/heater")[1]["activity"])

    def test_github_contributions_and_repositories(self):
        browser = self.account("octo")
        _, params = self.oauth_start(browser, "github", link="1")
        self.oauth_callback(browser, "github", params["state"])
        status, data, _ = browser.call("PUT", "/projects", {"projects": [
            {"name": "QuotaBar", "url": "https://quota.bar", "github": "gentpan/QuotaBar"},
            {"name": "Again", "url": "https://again.dev", "github": "https://github.com/GentPan/quotabar.git"},
            {"name": "Gone", "url": "https://gone.dev", "github": "nobody/missing"},
            {"name": "No repo", "url": "https://plain.dev"}]})
        self.assertEqual(status, 200, data)
        api = run_server.GITHUB_API
        routes = self.providers.routes
        user = {"id": 101, "login": "Octo-Cat"}
        page = {"status": 200, "body": contribution_page(datetime.date(2026, 9, 16),
                                                          {"2025-09-20": 1, "2026-09-01": 1234, "2026-09-16": 3})}
        stats = {"status": 202}
        routes[f"{api}/user/101"] = lambda method, headers, body: (200, json.dumps(user).encode())
        routes["https://github.com/users/Octo-Cat/contributions"] = lambda method, headers, body: (page["status"], page["body"])
        routes[f"{api}/repos/gentpan/QuotaBar"] = lambda method, headers, body: (200, json.dumps({
            "full_name": "gentpan/QuotaBar", "html_url": "https://github.com/gentpan/QuotaBar",
            "description": "Menu bar quotas", "stargazers_count": 1200, "forks_count": 40, "language": "Swift",
            "pushed_at": "2026-09-15T10:00:00Z", "archived": False}).encode())
        routes[f"{api}/repos/gentpan/QuotaBar/stats/commit_activity"] = lambda method, headers, body: (
            (202, b"") if stats["status"] == 202 else (200, json.dumps([{"total": n, "week": 0, "days": []} for n in range(50)]).encode()))

        self.assertEqual(self.get("/users/octo")[1]["github"], {"login": "Octo-Cat", "url": "https://github.com/Octo-Cat"})
        status, data, headers = self.http("GET", "/users/octo/github")
        self.assertEqual(status, 200, data)
        self.assertEqual(headers["cache-control"], "public, max-age=30")
        self.assertEqual((data["login"], data["url"], data["pending"], data["totals"], data["fetchedAt"]),
                         ("Octo-Cat", "https://github.com/Octo-Cat", False, None, NOW))
        self.assertEqual(data["calendar"], {"total": 1238, "from": "2025-09-17", "to": "2026-09-16", "days": [
            {"date": "2025-09-20", "count": 1}, {"date": "2026-09-01", "count": 1234}, {"date": "2026-09-16", "count": 3}]})
        self.assertEqual([repo["repo"] for repo in data["repos"]], ["gentpan/QuotaBar", "nobody/missing"])
        self.assertEqual(data["repos"][0], {
            "repo": "gentpan/QuotaBar", "url": "https://github.com/gentpan/QuotaBar", "description": "Menu bar quotas",
            "stars": 1200, "forks": 40, "language": "Swift", "pushedAt": NOW - 26 * 3600, "archived": False,
            "weeks": None, "commits": None, "fetchedAt": NOW})
        self.assertEqual(data["repos"][1], {"repo": "nobody/missing", "missing": True, "fetchedAt": NOW})
        # 没有令牌时 API 用 OAuth 应用的 client id / secret；公开的贡献页面什么都不带
        basic = "Basic " + base64.b64encode(f"gh-client:{GITHUB_SECRET}".encode()).decode()
        data_calls = [c for c in self.providers.calls if c["url"].startswith((api + "/repos/", api + "/user/101"))]
        self.assertTrue(data_calls and all(c["headers"].get("Authorization") == basic for c in data_calls))
        page_calls = [c for c in self.providers.calls if c["url"].endswith("/contributions")]
        self.assertEqual(len(page_calls), 1)
        self.assertNotIn("Authorization", page_calls[0]["headers"])

        # 缓存期内不再去取；提交统计还在算（202）的仓库两分钟后再取
        count = len(self.providers.calls)
        self.get("/users/octo/github")
        self.wait_github()
        self.assertEqual(len(self.providers.calls), count)
        stats["status"] = 200
        self.clock.advance(run_server.GITHUB_PENDING_RETRY + 1)
        self.assertIsNone(self.get("/users/octo/github")[1]["repos"][0]["weeks"])   # 先给上一份，后台去取
        self.wait_github()
        repo = self.get("/users/octo/github")[1]["repos"][0]
        self.assertEqual((repo["weeks"], repo["commits"]), ([0, 0] + list(range(50)), sum(range(50))))
        self.assertEqual(len([c for c in self.providers.calls if c["url"].endswith("/contributions")]), 1)

        # 有令牌：GraphQL 连提交、PR 的分项一起取；GitHub 上改了名跟着改
        self.service.settings.github_token = "github_pat_for_tests"
        user["login"] = "Octo-Renamed"
        graph = {"data": {"user": {"contributionsCollection": {
            "contributionCalendar": {"totalContributions": 5, "weeks": [{"contributionDays": [
                {"date": "2026-09-22", "contributionCount": 0}, {"date": "2026-09-23", "contributionCount": 5}]}]},
            "totalCommitContributions": 4, "totalPullRequestContributions": 1, "totalIssueContributions": 0,
            "totalPullRequestReviewContributions": 2, "restrictedContributionsCount": 7}}}}
        graph_status = {"value": 200}
        routes[run_server.GITHUB_GRAPHQL_URL] = lambda method, headers, body: (graph_status["value"], json.dumps(graph).encode())
        self.clock.advance(run_server.GITHUB_TTL)
        self.get("/users/octo/github")
        self.wait_github()
        data = self.get("/users/octo/github")[1]
        self.assertEqual((data["login"], data["totals"]),
                         ("Octo-Renamed", {"commits": 4, "pullRequests": 1, "issues": 0, "reviews": 2, "private": 7}))
        self.assertEqual(data["calendar"], {"total": 5, "from": "2026-09-22", "to": "2026-09-23",
                                            "days": [{"date": "2026-09-23", "count": 5}]})
        graphql = [c for c in self.providers.calls if c["url"] == run_server.GITHUB_GRAPHQL_URL][-1]
        self.assertEqual(graphql["headers"]["Authorization"], "Bearer github_pat_for_tests")
        self.assertEqual(json.loads(graphql["body"])["variables"], {"login": "Octo-Renamed"})
        self.assertEqual(self.get("/users/octo")[1]["github"]["login"], "Octo-Renamed")
        self.assertEqual(self.query("SELECT login FROM identities WHERE provider = 'github'"), [("Octo-Renamed",)])
        self.assertNotIn("github_pat_for_tests", self.dump())

        # GitHub 出错：留着上一份，十五分钟后再试
        graph_status["value"] = 502
        page["status"] = 500
        self.clock.advance(run_server.GITHUB_TTL)
        self.get("/users/octo/github")
        self.wait_github()
        self.assertEqual(self.get("/users/octo/github")[1]["totals"]["commits"], 4)
        self.assertEqual(self.query("SELECT retry_at FROM github_cache WHERE key = 'user:101'"),
                         [(int(self.clock()) + run_server.GITHUB_RETRY,)])

        # 关掉 GitHub 的显示：日历不给，项目的仓库数据照给
        browser.call("PUT", "/profile", {"showGithub": False})
        self.assertIsNone(self.get("/users/octo")[1]["github"])
        data = self.get("/users/octo/github")[1]
        self.assertEqual((data["login"], data["calendar"], data["totals"], len(data["repos"])), (None, None, None, 2))

        # 只填了 GitHub 链接、没关联 GitHub 登录的人没有贡献日历
        plain = self.account("plainer")
        plain.call("PUT", "/profile", {"links": {"github": "Octo-Cat"}})
        self.assertIsNone(self.get("/users/plainer")[1]["github"])
        self.assertEqual(self.get("/users/plainer/github")[1], {"login": None, "url": None, "calendar": None,
                                                                "totals": None, "repos": [], "pending": False,
                                                                "fetchedAt": None})
        status, data = self.get("/users/nobody-here/github")
        self.assertEqual((status, data["error"]), (404, "user_not_found"))

        # 删号时这个人的贡献日历缓存一起删，仓库的留着
        self.assertEqual(browser.call("DELETE", "/account")[0], 204)
        self.assertEqual(self.query("SELECT key FROM github_cache ORDER BY key"),
                         [("repo:gentpan/quotabar",), ("repo:nobody/missing",)])

    def test_github_rate_limit_pauses_every_github_request(self):
        browser = self.account("limited")
        _, params = self.oauth_start(browser, "github", link="1")
        self.oauth_callback(browser, "github", params["state"])
        browser.call("PUT", "/projects", {"projects": [{"name": "R", "url": "https://r.dev", "github": "gentpan/QuotaBar"}]})
        routes = self.providers.routes
        routes[f"{run_server.GITHUB_API}/user/101"] = lambda method, headers, body: (
            403, b'{"message":"API rate limit exceeded for 1.2.3.4."}')
        routes[f"{run_server.GITHUB_API}/repos/gentpan/QuotaBar"] = lambda method, headers, body: (429, b"{}")
        self.get("/users/limited/github")
        self.wait_github()
        self.assertEqual(self.service._github_paused_until, NOW + run_server.GITHUB_RATE_PAUSE)
        calls = len(self.providers.calls)
        # 新加的仓库从没取过，但超限暂停中也先不去取
        browser.call("PUT", "/projects", {"projects": [{"name": "R", "url": "https://r.dev", "github": "gentpan/QuotaBar"},
                                                       {"name": "S", "url": "https://s.dev", "github": "gentpan/Other"}]})
        self.clock.advance(60)
        self.assertEqual(self.get("/users/limited/github")[0], 200)
        self.wait_github()
        self.assertEqual(len(self.providers.calls), calls)
        self.clock.advance(run_server.GITHUB_RATE_PAUSE)
        self.get("/users/limited/github")
        self.wait_github()
        self.assertGreater(len(self.providers.calls), calls)

    def test_github_first_view_waits_then_says_pending(self):
        browser = self.account("slowpoke")
        _, params = self.oauth_start(browser, "github", link="1")
        self.oauth_callback(browser, "github", params["state"])
        release = threading.Event()
        routes = self.providers.routes

        def slow_user(method, headers, body):
            release.wait(10)
            return 200, json.dumps({"login": "Octo-Cat"}).encode()

        routes[f"{run_server.GITHUB_API}/user/101"] = slow_user
        routes["https://github.com/users/Octo-Cat/contributions"] = lambda method, headers, body: (
            200, contribution_page(datetime.date(2026, 9, 16), {}, cells=12))   # 太少：页面改版了
        with mock.patch.object(run_server, "GITHUB_WAIT", 0.05):
            status, data, headers = self.http("GET", "/users/slowpoke/github")
        self.assertEqual((status, data["pending"], data["login"], data["calendar"]), (200, True, "Octo-Cat", None))
        self.assertEqual(headers["cache-control"], "no-store")
        release.set()
        self.wait_github()
        data = self.get("/users/slowpoke/github")[1]
        self.assertEqual((data["pending"], data["calendar"]), (False, None))
        self.assertEqual(self.query("SELECT payload, retry_at FROM github_cache WHERE key = 'user:101'"),
                         [(None, NOW + run_server.GITHUB_RETRY)])


class AccountTests(ServerTestCase):
    def test_delete_account_removes_every_row(self):
        mac = self.joined("leaver")
        other_mac = self.paired(mac)
        stayer = self.joined("stayer")
        stayer.run(NOW - 4 * 3600)
        mac.run(NOW - 4 * 3600)
        other_mac.upload([], [{"minute": NOW - 600, "source": "codex", "tokens": 9}])
        mac.call("PUT", "/projects", {"projects": [{"name": "X", "url": "https://x.dev"}]})

        user_id = self.query("SELECT id FROM users WHERE username = 'leaver'")[0][0]
        status, data, headers = mac.call("DELETE", "/account")
        self.assertEqual((status, data), (204, None))
        self.assertEqual(headers["cache-control"], "no-store")

        for table in ("devices", "snapshots", "activity", "runs", "projects", "account_bindings", "account_owners",
                      "identities", "connect_requests"):
            count = self.query(f"SELECT COUNT(*) FROM {table} WHERE user_id = ?", (user_id,))[0][0]
            self.assertEqual(count, 0, table)
        self.assertEqual(self.query("SELECT COUNT(*) FROM users WHERE id = ?", (user_id,))[0][0], 0)
        self.assertEqual(self.query("SELECT COUNT(*) FROM sessions")[0][0], 1)  # 只剩 stayer 的
        nonces = self.query("SELECT COUNT(*) FROM nonces WHERE scope IN (?, ?)",
                            (mac.device_id, other_mac.device_id))[0][0]
        self.assertEqual(nonces, 0)
        self.assertEqual(mac.call("GET", "/me")[1]["error"], "unknown_device")
        self.assertEqual(other_mac.call("GET", "/me")[1]["error"], "unknown_device")
        self.assertEqual(mac.browser.call("GET", "/me")[1]["error"], "not_signed_in")
        self.assertEqual(self.get("/users/leaver")[0], 404)
        self.assertEqual([e["username"] for e in self.board()["entries"]], ["stayer"])
        # 名字释放后可以重新注册
        self.assertEqual(Mac(self).register("leaver")[0], 201)


class AbuseTests(ServerTestCase):
    def test_write_rate_limit_per_device(self):
        mac = self.joined("hasty")
        other = self.joined("patient")
        self.service.limits["write"] = (5, 10.0)
        for _ in range(5):
            self.assertEqual(mac.call("PUT", "/profile", {"bio": "again"})[0], 200)
        status, data, headers = mac.call("PUT", "/profile", {"bio": "again"})
        self.assertEqual((status, data["error"]), (429, "rate_limited"))
        self.assertEqual(headers["retry-after"], "10")
        self.assertEqual(other.call("PUT", "/profile", {"bio": "fine"})[0], 200)
        self.assertEqual(mac.call("GET", "/me")[0], 200)  # 读不限
        self.clock.advance(10)
        self.assertEqual(mac.call("PUT", "/profile", {"bio": "later"})[0], 200)
        self.assertEqual(mac.call("PUT", "/profile", {"bio": "later"})[0], 429)
        # 网页会话按账号限流
        for _ in range(5):
            self.assertEqual(other.browser.call("PUT", "/profile", {"bio": "web"})[0], 200)
        self.assertEqual(other.browser.call("PUT", "/profile", {"bio": "web"})[0], 429)

    def test_register_rate_limit_per_ip(self):
        self.service.limits["register"] = (2, 10.0)
        self.assertEqual(Mac(self).register("one-1")[0], 201)
        self.assertEqual(Mac(self).register("two-2")[0], 201)
        self.assertEqual(Mac(self).register("three-3")[0], 429)

    def test_forwarded_for_is_only_trusted_from_the_local_proxy(self):
        handler = type("FakeHandler", (), {})()
        handler.headers = {"X-Forwarded-For": "198.51.100.1, 203.0.113.7"}
        handler.client_address = ("127.0.0.1", 5000)
        self.assertEqual(run_server.client_ip(handler), "203.0.113.7")
        handler.client_address = ("192.0.2.10", 5000)
        self.assertEqual(run_server.client_ip(handler), "192.0.2.10")

    def test_body_over_one_megabyte_is_413(self):
        mac = self.joined("bulky")
        raw = b'{"snapshots": [], "pad": "' + b"x" * 1_100_000 + b'"}'
        status, data, _ = mac.call("POST", "/snapshots", raw=raw)
        self.assertEqual((status, data["error"]), (413, "body_too_large"))
        self.assertEqual(mac.call("GET", "/me")[0], 200)

    def test_unknown_route_is_404(self):
        self.assertEqual(self.get("/nope")[0], 404)
        self.assertEqual(self.http("GET", "/../../etc/passwd")[0], 404)
        self.assertEqual(self.http("POST", "/pair")[0], 404)

    def test_public_cache(self):
        mac = self.joined("cached")
        self.service.cache_ttl = 30
        status, stats, headers = self.http("GET", "/stats")
        self.assertEqual(headers["cache-control"], "public, max-age=30")
        self.assertEqual(stats["runs"], 0)
        mac.run(NOW - 4 * 3600)
        self.assertEqual(self.get("/stats")[1]["runs"], 0)
        self.clock.advance(31)
        self.assertEqual(self.get("/stats")[1]["runs"], 1)


TODAY = "2026-09-16"
OPUS = (5, 25, 6.25, 0.5)


def usage_row(date=TODAY, tool="claude", mode="desktop", model="claude-opus-5", project=None, output=0, **fields):
    row = {"date": date, "tool": tool, "mode": mode, "model": model, "input": 0, "output": output, "cacheRead": 0,
           "cacheWrite": 0, "sessions": 1, "activeMinutes": 10}
    if project:
        row["project"] = project
    row.update(fields)
    return row


class UsageTests(ServerTestCase):
    def setUp(self):
        super().setUp()
        self.service.prices.install({"claude-opus-5": OPUS}, NOW)

    def send(self, mac, rows, days=(TODAY,), projects=(), **extra):
        status, data, _ = mac.call("POST", "/usage", {"days": list(days), "rows": rows, "projects": list(projects), **extra})
        return status, data

    def test_upload_is_priced_by_the_server_and_replaces_whole_days(self):
        mac = self.joined("burner")
        project = {"id": "p_quotabar01", "name": "QuotaBar", "repo": "github.com/gentpan/QuotaBar"}
        status, data = self.send(mac, [
            usage_row(output=1_000_000, project="p_quotabar01", costUSD=999),   # 服务端按价目算，不看上报的花费
            usage_row(output=1_000_000, project="p_quotabar01"),                 # 同一格出现两次就加起来
            usage_row(tool="opencode", mode="cli", model="opencode", costUSD=3.5, input=10),
            usage_row(tool="codex", model="gpt-5-codex", input=1_000_000, date="2026-09-15"),
        ], days=(TODAY, "2026-09-15"), projects=[project], timezone="Asia/Shanghai")
        self.assertEqual(status, 200, data)
        self.assertEqual(data, {"accepted": 3, "days": 2, "projects": [{"id": "p_quotabar01", "slug": "quotabar", "repoVerified": False}]})
        self.assertEqual(self.query("SELECT tool, cost_micro, sessions FROM usage_rows ORDER BY tool"),
                         [("claude", 50_000_000, 2), ("codex", 1_250_000, 1), ("opencode", 3_500_000, 1)])
        self.assertEqual(self.query("SELECT usage_timezone FROM users"), [("Asia/Shanghai",)])

        # 同一天再传一次：那天这台设备的行整个换掉，没提到的日子不动
        status, data = self.send(mac, [usage_row(output=2_000_000)], projects=[project])
        self.assertEqual(status, 200, data)
        self.assertEqual(self.query("SELECT date, tool, project_id, cost_micro FROM usage_rows ORDER BY date"),
                         [("2026-09-15", "codex", "", 1_250_000), (TODAY, "claude", "", 50_000_000)])
        # 没有用量指向的项目不再公开
        self.assertEqual(data["projects"], [])

        for rows, days, projects, fragment in [
            ([usage_row(date="2026-09-14")], (TODAY,), (), "date must be one of days"),
            ([usage_row(tool="cursor")], (TODAY,), (), "tool is"),
            ([usage_row(mode="phone")], (TODAY,), (), "mode is"),
            ([usage_row(model="bad model!")], (TODAY,), (), "model is"),
            ([usage_row(project="p_notlisted1")], (TODAY,), (), "project must be"),
            ([usage_row(output=-1)], (TODAY,), (), "output is"),
            ([], ("2024-01-01",), (), "days must be"),
            ([], ("2026-09-18",), (), "days must be"),
            ([], (TODAY,), ({"id": "short", "name": "x"},), "id must be"),
            ([], (TODAY,), ({"id": "p_quotabar01", "name": "x", "repo": "not a repo"},), "repo must"),
        ]:
            status, data = self.send(mac, rows, days=days, projects=projects)
            self.assertEqual((status, data["error"]), (400, "invalid_usage"), fragment)
            self.assertIn(fragment, data["message"])
        status, data = self.send(mac, [], timezone="Mars/Base")
        self.assertEqual((status, data["error"]), (400, "invalid_timezone"))
        self.assertEqual(self.http("POST", "/usage", b"{}", {"Content-Type": "application/json"})[0], 401)

    def test_quota_readings_verify_the_days_and_only_verified_usage_ranks_first(self):
        mac = self.joined("verifier")
        mac.run(NOW - 4 * 3600)    # Claude 的额度在今天涨了
        self.assertEqual(self.query("SELECT date, tool FROM usage_verified"), [(TODAY, "claude")])
        rival = self.joined("rival")
        self.send(rival, [usage_row(output=4_000_000)])
        self.send(mac, [usage_row(output=1_000_000), usage_row(tool="codex", model="gpt-5-codex", output=1_000_000),
                        usage_row(tool="opencode", model="opencode", costUSD=2)])

        board = self.get("/usage/boards")[1]   # 默认：本周、按花费、只算已核实
        self.assertEqual((board["metric"], board["period"], board["verified"], board["from"], board["to"]),
                         ("cost", "week", True, "2026-09-14", "2026-09-20"))
        self.assertEqual([(e["username"], e["value"]) for e in board["entries"]], [("verifier", 25.0)])
        everyone = self.get("/usage/boards", verified="0")[1]
        self.assertEqual([(e["username"], e["rank"], e["value"]) for e in everyone["entries"]],
                         [("rival", 1, 100.0), ("verifier", 2, 37.0)])
        verifier = everyone["entries"][1]
        self.assertEqual(verifier["verifiedShare"], round(25 / 37, 4))
        self.assertEqual([t["tool"] for t in verifier["tools"]], ["claude", "codex", "opencode"])
        self.assertEqual(everyone["summary"]["runners"], 2)
        self.assertEqual(len(everyone["summary"]["daily"]), 7)
        self.assertEqual(everyone["summary"]["daily"][2]["costUSD"], 137.0)
        tokens = self.get("/usage/boards", verified="0", metric="tokens", tool="codex")[1]
        self.assertEqual([(e["username"], e["value"]) for e in tokens["entries"]], [("verifier", 1_000_000)])
        for query, code in (({"metric": "fame"}, "invalid_metric"), ({"period": "decade"}, "invalid_period"),
                            ({"tool": "cursor"}, "invalid_tool"), ({"region": "mars"}, "invalid_region")):
            self.assertEqual(self.get("/usage/boards", **query)[1]["error"], code)

        # 服务商账号归了别人：那些日子不再算已核实
        self.link_email_to_other_account = None
        self.query_ok = self.service.recompute_verified
        self.service.db.execute("DELETE FROM account_owners")
        self.service.recompute_verified(self.query("SELECT id FROM users WHERE username = 'verifier'")[0][0])
        self.assertEqual(self.query("SELECT COUNT(*) FROM usage_verified"), [(0,)])

    def test_streaks_ranks_last_week_and_changes(self):
        early, late = self.joined("early"), self.joined("late")
        last_week = ["2026-09-08", "2026-09-09", "2026-09-10"]
        self.send(early, [usage_row(date=d, output=100_000) for d in last_week], days=last_week)
        self.send(late, [usage_row(date=d, output=1_000_000) for d in last_week], days=last_week)
        this_week = ["2026-09-14", "2026-09-15", TODAY]
        self.send(early, [usage_row(date=d, output=2_000_000) for d in this_week], days=this_week)
        self.send(late, [usage_row(output=1_000_000)])
        board = self.get("/usage/boards", verified="0")[1]
        self.assertEqual([(e["username"], e["change"], e["new"]) for e in board["entries"]], [("early", 1, False), ("late", -1, False)])
        last = self.get("/usage/boards", verified="0", period="last")[1]
        self.assertEqual([e["username"] for e in last["entries"]], ["late", "early"])
        streak = self.get("/usage/boards", verified="0", metric="streak", period="all")[1]
        self.assertEqual([(e["username"], e["value"], e["unit"]) for e in streak["entries"]], [("early", 3, "days"), ("late", 1, "days")])
        active = self.get("/usage/boards", verified="0", metric="active", period="month")[1]
        self.assertEqual([(e["username"], e["value"]) for e in active["entries"]], [("early", 6), ("late", 4)])

    def test_projects_board_detail_contributors_and_taking_a_project_private(self):
        owner = self.connect(self.account("octo"))
        _, params = self.oauth_start(owner.browser, "github", link="1")
        self.oauth_callback(owner.browser, "github", params["state"])     # GitHub 登录名 Octo-Cat
        helper = self.joined("helper")
        repo = {"id": "p_repo000001", "name": "Octo App", "repo": "github.com/Octo-Cat/app"}
        _, data = self.send(owner, [usage_row(output=2_000_000, project="p_repo000001"), usage_row(output=100_000)], projects=[repo])
        self.assertEqual(data["projects"], [{"id": "p_repo000001", "slug": "octo-app", "repoVerified": True}])
        self.send(helper, [usage_row(output=1_000_000, project="p_help000001")],
                  projects=[{"id": "p_help000001", "name": "Octo App", "repo": "github.com/octo-cat/app"}])
        self.send(owner, [usage_row(date="2026-09-08", output=1_000_000, project="p_repo000001")], days=["2026-09-08"], projects=[repo])

        board = self.get("/usage/projects")[1]
        self.assertEqual([(e["owner"]["username"], e["project"]["slug"], e["costUSD"], e["project"]["repoVerified"])
                          for e in board["entries"]], [("octo", "octo-app", 50.0, True), ("helper", "octo-app", 25.0, False)])
        self.assertEqual((board["entries"][0]["growth"], len(board["entries"][0]["spark"]), board["entries"][0]["spark"][-1]),
                         (1.0, 14, 50.0))
        self.assertEqual(board["summary"], {"projects": 2, "costUSD": 75.0, "tokens": 3_000_000})

        status, detail = self.get("/users/octo/projects/Octo-App")
        self.assertEqual(status, 200, detail)
        self.assertEqual((detail["project"]["name"], detail["owner"]["username"], detail["totals"]["week"]["costUSD"],
                          detail["totals"]["all"]["costUSD"], detail["firstDate"], detail["lastDate"]),
                         ("Octo App", "octo", 50.0, 75.0, "2026-09-08", TODAY))
        self.assertEqual(detail["ranks"]["week"], {"rank": 1, "projects": 2})
        self.assertEqual([(c["username"], c["self"]) for c in detail["contributors"]], [("octo", True), ("helper", False)])
        self.assertEqual(detail["repo"]["url"], "https://github.com/Octo-Cat/app")
        self.assertEqual(self.get("/users/octo/projects/nothing")[1]["error"], "project_not_found")

        usage = self.get("/users/octo/usage")[1]
        self.assertEqual((usage["totals"]["all"]["costUSD"], usage["streaks"], [p["slug"] for p in usage["projects"]]),
                         (77.5, {"current": 1, "longest": 1}, ["octo-app"]))
        self.assertEqual((usage["projects"][0]["weekCostUSD"], len(usage["projects"][0]["spark"]), usage["projects"][0]["rank"]),
                         (50.0, 30, 1))
        self.assertEqual(usage["ranks"]["week"], {"rank": None, "runners": 0})   # 没有核实过的用量

        # 不公开了：应用带 projectsComplete 把名单清空，项目立刻从榜上和主页消失，用量还在
        _, data = self.send(owner, [], days=[], projects=[], projectsComplete=True)
        self.assertEqual(data["projects"], [])
        self.assertEqual(self.get("/users/octo/projects/octo-app")[0], 404)
        self.assertEqual([e["owner"]["username"] for e in self.get("/usage/projects")[1]["entries"]], ["helper"])
        self.assertEqual(self.get("/users/octo/usage")[1]["totals"]["all"]["costUSD"], 77.5)

        self.assertEqual(owner.call("DELETE", "/account")[0], 204)
        self.assertEqual(self.query("SELECT COUNT(*) FROM usage_rows WHERE user_id NOT IN (SELECT id FROM users)"), [(0,)])

    def test_badges(self):
        mac = self.joined("badger")
        days = [f"2026-09-{day:02d}" for day in range(3, 17)]    # 连续 14 天
        rows = [usage_row(date=d, output=1_000_000) for d in days]
        rows += [usage_row(date=TODAY, tool="codex", mode="cli", model="gpt-5-codex", input=200_000_000),
                 usage_row(date=TODAY, tool="opencode", mode="cli", model="opencode", costUSD=1, input=10)]
        self.send(mac, rows, days=days, projects=[{"id": "p_badge00001", "name": "Badge"}])
        badges = {b["id"]: b for b in self.get("/users/badger")[1]["badges"]}
        self.assertEqual([b[0] for b in run_server.BADGES], list(badges))
        self.assertEqual((badges["streak"]["value"], badges["streak"]["tier"], badges["streak"]["next"]), (14, 1, 30))
        self.assertEqual((badges["spend"]["value"], badges["spend"]["tier"]), (601, 1))    # 14 × $25 + $250 + $1
        self.assertEqual((badges["bigday"]["value"], badges["bigday"]["tier"]), (201_000_010, 1))
        self.assertEqual((badges["tools"]["tier"], badges["tools"]["tiers"], badges["ways"]["value"]), (2, 2, 3))
        self.assertEqual((badges["projects"]["tier"], badges["podium"]["value"], badges["podium"]["tier"]), (0, None, 0))

    def test_live_events(self):
        mac = self.joined("streamer")
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        connection.request("GET", run_server.API_PREFIX + "/live")
        response = connection.getresponse()
        self.assertEqual((response.status, response.getheader("Content-Type")), (200, "text/event-stream; charset=utf-8"))

        def next_event():
            name, data = None, None
            while True:
                line = response.fp.readline().decode("utf-8").rstrip("\n")
                if line.startswith("event: "):
                    name = line[len("event: "):]
                elif line.startswith("data: "):
                    data = json.loads(line[len("data: "):])
                elif line == "" and name:
                    return name, data

        self.assertEqual(next_event()[0], "hello")
        self.send(mac, [usage_row(output=1_000_000)])
        name, data = next_event()
        self.assertEqual((name, data["username"], data["costUSD"], data["byTool"]), ("usage", "streamer", 25.0, {"claude": 25.0}))
        self.assertEqual(next_event()[0], "board")
        mac.run(NOW - 4 * 3600)
        name, data = next_event()
        while name != "reading":
            name, data = next_event()
        self.assertEqual((data["username"], data["provider"], data["usedPercent"], data["tier"]), ("streamer", "claude", 100.0, "verified"))
        connection.close()


class ComputationTests(unittest.TestCase):
    def test_streaks(self):
        day = datetime.date(2026, 9, 16)
        dates = {day - datetime.timedelta(days=n) for n in (1, 2, 3, 7, 8)}
        self.assertEqual(run_server.streaks(dates, day), (3, 3))            # 今天还没有，从昨天数
        self.assertEqual(run_server.streaks(dates | {day}, day), (4, 4))
        self.assertEqual(run_server.streaks(set(), day), (0, 0))
        self.assertEqual(run_server.slugify("  Octo App! 2 "), "octo-app-2")
        self.assertEqual(run_server.slugify("项目"), "project")

    def test_thresholds_and_completion(self):
        readings = [(0, 10), (600, 50), (1200, 89.9), (1800, 90), (2400, 99.4), (3000, 99.5), (3600, 100)]
        summary = run_server.summarize_run(readings, window_start=-600)
        self.assertEqual((summary["seconds_to_50"], summary["seconds_to_90"], summary["seconds_to_100"]),
                         (1200, 2400, 3600))
        self.assertEqual((summary["completed_at"], summary["end_at"], summary["peak_at"]), (3000, 3000, 3600))
        self.assertTrue(summary["monotonic"] and summary["plausible"] and summary["covered"])
        unfinished = run_server.summarize_run([(0, 10), (600, 99.4)], window_start=0)
        self.assertIsNone(unfinished["seconds_to_100"])
        self.assertIsNone(unfinished["completed_at"])

    def test_jump_checks_every_pair_within_five_minutes(self):
        self.assertFalse(run_server.summarize_run([(0, 0), (120, 30), (240, 65)], 0)["plausible"])
        self.assertTrue(run_server.summarize_run([(0, 0), (300, 65)], 0)["plausible"])
        self.assertTrue(run_server.summarize_run([(0, 2.1), (60, 62.1)], 0)["plausible"])

    def test_drop_tolerance(self):
        self.assertTrue(run_server.summarize_run([(0, 40), (60, 38)], 0)["monotonic"])
        self.assertFalse(run_server.summarize_run([(0, 40), (60, 50), (120, 47.9)], 0)["monotonic"])

    def test_coverage_stops_at_full(self):
        self.assertTrue(run_server.summarize_run([(0, 0), (1200, 100), (9999, 100)], 0)["covered"])
        self.assertFalse(run_server.summarize_run([(0, 0), (1201, 100)], 0)["covered"])

    def test_season_is_iso_week_utc(self):
        self.assertEqual(run_server.season_of(NOW), "2026-W38")
        self.assertEqual(run_server.season_of(1_798_761_600), "2026-W53")  # 2027-01-01

    def test_plan_normalisation(self):
        self.assertEqual(run_server.normalize_plan("Pro 20x"), "pro20x")
        self.assertEqual(run_server.normalize_plan("Pro_Plus"), "proplus")
        self.assertEqual(run_server.normalize_plan(None), "")

    def test_migrations_are_idempotent(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "run.db")
            for _ in range(2):
                run_server.RunService(path, b"k" * 32).close()
            connection = sqlite3.connect(path)
            try:
                self.assertEqual(connection.execute("SELECT version FROM schema_version").fetchall(), [(1,), (2,), (3,), (4,), (5,), (6,)])
            finally:
                connection.close()

    def test_a_version_one_database_is_migrated(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "run.db")
            connection = sqlite3.connect(path, isolation_level=None)
            connection.execute("CREATE TABLE schema_version (version INTEGER NOT NULL)")
            connection.executescript(run_server.SCHEMA_V1)
            connection.execute("INSERT INTO users(username, display_name, region, joined_at) VALUES ('old', 'Old', 'global', 1)")
            connection.close()
            run_server.RunService(path, b"k" * 32).close()
            connection = sqlite3.connect(path)
            try:
                tables = {row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
                self.assertNotIn("pair_codes", tables)
                self.assertTrue({"identities", "sessions", "email_codes", "oauth_states", "connect_requests"} <= tables)
                self.assertEqual(connection.execute("SELECT username FROM users").fetchall(), [("old",)])
            finally:
                connection.close()

    def test_a_version_two_database_gets_provider_account_owners(self):
        """升级前：共用账号的双方都是 flagged(disputed)、没有摘要的 run 照样上榜。升级后按新规则重算。"""
        secret = b"k" * 32

        def hmac_of(provider, email):
            return run_server.hmac.new(secret, account_digest(provider, email).encode(), hashlib.sha256).hexdigest()

        shared, late_own, spare = (hmac_of("cursor", "team@example.com"), hmac_of("cursor", "late@example.com"),
                                   hmac_of("cursor", "spare@example.com"))
        start = NOW - 4 * 3600
        resets = start + FIVE_HOURS
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "run.db")
            connection = sqlite3.connect(path, isolation_level=None)
            connection.execute("CREATE TABLE schema_version (version INTEGER NOT NULL)")
            connection.executescript(run_server.SCHEMA_V1)
            connection.executescript(run_server.SCHEMA_V2)
            for user_id, name in ((1, "old"), (2, "late"), (3, "nodigest")):
                connection.execute("INSERT INTO users(id, username, display_name, region, joined_at)"
                                   " VALUES (?, ?, ?, 'global', 1)", (user_id, name, name))
            connection.execute("INSERT INTO identities(id, user_id, provider, subject, email, email_verified,"
                               " linked_at, last_used_at) VALUES ('i2', 2, 'email', 'late@example.com',"
                               " 'late@example.com', 1, 1, 1)")
            bindings = [(shared, 1, NOW - 3000), (shared, 2, NOW - 2000), (late_own, 2, NOW - 2000),
                        (spare, 3, NOW - 1000)]
            connection.executemany("INSERT INTO account_bindings(account_hmac, user_id, first_seen_at) VALUES (?, ?, ?)",
                                   bindings)

            def insert_run(user_id, plan, account, counted=1, device="d"):
                for minute, used in FAST:
                    connection.execute(
                        "INSERT INTO snapshots(user_id, device_id, counted, provider, plan, plan_norm, account_hmac,"
                        " window_key, window_title, window_seconds, used_percent, resets_at, resets_bucket, rankable,"
                        " observed_at, source, received_at) VALUES (?, ?, ?, 'cursor', ?, ?, ?, '18000:', '5-hour window',"
                        " ?, ?, ?, ?, 1, ?, 'api', ?)",
                        (user_id, f"{device}{user_id}{plan}", counted, plan, plan.lower(), account, FIVE_HOURS, used, resets,
                         resets, start + minute * 60, NOW - 1000 + minute))

            insert_run(1, "Pro", shared)
            insert_run(2, "Pro", shared)
            insert_run(2, "Business", late_own)
            insert_run(3, "Pro", None)
            insert_run(3, "Business", spare, counted=0, device="other")
            connection.execute(
                "INSERT INTO runs(user_id, provider, plan_norm, window_key, window_seconds, resets_bucket, resets_at,"
                " window_start, season, peak_percent, peak_at, first_observed_at, last_observed_at, readings, tier,"
                " flag_reason, updated_at) VALUES (1, 'cursor', 'pro', '18000:', ?, ?, ?, ?, '2026-W38', 100, ?, ?, ?,"
                " 13, 'flagged', 'disputed', 1)", (FIVE_HOURS, resets, resets, start, start, start, start + 7200))
            connection.close()

            service = run_server.RunService(path, secret, clock=lambda: NOW + 60)
            try:
                self.assertEqual(service.stats()["runs"], 2)
                entries = service.leaderboard({"provider": "cursor", "plan": "pro", "window": "18000:"})["entries"]
                self.assertEqual([(e["username"], e["accountVerified"]) for e in entries], [("old", False)])
            finally:
                service.close()

            connection = sqlite3.connect(path)
            try:
                self.assertEqual(connection.execute("SELECT version FROM schema_version").fetchall(), [(1,), (2,), (3,), (4,), (5,), (6,)])
                self.assertEqual(sorted(connection.execute(
                    "SELECT account_hmac, provider, user_id, via FROM account_owners").fetchall()),
                    sorted([(shared, "cursor", 1, "first"), (late_own, "cursor", 2, "email")]))
                # 只有非计分读数的绑定去掉；provider 和 last_seen_at 从读数补上
                self.assertEqual(sorted(connection.execute(
                    "SELECT account_hmac, user_id, provider, last_seen_at FROM account_bindings").fetchall()),
                    sorted([(shared, 1, "cursor", NOW - 880), (shared, 2, "cursor", NOW - 880),
                            (late_own, 2, "cursor", NOW - 880)]))
                self.assertEqual(connection.execute(
                    "SELECT user_id, plan_norm, tier, flag_reason, account_verified FROM runs ORDER BY user_id, plan_norm"
                ).fetchall(), [(1, "pro", "verified", None, 0), (2, "business", "verified", None, 1),
                               (2, "pro", "flagged", "account_elsewhere", 0), (3, "pro", "unranked", "no_account", 0)])
                # 升级 3 里的重算已经按带 public_id 的表结构写
                ids = [row[0] for row in connection.execute("SELECT public_id FROM runs")]
                self.assertEqual(len(set(ids)), 4)
                self.assertTrue(all(re.fullmatch(r"[A-Za-z0-9_-]{12}", run_id) for run_id in ids))
            finally:
                connection.close()
            # 再打开一次不会重复升级
            run_server.RunService(path, secret).close()

    def test_a_version_three_database_gets_run_ids(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "run.db")
            run_server.RunService(path, b"k" * 32).close()
            connection = sqlite3.connect(path, isolation_level=None)
            connection.execute("INSERT INTO users(id, username, display_name, region, joined_at) VALUES (1, 'old', 'Old', 'global', 1)")
            for bucket in (1000, 2000, 3000):
                connection.execute(
                    "INSERT INTO runs(user_id, provider, plan_norm, window_key, window_seconds, resets_bucket, resets_at,"
                    " window_start, season, peak_percent, peak_at, first_observed_at, last_observed_at, readings, tier,"
                    " updated_at) VALUES (1, 'claude', 'max20x', '18000:', 18000, ?, ?, ?, '2026-W38', 50, 1, 1, 1, 1,"
                    " 'verified', 1)", (bucket, bucket, bucket - 18000))
            # 退回到 schema 3 的样子：没有 public_id 列和索引
            connection.execute("DROP INDEX runs_public_id")
            connection.execute("ALTER TABLE runs DROP COLUMN public_id")
            connection.execute("DELETE FROM schema_version WHERE version >= 4")
            connection.close()

            run_server.RunService(path, b"k" * 32).close()
            connection = sqlite3.connect(path)
            try:
                self.assertEqual(connection.execute("SELECT version FROM schema_version").fetchall(), [(1,), (2,), (3,), (4,), (5,), (6,)])
                ids = [row[0] for row in connection.execute("SELECT public_id FROM runs ORDER BY id")]
                self.assertEqual(len(set(ids)), 3)
                self.assertTrue(all(re.fullmatch(r"[A-Za-z0-9_-]{12}", run_id) for run_id in ids))
                index = connection.execute("SELECT sql FROM sqlite_master WHERE name = 'runs_public_id'").fetchone()[0]
                self.assertIn("UNIQUE", index)
                with self.assertRaises(sqlite3.IntegrityError):
                    connection.execute("UPDATE runs SET public_id = ? WHERE id = (SELECT MAX(id) FROM runs)", (ids[0],))
            finally:
                connection.close()
            # 再打开不会换 id
            run_server.RunService(path, b"k" * 32).close()
            connection = sqlite3.connect(path)
            try:
                self.assertEqual([row[0] for row in connection.execute("SELECT public_id FROM runs ORDER BY id")], ids)
            finally:
                connection.close()

    def test_previous_season(self):
        self.assertEqual(run_server.previous_season("2026-W38"), "2026-W37")
        self.assertEqual(run_server.previous_season("2026-W01"), "2025-W52")
        self.assertEqual(run_server.previous_season("2021-W01"), "2020-W53")
        self.assertEqual(run_server.previous_season("2027-W01"), "2026-W53")
        self.assertIsNone(run_server.previous_season("all"))
        self.assertIsNone(run_server.previous_season("0001-W01"))

    def test_percentiles_and_shares(self):
        tens = list(range(1, 11))
        self.assertEqual([run_server.nearest_rank(tens, p) for p in (10, 50, 90)], [1, 5, 9])
        thirty = list(range(1, 31))
        self.assertEqual([run_server.nearest_rank(thirty, p) for p in (10, 50, 90)], [3, 15, 27])
        self.assertEqual([run_server.nearest_rank([7], p) for p in (10, 50, 90)], [7, 7, 7])
        self.assertEqual([run_server.nearest_rank([1, 2], p) for p in (10, 50, 90)], [1, 1, 2])
        self.assertIsNone(run_server.nearest_rank([], 50))
        self.assertEqual(run_server.lower_median([1, 2, 3, 4]), 2)
        self.assertEqual(run_server.lower_median([1, 2, 3]), 2)
        self.assertIsNone(run_server.lower_median([]))
        self.assertEqual((run_server.share(1, 3), run_server.share(2, 3), run_server.share(0, 4)), (0.3333, 0.6667, 0.0))
        self.assertIsNone(run_server.share(0, 0))

    def test_downsampling_keeps_first_last_and_thresholds(self):
        few = [(i * 60, float(i)) for i in range(240)]
        self.assertEqual(run_server.downsample_readings(few), few)
        # 一开始就连跳三条线：均匀抽取不会碰到下标 1、2、3，只有保留规则会留下它们
        many = [(0, 0.0), (60, 50.0), (120, 90.0), (180, 99.5)] + [(i * 60, 100.0) for i in range(4, 1000)]
        kept = run_server.downsample_readings(many)
        self.assertEqual(len(kept), 240)
        self.assertEqual(kept[:4], many[:4])
        self.assertEqual(kept[-1], many[-1])
        self.assertEqual(kept, sorted(set(kept)))
        # 没有到线的读数：保留首尾，其余按下标均匀抽
        flat = [(i, 0.0) for i in range(10)]
        self.assertEqual([t for t, _ in run_server.downsample_readings(flat, limit=6)], [0, 1, 3, 5, 8, 9])
        # 阈值读数在中间、抽样步长跨过它们时照样保留
        ramp = [(i, min(100.0, i / 10)) for i in range(2000)]
        kept = run_server.downsample_readings(ramp)
        self.assertEqual(len(kept), 240)
        for index in (0, 500, 900, 995, 1999):
            self.assertIn(ramp[index], kept)

    def test_secret_file_is_generated_private(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "etc", "secret")
            first = run_server.load_secret(path)
            self.assertEqual(len(first), 32)
            self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
            self.assertEqual(run_server.load_secret(path), first)

    def test_small_helpers(self):
        self.assertEqual(run_server.normalize_user_code("abcd efgh"), "ABCDEFGH")
        self.assertIsNone(run_server.normalize_user_code("ABCD-EFG0"))
        self.assertEqual(run_server.with_query("/a?b=1#c", "error=x"), "/a?b=1&error=x#c")
        self.assertEqual(run_server.parse_cookies('a=1; qr_session="tok"; a=2; junk'), {"a": "1", "qr_session": "tok"})
        self.assertEqual(run_server.username_base("Octo..Cat_"), "octo-cat")
        self.assertIsNone(run_server.normalize_email("üser@example.com"))
        subject, text = run_server.email_code_message("012345", "zh")
        self.assertEqual(subject, "Quota Run 验证码：012345")
        self.assertIn("什么都不会发生", text)


if __name__ == "__main__":
    unittest.main()

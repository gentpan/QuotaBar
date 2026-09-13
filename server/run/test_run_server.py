"""Quota Run 服务端测试。

在进程内起一个真实的 HTTP 服务（临时数据库、临时密钥、假时钟），用 cryptography 生成
P-256 密钥，像应用那样签名请求。运行：

    python3 -m unittest server/run/test_run_server.py      # 仓库根目录
    cd server/run && python3 -m unittest                   # 或者在本目录
"""
import base64
import hashlib
import http.client
import json
import os
import secrets
import sqlite3
import sys
import tempfile
import threading
import unittest
from urllib.parse import urlencode

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import run_server  # noqa: E402
from cryptography.hazmat.primitives import hashes, serialization  # noqa: E402
from cryptography.hazmat.primitives.asymmetric import ec  # noqa: E402

NOW = 1_789_560_000            # 2026-09-16 12:00 UTC，星期三，ISO 周 2026-W38
FIVE_HOURS = 18_000
DAY = 86_400
# 两小时从 0 涨到 100%，每 10 分钟一条
FAST = [(minute, round(minute * 100 / 120, 1)) for minute in range(0, 121, 10)]


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


class Mac:
    """一台装了 QuotaBar 的 Mac：自己的 P-256 私钥，按契约签名每个请求。"""

    def __init__(self, test):
        self.test = test
        self.key = ec.generate_private_key(ec.SECP256R1())
        self.device_id = None
        self.digest = None

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

    def join_with(self, code):
        status, data, _ = self.call("POST", "/register", {
            "pairCode": code, "publicKey": self.public_key, "deviceName": "Air", "platform": "macos",
            "appVersion": "0.6.0"})
        if status == 201:
            self.device_id = data["deviceId"]
        return status, data

    def upload(self, snapshots, activity=None):
        status, data, _ = self.call("POST", "/snapshots", {"snapshots": snapshots, "activity": activity or []})
        self.test.assertEqual(status, 200, data)
        return data

    def run(self, start, points=FAST, provider="claude", with_activity=True, digest="default", **fields):
        """上传一整段读数，默认附上活动分钟和账号摘要，正好满足 verified。"""
        digest = self.digest if digest == "default" else digest
        activity = [{"minute": start + 300, "source": provider, "tokens": 1200}] if with_activity else []
        return self.upload(series(start, points, provider=provider, digest=digest, **fields), activity)


class ServerTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.clock = Clock(NOW)
        self.db_path = os.path.join(self.tmp.name, "run.db")
        secret = run_server.load_secret(os.path.join(self.tmp.name, "secret"))
        generous = (100_000, 1.0)
        self.service = run_server.RunService(self.db_path, secret, clock=self.clock, cache_ttl=0,
                                             limits={"write": generous, "register": generous, "public": generous})
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

    def http(self, method, route, body=b"", headers=None, query=None):
        path = run_server.API_PREFIX + route
        if query:
            path += "?" + urlencode(query)
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=20)
        try:
            connection.request(method, path, body=body or None, headers=headers or {})
            response = connection.getresponse()
            raw = response.read()
            data = json.loads(raw) if raw else None
            return response.status, data, {k.lower(): v for k, v in response.getheaders()}
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

    def joined(self, username, region="global"):
        mac = Mac(self)
        status, data = mac.register(username, region=region)
        self.assertEqual(status, 201, data)
        return mac

    def paired(self, mac):
        status, data, _ = mac.call("POST", "/pair")
        self.assertEqual(status, 200, data)
        other = Mac(self)
        status, joined = other.join_with(data["code"])
        self.assertEqual(status, 201, joined)
        other.digest = mac.digest
        return other

    def query(self, sql, params=()):
        connection = sqlite3.connect(self.db_path)
        try:
            return connection.execute(sql, params).fetchall()
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
                                          "lastSeenAt": NOW, "current": True}])
        self.assertIsNone(me["rankedChangeAvailableAt"])
        self.assertIsNone(me["lastUploadAt"])
        self.assertEqual(me["projects"], [])

    def test_username_rules_and_taken(self):
        for bad in ["ab", "-abc", "_abc", "admin", "Leaderboard", "a" * 21, "has space", "ümlaut", "", None]:
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

    def test_pairing_a_second_mac(self):
        first = self.joined("pairer")
        status, pair, _ = first.call("POST", "/pair")
        self.assertEqual(status, 200)
        self.assertEqual(len(pair["code"]), 8)
        self.assertEqual(pair["expiresAt"], NOW + 600)

        second = Mac(self)
        typed = pair["code"][:4].lower() + "-" + pair["code"][4:].lower()
        status, data = second.join_with(typed)
        self.assertEqual(status, 201, data)
        self.assertEqual(data["user"]["username"], "pairer")
        self.assertFalse(data["ranked"])
        _, me, _ = first.call("GET", "/me")
        self.assertEqual([(d["ranked"], d["current"]) for d in me["devices"]], [(True, True), (False, False)])

        status, data = Mac(self).join_with(pair["code"])
        self.assertEqual((status, data["error"]), (404, "pair_code_invalid"))

        _, pair, _ = first.call("POST", "/pair")
        self.clock.advance(601)
        status, data = Mac(self).join_with(pair["code"])
        self.assertEqual((status, data["error"]), (404, "pair_code_invalid"))

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
        self.assertEqual(board["entries"], [{
            "rank": 1, "username": "sprinter", "displayName": "Sprinter", "value": 7200, "unit": "seconds",
            "tier": "verified", "achievedAt": start + 7200, "peakPercent": 100.0}])
        self.assertEqual(len(self.board(tier="verified")["entries"]), 1)

        status, boards = self.get("/boards", region="global")
        self.assertEqual(status, 200)
        self.assertEqual([(b["provider"], b["plan"], b["windowKey"], b["runners"]) for b in boards["boards"]],
                         [("claude", "max20x", "18000:", 1)])
        stats = self.get("/stats")[1]
        self.assertEqual((stats["users"], stats["runs"], stats["verifiedRuns"], stats["providers"]), (1, 1, 1, 1))

        recent = self.get("/users/sprinter")[1]["recent"][0]
        self.assertEqual((recent["secondsTo50"], recent["secondsTo90"], recent["secondsTo100"]), (3600, 6600, 7200))
        self.assertEqual((recent["windowStart"], recent["completedAt"]), (start, start + 7200))

    def test_gap_over_twenty_minutes_is_standard(self):
        mac = self.joined("gappy")
        points = [(0, 0), (10, 10), (40, 40), (60, 60), (80, 80), (100, 100)]
        mac.run(NOW - 4 * 3600, points)
        self.assertEqual(self.run_tiers(), ["standard"])
        self.assertEqual(self.board()["entries"][0]["tier"], "standard")
        self.assertEqual(self.board(tier="verified")["entries"], [])

    def test_missing_account_digest_is_standard(self):
        mac = self.joined("nodigest")
        mac.run(NOW - 4 * 3600, digest=None)
        self.assertEqual(self.run_tiers(), ["standard"])

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

    def test_shared_provider_account_is_disputed(self):
        first = self.joined("owner")
        second = self.joined("borrower")
        second.digest = first.digest
        start = NOW - 4 * 3600
        first.run(start)
        self.assertEqual(self.run_tiers(), ["verified"])
        second.run(start + 600)
        self.assertEqual(self.run_tiers(), ["flagged", "flagged"])
        self.assertEqual(self.board()["entries"], [])
        self.assertEqual(self.get("/users/owner")[1]["recent"], [])
        # 争议的另一方离开后，剩下那位的 run 恢复
        self.assertEqual(second.call("DELETE", "/account")[0], 204)
        self.assertEqual(self.run_tiers(), ["verified"])
        self.assertEqual([e["username"] for e in self.board()["entries"]], ["owner"])

    def assert_flagged_everywhere(self, username, reason):
        rows = self.query("SELECT tier, flag_reason FROM runs")
        self.assertEqual(rows, [("flagged", reason)])
        self.assertEqual(self.board()["entries"], [])
        self.assertEqual(self.board(metric="peak")["entries"], [])
        self.assertEqual(self.get("/boards")[1]["boards"], [])
        profile = self.get(f"/users/{username}")[1]
        self.assertEqual((profile["bests"], profile["recent"], profile["stats"]["runs"]), ([], [], 0))
        self.assertEqual(self.get("/stats")[1]["runs"], 0)

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


class ProfileTests(ServerTestCase):
    def test_profile_projects_and_bests(self):
        mac = self.joined("builder")
        status, data, _ = mac.call("PUT", "/profile", {
            "displayName": "The Builder", "bio": "Ships things.", "region": "china",
            "links": {"website": "https://builder.dev", "github": "@gentpan", "x": "https://x.com/gentpan"}})
        self.assertEqual(status, 200, data)
        self.assertEqual(data["user"]["links"], {"website": "https://builder.dev",
                                                 "github": "https://github.com/gentpan", "x": "https://x.com/gentpan"})
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
        for secret in (mac.device_id, mac.digest, self.service.account_hmac(mac.digest)):
            self.assertNotIn(secret, text)
        board_text = json.dumps(self.board())
        self.assertNotIn(mac.device_id, board_text)
        self.assertNotIn(mac.digest, board_text)

        status, data, headers = self.http("GET", "/users/nobody-here")
        self.assertEqual((status, data["error"]), (404, "user_not_found"))
        self.assertEqual(headers["cache-control"], "public, max-age=30")

        _, me, _ = mac.call("GET", "/me")
        self.assertEqual(len(me["projects"]), 2)


class AccountTests(ServerTestCase):
    def test_delete_account_removes_every_row(self):
        mac = self.joined("leaver")
        other_mac = self.paired(mac)
        stayer = self.joined("stayer")
        stayer.run(NOW - 4 * 3600)
        mac.run(NOW - 4 * 3600)
        other_mac.upload([], [{"minute": NOW - 600, "source": "codex", "tokens": 9}])
        mac.call("PUT", "/projects", {"projects": [{"name": "X", "url": "https://x.dev"}]})
        mac.call("POST", "/pair")

        user_id = self.query("SELECT id FROM users WHERE username = 'leaver'")[0][0]
        status, data, headers = mac.call("DELETE", "/account")
        self.assertEqual((status, data), (204, None))
        self.assertEqual(headers["cache-control"], "no-store")

        for table in ("devices", "snapshots", "activity", "runs", "projects", "pair_codes", "account_bindings"):
            count = self.query(f"SELECT COUNT(*) FROM {table} WHERE user_id = ?", (user_id,))[0][0]
            self.assertEqual(count, 0, table)
        self.assertEqual(self.query("SELECT COUNT(*) FROM users WHERE id = ?", (user_id,))[0][0], 0)
        nonces = self.query("SELECT COUNT(*) FROM nonces WHERE scope IN (?, ?)",
                            (mac.device_id, other_mac.device_id))[0][0]
        self.assertEqual(nonces, 0)
        self.assertEqual(mac.call("GET", "/me")[1]["error"], "unknown_device")
        self.assertEqual(other_mac.call("GET", "/me")[1]["error"], "unknown_device")
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

    def test_register_rate_limit_per_ip(self):
        self.service.limits["register"] = (2, 10.0)
        self.assertEqual(Mac(self).register("one-1")[0], 201)
        self.assertEqual(Mac(self).register("two-2")[0], 201)
        self.assertEqual(Mac(self).register("three-3")[0], 429)

    def test_body_over_one_megabyte_is_413(self):
        mac = self.joined("bulky")
        raw = b'{"snapshots": [], "pad": "' + b"x" * 1_100_000 + b'"}'
        status, data, _ = mac.call("POST", "/snapshots", raw=raw)
        self.assertEqual((status, data["error"]), (413, "body_too_large"))
        self.assertEqual(mac.call("GET", "/me")[0], 200)

    def test_unknown_route_is_404(self):
        self.assertEqual(self.get("/nope")[0], 404)
        self.assertEqual(self.http("GET", "/../../etc/passwd")[0], 404)

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


class ComputationTests(unittest.TestCase):
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
                self.assertEqual(connection.execute("SELECT version FROM schema_version").fetchall(), [(1,)])
            finally:
                connection.close()

    def test_secret_file_is_generated_private(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "etc", "secret")
            first = run_server.load_secret(path)
            self.assertEqual(len(first), 32)
            self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
            self.assertEqual(run_server.load_secret(path), first)


if __name__ == "__main__":
    unittest.main()

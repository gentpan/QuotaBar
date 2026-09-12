#!/usr/bin/env python3
"""quota.bar 的反馈接收端：一个只依赖标准库的小 HTTP 服务。

POST /api/feedback，JSON 体：
  {"kind": "bug|idea|other", "message": "...", "contact": "可选",
   "app": "0.4.0 (11)", "macos": "27.0", "locale": "zh-Hans", "diagnostics": {...}}

每条反馈追加写入 FEEDBACK_DIR/feedback.jsonl；若配置了 GITHUB_TOKEN 与
GITHUB_REPO，再以 issue 的形式建到仓库里（用户无需登录，令牌只在服务器上）。
响应：{"ok": true, "id": "...", "issue_url": "..."?}。

环境变量（/etc/quotabar-feedback.env）：
  FEEDBACK_DIR   存放目录，默认 /var/lib/quotabar
  FEEDBACK_PORT  监听端口，默认 8787（只绑 127.0.0.1，由 nginx 反代）
  GITHUB_TOKEN   可选，仅需 Issues 写权限的 fine-grained token
  GITHUB_REPO    可选，如 gentpan/quotabar
  GITHUB_LABEL   可选，默认 feedback
"""
import json
import os
import sys
import time
import uuid
import urllib.request
from collections import defaultdict, deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

FEEDBACK_DIR = os.environ.get("FEEDBACK_DIR", "/var/lib/quotabar")
PORT = int(os.environ.get("FEEDBACK_PORT", "8787"))
GITHUB_TOKEN = os.environ.get("GITHUB_TOKEN", "").strip()
GITHUB_REPO = os.environ.get("GITHUB_REPO", "").strip()
GITHUB_LABEL = os.environ.get("GITHUB_LABEL", "feedback").strip()
MAX_BODY = 20_000
RATE_LIMIT = 10          # 每个来源 IP 每小时
KINDS = {"bug": "问题", "idea": "建议", "other": "其他"}

_recent = defaultdict(deque)


def client_ip(handler):
    forwarded = handler.headers.get("X-Forwarded-For", "")
    if forwarded:
        return forwarded.split(",")[0].strip()
    return handler.client_address[0]


def rate_limited(ip):
    now = time.time()
    window = _recent[ip]
    while window and now - window[0] > 3600:
        window.popleft()
    if len(window) >= RATE_LIMIT:
        return True
    window.append(now)
    return False


def store(entry):
    os.makedirs(FEEDBACK_DIR, exist_ok=True)
    path = os.path.join(FEEDBACK_DIR, "feedback.jsonl")
    with open(path, "a", encoding="utf-8") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")


def github_issue(entry):
    if not GITHUB_TOKEN or not GITHUB_REPO:
        return None
    kind = KINDS.get(entry["kind"], "其他")
    first_line = entry["message"].strip().splitlines()[0][:72] if entry["message"].strip() else "（无内容）"
    title = f"[{kind}] {first_line}"
    diag = entry.get("diagnostics") or {}
    lines = [entry["message"].strip(), "", "---",
             f"- 版本：{entry.get('app') or '?'} · macOS {entry.get('macos') or '?'} · {entry.get('locale') or '?'}"]
    for key, value in diag.items():
        lines.append(f"- {key}：{value}")
    if entry.get("contact"):
        lines.append(f"- 联系方式：{entry['contact']}")
    lines.append(f"- 反馈编号：{entry['id']}")
    body = json.dumps({"title": title, "body": "\n".join(lines), "labels": [GITHUB_LABEL]}).encode()
    request = urllib.request.Request(
        f"https://api.github.com/repos/{GITHUB_REPO}/issues", data=body, method="POST",
        headers={"Authorization": f"Bearer {GITHUB_TOKEN}", "Accept": "application/vnd.github+json",
                 "Content-Type": "application/json", "User-Agent": "quota.bar-feedback"})
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            return json.load(response).get("html_url")
    except Exception as error:  # 建 issue 失败不影响落盘，反馈不丢
        print(f"github: {error}", file=sys.stderr)
        return None


class Handler(BaseHTTPRequestHandler):
    server_version = "quotabar-feedback/1"

    def log_message(self, fmt, *args):  # 不记 IP 以外的内容
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    def reply(self, code, payload):
        data = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path.rstrip("/") == "/api/feedback":
            return self.reply(200, {"ok": True, "accepts": "POST", "github": bool(GITHUB_TOKEN and GITHUB_REPO)})
        self.reply(404, {"ok": False, "error": "not found"})

    def do_POST(self):
        if self.path.rstrip("/") != "/api/feedback":
            return self.reply(404, {"ok": False, "error": "not found"})
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > MAX_BODY:
            return self.reply(413, {"ok": False, "error": "body too large"})
        try:
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
        except Exception:
            return self.reply(400, {"ok": False, "error": "bad json"})
        message = str(payload.get("message") or "").strip()
        if len(message) < 3:
            return self.reply(400, {"ok": False, "error": "message too short"})
        ip = client_ip(self)
        if rate_limited(ip):
            return self.reply(429, {"ok": False, "error": "too many"})
        entry = {
            "id": uuid.uuid4().hex[:12],
            "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "kind": payload.get("kind") if payload.get("kind") in KINDS else "other",
            "message": message[:8000],
            "contact": str(payload.get("contact") or "")[:200],
            "app": str(payload.get("app") or "")[:60],
            "macos": str(payload.get("macos") or "")[:40],
            "locale": str(payload.get("locale") or "")[:20],
            "diagnostics": {str(k)[:40]: str(v)[:200] for k, v in (payload.get("diagnostics") or {}).items()} if isinstance(payload.get("diagnostics"), dict) else {},
            "test": bool(payload.get("test")),
        }
        store(entry)
        issue_url = None if entry["test"] else github_issue(entry)
        self.reply(200, {"ok": True, "id": entry["id"], "issue_url": issue_url})


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"quotabar feedback on 127.0.0.1:{PORT}, dir={FEEDBACK_DIR}, github={'on' if GITHUB_TOKEN and GITHUB_REPO else 'off'}", file=sys.stderr)
    server.serve_forever()

#!/bin/bash
# Installs the Quota Run API on the quota.bar host and wires Caddy to it.
# Idempotent: re-running updates the code and restarts the service; the database,
# the HMAC secret and existing Caddy lines are left as they are.
set -euo pipefail
cd "$(dirname "$0")/.."
HOST="${SITE_HOST:-root@15.204.80.137}"
KEY="${SITE_KEY:-$HOME/.ssh/gentpan.pem}"
SSH="ssh -i $KEY -o BatchMode=yes -o ConnectTimeout=25"

# 先在本机跑一遍测试；本机没装 cryptography 时跳过（服务器上有）
if python3 -c 'import cryptography' 2>/dev/null; then
  echo "== 本地测试 =="
  python3 -m unittest server/run/test_run_server.py
else
  echo "本机没有 cryptography，跳过测试"
fi

rsync -az --delete --exclude '__pycache__/' --exclude 'test_*.py' -e "$SSH" server/run/ "$HOST:/opt/quotabar-run/"
$SSH "$HOST" bash -s <<'REMOTE'
set -euo pipefail
python3 -c 'import sys, cryptography; assert sys.version_info >= (3, 11)' \
  || { echo "需要 python3 ≥ 3.11 与 python3-cryptography"; exit 1; }

# 专用系统用户：数据库和密钥只归它
id -u quotabar-run >/dev/null 2>&1 \
  || useradd --system --home-dir /var/lib/quotabar-run --no-create-home --shell /usr/sbin/nologin quotabar-run
install -d -m 750 -o quotabar-run -g quotabar-run /var/lib/quotabar-run

# HMAC 密钥在服务器上生成，从不回显；已存在就不动——换密钥会让所有账号绑定失效
if [ ! -s /etc/quotabar-run.secret ]; then
  (umask 077; python3 -c 'import secrets; print(secrets.token_hex(32))' > /etc/quotabar-run.secret)
  echo "已生成 /etc/quotabar-run.secret"
fi
chown quotabar-run:quotabar-run /etc/quotabar-run.secret
chmod 600 /etc/quotabar-run.secret

install -m 644 /opt/quotabar-run/quotabar-run.service /etc/systemd/system/quotabar-run.service
systemctl daemon-reload
systemctl enable quotabar-run >/dev/null
systemctl restart quotabar-run

# Caddy：往 quota.bar 站点块里加 /api/run/* 反代和 /@username 改写；已经有了就不重复加
site=/etc/caddy/sites/quota.bar.caddy
run_site=/etc/caddy/sites/quota.run.caddy
snippet=/opt/quotabar-run/caddy-snippet.caddy
if [ ! -f "$site" ]; then echo "找不到 $site"; exit 1; fi
backup=$(mktemp)
cp -p "$site" "$backup"
added_run_site=0
if ! grep -q "/api/run/" "$site"; then
  python3 - "$site" "$snippet" <<'PYCADDY'
import re, sys
path, snippet_path = sys.argv[1], sys.argv[2]
snippet = open(snippet_path).read()
begin, end = "# ---- BEGIN quota.bar ----\n", "# ---- END quota.bar ----"
block = snippet[snippet.index(begin) + len(begin):snippet.index(end)]
text = open(path).read()
match = re.search(r"(?m)^quota\.bar\s*\{", text)
idx = match.start() if match else text.index('quota.bar {')
depth = 0; end_at = None
for i in range(idx, len(text)):
    if text[i] == '{': depth += 1
    elif text[i] == '}':
        depth -= 1
        if depth == 0:
            end_at = i
            break
text = text[:end_at] + block + text[end_at:]
open(path, 'w').write(text)
print('已插入 Quota Run 的 handle 与 rewrite 到', path)
PYCADDY
fi
# quota.run 的跳转站点：域名解析到位后才装，否则 Caddy 会不停地申请证书失败
if [ ! -f "$run_site" ]; then
  if getent hosts quota.run >/dev/null 2>&1; then
    python3 - "$snippet" "$run_site" <<'PYRUN'
import sys
snippet = open(sys.argv[1]).read()
begin, end = "# ---- BEGIN quota.run ----\n", "# ---- END quota.run ----"
open(sys.argv[2], 'w').write(snippet[snippet.index(begin) + len(begin):snippet.index(end)])
print('已写入', sys.argv[2])
PYRUN
    added_run_site=1
    grep -q "sites/" /etc/caddy/Caddyfile || echo "注意：/etc/caddy/Caddyfile 似乎没有 import sites/*，quota.run 站点块不会生效"
  else
    echo "quota.run 还没有解析到任何地址，跳过它的站点块（解析好后重跑本脚本）"
  fi
fi
if caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
  systemctl reload caddy
else
  echo "caddy validate 失败，恢复原配置："
  caddy validate --config /etc/caddy/Caddyfile 2>&1 | tail -5 || true
  cp -p "$backup" "$site"
  [ "$added_run_site" = 1 ] && rm -f "$run_site"
  rm -f "$backup"
  exit 1
fi
rm -f "$backup"
sleep 1
systemctl is-active quotabar-run
curl -s -o /dev/null -w 'GET 本机 %{http_code}\n' http://127.0.0.1:8788/api/run/v1/stats
REMOTE
echo "== 公网验证 =="
curl -s --max-time 20 https://quota.bar/api/run/v1/stats; echo

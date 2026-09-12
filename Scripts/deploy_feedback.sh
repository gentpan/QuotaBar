#!/bin/bash
# Installs the feedback receiver on the quota.bar host and wires nginx to it.
# Idempotent: re-running updates the script and reloads the service.
set -euo pipefail
cd "$(dirname "$0")/.."
HOST="${SITE_HOST:-root@5.9.73.228}"
KEY="${SITE_KEY:-$HOME/.ssh/gentpan.pem}"
SSH="ssh -i $KEY -o BatchMode=yes -o ConnectTimeout=25"

rsync -az -e "$SSH" server/feedback/ "$HOST:/opt/quotabar-feedback/"
$SSH "$HOST" bash -s <<'REMOTE'
set -euo pipefail
install -m 644 /opt/quotabar-feedback/quotabar-feedback.service /etc/systemd/system/quotabar-feedback.service
mkdir -p /var/lib/quotabar && chown www-data:www-data /var/lib/quotabar
[ -f /etc/quotabar-feedback.env ] || { echo "# GITHUB_TOKEN=…  GITHUB_REPO=gentpan/quotabar" > /etc/quotabar-feedback.env; chmod 600 /etc/quotabar-feedback.env; }
systemctl daemon-reload
systemctl enable --now quotabar-feedback >/dev/null
systemctl restart quotabar-feedback
# nginx：找到 quota.bar 的 server 块所在文件，没有 location 就插到块尾
conf=$(grep -lR "server_name quota.bar" /etc/nginx/sites-enabled /etc/nginx/conf.d 2>/dev/null | head -1)
if [ -z "$conf" ]; then echo "找不到 quota.bar 的 nginx 配置"; exit 1; fi
if ! grep -q "location /api/feedback" "$conf"; then
  python3 - "$conf" <<'PY'
import re, sys
path = sys.argv[1]; text = open(path).read()
snippet = open('/opt/quotabar-feedback/nginx-location.conf').read()
# 在含 server_name quota.bar 的 server 块里，把 location 插在该块最后一个 "}" 之前
idx = text.index('server_name quota.bar')
start = text.rfind('server {', 0, idx)
depth = 0; end = None
for i in range(start, len(text)):
    if text[i] == '{': depth += 1
    elif text[i] == '}':
        depth -= 1
        if depth == 0: end = i; break
text = text[:end] + snippet + text[end:]
open(path, 'w').write(text)
print('已插入 location 到', path)
PY
fi
nginx -t && systemctl reload nginx
sleep 1
systemctl is-active quotabar-feedback
curl -s -o /dev/null -w 'GET 本机 %{http_code}\n' http://127.0.0.1:8787/api/feedback
REMOTE
echo "== 公网验证 =="
curl -s --max-time 20 https://quota.bar/api/feedback; echo
curl -s --max-time 20 -X POST https://quota.bar/api/feedback -H 'Content-Type: application/json' \
  -d '{"kind":"other","message":"deploy self-test","test":true,"app":"deploy"}'; echo

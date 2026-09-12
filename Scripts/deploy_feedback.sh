#!/bin/bash
# Installs the feedback receiver on the quota.bar host and wires Caddy to it.
# Idempotent: re-running updates the script and reloads the service.
set -euo pipefail
cd "$(dirname "$0")/.."
HOST="${SITE_HOST:-root@15.204.80.137}"
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
# Caddy：在 quota.bar 的站点块里加 /api/feedback 的反代；没有就插到块尾
site=/etc/caddy/sites/quota.bar.caddy
if [ ! -f "$site" ]; then echo "找不到 $site"; exit 1; fi
if ! grep -q "/api/feedback" "$site"; then
  python3 - "$site" <<'PYCADDY'
import sys
path = sys.argv[1]; text = open(path).read()
snippet = "\thandle /api/feedback* {\n\t\treverse_proxy 127.0.0.1:8787\n\t}\n"
idx = text.index('quota.bar {')
depth = 0; end = None
for i in range(idx, len(text)):
    if text[i] == '{': depth += 1
    elif text[i] == '}':
        depth -= 1
        if depth == 0:
            end = i
            break
text = text[:end] + snippet + text[end:]
open(path, 'w').write(text)
print('已插入 handle /api/feedback 到', path)
PYCADDY
fi
caddy validate --config /etc/caddy/Caddyfile >/dev/null && systemctl reload caddy
sleep 1
systemctl is-active quotabar-feedback
curl -s -o /dev/null -w 'GET 本机 %{http_code}\n' http://127.0.0.1:8787/api/feedback
REMOTE
echo "== 公网验证 =="
curl -s --max-time 20 https://quota.bar/api/feedback; echo
curl -s --max-time 20 -X POST https://quota.bar/api/feedback -H 'Content-Type: application/json' \
  -d '{"kind":"other","message":"deploy self-test","test":true,"app":"deploy"}'; echo

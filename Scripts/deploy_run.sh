#!/bin/bash
# Installs the Quota Run API on the quota.bar host and wires Caddy: quota.run serves
# the pages (synced by deploy_site.sh) and /api/*; quota.bar only redirects old addresses.
# Idempotent: re-running updates the code and restarts the service; the database,
# the login settings in /etc/quotabar-run.env (created empty once, never overwritten)
# and the HMAC secret are left as they are; the Caddy blocks are replaced.
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

# 登录配置（GitHub / Google / SMTP 的密钥）放在 /etc/quotabar-run.env，由 Scripts/configure_run_login.sh
# 写入。这里只在文件不存在时放一个只有变量名的空模板；已存在就绝不覆盖，也从不回显它的内容。
if [ ! -e /etc/quotabar-run.env ]; then
  (umask 027; cat > /etc/quotabar-run.env <<'ENVTEMPLATE'
# Quota Run 线上配置：systemd EnvironmentFile，由 quotabar-run.service 读取。
# 每行 KEY=value，不加引号、不加 export；去掉行首的 # 再填值，改完 systemctl restart quotabar-run。
# 没填的登录方式在 GET /api/v1/auth/providers 里是 false。可以用 Scripts/configure_run_login.sh 写入。
# QUOTA_RUN_ORIGIN=
# QUOTA_RUN_GITHUB_CLIENT_ID=
# QUOTA_RUN_GITHUB_CLIENT_SECRET=
# QUOTA_RUN_GOOGLE_CLIENT_ID=
# QUOTA_RUN_GOOGLE_CLIENT_SECRET=
# QUOTA_RUN_SMTP_HOST=
# QUOTA_RUN_SMTP_PORT=
# QUOTA_RUN_SMTP_USER=
# QUOTA_RUN_SMTP_PASSWORD=
# QUOTA_RUN_MAIL_FROM=
ENVTEMPLATE
  )
  echo "已生成 /etc/quotabar-run.env（空模板）"
fi
chown root:quotabar-run /etc/quotabar-run.env
chmod 640 /etc/quotabar-run.env

install -m 644 /opt/quotabar-run/quotabar-run.service /etc/systemd/system/quotabar-run.service
systemctl daemon-reload
systemctl enable quotabar-run >/dev/null
systemctl restart quotabar-run

# Caddy：quota.run 是完整站点（页面 + /api/*），整份覆盖；quota.bar 站点块里只留旧地址的跳转，
# 放在「# >>> quota-run」「# <<< quota-run」之间，重跑时整段替换。早先没有标记的那段（/api/run/ 反代和改写）一并删掉。
site=/etc/caddy/sites/quota.bar.caddy
run_site=/etc/caddy/sites/quota.run.caddy
snippet=/opt/quotabar-run/caddy-snippet.caddy
if [ ! -f "$site" ]; then echo "找不到 $site"; exit 1; fi
backup=$(mktemp); run_backup=$(mktemp)
cp -p "$site" "$backup"
had_run_site=0
[ -f "$run_site" ] && { cp -p "$run_site" "$run_backup"; had_run_site=1; }
install -d -m 755 -o www-data -g www-data /var/www/quota.run
python3 - "$site" "$run_site" "$snippet" <<'PYCADDY'
import re, sys
site_path, run_path, snippet_path = sys.argv[1:4]
snippet = open(snippet_path).read()
def part(name):
    begin, end = f"# ---- BEGIN {name} ----\n", f"# ---- END {name} ----"
    return snippet[snippet.index(begin) + len(begin):snippet.index(end)]

text = open(site_path).read()
# 早先的无标记版本：从「# Quota Run API」到最后一条 leaderboard 改写。
text = re.sub(r"\t# Quota Run API.*?rewrite @quotaRunBoardZh /zh/leaderboard\.html\n", "", text, flags=re.S)
text = re.sub(r"\t# >>> quota-run\n.*?\t# <<< quota-run\n", "", text, flags=re.S)
block = "\t# >>> quota-run\n" + part("quota.bar") + "\t# <<< quota-run\n"
match = re.search(r"(?m)^quota\.bar\s*\{", text)
depth = 0
for i in range(match.start(), len(text)):
    if text[i] == "{": depth += 1
    elif text[i] == "}":
        depth -= 1
        if depth == 0:
            text = text[:i] + block + text[i:]
            break
open(site_path, "w").write(text)
open(run_path, "w").write(part("quota.run"))
print("已更新", site_path, "与", run_path)
PYCADDY
if caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
  systemctl reload caddy
else
  echo "caddy validate 失败，恢复原配置："
  caddy validate --config /etc/caddy/Caddyfile 2>&1 | tail -5 || true
  cp -p "$backup" "$site"
  if [ "$had_run_site" = 1 ]; then cp -p "$run_backup" "$run_site"; else rm -f "$run_site"; fi
  rm -f "$backup" "$run_backup"
  exit 1
fi
rm -f "$backup" "$run_backup"
sleep 1
systemctl is-active quotabar-run
curl -s -o /dev/null -w 'GET 本机 %{http_code}\n' http://127.0.0.1:8788/api/v1/stats
# 只显示哪些登录方式已配置（true/false），不含任何密钥
echo "登录方式：$(curl -s http://127.0.0.1:8788/api/v1/auth/providers)"
REMOTE
echo "== 公网验证 =="
curl -s --max-time 20 https://quota.run/api/v1/stats; echo
curl -s --max-time 20 https://quota.run/api/v1/auth/providers; echo
curl -s -o /dev/null --max-time 20 -w 'POST /register → %{http_code}（应为 404）\n' -X POST https://quota.run/api/v1/register
curl -s -o /dev/null --max-time 20 -w 'quota.bar/leaderboard → %{http_code} %{redirect_url}\n' https://quota.bar/leaderboard
curl -s -o /dev/null --max-time 20 -w 'quota.bar/api/run/v1/stats → %{http_code}\n' https://quota.bar/api/run/v1/stats

#!/bin/bash
# 把 Quota Run 登录用的凭据写进服务器上的 /etc/quotabar-run.env，然后重启服务。
#
#   ./Scripts/configure_run_login.sh google ~/Downloads/client_secret_….json   # Google 控制台下载的 JSON
#   ./Scripts/configure_run_login.sh github                                    # 终端里输入 Client ID 和 Secret（不回显）
#   ./Scripts/configure_run_login.sh cloudflare                                # Cloudflare Email Sending：只输入 API 令牌（不回显）
#   ./Scripts/configure_run_login.sh smtp                                      # 终端里输入 SMTP 设置（密码不回显）
#   ./Scripts/configure_run_login.sh github-token                              # 个人主页 GitHub 数据用的令牌（不回显，不需要任何权限）
#
# 凭据只经 ssh 的标准输入传过去，不出现在命令行参数、终端输出或仓库里；
# 服务器上只改动对应的几行，其余设置原样保留。
set -euo pipefail
cd "$(dirname "$0")/.."
HOST="${SITE_HOST:-root@15.204.80.137}"
KEY="${SITE_KEY:-$HOME/.ssh/gentpan.pem}"
kind="${1:-}"

die() { echo "error: $*" >&2; exit 1; }

case "$kind" in
  google)
    file="${2:-}"
    [ -f "$file" ] || die "用法：$0 google <client_secret.json>"
    payload="$(python3 - "$file" <<'PY'
import json, sys
web = json.load(open(sys.argv[1])).get("web") or {}
cid, secret = web.get("client_id", ""), web.get("client_secret", "")
if not cid or not secret:
    sys.exit("这个 JSON 里没有 web.client_id / web.client_secret（要选「Web 应用」类型的客户端）")
want = "https://quota.run/api/v1/auth/google/callback"
if want not in (web.get("redirect_uris") or []):
    print(f"注意：重定向 URI 里没有 {want}，Google 登录会报 redirect_uri_mismatch", file=sys.stderr)
print(json.dumps({"QUOTA_RUN_GOOGLE_CLIENT_ID": cid, "QUOTA_RUN_GOOGLE_CLIENT_SECRET": secret}))
PY
)"
    ;;
  github)
    read -r -p "GitHub Client ID: " cid
    read -r -s -p "GitHub Client Secret（不回显）: " secret; echo
    [ -n "$cid" ] && [ -n "$secret" ] || die "两项都要填"
    payload="$(CID="$cid" SECRET="$secret" python3 -c 'import json, os; print(json.dumps({"QUOTA_RUN_GITHUB_CLIENT_ID": os.environ["CID"], "QUOTA_RUN_GITHUB_CLIENT_SECRET": os.environ["SECRET"]}))')"
    ;;
  cloudflare)
    # Cloudflare Email Sending 的 SMTP：smtp.mx.cloudflare.net:465（隐式 TLS），用户名是字面的 api_token，
    # 密码是带「Email Sending: Edit」权限的 API 令牌；发件域名 notice.quota.run 要先在 Email Service → Email Sending 里接入。
    read -r -s -p "Cloudflare API 令牌（Email Sending: Edit，不回显）: " token; echo
    read -r -p "发件人 [Quota Run <noreply@notice.quota.run>]: " from
    [ -n "$token" ] || die "令牌不能为空"
    payload="$(T="$token" F="${from:-Quota Run <noreply@notice.quota.run>}" python3 -c 'import json, os; print(json.dumps({"QUOTA_RUN_SMTP_HOST": "smtp.mx.cloudflare.net", "QUOTA_RUN_SMTP_PORT": "465", "QUOTA_RUN_SMTP_USER": "api_token", "QUOTA_RUN_SMTP_PASSWORD": os.environ["T"], "QUOTA_RUN_MAIL_FROM": os.environ["F"]}))')"
    ;;
  smtp)
    read -r -p "SMTP 主机（如 smtp.resend.com）: " host
    read -r -p "端口（465 = TLS，587 = STARTTLS）[465]: " port
    read -r -p "用户名: " user
    read -r -s -p "密码（不回显）: " password; echo
    read -r -p "发件人（如 Quota Run <noreply@notice.quota.run>）: " from
    [ -n "$host" ] && [ -n "$user" ] && [ -n "$password" ] && [ -n "$from" ] || die "主机、用户名、密码、发件人都要填"
    payload="$(H="$host" P="${port:-465}" U="$user" W="$password" F="$from" python3 -c 'import json, os; print(json.dumps({"QUOTA_RUN_SMTP_HOST": os.environ["H"], "QUOTA_RUN_SMTP_PORT": os.environ["P"], "QUOTA_RUN_SMTP_USER": os.environ["U"], "QUOTA_RUN_SMTP_PASSWORD": os.environ["W"], "QUOTA_RUN_MAIL_FROM": os.environ["F"]}))')"
    ;;
  github-token)
    # github.com/settings/personal-access-tokens → Fine-grained token，Repository access 选 Public repositories，不加任何权限。
    # 只用来读个人主页上的贡献日历和提交、PR 数；留空就删掉这一项（回到读公开页面）。
    read -r -s -p "GitHub 令牌（不回显，留空则删除）: " token; echo
    payload="$(T="$token" python3 -c 'import json, os; print(json.dumps({"QUOTA_RUN_GITHUB_TOKEN": os.environ["T"]}))')"
    ;;
  *)
    die "用法：$0 google <client_secret.json> | github | cloudflare | smtp | github-token"
    ;;
esac

# 远端脚本先传过去；凭据走标准输入。
remote_script="$(mktemp)"
cat > "$remote_script" <<'PY'
import grp, json, os, sys
path = "/etc/quotabar-run.env"
updates = json.loads(sys.stdin.read())
updates.setdefault("QUOTA_RUN_ORIGIN", "https://quota.run")
lines = open(path).read().splitlines() if os.path.exists(path) else [
    "# Quota Run 的登录与发信设置（Scripts/configure_run_login.sh 维护）。不要提交到任何地方。"]
seen = set()
out = []
for line in lines:
    key = line.split("=", 1)[0].strip() if "=" in line and not line.lstrip().startswith("#") else None
    if key in updates:
        if key in seen:
            continue
        out.append(f"{key}={updates[key]}")
        seen.add(key)
    else:
        out.append(line)
for key, value in updates.items():
    if key not in seen and not (key == "QUOTA_RUN_ORIGIN" and any(l.startswith("QUOTA_RUN_ORIGIN=") for l in out)):
        out.append(f"{key}={value}")
tmp = path + ".tmp"
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o640)
with os.fdopen(fd, "w") as handle:
    handle.write("\n".join(out) + "\n")
try:
    os.chown(tmp, 0, grp.getgrnam("quotabar-run").gr_gid)
except KeyError:
    pass
os.chmod(tmp, 0o640)
os.replace(tmp, path)
print("已写入 " + path + "：" + "、".join(k for k in updates))
PY
scp -q -i "$KEY" -o BatchMode=yes "$remote_script" "$HOST:/root/.quotabar-run-env.py"
rm -f "$remote_script"
printf '%s' "$payload" | ssh -i "$KEY" -o BatchMode=yes "$HOST" \
  'python3 /root/.quotabar-run-env.py; rm -f /root/.quotabar-run-env.py; systemctl restart quotabar-run && systemctl is-active quotabar-run'

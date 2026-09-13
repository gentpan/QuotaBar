#!/bin/bash
# Publishes web/ to quota.bar and web-run/ (Quota Run) to quota.run.
#
# The ?v= token on every asset URL is derived from the *content* of the files
# it guards, so changing a file changes its URL. This is not a nicety: the site
# tells Cloudflare to cache static assets for a day, so a redeploy that reuses
# the token leaves the public site on the old copy while the origin is correct
# — which looks exactly like a deploy that worked. That happened twice before
# this script existed, hence the verification step at the end.
set -euo pipefail
cd "$(dirname "$0")/.."

HOST="${SITE_HOST:-root@15.204.80.137}"
KEY="${SITE_KEY:-$HOME/.ssh/gentpan.pem}"
ROOT="${SITE_ROOT:-/var/www/quota.bar}"
RUN_ROOT="${RUN_ROOT:-/var/www/quota.run}"

# One token for all assets: simpler than per-file hashes, and a redeploy that
# touches anything is cheap enough to re-fetch the rest.
# 先把 ?v= 本身洗掉再算：这些文件里也带指纹，不洗的话指纹会自己喂自己，
# 内容没动也会每次换一个值，等于每次部署都让全站资源重新下载一遍。
# README 与官网里的更新日志、热力图都从 CHANGELOG.md 和提交记录生成，发布前先同步。
python3 Scripts/sync_changelog.py ${CHANGELOG_FILE:+--changelog "$CHANGELOG_FILE"}

# quota.run 的样式和脚本：共用的 base.css / common.js，各页自己的 css / js，以及只在 ?demo=1 时加载的 demo.js。
RUN_CSS="web-run/base.css web-run/board.css web-run/profile.css web-run/rules.css web-run/account.css web-run/ui.css web-run/pages.css"
RUN_JS="web-run/common.js web-run/board.js web-run/profile.js web-run/account.js web-run/demo.js web-run/ui.js web-run/usage.js web-run/projects.js web-run/project.js web-run/kit.js"
RUN_PAGES="index u rules login account connect usage projects project kit"

# 图片也算进去：只换了截图、分享图或服务商 logo 时，指纹不变的话 CDN 会继续给旧图。
STAMP="$( { cat web/styles.css web/replica.css web/app.js web/replica.js $RUN_CSS $RUN_JS \
           | /usr/bin/sed -E 's/\?v=[A-Za-z0-9]+//g'
           find web/assets web-run/assets -type f \( -name '*.png' -o -name '*.jpg' -o -name '*.webp' \) | sort | xargs cat; } \
         | shasum -a 256 | cut -c1-8)"
echo "内容指纹 v=$STAMP"

# Rewrite every ?v=… in the HTML, and the font URL the stylesheets carry.
# quota.run 的每一页（排行榜、个人主页 u.html、规则，登录、账号、连接）同样带指纹；
# common.js 从自己的 ?v= 取 logo 和 demo.js 的指纹，不用单独改。
run_html=""
for page in $RUN_PAGES; do run_html="$run_html web-run/$page.html web-run/zh/$page.html"; done
/usr/bin/sed -i '' -E "s/\?v=[A-Za-z0-9]+/?v=$STAMP/g" web/index.html web/changelog.html web/zh/index.html web/zh/changelog.html $run_html
/usr/bin/sed -i '' -E "s/(InstrumentSans-Variable\.ttf)\?v=[A-Za-z0-9]+/\1?v=$STAMP/" web/styles.css web-run/base.css
/usr/bin/sed -i '' -E "s/(wallpaper-[a-z0-9-]+\.webp)\?v=[A-Za-z0-9]+/\1?v=$STAMP/g" web/styles.css
# replica.js 里的 LOGOV 也要跟上，否则 JS 渲染出的那些 logo 拿的是旧指纹。
/usr/bin/sed -i '' -E "s/(var LOGOV = \")\?v=[A-Za-z0-9]+/\1?v=$STAMP/" web/replica.js

# download/ 里是安装包的服务器副本，由 publish_release.sh 上传，不在 web/ 里——
# 排除掉，否则 --delete 会把它们删了。
rsync -az --delete --exclude /download/ -e "ssh -i $KEY -o BatchMode=yes" web/ "$HOST:$ROOT/"
ssh -i "$KEY" -o BatchMode=yes "$HOST" "mkdir -p $RUN_ROOT"
rsync -az --delete -e "ssh -i $KEY -o BatchMode=yes" web-run/ "$HOST:$RUN_ROOT/"
ssh -i "$KEY" -o BatchMode=yes "$HOST" "chown -R www-data:www-data $ROOT $RUN_ROOT"
echo "已同步"

# Verify what the public actually gets, not what the origin holds. A stale CDN
# copy is the failure this script exists to prevent, so it is checked, not
# assumed.
fail=0
for f in web/styles.css web/replica.css web/app.js web/replica.js $RUN_CSS $RUN_JS; do
  site=https://quota.bar; [[ $f == web-run/* ]] && site=https://quota.run
  want=$(stat -f%z "$f")
  got=$(curl -s -o /dev/null -w '%{size_download}' --max-time 20 "$site/${f#*/}?v=$STAMP")
  if [ "$want" = "$got" ]; then
    printf "  ✅ %-22s %s B\n" "$f" "$got"
  else
    printf "  ❌ %-22s 线上 %s B ≠ 本地 %s B\n" "$f" "$got" "$want"
    fail=1
  fi
done
# /rules、/login、/account、/connect 走 Caddy 的 try_files，顺便验证这条映射在线上生效。
for page in quota.bar/ quota.bar/zh/ quota.run/ quota.run/zh/ quota.run/u.html quota.run/zh/u.html \
            quota.run/rules quota.run/zh/rules quota.run/login quota.run/zh/login \
            quota.run/account quota.run/zh/account quota.run/connect quota.run/zh/connect \
            quota.run/usage quota.run/zh/usage quota.run/projects quota.run/zh/projects quota.run/kit quota.run/zh/kit; do
  html=$(curl -s --max-time 20 "https://$page" | grep -c "?v=$STAMP" || true)
  [ "$html" -gt 0 ] && printf "  ✅ %-22s 引用 %s 处新指纹\n" "$page" "$html" \
                    || { printf "  ❌ %-22s 仍在引用旧指纹\n" "$page"; fail=1; }
done
exit $fail

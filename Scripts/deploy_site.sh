#!/bin/bash
# Publishes web/ to quota.bar.
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

# One token for all assets: simpler than per-file hashes, and a redeploy that
# touches anything is cheap enough to re-fetch the rest.
# 先把 ?v= 本身洗掉再算：这些文件里也带指纹，不洗的话指纹会自己喂自己，
# 内容没动也会每次换一个值，等于每次部署都让全站资源重新下载一遍。
# README 与官网里的更新日志、热力图都从 CHANGELOG.md 和提交记录生成，发布前先同步。
python3 Scripts/sync_changelog.py ${CHANGELOG_FILE:+--changelog "$CHANGELOG_FILE"}

# 图片也算进去：只换了截图或分享图时，指纹不变的话 CDN 会继续给旧图。
STAMP="$( { cat web/styles.css web/replica.css web/app.js web/replica.js \
           | /usr/bin/sed -E 's/\?v=[A-Za-z0-9]+//g'
           find web/assets -type f \( -name '*.png' -o -name '*.jpg' -o -name '*.webp' \) | sort | xargs cat; } \
         | shasum -a 256 | cut -c1-8)"
echo "内容指纹 v=$STAMP"

# Rewrite every ?v=… in the HTML, and the font URL the stylesheet carries.
/usr/bin/sed -i '' -E "s/\?v=[A-Za-z0-9]+/?v=$STAMP/g" web/index.html web/changelog.html
/usr/bin/sed -i '' -E "s/(InstrumentSans-Variable\.ttf)\?v=[A-Za-z0-9]+/\1?v=$STAMP/" web/styles.css
/usr/bin/sed -i '' -E "s/(wallpaper-[a-z0-9-]+\.webp)\?v=[A-Za-z0-9]+/\1?v=$STAMP/g" web/styles.css
# replica.js 里的 LOGOV 也要跟上，否则 JS 渲染出的那些 logo 拿的是旧指纹。
/usr/bin/sed -i '' -E "s/(var LOGOV = \")\?v=[A-Za-z0-9]+/\1?v=$STAMP/" web/replica.js

rsync -az --delete -e "ssh -i $KEY -o BatchMode=yes" web/ "$HOST:$ROOT/"
ssh -i "$KEY" -o BatchMode=yes "$HOST" "chown -R www-data:www-data $ROOT"
echo "已同步"

# Verify what the public actually gets, not what the origin holds. A stale CDN
# copy is the failure this script exists to prevent, so it is checked, not
# assumed.
fail=0
for f in styles.css replica.css app.js replica.js; do
  want=$(stat -f%z "web/$f")
  got=$(curl -s -o /dev/null -w '%{size_download}' --max-time 20 "https://quota.bar/$f?v=$STAMP")
  if [ "$want" = "$got" ]; then
    printf "  ✅ %-14s %s B\n" "$f" "$got"
  else
    printf "  ❌ %-14s 线上 %s B ≠ 本地 %s B\n" "$f" "$got" "$want"
    fail=1
  fi
done
html=$(curl -s --max-time 20 "https://quota.bar/" | grep -c "?v=$STAMP" || true)
[ "$html" -gt 0 ] && printf "  ✅ %-14s 引用 %s 处新指纹\n" "index.html" "$html" \
                  || { printf "  ❌ %-14s 仍在引用旧指纹\n" "index.html"; fail=1; }
exit $fail

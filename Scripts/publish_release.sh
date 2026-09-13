#!/bin/bash
# 发布 release.sh 已经打好的版本：GitHub Release、quota.bar 服务器副本、
# Homebrew tap、官网，一次做完。
#
#   ./Scripts/publish_release.sh                    # 版本号取 Info.plist
#   STEPS="mirror" ./Scripts/publish_release.sh     # 只重传服务器副本
#   NOTES=notes.md ./Scripts/publish_release.sh     # 自己写的发布说明
#
# 服务器副本是给打不开或下不动 GitHub 的网络用的：官网的下载按钮直接指向它，
# 应用内更新在 GitHub 连不上时也改从这里取（download/latest.json）。
#
# 前提：CHANGELOG.md 里已有「## <版本> · <日期>」，v<版本> 的 tag 已推送。
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="${REPO:-gentpan/QuotaBar}"
TAP="${TAP:-gentpan/homebrew-tap}"
HOST="${SITE_HOST:-root@15.204.80.137}"
KEY="${SITE_KEY:-$HOME/.ssh/gentpan.pem}"
ROOT="${SITE_ROOT:-/var/www/quota.bar}"
DIST="${DIST:-dist}"
STEPS="${STEPS:-github mirror tap site}"
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)}"
ZIP="$DIST/QuotaBar-$VERSION.zip"
DMG="$DIST/QuotaBar-$VERSION.dmg"
SSH=(ssh -i "$KEY" -o BatchMode=yes "$HOST")

die() { echo "error: $*" >&2; exit 1; }
has_step() { [[ " $STEPS " == *" $1 "* ]]; }

[ -f "$ZIP" ] && [ -f "$DMG" ] || die "$DIST 里没有 $VERSION 的 zip 和 dmg，先跑 ./Scripts/release.sh"
grep -q "^## $VERSION " CHANGELOG.md || die "CHANGELOG.md 里还没有「## $VERSION · 日期」，版本还没定稿"
git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null || die "没有 v$VERSION 的 tag"
ZIP_SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
DMG_SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"

# 发布说明默认取两份更新日志里这个版本的那一节，英文在前。
release_notes() {
  python3 - "$VERSION" <<'PY'
import pathlib, re, sys
version = sys.argv[1]
def section(path):
    p = pathlib.Path(path)
    if not p.exists():
        return ""
    m = re.search(rf"^## {re.escape(version)} .*?$(.*?)(?=^## |\Z)", p.read_text(encoding="utf-8"), re.M | re.S)
    return m.group(1).strip() if m else ""
en, zh = section("CHANGELOG.en.md"), section("CHANGELOG.md")
parts = [s for s in (en, zh) if s]
print("\n\n---\n\n".join(parts))
PY
}

if has_step github; then
  echo "── GitHub Release"
  if gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1; then
    echo "  v$VERSION 已存在，跳过"
  else
    notes="${NOTES:-$(mktemp)}"
    [ -n "${NOTES:-}" ] || release_notes > "$notes"
    gh release create "v$VERSION" "$ZIP" "$DMG" --repo "$REPO" \
      --title "QuotaBar $VERSION" --notes-file "$notes" --verify-tag
  fi
fi

if has_step mirror; then
  echo "── 服务器副本 https://quota.bar/download/"
  "${SSH[@]}" "mkdir -p $ROOT/download"
  # 先传成 .part 再改名：下载到一半的人拿不到半截文件。
  for f in "$ZIP" "$DMG"; do
    name="$(basename "$f")"
    scp -q -i "$KEY" -o BatchMode=yes "$f" "$HOST:$ROOT/download/$name.part"
    "${SSH[@]}" "mv $ROOT/download/$name.part $ROOT/download/$name"
  done
  latest="$(mktemp)"
  python3 - "$VERSION" "$ZIP_SHA" "$DMG_SHA" "$REPO" > "$latest" <<'PY'
import datetime, json, sys
version, zip_sha, dmg_sha, repo = sys.argv[1:5]
base = "https://quota.bar/download"
print(json.dumps({
    "version": version,
    "url": f"{base}/QuotaBar-{version}.zip",
    "sha256": zip_sha,
    "dmg": f"{base}/QuotaBar-{version}.dmg",
    "dmgSha256": dmg_sha,
    "page": "https://quota.bar/changelog.html",
    "github": f"https://github.com/{repo}/releases/tag/v{version}",
    "publishedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}, indent=2))
PY
  scp -q -i "$KEY" -o BatchMode=yes "$latest" "$HOST:$ROOT/download/latest.json"
  "${SSH[@]}" "chown -R www-data:www-data $ROOT/download && chmod 644 $ROOT/download/*"

  # 核对公网上拿到的，而不是服务器上放着的：中间隔着 Cloudflare。
  remote="$("${SSH[@]}" "cd $ROOT/download && sha256sum QuotaBar-$VERSION.zip QuotaBar-$VERSION.dmg" | cut -d' ' -f1 | tr '\n' ' ')"
  [ "$remote" = "$ZIP_SHA $DMG_SHA " ] || die "服务器上的文件校验值不对：$remote"
  for f in "$ZIP" "$DMG"; do
    name="$(basename "$f")"
    want="$(stat -f%z "$f")"
    got="$(curl -sI --max-time 30 "https://quota.bar/download/$name" | tr -d '\r' | awk 'tolower($1)=="content-length:"{print $2}' | tail -1)"
    [ "$want" = "$got" ] || die "https://quota.bar/download/$name 线上大小 ${got:-无} ≠ 本地 $want"
    printf "  ✅ %-22s %s B\n" "$name" "$got"
  done
  curl -s --max-time 20 "https://quota.bar/download/latest.json" | grep -q "\"version\": \"$VERSION\"" \
    && echo "  ✅ latest.json          $VERSION" || die "latest.json 线上不是 $VERSION"
fi

if has_step tap; then
  echo "── Homebrew tap"
  work="$(mktemp -d)"
  gh repo clone "$TAP" "$work" -- -q
  cp "$DIST/quotabar.rb" "$work/Casks/quotabar.rb"
  if git -C "$work" diff --quiet; then
    echo "  cask 已是 $VERSION，跳过"
  else
    git -C "$work" add Casks/quotabar.rb
    git -C "$work" commit -q -m "quotabar $VERSION"
    git -C "$work" push -q origin HEAD
    echo "  ✅ $(git -C "$work" log --oneline -1)"
  fi
  rm -rf "$work"
fi

if has_step site; then
  echo "── 官网"
  ./Scripts/deploy_site.sh
fi

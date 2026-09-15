#!/bin/bash
# 在 release.sh 打好的通用版 QuotaBar.app 之上，另做两个单一架构的安装包，
# 给官网上分开的两个下载按钮用：
#
#   dist/QuotaBar-<版本>-apple-silicon.dmg   只含 arm64
#   dist/QuotaBar-<版本>-intel.dmg           只含 x86_64
#
#   ./Scripts/release_thin.sh        # release.sh 最后会自己调用
#
# 应用内更新和 Homebrew 仍然用通用包：一个文件两种芯片都能装，不用判断机型。
# 拆出来的程序签名已经变了，所以每个都重新签名、公证并装订，app 和 dmg 各一次；
# 两种芯片并行做，Gatekeeper 不接受就不算完成。
set -euo pipefail
cd "$(dirname "$0")/.."

DIST="${DIST:-dist}"
NOTARY_PROFILE="${NOTARY_PROFILE:-QuotaBar}"
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null \
  | grep 'Developer ID Application' | head -1 | sed -E 's/.*"(.*)".*/\1/' || true)}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
APP=QuotaBar.app

die() { echo "error: $*" >&2; exit 1; }

[ -n "$SIGN_ID" ] || die "没有 Developer ID Application 证书，拆出来的包没法签名公证"
[ -d "$APP" ] || die "没有 $APP，先跑 ./Scripts/release.sh"
archs="$(lipo -archs "$APP/Contents/MacOS/QuotaBar")"
[[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || die "$APP 不是通用版（$archs），先跑 ./Scripts/release.sh"
built="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[ "$built" = "$VERSION" ] || die "$APP 是 $built，Info.plist 是 $VERSION"
mkdir -p "$DIST"

notarize() {
  local file="$1" out
  out="$(xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)"
  echo "$out"
  grep -q "status: Accepted" <<<"$out" || die "公证没有通过：$file"
}

thin() {
  local arch="$1" label="$2"
  local work app dmg stage
  work="$(mktemp -d)"
  app="$work/QuotaBar.app"
  dmg="$DIST/QuotaBar-$VERSION-$label.dmg"

  ditto "$APP" "$app"
  lipo -thin "$arch" "$app/Contents/MacOS/QuotaBar" -output "$work/QuotaBar"
  mv "$work/QuotaBar" "$app/Contents/MacOS/QuotaBar"
  # 通用包装订的公证凭证属于原来的签名，留着只会让验证对不上。
  rm -f "$app/Contents/CodeResources"
  codesign --force --options runtime --timestamp \
    --entitlements Resources/QuotaBar.entitlements --sign "$SIGN_ID" "$app"
  codesign --verify --strict "$app"

  ditto -c -k --keepParent "$app" "$work/QuotaBar.zip"
  notarize "$work/QuotaBar.zip"
  xcrun stapler staple "$app"
  spctl -a -vv "$app" 2>&1 | grep -q accepted || die "Gatekeeper 不接受 $label 的 app"

  stage="$work/stage/QuotaBar"
  mkdir -p "$stage"
  cp -R "$app" "$stage/"
  ln -s /Applications "$stage/Applications"
  rm -f "$dmg"
  hdiutil create -volname "QuotaBar" -srcfolder "$stage" -ov -format UDZO -quiet "$dmg"
  codesign --force --timestamp --sign "$SIGN_ID" "$dmg"
  notarize "$dmg"
  xcrun stapler staple "$dmg"
  spctl -a -t open --context context:primary-signature -v "$dmg" 2>&1 | grep -q accepted \
    || die "Gatekeeper 不接受 $dmg"
  rm -rf "$work"
  echo "✅ $dmg  $(du -h "$dmg" | cut -f1)"
}

logs="$(mktemp -d)"
thin arm64 apple-silicon >"$logs/apple-silicon.log" 2>&1 & arm=$!
thin x86_64 intel >"$logs/intel.log" 2>&1 & intel=$!
status=0
wait "$arm" || { echo "── Apple 芯片版失败："; cat "$logs/apple-silicon.log"; status=1; }
wait "$intel" || { echo "── Intel 版失败："; cat "$logs/intel.log"; status=1; }
[ "$status" = 0 ] || exit 1

echo
echo "── 单一架构安装包 $VERSION ─────────────────────"
for label in apple-silicon intel; do
  f="$DIST/QuotaBar-$VERSION-$label.dmg"
  echo "  $label  $f  ($(du -h "$f" | cut -f1))  sha256 $(shasum -a 256 "$f" | cut -d' ' -f1)"
done

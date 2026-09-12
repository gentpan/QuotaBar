#!/bin/bash
# Builds QuotaBar.app in place.
#
# Signing tiers, picked automatically:
#   1. Developer ID Application certificate present -> hardened-runtime signature
#      that Gatekeeper accepts once the app is also notarized.
#   2. Nothing present -> ad-hoc signature. Runs on this Mac only; anyone else
#      who downloads it gets "QuotaBar is damaged and can't be opened", which is
#      Gatekeeper's (badly worded) way of saying "unsigned".
#
# Notarizing additionally requires a stored notarytool credential:
#   xcrun notarytool store-credentials QuotaBar \
#     --apple-id you@example.com --team-id <YOUR_TEAM_ID>
#   NOTARIZE=1 ./Scripts/package_app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

# Prefer a full Xcode toolchain: CommandLineTools alone lacks the SwiftUI macro plugin.
if [[ "$(xcode-select -p)" == *CommandLineTools* ]]; then
  for candidate in /Applications/Xcode-beta.app /Applications/Xcode.app; do
    if [ -d "$candidate/Contents/Developer" ]; then
      export DEVELOPER_DIR="$candidate/Contents/Developer"
      break
    fi
  done
fi

CONFIG=${CONFIG:-release}
# Universal by default. A plain `swift build` only produces the host
# architecture, and 0.3.2 shipped arm64-only against a README that promises
# Intel. UNIVERSAL=0 skips the second slice for a quick local build.
ARCHS=()
if [ "${UNIVERSAL:-1}" = "1" ]; then
  ARCHS=(--arch arm64 --arch x86_64)
fi
# ${ARCHS[@]+...}: bash 3.2 treats an empty array as unbound under set -u.
swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"} --product QuotaBar
BIN="$(swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/QuotaBar"
echo "Architectures: $(lipo -archs "$BIN")"

APP=QuotaBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/QuotaBar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Stamp when this bundle was actually assembled. The version alone does not
# answer "is this the build I just made?" during a dev loop, and it does not
# answer "when did the updater last replace this?" afterwards. Written here
# rather than baked into the source plist so it cannot go stale, and before
# signing so the signature covers it.
BUILD_DATE="$(date '+%Y-%m-%d %H:%M')"
/usr/libexec/PlistBuddy -c "Add :QBBuildDate string $BUILD_DATE" \
  "$APP/Contents/Info.plist" >/dev/null 2>&1 \
  || /usr/libexec/PlistBuddy -c "Set :QBBuildDate $BUILD_DATE" "$APP/Contents/Info.plist"
cp -R Sources/QuotaBar/Resources/logos "$APP/Contents/Resources/logos"
cp -R Sources/QuotaBar/Resources/brands "$APP/Contents/Resources/brands"
# Info.plist's ATSApplicationFontsPath points here; without the copy the
# wordmark silently falls back to the system font.
cp -R Sources/QuotaBar/Resources/fonts "$APP/Contents/Resources/fonts"

# Build AppIcon.icns from Assets/icon.png
WORK="$(mktemp -d)"
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 64 128 256 512 1024; do
  sips -z "$size" "$size" Assets/icon.png --out "$ICONSET/icon_${size}.png" >/dev/null
done
cp "$ICONSET/icon_64.png" "$ICONSET/icon_32x32@2x.png"
cp "$ICONSET/icon_256.png" "$ICONSET/icon_128x128@2x.png"
cp "$ICONSET/icon_512.png" "$ICONSET/icon_256x256@2x.png"
cp "$ICONSET/icon_1024.png" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$WORK"

# ---- Sign -------------------------------------------------------------------

# SIGN_ID may name an identity explicitly; otherwise take the first Developer ID.
SIGN_ID="${SIGN_ID:-}"
if [ -z "$SIGN_ID" ]; then
  SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep 'Developer ID Application' | head -1 | sed -E 's/.*"(.*)".*/\1/' || true)"
fi

if [ -n "$SIGN_ID" ]; then
  echo "Signing as: $SIGN_ID"
  # --options runtime is what notarization requires; --timestamp gets the secure
  # timestamp that keeps the signature valid after the certificate expires.
  # No --deep: it is deprecated and this bundle has no nested code anyway.
  codesign --force --options runtime --timestamp \
    --entitlements Resources/QuotaBar.entitlements \
    --sign "$SIGN_ID" "$APP"
  SIGNED_PROPERLY=1
else
  echo "No Developer ID certificate found — falling back to ad-hoc (this Mac only)."
  codesign --force --sign - "$APP"
  SIGNED_PROPERLY=0
fi

codesign --verify --strict --verbose=2 "$APP"

# ---- Notarize ---------------------------------------------------------------

NOTARIZE="${NOTARIZE:-0}"
NOTARY_PROFILE="${NOTARY_PROFILE:-QuotaBar}"

if [ "$NOTARIZE" = "1" ]; then
  if [ "$SIGNED_PROPERLY" != "1" ]; then
    echo "error: cannot notarize an ad-hoc signed app — a Developer ID certificate is required." >&2
    exit 1
  fi
  ZIP="$(mktemp -d)/QuotaBar.zip"
  # ditto, not zip: preserves the bundle's symlinks and extended attributes.
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "Submitting to Apple for notarization (this usually takes a few minutes)…"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  # Stapling attaches the ticket so the app validates without a network round trip.
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  rm -rf "$(dirname "$ZIP")"
fi

# ---- Report -----------------------------------------------------------------

echo
if spctl -a -vv "$APP" 2>&1 | grep -q accepted; then
  echo "✅ Gatekeeper: accepted — this build can be handed to other people."
elif [ "$SIGNED_PROPERLY" = "1" ]; then
  echo "⚠️  Signed with Developer ID but not notarized."
  echo "    Others will see \"cannot be opened because Apple cannot check it\"."
  echo "    Run: NOTARIZE=1 ./Scripts/package_app.sh"
else
  echo "⚠️  Ad-hoc signed — runs on this Mac only."
  echo "    Others will see \"QuotaBar is damaged and can't be opened\"."
fi
echo "Built $APP — run: open $APP"

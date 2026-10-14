#!/bin/bash
# Build the release app (named in Support/app.env) into macos/build/.
#   ./scripts/build-app.sh            # release, size-optimized, ad-hoc signed
#   ./scripts/build-app.sh --open     # …and launch it
#   ./scripts/build-app.sh --zip      # …and make build/Kavach-Console.zip for a GitHub release
# Needs only the Command Line Tools (no Xcode).
#
# Signing: ad-hoc by default. macOS ties the Accessibility permission (Guard's
# screen lock) to the signature, and every ad-hoc build has a new one, so the
# permission has to be re-allowed after each rebuild. To keep it, create a
# self-signed code-signing certificate once (Keychain Access ▸ Certificate
# Assistant ▸ Create a Certificate…, type "Code Signing") named "Kavach Dev",
# or point KAVACH_SIGN_ID at any code-signing identity you own.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
# App identity (name, bundle id, …) comes from one file.
source "$ROOT/Support/app.env"
VERSION="$(grep -m1 '"version"' ../package.json | sed -E 's/.*"([0-9][^"]*)".*/\1/')"
OUT="$ROOT/build"
APP="$OUT/$APP_NAME.app"
SCRATCH="$ROOT/.build-release"

echo "▸ Compiling (release, -Osize)…"
set +e
swift build --build-system native -c release --scratch-path "$SCRATCH" \
  -Xswiftc -Osize -Xswiftc -gnone \
  -Xlinker -dead_strip -Xlinker -dead_strip_dylibs 2>&1 | grep -vE "^warning: '--build-system native'"
STATUS=${PIPESTATUS[0]}
set -e
# Never package a stale binary from an earlier build.
[ "$STATUS" -eq 0 ] || { echo "✘ compile failed — app not updated"; exit 1; }
BIN="$(swift build --build-system native -c release --scratch-path "$SCRATCH" --show-bin-path 2>/dev/null)/KavachConsole"
[ -x "$BIN" ] || { echo "build failed"; exit 1; }

echo "▸ Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$EXECUTABLE"
strip -x "$APP/Contents/MacOS/$EXECUTABLE"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__APP_NAME__/$APP_NAME/g" -e "s/__APP_SHORT_NAME__/$APP_SHORT_NAME/g" \
    -e "s/__APP_TAGLINE__/$APP_TAGLINE/g" -e "s/__BUNDLE_ID__/$BUNDLE_ID/g" -e "s/__EXECUTABLE__/$EXECUTABLE/g" \
    Support/Info.plist > "$APP/Contents/Info.plist"

# App icon from the shared 1024px source, 16–256pt at 1x and 2x (largest image
# 512px). The 512pt sizes are left out on purpose: they would triple the .icns
# for a size only Finder's biggest icon view ever shows.
SRC="$ROOT/Support/AppIcon.png"
ICONSET="$OUT/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for s in 16 32 128 256; do
  sips -z $s $s "$SRC" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$SRC" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

SIGN_ID="${KAVACH_SIGN_ID:-}"
if [ -z "$SIGN_ID" ] && security find-identity -p codesigning 2>/dev/null | grep -q '"Kavach Dev"'; then
  SIGN_ID="Kavach Dev"
fi
if [ -n "$SIGN_ID" ]; then
  echo "▸ Signing ($SIGN_ID)…"
  codesign --force --sign "$SIGN_ID" --options runtime "$APP" >/dev/null
else
  echo "▸ Signing (ad-hoc — re-allow Accessibility after this build if you use the Guard lock)…"
  codesign --force --sign - --options runtime "$APP" >/dev/null
fi

SIZE="$(du -sh "$APP" | cut -f1)"
echo "✔ $APP  ($SIZE)"
for arg in "$@"; do
  case "$arg" in
    --zip)
      ZIP="$OUT/${APP_NAME// /-}.zip"
      rm -f "$ZIP"
      # ditto keeps the bundle's symlinks, permissions and signature intact (zip -r doesn't).
      ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
      echo "✔ $ZIP  ($(du -h "$ZIP" | cut -f1))"
      ;;
    --open) open "$APP" ;;
  esac
done
exit 0

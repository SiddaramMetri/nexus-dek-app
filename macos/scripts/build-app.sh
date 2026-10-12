#!/bin/bash
# Build a release NexusConsole.app into macos/build/.
#   ./scripts/build-app.sh            # release, size-optimized, ad-hoc signed
#   ./scripts/build-app.sh --open     # …and launch it
# Needs only the Command Line Tools (no Xcode).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
VERSION="$(grep -m1 '"version"' ../package.json | sed -E 's/.*"([0-9][^"]*)".*/\1/')"
OUT="$ROOT/build"
APP="$OUT/Nexus Console.app"
SCRATCH="$ROOT/.build-release"

echo "▸ Compiling (release, -Osize)…"
swift build --build-system native -c release --scratch-path "$SCRATCH" \
  -Xswiftc -Osize -Xswiftc -gnone \
  -Xlinker -dead_strip -Xlinker -dead_strip_dylibs 2>&1 | grep -vE "^warning: '--build-system native'" || true
BIN="$(swift build --build-system native -c release --scratch-path "$SCRATCH" --show-bin-path 2>/dev/null)/NexusConsole"
[ -x "$BIN" ] || { echo "build failed"; exit 1; }

echo "▸ Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/NexusConsole"
strip -x "$APP/Contents/MacOS/NexusConsole"
sed "s/__VERSION__/$VERSION/g" Support/Info.plist > "$APP/Contents/Info.plist"

# App icon from the shared 1024px source, 16–256pt at 1x and 2x (largest image
# 512px). The 512pt sizes are left out on purpose: they would triple the .icns
# for a size only Finder's biggest icon view ever shows.
SRC="$ROOT/../public/Assets.xcassets/AppIcon.appiconset/1024.png"
ICONSET="$OUT/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for s in 16 32 128 256; do
  sips -z $s $s "$SRC" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$SRC" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

echo "▸ Signing (ad-hoc)…"
codesign --force --sign - --options runtime "$APP" >/dev/null

SIZE="$(du -sh "$APP" | cut -f1)"
echo "✔ $APP  ($SIZE)"
[ "${1:-}" = "--open" ] && open "$APP"
exit 0

#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="잠자기방지.app"
DIST="$ROOT/dist/$APP_NAME"
MACOS="$DIST/Contents/MacOS"
RES="$DIST/Contents/Resources"
SDK="$(xcrun --show-sdk-path)"

rm -rf "$DIST"
mkdir -p "$MACOS" "$RES" "$DIST/Contents"

swiftc -O -parse-as-library \
  -sdk "$SDK" \
  -target arm64-apple-macos12 \
  -framework AppKit -framework Foundation -framework IOKit \
  -Xlinker -dead_strip \
  "$ROOT"/Sources/lidguard/*.swift \
  -o "$MACOS/lidguard"

cp "$ROOT/Info.plist" "$DIST/Contents/Info.plist"
ICON_SRC="$ROOT/assets/AppIcon.icns"
if [ -f "$ICON_SRC" ]; then
  cp "$ICON_SRC" "$RES/AppIcon.icns"
fi

strip -x "$MACOS/lidguard"
xattr -cr "$DIST"
codesign --force --sign - --timestamp=none "$DIST" >/dev/null
echo "built $DIST"

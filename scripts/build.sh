#!/usr/bin/env bash
# Build 잠자기방지.app (lidguard) for macOS Apple Silicon / Intel.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Sources/lidguard/main.swift"
OUT_DIR="${1:-$ROOT/dist}"
APP="$OUT_DIR/잠자기방지.app"
BIN_NAME="lidguard"
MIN_OS="${MACOSX_DEPLOYMENT_TARGET:-12.0}"

mkdir -p "$OUT_DIR"
rm -rf "$APP"

echo "==> Compiling $BIN_NAME (macOS $MIN_OS+)"
TMPBIN="$(mktemp -t lidguard)"
swiftc \
  -O \
  -target "arm64-apple-macosx${MIN_OS}" \
  -sdk "$(xcrun --show-sdk-path)" \
  -framework AppKit \
  -framework Foundation \
  -o "$TMPBIN" \
  "$SRC"

# Optional universal binary if Intel slice requested
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  TMPX86="$(mktemp -t lidguard-x86)"
  swiftc \
    -O \
    -target "x86_64-apple-macosx${MIN_OS}" \
    -sdk "$(xcrun --show-sdk-path)" \
    -framework AppKit \
    -framework Foundation \
    -o "$TMPX86" \
    "$SRC"
  lipo -create -output "${TMPBIN}.uni" "$TMPBIN" "$TMPX86"
  mv "${TMPBIN}.uni" "$TMPBIN"
  rm -f "$TMPX86"
fi

echo "==> Assembling $APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$TMPBIN" "$APP/Contents/MacOS/$BIN_NAME"
chmod +x "$APP/Contents/MacOS/$BIN_NAME"
rm -f "$TMPBIN"

cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
if [[ -f "$ROOT/assets/AppIcon.icns" ]]; then
  cp "$ROOT/assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# Ad-hoc sign so Gatekeeper is happier on local builds
if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP" 2>/dev/null || true
fi

echo "==> Done: $APP"
echo "    Open with: open \"$APP\""

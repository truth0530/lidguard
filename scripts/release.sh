#!/bin/bash
# Build, package and publish a GitHub release that the in-app updater can use.
# The updater needs both assets: <zip> and <zip>.sha256.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)"
TAG="v$VERSION"
NOTES_FILE="${1:-}"

git diff --quiet HEAD || { echo "커밋하지 않은 변경이 있습니다" >&2; exit 1; }
git fetch -q origin
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "origin/main과 HEAD가 다릅니다 · 먼저 push 하세요" >&2; exit 1; }
if gh release view "$TAG" >/dev/null 2>&1; then
  echo "$TAG 릴리스가 이미 있습니다" >&2; exit 1
fi

bash tests/test_watchdog.sh
bash scripts/build.sh

OUT="$ROOT/dist/release"
rm -rf "$OUT"; mkdir -p "$OUT"
ZIP_NAME="lidguard-macOS-arm64.zip"
# No extended attributes: a quarantine flag inside the zip would block the updated app.
ditto -c -k --norsrc --noextattr --keepParent "$ROOT/dist/잠자기방지.app" "$OUT/$ZIP_NAME"
(cd "$OUT" && shasum -a 256 "$ZIP_NAME" > "$ZIP_NAME.sha256")

if [ -n "$NOTES_FILE" ]; then
  gh release create "$TAG" "$OUT/$ZIP_NAME" "$OUT/$ZIP_NAME.sha256" --target main --title "잠자기 방지 $VERSION" --notes-file "$NOTES_FILE"
else
  gh release create "$TAG" "$OUT/$ZIP_NAME" "$OUT/$ZIP_NAME.sha256" --target main --title "잠자기 방지 $VERSION" --generate-notes
fi
gh release view "$TAG" --json tagName,assets --jq '.tagName+" "+([.assets[].name]|join(","))'

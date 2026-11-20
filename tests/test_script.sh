#!/bin/bash
# Checks the admin start script builder without admin rights.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d /tmp/lidguard-script.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
cp "$ROOT/tests/script_checks.swift" "$OUT/main.swift"
swiftc -O -sdk "$(xcrun --show-sdk-path)" -target arm64-apple-macos12 \
  "$ROOT/Sources/lidguard/StartScript.swift" "$OUT/main.swift" -o "$OUT/script_checks"
xattr -c "$OUT/script_checks" 2>/dev/null || true
"$OUT/script_checks"

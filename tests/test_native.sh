#!/bin/bash
# Checks the native probes on the real machine: IOKit lid/SleepDisabled reads,
# kill(2) liveness incl. EPERM, the IOPM assertion, and per-call cost.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d /tmp/lidguard-native.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT
# Top-level code is only allowed in a file named main.swift.
cp "$ROOT/tests/native_checks.swift" "$OUT/main.swift"
swiftc -O -sdk "$(xcrun --show-sdk-path)" -target arm64-apple-macos12 \
  -framework IOKit \
  "$ROOT/Sources/lidguard/Native.swift" "$ROOT/Sources/lidguard/Updater.swift" \
  "$OUT/main.swift" -o "$OUT/native_checks"
xattr -c "$OUT/native_checks" 2>/dev/null || true
"$OUT/native_checks"

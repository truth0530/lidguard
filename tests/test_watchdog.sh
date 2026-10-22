#!/bin/bash
# Exercises `lidguard --watchdog` with a fake pmset and env-faked lid/thermal
# state. Fakes are honoured only for non-root processes.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d /tmp/lidguard-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

if [ -z "${LIDGUARD_BIN:-}" ]; then
  bash "$ROOT/scripts/build.sh" >/dev/null 2>&1
  LIDGUARD_BIN="$ROOT/dist/잠자기방지.app/Contents/MacOS/lidguard"
fi
BIN="$LIDGUARD_BIN"

fake_pmset="$TMP/pmset"
log="$TMP/lidguard_watchdog.log"
cat >"$fake_pmset" <<'EOF'
#!/bin/bash
echo "pmset $*" >>"${LIDGUARD_STATE_DIR}/pmset.log"
EOF
chmod +x "$fake_pmset"

run_wd() {
  LIDGUARD_STATE_DIR="$TMP" \
  LIDGUARD_POLL_SECONDS="${POLL:-1}" \
  LIDGUARD_PMSET="$fake_pmset" \
  LIDGUARD_LOG="$log" \
  LIDGUARD_GUI_GRACE="${GRACE:-60}" \
  LIDGUARD_FAKE_THERMAL="${FAKE_THERM:-nominal}" \
  LIDGUARD_FAKE_CLAMSHELL="${FAKE_CLAMSHELL:-No}" \
  LIDGUARD_FAKE_POWER="${LIDGUARD_FAKE_POWER:-ac}" \
  LIDGUARD_FAKE_POWER_FILE="${LIDGUARD_FAKE_POWER_FILE:-}" \
  "$BIN" --watchdog "$@"
}

reset() {
  : >"$TMP/pmset.log"
  : >"$log"
  rm -f "$TMP/lidguard_last_revert" "$TMP/lidguard_stop"
  echo 1 >"$TMP/lidguard_gen"
}

fail() { echo "fail: $*" >&2; exit 1; }
soon() { echo $(( $(date +%s) + $1 )); }

# 1) closed + lid closed: deadline reverts disablesleep
reset
FAKE_CLAMSHELL=Yes run_wd --gen 1 --closed-until "$(soon 1)"
grep -q "pmset -a disablesleep 0" "$TMP/pmset.log"
grep -q "revert: closed-idle" "$log"
echo "ok closed deadline"

# 2) gen mismatch does not revert
reset
echo 2 >"$TMP/lidguard_gen"
FAKE_CLAMSHELL=Yes run_wd --gen 1 --closed-until "$(soon 1)"
grep -q "disablesleep 0" "$TMP/pmset.log" && fail "reverted after gen change"
grep -q "gen changed, exit without revert" "$log"
echo "ok gen mismatch"

# 3) thermal abort (ProcessInfo.thermalState serious)
reset
FAKE_THERM=serious FAKE_CLAMSHELL=Yes run_wd --gen 1 --closed-until "$(soon 30)"
grep -q "revert: thermal serious" "$log"
grep -q "disablesleep 0" "$TMP/pmset.log"
grep -q " thermal serious$" "$TMP/lidguard_last_revert"
echo "ok thermal (reason recorded)"

# 4) clamshell sleepnow after closed deadline
reset
FAKE_CLAMSHELL=Yes run_wd --gen 1 --closed-until "$(soon 1)" --sleepnow-if-closed
grep -q "pmset sleepnow" "$TMP/pmset.log"
echo "ok sleepnow-if-closed"

# 5) no closed timer: exits at once and never sets disablesleep 1
reset
run_wd --gen 1 --closed-until 0
grep -q "disablesleep 1" "$TMP/pmset.log" && fail "set disablesleep with no closed timer"
echo "ok no closed timer"

# 6) stop file reverts before deadline
reset
touch "$TMP/lidguard_stop"
FAKE_CLAMSHELL=Yes run_wd --gen 1 --closed-until "$(soon 30)"
grep -q "revert: stop-file" "$log"
grep -q "disablesleep 0" "$TMP/pmset.log"
echo "ok stop-file"

# 7) lid OPEN: set disablesleep 1 at once, clear on deadline, never sleepnow
reset
FAKE_CLAMSHELL=No run_wd --gen 1 --closed-until "$(soon 1)" --sleepnow-if-closed
grep -q "sleepnow" "$TMP/pmset.log" && fail "sleepnow while lid open"
grep -q "disablesleep 1" "$TMP/pmset.log"
grep -q "disablesleep 0" "$TMP/pmset.log"
grep -q "phase=lid-open-closed-armed" "$log"
echo "ok lid-open preemptive disablesleep"

# 8) lid closed also sets disablesleep 1
reset
FAKE_CLAMSHELL=Yes run_wd --gen 1 --closed-until "$(soon 1)"
grep -q "disablesleep 1" "$TMP/pmset.log"
grep -q "disablesleep 0" "$TMP/pmset.log"
echo "ok lid-closed sets disablesleep"

# 9) unreadable lid sensor stays unknown and never causes sleepnow
reset
FAKE_CLAMSHELL=unknown run_wd --gen 1 --closed-until "$(soon 1)" --sleepnow-if-closed
grep -q "sleepnow" "$TMP/pmset.log" && fail "sleepnow with unavailable lid sensor"
grep -q "state unavailable" "$log"
echo "ok unknown lid is fail-safe"

# 10) app force-quit (gui pid gone) reverts after the grace period
reset
GUI=99990; while kill -0 "$GUI" 2>/dev/null; do GUI=$((GUI - 1)); done
GRACE=1 FAKE_CLAMSHELL=Yes run_wd --gen 1 --closed-until "$(soon 120)" --gui-pid "$GUI"
grep -q "revert: gui-exited" "$log"
grep -q "disablesleep 0" "$TMP/pmset.log"
grep -q " gui-exited$" "$TMP/lidguard_last_revert"
echo "ok gui-exited after force-quit"

# 11) live gui pid keeps running until the deadline
reset
sleep 30 & GUI=$!
GRACE=1 FAKE_CLAMSHELL=Yes run_wd --gen 1 --closed-until "$(soon 3)" --gui-pid "$GUI"
kill $GUI 2>/dev/null || true
grep -q "gui-exited" "$log" && fail "reverted while app alive"
grep -q "revert: closed-idle" "$log"
echo "ok live gui keeps running"

# 12) pmset runs only on transitions: one set, one clear over several polls
reset
FAKE_CLAMSHELL=No run_wd --gen 1 --closed-until "$(soon 4)"
sets=$(grep -c "disablesleep 1" "$TMP/pmset.log")
clears=$(grep -c "disablesleep 0" "$TMP/pmset.log")
[ "$sets" -eq 1 ] || fail "disablesleep 1 called $sets times"
[ "$clears" -eq 1 ] || fail "disablesleep 0 called $clears times"
echo "ok pmset only on transitions (set=$sets clear=$clears)"

# 13) SIGTERM reverts
reset
# Background the binary itself (not a bash function) so $! is the watchdog pid.
LIDGUARD_STATE_DIR="$TMP" LIDGUARD_POLL_SECONDS=1 LIDGUARD_PMSET="$fake_pmset" LIDGUARD_LOG="$log" \
  LIDGUARD_FAKE_THERMAL=nominal LIDGUARD_FAKE_CLAMSHELL=Yes \
  "$BIN" --watchdog --gen 1 --closed-until "$(soon 60)" &
WD=$!
sleep 1.5
kill -TERM $WD
wait $WD || true
grep -q "revert: signal" "$log"
grep -q "disablesleep 0" "$TMP/pmset.log"
echo "ok SIGTERM reverts"

# 14) --daemonize detaches into its own session and writes the pidfile
reset
pidfile="$TMP/wd.pid"
start=$(date +%s)
FAKE_CLAMSHELL=Yes run_wd --gen 1 --closed-until "$(soon 60)" --pidfile "$pidfile" --daemonize
[ $(( $(date +%s) - start )) -le 2 ] || fail "--daemonize did not return quickly"
for _ in $(seq 1 30); do [ -s "$pidfile" ] && break; sleep 0.1; done
WD=$(tr -d '[:space:]' <"$pidfile")
kill -0 "$WD" || fail "daemon not running"
touch "$TMP/lidguard_stop"
for _ in $(seq 1 40); do kill -0 "$WD" 2>/dev/null || break; sleep 0.1; done
kill -0 "$WD" 2>/dev/null && fail "daemon ignored stop file"
grep -q "revert: stop-file" "$log"
[ -e "$pidfile" ] && fail "pidfile not removed"
echo "ok daemonize + stop within poll"

# 15) --ac-only on battery from the start: never arms, stays paused, reverts at deadline
reset
LIDGUARD_FAKE_POWER=battery FAKE_CLAMSHELL=No run_wd --gen 1 --closed-until "$(soon 2)" --ac-only
grep -q "disablesleep 1" "$TMP/pmset.log" && fail "armed on battery with --ac-only"
grep -q "power battery — pause" "$log"
grep -q "phase=battery-paused" "$log"
grep -q "revert: open-idle" "$log"
echo "ok ac-only on battery stays paused"

# 16) --ac-only: unplugging with the lid closed sends the Mac to sleep once
reset
LIDGUARD_FAKE_POWER=battery FAKE_CLAMSHELL=Yes run_wd --gen 1 --closed-until "$(soon 2)" --ac-only
grep -q "battery with lid closed — sleepnow" "$log"
[ "$(grep -c "pmset sleepnow" "$TMP/pmset.log")" -eq 1 ] || fail "sleepnow not exactly once"
echo "ok ac-only unplug with lid closed sleeps"

# 17) --ac-only: AC -> battery -> AC pauses and re-arms within the timer
reset
power="$TMP/power"; echo ac >"$power"
LIDGUARD_FAKE_POWER_FILE="$power" FAKE_CLAMSHELL=No run_wd --gen 1 --closed-until "$(soon 6)" --ac-only &
WD=$!
sleep 1.5; echo battery >"$power"
sleep 2;   echo ac >"$power"
wait $WD || true
seq=$(grep -o "disablesleep [01]" "$TMP/pmset.log" | tr '\n' ',' )
[ "$seq" = "disablesleep 1,disablesleep 0,disablesleep 1,disablesleep 0," ] || fail "unexpected pmset sequence: $seq"
grep -q "power battery — pause" "$log"
grep -q "power ac — resume" "$log"
echo "ok ac-only pause and resume ($seq)"

# 18) without --ac-only, battery changes nothing
reset
LIDGUARD_FAKE_POWER=battery FAKE_CLAMSHELL=No run_wd --gen 1 --closed-until "$(soon 2)"
grep -q "pause" "$log" && fail "paused without --ac-only"
grep -q "disablesleep 1" "$TMP/pmset.log"
echo "ok battery ignored without ac-only"

echo "ALL PASS"

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
UID_ME="$(id -u)"

# On failure, say where and show the watchdog log instead of exiting silently.
trap 'rc=$?; echo "fail: line $LINENO (exit $rc)" >&2; echo "--- watchdog log" >&2; cat "$TMP/lidguard_watchdog.log" >&2 2>/dev/null; echo "--- pmset calls" >&2; cat "$TMP/pmset.log" >&2 2>/dev/null' ERR

# A freshly built binary can take over a second on its first launch (macOS
# security check). Launch it once so timing-sensitive cases are not skewed.
"$BIN" --watchdog >/dev/null 2>&1 || true

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
  LIDGUARD_FAKE_BATTERY_PERCENT="${LIDGUARD_FAKE_BATTERY_PERCENT:-80}" \
  "$BIN" --watchdog --request-dir "$TMP" --request-uid "$UID_ME" "$@"
}

reset() {
  : >"$TMP/pmset.log"
  : >"$log"
  rm -f "$TMP/lidguard_last_revert" "$TMP/lidguard_stop" "$TMP/lidguard_request_until" "$TMP/lidguard_ui"
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
FAKE_CLAMSHELL=No run_wd --gen 1 --closed-until "$(soon 3)" --sleepnow-if-closed
grep -q "sleepnow" "$TMP/pmset.log" && fail "sleepnow while lid open"
grep -q "disablesleep 1" "$TMP/pmset.log"
grep -q "disablesleep 0" "$TMP/pmset.log"
grep -q "phase=lid-open-closed-armed" "$log"
echo "ok lid-open preemptive disablesleep"

# 8) lid closed also sets disablesleep 1
reset
FAKE_CLAMSHELL=Yes run_wd --gen 1 --closed-until "$(soon 3)"
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
  "$BIN" --watchdog --request-dir "$TMP" --request-uid "$UID_ME" --gen 1 --closed-until "$(soon 60)" &
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

# 15) timed close + --ac-only on battery: stay armed so a hotspot survives the lid
reset
LIDGUARD_FAKE_POWER=battery FAKE_CLAMSHELL=No run_wd --gen 1 --closed-until "$(soon 2)" --ac-only
grep -q "disablesleep 1" "$TMP/pmset.log" || fail "timed close did not arm on battery"
grep -q "power battery — pause" "$log" && fail "timed close paused on battery"
grep -q "phase=lid-open-closed-armed" "$log"
grep -q "revert: open-idle" "$log"
grep -q "sleepnow" "$TMP/pmset.log" && fail "sleepnow while lid open"
echo "ok timed close stays armed on battery"

# 16) timed close on battery with the lid already closed: no immediate sleep, sleep at the deadline
reset
LIDGUARD_FAKE_POWER=battery FAKE_CLAMSHELL=Yes run_wd --gen 1 --closed-until "$(soon 2)" --ac-only --sleepnow-if-closed
grep -q "disablesleep 1" "$TMP/pmset.log" || fail "did not hold disablesleep"
grep -q "phase=lid-closed-awake" "$log" || fail "never stayed awake with the lid closed"
grep -q "battery with lid closed — sleepnow" "$log" && fail "slept immediately on battery"
grep -q "revert: closed-idle" "$log"
grep -q "clamshell closed — sleepnow" "$log"
[ "$(grep -c "pmset sleepnow" "$TMP/pmset.log")" -eq 1 ] || fail "sleepnow not exactly once at the deadline"
echo "ok timed close keeps hotspot until the deadline"

# 17) 무한 still pauses on battery and re-arms when power returns
reset
power="$TMP/power"; echo ac >"$power"
LIDGUARD_FAKE_POWER_FILE="$power" FAKE_CLAMSHELL=No \
  run_wd --gen 1 --closed-until 0 --closed-unlimited --ac-only &
WD=$!
sleep 1.5; echo battery >"$power"
sleep 2;   echo ac >"$power"
sleep 1.5
touch "$TMP/lidguard_stop"
wait $WD || true
seq=$(grep -o "disablesleep [01]" "$TMP/pmset.log" | tr '\n' ',' )
[ "$seq" = "disablesleep 1,disablesleep 0,disablesleep 1,disablesleep 0," ] || fail "unexpected pmset sequence: $seq"
grep -q "power battery — pause" "$log"
grep -q "power ac — resume" "$log"
grep -q "sleepnow" "$TMP/pmset.log" && fail "sleepnow while lid open"
echo "ok unlimited pauses and resumes ($seq)"

# 18) without --ac-only, battery changes nothing
reset
LIDGUARD_FAKE_POWER=battery FAKE_CLAMSHELL=No run_wd --gen 1 --closed-until "$(soon 3)"
grep -q "pause" "$log" && fail "paused without --ac-only"
grep -q "disablesleep 1" "$TMP/pmset.log"
echo "ok battery ignored without ac-only"

# 19) battery at 5% or lower on battery power ends the session
reset
LIDGUARD_FAKE_POWER=battery LIDGUARD_FAKE_BATTERY_PERCENT=5 FAKE_CLAMSHELL=Yes run_wd --gen 1 --closed-until "$(soon 30)" --sleepnow-if-closed
grep -q "revert: battery-low 5%" "$log"
grep -q "disablesleep 0" "$TMP/pmset.log"
grep -q "pmset sleepnow" "$TMP/pmset.log"
grep -q " battery-low 5%$" "$TMP/lidguard_last_revert"
echo "ok battery 5% reverts and sleeps"

# 20) 4% while charging is not low
reset
LIDGUARD_FAKE_POWER=ac LIDGUARD_FAKE_BATTERY_PERCENT=4 FAKE_CLAMSHELL=Yes run_wd --gen 1 --closed-until "$(soon 2)"
grep -q "battery-low" "$log" && fail "battery-low while charging"
grep -q "revert: closed-idle" "$log"
echo "ok low battery ignored while charging"

# 21) --closed-unlimited without --ac-only is refused
reset
rc=0
run_wd --gen 1 --closed-until 0 --closed-unlimited 2>/dev/null || rc=$?
[ "$rc" -eq 2 ] || fail "closed-unlimited without ac-only exited $rc"
grep -q "disablesleep 1" "$TMP/pmset.log" && fail "armed without ac-only"
echo "ok closed-unlimited needs ac-only"

# 22) --closed-unlimited --ac-only keeps running with no deadline until 해제
reset
LIDGUARD_STATE_DIR="$TMP" LIDGUARD_POLL_SECONDS=1 LIDGUARD_PMSET="$fake_pmset" LIDGUARD_LOG="$log" \
  LIDGUARD_FAKE_THERMAL=nominal LIDGUARD_FAKE_CLAMSHELL=Yes LIDGUARD_FAKE_POWER=ac LIDGUARD_FAKE_BATTERY_PERCENT=80 \
  "$BIN" --watchdog --request-dir "$TMP" --request-uid "$UID_ME" --gen 1 --closed-until 0 --closed-unlimited --ac-only &
WD=$!
sleep 3
kill -0 $WD || fail "unlimited watchdog exited early"
grep -q "phase=lid-closed-awake" "$log"
grep -q "closed_unlimited=1" "$TMP/lidguard_ui"
touch "$TMP/lidguard_stop"
wait $WD || true
grep -q "revert: stop-file" "$log"
[ "$(grep -c "disablesleep 1" "$TMP/pmset.log")" -eq 1 ] || fail "unlimited re-armed repeatedly"
echo "ok closed-unlimited runs until stop"

# 23) --closed-unlimited --ac-only: unplugging with the lid closed sleeps
reset
LIDGUARD_FAKE_POWER=battery FAKE_CLAMSHELL=Yes run_wd --gen 1 --closed-until 0 --closed-unlimited --ac-only &
WD=$!
sleep 2.5
touch "$TMP/lidguard_stop"
wait $WD || true
grep -q "battery with lid closed — sleepnow" "$log"
grep -q "disablesleep 1" "$TMP/pmset.log" && fail "armed on battery"
echo "ok closed-unlimited pauses on battery"

ui_until() { sed -n 's/^closed_until=//p' "$TMP/lidguard_ui"; }

# 24) a request file moves the deadline later while running, no restart
reset
start=$(date +%s)
LIDGUARD_MIN_REQUEST_SECONDS=1 FAKE_CLAMSHELL=No run_wd --gen 1 --closed-until "$(soon 2)" &
WD=$!
sleep 1; want=$(soon 4); echo "$want" >"$TMP/lidguard_request_until"
sleep 1.5
[ "$(ui_until)" = "$want" ] || fail "ui closed_until $(ui_until) != $want"
[ -e "$TMP/lidguard_request_until" ] && fail "request not consumed"
wait $WD || true
[ $(( $(date +%s) - start )) -ge 4 ] || fail "deadline did not move"
grep -q "request closed_until" "$log"
grep -q "revert: open-idle" "$log"
[ "$(grep -c "disablesleep 1" "$TMP/pmset.log")" -eq 1 ] || fail "re-armed on extend"
echo "ok request extends deadline"

# 25) a request beyond 6 hours is clamped to now+6h
reset
FAKE_CLAMSHELL=No run_wd --gen 1 --closed-until "$(soon 30)" &
WD=$!
sleep 1; echo "$(soon 36000)" >"$TMP/lidguard_request_until"
sleep 1.5
cap=$(( $(date +%s) + 21600 ))
u=$(ui_until)
[ "$u" -le "$cap" ] && [ "$u" -ge $(( cap - 5 )) ] || fail "not clamped to 6h: $u vs $cap"
grep -q "clamped from" "$log"
touch "$TMP/lidguard_stop"; wait $WD || true
echo "ok request capped at 6 hours"

# 26) shortening below the minimum is lifted to now+minimum, then ends
reset
start=$(date +%s)
LIDGUARD_MIN_REQUEST_SECONDS=2 FAKE_CLAMSHELL=No run_wd --gen 1 --closed-until "$(soon 60)" &
WD=$!
sleep 1; echo "$(date +%s)" >"$TMP/lidguard_request_until"
wait $WD || true
el=$(( $(date +%s) - start ))
[ "$el" -ge 3 ] && [ "$el" -le 8 ] || fail "shortened session ran ${el}s"
grep -q "revert: open-idle" "$log"
echo "ok request shortens with a floor"

# 27) 무한 ignores deadline requests
reset
FAKE_CLAMSHELL=No LIDGUARD_FAKE_POWER=ac run_wd --gen 1 --closed-until 0 --closed-unlimited --ac-only &
WD=$!
sleep 1; echo "$(soon 5)" >"$TMP/lidguard_request_until"
sleep 1.5
grep -q "request ignored: unlimited" "$log" || fail "unlimited took a deadline"
grep -q "closed_unlimited=1" "$TMP/lidguard_ui"
touch "$TMP/lidguard_stop"; wait $WD || true
echo "ok unlimited ignores requests"

# 28) symlinked request and stop files are refused (root must not follow links)
reset
echo "$(soon 3)" >"$TMP/target"
LIDGUARD_MIN_REQUEST_SECONDS=1 FAKE_CLAMSHELL=No run_wd --gen 1 --closed-until "$(soon 3)" &
WD=$!
sleep 0.5
ln -sf "$TMP/target" "$TMP/lidguard_request_until"
ln -sf "$TMP/target" "$TMP/lidguard_stop"
wait $WD || true
grep -q "request closed_until" "$log" && fail "followed a symlinked request"
grep -q "revert: stop-file" "$log" && fail "followed a symlinked stop file"
grep -q "revert: open-idle" "$log"
rm -f "$TMP/lidguard_request_until" "$TMP/lidguard_stop" "$TMP/target"
echo "ok symlinks refused"

# 29) request dir and uid must come together
reset
rc=0
"$BIN" --watchdog --gen 1 --closed-until 0 --request-dir "$TMP" 2>/dev/null || rc=$?
[ "$rc" -eq 2 ] || fail "request-dir without uid exited $rc"
echo "ok request args paired"

echo "ALL PASS"

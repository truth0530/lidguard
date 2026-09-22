#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WATCHDOG="$ROOT/scripts/watchdog.sh"
TMP="$(mktemp -d /tmp/lidguard-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

fake_pmset="$TMP/pmset"
fake_ioreg="$TMP/ioreg"
fake_pgrep="$TMP/pgrep"
fake_caffeinate="$TMP/caffeinate"
log="$TMP/lidguard_watchdog.log"

cat >"$fake_pmset" <<'EOF'
#!/bin/bash
echo "pmset $*" >>"${LIDGUARD_STATE_DIR}/pmset.log"
if [ "${1:-}" = "-g" ] && [ "${2:-}" = "therm" ]; then
  if [ -n "${FAKE_THERM:-}" ]; then
    echo "CPU_Speed_Limit = ${FAKE_THERM}"
  fi
fi
EOF
cat >"$fake_ioreg" <<'EOF'
#!/bin/bash
if [ "${FAKE_CLAMSHELL:-}" = "Yes" ]; then
  echo '"AppleClamshellState" = Yes'
else
  echo '"AppleClamshellState" = No'
fi
EOF
cat >"$fake_pgrep" <<'EOF'
#!/bin/bash
exit ${FAKE_PGREP_EXIT:-0}
EOF
cat >"$fake_caffeinate" <<'EOF'
#!/bin/bash
echo "caffeinate $*" >>"${LIDGUARD_STATE_DIR}/caffeinate.log"
exec /bin/sleep 60
EOF
chmod +x "$fake_pmset" "$fake_ioreg" "$fake_pgrep" "$fake_caffeinate"

run_wd() {
  LIDGUARD_STATE_DIR="$TMP" \
  LIDGUARD_POLL_SECONDS="${POLL:-1}" \
  LIDGUARD_PMSET="$fake_pmset" \
  LIDGUARD_IOREG="${IOREG_OVERRIDE:-$fake_ioreg}" \
  LIDGUARD_PKILL="/usr/bin/true" \
  LIDGUARD_PGREP="$fake_pgrep" \
  LIDGUARD_CAFFEINATE="$fake_caffeinate" \
  LIDGUARD_LOG="$log" \
  FAKE_THERM="${FAKE_THERM:-}" \
  FAKE_CLAMSHELL="${FAKE_CLAMSHELL:-No}" \
  FAKE_PGREP_EXIT="${FAKE_PGREP_EXIT:-0}" \
  "$WATCHDOG" "$@"
}

echo 1 >"$TMP/lidguard_gen"

# 1) closed + lid closed: deadline reverts disablesleep
POLL=1
until=$(( $(date +%s) + 1 ))
FAKE_CLAMSHELL=Yes run_wd --until "$until" --gen 1 --mode closed
grep -q "pmset -a disablesleep 0" "$TMP/pmset.log"
grep -q "revert: closed-idle" "$log"
echo "ok closed deadline"

# 2) gen mismatch does not revert
: >"$TMP/pmset.log"
echo 2 >"$TMP/lidguard_gen"
until=$(( $(date +%s) + 1 ))
FAKE_CLAMSHELL=Yes run_wd --until "$until" --gen 1 --mode closed
if grep -q "disablesleep 0" "$TMP/pmset.log"; then
  echo "fail: reverted after gen change" >&2
  exit 1
fi
grep -q "gen changed, exit without revert" "$log"
echo "ok gen mismatch"

# 3) thermal abort
: >"$TMP/pmset.log"
echo 1 >"$TMP/lidguard_gen"
: >"$log"
until=$(( $(date +%s) + 30 ))
FAKE_THERM=50 FAKE_CLAMSHELL=Yes POLL=1 run_wd --until "$until" --gen 1 --mode closed
grep -q "thermal" "$log"
grep -q "disablesleep 0" "$TMP/pmset.log"
echo "ok thermal"

# 4) clamshell sleepnow after closed deadline
: >"$TMP/pmset.log"
echo 1 >"$TMP/lidguard_gen"
until=$(( $(date +%s) + 1 ))
FAKE_CLAMSHELL=Yes POLL=1 run_wd --until "$until" --gen 1 --mode closed --sleepnow-if-closed
grep -q "sleepnow" "$TMP/pmset.log"
echo "ok sleepnow-if-closed"

# 5) open mode never sets disablesleep 1
: >"$TMP/pmset.log"
echo 1 >"$TMP/lidguard_gen"
until=$(( $(date +%s) + 1 ))
POLL=1 run_wd --until "$until" --gen 1 --mode open
if grep -q "disablesleep 1" "$TMP/pmset.log"; then
  echo "fail: open mode set disablesleep 1" >&2
  exit 1
fi
echo "ok open mode no disablesleep 1"

# 6) stop file reverts before deadline
: >"$TMP/pmset.log"
echo 1 >"$TMP/lidguard_gen"
touch "$TMP/lidguard_stop"
until=$(( $(date +%s) + 30 ))
FAKE_CLAMSHELL=Yes POLL=1 run_wd --until "$until" --gen 1 --mode closed
grep -q "stop-file" "$log"
grep -q "disablesleep 0" "$TMP/pmset.log"
rm -f "$TMP/lidguard_stop"
echo "ok stop-file"

# 7) closed-mode with lid OPEN must set disablesleep 1 immediately, then
#    clear it on deadline, and must not sleepnow
: >"$TMP/pmset.log"
: >"$log"
echo 1 >"$TMP/lidguard_gen"
until=$(( $(date +%s) + 1 ))
FAKE_CLAMSHELL=No POLL=1 run_wd --until "$until" --gen 1 --mode closed --sleepnow-if-closed
if grep -q "sleepnow" "$TMP/pmset.log"; then
  echo "fail: sleepnow while lid open" >&2
  exit 1
fi
grep -q "disablesleep 1" "$TMP/pmset.log"
grep -q "disablesleep 0" "$TMP/pmset.log"
grep -q "phase=lid-open-closed-armed" "$log"
echo "ok lid-open preemptive disablesleep"

# 8) closed-mode with lid closed also sets disablesleep 1
: >"$TMP/pmset.log"
: >"$log"
echo 1 >"$TMP/lidguard_gen"
until=$(( $(date +%s) + 1 ))
FAKE_CLAMSHELL=Yes POLL=1 run_wd --until "$until" --gen 1 --mode closed
grep -q "disablesleep 1" "$TMP/pmset.log"
grep -q "disablesleep 0" "$TMP/pmset.log"
echo "ok lid-closed sets disablesleep"

# 9) a missing ioreg executable must remain unknown and must never cause a
#    false sleepnow request.
: >"$TMP/pmset.log"
: >"$log"
echo 1 >"$TMP/lidguard_gen"
until=$(( $(date +%s) + 1 ))
IOREG_OVERRIDE="$TMP/does-not-exist" POLL=1 run_wd --until "$until" --gen 1 --mode closed --sleepnow-if-closed
if grep -q "sleepnow" "$TMP/pmset.log"; then
  echo "fail: sleepnow with unavailable lid sensor" >&2
  exit 1
fi
grep -q "state unavailable" "$log"
echo "ok missing ioreg is fail-safe"

echo "ALL PASS"

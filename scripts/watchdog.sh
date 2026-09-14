#!/bin/bash
# Wall-clock watchdog for lidguard. Must not depend on GUI NSTimer.
# Closed-lid keep-awake applies ONLY while the clamshell is actually closed.
# Opening the lid clears disablesleep so the display can sleep.
set -u

STATE_DIR="${LIDGUARD_STATE_DIR:-/tmp}"
POLL="${LIDGUARD_POLL_SECONDS:-10}"
PMSET="${LIDGUARD_PMSET:-/usr/bin/pmset}"
IOREG="${LIDGUARD_IOREG:-/usr/bin/ioreg}"
DATE="${LIDGUARD_DATE:-/bin/date}"
PKILL="${LIDGUARD_PKILL:-/usr/bin/pkill}"
PGREP="${LIDGUARD_PGREP:-/usr/bin/pgrep}"
CAFFEINATE="${LIDGUARD_CAFFEINATE:-/usr/bin/caffeinate}"
LOG="${LIDGUARD_LOG:-$STATE_DIR/lidguard_watchdog.log}"

UNTIL=""
GEN=""
MODE=""
CLOSED_UNTIL=0
OPEN_UNTIL=0
OPEN_UNLIMITED=0
SLEEPNOW_IF_CLOSED=0
REQUIRE_GUI=0

usage() {
  echo "usage: watchdog.sh --gen N [--mode open|closed] [--until EPOCH] [--closed-until EPOCH] [--open-until EPOCH] [--open-unlimited] [--sleepnow-if-closed] [--require-gui]" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --until) UNTIL="${2:-}"; shift 2 ;;
    --gen) GEN="${2:-}"; shift 2 ;;
    --mode) MODE="${2:-}"; shift 2 ;;
    --closed-until) CLOSED_UNTIL="${2:-0}"; shift 2 ;;
    --open-until) OPEN_UNTIL="${2:-0}"; shift 2 ;;
    --open-unlimited) OPEN_UNLIMITED=1; shift ;;
    --sleepnow-if-closed) SLEEPNOW_IF_CLOSED=1; shift ;;
    --require-gui) REQUIRE_GUI=1; shift ;;
    -h|--help) usage ;;
    *) echo "unknown arg: $1" >&2; usage ;;
  esac
done

[ -n "$GEN" ] || usage

# Compat: --mode + --until map onto the matching lid timer. The other lid
# state does not keep the machine awake (0 = 끔).
if [ -n "$UNTIL" ]; then
  if [ "$MODE" = "closed" ]; then
    CLOSED_UNTIL="$UNTIL"
  elif [ "$MODE" = "open" ]; then
    OPEN_UNTIL="$UNTIL"
  fi
fi

log() { echo "$($DATE '+%Y-%m-%dT%H:%M:%S') $*" >>"$LOG"; }

read_gen() {
  cat "$STATE_DIR/lidguard_gen" 2>/dev/null || echo ""
}

clamshell_closed() {
  "$IOREG" -r -k AppleClamshellState -d 4 2>/dev/null \
    | awk -F'= ' '/AppleClamshellState/ { gsub(/[ ;]/, "", $2); print $2; exit }' \
    | grep -qi 'Yes'
}

thermal_pressure() {
  "$PMSET" -g therm 2>/dev/null | awk -F= '/CPU_Speed_Limit/ { gsub(/ /,"",$2); print $2; exit }'
}

gui_alive() {
  "$PGREP" -x lidguard >/dev/null 2>&1
}

stale() {
  [ "$(read_gen)" != "$GEN" ]
}

stop_requested() {
  [ -f "$STATE_DIR/lidguard_stop" ]
}

kill_caffeinate() {
  if [ -f "$STATE_DIR/lidguard_caffeinate.pid" ]; then
    kill "$(cat "$STATE_DIR/lidguard_caffeinate.pid")" >/dev/null 2>&1 || true
  fi
  "$PKILL" -f "/usr/bin/caffeinate -i" >/dev/null 2>&1 || true
  rm -f "$STATE_DIR/lidguard_caffeinate.pid"
}

ensure_caffeinate() {
  if [ -f "$STATE_DIR/lidguard_caffeinate.pid" ] && kill -0 "$(cat "$STATE_DIR/lidguard_caffeinate.pid")" 2>/dev/null; then
    return 0
  fi
  if [ ! -x "$CAFFEINATE" ]; then
    return 0
  fi
  nohup "$CAFFEINATE" -i >/dev/null 2>&1 &
  echo $! >"$STATE_DIR/lidguard_caffeinate.pid"
}

clear_disablesleep() {
  "$PMSET" -a disablesleep 0 >/dev/null 2>&1 || true
}

set_disablesleep() {
  "$PMSET" -a disablesleep 1 >/dev/null 2>&1 || true
}

revert() {
  local reason="$1"
  log "revert: $reason gen=$GEN closed_until=$CLOSED_UNTIL open_until=$OPEN_UNTIL"
  if stale; then
    log "skip revert, gen changed ($(read_gen) != $GEN)"
    return 0
  fi
  clear_disablesleep
  kill_caffeinate
  rm -f "$STATE_DIR/lidguard_until" \
        "$STATE_DIR/lidguard_watchdog.pid"
  if [ "$SLEEPNOW_IF_CLOSED" -eq 1 ] && clamshell_closed; then
    log "clamshell closed — sleepnow"
    "$PMSET" sleepnow >/dev/null 2>&1 || true
  fi
}

now_epoch() { "$DATE" +%s; }

closed_active() {
  local now="$1"
  [ "$CLOSED_UNTIL" -gt 0 ] 2>/dev/null && [ "$now" -lt "$CLOSED_UNTIL" ]
}

open_active() {
  local now="$1"
  [ "$OPEN_UNLIMITED" -eq 1 ] && return 0
  [ "$OPEN_UNTIL" -gt 0 ] 2>/dev/null && [ "$now" -lt "$OPEN_UNTIL" ]
}

log "start gen=$GEN closed_until=$CLOSED_UNTIL open_until=$OPEN_UNTIL unlimited=$OPEN_UNLIMITED poll=$POLL"

missed_gui=0
while true; do
  if stale; then
    log "gen changed, exit without revert"
    exit 0
  fi

  if stop_requested; then
    revert "stop-file"
    exit 0
  fi

  now="$(now_epoch)"
  c_on=0
  o_on=0
  closed_active "$now" && c_on=1
  open_active "$now" && o_on=1

  limit="$(thermal_pressure || true)"
  if [ -n "$limit" ] && [ "$limit" -lt 80 ] 2>/dev/null; then
    revert "thermal CPU_Speed_Limit=$limit"
    exit 0
  fi

  if [ "$REQUIRE_GUI" -eq 1 ]; then
    if gui_alive; then
      missed_gui=0
    else
      missed_gui=$((missed_gui + 1))
      if [ "$missed_gui" -ge 6 ] || [ "$POLL" -ge 30 ]; then
        revert "gui-exited"
        exit 0
      fi
    fi
  fi

  if clamshell_closed; then
    if [ "$c_on" -eq 1 ]; then
      set_disablesleep
    else
      revert "closed-idle"
      exit 0
    fi
  else
    # Lid open: never leave disablesleep on — that keeps the display up all day.
    clear_disablesleep
    if [ "$o_on" -eq 1 ]; then
      ensure_caffeinate
    else
      kill_caffeinate
      if [ "$c_on" -eq 0 ]; then
        revert "open-idle"
        exit 0
      fi
    fi
  fi

  sleep "$POLL"
done

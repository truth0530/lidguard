#!/bin/bash
# Wall-clock watchdog for lidguard. Must not depend on GUI NSTimer.
# Closed-lid keep-awake must set disablesleep BEFORE the lid closes.
# Clamshell Sleep is synchronous; a post-close poll always loses.
set -u

STATE_DIR="${LIDGUARD_STATE_DIR:-/tmp}"
POLL="${LIDGUARD_POLL_SECONDS:-10}"
PMSET="${LIDGUARD_PMSET:-/usr/bin/pmset}"
IOREG="${LIDGUARD_IOREG:-/usr/sbin/ioreg}"
DATE="${LIDGUARD_DATE:-/bin/date}"
PKILL="${LIDGUARD_PKILL:-/usr/bin/pkill}"
PGREP="${LIDGUARD_PGREP:-/usr/bin/pgrep}"
CAFFEINATE="${LIDGUARD_CAFFEINATE:-/usr/bin/caffeinate}"
STAT="${LIDGUARD_STAT:-/usr/bin/stat}"
LOG="${LIDGUARD_LOG:-$STATE_DIR/lidguard_watchdog.log}"
HEARTBEAT="${LIDGUARD_HEARTBEAT:-$STATE_DIR/lidguard_heartbeat}"
UI_STATE="${LIDGUARD_UI_STATE:-$STATE_DIR/lidguard_ui}"

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

clamshell_state() {
  local state
  state="$($IOREG -r -k AppleClamshellState -d 4 2>/dev/null \
    | awk -F'= ' '/AppleClamshellState/ { gsub(/[ ;]/, "", $2); print $2; exit }')"
  case "$state" in
    Yes) echo closed ;;
    No) echo open ;;
    *) echo unknown ;;
  esac
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

pid_running() {
  local pid="$1"
  [ -n "$pid" ] || return 1
  /bin/ps -p "$pid" -o pid= >/dev/null 2>&1
}

console_user() {
  "$STAT" -f %Su /dev/console 2>/dev/null || true
}

write_heartbeat() {
  local now="$1"
  local lid="$2"
  local phase="$3"
  echo "$now" >"$HEARTBEAT"
  cat >"$UI_STATE" <<EOF
heartbeat=$now
closed_until=$CLOSED_UNTIL
open_until=$OPEN_UNTIL
open_unlimited=$OPEN_UNLIMITED
lid=$lid
phase=$phase
gen=$GEN
EOF
  if [ "$phase" != "$LAST_PHASE" ]; then
    log "phase=$phase lid=$lid"
    LAST_PHASE="$phase"
  fi
}

kill_caffeinate() {
  if [ -f "$STATE_DIR/lidguard_caffeinate.pid" ]; then
    kill "$(cat "$STATE_DIR/lidguard_caffeinate.pid")" >/dev/null 2>&1 || true
  fi
  "$PKILL" -f "/usr/bin/caffeinate -i" >/dev/null 2>&1 || true
  rm -f "$STATE_DIR/lidguard_caffeinate.pid"
}

ensure_caffeinate() {
  if [ -f "$STATE_DIR/lidguard_caffeinate.pid" ] && pid_running "$(tr -d '[:space:]' <"$STATE_DIR/lidguard_caffeinate.pid")"; then
    return 0
  fi
  if [ ! -x "$CAFFEINATE" ]; then
    return 0
  fi
  local user
  user="$(console_user)"
  if [ "$(id -u)" -eq 0 ] && [ -n "$user" ] && [ "$user" != "root" ]; then
    sudo -u "$user" "$CAFFEINATE" -i </dev/null >/dev/null 2>&1 &
  else
    "$CAFFEINATE" -i </dev/null >/dev/null 2>&1 &
  fi
  echo $! >"$STATE_DIR/lidguard_caffeinate.pid"
}

SLEEP_DISABLED=""
LAST_PHASE=""
LAST_LID_STATE="unknown"

clear_disablesleep() {
  if "$PMSET" -a disablesleep 0 >/dev/null 2>&1; then
    if [ "$SLEEP_DISABLED" != "0" ]; then
      log "disablesleep 0"
    fi
    SLEEP_DISABLED=0
  else
    log "disablesleep 0 failed"
  fi
}

set_disablesleep() {
  if "$PMSET" -a disablesleep 1 >/dev/null 2>&1; then
    if [ "$SLEEP_DISABLED" != "1" ]; then
      log "disablesleep 1"
    fi
    SLEEP_DISABLED=1
  else
    log "disablesleep 1 failed"
  fi
}

revert() {
  local reason="$1"
  log "revert: $reason gen=$GEN closed_until=$CLOSED_UNTIL open_until=$OPEN_UNTIL"
  if stale; then
    log "skip revert, gen changed ($(read_gen) != $GEN)"
    return 0
  fi
  if [ "$SLEEP_DISABLED" = "1" ] || [ "$CLOSED_UNTIL" -gt 0 ] 2>/dev/null; then
    clear_disablesleep
  fi
  kill_caffeinate
  rm -f "$STATE_DIR/lidguard_until" \
        "$STATE_DIR/lidguard_watchdog.pid"
  local lid_state
  lid_state="$(clamshell_state)"
  # A transient unreadable lid state can occur while disablesleep is being
  # cleared. Only fall back to the last confirmed state when it is unknown;
  # a confirmed open lid must never trigger sleepnow.
  if [ "$SLEEPNOW_IF_CLOSED" -eq 1 ] \
    && { [ "$lid_state" = "closed" ] || \
         { [ "$lid_state" = "unknown" ] && [ "$LAST_LID_STATE" = "closed" ]; }; }; then
    log "clamshell closed — sleepnow"
    "$PMSET" sleepnow >/dev/null 2>&1 || true
  elif [ "$SLEEPNOW_IF_CLOSED" -eq 1 ]; then
    log "clamshell not confirmed closed — skip sleepnow state=$lid_state last=$LAST_LID_STATE"
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
if closed_active "$(now_epoch)"; then
  set_disablesleep
fi

missed_gui=0
while true; do
  # Stop file first. Bumping gen during 해제 must not skip revert.
  if stop_requested; then
    revert "stop-file"
    exit 0
  fi

  if stale; then
    log "gen changed, exit without revert"
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

  # Closed-mode must hold disablesleep even while the lid is still open.
  # Otherwise the next Clamshell Sleep wins the race against this poll.
  # Open-only mode is unprivileged — do not call pmset.
  if [ "$c_on" -eq 1 ]; then
    set_disablesleep
  elif [ "$SLEEP_DISABLED" = "1" ] || [ "$CLOSED_UNTIL" -gt 0 ] 2>/dev/null; then
    clear_disablesleep
  fi

  lid_state="$(clamshell_state)"
  if [ "$lid_state" = "closed" ]; then
    LAST_LID_STATE="closed"
    if [ "$c_on" -eq 1 ]; then
      write_heartbeat "$now" "closed" "lid-closed-awake"
    else
      revert "closed-idle"
      exit 0
    fi
  elif [ "$lid_state" = "open" ]; then
    LAST_LID_STATE="open"
    if [ "$o_on" -eq 1 ]; then
      ensure_caffeinate
      write_heartbeat "$now" "open" "lid-open-awake"
    else
      kill_caffeinate
      if [ "$c_on" -eq 0 ]; then
        revert "open-idle"
        exit 0
      fi
      write_heartbeat "$now" "open" "lid-open-closed-armed"
    fi
  else
    log "clamshell state unavailable; retaining last=$LAST_LID_STATE"
    if [ "$c_on" -eq 1 ]; then
      write_heartbeat "$now" "$LAST_LID_STATE" "lid-state-unknown"
    else
      revert "lid-state-unknown"
      exit 0
    fi
  fi

  sleep "$POLL"
done

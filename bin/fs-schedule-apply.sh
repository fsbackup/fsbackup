#!/usr/bin/env bash
set -u
set -o pipefail

# =============================================================================
# fs-schedule-apply.sh — apply schedule from fsbackup.conf to systemd timers
#
# Reads *_SCHEDULE vars from fsbackup.conf and writes per-class timer drop-ins
# under /etc/systemd/system/<unit>.timer.d/schedule.conf, then reloads.
#
# Schedule var format (OnCalendar= values):
#   CLASS1_DAILY_SCHEDULE="*-*-* 01:45"
#   CLASS1_WEEKLY_SCHEDULE="Sat *-*-* 02:00"
#   CLASS1_MONTHLY_SCHEDULE="*-*-01 03:00"
#   CLASS2_DAILY_SCHEDULE="*-*-* 02:15"
#   CLASS2_WEEKLY_SCHEDULE="Sat *-*-* 02:30"
#   CLASS3_MONTHLY_SCHEDULE="*-*-01 04:00"
#
# Must run as root (writes to /etc/systemd/system/).
# =============================================================================

[[ "$(id -u)" -eq 0 ]] || { echo "Must run as root"; exit 1; }

CONF_FILE="/etc/fsbackup/fsbackup.conf"
[[ -f "$CONF_FILE" ]] || { echo "Config not found: $CONF_FILE"; exit 2; }

. "$CONF_FILE"

DROPIN_DIR="/etc/systemd/system"
CHANGED=0

apply_schedule() {
  local class="$1"
  local type="$2"
  local schedule="$3"

  local unit="fsbackup-runner-${type}@${class}.timer"
  local dropin="${DROPIN_DIR}/${unit}.d"
  local conf="${dropin}/schedule.conf"

  mkdir -p "$dropin"

  local current=""
  [[ -f "$conf" ]] && current=$(grep "^OnCalendar=" "$conf" | head -1 | cut -d= -f2-)

  if [[ "$current" != "$schedule" ]]; then
    cat >"$conf" <<EOF
[Timer]
OnCalendar=
OnCalendar=${schedule}
EOF
    echo "Updated: ${unit} → ${schedule}"
    CHANGED=1
  else
    echo "Unchanged: ${unit}"
  fi
}

# class1
[[ -n "${CLASS1_DAILY_SCHEDULE:-}" ]]   && apply_schedule class1 daily   "$CLASS1_DAILY_SCHEDULE"
[[ -n "${CLASS1_WEEKLY_SCHEDULE:-}" ]]  && apply_schedule class1 weekly  "$CLASS1_WEEKLY_SCHEDULE"
[[ -n "${CLASS1_MONTHLY_SCHEDULE:-}" ]] && apply_schedule class1 monthly "$CLASS1_MONTHLY_SCHEDULE"

# class2
[[ -n "${CLASS2_DAILY_SCHEDULE:-}" ]]   && apply_schedule class2 daily   "$CLASS2_DAILY_SCHEDULE"
[[ -n "${CLASS2_WEEKLY_SCHEDULE:-}" ]]  && apply_schedule class2 weekly  "$CLASS2_WEEKLY_SCHEDULE"
[[ -n "${CLASS2_MONTHLY_SCHEDULE:-}" ]] && apply_schedule class2 monthly "$CLASS2_MONTHLY_SCHEDULE"

# class3
[[ -n "${CLASS3_DAILY_SCHEDULE:-}" ]]   && apply_schedule class3 daily   "$CLASS3_DAILY_SCHEDULE"
[[ -n "${CLASS3_WEEKLY_SCHEDULE:-}" ]]  && apply_schedule class3 weekly  "$CLASS3_WEEKLY_SCHEDULE"
[[ -n "${CLASS3_MONTHLY_SCHEDULE:-}" ]] && apply_schedule class3 monthly "$CLASS3_MONTHLY_SCHEDULE"

if [[ "$CHANGED" -eq 1 ]]; then
  systemctl daemon-reload
  # Restart only active timers so disabled ones aren't started unintentionally
  while IFS= read -r unit; do
    systemctl restart "$unit" 2>/dev/null && echo "Restarted: $unit"
  done < <(systemctl list-units --type=timer --state=active --no-legend \
             | awk '{print $1}' | grep '^fsbackup-runner-')
  echo "Schedule applied."
else
  echo "No changes."
fi

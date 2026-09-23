#!/usr/bin/env bash
set -u
set -o pipefail

# =============================================================================
# fs-schedule-set.sh — change one runner schedule in fsbackup.conf and apply it
#
# Usage:
#   sudo fs-schedule-set.sh <KEY> <OnCalendar expression>
#   e.g. sudo fs-schedule-set.sh CLASS1_DAILY_SCHEDULE "*-*-* 01:45"
#
# Called by the web UI (Configuration → Schedule) through a sudoers drop-in
# scoped to this script. fsbackup.conf is sourced as root by
# fs-schedule-apply.sh, so the value is validated strictly here — not only in
# the web UI — before it is written:
#   - KEY must be CLASS[1-3]_{DAILY,WEEKLY,MONTHLY}_SCHEDULE and already set
#     (uncommented) in fsbackup.conf; enabling a new schedule also needs its
#     timer enabled, which stays a console step
#   - VALUE may only contain OnCalendar characters and must parse with
#     `systemd-analyze calendar`
#
# The conf is rewritten atomically (previous copy kept as fsbackup.conf.bak),
# then fs-schedule-apply.sh regenerates the timer drop-ins.
# =============================================================================

[[ "$(id -u)" -eq 0 ]] || { echo "Must run as root"; exit 1; }
[[ $# -eq 2 ]] || { echo "Usage: $0 <CLASSn_TYPE_SCHEDULE> <OnCalendar expression>"; exit 2; }

KEY="$1"
VALUE="$2"
CONF_FILE="/etc/fsbackup/fsbackup.conf"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ "$KEY" =~ ^CLASS[1-3]_(DAILY|WEEKLY|MONTHLY)_SCHEDULE$ ]] \
  || { echo "Invalid schedule key: $KEY"; exit 2; }

# OnCalendar grammar: weekday names, digits, * - : . , / ~ and spaces.
# Anything else (quotes, $, `, \, ;) could break out of the sourced assignment.
[[ ${#VALUE} -le 64 && "$VALUE" =~ ^[A-Za-z0-9*:,./~\ -]+$ ]] \
  || { echo "Invalid characters in schedule: $VALUE"; exit 2; }

systemd-analyze calendar "$VALUE" >/dev/null 2>&1 \
  || { echo "Not a valid OnCalendar expression: $VALUE"; exit 2; }

[[ -f "$CONF_FILE" ]] || { echo "Config not found: $CONF_FILE"; exit 2; }

grep -Eq "^[[:space:]]*${KEY}=" "$CONF_FILE" \
  || { echo "$KEY is not set in $CONF_FILE — enable new schedules from the console"; exit 2; }

tmp="$(mktemp "${CONF_FILE}.XXXXXX")" || { echo "Could not create temp file"; exit 1; }
trap 'rm -f "$tmp"' EXIT

awk -v key="$KEY" -v val="$VALUE" '
  $0 ~ "^[[:space:]]*" key "=" { print key "=\"" val "\""; next }
  { print }
' "$CONF_FILE" >"$tmp" || { echo "Failed to rewrite $CONF_FILE"; exit 1; }

chmod --reference="$CONF_FILE" "$tmp"
chown --reference="$CONF_FILE" "$tmp"
cp -p "$CONF_FILE" "${CONF_FILE}.bak"
mv "$tmp" "$CONF_FILE"
trap - EXIT

echo "Set ${KEY}=\"${VALUE}\" in ${CONF_FILE}"
exec "${SCRIPT_DIR}/fs-schedule-apply.sh"

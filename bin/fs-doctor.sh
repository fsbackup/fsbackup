#!/usr/bin/env bash
set -u
set -o pipefail

# =============================================================================
# fs-doctor.sh — target health + snapshot audit + immutability verification
#
# Logging (lib/log.sh): the report is printed to stdout (journald) as before
# and also written, timestamped, to $LOG_DIR/doctor-<class>.log so past runs
# rotate and can be browsed. Orphan datasets are appended to
# $LOG_DIR/fs-orphans.log (shared by all classes).
# =============================================================================

CONFIG_FILE="/etc/fsbackup/targets.yml"
BACKUP_SSH_USER="backup"

CLASS=""

NODEEXP_DIR="/var/lib/node_exporter/textfile_collector"
NODEEXP_METRIC="${NODEEXP_DIR}/fsbackup_nodeexp_health.prom"
ORPHAN_METRIC="${NODEEXP_DIR}/fsbackup_orphans.prom"

. /etc/fsbackup/fsbackup.conf
LOG_DIR="${LOG_DIR:-/var/log/fsbackup}"
. "$(dirname "$(readlink -f "$0")")/../lib/log.sh" || { echo "fs-doctor: cannot load lib/log.sh" >&2; exit 2; }
PRIMARY_SNAPSHOT_ROOT="${SNAPSHOT_ROOT:-/backup/snapshots}"

ORPHAN_LOG="${LOG_DIR}/fs-orphans.log"

usage() {
  echo "Usage: fs-doctor.sh --class <class>"
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --class) CLASS="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -n "$CLASS" ]] || usage
log_init "doctor-${CLASS}"

# say <text>: one report line — stdout (journald) and the doctor log file.
say() {
  printf '%s\n' "$*"
  [[ -n "$*" ]] && log "doctor" "$*"
  return 0
}

# row <target> <status> <detail>: one aligned report table row.
row() {
  say "$(printf "%-28s %-6s %s" "$1" "$2" "$3")"
}

# orphan_log <msg>: append to the shared fs-orphans.log instead of doctor-<class>.log.
orphan_log() {
  LOG_FILE="$ORPHAN_LOG" log "orphans" "$@"
}

START_TS=$(date +%s.%N)

for cmd in yq jq ssh; do
  command -v "$cmd" >/dev/null || { error "doctor" "$cmd not found"; exit 2; }
done

mapfile -t TARGETS < <(
  yq eval -o=json ".${CLASS}[]" "$CONFIG_FILE" | jq -c .
)

is_local_host() {
  local h="$1"
  [[ "$h" == "localhost" || "$h" == "$(hostname -s)" || "$h" == "$(hostname -f 2>/dev/null)" ]] && return 0
  getent hosts "$h" >/dev/null 2>&1 || return 1
  for ip in $(getent hosts "$h" | awk '{print $1}'); do
    hostname -I | grep -qw "$ip" && return 0
  done
  return 1
}

SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=5)

PASS=0
FAIL=0
WARN=0
MISSING_DATASETS=0

say
say "fsbackup doctor"
say "  Class:  $CLASS"
say

row "TARGET" "STAT" "DETAIL"
row "----------------------------" "------" "------------------------------"

# -----------------------------------------------------------------------------
# TARGET HEALTH
# -----------------------------------------------------------------------------
for t in "${TARGETS[@]}"; do
  id="$(jq -r '.id // empty' <<<"$t")"
  host="$(jq -r '.host // empty' <<<"$t")"
  src="$(jq -r '.source // empty' <<<"$t")"

  if [[ -z "$id" || -z "$host" || -z "$src" ]]; then
    row "${id:-<unknown>}" "WARN" "invalid target entry"
    ((WARN++))
    continue
  fi

  if [[ ! -d "${PRIMARY_SNAPSHOT_ROOT}/${CLASS}/${id}" ]]; then
    row "$id" "WARN" "dataset not provisioned (runner will auto-provision)"
    ((WARN++))
    ((MISSING_DATASETS++))
    continue
  fi

  if is_local_host "$host"; then
    if [[ -e "$src" ]]; then
      row "$id" "OK" "local path exists"
      ((PASS++))
    else
      row "$id" "FAIL" "local missing: $src"
      ((FAIL++))
    fi
    continue
  fi

  if ssh "${SSH_OPTS[@]}" "${BACKUP_SSH_USER}@${host}" "test -e '$src'" >/dev/null 2>&1; then
    row "$id" "OK" "ssh+path OK"
    ((PASS++))
  else
    row "$id" "FAIL" "ssh/path failed"
    ((FAIL++))
  fi
done

say
say "Doctor summary"
say "  OK:    $PASS"
say "  WARN:  $WARN"
say "  FAIL:  $FAIL"
say

# -----------------------------------------------------------------------------
# ORPHAN DETECTION
# -----------------------------------------------------------------------------

mapfile -t VALID_IDS < <(
  yq eval '.. | select(has("id")) | .id' "$CONFIG_FILE" | sort -u
)

declare -A VALID
for id in "${VALID_IDS[@]}"; do VALID["$id"]=1; done

ORPHAN_COUNT=0

# v2.0: datasets are at SNAPSHOT_ROOT/class/target (depth 2)
while read -r d; do
  target="$(basename "$d")"
  class="$(basename "$(dirname "$d")")"

  if [[ -z "${VALID[$target]+x}" ]]; then
    ORPHAN_COUNT=$((ORPHAN_COUNT + 1))
    orphan_log "class=${class} orphan=${target}"
  fi
done < <(find "$PRIMARY_SNAPSHOT_ROOT" -mindepth 2 -maxdepth 2 -type d)

tmp="$(mktemp)"
cat >"$tmp" <<EOF
fsbackup_orphan_snapshots_total ${ORPHAN_COUNT}
EOF
chgrp nodeexp_txt "$tmp" 2>/dev/null || true
chmod 0644 "$tmp"
mv "$tmp" "$ORPHAN_METRIC"

# -----------------------------------------------------------------------------
# ZFS SCRUB (pool-level; reads fsbackup_scrub.prom from fs-scrub-check.sh)
# -----------------------------------------------------------------------------
# Warns if the last scrub check failed, or if no clean scrub is on record
# within SCRUB_MAX_AGE_DAYS (monthly timer + margin). Report only; it doesn't
# change the target counts above.
SCRUB_PROM="${NODEEXP_DIR}/fsbackup_scrub.prom"
SCRUB_MAX_AGE_DAYS="${SCRUB_MAX_AGE_DAYS:-35}"
[[ "$SCRUB_MAX_AGE_DAYS" =~ ^[0-9]+$ ]] || SCRUB_MAX_AGE_DAYS=35

# The textfile dir is writable by fsbackup and the nodeexp_txt group, not only
# by root, so the values read from the prom file are untrusted. Bash evaluates
# array subscripts inside $(( )) and [[ -gt ]], so a value like
# `x[$(cmd)]` would run cmd. Only values that are plain numbers reach
# arithmetic or date; anything else makes the row a WARN.
_is_ts()  { [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]]; }
_is_int() { [[ "$1" =~ ^[0-9]+$ ]]; }

say "ZFS scrub"
# -f: a FIFO planted in the textfile dir would otherwise hang the doctor.
if [[ ! -f "$SCRUB_PROM" || ! -r "$SCRUB_PROM" ]]; then
  row "-" "WARN" "no scrub result yet (fsbackup-scrub.service has not finished a run)"
else
  NOW_TS="$(date +%s)"
  scrub_rows=0
  # one line per pool: <pool> <success> <last_run> <last_success> <problems>
  while read -r pool s_ok s_run s_last s_prob; do
    scrub_rows=$((scrub_rows + 1))
    if [[ ! "$s_ok" =~ ^[01]$ ]] || ! _is_ts "$s_run" || ! _is_int "$s_prob" ||
       { [[ "$s_last" != "-" ]] && ! _is_ts "$s_last"; }; then
      row "$pool" "WARN" "unreadable scrub result in ${SCRUB_PROM}"
      continue
    fi
    s_run="${s_run%.*}"; s_last="${s_last%.*}"
    if [[ "$s_ok" == "0" ]]; then
      row "$pool" "WARN" \
        "last scrub check FAILED on $(date -d "@${s_run}" +%F 2>/dev/null || echo '?') (${s_prob} problem(s)); see journalctl -u fsbackup-scrub"
    elif [[ "$s_last" == "-" ]]; then
      row "$pool" "WARN" "no clean scrub on record"
    else
      age_days=$(( (NOW_TS - 10#$s_last) / 86400 ))
      if (( age_days > 10#$SCRUB_MAX_AGE_DAYS )); then
        row "$pool" "WARN" \
          "last clean scrub ${age_days} days ago (> ${SCRUB_MAX_AGE_DAYS}); check fsbackup-scrub.timer"
      else
        row "$pool" "OK" \
          "last clean scrub $(date -d "@${s_last}" +%F) (${age_days} days ago)"
      fi
    fi
  done < <(awk '
    # pool names as zpool allows them; other lines are ignored
    /^fsbackup_scrub_[a-z_]+\{pool="[A-Za-z][A-Za-z0-9_.:-]*"\} / {
      name = $1; sub(/\{.*/, "", name)
      pool = $1; sub(/^[^"]*"/, "", pool); sub(/".*/, "", pool)
      if (!(pool in seen)) { seen[pool] = 1; order[++n] = pool }
      v[pool, name] = $2
    }
    function g(p, m) { return ((p, m) in v) ? v[p, m] : "-" }
    END {
      for (i = 1; i <= n; i++) {
        p = order[i]
        print p, g(p, "fsbackup_scrub_success"), g(p, "fsbackup_scrub_last_run_seconds"),
              g(p, "fsbackup_scrub_last_success_seconds"), g(p, "fsbackup_scrub_problems")
      }
    }' "$SCRUB_PROM")
  if [[ "$scrub_rows" -eq 0 ]]; then
    row "-" "WARN" "no pool results in ${SCRUB_PROM}"
  fi
fi
say

END_TS=$(date +%s.%N)
DURATION=$(awk "BEGIN {print $END_TS - $START_TS}")

tmp="$(mktemp)"
cat >"$tmp" <<EOF
# HELP fsbackup_doctor_duration_seconds Duration of fsbackup doctor run
# TYPE fsbackup_doctor_duration_seconds gauge
fsbackup_doctor_duration_seconds{class="$CLASS"} ${DURATION}
# HELP fsbackup_doctor_missing_datasets Targets in targets.yml with no provisioned dataset
# TYPE fsbackup_doctor_missing_datasets gauge
fsbackup_doctor_missing_datasets{class="$CLASS"} ${MISSING_DATASETS}
EOF
chgrp nodeexp_txt "$tmp" 2>/dev/null || true
chmod 0644 "$tmp"
mv "$tmp" "${NODEEXP_DIR}/fsbackup_doctor_duration.prom"

event "doctor" "Doctor complete: class=${CLASS} ok=${PASS} warn=${WARN} fail=${FAIL} missing_datasets=${MISSING_DATASETS} orphans=${ORPHAN_COUNT} duration=${DURATION}s"

exit 0


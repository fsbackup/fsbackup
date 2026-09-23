#!/usr/bin/env bash
set -u
set -o pipefail

# =============================================================================
# fs-doctor.sh — target health + snapshot audit + immutability verification
# =============================================================================

CONFIG_FILE="/etc/fsbackup/targets.yml"
BACKUP_SSH_USER="backup"

CLASS=""

NODEEXP_DIR="/var/lib/node_exporter/textfile_collector"
NODEEXP_METRIC="${NODEEXP_DIR}/fsbackup_nodeexp_health.prom"
ORPHAN_METRIC="${NODEEXP_DIR}/fsbackup_orphans.prom"

ORPHAN_LOG="/var/lib/fsbackup/log/fs-orphans.log"

. /etc/fsbackup/fsbackup.conf
PRIMARY_SNAPSHOT_ROOT="${SNAPSHOT_ROOT:-/backup/snapshots}"

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

START_TS=$(date +%s.%N)

for cmd in yq jq ssh; do
  command -v "$cmd" >/dev/null || { echo "$cmd not found"; exit 2; }
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

echo
echo "fsbackup doctor"
echo "  Class:  $CLASS"
echo

printf "%-28s %-6s %s\n" "TARGET" "STAT" "DETAIL"
printf "%-28s %-6s %s\n" "----------------------------" "------" "------------------------------"

# -----------------------------------------------------------------------------
# TARGET HEALTH
# -----------------------------------------------------------------------------
for t in "${TARGETS[@]}"; do
  id="$(jq -r '.id // empty' <<<"$t")"
  host="$(jq -r '.host // empty' <<<"$t")"
  src="$(jq -r '.source // empty' <<<"$t")"

  if [[ -z "$id" || -z "$host" || -z "$src" ]]; then
    printf "%-28s %-6s %s\n" "${id:-<unknown>}" "WARN" "invalid target entry"
    ((WARN++))
    continue
  fi

  if [[ ! -d "${PRIMARY_SNAPSHOT_ROOT}/${CLASS}/${id}" ]]; then
    printf "%-28s %-6s %s\n" "$id" "WARN" "dataset not provisioned (runner will auto-provision)"
    ((WARN++))
    ((MISSING_DATASETS++))
    continue
  fi

  if is_local_host "$host"; then
    if [[ -e "$src" ]]; then
      printf "%-28s %-6s %s\n" "$id" "OK" "local path exists"
      ((PASS++))
    else
      printf "%-28s %-6s %s\n" "$id" "FAIL" "local missing: $src"
      ((FAIL++))
    fi
    continue
  fi

  if ssh "${SSH_OPTS[@]}" "${BACKUP_SSH_USER}@${host}" "test -e '$src'" >/dev/null 2>&1; then
    printf "%-28s %-6s %s\n" "$id" "OK" "ssh+path OK"
    ((PASS++))
  else
    printf "%-28s %-6s %s\n" "$id" "FAIL" "ssh/path failed"
    ((FAIL++))
  fi
done

echo
echo "Doctor summary"
echo "  OK:    $PASS"
echo "  WARN:  $WARN"
echo "  FAIL:  $FAIL"
echo

# -----------------------------------------------------------------------------
# ORPHAN DETECTION
# -----------------------------------------------------------------------------
mkdir -p "$(dirname "$ORPHAN_LOG")"

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
    echo "$(date -Is) class=${class} orphan=${target}" >>"$ORPHAN_LOG"
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

echo "ZFS scrub"
if [[ ! -r "$SCRUB_PROM" ]]; then
  printf "%-28s %-6s %s\n" "-" "WARN" "no scrub result yet (fsbackup-scrub.service has not finished a run)"
else
  NOW_TS="$(date +%s)"
  # one line per pool: <pool> <success> <last_run> <last_success> <problems>
  while read -r pool s_ok s_run s_last s_prob; do
    if [[ "$s_ok" == "0" ]]; then
      printf "%-28s %-6s %s\n" "$pool" "WARN" \
        "last scrub check FAILED on $(date -d "@${s_run}" +%F 2>/dev/null || echo '?') (${s_prob} problem(s)); see journalctl -u fsbackup-scrub"
    elif [[ "$s_last" == "-" ]]; then
      printf "%-28s %-6s %s\n" "$pool" "WARN" "no clean scrub on record"
    else
      age_days=$(( (NOW_TS - ${s_last%.*}) / 86400 ))
      if [[ "$age_days" -gt "$SCRUB_MAX_AGE_DAYS" ]]; then
        printf "%-28s %-6s %s\n" "$pool" "WARN" \
          "last clean scrub ${age_days} days ago (> ${SCRUB_MAX_AGE_DAYS}); check fsbackup-scrub.timer"
      else
        printf "%-28s %-6s %s\n" "$pool" "OK" \
          "last clean scrub $(date -d "@${s_last%.*}" +%F) (${age_days} days ago)"
      fi
    fi
  done < <(awk '
    /^fsbackup_scrub_[a-z_]+\{pool="[^"]*"\} / {
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
fi
echo

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

exit 0


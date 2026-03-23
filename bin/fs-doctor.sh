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


END_TS=$(date +%s.%N)
DURATION=$(awk "BEGIN {print $END_TS - $START_TS}")

tmp="$(mktemp)"
cat >"$tmp" <<EOF
# HELP fsbackup_doctor_duration_seconds Duration of fsbackup doctor run
# TYPE fsbackup_doctor_duration_seconds gauge
fsbackup_doctor_duration_seconds{class="$CLASS"} ${DURATION}
EOF
chgrp nodeexp_txt "$tmp" 2>/dev/null || true
chmod 0644 "$tmp"
mv "$tmp" "${NODEEXP_DIR}/fsbackup_doctor_duration.prom"

exit 0


#!/usr/bin/env bash
set -u
set -o pipefail

# =============================================================================
# fs-doctor.sh — target health + snapshot audit
# =============================================================================

CONFIG_FILE="/etc/fsbackup/targets.yml"
BACKUP_SSH_USER="backup"

CLASS=""
SEED_HOSTKEYS=0

NODEEXP_DIR="/var/lib/node_exporter/textfile_collector"
NODEEXP_METRIC="${NODEEXP_DIR}/fsbackup_nodeexp_health.prom"
ORPHAN_METRIC="${NODEEXP_DIR}/fsbackup_orphans.prom"

ORPHAN_LOG="/var/lib/fsbackup/log/fs-orphans.log"

PRIMARY_SNAPSHOT_ROOT="/backup/snapshots"
MIRROR_SNAPSHOT_ROOT="/backup2/snapshots"

usage() {
  echo "Usage: fs-doctor.sh --class <class> [--seed-hostkeys]"
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --class) CLASS="$2"; shift 2 ;;
    --seed-hostkeys) SEED_HOSTKEYS=1; shift ;;
    *) usage ;;
  esac
done

[[ -n "$CLASS" ]] || usage

for cmd in yq jq ssh rsync ssh-keyscan; do
  command -v "$cmd" >/dev/null || { echo "$cmd not found"; exit 2; }
done

mapfile -t TARGETS < <(
  yq eval -o=json ".${CLASS}[]" "$CONFIG_FILE" | jq -c .
)

is_local_host() {
  local h="$1"
  local short fqdn
  short="$(hostname -s)"
  fqdn="$(hostname -f 2>/dev/null || true)"

  [[ "$h" == "localhost" || "$h" == "$short" || "$h" == "$fqdn" ]] && return 0

  if getent hosts "$h" >/dev/null 2>&1; then
    for ip in $(getent hosts "$h" | awk '{print $1}'); do
      hostname -I | grep -qw "$ip" && return 0
    done
  fi
  return 1
}

SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=5)

TOTAL="${#TARGETS[@]}"
PASS=0
FAIL=0
WARN=0

echo
echo "fsbackup doctor"
echo "  Class:  $CLASS"
echo "  Items:  $TOTAL"
echo

printf "%-28s %-6s %s\n" "TARGET" "STAT" "DETAIL"
printf "%-28s %-6s %s\n" "----------------------------" "------" "------------------------------"

# -----------------------------------------------------------------------------
# TARGET CHECKS
# -----------------------------------------------------------------------------
for t in "${TARGETS[@]}"; do
  id="$(jq -r '.id // empty' <<<"$t")"
  host="$(jq -r '.host // empty' <<<"$t")"
  src="$(jq -r '.source // empty' <<<"$t")"

  # Hard guard against malformed targets
  if [[ -z "$id" || -z "$host" || -z "$src" ]]; then
    printf "%-28s %-6s %s\n" "${id:-<unknown>}" "WARN" "invalid target entry (missing id/host/source)"
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

  if ! ssh "${SSH_OPTS[@]}" "${BACKUP_SSH_USER}@${host}" "test -e '$src'" >/dev/null 2>&1; then
    printf "%-28s %-6s %s\n" "$id" "FAIL" "ssh/path failed"
    ((FAIL++))
    continue
  fi

  printf "%-28s %-6s %s\n" "$id" "OK" "ssh+path OK"
  ((PASS++))
done

echo
echo "Doctor summary"
echo "  OK:    $PASS"
echo "  WARN:  $WARN"
echo "  FAIL:  $FAIL"
echo

# -----------------------------------------------------------------------------
# Node exporter textfile access health
# -----------------------------------------------------------------------------
nodeexp_ok=0
[[ -d "$NODEEXP_DIR" && -w "$NODEEXP_DIR" && -x "$NODEEXP_DIR" ]] && nodeexp_ok=1

tmp="$(mktemp)"
cat >"$tmp" <<EOF
# HELP fsbackup_node_exporter_textfile_access Can fsbackup write node_exporter textfile dir (1=yes,0=no)
# TYPE fsbackup_node_exporter_textfile_access gauge
fsbackup_node_exporter_textfile_access ${nodeexp_ok}
EOF
chgrp nodeexp_txt "$tmp"
chmod 0644 "$tmp"
mv "$tmp" "$NODEEXP_METRIC" 2>/dev/null || rm -f "$tmp"

# -----------------------------------------------------------------------------
# ORPHAN SNAPSHOT DETECTION (primary + mirror + annual)
# -----------------------------------------------------------------------------
mkdir -p "$(dirname "$ORPHAN_LOG")"

mapfile -t VALID_IDS < <(
  yq eval '.. | select(has("id")) | .id' "$CONFIG_FILE" | sort -u
)

declare -A VALID
for id in "${VALID_IDS[@]}"; do VALID["$id"]=1; done

declare -A ORPHANS=( ["primary"]=0 ["mirror"]=0 )

scan_root() {
  local root="$1"
  local label="$2"

  [[ -d "$root" ]] || return 0

  find "$root" -mindepth 3 -maxdepth 4 -type d | while read -r d; do
    target="$(basename "$d")"
    class="$(basename "$(dirname "$d")")"
    tier="$(basename "$(dirname "$(dirname "$d")")")"
    date="$(basename "$(dirname "$(dirname "$(dirname "$d")")")")"

    if [[ -z "${VALID[$target]+x}" ]]; then
      ORPHANS["$label"]=$((ORPHANS["$label"] + 1))
      echo "$(date -Is) root=${label} tier=${tier} date=${date} class=${class} orphan=${target}" >>"$ORPHAN_LOG"
    fi
  done
}

scan_root "$PRIMARY_SNAPSHOT_ROOT" "primary"
scan_root "$MIRROR_SNAPSHOT_ROOT" "mirror"

tmp="$(mktemp)"
cat >"$tmp" <<EOF
# HELP fsbackup_orphan_snapshots_total Number of orphaned snapshots by root
# TYPE fsbackup_orphan_snapshots_total gauge
fsbackup_orphan_snapshots_total{root="primary"} ${ORPHANS[primary]}
fsbackup_orphan_snapshots_total{root="mirror"} ${ORPHANS[mirror]}
EOF
chgrp nodeexp_txt "$tmp"
chmod 0644 "$tmp"
mv "$tmp" "$ORPHAN_METRIC" 2>/dev/null || rm -f "$tmp"

exit 0


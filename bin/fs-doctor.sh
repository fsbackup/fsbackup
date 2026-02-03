#!/usr/bin/env bash
set -u
set -o pipefail

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
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --class) CLASS="$2"; shift 2 ;;
    --seed-hostkeys) SEED_HOSTKEYS=1; shift ;;
    *) usage; exit 2 ;;
  esac
done

[[ -n "$CLASS" ]] || { echo "Missing --class"; exit 2; }

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

echo
echo "fsbackup doctor"
echo "  Class:  $CLASS"
echo "  Items:  $TOTAL"
echo

printf "%-28s %-6s %s\n" "TARGET" "STAT" "DETAIL"
printf "%-28s %-6s %s\n" "----------------------------" "------" "------------------------------"

for t in "${TARGETS[@]}"; do
  id="$(jq -r '.id' <<<"$t")"
  host="$(jq -r '.host' <<<"$t")"
  src="$(jq -r '.source' <<<"$t")"
  rsync_opts="$(jq -r '.rsync_opts // empty' <<<"$t")"

  if is_local_host "$host"; then
    [[ -e "$src" ]] && { printf "%-28s OK     local path exists\n" "$id"; ((PASS++)); } \
                     || { printf "%-28s FAIL   local missing\n" "$id"; ((FAIL++)); }
    continue
  fi

  if ! ssh "${SSH_OPTS[@]}" "${BACKUP_SSH_USER}@${host}" "test -e '$src'" >/dev/null 2>&1; then
    printf "%-28s FAIL   remote missing\n" "$id"
    ((FAIL++))
    continue
  fi

  printf "%-28s OK     ssh+path OK\n" "$id"
  ((PASS++))
done

echo
echo "Doctor summary"
echo "  Total: $TOTAL"
echo "  OK:    $PASS"
echo "  FAIL:  $FAIL"
echo

# -----------------------------------------------------------------------------
# Node exporter health
# -----------------------------------------------------------------------------
nodeexp_ok=0
[[ -d "$NODEEXP_DIR" && -w "$NODEEXP_DIR" ]] && nodeexp_ok=1

tmp="$(mktemp)"
cat >"$tmp" <<EOF
fsbackup_node_exporter_textfile_access ${nodeexp_ok}
EOF
chmod 0644 "$tmp"
chgrp nodeexp_txt "$tmp"
mv "$tmp" "$NODEEXP_METRIC" 2>/dev/null || rm -f "$tmp"

# -----------------------------------------------------------------------------
# Orphan detection (PRIMARY + MIRROR)
# -----------------------------------------------------------------------------
mkdir -p "$(dirname "$ORPHAN_LOG")"

mapfile -t VALID_IDS < <(
  yq eval '.. | select(has("id")) | .id' "$CONFIG_FILE" | sort -u
)

declare -A VALID
for id in "${VALID_IDS[@]}"; do VALID["$id"]=1; done

declare -A ORPHANS
ORPHANS["primary"]=0
ORPHANS["mirror"]=0

scan_root() {
  local root="$1"
  local label="$2"

  [[ -d "$root" ]] || return 0

  find "$root" -mindepth 3 -maxdepth 3 -type d | while read -r d; do
    target="$(basename "$d")"
    class="$(basename "$(dirname "$d")")"
    date="$(basename "$(dirname "$(dirname "$d")")")"

    if [[ -z "${VALID[$target]+x}" ]]; then
      ORPHANS["$label"]=$((ORPHANS["$label"] + 1))
      echo "$(date -Is) root=${label} date=${date} class=${class} orphan=${target}" >>"$ORPHAN_LOG"
    fi
  done
}

scan_root "$PRIMARY_SNAPSHOT_ROOT" "primary"
scan_root "$MIRROR_SNAPSHOT_ROOT" "mirror"

tmp="$(mktemp)"
cat >"$tmp" <<EOF
fsbackup_orphan_snapshots_total{root="primary"} ${ORPHANS[primary]}
fsbackup_orphan_snapshots_total{root="mirror"} ${ORPHANS[mirror]}
EOF
chgrp nodeexp_txt "$tmp"
chmod 0644 "$tmp"
mv "$tmp" "$ORPHAN_METRIC"

exit 0


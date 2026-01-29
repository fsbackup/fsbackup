#!/usr/bin/env bash
set -u

CONFIG_FILE="/etc/fsbackup/targets.yml"
BACKUP_ROOT="/bak/snapshots"
BACKUP_SSH_USER="backup"

LOG_DIR="/var/lib/fsbackup/log"
LOG_FILE="${LOG_DIR}/backup.log"

SNAPSHOT_TYPE=""
CLASS=""
DRY_RUN=0
REPLACE=0

mkdir -p "$LOG_DIR"
touch "$LOG_FILE"
chmod 0640 "$LOG_FILE"

exec > >(tee -a "$LOG_FILE") 2>&1

ts() {
  date +"%Y-%m-%dT%H:%M:%S%z"
}

log() {
  local id="$1"
  shift
  printf "%s [%s] %s\n" "$(ts)" "$id" "$*"
}

usage() {
  echo "Usage: fs-runner.sh <daily|weekly|monthly> --class <class> [--dry-run] [--replace-existing]"
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    daily|weekly|monthly) SNAPSHOT_TYPE="$1"; shift ;;
    --class) CLASS="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --replace-existing) REPLACE=1; shift ;;
    *) usage ;;
  esac
done

[[ -n "$SNAPSHOT_TYPE" && -n "$CLASS" ]] || usage

command -v yq >/dev/null || { echo "yq not found"; exit 2; }
command -v jq >/dev/null || { echo "jq not found"; exit 2; }
command -v rsync >/dev/null || { echo "rsync not found"; exit 2; }

mapfile -t TARGETS < <(
  yq eval -o=json ".${CLASS}[]" "$CONFIG_FILE" | jq -c .
)

DATE="$(date +%F)"
DEST_BASE="${BACKUP_ROOT}/${SNAPSHOT_TYPE}/${DATE}/${CLASS}"

is_local_host() {
  local h="$1"
  local short fqdn
  short="$(hostname -s)"
  fqdn="$(hostname -f 2>/dev/null || true)"

  [[ "$h" == "localhost" ]] && return 0
  [[ "$h" == "$short" ]] && return 0
  [[ -n "$fqdn" && "$h" == "$fqdn" ]] && return 0

  if getent hosts "$h" >/dev/null 2>&1; then
    local tip lip
    for tip in $(getent hosts "$h" | awk '{print $1}'); do
      for lip in $(hostname -I); do
        [[ "$tip" == "$lip" ]] && return 0
      done
    done
  fi

  return 1
}

TOTAL="${#TARGETS[@]}"
OK=0
FAIL=0

echo
echo "fs-runner starting"
echo "  Snapshot type: $SNAPSHOT_TYPE"
echo "  Class:         $CLASS"
echo "  Targets:       $TOTAL"
echo "  Dry-run:       $DRY_RUN"
echo "  Replace:       $REPLACE"
echo

echo "Running preflight checks..."

for t in "${TARGETS[@]}"; do
  id="$(jq -r '.id' <<<"$t")"
  host="$(jq -r '.host' <<<"$t")"
  src="$(jq -r '.source' <<<"$t")"
  rsync_opts="$(jq -r '.rsync_opts // empty' <<<"$t")"

  if is_local_host "$host"; then
    [[ -e "$src" ]] || { echo "→ $id      FAIL"; exit 1; }
  else
    ssh -o BatchMode=yes "${BACKUP_SSH_USER}@${host}" "test -e '$src'" \
      || { echo "→ $id      FAIL"; exit 1; }
  fi
  echo "→ $id      OK"
done

echo
echo "Preflight OK — executing snapshots"
echo

mkdir -p "$DEST_BASE"

for t in "${TARGETS[@]}"; do
  id="$(jq -r '.id' <<<"$t")"
  host="$(jq -r '.host' <<<"$t")"
  src="$(jq -r '.source' <<<"$t")"
  rsync_opts="$(jq -r '.rsync_opts // empty' <<<"$t")"

  dest="${DEST_BASE}/${id}"

  [[ -d "$dest" && "$REPLACE" -eq 1 ]] && rm -rf "$dest"
  mkdir -p "$dest"

  RSYNC_CMD=(rsync -a)
  [[ "$DRY_RUN" -eq 1 ]] && RSYNC_CMD+=(-n)
  [[ -n "$rsync_opts" ]] && RSYNC_CMD+=($rsync_opts)

  if is_local_host "$host"; then
    log "$id" "Starting snapshot (${SNAPSHOT_TYPE}) from ${src}"
    if "${RSYNC_CMD[@]}" "${src%/}/" "$dest/"; then
      log "$id" "Snapshot completed successfully"
      ((OK++))
    else
      rc=$?
      log "$id" "ERROR (${rc}): rsync failed"
      ((FAIL++))
    fi
  else
    log "$id" "Starting snapshot (${SNAPSHOT_TYPE}) from ${host}:${src}"
    if "${RSYNC_CMD[@]}" "${BACKUP_SSH_USER}@${host}:${src%/}/" "$dest/"; then
      log "$id" "Snapshot completed successfully"
      ((OK++))
    else
      rc=$?
      if [[ "$rsync_opts" == *"--ignore-errors"* ]]; then
        log "$id" "WARNING (${rc}): rsync errors ignored"
        ((OK++))
      else
        log "$id" "ERROR (${rc}): rsync failed"
        ((FAIL++))
      fi
    fi
  fi
done

echo
echo "fs-runner summary"
echo "  Total:     $TOTAL"
echo "  Succeeded: $OK"
echo "  Failed:    $FAIL"
echo

exit 0


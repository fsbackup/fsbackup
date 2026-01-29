#!/usr/bin/env bash
set -u

CONFIG_FILE="/etc/fsbackup/targets.yml"
SNAPSHOT_ROOT="/bak/snapshots"
BACKUP_SSH_USER="backup"

LOG_DIR="/var/lib/fsbackup/log"
LOG_FILE="${LOG_DIR}/backup.log"

NODE_EXPORTER_TEXTFILE="/var/lib/node_exporter/textfile_collector"
METRIC_FILE="${NODE_EXPORTER_TEXTFILE}/fsbackup_runner.prom"

LOCK_FILE="/var/lock/fsbackup.lock"

usage() {
  cat <<EOF
Usage:
  fs-runner.sh <daily|weekly|monthly> --class <class> [--dry-run] [--replace-existing]

Examples:
  fs-runner.sh daily --class class2 --dry-run
  fs-runner.sh daily --class class2 --replace-existing
EOF
}

SNAP_TYPE="${1:-}"
shift || true

CLASS=""
DRY_RUN=0
REPLACE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --class) CLASS="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --replace-existing) REPLACE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ "$SNAP_TYPE" == "daily" || "$SNAP_TYPE" == "weekly" || "$SNAP_TYPE" == "monthly" ]] || { usage; exit 2; }
[[ -n "$CLASS" ]] || { echo "Missing --class" >&2; exit 2; }

command -v yq >/dev/null || { echo "yq not found" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq not found" >&2; exit 2; }
command -v rsync >/dev/null || { echo "rsync not found" >&2; exit 2; }
command -v ssh >/dev/null || { echo "ssh not found" >&2; exit 2; }
command -v flock >/dev/null || { echo "flock not found" >&2; exit 2; }

ts() { date +%Y-%m-%dT%H:%M:%S%z; }

log() {
  local msg="$*"
  printf "%s %s\n" "$(ts)" "$msg"
}

# Identify local host robustly
is_local_host() {
  local h="$1"
  local short fqdn
  short="$(hostname -s)"
  fqdn="$(hostname -f 2>/dev/null || true)"

  [[ "$h" == "localhost" ]] && return 0
  [[ "$h" == "$short" ]] && return 0
  [[ -n "$fqdn" && "$h" == "$fqdn" ]] && return 0

  if getent hosts "$h" >/dev/null 2>&1; then
    local target_ips local_ips ip lip
    target_ips="$(getent hosts "$h" | awk '{print $1}')"
    local_ips="$(hostname -I 2>/dev/null || true)"
    for ip in $target_ips; do
      for lip in $local_ips; do
        [[ "$ip" == "$lip" ]] && return 0
      done
    done
  fi

  return 1
}

# Snapshot key by type
snap_key() {
  case "$SNAP_TYPE" in
    daily) date +%F ;;
    weekly) date +%G-W%V ;;
    monthly) date +%Y-%m ;;
  esac
}

SNAP_KEY="$(snap_key)"
DEST_BASE="${SNAPSHOT_ROOT}/${SNAP_TYPE}/${SNAP_KEY}/${CLASS}"

# Load targets as compact JSON, one per line
mapfile -t TARGETS < <(yq eval -o=json ".${CLASS}[]" "$CONFIG_FILE" | jq -c .)
TOTAL="${#TARGETS[@]}"

mkdir -p "$LOG_DIR" || true

# Single-run lock + tee logging
exec > >(tee -a "$LOG_FILE") 2>&1

log "fs-runner starting"
log "  Snapshot type: $SNAP_TYPE"
log "  Class:         $CLASS"
log "  Targets:       $TOTAL"
log "  Dry-run:       $DRY_RUN"
log "  Replace:       $REPLACE"
log ""

# Lock whole run to prevent overlap (runner/promote/retention can share same lock)
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log "[fs-runner] Another fsbackup job is running (lock held): $LOCK_FILE"
  exit 75
fi

# --- Preflight: run doctor and require PASS ---
log "Running preflight checks..."
if ! sudo -u fsbackup /usr/local/sbin/fs-doctor.sh --class "$CLASS" >/dev/null; then
  log "Preflight failed — aborting snapshot run."
  exit 10
fi

# Print preflight summary lines (doctor output is already in log file; show concise OK)
for t in "${TARGETS[@]}"; do
  id="$(jq -r '.id // empty' <<<"$t")"
  [[ -z "$id" ]] && continue
  printf "→ %-24s %s\n" "$id" "OK"
done

log ""
log "Preflight OK — executing snapshots"
log ""

mkdir -p "$DEST_BASE"

OK=0
FAIL=0

run_one() {
  local id host src rsync_opts type dest src_desc
  id="$(jq -r '.id // empty' <<<"$1")"
  host="$(jq -r '.host // empty' <<<"$1")"
  src="$(jq -r '.source // empty' <<<"$1")"
  type="$(jq -r '.type // "dir"' <<<"$1")"
  rsync_opts="$(jq -r '.rsync_opts // empty' <<<"$1")"

  [[ -z "$id" || -z "$host" || -z "$src" ]] && return 11

  dest="${DEST_BASE}/${id}"
  src_desc="${src}"

  # Ensure per-target dest exists, and optionally replace
  if [[ "$REPLACE" -eq 1 && -d "$dest" ]]; then
    rm -rf --one-file-system "$dest"
  fi
  mkdir -p "$dest"

  # Base rsync options
  local -a RSYNC_CMD
  RSYNC_CMD=(rsync -a --delete --numeric-ids)
  [[ "$DRY_RUN" -eq 1 ]] && RSYNC_CMD+=(-n -v)

  # Optional per-target rsync opts from targets.yml
  if [[ -n "$rsync_opts" ]]; then
    # word-split intended
    RSYNC_CMD+=($rsync_opts)
  fi

  log "[$id] Starting snapshot ($SNAP_TYPE) from ${src_desc}${host:+ (host=$host)}"

  if is_local_host "$host"; then
    # local path
    if [[ ! -e "$src" ]]; then
      log "[$id] ERROR (10): Source path missing: $src"
      return 10
    fi
    # normalize: if dir, sync contents; if file, sync file into dest
    if [[ "$type" == "file" ]]; then
      "${RSYNC_CMD[@]}" "$src" "$dest/" || return 20
    else
      "${RSYNC_CMD[@]}" "${src%/}/" "$dest/" || return 20
    fi
  else
    # remote path
    if [[ "$type" == "file" ]]; then
      "${RSYNC_CMD[@]}" "${BACKUP_SSH_USER}@${host}:$src" "$dest/" || return 20
    else
      "${RSYNC_CMD[@]}" "${BACKUP_SSH_USER}@${host}:${src%/}/" "$dest/" || return 20
    fi
  fi

  log "[$id] Snapshot completed successfully"
  return 0
}

for t in "${TARGETS[@]}"; do
  id="$(jq -r '.id // empty' <<<"$t")"
  if run_one "$t"; then
    ((OK++))
  else
    rc=$?
    log "[$id] ERROR ($rc): snapshot failed"
    ((FAIL++))
  fi
done

log ""
log "fs-runner summary"
log "  Total:     $TOTAL"
log "  Succeeded: $OK"
log "  Failed:    $FAIL"
log ""

# Metrics
now="$(date +%s)"
cat >"$METRIC_FILE" <<EOF
# HELP fsbackup_runner_last_run_seconds Unix timestamp of last runner completion
# TYPE fsbackup_runner_last_run_seconds gauge
fsbackup_runner_last_run_seconds $now
# HELP fsbackup_runner_targets_total Number of targets attempted
# TYPE fsbackup_runner_targets_total gauge
fsbackup_runner_targets_total $TOTAL
# HELP fsbackup_runner_targets_ok Number of targets succeeded
# TYPE fsbackup_runner_targets_ok gauge
fsbackup_runner_targets_ok $OK
# HELP fsbackup_runner_targets_fail Number of targets failed
# TYPE fsbackup_runner_targets_fail gauge
fsbackup_runner_targets_fail $FAIL
# HELP fsbackup_runner_status Overall status (0=ok,1=fail)
# TYPE fsbackup_runner_status gauge
fsbackup_runner_status $([[ "$FAIL" -gt 0 ]] && echo 1 || echo 0)
EOF
chmod 0644 "$METRIC_FILE" 2>/dev/null || true

[[ "$FAIL" -eq 0 ]]


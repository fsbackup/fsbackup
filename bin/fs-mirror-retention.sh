#!/bin/bash
set -u
set -o pipefail

# =============================================================================
# fs-mirror-retention.sh — retention for SNAPSHOT_MIRROR_ROOT only
#
# Layout assumed under SNAPSHOT_MIRROR_ROOT:
#   daily/YYYY-MM-DD/classN/<target-id>/
#   weekly/YYYY-Www/classN/<target-id>/
#   monthly/YYYY-MM/classN/<target-id>/
#
# Policy:
#   Keep newest N folders per tier (N configurable via fsbackup.conf)
#   Delete older folders *as whole units* (never partial classes/targets)
#
# Safety:
#   - If SNAPSHOT_MIRROR_ROOT unset: exit 0 (no-op)
#   - If mirror root not writable: fail
#   - Uses flock to avoid concurrent runs
#   - Supports --dry-run
# =============================================================================

. /etc/fsbackup/fsbackup.conf

DRY_RUN=0
usage() {
  echo "Usage: fs-mirror-retention.sh [--dry-run]"
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    *) usage ;;
  esac
done

# Backward-compatible no-op
if [[ -z "${SNAPSHOT_MIRROR_ROOT:-}" ]]; then
  echo "$(date +%Y-%m-%dT%H:%M:%S%z) fs-mirror-retention: SNAPSHOT_MIRROR_ROOT not set; skipping"
  exit 0
fi

ROOT="${SNAPSHOT_MIRROR_ROOT}"

# Defaults if not configured
KEEP_DAILY="${MIRROR_RETENTION_DAILY:-14}"
KEEP_WEEKLY="${MIRROR_RETENTION_WEEKLY:-12}"
KEEP_MONTHLY="${MIRROR_RETENTION_MONTHLY:-24}"

LOG_DIR="/var/lib/fsbackup/log"
LOG_FILE="${LOG_DIR}/mirror-retention.log"
mkdir -p "$LOG_DIR"

NODEEXP_DIR="/var/lib/node_exporter/textfile_collector"
PROM_TMP="$(mktemp)"
PROM_OUT="${NODEEXP_DIR}/fsbackup_mirror_retention.prom"

log() {
  echo "$(date +%Y-%m-%dT%H:%M:%S%z) [mirror-retention] $*" | tee -a "$LOG_FILE"
}

# Lock to avoid overlap
exec 9>/run/lock/fsbackup-mirror-retention.lock
flock -n 9 || { log "WARN another mirror-retention instance is running; exiting"; exit 0; }

# Validate destination root
if [[ ! -d "$ROOT" ]]; then
  log "ERROR mirror root does not exist: $ROOT"
  exit 1
fi
if [[ ! -w "$ROOT" ]]; then
  log "ERROR mirror root not writable: $ROOT"
  exit 1
fi

# Helper: list immediate child directories sorted (lexicographic = chronological for these names)
list_dirs_sorted() {
  local base="$1"
  [[ -d "$base" ]] || return 0
  find "$base" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort
}

# Helper: delete a folder safely (whole tier key folder)
delete_dir() {
  local path="$1"
  local tier="$2"

  local bytes=0
  bytes="$(du -sb "$path" 2>/dev/null | awk '{print $1}' || echo 0)"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN delete tier=${tier} path=${path} bytes=${bytes}"
    return 0
  fi

  rm -rf --one-file-system "$path"
}

START_TS="$(date +%s)"
NOW_EPOCH="$(date +%s)"

# Metrics counters
rc=0

deleted_daily=0
deleted_weekly=0
deleted_monthly=0

deleted_bytes_daily=0
deleted_bytes_weekly=0
deleted_bytes_monthly=0

candidates_daily=0
candidates_weekly=0
candidates_monthly=0

log "Beginning mirror retention"
log "  ROOT:         $ROOT"
log "  Keep daily:   $KEEP_DAILY"
log "  Keep weekly:  $KEEP_WEEKLY"
log "  Keep monthly: $KEEP_MONTHLY"
log "  Dry-run:      $DRY_RUN"

# -----------------------------------------------------------------------------
# DAILY retention: delete old YYYY-MM-DD folders
# -----------------------------------------------------------------------------
daily_base="${ROOT}/daily"
mapfile -t daily_keys < <(list_dirs_sorted "$daily_base" || true)
candidates_daily="${#daily_keys[@]}"

if (( candidates_daily > KEEP_DAILY )); then
  del_count=$((candidates_daily - KEEP_DAILY))
  for ((i=0; i<del_count; i++)); do
    key="${daily_keys[$i]}"
    path="${daily_base}/${key}"
    bytes="$(du -sb "$path" 2>/dev/null | awk '{print $1}' || echo 0)"
    if delete_dir "$path" "daily"; then
      ((deleted_daily++))
      deleted_bytes_daily=$((deleted_bytes_daily + bytes))
      log "Deleted daily: ${path}"
    else
      log "ERROR failed delete daily: ${path}"
      rc=1
    fi
  done
else
  log "Daily: nothing to delete (${candidates_daily} <= ${KEEP_DAILY})"
fi

# -----------------------------------------------------------------------------
# WEEKLY retention: delete old YYYY-Www folders
# -----------------------------------------------------------------------------
weekly_base="${ROOT}/weekly"
mapfile -t weekly_keys < <(list_dirs_sorted "$weekly_base" || true)
candidates_weekly="${#weekly_keys[@]}"

if (( candidates_weekly > KEEP_WEEKLY )); then
  del_count=$((candidates_weekly - KEEP_WEEKLY))
  for ((i=0; i<del_count; i++)); do
    key="${weekly_keys[$i]}"
    path="${weekly_base}/${key}"
    bytes="$(du -sb "$path" 2>/dev/null | awk '{print $1}' || echo 0)"
    if delete_dir "$path" "weekly"; then
      ((deleted_weekly++))
      deleted_bytes_weekly=$((deleted_bytes_weekly + bytes))
      log "Deleted weekly: ${path}"
    else
      log "ERROR failed delete weekly: ${path}"
      rc=1
    fi
  done
else
  log "Weekly: nothing to delete (${candidates_weekly} <= ${KEEP_WEEKLY})"
fi

# -----------------------------------------------------------------------------
# MONTHLY retention: delete old YYYY-MM folders
# -----------------------------------------------------------------------------
monthly_base="${ROOT}/monthly"
mapfile -t monthly_keys < <(list_dirs_sorted "$monthly_base" || true)
candidates_monthly="${#monthly_keys[@]}"

if (( candidates_monthly > KEEP_MONTHLY )); then
  del_count=$((candidates_monthly - KEEP_MONTHLY))
  for ((i=0; i<del_count; i++)); do
    key="${monthly_keys[$i]}"
    path="${monthly_base}/${key}"
    bytes="$(du -sb "$path" 2>/dev/null | awk '{print $1}' || echo 0)"
    if delete_dir "$path" "monthly"; then
      ((deleted_monthly++))
      deleted_bytes_monthly=$((deleted_bytes_monthly + bytes))
      log "Deleted monthly: ${path}"
    else
      log "ERROR failed delete monthly: ${path}"
      rc=1
    fi
  done
else
  log "Monthly: nothing to delete (${candidates_monthly} <= ${KEEP_MONTHLY})"
fi

END_TS="$(date +%s)"
DURATION=$((END_TS - START_TS))

# -----------------------------------------------------------------------------
# Prometheus metrics
# -----------------------------------------------------------------------------
cat >"$PROM_TMP" <<EOF
# HELP fsbackup_mirror_retention_last_success Unix timestamp of last mirror retention run
# TYPE fsbackup_mirror_retention_last_success gauge
fsbackup_mirror_retention_last_success ${NOW_EPOCH}

# HELP fsbackup_mirror_retention_last_exit_code Exit code of mirror retention (0=success)
# TYPE fsbackup_mirror_retention_last_exit_code gauge
fsbackup_mirror_retention_last_exit_code ${rc}

# HELP fsbackup_mirror_retention_duration_seconds Duration of mirror retention run
# TYPE fsbackup_mirror_retention_duration_seconds gauge
fsbackup_mirror_retention_duration_seconds ${DURATION}

# HELP fsbackup_mirror_retention_candidates_total Snapshot key folders seen per tier
# TYPE fsbackup_mirror_retention_candidates_total gauge
fsbackup_mirror_retention_candidates_total{tier="daily"} ${candidates_daily}
fsbackup_mirror_retention_candidates_total{tier="weekly"} ${candidates_weekly}
fsbackup_mirror_retention_candidates_total{tier="monthly"} ${candidates_monthly}

# HELP fsbackup_mirror_retention_deleted_total Snapshot key folders deleted per tier
# TYPE fsbackup_mirror_retention_deleted_total counter
fsbackup_mirror_retention_deleted_total{tier="daily"} ${deleted_daily}
fsbackup_mirror_retention_deleted_total{tier="weekly"} ${deleted_weekly}
fsbackup_mirror_retention_deleted_total{tier="monthly"} ${deleted_monthly}

# HELP fsbackup_mirror_retention_deleted_bytes_total Bytes deleted per tier
# TYPE fsbackup_mirror_retention_deleted_bytes_total counter
fsbackup_mirror_retention_deleted_bytes_total{tier="daily"} ${deleted_bytes_daily}
fsbackup_mirror_retention_deleted_bytes_total{tier="weekly"} ${deleted_bytes_weekly}
fsbackup_mirror_retention_deleted_bytes_total{tier="monthly"} ${deleted_bytes_monthly}
EOF

chgrp nodeexp_txt "$PROM_TMP" 2>/dev/null || true
chmod 0640 "$PROM_TMP" 2>/dev/null || true
mv "$PROM_TMP" "$PROM_OUT" 2>/dev/null || rm -f "$PROM_TMP"

log "Mirror retention completed (rc=${rc}, duration=${DURATION}s)"
exit "$rc"


#!/usr/bin/env bash
set -u
set -o pipefail

# =============================================================================
# fs-export-s3.sh — upload ZFS snapshots to S3 (v2.0)
#
# Enumerates ZFS snapshots via `zfs list -t snapshot`, uploads weekly,
# monthly, and annual tiers for all classes not in S3_SKIP_CLASSES.
# Idempotent: checks S3 before uploading and skips objects already present.
#
# S3 key structure:  <tier>/<class>/<target>/<target>--<date>.tar.zst.age
# Snapshot data:     <SNAPSHOT_ROOT>/<class>/<target>/.zfs/snapshot/<name>/
#
# Required in /etc/fsbackup/fsbackup.conf:
#   S3_BUCKET="fsbackup-snapshots-XXXXXX"
#
# Optional in /etc/fsbackup/fsbackup.conf:
#   S3_SKIP_CLASSES="class3"    (space-separated, defaults to class3)
#   S3_AWS_PROFILE="fsbackup"   (defaults to fsbackup)
#
# Logging (lib/log.sh): $LOG_DIR/s3-export.log gets every object decision
# (SKIP/EXISTS/UPLOAD/OK); journald gets the run start, the summary and errors.
# =============================================================================

. /etc/fsbackup/fsbackup.conf
LOG_DIR="${LOG_DIR:-/var/log/fsbackup}"
. "$(dirname "$(readlink -f "$0")")/../lib/log.sh" || { echo "fs-export-s3: cannot load lib/log.sh" >&2; exit 2; }

S3_BUCKET="${S3_BUCKET:-}"
S3_SKIP_CLASSES="${S3_SKIP_CLASSES:-class3}"
AWS_PROFILE="${S3_AWS_PROFILE:-fsbackup}"
AGE_PUBKEY_FILE="/etc/fsbackup/age.pub"

PRIMARY_SNAPSHOT_ROOT="${SNAPSHOT_ROOT:-/backup/snapshots}"
ZFS_BASE="${PRIMARY_SNAPSHOT_ROOT#/}"   # e.g. backup/snapshots

log_init s3-export
NODEEXP_DIR="/var/lib/node_exporter/textfile_collector"
PROM_OUT="${NODEEXP_DIR}/fsbackup_s3.prom"
PROM_TMP="$(mktemp)"
ZFS_ERR_TMP="$(mktemp)"
trap 'rm -f "$PROM_TMP" "$ZFS_ERR_TMP"' EXIT

# -----------------------------------------------------------------------------
# Preflight checks
# -----------------------------------------------------------------------------

[[ -n "$S3_BUCKET" ]] || { error "s3-export" "S3_BUCKET not set in fsbackup.conf"; exit 2; }
[[ -f "$AGE_PUBKEY_FILE" ]] || { error "s3-export" "age public key not found: $AGE_PUBKEY_FILE"; exit 2; }

for cmd in zfs age aws; do
  command -v "$cmd" >/dev/null || { error "s3-export" "$cmd not found"; exit 2; }
done

# Lock to prevent overlapping runs
exec 9>/run/lock/fsbackup-s3-export.lock
flock -n 9 || { event "s3-export" "already running, exiting"; exit 0; }

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

START_TS="$(date +%s)"
UPLOADED=0
SKIPPED=0
FAILED=0
BYTES_TOTAL=0

event "s3-export" "Starting S3 export to s3://${S3_BUCKET}"
log "s3-export" "  ZFS base:     ${ZFS_BASE}"
log "s3-export" "  Skip classes: ${S3_SKIP_CLASSES:-<none>}"

while IFS= read -r snapfull; do
  # snapfull = backup/snapshots/class1/technicom.files@weekly-2026-W12
  dataset="${snapfull%%@*}"    # backup/snapshots/class1/technicom.files
  snapname="${snapfull##*@}"   # weekly-2026-W12

  # Determine tier and date key from snapshot name
  case "$snapname" in
    weekly-*)  tier="weekly";  date_key="${snapname#weekly-}" ;;
    monthly-*) tier="monthly"; date_key="${snapname#monthly-}" ;;
    annual-*)  tier="annual";  date_key="${snapname#annual-}" ;;
    *)         continue ;;  # daily snapshots not exported to S3
  esac

  # Extract class/target from dataset path relative to ZFS_BASE
  rel="${dataset#${ZFS_BASE}/}"

  # Must be exactly class/target (two components)
  cls="${rel%%/*}"
  target="${rel#*/}"
  if [[ "$cls" == "$target" || "$target" == */* ]]; then
    error "s3-export" "unexpected dataset depth, skipping: $dataset"
    continue
  fi

  # Skip excluded classes
  if [[ -n "$S3_SKIP_CLASSES" && " $S3_SKIP_CLASSES " == *" $cls "* ]]; then
    log "s3-export" "SKIP class=${cls} tier=${tier} date=${date_key} target=${target} (S3_SKIP_CLASSES)"
    continue
  fi

  # Snapshot data is available via the ZFS .zfs hidden directory
  snap_data="${PRIMARY_SNAPSHOT_ROOT}/${cls}/${target}/.zfs/snapshot/${snapname}"
  if [[ ! -d "$snap_data" ]]; then
    error "s3-export" "snapshot data dir not found: $snap_data"
    continue
  fi

  archive="${target}--${date_key}.tar.zst.age"
  s3_key="${tier}/${cls}/${target}/${archive}"
  s3_uri="s3://${S3_BUCKET}/${s3_key}"

  # Skip if already uploaded
  if aws s3api head-object \
      --bucket "$S3_BUCKET" \
      --key "$s3_key" \
      --profile "$AWS_PROFILE" \
      &>/dev/null; then
    log "s3-export" "EXISTS ${s3_uri}"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  log "s3-export" "UPLOAD ${s3_uri}"

  if tar -C "$snap_data" -cf - . \
      | zstd -6 -T0 \
      | age -e -R "$AGE_PUBKEY_FILE" \
      | aws s3 cp - "$s3_uri" \
          --no-progress \
          --profile "$AWS_PROFILE"; then

    UPLOADED=$((UPLOADED + 1))

    BYTES=$(aws s3api head-object \
      --bucket "$S3_BUCKET" \
      --key "$s3_key" \
      --profile "$AWS_PROFILE" \
      --query 'ContentLength' \
      --output text 2>/dev/null || echo 0)
    BYTES_TOTAL=$((BYTES_TOTAL + BYTES))

    log "s3-export" "OK ${s3_uri} (${BYTES} bytes)"

    echo "fsbackup_s3_target_last_upload{tier=\"${tier}\",class=\"${cls}\",target=\"${target}\"} $(date +%s)" \
      >>"$PROM_TMP"

  else
    FAILED=$((FAILED + 1))
    error "s3-export" "upload failed: ${s3_uri}"

    echo "fsbackup_s3_target_last_failure{tier=\"${tier}\",class=\"${cls}\",target=\"${target}\"} $(date +%s)" \
      >>"$PROM_TMP"
  fi

done < <(zfs list -t snapshot -r -H -o name "$ZFS_BASE" 2>"$ZFS_ERR_TMP" | sort)

while IFS= read -r errline; do
  error "s3-export" "zfs list: $errline"
done <"$ZFS_ERR_TMP"

END_TS="$(date +%s)"
DURATION=$((END_TS - START_TS))
EXIT_CODE=$([[ "$FAILED" -gt 0 ]] && echo 1 || echo 0)

cat >>"$PROM_TMP" <<EOF
# HELP fsbackup_s3_last_success Unix timestamp of last S3 export run completion
# TYPE fsbackup_s3_last_success gauge
fsbackup_s3_last_success $(date +%s)

# HELP fsbackup_s3_last_exit_code Exit code of last S3 export run (0=success)
# TYPE fsbackup_s3_last_exit_code gauge
fsbackup_s3_last_exit_code ${EXIT_CODE}

# HELP fsbackup_s3_uploaded_total Objects uploaded in this run
# TYPE fsbackup_s3_uploaded_total gauge
fsbackup_s3_uploaded_total ${UPLOADED}

# HELP fsbackup_s3_skipped_total Objects skipped (already present in S3) in this run
# TYPE fsbackup_s3_skipped_total gauge
fsbackup_s3_skipped_total ${SKIPPED}

# HELP fsbackup_s3_failed_total Objects that failed to upload in this run
# TYPE fsbackup_s3_failed_total gauge
fsbackup_s3_failed_total ${FAILED}

# HELP fsbackup_s3_bytes_total Bytes uploaded in this run
# TYPE fsbackup_s3_bytes_total gauge
fsbackup_s3_bytes_total ${BYTES_TOTAL}

# HELP fsbackup_s3_duration_seconds Duration of S3 export run in seconds
# TYPE fsbackup_s3_duration_seconds gauge
fsbackup_s3_duration_seconds ${DURATION}
EOF

chgrp nodeexp_txt "$PROM_TMP" 2>/dev/null || true
chmod 0644 "$PROM_TMP"
mv "$PROM_TMP" "$PROM_OUT"

event "s3-export" "S3 export complete: uploaded=${UPLOADED} skipped=${SKIPPED} failed=${FAILED} bytes=${BYTES_TOTAL} duration=${DURATION}s"
exit "$EXIT_CODE"

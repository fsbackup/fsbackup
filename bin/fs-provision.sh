#!/usr/bin/env bash
set -u
set -o pipefail

# =============================================================================
# fs-provision.sh — create ZFS datasets for all targets in targets.yml
#
# Reads targets.yml and creates a ZFS dataset for each target that doesn't
# already exist. Safe to re-run — existing datasets are left untouched.
# Must run as root (or as the fsbackup user if zfs allow is already set).
#
# Usage:
#   sudo fs-provision.sh [--dry-run] [--targets-file /path/to/targets.yml]
# =============================================================================

CONFIG_FILE="/etc/fsbackup/fsbackup.conf"
TARGETS_FILE="/etc/fsbackup/targets.yml"
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)       DRY_RUN=1; shift ;;
    --targets-file)  TARGETS_FILE="$2"; shift 2 ;;
    *) echo "Usage: $0 [--dry-run] [--targets-file /path/to/targets.yml]"; exit 2 ;;
  esac
done

[[ -f "$CONFIG_FILE" ]] || { echo "fsbackup.conf not found: $CONFIG_FILE"; exit 2; }
[[ -f "$TARGETS_FILE" ]] || { echo "targets.yml not found: $TARGETS_FILE"; exit 2; }

. "$CONFIG_FILE"
PRIMARY_SNAPSHOT_ROOT="${SNAPSHOT_ROOT:-/backup/snapshots}"
ZFS_BASE="${PRIMARY_SNAPSHOT_ROOT#/}"   # e.g. backup/snapshots

for cmd in yq jq zfs; do
  command -v "$cmd" >/dev/null || { echo "$cmd not found"; exit 2; }
done

# Verify the parent ZFS dataset exists
if ! zfs list "$ZFS_BASE" &>/dev/null; then
  echo "ERROR: ZFS dataset '${ZFS_BASE}' does not exist."
  echo "       Create the pool and dataset first:"
  echo "         zpool create -o ashift=12 backup mirror /dev/sdX /dev/sdY"
  echo "         zfs create backup/snapshots"
  exit 2
fi

echo
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "fs-provision.sh — DRY RUN (no datasets will be created)"
else
  echo "fs-provision.sh — provisioning ZFS datasets"
fi
echo "  ZFS base:    ${ZFS_BASE}"
echo "  Targets:     ${TARGETS_FILE}"
echo

CREATED=0
EXISTING=0
FAILED=0

# Iterate all target entries across all classes
while IFS= read -r entry; do
  id="$(jq -r '.id // empty' <<<"$entry")"
  [[ -n "$id" ]] || continue

  # Determine which class this target belongs to by extracting from yq output
  # yq emits a comment-like marker — we use a second pass keyed on id
  cls="$(yq eval 'to_entries | .[] | .key as $cls | .value[] | select(.id == "'"$id"'") | $cls' "$TARGETS_FILE" 2>/dev/null | head -1)"

  if [[ -z "$cls" ]]; then
    echo "  WARN  could not determine class for target: $id"
    continue
  fi

  dataset="${ZFS_BASE}/${cls}/${id}"

  if zfs list "$dataset" &>/dev/null; then
    printf "  %-8s %-12s %s\n" "EXISTS" "[$cls]" "$dataset"
    EXISTING=$((EXISTING + 1))
  else
    if [[ "$DRY_RUN" -eq 1 ]]; then
      printf "  %-8s %-12s %s\n" "CREATE" "[$cls]" "$dataset"
      CREATED=$((CREATED + 1))
    else
      if zfs create -p "$dataset"; then
        printf "  %-8s %-12s %s\n" "CREATED" "[$cls]" "$dataset"
        CREATED=$((CREATED + 1))
      else
        printf "  %-8s %-12s %s\n" "FAILED" "[$cls]" "$dataset"
        FAILED=$((FAILED + 1))
      fi
    fi
  fi

done < <(yq eval -o=json '.. | select(has("id"))' "$TARGETS_FILE" | jq -c .)

echo
echo "Summary"
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "  Would create: $CREATED"
else
  echo "  Created:  $CREATED"
  echo "  Failed:   $FAILED"
fi
echo "  Existing: $EXISTING"
echo

if [[ "$FAILED" -gt 0 ]]; then
  echo "Some datasets failed to create. Check ZFS permissions:"
  echo "  sudo zfs allow fsbackup create,snapshot,mount,destroy ${ZFS_BASE}"
  exit 1
fi

exit 0

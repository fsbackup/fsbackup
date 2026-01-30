#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# fs-target-rename.sh
#
# Rename or delete snapshots for a target ID across all tiers.
#
# Usage:
#   fs-target-rename.sh \
#     --class class2 \
#     --from old.target.id \
#     --to new.target.id \
#     --move | --delete \
#     [--dry-run]
# =============================================================================

SNAPSHOT_ROOT="/backup/snapshots"

CLASS=""
FROM_ID=""
TO_ID=""
MODE=""
DRY_RUN=0

usage() {
  echo "Usage:"
  echo "  fs-target-rename.sh --class <class> --from <old-id> --to <new-id> (--move | --delete) [--dry-run]"
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --class) CLASS="$2"; shift 2 ;;
    --from) FROM_ID="$2"; shift 2 ;;
    --to) TO_ID="$2"; shift 2 ;;
    --move) MODE="move"; shift ;;
    --delete) MODE="delete"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) usage ;;
  esac
done

[[ -n "$CLASS" && -n "$FROM_ID" && -n "$MODE" ]] || usage
[[ "$MODE" == "move" || "$MODE" == "delete" ]] || usage

if [[ "$MODE" == "move" && -z "$TO_ID" ]]; then
  echo "ERROR: --to is required with --move"
  exit 2
fi

log() {
  echo "$(date +%Y-%m-%dT%H:%M:%S%z) [fs-target-rename] $*"
}

tiers=(daily weekly monthly)

FOUND=0

for tier in "${tiers[@]}"; do
  tier_dir="${SNAPSHOT_ROOT}/${tier}"

  [[ -d "$tier_dir" ]] || continue

  while IFS= read -r -d '' path; do
    FOUND=1
    parent="$(dirname "$path")"

    case "$MODE" in
      move)
        dest="${parent}/${TO_ID}"
        log "MOVE ${path} → ${dest}"
        if [[ "$DRY_RUN" -eq 0 ]]; then
          mkdir -p "$parent"
          mv "$path" "$dest"
        fi
        ;;
      delete)
        log "DELETE ${path}"
        if [[ "$DRY_RUN" -eq 0 ]]; then
          rm -rf "$path"
        fi
        ;;
    esac
  done < <(
    find "$tier_dir" -mindepth 3 -maxdepth 3 \
      -type d \
      -path "*/${CLASS}/${FROM_ID}" \
      -print0
  )
done

if [[ "$FOUND" -eq 0 ]]; then
  log "No snapshots found for target '${FROM_ID}' (class=${CLASS})"
else
  log "Completed (${MODE}) operation for target '${FROM_ID}'"
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "DRY-RUN: no changes made"
fi


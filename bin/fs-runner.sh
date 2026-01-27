#!/usr/bin/env bash
set -u
# IMPORTANT: no `set -e` — runner must survive failures

# =============================================================================
# fs-runner.sh
#
# Orchestrates snapshot runs for a given snapshot type + class.
# Executes all targets even if some fail.
#
# Exit codes:
#   0 = all targets succeeded
#   1 = one or more targets failed
#   2 = preflight or usage error
#
# =============================================================================

CONFIG_FILE="/etc/fsbackup/targets.yml"
SNAPSHOT_SCRIPT="/usr/local/sbin/fs-snapshot.sh"
METRICS_DIR="/var/lib/node_exporter/textfile_collector"

# -----------------------------
# Arguments
# -----------------------------
SNAPSHOT_TYPE="${1:-}"
shift || true

CLASS=""
DRY_RUN=0
REPLACE_EXISTING=0

# -----------------------------
# Parse flags
# -----------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --class)
      CLASS="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --replace-existing)
      REPLACE_EXISTING=1
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

# -----------------------------
# Validation
# -----------------------------
[[ -n "$SNAPSHOT_TYPE" ]] || { echo "Missing snapshot type"; exit 2; }
[[ -n "$CLASS" ]] || { echo "Missing --class"; exit 2; }

command -v yq >/dev/null || { echo "ERROR: yq not found"; exit 2; }
command -v jq >/dev/null || { echo "ERROR: jq not found"; exit 2; }

if ! yq eval ".${CLASS}" "$CONFIG_FILE" >/dev/null 2>&1; then
  echo "Class not found in targets.yml: $CLASS" >&2
  exit 2
fi

START_TS="$(date +%s)"
RUNNER_METRICS="${METRICS_DIR}/fs_runner__${SNAPSHOT_TYPE}_${CLASS}.prom"

# -----------------------------
# Header
# -----------------------------
TARGET_COUNT="$(yq eval ".${CLASS} | length" "$CONFIG_FILE")"

echo
echo "fs-runner starting"
echo "  Snapshot type: $SNAPSHOT_TYPE"
echo "  Class:         $CLASS"
echo "  Targets:       $TARGET_COUNT"
echo "  Dry-run:       $DRY_RUN"
echo "  Replace:       $REPLACE_EXISTING"
echo

# =============================================================================
# PREFLIGHT
# =============================================================================
echo "Running preflight checks..."
echo

mapfile -t PREFLIGHT_TARGETS < <(
  yq eval -o=json ".${CLASS}" "$CONFIG_FILE" | jq -c '.[]'
)



PREFLIGHT_FAILED=0

for target in "${PREFLIGHT_TARGETS[@]}"; do
  TARGET_ID="$(jq -r '.id' <<<"$target")"
  HOST="$(jq -r '.host' <<<"$target")"
  SOURCE="$(jq -r '.source' <<<"$target")"

  printf "→ %-25s " "$TARGET_ID"

  if [[ "$HOST" == "fs" || "$HOST" == "local" ]]; then
    if [[ ! -e "$SOURCE" ]]; then
      echo "FAIL (missing local path)"
      PREFLIGHT_FAILED=1
      continue
    fi
  else
    if ! sudo -u fsbackup ssh -o BatchMode=yes -o ConnectTimeout=5 "$HOST" \
         "test -e '$SOURCE'" >/dev/null 2>&1; then
      echo "FAIL (ssh or path)"
      PREFLIGHT_FAILED=1
      continue
    fi
  fi

  echo "OK"
done

if [[ "$PREFLIGHT_FAILED" -eq 1 ]]; then
  echo
  echo "Preflight failed — aborting snapshot run."
  exit 2
fi

echo
echo "Preflight passed."
echo

# =============================================================================
# RUNNER
# =============================================================================
mapfile -t TARGETS < <(
  yq eval -o=json ".${CLASS}" "$CONFIG_FILE" | jq -c '.[]'
)

TOTAL="${#TARGETS[@]}"
SUCCEEDED=0
FAILED=0
FAILED_TARGETS=()

for target in "${TARGETS[@]}"; do
  TARGET_ID="$(jq -r '.id' <<<"$target")"
  HOST="$(jq -r '.host' <<<"$target")"
  SOURCE="$(jq -r '.source' <<<"$target")"

  echo "→ Target: $TARGET_ID"
  echo "  Host:   $HOST"
  echo "  Source: $SOURCE"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "  DRY-RUN: would invoke snapshot"
    echo
    continue
  fi

  CMD=(
    "$SNAPSHOT_SCRIPT"
    --target-id "$TARGET_ID"
    --class "$CLASS"
    --host "$HOST"
    --source "$SOURCE"
    --snapshot-type "$SNAPSHOT_TYPE"
  )

  if [[ "$REPLACE_EXISTING" -eq 1 ]]; then
    CMD+=(--replace-existing)
  fi

  "${CMD[@]}"
  RC=$?

  if [[ "$RC" -eq 0 ]]; then
    ((SUCCEEDED++))
  else
    ((FAILED++))
    FAILED_TARGETS+=("$TARGET_ID")
  fi

  echo
done

# =============================================================================
# SUMMARY
# =============================================================================
echo "fs-runner summary"
echo "  Snapshot type: $SNAPSHOT_TYPE"
echo "  Class:         $CLASS"
echo "  Total targets: $TOTAL"
echo "  Succeeded:     $SUCCEEDED"
echo "  Failed:        $FAILED"

if [[ "$FAILED" -gt 0 ]]; then
  echo
  echo "  Failed targets:"
  for t in "${FAILED_TARGETS[@]}"; do
    echo "    - $t"
  done
fi

echo

# =============================================================================
# METRICS
# =============================================================================
END_TS="$(date +%s)"
DURATION="$((END_TS - START_TS))"

cat >"$RUNNER_METRICS" <<EOF
# HELP fs_runner_targets_total Total targets evaluated
# TYPE fs_runner_targets_total gauge
fs_runner_targets_total $TOTAL

# HELP fs_runner_targets_succeeded Targets succeeded
# TYPE fs_runner_targets_succeeded gauge
fs_runner_targets_succeeded $SUCCEEDED

# HELP fs_runner_targets_failed Targets failed
# TYPE fs_runner_targets_failed gauge
fs_runner_targets_failed $FAILED

# HELP fs_runner_status Runner status (0=success,1=partial failure)
# TYPE fs_runner_status gauge
fs_runner_status $([[ "$FAILED" -gt 0 ]] && echo 1 || echo 0)

# HELP fs_runner_duration_seconds Total run duration
# TYPE fs_runner_duration_seconds gauge
fs_runner_duration_seconds $DURATION
EOF

# =============================================================================
# EXIT
# =============================================================================
if [[ "$FAILED" -gt 0 ]]; then
  exit 1
fi

exit 0


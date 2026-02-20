#!/usr/bin/env bash
set -euo pipefail

# ---- CONFIG ----
API_URL="https://prometheus.kluhsman.com/prometheus/api/v1/admin/tsdb/snapshot"
SNAPSHOT_BASE="/docker/volumes/prometheus_data/_data/prometheus_data/snapshots"
LINK_PATH="$SNAPSHOT_BASE/current_snapshot"

NODEEXP_DIR="/var/lib/node_exporter/textfile_collector"
METRIC_FILE="$NODEEXP_DIR/prometheus_snapshot.prom"
METRIC_GROUP="nodeexp_txt"

LOCKFILE="/var/lock/prometheus-prebackup.lock"

# ---- LOCK ----
exec 9>"$LOCKFILE"
flock -n 9 || {
    echo "Snapshot already running"
    exit 1
}

START_TS=$(date +%s.%N)
START_EPOCH=$(date +%s)

EXIT_CODE=1
SUCCESS=0
BLOCK_COUNT=0

write_metrics() {
    END_TS=$(date +%s.%N)
    END_EPOCH=$(date +%s)
    DURATION=$(awk "BEGIN {print $END_TS - $START_TS}")

    tmp="$(mktemp)"

    cat >"$tmp" <<EOF
# HELP prometheus_snapshot_last_success Whether last snapshot succeeded (1=yes,0=no)
# TYPE prometheus_snapshot_last_success gauge
prometheus_snapshot_last_success $SUCCESS

# HELP prometheus_snapshot_last_exit_code Exit code of last snapshot attempt
# TYPE prometheus_snapshot_last_exit_code gauge
prometheus_snapshot_last_exit_code $EXIT_CODE

# HELP prometheus_snapshot_last_duration_seconds Duration of snapshot process
# TYPE prometheus_snapshot_last_duration_seconds gauge
prometheus_snapshot_last_duration_seconds $DURATION

# HELP prometheus_snapshot_last_block_count Number of blocks in last snapshot
# TYPE prometheus_snapshot_last_block_count gauge
prometheus_snapshot_last_block_count $BLOCK_COUNT

# HELP prometheus_snapshot_last_timestamp Unix timestamp of last snapshot attempt
# TYPE prometheus_snapshot_last_timestamp gauge
prometheus_snapshot_last_timestamp $END_EPOCH
EOF

    chgrp "$METRIC_GROUP" "$tmp"
    chmod 0644 "$tmp"
    mv "$tmp" "$METRIC_FILE"
}

echo "[prometheus-prebackup] Starting snapshot..."

# Remove symlink first so failure is loud
rm -f "$LINK_PATH"

# ---- CREATE SNAPSHOT ----
if ! RESPONSE=$(curl -sS --fail -XPOST "$API_URL"); then
    echo "[prometheus-prebackup] Snapshot API call failed"
    EXIT_CODE=2
    write_metrics
    exit "$EXIT_CODE"
fi

SNAP_ID=$(echo "$RESPONSE" | jq -r '.data.name')

if [[ -z "$SNAP_ID" || "$SNAP_ID" == "null" ]]; then
    echo "[prometheus-prebackup] Could not extract snapshot ID"
    EXIT_CODE=3
    write_metrics
    exit "$EXIT_CODE"
fi

SNAP_PATH="$SNAPSHOT_BASE/$SNAP_ID"

# Wait up to 5 seconds for filesystem visibility
for _ in {1..5}; do
    [[ -d "$SNAP_PATH" ]] && break
    sleep 1
done

if [[ ! -d "$SNAP_PATH" ]]; then
    echo "[prometheus-prebackup] Snapshot directory not found"
    EXIT_CODE=4
    write_metrics
    exit "$EXIT_CODE"
fi

# Count block directories (ULID format starting with 01)
BLOCK_COUNT=$(find "$SNAP_PATH" -maxdepth 1 -type d -name "01*" | wc -l)

if [[ "$BLOCK_COUNT" -eq 0 ]]; then
    echo "[prometheus-prebackup] Snapshot contains zero blocks"
    EXIT_CODE=5
    write_metrics
    exit "$EXIT_CODE"
fi

# ---- CREATE SYMLINK ----
ln -s "$SNAP_PATH" "$LINK_PATH"

SUCCESS=1
EXIT_CODE=0

echo "[prometheus-prebackup] Snapshot ready: $SNAP_ID"

write_metrics
exit 0


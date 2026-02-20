#!/usr/bin/env bash
set -euo pipefail

# ---- CONFIG ----
API_URL="https://victoria.kluhsman.com/snapshot/create"
SNAPSHOT_BASE="/docker/volumes/prometheus_data/_data/victoriametrics_data/snapshots"
LINK_PATH="$SNAPSHOT_BASE/current_snapshot"

NODEEXP_DIR="/var/lib/node_exporter/textfile_collector"
METRIC_FILE="$NODEEXP_DIR/victoriametrics_snapshot.prom"
METRIC_GROUP="nodeexp_txt"

LOCKFILE="/var/lock/victoriametrics-prebackup.lock"

# ---- LOCK ----
exec 9>"$LOCKFILE"
flock -n 9 || {
    echo "VictoriaMetrics snapshot already running"
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
# HELP victoriametrics_snapshot_last_success Whether last snapshot succeeded (1=yes,0=no)
# TYPE victoriametrics_snapshot_last_success gauge
victoriametrics_snapshot_last_success $SUCCESS

# HELP victoriametrics_snapshot_last_exit_code Exit code of last snapshot attempt
# TYPE victoriametrics_snapshot_last_exit_code gauge
victoriametrics_snapshot_last_exit_code $EXIT_CODE

# HELP victoriametrics_snapshot_last_duration_seconds Duration of snapshot process
# TYPE victoriametrics_snapshot_last_duration_seconds gauge
victoriametrics_snapshot_last_duration_seconds $DURATION

# HELP victoriametrics_snapshot_last_block_count Directory count in snapshot
# TYPE victoriametrics_snapshot_last_block_count gauge
victoriametrics_snapshot_last_block_count $BLOCK_COUNT

# HELP victoriametrics_snapshot_last_timestamp Unix timestamp of last snapshot attempt
# TYPE victoriametrics_snapshot_last_timestamp gauge
victoriametrics_snapshot_last_timestamp $END_EPOCH
EOF

    chgrp "$METRIC_GROUP" "$tmp"
    chmod 0644 "$tmp"
    mv "$tmp" "$METRIC_FILE"
}

echo "[victoriametrics-prebackup] Starting snapshot..."

rm -f "$LINK_PATH"

if ! RESPONSE=$(curl -sS --fail -XPOST "$API_URL"); then
    echo "Snapshot API call failed"
    EXIT_CODE=2
    write_metrics
    exit "$EXIT_CODE"
fi

SNAP_ID=$(echo "$RESPONSE" | jq -r '.snapshot')

if [[ -z "$SNAP_ID" || "$SNAP_ID" == "null" ]]; then
    echo "Could not extract snapshot ID"
    EXIT_CODE=3
    write_metrics
    exit "$EXIT_CODE"
fi

SNAP_PATH="$SNAPSHOT_BASE/$SNAP_ID"

for _ in {1..5}; do
    [[ -d "$SNAP_PATH" ]] && break
    sleep 1
done

if [[ ! -d "$SNAP_PATH" ]]; then
    echo "Snapshot directory not found"
    EXIT_CODE=4
    write_metrics
    exit "$EXIT_CODE"
fi

BLOCK_COUNT=$(find "$SNAP_PATH" -mindepth 1 -maxdepth 1 -type d | wc -l)

if [[ "$BLOCK_COUNT" -eq 0 ]]; then
    echo "Snapshot appears empty"
    EXIT_CODE=5
    write_metrics
    exit "$EXIT_CODE"
fi

ln -s "$SNAP_PATH" "$LINK_PATH"

SUCCESS=1
EXIT_CODE=0

write_metrics
exit 0


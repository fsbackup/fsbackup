#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# fs-db-export.sh — database export helper (mysql / mariadb / postgres)
#
# Environment variables (required):
#   DB_ENGINE=mysql|mariadb|postgres
#   DB_CONTAINER=<container name>
#   DB_NAME=<database name>
#   DB_USER=<db user>
#   DB_PASSWORD=<db password>
#   EXPORT_ROOT=/exports/<app>
#
# Optional:
#   DB_CLIENT_IMAGE (default: mariadb:11 for mariadb, mysql:8 for mysql)
#   RETENTION=14
# =============================================================================

# -----------------------------
# Config
# -----------------------------
DB_ENGINE="${DB_ENGINE:?missing DB_ENGINE}"
DB_CONTAINER="${DB_CONTAINER:?missing DB_CONTAINER}"
DB_NAME="${DB_NAME:?missing DB_NAME}"
DB_USER="${DB_USER:?missing DB_USER}"
DB_PASSWORD="${DB_PASSWORD:?missing DB_PASSWORD}"
EXPORT_ROOT="${EXPORT_ROOT:?missing EXPORT_ROOT}"

RETENTION="${RETENTION:-14}"
HOSTNAME="$(hostname -s)"
TIMESTAMP="$(date +%F_%H-%M-%S)"
EPOCH_NOW="$(date +%s)"

EXPORT_DIR="${EXPORT_ROOT}"
EXPORT_FILE="${EXPORT_DIR}/${DB_NAME}_${TIMESTAMP}.sql"

NODEEXP_DIR="/var/lib/node_exporter/textfile_collector"
METRICS_FILE="${NODEEXP_DIR}/fs_db_export_${DB_NAME}.prom"

mkdir -p "$EXPORT_DIR"

# -----------------------------
# Metrics helpers
# -----------------------------
emit_metrics() {
  local status="$1"      # 0=success,1=failure
  local size="$2"        # bytes
  local end_ts="$3"

  tmp="$(mktemp)"
  cat >"$tmp" <<EOF
# HELP fs_db_export_success Database export success (1=success,0=failure)
# TYPE fs_db_export_success gauge
fs_db_export_success{db="${DB_NAME}",engine="${DB_ENGINE}",host="${HOSTNAME}"} $((status == 0 ? 1 : 0))

# HELP fs_db_export_last_timestamp Last export timestamp (epoch)
# TYPE fs_db_export_last_timestamp gauge
fs_db_export_last_timestamp{db="${DB_NAME}",engine="${DB_ENGINE}",host="${HOSTNAME}"} ${end_ts}

# HELP fs_db_export_size_bytes Size of last export in bytes
# TYPE fs_db_export_size_bytes gauge
fs_db_export_size_bytes{db="${DB_NAME}",engine="${DB_ENGINE}",host="${HOSTNAME}"} ${size}
EOF

  chmod 0644 "$tmp"
  mv "$tmp" "$METRICS_FILE"
}

# -----------------------------
# Export logic
# -----------------------------
START_TS="$(date +%s)"
SIZE=0
STATUS=1

echo "[$(date -Is)] Starting ${DB_ENGINE} export for ${DB_NAME}"

if [[ "$DB_ENGINE" == "mariadb" || "$DB_ENGINE" == "mysql" ]]; then
  CLIENT_IMAGE="${DB_CLIENT_IMAGE:-mariadb:11}"

  docker run --rm \
    --network "container:${DB_CONTAINER}" \
    -v "${EXPORT_DIR}:/exports" \
    -e MYSQL_PWD="${DB_PASSWORD}" \
    "${CLIENT_IMAGE}" \
    mariadb-dump \
      -h 127.0.0.1 \
      -u "${DB_USER}" \
      --single-transaction \
      --quick \
      --routines \
      --events \
      --triggers \
      "${DB_NAME}" \
      > "${EXPORT_FILE}"

elif [[ "$DB_ENGINE" == "postgres" ]]; then
  docker exec \
    -e PGPASSWORD="${DB_PASSWORD}" \
    "${DB_CONTAINER}" \
    pg_dump \
      -U "${DB_USER}" \
      -F p \
      "${DB_NAME}" \
      > "${EXPORT_FILE}"

else
  echo "ERROR: unsupported DB_ENGINE=${DB_ENGINE}" >&2
  exit 2
fi

# -----------------------------
# Post-run checks
# -----------------------------
if [[ -s "$EXPORT_FILE" ]]; then
  SIZE="$(stat -c %s "$EXPORT_FILE")"
  STATUS=0
  echo "[$(date -Is)] Export completed: ${EXPORT_FILE} (${SIZE} bytes)"
else
  echo "ERROR: export file missing or empty: ${EXPORT_FILE}" >&2
fi

END_TS="$(date +%s)"

emit_metrics "$STATUS" "$SIZE" "$END_TS"

# -----------------------------
# Retention
# -----------------------------
ls -1t "${EXPORT_DIR}"/*.sql 2>/dev/null | tail -n +$((RETENTION + 1)) | xargs -r rm -f

exit "$STATUS"


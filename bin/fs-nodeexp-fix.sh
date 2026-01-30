#!/usr/bin/env bash
set -euo pipefail

DIR="/var/lib/node_exporter/textfile_collector"
GROUP="nodeexp_txt"
SERVICE_USER="node_exporter"

log() {
  echo "$(date -Is) [fs-nodeexp-fix] $*"
}

log "Starting node_exporter textfile collector repair"

# ---- sanity checks ----
id "$SERVICE_USER" >/dev/null 2>&1 || {
  log "ERROR: user '$SERVICE_USER' does not exist"
  exit 1
}

getent group "$GROUP" >/dev/null 2>&1 || {
  log "ERROR: group '$GROUP' does not exist"
  exit 1
}

[[ -d "$DIR" ]] || {
  log "ERROR: directory $DIR does not exist"
  exit 1
}

# ---- ensure group membership ----
if ! id "$SERVICE_USER" | grep -qw "$GROUP"; then
  log "Adding $SERVICE_USER to group $GROUP"
  usermod -aG "$GROUP" "$SERVICE_USER"
  NEED_RESTART=1
else
  NEED_RESTART=0
fi

# ---- directory permissions ----
log "Fixing directory ownership and permissions"
chown root:"$GROUP" "$DIR"
chmod 2775 "$DIR"

# ---- ACLs (explicit + defaults) ----
log "Applying ACLs"
setfacl -m g:"$GROUP":rwx "$DIR"
setfacl -m o:rx "$DIR"

setfacl -d -m g:"$GROUP":rwx "$DIR"
setfacl -d -m o:rx "$DIR"

# ---- fix existing files ----
log "Fixing existing metric file permissions"
find "$DIR" -type f -name "*.prom" -exec chmod g+r {} +
find "$DIR" -type f -name "*.lock" -exec chmod g+r {} + || true

# ---- validation ----
log "Validating access as $SERVICE_USER"
if ! sudo -u "$SERVICE_USER" ls "$DIR" >/dev/null 2>&1; then
  log "ERROR: $SERVICE_USER still cannot read $DIR"
  exit 1
fi

# ---- restart if required ----
if [[ "$NEED_RESTART" -eq 1 ]]; then
  log "Restarting node_exporter"
  systemctl restart node_exporter
else
  log "Restart not required"
fi

log "node_exporter textfile collector is healthy"


#!/usr/bin/env bash
set -euo pipefail

DIR="/var/lib/node_exporter/textfile_collector"
GROUP="nodeexp_txt"
SERVICE_USER="node_exporter"
WEB_USER=""

log() {
  echo "$(date -Is) [fs-nodeexp-fix] $*"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --web-user) WEB_USER="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--web-user <username>]"
      echo "  --web-user  Also grant read ACLs to this user (e.g. the fsbackup web UI user)"
      exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

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

# ---- optional web UI user read access ----
if [[ -n "$WEB_USER" ]]; then
  if ! id "$WEB_USER" &>/dev/null; then
    log "ERROR: --web-user '$WEB_USER' does not exist"
    exit 1
  fi
  log "Granting read ACLs to web user: $WEB_USER"
  setfacl -m "u:${WEB_USER}:rx" "$DIR"
  setfacl -d -m "u:${WEB_USER}:r" "$DIR"
  find "$DIR" -type f -name "*.prom" -exec setfacl -m "u:${WEB_USER}:r" {} +
  log "Web user $WEB_USER can read $DIR"
fi

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


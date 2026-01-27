#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# fsbackup_remote_init.sh
#
# Run on SOURCE hosts (ns1, hs, weewx, rp, denhpsvr*)
# Prepares host for fsbackup rsync-over-SSH access.
#
# Safe to re-run.
# =============================================================================

BACKUP_USER="backup"
BACKUP_UID="34"
BACKUP_GID="34"
BACKUP_HOME="/var/lib/fsbackup-src"
BACKUP_SHELL="/bin/bash"

SSH_PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEJwT7RbHgoeGRTQfF/bbdtJJ6+WBfteTH5jYTzZUUcc fsbackup@fs"

NODEEXP_GROUP="node_exporter"

echo "== fsbackup remote init =="

# -----------------------------------------------------------------------------
# User setup
# -----------------------------------------------------------------------------
if ! id "$BACKUP_USER" &>/dev/null; then
  useradd \
    --system \
    --uid "$BACKUP_UID" \
    --gid "$BACKUP_GID" \
    --home-dir "$BACKUP_HOME" \
    --create-home \
    --shell "$BACKUP_SHELL" \
    "$BACKUP_USER"
else
  usermod \
    --home "$BACKUP_HOME" \
    --shell "$BACKUP_SHELL" \
    "$BACKUP_USER"
fi

passwd -l "$BACKUP_USER" >/dev/null

mkdir -p "$BACKUP_HOME"
chown "$BACKUP_USER:$BACKUP_USER" "$BACKUP_HOME"
chmod 750 "$BACKUP_HOME"

# -----------------------------------------------------------------------------
# SSH setup
# -----------------------------------------------------------------------------
SSH_DIR="$BACKUP_HOME/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"

mkdir -p "$SSH_DIR"
touch "$AUTH_KEYS"

grep -qxF "$SSH_PUBKEY" "$AUTH_KEYS" || echo "$SSH_PUBKEY" >>"$AUTH_KEYS"

chown -R "$BACKUP_USER:$BACKUP_USER" "$SSH_DIR"
chmod 700 "$SSH_DIR"
chmod 600 "$AUTH_KEYS"

# -----------------------------------------------------------------------------
# ACL helpers
# -----------------------------------------------------------------------------
ensure_exec() {
  local path="$1"
  setfacl -m "u:${BACKUP_USER}:x" "$path" 2>/dev/null || true
}

ensure_read_exec_dir() {
  local path="$1"
  setfacl -m "u:${BACKUP_USER}:rx" "$path" 2>/dev/null || true
}

ensure_read_files() {
  local path="$1"
  setfacl -R -m "u:${BACKUP_USER}:r" "$path" 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# Common parent traversal
# -----------------------------------------------------------------------------
ensure_exec /etc
ensure_exec /var
ensure_exec /docker || true

# -----------------------------------------------------------------------------
# Known backup paths (safe defaults)
# -----------------------------------------------------------------------------
for d in \
  /etc/headscale \
  /etc/bind \
  /etc/webmin \
  /var/webmin \
  /etc/nginx \
  /etc/avahi \
  /var/www \
  /docker/stacks
do
  if [[ -d "$d" ]]; then
    ensure_read_exec_dir "$d"
    ensure_read_files "$d"
  fi
done

# -----------------------------------------------------------------------------
# node_exporter compatibility (DO NOT break patchcheck)
# -----------------------------------------------------------------------------
if getent group "$NODEEXP_GROUP" >/dev/null; then
  usermod -aG "$NODEEXP_GROUP" "$BACKUP_USER"
fi

# -----------------------------------------------------------------------------
# Verification
# -----------------------------------------------------------------------------
sudo -u "$BACKUP_USER" ssh -o BatchMode=yes -o StrictHostKeyChecking=no localhost true 2>/dev/null || true

echo "fsbackup-remote-init: OK"


#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# fsbackup-remote-init.sh
#
# Prepares a remote host for fsbackup pulls via SSH + rsync
# while preserving node_exporter patch metrics permissions.
#
# SAFE TO RE-RUN
# =============================================================================

# -----------------------------
# CONFIG
# -----------------------------
BACKUP_USER="backup"
BACKUP_GROUP="backup"
NODEEXP_GROUP="nodeexp_txt"
PATCH_USER="patchcheck"

SSH_DIR="/home/${BACKUP_USER}/.ssh"
AUTHORIZED_KEYS="${SSH_DIR}/authorized_keys"

NODE_EXPORTER_TEXTFILE="/var/lib/node_exporter/textfile_collector"
PROM_FILE="${NODE_EXPORTER_TEXTFILE}/fsbackup_remote_init.prom"

# ⚠️ REPLACE THIS KEY
FSBACKUP_PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEJwT7RbHgoeGRTQfF/bbdtJJ6+WBfteTH5jYTzZUUcc fsbackup@backup-host"

# -----------------------------
# Sanity
# -----------------------------
[[ $EUID -eq 0 ]] || { echo "ERROR: must be run as root"; exit 1; }

# -----------------------------
# Backup user
# -----------------------------
getent group "$BACKUP_GROUP" >/dev/null || groupadd "$BACKUP_GROUP"

if ! id "$BACKUP_USER" >/dev/null 2>&1; then
  useradd \
    --system \
    --home "/home/${BACKUP_USER}" \
    --create-home \
    --shell /usr/sbin/nologin \
    --gid "$BACKUP_GROUP" \
    "$BACKUP_USER"
fi

usermod -s /usr/sbin/nologin "$BACKUP_USER"

# -----------------------------
# SSH setup
# -----------------------------
install -d -o "$BACKUP_USER" -g "$BACKUP_GROUP" -m 0700 "$SSH_DIR"

touch "$AUTHORIZED_KEYS"
chown "$BACKUP_USER:$BACKUP_GROUP" "$AUTHORIZED_KEYS"
chmod 600 "$AUTHORIZED_KEYS"

if ! grep -qF "$FSBACKUP_PUBKEY" "$AUTHORIZED_KEYS"; then
  echo "$FSBACKUP_PUBKEY" >>"$AUTHORIZED_KEYS"
fi

# -----------------------------
# node_exporter shared access
# -----------------------------
groupadd -f "$NODEEXP_GROUP"

usermod -aG "$NODEEXP_GROUP" "$PATCH_USER" 2>/dev/null || true
usermod -aG "$NODEEXP_GROUP" "$BACKUP_USER"

install -d -o root -g "$NODEEXP_GROUP" -m 2775 "$NODE_EXPORTER_TEXTFILE"

setfacl -m g:"$NODEEXP_GROUP":rwx "$NODE_EXPORTER_TEXTFILE"
setfacl -d -m g:"$NODEEXP_GROUP":rwx "$NODE_EXPORTER_TEXTFILE"

# -----------------------------
# Prometheus metric
# -----------------------------
cat >"$PROM_FILE" <<EOF
# HELP fsbackup_remote_init_ok Remote fsbackup SSH setup completed
# TYPE fsbackup_remote_init_ok gauge
fsbackup_remote_init_ok 1
EOF

chown root:"$NODEEXP_GROUP" "$PROM_FILE"
chmod 664 "$PROM_FILE"

# -----------------------------
# Verifier (single-line contract check)
# -----------------------------
getent group "$NODEEXP_GROUP" >/dev/null \
  && getfacl "$NODE_EXPORTER_TEXTFILE" | grep -q "group:${NODEEXP_GROUP}:rwx" \
  || { echo "ERROR: nodeexp_txt ACL misconfigured"; exit 1; }

# -----------------------------
# Done
# -----------------------------
echo "Remote fsbackup init complete."
echo "Backup user:      $BACKUP_USER"
echo "Node exporter OK: $NODE_EXPORTER_TEXTFILE"


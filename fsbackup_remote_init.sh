#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# fsbackup-remote-init.sh
#
# Idempotent remote host preparation for fsbackup
# Safe to run multiple times.
#
# =============================================================================

BACKUP_USER="backup"
BACKUP_GROUP="backup"
BACKUP_HOME="/home/backup"
BACKUP_SHELL="/bin/bash"

NODEEXP_GROUP="nodeexp_txt"
TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"
METRIC_FILE="${TEXTFILE_DIR}/fsbackup_remote_ready.prom"

SSH_KEY_NAME="id_ed25519_backup.pub"

# -----------------------------
# EMBEDDED PUBLIC KEY (REPLACE)
# -----------------------------
BACKUP_PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEJwT7RbHgoeGRTQfF/bbdtJJ6+WBfteTH5jYTzZUUcc"

# -----------------------------
# Sanity checks
# -----------------------------
[[ $EUID -eq 0 ]] || { echo "Must be run as root"; exit 1; }

# -----------------------------
# Ensure groups
# -----------------------------
getent group "$BACKUP_GROUP" >/dev/null || groupadd "$BACKUP_GROUP"
getent group "$NODEEXP_GROUP" >/dev/null || groupadd "$NODEEXP_GROUP"

# -----------------------------
# Ensure backup user
# -----------------------------
if ! id "$BACKUP_USER" >/dev/null 2>&1; then
  useradd \
    --system \
    --home "$BACKUP_HOME" \
    --create-home \
    --shell "$BACKUP_SHELL" \
    --gid "$BACKUP_GROUP" \
    "$BACKUP_USER"
fi

# Enforce correct shell + home
usermod -s "$BACKUP_SHELL" -d "$BACKUP_HOME" "$BACKUP_USER"

# -----------------------------
# SSH setup
# -----------------------------
SSH_DIR="${BACKUP_HOME}/.ssh"
AUTH_KEYS="${SSH_DIR}/authorized_keys"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
chown "$BACKUP_USER:$BACKUP_GROUP" "$SSH_DIR"

touch "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"
chown "$BACKUP_USER:$BACKUP_GROUP" "$AUTH_KEYS"

if ! grep -q "$BACKUP_PUBKEY" "$AUTH_KEYS"; then
  echo "$BACKUP_PUBKEY" >>"$AUTH_KEYS"
fi

# -----------------------------
# node_exporter textfile perms
# -----------------------------
mkdir -p "$TEXTFILE_DIR"

chown root:"$NODEEXP_GROUP" "$TEXTFILE_DIR"
chmod 2775 "$TEXTFILE_DIR"

# Ensure ACLs (safe if already present)
setfacl -m g:"$NODEEXP_GROUP":rwx "$TEXTFILE_DIR" || true
setfacl -d -m g:"$NODEEXP_GROUP":rwx "$TEXTFILE_DIR" || true

usermod -aG "$NODEEXP_GROUP" "$BACKUP_USER"

# -----------------------------
# Verification checks
# -----------------------------
sudo -u "$BACKUP_USER" test -w "$TEXTFILE_DIR"
sudo -u "$BACKUP_USER" ssh -o BatchMode=yes -o StrictHostKeyChecking=no localhost true 2>/dev/null || true

# -----------------------------
# Prometheus readiness metric
# -----------------------------
cat >"$METRIC_FILE" <<EOF
# HELP fsbackup_remote_ready Remote host ready for fsbackup
# TYPE fsbackup_remote_ready gauge
fsbackup_remote_ready 1
EOF

chown "$BACKUP_USER:$NODEEXP_GROUP" "$METRIC_FILE"
chmod 644 "$METRIC_FILE"

# -----------------------------
# Summary
# -----------------------------
echo
echo "fsbackup remote init complete."
echo
echo "Backup user:   $BACKUP_USER"
echo "Home dir:      $BACKUP_HOME"
echo "Shell:         $BACKUP_SHELL"
echo "SSH key ready: yes"
echo "node_exporter: preserved"
echo
echo "This script is safe to re-run."


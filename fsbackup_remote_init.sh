#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# fsbackup remote SSH bootstrap
#
# SAFE FOR NODE_EXPORTER TEXTFILE COLLECTOR
#
# Run as root on REMOTE HOST
# =============================================================================

# -----------------------------
# Accounts & groups
# -----------------------------
BACKUP_USER="backup"
PATCHCHECK_USER="patchcheck"
NODEEXP_GROUP="nodeexp_txt"

BACKUP_HOME="/home/${BACKUP_USER}"
BACKUP_SHELL="/usr/sbin/nologin"

NODE_EXPORTER_TEXTFILE="/var/lib/node_exporter/textfile_collector"

# ---------------------------------------------------------------------
# EMBEDDED PUBLIC KEY (REPLACE THIS)
# ---------------------------------------------------------------------
FSBACKUP_PUBKEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEJwT7RbHgoeGRTQfF/bbdtJJ6+WBfteTH5jYTzZUUcc fsbackup@fs'

echo "== fsbackup remote bootstrap (node_exporter safe) =="

# -----------------------------
# Ensure shared node exporter group
# -----------------------------
if ! getent group "$NODEEXP_GROUP" >/dev/null; then
  groupadd "$NODEEXP_GROUP"
  echo "Created group: $NODEEXP_GROUP"
else
  echo "Group exists: $NODEEXP_GROUP"
fi

# -----------------------------
# Ensure backup user
# -----------------------------
if ! id "$BACKUP_USER" &>/dev/null; then
  useradd \
    --home "$BACKUP_HOME" \
    --create-home \
    --shell "$BACKUP_SHELL" \
    "$BACKUP_USER"
  echo "Created user: $BACKUP_USER"
else
  echo "User exists: $BACKUP_USER"
fi

# Unlock (nologin is fine, but account must not be locked)
passwd -u "$BACKUP_USER" >/dev/null || true
usermod -s "$BACKUP_SHELL" "$BACKUP_USER"

# -----------------------------
# Ensure patchcheck user exists
# (do NOT modify shell / behavior)
# -----------------------------
if ! id "$PATCHCHECK_USER" &>/dev/null; then
  echo "WARNING: patchcheck user not found (skipping user creation)"
else
  echo "User exists: $PATCHCHECK_USER"
fi

# -----------------------------
# Group membership (CRITICAL)
# -----------------------------
usermod -aG "$NODEEXP_GROUP" "$BACKUP_USER"

if id "$PATCHCHECK_USER" &>/dev/null; then
  usermod -aG "$NODEEXP_GROUP" "$PATCHCHECK_USER"
fi

# -----------------------------
# SSH setup for backup user
# -----------------------------
install -d -m 700 -o "$BACKUP_USER" -g "$BACKUP_USER" "$BACKUP_HOME/.ssh"
touch "$BACKUP_HOME/.ssh/authorized_keys"
chown "$BACKUP_USER:$BACKUP_USER" "$BACKUP_HOME/.ssh/authorized_keys"
chmod 600 "$BACKUP_HOME/.ssh/authorized_keys"

if ! grep -qxF "$FSBACKUP_PUBKEY" "$BACKUP_HOME/.ssh/authorized_keys"; then
  echo "$FSBACKUP_PUBKEY" >>"$BACKUP_HOME/.ssh/authorized_keys"
  echo "Installed fsbackup SSH key"
else
  echo "fsbackup SSH key already present"
fi

# -----------------------------
# node_exporter textfile permissions
# -----------------------------
mkdir -p "$NODE_EXPORTER_TEXTFILE"

# Ownership stays root for safety
chown root:"$NODEEXP_GROUP" "$NODE_EXPORTER_TEXTFILE"
chmod 2775 "$NODE_EXPORTER_TEXTFILE"   # setgid so files inherit group

# ACLs: allow both services full access
setfacl -m "g:${NODEEXP_GROUP}:rwx" "$NODE_EXPORTER_TEXTFILE"
setfacl -d -m "g:${NODEEXP_GROUP}:rwx" "$NODE_EXPORTER_TEXTFILE"

# -----------------------------
# Verify write access (non-fatal)
# -----------------------------
echo "Verifying node_exporter write access..."

sudo -u "$BACKUP_USER" touch "$NODE_EXPORTER_TEXTFILE/.backup_test" && rm -f "$NODE_EXPORTER_TEXTFILE/.backup_test"

if id "$PATCHCHECK_USER" &>/dev/null; then
  sudo -u "$PATCHCHECK_USER" touch "$NODE_EXPORTER_TEXTFILE/.patchcheck_test" && rm -f "$NODE_EXPORTER_TEXTFILE/.patchcheck_test"
fi

# -----------------------------
# SSHD hardening (safe drop-in)
# -----------------------------
SSHD_DROPIN="/etc/ssh/sshd_config.d/fsbackup.conf"

cat >"$SSHD_DROPIN" <<EOF
PubkeyAuthentication yes
PasswordAuthentication no
PermitEmptyPasswords no
PermitRootLogin no
AllowUsers ${BACKUP_USER}
EOF

chmod 644 "$SSHD_DROPIN"

if systemctl is-active ssh >/dev/null 2>&1; then
  systemctl reload ssh
elif systemctl is-active sshd >/dev/null 2>&1; then
  systemctl reload sshd
fi

# -----------------------------
# Summary
# -----------------------------
echo
echo "Remote fsbackup bootstrap complete"
echo
echo "Users:"
echo "  - backup      (SSH access)"
echo "  - patchcheck  (unchanged)"
echo
echo "Shared group:"
echo "  - $NODEEXP_GROUP"
echo
echo "Textfile collector:"
echo "  $NODE_EXPORTER_TEXTFILE"
echo
echo "Test from backup host:"
echo "  sudo -u fsbackup ssh backup@$(hostname -f) 'echo ssh-ok'"


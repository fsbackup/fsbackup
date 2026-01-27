#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# fsbackup remote SSH bootstrap
#
# Run as root ON THE REMOTE HOST
# =============================================================================

BACKUP_USER="backup"
BACKUP_HOME="/home/${BACKUP_USER}"
BACKUP_SHELL="/usr/sbin/nologin"

# ---------------------------------------------------------------------
# EMBEDDED PUBLIC KEY
# Replace this entire line with your REAL fsbackup public key
# ---------------------------------------------------------------------
FSBACKUP_PUBKEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFAKEKEYREPLACEMEWITHREALKEY fsbackup@fs'

echo "== fsbackup remote bootstrap =="

# -----------------------------
# Create backup user
# -----------------------------
if ! id "$BACKUP_USER" &>/dev/null; then
  useradd \
    --home "$BACKUP_HOME" \
    --create-home \
    --shell "$BACKUP_SHELL" \
    "$BACKUP_USER"
  echo "Created user: $BACKUP_USER"
else
  echo "User already exists: $BACKUP_USER"
fi

# -----------------------------
# Unlock account (CRITICAL)
# -----------------------------
passwd -u "$BACKUP_USER" >/dev/null || true
usermod -s "$BACKUP_SHELL" "$BACKUP_USER"

# -----------------------------
# SSH directory + perms
# -----------------------------
install -d -m 700 -o "$BACKUP_USER" -g "$BACKUP_USER" "$BACKUP_HOME/.ssh"
touch "$BACKUP_HOME/.ssh/authorized_keys"
chown "$BACKUP_USER:$BACKUP_USER" "$BACKUP_HOME/.ssh/authorized_keys"
chmod 600 "$BACKUP_HOME/.ssh/authorized_keys"

# -----------------------------
# Install fsbackup public key
# -----------------------------
if ! grep -qxF "$FSBACKUP_PUBKEY" "$BACKUP_HOME/.ssh/authorized_keys"; then
  echo "$FSBACKUP_PUBKEY" >>"$BACKUP_HOME/.ssh/authorized_keys"
  echo "Installed fsbackup SSH key"
else
  echo "fsbackup SSH key already present"
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

# -----------------------------
# Reload sshd
# -----------------------------
if systemctl is-active ssh >/dev/null 2>&1; then
  systemctl reload ssh
elif systemctl is-active sshd >/dev/null 2>&1; then
  systemctl reload sshd
fi

# -----------------------------
# Final verification hint
# -----------------------------
echo
echo "fsbackup remote bootstrap complete"
echo
echo "From backup host, test with:"
echo "  sudo -u fsbackup ssh backup@$(hostname -f) 'echo ssh-ok'"
echo
echo "Then test rsync:"
echo "  sudo -u fsbackup rsync -av backup@$(hostname -f):/etc /tmp/test"


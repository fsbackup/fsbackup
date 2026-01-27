#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# fsbackup_remote_init.sh
#
# Run on EACH REMOTE HOST as root. Creates/fixes the "backup" user for rsync/ssh
# and sets safe ACLs for backup reads WITHOUT breaking node_exporter patching perms.
#
# Key behaviors:
# - backup user: /home/backup, shell /bin/bash, password locked (SSH key only)
# - authorized_keys installed (placeholder supported)
# - node_exporter textfile_collector perms model preserved:
#     group nodeexp_txt + setgid + default ACLs for patchcheck + backup
# - allow-path ACL policy:
#     directories: u:backup:rx
#     files:       u:backup:r
#
# =============================================================================

BACKUP_USER="backup"
BACKUP_GROUP="backup"

# Your policy group for textfile collector sharing between services:
NODEEXP_GROUP="nodeexp_txt"
PATCHCHECK_USER="patchcheck"
NODE_EXPORTER_TEXTFILE="/var/lib/node_exporter/textfile_collector"

# Placeholder public key (REPLACE ME)
DEFAULT_PUBKEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEJwT7RbHgoeGRTQfF/bbdtJJ6+WBfteTH5jYTzZUUcc fsbackup@fs'

PUBKEY="${DEFAULT_PUBKEY}"
PUBKEY_FILE=""

ALLOW_PATHS=()

WRITE_METRIC=1

usage() {
  cat <<'EOF'
Usage:
  fsbackup_remote_init.sh [--pubkey "ssh-ed25519 ..."] [--pubkey-file /path/key.pub]
                          [--allow-path /path]... [--no-metric]

Examples:
  sudo bash fsbackup_remote_init.sh --pubkey-file /root/id_ed25519_backup.pub \
      --allow-path /etc/headscale --allow-path /etc/bind --allow-path /etc/nginx

  sudo bash fsbackup_remote_init.sh --pubkey "ssh-ed25519 AAAA..." \
      --allow-path /var/www/html --allow-path /etc/weewx
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pubkey) PUBKEY="$2"; shift 2 ;;
    --pubkey-file) PUBKEY_FILE="$2"; shift 2 ;;
    --allow-path) ALLOW_PATHS+=("$2"); shift 2 ;;
    --no-metric) WRITE_METRIC=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown arg: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "ERROR: must run as root"; exit 1; }

if [[ -n "$PUBKEY_FILE" ]]; then
  [[ -f "$PUBKEY_FILE" ]] || { echo "ERROR: pubkey file missing: $PUBKEY_FILE"; exit 1; }
  PUBKEY="$(cat "$PUBKEY_FILE")"
fi

# -----------------------------
# Helpers
# -----------------------------
ensure_group() {
  local g="$1"
  getent group "$g" >/dev/null || groupadd "$g"
}

ensure_user() {
  local u="$1"
  local home="$2"
  local shell="$3"
  ensure_group "$BACKUP_GROUP"

  if ! id "$u" >/dev/null 2>&1; then
    useradd --create-home --home-dir "$home" --shell "$shell" --gid "$BACKUP_GROUP" "$u"
  fi

  # Fix home and shell if someone created it wrong earlier.
  usermod --home "$home" --shell "$shell" "$u"

  # Ensure home exists and ownership is correct.
  mkdir -p "$home"
  chown "$u:$BACKUP_GROUP" "$home"
  chmod 700 "$home"

  # Lock password (SSH key only). Does NOT disable key auth.
  passwd -l "$u" >/dev/null 2>&1 || true
}

install_authorized_key() {
  local u="$1"
  local home
  home="$(getent passwd "$u" | cut -d: -f6)"
  local sshdir="${home}/.ssh"
  local auth="${sshdir}/authorized_keys"

  mkdir -p "$sshdir"
  chmod 700 "$sshdir"
  chown "$u:$BACKUP_GROUP" "$sshdir"

  # Idempotent key install (append only if missing)
  touch "$auth"
  chmod 600 "$auth"
  chown "$u:$BACKUP_GROUP" "$auth"

  if ! grep -qxF "$PUBKEY" "$auth"; then
    echo "$PUBKEY" >>"$auth"
  fi
}

# Apply "dirs rx, files r" ACL pattern to a given path.
apply_backup_read_acl() {
  local path="$1"

  if [[ ! -e "$path" ]]; then
    echo "WARN: allow-path does not exist (skipping): $path" >&2
    return 0
  fi

  # If it's a file, treat its parent dir + file.
  if [[ -f "$path" ]]; then
    local d
    d="$(dirname "$path")"
    find "$d" -maxdepth 0 -type d -exec setfacl -m "u:${BACKUP_USER}:rx" {} + || true
    find "$d" -maxdepth 0 -type d -exec setfacl -m "m::rx" {} + || true
    setfacl -m "u:${BACKUP_USER}:r" "$path" || true
    setfacl -m "m::r" "$path" || true
    return 0
  fi

  # Directory tree:
  # Directories need x for traversal. Files need only r.
  find "$path" -type d -exec setfacl -m "u:${BACKUP_USER}:rx" {} + || true
  find "$path" -type d -exec setfacl -m "m::rx" {} + || true

  find "$path" -type f -exec setfacl -m "u:${BACKUP_USER}:r" {} + || true
  find "$path" -type f -exec setfacl -m "m::r" {} + || true
}

# Ensure node_exporter textfile collector supports multiple writers safely.
ensure_textfile_permissions() {
  ensure_group "$NODEEXP_GROUP"

  # Ensure node_exporter service account exists? (don’t create; just add if present)
  if id -u node_exporter >/dev/null 2>&1; then
    usermod -aG "$NODEEXP_GROUP" node_exporter || true
  fi

  # Ensure patchcheck exists? (don’t create; but add if present)
  if id -u "$PATCHCHECK_USER" >/dev/null 2>&1; then
    usermod -aG "$NODEEXP_GROUP" "$PATCHCHECK_USER" || true
  fi

  # Ensure backup is also in that group
  usermod -aG "$NODEEXP_GROUP" "$BACKUP_USER" || true

  mkdir -p "$NODE_EXPORTER_TEXTFILE"
  chown root:"$NODEEXP_GROUP" "$NODE_EXPORTER_TEXTFILE"
  chmod 2775 "$NODE_EXPORTER_TEXTFILE"

  # Default ACLs so new files inherit group write,
  # and so backup + patchcheck can both manage files.
  setfacl -m "g:${NODEEXP_GROUP}:rwx" "$NODE_EXPORTER_TEXTFILE" || true
  setfacl -d -m "g:${NODEEXP_GROUP}:rwx" "$NODE_EXPORTER_TEXTFILE" || true

  # Explicitly ensure the two service users can rwx this directory, without depending on umask.
  setfacl -m "u:${BACKUP_USER}:rwx" "$NODE_EXPORTER_TEXTFILE" || true
  setfacl -d -m "u:${BACKUP_USER}:rwx" "$NODE_EXPORTER_TEXTFILE" || true

  if id -u "$PATCHCHECK_USER" >/dev/null 2>&1; then
    setfacl -m "u:${PATCHCHECK_USER}:rwx" "$NODE_EXPORTER_TEXTFILE" || true
    setfacl -d -m "u:${PATCHCHECK_USER}:rwx" "$NODE_EXPORTER_TEXTFILE" || true
  fi
}

write_metric() {
  [[ "$WRITE_METRIC" -eq 1 ]] || return 0
  local metric_file="${NODE_EXPORTER_TEXTFILE}/fsbackup_remote_init.prom"
  local now
  now="$(date +%s)"

  cat >"$metric_file" <<EOF
# HELP fsbackup_remote_init_last_run_seconds Unix timestamp of last remote init run
# TYPE fsbackup_remote_init_last_run_seconds gauge
fsbackup_remote_init_last_run_seconds ${now}
EOF

  chown root:"$NODEEXP_GROUP" "$metric_file" || true
  chmod 664 "$metric_file" || true
}

# -----------------------------
# Main
# -----------------------------
echo "fsbackup remote init starting on $(hostname -s)"

ensure_user "$BACKUP_USER" "/home/backup" "/bin/bash"
install_authorized_key "$BACKUP_USER"

ensure_textfile_permissions

# Apply ACLs for requested allow paths
if [[ ${#ALLOW_PATHS[@]} -gt 0 ]]; then
  echo "Applying backup read ACLs to allow-paths:"
  for p in "${ALLOW_PATHS[@]}"; do
    echo "  - $p"
    apply_backup_read_acl "$p"
  done
else
  echo "No --allow-path specified; skipping ACL path grants."
fi

write_metric

# One-line verifier (requested)
# - confirms account is usable (no “account not available”)
# - confirms sshdir perms
echo "VERIFIER: $(getent passwd backup | cut -d: -f1,6,7) ; sshdir=$(stat -c '%U:%G %a' /home/backup/.ssh 2>/dev/null || echo n/a)"

echo "fsbackup remote init complete."


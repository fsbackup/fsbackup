#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# fs-trust-host.sh
#
# Seeds SSH host keys for fsbackup with strict verification.
# Emits Prometheus metrics for host trust visibility.
#
# Usage:
#   fs-trust-host.sh <host>                     scan and trust (console, TOFU)
#   fs-trust-host.sh --scan <host>              print the host's ed25519 key
#                                               fingerprint; writes nothing
#   fs-trust-host.sh --expect <SHA256:fp> <host>
#                                               trust only if the host still
#                                               presents exactly this key
#
# The web UI (Configuration → Hosts) uses --scan to show the fingerprint for
# the operator to verify, then --expect with the confirmed value, so the key
# written is the one that was reviewed. Port 22 only (the runner connects to
# backup@<host> on the default port).
# =============================================================================

MODE="trust"
EXPECT_FP=""
case "${1:-}" in
  --scan)   MODE="scan"; shift ;;
  --expect) MODE="expect"; EXPECT_FP="${2:-}"; shift 2 || true ;;
esac
HOST="${1:-}"
PORT=22

FSBACKUP_USER="fsbackup"
SSH_DIR="/var/lib/fsbackup/.ssh"
KNOWN_HOSTS="$SSH_DIR/known_hosts"

METRICS_DIR="/var/lib/node_exporter/textfile_collector"
METRIC_FILE="$METRICS_DIR/fsbackup_ssh_hostkeys.prom"

GROUP_NODEEXP="nodeexp_txt"

usage() {
  echo "Usage: fs-trust-host.sh [--scan | --expect <SHA256:fingerprint>] <hostname>" >&2
  exit 2
}

[[ -n "$HOST" ]] || usage
# Hostname or IPv4 only — never let a value that starts with '-' reach
# ssh-keyscan as an option (e.g. -f <file>).
[[ "$HOST" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$ ]] \
  || { echo "ERROR: invalid hostname: $HOST" >&2; exit 2; }
if [[ "$MODE" == "expect" ]]; then
  [[ "$EXPECT_FP" =~ ^SHA256:[A-Za-z0-9+/]{43}$ ]] \
    || { echo "ERROR: invalid fingerprint: $EXPECT_FP" >&2; exit 2; }
fi

[[ $EUID -eq 0 || "$(id -un)" == "$FSBACKUP_USER" ]] \
  || { echo "ERROR: must be run as root or $FSBACKUP_USER" >&2; exit 1; }

# ------------------------------------------------------------------
# Scan the host's current ed25519 key
# ------------------------------------------------------------------
TMP_KEYS="$(mktemp)"
trap 'rm -f "$TMP_KEYS"' EXIT

scan_host() {
  ssh-keyscan -p "$PORT" -t ed25519 -- "$HOST" >"$TMP_KEYS" 2>/dev/null || true
  [[ -s "$TMP_KEYS" ]] || { echo "ERROR: ssh-keyscan got no ed25519 key from $HOST" >&2; exit 1; }
  FP="$(ssh-keygen -lf "$TMP_KEYS" | awk 'NR==1 {print $2}')"
  [[ -n "$FP" ]] || { echo "ERROR: failed to extract fingerprint for $HOST" >&2; exit 1; }
}

if [[ "$MODE" == "scan" ]]; then
  scan_host
  echo "FINGERPRINT $FP"
  if ssh-keygen -F "$HOST" -f "$KNOWN_HOSTS" >/dev/null 2>&1; then
    echo "Host key already present for $HOST"
  fi
  exit 0
fi

mkdir -p "$SSH_DIR"
touch "$KNOWN_HOSTS"

if [[ $EUID -eq 0 ]]; then
  chown -R "$FSBACKUP_USER:$FSBACKUP_USER" "$SSH_DIR"
fi
chmod 700 "$SSH_DIR"
chmod 600 "$KNOWN_HOSTS"

# ------------------------------------------------------------------
# Refuse silent key changes
# ------------------------------------------------------------------
if ssh-keygen -F "$HOST" -f "$KNOWN_HOSTS" >/dev/null; then
  echo "Host key already present for $HOST — skipping"
  exit 0
fi

echo "Seeding SSH host key for $HOST..."
scan_host

if [[ "$MODE" == "expect" && "$FP" != "$EXPECT_FP" ]]; then
  echo "ERROR: $HOST now presents $FP, not the confirmed $EXPECT_FP — nothing written" >&2
  exit 1
fi

cat "$TMP_KEYS" >>"$KNOWN_HOSTS"

echo "Host key trusted: $HOST ($FP)"

# ------------------------------------------------------------------
# Prometheus metric (atomic; keeps the other hosts' lines)
# ------------------------------------------------------------------
mkdir -p "$METRICS_DIR"

tmp="$(mktemp)"
{
  echo "# HELP fsbackup_ssh_host_key_present Whether an SSH host key is trusted (1=yes)"
  echo "# TYPE fsbackup_ssh_host_key_present gauge"
  if [[ -f "$METRIC_FILE" ]]; then
    grep '^fsbackup_ssh_host_key_present{' "$METRIC_FILE" \
      | grep -vF "{host=\"$HOST\"," || true
  fi
  echo "fsbackup_ssh_host_key_present{host=\"$HOST\",fingerprint=\"$FP\"} 1"
} >"$tmp"

if [[ $EUID -eq 0 ]]; then
  chown "$FSBACKUP_USER:$GROUP_NODEEXP" "$tmp"
fi
chmod 0644 "$tmp" 2>/dev/null || true
mv "$tmp" "$METRIC_FILE"

exit 0

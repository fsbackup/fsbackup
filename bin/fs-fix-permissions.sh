#!/usr/bin/env bash
set -u
set -o pipefail

# =============================================================================
# fs-fix-permissions.sh — grant fsbackup user read ACLs on all local source paths
#
# Reads targets.yml, finds targets with host: localhost (or the local hostname),
# and applies setfacl -R -m u:fsbackup:rX on each source path.
# Must run as root. Safe to re-run — setfacl is idempotent.
# =============================================================================

[[ $EUID -eq 0 ]] || { echo "Must run as root"; exit 1; }

CONFIG_FILE="${1:-/etc/fsbackup/targets.yml}"
FSBACKUP_USER="${FSBACKUP_USER:-fsbackup}"

[[ -f "$CONFIG_FILE" ]] || { echo "targets.yml not found: $CONFIG_FILE"; exit 2; }

for cmd in yq jq setfacl; do
    command -v "$cmd" >/dev/null || { echo "$cmd not found"; exit 2; }
done

LOCAL_HOSTNAME="$(hostname -s)"

echo "Scanning local targets in $CONFIG_FILE..."
echo

while IFS= read -r entry; do
    host="$(jq -r '.host // empty' <<<"$entry")"
    src="$(jq -r '.source // empty'  <<<"$entry")"
    id="$(jq -r '.id // empty'       <<<"$entry")"

    [[ -z "$host" || -z "$src" ]] && continue

    # Only local targets
    if [[ "$host" != "localhost" && "$host" != "$LOCAL_HOSTNAME" && "$host" != "fs" ]]; then
        continue
    fi

    if [[ ! -e "$src" ]]; then
        echo "  SKIP  $id — path not found: $src"
        continue
    fi

    setfacl -R -m "u:${FSBACKUP_USER}:rX" "$src" 2>/dev/null
    echo "  OK    $id — $src"

done < <(yq eval -o=json '.. | select(has("id"))' "$CONFIG_FILE" | jq -c .)

echo
echo "Done. Re-run after adding new local targets or after Docker volume recreation."

#!/usr/bin/env bash
set -u

CONFIG_FILE="/etc/fsbackup/targets.yml"
BACKUP_SSH_USER="backup"

CLASS=""
SEED_HOSTKEYS=0

usage() {
  echo "Usage: fs-doctor.sh --class <class> [--seed-hostkeys]"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --class) CLASS="$2"; shift 2 ;;
    --seed-hostkeys) SEED_HOSTKEYS=1; shift ;;
    *) usage; exit 2 ;;
  esac
done

[[ -n "$CLASS" ]] || { echo "Missing --class"; exit 2; }

command -v yq >/dev/null || { echo "yq not found"; exit 2; }
command -v jq >/dev/null || { echo "jq not found"; exit 2; }

mapfile -t TARGETS < <(
  yq eval -o=json ".${CLASS}[]" "$CONFIG_FILE" | jq -c .
)

is_local_host() {
  local h="$1"

  # Normalize
  local short
  short="$(hostname -s)"
  local fqdn
  fqdn="$(hostname -f 2>/dev/null || true)"

  # Direct matches
  [[ "$h" == "localhost" ]] && return 0
  [[ "$h" == "$short" ]] && return 0
  [[ -n "$fqdn" && "$h" == "$fqdn" ]] && return 0

  # IP match (covers interface IPs)
  if getent hosts "$h" >/dev/null 2>&1; then
    local target_ips local_ips
    target_ips="$(getent hosts "$h" | awk '{print $1}')"
    local_ips="$(hostname -I 2>/dev/null)"

    for ip in $target_ips; do
      for lip in $local_ips; do
        [[ "$ip" == "$lip" ]] && return 0
      done
    done
  fi

  return 1
}

is_excludable_rsync_error() {
  grep -qE 'rsync: \[sender\] opendir ".+" failed: Permission denied' <<<"$1"
}

TOTAL="${#TARGETS[@]}"
PASS=0
FAIL=0

echo
echo "fsbackup doctor"
echo "  Class:  $CLASS"
echo "  Items:  $TOTAL"
echo

printf "%-28s %-6s %s\n" "TARGET" "STAT" "DETAIL"
printf "%-28s %-6s %s\n" "----------------------------" "------" "------------------------------"

for t in "${TARGETS[@]}"; do
  id="$(jq -r '.id // empty' <<<"$t")"
  host="$(jq -r '.host // empty' <<<"$t")"
  src="$(jq -r '.source // empty' <<<"$t")"
  rsync_opts="$(jq -r '.rsync_opts // empty' <<<"$t")"

  [[ -z "$id" || -z "$host" || -z "$src" ]] && {
    printf "%-28s FAIL   bad target entry\n" "${id:-<missing>}"
    ((FAIL++))
    continue
  }

  if is_local_host "$host"; then
    if [[ -e "$src" ]]; then
      printf "%-28s %-6s %s\n" "$id" "OK" "local path exists"
      ((PASS++))
    else
      printf "%-28s %-6s %s\n" "$id" "FAIL" "local missing: $src"
      ((FAIL++))
    fi
    continue
  fi

  # SSH check
  if ! ssh -o BatchMode=yes -o StrictHostKeyChecking=yes \
      "${BACKUP_SSH_USER}@${host}" "echo ok" >/dev/null 2>&1; then
    printf "%-28s FAIL   ssh failed\n" "$id"
    ((FAIL++))
    continue
  fi

  # Path check
  if ! ssh "${BACKUP_SSH_USER}@${host}" "test -e '$src'" >/dev/null 2>&1; then
    printf "%-28s FAIL   remote missing: %s\n" "$id" "$src"
    ((FAIL++))
    continue
  fi

  # rsync dry-run
  RSYNC_ERR="$(
    "${RSYNC_CMD[@]}" \
      "${BACKUP_SSH_USER}@${host}:${src%/}/" \
      "/tmp/fsdoctor_${id}" 2>&1 >/dev/null
  )"

  if [[ $? -eq 0 ]]; then
    printf "%-28s OK     ssh+path+rsync dry-run OK\n" "$id"
    ((PASS++))
  elif is_excludable_rsync_error "$RSYNC_ERR"; then
    printf "%-28s WARN   rsync permission-denied (auto-excludable)\n" "$id"
    ((PASS++))
  else
    printf "%-28s FAIL   rsync failed\n" "$id"
    ((FAIL++))
  fi

done

echo
echo "Doctor summary"
echo "  Total: $TOTAL"
echo "  OK:    $PASS"
echo "  FAIL:  $FAIL"
echo
NODEEXP_DIR="/var/lib/node_exporter/textfile_collector"

if [[ -d "$NODEEXP_DIR" && -r "$NODEEXP_DIR" && -x "$NODEEXP_DIR" ]]; then
  echo "node_exporter_textfile_access 1"
else
  echo "WARN: node_exporter cannot read textfile collector"
  echo "node_exporter_textfile_access 0"
fi

exit 0


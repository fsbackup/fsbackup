#!/usr/bin/env bash
set -u
set -o pipefail

# =============================================================================
# fs-logrotate-metric.sh — is logrotate actually rotating fsbackup's logs?
#
# Run hourly by fsbackup-logrotate-metric.timer, as fsbackup (it only reads
# fsbackup's own logs and /etc/logrotate.d/fsbackup; no root needed). Writes
# fsbackup_logrotate.prom for the dashboard's "Log Rotation" panel:
#
#   fsbackup_logrotate_ok                  1 = config valid and no stale logs
#   fsbackup_logrotate_last_run_seconds    start of the day of the newest
#                                          rotated file (<name>.log-YYYYMMDD[.gz])
#   fsbackup_logrotate_config_ok           logrotate -d passes and the config
#                                          targets LOG_DIR/*.log
#   fsbackup_logrotate_stale_logs          logs whose first entry is older than
#                                          LOGROTATE_MAX_AGE_SECONDS
#   fsbackup_logrotate_oldest_entry_age_seconds
#                                          age of the oldest first entry across
#                                          non-empty logs
#   fsbackup_logrotate_checked_seconds     when this check last ran
#
# Why "first entry": logs rotate daily with copytruncate + notifempty, so a
# non-empty log only ever holds lines written since the last rotation (about a
# day). If its first line is older than two days, rotation has stopped for it.
# Every fsbackup log line starts with an ISO timestamp (date -Is, or
# +%Y-%m-%dT%H:%M:%S%z in older s3-export lines); a first line without one is
# not counted either way. Empty logs are never stale.
#
# The last-rotation time comes from the dateext date in rotated file names,
# not ctime: moving or re-owning the files (e.g. the /var/log/fsbackup
# migration) changes ctime but not the name.
#
# Usage: fs-logrotate-metric.sh   (no arguments)
# Exit:  0 metric written (whatever it says), 2 usage/config error, 1 could
#        not write the metric. A stale log or bad config is reported in the
#        metric and the journal, not as a failed unit, so an hourly timer
#        doesn't page on it.
#
# Functions below only touch their arguments; the script stops before the main
# body when sourced, so tests can call them against a scratch directory.
# =============================================================================

# first_entry_epoch <file> — epoch of the timestamp at the start of the file's
# first line, or nothing if the file is empty or the line has no timestamp.
# Regular files only; the read is size- and time-limited.
first_entry_epoch() {
  local f="$1" line ts
  [[ -f "$f" && ! -L "$f" && -s "$f" ]] || return 0
  # Exit status ignored: with pipefail, head -n 1 closing the pipe early can
  # make it non-zero even though the line was read.
  line="$(timeout 5 head -c 256 -- "$f" 2>/dev/null | head -n 1)"
  ts="${line%% *}"
  [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([+-][0-9]{2}:?[0-9]{2}|Z)?$ ]] || return 0
  date -d "$ts" +%s 2>/dev/null || true
}

# newest_rotation_epoch <log_dir> — start of the local day in the newest
# rotated file name (<name>.log-YYYYMMDD or .log-YYYYMMDD.gz), or 0.
newest_rotation_epoch() {
  local dir="$1" newest
  newest="$(find "$dir" -maxdepth 1 -type f -regextype posix-extended \
              -regex '.*\.log-[0-9]{8}(\.gz)?' -printf '%f\n' 2>/dev/null \
            | sed -E 's/.*\.log-([0-9]{8})(\.gz)?$/\1/' | sort -r | head -n 1)"
  if [[ -n "$newest" ]]; then
    date -d "$newest" +%s 2>/dev/null || echo 0
  else
    echo 0
  fi
}

# config_ok <logrotate_conf> <log_dir> — 0 if logrotate accepts the config
# and it has a "<log_dir>/*.log {" block.
# logrotate -d exits 0 for some bad configs (an unknown directive is only
# reported as "error: ... ignoring line"), so any "error:" line fails too.
# -s /dev/null: the real state file is root-only (0640) and would add an
# "error opening state file" line; -d never writes state anyway.
config_ok() {
  local conf="$1" dir="$2" out
  [[ -f "$conf" && -r "$conf" ]] || return 1
  grep -qF "${dir}/*.log {" "$conf" || return 1
  out="$(timeout 30 logrotate -d -s /dev/null "$conf" 2>&1 >/dev/null)" || return 1
  ! grep -q '^error:' <<<"$out"
}

# write_prom <out_file> <assoc-array-name> — atomic write: the tmp file is in
# the same dir (so mv is a rename) with a name node_exporter ignores.
write_prom() {
  local out="$1"
  local -n _m="$2"
  local tmp
  tmp="$(mktemp "$(dirname "$out")/.fsbackup_logrotate.XXXXXX")" || return 1
  cat >"$tmp" <<EOF
# HELP fsbackup_logrotate_ok 1 if the logrotate config is valid and no fsbackup log is stale, 0 otherwise
# TYPE fsbackup_logrotate_ok gauge
fsbackup_logrotate_ok ${_m[ok]}

# HELP fsbackup_logrotate_last_run_seconds Start of the day (Unix time) of the newest rotated fsbackup log file; 0 if none
# TYPE fsbackup_logrotate_last_run_seconds gauge
fsbackup_logrotate_last_run_seconds ${_m[last_rotation]}

# HELP fsbackup_logrotate_config_ok 1 if logrotate -d accepts /etc/logrotate.d/fsbackup and it targets LOG_DIR/*.log
# TYPE fsbackup_logrotate_config_ok gauge
fsbackup_logrotate_config_ok ${_m[config_ok]}

# HELP fsbackup_logrotate_stale_logs Non-empty fsbackup logs whose first entry is older than the max age (rotation not happening)
# TYPE fsbackup_logrotate_stale_logs gauge
fsbackup_logrotate_stale_logs ${_m[stale]}

# HELP fsbackup_logrotate_oldest_entry_age_seconds Age of the oldest first entry across non-empty fsbackup logs
# TYPE fsbackup_logrotate_oldest_entry_age_seconds gauge
fsbackup_logrotate_oldest_entry_age_seconds ${_m[oldest_age]}

# HELP fsbackup_logrotate_checked_seconds Unix time this check last ran
# TYPE fsbackup_logrotate_checked_seconds gauge
fsbackup_logrotate_checked_seconds ${_m[checked]}
EOF
  chgrp nodeexp_txt "$tmp" 2>/dev/null || true
  chmod 0644 "$tmp"
  mv -fT "$tmp" "$out" || { rm -f "$tmp"; return 1; }
}

# Stop here when sourced (tests); everything below is the actual run.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  return 0
fi

[[ $# -eq 0 ]] || { echo "Usage: $0   (no arguments)" >&2; exit 2; }

. /etc/fsbackup/fsbackup.conf || { echo "cannot read /etc/fsbackup/fsbackup.conf" >&2; exit 2; }
LOG_DIR="${LOG_DIR:-/var/log/fsbackup}"
LOG_DIR="${LOG_DIR%/}"
MAX_AGE="${LOGROTATE_MAX_AGE_SECONDS:-172800}"   # 2 days
[[ "$MAX_AGE" =~ ^[0-9]+$ ]] || { echo "LOGROTATE_MAX_AGE_SECONDS must be a number" >&2; exit 2; }

LOGROTATE_CONF="/etc/logrotate.d/fsbackup"
PROM_OUT="/var/lib/node_exporter/textfile_collector/fsbackup_logrotate.prom"

declare -A M
now="$(date +%s)"
M[checked]="$now"
M[last_rotation]="$(newest_rotation_epoch "$LOG_DIR")"

if config_ok "$LOGROTATE_CONF" "$LOG_DIR"; then
  M[config_ok]=1
else
  M[config_ok]=0
  echo "WARN logrotate config ${LOGROTATE_CONF} is invalid or does not target ${LOG_DIR}/*.log (check: logrotate -d ${LOGROTATE_CONF})"
fi

stale=0
oldest_age=0
stale_names=()
while IFS= read -r -d '' f; do
  first="$(first_entry_epoch "$f")"
  [[ -n "$first" ]] || continue
  age=$(( now - first ))
  (( age > oldest_age )) && oldest_age=$age
  if (( age > MAX_AGE )); then
    stale=$((stale + 1))
    stale_names+=("$(basename "$f") ($(( age / 3600 ))h)")
  fi
done < <(find "$LOG_DIR" -maxdepth 1 -type f -name '*.log' -print0 2>/dev/null)
M[stale]="$stale"
M[oldest_age]="$oldest_age"

if [[ "${M[config_ok]}" -eq 1 && "$stale" -eq 0 ]]; then
  M[ok]=1
else
  M[ok]=0
fi
(( stale > 0 )) && echo "WARN ${stale} log(s) not rotated in over $(( MAX_AGE / 3600 ))h: ${stale_names[*]}"

write_prom "$PROM_OUT" M || { echo "ERROR cannot write ${PROM_OUT}" >&2; exit 1; }

last_fmt="never"
[[ "${M[last_rotation]}" -gt 0 ]] && last_fmt="$(date -d "@${M[last_rotation]}" +%F)"
echo "logrotate ok=${M[ok]} config_ok=${M[config_ok]} stale=${stale} oldest_entry_age=${oldest_age}s last_rotated=${last_fmt}"
exit 0

# shellcheck shell=bash
# =============================================================================
# lib/log.sh — shared logging helpers for fsbackup job scripts
#
# Installed as /opt/fsbackup/lib/log.sh. Scripts in bin/ and s3/ (one level
# below the install root) load it after sourcing fsbackup.conf:
#
#   . /etc/fsbackup/fsbackup.conf
#   LOG_DIR="${LOG_DIR:-/var/log/fsbackup}"
#   . "$(dirname "$(readlink -f "$0")")/../lib/log.sh"
#   log_init retention            # -> $LOG_DIR/retention.log
#
# What goes where (journald = the unit's stdout/stderr):
#
#   log   <tag> <msg...>   file only: detail (rsync stats, snapshot names,
#                          retention keep/destroy decisions, S3 objects, ...)
#   event <tag> <msg...>   file + stdout: run start/end, one line per target
#                          result, the final summary
#   error <tag> <msg...>   file + stderr: errors and warnings; the message is
#                          prefixed "ERROR "
#   log_stream <tag>       file only: log each line read from stdin (command
#                          output such as rsync --stats or zfs stderr)
#
# Every line has the same format: "<date -Is> [<tag>] <msg>".
#
# A logging problem never fails a job. If LOG_DIR is missing or not writable,
# the file part is skipped, event/error still reach stdout/stderr, and a single
# warning is printed to stderr for the run.
#
# Plain bash, no dependencies; safe under `set -u` and `set -o pipefail`.
# =============================================================================

LOG_DIR="${LOG_DIR:-/var/log/fsbackup}"
LOG_FILE="${LOG_FILE:-}"
_LOG_WARNED=0
_LOG_TS=""

# _log_ts: set _LOG_TS to the current time in `date -Is` format
# (2026-09-23T02:19:54-06:00). Uses the printf builtin, so logging a long
# rsync output does not fork date once per line.
_log_ts() {
  local t
  printf -v t '%(%Y-%m-%dT%H:%M:%S%z)T' -1
  _LOG_TS="${t:0:${#t}-2}:${t: -2}"
}

# _log_warn_once: tell stderr (journald) once per run that file logging is off.
_log_warn_once() {
  [[ "$_LOG_WARNED" -eq 0 ]] || return 0
  _LOG_WARNED=1
  _log_ts
  printf '%s [log] WARN cannot write %s; detail lines from this run are not being saved (check LOG_DIR exists and is owned by the job user)\n' \
    "$_LOG_TS" "$LOG_FILE" >&2
}

# _log_write <line>: append one line to LOG_FILE. Never fails.
_log_write() {
  [[ -n "$LOG_FILE" ]] || return 0
  { printf '%s\n' "$1" >>"$LOG_FILE"; } 2>/dev/null || _log_warn_once
  return 0
}

# log_init <basename>: LOG_FILE="$LOG_DIR/<basename>.log" and create LOG_DIR.
log_init() {
  LOG_FILE="${LOG_DIR}/${1:-fsbackup}.log"
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  # Probe once so an unwritable LOG_DIR is reported at the start of the run.
  { : >>"$LOG_FILE"; } 2>/dev/null || _log_warn_once
  return 0
}

log() {
  local tag="${1:-}"
  shift || true
  _log_ts
  _log_write "${_LOG_TS} [${tag}] $*"
}

event() {
  local tag="${1:-}" line
  shift || true
  _log_ts
  line="${_LOG_TS} [${tag}] $*"
  printf '%s\n' "$line"
  _log_write "$line"
}

error() {
  local tag="${1:-}" line
  shift || true
  _log_ts
  line="${_LOG_TS} [${tag}] ERROR $*"
  printf '%s\n' "$line" >&2
  _log_write "$line"
}

log_stream() {
  local tag="${1:-}" line
  while IFS= read -r line || [[ -n "$line" ]]; do
    log "$tag" "$line"
  done
  return 0
}

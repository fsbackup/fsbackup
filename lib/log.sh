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
# Running as root (fsbackup-scrub.service, or a job started by hand with sudo):
# LOG_DIR belongs to fsbackup, so fsbackup can put a symlink there, e.g.
# scrub.log -> /etc/shadow or a sudoers drop-in. A root `>>` would follow it
# and append to the target; fs.protected_symlinks does not help, because it
# only covers sticky world-writable dirs. So when EUID is 0 this file never
# opens a path in LOG_DIR as root: every file write, and the mkdir in log_init,
# runs as fsbackup via setpriv. That also keeps new log files fsbackup-owned,
# which logrotate (su fsbackup, copytruncate) needs. Root scripts must not open
# or chown log files themselves. If the drop fails (no fsbackup user, no
# setpriv), file logging is off for the run, with the usual single warning.
#
# Plain bash; setpriv (util-linux) is needed only when running as root. Safe
# under `set -u` and `set -o pipefail`.
# =============================================================================

LOG_DIR="${LOG_DIR:-/var/log/fsbackup}"
LOG_FILE="${LOG_FILE:-}"
_LOG_WARNED=0
_LOG_TS=""
# The user that does the file writes when this runs as root (see above).
# Empty when not root: the job user writes its own files, with no extra process.
_LOG_AS_USER=""
[[ "$EUID" -eq 0 ]] && _LOG_AS_USER="fsbackup"

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
  printf '%s [log] WARN cannot write %s%s; detail lines from this run are not being saved (check LOG_DIR exists and is writable by %s)\n' \
    "$_LOG_TS" "$LOG_FILE" "${_LOG_AS_USER:+ as ${_LOG_AS_USER}}" "${_LOG_AS_USER:-the job user}" >&2
}

# _log_as_user <cmd...>: run cmd as $_LOG_AS_USER, with no supplementary
# groups. Only used when running as root.
_log_as_user() {
  setpriv --reuid="$_LOG_AS_USER" --regid="$_LOG_AS_USER" --clear-groups -- "$@"
}

# _log_write <line>: append one line to LOG_FILE. Never fails.
_log_write() {
  [[ -n "$LOG_FILE" ]] || return 0
  if [[ -n "$_LOG_AS_USER" ]]; then
    _log_as_user tee -a -- "$LOG_FILE" >/dev/null 2>&1 <<<"$1" || _log_warn_once
  else
    { printf '%s\n' "$1" >>"$LOG_FILE"; } 2>/dev/null || _log_warn_once
  fi
  return 0
}

# log_init <basename>: LOG_FILE="$LOG_DIR/<basename>.log" and create LOG_DIR.
# Probes once, so an unwritable LOG_DIR is reported at the start of the run.
log_init() {
  LOG_FILE="${LOG_DIR}/${1:-fsbackup}.log"
  if [[ -n "$_LOG_AS_USER" ]]; then
    _log_as_user mkdir -p -- "$LOG_DIR" >/dev/null 2>&1 || true
    _log_as_user tee -a -- "$LOG_FILE" </dev/null >/dev/null 2>&1 || _log_warn_once
  else
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    { : >>"$LOG_FILE"; } 2>/dev/null || _log_warn_once
  fi
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

# log_stream always reads stdin to the end, even when the file can't be
# written, so `cmd 2>&1 | log_stream <tag>` never kills cmd with SIGPIPE.
log_stream() {
  local tag="${1:-}" line
  if [[ -n "$_LOG_AS_USER" && -n "$LOG_FILE" ]]; then
    # Root: one privilege-dropped writer for the whole stream, not one per
    # line. PIPE is ignored in this subshell only: if the writer dies, the
    # loop gets write errors instead of being killed, and keeps draining.
    (
      trap '' PIPE
      while IFS= read -r line || [[ -n "$line" ]]; do
        _log_ts
        printf '%s [%s] %s\n' "$_LOG_TS" "$tag" "$line" 2>/dev/null
      done
    ) | _log_as_user tee -a -- "$LOG_FILE" >/dev/null 2>&1 || _log_warn_once
    return 0
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    log "$tag" "$line"
  done
  return 0
}

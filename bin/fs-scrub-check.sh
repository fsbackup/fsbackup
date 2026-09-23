#!/usr/bin/env bash
set -u
set -o pipefail

# =============================================================================
# fs-scrub-check.sh — scrub the backup pool and fail loudly on any problem
#
# Run monthly by fsbackup-scrub.timer, as root (zpool scrub needs root):
#   1. zpool scrub -w <pool>    blocks until the scrub has finished
#   2. zpool status -p <pool>   checked for: pool state != ONLINE, vdevs not
#                               ONLINE, non-zero READ/WRITE/CKSUM counters,
#                               bytes repaired or errors on the scan line, and
#                               an errors: line other than "No known data errors"
#   3. writes fsbackup_scrub.prom, and exits non-zero on any problem so the
#      unit shows as failed.
#
# Pool: ZFS_POOL from fsbackup.conf if set, else the pool holding SNAPSHOT_ROOT
# (/backup/snapshots -> dataset backup/snapshots -> pool "backup").
#
# A scrub that is already running when this starts (for example Ubuntu's own
# zfsutils-linux cron scrub on the second Sunday) is not an error: this waits
# for it to finish and checks its result instead of starting a second one. A
# resilver in progress is waited for, then the scrub is started.
#
# vdev error counters stay in zpool status through later scrubs until they
# are cleared, so every run keeps failing until someone has looked. After
# investigating:  sudo zpool clear <pool>
#
# Logging: run start, the pool result, the summary and every problem go to
# journald; the full zpool status output goes to $LOG_DIR/scrub.log only.
#
# Usage:  fs-scrub-check.sh             (no arguments; run as root)
# Exit:   0 clean, 1 problem found or scrub failed, 2 usage/config error
#
# The functions below touch nothing but their arguments, and the script stops
# before the main body when sourced, so tests can `. fs-scrub-check.sh`, feed
# fixture `zpool status` text to scrub_parse_status and point
# scrub_write_prom at a scratch file.
# =============================================================================

# -----------------------------------------------------------------------------
# scrub_parse_status — evaluate `zpool status -p <pool>` text read from stdin.
#
# Prints key=value lines:
#   pool= state= status= scan= scan_func=(scrub|resilver|none|unknown)
#   scan_state=(finished|in_progress|paused|canceled|none|unknown)
#   repaired= repaired_bytes= scan_errors= device_errors= data_errors= errors=
#   problem=<text>      one line per problem found (zero or more)
# Keys whose value could not be determined are left out.
#
# Returns 0 if no problems, 1 if any, 2 if the text is not a zpool status.
# The scan is expected to be a finished scrub: anything else (in progress,
# canceled, a resilver, none) is reported as a problem.
# -----------------------------------------------------------------------------
scrub_parse_status() {
  awk '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function problem(msg) { np++; prob[np] = msg }
    # zfs_nicebytes text ("0B", "512B", "12K", "1.50M") -> bytes, or -1
    function nicebytes(s,   num, unit, mult) {
      if (s !~ /^[0-9]+(\.[0-9]+)?[BKMGTPE]?$/) return -1
      unit = substr(s, length(s), 1)
      num = s; sub(/[BKMGTPE]$/, "", num)
      mult = 1
      if      (unit == "K") mult = 1024
      else if (unit == "M") mult = 1024 * 1024
      else if (unit == "G") mult = 1024 * 1024 * 1024
      else if (unit == "T") mult = 1024 * 1024 * 1024 * 1024
      else if (unit == "P") mult = 1024 * 1024 * 1024 * 1024 * 1024
      else if (unit == "E") mult = 1024 * 1024 * 1024 * 1024 * 1024 * 1024
      return sprintf("%.0f", num * mult)
    }
    BEGIN { mode = ""; hdr = 0; spares = 0; dev_err = 0; np = 0 }
    {
      t = trim($0)
      if (t ~ /^errors:/) {
        mode = "errors"; errline = trim(substr(t, 8)); have_errline = 1; next
      }
      # Key lines ("pool:", "state:", "scan:", "config:", "status:", ...).
      # Not inside config: device names such as pci-0000:00:17.0-ata-1
      # contain colons.
      if (mode != "config" && t ~ /^[a-z][a-z ]*:/) {
        key = t; sub(/:.*/, "", key)
        val = t; sub(/^[^:]*:[ \t]*/, "", val)
        mode = key
        if      (key == "pool")   pool = val
        else if (key == "state")  state = val
        else if (key == "status") status = val
        else if (key == "scan")   scan = val
        else if (key == "config") { hdr = 0; spares = 0 }
        next
      }
      # Continuation lines of the scan: entry (progress of a running scrub)
      if (mode == "scan") { if (t != "") scan_more = scan_more " " t; next }
      if (mode != "config" || t == "") next

      n = split(t, f, /[ \t]+/)
      if (f[1] == "NAME" && f[2] == "STATE") { hdr = 1; next }
      if (!hdr) next
      # Section headers (logs, cache, spares, special, dedup) are one word.
      # Spare rows ("sdx AVAIL", "sdx INUSE currently in use") have no counters.
      if (n == 1) { spares = (f[1] == "spares"); next }
      if (spares) next

      name = f[1]; vstate = f[2]
      if (name != pool && vstate != "ONLINE")
        problem("vdev " name " is " vstate)
      if (n >= 5) {
        bad = 0
        for (i = 3; i <= 5; i++) {
          if (f[i] != "0") {
            bad = 1
            dev_err += (f[i] ~ /^[0-9]+$/) ? f[i] + 0 : 1
          }
        }
        if (bad) {
          note = ""
          for (i = 6; i <= n; i++) note = note " " f[i]
          problem("vdev " name " error counters read=" f[3] " write=" f[4] " cksum=" f[5] note)
        }
      }
    }
    END {
      if (pool == "" || state == "") {
        print "problem=could not parse zpool status output"
        exit 2
      }

      if (state != "ONLINE") problem("pool state is " state)

      # Scan line: "scrub repaired 0B in 01:04:11 with 0 errors on <date>",
      # "scrub in progress since <date>", "scrub paused since <date>",
      # "scrub canceled on <date>", "resilvered 1.2G in ... with 0 errors on
      # <date>", "resilver in progress since <date>", "none requested".
      nw = split(scan, w, /[ \t]+/)
      sfunc = "unknown"; sstate = "unknown"; repaired = ""; scan_errs = ""
      if (w[1] == "none") { sfunc = "none"; sstate = "none" }
      else if (w[1] == "scrub" || w[1] == "resilver" || w[1] == "resilvered") {
        sfunc = (w[1] == "scrub") ? "scrub" : "resilver"
        if (w[1] == "resilvered" || w[2] == "repaired")  sstate = "finished"
        else if (w[2] == "in" && w[3] == "progress")     sstate = "in_progress"
        else if (w[2] == "paused")                       sstate = "paused"
        else if (w[2] == "canceled" || w[2] == "cancelled") sstate = "canceled"
      }
      # "repaired" only for a scrub: "resilvered 350G" on a resilver is the
      # normal rebuild of a device, not a repair of bad data.
      if (sstate == "finished") {
        if (sfunc == "scrub") repaired = w[3]
        for (i = 1; i + 2 <= nw; i++)
          if (w[i] == "with" && w[i + 2] == "errors") scan_errs = w[i + 1]
      } else if (sfunc == "scrub" && (sstate == "in_progress" || sstate == "paused")) {
        # "... 0B repaired, 16.91% done, 00:00:04 to go"
        nm = split(scan_more, c, /[ \t,]+/)
        for (i = 2; i <= nm; i++) if (c[i] == "repaired") repaired = c[i - 1]
      }

      if (sfunc != "scrub" || sstate != "finished")
        problem("last scan is not a completed scrub: " (scan == "" ? "(no scan line)" : scan))
      if (scan_errs != "" && scan_errs != "0")
        problem("scrub reported " scan_errs " error(s)")
      rb = ""
      if (repaired != "") {
        rb = nicebytes(repaired)
        if (rb == -1) { problem("could not parse repaired amount: " repaired); rb = "" }
        else if (rb + 0 > 0) problem("scrub repaired " repaired " (a device returned bad data)")
      }

      de = ""
      if (!have_errline) problem("no errors: line in zpool status output")
      else if (errline ~ /^No known data errors/) de = 0
      else {
        problem("data errors: " errline)
        de = (errline ~ /^[0-9]+ /) ? errline + 0 : 1
      }

      print "pool=" pool
      print "state=" state
      if (status != "") print "status=" status
      print "scan=" scan
      print "scan_func=" sfunc
      print "scan_state=" sstate
      if (repaired != "")  print "repaired=" repaired
      if (rb != "")        print "repaired_bytes=" rb
      if (scan_errs != "") print "scan_errors=" scan_errs
      print "device_errors=" dev_err
      if (de != "")        print "data_errors=" de
      if (have_errline)    print "errors=" errline
      for (i = 1; i <= np; i++) print "problem=" prob[i]
      exit (np > 0 ? 1 : 0)
    }
  '
}

# scrub_prom_value <prom_file> <metric> <pool> — print the metric value for
# pool="<pool>" from an existing prom file (nothing if absent or not a plain
# non-negative number).
# This runs as root, and the textfile dir is writable by fsbackup and the
# nodeexp_txt group, so the file is untrusted: only a regular file is read
# (not a symlink, which root would follow, and not a FIFO, which would block),
# the read is time-limited in case the file is swapped after the check, and
# only a number comes back.
scrub_prom_value() {
  local file="$1" metric="$2" pool="$3"
  [[ -f "$file" && ! -L "$file" && -r "$file" ]] || return 0
  timeout 10 awk -v key="${metric}{pool=\"${pool}\"}" '
    $1 == key { v = $2 }
    END { if (v ~ /^[0-9]+(\.[0-9]+)?$/) print v }' "$file" 2>/dev/null
  return 0
}

# scrub_write_prom <out_file> <pool> <assoc-array-name>
# Writes fsbackup_scrub.prom atomically (tmp + mv). The array holds the values
# by key: last_run last_success success problems duration scan_errors
# repaired_bytes device_errors data_errors. Empty/missing keys are left out.
# The tmp file is made in /tmp (sticky, so nobody else can swap it before the
# chgrp/chmod), not in the group-writable textfile dir. mv -T renames onto
# <out_file> itself: without it, a symlink to a directory planted at
# <out_file> would make root move the tmp file into that directory and the
# metric would silently not update.
scrub_write_prom() {
  local out="$1" pool="$2"
  local -n _vals="$3"
  local tmp entry metric key help
  local -a metrics=(
    "fsbackup_scrub_last_run_seconds|last_run|Unix timestamp when the last scrub check finished"
    "fsbackup_scrub_last_success_seconds|last_success|Unix timestamp of the last scrub check that found no problems"
    "fsbackup_scrub_success|success|1 if the last scrub check found no problems, 0 otherwise"
    "fsbackup_scrub_problems|problems|Problems found by the last scrub check (pool/vdev state, error counters, repairs, data errors, scrub failure)"
    "fsbackup_scrub_duration_seconds|duration|Duration of the last scrub check in seconds, including the scrub itself"
    "fsbackup_scrub_scan_errors|scan_errors|Errors reported on the zpool status scan line by the last scrub"
    "fsbackup_scrub_repaired_bytes|repaired_bytes|Bytes repaired by the last scrub (approximate; zpool status rounds it)"
    "fsbackup_scrub_device_errors|device_errors|Sum of READ/WRITE/CKSUM error counters over all vdevs after the last scrub"
    "fsbackup_scrub_data_errors|data_errors|Permanent data errors reported by zpool status after the last scrub"
  )

  tmp="$(mktemp)" || return 1
  for entry in "${metrics[@]}"; do
    IFS='|' read -r metric key help <<<"$entry"
    [[ -n "${_vals[$key]:-}" ]] || continue
    printf '# HELP %s %s\n# TYPE %s gauge\n%s{pool="%s"} %s\n\n' \
      "$metric" "$help" "$metric" "$metric" "$pool" "${_vals[$key]}"
  done >"$tmp"
  chgrp nodeexp_txt "$tmp" 2>/dev/null || true
  chmod 0644 "$tmp"
  mv -fT "$tmp" "$out" || { rm -f "$tmp"; return 1; }
}

# Stop here when sourced (tests); everything below is the actual run.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  return 0
fi

[[ $# -eq 0 ]] || { echo "Usage: $0   (no arguments)" >&2; exit 2; }
[[ "$(id -u)" -eq 0 ]] || { echo "fs-scrub-check.sh must run as root (zpool scrub)" >&2; exit 2; }
export LC_ALL=C   # scrub_parse_status matches zpool's English wording

. /etc/fsbackup/fsbackup.conf
LOG_DIR="${LOG_DIR:-/var/lib/fsbackup/log}"

# --- logging -----------------------------------------------------------------
# Local stand-in for lib/log.sh (#113), same contract:
#   log   <tag> <msg...>   file only
#   event <tag> <msg...>   file + stdout (journald)
#   error <tag> <msg...>   file + stderr (journald), prefixed "ERROR "
# When lib/log.sh lands, replace this block with
#   . "$(dirname "$(readlink -f "$0")")/../lib/log.sh"
#   log_init scrub
# and change the LOG_DIR default above to /var/log/fsbackup.
LOG_FILE="$LOG_DIR/scrub.log"
mkdir -p "$LOG_DIR" 2>/dev/null || true
log()   { local tag="$1"; shift; echo "$(date -Is) [$tag] $*" >>"$LOG_FILE"; }
event() { local tag="$1"; shift; echo "$(date -Is) [$tag] $*" | tee -a "$LOG_FILE"; }
error() { local tag="$1"; shift; echo "$(date -Is) [$tag] ERROR $*" | tee -a "$LOG_FILE" >&2; }
# --- end logging -------------------------------------------------------------

# Keep this after the logging block, including once lib/log.sh is in use.
# This script runs as root, but $LOG_DIR belongs to fsbackup. If root opened a
# path in there, it would follow any symlink fsbackup had planted, so fsbackup
# could make root create or append to any file. A root-owned scrub.log would
# also break rotation: logrotate runs as fsbackup and copytruncate has to
# truncate the file. So one tee, running as fsbackup, does all the file writes,
# and LOG_FILE points at the pipe to it. It starts before the lock is taken so
# it doesn't inherit the lock fd.
LOG_WRITER_PID=""
if id -u fsbackup >/dev/null 2>&1 && command -v setpriv >/dev/null 2>&1; then
  exec 3> >(exec setpriv --reuid=fsbackup --regid=fsbackup --clear-groups -- \
              tee -a "$LOG_FILE" >/dev/null)
  LOG_WRITER_PID=$!
  LOG_FILE=/dev/fd/3
fi
# If the writer dies, writes to it should fail quietly, not kill the run with SIGPIPE.
trap '' PIPE

finish() {
  # Close the pipe and wait for tee, so the last lines reach the file before
  # systemd cleans up the unit's cgroup.
  if [[ -n "$LOG_WRITER_PID" ]]; then
    exec 3>&-
    wait "$LOG_WRITER_PID" 2>/dev/null
  fi
}
trap finish EXIT
trap 'error scrub "interrupted by signal; a running scrub continues in the kernel (zpool status)"; exit 1' INT TERM

NODEEXP_DIR="/var/lib/node_exporter/textfile_collector"
PROM_OUT="${NODEEXP_DIR}/fsbackup_scrub.prom"

# /run, not /run/lock: /run/lock is world-writable, so another user could
# pre-create the lock file and block root from opening it.
LOCK_FILE="/run/fsbackup-scrub.lock"
exec 9>"$LOCK_FILE" || { error scrub "cannot open lock file ${LOCK_FILE}"; exit 2; }
flock -n 9 || { event scrub "another scrub check is already running, exiting"; exit 0; }

# -----------------------------------------------------------------------------
# Pool
# -----------------------------------------------------------------------------
PRIMARY_SNAPSHOT_ROOT="${SNAPSHOT_ROOT:-/backup/snapshots}"
POOL="${ZFS_POOL:-}"
if [[ -z "$POOL" ]]; then
  # zfs list resolves a mounted path to its dataset; fall back to the repo
  # convention (dataset = SNAPSHOT_ROOT without the leading /).
  ds="$(zfs list -H -o name "$PRIMARY_SNAPSHOT_ROOT" 2>/dev/null)" || ds=""
  [[ -n "$ds" ]] || ds="${PRIMARY_SNAPSHOT_ROOT#/}"
  POOL="${ds%%/*}"
fi
if [[ ! "$POOL" =~ ^[A-Za-z][A-Za-z0-9_.:-]*$ ]]; then
  error scrub "invalid pool name '${POOL}' (set ZFS_POOL or SNAPSHOT_ROOT in fsbackup.conf)"
  exit 2
fi

# -----------------------------------------------------------------------------
# Scrub
# -----------------------------------------------------------------------------
START_TS="$(date +%s)"
PROBLEMS=()
declare -A S=()

# scan_activity <pool> — print "<scan_func> <scan_state>" for the pool now
scan_activity() {
  zpool status -p "$1" 2>/dev/null | scrub_parse_status |
    awk -F= '$1 == "scan_func" { f = $2 } $1 == "scan_state" { s = $2 }
             END { print (f == "" ? "unknown" : f), (s == "" ? "unknown" : s) }'
}

event scrub "starting scrub check of pool ${POOL}"

if ! zpool list -H -o name "$POOL" >/dev/null 2>&1; then
  PROBLEMS+=("pool ${POOL} not found (zpool list)")
else
  log "$POOL" "zpool scrub -w ${POOL}"
  out="$(zpool scrub -w "$POOL" 2>&1)"; rc=$?
  if [[ $rc -ne 0 ]]; then
    read -r sfunc sstate < <(scan_activity "$POOL")
    if [[ "$sfunc" == "scrub" && "$sstate" == "in_progress" ]]; then
      event "$POOL" "a scrub started elsewhere is already running; waiting for it and checking its result"
      out="$(zpool wait -t scrub "$POOL" 2>&1)"; rc=$?
    elif [[ "$sfunc" == "resilver" && "$sstate" == "in_progress" ]]; then
      event "$POOL" "resilver in progress; waiting for it to finish, then scrubbing"
      out="$(zpool wait -t resilver "$POOL" 2>&1)" && out="$(zpool scrub -w "$POOL" 2>&1)"; rc=$?
    fi
  fi
  [[ -n "$out" ]] && log "$POOL" "zpool: ${out//$'\n'/ | }"
  [[ $rc -eq 0 ]] || PROBLEMS+=("zpool scrub failed (exit ${rc}): ${out//$'\n'/ }")

  # Full status to the file only
  status_txt="$(zpool status -p "$POOL" 2>&1)"
  log "$POOL" "zpool status -p ${POOL}:"
  while IFS= read -r line; do log "$POOL" "  ${line}"; done <<<"$status_txt"

  while IFS= read -r kv; do
    [[ -n "$kv" ]] || continue
    k="${kv%%=*}"; v="${kv#*=}"
    if [[ "$k" == "problem" ]]; then PROBLEMS+=("$v"); else S["$k"]="$v"; fi
  done < <(printf '%s\n' "$status_txt" | scrub_parse_status)
fi

END_TS="$(date +%s)"
DURATION=$(( END_TS - START_TS ))
NPROB="${#PROBLEMS[@]}"

SUMMARY="state=${S[state]:-?} repaired=${S[repaired]:-?} scan_errors=${S[scan_errors]:-?} device_errors=${S[device_errors]:-?} data_errors=${S[data_errors]:-?} duration=${DURATION}s"
if [[ "$NPROB" -eq 0 ]]; then
  event "$POOL" "OK: ${SUMMARY} (${S[scan]:-})"
else
  error "$POOL" "FAILED: ${NPROB} problem(s): ${SUMMARY}"
  for p in "${PROBLEMS[@]}"; do error "$POOL" "$p"; done
fi

# -----------------------------------------------------------------------------
# Prometheus metrics
# -----------------------------------------------------------------------------
declare -A M=(
  [last_run]="$END_TS"
  [success]="$([[ "$NPROB" -eq 0 ]] && echo 1 || echo 0)"
  [problems]="$NPROB"
  [duration]="$DURATION"
  [scan_errors]="${S[scan_errors]:-}"
  [repaired_bytes]="${S[repaired_bytes]:-}"
  [device_errors]="${S[device_errors]:-}"
  [data_errors]="${S[data_errors]:-}"
)
if [[ "$NPROB" -eq 0 ]]; then
  M[last_success]="$END_TS"
else
  M[last_success]="$(scrub_prom_value "$PROM_OUT" fsbackup_scrub_last_success_seconds "$POOL")"
fi
scrub_write_prom "$PROM_OUT" "$POOL" M || error scrub "failed to write ${PROM_OUT}"

if [[ "$NPROB" -eq 0 ]]; then
  event scrub "scrub check finished: pool=${POOL} result=OK duration=${DURATION}s"
  exit 0
fi
event scrub "scrub check finished: pool=${POOL} result=FAILED problems=${NPROB} duration=${DURATION}s"
exit 1

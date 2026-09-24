# CLAUDE.md — fsbackup

ZFS-native rsync snapshot backup system for a home lab. Runs bare-metal on `fs` (172.30.3.130) as the `fsbackup` system user under systemd. Snapshots are taken over SSH (or locally), stored as ZFS snapshots, and exported to S3 (weekly/monthly/annual). No Docker, no supercronic.

---

## Repo Layout

```
bin/          Core backup scripts (runner, retention, doctor, provision, install, etc.)
conf/         Config templates (targets.yml.example, fsbackup.conf.example, logrotate.fsbackup)
docs/         User-facing documentation
lib/          Shared shell helpers sourced by bin/ and s3/ scripts (log.sh)
remote/       Scripts that run ON remote hosts, not the backup server
s3/           S3 export script
systemd/      Systemd unit and timer files
utils/        Manual/administrative utilities (restore, trust-host, target-rename, etc.)
web/          FastAPI + HTMX web UI
```

---

## Key Paths (Live System)

| Purpose | Path |
|---------|------|
| Installed config | `/etc/fsbackup/fsbackup.conf` |
| Targets file | `/etc/fsbackup/targets.yml` |
| DB export env files | `/etc/fsbackup/db/<name>.env` |
| age public key | `/etc/fsbackup/age.pub` |
| age private key | `/etc/fsbackup/age.key` (**NOT on server in production**) |
| AWS credentials | `/var/lib/fsbackup/.aws/credentials` (profile: `fsbackup`) |
| SSH keys | `/var/lib/fsbackup/.ssh/` (id_ed25519_backup + known_hosts) |
| Primary snapshots | `/backup/snapshots/` |
| DB exports | `/backup/exports/` |
| Logs | `/var/log/fsbackup/` (`LOG_DIR`; fsbackup:fsbackup 0750) |
| Log rotation | `/etc/logrotate.d/fsbackup` (from `conf/logrotate.fsbackup`) |
| Node exporter metrics | `/var/lib/node_exporter/textfile_collector/` |
| Sudoers drop-in | `/etc/sudoers.d/fsbackup-zfs-destroy` |

**ZFS dataset layout:** `backup/snapshots/<class>/<target>`
- e.g. `backup/snapshots/class1/paperlessngx.db`
- ZFS snapshots: `@daily-YYYY-MM-DD`, `@weekly-YYYY-Www`, `@monthly-YYYY-MM`
- Snapshot contents accessible read-only via `.zfs/snapshot/<name>/`

---

## fsbackup.conf Keys

```bash
SNAPSHOT_ROOT="/backup/snapshots"   # ZFS dataset root = strip leading /
LOG_DIR="/var/log/fsbackup"         # log files; default when unset
CLASS1_DAILY_SCHEDULE="*-*-* 01:49:00"
CLASS1_WEEKLY_SCHEDULE="Mon *-*-* 02:00:00"
CLASS1_MONTHLY_SCHEDULE="*-*-01 02:00:00"
KEEP_DAILY=14
KEEP_WEEKLY=8
KEEP_MONTHLY=12
S3_BUCKET="fsbackup-snapshots-SUFFIX"
```

Scripts source this with: `. /etc/fsbackup/fsbackup.conf`, then `LOG_DIR="${LOG_DIR:-/var/log/fsbackup}"`.
The web UI reads `LOG_DIR` by parsing the file as text (`_resolve_log_dir()` in `web/main.py`; env `FSBACKUP_LOG_DIR` overrides), so it must be a literal path.

---

## Data Classes

| Class | Description | Schedule |
|-------|-------------|----------|
| class1 | Application data, personal files, DBs | Daily + weekly + monthly |
| class2 | Infrastructure config (docker stacks, nginx, bind, etc.) | Daily + weekly + monthly |
| class3 | Large archives (photos, video libraries, etc.) | Monthly only |

---

## Script Roles

| Script | Location | Called From |
|--------|----------|-------------|
| `fs-runner.sh` | `bin/` | systemd timer (`fsbackup-runner-daily@<class>`, etc.) |
| `fs-retention.sh` | `bin/` | systemd timer (`fsbackup-retention.timer`) |
| `fs-provision.sh` | `bin/` | manual (create ZFS datasets from targets.yml) |
| `fs-doctor.sh` | `bin/` | systemd timer (`fsbackup-doctor@<class>.timer`) |
| `fs-install.sh` | `bin/` | manual (bare-metal installer; run as root) |
| `fs-schedule-apply.sh` | `bin/` | manual + installer (writes systemd OnCalendar= drop-ins) |
| `fs-schedule-set.sh` | `bin/` | manual + web UI (Configuration > Schedule): set one `CLASS*_SCHEDULE`, then apply |
| `fs-db-export.sh` | `bin/` | systemd timer (`fs-db-export@<name>.timer`); runs as root |
| `fs-logrotate-metric.sh` | `bin/` | systemd timer (`fsbackup-logrotate-metric.timer`, hourly); runs as fsbackup. Stale = non-empty log whose first entry is > 2 days old |
| `fs-scrub-check.sh` | `bin/` | systemd timer (`fsbackup-scrub.timer`); runs as root. `zpool scrub -w`, then fails on any `zpool status` problem |
| `fs-restore.sh` | `utils/` | manual only |
| `fs-trust-host.sh` | `utils/` | manual only |
| `fs-target-rename.sh` | `utils/` | manual + web UI (Configuration > Targets > Rename) |
| `fs-export-s3.sh` | `s3/` | systemd timer (`fsbackup-s3-export.timer`) |
| `fsbackup_remote_init.sh` | `remote/` | run ON remote host to set up backup user |

---

## Systemd Units

Parameterized by class instance (e.g. `@class1`):

| Unit | Purpose |
|------|---------|
| `fsbackup-runner-daily@.timer` | Daily rsync + ZFS snapshot |
| `fsbackup-runner-weekly@.timer` | Weekly rsync + ZFS snapshot |
| `fsbackup-runner-monthly@.timer` | Monthly rsync + ZFS snapshot |
| `fsbackup-doctor@.timer` | SSH/path health check + orphan scan |
| `fsbackup-retention.timer` | Prune old ZFS snapshots |
| `fsbackup-s3-export.timer` | Encrypt + upload to S3 |
| `fsbackup-scrub.timer` | Monthly ZFS scrub + health check (`fs-scrub-check.sh`, 5th 03:00) |
| `fsbackup-logrotate-metric.timer` | Hourly: `fs-logrotate-metric.sh` (as fsbackup) checks log rotation, writes `fsbackup_logrotate.prom` |
| `fsbackup-web.service` | FastAPI web UI (no timer; persistent) |
| `fs-db-export@.timer` | DB export; instance = env filename in /etc/fsbackup/db/ |

---

## Logging

All log files live in `LOG_DIR` (default `/var/log/fsbackup/`):
`backup-<class>.log` (runner, all types), `retention.log`, `s3-export.log`, `doctor-<class>.log`,
`fs-orphans.log` (orphan events, all classes), `scrub.log` (monthly ZFS scrub, full `zpool status`).

| Destination | Content |
|---|---|
| journald (stdout/stderr) | Run start/end, one line per target result, final summary, all errors/warnings |
| `$LOG_DIR/*.log` | Everything above plus detail: rsync stats, snapshot names, provision output, retention keep/destroy, per-object S3 |

The doctor prints its report to stdout (journald) and also writes it to `doctor-<class>.log`.
Line format everywhere: `<date -Is> [<tag>] <msg>`; errors carry `ERROR `.
Rotation: `/etc/logrotate.d/fsbackup` — daily, 30 kept, `copytruncate`, `dateext` → `<name>.log-YYYYMMDD`, older ones `.gz`.
Units set `SyslogIdentifier=fsbackup-<job>` (templated: `fsbackup-runner-<class>`, `fsbackup-doctor-<class>`).
The fsbackup-user job units have `LogsDirectory=fsbackup` + `LogsDirectoryMode=0750`; never add that to a `User=root` unit (systemd would chown the dir to root).
Root-run scripts (e.g. `fs-scrub-check.sh`): when `EUID` is 0, `lib/log.sh` does every file write (and its `mkdir`) as fsbackup via `setpriv`,
because fsbackup owns `LOG_DIR` and could plant a symlink (`scrub.log -> /etc/shadow`) that a root `>>` or `chown` would follow, or a FIFO that a normal open would block on (hence `dd oflag=nonblock` in root mode, and a regular-file check otherwise).
So root code must never open, create or `chown` anything in `LOG_DIR` itself; just use the helpers. New files stay fsbackup-owned, so logrotate can rotate them.
The web log viewer (`/api/journal/<unit>`) reads the current file + newest uncompressed rotated file, and falls back to `journalctl -u` when a unit has no file yet.
Both Logs tabs open files in `LOG_DIR` only through `_log_fd_open()` (`O_NOFOLLOW` + `O_NONBLOCK`, regular files only); don't add a plain `open()`/`read_text()` of a log path.

---

## Privilege Model

The `fsbackup` user runs most services. Exceptions:
- `fs-db-export@.service`: `User=root` (needs `docker exec`)
- `fsbackup-scrub.service`: `User=root` (`zpool scrub` has no delegation). Lock is `/run/fsbackup-scrub.lock` (0600: flock works on a read-only fd, so a readable lock file would let any user make the scrub skip itself), not `/run/lock`, which is world-writable. The unit has `TimeoutStartSec=2d`, so a hung check fails instead of staying active.
- Orphan dataset deletion in web UI: `sudo zfs destroy -r <dataset>` — allowed via `/etc/sudoers.d/fsbackup-zfs-destroy` (NOPASSWD, scoped to `SNAPSHOT_ROOT/*/*`). Created automatically by `fs-install.sh`.
- Runner auto-provisioning: `sudo fs-provision.sh` — `/etc/sudoers.d/fsbackup-provision`.
- Web UI rename target: `sudo fs-target-rename.sh …` — `/etc/sudoers.d/fsbackup-target-rename`.
- Web UI schedule edits: `sudo fs-schedule-set.sh <KEY> <OnCalendar>` — `/etc/sudoers.d/fsbackup-schedule`. `fsbackup.conf` is sourced as root, so the script validates key + value itself.

---

## Coding Conventions

- All scripts: `#!/usr/bin/env bash` + `set -u` + `set -o pipefail` (no `set -e` — errors handled per-iteration)
- Source config at top: `. /etc/fsbackup/fsbackup.conf`, then `LOG_DIR="${LOG_DIR:-/var/log/fsbackup}"`
- Logging: source `lib/log.sh` (`. "$(dirname "$(readlink -f "$0")")/../lib/log.sh"`), call `log_init <basename>`, then
  `log <tag> msg` (file only: detail), `event <tag> msg` (file + stdout: start/end, per-target result, summary),
  `error <tag> msg` (file + stderr, prefixed `ERROR `: errors and warnings), `cmd 2>&1 | log_stream <tag>` (command output to file).
  Never `>>"$LOG_FILE"` directly — the helpers keep the job running if LOG_DIR is unwritable, and drop to fsbackup for the write when run as root.
- Prometheus metrics: write `.prom` files to node exporter textfile dir, then `mv` atomically
- Prom file permissions: `chgrp nodeexp_txt ... 2>/dev/null || true` + `chmod 0644`
- AWS CLI calls use `--profile fsbackup`

---

## Web UI (`web/`)

FastAPI + HTMX + Tailwind CDN. `fsbackup-web.service` on `0.0.0.0:8080`.

- `web/.env`: `HOST`, `PORT`, `AUTH_ENABLED`, `AUTH_PASSWORD_HASH` (bcrypt)
- Auth: bcrypt password hash; `/static/` exempt

### Pages

| Route | Description |
|-------|-------------|
| `/` | Dashboard — class status cards |
| `/snapshots` | Filterable snapshot browser; orphan rows highlighted red with inline delete |
| `/logs` | Live tab: log viewer (per-job sections) + Prometheus metrics table. History tab (`?tab=history`): rotated logs in `LOG_DIR` by date per source; `.gz` read in memory, allow-listed source + date only (#115) |
| `/restore` | Restore files from a snapshot |
| `/run` | Trigger runner/doctor per class; retention (preview/prune) and S3 export |
| `/s3` | S3 offsite bucket browser |
| `/configuration` | Tabbed config: Hosts, Targets, Schedule, Volumes & Maintenance |
| `/browse` | Filesystem browser inside a snapshot |

---

## Git / Deployment

- Working repo: `/home/crash/projects/fsbackup` (owned `crash:crash`)
- Installed at: `/opt/fsbackup/` — must **not** be writable by `fsbackup` (it has NOPASSWD sudo on scripts there). Installer sets `root:root`; on `fs` it's `crash:crash` via the rsync deploy — both fine.
- `/etc/fsbackup` has `u:fsbackup:rwx` (web targets.yml editor) **plus the sticky bit** so fsbackup can't replace root-owned `fsbackup.conf`, which root-run scripts source (#105).
- Remote: `git@github.com:fsbackup/fsbackup.git`
- **main is branch-protected** — always branch + PR
- Deploy: `sudo rsync -a --delete --exclude='.git' --exclude='.claude' --exclude='web/.venv' --exclude='web/.env' --exclude='conf/targets.yml' /home/crash/projects/fsbackup/ /opt/fsbackup/`
  (`.claude` holds agent worktrees with other branches' unreviewed code; it must never reach `/opt`.)
- Verify a deploy: `diff -rq -x .git -x .claude -x .venv -x .env -x targets.yml -x __pycache__ /home/crash/projects/fsbackup /opt/fsbackup`
- `conf/targets.yml` is gitignored — never commit it
- Current release: **v2.2.0**

## Known Issues / Open Work

- `grafana.data` rsync fails nightly with exit 24 (`grafana.db-journal` vanishes mid-transfer). Fix: add `--exclude=grafana.db-journal` to target rsync_opts.
- Stale broken symlinks in `/etc/systemd/system/timers.target.wants/` for old v1.x units — harmless, can be cleaned up with `find /etc/systemd/system -xtype l -delete`.
- `#52` — parallel doctor runs, race on shared prom files (low priority)
- `#66` — TrueNAS SCALE support (backburner)

# Operations

Day-to-day management: checking health, running jobs manually, managing orphan datasets,
and troubleshooting.

fsbackup runs bare-metal as the `fsbackup` user under systemd. Manual commands are run
with `sudo -u fsbackup`. Most of these actions are also available in the web UI — see
[web/README.md](../web/README.md).

---

## Checking system health

### Doctor

The doctor checks SSH reachability and source-path existence for all targets in a class,
and flags orphan datasets and targets with no provisioned dataset.

```bash
sudo -u fsbackup /opt/fsbackup/bin/fs-doctor.sh --class class1
sudo -u fsbackup /opt/fsbackup/bin/fs-doctor.sh --class class2
sudo -u fsbackup /opt/fsbackup/bin/fs-doctor.sh --class class3
```

Output:

```
fsbackup doctor
  Class:  class2

TARGET                       STAT   DETAIL
---------------------------- ------ ------------------------------
apache.config                OK     local path exists
rp.nginx.config              OK     ssh+path OK
weewx.config                 OK     ssh+path OK

Doctor summary
  OK:    3
  WARN:  0
  FAIL:  0

2026-09-23T02:05:03-06:00 [doctor] Doctor complete: class=class2 ok=3 warn=0 fail=0 missing_datasets=0 orphans=0 duration=1.2s
```

The same report is written, timestamped, to `/var/log/fsbackup/doctor-<class>.log`,
so past runs rotate with the other logs.

Any `FAIL` must be resolved before the runner will succeed for that target. A `WARN`
for a missing dataset clears itself once the target is provisioned (see below).

The report ends with a pool-level **ZFS scrub** line, read from the metrics that
`fs-scrub-check.sh` writes. It warns if the last scrub check failed, or if the last clean
scrub is more than `SCRUB_MAX_AGE_DAYS` (default 35) days old:

```
ZFS scrub
backup                       OK     last clean scrub 2026-10-05 (3 days ago)
```

This line is informational: it isn't counted in the target summary. See
[ZFS scrub](#zfs-scrub) below.

### Logs

Each job logs to two places:

| Where | What |
|---|---|
| **journald** (`journalctl -u <unit>`) | Run start and end, one line per target (ok/failed, duration, bytes), the final summary, and every error or warning |
| **Log files** in `LOG_DIR` (default `/var/log/fsbackup/`) | All of the above plus the detail: rsync `--stats`, snapshot names, provisioning output, retention keep/destroy decisions, per-object S3 uploads |

Every line has the same format, `<date -Is> [<tag>] <message>`, where the tag is the
target id or the job name. Errors are prefixed `ERROR`.

```bash
tail -f /var/log/fsbackup/backup-class1.log   # runner — class1 (daily/weekly/monthly)
tail -f /var/log/fsbackup/backup-class2.log   # runner — class2
tail -f /var/log/fsbackup/retention.log       # retention
tail -f /var/log/fsbackup/s3-export.log       # S3 export
cat     /var/log/fsbackup/doctor-class1.log   # doctor report — class1
cat     /var/log/fsbackup/fs-orphans.log      # doctor orphan scan (all classes)
cat     /var/log/fsbackup/scrub.log           # monthly ZFS scrub (full zpool status)
```

The directory is `LOG_DIR` in `fsbackup.conf`. It must be owned by `fsbackup:fsbackup`
(mode 0750); the job units also create `/var/log/fsbackup` with that ownership if it
is missing (`LogsDirectory=`). If a job can't write its log file it still runs, still
logs to the journal, and prints one `WARN cannot write …` line. A job that runs as root
(the ZFS scrub, or a script started with plain `sudo`) writes its log file as `fsbackup`
(through `setpriv`), so every file in the directory stays `fsbackup`-owned.

logrotate (`/etc/logrotate.d/fsbackup`, from `conf/logrotate.fsbackup`) rotates the
files daily and keeps 30: `backup-class1.log-20260922` is yesterday's file, and older
ones are compressed (`backup-class1.log-20260921.gz`). To read an older day:

```bash
zless /var/log/fsbackup/backup-class1.log-20260915.gz
sudo logrotate -d /etc/logrotate.d/fsbackup   # check the rotation config
```

Each unit sets a `SyslogIdentifier`, so the journal can also be filtered by job:
`journalctl -t fsbackup-runner-class1` shows every runner type for class1.

### Timer status

```bash
# See when each fsbackup timer last ran and next fires
systemctl list-timers 'fsbackup-*'

# Follow a specific unit's journal
journalctl -u fsbackup-runner-daily@class1.service -f
```

---

## Running jobs manually

### Dry-run a snapshot (safe, no changes)

```bash
sudo -u fsbackup /opt/fsbackup/bin/fs-runner.sh daily --class class1 --dry-run
```

### Run a snapshot for real

```bash
sudo -u fsbackup /opt/fsbackup/bin/fs-runner.sh daily --class class1
```

Snapshot type is the first argument (`daily`, `weekly`, or `monthly`) and becomes the
snapshot-name prefix.

### Run a single target only

```bash
sudo -u fsbackup /opt/fsbackup/bin/fs-runner.sh daily --class class1 --target mosquitto.data
```

With `--target`, the Prometheus metrics for other targets are carried forward from the
previous run so the dashboard stays intact, and `fsbackup_runner_run_scope{class}` is set
to 0 to mark the partial run.

### Run retention manually

```bash
sudo -u fsbackup /opt/fsbackup/bin/fs-retention.sh --dry-run
sudo -u fsbackup /opt/fsbackup/bin/fs-retention.sh
```

### Run the S3 export manually

```bash
sudo -u fsbackup /opt/fsbackup/s3/fs-export-s3.sh
```

Idempotent — it uploads any weekly/monthly snapshots not already in the bucket.

### Run a ZFS scrub check manually

The scrub runs as root and blocks until the scrub has finished (about an hour on `fs`),
so start it without waiting and follow the journal:

```bash
sudo systemctl start --no-block fsbackup-scrub.service
journalctl -fu fsbackup-scrub.service
```

See [ZFS scrub](#zfs-scrub) for what it checks.

### Trigger a job through systemd

Starting the service (rather than the timer) runs it immediately:

```bash
sudo systemctl start fsbackup-runner-daily@class1.service
sudo systemctl start fsbackup-retention.service
```

---

## Orphan datasets

An orphan is a ZFS dataset for a target that no longer exists in `targets.yml` — usually
left behind after removing a target.

### Detecting orphans

The doctor detects orphans on every run and:
- appends entries to `/var/log/fsbackup/fs-orphans.log`, and
- writes `fsbackup_orphan_snapshots_total` (alert if > 0).

```bash
cat /var/log/fsbackup/fs-orphans.log
```

### Removing orphans

**Web UI (recommended)**: the Snapshots page highlights orphan rows in red with a ⚠
badge and provides an orphan-only filter with bulk-select and a "Delete datasets" action.
Deletion runs `sudo zfs destroy -r` under the scoped sudoers drop-in.

**Command line**: destroy the dataset (and its snapshots) directly. The dataset name is
the filesystem path with the leading `/` stripped:

```bash
# Inspect first
zfs list -r backup/snapshots/<class>/<target>

# Destroy the dataset and all its snapshots
sudo zfs destroy -r backup/snapshots/<class>/<target>
```

Run the doctor again afterward to confirm the orphan count drops to zero.

---

## ZFS scrub

`fsbackup-scrub.timer` runs `fs-scrub-check.sh` as root on the 5th of each month at
03:00. It scrubs the backup pool (`ZFS_POOL` in `fsbackup.conf`, default: the pool that
holds `SNAPSHOT_ROOT`, i.e. `backup`) with `zpool scrub -w`. Once the scrub has finished
it checks `zpool status -p` and **fails the unit** if any of these is true:

- the pool state isn't `ONLINE`, or any vdev isn't `ONLINE`
- any vdev has a non-zero `READ`, `WRITE` or `CKSUM` counter
- the scrub repaired data or reported errors, or didn't complete (canceled, paused)
- the `errors:` line is anything other than `No known data errors`

If a scrub is already running when the job starts (for example the one Ubuntu's
`zfsutils-linux` cron job starts on the second Sunday of the month), the job waits for it
and checks its result instead of starting another. If a resilver is running, the job waits
for it to finish, then scrubs.

Only one check runs at a time (lock: `/run/fsbackup-scrub.lock`, root-only). A second one
started meanwhile logs `ERROR another scrub check is already running …` and exits 0
without checking. The unit has a two-day start timeout (`TimeoutStartSec=2d`): a check
that hangs is stopped and the unit fails with `Result=timeout`. The scrub itself carries on
in the kernel (`zpool status backup`), and the next run waits for it.

Output:

- journald (`journalctl -u fsbackup-scrub`): the start line, one result line for the pool,
  a summary line, and one `ERROR` line per problem
- `/var/lib/fsbackup/log/scrub.log` (`$LOG_DIR/scrub.log`): the same lines, plus the full
  `zpool status -p` output. The job runs as root but writes this file as `fsbackup`, so it
  stays fsbackup-owned. If the log directory is missing and `fsbackup` can't create it,
  the journal gets one `[log] WARN cannot write …` line and the check still runs.
- `fsbackup_scrub.prom`: `fsbackup_scrub_success{pool}`,
  `fsbackup_scrub_last_success_seconds{pool}`, `fsbackup_scrub_problems{pool}` and more
  (see [reference.md](reference.md#prometheus-metrics)). Alert on
  `fsbackup_scrub_success == 0` or on `time() - fsbackup_scrub_last_success_seconds > 35*86400`.

```bash
cat /var/lib/node_exporter/textfile_collector/fsbackup_scrub.prom
```

### When the scrub check fails

```bash
journalctl -u fsbackup-scrub.service -n 50    # which checks failed
sudo zpool status -v backup                   # device states, counters, damaged files (-v needs root)
```

- **Repaired bytes or `CKSUM` errors on one disk, pool still `ONLINE`**: redundancy fixed
  the data, but that disk returned bad data. Check its SMART data and cabling
  (`sudo smartctl -a /dev/sdX`).
- **`DEGRADED` / `UNAVAIL` / `FAULTED`**: a disk has dropped out. Replace it with
  `zpool replace`.
- **Permanent data errors**: the pool couldn't repair some blocks. `sudo zpool status -v`
  lists the affected files and snapshots, and the `see:` link in its output describes
  recovery. Get good copies from the source host or from S3.

The vdev error counters stay in `zpool status` through later scrubs until they're
cleared, so the check keeps failing until then. (The repaired amount is replaced by the
next scrub's.) Once the cause is dealt with, clear the counters and re-run the check:

```bash
sudo zpool clear backup
sudo systemctl start --no-block fsbackup-scrub.service
```

> **Two scrubs a month.** Ubuntu's `zfsutils-linux` package also scrubs every pool on the
> second Sunday of the month (`/etc/cron.d/zfsutils-linux`). The fsbackup check doesn't
> depend on it. To keep only the fsbackup scrub, turn Ubuntu's off for this pool:
> `sudo zfs set org.debian:periodic-scrub=disable backup`.

---

## Provisioning datasets

Datasets for newly added targets are created automatically at the start of the next
runner run (`fs-provision.sh` via the `fsbackup-provision` sudoers drop-in). To provision
immediately instead of waiting:

```bash
sudo /opt/fsbackup/bin/fs-provision.sh
```

---

## Re-running after a failure

If a target fails mid-run, the next scheduled run retries it; the failure count is tracked
in `fsbackup_runner_target_failures_total`. To retry a single target immediately:

```bash
sudo -u fsbackup /opt/fsbackup/bin/fs-runner.sh daily --class class1 --target <id>
```

---

## Troubleshooting

### Exit code 255 in Prometheus metrics

`fsbackup_runner_target_last_exit_code{target="..."} 255` means rsync received exit code
255, an **SSH connection failure** — rsync never started on the remote host. This is a
connectivity problem, not a backup-data error.

Common causes:

- **Network unreachable** — the backup server cannot route to the target host. Check with
  `ip route get <host-ip>`. If the result shows `broadcast ... cache <local,brd>`, that is
  the kernel FIB routing bug (see below).
- **SSH host key mismatch** — the target host was rebuilt. Re-trust the key:
  ```bash
  sudo -u fsbackup ssh-keygen -R <hostname> -f /var/lib/fsbackup/.ssh/known_hosts
  sudo /opt/fsbackup/utils/fs-trust-host.sh <hostname>
  ```
- **SSH auth failure** — the `backup` user on the remote host is missing the authorized
  key. Re-run `fsbackup_remote_init.sh` on the remote host.
- **Source host down** — unreachable for unrelated reasons; doctor shows `FAIL ssh unreachable`.

To distinguish the cause, connect manually as the fsbackup user:

```bash
sudo -u fsbackup ssh backup@<hostname> echo ok
```

---

### Network unreachable (Linux FIB routing bug)

On this host (`fs`, 172.30.3.130/28, DAT VLAN), a Linux 6.8 kernel bug intermittently
classifies route lookups for cross-VLAN destinations as `RTN_BROADCAST`, causing TCP
`connect()` to fail with `ENETUNREACH`. It manifests as scattered rsync exit-code-255
failures across targets on the CORE, APP, or DMZ VLANs.

**This is a host networking issue, not an fsbackup bug.**

Diagnosis:

```bash
ip route get 172.30.3.10
# Healthy:  172.30.3.10 via 172.30.3.129 dev enp2s0f0 ...
# Affected: broadcast 172.30.3.10 via ... cache <local,brd>
```

**Fix:** explicit per-VLAN static routes in `/etc/netplan/00-enp2s0f-config.yaml` so the
kernel resolves cross-VLAN destinations from a real FIB entry instead of a cached
exception:

```
172.30.3.0/26   via 172.30.3.129   # CORE VLAN
172.30.3.64/26  via 172.30.3.129   # APP VLAN
172.30.3.248/29 via 172.30.3.129   # DMZ VLAN
```

Verify after a reboot or netplan change:

```bash
ip route show | grep 172.30.3
```

Also ensure `accept_redirects=0` is set (see `/etc/sysctl.d/99-routing.conf`) and that
RIP/OSPF are disabled on the DAT VLAN interface on the SonicWALL.

---

### Permission denied on local source paths

Local targets (`host: fs`) run rsync as the `fsbackup` user on the local filesystem. If
files under the source path are not readable by that user (e.g. mode `600`/`700`), rsync
fails with `Permission denied` and exit code 23.

Fix: grant the `fsbackup` user read access via ACL, recursively, plus a default ACL for
future files:

```bash
sudo setfacl -R -m u:fsbackup:rX /path/to/source
sudo setfacl -R -m d:u:fsbackup:rX /path/to/source
```

> Note: a file created mode `0600` clamps the ACL mask, which can defeat a `u:fsbackup`
> grant on that specific file. If a particular file keeps failing, exclude it in the
> target's `rsync_opts` or widen the mask with `setfacl -R -m mask::r-x`.

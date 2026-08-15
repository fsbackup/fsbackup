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
```

Any `FAIL` must be resolved before the runner will succeed for that target. A `WARN`
for a missing dataset clears itself once the target is provisioned (see below).

### Logs

Runner logs are per class; other jobs have their own files under
`/var/lib/fsbackup/log/`:

```bash
tail -f /var/lib/fsbackup/log/backup-class1.log   # runner — class1
tail -f /var/lib/fsbackup/log/backup-class2.log   # runner — class2
tail -f /var/lib/fsbackup/log/retention.log       # retention
tail -f /var/lib/fsbackup/log/s3-export.log       # S3 export
cat     /var/lib/fsbackup/log/fs-orphans.log      # doctor orphan scan
```

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
- appends entries to `/var/lib/fsbackup/log/fs-orphans.log`, and
- writes `fsbackup_orphan_snapshots_total` (alert if > 0).

```bash
cat /var/lib/fsbackup/log/fs-orphans.log
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

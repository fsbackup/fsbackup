# Operations

Day-to-day management: checking health, running jobs manually, managing orphans, and
verifying the mirror.

All scripts run inside the Docker container. The examples below use `docker exec`. Replace `fsbackup` with your container name if different.

---

## Checking system health

### Doctor

The doctor checks SSH reachability and source path existence for all targets in a class.
It also scans for orphaned snapshots and verifies annual snapshot immutability.

```bash
docker exec -it fsbackup /opt/fsbackup/bin/fs-doctor.sh --class class1
docker exec -it fsbackup /opt/fsbackup/bin/fs-doctor.sh --class class2
docker exec -it fsbackup /opt/fsbackup/bin/fs-doctor.sh --class class3
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

Any `FAIL` must be resolved before the runner will succeed for that target.

### Logs

```bash
# Main backup log (runner + promote + retention all write here)
tail -f /var/lib/fsbackup/log/backup.log

# Mirror log
tail -f /var/lib/fsbackup/log/mirror.log

# Annual promote log
tail -f /var/lib/fsbackup/log/annual-promote.log

# Orphan log (appended by doctor)
cat /var/lib/fsbackup/log/fs-orphans.log
```

### Container and scheduler status

```bash
# Check container is running
docker ps | grep fsbackup

# Follow all output from the container (supercronic + uvicorn)
docker logs -f fsbackup

# Check supercronic job output
docker exec -it fsbackup tail -f /var/lib/fsbackup/log/backup.log
```

---

## Running jobs manually

### Dry-run a snapshot (safe, no changes)

```bash
docker exec -it fsbackup /opt/fsbackup/bin/fs-runner.sh daily --class class1 --dry-run
```

### Run a snapshot for real

```bash
docker exec -it fsbackup /opt/fsbackup/bin/fs-runner.sh daily --class class1
```

### Run a single target only

```bash
docker exec -it fsbackup /opt/fsbackup/bin/fs-runner.sh daily --class class1 --target mosquitto.data
```

When `--target` is used, the Prometheus metrics file is updated only for that target.
All other targets' metrics are carried forward from the previous run, so the dashboard
stays intact. The class-level success/failure counters are not updated on partial runs.

### Replace an existing snapshot (re-sync over it)

By default the runner uses `--ignore-existing` to avoid re-transferring unchanged data.
To force a full re-sync of an existing snapshot:

```bash
docker exec -it fsbackup /opt/fsbackup/bin/fs-runner.sh daily --class class1 \
  --target mosquitto.data --replace-existing
```

### Run promotion manually

```bash
docker exec -it fsbackup /opt/fsbackup/bin/fs-promote.sh
```

Promotion only acts on `DOW=1` (Monday) for weekly and `DOM=01` for monthly. To test
outside those days the script will run but skip promotion — check the log.

### Run annual promotion manually

```bash
docker exec -it fsbackup /opt/fsbackup/bin/fs-annual-promote.sh --dry-run
docker exec -it fsbackup /opt/fsbackup/bin/fs-annual-promote.sh
# or for a specific year:
docker exec -it fsbackup /opt/fsbackup/bin/fs-annual-promote.sh --year 2025
```

### Run retention manually

```bash
docker exec -it fsbackup /opt/fsbackup/bin/fs-retention.sh
docker exec -it fsbackup /opt/fsbackup/bin/fs-mirror-retention.sh
```

### Run mirror manually

```bash
docker exec -it fsbackup /opt/fsbackup/bin/fs-mirror.sh daily
docker exec -it fsbackup /opt/fsbackup/bin/fs-mirror.sh promote
```

---

## Orphan snapshots

An orphan is a snapshot directory for a target that no longer exists in `targets.yml`.
This happens after removing a target.

### Detecting orphans

The doctor detects orphans on every run and:
- Appends entries to `/var/lib/fsbackup/log/fs-orphans.log`
- Writes a Prometheus metric: `fsbackup_orphan_snapshots_total{root="primary|mirror"}`

View current orphans:

```bash
cat /var/lib/fsbackup/log/fs-orphans.log
```

Each line shows: `root= tier= date= class= orphan=<target-id>`

### Removing orphans

Orphans are never removed automatically. To remove them manually:

```bash
# Inspect first
sudo find /backup/snapshots -type d -name "<target-id>"

# Remove from primary
sudo find /backup/snapshots -type d -name "<target-id>" -exec rm -rf {} +

# Remove from mirror
sudo find /backup2/snapshots -type d -name "<target-id>" -exec rm -rf {} +
```

After removal, run the doctor again to confirm the orphan count drops to zero.

---

## Mirror health

### Check mirror metrics

If using Prometheus/Grafana, check:
- `fsbackup_mirror_last_exit_code{mode="daily"}` — 0 = success
- `fsbackup_mirror_last_exit_code{mode="promote"}` — 0 = success
- `fsbackup_mirror_last_success` — timestamp of last successful run

### Check mirror log

```bash
tail -100 /var/lib/fsbackup/log/mirror.log
```

### Verify mirror contents

```bash
# Compare primary vs mirror for a specific date/class
diff -rq \
  /backup/snapshots/daily/$(date +%F)/class1 \
  /backup2/snapshots/daily/$(date +%F)/class1
```

### Manual mirror check for annual snapshots

```bash
docker exec -it fsbackup /opt/fsbackup/utils/fs-annual-mirror-check.sh
```

---

## Annual snapshot immutability

Annual snapshots are made read-only after creation (`chmod -R u-w`). The doctor verifies
this on every run and writes `fsbackup_annual_immutable{root="primary|mirror"}`.

If an annual snapshot is accidentally made writable, the doctor will log it to
`/var/lib/fsbackup/log/fs-immutable.log`.

To re-lock:

```bash
sudo chmod -R u-w /backup/snapshots/annual
sudo chmod -R u-w /backup2/snapshots/annual
```

---

## Re-running after a failure

If a target fails mid-run, the next scheduled run will retry it. The failure counter is
tracked in the Prometheus metric `fsbackup_runner_target_failures_total`.

To re-run immediately for a specific target:

```bash
docker exec -it fsbackup /opt/fsbackup/bin/fs-runner.sh daily --class class1 --target <id>
```

---

## Troubleshooting

### Exit code 255 in Prometheus metrics

`fsbackup_runner_target_last_exit_code{target="..."} 255` means rsync received exit code
255, which is a **SSH connection failure** — rsync never got started on the remote host.
This is not a backup data error; it is a connectivity problem between the backup server
and the source host.

Common causes:

- **Network unreachable** — the backup server cannot route to the target host. Check
  routing with `ip route get <host-ip>`. If the result shows `broadcast ... cache <local,brd>`
  that is a kernel FIB routing bug (see below).
- **SSH host key mismatch** — the target host was rebuilt. Re-trust the key:
  ```bash
  ssh-keygen -R <hostname> -f /var/lib/fsbackup/.ssh/known_hosts
  docker exec -it fsbackup /opt/fsbackup/utils/fs-trust-host.sh <hostname>
  ```
- **SSH auth failure** — the `backup` user on the remote host does not have the correct
  authorized key. Re-run `fsbackup_remote_init.sh` on the remote host.
- **Source host is down** — the host is unreachable for unrelated reasons. Doctor will
  show `FAIL  ssh unreachable`.

To distinguish the cause, run SSH manually as the fsbackup user:

```bash
sudo -u fsbackup ssh backup@<hostname> echo ok
```

---

### Network unreachable (Linux FIB routing bug)

On this host (`fs`, 172.30.3.130/28, DAT VLAN), a Linux 6.8 kernel bug intermittently
classifies route lookups for cross-VLAN destinations as `RTN_BROADCAST`, causing TCP
`connect()` to fail with `ENETUNREACH`. This manifests as rsync exit code 255 for any
target on the CORE, APP, or DMZ VLANs.

**This is not a backup system bug.** It is a host networking issue.

Symptoms: scattered 255 failures across multiple targets in the same run, particularly
targets on different VLANs (denhpsvr1 .10, denhpsvr2 .70, ns1 .53, ns2 .54).

Diagnosis:

```bash
ip route get 172.30.3.10
# Healthy:  172.30.3.10 via 172.30.3.129 dev enp2s0f0 ...
# Affected: broadcast 172.30.3.10 via ... cache <local,brd>
```

**Fix:** Explicit per-VLAN static routes in `/etc/netplan/00-enp2s0f-config.yaml` ensure
the kernel resolves cross-VLAN destinations from a real FIB entry rather than creating
a cached exception that triggers the bug. Current routes configured:

```
172.30.3.0/26   via 172.30.3.129   # CORE VLAN
172.30.3.64/26  via 172.30.3.129   # APP VLAN
172.30.3.248/29 via 172.30.3.129   # DMZ VLAN
```

If the bug recurs after a reboot or netplan change, verify these routes are present:

```bash
ip route show | grep 172.30.3
```

Also ensure `accept_redirects=0` is set (see `/etc/sysctl.d/99-routing.conf`) and that
RIP/OSPF are disabled on the DAT VLAN interface on the SonicWALL.

---

### Permission denied on local source paths

Local targets (`host: fs`) run rsync as the `fsbackup` user on the local filesystem.
If files or directories under the source path are not world-readable (e.g. mode `600`
or `700`), rsync will fail with `Permission denied` and exit code 23.

Fix: grant the `fsbackup` user read access via ACL, recursively:

```bash
sudo setfacl -R -m u:fsbackup:rX /path/to/source
sudo setfacl -R -m d:u:fsbackup:rX /path/to/source   # default ACL for new files
```

The `d:` default ACL ensures future files created in that tree are automatically
readable by the backup user without needing to re-run setfacl.

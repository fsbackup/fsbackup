# Reference

Classes, snapshot layout, retention, offsite strategy, timers, metrics, and web UI
security.

---

## Data classes

Targets are organized into classes. Each class has its own backup schedule, retention
policy, and offsite strategy.

### class1 — Application data

Frequently changing data: app volumes, databases, personal files.

- **Schedule**: daily ~01:45, weekly Sat ~02:00, monthly 1st ~03:00
- **Snapshot types**: daily, weekly, monthly
- **Offsite**: S3 — weekly + monthly uploaded nightly via `fsbackup-s3-export.timer`

### class2 — Infrastructure config

Slowly changing config: docker stacks, nginx, bind, etc.

- **Schedule**: daily ~02:15, weekly Sat ~02:30
- **Snapshot types**: daily, weekly (monthly disabled — `CLASS2_MONTHLY_SCHEDULE` commented out in `fsbackup.conf`)
- **Offsite**: S3 — weekly uploaded nightly

### class3 — Large archives

Large, infrequently changing data: photo libraries, raw camera files.

- **Schedule**: monthly (1st of each month ~04:00)
- **Snapshot types**: monthly only
- **Offsite**: excluded from S3 by default (`S3_SKIP_CLASSES=class3`); manual USB / M-DISC

---

## Snapshot layout

fsbackup v2 uses ZFS-native snapshots. Each target has a dedicated ZFS dataset; snapshots
are named with a type prefix and a date stamp. There are no dated tier directories.

**ZFS dataset path**: `backup/snapshots/<class>/<target>`

**Snapshot names**:

| Type | Format | Example |
|---|---|---|
| daily | `@daily-YYYY-MM-DD` | `@daily-2026-04-11` |
| weekly | `@weekly-YYYY-Www` (ISO week) | `@weekly-2026-W15` |
| monthly | `@monthly-YYYY-MM` | `@monthly-2026-04` |

**Filesystem access** (read-only via the `.zfs` automount):

```
/backup/snapshots/<class>/<target>/.zfs/snapshot/<snapshot-name>/
```

Example: `/backup/snapshots/class1/technicom.files/.zfs/snapshot/weekly-2026-W15/`

---

## Retention

`fs-retention.sh` keeps the newest N snapshots of each type per dataset and destroys the
rest with `zfs destroy`.

| Type | Kept | Key |
|---|---|---|
| daily | 14 | `KEEP_DAILY` |
| weekly | 8 | `KEEP_WEEKLY` |
| monthly | 12 | `KEEP_MONTHLY` |
| annual | all (0 = unlimited) | `KEEP_ANNUAL` |

Runs daily ~06:00 via `fsbackup-retention.timer`, after the overnight backup windows.

There is no hardlink promotion and no on-disk mirror copy in v2.0 — each snapshot type is
taken independently by its own runner timer, and physical redundancy is provided at the
ZFS pool level.

---

## Offsite strategy

### S3 (class1 + class2)

Weekly and monthly ZFS snapshots are encrypted with `age` and uploaded to S3 nightly by
`fs-export-s3.sh`. The script is idempotent: it enumerates current ZFS snapshots and
uploads any weekly/monthly not already in the bucket, so the first run backfills anything
previously missed. Retention in S3 is handled by bucket lifecycle rules; the script never
deletes.

S3 key layout: `<tier>/<class>/<target>/<target>--<date>.tar.zst.age`

| Setting | Value |
|---|---|
| Bucket | `S3_BUCKET` in `fsbackup.conf` |
| AWS profile | `S3_AWS_PROFILE` (default: `fsbackup`) |
| Credentials | `/var/lib/fsbackup/.aws/credentials` |
| Encryption | `age` public key at `/etc/fsbackup/age.pub` |
| Skip classes | `S3_SKIP_CLASSES` (default: `class3`) |

The `age` **private key is not stored on the server**. Keep it offline (password manager,
encrypted USB). Without it, S3 objects cannot be decrypted for restore. See the S3 setup
and restore commands in the [top-level README](../README.md#s3-cloud-export).

### class3 — photos and large archives

Excluded from S3 by default. Manual offsite copies:

| Frequency | Medium | Process |
|---|---|---|
| Monthly | USB external drive | Copy from `.zfs/snapshot/monthly-YYYY-MM/` |
| Annual | M-DISC (archival optical) | Burn from the December monthly snapshot |

---

## Timer schedule

All times approximate; runner timers use `RandomizedDelaySec`. Schedules for the runner
timers come from `CLASS*_*_SCHEDULE` in `fsbackup.conf` (applied by `fs-schedule-apply.sh`);
the rest are set in the timer unit files.

**Nightly (every day)**

| Time | Unit | Action |
|---|---|---|
| ~01:45 | `fsbackup-runner-daily@class1` | Daily rsync + ZFS snapshot — class1 |
| 02:05 | `fsbackup-doctor@class1` | SSH/path health check — class1 |
| 02:05 | `fsbackup-doctor@class2` | SSH/path health check — class2 |
| 02:05 | `fsbackup-doctor@class3` | SSH/path health check — class3 |
| ~02:15 | `fsbackup-runner-daily@class2` | Daily rsync + ZFS snapshot — class2 |
| 04:30 | `fsbackup-s3-export` | Encrypt + upload weekly/monthly to S3 |
| 06:00 | `fsbackup-retention` | Prune old ZFS snapshots (all classes) |
| 00:00 | `fsbackup-logrotate-metric` | Rotate Prometheus `.prom` files |

**Weekly (Saturday)**

| Time | Unit | Action |
|---|---|---|
| Sat ~02:00 | `fsbackup-runner-weekly@class1` | Weekly rsync + ZFS snapshot — class1 |
| Sat ~02:30 | `fsbackup-runner-weekly@class2` | Weekly rsync + ZFS snapshot — class2 |

**Monthly**

| Time | Unit | Action |
|---|---|---|
| 1st ~03:00 | `fsbackup-runner-monthly@class1` | Monthly rsync + ZFS snapshot — class1 |
| 1st ~04:00 | `fsbackup-runner-monthly@class3` | Monthly rsync + ZFS snapshot — class3 |
| 5th 03:00 | `fsbackup-scrub` | ZFS pool scrub |

> `fsbackup-runner-monthly@class2` is intentionally disabled (`CLASS2_MONTHLY_SCHEDULE`
> commented out). class2 retains 14 dailies and 8 weeklies, sufficient for config data.

> On Saturdays, class1 daily (~01:45) and weekly (~02:00) run ~15 minutes apart. If the
> daily run takes longer than that they may overlap; `fs-runner.sh` locking prevents two
> runs of the same class colliding.

---

## Key paths

| Path | Purpose |
|---|---|
| `/opt/fsbackup/` | Installed scripts, configs, systemd units, web UI |
| `/etc/fsbackup/fsbackup.conf` | Runtime config (roots, schedules, retention, S3) |
| `/etc/fsbackup/targets.yml` | Target definitions |
| `/etc/fsbackup/db/<name>.env` | DB export credentials (per database) |
| `/etc/fsbackup/age.pub` | age public key for S3 encryption |
| `/var/lib/fsbackup/` | fsbackup user home |
| `/var/lib/fsbackup/.ssh/id_ed25519_backup` | Private key used to pull from remotes |
| `/var/lib/fsbackup/.aws/credentials` | AWS credentials (profile `fsbackup`) |
| `/var/lib/fsbackup/log/` | Log files (per-class runner logs, retention, s3-export, orphans) |
| `/backup/snapshots/` | ZFS snapshot root (`SNAPSHOT_ROOT`) |
| `/var/lib/node_exporter/textfile_collector/` | Prometheus metrics output |
| `/etc/sudoers.d/fsbackup-zfs-destroy` | NOPASSWD `zfs destroy -r <root>/*/*` (web UI orphan-delete) |
| `/etc/sudoers.d/fsbackup-provision` | NOPASSWD `fs-provision.sh` (runner auto-provision) |

---

## Prometheus metrics

The exact metric set is documented per script in [overview.md](overview.md#prometheus-metrics).
Summary of the most useful series:

| Metric | Description |
|---|---|
| `fsbackup_snapshot_last_success{class,target}` | Timestamp of last successful snapshot |
| `fsbackup_snapshot_bytes{class,target}` | Dataset size in bytes |
| `fsbackup_runner_target_last_exit_code{class,target}` | rsync exit code (0 ok, 255 SSH failure) |
| `fsbackup_runner_target_failures_total{class,target}` | Cumulative failure count |
| `fsbackup_runner_success{class}` / `fsbackup_runner_failed{class}` | Targets ok / failed in last run |
| `fsbackup_orphan_snapshots_total` | Orphan datasets detected (no label; alert if > 0) |
| `fsbackup_doctor_missing_datasets{class}` | Targets with no provisioned dataset |
| `fsbackup_doctor_duration_seconds{class}` | Doctor run duration |
| `fsbackup_retention_last_run_seconds` | Timestamp of last retention run |
| `fsbackup_retention_destroyed_total` / `_failed_total` | Snapshots destroyed / failed to destroy |
| `fsbackup_ssh_host_key_present{host,fingerprint}` | 1 if the host's SSH key is trusted |
| `fsbackup_s3_last_success` / `fsbackup_s3_last_exit_code` | Last S3 run time / result |
| `fsbackup_s3_target_last_upload{tier,class,target}` | Last successful S3 upload per target |

---

## Web UI security

The web UI (`fsbackup-web.service`) is a login-protected FastAPI app that binds
`0.0.0.0:8080` by default. It is an administrative surface for a backup server, so treat
it as internal-only even though it is authenticated.

### Restrict which interface it listens on

Set `HOST` in `web/.env` to a specific internal address (e.g. your management IP) instead
of `0.0.0.0`, then restart the service:

```bash
# web/.env
HOST=172.30.1.10
```

```bash
sudo systemctl restart fsbackup-web.service
```

### Restrict access at the host firewall

Allow port 8080 only from your trusted management subnet and deny it elsewhere. Replace
`172.30.1.0/26` with your own management CIDR.

**UFW**

```bash
sudo ufw allow from 172.30.1.0/26 to any port 8080 proto tcp
sudo ufw deny 8080/tcp
```

**nftables**

```
table inet fsbackup {
  chain input {
    type filter hook input priority 0; policy accept;
    tcp dport 8080 ip saddr 172.30.1.0/26 accept
    tcp dport 8080 drop
  }
}
```

**iptables**

```bash
sudo iptables -A INPUT -p tcp --dport 8080 -s 172.30.1.0/26 -j ACCEPT
sudo iptables -A INPUT -p tcp --dport 8080 -j DROP
```

### Edge firewall

Do **not** create a WAN → 8080 rule on your perimeter firewall (e.g. SonicWALL). The
backup server has internet access for S3, but the web UI should never be reachable from
the internet — keep it LAN/management-only.

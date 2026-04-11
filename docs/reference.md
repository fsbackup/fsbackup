# Reference

System overview: classes, snapshot structure, retention, promotion, mirror, and offsite.

---

## Data classes

Targets are organized into classes. Each class has its own backup schedule, retention
policy, and offsite strategy.

### class1 — Application data

Frequently changing data: app volumes, databases, personal files.

- **Schedule**: daily at ~01:45, weekly Sat ~02:00, monthly 1st ~03:00
- **Tiers**: daily, weekly, monthly
- **Offsite**: S3 — weekly + monthly uploaded nightly via `fsbackup-s3-export.timer`

### class2 — Infrastructure config

Slowly changing config: docker stacks, nginx, bind, etc.

- **Schedule**: daily at ~02:15, weekly Sat ~02:30
- **Tiers**: daily, weekly (monthly disabled — `CLASS2_MONTHLY_SCHEDULE` commented out in `fsbackup.conf`)
- **Offsite**: S3 — weekly uploaded nightly via `fsbackup-s3-export.timer`

### class3 — Large archives

Large, infrequently changing data: photo libraries, raw camera files.

- **Schedule**: monthly (1st of each month at ~04:00)
- **Tiers**: monthly only (no daily, no weekly)
- **Offsite**: excluded from S3 by default (`S3_SKIP_CLASSES=class3`); manual M-DISC/USB

---

## Snapshot path structure

fsbackup v2 uses ZFS-native snapshots. Each target has a dedicated ZFS dataset; snapshots
are named with a tier prefix and a date stamp.

**ZFS dataset path**: `backup/snapshots/<class>/<target>`

**Snapshot names**:

| Tier | Format | Example |
|---|---|---|
| daily | `@daily-YYYY-MM-DD` | `@daily-2026-04-11` |
| weekly | `@weekly-YYYY-Www` | `@weekly-2026-W15` |
| monthly | `@monthly-YYYY-MM` | `@monthly-2026-04` |

**Filesystem access** (read-only via `.zfs` automount):

```
/backup/snapshots/<class>/<target>/.zfs/snapshot/<snapshot-name>/
```

Example: `/backup/snapshots/class1/technicom.files/.zfs/snapshot/weekly-2026-W15/`

---

## Retention policy

| Tier | Kept |
|---|---|
| daily | 14 (`KEEP_DAILY`) |
| weekly | 8 (`KEEP_WEEKLY`) |
| monthly | 12 (`KEEP_MONTHLY`) |

Retention runs daily at ~06:00 via `fsbackup-retention.timer` (after overnight backup windows).

---

## Promotion and mirroring

Not implemented in v2.0. Each tier (daily/weekly/monthly) is taken independently by
its own runner timer. There are no hardlink promotions or mirror copies in this release.

---

## Offsite strategy

### S3 (class1 + class2)

Weekly and monthly ZFS snapshots are encrypted with `age` and uploaded to S3 nightly
by `fs-export-s3.sh`. The script is idempotent: it enumerates all current ZFS snapshots
and uploads any weekly/monthly/annual snapshots not already present in the bucket.
This means the first successful run will backfill all previously missed snapshots.

S3 key layout: `<tier>/<class>/<target>/<target>--<date>.tar.zst.age`

| Setting | Value |
|---|---|
| Bucket | `S3_BUCKET` in `fsbackup.conf` |
| AWS profile | `S3_AWS_PROFILE` (default: `fsbackup`) |
| Credentials | `/var/lib/fsbackup/.aws/credentials` |
| Encryption | `age` public key at `/etc/fsbackup/age.pub` |
| Skip classes | `S3_SKIP_CLASSES` (default: `class3`) |

The `age` private key is **not stored on the server**. Keep it offline (e.g., Bitwarden,
encrypted USB). Without it, S3 objects cannot be decrypted for restore.

### class3 — photos and large archives

Excluded from S3 by default (`S3_SKIP_CLASSES=class3`). Manual offsite copies:

| Frequency | Medium | Process |
|---|---|---|
| Monthly | USB external drive | Manual copy from snapshot `.zfs/snapshot/monthly-YYYY-MM/` |
| Annual | M-DISC (archival optical disc) | Manual burn from the December monthly snapshot |

---

## Timer schedule

All times approximate. Runner timers use `RandomizedDelaySec=5m`.

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

**Monthly (1st of month)**

| Time | Unit | Action |
|---|---|---|
| 1st ~03:00 | `fsbackup-runner-monthly@class1` | Monthly rsync + ZFS snapshot — class1 |
| 1st ~04:00 | `fsbackup-runner-monthly@class3` | Monthly rsync + ZFS snapshot — class3 |

**Monthly (5th of month)**

| Time | Unit | Action |
|---|---|---|
| 5th 03:00 | `fsbackup-scrub` | ZFS pool scrub |

> **Note**: `fsbackup-runner-monthly@class2` is intentionally disabled
> (`CLASS2_MONTHLY_SCHEDULE` commented out in `fsbackup.conf`). class2 retains
> 14 days of dailies and 8 weeks of weeklies, which is sufficient for config data.

> **Schedule note**: On Saturdays, class1 daily (01:45) and weekly (02:00) run only
> 15 minutes apart. If the daily backup takes longer than ~15 minutes, both runners
> may overlap. Check `fs-runner.sh` locking if this causes issues.

---

## Key paths

| Path | Purpose |
|---|---|
| `/opt/fsbackup/` | Repository — all scripts, configs, systemd units |
| `/etc/fsbackup/fsbackup.conf` | Runtime config (roots, skip classes) |
| `/etc/fsbackup/targets.yml` | Target definitions |
| `/var/lib/fsbackup/` | fsbackup user home |
| `/var/lib/fsbackup/.ssh/` | SSH keys for fsbackup user |
| `/var/lib/fsbackup/.ssh/id_ed25519_backup` | Private key used to pull from remotes |
| `/var/lib/fsbackup/log/` | All log files |
| `/backup/snapshots/` | Primary snapshot root |
| `/backup2/snapshots/` | Mirror snapshot root |
| `/var/lib/node_exporter/textfile_collector/` | Prometheus metrics output |
| `/etc/sudoers.d/fsbackup-zfs-destroy` | Scoped NOPASSWD rule: allows `fsbackup` to run `zfs destroy -r <dataset>/*/*` (required by web UI orphan-delete) |

---

## Prometheus metrics

| Metric | Description |
|---|---|
| `fsbackup_snapshot_last_success{class,target}` | Unix timestamp of last successful snapshot |
| `fsbackup_snapshot_bytes{class,target}` | Bytes in last successful snapshot |
| `fsbackup_runner_target_last_exit_code{class,target}` | Exit code of last run |
| `fsbackup_runner_target_failures_total{class,target}` | Cumulative failure count |
| `fsbackup_runner_success{class}` | Targets succeeded in last run |
| `fsbackup_runner_failed{class}` | Targets failed in last run |
| `fsbackup_orphan_snapshots_total{root}` | Orphaned snapshot directories detected |
| `fsbackup_annual_immutable{root}` | 1 if annual snapshots are read-only |
| `fsbackup_mirror_last_success{mode}` | Timestamp of last mirror run |
| `fsbackup_mirror_last_exit_code{mode}` | Exit code of last mirror run |
| `fsbackup_mirror_bytes_total{mode}` | Bytes in mirrored scope |
| `fsbackup_retention_last_run_seconds` | Timestamp of last retention run |
| `fsbackup_promote_weekly_classes_promoted` | Classes promoted to weekly last run |
| `fsbackup_promote_monthly_classes_promoted` | Classes promoted to monthly last run |
| `fsbackup_annual_promote_success{year}` | 1 if annual promote succeeded |
| `fsbackup_doctor_duration_seconds{class}` | Doctor run duration |
| `fsbackup_ssh_host_key_present{host,fingerprint}` | 1 if SSH host key is trusted |
| `fsbackup_s3_last_success` | Unix timestamp of last S3 export run |
| `fsbackup_s3_last_exit_code` | Exit code of last S3 export run (0=success) |
| `fsbackup_s3_uploaded_total` | Objects uploaded in last S3 run |
| `fsbackup_s3_skipped_total` | Objects skipped (already in S3) in last run |
| `fsbackup_s3_failed_total` | Objects that failed to upload in last run |
| `fsbackup_s3_bytes_total` | Bytes uploaded in last S3 run |
| `fsbackup_s3_duration_seconds` | Duration of last S3 export run |
| `fsbackup_s3_target_last_upload{tier,class,target}` | Timestamp of last successful upload per target |
| `fsbackup_s3_target_last_failure{tier,class,target}` | Timestamp of last upload failure per target |

# fsbackup

fsbackup is a pull-based snapshot backup system designed for home lab Linux servers.

---

## Repository layout

```
bin/        Core scripts run by systemd timers
utils/      Manual-use utilities (restore, trust-host, node_exporter repair, etc.)
remote/     Scripts deployed to and run ON remote source hosts
systemd/    Source of truth for all unit files (services + timers)
s3/         S3 offload scripts (WIP)
conf/       Config templates and examples
```

---

## Design principles

- Pull-based: the backup host initiates all rsync connections
- Least privilege: `backup` account on source hosts has read-only access
- Immutable daily snapshots via chattr +i
- Deterministic retention and promotion tiers
- Prometheus metrics via node_exporter textfile collector

---

## Snapshot layout

```
/backup/snapshots/
  daily/    YYYY-MM-DD/<class>/<target>/
  weekly/   YYYY-W##/<class>/<target>/
  monthly/  YYYY-MM/<class>/<target>/
  annual/   YYYY/<class>/<target>/   (class1 only, promoted each January)
```

Mirror copy at `/backup2/snapshots/` (same structure).

---

## Data classes

| Class  | Description                        | Tiers              |
|--------|------------------------------------|--------------------|
| class1 | Hot app data, databases            | daily/weekly/monthly/annual |
| class2 | Infrastructure config              | daily/weekly/monthly |
| class3 | Archival (photos, etc.) — planned  | TBD                |

---

## Restore

Use `utils/fs-restore.sh` as the `fsbackup` system user, or as root.

### Browse available snapshots

```bash
# List available date keys for a tier
fs-restore.sh list --type daily
fs-restore.sh list --type weekly
fs-restore.sh list --type monthly

# List classes under a specific date key
fs-restore.sh list --type daily --date 2026-02-27

# List targets (backup IDs) under a specific date/class
fs-restore.sh list --type daily   --date 2026-02-27    --class class2
fs-restore.sh list --type weekly  --date 2026-W09      --class class1
fs-restore.sh list --type monthly --date 2026-02       --class class1
```

### Restore to a local path

```bash
# Restore the most recent daily snapshot to /tmp/restore-nginx
fs-restore.sh restore \
  --type daily --class class2 --id nginx.data \
  --latest \
  --to /tmp/restore-nginx

# Restore from a specific date
fs-restore.sh restore \
  --type weekly --class class2 --id ns1.bind.named.conf \
  --date 2026-W09 \
  --to /tmp/restore-bind
```

### Restore directly to a remote host

The script rsyncs the snapshot to `backup@<host>:<path>` using the same SSH key
the runner uses. The destination path is created if it does not exist.

```bash
# Restore bind config to ns1 staging path
fs-restore.sh restore \
  --type daily --class class2 --id ns1.bind.named.conf \
  --latest \
  --to-host ns1 --to-path /tmp/restore-bind

# Restore from a specific weekly snapshot to ns2
fs-restore.sh restore \
  --type weekly --class class2 --id ns2.bind.named.conf \
  --date 2026-W09 \
  --to-host ns2 --to-path /tmp/restore-bind
```

### Arguments reference

| Flag | Required | Description |
|------|----------|-------------|
| `--type` | yes | `daily`, `weekly`, or `monthly` |
| `--class` | yes (restore) | `class1`, `class2`, etc. |
| `--id` | yes (restore) | Target name as shown in `list` output |
| `--latest` | one of | Use the most recent snapshot key |
| `--date` | one of | Explicit snapshot key (e.g. `2026-02-27`, `2026-W09`, `2026-02`) |
| `--to` | one of | Local destination directory |
| `--to-host` + `--to-path` | one of | Remote host + path (rsync over SSH) |

### Exit codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 2 | Argument error (missing or invalid flag) |
| 4 | Snapshot path not found on disk |

---

## Deploying unit file changes

The `systemd/` directory is the source of truth. After editing unit files there:

```bash
sudo cp /opt/fsbackup/systemd/*.service /opt/fsbackup/systemd/*.timer /etc/systemd/system/
sudo systemctl daemon-reload
```

---

## License

Internal use.

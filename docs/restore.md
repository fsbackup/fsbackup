# Restoring from a Snapshot

Restores are performed with `utils/fs-restore.sh`, which reads from the read-only ZFS
snapshot directories (`<dataset>/.zfs/snapshot/<name>/`) and rsyncs the contents to a
local path or pushes them to a remote host over SSH. The same restore is also available
in the web UI (Restore page).

Run it as the `fsbackup` user:

```bash
sudo -u fsbackup /opt/fsbackup/utils/fs-restore.sh ...
```

> Remote restores use the same `backup` SSH user that pulls data. That user must have
> write access to the destination path on the remote host.

---

## Discovering available snapshots

`list` accepts optional `--type`, `--class`, and `--id` filters:

```bash
# Everything
sudo -u fsbackup /opt/fsbackup/utils/fs-restore.sh list

# One class
sudo -u fsbackup /opt/fsbackup/utils/fs-restore.sh list --class class2

# One target (shows its snapshot names, e.g. daily-2026-03-05, weekly-2026-W10)
sudo -u fsbackup /opt/fsbackup/utils/fs-restore.sh list --class class2 --id nginx.data

# Only one type across all targets
sudo -u fsbackup /opt/fsbackup/utils/fs-restore.sh list --type weekly
```

Snapshot names are `<type>-<date>` — `daily-2026-03-05`, `weekly-2026-W10`,
`monthly-2026-03`.

---

## Restoring to a local path

Restore into a directory on the backup server — useful for inspecting or staging before
pushing to a host. Pick the snapshot with `--latest` (optionally narrowed by `--type`) or
name it exactly with `--snapshot`.

```bash
# Most recent daily snapshot
sudo -u fsbackup /opt/fsbackup/utils/fs-restore.sh restore \
  --class class2 --id nginx.data \
  --latest --type daily \
  --to /tmp/restore-nginx

# A specific snapshot by name
sudo -u fsbackup /opt/fsbackup/utils/fs-restore.sh restore \
  --class class2 --id nginx.data \
  --snapshot weekly-2026-W10 \
  --to /tmp/restore-nginx
```

The destination is created if it does not exist.

---

## Restoring directly to a remote host

Pushes the snapshot to a path on a remote host over SSH as the `backup` user:

```bash
sudo -u fsbackup /opt/fsbackup/utils/fs-restore.sh restore \
  --class class2 --id ns1.bind.named.conf \
  --snapshot daily-2026-01-29 \
  --to-host ns1 --to-path /tmp/restore-bind
```

This restores to `/tmp/restore-bind` on `ns1`. Always restore to a staging path first,
verify the contents, then move into place as root.

---

## Flags reference

| Flag | Applies to | Description |
|------|-----------|-------------|
| `--class` | list, restore | `class1`, `class2`, `class3` |
| `--id` | list, restore | Target ID as shown in `list` output |
| `--type` | list, restore | `daily`, `weekly`, `monthly`, `annual` (filters `--latest`) |
| `--snapshot` | restore | Exact snapshot name, e.g. `weekly-2026-W10` |
| `--latest` | restore | Use the most recent snapshot (optionally of `--type`) |
| `--to` | restore | Local destination directory |
| `--to-host` + `--to-path` | restore | Remote host and path (rsync over SSH) |

`--snapshot` and `--latest` are mutually exclusive; give exactly one. Likewise choose
either `--to` (local) or `--to-host` + `--to-path` (remote).

---

## Recommended workflow

1. **Identify** the snapshot:
   ```bash
   sudo -u fsbackup /opt/fsbackup/utils/fs-restore.sh list --class class1 --id mosquitto.data
   ```
2. **Stage** it locally or to `/tmp` on the target host.
3. **Verify** the contents before touching production paths.
4. **Move into place** (stop service, swap directory, restart service).

---

## Restoring class3 (photos)

class3 snapshots are monthly:

```bash
sudo -u fsbackup /opt/fsbackup/utils/fs-restore.sh list --class class3 --type monthly

sudo -u fsbackup /opt/fsbackup/utils/fs-restore.sh restore \
  --class class3 --id pictures.digital_cameras \
  --latest --type monthly \
  --to /tmp/restore-photos
```

For USB or M-DISC offsite copies, mount the media and copy directly — those are plain
directory trees and do not need the restore script.

---

## Restoring from S3

Weekly and monthly snapshots exported offsite are stored as `age`-encrypted, zstd-compressed
tar archives. Restoring them requires the **offline `age` private key**. See the
[Restore from S3](../README.md#restore-from-s3) section of the top-level README for the
download-and-decrypt commands.

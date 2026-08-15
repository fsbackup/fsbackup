# Installation — fsbackup backup server

This document covers setting up fsbackup on the primary backup host.
For adding new source hosts, see [adding-hosts-and-targets.md](adding-hosts-and-targets.md).

fsbackup v2.0 runs bare-metal as the `fsbackup` system user under systemd timers.
The Docker deployment and supercronic scheduler used in v1.x were removed.

---

## Prerequisites

- Ubuntu 24.04 (or Debian-based) with root access
- A **ZFS pool** with a dataset at the snapshot root. By default fsbackup uses
  `backup/snapshots` (pool `backup`); override with `SNAPSHOT_ROOT` in `fsbackup.conf`.
- `node_exporter` with the textfile collector enabled (optional, for Prometheus metrics)

The installer handles the remaining packages: `rsync`, `openssh-client`, `jq`, `yq`,
`zstd`, `acl`, `zfsutils-linux`, the AWS CLI v2, and `python3`/`python3-venv` for the web UI.

---

## Guided install (recommended)

### 1. Clone the repository

```bash
git clone https://github.com/fsbackup/fsbackup /home/<user>/fsbackup
```

### 2. Run the installer

```bash
sudo /home/<user>/fsbackup/bin/fs-install.sh
```

`bin/fs-install.sh` is idempotent and performs every step below in order:

1. Installs required packages (and AWS CLI v2 / `yq` if missing).
2. Creates the `fsbackup` system user and group (UID/GID **993**).
3. Installs the scripts to `/opt/fsbackup` (via `rsync`, owned by `fsbackup`).
4. Creates the config skeleton in `/etc/fsbackup` from the `.example` files.
5. Sets up ZFS delegation (`zfs allow`) and two sudoers drop-ins
   (`fsbackup-zfs-destroy`, `fsbackup-provision`).
6. Installs and enables the systemd timers.
7. Applies the schedule from `fsbackup.conf` via `fs-schedule-apply.sh`.
8. Optionally installs the web UI (`web/install.sh`).

The private SSH key for pulling from source hosts is created at
`/var/lib/fsbackup/.ssh/id_ed25519_backup`; its public key is printed for use when
adding remote hosts.

### 3. Configure

```bash
sudoedit /etc/fsbackup/fsbackup.conf   # SNAPSHOT_ROOT, schedules, retention, S3
sudoedit /etc/fsbackup/targets.yml     # backup targets
```

`fsbackup.conf` holds the snapshot root, the per-class `CLASS*_*_SCHEDULE` values,
`KEEP_*` retention counts, and the S3 settings. After changing any schedule value,
re-apply it to the timers:

```bash
sudo /opt/fsbackup/bin/fs-schedule-apply.sh
```

### 4. Provision datasets, trust hosts, verify

```bash
# Create the ZFS datasets for the targets you defined
sudo /opt/fsbackup/bin/fs-provision.sh

# Trust each remote source host's SSH key
sudo /opt/fsbackup/utils/fs-trust-host.sh <hostname>

# Health check
sudo -u fsbackup /opt/fsbackup/bin/fs-doctor.sh --class class1
sudo -u fsbackup /opt/fsbackup/bin/fs-doctor.sh --class class2
```

All targets should report `OK`. See
[adding-hosts-and-targets.md](adding-hosts-and-targets.md) for initializing the
`backup` user on each source host.

### 5. Run the first snapshot

```bash
sudo -u fsbackup /opt/fsbackup/bin/fs-runner.sh daily --class class1 --dry-run
sudo -u fsbackup /opt/fsbackup/bin/fs-runner.sh daily --class class1
```

The systemd timers then take over on the configured schedule.

---

## Securing the web UI

The web UI (`fsbackup-web.service`) binds `0.0.0.0:8080` by default and is
authenticated, but it is an admin surface for a backup server — keep it reachable
only from your trusted management network. See the
[web UI security notes](reference.md#web-ui-security) in the reference for firewall
snippets and how to bind it to a single interface.

---

## Manual install (without the installer)

If you prefer to install by hand, the steps mirror what `fs-install.sh` does:

1. **Create the user** (UID/GID 993 for on-disk ownership consistency):
   ```bash
   sudo groupadd -r --gid 993 fsbackup
   sudo useradd -r --uid 993 -g fsbackup -d /var/lib/fsbackup -s /bin/bash fsbackup
   ```

2. **Install the scripts**:
   ```bash
   sudo rsync -a --delete --exclude='.git' --exclude='web/.venv' \
     --exclude='web/.env' --exclude='conf/targets.yml' \
     /home/<user>/fsbackup/ /opt/fsbackup/
   sudo chown -R fsbackup:fsbackup /opt/fsbackup
   ```

3. **Config**:
   ```bash
   sudo mkdir -p /etc/fsbackup/db
   sudo cp /opt/fsbackup/conf/fsbackup.conf.example /etc/fsbackup/fsbackup.conf
   sudo cp /opt/fsbackup/conf/targets.yml.example   /etc/fsbackup/targets.yml
   ```

4. **ZFS delegation + sudoers** (dataset = `SNAPSHOT_ROOT` with the leading `/` stripped):
   ```bash
   sudo zfs allow fsbackup create,snapshot,mount,destroy backup/snapshots
   sudo chown -R fsbackup:fsbackup /backup/snapshots
   # Web UI orphan-delete and runner auto-provision need these NOPASSWD rules:
   echo 'fsbackup ALL=(root) NOPASSWD: /usr/sbin/zfs destroy -r backup/snapshots/*/*' \
     | sudo tee /etc/sudoers.d/fsbackup-zfs-destroy
   echo 'fsbackup ALL=(root) NOPASSWD: /opt/fsbackup/bin/fs-provision.sh' \
     | sudo tee /etc/sudoers.d/fsbackup-provision
   sudo chmod 0440 /etc/sudoers.d/fsbackup-zfs-destroy /etc/sudoers.d/fsbackup-provision
   ```

5. **Systemd units + schedule**:
   ```bash
   sudo cp /opt/fsbackup/systemd/*.service /opt/fsbackup/systemd/*.timer /etc/systemd/system/
   sudo systemctl daemon-reload
   sudo systemctl enable --now \
     fsbackup-doctor@class1.timer fsbackup-doctor@class2.timer \
     fsbackup-runner-daily@class1.timer fsbackup-runner-daily@class2.timer \
     fsbackup-retention.timer fsbackup-s3-export.timer \
     fsbackup-scrub.timer fsbackup-logrotate-metric.timer
   sudo /opt/fsbackup/bin/fs-schedule-apply.sh
   ```
   Enable the weekly/monthly runner timers for whichever classes have a
   `CLASS*_WEEKLY_SCHEDULE` / `CLASS*_MONTHLY_SCHEDULE` set.

6. **Web UI**: run `sudo /opt/fsbackup/web/install.sh` to create the virtualenv,
   write `web/.env` (including the bcrypt auth hash), and enable `fsbackup-web.service`.

---

## Updating an existing install

Pull the repo and re-sync to `/opt/fsbackup`. `fs-install.sh` is safe to re-run, or
use the rsync one-liner directly:

```bash
cd /home/<user>/fsbackup && git pull --ff-only
sudo rsync -a --delete --exclude='.git' --exclude='web/.venv' \
  --exclude='web/.env' --exclude='conf/targets.yml' \
  /home/<user>/fsbackup/ /opt/fsbackup/
# Restart the web UI if web/ changed; reload systemd if unit files changed:
sudo systemctl restart fsbackup-web.service
```

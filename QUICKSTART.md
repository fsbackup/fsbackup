# fsbackup – Quick Start

This guide gets a new backup server running with the guided installer.
For a step-by-step manual walkthrough see [docs/installation.md](docs/installation.md).

fsbackup v2.0 runs bare-metal as the `fsbackup` system user under systemd timers.
There is no Docker image and no supercronic — those were removed in v2.0.

---

## Prerequisites

- Ubuntu 24.04 (or Debian-based) with root access
- A **ZFS pool** for backups, with a dataset at the snapshot root (default `backup/snapshots`)
- `node_exporter` with the textfile collector enabled (optional, for Prometheus metrics)

The installer pulls in the remaining dependencies (`rsync`, `openssh-client`, `jq`,
`yq`, `zstd`, `acl`, `zfsutils-linux`, the AWS CLI, and Python for the web UI).

---

## 1. Clone the repository

```bash
git clone https://github.com/fsbackup/fsbackup /home/<user>/fsbackup
```

---

## 2. Run the installer

`bin/fs-install.sh` is the one-shot installer. Run as root, it:

- installs dependencies and creates the `fsbackup` system user (UID 993),
- installs the scripts to `/opt/fsbackup`,
- creates the config skeleton in `/etc/fsbackup`,
- sets up ZFS delegation and the sudoers drop-ins,
- installs and enables the systemd timers,
- applies the schedule from `fsbackup.conf`, and
- offers to set up the web UI.

```bash
sudo /home/<user>/fsbackup/bin/fs-install.sh
```

It is idempotent — safe to re-run to pick up new scripts or units.

---

## 3. Configure

Edit the two config files the installer created:

```bash
sudoedit /etc/fsbackup/fsbackup.conf   # SNAPSHOT_ROOT, schedules, retention, S3 bucket
sudoedit /etc/fsbackup/targets.yml     # your backup targets
```

A minimal target:

```yaml
class2:
  - id: nginx.config
    host: rp
    source: /etc/nginx
    type: dir
```

See [docs/adding-hosts-and-targets.md](docs/adding-hosts-and-targets.md) for the full
`targets.yml` reference.

---

## 4. Trust remote hosts and provision datasets

For each remote source host, seed its SSH host key and initialize the `backup` user:

```bash
sudo /opt/fsbackup/utils/fs-trust-host.sh <hostname>
```

Then run the remote init script **on the source host** (see
[docs/adding-hosts-and-targets.md](docs/adding-hosts-and-targets.md)).

Create the ZFS datasets for the targets you defined:

```bash
sudo /opt/fsbackup/bin/fs-provision.sh
```

(New targets added later are auto-provisioned at the start of the next runner run, so
this manual step is only needed to provision immediately.)

---

## 5. Verify with doctor

```bash
sudo -u fsbackup /opt/fsbackup/bin/fs-doctor.sh --class class1
sudo -u fsbackup /opt/fsbackup/bin/fs-doctor.sh --class class2
```

All targets must show `OK`. Resolve any `FAIL` before running the runner.

---

## 6. Run the first snapshot

```bash
sudo -u fsbackup /opt/fsbackup/bin/fs-runner.sh daily --class class1 --dry-run
sudo -u fsbackup /opt/fsbackup/bin/fs-runner.sh daily --class class1
```

From here the systemd timers take over on the schedule defined in `fsbackup.conf`.
See [docs/reference.md](docs/reference.md#timer-schedule) for the full timer list.

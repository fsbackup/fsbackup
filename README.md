# fsbackup

`fsbackup` is a lightweight, pull-based backup system built around `rsync`, SSH, and filesystem snapshots.
This repository contains **only the code and configuration needed to deploy and run the backup system**.

Operational runbooks, retention policy explanations, and business-facing documentation live **outside this repo**
in the central documentation site.

---

## What this repository is for

- Installing the fsbackup tooling on the backup server
- Preparing remote hosts for safe, read-only backups
- Defining *what* gets backed up (targets)
- Running daily snapshots and promotions

This repo intentionally avoids:
- Business retention rationale
- Disaster recovery narratives
- Human procedures (those belong in Docmost)

---

## Repository layout

```
.
├── bin/                    # Executable scripts
│   ├── fs-runner.sh         # Main snapshot runner
│   ├── fs-doctor.sh         # Connectivity & permissions checks
│   ├── fs-snapshot.sh      # Single-target snapshot helper
│   ├── fs-preflight.sh     # Shared preflight logic
│   ├── fs-promote.sh       # Daily → weekly → monthly promotion
│   ├── fs-retention.sh     # Retention policy enforcement
│   ├── fs-prune.sh         # Old snapshot pruning
│   ├── fs-restore.sh       # Restore helper
│   ├── fs-trust-host.sh    # SSH host key seeding
│   └── fs-export-s3.sh     # Optional offsite export
│
├── etc/
│   ├── targets.yml         # Backup target definitions
│   └── fsbackup.conf       # Global settings (paths, retention)
│
├── bootstrap/
│   └── fsbackup_bootstrap.sh   # Initial setup on backup server
│
├── remote/
│   └── fsbackup_remote_init.sh # Prepare source hosts
│
└── README.md               # This file
```

---

## Installation (backup server)

1. Clone the repository:
   ```bash
   git clone <private-repo-url> /opt/fsbackup
   cd /opt/fsbackup
   ```

2. Run the bootstrap script:
   ```bash
   sudo ./bootstrap/fsbackup_bootstrap.sh
   ```

   This will:
   - Create the `fsbackup` user
   - Create snapshot directories (e.g. `/bak/snapshots`)
   - Generate SSH keys
   - Install scripts into `/usr/local/bin` (or symlink)

3. Verify:
   ```bash
   sudo -u fsbackup fs-doctor.sh --class class2
   ```

---

## Preparing source hosts

On **each system to be backed up**, run:

```bash
sudo ./remote/fsbackup_remote_init.sh
```

This script:
- Creates the `backup` user
- Installs the backup server’s SSH public key
- Applies minimal ACLs to approved paths only

> No services are restarted and no daemons are installed.

---

## Configuration

### targets.yml

All backup scope is defined in:

```
etc/targets.yml
```

Each entry specifies:
- `id` – unique snapshot name
- `host` – source host (or local hostname)
- `source` – file or directory path
- `type` – `file` or `dir`
- `rsync_opts` – optional per-target overrides

Example:

```yaml
class2:
  - id: headscale.config
    host: hs
    source: /etc/headscale
    type: dir
```

---

## Running backups

### Preflight (recommended)

```bash
sudo -u fsbackup fs-doctor.sh --class class2
```

### Daily snapshot

```bash
sudo -u fsbackup fs-runner.sh daily --class class2
```

### Dry run

```bash
sudo -u fsbackup fs-runner.sh daily --class class2 --dry-run
```

---

## Scheduling

The system is designed to be driven by **systemd timers**:

- Daily snapshots
- Weekly/monthly promotion
- Retention pruning

Timer units are installed separately and are not required for manual operation.

---

## Logging

All runs are logged with timestamps and target IDs.
Logs are written via `tee` to the configured log directory
(e.g. `/var/lib/fsbackup/log/backup.log`).

---

## What’s documented elsewhere

The following intentionally live in the documentation site, not here:

- Backup & Restore Runbook
- Retention policy justification
- Disaster recovery scenarios
- Audit / compliance explanations

This repo is **implementation**, not policy.

---

## Philosophy

- Pull-based (backup server initiates all access)
- Least-privilege ACLs
- No agents
- No databases
- Human-readable snapshots


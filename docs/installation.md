# Installation — fsbackup backup server

This document covers setting up the fsbackup system on the primary backup host.
For adding new source hosts, see [adding-hosts-and-targets.md](adding-hosts-and-targets.md).

---

## Choose your deployment

| | Docker | Bare-metal |
|---|---|---|
| **Recommended** | Yes | For environments without Docker |
| **Scheduler** | supercronic (in container) | systemd timers |
| **Scripts run as** | fsbackup user inside container | fsbackup user on host |
| **Config location** | `/etc/fsbackup/` (bind-mounted) | `/etc/fsbackup/` |

**Docker:** follow steps 1–7 below, then continue in [docker.md](docker.md).

**Bare-metal:** follow steps 1–7 below, then continue in the [Bare-metal deployment](#bare-metal-deployment) section.

---

## Common setup (both paths)

### 1. Clone the repository

```bash
git clone https://github.com/fsbackup/fsbackup /home/<user>/fsbackup
```

---

### 2. Create the fsbackup system user

```bash
sudo useradd -r --uid 993 -g $(getent group | awk -F: '$3==993{print $1}' || echo fsbackup) \
  -d /var/lib/fsbackup -s /bin/bash fsbackup 2>/dev/null || \
sudo useradd -r -m -d /var/lib/fsbackup -s /bin/bash fsbackup
sudo usermod -u 993 fsbackup
```

The UID **must be 993** to match the user baked into the Docker image. Use the same UID for bare-metal deployments for consistency.

---

### 3. Generate the backup SSH keypair

The `fsbackup` user pulls from remote hosts using the `backup` user over SSH.
The keypair lives in the fsbackup home directory.

```bash
sudo -u fsbackup ssh-keygen -t ed25519 -f /var/lib/fsbackup/.ssh/id_ed25519_backup -N ""
```

The public key (`id_ed25519_backup.pub`) is installed on each remote source host.
See [adding-hosts-and-targets.md](adding-hosts-and-targets.md) for that process.

---

### 4. Create the config directory

```bash
sudo mkdir -p /etc/fsbackup/db
sudo cp /home/<user>/fsbackup/conf/fsbackup.conf.example /etc/fsbackup/fsbackup.conf
sudo cp /home/<user>/fsbackup/conf/targets.yml.example /etc/fsbackup/targets.yml
sudo cp /home/<user>/fsbackup/conf/fsbackup.crontab /etc/fsbackup/fsbackup.crontab
```

Edit `/etc/fsbackup/fsbackup.conf`:

```bash
SNAPSHOT_ROOT="/backup/snapshots"
SNAPSHOT_MIRROR_ROOT="/backup2/snapshots"
MIRROR_SKIP_CLASSES="class3"
```

`MIRROR_SKIP_CLASSES` is a space-separated list of class names to exclude from mirroring.

---

### 5. Create snapshot directories

```bash
sudo mkdir -p /backup/snapshots/{daily,weekly,monthly,annual}
sudo mkdir -p /backup2/snapshots/{daily,weekly,monthly,annual}
sudo chown -R fsbackup:fsbackup /backup/snapshots
sudo chown -R fsbackup:fsbackup /backup2/snapshots
```

---

### 6. Create log directory

```bash
sudo mkdir -p /var/lib/fsbackup/log
sudo chown -R fsbackup:fsbackup /var/lib/fsbackup
```

---

### 7. Set up node_exporter textfile collector (optional)

If you're running Prometheus node_exporter with the textfile collector:

```bash
sudo groupadd nodeexp_txt
sudo usermod -aG nodeexp_txt fsbackup
sudo usermod -aG nodeexp_txt node_exporter   # or whatever user runs node_exporter

sudo mkdir -p /var/lib/node_exporter/textfile_collector
sudo chown root:nodeexp_txt /var/lib/node_exporter/textfile_collector
sudo chmod 2775 /var/lib/node_exporter/textfile_collector
```

Or use the repair utility, which handles all of the above and sets default ACLs:

```bash
sudo /home/<user>/fsbackup/utils/fs-nodeexp-fix.sh
```

---

## Docker deployment

See [docker.md](docker.md) for the full stack compose setup, volume configuration, and first-run steps.

Quick start:

```bash
mkdir -p /docker/stacks/fsbackup
cp /home/<user>/fsbackup/conf/docker-compose.yml.example /docker/stacks/fsbackup/docker-compose.yml
# Edit docker-compose.yml — set image tag, ports, volumes, extra_hosts
cd /docker/stacks/fsbackup
docker compose up -d
```

Trust remote host SSH keys:

```bash
docker exec -it fsbackup /opt/fsbackup/utils/fs-trust-host.sh <hostname>
```

Verify and run first snapshot:

```bash
docker exec -it fsbackup /opt/fsbackup/bin/fs-doctor.sh --class class1
docker exec -it fsbackup /opt/fsbackup/bin/fs-runner.sh daily --class class1 --dry-run
docker exec -it fsbackup /opt/fsbackup/bin/fs-runner.sh daily --class class1
```

---

## Bare-metal deployment

### 8. Install scripts

```bash
sudo mkdir -p /opt/fsbackup
sudo cp -r /home/<user>/fsbackup/bin /opt/fsbackup/bin
sudo cp -r /home/<user>/fsbackup/utils /opt/fsbackup/utils
sudo cp -r /home/<user>/fsbackup/s3 /opt/fsbackup/s3
sudo chmod -R 755 /opt/fsbackup
```

---

### 9. Trust remote host SSH keys

```bash
sudo /opt/fsbackup/utils/fs-trust-host.sh <hostname>
```

For local targets, no key trust is needed — rsync accesses paths directly.

---

### 10. Install systemd units

```bash
sudo cp /home/<user>/fsbackup/systemd/*.service /etc/systemd/system/
sudo cp /home/<user>/fsbackup/systemd/*.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now \
  fsbackup-doctor@class1.timer \
  fsbackup-doctor@class2.timer \
  fsbackup-runner@class1.timer \
  fsbackup-runner@class2.timer \
  fsbackup-mirror-daily.timer \
  fsbackup-mirror-promote.timer \
  fsbackup-retention.timer \
  fsbackup-mirror-retention.timer \
  fsbackup-promote.timer \
  fsbackup-s3-export.timer \
  fsbackup-annual-promote.timer
```

---

### 11. Verify and run first snapshot

```bash
sudo -u fsbackup /opt/fsbackup/bin/fs-doctor.sh --class class1
sudo -u fsbackup /opt/fsbackup/bin/fs-doctor.sh --class class2
```

All targets should report `OK`. Fix any `FAIL` entries before running the runner.

```bash
sudo -u fsbackup /opt/fsbackup/bin/fs-runner.sh daily --class class1 --dry-run
sudo -u fsbackup /opt/fsbackup/bin/fs-runner.sh daily --class class1
```

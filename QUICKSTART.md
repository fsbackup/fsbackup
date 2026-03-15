# fsbackup – Quick Start

This guide gets a new environment backing up in under 15 minutes.
For full details see [docs/installation.md](docs/installation.md) and [docs/docker.md](docs/docker.md).

---

## Prerequisites

- Ubuntu/Debian Linux
- Dedicated backup drive(s) mounted (e.g. `/backup`, `/backup2`)
- `node_exporter` with textfile collector (optional, for Prometheus metrics)
- **Docker deployment:** Docker Engine + Docker Compose v2
- **Bare-metal deployment:** `rsync`, `openssh-client`

---

## 1. Clone the repository

```bash
git clone https://github.com/fsbackup/fsbackup /home/<user>/fsbackup
```

---

## 2. Create the fsbackup system user

```bash
sudo useradd -r -m --uid 993 -d /var/lib/fsbackup -s /bin/bash fsbackup
```

The UID **must be 993** to match the user baked into the Docker image. Use the same UID for bare-metal for consistency.

---

## 3. Generate the SSH keypair

```bash
sudo -u fsbackup ssh-keygen -t ed25519 -f /var/lib/fsbackup/.ssh/id_ed25519_backup -N ""
```

---

## 4. Create directories

```bash
sudo mkdir -p /etc/fsbackup/db
sudo mkdir -p /backup/snapshots/{daily,weekly,monthly,annual}
sudo mkdir -p /backup2/snapshots/{daily,weekly,monthly,annual}
sudo chown -R fsbackup:fsbackup /backup/snapshots /backup2/snapshots /var/lib/fsbackup
```

---

## 5. Configure

```bash
sudo cp /home/<user>/fsbackup/conf/fsbackup.conf.example /etc/fsbackup/fsbackup.conf
sudo cp /home/<user>/fsbackup/conf/targets.yml.example /etc/fsbackup/targets.yml
sudo cp /home/<user>/fsbackup/conf/fsbackup.crontab /etc/fsbackup/fsbackup.crontab
```

Edit `/etc/fsbackup/targets.yml` to define your backup targets. Example:

```yaml
class2:
  - id: nginx.config
    host: rp
    source: /etc/nginx
    type: dir
```

---

## 6. Initialize remote hosts

On each source host, run:

```bash
sudo /home/<user>/fsbackup/remote/fsbackup_remote_init.sh \
  --pubkey-file /var/lib/fsbackup/.ssh/id_ed25519_backup.pub
```

---

## 7a. Deploy with Docker (recommended)

```bash
mkdir -p /docker/stacks/fsbackup
cp /home/<user>/fsbackup/conf/docker-compose.yml.example /docker/stacks/fsbackup/docker-compose.yml
# Edit docker-compose.yml — set image tag, ports, volumes, extra_hosts
cd /docker/stacks/fsbackup
docker compose up -d
```

Trust remote SSH host keys:

```bash
docker exec -it fsbackup /opt/fsbackup/utils/fs-trust-host.sh <hostname>
```

See [docs/docker.md](docs/docker.md) for the full stack setup and volume reference.

---

## 7b. Deploy bare-metal (without Docker)

Copy scripts to the system path:

```bash
sudo cp -r /home/<user>/fsbackup/bin /opt/fsbackup/bin
sudo cp -r /home/<user>/fsbackup/utils /opt/fsbackup/utils
sudo cp -r /home/<user>/fsbackup/s3 /opt/fsbackup/s3
sudo chmod -R 755 /opt/fsbackup
```

Trust remote SSH host keys:

```bash
sudo /opt/fsbackup/utils/fs-trust-host.sh <hostname>
```

Install systemd units and enable timers:

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

## 8. Verify with doctor

**Docker:**
```bash
docker exec -it fsbackup /opt/fsbackup/bin/fs-doctor.sh --class class1
docker exec -it fsbackup /opt/fsbackup/bin/fs-doctor.sh --class class2
```

**Bare-metal:**
```bash
sudo -u fsbackup /opt/fsbackup/bin/fs-doctor.sh --class class1
sudo -u fsbackup /opt/fsbackup/bin/fs-doctor.sh --class class2
```

All targets must show `OK`.

---

## 9. Run first snapshot

**Docker:**
```bash
docker exec -it fsbackup /opt/fsbackup/bin/fs-runner.sh daily --class class1 --dry-run
docker exec -it fsbackup /opt/fsbackup/bin/fs-runner.sh daily --class class1
```

**Bare-metal:**
```bash
sudo -u fsbackup /opt/fsbackup/bin/fs-runner.sh daily --class class1 --dry-run
sudo -u fsbackup /opt/fsbackup/bin/fs-runner.sh daily --class class1
```

---

## Daily schedule

| Time | Job |
|------|-----|
| 01:15 | `fs-doctor.sh --class class1` |
| 01:40 | `fs-db-export.sh` (if configured) |
| 01:45 | `fs-runner.sh daily --class class1` |
| 02:05 | `fs-doctor.sh --class class2` |
| 02:15 | `fs-runner.sh daily --class class2` |
| 02:30 | `fs-mirror.sh daily` |
| 03:00 | `fs-retention.sh` |
| 03:30 | `fs-promote.sh` |
| 03:40 | `fs-mirror.sh promote` |
| 04:00 | `fs-mirror-retention.sh` |
| 04:30 | `fs-export-s3.sh` |
| 04:45 (1st of month) | `fs-runner.sh monthly --class class3` |
| 03:00 (Jan 5) | `fs-annual-promote.sh` |

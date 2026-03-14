# Installation — fsbackup backup server

This document covers setting up the fsbackup system on the primary backup host.
For adding new source hosts, see [adding-hosts-and-targets.md](adding-hosts-and-targets.md).

fsbackup runs as a Docker container. See [docker.md](docker.md) for the full Docker deployment guide. The steps below cover the one-time host preparation that Docker deployment requires.

---

## Prerequisites

- Ubuntu/Debian Linux
- Docker Engine + Docker Compose v2
- Dedicated backup drive(s) mounted (e.g. `/backup`, `/backup2`)
- `node_exporter` with textfile collector (optional, for Prometheus metrics)

---

## 1. Clone the repository

```bash
git clone <repo-url> /home/<user>/fsbackup
```

The repo is used for building the Docker image and as a reference. Scripts run from inside the container at `/opt/fsbackup/`.

---

## 2. Create the fsbackup system user

```bash
sudo useradd -r --uid 993 -g $(getent group | awk -F: '$3==993{print $1}' || echo fsbackup) \
  -d /var/lib/fsbackup -s /bin/bash fsbackup 2>/dev/null || \
sudo useradd -r -m -d /var/lib/fsbackup -s /bin/bash fsbackup
sudo usermod -u 993 fsbackup
```

The UID **must be 993** to match the user baked into the Docker image. The container runs as `user: "993:993"` and needs matching ownership on bind-mounted directories.

---

## 3. Generate the backup SSH keypair

The `fsbackup` user on this host pulls from remote hosts using the `backup` user over SSH.
The keypair lives in the fsbackup home directory.

```bash
sudo -u fsbackup ssh-keygen -t ed25519 -f /var/lib/fsbackup/.ssh/id_ed25519_backup -N ""
```

The public key (`id_ed25519_backup.pub`) is what gets installed on each remote source host.
See [adding-hosts-and-targets.md](adding-hosts-and-targets.md) for that process.

---

## 4. Create the config directory

```bash
mkdir -p /etc/fsbackup/db
cp /opt/fsbackup/conf/fsbackup.conf.example /etc/fsbackup/fsbackup.conf
cp /opt/fsbackup/conf/targets.yml /etc/fsbackup/targets.yml
```

Edit `/etc/fsbackup/fsbackup.conf`:

```bash
SNAPSHOT_ROOT="/backup/snapshots"
SNAPSHOT_MIRROR_ROOT="/backup2/snapshots"
MIRROR_SKIP_CLASSES="class3"
```

`MIRROR_SKIP_CLASSES` is a space-separated list of class names to exclude from mirroring.

---

## 5. Create snapshot directories

```bash
mkdir -p /backup/snapshots/{daily,weekly,monthly,annual}
mkdir -p /backup2/snapshots/{daily,weekly,monthly,annual}
chown -R fsbackup:fsbackup /backup/snapshots
chown -R fsbackup:fsbackup /backup2/snapshots
```

---

## 6. Create log and lock directories

```bash
mkdir -p /var/lib/fsbackup/log
chown -R fsbackup:fsbackup /var/lib/fsbackup
```

---

## 7. Set up node_exporter textfile collector (optional)

If you're running Prometheus node_exporter with the textfile collector:

```bash
groupadd nodeexp_txt
usermod -aG nodeexp_txt fsbackup
usermod -aG nodeexp_txt node_exporter   # or whatever user runs node_exporter

mkdir -p /var/lib/node_exporter/textfile_collector
chown root:nodeexp_txt /var/lib/node_exporter/textfile_collector
chmod 2775 /var/lib/node_exporter/textfile_collector
```

Or use the repair utility, which handles all of the above and also sets default ACLs so new metric files stay readable:

```bash
sudo /opt/fsbackup/utils/fs-nodeexp-fix.sh
```

If you're also running the web UI under a separate user, pass `--web-user` to grant that user read access (including a default ACL so future files inherit it):

```bash
sudo /opt/fsbackup/utils/fs-nodeexp-fix.sh --web-user fsbackup
```

The web UI `install.sh` calls this automatically when the web user differs from `fsbackup`.

---

## 8. Deploy the Docker stack

See [docker.md](docker.md) for the full stack compose setup, volume configuration, and first-run steps.

Quick start:

```bash
mkdir -p /docker/stacks/fsbackup
cp /home/<user>/fsbackup/conf/docker-compose.yml.example /docker/stacks/fsbackup/docker-compose.yml
# Edit docker-compose.yml — set image tag, ports, volumes, extra_hosts
cd /docker/stacks/fsbackup
docker compose up -d
```

---

## 9. Trust remote host SSH keys

For each remote host that fsbackup will pull from:

```bash
docker exec -it fsbackup /opt/fsbackup/utils/fs-trust-host.sh <hostname>
```

For local (`host: localhost`) targets, no key trust is needed — rsync accesses paths directly via bind mounts.

---

## 10. Verify

```bash
docker exec -it fsbackup /opt/fsbackup/bin/fs-doctor.sh --class class1
docker exec -it fsbackup /opt/fsbackup/bin/fs-doctor.sh --class class2
```

All targets should report `OK`. Fix any `FAIL` entries before running the runner.

---

## 11. Run a first snapshot

```bash
docker exec -it fsbackup /opt/fsbackup/bin/fs-runner.sh daily --class class1 --dry-run
docker exec -it fsbackup /opt/fsbackup/bin/fs-runner.sh daily --class class1
```

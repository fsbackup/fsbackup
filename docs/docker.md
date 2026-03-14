# Docker Deployment — fsbackup

This guide covers running fsbackup entirely inside a Docker container. The container replaces systemd timers (supercronic handles scheduling), the web UI runs on port 8080, and all persistent state lives on bind-mounted host paths so the container is stateless and upgradeable.

---

## Prerequisites

- Docker Engine (with Compose v2) on the host
- A dedicated backup drive mounted at `/backup` (primary snapshots)
- A mirror drive mounted at `/backup2` (optional but recommended)
- The `fsbackup` system user already created on the host with UID/GID **993:993**

If the user does not exist yet:

```bash
useradd -r -u 993 -g 993 -m -d /var/lib/fsbackup -s /bin/bash fsbackup
```

Confirm:

```bash
id fsbackup
# uid=993(fsbackup) gid=993(fsbackup) groups=993(fsbackup)
```

The container runs as `993:993`. Files written by the container (snapshots, logs, metrics) will be owned by this UID on the host.

---

## Before You Begin — One-Time Host Setup

Complete these steps once before starting the container for the first time.

### 1. Create required directories

```bash
mkdir -p /backup/snapshots/{daily,weekly,monthly,annual}
mkdir -p /backup2/snapshots/{daily,weekly,monthly,annual}
mkdir -p /backup/exports
mkdir -p /backup/restore
mkdir -p /var/lib/fsbackup/{.ssh,.aws,log}
mkdir -p /etc/fsbackup/db

chown -R fsbackup:fsbackup /backup/snapshots /backup2/snapshots
chown -R fsbackup:fsbackup /backup/exports /backup/restore
chown -R fsbackup:fsbackup /var/lib/fsbackup
chown -R fsbackup:fsbackup /etc/fsbackup
```

### 2. Write the config files

```bash
# Copy examples from the repo
cp /opt/fsbackup/conf/fsbackup.conf.example /etc/fsbackup/fsbackup.conf
cp /opt/fsbackup/conf/targets.yml.example   /etc/fsbackup/targets.yml
cp /opt/fsbackup/conf/fsbackup.crontab      /etc/fsbackup/fsbackup.crontab
```

Edit `/etc/fsbackup/fsbackup.conf` at minimum:

```bash
SNAPSHOT_ROOT="/backup/snapshots"
SNAPSHOT_MIRROR_ROOT="/backup2/snapshots"
MIRROR_SKIP_CLASSES="class3"
```

Edit `/etc/fsbackup/targets.yml` with your hosts and paths. Targets that previously used `host: fs` (local host) must use `host: localhost` in Docker, and those source paths must be bind-mounted into the container (see [Volumes reference](#volumes-reference) below).

### 3. Generate the backup SSH keypair

```bash
sudo -u fsbackup ssh-keygen -t ed25519 \
  -f /var/lib/fsbackup/.ssh/id_ed25519 -N ""
chmod 700 /var/lib/fsbackup/.ssh
chmod 600 /var/lib/fsbackup/.ssh/id_ed25519
```

Install the public key on each remote host (see [adding-hosts-and-targets.md](adding-hosts-and-targets.md)).

### 4. Set up AWS credentials (S3 export only)

```bash
mkdir -p /var/lib/fsbackup/.aws
cat > /var/lib/fsbackup/.aws/credentials <<'EOF'
[fsbackup]
aws_access_key_id     = YOUR_ACCESS_KEY
aws_secret_access_key = YOUR_SECRET_KEY
EOF

cat > /var/lib/fsbackup/.aws/config <<'EOF'
[profile fsbackup]
region = us-west-2
EOF

chown -R fsbackup:fsbackup /var/lib/fsbackup/.aws
chmod 600 /var/lib/fsbackup/.aws/credentials
```

### 5. Set up the node_exporter textfile directory (optional)

If you run Prometheus node_exporter with the textfile collector:

```bash
groupadd nodeexp_txt
usermod -aG nodeexp_txt fsbackup
mkdir -p /var/lib/node_exporter/textfile_collector
chown root:nodeexp_txt /var/lib/node_exporter/textfile_collector
chmod 2775 /var/lib/node_exporter/textfile_collector
```

Or use the repair utility:

```bash
sudo /opt/fsbackup/utils/fs-nodeexp-fix.sh
```

### 6. Find the Docker socket GID

The container needs access to `/var/run/docker.sock` for `fs-db-export.sh` (it runs `docker exec` against the paperlessngx container).

```bash
stat -c '%g' /var/run/docker.sock
# e.g. 129
```

Use this GID in `group_add` in the compose file (see the example below).

---

## Stack Compose Setup

The live stack lives at `/docker/stacks/fsbackup/docker-compose.yml`. An annotated example is in `conf/docker-compose.yml.example`.

A minimal working stack:

```yaml
services:
  fsbackup:
    container_name: fsbackup
    image: registry.kluhsman.com/fsbackup:v0.9.1
    restart: unless-stopped

    # Must match the fsbackup user on the host.
    user: "993:993"

    # Add the Docker socket GID so db-export can run `docker exec`.
    # Find it with: stat -c '%g' /var/run/docker.sock
    group_add:
      - "129"

    # Bind only to the backup server's IP so the UI is not exposed to all interfaces.
    ports:
      - "172.30.3.130:8080:8080"

    # Web UI config and credentials (see Web UI Configuration below).
    env_file:
      - stack.env

    # Pin remote hostnames to IPs to avoid DNS failures (see Troubleshooting).
    extra_hosts:
      - "denhpsvr1:172.30.3.10"
      - "denhpsvr2:172.30.3.70"
      - "ns1:172.30.3.53"
      - "ns2:172.30.3.54"
      # add remaining remote backup targets here

    volumes:
      # Primary snapshot storage
      - /backup/snapshots:/backup/snapshots

      # Mirror snapshot storage (remove if no second drive)
      - /backup2/snapshots:/backup2/snapshots

      # DB export staging
      - /backup/exports:/backup/exports

      # Restore staging
      - /backup/restore:/restore

      # Prometheus textfile collector (remove if not using node_exporter)
      - /var/lib/node_exporter/textfile_collector:/var/lib/node_exporter/textfile_collector

      # fsbackup config: fsbackup.conf, targets.yml, fsbackup.crontab, age.pub, db/
      - /etc/fsbackup:/etc/fsbackup

      # fsbackup state: .ssh/, .aws/, log/
      - /var/lib/fsbackup:/var/lib/fsbackup

      # Docker socket for db-export
      - /var/run/docker.sock:/var/run/docker.sock

      # Localhost source paths (targets with host: localhost in targets.yml)
      # Add one line per source path that is backed up from this host.
      # Example:
      # - /docker/stacks:/docker/stacks:ro
      # - /share/technicom:/share/technicom:ro
      # - /etc/apache2:/etc/apache2:ro
```

Place `stack.env` next to `docker-compose.yml` (see [Web UI Configuration](#web-ui-configuration) below).

---

## Volumes Reference

| Host path | Container path | Purpose |
|-----------|----------------|---------|
| `/backup/snapshots` | `/backup/snapshots` | Primary rsync snapshot storage |
| `/backup2/snapshots` | `/backup2/snapshots` | Mirror snapshot storage |
| `/backup/exports` | `/backup/exports` | DB export output |
| `/backup/restore` | `/restore` | Restore staging area |
| `/var/lib/node_exporter/textfile_collector` | `/var/lib/node_exporter/textfile_collector` | Prometheus `.prom` metrics |
| `/etc/fsbackup` | `/etc/fsbackup` | Config, targets.yml, crontab, age.pub, db/ env files |
| `/var/lib/fsbackup` | `/var/lib/fsbackup` | SSH keys, AWS creds, logs |
| `/var/run/docker.sock` | `/var/run/docker.sock` | Docker socket for db-export |
| _(your localhost paths)_ | _(same paths)_ | Source data for `host: localhost` targets |

All mounts are bind mounts. There are no named volumes. Everything persists on the host and survives container replacement.

---

## Web UI Configuration

Create `stack.env` in the stack directory (next to `docker-compose.yml`):

```bash
# Server
HOST=0.0.0.0
PORT=8080

# Snapshot paths (must match fsbackup.conf)
SNAPSHOT_ROOT=/backup/snapshots
MIRROR_ROOT=/backup2/snapshots
TARGETS_FILE=/etc/fsbackup/targets.yml

# Auth
AUTH_ENABLED=true

# Session secret — generate with:
#   python3 -c "import secrets; print(secrets.token_hex(32))"
SECRET_KEY=your-secret-here

# S3 (if using)
S3_BUCKET=fsbackup-snapshots-SUFFIX
S3_PROFILE=fsbackup
S3_REGION=us-west-2
```

**Important — bcrypt `$` escaping:** Docker Compose v2 interpolates `$` in env files. If `AUTH_PASSWORD_HASH` contains a bcrypt hash (which always starts with `$2b$`), every `$` must be doubled to `$$`:

```bash
# Wrong (Compose will silently corrupt the hash):
AUTH_PASSWORD_HASH=$2b$12$abc...

# Correct:
AUTH_PASSWORD_HASH=$$2b$$12$$abc...
```

Generate a bcrypt hash:

```bash
python3 -c "import bcrypt; print(bcrypt.hashpw(b'yourpassword', bcrypt.gensalt()).decode())"
```

Then double every `$` before pasting into `stack.env`.

---

## SSH Host Keys

Before the container runs its first backup, you must seed known_hosts for every remote target. The file is bind-mounted from the host at `/var/lib/fsbackup/.ssh/known_hosts`, so you can populate it from either the host or the container.

**From the host:**

```bash
ssh-keyscan -t ed25519 denhpsvr1 >> /var/lib/fsbackup/.ssh/known_hosts
ssh-keyscan -t ed25519 denhpsvr2 >> /var/lib/fsbackup/.ssh/known_hosts
# repeat for each remote target
chown fsbackup:fsbackup /var/lib/fsbackup/.ssh/known_hosts
chmod 600 /var/lib/fsbackup/.ssh/known_hosts
```

**From inside the container (after it is running):**

```bash
docker exec -it fsbackup /opt/fsbackup/utils/fs-trust-host.sh denhpsvr1
docker exec -it fsbackup /opt/fsbackup/utils/fs-trust-host.sh denhpsvr2
```

Changes write through to the host bind mount immediately.

---

## Scheduler (Crontab)

supercronic reads `/etc/fsbackup/fsbackup.crontab` at startup and hot-reloads it on change. The file is bind-mounted from the host, so you can edit it on the host and supercronic picks up the change without a container restart.

The default schedule (`conf/fsbackup.crontab`):

| Time | Job |
|------|-----|
| 00:30 daily | `fs-logrotate-metric.sh` |
| 01:15 daily | `fs-doctor.sh --class class1` |
| 01:40 daily | `fs-db-export.sh` (paperlessngx) |
| 01:45 daily | `fs-runner.sh daily --class class1` |
| 02:05 daily | `fs-doctor.sh --class class2` |
| 02:15 daily | `fs-runner.sh daily --class class2` |
| 02:30 daily | `fs-mirror.sh daily` |
| 03:00 daily | `fs-retention.sh` |
| 03:30 daily | `fs-promote.sh` |
| 03:40 daily | `fs-mirror.sh promote` |
| 04:00 daily | `fs-mirror-retention.sh` |
| 04:15, 1st of month | `fs-doctor.sh --class class3` |
| 04:30 daily | `fs-export-s3.sh` |
| 04:45, 1st of month | `fs-runner.sh monthly --class class3` |
| 03:00, Jan 5 | `fs-annual-promote.sh` |

To disable a job, comment it out in `/etc/fsbackup/fsbackup.crontab` on the host.

---

## Running Jobs Manually

Execute any script directly with `docker exec`:

```bash
# Dry-run snapshot for class1
docker exec -it fsbackup /opt/fsbackup/bin/fs-runner.sh daily --class class1 --dry-run

# Live snapshot for class1
docker exec -it fsbackup /opt/fsbackup/bin/fs-runner.sh daily --class class1

# Health check
docker exec -it fsbackup /opt/fsbackup/bin/fs-doctor.sh --class class1
docker exec -it fsbackup /opt/fsbackup/bin/fs-doctor.sh --class class2

# Restore latest snapshot of a target to /restore/test
docker exec -it fsbackup /opt/fsbackup/utils/fs-restore.sh restore \
  --type daily --class class2 --id rp.nginx.config --latest --to /restore/test

# Mirror
docker exec -it fsbackup /opt/fsbackup/bin/fs-mirror.sh daily

# Promote
docker exec -it fsbackup /opt/fsbackup/bin/fs-promote.sh

# Retention
docker exec -it fsbackup /opt/fsbackup/bin/fs-retention.sh
```

Logs are written to `/var/lib/fsbackup/log/` (bind-mounted from host) and viewable via the web UI.

---

## Building and Pushing the Image

```bash
cd /home/crash/fsbackup   # or /opt/fsbackup

docker build \
  -t registry.kluhsman.com/fsbackup:vX.Y.Z \
  -t registry.kluhsman.com/fsbackup:latest \
  .

docker push registry.kluhsman.com/fsbackup:vX.Y.Z
docker push registry.kluhsman.com/fsbackup:latest
```

The image is built from repo root. Replace `vX.Y.Z` with the release tag (e.g. `v0.9.2`).

---

## Upgrading

1. Build and push the new image (see above).
2. On the host:

```bash
cd /docker/stacks/fsbackup
docker compose pull
docker compose up -d
```

`docker compose up -d` recreates the container with the new image. All state is on bind mounts, so no data is lost. The upgrade takes a few seconds; schedule it outside the backup window (before 01:00 or after 05:00).

---

## Troubleshooting

### Permission denied writing snapshots or logs

The container runs as `993:993`. Confirm ownership of the bind-mounted directories:

```bash
ls -la /backup/snapshots
ls -la /var/lib/fsbackup
```

If directories are owned by root:

```bash
chown -R fsbackup:fsbackup /backup/snapshots /backup2/snapshots
chown -R fsbackup:fsbackup /backup/exports /backup/restore
chown -R fsbackup:fsbackup /var/lib/fsbackup /etc/fsbackup
```

### Docker socket permission denied (db-export fails)

`fs-db-export.sh` runs `docker exec` against a container on the host. The container user (`993`) needs access to the Docker socket.

Find the GID of the socket:

```bash
stat -c '%g' /var/run/docker.sock
```

Set that GID in `group_add` in the compose file. After changing `group_add`, recreate the container:

```bash
docker compose up -d
```

Verify inside the container:

```bash
docker exec -it fsbackup id
# should show the docker GID in the groups list
docker exec -it fsbackup docker ps
# should succeed without permission error
```

### DNS failures for remote hosts (Linux 6.8 FIB exception bug)

Linux 6.8 has an intermittent FIB exception bug that can cause TCP connections to cross-VLAN hosts to fail with `ENETUNREACH`. Docker bridge traffic is affected. The fix is to bypass DNS for backup target hostnames by pinning them to IP addresses using `extra_hosts` in the compose file:

```yaml
extra_hosts:
  - "denhpsvr1:172.30.3.10"
  - "denhpsvr2:172.30.3.70"
  - "ns1:172.30.3.53"
  - "ns2:172.30.3.54"
```

Add every remote host that appears in `targets.yml`. This injects static `/etc/hosts` entries into the container and removes the DNS lookup from the connection path entirely.

### bcrypt password hash silently corrupted

If web UI login fails immediately after setting `AUTH_PASSWORD_HASH`, the hash likely contains unescaped `$` signs. Docker Compose v2 interpolates `$VAR` patterns in env files.

Fix: double every `$` in the hash value in `stack.env`:

```bash
# Before (broken):
AUTH_PASSWORD_HASH=$2b$12$LongHashHere

# After (correct):
AUTH_PASSWORD_HASH=$$2b$$12$$LongHashHere
```

Restart the container after editing `stack.env`:

```bash
docker compose up -d
```

### SSH host key verification failure

If a backup fails with `Host key verification failed`, the remote host's key is not in `known_hosts`. Trust the host:

```bash
# From the host (bind-mounted, takes effect immediately):
ssh-keyscan -t ed25519 <hostname> >> /var/lib/fsbackup/.ssh/known_hosts

# Or from inside the container:
docker exec -it fsbackup /opt/fsbackup/utils/fs-trust-host.sh <hostname>
```

### Localhost source paths not found

Targets with `host: localhost` in `targets.yml` expect the source path to exist inside the container. If rsync reports the source path as missing, add the corresponding bind mount to the compose file:

```yaml
volumes:
  - /docker/stacks:/docker/stacks:ro
  - /share/technicom:/share/technicom:ro
  - /etc/apache2:/etc/apache2:ro
```

Then recreate the container: `docker compose up -d`.

### Viewing logs

```bash
# Live supercronic output (cron job stdout/stderr)
docker logs -f fsbackup

# Per-job log files (written by the scripts)
ls /var/lib/fsbackup/log/

# Or via the web UI at http://172.30.3.130:8080
```

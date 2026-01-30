# fsbackup – Quick Start

This guide gets a new environment backing up in ~10 minutes.

---

## 1. Clone repository

```bash
git clone <internal-repo-url> fsbackup
cd fsbackup
```

---

## 2. Bootstrap backup host

```bash
sudo ./bin/fsbackup_bootstrap.sh
```

Creates:
- fsbackup user
- SSH keypair
- Snapshot directories
- systemd timers (optional)

---

## 3. Configure targets

Edit:

```bash
/etc/fsbackup/targets.yml
```

Example:

```yaml
class2:
  - id: nginx.config
    host: rp
    source: /etc/nginx
    type: dir
```

---

## 4. Initialize remote hosts

On each source host:

```bash
sudo ./bin/fsbackup_remote_init.sh
```

This:
- Creates backup user
- Installs SSH key
- Applies ACLs (read-only)

---

## 5. Verify with doctor

```bash
sudo -u fsbackup ./bin/fs-doctor.sh --class class2
```

All targets must be OK.

---

## 6. Run snapshot

```bash
sudo -u fsbackup ./bin/fs-runner.sh daily --class class2
```

Snapshots are written under:

```text
/bak/snapshots/class2/daily/
```


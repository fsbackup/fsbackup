# fsbackup

fsbackup is a pull-based snapshot backup system designed for Linux servers.
This repository contains the **implementation scripts only**.

Operational runbooks and business documentation live outside this repository.

---

## What this repository contains

- Snapshot runner (`fs-runner.sh`)
- Preflight & diagnostics (`fs-preflight.sh`, `fs-doctor.sh`)
- Retention, pruning, promotion (`fs-retention.sh`, `fs-prune.sh`, `fs-promote.sh`)
- Restore tooling (`fs-restore.sh`)
- Bootstrap & trust helpers
- `targets.yml` schema and examples

---

## Design principles

- Pull-based (backup host initiates all access)
- Least privilege (ACL-scoped read-only access)
- Immutable snapshots
- Deterministic retention and promotion
- Fully scriptable / auditable

---

## Quick start

See `QUICKSTART.md`.

---

## Documentation split

| Location | Purpose |
|--------|--------|
| This repo | How the system works |
| Docmost | Why it exists, runbooks, DR |

---

## License

Internal use.


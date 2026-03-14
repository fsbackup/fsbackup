#!/usr/bin/env bash
set -euo pipefail

PRIMARY="/backup/snapshots/annual"
MIRROR="/backup2/snapshots/annual"

NODEEXP_DIR="/var/lib/node_exporter/textfile_collector"
PROM_OUT="${NODEEXP_DIR}/fsbackup_annual_mirror.prom"

ok=1

for y in "$PRIMARY"/*; do
  year="$(basename "$y")"
  src="$PRIMARY/$year/class1"
  dst="$MIRROR/$year/class1"

  [[ -d "$src" ]] || continue
  [[ -d "$dst" ]] || { ok=0; continue; }

  src_bytes="$(du -sb "$src" | awk '{print $1}')"
  dst_bytes="$(du -sb "$dst" | awk '{print $1}')"

  [[ "$src_bytes" == "$dst_bytes" ]] || ok=0
done

cat >"$PROM_OUT" <<EOF
fsbackup_annual_mirror_in_sync ${ok}
EOF

chgrp nodeexp_txt "$PROM_OUT" 2>/dev/null || true
chmod 0644 "$PROM_OUT"


#!/usr/bin/env python3
"""
darksite/wg-refresh-planes.py

This script is intended to keep the master-side WireGuard configs (wg1/wg2/wg3)
in sync with the set of Salt minions.

Your original environment may already have a richer version of this script.
This "release" includes a conservative implementation that:

- Verifies wg configs exist
- Backs up configs with a timestamp
- Restarts wg-quick@wg{1,2,3}

It does NOT attempt to (re)generate peer stanzas, because that requires
your site-specific source of truth (Salt grains/pillars, installer outputs, etc.).

If you already have a working wg-refresh-planes.py on your master, keep it.
"""
from __future__ import annotations
import time
import shutil
import subprocess
from pathlib import Path

def run(cmd: str) -> int:
    p = subprocess.run(["bash","-lc",cmd], text=True)
    return p.returncode

def main() -> None:
    ts = time.strftime("%Y%m%d%H%M%S")
    for iface in ("wg1","wg2","wg3"):
        cfg = Path(f"/etc/wireguard/{iface}.conf")
        if cfg.exists():
            bak = cfg.with_suffix(cfg.suffix + f".bak.{ts}")
            shutil.copy2(cfg, bak)
        # restart even if missing; non-zero is OK
        run(f"systemctl restart wg-quick@{iface}.service || true")

if __name__ == "__main__":
    main()

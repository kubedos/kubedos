#!/usr/bin/env bash
set -euo pipefail

# This helper is optional; it runs /root/darksite/apply.py on the master.
# Adjust variables as needed.

ADMIN_USER="${ADMIN_USER:-todd}"
MASTER_LAN="${MASTER_LAN:-10.78.0.1}"

# Full path to the SSH private key used to reach the master.
SSH_KEY_PATH="${SSH_KEY_PATH:-/home/todd/.ssh/_ed25519}"

log() { echo "[$(date -Is)] $*"; }

run_apply_on_master() {
  log "Running apply.py on master via ${ADMIN_USER}@${MASTER_LAN}"

  local host="${ADMIN_USER}@${MASTER_LAN}"

  ssh     -i "${SSH_KEY_PATH}"     -o StrictHostKeyChecking=no     -o UserKnownHostsFile=/dev/null     -o ConnectTimeout=10     -o BatchMode=yes     "$host"     bash -lc '
      set -euo pipefail
      sleep 15
      test -r /root/darksite/apply.py
      command -v python3 >/dev/null
      sudo -n python3 /root/darksite/apply.py
    '
}

if [[ "${1:-}" == "apply" ]]; then
  run_apply_on_master
else
  echo "Usage: $0 apply"
fi

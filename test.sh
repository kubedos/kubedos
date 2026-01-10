#!/usr/bin/env bash
#
# deploy.sh — Build a full “hub + spokes” Kubernetes lab on a Proxmox host
#
# What this does
#   - Builds custom Debian installer ISOs (per-role) with:
#       * preseed.cfg (fully automated)
#       * baked /darksite payload (optional)
#       * baked ISO-local APT repo snapshot (“darksite apt”, optional)
#       * one-shot systemd bootstrap that runs postinstall.sh on first boot
#   - Deploys VMs on Proxmox (master + minions) and wires them together using
#     multiple WireGuard planes (wg1/wg2/wg3).
#   - Seeds hub metadata (hub.env) and optionally auto-enrolls minions onto hub.
#
# Key improvements vs your pasted draft
#   - Removed duplicated/contradicting definitions (SSH_OPTS/log/require_cmd/darksite_build_apt_repo, etc.)
#   - Unified APT “mode” into REPO_MODE (darksite|connected|both) everywhere
#   - Fixed PRESEED_EXTRA_PKGS default quoting bug
#   - Removed hard-coded “trixie” in postinstall sources; uses DEBIAN_CODENAME
#   - run_apply_on_master uses a configurable SSH key path (no hard-coded /home/todd/.ssh/id_ed25519)
#   - Safer ISO copy/build ordering (copy ISO → then write preseed + darksite)
#
# Usage
#   TARGET=proxmox-all     ./deploy.sh
#   TARGET=proxmox-cluster ./deploy.sh
#   TARGET=proxmox-k8s-ha  ./deploy.sh
#
# Environment overrides
#   REPO_MODE=darksite|connected|both
#   DEBIAN_CODENAME=bookworm|trixie|...
#   DARKSITE_SRC=/path/to/payload/darksite
#   PROXMOX_HOST=...
#   ISO_ORIG=/root/debian-*.iso
#
set -euo pipefail

# =============================================================================
# Repo root + defaults
# =============================================================================
_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
_repo_root="$(git -C "$_script_dir" rev-parse --show-toplevel 2>/dev/null || echo "$_script_dir")"

_default_home() {
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    eval echo "~${SUDO_USER}"
  else
    echo "${HOME:-/root}"
  fi
}

# =============================================================================
# Logging / helpers
# =============================================================================
log()  { echo "[INFO]  $(date '+%F %T') - $*"; }
warn() { echo "[WARN]  $(date '+%F %T') - $*" >&2; }
err()  { echo "[ERROR] $(date '+%F %T') - $*" >&2; }
die()  { err "$*"; exit 1; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }
require_cmd() { have_cmd "$1" || die "Required command not found in PATH: $1"; }

# =============================================================================
# Build artifacts root (must exist early)
# =============================================================================
BUILD_ROOT="${BUILD_ROOT:-/root/builds}"
mkdir -p "$BUILD_ROOT"

# =============================================================================
# Darksite payload source path resolution
# =============================================================================
default_darksite_src() {
  local candidate

  candidate="${_repo_root}/payload/darksite"
  [[ -d "$candidate" ]] && { echo "$candidate"; return 0; }

  candidate="$(_default_home)/foundrybot/payload/darksite"
  [[ -d "$candidate" ]] && { echo "$candidate"; return 0; }

  candidate="/root/foundrybot/payload/darksite"
  [[ -d "$candidate" ]] && { echo "$candidate"; return 0; }

  echo "$(_default_home)/foundrybot/payload/darksite"
}

DARKSITE_SRC="${DARKSITE_SRC:-$(default_darksite_src)}"

# =============================================================================
# Repo / installer mode (CONNECTED vs DARKSITE vs BOTH)
# =============================================================================
# REPO_MODE:
#   darksite  = installer uses ONLY the ISO-embedded repo (true time capsule)
#   connected = installer uses network mirrors only
#   both      = prefer ISO repo but allow mirrors
REPO_MODE="${REPO_MODE:-darksite}"                    # darksite | connected | both
DEBIAN_CODENAME="${DEBIAN_CODENAME:-trixie}"          # bookworm, trixie, etc
ARCH="${ARCH:-amd64}"                                # amd64, arm64, etc

# Components for connected mirrors and for darksite snapshot resolution
APT_COMPONENTS="${APT_COMPONENTS:-main contrib non-free non-free-firmware}"

# Root package set to “time-capsule” into the ISO’s darksite repo.
DARKSITE_ROOT_PKGS="${DARKSITE_ROOT_PKGS:-\
ca-certificates curl wget gnupg sudo openssh-server \
vim-tiny less net-tools iproute2 pciutils usbutils \
rsync tmux jq git \
}"

# Darksite repo build behavior
DARKSITE_BUILD_ON_DEMAND="${DARKSITE_BUILD_ON_DEMAND:-yes}"   # yes|no
DARKSITE_CLEAN_BUILD="${DARKSITE_CLEAN_BUILD:-1}"            # 1=yes wipe dest
DARKSITE_BUILDER="${DARKSITE_BUILDER:-auto}"                 # auto|native|container
CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-docker}"             # docker|podman
DEBIAN_CONTAINER_IMAGE="${DEBIAN_CONTAINER_IMAGE:-debian:${DEBIAN_CODENAME}}"

log "[*] REPO_MODE=$REPO_MODE CODENAME=$DEBIAN_CODENAME ARCH=$ARCH"

# =============================================================================
# Preseed / installer behaviour
# =============================================================================
PRESEED_LOCALE="${PRESEED_LOCALE:-en_US.UTF-8}"
PRESEED_KEYMAP="${PRESEED_KEYMAP:-us}"
PRESEED_TIMEZONE="${PRESEED_TIMEZONE:-America/Vancouver}"
PRESEED_ROOT_PASSWORD="${PRESEED_ROOT_PASSWORD:-root}"
PRESEED_BOOTDEV="${PRESEED_BOOTDEV:-/dev/sda}"

# FIXED: proper default with spaces
PRESEED_EXTRA_PKGS="${PRESEED_EXTRA_PKGS:-openssh-server rsync}"

# =============================================================================
# Proxmox target selector
# =============================================================================
TARGET="${TARGET:-proxmox-all}"
INPUT="${INPUT:-1}"

case "$INPUT" in
  1|fiend)  PROXMOX_HOST="${PROXMOX_HOST:-10.100.10.225}" ;;
  2|dragon) PROXMOX_HOST="${PROXMOX_HOST:-10.100.10.226}" ;;
  3|lion)   PROXMOX_HOST="${PROXMOX_HOST:-10.100.10.227}" ;;
  *)        die "Unknown INPUT=$INPUT (expected 1|fiend, 2|dragon, 3|lion)" ;;
esac

# =============================================================================
# ISO source / Proxmox storage IDs
# =============================================================================
ISO_ORIG="${ISO_ORIG:-/root/debian-13.2.0-amd64-netinst.iso}"
ISO_STORAGE="${ISO_STORAGE:-local}"
VM_STORAGE="${VM_STORAGE:-local-zfs}"

# =============================================================================
# LAN / DNS settings
# =============================================================================
NETMASK="${NETMASK:-255.255.255.0}"
GATEWAY="${GATEWAY:-10.100.10.1}"
NAMESERVER="${NAMESERVER:-10.100.10.2 10.100.10.3}"
DOMAIN="${DOMAIN:-unixbox.net}"

# =============================================================================
# Master + inventory (IDs + IPs)
# =============================================================================
MASTER_LAN="${MASTER_LAN:-10.100.10.224}"
MASTER_NAME="${MASTER_NAME:-master}"
MASTER_ID="${MASTER_ID:-2000}"

PROM_ID="${PROM_ID:-2001}"; PROM_NAME="${PROM_NAME:-prometheus}"; PROM_IP="${PROM_IP:-10.100.10.223}"
GRAF_ID="${GRAF_ID:-2002}"; GRAF_NAME="${GRAF_NAME:-grafana}";    GRAF_IP="${GRAF_IP:-10.100.10.222}"
STOR_ID="${STOR_ID:-2003}"; STOR_NAME="${STOR_NAME:-storage}";    STOR_IP="${STOR_IP:-10.100.10.221}"

ETCD1_ID="${ETCD1_ID:-2004}"; ETCD1_NAME="${ETCD1_NAME:-etcd-1}"; ETCD1_IP="${ETCD1_IP:-10.100.10.220}"
ETCD2_ID="${ETCD2_ID:-2005}"; ETCD2_NAME="${ETCD2_NAME:-etcd-2}"; ETCD2_IP="${ETCD2_IP:-10.100.10.219}"
ETCD3_ID="${ETCD3_ID:-2006}"; ETCD3_NAME="${ETCD3_NAME:-etcd-3}"; ETCD3_IP="${ETCD3_IP:-10.100.10.218}"

K8SCP1_ID="${K8SCP1_ID:-2007}"; K8SCP1_NAME="${K8SCP1_NAME:-cp-1}"; K8SCP1_IP="${K8SCP1_IP:-10.100.10.217}"
K8SCP2_ID="${K8SCP2_ID:-2008}"; K8SCP2_NAME="${K8SCP2_NAME:-cp-2}"; K8SCP2_IP="${K8SCP2_IP:-10.100.10.216}"
K8SCP3_ID="${K8SCP3_ID:-2009}"; K8SCP3_NAME="${K8SCP3_NAME:-cp-3}"; K8SCP3_IP="${K8SCP3_IP:-10.100.10.215}"

K8SW1_ID="${K8SW1_ID:-2010}"; K8SW1_NAME="${K8SW1_NAME:-w-1}"; K8SW1_IP="${K8SW1_IP:-10.100.10.214}"
K8SW2_ID="${K8SW2_ID:-2011}"; K8SW2_NAME="${K8SW2_NAME:-w-2}"; K8SW2_IP="${K8SW2_IP:-10.100.10.213}"
K8SW3_ID="${K8SW3_ID:-2012}"; K8SW3_NAME="${K8SW3_NAME:-w-3}"; K8SW3_IP="${K8SW3_IP:-10.100.10.212}"

K8SLB1_ID="${K8SLB1_ID:-2013}"; K8SLB1_NAME="${K8SLB1_NAME:-lb-1}"; K8SLB1_IP="${K8SLB1_IP:-10.100.10.211}"
K8SLB2_ID="${K8SLB2_ID:-2014}"; K8SLB2_NAME="${K8SLB2_NAME:-lb-2}"; K8SLB2_IP="${K8SLB2_IP:-10.100.10.210}"
K8SLB3_ID="${K8SLB3_ID:-2015}"; K8SLB3_NAME="${K8SLB3_NAME:-lb-3}"; K8SLB3_IP="${K8SLB3_IP:-10.100.10.209}"

# =============================================================================
# WireGuard hub planes (on MASTER)
# =============================================================================
WG1_IP="${WG1_IP:-10.78.0.1/16}"; WG1_PORT="${WG1_PORT:-51821}"
WG2_IP="${WG2_IP:-10.79.0.1/16}"; WG2_PORT="${WG2_PORT:-51822}"
WG3_IP="${WG3_IP:-10.80.0.1/16}"; WG3_PORT="${WG3_PORT:-51823}"
WG_ALLOWED_CIDR="${WG_ALLOWED_CIDR:-10.78.0.0/16,10.79.0.0/16,10.80.0.0/16}"

# =============================================================================
# Per-node WG /32 allocations
# =============================================================================
PROM_WG1="${PROM_WG1:-10.78.0.2/32}"; PROM_WG2="${PROM_WG2:-10.79.0.2/32}"; PROM_WG3="${PROM_WG3:-10.80.0.2/32}"
GRAF_WG1="${GRAF_WG1:-10.78.0.3/32}"; GRAF_WG2="${GRAF_WG2:-10.79.0.3/32}"; GRAF_WG3="${GRAF_WG3:-10.80.0.3/32}"
STOR_WG1="${STOR_WG1:-10.78.0.4/32}"; STOR_WG2="${STOR_WG2:-10.79.0.4/32}"; STOR_WG3="${STOR_WG3:-10.80.0.4/32}"

ETCD1_WG1="${ETCD1_WG1:-10.78.0.5/32}"; ETCD1_WG2="${ETCD1_WG2:-10.79.0.5/32}"; ETCD1_WG3="${ETCD1_WG3:-10.80.0.5/32}"
ETCD2_WG1="${ETCD2_WG1:-10.78.0.6/32}"; ETCD2_WG2="${ETCD2_WG2:-10.79.0.6/32}"; ETCD2_WG3="${ETCD2_WG3:-10.80.0.6/32}"
ETCD3_WG1="${ETCD3_WG1:-10.78.0.7/32}"; ETCD3_WG2="${ETCD3_WG2:-10.79.0.7/32}"; ETCD3_WG3="${ETCD3_WG3:-10.80.0.7/32}"

K8SCP1_WG1="${K8SCP1_WG1:-10.78.0.8/32}";  K8SCP1_WG2="${K8SCP1_WG2:-10.79.0.8/32}";  K8SCP1_WG3="${K8SCP1_WG3:-10.80.0.8/32}"
K8SCP2_WG1="${K8SCP2_WG1:-10.78.0.9/32}";  K8SCP2_WG2="${K8SCP2_WG2:-10.79.0.9/32}";  K8SCP2_WG3="${K8SCP2_WG3:-10.80.0.9/32}"
K8SCP3_WG1="${K8SCP3_WG1:-10.78.0.10/32}"; K8SCP3_WG2="${K8SCP3_WG2:-10.79.0.10/32}"; K8SCP3_WG3="${K8SCP3_WG3:-10.80.0.10/32}"

K8SW1_WG1="${K8SW1_WG1:-10.78.0.11/32}"; K8SW1_WG2="${K8SW1_WG2:-10.79.0.11/32}"; K8SW1_WG3="${K8SW1_WG3:-10.80.0.11/32}"
K8SW2_WG1="${K8SW2_WG1:-10.78.0.12/32}"; K8SW2_WG2="${K8SW2_WG2:-10.79.0.12/32}"; K8SW2_WG3="${K8SW2_WG3:-10.80.0.12/32}"
K8SW3_WG1="${K8SW3_WG1:-10.78.0.13/32}"; K8SW3_WG2="${K8SW3_WG2:-10.79.0.13/32}"; K8SW3_WG3="${K8SW3_WG3:-10.80.0.13/32}"

K8SLB1_WG1="${K8SLB1_WG1:-10.78.0.14/32}"; K8SLB1_WG2="${K8SLB1_WG2:-10.79.0.14/32}"; K8SLB1_WG3="${K8SLB1_WG3:-10.80.0.14/32}"
K8SLB2_WG1="${K8SLB2_WG1:-10.78.0.15/32}"; K8SLB2_WG2="${K8SLB2_WG2:-10.79.0.15/32}"; K8SLB2_WG3="${K8SLB2_WG3:-10.80.0.15/32}"
K8SLB3_WG1="${K8SLB3_WG1:-10.78.0.16/32}"; K8SLB3_WG2="${K8SLB3_WG2:-10.79.0.16/32}"; K8SLB3_WG3="${K8SLB3_WG3:-10.80.0.16/32}"

# =============================================================================
# VM sizing
# =============================================================================
MASTER_MEM="${MASTER_MEM:-4096}"; MASTER_CORES="${MASTER_CORES:-4}";  MASTER_DISK_GB="${MASTER_DISK_GB:-40}"
MINION_MEM="${MINION_MEM:-4096}"; MINION_CORES="${MINION_CORES:-4}"; MINION_DISK_GB="${MINION_DISK_GB:-32}"
K8S_LB_MEM="${K8S_LB_MEM:-2048}"; K8S_LB_CORES="${K8S_LB_CORES:-2}";  K8S_LB_DISK_GB="${K8S_LB_DISK_GB:-16}"
K8S_CP_MEM="${K8S_CP_MEM:-8192}"; K8S_CP_CORES="${K8S_CP_CORES:-4}";  K8S_CP_DISK_GB="${K8S_CP_DISK_GB:-50}"
K8S_WK_MEM="${K8S_WK_MEM:-8192}"; K8S_WK_CORES="${K8S_WK_CORES:-4}";  K8S_WK_DISK_GB="${K8S_WK_DISK_GB:-60}"

# =============================================================================
# Admin / auth
# =============================================================================
ADMIN_USER="${ADMIN_USER:-todd}"
ADMIN_PUBKEY_FILE="${ADMIN_PUBKEY_FILE:-}"
SSH_PUBKEY="${SSH_PUBKEY:-ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINgqdaF+C41xwLS41+dOTnpsrDTPkAwo4Zejn4tb0lOt todd@onyx.unixbox.net}"
ALLOW_ADMIN_PASSWORD="${ALLOW_ADMIN_PASSWORD:-no}" # yes|no

# =============================================================================
# Enrollment SSH keypair (for WG enrollment & registration)
# =============================================================================
ENROLL_KEY_NAME="${ENROLL_KEY_NAME:-enroll_ed25519}"
ENROLL_KEY_DIR="$BUILD_ROOT/keys"
ENROLL_KEY_PRIV="$ENROLL_KEY_DIR/${ENROLL_KEY_NAME}"
ENROLL_KEY_PUB="$ENROLL_KEY_DIR/${ENROLL_KEY_NAME}.pub"

ensure_enroll_keypair() {
  mkdir -p "$ENROLL_KEY_DIR"
  if [[ ! -f "$ENROLL_KEY_PRIV" || ! -f "$ENROLL_KEY_PUB" ]]; then
    log "Generating cluster enrollment SSH keypair in $ENROLL_KEY_DIR"
    ssh-keygen -t ed25519 -N "" -f "$ENROLL_KEY_PRIV" -C "enroll@cluster" >/dev/null
  else
    log "Using existing enrollment keypair in $ENROLL_KEY_DIR"
  fi
}

# =============================================================================
# SSH helpers (build host → Proxmox / remote)
# =============================================================================
KNOWN_HOSTS="${KNOWN_HOSTS:-${BUILD_ROOT}/known_hosts}"
mkdir -p "$(dirname "$KNOWN_HOSTS")"
touch "$KNOWN_HOSTS"
chmod 600 "$KNOWN_HOSTS"

SSH_OPTS=(
  -o LogLevel=ERROR
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile="$KNOWN_HOSTS"
  -o GlobalKnownHostsFile=/dev/null
  -o CheckHostIP=yes
  -o ConnectTimeout=8
  -o BatchMode=yes
)

sssh() { ssh -q "${SSH_OPTS[@]}" "$@"; }
sscp() { scp -q "${SSH_OPTS[@]}" "$@"; }

# =============================================================================
# DARKSITE APT repo snapshot builder
# =============================================================================
ensure_container_runtime() {
  have_cmd "$CONTAINER_RUNTIME" || die "Container runtime not found: $CONTAINER_RUNTIME (set CONTAINER_RUNTIME=docker or install podman/docker)"
}

darksite_build_apt_repo__native() {
  local dest="$1"
  local tmp; tmp="$(mktemp -d)"
  mkdir -p "$dest"
  have_cmd apt-get || die "native darksite builder requires apt-get (not available). Set DARKSITE_BUILDER=container."

  local need=()
  for c in apt-rdepends dpkg-scanpackages apt-ftparchive gzip; do
    have_cmd "$c" || need+=("$c")
  done
  if (( ${#need[@]} > 0 )); then
    log "Installing darksite build deps: ${need[*]}"
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y apt-rdepends dpkg-dev apt-utils gnupg ca-certificates gzip
    hash -r
  fi

  require_cmd apt-rdepends
  require_cmd dpkg-scanpackages
  require_cmd apt-ftparchive
  require_cmd gzip

  if [[ "${DARKSITE_CLEAN_BUILD:-1}" == "1" ]]; then
    rm -rf "${dest:?}/"*
  fi

  log "Building darksite APT repo into: $dest"
  log "Root packages: ${DARKSITE_ROOT_PKGS}"

  mapfile -t pkgs < <(
    apt-rdepends -f Depends,PreDepends ${DARKSITE_ROOT_PKGS} 2>/dev/null \
      | sed -n \
          's/^[[:space:]]*Depends:[[:space:]]*//p;
           s/^[[:space:]]*PreDepends:[[:space:]]*//p;
           /^[A-Za-z0-9]/p' \
      | sed 's/[[:space:]]*(.*)//g' \
      | tr '|' '\n' \
      | awk '{print $1}' \
      | grep -E '^[A-Za-z0-9][A-Za-z0-9+.-]+$' \
      | sort -u
  )

  (
    cd "$tmp"
    for p in "${pkgs[@]}"; do
      apt-get download "$p" >/dev/null 2>&1 || true
    done
  )

  shopt -s nullglob
  local debs=( "$tmp"/*.deb )
  (( ${#debs[@]} > 0 )) || die "Darksite repo build failed: no .deb files were downloaded."
  mv "$tmp"/*.deb "$dest/"

  ( cd "$dest" && dpkg-scanpackages . /dev/null > Packages )
  gzip -9c "$dest/Packages" > "$dest/Packages.gz"
  ( cd "$dest" && apt-ftparchive release . > Release )

  rm -rf "$tmp"
  log "Darksite APT repo ready: $dest"
}

darksite_build_apt_repo__container() {
  local dest="$1"
  mkdir -p "$dest"
  ensure_container_runtime

  log "Building darksite APT repo in container: ${DEBIAN_CONTAINER_IMAGE} (runtime=$CONTAINER_RUNTIME)"
  log "Output dir: $dest"

  local inner_script
  inner_script="$(cat <<'EOS'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get install -y apt-rdepends dpkg-dev apt-utils gnupg ca-certificates gzip

DEST="/out"
TMP="$(mktemp -d)"
mkdir -p "$DEST"

if [[ "${DARKSITE_CLEAN_BUILD:-1}" == "1" ]]; then
  rm -rf "${DEST:?}/"*
fi

echo "[container] root packages: ${DARKSITE_ROOT_PKGS}"

mapfile -t pkgs < <(
  apt-rdepends -f Depends,PreDepends ${DARKSITE_ROOT_PKGS} 2>/dev/null \
    | sed -n \
        's/^[[:space:]]*Depends:[[:space:]]*//p;
         s/^[[:space:]]*PreDepends:[[:space:]]*//p;
         /^[A-Za-z0-9]/p' \
    | sed 's/[[:space:]]*(.*)//g' \
    | tr '|' '\n' \
    | awk '{print $1}' \
    | grep -E '^[A-Za-z0-9][A-Za-z0-9+.-]+$' \
    | sort -u
)

(
  cd "$TMP"
  for p in "${pkgs[@]}"; do
    apt-get download "$p" >/dev/null 2>&1 || true
  done
)

shopt -s nullglob
debs=( "$TMP"/*.deb )
if (( ${#debs[@]} == 0 )); then
  echo "[container] ERROR: no debs downloaded" >&2
  exit 2
fi

mv "$TMP"/*.deb "$DEST/"

( cd "$DEST" && dpkg-scanpackages . /dev/null > Packages )
gzip -9c "$DEST/Packages" > "$DEST/Packages.gz"
( cd "$DEST" && apt-ftparchive release . > Release )

rm -rf "$TMP"
echo "[container] OK: repo built in $DEST"
EOS
)"

  if [[ "$CONTAINER_RUNTIME" == "podman" ]]; then
    podman run --rm --net=host \
      -e DARKSITE_ROOT_PKGS="${DARKSITE_ROOT_PKGS}" \
      -e DARKSITE_CLEAN_BUILD="${DARKSITE_CLEAN_BUILD:-1}" \
      -v "$dest:/out:Z" \
      "${DEBIAN_CONTAINER_IMAGE}" \
      bash -lc "$inner_script"
  else
    docker run --rm --network=host \
      -e DARKSITE_ROOT_PKGS="${DARKSITE_ROOT_PKGS}" \
      -e DARKSITE_CLEAN_BUILD="${DARKSITE_CLEAN_BUILD:-1}" \
      -v "$dest:/out" \
      "${DEBIAN_CONTAINER_IMAGE}" \
      bash -lc "$inner_script"
  fi

  log "Darksite APT repo ready: $dest"
}

darksite_build_apt_repo() {
  local dest="$1"
  local mode="$DARKSITE_BUILDER"
  if [[ "$mode" == "auto" ]]; then
    if have_cmd apt-get; then
      mode="native"
    else
      mode="container"
    fi
  fi

  case "$mode" in
    native)    darksite_build_apt_repo__native "$dest" ;;
    container) darksite_build_apt_repo__container "$dest" ;;
    *) die "Unknown DARKSITE_BUILDER=$DARKSITE_BUILDER (expected auto|native|container)" ;;
  esac
}

# =============================================================================
# Preseed APT snippet generator (installer stage)
# =============================================================================
preseed_emit_apt_snippet() {
  case "${REPO_MODE}" in
    darksite)
      cat <<'EOF'
# --- DARKSITE APT (local only) ---
d-i apt-setup/use_mirror boolean false
d-i apt-cdrom-setup/another boolean false

# ISO-local flat repo baked at /cdrom/darksite/apt
d-i apt-setup/local0/repository string deb [trusted=yes] file:/cdrom/darksite/apt ./
d-i apt-setup/local0/comment string Darksite ISO repo
d-i apt-setup/local0/source boolean false

# Don't use security mirrors when darksite-only
d-i apt-setup/security-updates boolean false
EOF
      ;;
    both)
      cat <<'EOF'
# --- BOTH APT (local + mirror) ---
d-i apt-setup/use_mirror boolean true
d-i mirror/country string manual
d-i mirror/http/hostname string deb.debian.org
d-i mirror/http/directory string /debian
d-i mirror/http/proxy string

d-i apt-cdrom-setup/another boolean false
d-i apt-setup/local0/repository string deb [trusted=yes] file:/cdrom/darksite/apt ./
d-i apt-setup/local0/comment string Darksite ISO repo
d-i apt-setup/local0/source boolean false
EOF
      ;;
    *)
      cat <<'EOF'
# --- CONNECTED APT (mirror) ---
d-i apt-setup/use_mirror boolean true
d-i mirror/country string manual
d-i mirror/http/hostname string deb.debian.org
d-i mirror/http/directory string /debian
d-i mirror/http/proxy string
EOF
      ;;
  esac
}

# =============================================================================
# PROXMOX helpers
# =============================================================================
pmx() { sssh root@"$PROXMOX_HOST" "$@"; }

pmx_vm_state() { pmx "qm status $1 2>/dev/null | awk '{print tolower(\$2)}'" || echo "unknown"; }

pmx_wait_for_state() {
  local vmid="$1" want="$2" timeout="${3:-2400}" start state
  start=$(date +%s)
  log "Waiting for VM $vmid to be $want ..."
  while :; do
    state="$(pmx_vm_state "$vmid")"
    [[ "$state" == "$want" ]] && { log "VM $vmid is $state"; return 0; }
    (( $(date +%s) - start > timeout )) && { err "Timeout: VM $vmid not $want (state=$state)"; return 1; }
    sleep 5
  done
}

pmx_wait_qga() {
  local vmid="$1" timeout="${2:-1200}" start; start=$(date +%s)
  log "Waiting for QEMU Guest Agent on VM $vmid ..."
  while :; do
    if pmx "qm agent $vmid ping >/dev/null 2>&1 || qm guest ping $vmid >/dev/null 2>&1"; then
      log "QGA ready on VM $vmid"; return 0
    fi
    (( $(date +%s) - start > timeout )) && { err "Timeout waiting for QGA on VM $vmid"; return 1; }
    sleep 3
  done
}

pmx_guest_exec() {
  local vmid="$1"; shift
  pmx "qm guest exec $vmid -- $* >/dev/null 2>&1 || true"
}

pmx_guest_cat() {
  local vmid="$1" path="$2"
  pmx "qm guest exec $vmid --output-format json -- /bin/cat '$path' 2>/dev/null" \
    | sed -n 's/.*"out-data"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | base64 -d 2>/dev/null || return 2
}

pmx_upload_iso() {
  local iso_file="$1" iso_base
  iso_base="$(basename "$iso_file")"
  sscp "$iso_file" "root@${PROXMOX_HOST}:/var/lib/vz/template/iso/$iso_base"
  echo "$iso_base"
}

pmx_deploy() {
  local vmid="$1" vmname="$2" iso_file="$3" mem="$4" cores="$5" disk_gb="$6"
  local iso_base
  log "Uploading ISO to Proxmox: $(basename "$iso_file")"
  iso_base="$(pmx_upload_iso "$iso_file")"

  pmx \
    VMID="$vmid" VMNAME="${vmname}.${DOMAIN}-$vmid" FINAL_ISO="$iso_base" \
    VM_STORAGE="$VM_STORAGE" ISO_STORAGE="$ISO_STORAGE" \
    DISK_SIZE_GB="$disk_gb" MEMORY_MB="$mem" CORES="$cores" 'bash -s' <<'EOSSH'
set -euo pipefail
qm destroy "$VMID" --purge >/dev/null 2>&1 || true

qm create "$VMID" \
  --name "$VMNAME" \
  --memory "$MEMORY_MB" --cores "$CORES" \
  --cpu host \
  --sockets 1 \
  --machine q35 \
  --net0 virtio,bridge=vmbr0,firewall=1 \
  --scsihw virtio-scsi-single \
  --scsi0 ${VM_STORAGE}:${DISK_SIZE_GB} \
  --serial0 socket \
  --ostype l26 \
  --agent enabled=1,fstrim_cloned_disks=1

qm set "$VMID" --bios ovmf
qm set "$VMID" --efidisk0 ${VM_STORAGE}:0,efitype=4m,pre-enrolled-keys=1
qm set "$VMID" --tpmstate ${VM_STORAGE}:1,version=v2.0,size=4M

qm set "$VMID" --ide2 ${ISO_STORAGE}:iso/${FINAL_ISO},media=cdrom
qm set "$VMID" --boot order=ide2
qm start "$VMID"
EOSSH
}

wait_poweroff() { pmx_wait_for_state "$1" "stopped" "${2:-2400}"; }

boot_from_disk() {
  local vmid="$1"
  pmx "qm set $vmid --delete ide2; qm set $vmid --boot order=scsi0; qm start $vmid"
  pmx_wait_for_state "$vmid" "running" 600
}

# =============================================================================
# ISO builder
# =============================================================================
mk_iso() {
  local name="$1"              # hostname short name
  local postinstall_src="$2"   # postinstall.sh path
  local iso_out="$3"           # output ISO path
  local static_ip="${4:-}"     # optional static ip

  require_cmd xorriso
  require_cmd mount
  require_cmd umount

  [[ -f "$ISO_ORIG" ]] || die "ISO_ORIG not found: $ISO_ORIG"

  local build="$BUILD_ROOT/$name"
  local mnt="$build/mnt"
  local cust="$build/custom"

  rm -rf "$build" 2>/dev/null || true
  mkdir -p "$mnt" "$cust"

  # Copy ISO tree
  (
    set -euo pipefail
    trap 'umount -f "$mnt" 2>/dev/null || true' EXIT
    mount -o loop,ro "$ISO_ORIG" "$mnt"
    # rsync preserves structure better than cp
    rsync -aH "$mnt/" "$cust/"
  )

  # Bake darksite payload
  local dark="$cust/darksite"
  mkdir -p "$dark"

  log "mk_iso($name): DARKSITE_SRC=${DARKSITE_SRC}"
  if [[ -d "$DARKSITE_SRC" ]]; then
    rsync -a --delete "$DARKSITE_SRC"/ "$dark"/
  else
    warn "DARKSITE_SRC not found: $DARKSITE_SRC (skipping extra payload)"
  fi

  ensure_enroll_keypair
  install -m0600 "$ENROLL_KEY_PRIV" "$dark/enroll_ed25519"
  install -m0644 "$ENROLL_KEY_PUB"  "$dark/enroll_ed25519.pub"

  # ISO-local APT snapshot
  if [[ "$REPO_MODE" == "darksite" || "$REPO_MODE" == "both" ]]; then
    if [[ "${DARKSITE_BUILD_ON_DEMAND}" == "yes" ]]; then
      log "Building ISO-local APT repo snapshot into $dark/apt"
      darksite_build_apt_repo "$dark/apt"
    else
      warn "DARKSITE_BUILD_ON_DEMAND=no; expecting repo already at $dark/apt"
    fi
  fi

  # Postinstall
  install -m0755 "$postinstall_src" "$dark/postinstall.sh"

  # One-shot bootstrap unit
  cat >"$dark/bootstrap.service" <<'EOF'
[Unit]
Description=Initial Bootstrap Script (One-time)
After=network-online.target
Wants=network-online.target
ConditionPathExists=/root/darksite/postinstall.sh
ConditionPathExists=!/root/.bootstrap_done

[Service]
Type=oneshot
ExecStart=/bin/bash -lc '/root/darksite/postinstall.sh'
StandardOutput=journal+console
StandardError=journal+console
TimeoutStartSec=0
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  # Seed env file (installer copies to /etc/environment.d)
  cat >"$dark/99-provision.conf" <<EOF
DOMAIN=${DOMAIN}
ADMIN_USER=${ADMIN_USER}
MASTER_LAN=${MASTER_LAN}
ALLOW_ADMIN_PASSWORD=${ALLOW_ADMIN_PASSWORD}
WG_ALLOWED_CIDR=${WG_ALLOWED_CIDR}
WG1_IP=${WG1_IP}
WG2_IP=${WG2_IP}
WG3_IP=${WG3_IP}
WG1_PORT=${WG1_PORT}
WG2_PORT=${WG2_PORT}
WG3_PORT=${WG3_PORT}
REPO_MODE=${REPO_MODE}
DEBIAN_CODENAME=${DEBIAN_CODENAME}
EOF

  # Admin authorized key seed
  if [[ -n "${SSH_PUBKEY:-}" ]]; then
    printf '%s\n' "$SSH_PUBKEY" >"$dark/authorized_keys.${ADMIN_USER}"
  elif [[ -n "${ADMIN_PUBKEY_FILE:-}" && -r "$ADMIN_PUBKEY_FILE" ]]; then
    cat "$ADMIN_PUBKEY_FILE" >"$dark/authorized_keys.${ADMIN_USER}"
  else
    : >"$dark/authorized_keys.${ADMIN_USER}"
  fi
  chmod 0644 "$dark/authorized_keys.${ADMIN_USER}"

  # Network block
  local NETBLOCK
  if [[ -z "${static_ip:-}" ]]; then
    NETBLOCK="d-i netcfg/choose_interface select auto
d-i netcfg/disable_dhcp boolean false
d-i netcfg/get_hostname string ${name}
d-i netcfg/hostname string ${name}
d-i netcfg/get_domain string ${DOMAIN}"
  else
    NETBLOCK="d-i netcfg/choose_interface select auto
d-i netcfg/get_hostname string ${name}
d-i netcfg/hostname string ${name}
d-i netcfg/get_domain string ${DOMAIN}
d-i netcfg/disable_dhcp boolean true
d-i netcfg/get_ipaddress string ${static_ip}
d-i netcfg/get_netmask string ${NETMASK}
d-i netcfg/get_gateway string ${GATEWAY}
d-i netcfg/get_nameservers string ${NAMESERVER}"
  fi

  local APT_SNIPPET
  APT_SNIPPET="$(preseed_emit_apt_snippet)"

  # Write preseed.cfg
  cat >"$cust/preseed.cfg" <<'EOF'
d-i debconf/frontend select Noninteractive
d-i debconf/priority string critical

d-i apt-cdrom-setup/another boolean false

d-i debian-installer/locale string __PRESEED_LOCALE__
d-i console-setup/ask_detect boolean false
d-i keyboard-configuration/xkb-keymap select __PRESEED_KEYMAP__

__NETBLOCK__

__APT_SNIPPET__

d-i passwd/root-login boolean true
d-i passwd/root-password password __PRESEED_ROOT_PASSWORD__
d-i passwd/root-password-again password __PRESEED_ROOT_PASSWORD__
d-i passwd/make-user boolean false

d-i time/zone string __PRESEED_TIMEZONE__
d-i clock-setup/utc boolean true
d-i clock-setup/ntp boolean true

d-i partman-auto/method string lvm
d-i partman-auto/choose_recipe select atomic
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true
d-i partman/choose_partition select finish
d-i partman-lvm/confirm boolean true
d-i partman-lvm/confirm_nooverwrite boolean true
d-i partman-auto-lvm/guided_size string max

d-i pkgsel/run_tasksel boolean false
d-i pkgsel/include string __PRESEED_EXTRA_PKGS__
d-i pkgsel/upgrade select none
d-i pkgsel/ignore-recommends boolean true
popularity-contest popularity-contest/participate boolean false

d-i grub-installer/only_debian boolean true
d-i grub-installer/bootdev string __PRESEED_BOOTDEV__

# Late command: copy darksite and enable bootstrap
d-i preseed/late_command string \
  set -e; \
  FQDN="__FQDN__"; SHORT="__SHORT__"; \
  echo "$FQDN" > /target/etc/hostname; \
  if grep -q '^127\.0\.1\.1' /target/etc/hosts; then \
    sed -ri "s/^127\.0\.1\.1.*/127.0.1.1\t$FQDN\t$SHORT/" /target/etc/hosts; \
  else \
    printf '\n127.0.1.1\t%s\t%s\n' "$FQDN" "$SHORT" >> /target/etc/hosts; \
  fi; \
  mkdir -p /target/root/darksite; \
  cp -a /cdrom/darksite/. /target/root/darksite/; \
  in-target install -d -m0755 /etc/environment.d; \
  in-target install -m0644 /root/darksite/99-provision.conf /etc/environment.d/99-provision.conf; \
  in-target install -m0644 /root/darksite/bootstrap.service /etc/systemd/system/bootstrap.service; \
  in-target systemctl daemon-reload; \
  in-target systemctl enable bootstrap.service; \
  in-target /bin/systemctl --no-block poweroff || true

d-i cdrom-detect/eject boolean true
d-i finish-install/reboot_in_progress note
d-i finish-install/exit-installer boolean true
d-i debian-installer/exit/poweroff boolean true
EOF

  local fqdn="${name}.${DOMAIN}"
  sed -i \
    -e "s|__PRESEED_LOCALE__|${PRESEED_LOCALE}|g" \
    -e "s|__PRESEED_KEYMAP__|${PRESEED_KEYMAP}|g" \
    -e "s|__PRESEED_ROOT_PASSWORD__|${PRESEED_ROOT_PASSWORD}|g" \
    -e "s|__PRESEED_TIMEZONE__|${PRESEED_TIMEZONE}|g" \
    -e "s|__PRESEED_EXTRA_PKGS__|${PRESEED_EXTRA_PKGS}|g" \
    -e "s|__PRESEED_BOOTDEV__|${PRESEED_BOOTDEV}|g" \
    -e "s|__FQDN__|${fqdn}|g" \
    -e "s|__SHORT__|${name}|g" \
    "$cust/preseed.cfg"

  export NETBLOCK APT_SNIPPET
  perl -0777 -i -pe 's/__NETBLOCK__/$ENV{NETBLOCK}/g' "$cust/preseed.cfg"
  perl -0777 -i -pe 's/__APT_SNIPPET__/$ENV{APT_SNIPPET}/g' "$cust/preseed.cfg"

  # Boot args patch
  local KARGS="auto=true priority=critical preseed/file=/cdrom/preseed.cfg ---"

  if [[ -f "$cust/isolinux/txt.cfg" ]]; then
    cat >>"$cust/isolinux/txt.cfg" <<EOF
label auto
  menu label ^auto (preseed)
  kernel /install.amd/vmlinuz
  append initrd=/install.amd/initrd.gz $KARGS
EOF
    sed -i 's/^default .*/default auto/' "$cust/isolinux/isolinux.cfg" 2>/dev/null || true
  fi

  local cfg
  for cfg in \
    "$cust/boot/grub/grub.cfg" \
    "$cust/boot/grub/x86_64-efi/grub.cfg" \
    "$cust/EFI/boot/grub.cfg"
  do
    [[ -f "$cfg" ]] || continue
    sed -i 's/^set[[:space:]]\+timeout=.*/set timeout=1/' "$cfg" 2>/dev/null || true
    sed -i "s#^\([[:space:]]*linux[[:space:]]\+\S\+\)#\1 $KARGS#g" "$cfg" || true
  done

  # Detect EFI image path
  local efi_img=""
  if [[ -f "$cust/boot/grub/efi.img" ]]; then
    efi_img="boot/grub/efi.img"
  elif [[ -f "$cust/efi.img" ]]; then
    efi_img="efi.img"
  fi

  # Repack ISO (BIOS+UEFI if possible)
  if [[ -f "$cust/isolinux/isolinux.bin" && -f /usr/share/syslinux/isohdpfx.bin ]]; then
    log "Repacking ISO (hybrid) -> $iso_out"
    if [[ -n "$efi_img" ]]; then
      xorriso -as mkisofs \
        -o "$iso_out" \
        -r -J -joliet-long -l \
        -isohybrid-mbr /usr/share/syslinux/isohdpfx.bin \
        -b isolinux/isolinux.bin \
        -c isolinux/boot.cat \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        -eltorito-alt-boot \
        -e "$efi_img" \
        -no-emul-boot -isohybrid-gpt-basdat \
        "$cust"
    else
      xorriso -as mkisofs \
        -o "$iso_out" \
        -r -J -joliet-long -l \
        -isohybrid-mbr /usr/share/syslinux/isohdpfx.bin \
        -b isolinux/isolinux.bin \
        -c isolinux/boot.cat \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        "$cust"
    fi
  else
    [[ -n "$efi_img" ]] || die "EFI image not found in ISO tree; cannot build bootable ISO"
    log "Repacking ISO (UEFI-only) -> $iso_out"
    xorriso -as mkisofs \
      -o "$iso_out" \
      -r -J -joliet-long -l \
      -eltorito-alt-boot \
      -e "$efi_img" \
      -no-emul-boot -isohybrid-gpt-basdat \
      "$cust"
  fi
}

# =============================================================================
# MASTER postinstall emitter
# =============================================================================
emit_postinstall_master() {
  local out="$1"
  cat >"$out" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
LOG="/var/log/postinstall-master.log"
exec > >(tee -a "$LOG") 2>&1
trap 'echo "[X] Failed at line $LINENO" >&2' ERR
log(){ echo "[INFO] $(date '+%F %T') - $*"; }

# Load seeded env (from ISO)
if [[ -r /etc/environment.d/99-provision.conf ]]; then
  # shellcheck disable=SC2046
  export $(grep -E '^[A-Z0-9_]+=' /etc/environment.d/99-provision.conf | xargs -d'\n' || true)
fi

DOMAIN="${DOMAIN:-unixbox.net}"
DEBIAN_CODENAME="${DEBIAN_CODENAME:-trixie}"
REPO_MODE="${REPO_MODE:-darksite}"

MASTER_LAN="${MASTER_LAN:-10.100.10.224}"
ADMIN_USER="${ADMIN_USER:-todd}"
ALLOW_ADMIN_PASSWORD="${ALLOW_ADMIN_PASSWORD:-no}"

WG1_IP="${WG1_IP:-10.78.0.1/16}"; WG1_PORT="${WG1_PORT:-51821}"
WG2_IP="${WG2_IP:-10.79.0.1/16}"; WG2_PORT="${WG2_PORT:-51822}"
WG3_IP="${WG3_IP:-10.80.0.1/16}"; WG3_PORT="${WG3_PORT:-51823}"

configure_apt() {
  log "Configuring APT (REPO_MODE=$REPO_MODE)"
  export DEBIAN_FRONTEND=noninteractive
  if [[ "$REPO_MODE" == "darksite" || "$REPO_MODE" == "both" ]]; then
    if [[ -d /root/darksite/apt ]]; then
      cat >/etc/apt/sources.list <<'EOF'
deb [trusted=yes] file:/root/darksite/apt ./
EOF
    fi
  fi

  if [[ "$REPO_MODE" == "connected" || "$REPO_MODE" == "both" ]]; then
    cat >/etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian ${DEBIAN_CODENAME} main contrib non-free non-free-firmware
deb http://deb.debian.org/debian ${DEBIAN_CODENAME}-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security ${DEBIAN_CODENAME}-security main contrib non-free non-free-firmware
EOF
  fi
  apt-get update -y || true
}

install_base() {
  log "Installing base packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y --no-install-recommends \
    sudo openssh-server ca-certificates curl wget gnupg jq \
    iproute2 iputils-ping net-tools \
    nftables wireguard-tools \
    qemu-guest-agent chrony rsyslog \
    salt-master salt-api salt-common \
    prometheus prometheus-node-exporter grafana || true
  systemctl enable --now qemu-guest-agent chrony rsyslog ssh || true
}

ensure_users() {
  log "Creating admin user + ssh hardening"
  local seed="/root/darksite/authorized_keys.${ADMIN_USER}"
  local pub=""; [[ -s "$seed" ]] && pub="$(head -n1 "$seed")"

  id -u "$ADMIN_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$ADMIN_USER"
  install -d -m700 -o "$ADMIN_USER" -g "$ADMIN_USER" "/home/$ADMIN_USER/.ssh"
  touch "/home/$ADMIN_USER/.ssh/authorized_keys"
  chmod 600 "/home/$ADMIN_USER/.ssh/authorized_keys"
  chown -R "$ADMIN_USER:$ADMIN_USER" "/home/$ADMIN_USER/.ssh"
  [[ -n "$pub" ]] && grep -qxF "$pub" "/home/$ADMIN_USER/.ssh/authorized_keys" || [[ -n "$pub" ]] && echo "$pub" >> "/home/$ADMIN_USER/.ssh/authorized_keys"

  # allow enrollment key to log in as admin
  if [[ -s /root/darksite/enroll_ed25519.pub ]]; then
    local enroll_pub; enroll_pub="$(head -n1 /root/darksite/enroll_ed25519.pub)"
    grep -qxF "$enroll_pub" "/home/$ADMIN_USER/.ssh/authorized_keys" || echo "$enroll_pub" >> "/home/$ADMIN_USER/.ssh/authorized_keys"
  fi

  install -d -m755 /etc/sudoers.d
  printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$ADMIN_USER" >"/etc/sudoers.d/90-$ADMIN_USER"
  chmod 0440 "/etc/sudoers.d/90-$ADMIN_USER"

  install -d -m755 /etc/ssh/sshd_config.d
  cat >/etc/ssh/sshd_config.d/99-hard.conf <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
X11Forwarding no
AllowTcpForwarding no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
EOF

  if [[ "$ALLOW_ADMIN_PASSWORD" == "yes" ]]; then
    cat >/etc/ssh/sshd_config.d/10-admin-lan-password.conf <<EOF
Match User ${ADMIN_USER} Address 10.100.10.0/24
  PasswordAuthentication yes
EOF
  fi

  sshd -t && systemctl restart ssh || true
}

wg_setup_hub() {
  log "Configuring WireGuard hub planes (wg1/wg2/wg3)"
  install -d -m700 /etc/wireguard
  umask 077

  for ifn in wg1 wg2 wg3; do
    [[ -f "/etc/wireguard/${ifn}.key" ]] || wg genkey | tee "/etc/wireguard/${ifn}.key" | wg pubkey >"/etc/wireguard/${ifn}.pub"
  done

  cat >/etc/wireguard/wg1.conf <<EOF
[Interface]
Address    = ${WG1_IP}
PrivateKey = $(cat /etc/wireguard/wg1.key)
ListenPort = ${WG1_PORT}
MTU        = 1420
EOF

  cat >/etc/wireguard/wg2.conf <<EOF
[Interface]
Address    = ${WG2_IP}
PrivateKey = $(cat /etc/wireguard/wg2.key)
ListenPort = ${WG2_PORT}
MTU        = 1420
EOF

  cat >/etc/wireguard/wg3.conf <<EOF
[Interface]
Address    = ${WG3_IP}
PrivateKey = $(cat /etc/wireguard/wg3.key)
ListenPort = ${WG3_PORT}
MTU        = 1420
EOF

  chmod 600 /etc/wireguard/*.conf
  systemctl enable --now wg-quick@wg1 wg-quick@wg2 wg-quick@wg3 || true
}

nft_firewall() {
  log "Writing nftables firewall"
  local lan_if; lan_if="$(ip route show default | awk '/default/ {print $5; exit}' || true)"
  : "${lan_if:=ens18}"

  cat >/etc/nftables.conf <<EOF
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
  chain input {
    type filter hook input priority 0; policy drop;
    ct state established,related accept
    iifname "lo" accept
    ip protocol icmp accept

    tcp dport 22 accept
    udp dport { ${WG1_PORT}, ${WG2_PORT}, ${WG3_PORT} } accept

    iifname "wg1" accept
    iifname "wg2" accept
    iifname "wg3" accept
  }
  chain forward {
    type filter hook forward priority 0; policy drop;
    ct state established,related accept
    iifname "wg1" oifname "${lan_if}" accept
    iifname "wg2" oifname "${lan_if}" accept
    iifname "wg3" oifname "${lan_if}" accept
    iifname "${lan_if}" oifname "wg1" accept
    iifname "${lan_if}" oifname "wg2" accept
    iifname "${lan_if}" oifname "wg3" accept
  }
  chain output { type filter hook output priority 0; policy accept; }
}
EOF
  nft -f /etc/nftables.conf || true
  systemctl enable --now nftables || true
}

seed_hub_env() {
  log "Seeding /srv/wg/hub.env"
  install -d -m0755 /srv/wg
  cat >/srv/wg/hub.env <<EOF
HUB_LAN=${MASTER_LAN}
HUB_WG1_NET=10.78.0.0/16
HUB_WG2_NET=10.79.0.0/16
HUB_WG3_NET=10.80.0.0/16

WG1_PORT=${WG1_PORT}
WG2_PORT=${WG2_PORT}
WG3_PORT=${WG3_PORT}

WG1_PUB=$(cat /etc/wireguard/wg1.pub)
WG2_PUB=$(cat /etc/wireguard/wg2.pub)
WG3_PUB=$(cat /etc/wireguard/wg3.pub)
EOF
  chmod 0644 /srv/wg/hub.env
}

install_enrollment_helpers() {
  log "Installing wg-add-peer, wg-enrollment, register-minion"
  install -d -m0755 /usr/local/sbin /srv/wg /etc/prometheus/targets.d

  cat >/usr/local/sbin/wg-add-peer <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
PUB="${1:-}"; ADDR="${2:-}"; IFN="${3:-wg1}"
FLAG="/srv/wg/ENROLL_ENABLED"
[[ -f "$FLAG" ]] || { echo "enrollment closed" >&2; exit 2; }
[[ -n "$PUB" && -n "$ADDR" ]] || { echo "usage: wg-add-peer <pub> <ip/32> [if]" >&2; exit 1; }

wg set "$IFN" peer "$PUB" allowed-ips "$ADDR" persistent-keepalive 25 2>/dev/null || \
  wg set "$IFN" peer "$PUB" allowed-ips "$ADDR"

CONF="/etc/wireguard/${IFN}.conf"
grep -q "$PUB" "$CONF" || printf "\n[Peer]\nPublicKey=%s\nAllowedIPs=%s\nPersistentKeepalive=25\n" "$PUB" "$ADDR" >> "$CONF"
systemctl reload "wg-quick@${IFN}" 2>/dev/null || true
echo "OK"
EOF
  chmod 0755 /usr/local/sbin/wg-add-peer

  cat >/usr/local/sbin/wg-enrollment <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
FLAG="/srv/wg/ENROLL_ENABLED"
case "${1:-}" in
  on)  : >"$FLAG"; echo "enrollment enabled";;
  off) rm -f "$FLAG"; echo "enrollment disabled";;
  *)   echo "usage: wg-enrollment on|off" >&2; exit 1;;
esac
EOF
  chmod 0755 /usr/local/sbin/wg-enrollment

  cat >/usr/local/sbin/register-minion <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
GROUP="${1:-}"; HOST="${2:-}"; IP="${3:-}"
[[ -n "$GROUP" && -n "$HOST" && -n "$IP" ]] || { echo "usage: register-minion <group> <host> <wg2-ip>"; exit 2; }

ANS_HOSTS="/etc/ansible/hosts"
PROM_DIR="/etc/prometheus/targets.d"
PROM_TGT="${PROM_DIR}/${GROUP}.json"
mkdir -p "$(dirname "$ANS_HOSTS")" "$PROM_DIR"
touch "$ANS_HOSTS"

if ! grep -q "^\[${GROUP}\]" "$ANS_HOSTS"; then
  printf "\n[%s]\n" "$GROUP" >> "$ANS_HOSTS"
fi
sed -i "/^${HOST}\b/d" "$ANS_HOSTS"
printf "%s ansible_host=%s\n" "$HOST" "$IP" >> "$ANS_HOSTS"

[[ -s "$PROM_TGT" ]] || echo '[]' > "$PROM_TGT"
tmp="$(mktemp)"
jq --arg target "${IP}:9100" 'map(select(.targets|index($target)|not)) + [{"targets":[$target]}]' "$PROM_TGT" > "$tmp" && mv "$tmp" "$PROM_TGT"

systemctl reload prometheus 2>/dev/null || pkill -HUP prometheus 2>/dev/null || true
echo "OK"
EOF
  chmod 0755 /usr/local/sbin/register-minion
}

configure_salt_master() {
  log "Configuring Salt master (auto_accept=true)"
  install -d -m0755 /etc/salt/master.d
  cat >/etc/salt/master.d/bootstrap.conf <<'EOF'
auto_accept: True
ipv6: False
EOF
  systemctl enable --now salt-master salt-api || true
}

configure_prometheus_bind_wg2() {
  log "Binding Prometheus & node_exporter to WireGuard plane"
  local wg2_ip; wg2_ip="$(ip -4 -o addr show dev wg2 | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
  : "${wg2_ip:=10.79.0.1}"

  install -d -m0755 /etc/systemd/system/prometheus.service.d
  cat >/etc/systemd/system/prometheus.service.d/override.conf <<EOF
[Service]
Environment=
ExecStart=
ExecStart=/usr/bin/prometheus --web.listen-address=${wg2_ip}:9090 --config.file=/etc/prometheus/prometheus.yml
EOF

  install -d -m0755 /etc/systemd/system/prometheus-node-exporter.service.d
  cat >/etc/systemd/system/prometheus-node-exporter.service.d/override.conf <<EOF
[Service]
Environment=
ExecStart=
ExecStart=/usr/bin/prometheus-node-exporter --web.listen-address=${wg2_ip}:9100 --web.disable-exporter-metrics
EOF

  cat >/etc/prometheus/prometheus.yml <<'EOF'
global:
  scrape_interval: 15s
scrape_configs:
  - job_name: 'node'
    file_sd_configs:
      - files:
        - /etc/prometheus/targets.d/*.json
EOF

  systemctl daemon-reload
  systemctl enable --now prometheus prometheus-node-exporter grafana-server || true
}

main() {
  log "BEGIN master postinstall"
  configure_apt
  install_base
  ensure_users
  wg_setup_hub
  nft_firewall
  seed_hub_env
  install_enrollment_helpers
  configure_salt_master
  configure_prometheus_bind_wg2

  touch /root/.bootstrap_done
  systemctl disable bootstrap.service 2>/dev/null || true

  log "Master ready; powering off..."
  (sleep 2; systemctl --no-block poweroff) & disown
}
main
EOS
}

# =============================================================================
# MINION postinstall emitter
# =============================================================================
emit_postinstall_minion() {
  local out="$1"
  cat >"$out" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
LOG="/var/log/minion-postinstall.log"
exec > >(tee -a "$LOG") 2>&1
trap 'echo "[X] Failed at line $LINENO" >&2' ERR
log(){ echo "[INFO] $(date '+%F %T') - $*"; }

if [[ -r /etc/environment.d/99-provision.conf ]]; then
  # shellcheck disable=SC2046
  export $(grep -E '^[A-Z0-9_]+=' /etc/environment.d/99-provision.conf | xargs -d'\n' || true)
fi

DEBIAN_CODENAME="${DEBIAN_CODENAME:-trixie}"
REPO_MODE="${REPO_MODE:-darksite}"

ADMIN_USER="${ADMIN_USER:-todd}"
ALLOW_ADMIN_PASSWORD="${ALLOW_ADMIN_PASSWORD:-no}"
MY_GROUP="${MY_GROUP:-generic}"

WG1_WANTED="${WG1_WANTED:-10.78.0.2/32}"
WG2_WANTED="${WG2_WANTED:-10.79.0.2/32}"
WG3_WANTED="${WG3_WANTED:-10.80.0.2/32}"

HUB_ENV="/root/darksite/cluster-seed/hub.env"

configure_apt() {
  log "Configuring APT (REPO_MODE=$REPO_MODE)"
  export DEBIAN_FRONTEND=noninteractive
  if [[ "$REPO_MODE" == "darksite" || "$REPO_MODE" == "both" ]]; then
    if [[ -d /root/darksite/apt ]]; then
      cat >/etc/apt/sources.list <<'EOF'
deb [trusted=yes] file:/root/darksite/apt ./
EOF
    fi
  fi
  if [[ "$REPO_MODE" == "connected" || "$REPO_MODE" == "both" ]]; then
    cat >/etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian ${DEBIAN_CODENAME} main contrib non-free non-free-firmware
deb http://deb.debian.org/debian ${DEBIAN_CODENAME}-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security ${DEBIAN_CODENAME}-security main contrib non-free non-free-firmware
EOF
  fi
  apt-get update -y || true
}

install_base() {
  log "Installing base packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y --no-install-recommends \
    sudo openssh-server ca-certificates curl wget gnupg jq \
    iproute2 iputils-ping net-tools \
    nftables wireguard-tools \
    qemu-guest-agent chrony rsyslog \
    salt-minion salt-common \
    prometheus-node-exporter || true
  systemctl enable --now qemu-guest-agent chrony rsyslog ssh || true
}

ensure_admin_user() {
  log "Ensuring admin user $ADMIN_USER"
  local seed="/root/darksite/authorized_keys.${ADMIN_USER}"
  local pub=""; [[ -s "$seed" ]] && pub="$(head -n1 "$seed")"

  id -u "$ADMIN_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$ADMIN_USER"
  install -d -m700 -o "$ADMIN_USER" -g "$ADMIN_USER" "/home/$ADMIN_USER/.ssh"
  touch "/home/$ADMIN_USER/.ssh/authorized_keys"
  chmod 600 "/home/$ADMIN_USER/.ssh/authorized_keys"
  chown -R "$ADMIN_USER:$ADMIN_USER" "/home/$ADMIN_USER/.ssh"
  [[ -n "$pub" ]] && grep -qxF "$pub" "/home/$ADMIN_USER/.ssh/authorized_keys" || [[ -n "$pub" ]] && echo "$pub" >> "/home/$ADMIN_USER/.ssh/authorized_keys"

  install -d -m755 /etc/sudoers.d
  printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$ADMIN_USER" >"/etc/sudoers.d/90-$ADMIN_USER"
  chmod 0440 "/etc/sudoers.d/90-$ADMIN_USER"

  install -d -m755 /etc/ssh/sshd_config.d
  cat >/etc/ssh/sshd_config.d/99-hard.conf <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
X11Forwarding no
AllowTcpForwarding no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
EOF
  if [[ "$ALLOW_ADMIN_PASSWORD" == "yes" ]]; then
    cat >/etc/ssh/sshd_config.d/10-admin-lan-password.conf <<EOF
Match User ${ADMIN_USER} Address 10.100.10.0/24
  PasswordAuthentication yes
EOF
  fi
  sshd -t && systemctl restart ssh || true
}

read_hub_env() {
  [[ -r "$HUB_ENV" ]] || { echo "[X] missing $HUB_ENV" >&2; exit 2; }
  # shellcheck disable=SC1090
  . "$HUB_ENV"
  : "${HUB_LAN:?missing HUB_LAN}"
  : "${WG1_PUB:?missing WG1_PUB}"
  : "${WG2_PUB:?missing WG2_PUB}"
  : "${WG3_PUB:?missing WG3_PUB}"
  : "${WG1_PORT:?missing WG1_PORT}"
  : "${WG2_PORT:?missing WG2_PORT}"
  : "${WG3_PORT:?missing WG3_PORT}"
  : "${HUB_WG1_NET:?missing HUB_WG1_NET}"
  : "${HUB_WG2_NET:?missing HUB_WG2_NET}"
  : "${HUB_WG3_NET:?missing HUB_WG3_NET}"
}

wg_setup_minion() {
  log "Configuring WireGuard planes on minion"
  install -d -m700 /etc/wireguard
  umask 077

  for ifn in wg1 wg2 wg3; do
    [[ -f "/etc/wireguard/${ifn}.key" ]] || wg genkey | tee "/etc/wireguard/${ifn}.key" | wg pubkey >"/etc/wireguard/${ifn}.pub"
  done

  cat >/etc/wireguard/wg1.conf <<EOF
[Interface]
Address    = ${WG1_WANTED}
PrivateKey = $(cat /etc/wireguard/wg1.key)
ListenPort = 0
MTU        = 1420

[Peer]
PublicKey  = ${WG1_PUB}
Endpoint   = ${HUB_LAN}:${WG1_PORT}
AllowedIPs = ${HUB_WG1_NET}
PersistentKeepalive = 25
EOF

  cat >/etc/wireguard/wg2.conf <<EOF
[Interface]
Address    = ${WG2_WANTED}
PrivateKey = $(cat /etc/wireguard/wg2.key)
ListenPort = 0
MTU        = 1420

[Peer]
PublicKey  = ${WG2_PUB}
Endpoint   = ${HUB_LAN}:${WG2_PORT}
AllowedIPs = ${HUB_WG2_NET}
PersistentKeepalive = 25
EOF

  cat >/etc/wireguard/wg3.conf <<EOF
[Interface]
Address    = ${WG3_WANTED}
PrivateKey = $(cat /etc/wireguard/wg3.key)
ListenPort = 0
MTU        = 1420

[Peer]
PublicKey  = ${WG3_PUB}
Endpoint   = ${HUB_LAN}:${WG3_PORT}
AllowedIPs = ${HUB_WG3_NET}
PersistentKeepalive = 25
EOF

  chmod 600 /etc/wireguard/*.conf
  systemctl enable --now wg-quick@wg1 wg-quick@wg2 wg-quick@wg3 || true
}

install_enroll_key() {
  log "Installing enrollment SSH key for hub actions"
  [[ -r /root/darksite/enroll_ed25519 ]] || { log "No enroll key in /root/darksite; skipping"; return 0; }
  install -d -m700 /root/.ssh
  install -m600 /root/darksite/enroll_ed25519 /root/.ssh/enroll_ed25519
}

auto_enroll() {
  log "Auto-enrolling with hub wg-add-peer (best effort)"
  [[ -r /root/.ssh/enroll_ed25519 ]] || { log "No /root/.ssh/enroll_ed25519; skipping enroll"; return 0; }
  local ssho=(-i /root/.ssh/enroll_ed25519 -o LogLevel=ERROR -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=8)

  for iface in wg1 wg2 wg3; do
    local wanted pub
    case "$iface" in
      wg1) wanted="$WG1_WANTED" ;;
      wg2) wanted="$WG2_WANTED" ;;
      wg3) wanted="$WG3_WANTED" ;;
    esac
    pub="$(cat "/etc/wireguard/${iface}.pub" 2>/dev/null || true)"
    [[ -n "$pub" ]] || continue
    ssh "${ssho[@]}" "${ADMIN_USER}@${HUB_LAN}" "sudo /usr/local/sbin/wg-add-peer '$pub' '$wanted' '$iface'" || true
  done
}

nft_minion() {
  log "Writing nftables firewall"
  cat >/etc/nftables.conf <<'EOF'
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
  chain input {
    type filter hook input priority 0; policy drop;
    ct state established,related accept
    iifname "lo" accept
    ip protocol icmp accept
    tcp dport 22 accept
    iifname "wg1" accept
    iifname "wg2" accept
    iifname "wg3" accept
  }
  chain output { type filter hook output priority 0; policy accept; }
}
EOF
  nft -f /etc/nftables.conf || true
  systemctl enable --now nftables || true
}

configure_salt_minion() {
  log "Configuring Salt minion"
  install -d -m0755 /etc/salt/minion.d
  cat >/etc/salt/minion.d/master.conf <<EOF
master: ${HUB_LAN}
ipv6: False
EOF
  cat >/etc/salt/minion.d/grains.conf <<EOF
grains:
  role: ${MY_GROUP}
EOF
  systemctl enable --now salt-minion || true
}

bind_node_exporter_wg2() {
  log "Binding node_exporter to wg2"
  local wg2_ip; wg2_ip="$(echo "$WG2_WANTED" | cut -d/ -f1)"
  install -d -m0755 /etc/systemd/system/prometheus-node-exporter.service.d
  cat >/etc/systemd/system/prometheus-node-exporter.service.d/override.conf <<EOF
[Service]
Environment=
ExecStart=
ExecStart=/usr/bin/prometheus-node-exporter --web.listen-address=${wg2_ip}:9100 --web.disable-exporter-metrics
EOF
  systemctl daemon-reload
  systemctl enable --now prometheus-node-exporter || true
}

register_with_master() {
  log "Registering with master (register-minion) best effort"
  [[ -r /root/.ssh/enroll_ed25519 ]] || return 0
  local ssho=(-i /root/.ssh/enroll_ed25519 -o LogLevel=ERROR -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=8)
  local wg2_ip host; wg2_ip="$(echo "$WG2_WANTED" | cut -d/ -f1)"; host="$(hostname -s)"
  ssh "${ssho[@]}" "${ADMIN_USER}@${HUB_LAN}" "sudo /usr/local/sbin/register-minion '${MY_GROUP}' '${host}' '${wg2_ip}'" || true
}

main() {
  log "BEGIN minion postinstall"
  configure_apt
  install_base
  ensure_admin_user
  install_enroll_key
  read_hub_env
  wg_setup_minion
  auto_enroll
  nft_minion
  configure_salt_minion
  bind_node_exporter_wg2
  register_with_master

  touch /root/.bootstrap_done
  systemctl disable bootstrap.service 2>/dev/null || true

  log "Minion ready; powering off..."
  (sleep 2; systemctl --no-block poweroff) & disown
}
main
EOS
}

# =============================================================================
# Minion wrapper emitter (injects group + wg wanted IPs + hub.env)
# =============================================================================
emit_minion_wrapper() {
  # emit_minion_wrapper <outfile> <group> <wg1/32> <wg2/32> <wg3/32>
  local out="$1" group="$2" wg1="$3" wg2="$4" wg3="$5"
  local hub_src="$BUILD_ROOT/hub/hub.env"
  [[ -s "$hub_src" ]] || die "Missing hub.env at $hub_src (master must be deployed first)"

  cat >"$out" <<'EOSH'
#!/usr/bin/env bash
set -euo pipefail
LOG="/var/log/minion-wrapper.log"
exec > >(tee -a "$LOG") 2>&1
trap 'echo "[X] Wrapper failed at line $LINENO" >&2' ERR
EOSH

  {
    echo 'install -d -m0755 /root/darksite/cluster-seed'
    echo 'cat > /root/darksite/cluster-seed/hub.env <<HUBEOF'
    cat "$hub_src"
    echo 'HUBEOF'
    echo 'chmod 0644 /root/darksite/cluster-seed/hub.env'
  } >>"$out"

  cat >>"$out" <<EOSH
install -d -m0755 /etc/environment.d
{
  echo "MY_GROUP=${group}"
  echo "WG1_WANTED=${wg1}"
  echo "WG2_WANTED=${wg2}"
  echo "WG3_WANTED=${wg3}"
} >> /etc/environment.d/99-provision.conf
chmod 0644 /etc/environment.d/99-provision.conf
EOSH

  cat >>"$out" <<'EOSH'
install -d -m0755 /root/darksite
cat >/root/darksite/postinstall-minion.sh <<'EOMINION'
EOSH

  local tmp
  tmp="$(mktemp)"
  emit_postinstall_minion "$tmp"
  cat "$tmp" >>"$out"
  rm -f "$tmp"

  cat >>"$out" <<'EOSH'
EOMINION
chmod +x /root/darksite/postinstall-minion.sh
bash -lc '/root/darksite/postinstall-minion.sh'
EOSH

  chmod +x "$out"
}

# =============================================================================
# Deploy helpers
# =============================================================================
ensure_master_enrollment_seed() {
  local vmid="$1"
  pmx_guest_exec "$vmid" /bin/bash -lc 'set -euo pipefail; install -d -m0755 /srv/wg; : > /srv/wg/ENROLL_ENABLED'
}

deploy_minion_vm() {
  # deploy_minion_vm <vmid> <name> <lan_ip> <group> <wg1/32> <wg2/32> <wg3/32> <mem> <cores> <disk>
  local id="$1" name="$2" ip="$3" group="$4" wg1="$5" wg2="$6" wg3="$7" mem="$8" cores="$9" disk="${10}"

  local payload iso
  payload="$(mktemp)"
  emit_minion_wrapper "$payload" "$group" "$wg1" "$wg2" "$wg3"

  iso="$BUILD_ROOT/${name}.iso"
  mk_iso "$name" "$payload" "$iso" "$ip"
  pmx_deploy "$id" "$name" "$iso" "$mem" "$cores" "$disk"

  wait_poweroff "$id" 2400
  boot_from_disk "$id"
  wait_poweroff "$id" 2400
  pmx "qm start $id"
  pmx_wait_for_state "$id" "running" 600
}

# =============================================================================
# Proxmox flows
# =============================================================================
proxmox_cluster() {
  log "=== Deploying base cluster (master + prom + graf + storage) ==="

  ensure_enroll_keypair

  local master_payload master_iso
  master_payload="$(mktemp)"
  emit_postinstall_master "$master_payload"

  master_iso="$BUILD_ROOT/master.iso"
  mk_iso "master" "$master_payload" "$master_iso" "$MASTER_LAN"
  pmx_deploy "$MASTER_ID" "$MASTER_NAME" "$master_iso" "$MASTER_MEM" "$MASTER_CORES" "$MASTER_DISK_GB"

  wait_poweroff "$MASTER_ID" 2400
  boot_from_disk "$MASTER_ID"
  wait_poweroff "$MASTER_ID" 2400
  pmx "qm start $MASTER_ID"
  pmx_wait_for_state "$MASTER_ID" "running" 600
  pmx_wait_qga "$MASTER_ID" 900

  ensure_master_enrollment_seed "$MASTER_ID"

  log "Fetching hub.env from master via QGA"
  mkdir -p "$BUILD_ROOT/hub"
  local dest="$BUILD_ROOT/hub/hub.env"
  if pmx_guest_cat "$MASTER_ID" "/srv/wg/hub.env" > "${dest}.tmp" && [[ -s "${dest}.tmp" ]]; then
    mv -f "${dest}.tmp" "${dest}"
    log "hub.env saved to $dest"
  else
    die "Failed to retrieve /srv/wg/hub.env via QGA"
  fi

  deploy_minion_vm "$PROM_ID" "$PROM_NAME" "$PROM_IP" "prom" \
    "$PROM_WG1" "$PROM_WG2" "$PROM_WG3" \
    "$MINION_MEM" "$MINION_CORES" "$MINION_DISK_GB"

  deploy_minion_vm "$GRAF_ID" "$GRAF_NAME" "$GRAF_IP" "graf" \
    "$GRAF_WG1" "$GRAF_WG2" "$GRAF_WG3" \
    "$MINION_MEM" "$MINION_CORES" "$MINION_DISK_GB"

  deploy_minion_vm "$STOR_ID" "$STOR_NAME" "$STOR_IP" "storage" \
    "$STOR_WG1" "$STOR_WG2" "$STOR_WG3" \
    "$MINION_MEM" "$MINION_CORES" "$MINION_DISK_GB"

  pmx_guest_exec "$MASTER_ID" /bin/bash -lc "rm -f /srv/wg/ENROLL_ENABLED" || true
  log "Base cluster deployed."
}

proxmox_k8s_ha() {
  log "=== Deploying K8s HA VMs (etcd + lbs + cps + workers) ==="

  pmx "qm start $MASTER_ID" >/dev/null 2>&1 || true
  pmx_wait_for_state "$MASTER_ID" "running" 600
  pmx_wait_qga "$MASTER_ID" 900
  ensure_master_enrollment_seed "$MASTER_ID"

  [[ -s "$BUILD_ROOT/hub/hub.env" ]] || die "Missing $BUILD_ROOT/hub/hub.env"

  deploy_minion_vm "$ETCD1_ID" "$ETCD1_NAME" "$ETCD1_IP" "etcd" \
    "$ETCD1_WG1" "$ETCD1_WG2" "$ETCD1_WG3" \
    "$MINION_MEM" "$MINION_CORES" "$MINION_DISK_GB"
  deploy_minion_vm "$ETCD2_ID" "$ETCD2_NAME" "$ETCD2_IP" "etcd" \
    "$ETCD2_WG1" "$ETCD2_WG2" "$ETCD2_WG3" \
    "$MINION_MEM" "$MINION_CORES" "$MINION_DISK_GB"
  deploy_minion_vm "$ETCD3_ID" "$ETCD3_NAME" "$ETCD3_IP" "etcd" \
    "$ETCD3_WG1" "$ETCD3_WG2" "$ETCD3_WG3" \
    "$MINION_MEM" "$MINION_CORES" "$MINION_DISK_GB"

  deploy_minion_vm "$K8SLB1_ID" "$K8SLB1_NAME" "$K8SLB1_IP" "lb" \
    "$K8SLB1_WG1" "$K8SLB1_WG2" "$K8SLB1_WG3" \
    "$K8S_LB_MEM" "$K8S_LB_CORES" "$K8S_LB_DISK_GB"
  deploy_minion_vm "$K8SLB2_ID" "$K8SLB2_NAME" "$K8SLB2_IP" "lb" \
    "$K8SLB2_WG1" "$K8SLB2_WG2" "$K8SLB2_WG3" \
    "$K8S_LB_MEM" "$K8S_LB_CORES" "$K8S_LB_DISK_GB"
  deploy_minion_vm "$K8SLB3_ID" "$K8SLB3_NAME" "$K8SLB3_IP" "lb" \
    "$K8SLB3_WG1" "$K8SLB3_WG2" "$K8SLB3_WG3" \
    "$K8S_LB_MEM" "$K8S_LB_CORES" "$K8S_LB_DISK_GB"

  deploy_minion_vm "$K8SCP1_ID" "$K8SCP1_NAME" "$K8SCP1_IP" "cp" \
    "$K8SCP1_WG1" "$K8SCP1_WG2" "$K8SCP1_WG3" \
    "$K8S_CP_MEM" "$K8S_CP_CORES" "$K8S_CP_DISK_GB"
  deploy_minion_vm "$K8SCP2_ID" "$K8SCP2_NAME" "$K8SCP2_IP" "cp" \
    "$K8SCP2_WG1" "$K8SCP2_WG2" "$K8SCP2_WG3" \
    "$K8S_CP_MEM" "$K8S_CP_CORES" "$K8S_CP_DISK_GB"
  deploy_minion_vm "$K8SCP3_ID" "$K8SCP3_NAME" "$K8SCP3_IP" "cp" \
    "$K8SCP3_WG1" "$K8SCP3_WG2" "$K8SCP3_WG3" \
    "$K8S_CP_MEM" "$K8S_CP_CORES" "$K8S_CP_DISK_GB"

  deploy_minion_vm "$K8SW1_ID" "$K8SW1_NAME" "$K8SW1_IP" "worker" \
    "$K8SW1_WG1" "$K8SW1_WG2" "$K8SW1_WG3" \
    "$K8S_WK_MEM" "$K8S_WK_CORES" "$K8S_WK_DISK_GB"
  deploy_minion_vm "$K8SW2_ID" "$K8SW2_NAME" "$K8SW2_IP" "worker" \
    "$K8SW2_WG1" "$K8SW2_WG2" "$K8SW2_WG3" \
    "$K8S_WK_MEM" "$K8S_WK_CORES" "$K8S_WK_DISK_GB"
  deploy_minion_vm "$K8SW3_ID" "$K8SW3_NAME" "$K8SW3_IP" "worker" \
    "$K8SW3_WG1" "$K8SW3_WG2" "$K8SW3_WG3" \
    "$K8S_WK_MEM" "$K8S_WK_CORES" "$K8S_WK_DISK_GB"

  pmx_guest_exec "$MASTER_ID" /bin/bash -lc "rm -f /srv/wg/ENROLL_ENABLED" || true
  log "K8s HA VM fleet deployed."
}

proxmox_all() {
  proxmox_cluster
  proxmox_k8s_ha
  log "=== proxmox-all complete ==="
}

# =============================================================================
# Optional: apply step on master (customizable key path)
# =============================================================================
APPLY_SSH_KEY="${APPLY_SSH_KEY:-$(_default_home)/.ssh/id_ed25519}"
run_apply_on_master() {
  log "Running apply.py on master (if present) via ${ADMIN_USER}@${MASTER_LAN}"
  [[ -r "$APPLY_SSH_KEY" ]] || die "APPLY_SSH_KEY not readable: $APPLY_SSH_KEY"

  ssh -i "$APPLY_SSH_KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=20 \
    -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$KNOWN_HOSTS" \
    "${ADMIN_USER}@${MASTER_LAN}" -- bash -lc '
      set -euo pipefail
      APPLY="/srv/darksite/apply.py"
      if [[ -f "$APPLY" ]]; then
        sudo -n /usr/bin/python3 -u "$APPLY"
      else
        echo "[REMOTE] No /srv/darksite/apply.py present; skipping."
      fi
    '
}

# =============================================================================
# MAIN
# =============================================================================
case "$TARGET" in
  proxmox-all)     proxmox_all     ;;
  proxmox-cluster) proxmox_cluster ;;
  proxmox-k8s-ha)  proxmox_k8s_ha  ;;
  *)
    die "Unknown TARGET '$TARGET'. Expected: proxmox-all | proxmox-cluster | proxmox-k8s-ha"
    ;;
esac

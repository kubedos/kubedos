#!/usr/bin/env bash

: <<'COMMENT'
deploy.sh — Kubernetes cluster builder for an entire VM host
COMMENT

set -euo pipefail
# =============================================================================
# Config knobs (env overrides)
#   - DARKSITE_SRC: path to static payload staged into ISO at /cdrom/darksite/
#       Default: <repo_root>/payload/darksite if present, else ~/<...>/foundrybot/payload/darksite
#       NOTE: if running under sudo, we resolve the invoking user's HOME via SUDO_USER.
# =============================================================================

_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
_repo_root="$(git -C "$_script_dir" rev-parse --show-toplevel 2>/dev/null || echo "$_script_dir")"  # git root if available

_default_home() {
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    eval echo "~${SUDO_USER}"
  else
    echo "${HOME:-/root}"
  fi
}

default_darksite_src() {
  local candidate
  # 1) Repo-local payload (deterministic)
  candidate="${_repo_root}/payload/darksite"
  if [[ -d "$candidate" ]]; then
    echo "$candidate"
    return 0
  fi

  # 2) User-home convention (matches docs): ~/foundrybot/payload/darksite
  candidate="$(_default_home)/foundrybot/payload/darksite"
  if [[ -d "$candidate" ]]; then
    echo "$candidate"
    return 0
  fi

  # 3) Legacy/root convention
  candidate="/root/foundrybot/payload/darksite"
  if [[ -d "$candidate" ]]; then
    echo "$candidate"
    return 0
  fi

  # Default to user-home even if missing (caller will warn)
  echo "$(_default_home)/foundrybot/payload/darksite"
}

if [[ -z "${DARKSITE_SRC:-}" ]]; then
  DARKSITE_SRC="$(default_darksite_src)"
fi


# =============================================================================
# Logging / error helpers
# =============================================================================

log()  { echo "[INFO]  $(date '+%F %T') - $*"; }
warn() { echo "[WARN]  $(date '+%F %T') - $*" >&2; }
err()  { echo "[ERROR] $(date '+%F %T') - $*" >&2; }
die()  { err "$*"; exit 1; }

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "Required command not found in PATH: $cmd"
}

# =============================================================================
# SSH helpers (build host → Proxmox / remote)
# =============================================================================

KNOWN_HOSTS="${KNOWN_HOSTS:-${BUILD_ROOT:-/root/builds}/known_hosts}"
mkdir -p "$(dirname "$KNOWN_HOSTS")"
touch "$KNOWN_HOSTS"
chmod 600 "$KNOWN_HOSTS"

SSH_OPTS=(
  -o LogLevel=ERROR
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile="$KNOWN_HOSTS"
  -o GlobalKnownHostsFile=/dev/null
  -o CheckHostIP=yes
  -o ConnectTimeout=6
  -o BatchMode=yes
)

sssh() { ssh -q "${SSH_OPTS[@]}" "$@"; }
sscp() { scp -q -o BatchMode=yes -o ConnectTimeout=6 -o UserKnownHostsFile="$KNOWN_HOSTS" -o StrictHostKeyChecking=accept-new "$@"; }

# =============================================================================
# DARKSITE APT REPO BUILD HELPERS
# Inserted: deploy.sh @ line 22
# =============================================================================

# Upstream mirrors used when connected (and for darksite dependency resolution)
DEBIAN_MIRROR="${DEBIAN_MIRROR:-http://deb.debian.org/debian}"
SECURITY_MIRROR="${SECURITY_MIRROR:-http://security.debian.org/debian-security}"

# =============================================================================
# DARKSITE APT REPO BUILD HELPERS
# =============================================================================

ensure_darksite_build_deps() {
  # Only applies if we're on a Debian-like build host and auto-install is enabled
  [[ "${DARKSITE_BUILD_DEPS_AUTO:-1}" == "1" ]] || return 0
  command -v apt-get >/dev/null 2>&1 || return 0

  local need=()

  # Tools we require for building a flat repo snapshot
  for c in apt-rdepends dpkg-scanpackages apt-ftparchive gpg gzip; do
    command -v "$c" >/dev/null 2>&1 || need+=("$c")
  done

  if (( ${#need[@]} > 0 )); then
    log "[*] Installing darksite build dependencies (missing: ${need[*]})"
    apt-get update -y

    # apt-rdepends (package: apt-rdepends)
    # dpkg-scanpackages (package: dpkg-dev)
    # apt-ftparchive (package: apt-utils)
    # gpg (package: gnupg)
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
      apt-rdepends dpkg-dev apt-utils gnupg ca-certificates

    # Make sure PATH lookup refreshes in the current shell
    hash -r
  fi
}

darksite_build_apt_repo() {
  # Builds a flat APT repo at: <dest>/ (deb files) + Packages.gz + Release
  # The repo will be referenced as: deb [trusted=yes] file:/cdrom/darksite/apt ./
  local dest="$1"
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$dest"

  ensure_darksite_build_deps

  require_cmd apt-rdepends
  require_cmd dpkg-scanpackages
  require_cmd apt-ftparchive
  require_cmd gzip

  if [[ "${DARKSITE_CLEAN_BUILD:-1}" == "1" ]]; then
    rm -rf "${dest:?}/"*
  fi

  log "[*] Building darksite APT repo into: $dest"
  log "[*] Darksite root packages: ${DARKSITE_ROOT_PKGS}"

  # Resolve dependency closure
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

  # Download all .debs
  (
    cd "$tmp"
    for p in "${pkgs[@]}"; do
      # apt-get download returns non-zero for virtual packages; ignore those
      apt-get download "$p" >/dev/null 2>&1 || true
    done
  )

  shopt -s nullglob
  local debs=( "$tmp"/*.deb )
  if (( ${#debs[@]} == 0 )); then
    die "Darksite repo build failed: no .deb files were downloaded. Check mirrors/apt config."
  fi

  mv "$tmp"/*.deb "$dest/"

  # Generate Packages + Packages.gz
  ( cd "$dest" && dpkg-scanpackages . /dev/null > Packages )
  gzip -9c "$dest/Packages" > "$dest/Packages.gz"

  # Generate Release (simple, flat repo)
  ( cd "$dest" && apt-ftparchive release . > Release )

  rm -rf "$tmp"
  log "[OK] Darksite APT repo ready: $dest"
}

repo_profile_flags() {
  # Translate REPO_PROFILE into APT_USE_* flags (used by connected_sources_list)
  case "${REPO_PROFILE:-full}" in
    base)
      APT_USE_UPDATES=0
      APT_USE_SECURITY=0
      APT_USE_BACKPORTS=0
      ;;
    base+updates)
      APT_USE_UPDATES=1
      APT_USE_SECURITY=0
      APT_USE_BACKPORTS=0
      ;;
    full|*)
      APT_USE_UPDATES=1
      APT_USE_SECURITY=1
      APT_USE_BACKPORTS=0
      ;;
  esac
}

connected_sources_list() {
  # Generates a sources.list for normal “connected” operation
  local suite="${DEBIAN_CODENAME}"
  cat <<EOF
deb ${DEBIAN_MIRROR} ${suite} ${APT_COMPONENTS}
EOF
  [[ "${APT_USE_UPDATES}" == "1"  ]] && echo "deb ${DEBIAN_MIRROR} ${suite}-updates ${APT_COMPONENTS}"
  [[ "${APT_USE_SECURITY}" == "1" ]] && echo "deb ${SECURITY_MIRROR} ${suite}-security ${APT_COMPONENTS}"
  [[ "${APT_USE_BACKPORTS}" == "1" ]] && echo "deb ${DEBIAN_MIRROR} ${suite}-backports ${APT_COMPONENTS}"
}

darksite_build_apt_repo() {
  # Builds a flat APT repo at:
  #   <dest>/ (deb files) + Packages.gz + Release
  #
  # This repo is referenced inside the installer as:
  #   deb [trusted=yes] file:/cdrom/darksite/apt ./
  #
  local dest="$1"
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$dest"

  ensure_darksite_build_deps
  require_cmd apt-rdepends
  require_cmd dpkg-scanpackages
  require_cmd apt-ftparchive
  require_cmd apt-get

  repo_profile_flags

  if [[ "${DARKSITE_CLEAN_BUILD}" == "1" ]]; then
    rm -rf "${dest:?}/"*
  fi

  log "[*] Building darksite APT repo into: $dest"
  log "[*] Darksite root packages: ${DARKSITE_ROOT_PKGS}"
  log "[*] Using mirrors via connected_sources_list (REPO_PROFILE=${REPO_PROFILE})"

  # Ensure build host has the right sources (for dependency resolution + downloads)
  mkdir -p /etc/apt/sources.list.d
  connected_sources_list > /etc/apt/sources.list.d/foundrybot.connected.list
  apt-get update -y

  # Resolve dependency closure
  mapfile -t pkgs < <(
    apt-rdepends -f Depends,PreDepends ${DARKSITE_ROOT_PKGS} 2>/dev/null \
      | sed -n 's/^[[:space:]]*Depends:[[:space:]]*//p; s/^[[:space:]]*PreDepends:[[:space:]]*//p; /^[A-Za-z0-9]/p' \
      | sed 's/[[:space:]]*(.*)//g' \
      | tr '|' '\n' \
      | awk '{print $1}' \
      | grep -E '^[A-Za-z0-9][A-Za-z0-9+.-]+$' \
      | sort -u
  )

  # Download all .debs
  (
    cd "$tmp"
    for p in "${pkgs[@]}"; do
      apt-get download "$p" >/dev/null 2>&1 || true
    done
  )

  shopt -s nullglob
  local debs=( "$tmp"/*.deb )
  if (( ${#debs[@]} == 0 )); then
    die "Darksite repo build failed: no .deb files were downloaded. Check mirrors/apt config."
  fi

  mv "$tmp"/*.deb "$dest/"

  # Generate Packages + Packages.gz
  ( cd "$dest" && dpkg-scanpackages . /dev/null > Packages )
  gzip -9c "$dest/Packages" > "$dest/Packages.gz"

  # Generate Release (simple, flat repo)
  ( cd "$dest" && apt-ftparchive release . > Release )

  rm -rf "$tmp"
  log "[OK] Darksite APT repo ready: $dest"
}

preseed_emit_apt_snippet() {
  # Emits a valid Debian Installer preseed APT block.
  # REPO_MODE:
  #   connected : use normal Debian mirrors
  #   darksite  : use only the ISO-baked repo at /cdrom/darksite/apt
  #   both      : prefer ISO repo but allow mirrors
  case "${REPO_MODE}" in
    darksite)
      cat <<'EOF'
# --- DARKSITE APT (local only) ---
d-i apt-setup/use_mirror boolean false
d-i apt-cdrom-setup/another boolean false

# Use a local APT repo baked into the ISO at /cdrom/darksite/apt
d-i apt-setup/local0/repository string deb [trusted=yes] file:/cdrom/darksite/apt trixie main contrib non-free non-free-firmware
d-i apt-setup/local0/comment string Darksite ISO repo
d-i apt-setup/local0/source boolean false

# Don't try security/updates mirrors when darksite-only
d-i apt-setup/security-updates boolean false
EOF
      ;;
    both)
      cat <<'EOF'
# --- BOTH APT (local + mirror) ---
# Prefer local repo, but also allow internet mirrors if available
d-i apt-setup/use_mirror boolean true
d-i mirror/country string manual
d-i mirror/http/hostname string deb.debian.org
d-i mirror/http/directory string /debian
d-i mirror/http/proxy string

d-i apt-cdrom-setup/another boolean false
d-i apt-setup/local0/repository string deb [trusted=yes] file:/cdrom/darksite/apt trixie main contrib non-free non-free-firmware
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
# Repo / installer mode (CONNECTED vs DARKSITE vs BOTH)
# =============================================================================
# REPO_MODE:
#   darksite  = installer uses ONLY the ISO-embedded repo (true time capsule)
#   connected = installer uses network mirrors only
#   both      = installer uses ISO repo first + network mirrors as fallback
REPO_MODE="${REPO_MODE:-connected}"                    # darksite | connected | both

# Debian release codename + arch
DEBIAN_CODENAME="${DEBIAN_CODENAME:-trixie}"          # bookworm, trixie, etc
ARCH="${ARCH:-amd64}"                                 # amd64, arm64, etc

# “Multi repo selector” (what suites/services we include when building darksite)
#   base        = deb.debian.org (main) only
#   base+updates= + trixie-updates
#   full        = + trixie-updates + trixie-security
REPO_PROFILE="${REPO_PROFILE:-full}"                  # base | base+updates | full

# =============================================================================
# APT MODE + REPO SELECTOR (connected vs darksite vs both)
# Inserted: deploy.sh @ line 63
# =============================================================================

# connected  = installer + postinstall use internet mirrors
# darksite   = installer + postinstall prefer local APT repo baked into ISO
# both       = bake darksite repo into ISO, but allow falling back to mirrors
APT_MODE="${APT_MODE:-connected}"     # connected|darksite|both

# Which upstream repos should be mirrored into the darksite repo?
# (applies when APT_MODE=darksite|both)
APT_USE_MAIN="${APT_USE_MAIN:-1}"            # 1=yes
APT_USE_UPDATES="${APT_USE_UPDATES:-1}"      # 1=yes (e.g. trixie-updates)
APT_USE_SECURITY="${APT_USE_SECURITY:-1}"    # 1=yes (e.g. trixie-security)
APT_USE_BACKPORTS="${APT_USE_BACKPORTS:-0}"  # 1=yes

# Components to include when connected (and for dependency resolution during darksite build)
APT_COMPONENTS="${APT_COMPONENTS:-main contrib non-free non-free-firmware}"

# Base package set to “time-capsule” into the ISO’s darksite repo.
# Add/remove freely; this is the closure root.
DARKSITE_ROOT_PKGS="${DARKSITE_ROOT_PKGS:-\
ca-certificates curl wget gnupg sudo openssh-server \
vim-tiny less net-tools iproute2 pciutils usbutils \
rsync tmux jq git \
}"

# Build-time behavior
DARKSITE_BUILD_DEPS_AUTO="${DARKSITE_BUILD_DEPS_AUTO:-1}"  # auto apt-get install tools needed to build repo
DARKSITE_CLEAN_BUILD="${DARKSITE_CLEAN_BUILD:-1}"          # wipe/rebuild darksite repo each run


# Components to include in both connected sources and the darksite snapshot
REPO_COMPONENTS="${REPO_COMPONENTS:-main contrib non-free non-free-firmware}"

# When REPO_MODE includes darksite: build the repo on-demand during mk_iso()
DARKSITE_BUILD_ON_DEMAND="${DARKSITE_BUILD_ON_DEMAND:-yes}"   # yes|no
DARKSITE_KEYRING_MODE="${DARKSITE_KEYRING_MODE:-trusted}"     # trusted|signed (trusted uses [trusted=yes])

log "[*] REPO_MODE=$REPO_MODE REPO_PROFILE=$REPO_PROFILE CODENAME=$DEBIAN_CODENAME ARCH=$ARCH"

# =============================================================================
# Preseed / installer behaviour
# =============================================================================

PRESEED_LOCALE="${PRESEED_LOCALE:-en_US.UTF-8}"                               # PRESEED_LOCALE: system locale (POSIX-style). Examples: en_US.UTF-8, en_GB.UTF-8, fr_CA.UTF-8, de_DE.UTF-8
PRESEED_KEYMAP="${PRESEED_KEYMAP:-us}"                                        # PRESEED_KEYMAP: console keymap. Examples: us, uk, de, fr, ca, se, ...
PRESEED_TIMEZONE="${PRESEED_TIMEZONE:-America/Vancouver}"                     # PRESEED_TIMEZONE: system timezone (tzdata name). IE: America/Vancouver, UTC, Europe/Berlin, America/New_York
PRESEED_MIRROR_COUNTRY="${PRESEED_MIRROR_COUNTRY:-manual}"                    # PRESEED_MIRROR_COUNTRY: Debian mirror country selector. Otherwise: two-letter country code (e.g. CA, US, DE).
PRESEED_MIRROR_HOST="${PRESEED_MIRROR_HOST:-deb.debian.org}"                  # PRESEED_MIRROR_HOST: Debian mirror hostname. Ex : deb.debian.org, ftp.ca.debian.org, mirror.local.lan
PRESEED_MIRROR_DIR="${PRESEED_MIRROR_DIR:-/debian}"                           # PRESEED_MIRROR_DIR: Debian mirror directory path (typically /debian).
PRESEED_HTTP_PROXY="${PRESEED_HTTP_PROXY:-}"                                  # PRESEED_HTTP_PROXY: HTTP proxy for installer. Empty = no proxy. Example: http://10.0.0.10:3128
PRESEED_ROOT_PASSWORD="${PRESEED_ROOT_PASSWORD:-root}"                        # PRESEED_ROOT_PASSWORD: root password used by preseed. Strongly recommended to override via env/secret.
PRESEED_BOOTDEV="${PRESEED_BOOTDEV:-/dev/sda}"                                # PRESEED_BOOTDEV: install target disk inside the VM. Examples: /dev/sda, /dev/vda, /dev/nvme0n1
PRESEED_EXTRA_PKGS="${PRESEED_EXTRA_PKGS:-openssh-server} rsync"                    # PRESEED_EXTRA_PKGS: space-separated list of extra packagesExample: "openssh-server curl vim"

# =============================================================================
# High-level deployment mode / targets
# =============================================================================

# TARGET: what this script should do.
#   Typical values (depends on which functions you wire in):
#     proxmox-all        - full Proxmox flow (build ISO + master + minions)
#     proxmox-cluster    - build & deploy master + core minions
#     proxmox-k8s-ha     - build HA K8s layout on Proxmox
#     image-only         - build role ISOs only
#     export-base-image  - export master disk from Proxmox to qcow2
#     vmdk-export        - convert BASE_DISK_IMAGE → VMDK
#     aws-ami            - import BASE_DISK_IMAGE into AWS as AMI
#     aws-run            - launch EC2 instances from AMI
#     firecracker-bundle - emit Firecracker rootfs/kernel/initrd + helpers
#     firecracker        - run Firecracker microVMs
#     packer-scaffold    - emit Packer QEMU template
TARGET="${TARGET:-proxmox-all}"

# INPUT: logical Proxmox target selector (maps to PROXMOX_HOST).
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

ISO_ORIG="${ISO_ORIG:-/root/debian-13.2.0-amd64-netinst.iso}"                 # ISO_ORIG: source Debian ISO used to build custom images.
ISO_STORAGE="${ISO_STORAGE:-local}"                                           # ISO_STORAGE: local (default).
VM_STORAGE="${VM_STORAGE:-local-zfs}"                                         # VM_STORAGE: local-zfs (local/nvme), void (ceph), fireball (zfs-rust)

# =============================================================================
# LAN / DNS settings
# =============================================================================

NETMASK="${NETMASK:-255.255.255.0}"
GATEWAY="${GATEWAY:-10.100.10.1}"
NAMESERVER="${NAMESERVER:-10.100.10.2 10.100.10.3}"
DOMAIN="${DOMAIN:-unixbox.net}"
MASTER_LAN="${MASTER_LAN:-10.100.10.224}"
MASTER_NAME="${MASTER_NAME:-master}"
MASTER_ID="${MASTER_ID:-2000}"

# =============================================================================
# WireGuard hubs (on MASTER)
# =============================================================================

WG0_IP="${WG0_IP:-10.77.0.1/16}"; WG0_PORT="${WG0_PORT:-51820}"
WG1_IP="${WG1_IP:-10.78.0.1/16}"; WG1_PORT="${WG1_PORT:-51821}"
WG2_IP="${WG2_IP:-10.79.0.1/16}"; WG2_PORT="${WG2_PORT:-51822}"
WG3_IP="${WG3_IP:-10.80.0.1/16}"; WG3_PORT="${WG3_PORT:-51823}"
WG_ALLOWED_CIDR="${WG_ALLOWED_CIDR:-10.77.0.0/16,10.78.0.0/16,10.79.0.0/16,10.80.0.0/16}"

# =============================================================================
# VM inventory (IDs + LAN) IPs
# =============================================================================

MASTER_ID="${MASTER_ID:-2000}"; MASTER_NAME="${MASTER_NAME:-master}"; MASTER_LAN="${MASTER_LAN:-10.100.10.224}"
PROM_ID="${PROM_ID:-2001}"; PROM_NAME="${PROM_NAME:-prometheus}"; PROM_IP="${PROM_IP:-10.100.10.223}"
GRAF_ID="${GRAF_ID:-2002}"; GRAF_NAME="${GRAF_NAME:-grafana}"; GRAF_IP="${GRAF_IP:-10.100.10.222}"
STOR_ID="${STOR_ID:-2003}"; STOR_NAME="${STOR_NAME:-storage}"; STOR_IP="${STOR_IP:-10.100.10.221}"
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

# Optional: API VIP (recommended as a separate floating IP; adjust if you already use one)
K8S_API_VIP="${K8S_API_VIP:-10.100.10.208}"

# =============================================================================
# Per-node WG (/32) — wg0 DO NOT USE, Start with wg1/wg2/wg3 for nodes
# =============================================================================

PROM_WG0="${PROM_WG0:-10.77.0.2/32}"; PROM_WG1="${PROM_WG1:-10.78.0.2/32}"; PROM_WG2="${PROM_WG2:-10.79.0.2/32}"; PROM_WG3="${PROM_WG3:-10.80.0.2/32}"
GRAF_WG0="${GRAF_WG0:-10.77.0.3/32}"; GRAF_WG1="${GRAF_WG1:-10.78.0.3/32}"; GRAF_WG2="${GRAF_WG2:-10.79.0.3/32}"; GRAF_WG3="${GRAF_WG3:-10.80.0.3/32}"
STOR_WG0="${STOR_WG0:-10.77.0.4/32}"; STOR_WG1="${STOR_WG1:-10.78.0.4/32}"; STOR_WG2="${STOR_WG2:-10.79.0.4/32}"; STOR_WG3="${STOR_WG3:-10.80.0.4/32}"
ETCD1_WG0="${ETCD1_WG0:-10.77.0.5/32}"; ETCD1_WG1="${ETCD1_WG1:-10.78.0.5/32}"; ETCD1_WG2="${ETCD1_WG2:-10.79.0.5/32}"; ETCD1_WG3="${ETCD1_WG3:-10.80.0.5/32}"
ETCD2_WG0="${ETCD2_WG0:-10.77.0.6/32}"; ETCD2_WG1="${ETCD2_WG1:-10.78.0.6/32}"; ETCD2_WG2="${ETCD2_WG2:-10.79.0.6/32}"; ETCD2_WG3="${ETCD2_WG3:-10.80.0.6/32}"
ETCD3_WG0="${ETCD3_WG0:-10.77.0.7/32}"; ETCD3_WG1="${ETCD3_WG1:-10.78.0.7/32}"; ETCD3_WG2="${ETCD3_WG2:-10.79.0.7/32}"; ETCD3_WG3="${ETCD3_WG3:-10.80.0.7/32}"
K8SCP1_WG0="${K8SCP1_WG0:-10.77.0.8/32}"; K8SCP1_WG1="${K8SCP1_WG1:-10.78.0.8/32}"; K8SCP1_WG2="${K8SCP1_WG2:-10.79.0.8/32}"; K8SCP1_WG3="${K8SCP1_WG3:-10.80.0.8/32}"
K8SCP2_WG0="${K8SCP2_WG0:-10.77.0.9/32}"; K8SCP2_WG1="${K8SCP2_WG1:-10.78.0.9/32}"; K8SCP2_WG2="${K8SCP2_WG2:-10.79.0.9/32}"; K8SCP2_WG3="${K8SCP2_WG3:-10.80.0.9/32}"
K8SCP3_WG0="${K8SCP3_WG0:-10.77.0.10/32}"; K8SCP3_WG1="${K8SCP3_WG1:-10.78.0.10/32}"; K8SCP3_WG2="${K8SCP3_WG2:-10.79.0.10/32}"; K8SCP3_WG3="${K8SCP3_WG3:-10.80.0.10/32}"
K8SW1_WG0="${K8SW1_WG0:-10.77.0.11/32}"; K8SW1_WG1="${K8SW1_WG1:-10.78.0.11/32}"; K8SW1_WG2="${K8SW1_WG2:-10.79.0.11/32}"; K8SW1_WG3="${K8SW1_WG3:-10.80.0.11/32}"
K8SW2_WG0="${K8SW2_WG0:-10.77.0.12/32}"; K8SW2_WG1="${K8SW2_WG1:-10.78.0.12/32}"; K8SW2_WG2="${K8SW2_WG2:-10.79.0.12/32}"; K8SW2_WG3="${K8SW2_WG3:-10.80.0.12/32}"
K8SW3_WG0="${K8SW3_WG0:-10.77.0.13/32}"; K8SW3_WG1="${K8SW3_WG1:-10.78.0.13/32}"; K8SW3_WG2="${K8SW3_WG2:-10.79.0.13/32}"; K8SW3_WG3="${K8SW3_WG3:-10.80.0.13/32}"
K8SLB1_WG0="${K8SLB1_WG0:-10.77.0.14/32}"; K8SLB1_WG1="${K8SLB1_WG1:-10.78.0.14/32}"; K8SLB1_WG2="${K8SLB1_WG2:-10.79.0.14/32}"; K8SLB1_WG3="${K8SLB1_WG3:-10.80.0.14/32}"
K8SLB2_WG0="${K8SLB2_WG0:-10.77.0.15/32}"; K8SLB2_WG1="${K8SLB2_WG1:-10.78.0.15/32}"; K8SLB2_WG2="${K8SLB2_WG2:-10.79.0.15/32}"; K8SLB2_WG3="${K8SLB2_WG3:-10.80.0.15/32}"
K8SLB3_WG0="${K8SLB3_WG0:-10.77.0.16/32}"; K8SLB3_WG1="${K8SLB3_WG1:-10.78.0.16/32}"; K8SLB3_WG2="${K8SLB3_WG2:-10.79.0.16/32}"; K8SLB3_WG3="${K8SLB3_WG3:-10.80.0.16/32}"

# =============================================================================
# VM sizing (resources per role)
# =============================================================================
# Memory in MB, cores as vCPUs, disk in GB.

MASTER_MEM="${MASTER_MEM:-4096}"; MASTER_CORES="${MASTER_CORES:-4}";  MASTER_DISK_GB="${MASTER_DISK_GB:-40}"
MINION_MEM="${MINION_MEM:-4096}"; MINION_CORES="${MINION_CORES:-4}"; MINION_DISK_GB="${MINION_DISK_GB:-32}"
K8S_MEM="${K8S_MEM:-8192}"
STOR_DISK_GB="${STOR_DISK_GB:-64}"
K8S_LB_MEM="${K8S_LB_MEM:-2048}"; K8S_LB_CORES="${K8S_LB_CORES:-2}";  K8S_LB_DISK_GB="${K8S_LB_DISK_GB:-16}"
K8S_CP_MEM="${K8S_CP_MEM:-8192}"; K8S_CP_CORES="${K8S_CP_CORES:-4}";  K8S_CP_DISK_GB="${K8S_CP_DISK_GB:-50}"
K8S_WK_MEM="${K8S_WK_MEM:-8192}"; K8S_WK_CORES="${K8S_WK_CORES:-4}";  K8S_WK_DISK_GB="${K8S_WK_DISK_GB:-60}"

# =============================================================================
# Admin / auth / GUI
# =============================================================================

ADMIN_USER="${ADMIN_USER:-todd}"                                              # ADMIN_USER: primary admin account created in the guest.
ADMIN_PUBKEY_FILE="${ADMIN_PUBKEY_FILE:-}"
SSH_PUBKEY="${SSH_PUBKEY:-ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINgqdaF+C41xwLS41+dOTnpsrDTPkAwo4Zejn4tb0lOt todd@onyx.unixbox.net}"  # SSH_PUBKEY: SSH public key for ADMIN_USER.
ALLOW_ADMIN_PASSWORD="${ALLOW_ADMIN_PASSWORD:-${ALLOW_TODD_PASSWORD:-no}}"    # ALLOW_ADMIN_PASSWORD: whether password SSH auth is enabled for ADMIN_USER. (yes|no)

GUI_PROFILE="${GUI_PROFILE:-server}"                                          # GUI_PROFILE: what kind of GUI to install (if any). (server|gnome|minimal)
INSTALL_ANSIBLE="${INSTALL_ANSIBLE:-yes}"                                     # INSTALL_ANSIBLE: whether to install Ansible on master (yes|no).
INSTALL_SEMAPHORE="${INSTALL_SEMAPHORE:-no}"                                  # INSTALL_SEMAPHORE: yes | try | no
TMUX_CONF="${TMUX_CONF:-/etc/skel/.tmux.conf}"

# =============================================================================
# Build artifacts / disk image paths
# =============================================================================

BUILD_ROOT="${BUILD_ROOT:-/root/builds}"                                      # BUILD_ROOT: base directory on the build server for all outputs.
mkdir -p "$BUILD_ROOT"

BASE_DISK_IMAGE="${BASE_DISK_IMAGE:-$BUILD_ROOT/base-root.qcow2}"             # BASE_DISK_IMAGE: exported “golden” VM disk (qcow2 or raw). Used as input for vmdk-export, aws-ami, etc
BASE_RAW_IMAGE="${BASE_RAW_IMAGE:-$BUILD_ROOT/base-root.raw}"                 # BASE_RAW_IMAGE: optional explicit raw image path (for tools needing raw).
BASE_VMDK_IMAGE="${BASE_VMDK_IMAGE:-$BUILD_ROOT/base-root.vmdk}"              # BASE_VMDK_IMAGE: default VMDK path (ESXi).

# =============================================================================
# AWS image bake / EC2 run
# =============================================================================

AWS_REGION="${AWS_REGION:-us-east-1}"                                         # AWS_REGION: AWS region (e.g. us-east-1, us-west-2, ca-central-1)
AWS_PROFILE="${AWS_PROFILE:-default}"                                         # AWS_PROFILE: AWS CLI profile to use (from ~/.aws/credentials).
AWS_S3_BUCKET="${AWS_S3_BUCKET:-foundrybot-images}"                           # AWS_S3_BUCKET: S3 bucket used during AMI import.
AWS_IMPORT_ROLE="${AWS_IMPORT_ROLE:-vmimport}"                                # AWS_IMPORT_ROLE: IAM role for VM import (typically 'vmimport').
AWS_ARCH="${AWS_ARCH:-x86_64}"                                                # AWS_ARCH: AMI architecture (x86_64 | arm64).
AWS_INSTANCE_TYPE="${AWS_INSTANCE_TYPE:-t3.micro}"                            # AWS_INSTANCE_TYPE: EC2 instance type for builds / runs.
AWS_ASSOC_PUBLIC_IP="${AWS_ASSOC_PUBLIC_IP:-true}"                            # AWS_ASSOC_PUBLIC_IP: whether to associate public IP on run (true|false).
AWS_KEY_NAME="${AWS_KEY_NAME:-clusterkey}"                                    # AWS_KEY_NAME: Name of EC2 KeyPair to inject.
AWS_SECURITY_GROUP_ID="${AWS_SECURITY_GROUP_ID:-}"                            # AWS_SECURITY_GROUP_ID: Security Group ID for run (required for aws-run).
AWS_SUBNET_ID="${AWS_SUBNET_ID:-}"                                            # AWS_SUBNET_ID: Subnet ID where instances will be launched.
AWS_VPC_ID="${AWS_VPC_ID:-}"                                                  # AWS_VPC_ID: VPC ID (optional; some flows infer from subnet).
AWS_AMI_ID="${AWS_AMI_ID:-}"                                                  # AWS_AMI_ID: The AMI ID to run (required for aws-run).
AWS_TAG_STACK="${AWS_TAG_STACK:-foundrybot}"                                  # AWS_TAG_STACK: Base tag value for "Stack" or similar.
AWS_RUN_ROLE="${AWS_RUN_ROLE:-generic}"                                       # AWS_RUN_ROLE: logical role name for instances launched by aws-run.
AWS_RUN_COUNT="${AWS_RUN_COUNT:-1}"                                           # AWS_RUN_COUNT: number of instances to launch in aws-run.

# =============================================================================
# Firecracker microVM parameters
# =============================================================================

FC_IMG_SIZE_MB="${FC_IMG_SIZE_MB:-2048}"                                      # FC_IMG_SIZE_MB: rootfs size when creating Firecracker images.
FC_VCPUS="${FC_VCPUS:-2}"                                                     # FC_VCPUS / FC_MEM_MB: default Firecracker vCPU count and RAM in MB.
FC_MEM_MB="${FC_MEM_MB:-2048}"
FC_ROOTFS_IMG="${FC_ROOTFS_IMG:-$BUILD_ROOT/firecracker/rootfs.ext4}"         # FC_ROOTFS_IMG / FC_KERNEL / FC_INITRD: paths to Firecracker artifacts.
FC_KERNEL="${FC_KERNEL:-$BUILD_ROOT/firecracker/vmlinux}"
FC_INITRD="${FC_INITRD:-$BUILD_ROOT/firecracker/initrd.img}"
FC_WORKDIR="${FC_WORKDIR:-$BUILD_ROOT/firecracker}"                           # FC_WORKDIR: directory holding Firecracker configs/run scripts.

# =============================================================================
# Packer output paths
# =============================================================================

PACKER_OUT_DIR="${PACKER_OUT_DIR:-$BUILD_ROOT/packer}"                        # PACKER_OUT_DIR: where Packer templates live.
PACKER_TEMPLATE="${PACKER_TEMPLATE:-$PACKER_OUT_DIR/foundrybot-qemu.json}"    # PACKER_TEMPLATE: path to generated QEMU Packer template.

# =============================================================================
# ESXi / VMDK export
# =============================================================================

VMDK_OUTPUT="${VMDK_OUTPUT:-$BASE_VMDK_IMAGE}"                                # VMDK_OUTPUT: target VMDK path when exporting BASE_DISK_IMAGE.

# =============================================================================
# Enrollment SSH keypair (for WireGuard / cluster enrollment)
# =============================================================================

ENROLL_KEY_NAME="${ENROLL_KEY_NAME:-enroll_ed25519}"                          # ENROLL_KEY_NAME: filename stem for enroll SSH keypair.
ENROLL_KEY_DIR="$BUILD_ROOT/keys"                                             # ENROLL_KEY_DIR: directory to store enrollment keys under BUILD_ROOT.
ENROLL_KEY_PRIV="$ENROLL_KEY_DIR/${ENROLL_KEY_NAME}"                          # ENROLL_KEY_PRIV / ENROLL_KEY_PUB: private/public key paths.
ENROLL_KEY_PUB="$ENROLL_KEY_DIR/${ENROLL_KEY_NAME}.pub"

ensure_enroll_keypair() {
  mkdir -p "$ENROLL_KEY_DIR"
  if [[ ! -f "$ENROLL_KEY_PRIV" || ! -f "$ENROLL_KEY_PUB" ]]; then
    log "Generating cluster enrollment SSH keypair in $ENROLL_KEY_DIR"
    ssh-keygen -t ed25519 -N "" -f "$ENROLL_KEY_PRIV" -C "enroll@cluster" >/dev/null
  else
    log "Using existing cluster enrollment keypair in $ENROLL_KEY_DIR"
  fi
}

# =============================================================================
# Tool sanity checks
# =============================================================================

require_cmd xorriso || true
command -v xorriso >/dev/null || { err "xorriso not installed (needed for ISO build)"; }

SSH_OPTS="-q -o LogLevel=ERROR -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o CheckHostIP=no -o ConnectTimeout=6 -o BatchMode=yes"
sssh(){ ssh $SSH_OPTS "$@"; }
sscp(){ scp -q $SSH_OPTS "$@"; }

log() { echo "[INFO]  $(date '+%F %T') - $*"; }
warn(){ echo "[WARN]  $(date '+%F %T') - $*" >&2; }
err() { echo "[ERROR] $(date '+%F %T') - $*"; }
die(){ err "$*"; exit 1; }

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "Required command not found in PATH: $cmd"
}

command -v xorriso >/dev/null || { err "xorriso not installed (needed for ISO build)"; }

# =============================================================================
# DARKSITE APT REPO BUILD HELPERS
# =============================================================================

# How to build the darksite APT snapshot when host is not Debian-based.
#   auto      = if apt-get exists -> native, else -> container
#   native    = require apt-get on host
#   container = always use Debian container builder
DARKSITE_BUILDER="${DARKSITE_BUILDER:-auto}"          # auto|native|container
CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-docker}"      # podman|docker
DEBIAN_CONTAINER_IMAGE="${DEBIAN_CONTAINER_IMAGE:-debian:${DEBIAN_CODENAME:-trixie}}"

# Optional: if you want to pin to stable builder regardless of target codename:
# DEBIAN_CONTAINER_IMAGE="${DEBIAN_CONTAINER_IMAGE:-debian:bookworm}"

have_cmd() { command -v "$1" >/dev/null 2>&1; }

ensure_container_runtime() {
  local rt="$CONTAINER_RUNTIME"
  have_cmd "$rt" || die "Container runtime not found: $rt (set CONTAINER_RUNTIME=docker or install podman/docker)"
}

darksite_build_apt_repo__native() {
  local dest="$1"
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$dest"

  have_cmd apt-get || die "native darksite builder requires apt-get (not available on this host). Set DARKSITE_BUILDER=container."

  # install deps
  local need=()
  for c in apt-rdepends dpkg-scanpackages apt-ftparchive gzip; do
    have_cmd "$c" || need+=("$c")
  done
  if (( ${#need[@]} > 0 )); then
    log "[*] Installing darksite build deps (missing: ${need[*]})"
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y apt-rdepends dpkg-dev apt-utils gnupg ca-certificates
    hash -r
  fi

  require_cmd apt-rdepends
  require_cmd dpkg-scanpackages
  require_cmd apt-ftparchive
  require_cmd gzip

  if [[ "${DARKSITE_CLEAN_BUILD:-1}" == "1" ]]; then
    rm -rf "${dest:?}/"*
  fi

  log "[*] Building darksite APT repo into: $dest"
  log "[*] Darksite root packages: ${DARKSITE_ROOT_PKGS}"

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
  if (( ${#debs[@]} == 0 )); then
    die "Darksite repo build failed: no .deb files were downloaded."
  fi

  mv "$tmp"/*.deb "$dest/"

  ( cd "$dest" && dpkg-scanpackages . /dev/null > Packages )
  gzip -9c "$dest/Packages" > "$dest/Packages.gz"
  ( cd "$dest" && apt-ftparchive release . > Release )

  rm -rf "$tmp"
  log "[OK] Darksite APT repo ready: $dest"
}

darksite_build_apt_repo__container() {
  local dest="$1"
  mkdir -p "$dest"
  ensure_container_runtime

  # Build in a debian container, output written directly to $dest via bind mount.
  # Use host network so the container can reach mirrors if REPO_MODE allows it.
  log "[*] Building darksite APT repo in container: ${DEBIAN_CONTAINER_IMAGE} (runtime=$CONTAINER_RUNTIME)"
  log "[*] Output dir: $dest"

  # The script we run inside the container
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

  # Run it
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

  log "[OK] Darksite APT repo ready: $dest"
}

darksite_build_apt_repo() {
  # Unified entrypoint used by mk_iso().
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
# PROXMOX HELPERS
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

pmx_qga_has_json() {
  if [[ "${PMX_QGA_JSON:-}" == "yes" || "${PMX_QGA_JSON:-}" == "no" ]]; then
    echo "$PMX_QGA_JSON"; return
  fi
  PMX_QGA_JSON="$( pmx "qm guest exec -h 2>&1 | grep -q -- '--output-format' && echo yes || echo no" | tr -d '\r' )"
  echo "$PMX_QGA_JSON"
}

pmx_guest_exec() {
  local vmid="$1"; shift
  pmx "qm guest exec $vmid -- $* >/dev/null 2>&1 || true"
}

pmx_guest_cat() {
  local vmid="$1" path="$2"
  local has_json raw pid status outb64 outplain outjson

  has_json="$(pmx_qga_has_json)"

  if [[ "$has_json" == "yes" ]]; then
    raw="$(pmx "qm guest exec $vmid --output-format json -- /bin/cat '$path' 2>/dev/null || true")"
    pid="$(printf '%s\n' "$raw" | sed -n 's/.*\"pid\"[[:space:]]*:[[:space:]]*\([0-9]\+\).*/\1/p')"
    [[ -n "$pid" ]] || return 2
    while :; do
      status="$(pmx "qm guest exec-status $vmid $pid --output-format json 2>/dev/null || true")" || true
      if printf '%s' "$status" | grep -Eq '"exited"[[:space:]]*:[[:space:]]*(true|1)'; then
        outb64="$(printf '%s' "$status" | sed -n 's/.*\"out-data\"[[:space:]]*:[[:space:]]*\"\([^"]*\)\".*/\1/p')"
        if [[ -n "$outb64" ]]; then
          printf '%s' "$outb64" | base64 -d 2>/dev/null || printf '%b' "${outb64//\\n/$'\n'}"
        else
          outplain="$(printf '%s' "$status" | sed -n 's/.*\"out\"[[:space:]]*:[[:space:]]*\"\([^"]*\)\".*/\1/p')"
          printf '%b' "${outplain//\\n/$'\n'}"
        fi
        break
      fi
      sleep 1
    done
  else
    outjson="$(pmx "qm guest exec $vmid -- /bin/cat '$path' 2>/dev/null || true")"
    outb64="$(printf '%s\n' "$outjson" | sed -n 's/.*\"out-data\"[[:space:]]*:[[:space:]]*\"\(.*\)\".*/\1/p')"
    if [[ -n "$outb64" ]]; then
      printf '%b' "${outb64//\\n/$'\n'}"
    else
      outplain="$(printf '%s\n' "$outjson" | sed -n 's/.*\"out\"[[:space:]]*:[[:space:]]*\"\(.*\)\".*/\1/p')"
      [[ -n "$outplain" ]] || return 3
      printf '%b' "${outplain//\\n/$'\n'}"
    fi
  fi
}

pmx_upload_iso() {
  local iso_file="$1" iso_base
  iso_base="$(basename "$iso_file")"
  sscp "$iso_file" "root@${PROXMOX_HOST}:/var/lib/vz/template/iso/$iso_base" || {
    log "ISO upload retry: $iso_base"; sleep 2
    sscp "$iso_file" "root@${PROXMOX_HOST}:/var/lib/vz/template/iso/$iso_base"
  }
  pmx "for i in {1..30}; do pvesm list ${ISO_STORAGE} | awk '{print \$5}' | grep -qx \"${iso_base}\" && exit 0; sleep 1; done; exit 1" \
    || warn "pvesm list didn't show ${iso_base} yet—will still try to attach"
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

# Create VM with Secure Boot + TPM2
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

# UEFI firmware + Secure Boot keys
qm set "$VMID" --bios ovmf
qm set "$VMID" --efidisk0 ${VM_STORAGE}:0,efitype=4m,pre-enrolled-keys=1

# TPM 2.0 state
qm set "$VMID" --tpmstate ${VM_STORAGE}:1,version=v2.0,size=4M

# Attach installer ISO
for i in {1..10}; do
  if qm set "$VMID" --ide2 ${ISO_STORAGE}:iso/${FINAL_ISO},media=cdrom 2>/dev/null; then
    break
  fi
  sleep 1
done

if ! qm config "$VMID" | grep -q '^ide2:.*media=cdrom'; then
  echo "[X] failed to attach ISO ${FINAL_ISO} from ${ISO_STORAGE}" >&2
  exit 1
fi

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

seed_tmux_conf() {
  : "${ADMIN_USER:=todd}"
  : "${TMUX_CONF:=/etc/skel/.tmux.conf}"

  log "Writing tmux config to ${TMUX_CONF}"
  install -d -m0755 "$(dirname "$TMUX_CONF")"

  cat >"$TMUX_CONF" <<'EOF'
set -g mouse on
set -g history-limit 100000
setw -g mode-keys vi
bind -n C-Space copy-mode
EOF

  # Copy to root and admin user if they exist
  if id root >/dev/null 2>&1; then
    cp -f "$TMUX_CONF" /root/.tmux.conf
  fi
  if id "$ADMIN_USER" >/dev/null 2>&1; then
    cp -f "$TMUX_CONF" "/home/${ADMIN_USER}/.tmux.conf"
    chown "${ADMIN_USER}:${ADMIN_USER}" "/home/${ADMIN_USER}/.tmux.conf"
  fi
}

# =============================================================================
# ISO BUILDER
# =============================================================================

mk_iso() {
  local name="$1"              # hostname short name (e.g. etcd-1, cp-1, w-1, storage)
  local postinstall_src="$2"   # postinstall.sh source path
  local iso_out="$3"           # output ISO path
  local static_ip="${4:-}"     # optional static ip

  local build="$BUILD_ROOT/$name"
  local mnt="$build/mnt"
  local cust="$build/custom"

  rm -rf "$build" 2>/dev/null || true
  mkdir -p "$mnt" "$cust"

  # =============================================================================
  # Copy original ISO contents into custom tree FIRST
  # (This prevents later operations from being overwritten by the ISO copy step.)
  # =============================================================================
  (
    set -euo pipefail
    trap 'umount -f "$mnt" 2>/dev/null || true' EXIT
    mount -o loop,ro "$ISO_ORIG" "$mnt"
    cp -a "$mnt/"* "$cust/"
    cp -a "$mnt/.disk" "$cust/" 2>/dev/null || true
  )

  # =============================================================================
  # Ensure ISO darksite/ exists, then bake payload into it
  # =============================================================================
  local dark="$cust/darksite"
  mkdir -p "$dark"

  log "mk_iso: effective DARKSITE_SRC=${DARKSITE_SRC:-<unset>}"

  # ---------------------------------------------------------------------------
  # Bake darksite payload into ISO darksite/
  #   - optional static payload (DARKSITE_SRC)
  #   - optional on-demand APT repo snapshot (DARKSITE_BUILD_ON_DEMAND)
  # ---------------------------------------------------------------------------
  if [[ -d "${DARKSITE_SRC:-}" ]]; then
    log "Baking DARKSITE_SRC=$DARKSITE_SRC into ISO darksite/"
    rsync -a --delete "$DARKSITE_SRC"/ "$dark"/

    # If not master, remove ansible material from ISO payload
    if [[ "${name}" != "master" && "${name}" != "master.unixbox.net" ]]; then
      rm -rf "$dark/ansible" 2>/dev/null || true
      rm -f  "$dark/ansible_ed25519" 2>/dev/null || true
    fi
  else
    warn "DARKSITE_SRC not found: ${DARKSITE_SRC:-<unset>} (skipping extra darksite payload)"
  fi

  # Build and bake the ISO-local APT repo snapshot (true time capsule)
  if [[ "$REPO_MODE" == "darksite" || "$REPO_MODE" == "both" ]]; then
    if [[ "${DARKSITE_BUILD_ON_DEMAND:-yes}" == "yes" ]]; then
      log "[*] Building ISO-local APT repo snapshot (REPO_MODE=$REPO_MODE)"
      darksite_build_apt_repo "$dark/apt"
    else
      warn "DARKSITE_BUILD_ON_DEMAND=no — expecting repo already present at $dark/apt"
    fi
  fi

  # =============================================================================
  # Bake postinstall payload into ISO darksite/
  # =============================================================================
  install -m0755 "$postinstall_src" "$dark/postinstall.sh"

  # =============================================================================
  # systemd one-shot bootstrap to run postinstall.sh once
  # =============================================================================
  cat >"$dark/bootstrap.service" <<'EOF'
[Unit]
Description=Initial Bootstrap Script (One-time)
After=network-online.target
Wants=network-online.target
ConditionPathExists=/root/darksite/postinstall.sh
ConditionPathExists=!/root/.bootstrap_done

[Service]
Type=oneshot
Environment=SHELL=/bin/bash
ExecStart=/bin/bash -lc '/root/darksite/postinstall.sh'
StandardOutput=journal+console
StandardError=journal+console
TimeoutStartSec=0
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  # =============================================================================
  # systemd one-shot apply unit (MUST NOT be embedded via heredoc in preseed)
  # Ship this file in ISO payload and copy it in-target in late_command.
  # =============================================================================
  mkdir -p "$dark/systemd"
  cat >"$dark/systemd/darksite-apply.service" <<'EOF'
[Unit]
Description=KubeOS apply (one-shot)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/env python3 /srv/darksite/apply.py
WorkingDirectory=/srv/darksite
StandardOutput=journal
StandardError=journal
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF

  # =============================================================================
  # Provision env file (consumed by postinstall/apply)
  # =============================================================================
  {
    echo "DOMAIN=${DOMAIN}"
    echo "ADMIN_USER=${ADMIN_USER}"
    echo "MASTER_LAN=${MASTER_LAN}"
    echo "ALLOW_ADMIN_PASSWORD=${ALLOW_ADMIN_PASSWORD}"
    echo "WG_ALLOWED_CIDR=${WG_ALLOWED_CIDR}"
    echo "GUI_PROFILE=${GUI_PROFILE}"
    echo "WG0_PORT=${WG0_PORT}"
    echo "WG1_PORT=${WG1_PORT}"
    echo "WG2_PORT=${WG2_PORT}"
    echo "WG3_PORT=${WG3_PORT}"
    echo "INSTALL_ANSIBLE=${INSTALL_ANSIBLE}"
    echo "INSTALL_SEMAPHORE=${INSTALL_SEMAPHORE}"
    echo "REPO_MODE=${REPO_MODE}"
    echo "DEBIAN_CODENAME=${DEBIAN_CODENAME}"
  } >"$dark/99-provision.conf"

  # =============================================================================
  # Admin authorized key seed (optional)
  # =============================================================================
  local auth_seed="$dark/authorized_keys.${ADMIN_USER}"
  if [[ -n "${SSH_PUBKEY:-}" ]]; then
    printf '%s\n' "$SSH_PUBKEY" >"$auth_seed"
  elif [[ -n "${ADMIN_PUBKEY_FILE:-}" && -r "$ADMIN_PUBKEY_FILE" ]]; then
    cat "$ADMIN_PUBKEY_FILE" >"$auth_seed"
  else
    : >"$auth_seed"
  fi
  chmod 0644 "$auth_seed"

  # =============================================================================
  # Bake enrollment keypair (optional)
  # =============================================================================
  if [[ -n "${ENROLL_KEY_PRIV:-}" && -n "${ENROLL_KEY_PUB:-}" && -f "$ENROLL_KEY_PRIV" && -f "$ENROLL_KEY_PUB" ]]; then
    install -m0600 "$ENROLL_KEY_PRIV" "$dark/enroll_ed25519"
    install -m0644 "$ENROLL_KEY_PUB"  "$dark/enroll_ed25519.pub"
  fi

  # =============================================================================
  # Preseed networking block (DHCP vs static)
  # =============================================================================
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

  # =============================================================================
  # APT snippet (DARKSITE vs CONNECTED vs BOTH)
  # =============================================================================
  local APT_SNIPPET
  APT_SNIPPET="$(preseed_emit_apt_snippet)"

  # =============================================================================
  # Write preseed.cfg (NO heredocs inside late_command)
  # =============================================================================
  cat >"$cust/preseed.cfg" <<'EOF'
# =============================================================================
# Force full automation (prevents installer prompts from stopping the run)
# =============================================================================
d-i debconf/frontend select Noninteractive
d-i debconf/priority string critical

# =============================================================================
# Prevent netinst from prompting: "Scan extra installation media?"
# =============================================================================
d-i apt-cdrom-setup/another boolean false

# (optional) keep cdrom handling stable
#d-i apt-setup/cdrom/set-first boolean true
d-i apt-setup/cdrom/set-next boolean false
d-i apt-setup/cdrom/set-failed boolean false

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

# =============================================================================
# Late command: seed darksite + bootstrap + apply (ONE LINE SAFE)
# =============================================================================
d-i preseed/late_command string \
  set -e; \
  FQDN="__FQDN__"; SHORT="__SHORT__"; \
  echo "$FQDN" > /target/etc/hostname; \
  in-target hostnamectl set-hostname "$FQDN" || true; \
  if grep -q '^127\.0\.1\.1' /target/etc/hosts; then \
    sed -ri "s/^127\.0\.1\.1.*/127.0.1.1\t$FQDN\t$SHORT/" /target/etc/hosts; \
  else \
    printf '\n127.0.1.1\t%s\t%s\n' "$FQDN" "$SHORT" >> /target/etc/hosts; \
  fi; \
  mkdir -p /target/root/darksite; \
  cp -a /cdrom/darksite/. /target/root/darksite/; \
  in-target chmod +x /root/darksite/postinstall.sh /root/darksite/apply.py /root/darksite/wg-refresh-planes.py 2>/dev/null || true; \
  in-target mkdir -p /srv/ansible /srv/darksite /etc/systemd/system /etc/environment.d /var/lib/kubeos; \
  if in-target test -f /etc/hostname && in-target grep -qi "^master" /etc/hostname; then in-target cp -a /root/darksite/ansible/. /srv/ansible/ 2>/dev/null || true; fi; \
  in-target install -m 0755 /root/darksite/apply.py /srv/darksite/apply.py 2>/dev/null || true; \
  in-target install -m 0755 /root/darksite/wg-refresh-planes.py /srv/darksite/wg-refresh-planes.py 2>/dev/null || true; \
  in-target cp -a /root/darksite/systemd/. /etc/systemd/system/ 2>/dev/null || true; \
  in-target install -m 0644 /root/darksite/bootstrap.service /etc/systemd/system/bootstrap.service; \
  in-target install -m 0644 /root/darksite/99-provision.conf /etc/environment.d/99-provision.conf; \
  in-target chmod 0644 /etc/environment.d/99-provision.conf; \
  in-target systemctl daemon-reload; \
  in-target systemctl disable --now darksite-wg-reflector.timer 2>/dev/null || true; \
  in-target systemctl disable --now darksite-wg-reflector.service 2>/dev/null || true; \
  in-target systemctl mask darksite-wg-reflector.timer 2>/dev/null || true; \
  in-target systemctl mask darksite-wg-reflector.service 2>/dev/null || true; \
  in-target systemctl enable darksite-apply.service 2>/dev/null || true; \
  in-target systemctl enable bootstrap.service 2>/dev/null || true; \
  in-target /bin/systemctl --no-block poweroff || true

d-i cdrom-detect/eject boolean true
d-i finish-install/reboot_in_progress note
d-i finish-install/exit-installer boolean true
d-i debian-installer/exit/poweroff boolean true
EOF

  # =============================================================================
  # Replace placeholders safely (NETBLOCK/APT_SNIPPET are multiline; use perl)
  # =============================================================================
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

  # =============================================================================
  # Preseed sanitation + validation (fail fast)
  # =============================================================================
  sed -i 's/\r$//' "$cust/preseed.cfg" || true
  perl -i -pe 's/^\x{FEFF}//' "$cust/preseed.cfg" 2>/dev/null || true

  # Fail hard if the preseed accidentally contains systemd unit headers
  if grep -qE '^\[(Unit|Service|Install)\]' "$cust/preseed.cfg"; then
    echo '[FATAL] preseed.cfg contains raw systemd unit stanza lines; this will break d-i.' >&2
    nl -ba "$cust/preseed.cfg" | sed -n '1,220p' >&2
    die 'Invalid preseed.cfg (contains unit headers)'
  fi

  if ! command -v debconf-set-selections >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y debconf-utils >/dev/null 2>&1 || true
  fi
  if command -v debconf-set-selections >/dev/null 2>&1; then
    if ! debconf-set-selections --checkonly <"$cust/preseed.cfg"; then
      echo '[FATAL] preseed.cfg failed debconf validation. Showing first 220 lines:' >&2
      nl -ba "$cust/preseed.cfg" | sed -n '1,220p' >&2
      die 'Invalid preseed.cfg generated (debconf check failed)'
    fi
  fi

  # =============================================================================
  # Bootloader patching (BIOS + UEFI)
  # =============================================================================
  local KARGS="auto=true priority=critical vga=788 preseed/file=/cdrom/preseed.cfg ---"

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

    if grep -q '^set[[:space:]]\+default=' "$cfg"; then
      sed -i 's/^set[[:space:]]\+default.*/set default="0"/' "$cfg" || true
    else
      sed -i '1i set default="0"' "$cfg" || true
    fi

    if grep -q '^set[[:space:]]\+timeout=' "$cfg"; then
      sed -i 's/^set[[:space:]]\+timeout.*/set timeout=1/' "$cfg" || true
    else
      sed -i '1i set timeout=1' "$cfg" || true
    fi

    # Append kernel args to linux lines
    sed -i "s#^\([[:space:]]*linux[[:space:]]\+\S\+\)#\1 $KARGS#g" "$cfg" || true
  done

  local efi_img=""
  if [[ -f "$cust/boot/grub/efi.img" ]]; then
    efi_img="boot/grub/efi.img"
  elif [[ -f "$cust/efi.img" ]]; then
    efi_img="efi.img"
  fi

  # =============================================================================
  # Final ISO repack (BIOS+UEFI hybrid if possible)
  # =============================================================================
  if [[ -f "$cust/isolinux/isolinux.bin" && -f "$cust/isolinux/boot.cat" && -f /usr/share/syslinux/isohdpfx.bin ]]; then
    log "Repacking ISO (BIOS+UEFI hybrid) -> $iso_out"

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
    log "No isolinux BIOS bits found; building UEFI-only ISO"

    [[ -n "$efi_img" ]] || die "EFI image not found in ISO tree - cannot build bootable ISO"

    xorriso -as mkisofs \
      -o "$iso_out" \
      -r -J -joliet-long -l \
      -eltorito-alt-boot \
      -e "$efi_img" \
      -no-emul-boot -isohybrid-gpt-basdat \
      "$cust"
  fi

  # =============================================================================
  # Quick sanity check: ensure /darksite/ and /preseed.cfg exist in the ISO tree.
  # =============================================================================
  if [[ ! -f "$cust/preseed.cfg" ]]; then
    die "preseed.cfg missing from ISO tree: $cust/preseed.cfg"
  fi
  if [[ ! -d "$cust/darksite" ]]; then
    die "darksite/ missing from ISO tree: $cust/darksite"
  fi
}

# =============================================================================
# MASTER POSTINSTALL
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

# Load seed environment if present (from mk_iso)
if [ -r /etc/environment.d/99-provision.conf ]; then
  # shellcheck disable=SC2046
  export $(grep -E '^[A-Z0-9_]+=' /etc/environment.d/99-provision.conf | xargs -d'\n' || true)
fi

# ---------- Defaults (if not seeded) ----------
DOMAIN="${DOMAIN:-unixbox.net}"

MASTER_LAN="${MASTER_LAN:-10.100.10.224}"

WG0_IP="${WG0_IP:-10.77.0.1/16}"; WG0_PORT="${WG0_PORT:-51820}"
WG1_IP="${WG1_IP:-10.78.0.1/16}"; WG1_PORT="${WG1_PORT:-51821}"
WG2_IP="${WG2_IP:-10.79.0.1/16}"; WG2_PORT="${WG2_PORT:-51822}"
WG3_IP="${WG3_IP:-10.80.0.1/16}"; WG3_PORT="${WG3_PORT:-51823}"

WG_ALLOWED_CIDR="${WG_ALLOWED_CIDR:-10.77.0.0/16,10.78.0.0/16,10.79.0.0/16,10.80.0.0/16}"

ADMIN_USER="${ADMIN_USER:-todd}"
ALLOW_ADMIN_PASSWORD="${ALLOW_ADMIN_PASSWORD:-no}"

INSTALL_ANSIBLE="${INSTALL_ANSIBLE:-yes}"
INSTALL_SEMAPHORE="${INSTALL_SEMAPHORE:-yes}"   # yes|try|no

HUB_NAME="${HUB_NAME:-master}"

# ---------- Helpers ----------
ensure_base() {
  log "Configuring APT & base system packages"
  export DEBIAN_FRONTEND=noninteractive

  cat >/etc/apt/sources.list <<'EOF'
deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware
EOF

  for i in 1 2 3; do
    if apt-get update -y; then break; fi
    sleep $((i*3))
  done

  apt-get install -y --no-install-recommends \
    sudo openssh-server curl wget ca-certificates gnupg jq xxd unzip tar \
    iproute2 iputils-ping net-tools \
    nftables wireguard-tools \
    python3-venv python3-pip python3-bpfcc python3-psutil \
    libbpfcc llvm libclang-cpp* \
    chrony rsyslog qemu-guest-agent vim || true

  echo wireguard >/etc/modules-load.d/wireguard.conf || true
  modprobe wireguard 2>/dev/null || true

  # Use python3 -m pip so we don’t care about pip vs pip3 name
  if command -v python3 >/dev/null; then
    python3 -m pip install --upgrade pip >/dev/null 2>&1 || true
    python3 -m pip install dnspython requests cryptography pyOpenSSL || true
  fi

  systemctl enable --now qemu-guest-agent chrony rsyslog ssh || true

  cat >/etc/sysctl.d/99-master.conf <<'EOF'
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
EOF

  sysctl --system || true
}

ensure_users(){
  local SEED="/root/darksite/authorized_keys.${ADMIN_USER}"
  local PUB=""; [[ -s "$SEED" ]] && PUB="$(head -n1 "$SEED")"

  mk(){ local u="$1" k="$2";
    id -u "$u" &>/dev/null || useradd -m -s /bin/bash "$u";
    install -d -m700 -o "$u" -g "$u" "/home/$u/.ssh";
    touch "/home/$u/.ssh/authorized_keys"; chmod 600 "/home/$u/.ssh/authorized_keys"
    chown -R "$u:$u" "/home/$u/.ssh"
    [[ -n "$k" ]] && grep -qxF "$k" "/home/$u/.ssh/authorized_keys" || {
      [[ -n "$k" ]] && printf '%s\n' "$k" >> "/home/$u/.ssh/authorized_keys"
    }
    install -d -m755 /etc/sudoers.d
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$u" >"/etc/sudoers.d/90-$u"
    chmod 0440 "/etc/sudoers.d/90-$u"
  }

  mk "$ADMIN_USER" "$PUB"

  # ansible service user
  id -u ansible &>/dev/null || useradd -m -s /bin/bash -G sudo ansible
  install -d -m700 -o ansible -g ansible /home/ansible/.ssh
  [[ -s /home/ansible/.ssh/id_ed25519 ]] || \
    runuser -u ansible -- ssh-keygen -t ed25519 -N "" -f /home/ansible/.ssh/id_ed25519
  install -m0644 /home/ansible/.ssh/id_ed25519.pub /home/ansible/.ssh/authorized_keys
  chown ansible:ansible /home/ansible/.ssh/authorized_keys
  chmod 600 /home/ansible/.ssh/authorized_keys
  cat >/etc/sudoers.d/90-ansible <<'EOF'
ansible ALL=(ALL) NOPASSWD:ALL
EOF
  chmod 0440 /etc/sudoers.d/90-ansible
  visudo -c >/dev/null

  # Allow the cluster enrollment key to log in as ADMIN_USER
  local ENROLL_PUB_SRC="/root/darksite/enroll_ed25519.pub"
  if [[ -s "$ENROLL_PUB_SRC" ]]; then
    local ENROLL_PUB
    ENROLL_PUB="$(head -n1 "$ENROLL_PUB_SRC")"
    if ! grep -qxF "$ENROLL_PUB" "/home/${ADMIN_USER}/.ssh/authorized_keys"; then
      printf '%s\n' "$ENROLL_PUB" >> "/home/${ADMIN_USER}/.ssh/authorized_keys"
    fi
  fi

  # Backplane is wg1
  local BACKPLANE_IF="wg1"
  local BACKPLANE_IP="${WG1_IP%/*}"

  install -d -m755 /etc/ssh/sshd_config.d
  cat >/etc/ssh/sshd_config.d/00-listen.conf <<EOF
ListenAddress ${MASTER_LAN}
ListenAddress ${BACKPLANE_IP}
AllowUsers ${ADMIN_USER} ansible
EOF

  cat >/etc/ssh/sshd_config.d/99-hard.conf <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
X11Forwarding no
AllowTcpForwarding no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
EOF

  if [ "${ALLOW_ADMIN_PASSWORD}" = "yes" ]; then
    cat >/etc/ssh/sshd_config.d/10-admin-lan-password.conf <<EOF
Match User ${ADMIN_USER} Address 10.100.10.0/24
    PasswordAuthentication yes
EOF
  fi

  install -d -m755 /etc/systemd/system/ssh.service.d
  cat >/etc/systemd/system/ssh.service.d/wg-order.conf <<'EOF'
[Unit]
After=wg-quick@wg1.service network-online.target
Wants=wg-quick@wg1.service network-online.target
EOF

  (sshd -t && systemctl daemon-reload && systemctl restart ssh) || true
}

wg_setup_planes() {
  log "Configuring WireGuard planes (wg0 reserved, wg1/wg2/wg3 active)"

  install -d -m700 /etc/wireguard
  local _old_umask; _old_umask="$(umask)"
  umask 077

  # Generate keys once per interface if missing
  local ifn
  for ifn in wg0 wg1 wg2 wg3; do
    [ -f "/etc/wireguard/${ifn}.key" ] || wg genkey | tee "/etc/wireguard/${ifn}.key" | wg pubkey >"/etc/wireguard/${ifn}.pub"
  done

  # wg0: reserved, NOT started (future use / extra plane)
  cat >/etc/wireguard/wg0.conf <<EOF
[Interface]
Address    = ${WG0_IP}
PrivateKey = $(cat /etc/wireguard/wg0.key)
ListenPort = ${WG0_PORT}
MTU        = 1420
EOF

  # wg1: Ansible / SSH plane
  cat >/etc/wireguard/wg1.conf <<EOF
[Interface]
Address    = ${WG1_IP}
PrivateKey = $(cat /etc/wireguard/wg1.key)
ListenPort = ${WG1_PORT}
MTU        = 1420
EOF

  # wg2: Metrics plane
  cat >/etc/wireguard/wg2.conf <<EOF
[Interface]
Address    = ${WG2_IP}
PrivateKey = $(cat /etc/wireguard/wg2.key)
ListenPort = ${WG2_PORT}
MTU        = 1420
EOF

  # wg3: K8s backend plane
  cat >/etc/wireguard/wg3.conf <<EOF
[Interface]
Address    = ${WG3_IP}
PrivateKey = $(cat /etc/wireguard/wg3.key)
ListenPort = ${WG3_PORT}
MTU        = 1420
EOF

  chmod 600 /etc/wireguard/*.conf
  umask "$_old_umask"

  systemctl daemon-reload || true
  systemctl enable --now wg-quick@wg1 || true
  systemctl enable --now wg-quick@wg2 || true
  systemctl enable --now wg-quick@wg3 || true
  # NOTE: wg0 is intentionally NOT enabled
}

nft_firewall() {
  # Try to detect the primary LAN interface (fallback to ens18 if we can't)
  local lan_if
  lan_if="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')" || true
  : "${lan_if:=ens18}"

  cat >/etc/nftables.conf <<EOF
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
  chain input {
    type filter hook input priority 0; policy drop;

    # Basic sanity
    ct state established,related accept
    iifname "lo" accept
    ip protocol icmp accept

    # SSH + RDP
    tcp dport 22 accept
    tcp dport 3389 accept

    # WireGuard ports
    udp dport { ${WG0_PORT}, ${WG1_PORT}, ${WG2_PORT}, ${WG3_PORT} } accept

    # Allow traffic arriving over the WG planes
    iifname "wg0" accept
    iifname "wg1" accept
    iifname "wg2" accept
    iifname "wg3" accept
  }

  chain forward {
    type filter hook forward priority 0; policy drop;

    ct state established,related accept

    # Allow WG planes to reach the LAN, and replies back
    iifname "wg1" oifname "${lan_if}" accept
    iifname "wg2" oifname "${lan_if}" accept
    iifname "wg3" oifname "${lan_if}" accept

    iifname "${lan_if}" oifname "wg1" accept
    iifname "${lan_if}" oifname "wg2" accept
    iifname "${lan_if}" oifname "wg3" accept
  }

  chain output {
    type filter hook output priority 0; policy accept;
  }
}

table ip nat {
  chain postrouting {
    type nat hook postrouting priority 100; policy accept;

    # Masquerade anything leaving via the LAN interface
    oifname "${lan_if}" masquerade
  }
}
EOF

  nft -f /etc/nftables.conf || true
  systemctl enable --now nftables || true
}

helper_tools() {
  log "Installing wg-add-peer, wg-enrollment, register-minion helpers"

  # wg-add-peer: generic, used for wg1/wg2/wg3 (wg0 if ever needed)
  cat >/usr/local/sbin/wg-add-peer <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
IFN="${3:-wg1}"
PUB="${1:-}"
ADDR="${2:-}"
FLAG="/srv/wg/ENROLL_ENABLED"

if [[ ! -f "$FLAG" ]]; then
  echo "[X] enrollment closed" >&2
  exit 2
fi
if [[ -z "$PUB" || -z "$ADDR" ]]; then
  echo "usage: wg-add-peer <pubkey> <ip/cidr> [ifname]" >&2
  exit 1
fi

if wg show "$IFN" peers 2>/dev/null | grep -qx "$PUB"; then
  wg set "$IFN" peer "$PUB" allowed-ips "$ADDR"
else
  wg set "$IFN" peer "$PUB" allowed-ips "$ADDR" persistent-keepalive 25
fi

CONF="/etc/wireguard/${IFN}.conf"
if ! grep -q "$PUB" "$CONF"; then
  printf "\n[Peer]\nPublicKey  = %s\nAllowedIPs = %s\nPersistentKeepalive = 25\n" "$PUB" "$ADDR" >> "$CONF"
fi

systemctl reload "wg-quick@${IFN}" 2>/dev/null || true

# TODO: XDP/eBPF hook:
#  - update an eBPF map with peer->plane info here for fast dataplane decisions.

echo "[+] added $PUB $ADDR on $IFN"
EOF
  chmod 0755 /usr/local/sbin/wg-add-peer

  # wg-enrollment: toggle ENROLL_ENABLED flag
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

  # register-minion:
  cat >/usr/local/sbin/register-minion <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

GROUP="${1:-}"
HOST="${2:-}"
IP="${3:-}"        # metrics (wg2) IP, port 9100

if [[ -z "$GROUP" || -z "$HOST" || -z "$IP" ]]; then
  echo "usage: $0 <group> <hostname> <metrics-ip>" >&2
  exit 2
fi

ANS_HOSTS="/etc/ansible/hosts"
PROM_DIR="/etc/prometheus/targets.d"
PROM_TGT="${PROM_DIR}/${GROUP}.json"

mkdir -p "$(dirname "$ANS_HOSTS")" "$PROM_DIR"
touch "$ANS_HOSTS"

# Ansible inventory: we use IP as ansible_host for now.
if ! grep -q "^\[${GROUP}\]" "$ANS_HOSTS"; then
  printf "\n[%s]\n" "$GROUP" >> "$ANS_HOSTS"
fi
sed -i "/^${HOST}\b/d" "$ANS_HOSTS"
printf "%s ansible_host=%s\n" "$HOST" "$IP" >> "$ANS_HOSTS"

# Prometheus file_sd target for node_exporter (fixed port 9100)
if [[ ! -s "$PROM_TGT" ]]; then
  echo '[]' > "$PROM_TGT"
fi

tmp="$(mktemp)"
jq --arg target "${IP}:9100" '
  map(select(.targets|index($target)|not)) + [{"targets":[$target]}]
' "$PROM_TGT" > "$tmp" && mv "$tmp" "$PROM_TGT"

if pidof prometheus >/dev/null 2>&1; then
  pkill -HUP prometheus || systemctl reload prometheus || true
fi

echo "[OK] Registered ${HOST} (${IP}) in group ${GROUP}"
EOF
  chmod 0755 /usr/local/sbin/register-minion
}

# --- enroll script into the master VM --------------------------
install_wg_enroll_script(){
  install -d -m0755 /root
  cat >/root/wg_cluster_enroll.sh <<'EOWG'
#!/usr/bin/env bash
# wg_cluster_enroll.sh — master side, enroll all minions as peers on wg0..wg3
set -euo pipefail
IFACES="${IFACES:-0 1 2 3}"
DRY_RUN="${DRY_RUN:-0}"
LOG="/var/log/wg_cluster_enroll.log"
exec > >(tee -a "$LOG") 2>&1
msg(){ echo "[INFO] $(date '+%F %T') - $*"; }
warn(){ echo "[WARN] $(date '+%F %T') - $*" >&2; }
die(){ echo "[ERROR] $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing: $1"; }
need salt; need wg; need awk; need systemctl; need sed; need grep
get_minions(){ salt-key -L | awk '/Accepted Keys:/{f=1;next} /Denied Keys:|Rejected Keys:|Unaccepted Keys:/{f=0} f&&NF{print $1}' | sort -u; }
salt_cat(){ local m="$1" p="$2"; salt --out=newline_values_only -l quiet "$m" cmd.run "cat $p 2>/dev/null || true"; }
salt_eval(){ local m="$1" c="$2"; salt --out=newline_values_only -l quiet "$m" cmd.run "$c"; }
ensure_iface_up(){ ip link show "$1" >/dev/null 2>&1 || systemctl enable --now "wg-quick@$1" || true; }
ensure_peer_in_conf(){
  local ifn="$1" pub="$2" allowed="$3" conf="/etc/wireguard/${ifn}.conf"
  [[ -r "$conf" ]] || die "missing $conf"
  if grep -qF "$pub" "$conf"; then
    awk -v k="$pub" -v a="$allowed" '
      BEGIN{found=0; inpeer=0}
      /\[Peer\]/ {inpeer=1}
      inpeer && /^PublicKey[[:space:]]*=/ { pk=$0; sub(/^PublicKey[[:space:]]*=[[:space:]]*/,"",pk); if(pk==k){found=1} }
      found && /^AllowedIPs[[:space:]]*=/ { sub(/^AllowedIPs[[:space:]]*=.*/,"AllowedIPs = " a); found=0; print; next }
      {print}
    ' "$conf" > "${conf}.tmp" && mv "${conf}.tmp" "$conf"
  else
    {
      echo ""; echo "[Peer]"; echo "PublicKey  = $pub"; echo "AllowedIPs = $allowed"; echo "PersistentKeepalive = 25"
    } >> "$conf"; chmod 600 "$conf"
  fi
}
apply_conf_live(){ local ifn="$1" conf="/etc/wireguard/${ifn}.conf"; ip link show "$ifn" >/dev/null 2>&1 || systemctl enable --now "wg-quick@$ifn" || true; wg syncconf "$ifn" <(wg-quick strip "$conf") || true; }
msg "Enumerating minions"; readarray -t MINIONS < <(get_minions); [[ ${#MINIONS[@]} -gt 0 ]] || die "no accepted minions"
msg "Collecting pubkeys and desired /32s"
declare -A PEERS
for m in "${MINIONS[@]}"; do
  for i in $IFACES; do
    ifn="wg${i}"
    pub="$(salt_cat "$m" "/etc/wireguard/${ifn}.pub" | head -n1 | tr -d '\r')"; [[ -n "$pub" ]] || { warn "$m $ifn: missing pub"; continue; }
    want="$(salt_eval "$m" "awk -F= '/^WG${i}_WANTED=/{print \$2}' /etc/environment.d/99-provision.conf 2>/dev/null || awk '/^Address/{print \$3}' /etc/wireguard/${ifn}.conf 2>/dev/null | head -n1")"
    [[ -n "$want" ]] || { warn "$m $ifn: missing addr"; continue; }
    PEERS["${ifn}|${pub}"]="$want"; echo "  -> $m $ifn ${pub:0:8}… $want"
  done
done
for i in $IFACES; do [[ -r "/etc/wireguard/wg${i}.conf" ]] || die "missing /etc/wireguard/wg${i}.conf"; ensure_iface_up "wg${i}"; done
for k in "${!PEERS[@]}"; do ifn="${k%%|*}"; pub="${k##*|}"; allowed="${PEERS[$k]}"; ensure_peer_in_conf "$ifn" "$pub" "$allowed"; done
for i in $IFACES; do apply_conf_live "wg${i}"; done
for i in $IFACES; do echo "== $i =="; wg show "wg${i}" peers 2>/dev/null || true; done
EOWG
  chmod +x /root/wg_cluster_enroll.sh
}

# =============================================================================
# Prometheus Installer
# =============================================================================

telemetry_stack(){  # unchanged
  local wg1_ip; wg1_ip="$(ip -4 addr show dev wg1 | awk '/inet /{print $2}' | cut -d/ -f1)"
  [[ -n "$wg1_ip" ]] || wg1_ip="${WG1_IP%/*}"
  apt-get install -y prometheus prometheus-node-exporter grafana || true
  install -d -m755 /etc/prometheus/targets.d
  cat >/etc/prometheus/prometheus.yml <<'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 30s
scrape_configs:
  - job_name: 'node'
    file_sd_configs:
      - files:
        - /etc/prometheus/targets.d/*.json
EOF
  install -d -m755 /etc/systemd/system/prometheus.service.d
  cat >/etc/systemd/system/prometheus.service.d/override.conf <<EOF
[Service]
Environment=
ExecStart=
ExecStart=/usr/bin/prometheus --web.listen-address=${wg1_ip}:9090 --config.file=/etc/prometheus/prometheus.yml
EOF
  install -d -m755 /etc/systemd/system/prometheus-node-exporter.service.d
  cat >/etc/systemd/system/prometheus-node-exporter.service.d/override.conf <<EOF
[Service]
Environment=
ExecStart=
ExecStart=/usr/bin/prometheus-node-exporter --web.listen-address=${wg1_ip}:9100 --web.disable-exporter-metrics
EOF
  cat >/etc/systemd/system/prometheus.service.d/wg-order.conf <<'EOF'
[Unit]
After=wg-quick@wg1.service network-online.target
Wants=wg-quick@wg1.service network-online.target
EOF
  cat >/etc/systemd/system/prometheus-node-exporter.service.d/wg-order.conf <<'EOF'
[Unit]
After=wg-quick@wg1.service network-online.target
Wants=wg-quick@wg1.service network-online.target
EOF
  systemctl daemon-reload
  systemctl enable --now prometheus prometheus-node-exporter || true
  install -d /etc/grafana/provisioning/{datasources,dashboards}
  cat >/etc/grafana/provisioning/datasources/prom.yaml <<EOF
apiVersion: 1
datasources:
- name: Prometheus
  type: prometheus
  access: proxy
  url: http://${wg1_ip}:9090
  isDefault: true
EOF
  install -d -m755 /var/lib/grafana/dashboards/node
  cat >/etc/grafana/provisioning/dashboards/node.yaml <<'EOF'
apiVersion: 1
providers:
- name: node
  orgId: 1
  folder: "Node"
  type: file
  options:
    path: /var/lib/grafana/dashboards/node
EOF
  cat >/var/lib/grafana/dashboards/node/quick-node.json <<'EOF'
{"annotations":{"list":[{"builtIn":1,"datasource":{"type":"grafana","uid":"grafana"},"enable":true,"hide":true,"iconColor":"rgba(0, 211, 255, 1)","name":"Annotations & Alerts","type":"dashboard"}]},"editable":true,"graphTooltip":0,"panels":[{"type":"stat","title":"Up targets","datasource":"Prometheus","targets":[{"expr":"up"}]}],"schemaVersion":39,"style":"dark","time":{"from":"now-15m","to":"now"},"title":"Quick Node","version":1}
EOF
  systemctl enable --now grafana-server || true
}

control_stack(){  # unchanged
  apt-get install -y --no-install-recommends salt-master salt-api salt-common || true
  install -d -m0755 /etc/salt/master.d
  cat >/etc/salt/master.d/network.conf <<'EOF'
interface: 10.77.0.1
ipv6: False
publish_port: 4505
ret_port: 4506
EOF
  cat >/etc/salt/master.d/api.conf <<'EOF'
rest_cherrypy:
  host: 10.77.0.1
  port: 8000
  disable_ssl: True
EOF
  install -d -m0755 /etc/systemd/system/salt-master.service.d
  cat >/etc/systemd/system/salt-master.service.d/override.conf <<'EOF'
[Unit]
After=wg-quick@wg0.service network-online.target
Wants=wg-quick@wg0.service network-online.target
EOF
  systemctl daemon-reload
  systemctl enable --now salt-master salt-api || true

  if [ "${INSTALL_ANSIBLE}" = "yes" ]; then apt-get install -y ansible || true; fi

  if [ "${INSTALL_SEMAPHORE}" != "no" ]; then
    install -d -m755 /etc/semaphore
    if curl -fsSL -o /usr/local/bin/semaphore https://github.com/ansible-semaphore/semaphore/releases/latest/download/semaphore_linux_amd64 2>/dev/null; then
      chmod +x /usr/local/bin/semaphore
      cat >/etc/systemd/system/semaphore.service <<'EOF'
[Unit]
Description=Ansible Semaphore
After=wg-quick@wg0.service network-online.target
Wants=wg-quick@wg0.service
[Service]
ExecStart=/usr/local/bin/semaphore server --listen 10.77.0.1:3000
Restart=always
User=root
[Install]
WantedBy=multi-user.target
EOF
      systemctl daemon-reload; systemctl enable --now semaphore || true
    else
      echo "[WARN] Semaphore binary not fetched; install later." >&2
    fi
  fi
}

desktop_gui() {  # unchanged
  case "${GUI_PROFILE}" in
    rdp-minimal)
      apt-get install -y --no-install-recommends xorg xrdp xorgxrdp openbox xterm firefox-esr || true
      if [[ -f /etc/xrdp/xrdp.ini ]]; then
        sed -i 's/^\s*port\s*=.*/; &/' /etc/xrdp/xrdp.ini || true
        if grep -qE '^\s*address=' /etc/xrdp/xrdp.ini; then
          sed -i "s|^\s*address=.*|address=${MASTER_LAN}|" /etc/xrdp/xrdp.ini
        else
          sed -i "1i address=${MASTER_LAN}" /etc/xrdp/xrdp.ini
        fi
        if grep -qE '^\s*;port=' /etc/xrdp/xrdp.ini; then
          sed -i 's|^\s*;port=.*|port=3389|' /etc/xrdp/xrdp.ini
        elif grep -qE '^\s*port=' /etc/xrdp/xrdp.ini; then
          sed -i 's|^\s*port=.*|port=3389|' /etc/xrdp/xrdp.ini
        else
          sed -i '1i port=3389' /etc/xrdp/xrdp.ini
        fi
      fi
      cat >/etc/xrdp/startwm.sh <<'EOSH'
#!/bin/sh
export DESKTOP_SESSION=openbox
export XDG_SESSION_DESKTOP=openbox
export XDG_CURRENT_DESKTOP=openbox
[ -x /usr/bin/openbox-session ] && exec /usr/bin/openbox-session
[ -x /usr/bin/openbox ] && exec /usr/bin/openbox
exec /usr/bin/xterm
EOSH
      chmod +x /etc/xrdp/startwm.sh
      systemctl daemon-reload || true
      systemctl enable --now xrdp || true
      ;;
    wayland-gdm-minimal)
      apt-get install -y --no-install-recommends gdm3 gnome-shell gnome-session-bin firefox-esr || true
      systemctl enable --now gdm3 || true
      ;;
  esac
}

# -----------------------------------------------------------------------------
salt_master_stack() {
  log "Installing and configuring Salt master on LAN"

  install -d -m0755 /etc/apt/keyrings

  # Salt Broadcom repo
  curl -fsSL https://packages.broadcom.com/artifactory/api/security/keypair/SaltProjectKey/public \
    -o /etc/apt/keyrings/salt-archive-keyring.pgp || true
  chmod 0644 /etc/apt/keyrings/salt-archive-keyring.pgp || true
  gpg --dearmor </etc/apt/keyrings/salt-archive-keyring.pgp \
    >/etc/apt/keyrings/salt-archive-keyring.gpg 2>/dev/null || true
  chmod 0644 /etc/apt/keyrings/salt-archive-keyring.gpg || true

  cat >/etc/apt/sources.list.d/salt.sources <<'EOF'
Types: deb
URIs: https://packages.broadcom.com/artifactory/saltproject-deb
Suites: stable
Components: main
Signed-By: /etc/apt/keyrings/salt-archive-keyring.pgp
EOF

  cat >/etc/apt/preferences.d/salt-pin-1001 <<'EOF'
Package: salt-*
Pin: version 3006.*
Pin-Priority: 1001
EOF

  apt-get update -y || true
  apt-get install -y --no-install-recommends salt-master salt-api salt-common || true

  cat >/etc/salt/master.d/network.conf <<EOF
interface: ${MASTER_LAN}
ipv6: False
publish_port: 4505
ret_port: 4506
EOF

  # For now we keep salt-api without TLS to simplify; harden later.
  cat >/etc/salt/master.d/api.conf <<EOF
rest_cherrypy:
  host: ${MASTER_LAN}
  port: 8000
  disable_ssl: True
EOF

  cat >/etc/salt/master.d/bootstrap-autoaccept.conf <<'EOF'
auto_accept: True
EOF

  cat >/etc/salt/master.d/roots.conf <<'EOF'
file_roots:
  base:
    - /srv/salt

pillar_roots:
  base:
    - /srv/pillar
EOF

  install -d -m0755 /etc/systemd/system/salt-master.service.d
  cat >/etc/systemd/system/salt-master.service.d/wg-order.conf <<'EOF'
[Unit]
After=network-online.target
Wants=network-online.target
EOF

  systemctl daemon-reload
  systemctl enable --now salt-master salt-api || true
}

install_wg_refresh_tool() {
  log "Installing WireGuard plane refresh tool (wg-refresh-planes)"

  install -d -m0755 /usr/local/sbin
  install -d -m0755 /root/darksite || true

  cat >/usr/local/sbin/wg-refresh-planes <<'EOF_WG_REFRESH_PY'
#!/usr/bin/env python3
# Rebuild wg1/wg2/wg3 hub configs from minion state via Salt

import subprocess
import json
import shutil
import time
import os
from pathlib import Path

WG_DIR = Path("/etc/wireguard")
PLANES = ["wg1", "wg2", "wg3"]
SALT_TARGET = "*"          # adjust if you want a subset
SYSTEMD_UNIT_TEMPLATE = "wg-quick@{iface}.service"


def run(cmd, **kwargs):
    """Run a command and return stdout (text)."""
    kwargs.setdefault("text", True)
    kwargs.setdefault("check", True)
    return subprocess.run(cmd, stdout=subprocess.PIPE, **kwargs).stdout


def salt_cmd(target, shell_cmd):
    """
    Run a Salt cmd.run on all matching minions and return a dict:
        {minion_id: "output string"}

    We add --no-color and --static, and defensively extract the JSON
    payload between the first '{' and last '}' to avoid log noise.
    """
    out = run([
        "salt", target, "cmd.run", shell_cmd,
        "--out=json", "--static", "--no-color"
    ])
    out = out.strip()
    if not out:
        return {}

    # Strip anything before the first '{' and after the last '}'
    start = out.find("{")
    end = out.rfind("}")
    if start == -1 or end == -1 or end <= start:
        print(f"[WARN] Could not find JSON object in Salt output for cmd: {shell_cmd}")
        print(f"[WARN] Raw output was:\n{out}")
        return {}

    json_str = out[start:end + 1]

    try:
        return json.loads(json_str)
    except json.JSONDecodeError as e:
        print(f"[WARN] JSON decode failed for Salt output (cmd: {shell_cmd}): {e}")
        print(f"[WARN] Extracted JSON candidate was:\n{json_str}")
        return {}


def read_interface_block(conf_path):
    """
    Read only the [Interface] block from an existing wgX.conf,
    stopping at the first [Peer] (if any).
    Returns list of lines (without trailing newlines).
    """
    lines = []
    with open(conf_path, "r") as f:
        for line in f:
            if line.strip().startswith("[Peer]"):
                break
            lines.append(line.rstrip("\n"))
    return lines


def get_hub_ip(conf_path):
    """
    Parse the 'Address = 10.x.x.x/nn' line from the [Interface] section
    and return just the IP (no CIDR).
    """
    with open(conf_path, "r") as f:
        for line in f:
            stripped = line.strip()
            if stripped.startswith("Address"):
                # e.g. "Address    = 10.78.0.1/16"
                try:
                    _, rhs = stripped.split("=", 1)
                    addr = rhs.split("#", 1)[0].strip()
                    ip = addr.split("/", 1)[0].strip()
                    return ip
                except ValueError:
                    continue
    return None


def build_peers_for_plane(iface):
    """
    For a given interface (wg1, wg2, wg3):
      - ask all minions for IP on that interface
      - ask all minions for public key
    Returns list of dicts: {"minion": ..., "ip": ..., "pubkey": ...}
    """
    # Get IPv4 addr on that interface (one IP per minion)
    ip_cmd = f"ip -4 -o addr show dev {iface} 2>/dev/null | awk '{{print $4}}' | cut -d/ -f1"
    ips = salt_cmd(SALT_TARGET, ip_cmd)

    # Get public key for that interface
    pk_cmd = f"wg show {iface} public-key 2>/dev/null || true"
    pubkeys = salt_cmd(SALT_TARGET, pk_cmd)

    peers = []
    for minion, ip_out in sorted(ips.items()):
        ip = ip_out.strip()
        if not ip:
            continue  # no IP on this iface
        pubkey = pubkeys.get(minion, "").strip()
        if not pubkey:
            continue  # no public key
        peers.append({"minion": minion, "ip": ip, "pubkey": pubkey})
    return peers


def write_conf_for_plane(iface):
    conf_path = WG_DIR / f"{iface}.conf"
    if not conf_path.exists():
        print(f"[WARN] {conf_path} does not exist, skipping {iface}")
        return

    # Backup existing config
    ts = time.strftime("%Y%m%d%H%M%S")
    backup_path = conf_path.with_suffix(conf_path.suffix + f".bak.{ts}")
    shutil.copy2(conf_path, backup_path)
    print(f"[INFO] Backed up {conf_path} -> {backup_path}")

    # Read interface block and hub IP
    iface_lines = read_interface_block(conf_path)
    hub_ip = get_hub_ip(conf_path)
    if not hub_ip:
        print(f"[WARN] Could not determine hub IP from {conf_path}, continuing anyway")

    # Gather peers via Salt
    peers = build_peers_for_plane(iface)
    if not peers:
        print(f"[WARN] No peers found for {iface}, leaving only [Interface]")
    else:
        print(f"[INFO] Found {len(peers)} peers for {iface}")

    # Write new config
    new_path = conf_path.with_suffix(conf_path.suffix + ".new")
    with open(new_path, "w") as f:
        # [Interface] block
        for line in iface_lines:
            f.write(line + "\n")
        f.write("\n")

        # [Peer] blocks
        for peer in peers:
            ip = peer["ip"]
            # Skip adding self (hub) if it shows up in Salt results
            if hub_ip and ip == hub_ip:
                continue

            f.write("[Peer]\n")
            f.write(f"# {peer['minion']} ({iface})\n")
            f.write(f"PublicKey = {peer['pubkey']}\n")
            f.write(f"AllowedIPs = {ip}/32\n")
            # Uncomment if you want keepalive from clients back to hub
            # f.write("PersistentKeepalive = 25\n")
            f.write("\n")

    # Replace original with new
    os.replace(new_path, conf_path)
    print(f"[INFO] Updated {conf_path}")


def restart_plane(iface):
    unit = SYSTEMD_UNIT_TEMPLATE.format(iface=iface)
    print(f"[INFO] Restarting {unit}")
    try:
        run(["systemctl", "restart", unit])
    except subprocess.CalledProcessError as e:
        print(f"[ERROR] Failed to restart {unit}: {e}")


def main():
    for iface in PLANES:
        print(f"=== Processing {iface} ===")
        write_conf_for_plane(iface)
        restart_plane(iface)


if __name__ == "__main__":
    main()
EOF_WG_REFRESH_PY

  chmod 0755 /usr/local/sbin/wg-refresh-planes

  # Optional copy into darksite bundle for traceability
  cp -f /usr/local/sbin/wg-refresh-planes /root/darksite/wg-refresh-planes.py 2>/dev/null || true

  log "wg-refresh-planes installed (Python tool + darksite copy)"
}

ansible_stack() {
  if [ "${INSTALL_ANSIBLE}" != "yes" ]; then
    log "INSTALL_ANSIBLE != yes; skipping Ansible stack"
    return 0
  fi

  log "Installing Ansible and base config"
  apt-get install -y --no-install-recommends ansible || true

  install -d -m0755 /etc/ansible

  cat >/etc/ansible/ansible.cfg <<EOF
[defaults]
inventory = /etc/ansible/hosts
host_key_checking = False
forks = 50
timeout = 30
remote_user = ansible
# We'll use WireGuard plane (wg1) IPs for ansible_host where possible.
EOF

  touch /etc/ansible/hosts
}

semaphore_stack() {
  if [ "${INSTALL_SEMAPHORE}" = "no" ]; then
    log "INSTALL_SEMAPHORE=no; skipping Semaphore"
    return 0
  fi

  log "Installing Semaphore (Ansible UI) - best effort"

  local WG1_ADDR
  WG1_ADDR="$(echo "$WG1_IP" | cut -d/ -f1)"

  install -d -m755 /etc/semaphore

  if curl -fsSL -o /usr/local/bin/semaphore \
      https://github.com/ansible-semaphore/semaphore/releases/latest/download/semaphore_linux_amd64; then
    chmod +x /usr/local/bin/semaphore

    cat >/etc/systemd/system/semaphore.service <<EOF
[Unit]
Description=Ansible Semaphore
After=wg-quick@wg1.service network-online.target
Wants=wg-quick@wg1.service network-online.target

[Service]
ExecStart=/usr/local/bin/semaphore server --listen ${WG1_ADDR}:3000
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now semaphore || true
  else
    log "WARNING: Failed to fetch Semaphore binary; skipping UI."
  fi
}

hub_seed() {
  log "Seeding /srv/wg/hub.env with master WireGuard metadata"

  mkdir -p /srv/wg

  # Read master public keys (created in wg_setup_planes)
  local wg0_pub wg1_pub wg2_pub wg3_pub
  [ -r /etc/wireguard/wg0.pub ] && wg0_pub="$(cat /etc/wireguard/wg0.pub)" || wg0_pub=""
  [ -r /etc/wireguard/wg1.pub ] && wg1_pub="$(cat /etc/wireguard/wg1.pub)" || wg1_pub=""
  [ -r /etc/wireguard/wg2.pub ] && wg2_pub="$(cat /etc/wireguard/wg2.pub)" || wg2_pub=""
  [ -r /etc/wireguard/wg3.pub ] && wg3_pub="$(cat /etc/wireguard/wg3.pub)" || wg3_pub=""

  cat >/srv/wg/hub.env <<EOF
# Master WireGuard Hub metadata – AUTOGENERATED
HUB_NAME=${HUB_NAME}

# This is the IP that minions should use as endpoint for the hub:
HUB_LAN=${MASTER_LAN}
HUB_LAN_GW=10.100.10.1

# High-level WG plane nets
HUB_WG1_NET=10.78.0.0/16    # control/SSH plane
HUB_WG2_NET=10.79.0.0/16    # metrics/prom/graf plane
HUB_WG3_NET=10.80.0.0/16    # k8s/backplane

# Master interface addresses (same values as wg_setup_planes)
WG0_IP=${WG0_IP}
WG1_IP=${WG1_IP}
WG2_IP=${WG2_IP}
WG3_IP=${WG3_IP}

# Master listen ports
WG0_PORT=${WG0_PORT}
WG1_PORT=${WG1_PORT}
WG2_PORT=${WG2_PORT}
WG3_PORT=${WG3_PORT}

# Global allowed CIDR across planes
WG_ALLOWED_CIDR=${WG_ALLOWED_CIDR}

# Master public keys
WG0_PUB=${wg0_pub}
WG1_PUB=${wg1_pub}
WG2_PUB=${wg2_pub}
WG3_PUB=${wg3_pub}
EOF

  chmod 0644 /srv/wg/hub.env

  mkdir -p /srv/wg/peers
  cat >/srv/wg/README.md <<'EOF'
This directory holds WireGuard hub configuration and enrolled peers.

  * hub.env   – top-level metadata about this hub (IPs, ports, pubkeys)
  * peers/    – per-peer JSON/YAML/whatever we decide later

EOF
}

configure_salt_master_network() {
  echo "[*] Configuring Salt master bind addresses..."

  install -d -m 0755 /etc/salt/master.d

  cat >/etc/salt/master.d/network.conf <<'EOF'
# Bind Salt master on all IPv4 addresses so it’s reachable via:
#  - Public IP
#  - 10.100.x LAN
#  - 10.78.x WireGuard control plane
interface: 0.0.0.0
ipv6: False

# Standard Salt ports
publish_port: 4505
ret_port: 4506
EOF

  systemctl enable --now salt-master salt-api || true
}

configure_nftables_master() {
  echo "[*] Writing /etc/nftables.conf for master..."

  cat >/etc/nftables.conf <<'EOF'
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
  chain input {
    type filter hook input priority 0; policy drop;

    # Allow established/related
    ct state established,related accept

    # Loopback
    iifname "lo" accept

    # Basic ICMP
    ip protocol icmp accept
    ip6 nexthdr icmpv6 accept

    #################################################################
    # SSH (public, LAN, and over WireGuard)
    #################################################################
    tcp dport 22 accept

    #################################################################
    # Salt master (publisher 4505, return 4506)
    # Accessible via:
    #  - public IP
    #  - LAN (10.100.10.0/24)
    #  - WG control plane (10.78.0.0/16)
    #
    # If you want to tighten this later, you can add ip saddr filters.
    #################################################################
    tcp dport { 4505, 4506 } accept

    #################################################################
    # WireGuard UDP ports
    #################################################################
    udp dport { 51820, 51821, 51822, 51823 } accept

    #################################################################
    # Allow all traffic arriving from the WG planes
    # (wg0 = VPN, wg1 = control, wg2 = metrics, wg3 = backup, etc.)
    #################################################################
    iifname "wg0" accept
    iifname "wg1" accept
    iifname "wg2" accept
    iifname "wg3" accept

    #################################################################
    # Default-drop everything else
    #################################################################
  }

  chain forward {
    type filter hook forward priority 0; policy drop;

    # Allow forwarding between WG planes and LAN if desired.
    # You can refine this later with explicit rules.
    ct state established,related accept
  }

  chain output {
    type filter hook output priority 0; policy accept;
  }
}
EOF

  chmod 600 /etc/nftables.conf

  # Enable + apply
  systemctl enable nftables || true
  nft -f /etc/nftables.conf
}

# -----------------------------------------------------------------------------
write_bashrc() {
  log "Writing clean .bashrc for all users (via /etc/skel)..."

  local BASHRC=/etc/skel/.bashrc

  cat > "$BASHRC" <<'EOF'
# ~/.bashrc - foundryBot cluster console

# If not running interactively, don't do anything
[ -z "$PS1" ] && return

# =============================================================================
# History, shell options, basic prompt
# =============================================================================
HISTFILE=~/.bash_history
HISTSIZE=10000
HISTFILESIZE=20000
HISTTIMEFORMAT='%F %T '
HISTCONTROL=ignoredups:erasedups

shopt -s histappend
shopt -s checkwinsize
shopt -s cdspell

# Basic prompt (will be overridden below with colorized variant)
PS1='\u@\h:\w\$ '

# =============================================================================
# Banner
# =============================================================================

fb_banner() {
  cat << 'FBBANNER'

        ..                           ..                  ..
  < .z@8"`                     . uW8"                  dF
   !@88E           x.    .     `t888                  '88bu.
   '888E   u     .@88k  z88u    8888   .        .u    '*88888bu
    888E u@8NL  ~"8888 ^8888    9888.z88N    ud8888.    ^"*8888N
    888E`"88*"    8888  888R    9888  888E :888'8888.  beWE "888L
    888E .dN.     8888  888R    9888  888E d888 '88%"  888E  888E
    888E~8888     8888  888R    9888  888E 8888.+"     888E  888E
    888E '888&    8888 ,888B .  9888  888E 8888L       888E  888F
    888E  9888.  "8888Y 8888"  .8888  888" '8888c. .+ .888N..888
  '"888*" 4888"   `Y"   'YP     `%888*%"    "88888%    `"888*""
     ""    ""                      "`         "YP'        "" os
                secure · platfourms -> everywhere

FBBANNER
}

# Only show once per interactive session
if [ -z "$FBNOBANNER" ]; then
  fb_banner
  export FBNOBANNER=1
fi

# =============================================================================
# Colorized prompt (root vs non-root)
# =============================================================================

if [ "$EUID" -eq 0 ]; then
  PS1='\[\e[1;31m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ '
else
  PS1='\[\e[1;32m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ '
fi

# =============================================================================
# Bash completion
# =============================================================================

if [ -f /etc/bash_completion ]; then
  # shellcheck source=/etc/bash_completion
  . /etc/bash_completion
fi

# =============================================================================
# Basic quality-of-life aliases
# =============================================================================

alias cp='cp -i'
alias mv='mv -i'
alias rm='rm -i'

alias ls='ls --color=auto'
alias ll='ls -alF --color=auto'
alias la='ls -A --color=auto'
alias l='ls -CF --color=auto'
alias grep='grep --color=auto'
alias e='${EDITOR:-vim}'
alias vi='vim'

# Net & disk helpers
alias ports='ss -tuln'
alias df='df -h'
alias du='du -h'
alias tk='tmux kill-server'

# =============================================================================
# Salt cluster helper commands
# =============================================================================

# Wide minion list as a table
slist() {
  salt --static --no-color --out=json --out-indent=-1 "*" \
    grains.item host os osrelease ipv4 num_cpus mem_total roles \
  | jq -r '
      to_entries[]
      | .key as $id
      | .value as $v
      | ($v.ipv4 // []
         | map(select(. != "127.0.0.1" and . != "0.0.0.0"))
         | join("  ")) as $ips
      | [
          $id,
          $v.host,
          ($v.os + " " + $v.osrelease),
          $ips,
          $v.num_cpus,
          $v.mem_total,
          ($v.roles // "")
        ]
      | @tsv
    ' \
  | sort -k1,1
}

sping()      { salt "*" test.ping; }
ssall()      { salt "*" cmd.run 'ss -tnlp || netstat -tnlp'; }
skservices() { salt "*" service.status kubelet containerd; }
sdfall()     { salt "*" cmd.run 'df -hT --exclude-type=tmpfs --exclude-type=devtmpfs'; }
stop5()      { salt "*" cmd.run 'ps aux --sort=-%cpu | head -n 5'; }
smem5()      { salt "*" cmd.run 'ps aux --sort=-%mem | head -n 5'; }

skvers() {
  echo "== kubelet versions =="
  salt "*" cmd.run 'kubelet --version 2>/dev/null || echo no-kubelet'
  echo
  echo "== kubectl client versions =="
  salt "*" cmd.run 'kubectl version --client --short 2>/dev/null || echo no-kubectl'
}

# "World" apply helpers – tweak state names to your liking
fb_world() {
  echo "Applying 'world' state to all minions..."
  salt "*" state.apply world
}

fb_k8s_cluster() {
  echo "Applying 'k8s.cluster' to role:k8s_cp and role:k8s_worker..."
  salt -C 'G@role:k8s_cp or G@role:k8s_worker' state.apply k8s.cluster
}

# =============================================================================
# Kubernetes helper commands (Salt-powered via role:k8s_cp)
# =============================================================================

# Core cluster info
skcls()   { salt -G "role:k8s_cp" cmd.run 'kubectl cluster-info'; }
sknodes() { salt -G "role:k8s_cp" cmd.run 'kubectl get nodes -o wide'; }
skpods()  { salt -G "role:k8s_cp" cmd.run 'kubectl get pods -A -o wide'; }
sksys()   { salt -G "role:k8s_cp" cmd.run 'kubectl get pods -n kube-system -o wide'; }
sksvc()   { salt -G "role:k8s_cp" cmd.run 'kubectl get svc -A -o wide'; }
sking()   { salt -G "role:k8s_cp" cmd.run 'kubectl get ingress -A -o wide'; }
skapi()   { salt -G "role:k8s_cp" cmd.run 'kubectl api-resources | column -t'; }

# Health & metrics
skready() {
  salt -G "role:k8s_cp" cmd.run \
    'kubectl get nodes -o json | jq -r ".items[] | [.metadata.name, (.status.conditions[] | select(.type==\"Ready\").status)] | @tsv"'
}

sktop() {
  salt -G "role:k8s_cp" cmd.run \
    'kubectl top nodes 2>/dev/null || echo metrics-server-not-installed'
}

sktopp() {
  salt -G "role:k8s_cp" cmd.run \
    'kubectl top pods -A --use-protocol-buffers 2>/dev/null || echo metrics-server-not-installed'
}

skevents() {
  salt -G "role:k8s_cp" cmd.run \
    'kubectl get events -A --sort-by=.lastTimestamp | tail -n 40'
}

skdescribe() {
  if [ -z "$1" ]; then
    echo "Usage: skdescribe <pod> [namespace]"
    return 1
  fi
  local pod="$1"
  local ns="${2:-default}"
  salt -G "role:k8s_cp" cmd.run "kubectl describe pod $pod -n $ns"
}

# Workload inventory
skdeploy() { salt -G "role:k8s_cp" cmd.run 'kubectl get deploy -A -o wide'; }
skrs()     { salt -G "role:k8s_cp" cmd.run 'kubectl get rs -A -o wide'; }
sksts()    { salt -G "role:k8s_cp" cmd.run 'kubectl get statefulset -A -o wide'; }
skdaemon() { salt -G "role:k8s_cp" cmd.run 'kubectl get daemonset -A -o wide'; }

# Labels & annotations
sklabel() {
  if [ $# -lt 2 ]; then
    echo "Usage: sklabel <key>=<value> <pod> [namespace]"
    return 1
  fi
  local kv="$1"
  local pod="$2"
  local ns="${3:-default}"
  salt -G "role:k8s_cp" cmd.run "kubectl label pod $pod -n $ns $kv --overwrite"
}

skannot() {
  if [ $# -lt 2 ]; then
    echo "Usage: skannot <key>=<value> <pod> [namespace]"
    return 1
  fi
  local kv="$1"
  local pod="$2"
  local ns="${3:-default}"
  salt -G "role:k8s_cp" cmd.run "kubectl annotate pod $pod -n $ns $kv --overwrite"
}

# Networking
sknetpol() {
  salt -G "role:k8s_cp" cmd.run 'kubectl get networkpolicies -A -o wide'
}

skcni() {
  salt -G "role:k8s_cp" cmd.run \
    'kubectl get pods -n kube-flannel -o wide 2>/dev/null || kubectl get pods -n kube-system | grep -i cni'
}

sksvcips() {
  salt -G "role:k8s_cp" cmd.run \
    'kubectl get svc -A -o json | jq -r ".items[]|[.metadata.namespace,.metadata.name,.spec.clusterIP]|@tsv"'
}

skdns() {
  salt -G "role:k8s_cp" cmd.run \
    'kubectl get pods -n kube-system -l k8s-app=kube-dns -o wide 2>/dev/null || kubectl get pods -n kube-system | grep -i coredns'
}

# Logs
sklog() {
  if [ -z "$1" ]; then
    echo "Usage: sklog <pod> [namespace]"
    return 1
  fi
  local pod="$1"
  local ns="${2:-default}"
  salt -G "role:k8s_cp" cmd.run "kubectl logs $pod -n $ns --tail=200"
}

sklogf() {
  if [ -z "$1" ]; then
    echo "Usage: sklogf <pod> [namespace]"
    return 1
  fi
  local pod="$1"
  local ns="${2:-default}"
  salt -G "role:k8s_cp" cmd.run "kubectl logs $pod -n $ns -f"
}

sklogs_ns() {
  local ns="${1:-default}"
  salt -G "role:k8s_cp" cmd.run \
    "kubectl get pods -n $ns -o json \
      | jq -r '.items[].metadata.name' \
      | xargs -I {} kubectl logs {} -n $ns --tail=40"
}

# Container runtime & node diag
skcri()   { salt -G "role:k8s_cp" cmd.run 'crictl ps -a 2>/dev/null || echo no-cri-tools'; }
skdmesg() { salt "*" cmd.run 'dmesg | tail -n 25'; }
skoom()   { salt "*" cmd.run 'journalctl -k -g OOM -n 20 --no-pager'; }

# Rollouts & node lifecycle
skroll() {
  if [ -z "$1" ]; then
    echo "Usage: skroll <deployment> [namespace]"
    return 1
  fi
  local deploy="$1"
  local ns="${2:-default}"
  salt -G "role:k8s_cp" cmd.run "kubectl rollout restart deploy/$deploy -n $ns"
}

skundo() {
  if [ -z "$1" ]; then
    echo "Usage: skundo <deployment> [namespace]"
    return 1
  fi
  local deploy="$1"
  local ns="${2:-default}"
  salt -G "role:k8s_cp" cmd.run "kubectl rollout undo deploy/$deploy -n $ns"
}

skdrain() {
  if [ -z "$1" ]; then
    echo "Usage: skdrain <node>"
    return 1
  fi
  local node="$1"
  salt -G "role:k8s_cp" cmd.run "kubectl drain $node --ignore-daemonsets --force --delete-emptydir-data"
}

skuncordon() {
  if [ -z "$1" ]; then
    echo "Usage: skuncordon <node>"
    return 1
  fi
  local node="$1"
  salt -G "role:k8s_cp" cmd.run "kubectl uncordon $node"
}

skcordon() {
  if [ -z "$1" ]; then
    echo "Usage: skcordon <node>"
    return 1
  fi
  local node="$1"
  salt -G "role:k8s_cp" cmd.run "kubectl cordon $node"
}

# Security / certs / RBAC
skrbac() {
  salt -G "role:k8s_cp" cmd.run 'kubectl get roles,rolebindings -A -o wide'
}

sksa() {
  salt -G "role:k8s_cp" cmd.run 'kubectl get sa -A -o wide'
}

skcerts() {
  salt -G "role:k8s_cp" cmd.run \
    'for i in /etc/kubernetes/pki/*.crt; do echo "== $(basename "$i") =="; openssl x509 -in "$i" -text -noout | head -n 10; echo; done'
}

# Show-offs
skpodsmap() {
  salt -G "role:k8s_cp" cmd.run \
    'kubectl get pods -A -o json | jq -r ".items[] | [.metadata.namespace,.metadata.name,.status.podIP,(.spec.containers|length),.spec.nodeName] | @tsv"'
}

sktopcpu() {
  salt -G "role:k8s_cp" cmd.run \
    'kubectl top pod -A 2>/dev/null | sort -k3 -r | head -n 15'
}

# =============================================================================
# Helper: print cheat sheet of all the good stuff
# =============================================================================

shl() {
  printf "%s\n" \
"Salt / cluster helper commands:" \
"  slist         - List all minions in a wide table (id, host, OS, IPs, CPU, RAM, roles)." \
"  sping         - Ping all minions via Salt (test.ping)." \
"  ssall         - Show listening TCP sockets on all minions (ss/netstat)." \
"  skservices    - Check kubelet and containerd service status on all minions." \
"  skvers        - Show kubelet and kubectl versions on all minions." \
"  sdfall        - Show disk usage (df -hT, no tmpfs/devtmpfs) on all minions." \
"  stop5         - Top 5 CPU-hungry processes on each minion." \
"  smem5         - Top 5 memory-hungry processes on each minion." \
"  fb_world      - Apply top-level 'world' Salt state to all minions." \
"  fb_k8s_cluster- Apply 'k8s.cluster' state to CP + workers." \
"" \
"Kubernetes cluster helpers (via role:k8s_cp):" \
"  skcls         - Show cluster-info." \
"  sknodes       - List nodes (wide)." \
"  skpods        - List all pods (all namespaces, wide)." \
"  sksys         - Show kube-system pods." \
"  sksvc         - List all services." \
"  sking         - List all ingresses." \
"  skapi         - Show API resources." \
"  skready       - Show node Ready status." \
"  sktop         - Node CPU/mem usage (if metrics-server installed)." \
"  sktopp        - Pod CPU/mem usage (if metrics-server installed)." \
"  skevents      - Tail the last cluster events." \
"  skdeploy      - List deployments (all namespaces)." \
"  sksts         - List StatefulSets." \
"  skdaemon      - List DaemonSets." \
"  sknetpol      - List NetworkPolicies." \
"  sksvcips      - Map svc -> ClusterIP." \
"  skdns         - Show cluster DNS pods." \
"  sklog         - Show logs for a pod: sklog <pod> [ns]." \
"  sklogf        - Follow logs for a pod: sklogf <pod> [ns]." \
"  sklogs_ns     - Tail logs for all pods in a namespace." \
"  skroll        - Restart a deployment: skroll <deploy> [ns]." \
"  skundo        - Rollback a deployment: skundo <deploy> [ns]." \
"  skdrain       - Drain a node." \
"  skcordon      - Cordon a node." \
"  skuncordon    - Uncordon a node." \
"  skrbac        - List Roles and RoleBindings." \
"  sksa          - List ServiceAccounts." \
"  skcerts       - Dump brief info about control-plane certs." \
"  skpodsmap     - Pretty map of pods (ns, name, IP, containers, node)." \
"  sktopcpu      - Top 15 CPU-hungry pods." \
"" \
"Other:" \
"  cp/mv/rm      - Interactive (prompt before overwrite/delete)." \
"  ll/la/l       - ls variants." \
"  e, vi         - Open \$EDITOR (vim by default)." \
""
}

# =============================================================================
# Auto-activate BCC virtualenv (if present)
# =============================================================================

VENV_DIR="/root/bccenv"
if [ -d "$VENV_DIR" ] && [ -n "$PS1" ]; then
  if [ -z "$VIRTUAL_ENV" ] || [ "$VIRTUAL_ENV" != "$VENV_DIR" ]; then
    # shellcheck source=/dev/null
    source "$VENV_DIR/bin/activate"
  fi
fi

# =============================================================================
# Friendly login line
# =============================================================================

echo "Welcome $USER — connected to $(hostname) on $(date)"
echo "Type 'shl' for the foundryBot helper command list."
EOF
}

# =============================================================================
#  Write Tmux config
# =============================================================================

write_tmux_conf() {
  log "Writing tmux.conf to /etc/skel and root"
  apt-get install -y tmux

  local TMUX_CONF="/etc/skel/.tmux.conf"

  cat > "$TMUX_CONF" <<'EOF'
# ~/.tmux.conf — Airline-style theme
set -g mouse on
setw -g mode-keys vi
set -g history-limit 10000
set -g default-terminal "screen-256color"
set-option -ga terminal-overrides ",xterm-256color:Tc"
set-option -g status on
set-option -g status-interval 5
set-option -g status-justify centre
set-option -g status-bg colour236
set-option -g status-fg colour250
set-option -g status-style bold
set-option -g status-left-length 60
set-option -g status-left "#[fg=colour0,bg=colour83] #S #[fg=colour83,bg=colour55,nobold,nounderscore,noitalics]"
set-option -g status-right-length 120
set-option -g status-right "#[fg=colour55,bg=colour236]#[fg=colour250,bg=colour55] %Y-%m-%d  %H:%M #[fg=colour236,bg=colour55]#[fg=colour0,bg=colour236] #H "
set-window-option -g window-status-current-style "fg=colour0,bg=colour83,bold"
set-window-option -g window-status-current-format " #I:#W "
set-window-option -g window-status-style "fg=colour250,bg=colour236"
set-window-option -g window-status-format " #I:#W "
set-option -g pane-border-style "fg=colour238"
set-option -g pane-active-border-style "fg=colour83"
set-option -g message-style "bg=colour55,fg=colour250"
set-option -g message-command-style "bg=colour55,fg=colour250"
set-window-option -g bell-action none
bind | split-window -h
bind - split-window -v
unbind '"'
unbind %
bind r source-file ~/.tmux.conf \; display-message "Reloaded!"
bind-key -T copy-mode-vi 'v' send -X begin-selection
bind-key -T copy-mode-vi 'y' send -X copy-selection-and-cancel
EOF

  log ".tmux.conf written to /etc/skel/.tmux.conf"

  # Also set for root:
  cp "$TMUX_CONF" /root/.tmux.conf
  log ".tmux.conf copied to /root/.tmux.conf"
}

# Backwards-compat wrapper (if anything else ever calls this name)
seed_tmux_conf() {
  write_tmux_conf
}

# =============================================================================
# Write Vim config
# =============================================================================

setup_vim_config() {
  log "Writing standard Vim config..."
  apt-get install -y \
    vim \
    git \
    vim-airline \
    vim-airline-themes \
    vim-ctrlp \
    vim-fugitive \
    vim-gitgutter \
    vim-tabular

  local VIMRC=/etc/skel/.vimrc
  mkdir -p /etc/skel/.vim/autoload/airline/themes

  cat > "$VIMRC" <<'EOF'
syntax on
filetype plugin indent on
set nocompatible
set tabstop=2 shiftwidth=2 expandtab
set autoindent smartindent
set background=dark
set ruler
set showcmd
set cursorline
set wildmenu
set incsearch
set hlsearch
set laststatus=2
set clipboard=unnamedplus
set showmatch
set backspace=indent,eol,start
set ignorecase
set smartcase
set scrolloff=5
set wildmode=longest,list,full
set splitbelow
set splitright
highlight ColorColumn ctermbg=darkgrey guibg=grey
highlight ExtraWhitespace ctermbg=red guibg=red
match ExtraWhitespace /\s\+$/
let g:airline_powerline_fonts = 1
let g:airline_theme = 'custom'
let g:airline#extensions#tabline#enabled = 1
let g:airline_section_z = '%l:%c'
let g:ctrlp_map = '<c-p>'
let g:ctrlp_cmd = 'CtrlP'
nmap <leader>gs :Gstatus<CR>
nmap <leader>gd :Gdiff<CR>
nmap <leader>gc :Gcommit<CR>
nmap <leader>gb :Gblame<CR>
let g:gitgutter_enabled = 1
autocmd FileType python,yaml setlocal tabstop=2 shiftwidth=2 expandtab
autocmd FileType javascript,typescript,json setlocal tabstop=2 shiftwidth=2 expandtab
autocmd FileType sh,bash,zsh setlocal tabstop=2 shiftwidth=2 expandtab
nnoremap <leader>w :w<CR>
nnoremap <leader>q :q<CR>
nnoremap <leader>tw :%s/\s\+$//e<CR>
if &term =~ 'xterm'
  let &t_SI = "\e[6 q"
  let &t_EI = "\e[2 q"
endif
EOF

  chmod 644 /etc/skel/.vimrc
  cat > /etc/skel/.vim/autoload/airline/themes/custom.vim <<'EOF'
let g:airline#themes#custom#palette = {}
let s:N1 = [ '#000000' , '#00ff5f' , 0 , 83 ]
let s:N2 = [ '#ffffff' , '#5f00af' , 255 , 55 ]
let s:N3 = [ '#ffffff' , '#303030' , 255 , 236 ]
let s:I1 = [ '#000000' , '#5fd7ff' , 0 , 81 ]
let s:I2 = [ '#ffffff' , '#5f00d7' , 255 , 56 ]
let s:I3 = [ '#ffffff' , '#303030' , 255 , 236 ]
let s:V1 = [ '#000000' , '#af5fff' , 0 , 135 ]
let s:V2 = [ '#ffffff' , '#8700af' , 255 , 91 ]
let s:V3 = [ '#ffffff' , '#303030' , 255 , 236 ]
let s:R1 = [ '#000000' , '#ff5f00' , 0 , 202 ]
let s:R2 = [ '#ffffff' , '#d75f00' , 255 , 166 ]
let s:R3 = [ '#ffffff' , '#303030' , 255 , 236 ]
let s:IA = [ '#aaaaaa' , '#1c1c1c' , 250 , 234 ]
let g:airline#themes#custom#palette.normal = airline#themes#generate_color_map(s:N1, s:N2, s:N3)
let g:airline#themes#custom#palette.insert = airline#themes#generate_color_map(s:I1, s:I2, s:I3)
let g:airline#themes#custom#palette.visual = airline#themes#generate_color_map(s:V1, s:V2, s:V3)
let g:airline#themes#custom#palette.replace = airline#themes#generate_color_map(s:R1, s:R2, s:R3)
let g:airline#themes#custom#palette.inactive = airline#themes#generate_color_map(s:IA, s:IA, s:IA)
EOF

  mkdir -p /root/.vim/autoload/airline/themes
  cp /etc/skel/.vimrc /root/.vimrc
  chmod 644 /root/.vimrc
  cp /etc/skel/.vim/autoload/airline/themes/custom.vim /root/.vim/autoload/airline/themes/custom.vim
  chmod 644 /root/.vim/autoload/airline/themes/custom.vim
}

# =============================================================================
# Setup Python environment for BCC scripts
# =============================================================================

setup_python_env() {
  log "Setting up Python for BCC scripts..."

  # System packages only — no pip bcc!
  apt-get install -y python3-psutil python3-bpfcc

  # Create a virtualenv that sees system site-packages
  local VENV_DIR="/root/bccenv"
  python3 -m venv --system-site-packages "$VENV_DIR"

  source "$VENV_DIR/bin/activate"
  pip install --upgrade pip wheel setuptools
  pip install cryptography pyOpenSSL numba pytest
  deactivate

  log "System Python has psutil + bpfcc. Venv created at $VENV_DIR with system site-packages."

  # Auto-activate for root
  local ROOT_BASHRC="/root/.bashrc"
  if ! grep -q "$VENV_DIR" "$ROOT_BASHRC" 2>/dev/null; then
    {
      echo ""
      echo "# Auto-activate BCC virtualenv"
      echo "source \"$VENV_DIR/bin/activate\""
    } >> "$ROOT_BASHRC"
  fi

  # Auto-activate for future users
  local SKEL_BASHRC="/etc/skel/.bashrc"
  if ! grep -q "$VENV_DIR" "$SKEL_BASHRC" 2>/dev/null; then
    {
      echo ""
      echo "# Auto-activate BCC virtualenv if available"
      echo "[ -d \"$VENV_DIR\" ] && source \"$VENV_DIR/bin/activate\""
    } >> "$SKEL_BASHRC"
  fi

  log "Virtualenv activation added to root and skel .bashrc"
}

# =============================================================================
# Sync /etc/skel configs to existing users
# =============================================================================

sync_skel_to_existing_users() {
  log "Syncing skel configs to existing users (root + baked)..."

  local files=".bashrc .vimrc .tmux.conf"
  local homes="/root"
  homes+=" $(find /home -mindepth 1 -maxdepth 1 -type d 2>/dev/null || true)"

  for home in $homes; do
    for f in $files; do
      if [ -f "/etc/skel/$f" ]; then
        cp -f "/etc/skel/$f" "$home/$f"
      fi
    done
  done
}

  log "Seeding finish-cluster script and systemd unit on Salt master"

# =============================================================================
# Postinstall: copy darksite to /srv and run apply.py
# =============================================================================

post_darksite_to_srv_and_apply() {
  set -euo pipefail

  local src_root="/root/darksite"
  local src_ansible="${src_root}/ansible"
  local dst_root="/srv"
  local dst_ansible="${dst_root}/ansible"
  local dst_darksite="${dst_root}/darksite"

  log "Postinstall: staging Ansible + darksite helpers into /srv"

  [[ -d "$src_root" ]] || die "Missing $src_root (preseed copy likely failed)"

  # Ensure /srv exists
  install -d -m 0755 "$dst_root"
  install -d -m 0755 "$dst_ansible"
  install -d -m 0755 "$dst_darksite"

  # Prefer rsync if present (preserves perms, deletes stale files)
  if command -v rsync >/dev/null 2>&1; then
    if [[ -d "$src_ansible" ]]; then
      log "Staging ansible payload via rsync: $src_ansible -> $dst_ansible"
      rsync -aHAX --delete "${src_ansible}/" "${dst_ansible}/"
    else
      warn "No $src_ansible found; skipping ansible stage"
    fi
  else
    # Fallback to cp (no rsync in minimal installs)
    if [[ -d "$src_ansible" ]]; then
      log "Staging ansible payload via cp: $src_ansible -> $dst_ansible"
      rm -rf "$dst_ansible"
      install -d -m 0755 "$dst_ansible"
      cp -a "${src_ansible}/." "${dst_ansible}/"
    else
      warn "No $src_ansible found; skipping ansible stage"
    fi
  fi

  # Stage darksite helper scripts into /srv/darksite
  log "Staging darksite helper scripts -> $dst_darksite"
  install -m 0555 "$src_root/apply.py" "$dst_darksite/apply.py" 2>/dev/null || true
  install -m 0555 "$src_root/wg-refresh-planes.py" "$dst_darksite/wg-refresh-planes.py" 2>/dev/null || true

  log "Postinstall: /srv staging complete"
}

# =============================================================================
# Main
# =============================================================================

main_master() {
  log "BEGIN postinstall (master control hub)"

  ensure_base
  ensure_users
  wg_setup_planes
  nft_firewall
  hub_seed
  helper_tools
  salt_master_stack
  telemetry_stack
  control_stack
  desktop_gui
  install_wg_refresh_tool
  ansible_stack
  semaphore_stack
  configure_salt_master_network
  configure_nftables_master
  write_bashrc
  write_tmux_conf
  setup_vim_config
  setup_python_env
  sync_skel_to_existing_users
  post_darksite_to_srv_and_apply

  # Clean up unnecessary services
  systemctl disable --now openipmi.service 2>/dev/null || true
  systemctl mask openipmi.service 2>/dev/null || true

  log "Master hub ready."

  # Mark bootstrap as done for this VM
  touch /root/.bootstrap_done
  sync || true

  # Disable bootstrap.service so it won't be wanted on next boot
  systemctl disable bootstrap.service 2>/dev/null || true
  systemctl daemon-reload || true

  log "Powering off in 2s..."
  (sleep 2; systemctl --no-block poweroff) & disown
}

main_master
EOS
}

# =============================================================================
# MINION POSTINSTALL
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

# ---------------------------------------------------------------------------
# Import environment seeded by mk_iso / wrapper
# ---------------------------------------------------------------------------
if [ -r /etc/environment.d/99-provision.conf ]; then
  # shellcheck disable=SC2046
  export $(grep -E '^[A-Z0-9_]+=' /etc/environment.d/99-provision.conf | xargs -d'\n' || true)
fi

ADMIN_USER="${ADMIN_USER:-todd}"
ALLOW_ADMIN_PASSWORD="${ALLOW_ADMIN_PASSWORD:-no}"
MY_GROUP="${MY_GROUP:-prom}"

# Per-minion WireGuard IPs (seeded by wrapper / mk_iso)
WG0_WANTED="${WG0_WANTED:-10.77.0.2/32}"  # reserved plane
WG1_WANTED="${WG1_WANTED:-10.78.0.2/32}"  # control / SSH / Salt
WG2_WANTED="${WG2_WANTED:-10.79.0.2/32}"  # metrics plane
WG3_WANTED="${WG3_WANTED:-10.80.0.2/32}"  # k8s side/backplane

# Where hub.env might live (wrapper or manual copy)
HUB_ENV_CANDIDATES=(
  "/root/darksite/cluster-seed/hub.env"
  "/root/cluster-seed/hub.env"
  "/srv/wg/hub.env"
)

# =============================================================================
# BASE OS
# =============================================================================

ensure_base() {
  log "Configuring APT & base OS packages"
  export DEBIAN_FRONTEND=noninteractive

  cat >/etc/apt/sources.list <<'EOF'
deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware
EOF

  for i in 1 2 3; do
    if apt-get update -y; then break; fi
    sleep $((i*3))
  done

  apt-get install -y --no-install-recommends \
    sudo openssh-server curl wget ca-certificates gnupg jq xxd unzip tar \
    iproute2 iputils-ping ethtool tcpdump net-tools \
    nftables wireguard-tools rsync \
    chrony rsyslog qemu-guest-agent vim \
    prometheus-node-exporter || true

  echo wireguard >/etc/modules-load.d/wireguard.conf || true
  modprobe wireguard 2>/dev/null || true

  systemctl enable --now ssh chrony rsyslog qemu-guest-agent || true

  cat >/etc/sysctl.d/99-minion.conf <<'EOF'
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
EOF
  sysctl --system || true
}

# =============================================================================
# ADMIN USER + SSH
# =============================================================================

ensure_admin_user() {
  log "Ensuring admin user ${ADMIN_USER}"

  local SEED="/root/darksite/authorized_keys.${ADMIN_USER}"
  local PUB=""; [ -s "$SEED" ] && PUB="$(head -n1 "$SEED")"

  if ! id -u "${ADMIN_USER}" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "${ADMIN_USER}"
  fi

  install -d -m700 -o "${ADMIN_USER}" -g "${ADMIN_USER}" "/home/${ADMIN_USER}/.ssh"
  touch "/home/${ADMIN_USER}/.ssh/authorized_keys"
  chmod 600 "/home/${ADMIN_USER}/.ssh/authorized_keys"
  chown -R "${ADMIN_USER}:${ADMIN_USER}" "/home/${ADMIN_USER}/.ssh"

  if [ -n "$PUB" ] && ! grep -qxF "$PUB" "/home/${ADMIN_USER}/.ssh/authorized_keys"; then
    echo "$PUB" >> "/home/${ADMIN_USER}/.ssh/authorized_keys"
  fi

  install -d -m755 /etc/sudoers.d
  printf '%s ALL=(ALL) NOPASSWD:ALL\n' "${ADMIN_USER}" >"/etc/sudoers.d/90-${ADMIN_USER}"
  chmod 0440 "/etc/sudoers.d/90-${ADMIN_USER}"
}

# =============================================================================
# SSH HARDENING
# =============================================================================

install_enroll_key() {
  log "Installing cluster enrollment SSH key (for auto-enroll & registration)"

  local SRC_PRIV="/root/darksite/enroll_ed25519"
  local SRC_PUB="/root/darksite/enroll_ed25519.pub"
  local DST_DIR="/root/.ssh"
  local DST_PRIV="${DST_DIR}/enroll_ed25519"
  local DST_PUB="${DST_DIR}/enroll_ed25519.pub"

  if [[ ! -r "$SRC_PRIV" || ! -r "$SRC_PUB" ]]; then
    log "No enroll_ed25519 keypair found in /root/darksite; skipping install"
    return 0
  fi

  install -d -m700 "$DST_DIR"
  install -m600 "$SRC_PRIV" "$DST_PRIV"
  install -m644 "$SRC_PUB" "$DST_PUB"
}

ssh_hardening_static() {
  log "Applying static SSH hardening"

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

  if [ "${ALLOW_ADMIN_PASSWORD}" = "yes" ]; then
    cat >/etc/ssh/sshd_config.d/10-admin-lan-password.conf <<EOF
Match User ${ADMIN_USER} Address 10.100.10.0/24
    PasswordAuthentication yes
EOF
  fi

  install -d -m755 /etc/systemd/system/ssh.service.d
  cat >/etc/systemd/system/ssh.service.d/wg-order.conf <<'EOF'
[Unit]
After=wg-quick@wg1.service wg-quick@wg2.service wg-quick@wg3.service network-online.target
Wants=wg-quick@wg1.service network-online.target
EOF

  if sshd -t; then
    systemctl daemon-reload
    systemctl restart ssh || true
  else
    log "WARNING: sshd config test failed (pre-WG); will retry after WG1 setup"
  fi
}

ssh_bind_lan_and_wg1() {
  log "Configuring SSH ListenAddress for LAN + wg1"

  local LAN_IP WG1_ADDR
  LAN_IP="$(ip -4 addr show scope global | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1)"
  WG1_ADDR="$(echo "${WG1_WANTED}" | cut -d/ -f1)"

  if [ -z "$LAN_IP" ]; then
    log "WARNING: could not detect LAN IP; leaving ListenAddress unchanged"
    return 0
  fi

  cat >/etc/ssh/sshd_config.d/00-listen.conf <<EOF
ListenAddress ${LAN_IP}
ListenAddress ${WG1_ADDR}
EOF

  if sshd -t; then
    systemctl daemon-reload
    systemctl restart ssh || true
  else
    log "WARNING: sshd config test failed; keeping previous sshd config"
  fi
}

# =============================================================================
# HUB METADATA (hub.env)
# =============================================================================

read_hub() {
  log "Searching for hub.env"

  local f
  for f in "${HUB_ENV_CANDIDATES[@]}"; do
    if [ -r "$f" ]; then
      log "Loading hub env from $f"
      # shellcheck disable=SC1090
      . "$f"
      break
    fi
  done

  : "${HUB_LAN:?missing HUB_LAN in hub.env}"
  : "${WG1_PUB:?missing WG1_PUB in hub.env}"
  : "${WG2_PUB:?missing WG2_PUB in hub.env}"
  : "${WG3_PUB:?missing WG3_PUB in hub.env}"
  : "${WG1_PORT:?missing WG1_PORT in hub.env}"
  : "${WG2_PORT:?missing WG2_PORT in hub.env}"
  : "${WG3_PORT:?missing WG3_PORT in hub.env}"

  : "${HUB_WG1_NET:?missing HUB_WG1_NET in hub.env}"
  : "${HUB_WG2_NET:?missing HUB_WG2_NET in hub.env}"
  : "${HUB_WG3_NET:?missing HUB_WG3_NET in hub.env}"

  : "${WG_ALLOWED_CIDR:?missing WG_ALLOWED_CIDR in hub.env}"
}

# =============================================================================
# WIREGUARD PLANES
# =============================================================================

wg_setup_all() {
  log "Configuring WireGuard planes on minion"

  install -d -m700 /etc/wireguard
  local _old_umask; _old_umask="$(umask)"
  umask 077

  local ifn
  for ifn in wg0 wg1 wg2 wg3; do
    [ -f "/etc/wireguard/${ifn}.key" ] || wg genkey | tee "/etc/wireguard/${ifn}.key" | wg pubkey >"/etc/wireguard/${ifn}.pub"
  done

  # wg0: reserved
  cat >/etc/wireguard/wg0.conf <<EOF
[Interface]
Address    = ${WG0_WANTED}
PrivateKey = $(cat /etc/wireguard/wg0.key)
ListenPort = 0
MTU        = 1420
EOF

  # wg1: control / SSH / Salt
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

  # wg2: metrics plane
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

  # wg3: k8s side/backplane
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
  umask "$_old_umask"

  systemctl daemon-reload || true
  systemctl enable --now wg-quick@wg1 || true
  systemctl enable --now wg-quick@wg2 || true
  systemctl enable --now wg-quick@wg3 || true
}

auto_enroll_with_hub() {
  log "Attempting auto-enrollment with hub via wg-add-peer"

  local ENROLL_KEY="/root/.ssh/enroll_ed25519"
  if [[ ! -r "$ENROLL_KEY" ]]; then
    log "Enrollment SSH key ${ENROLL_KEY} missing; skipping auto-enroll"
    return 0
  fi

  local SSHOPTS="-i ${ENROLL_KEY} -o LogLevel=ERROR -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=6"

  # Check if enrollment is open
  local check_cmd='[ -f /srv/wg/ENROLL_ENABLED ]'
  if ! ssh $SSHOPTS "${ADMIN_USER}@${HUB_LAN}" "$check_cmd" 2>/dev/null; then
    log "Hub enrollment flag not present or unreachable; skipping wg-add-peer"
    return 0
  fi

  local iface wanted pub success any_success=0
  for iface in wg1 wg2 wg3; do
    case "$iface" in
      wg1) wanted="${WG1_WANTED}" ;;
      wg2) wanted="${WG2_WANTED}" ;;
      wg3) wanted="${WG3_WANTED}" ;;
    esac
    pub="$(cat "/etc/wireguard/${iface}.pub" 2>/dev/null || true)"
    if [[ -z "$pub" || -z "$wanted" ]]; then
      log "Skipping ${iface}: missing pubkey or wanted IP"
      continue
    fi

    success=0
    if ssh $SSHOPTS "${ADMIN_USER}@${HUB_LAN}" \
         "sudo /usr/local/sbin/wg-add-peer '$pub' '$wanted' '$iface'" 2>/dev/null; then
      success=1
    fi

    if [[ "$success" -eq 1 ]]; then
      log "[OK] Enrolled ${iface} (${wanted}) with hub"
      any_success=1
    else
      log "[WARN] Failed to enroll ${iface} with hub"
    fi
  done

  if [[ "$any_success" -ne 1 ]]; then
    log "[WARN] No WG interfaces enrolled with hub; continuing anyway"
  fi
}

# =============================================================================
# NFTABLES
# =============================================================================

nft_min() {
  log "Installing nftables rules on minion"

  cat >/etc/nftables.conf <<EOF
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
  chain input {
    type filter hook input priority 0; policy drop;

    # Established/related
    ct state { established, related } accept

    # Loopback
    iif "lo" accept

    # ICMP
    ip protocol icmp accept

    # SSH
    tcp dport 22 accept

    # WireGuard UDP hints (ports are from hub.env)
    udp dport { ${WG1_PORT:-51821}, ${WG2_PORT:-51822}, ${WG3_PORT:-51823} } accept

    # Any traffic from WG planes (control, metrics, k8s)
    ip saddr { 10.78.0.0/16, 10.79.0.0/16, 10.80.0.0/16 } accept
  }

  chain output {
    type filter hook output priority 0; policy accept;
  }

  chain forward {
    type filter hook forward priority 0; policy drop;

    ct state { established, related } accept

    # Allow forwarding within WG planes
    ip saddr { 10.78.0.0/16, 10.79.0.0/16, 10.80.0.0/16 } accept
    ip daddr { 10.78.0.0/16, 10.79.0.0/16, 10.80.0.0/16 } accept
  }
}
EOF

  systemctl enable --now nftables || true
}

# =============================================================================
# SALT MINION
# =============================================================================

install_salt_minion() {
  log "Installing Salt minion"

  install -d -m0755 /etc/apt/keyrings

  curl -fsSL https://packages.broadcom.com/artifactory/api/security/keypair/SaltProjectKey/public \
    -o /etc/apt/keyrings/salt-archive-keyring.pgp || true
  chmod 0644 /etc/apt/keyrings/salt-archive-keyring.pgp || true
  gpg --dearmor </etc/apt/keyrings/salt-archive-keyring.pgp \
    >/etc/apt/keyrings/salt-archive-keyring.gpg 2>/dev/null || true
  chmod 0644 /etc/apt/keyrings/salt-archive-keyring.gpg || true

  cat >/etc/apt/sources.list.d/salt.sources <<'EOF'
Types: deb
URIs: https://packages.broadcom.com/artifactory/saltproject-deb
Suites: stable
Components: main
Signed-By: /etc/apt/keyrings/salt-archive-keyring.pgp
EOF

  cat >/etc/apt/preferences.d/salt-pin-1001 <<'EOF'
Package: salt-*
Pin: version 3006.*
Pin-Priority: 1001
EOF

  apt-get update -y || true
  apt-get install -y --no-install-recommends salt-minion salt-common || true

  mkdir -p /etc/salt/minion.d

  # Master is the hub LAN IP from hub.env
  cat >/etc/salt/minion.d/master.conf <<EOF
master: ${HUB_LAN}
ipv6: False
EOF

  # Grains: role + LAN/WG IPs
  local LAN_IP WG1_ADDR WG2_ADDR WG3_ADDR
  LAN_IP="$(ip -4 addr show scope global | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1)"
  WG1_ADDR="$(echo "${WG1_WANTED}" | cut -d/ -f1)"
  WG2_ADDR="$(echo "${WG2_WANTED}" | cut -d/ -f1)"
  WG3_ADDR="$(echo "${WG3_WANTED}" | cut -d/ -f1)"

  cat >/etc/salt/minion.d/role.conf <<EOF
grains:
  role: ${MY_GROUP}
  lan_ip: ${LAN_IP}
  wg1_ip: ${WG1_ADDR}
  wg2_ip: ${WG2_ADDR}
  wg3_ip: ${WG3_ADDR}
EOF

  install -d -m0755 /etc/systemd/system/salt-minion.service.d
  cat >/etc/systemd/system/salt-minion.service.d/wg-order.conf <<'EOF'
[Unit]
After=wg-quick@wg1.service network-online.target
Wants=wg-quick@wg1.service network-online.target
EOF

  systemctl daemon-reload
  systemctl enable --now salt-minion || true
}

# =============================================================================
# METRICS (node_exporter on wg2)
# =============================================================================

bind_node_exporter() {
  log "Binding node_exporter to wg2 IP"

  local WG2_ADDR
  WG2_ADDR="$(echo "${WG2_WANTED}" | cut -d/ -f1)"

  install -d -m755 /etc/systemd/system/prometheus-node-exporter.service.d
  cat >/etc/systemd/system/prometheus-node-exporter.service.d/override.conf <<EOF
[Service]
Environment=
ExecStart=
ExecStart=/usr/bin/prometheus-node-exporter --web.listen-address=${WG2_ADDR}:9100 --web.disable-exporter-metrics
EOF

  cat >/etc/systemd/system/prometheus-node-exporter.service.d/wg-order.conf <<'EOF'
[Unit]
After=wg-quick@wg2.service network-online.target
Wants=wg-quick@wg2.service network-online.target
EOF

  systemctl daemon-reload
  systemctl enable --now prometheus-node-exporter || true
}

# =============================================================================
# REGISTER WITH MASTER (PROM + ANSIBLE)
# =============================================================================

register_with_master() {
  log "Registering minion with master via register-minion"

  local ENROLL_KEY="/root/.ssh/enroll_ed25519"
  if [[ ! -r "$ENROLL_KEY" ]]; then
    log "Enrollment SSH key ${ENROLL_KEY} missing; skipping register-minion"
    return 0
  fi

  local WG2_ADDR
  WG2_ADDR="$(echo "${WG2_WANTED}" | cut -d/ -f1)"
  local HOST_SHORT
  HOST_SHORT="$(hostname -s)"

  local SSHOPTS="-i ${ENROLL_KEY} -o LogLevel=ERROR -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=6"

  if ssh $SSHOPTS "${ADMIN_USER}@${HUB_LAN}" \
       "sudo /usr/local/sbin/register-minion '${MY_GROUP}' '${HOST_SHORT}' '${WG2_ADDR}'" 2>/dev/null; then
    log "[OK] Registered ${HOST_SHORT} (${WG2_ADDR}) in group ${MY_GROUP}"
    return 0
  fi

  log "[WARN] Failed to register minion with master; Prom/Ansible inventories will miss this node until fixed"
}

# =============================================================================
# ROLE-SPECIFIC HOOKS
# =============================================================================

maybe_role_specific() {
  case "${MY_GROUP}" in
    storage)
      log "Role=storage: installing minimal storage tooling (placeholder)"
      apt-get install -y --no-install-recommends zfsutils-linux || true
      modprobe zfs 2>/dev/null || true
      ;;
    # prom / graf / k8s-* etc. handled by Salt
  esac
}

# =============================================================================
# WRITE CLEAN .bashrc
# =============================================================================

write_bashrc() {
  log "Writing clean .bashrc for all users (via /etc/skel)..."

  local BASHRC=/etc/skel/.bashrc

  cat > "$BASHRC" <<'EOF'
# ~/.bashrc - foundryBot cluster console

# If not running interactively, don't do anything
[ -z "$PS1" ] && return

# =============================================================================
# History, shell options, basic prompt
# =============================================================================

HISTSIZE=10000
HISTFILESIZE=20000
HISTTIMEFORMAT='%F %T '
HISTCONTROL=ignoredups:erasedups

shopt -s histappend
shopt -s checkwinsize
shopt -s cdspell

# Basic prompt (will be overridden below with colorized variant)
PS1='\u@\h:\w\$ '

# =============================================================================
# Banner
# =============================================================================

fb_banner() {
  cat << 'FBBANNER'

     _____
    < Moo?>
     -----
        \   ^__^
         \  (oo)\_______
            (__)\       )\/\
                ||----w |
                ||     ||

  Role      : Kubernetes platform cattle node
  Directive : "If it breaks, replace it."
  Status    : ready to be re-provisioned

FBBANNER
}

# Only show once per interactive session
if [ -z "${FBNOBANNER:-}" ]; then
  fb_banner
  export FBNOBANNER=1
fi

# =============================================================================
# Colorized prompt (root vs non-root)
# =============================================================================

if [ "$EUID" -eq 0 ]; then
  PS1='\[\e[1;31m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ '
else
  PS1='\[\e[1;32m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ '
fi

# =============================================================================
# Bash completion
# =============================================================================

if [ -f /etc/bash_completion ]; then
  # shellcheck source=/etc/bash_completion
  . /etc/bash_completion
fi

# =============================================================================
# Basic quality-of-life aliases
# =============================================================================

alias cp='cp -i'
alias mv='mv -i'
alias rm='rm -i'

alias ls='ls --color=auto'
alias ll='ls -alF --color=auto'
alias la='ls -A --color=auto'
alias l='ls -CF --color=auto'
alias grep='grep --color=auto'
alias e='${EDITOR:-vim}'
alias vi='vim'

# Net & disk helpers
alias ports='ss -tuln'
alias df='df -h'
alias du='du -h'
alias tk='tmux kill-server'

# =============================================================================
# Auto-activate BCC virtualenv (if present)
# =============================================================================

VENV_DIR="/root/bccenv"
if [ -d "$VENV_DIR" ] && [ -n "$PS1" ]; then
  if [ -z "$VIRTUAL_ENV" ] || [ "$VIRTUAL_ENV" != "$VENV_DIR" ]; then
    # shellcheck source=/dev/null
    source "$VENV_DIR/bin/activate"
  fi
fi

# =============================================================================
# Friendly login line
# =============================================================================

echo "Welcome $USER — connected to $(hostname) on $(date)"
echo "Type 'shl' for the foundryBot helper command list."
EOF
}

# =============================================================================
# WRITE TMUX CONFIG
# =============================================================================

write_tmux_conf() {
  log "Writing tmux.conf to /etc/skel and root"
  apt-get install -y tmux

  local TMUX_CONF="/etc/skel/.tmux.conf"

  cat > "$TMUX_CONF" <<'EOF'
# ~/.tmux.conf — Airline-style theme
set -g mouse on
setw -g mode-keys vi
set -g history-limit 10000
set -g default-terminal "screen-256color"
set-option -ga terminal-overrides ",xterm-256color:Tc"
set-option -g status on
set-option -g status-interval 5
set-option -g status-justify centre
set-option -g status-bg colour236
set-option -g status-fg colour250
set-option -g status-style bold
set-option -g status-left-length 60
set-option -g status-left "#[fg=colour0,bg=colour83] #S #[fg=colour83,bg=colour55,nobold,nounderscore,noitalics]"
set-option -g status-right-length 120
set-option -g status-right "#[fg=colour55,bg=colour236]#[fg=colour250,bg=colour55] %Y-%m-%d  %H:%M #[fg=colour236,bg=colour55]#[fg=colour0,bg=colour236] #H "
set-window-option -g window-status-current-style "fg=colour0,bg=colour83,bold"
set-window-option -g window-status-current-format " #I:#W "
set-window-option -g window-status-style "fg=colour250,bg=colour236"
set-window-option -g window-status-format " #I:#W "
set-option -g pane-border-style "fg=colour238"
set-option -g pane-active-border-style "fg=colour83"
set-option -g message-style "bg=colour55,fg=colour250"
set-option -g message-command-style "bg=colour55,fg=colour250"
set-window-option -g bell-action none
bind | split-window -h
bind - split-window -v
unbind '"'
unbind %
bind r source-file ~/.tmux.conf \; display-message "Reloaded!"
bind-key -T copy-mode-vi 'v' send -X begin-selection
bind-key -T copy-mode-vi 'y' send -X copy-selection-and-cancel
EOF

  log ".tmux.conf written to /etc/skel/.tmux.conf"

  # Also set for root:
  cp "$TMUX_CONF" /root/.tmux.conf
  log ".tmux.conf copied to /root/.tmux.conf"
}

# Backwards-compat wrapper (if anything else ever calls this name)
seed_tmux_conf() {
  write_tmux_conf
}

# =============================================================================
# WRITE VIM CONFIG
# =============================================================================

setup_vim_config() {
  log "Writing standard Vim config..."
  apt-get install -y \
    vim \
    git \
    vim-airline \
    vim-airline-themes \
    vim-ctrlp \
    vim-fugitive \
    vim-gitgutter \
    vim-tabular

  local VIMRC=/etc/skel/.vimrc
  mkdir -p /etc/skel/.vim/autoload/airline/themes

  cat > "$VIMRC" <<'EOF'
syntax on
filetype plugin indent on
set nocompatible
set tabstop=2 shiftwidth=2 expandtab
set autoindent smartindent
set background=dark
set ruler
set showcmd
set cursorline
set wildmenu
set incsearch
set hlsearch
set laststatus=2
set clipboard=unnamedplus
set showmatch
set backspace=indent,eol,start
set ignorecase
set smartcase
set scrolloff=5
set wildmode=longest,list,full
set splitbelow
set splitright
highlight ColorColumn ctermbg=darkgrey guibg=grey
highlight ExtraWhitespace ctermbg=red guibg=red
match ExtraWhitespace /\s\+$/
let g:airline_powerline_fonts = 1
let g:airline_theme = 'custom'
let g:airline#extensions#tabline#enabled = 1
let g:airline_section_z = '%l:%c'
let g:ctrlp_map = '<c-p>'
let g:ctrlp_cmd = 'CtrlP'
nmap <leader>gs :Gstatus<CR>
nmap <leader>gd :Gdiff<CR>
nmap <leader>gc :Gcommit<CR>
nmap <leader>gb :Gblame<CR>
let g:gitgutter_enabled = 1
autocmd FileType python,yaml setlocal tabstop=2 shiftwidth=2 expandtab
autocmd FileType javascript,typescript,json setlocal tabstop=2 shiftwidth=2 expandtab
autocmd FileType sh,bash,zsh setlocal tabstop=2 shiftwidth=2 expandtab
nnoremap <leader>w :w<CR>
nnoremap <leader>q :q<CR>
nnoremap <leader>tw :%s/\s\+$//e<CR>
if &term =~ 'xterm'
  let &t_SI = "\e[6 q"
  let &t_EI = "\e[2 q"
endif
EOF

  chmod 644 /etc/skel/.vimrc
  cat > /etc/skel/.vim/autoload/airline/themes/custom.vim <<'EOF'
let g:airline#themes#custom#palette = {}
let s:N1 = [ '#000000' , '#00ff5f' , 0 , 83 ]
let s:N2 = [ '#ffffff' , '#5f00af' , 255 , 55 ]
let s:N3 = [ '#ffffff' , '#303030' , 255 , 236 ]
let s:I1 = [ '#000000' , '#5fd7ff' , 0 , 81 ]
let s:I2 = [ '#ffffff' , '#5f00d7' , 255 , 56 ]
let s:I3 = [ '#ffffff' , '#303030' , 255 , 236 ]
let s:V1 = [ '#000000' , '#af5fff' , 0 , 135 ]
let s:V2 = [ '#ffffff' , '#8700af' , 255 , 91 ]
let s:V3 = [ '#ffffff' , '#303030' , 255 , 236 ]
let s:R1 = [ '#000000' , '#ff5f00' , 0 , 202 ]
let s:R2 = [ '#ffffff' , '#d75f00' , 255 , 166 ]
let s:R3 = [ '#ffffff' , '#303030' , 255 , 236 ]
let s:IA = [ '#aaaaaa' , '#1c1c1c' , 250 , 234 ]
let g:airline#themes#custom#palette.normal = airline#themes#generate_color_map(s:N1, s:N2, s:N3)
let g:airline#themes#custom#palette.insert = airline#themes#generate_color_map(s:I1, s:I2, s:I3)
let g:airline#themes#custom#palette.visual = airline#themes#generate_color_map(s:V1, s:V2, s:V3)
let g:airline#themes#custom#palette.replace = airline#themes#generate_color_map(s:R1, s:R2, s:R3)
let g:airline#themes#custom#palette.inactive = airline#themes#generate_color_map(s:IA, s:IA, s:IA)
EOF

  mkdir -p /root/.vim/autoload/airline/themes
  cp /etc/skel/.vimrc /root/.vimrc
  chmod 644 /root/.vimrc
  cp /etc/skel/.vim/autoload/airline/themes/custom.vim /root/.vim/autoload/airline/themes/custom.vim
  chmod 644 /root/.vim/autoload/airline/themes/custom.vim
}

# =============================================================================
# SETUP PYTHON ENV FOR BCC SCRIPTS
# =============================================================================

setup_python_env() {
  log "Setting up Python for BCC scripts..."

  # System packages only — no pip bcc!
  apt-get install -y python3-psutil python3-bpfcc python3-venv

  # Create a virtualenv that sees system site-packages
  local VENV_DIR="/root/bccenv"
  python3 -m venv --system-site-packages "$VENV_DIR"

  source "$VENV_DIR/bin/activate"
  pip install --upgrade pip wheel setuptools
  pip install cryptography pyOpenSSL numba pytest
  deactivate

  log "System Python has psutil + bpfcc. Venv created at $VENV_DIR with system site-packages."

  # Auto-activate for root
  local ROOT_BASHRC="/root/.bashrc"
  if ! grep -q "$VENV_DIR" "$ROOT_BASHRC" 2>/dev/null; then
    {
      echo ""
      echo "# Auto-activate BCC virtualenv"
      echo "source \"$VENV_DIR/bin/activate\""
    } >> "$ROOT_BASHRC"
  fi

  # Auto-activate for future users
  local SKEL_BASHRC="/etc/skel/.bashrc"
  if ! grep -q "$VENV_DIR" "$SKEL_BASHRC" 2>/dev/null; then
    {
      echo ""
      echo "# Auto-activate BCC virtualenv if available"
      echo "[ -d \"$VENV_DIR\" ] && source \"$VENV_DIR/bin/activate\""
    } >> "$SKEL_BASHRC"
  fi

  log "Virtualenv activation added to root and skel .bashrc"
}

# =============================================================================
# SYNC SKEL TO EXISTING USERS
# =============================================================================

sync_skel_to_existing_users() {
  log "Syncing skel configs to existing users (root + baked)..."

  local files=".bashrc .vimrc .tmux.conf"
  local homes="/root"
  homes+=" $(find /home -mindepth 1 -maxdepth 1 -type d 2>/dev/null || true)"

  for home in $homes; do
    for f in $files; do
      if [ -f "/etc/skel/$f" ]; then
        cp -f "/etc/skel/$f" "$home/$f"
      fi
    done
  done
}

# =============================================================================
# MAIN
# =============================================================================

main() {
  log "BEGIN postinstall (minion)"

  ensure_base
  ensure_admin_user
  install_enroll_key
  ssh_hardening_static
  read_hub
  wg_setup_all
  ssh_bind_lan_and_wg1
  auto_enroll_with_hub
  nft_min
  install_salt_minion
  bind_node_exporter
  register_with_master
  maybe_role_specific
  write_bashrc
  write_tmux_conf
  setup_vim_config
  setup_python_env
  sync_skel_to_existing_users

  # Cleanup noisy/unneeded services
  systemctl disable --now openipmi.service 2>/dev/null || true
  systemctl mask openipmi.service 2>/dev/null || true

  log "Minion ready."

  # Disable bootstrap.service for next boot
  systemctl disable bootstrap.service 2>/dev/null || true
  systemctl daemon-reload || true

  log "Powering off in 2s..."
  (sleep 2; systemctl --no-block poweroff) & disown
}

main
EOS
}

# =============================================================================
# MINION WRAPPER
# =============================================================================

emit_minion_wrapper() {
  # Usage: emit_minion_wrapper <outfile> <group> <wg0/32> <wg1/32> <wg2/32> <wg3/32>
  local out="$1" group="$2" wg0="$3" wg1="$4" wg2="$5" wg3="$6"
  local hub_src="$BUILD_ROOT/hub/hub.env"
  [[ -s "$hub_src" ]] || { err "emit_minion_wrapper: missing hub.env at $hub_src"; return 1; }

  cat >"$out" <<'EOSH'
#!/usr/bin/env bash
set -euo pipefail
LOG="/var/log/minion-wrapper.log"
exec > >(tee -a "$LOG") 2>&1
trap 'echo "[X] Wrapper failed at line $LINENO" >&2' ERR
EOSH

  {
    echo 'mkdir -p /root/darksite/cluster-seed'
    echo 'cat > /root/darksite/cluster-seed/hub.env <<HUBEOF'
    cat "$hub_src"
    echo 'HUBEOF'
    echo 'chmod 0644 /root/darksite/cluster-seed/hub.env'
  } >>"$out"

  cat >>"$out" <<EOSH
install -d -m0755 /etc/environment.d
{
  echo "ADMIN_USER=\${ADMIN_USER:-$ADMIN_USER}"
  echo "MY_GROUP=${group}"
  echo "WG0_WANTED=${wg0}"
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

  local __tmp_minion
  __tmp_minion="$(mktemp)"
  emit_postinstall_minion "$__tmp_minion"
  cat "$__tmp_minion" >>"$out"
  rm -f "$__tmp_minion"

  cat >>"$out" <<'EOSH'
EOMINION
chmod +x /root/darksite/postinstall-minion.sh
bash -lc '/root/darksite/postinstall-minion.sh'
EOSH
  chmod +x "$out"
}

# =============================================================================
# GENERIC: ensure hub enrollment seed exists
# =============================================================================

ensure_master_enrollment_seed() {
  local vmid="$1"
  pmx_guest_exec "$vmid" /bin/bash -lc 'set -euo pipefail
mkdir -p /srv/wg
: > /srv/wg/ENROLL_ENABLED'
}

# =============================================================================
# Minion deploy helper
# =============================================================================

deploy_minion_vm() {
  # deploy_minion_vm <vmid> <name> <lan_ip> <group> <wg0/32> <wg1/32> <wg2/32> <wg3/32> <mem_mb> <cores> <disk_gb>
  local id="$1" name="$2" ip="$3" group="$4"
  local wg0="$5" wg1="$6" wg2="$7" wg3="$8"
  local mem="$9" cores="${10}" disk="${11}"

  local payload iso
  payload="$(mktemp)"
  emit_minion_wrapper "$payload" "$group" "$wg0" "$wg1" "$wg2" "$wg3"

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
# ORIGINAL: base proxmox_cluster
# =============================================================================

proxmox_cluster() {
  log "=== Building base Proxmox cluster (master + prom + graf + storage) ==="

  # --- Master (hub) ---
  log "Emitting postinstall-master.sh"
  MASTER_PAYLOAD="$(mktemp)"
  emit_postinstall_master "$MASTER_PAYLOAD"

  MASTER_ISO="$BUILD_ROOT/master.iso"
  mk_iso "master" "$MASTER_PAYLOAD" "$MASTER_ISO" "$MASTER_LAN"
  pmx_deploy "$MASTER_ID" "$MASTER_NAME" "$MASTER_ISO" "$MASTER_MEM" "$MASTER_CORES" "$MASTER_DISK_GB"

  wait_poweroff "$MASTER_ID" 1800
  boot_from_disk "$MASTER_ID"
  wait_poweroff "$MASTER_ID" 2400
  pmx "qm start $MASTER_ID"
  pmx_wait_for_state "$MASTER_ID" "running" 600
  pmx_wait_qga "$MASTER_ID" 900

  ensure_master_enrollment_seed "$MASTER_ID"

  log "Fetching hub.env from master via QGA..."
  mkdir -p "$BUILD_ROOT/hub"
  DEST="$BUILD_ROOT/hub/hub.env"
  if pmx_guest_cat "$MASTER_ID" "/srv/wg/hub.env" > "${DEST}.tmp" && [[ -s "${DEST}.tmp" ]]; then
    mv -f "${DEST}.tmp" "${DEST}"
    log "hub.env saved to ${DEST}"
  else
    err "QGA fetch failed; fallback to SSH probe"
    for u in "${ADMIN_USER}" ansible root; do
      if sssh "$u@${MASTER_LAN}" "test -r /srv/wg/hub.env" 2>/dev/null; then
        sscp "$u@${MASTER_LAN}:/srv/wg/hub.env" "${DEST}"
        break
      fi
    done
    [[ -s "$DEST" ]] || { err "Failed to retrieve hub.env"; exit 1; }
  fi

  pmx_guest_exec "$MASTER_ID" /bin/bash -lc ": >/srv/wg/ENROLL_ENABLED" || true

  # Core minions
  deploy_minion_vm "$PROM_ID" "$PROM_NAME" "$PROM_IP" "prom" \
    "$PROM_WG0" "$PROM_WG1" "$PROM_WG2" "$PROM_WG3" \
    "$MINION_MEM" "$MINION_CORES" "$MINION_DISK_GB"

  deploy_minion_vm "$GRAF_ID" "$GRAF_NAME" "$GRAF_IP" "graf" \
    "$GRAF_WG0" "$GRAF_WG1" "$GRAF_WG2" "$GRAF_WG3" \
    "$MINION_MEM" "$MINION_CORES" "$MINION_DISK_GB"

  deploy_minion_vm "$STOR_ID" "$STOR_NAME" "$STOR_IP" "storage" \
    "$STOR_WG0" "$STOR_WG1" "$STOR_WG2" "$STOR_WG3" \
    "$MINION_MEM" "$MINION_CORES" "$STOR_DISK_GB"

  pmx_guest_exec "$MASTER_ID" /bin/bash -lc "rm -f /srv/wg/ENROLL_ENABLED" || true
  log "Done. Master + core minions deployed."
}

# =============================================================================
# ORIGINAL: k8s_ha proxmox_cluster
# =============================================================================

proxmox_k8s_ha() {
  log "=== Deploying K8s HA VMs (etcd + LBs + CPs + workers) ==="

  pmx "qm start $MASTER_ID" >/dev/null 2>&1 || true
  pmx_wait_for_state "$MASTER_ID" "running" 600
  pmx_wait_qga "$MASTER_ID" 900
  ensure_master_enrollment_seed "$MASTER_ID"

  mkdir -p "$BUILD_ROOT/hub"
  DEST="$BUILD_ROOT/hub/hub.env"
  if pmx_guest_cat "$MASTER_ID" "/srv/wg/hub.env" > "${DEST}.tmp" && [[ -s "${DEST}.tmp" ]]; then
    mv -f "${DEST}.tmp" "${DEST}"
    log "hub.env refreshed at ${DEST}"
  else
    [[ -s "$DEST" ]] || die "Could not get hub.env for K8s nodes."
  fi

  pmx_guest_exec "$MASTER_ID" /bin/bash -lc ": >/srv/wg/ENROLL_ENABLED" || true

  # --- etcd ---
  deploy_minion_vm "$ETCD1_ID" "$ETCD1_NAME" "$ETCD1_IP" "etcd" \
    "$ETCD1_WG0" "$ETCD1_WG1" "$ETCD1_WG2" "$ETCD1_WG3" \
    "$MINION_MEM" "$MINION_CORES" "$MINION_DISK_GB"

  deploy_minion_vm "$ETCD2_ID" "$ETCD2_NAME" "$ETCD2_IP" "etcd" \
    "$ETCD2_WG0" "$ETCD2_WG1" "$ETCD2_WG2" "$ETCD2_WG3" \
    "$MINION_MEM" "$MINION_CORES" "$MINION_DISK_GB"

  deploy_minion_vm "$ETCD3_ID" "$ETCD3_NAME" "$ETCD3_IP" "etcd" \
    "$ETCD3_WG0" "$ETCD3_WG1" "$ETCD3_WG2" "$ETCD3_WG3" \
    "$MINION_MEM" "$MINION_CORES" "$MINION_DISK_GB"

  # --- LBs ---
  deploy_minion_vm "$K8SLB1_ID" "$K8SLB1_NAME" "$K8SLB1_IP" "lb" \
    "$K8SLB1_WG0" "$K8SLB1_WG1" "$K8SLB1_WG2" "$K8SLB1_WG3" \
    "$K8S_LB_MEM" "$K8S_LB_CORES" "$K8S_LB_DISK_GB"

  deploy_minion_vm "$K8SLB2_ID" "$K8SLB2_NAME" "$K8SLB2_IP" "lb" \
    "$K8SLB2_WG0" "$K8SLB2_WG1" "$K8SLB2_WG2" "$K8SLB2_WG3" \
    "$K8S_LB_MEM" "$K8S_LB_CORES" "$K8S_LB_DISK_GB"

  deploy_minion_vm "$K8SLB3_ID" "$K8SLB3_NAME" "$K8SLB3_IP" "lb" \
    "$K8SLB3_WG0" "$K8SLB3_WG1" "$K8SLB3_WG2" "$K8SLB3_WG3" \
    "$K8S_LB_MEM" "$K8S_LB_CORES" "$K8S_LB_DISK_GB"

  # --- Control planes ---
  deploy_minion_vm "$K8SCP1_ID" "$K8SCP1_NAME" "$K8SCP1_IP" "cp" \
    "$K8SCP1_WG0" "$K8SCP1_WG1" "$K8SCP1_WG2" "$K8SCP1_WG3" \
    "$K8S_CP_MEM" "$K8S_CP_CORES" "$K8S_CP_DISK_GB"

  deploy_minion_vm "$K8SCP2_ID" "$K8SCP2_NAME" "$K8SCP2_IP" "cp" \
    "$K8SCP2_WG0" "$K8SCP2_WG1" "$K8SCP2_WG2" "$K8SCP2_WG3" \
    "$K8S_CP_MEM" "$K8S_CP_CORES" "$K8S_CP_DISK_GB"

  deploy_minion_vm "$K8SCP3_ID" "$K8SCP3_NAME" "$K8SCP3_IP" "cp" \
    "$K8SCP3_WG0" "$K8SCP3_WG1" "$K8SCP3_WG2" "$K8SCP3_WG3" \
    "$K8S_CP_MEM" "$K8S_CP_CORES" "$K8S_CP_DISK_GB"

  # --- Workers ---
  deploy_minion_vm "$K8SW1_ID" "$K8SW1_NAME" "$K8SW1_IP" "worker" \
    "$K8SW1_WG0" "$K8SW1_WG1" "$K8SW1_WG2" "$K8SW1_WG3" \
    "$K8S_WK_MEM" "$K8S_WK_CORES" "$K8S_WK_DISK_GB"

  deploy_minion_vm "$K8SW2_ID" "$K8SW2_NAME" "$K8SW2_IP" "worker" \
    "$K8SW2_WG0" "$K8SW2_WG1" "$K8SW2_WG2" "$K8SW2_WG3" \
    "$K8S_WK_MEM" "$K8S_WK_CORES" "$K8S_WK_DISK_GB"

  deploy_minion_vm "$K8SW3_ID" "$K8SW3_NAME" "$K8SW3_IP" "worker" \
    "$K8SW3_WG0" "$K8SW3_WG1" "$K8SW3_WG2" "$K8SW3_WG3" \
    "$K8S_WK_MEM" "$K8S_WK_CORES" "$K8S_WK_DISK_GB"

  pmx_guest_exec "$MASTER_ID" /bin/bash -lc "rm -f /srv/wg/ENROLL_ENABLED" || true

  run_apply_on_master

  log "==> K8s cluster bootstrap is complete"
}

proxmox_all() {
  log "=== Running full Proxmox deployment: base cluster + K8s node VMs ==="
  proxmox_cluster
  proxmox_k8s_ha
  log "=== Proxmox ALL complete. ==="
}

# =============================================================================
# Run apply.py on master (authoritative: /srv/darksite/apply.py)
# - never touches ~/.ssh/known_hosts
# - all checks + execution happen under sudo (root-owned payload is fine)
# - streams apply output live (python -u)
# =============================================================================
run_apply_on_master() {
  log "Running apply.py on master via ${ADMIN_USER}@${MASTER_LAN}"
  local host="${ADMIN_USER}@${MASTER_LAN}"

  # Unit-scoped known_hosts on build server (deterministic, avoids hostkey drift pain)
  local unit_kh="${UNIT_KNOWN_HOSTS:-/srv/darksite/known_hosts.buildserver}"
  mkdir -p "$(dirname "$unit_kh")"
  : > "$unit_kh"
  chmod 600 "$unit_kh"

  ssh \
    -i /home/todd/.ssh/id_ed25519 \
    -o IdentitiesOnly=yes \
    -o ConnectTimeout=20 \
    -o BatchMode=yes \
    -o ServerAliveInterval=15 \
    -o ServerAliveCountMax=3 \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="$unit_kh" \
    "$host" -- bash -s <<'EOSSH'
set -euo pipefail

APPLY="/srv/darksite/apply.py"

echo "[REMOTE] start: $(date -Is)"
echo "[REMOTE] hostname: $(hostname -f)"
echo "[REMOTE] user: $(id -un) uid=$(id -u)"
echo "[REMOTE] apply path: ${APPLY}"

# Small settle, optional
sleep 5

echo "[REMOTE] sudo check..."
sudo -n true
echo "[REMOTE] sudo OK"

echo "[REMOTE] verifying payload (under sudo)..."
sudo -n test -f "$APPLY"
sudo -n ls -la "$APPLY"
sudo -n python3 -m py_compile "$APPLY"
echo "[REMOTE] apply.py compiles OK"

# Ensure unbuffered output for live streaming over SSH + journald
echo "[REMOTE] running apply.py (live output)..."
sudo -n /usr/bin/python3 -u "$APPLY"

echo "[REMOTE] done: $(date -Is)"
EOSSH
}

# =============================================================================
# Packer scaffold (optional)
# =============================================================================

packer_scaffold() {
  require_cmd packer
  mkdir -p "$PACKER_OUT_DIR"

  local iso="${MASTER_ISO:-${ISO_ORIG:-}}"
  [[ -n "${iso:-}" ]] || die "packer_scaffold: MASTER_ISO or ISO_ORIG must be set"

  log "Emitting Packer QEMU template at: $PACKER_TEMPLATE (iso=$iso)"

  cat >"$PACKER_TEMPLATE" <<EOF
{
  "variables": {
    "image_name": "foundrybot-debian13",
    "iso_url": "${iso}",
    "iso_checksum": "none"
  },
  "builders": [
    {
      "type": "qemu",
      "name": "foundrybot-qemu",
      "iso_url": "{{user \"iso_url\"}}",
      "iso_checksum": "{{user \"iso_checksum\"}}",
      "output_directory": "${PACKER_OUT_DIR}/output",
      "shutdown_command": "sudo shutdown -P now",
      "ssh_username": "${ADMIN_USER:-admin}",
      "ssh_password": "disabled",
      "ssh_timeout": "45m",
      "headless": true,
      "disk_size": 20480,
      "format": "qcow2",
      "accelerator": "kvm",
      "http_directory": "${PACKER_OUT_DIR}/http",
      "boot_wait": "5s",
      "boot_command": [
        "<esc><wait>",
        "auto priority=critical console=ttyS0,115200n8 ",
        "preseed/file=/cdrom/preseed.cfg ",
        "debian-installer=en_US ",
        "language=en ",
        "country=US ",
        "locale=en_US.UTF-8 ",
        "hostname=packer ",
        "domain=${DOMAIN:-example.com} ",
        "<enter>"
      ]
    }
  ],
  "provisioners": [
    { "type": "shell", "inline": [ "echo 'Packer provisioner hook - handoff to foundryBot bootstrap if desired.'" ] }
  ]
}
EOF

  log "Packer scaffold ready."
}

# =============================================================================
# Export VMDK (optional)
# =============================================================================

export_vmdk() {
  require_cmd qemu-img
  [[ -f "$BASE_DISK_IMAGE" ]] || die "export_vmdk: BASE_DISK_IMAGE not found"
  mkdir -p "$(dirname "$VMDK_OUTPUT")"
  log "Converting $BASE_DISK_IMAGE -> $VMDK_OUTPUT"
  qemu-img convert -O vmdk "$BASE_DISK_IMAGE" "$VMDK_OUTPUT"
  log "VMDK export complete: $VMDK_OUTPUT"
}

# =============================================================================
# Firecracker bundle/flow (optional)
# =============================================================================

firecracker_bundle() {
  mkdir -p "$FC_WORKDIR"
  [[ -f "$FC_ROOTFS_IMG" ]] || die "firecracker_bundle: FC_ROOTFS_IMG missing"
  [[ -f "$FC_KERNEL"    ]] || die "firecracker_bundle: FC_KERNEL missing"
  [[ -f "$FC_INITRD"    ]] || die "firecracker_bundle: FC_INITRD missing"

  local cfg="$FC_WORKDIR/fc-config.json"
  log "Emitting Firecracker config: $cfg"

  cat >"$cfg" <<EOF
{
  "boot-source": {
    "kernel_image_path": "${FC_KERNEL}",
    "initrd_path": "${FC_INITRD}",
    "boot_args": "console=ttyS0 reboot=k panic=1 pci=off ip=dhcp"
  },
  "drives": [
    { "drive_id": "rootfs", "path_on_host": "${FC_ROOTFS_IMG}", "is_root_device": true, "is_read_only": false }
  ],
  "machine-config": { "vcpu_count": ${FC_VCPUS}, "mem_size_mib": ${FC_MEM_MB}, "ht_enabled": false },
  "network-interfaces": []
}
EOF

  local run="$FC_WORKDIR/run-fc.sh"
  cat >"$run" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
FC_BIN="${FC_BIN:-firecracker}"
FC_SOCKET="${FC_SOCKET:-/tmp/firecracker.sock}"
FC_CONFIG="${FC_CONFIG:-/dev/null}"
rm -f "$FC_SOCKET"
$FC_BIN --api-sock "$FC_SOCKET" &
FC_PID=$!
cleanup() { kill "$FC_PID" 2>/dev/null || true; }
trap cleanup EXIT
curl -sS -X PUT --unix-socket "$FC_SOCKET" -H 'Content-Type: application/json' -d @"$FC_CONFIG" /machine-config >/dev/null
curl -sS -X PUT --unix-socket "$FC_SOCKET" -H 'Content-Type: application/json' -d @"$FC_CONFIG" /boot-source >/dev/null
curl -sS -X PUT --unix-socket "$FC_SOCKET" -H 'Content-Type: application/json' -d @"$FC_CONFIG" /drives/rootfs >/dev/null
curl -sS -X PUT --unix-socket "$FC_SOCKET" -H 'Content-Type: application/json' -d '{"action_type": "InstanceStart"}' /actions >/dev/null
wait "$FC_PID"
EOF
  chmod +x "$run"

  log "Firecracker bundle ready in $FC_WORKDIR"
  log "Run with: FC_CONFIG='$cfg' $run"
}

firecracker_flow() {
  firecracker_bundle
  log "Launching Firecracker microVM..."
  FC_CONFIG="$FC_WORKDIR/fc-config.json" "$FC_WORKDIR/run-fc.sh"
}

# =============================================================================
# AWS (optional)
# =============================================================================

aws_bake_ami() {
  require_cmd aws
  require_cmd qemu-img
  [[ -n "${AWS_S3_BUCKET:-}" ]]   || die "aws_bake_ami: AWS_S3_BUCKET must be set"
  [[ -n "${AWS_REGION:-}"   ]]   || die "aws_bake_ami: AWS_REGION must be set"
  [[ -n "${AWS_IMPORT_ROLE:-}" ]]|| die "aws_bake_ami: AWS_IMPORT_ROLE must be set"

  [[ -f "$BASE_DISK_IMAGE" ]] || die "aws_bake_ami: BASE_DISK_IMAGE not found"

  mkdir -p "$BUILD_ROOT/aws"
  local raw="$BASE_RAW_IMAGE"
  local key="foundrybot/${AWS_ARCH}/$(date +%Y%m%d-%H%M%S)-root.raw"

  log "Converting $BASE_DISK_IMAGE -> raw: $raw"
  qemu-img convert -O raw "$BASE_DISK_IMAGE" "$raw"

  log "Uploading raw image to s3://$AWS_S3_BUCKET/$key"
  aws --profile "$AWS_PROFILE" --region "$AWS_REGION" s3 cp "$raw" "s3://$AWS_S3_BUCKET/$key"

  log "Starting EC2 import-image task"
  local task_id
  task_id=$(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" ec2 import-image \
    --description "foundryBot Debian 13 $AWS_ARCH" \
    --disk-containers "FileFormat=RAW,UserBucket={S3Bucket=$AWS_S3_BUCKET,S3Key=$key}" \
    --role-name "$AWS_IMPORT_ROLE" --query 'ImportTaskId' --output text)

  log "Import task: $task_id (polling until completed...)"
  local status ami
  while :; do
    sleep 30
    status=$(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" ec2 describe-import-image-tasks \
      --import-task-ids "$task_id" --query 'ImportImageTasks[0].Status' --output text)
    log "Import status: $status"
    if [[ "$status" == "completed" ]]; then
      ami=$(aws --profile "$AWS_PROFILE" --region "$AWS_REGION" ec2 describe-import-image-tasks \
        --import-task-ids "$task_id" --query 'ImportImageTasks[0].ImageId' --output text)
      break
    elif [[ "$status" =~ ^(deleted|deleting|cancelling)$ ]]; then
      die "aws_bake_ami: import task $task_id failed with status=$status"
    fi
  done

  log "AMI created: $ami"
  echo "$ami" >"$BUILD_ROOT/aws/last-ami-id"
}

aws_run_from_ami() {
  require_cmd aws
  local ami="${AWS_AMI_ID:-}"
  if [[ -z "$ami" ]] && [[ -f "$BUILD_ROOT/aws/last-ami-id" ]]; then
    ami=$(<"$BUILD_ROOT/aws/last-ami-id")
  fi
  [[ -n "$ami" ]] || die "aws_run_from_ami: AWS_AMI_ID not set and no last-ami-id found"
  [[ -n "${AWS_SUBNET_ID:-}" ]] || die "aws_run_from_ami: AWS_SUBNET_ID must be set"
  [[ -n "${AWS_SECURITY_GROUP_ID:-}" ]] || die "aws_run_from_ami: AWS_SECURITY_GROUP_ID must be set"

  log "Launching $AWS_RUN_COUNT x $AWS_INSTANCE_TYPE in $AWS_REGION from AMI $ami"
  aws --profile "$AWS_PROFILE" --region "$AWS_REGION" ec2 run-instances \
    --image-id "$ami" \
    --count "${AWS_RUN_COUNT:-1}" \
    --instance-type "${AWS_INSTANCE_TYPE:-t3.medium}" \
    --key-name "$AWS_KEY_NAME" \
    --subnet-id "$AWS_SUBNET_ID" \
    --security-group-ids "$AWS_SECURITY_GROUP_ID" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=stack,Value=${AWS_TAG_STACK:-foundrybot}},{Key=role,Value=${AWS_RUN_ROLE:-generic}}]" \
    --output table
}

# =============================================================================
# MAIN
# =============================================================================

TARGET="${TARGET:-proxmox-all}"

case "$TARGET" in
  proxmox-all)        proxmox_all        ;;
  proxmox-cluster)    proxmox_cluster    ;;
  proxmox-k8s-ha)     proxmox_k8s_ha     ;;
  packer-scaffold)    packer_scaffold    ;;
  aws-ami|aws_ami)    aws_bake_ami       ;;
  aws-run|aws_run)    aws_run_from_ami   ;;
  firecracker-bundle) firecracker_bundle ;;
  firecracker)        firecracker_flow   ;;
  vmdk-export)        export_vmdk        ;;
  *)
    die "Unknown TARGET '$TARGET'. Expected: proxmox-all | proxmox-cluster | proxmox-k8s-ha | packer-scaffold | aws-ami | aws-run | firecracker-bundle | firecracker | vmdk-export"
    ;;
esac

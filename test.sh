#!/usr/bin/env bash
# deploy.sh — Role-count driven Proxmox cluster builder (LAN-first Salt bootstrap)
# -----------------------------------------------------------------------------
# Key properties:
#   - Build host does NOT need wireguard-tools.
#   - Master+minions bootstrap on LAN, Salt converges workloads afterward.
#   - Two SSH identities:
#       * PROXMOX_SSH_IDENTITY_FILE -> root@PROXMOX_HOST
#       * MASTER_SSH_IDENTITY_FILE  -> ADMIN_USER@MASTER_LAN
#   - All logs go to STDERR. Stdout is reserved for return values.
# -----------------------------------------------------------------------------

set -euo pipefail

# -----------------------------------------------------------------------------
# Logging (stderr only) + stdout for return values
# -----------------------------------------------------------------------------
log()  { echo "[INFO]  $(date '+%F %T') - $*" >&2; }
warn() { echo "[WARN]  $(date '+%F %T') - $*" >&2; }
err()  { echo "[ERROR] $(date '+%F %T') - $*" >&2; }
die()  { err "$*"; exit 1; }
say()  { echo "$*"; }  # stdout

have() { command -v "$1" >/dev/null 2>&1; }
need() { have "$1" || die "Missing required command: $1"; }

# -----------------------------------------------------------------------------
# Defaults / knobs (env overrides allowed)
# -----------------------------------------------------------------------------
TARGET="${TARGET:-proxmox-all}"     # proxmox-master | proxmox-minions | proxmox-all
INPUT="${INPUT:-1}"                # 1|2|3 or names mapped below
DOMAIN="${DOMAIN:-unixbox.net}"

# Proxmox host selection
case "$INPUT" in
  1|fiend)  PROXMOX_HOST="${PROXMOX_HOST:-10.100.10.225}" ;;
  2|dragon) PROXMOX_HOST="${PROXMOX_HOST:-10.100.10.226}" ;;
  3|lion)   PROXMOX_HOST="${PROXMOX_HOST:-10.100.10.227}" ;;
  *) die "Unknown INPUT=$INPUT (expected 1|fiend,2|dragon,3|lion)" ;;
esac

ISO_ORIG="${ISO_ORIG:-/root/debian-13.2.0-amd64-netinst.iso}"
ISO_STORAGE="${ISO_STORAGE:-local}"
VM_STORAGE="${VM_STORAGE:-local-zfs}"

# Network (LAN bootstrap plane)
NETMASK="${NETMASK:-255.255.255.0}"
GATEWAY="${GATEWAY:-10.100.10.1}"
NAMESERVER="${NAMESERVER:-10.100.10.2 10.100.10.3}"

# Master identity
MASTER_NAME="${MASTER_NAME:-master}"
MASTER_ID="${MASTER_ID:-2000}"
MASTER_LAN="${MASTER_LAN:-10.100.10.224}"

# Dynamic pools
LAN_START_IP="${LAN_START_IP:-10.100.10.200}"
VMID_START="${VMID_START:-2100}"

# WireGuard planes (intent only here; Salt will configure later)
WG1_NET="${WG1_NET:-10.78.0.0/16}"
WG2_NET="${WG2_NET:-10.79.0.0/16}"
WG3_NET="${WG3_NET:-10.80.0.0/16}"
WG_ALLOWED_CIDR="${WG_ALLOWED_CIDR:-10.78.0.0/16,10.79.0.0/16,10.80.0.0/16}"

WG1_IP="${WG1_IP:-10.78.0.1/16}"; WG1_PORT="${WG1_PORT:-51821}"
WG2_IP="${WG2_IP:-10.79.0.1/16}"; WG2_PORT="${WG2_PORT:-51822}"
WG3_IP="${WG3_IP:-10.80.0.1/16}"; WG3_PORT="${WG3_PORT:-51823}"

# Preseed / installer
PRESEED_LOCALE="${PRESEED_LOCALE:-en_US.UTF-8}"
PRESEED_KEYMAP="${PRESEED_KEYMAP:-us}"
PRESEED_TIMEZONE="${PRESEED_TIMEZONE:-America/Vancouver}"
PRESEED_ROOT_PASSWORD="${PRESEED_ROOT_PASSWORD:-root}"
PRESEED_BOOTDEV="${PRESEED_BOOTDEV:-/dev/sda}"
PRESEED_EXTRA_PKGS="${PRESEED_EXTRA_PKGS:-openssh-server rsync ca-certificates curl wget sudo}"

# Admin auth
ADMIN_USER="${ADMIN_USER:-todd}"
SSH_PUBKEY="${SSH_PUBKEY:-ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINgqdaF+C41xwLS41+dOTnpsrDTPkAwo4Zejn4tb0lOt todd@onyx.unixbox.net}"

# Resources
MASTER_MEM="${MASTER_MEM:-4096}"
MASTER_CORES="${MASTER_CORES:-4}"
MASTER_DISK_GB="${MASTER_DISK_GB:-40}"
MINION_MEM="${MINION_MEM:-4096}"
MINION_CORES="${MINION_CORES:-4}"
MINION_DISK_GB="${MINION_DISK_GB:-32}"

# Build outputs
BUILD_ROOT="${BUILD_ROOT:-/root/builds}"
mkdir -p "$BUILD_ROOT"

# Darksite payload root (optional)
DARKSITE_SRC="${DARKSITE_SRC:-}"
if [[ -z "${DARKSITE_SRC}" ]]; then
  if [[ -d "$(pwd)/payload/darksite" ]]; then DARKSITE_SRC="$(pwd)/payload/darksite"; fi
  if [[ -z "${DARKSITE_SRC}" && -d "$HOME/foundrybot/payload/darksite" ]]; then DARKSITE_SRC="$HOME/foundrybot/payload/darksite"; fi
fi

# -----------------------------------------------------------------------------
# Role counts
# -----------------------------------------------------------------------------
PROM_COUNT="${PROM_COUNT:-0}"
GRAF_COUNT="${GRAF_COUNT:-0}"
STORAGE_COUNT="${STORAGE_COUNT:-0}"
ETCD_COUNT="${ETCD_COUNT:-0}"
CP_COUNT="${CP_COUNT:-0}"
WORKER_COUNT="${WORKER_COUNT:-0}"
LB_COUNT="${LB_COUNT:-0}"
CI_COUNT="${CI_COUNT:-0}"

# -----------------------------------------------------------------------------
# CLI parsing
# -----------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage:
  $0 --target proxmox-all [role counts...]

Targets:
  --target proxmox-master
  --target proxmox-minions
  --target proxmox-all

Role counts:
  --prom N --graf N --storage N --etcd N --cp N --worker N --lb N --ci N

Allocation:
  --lan-start-ip IP
  --vmid-start N
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    --prom) PROM_COUNT="$2"; shift 2 ;;
    --graf) GRAF_COUNT="$2"; shift 2 ;;
    --storage) STORAGE_COUNT="$2"; shift 2 ;;
    --etcd) ETCD_COUNT="$2"; shift 2 ;;
    --cp) CP_COUNT="$2"; shift 2 ;;
    --worker) WORKER_COUNT="$2"; shift 2 ;;
    --lb) LB_COUNT="$2"; shift 2 ;;
    --ci) CI_COUNT="$2"; shift 2 ;;
    --lan-start-ip) LAN_START_IP="$2"; shift 2 ;;
    --vmid-start) VMID_START="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown arg: $1 (use --help)" ;;
  esac
done

# -----------------------------------------------------------------------------
# SSH identity selection (split: Proxmox vs Master)
# -----------------------------------------------------------------------------
KNOWN_HOSTS="${KNOWN_HOSTS:-$BUILD_ROOT/known_hosts}"
mkdir -p "$(dirname "$KNOWN_HOSTS")"
touch "$KNOWN_HOSTS"
chmod 600 "$KNOWN_HOSTS"

pick_key() {
  # pick_key "path1" "path2" ...
  local p
  for p in "$@"; do
    [[ -r "$p" ]] && { echo "$p"; return 0; }
  done
  return 1
}

# Proxmox root key: default to root's key first (common), then fallbacks
PROXMOX_SSH_IDENTITY_FILE="${PROXMOX_SSH_IDENTITY_FILE:-}"
if [[ -z "$PROXMOX_SSH_IDENTITY_FILE" ]]; then
  PROXMOX_SSH_IDENTITY_FILE="$(
    pick_key \
      /root/.ssh/id_ed25519 \
      /root/.ssh/id_rsa \
      "/home/${SUDO_USER:-}/.ssh/id_ed25519" \
      "/home/${SUDO_USER:-}/.ssh/id_rsa" \
      2>/dev/null || true
  )"
fi
[[ -r "${PROXMOX_SSH_IDENTITY_FILE:-}" ]] || die "PROXMOX_SSH_IDENTITY_FILE not readable. Set it to the key accepted by root@${PROXMOX_HOST}"

# Master admin key: default to admin user's key first
MASTER_SSH_IDENTITY_FILE="${MASTER_SSH_IDENTITY_FILE:-}"
if [[ -z "$MASTER_SSH_IDENTITY_FILE" ]]; then
  MASTER_SSH_IDENTITY_FILE="$(
    pick_key \
      "/home/${ADMIN_USER}/.ssh/id_ed25519" \
      "/home/${ADMIN_USER}/.ssh/id_rsa" \
      "/home/${SUDO_USER:-}/.ssh/id_ed25519" \
      "/home/${SUDO_USER:-}/.ssh/id_rsa" \
      /root/.ssh/id_ed25519 \
      /root/.ssh/id_rsa \
      2>/dev/null || true
  )"
fi
[[ -r "${MASTER_SSH_IDENTITY_FILE:-}" ]] || die "MASTER_SSH_IDENTITY_FILE not readable. Set it to the key for ${ADMIN_USER}@${MASTER_LAN}"

SSH_BASE_OPTS=(
  -o LogLevel=ERROR
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile="$KNOWN_HOSTS"
  -o GlobalKnownHostsFile=/dev/null
  -o ConnectTimeout=10
  -o BatchMode=yes
  -o IdentitiesOnly=yes
  -o PreferredAuthentications=publickey
)

pmx_ssh() { ssh -q "${SSH_BASE_OPTS[@]}" -i "$PROXMOX_SSH_IDENTITY_FILE" "$@"; }
pmx_scp() { scp -q "${SSH_BASE_OPTS[@]}" -i "$PROXMOX_SSH_IDENTITY_FILE" "$@"; }

mst_ssh() { ssh -q "${SSH_BASE_OPTS[@]}" -i "$MASTER_SSH_IDENTITY_FILE" "$@"; }
mst_scp() { scp -q "${SSH_BASE_OPTS[@]}" -i "$MASTER_SSH_IDENTITY_FILE" "$@"; }

pmx() { pmx_ssh root@"$PROXMOX_HOST" "$@"; }

wait_ssh_ready() {
  local host="$1" key="$2" tries="${3:-90}" sleep_s="${4:-2}"
  local i
  for ((i=1; i<=tries; i++)); do
    if ssh -q "${SSH_BASE_OPTS[@]}" -i "$key" "$host" "true" >/dev/null 2>&1; then return 0; fi
    sleep "$sleep_s"
  done
  return 1
}

# -----------------------------------------------------------------------------
# IP math helpers (IPv4)
# -----------------------------------------------------------------------------
ip2int() { local a b c d; IFS=. read -r a b c d <<<"$1"; echo $(( (a<<24) + (b<<16) + (c<<8) + d )); }
int2ip() { local x="$1"; echo "$(( (x>>24)&255 )).$(( (x>>16)&255 )).$(( (x>>8)&255 )).$(( x&255 ))"; }

wg16_ip_for_index() {
  local base="$1" idx="$2"
  local a b _c _d
  IFS=. read -r a b _c _d <<<"$base"
  local third=$(( idx / 254 ))
  local fourth=$(( (idx % 254) + 2 ))
  echo "${a}.${b}.${third}.${fourth}/32"
}

# -----------------------------------------------------------------------------
# Proxmox helpers
# -----------------------------------------------------------------------------
pmx_vm_state() { pmx "qm status $1 2>/dev/null | awk '{print tolower(\$2)}'" || echo "unknown"; }

pmx_wait_for_state() {
  local vmid="$1" want="$2" timeout="${3:-2400}"
  local start state
  start="$(date +%s)"
  log "Waiting for VM $vmid to be '$want'..."
  while :; do
    state="$(pmx_vm_state "$vmid")"
    [[ "$state" == "$want" ]] && { log "VM $vmid is $state"; return 0; }
    (( $(date +%s) - start > timeout )) && die "Timeout waiting VM $vmid want=$want got=$state"
    sleep 5
  done
}

pmx_upload_iso() {
  local iso_file="$1" iso_base
  [[ -f "$iso_file" ]] || die "ISO not found: $iso_file"
  iso_base="$(basename "$iso_file")"
  log "Uploading ISO => ${iso_base} (to root@${PROXMOX_HOST})"
  pmx_scp "$iso_file" "root@${PROXMOX_HOST}:/var/lib/vz/template/iso/$iso_base"
  say "$iso_base"
}

pmx_deploy() {
  local vmid="$1" vmname="$2" iso_file="$3" mem="$4" cores="$5" disk_gb="$6"
  local iso_base
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
  --cpu host --sockets 1 \
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

# -----------------------------------------------------------------------------
# ISO builder (native xorriso on build host)
# -----------------------------------------------------------------------------
need xorriso
need mount
need rsync

mk_iso() {
  local short="$1"           # hostname short
  local postinstall="$2"     # script path to bake into /darksite/postinstall.sh
  local iso_out="$3"
  local static_ip="$4"

  local build="$BUILD_ROOT/iso-$short"
  local mnt="$build/mnt"
  local cust="$build/custom"
  rm -rf "$build" || true
  mkdir -p "$mnt" "$cust"

  (
    trap 'umount -f "$mnt" 2>/dev/null || true' EXIT
    mount -o loop,ro "$ISO_ORIG" "$mnt"
    cp -a "$mnt/"* "$cust/"
    cp -a "$mnt/.disk" "$cust/" 2>/dev/null || true
  )

  # ---------------------------------------------------------------------------
  # darksite payload
  # ---------------------------------------------------------------------------
  mkdir -p "$cust/darksite"
  if [[ -n "${DARKSITE_SRC}" && -d "${DARKSITE_SRC}" ]]; then
    rsync -a --delete "${DARKSITE_SRC}/" "$cust/darksite/"
  fi
  install -m0755 "$postinstall" "$cust/darksite/postinstall.sh"

  cat >"$cust/darksite/bootstrap.service" <<'EOF'
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

  # ---------------------------------------------------------------------------
  # Preseed
  # ---------------------------------------------------------------------------
  local fqdn="${short}.${DOMAIN}"

  local NETBLOCK
  NETBLOCK="d-i netcfg/choose_interface select auto
d-i netcfg/get_hostname string ${short}
d-i netcfg/hostname string ${short}
d-i netcfg/get_domain string ${DOMAIN}
d-i netcfg/disable_dhcp boolean true
d-i netcfg/get_ipaddress string ${static_ip}
d-i netcfg/get_netmask string ${NETMASK}
d-i netcfg/get_gateway string ${GATEWAY}
d-i netcfg/get_nameservers string ${NAMESERVER}"

  cat >"$cust/preseed.cfg" <<EOF
d-i debconf/frontend select Noninteractive
d-i debconf/priority string critical
d-i apt-cdrom-setup/another boolean false

d-i debian-installer/locale string ${PRESEED_LOCALE}
d-i console-setup/ask_detect boolean false
d-i keyboard-configuration/xkb-keymap select ${PRESEED_KEYMAP}
${NETBLOCK}

d-i passwd/root-login boolean true
d-i passwd/root-password password ${PRESEED_ROOT_PASSWORD}
d-i passwd/root-password-again password ${PRESEED_ROOT_PASSWORD}
d-i passwd/make-user boolean false

d-i time/zone string ${PRESEED_TIMEZONE}
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
d-i pkgsel/include string ${PRESEED_EXTRA_PKGS}
d-i pkgsel/upgrade select none
d-i pkgsel/ignore-recommends boolean true
popularity-contest popularity-contest/participate boolean false

d-i grub-installer/only_debian boolean true
d-i grub-installer/bootdev string ${PRESEED_BOOTDEV}

d-i preseed/late_command string \
  set -e; \
  echo "${fqdn}" > /target/etc/hostname; \
  if grep -q '^127\\.0\\.1\\.1' /target/etc/hosts; then \
    sed -ri "s/^127\\.0\\.1\\.1.*/127.0.1.1\\t${fqdn}\\t${short}/" /target/etc/hosts; \
  else \
    printf '\\n127.0.1.1\\t%s\\t%s\\n' "${fqdn}" "${short}" >> /target/etc/hosts; \
  fi; \
  mkdir -p /target/root/darksite; \
  cp -a /cdrom/darksite/. /target/root/darksite/; \
  in-target install -m 0644 /root/darksite/bootstrap.service /etc/systemd/system/bootstrap.service; \
  in-target systemctl daemon-reload; \
  in-target systemctl enable bootstrap.service; \
  in-target /bin/systemctl --no-block poweroff || true

d-i cdrom-detect/eject boolean true
d-i finish-install/exit-installer boolean true
d-i debian-installer/exit/poweroff boolean true
EOF

  # ---------------------------------------------------------------------------
  # Bootloader patching: force AUTO entry for both BIOS (isolinux) and UEFI (grub)
  # ---------------------------------------------------------------------------
  local KARGS
  KARGS="auto=true priority=critical preseed/file=/cdrom/preseed.cfg ---"

  patch_isolinux() {
    local iso_cfg="$cust/isolinux/isolinux.cfg"
    local txt_cfg="$cust/isolinux/txt.cfg"
    local menu_cfg="$cust/isolinux/menu.cfg"
    local gtk_cfg="$cust/isolinux/gtk.cfg"

    [[ -f "$txt_cfg" ]] || return 0

    # Add an "auto" label with menu default
    if ! grep -qE '^label[[:space:]]+auto$' "$txt_cfg"; then
      cat >>"$txt_cfg" <<EOF

label auto
  menu label ^auto (preseed)
  menu default
  kernel /install.amd/vmlinuz
  append initrd=/install.amd/initrd.gz ${KARGS} quiet
EOF
    else
      # Ensure menu default exists in the stanza
      awk '
        BEGIN{in=0}
        /^label[[:space:]]+auto$/ {in=1}
        in==1 && /^[[:space:]]*menu[[:space:]]+default/ {found=1}
        in==1 && /^label[[:space:]]+/ && $2!="auto" { if(!found) print "  menu default"; in=0; found=0 }
        {print}
        END{ if(in==1 && !found) print "  menu default" }
      ' "$txt_cfg" >"$txt_cfg.tmp" && mv -f "$txt_cfg.tmp" "$txt_cfg"
    fi

    # Force isolinux to default to "auto" and not prompt
    if [[ -f "$iso_cfg" ]]; then
      if grep -qE '^default[[:space:]]+' "$iso_cfg"; then
        sed -ri 's/^default[[:space:]]+.*/default auto/' "$iso_cfg"
      else
        printf '\ndefault auto\n' >>"$iso_cfg"
      fi

      # prompt 0 and timeout 1 (syslinux timeout is deciseconds; 1 = 0.1s)
      if grep -qE '^prompt[[:space:]]+' "$iso_cfg"; then
        sed -ri 's/^prompt[[:space:]]+.*/prompt 0/' "$iso_cfg"
      else
        printf 'prompt 0\n' >>"$iso_cfg"
      fi

      if grep -qE '^timeout[[:space:]]+' "$iso_cfg"; then
        sed -ri 's/^timeout[[:space:]]+.*/timeout 1/' "$iso_cfg"
      else
        printf 'timeout 1\n' >>"$iso_cfg"
      fi
    fi

    # Some Debian media uses menu.cfg/gtk.cfg for defaults; set default there too if present
    for f in "$menu_cfg" "$gtk_cfg"; do
      [[ -f "$f" ]] || continue
      if grep -qE '^[[:space:]]*default[[:space:]]+' "$f"; then
        sed -ri 's/^[[:space:]]*default[[:space:]]+.*/default auto/' "$f" || true
      else
        printf '\ndefault auto\n' >>"$f"
      fi
    done
  }

  patch_grub_cfg_file() {
    local cfg="$1"
    [[ -f "$cfg" ]] || return 0

    # If we've already injected, keep idempotent
    if grep -q "menuentry 'auto (preseed)'" "$cfg"; then
      return 0
    fi

    # Prepend deterministic defaults (UEFI)
    # Ensure default points to our --id=auto entry.
    # Also hide menu to prevent needing interaction.
    local preamble
    preamble=$(
      cat <<EOF
set default="auto"
set timeout=1
if [ "\${timeout}" = -1 ]; then
  set timeout=1
fi
set timeout_style=hidden

EOF
    )

    # Inject our menuentry near the top (before other menuentries)
    # Paths for Debian netinst are typically /install.amd/vmlinuz and /install.amd/initrd.gz
    local entry
    entry=$(
      cat <<EOF
menuentry 'auto (preseed)' --id=auto {
  linux  /install.amd/vmlinuz ${KARGS} quiet
  initrd /install.amd/initrd.gz
}

EOF
    )

    # Build new config: preamble + entry + original
    {
      echo "$preamble"
      echo "$entry"
      cat "$cfg"
    } >"$cfg.tmp" && mv -f "$cfg.tmp" "$cfg"
  }

  patch_isolinux

  # Patch all common grub.cfg locations (Debian netinst varies by build)
  patch_grub_cfg_file "$cust/boot/grub/grub.cfg"
  patch_grub_cfg_file "$cust/boot/grub/x86_64-efi/grub.cfg"
  patch_grub_cfg_file "$cust/EFI/boot/grub.cfg"
  patch_grub_cfg_file "$cust/EFI/BOOT/grub.cfg"

  # ---------------------------------------------------------------------------
  # Determine EFI image if present
  # ---------------------------------------------------------------------------
  local efi_img=""
  [[ -f "$cust/boot/grub/efi.img" ]] && efi_img="boot/grub/efi.img"
  [[ -z "$efi_img" && -f "$cust/efi.img" ]] && efi_img="efi.img"

  # ---------------------------------------------------------------------------
  # Produce ISO
  # ---------------------------------------------------------------------------
  log "Producing ISO => $iso_out"

  if [[ -f "$cust/isolinux/isolinux.bin" && -f /usr/share/syslinux/isohdpfx.bin ]]; then
    xorriso -as mkisofs \
      -o "$iso_out" \
      -r -J -joliet-long -l \
      -isohybrid-mbr /usr/share/syslinux/isohdpfx.bin \
      -b isolinux/isolinux.bin \
      -c isolinux/boot.cat \
      -no-emul-boot -boot-load-size 4 -boot-info-table \
      ${efi_img:+-eltorito-alt-boot -e "$efi_img" -no-emul-boot -isohybrid-gpt-basdat} \
      "$cust"
  else
    [[ -n "$efi_img" ]] || die "UEFI image not found inside ISO tree"
    xorriso -as mkisofs \
      -o "$iso_out" \
      -r -J -joliet-long -l \
      -eltorito-alt-boot -e "$efi_img" -no-emul-boot -isohybrid-gpt-basdat \
      "$cust"
  fi

  [[ -s "$iso_out" ]] || die "ISO build failed: $iso_out"
}

# -----------------------------------------------------------------------------
# Salt tree emitter (minimal baseline; extend for wg/k8s)
# -----------------------------------------------------------------------------
emit_salt_tree_master() {
  local outdir="$1"
  mkdir -p "$outdir/salt" "$outdir/pillar" "$outdir/salt/role"

  cat >"$outdir/salt/top.sls" <<'EOF'
base:
  '*':
    - base
  'G@role:master':
    - role.master
  'G@role:prom':
    - role.prom
  'G@role:graf':
    - role.graf
  'G@role:storage':
    - role.storage
  'G@role:etcd':
    - role.etcd
  'G@role:cp':
    - role.cp
  'G@role:worker':
    - role.worker
  'G@role:lb':
    - role.lb
  'G@role:ci':
    - role.ci
EOF

  cat >"$outdir/salt/base.sls" <<'EOF'
base-packages:
  pkg.installed:
    - pkgs:
      - ca-certificates
      - curl
      - wget
      - sudo
      - jq
      - rsync
      - vim
      - nftables
      - chrony
      - openssh-server
      - qemu-guest-agent

chrony:
  service.running:
    - enable: True
    - name: chrony

ssh:
  service.running:
    - enable: True
    - name: ssh

qga:
  service.running:
    - enable: True
    - name: qemu-guest-agent
EOF

  cat >"$outdir/salt/role/master.sls" <<'EOF'
master-placeholder:
  test.nop:
    - name: "master role applied"
EOF

  for r in prom graf storage etcd cp worker lb ci; do
    cat >"$outdir/salt/role/${r}.sls" <<EOF
${r}-placeholder:
  test.nop:
    - name: "${r} role applied"
EOF
  done

  cat >"$outdir/pillar/top.sls" <<'EOF'
base:
  '*':
    - cluster
EOF

  cat >"$outdir/pillar/cluster.sls" <<EOF
cluster:
  domain: ${DOMAIN}
  master_lan: ${MASTER_LAN}
  wg:
    wg1: { net: ${WG1_NET}, ip: ${WG1_IP}, port: ${WG1_PORT} }
    wg2: { net: ${WG2_NET}, ip: ${WG2_IP}, port: ${WG2_PORT} }
    wg3: { net: ${WG3_NET}, ip: ${WG3_IP}, port: ${WG3_PORT} }
  wg_allowed_cidr: "${WG_ALLOWED_CIDR}"
EOF
}

# -----------------------------------------------------------------------------
# Postinstall scripts
# -----------------------------------------------------------------------------
emit_postinstall_master() {
  local out="$1"
  cat >"$out" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
LOG="/var/log/postinstall-master.log"
exec > >(tee -a "$LOG") 2>&1
trap 'echo "[X] Failed at line $LINENO" >&2' ERR

MASTER_LAN="__MASTER_LAN__"
ADMIN_USER="__ADMIN_USER__"
SSH_PUBKEY="__SSH_PUBKEY__"

install_base() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y || true
  apt-get install -y --no-install-recommends \
    ca-certificates curl wget gnupg jq rsync sudo vim \
    openssh-server nftables chrony qemu-guest-agent \
    salt-master salt-minion salt-common || true
  systemctl enable --now ssh chrony qemu-guest-agent || true
}

setup_admin() {
  id -u "$ADMIN_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$ADMIN_USER"
  install -d -m700 -o "$ADMIN_USER" -g "$ADMIN_USER" "/home/$ADMIN_USER/.ssh"
  touch "/home/$ADMIN_USER/.ssh/authorized_keys"
  chmod 600 "/home/$ADMIN_USER/.ssh/authorized_keys"
  chown -R "$ADMIN_USER:$ADMIN_USER" "/home/$ADMIN_USER/.ssh"
  if [[ -n "$SSH_PUBKEY" ]] && ! grep -qxF "$SSH_PUBKEY" "/home/$ADMIN_USER/.ssh/authorized_keys"; then
    echo "$SSH_PUBKEY" >> "/home/$ADMIN_USER/.ssh/authorized_keys"
  fi
  printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$ADMIN_USER" >/etc/sudoers.d/90-"$ADMIN_USER"
  chmod 0440 /etc/sudoers.d/90-"$ADMIN_USER"
}

setup_salt_master() {
  install -d -m0755 /etc/salt/master.d /etc/salt/minion.d

  cat >/etc/salt/master.d/roots.conf <<'EOF_SALT'
file_roots:
  base:
    - /srv/salt
pillar_roots:
  base:
    - /srv/pillar
EOF_SALT

  cat >/etc/salt/master.d/autoaccept.conf <<'EOF_SALT'
auto_accept: True
EOF_SALT

  cat >/etc/salt/master.d/network.conf <<'EOF_SALT'
interface: 0.0.0.0
ipv6: False
publish_port: 4505
ret_port: 4506
EOF_SALT

  cat >/etc/salt/minion.d/master.conf <<EOF_MIN
master: ${MASTER_LAN}
id: master
ipv6: False
grains:
  role: master
EOF_MIN

  systemctl enable --now salt-master salt-minion || true
}

stage_salt_tree() {
  if [[ -d /root/darksite/salt && -d /root/darksite/pillar ]]; then
    mkdir -p /srv/salt /srv/pillar
    rsync -a /root/darksite/salt/ /srv/salt/
    rsync -a /root/darksite/pillar/ /srv/pillar/
    systemctl restart salt-master 2>/dev/null || true
  fi
}

setup_firewall() {
  cat >/etc/nftables.conf <<'EOF_NFT'
flush ruleset
table inet filter {
  chain input {
    type filter hook input priority 0; policy drop;
    ct state established,related accept
    iif lo accept
    ip protocol icmp accept
    tcp dport 22 accept
    tcp dport {4505,4506} accept
  }
  chain output { type filter hook output priority 0; policy accept; }
}
EOF_NFT
  systemctl enable --now nftables || true
  nft -f /etc/nftables.conf || true
}

main() {
  install_base
  setup_admin
  setup_salt_master
  stage_salt_tree
  setup_firewall

  touch /root/.bootstrap_done
  systemctl disable bootstrap.service || true
  (sleep 2; systemctl --no-block poweroff) & disown
}
main
EOF

  sed -i \
    -e "s|__MASTER_LAN__|${MASTER_LAN}|g" \
    -e "s|__ADMIN_USER__|${ADMIN_USER}|g" \
    -e "s|__SSH_PUBKEY__|${SSH_PUBKEY//|/\\|}|g" \
    "$out"
}

emit_postinstall_minion() {
  local out="$1" role="$2" lan_ip="$3" wg1_wanted="$4" wg2_wanted="$5" wg3_wanted="$6"

  cat >"$out" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
LOG="/var/log/postinstall-minion.log"
exec > >(tee -a "$LOG") 2>&1
trap 'echo "[X] Failed at line $LINENO" >&2' ERR

ROLE="__ROLE__"
MASTER_LAN="__MASTER_LAN__"
ADMIN_USER="__ADMIN_USER__"
SSH_PUBKEY="__SSH_PUBKEY__"
LAN_IP="__LAN_IP__"
WG1_WANTED="__WG1_WANTED__"
WG2_WANTED="__WG2_WANTED__"
WG3_WANTED="__WG3_WANTED__"

install_base() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y || true
  apt-get install -y --no-install-recommends \
    ca-certificates curl wget gnupg jq rsync sudo vim \
    openssh-server nftables chrony qemu-guest-agent \
    salt-minion salt-common prometheus-node-exporter || true
  systemctl enable --now ssh chrony qemu-guest-agent || true
}

setup_admin() {
  id -u "$ADMIN_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$ADMIN_USER"
  install -d -m700 -o "$ADMIN_USER" -g "$ADMIN_USER" "/home/$ADMIN_USER/.ssh"
  touch "/home/$ADMIN_USER/.ssh/authorized_keys"
  chmod 600 "/home/$ADMIN_USER/.ssh/authorized_keys"
  chown -R "$ADMIN_USER:$ADMIN_USER" "/home/$ADMIN_USER/.ssh"
  if [[ -n "$SSH_PUBKEY" ]] && ! grep -qxF "$SSH_PUBKEY" "/home/$ADMIN_USER/.ssh/authorized_keys"; then
    echo "$SSH_PUBKEY" >> "/home/$ADMIN_USER/.ssh/authorized_keys"
  fi
  printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$ADMIN_USER" >/etc/sudoers.d/90-"$ADMIN_USER"
  chmod 0440 /etc/sudoers.d/90-"$ADMIN_USER"
}

setup_salt_minion() {
  install -d -m0755 /etc/salt/minion.d

  cat >/etc/salt/minion.d/master.conf <<EOF_MIN
master: ${MASTER_LAN}
ipv6: False
EOF_MIN

  cat >/etc/salt/minion.d/grains.conf <<EOF_MIN
grains:
  role: ${ROLE}
  lan_ip: ${LAN_IP}
  wg1_wanted: ${WG1_WANTED}
  wg2_wanted: ${WG2_WANTED}
  wg3_wanted: ${WG3_WANTED}
EOF_MIN

  systemctl enable --now salt-minion || true
}

setup_firewall() {
  cat >/etc/nftables.conf <<'EOF_NFT'
flush ruleset
table inet filter {
  chain input {
    type filter hook input priority 0; policy drop;
    ct state established,related accept
    iif lo accept
    ip protocol icmp accept
    tcp dport 22 accept
  }
  chain output { type filter hook output priority 0; policy accept; }
}
EOF_NFT
  systemctl enable --now nftables || true
  nft -f /etc/nftables.conf || true
}

main() {
  install_base
  setup_admin
  setup_salt_minion
  setup_firewall
  touch /root/.bootstrap_done
  systemctl disable bootstrap.service || true
  (sleep 2; systemctl --no-block poweroff) & disown
}
main
EOF

  sed -i \
    -e "s|__ROLE__|${role}|g" \
    -e "s|__MASTER_LAN__|${MASTER_LAN}|g" \
    -e "s|__ADMIN_USER__|${ADMIN_USER}|g" \
    -e "s|__SSH_PUBKEY__|${SSH_PUBKEY//|/\\|}|g" \
    -e "s|__LAN_IP__|${lan_ip}|g" \
    -e "s|__WG1_WANTED__|${wg1_wanted}|g" \
    -e "s|__WG2_WANTED__|${wg2_wanted}|g" \
    -e "s|__WG3_WANTED__|${wg3_wanted}|g" \
    "$out"
}

# -----------------------------------------------------------------------------
# Plan builder
# -----------------------------------------------------------------------------
plan_nodes() {
  local lan_i vmid_i
  lan_i="$(ip2int "$LAN_START_IP")"
  vmid_i="$VMID_START"

  local idx=0
  local -a roles=()
  local r

  for r in prom graf storage etcd cp worker lb ci; do
    local cnt_var="${r^^}_COUNT"
    local cnt="${!cnt_var:-0}"
    for ((n=1; n<=cnt; n++)); do roles+=("$r"); done
  done

  [[ "${#roles[@]}" -gt 0 ]] || warn "No minions requested."

  for r in "${roles[@]}"; do
    idx=$((idx+1))
    local name="${r}-${idx}"

    local lan_ip; lan_ip="$(int2ip "$lan_i")"; lan_i=$((lan_i+1))

    local wg1 wg2 wg3
    wg1="$(wg16_ip_for_index "10.78.0.0" "$idx")"
    wg2="$(wg16_ip_for_index "10.79.0.0" "$idx")"
    wg3="$(wg16_ip_for_index "10.80.0.0" "$idx")"

    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
      "$r" "$name" "$vmid_i" "$lan_ip" "$wg1" "$wg2" "$wg3"

    vmid_i=$((vmid_i+1))
  done
}

# -----------------------------------------------------------------------------
# Build master ISO
# -----------------------------------------------------------------------------
build_master_iso() {
  log "Building master ISO"
  local tmpdir="$BUILD_ROOT/master_payload"
  rm -rf "$tmpdir" || true
  mkdir -p "$tmpdir"

  emit_salt_tree_master "$tmpdir/saltroot"
  local post="$tmpdir/postinstall-master.sh"
  emit_postinstall_master "$post"

  local combo="$tmpdir/darksite_combo"
  mkdir -p "$combo"
  if [[ -n "${DARKSITE_SRC}" && -d "${DARKSITE_SRC}" ]]; then
    rsync -a --delete "${DARKSITE_SRC}/" "$combo/"
  fi
  mkdir -p "$combo/salt" "$combo/pillar"
  rsync -a "$tmpdir/saltroot/salt/" "$combo/salt/"
  rsync -a "$tmpdir/saltroot/pillar/" "$combo/pillar/"

  local master_iso="$BUILD_ROOT/master.iso"
  local old_dark="${DARKSITE_SRC:-}"
  DARKSITE_SRC="$combo" mk_iso "master" "$post" "$master_iso" "$MASTER_LAN"
  DARKSITE_SRC="$old_dark"

  say "$master_iso"
}

# -----------------------------------------------------------------------------
# Build minion ISO
# -----------------------------------------------------------------------------
build_minion_iso() {
  local role="$1" name="$2" lan_ip="$3" wg1="$4" wg2="$5" wg3="$6"

  local tmp="$BUILD_ROOT/minion-$name"
  rm -rf "$tmp" || true
  mkdir -p "$tmp"

  local post="$tmp/postinstall-minion.sh"
  emit_postinstall_minion "$post" "$role" "$lan_ip" "$wg1" "$wg2" "$wg3"

  local combo="$tmp/darksite_combo"
  mkdir -p "$combo"
  if [[ -n "${DARKSITE_SRC}" && -d "${DARKSITE_SRC}" ]]; then
    rsync -a --delete "${DARKSITE_SRC}/" "$combo/"
  fi

  local iso="$BUILD_ROOT/${name}.iso"
  local old_dark="${DARKSITE_SRC:-}"
  DARKSITE_SRC="$combo" mk_iso "$name" "$post" "$iso" "$lan_ip"
  DARKSITE_SRC="$old_dark"

  say "$iso"
}

# -----------------------------------------------------------------------------
# Deploy master
# -----------------------------------------------------------------------------
proxmox_master() {
  local master_iso
  master_iso="$(build_master_iso)"
  [[ -f "$master_iso" ]] || die "Master ISO not found: $master_iso"

  log "Deploying master VMID=$MASTER_ID IP=$MASTER_LAN"
  pmx_deploy "$MASTER_ID" "$MASTER_NAME" "$master_iso" "$MASTER_MEM" "$MASTER_CORES" "$MASTER_DISK_GB"

  wait_poweroff "$MASTER_ID" 2400
  boot_from_disk "$MASTER_ID"
  wait_poweroff "$MASTER_ID" 2400

  pmx "qm start $MASTER_ID"
  pmx_wait_for_state "$MASTER_ID" "running" 600

  log "Master running. Waiting for SSH on LAN (${ADMIN_USER}@${MASTER_LAN})..."
  if wait_ssh_ready "${ADMIN_USER}@${MASTER_LAN}" "$MASTER_SSH_IDENTITY_FILE" 120 2; then
    log "Master SSH is ready."
  else
    warn "Master SSH not ready yet; continue anyway."
  fi
}

# -----------------------------------------------------------------------------
# Deploy minions
# -----------------------------------------------------------------------------
proxmox_minions() {
  log "Building minions from role counts: prom=$PROM_COUNT graf=$GRAF_COUNT storage=$STORAGE_COUNT etcd=$ETCD_COUNT cp=$CP_COUNT worker=$WORKER_COUNT lb=$LB_COUNT ci=$CI_COUNT"
  log "LAN_START_IP=$LAN_START_IP VMID_START=$VMID_START"

  local plan="$BUILD_ROOT/plan.tsv"
  plan_nodes >"$plan"
  log "Plan: $plan"
  head -n 20 "$plan" | sed 's/^/[PLAN] /' >&2 || true

  while IFS=$'\t' read -r role name vmid lan_ip wg1 wg2 wg3; do
    log "Deploying $name role=$role vmid=$vmid ip=$lan_ip"
    local iso
    iso="$(build_minion_iso "$role" "$name" "$lan_ip" "$wg1" "$wg2" "$wg3")"
    pmx_deploy "$vmid" "$name" "$iso" "$MINION_MEM" "$MINION_CORES" "$MINION_DISK_GB"

    wait_poweroff "$vmid" 2400
    boot_from_disk "$vmid"
    wait_poweroff "$vmid" 2400

    pmx "qm start $vmid"
    pmx_wait_for_state "$vmid" "running" 600
  done <"$plan"
}

# -----------------------------------------------------------------------------
# Converge from master
# -----------------------------------------------------------------------------
converge_master() {
  log "Triggering Salt converge from master (LAN best-effort)"
  if ! wait_ssh_ready "${ADMIN_USER}@${MASTER_LAN}" "$MASTER_SSH_IDENTITY_FILE" 90 2; then
    warn "SSH not ready to master; skipping converge."
    return 0
  fi

  mst_ssh "${ADMIN_USER}@${MASTER_LAN}" "sudo salt '*' test.ping --timeout=10 || true" || true
  mst_ssh "${ADMIN_USER}@${MASTER_LAN}" "sudo salt '*' state.highstate --timeout=120 || true" || true
  log "Converge complete."
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  log "TARGET=$TARGET PROXMOX_HOST=$PROXMOX_HOST"
  [[ -r "$ISO_ORIG" ]] || die "ISO_ORIG not readable: $ISO_ORIG"

  case "$TARGET" in
    proxmox-master)
      proxmox_master
      ;;
    proxmox-minions)
      proxmox_minions
      converge_master
      ;;
    proxmox-all|proxmox-all*)
      proxmox_master
      proxmox_minions
      converge_master
      ;;
    *)
      die "Unknown TARGET=$TARGET"
      ;;
  esac

  log "Done."
}

main


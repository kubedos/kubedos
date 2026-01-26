#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="${LOG_FILE:-/root/install.txt}"
exec &> >(tee -a "$LOG_FILE")

log() { echo "[INFO]  $(date '+%F %T') - $*"; }
warn(){ echo "[WARN]  $(date '+%F %T') - $*" >&2; }
err() { echo "[ERROR] $(date '+%F %T') - $*" >&2; }
die() { err "$*"; exit 1; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

# === CONFIGURATION (env overrides) ===
ISO_ORIG="${ISO_ORIG:-/root/debian-13.2.0-amd64-DVD-1.iso}"

BUILD_DIR="${BUILD_DIR:-/root/debian-iso}"
CUSTOM_DIR="$BUILD_DIR/custom"
MOUNT_DIR="$BUILD_DIR/mnt"
EFI_MNT="$BUILD_DIR/efi-mnt"

DARKSITE_DIR="$CUSTOM_DIR/darksite"
PRESEED_FILE="${PRESEED_FILE:-preseed.cfg}"

OUTPUT_ISO="$BUILD_DIR/out.iso"
FINAL_ISO="${FINAL_ISO:-/root/master.iso}"

# Identity & creds (override via env)
HOSTNAME="${HOSTNAME:-debian}"
DOMAIN="${DOMAIN:-lan.xaeon.io}"
TIMEZONE="${TIMEZONE:-America/Vancouver}"
LOCALE="${LOCALE:-en_US.UTF-8}"
KEYMAP="${KEYMAP:-us}"

# User/password config
# NOTE: This matches your original approach (plaintext). You can replace with hashes later.
ROOT_LOGIN="${ROOT_LOGIN:-false}"                 # false = no direct root login
ROOT_PASSWORD="${ROOT_PASSWORD:-root}"            # used if ROOT_LOGIN=true
USERNAME="${USERNAME:-debian}"
USER_FULLNAME="${USER_FULLNAME:-Debian User}"
USER_PASSWORD="${USER_PASSWORD:-debian}"

# Task selection
TASKS="${TASKS:-standard, ssh-server}"

# Syslinux MBR path varies by distro/container
ISOHYBRID_MBR="${ISOHYBRID_MBR:-}"
if [[ -z "$ISOHYBRID_MBR" ]]; then
  for p in /usr/share/syslinux/isohdpfx.bin /usr/lib/ISOLINUX/isohdpfx.bin /usr/lib/syslinux/bios/isohdpfx.bin; do
    [[ -f "$p" ]] && ISOHYBRID_MBR="$p" && break
  done
fi

# Tools we need
require_cmd xorriso
require_cmd mount
require_cmd umount
require_cmd sed
require_cmd awk
require_cmd grep
require_cmd find
require_cmd md5sum
require_cmd rsync

# ------------------------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------------------------
log "Cleaning up..."
umount "$MOUNT_DIR" 2>/dev/null || true
umount "$EFI_MNT" 2>/dev/null || true
rm -rf "$BUILD_DIR"
mkdir -p "$CUSTOM_DIR" "$MOUNT_DIR" "$EFI_MNT" "$DARKSITE_DIR"

# ------------------------------------------------------------------------------
# Copy ISO contents (include dotfiles)
# ------------------------------------------------------------------------------
log "Mounting ISO: $ISO_ORIG"
mount -o loop,ro "$ISO_ORIG" "$MOUNT_DIR" || die "Failed to mount ISO"

log "Copying ISO contents (preserving dotfiles)..."
# Use rsync so we never miss hidden files beyond .disk
rsync -aH --delete "$MOUNT_DIR"/ "$CUSTOM_DIR"/
umount "$MOUNT_DIR"

# ------------------------------------------------------------------------------
# Write postinstall + bootstrap
# ------------------------------------------------------------------------------
log "Writing darksite/postinstall.sh..."
cat > "$DARKSITE_DIR/postinstall.sh" <<'EOSCRIPT'
#!/usr/bin/env bash
set -euxo pipefail

LOGFILE="/var/log/postinstall.log"
exec > >(tee -a "$LOGFILE") 2>&1
trap 'echo "[✖] Postinstall failed on line $LINENO" >&2; exit 1' ERR
log(){ echo "[INFO] $(date '+%F %T') — $*"; }

log "Starting postinstall setup..."

remove_cd_sources() { sed -i '/cdrom:/d' /etc/apt/sources.list || true; }

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y \
    ca-certificates curl cloud-init gnupg lsb-release apt-transport-https software-properties-common \
    openssh-server sudo

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/debian $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  systemctl enable docker
  systemctl start docker

  mkdir -p /etc/docker
  cat > /etc/docker/daemon.json <<EOF
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "100m", "max-file": "3" },
  "storage-driver": "overlay2"
}
EOF
  systemctl restart docker || true

  docker swarm init || true
  docker pull alpine || true
  docker pull nginx || true
  docker service create --name web --replicas 2 -p 80:80 nginx || true

  docker info || true
  docker service ls || true
  log "Docker installed and started."
}

harden_ssh() {
  mkdir -p /etc/ssh/sshd_config.d/
  cat > /etc/ssh/sshd_config.d/hardening.conf <<EOF
PasswordAuthentication no
PermitRootLogin no
EOF
  systemctl restart ssh || true
}

create_user() {
  local user="$1"
  local ssh_key="$2"

  if ! id "$user" &>/dev/null; then
    adduser --disabled-password --gecos "" "$user"
    echo "$user ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/"$user"
    chmod 0440 /etc/sudoers.d/"$user"
  fi

  mkdir -p /home/"$user"/.ssh
  printf '%s\n' "$ssh_key" > /home/"$user"/.ssh/authorized_keys
  chmod 700 /home/"$user"/.ssh
  chmod 600 /home/"$user"/.ssh/authorized_keys
  chown -R "$user:$user" /home/"$user"/.ssh
}

create_users() {
  create_user "ansible" "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDQxCqOqlNPjv/ZkIkAs8yhhx9EVOEsQUDx80Auhvn8U ansible"
  create_user "debian"  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOULOqaBuNbkIro5ichg58TELDGD0f9H8AkPh9xph+VR debian@semaphore-BHS-VMH-2"
}

reset_cloud_init() {
  cloud-init clean --logs || true
  rm -rf /var/lib/cloud/ || true
}

regenerate_identity() {
  truncate -s 0 /etc/machine-id || true
  rm -f /var/lib/dbus/machine-id || true
  ln -sf /etc/machine-id /var/lib/dbus/machine-id || true
  rm -f /etc/ssh/ssh_host_* || true
}

self_destruct() {
  systemctl disable bootstrap.service || true
  rm -f /etc/systemd/system/bootstrap.service || true
  systemctl daemon-reload || true
}

remove_cd_sources
install_packages
harden_ssh
create_users
reset_cloud_init
regenerate_identity
self_destruct

log "[✔] Postinstall complete — powering off..."
poweroff
EOSCRIPT
chmod +x "$DARKSITE_DIR/postinstall.sh"

log "Writing darksite/bootstrap.service..."
cat > "$DARKSITE_DIR/bootstrap.service" <<'EOF'
[Unit]
Description=Initial Bootstrap Script
After=network.target
Wants=network.target

[Service]
Type=oneshot
ExecStart=/root/darksite/postinstall.sh
RemainAfterExit=false
TimeoutStartSec=900
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# ------------------------------------------------------------------------------
# Preseed (NVMe-first + NO netcfg during install)
# ------------------------------------------------------------------------------
log "Writing ${PRESEED_FILE} (NVMe-first, skip Wi-Fi by disabling netcfg)..."
cat > "$CUSTOM_DIR/$PRESEED_FILE" <<EOF
# Force full automation
d-i debconf/frontend select Noninteractive
d-i debconf/priority string critical

# Localization
d-i debian-installer/locale string ${LOCALE}
d-i console-setup/ask_detect boolean false
d-i keyboard-configuration/xkb-keymap select ${KEYMAP}

# Disable network configuration entirely during install (prevents Wi-Fi prompts)
d-i netcfg/enable boolean false

# Hostname/domain (still set these)
d-i netcfg/get_hostname string ${HOSTNAME}
d-i netcfg/get_domain string ${DOMAIN}

# APT: DVD-only
d-i apt-setup/use_mirror boolean false
d-i apt-cdrom-setup/another boolean false
d-i apt-setup/non-free boolean true
d-i apt-setup/contrib boolean true

# Users
d-i passwd/root-login boolean ${ROOT_LOGIN}
d-i passwd/make-user boolean true
d-i passwd/username string ${USERNAME}
d-i passwd/user-fullname string ${USER_FULLNAME}
d-i passwd/user-password password ${USER_PASSWORD}
d-i passwd/user-password-again password ${USER_PASSWORD}
d-i passwd/root-password password ${ROOT_PASSWORD}
d-i passwd/root-password-again password ${ROOT_PASSWORD}

# Time
d-i time/zone string ${TIMEZONE}
d-i clock-setup/utc boolean true
d-i clock-setup/ntp boolean true

# Disk: NVMe-first
d-i partman/early_command string \\
  DISK=""; \\
  if [ -b /dev/nvme0n1 ]; then DISK="/dev/nvme0n1"; \\
  else DISK="\$(ls -1 /dev/nvme*n1 2>/dev/null | head -n1 || true)"; fi; \\
  if [ -z "\$DISK" ]; then DISK="\$(list-devices disk | head -n1)"; fi; \\
  echo "Using install disk: \$DISK"; \\
  debconf-set partman-auto/disk "\$DISK"; \\
  debconf-set grub-installer/bootdev "\$DISK"

# Partitioning (LVM atomic)
d-i partman-auto/method string lvm
d-i partman-lvm/device_remove_lvm boolean true
d-i partman-auto/choose_recipe select atomic
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true
d-i partman/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman-lvm/confirm boolean true
d-i partman-lvm/confirm_nooverwrite boolean true
d-i partman-lvm/confirm_write_new_label boolean true
d-i partman-auto-lvm/guided_size string max

# Tasks
tasksel tasksel/first multiselect ${TASKS}
popularity-contest popularity-contest/participate boolean false

# GRUB
d-i grub-installer/only_debian boolean true

# Late command: seed darksite + enable bootstrap.service
d-i preseed/late_command string \\
  set -e; \\
  cp -a /cdrom/darksite /target/root/; \\
  in-target chmod +x /root/darksite/postinstall.sh; \\
  in-target cp /root/darksite/bootstrap.service /etc/systemd/system/bootstrap.service; \\
  in-target systemctl daemon-reload; \\
  in-target systemctl enable bootstrap.service; \\
  true

# Power off at end
d-i debian-installer/exit/poweroff boolean true
d-i cdrom-detect/eject boolean true
d-i finish-install/exit-installer boolean true
EOF

# ------------------------------------------------------------------------------
# Bootloader injection: BIOS (isolinux) + UEFI (grub.cfg + efi.img)
# ------------------------------------------------------------------------------
KARGS="auto=true priority=critical vga=788 preseed/file=/cdrom/${PRESEED_FILE} ---"

inject_isolinux() {
  local txt="$CUSTOM_DIR/isolinux/txt.cfg"
  local cfg="$CUSTOM_DIR/isolinux/isolinux.cfg"
  [[ -f "$txt" ]] || return 0

  if ! grep -qE '^label[[:space:]]+auto$' "$txt"; then
    cat >>"$txt" <<EOF

label auto
  menu label ^KubeOS auto (no-touch)
  kernel /install.amd/vmlinuz
  append initrd=/install.amd/initrd.gz ${KARGS}
EOF
  fi

  [[ -f "$cfg" ]] && sed -i 's/^default .*/default auto/' "$cfg" || true
}

grub_menu_block() {
  cat <<EOF
### --- KubeOS injected entry (do not edit above) ---
set default="kubedos_auto"
set timeout=1

menuentry "KubeOS auto (no-touch)" --id kubedos_auto {
    linux /install.amd/vmlinuz ${KARGS}
    initrd /install.amd/initrd.gz
}
### --- End KubeOS injected entry ---
EOF
}

inject_grub_cfg_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0

  # If already injected, do nothing
  if grep -q 'KubeOS injected entry' "$f"; then
    return 0
  fi

  # Prepend our block to top of file to ensure entry exists and default applies
  local tmp
  tmp="$(mktemp)"
  grub_menu_block > "$tmp"
  cat "$f" >> "$tmp"
  mv "$tmp" "$f"
}

inject_uefi_grub_tree() {
  # Patch common grub.cfg locations in the ISO filesystem
  local f
  for f in \
    "$CUSTOM_DIR/boot/grub/grub.cfg" \
    "$CUSTOM_DIR/boot/grub/x86_64-efi/grub.cfg" \
    "$CUSTOM_DIR/EFI/BOOT/grub.cfg" \
    "$CUSTOM_DIR/boot/grub/loopback.cfg"
  do
    inject_grub_cfg_file "$f"
  done
}

inject_efi_img() {
  local img="$CUSTOM_DIR/boot/grub/efi.img"
  [[ -f "$img" ]] || return 0

  umount "$EFI_MNT" 2>/dev/null || true
  mount -o loop,rw "$img" "$EFI_MNT" || { warn "Could not mount efi.img for patching"; return 0; }

  # Patch the grub.cfg inside the EFI image (this is the critical UEFI path)
  local f
  for f in "$EFI_MNT/EFI/BOOT/grub.cfg" "$EFI_MNT/EFI/debian/grub.cfg"; do
    inject_grub_cfg_file "$f"
  done

  sync || true
  umount "$EFI_MNT" || true
}

log "Injecting BIOS isolinux entry..."
inject_isolinux

log "Injecting UEFI GRUB entry in ISO tree..."
inject_uefi_grub_tree

log "Injecting UEFI GRUB entry inside efi.img..."
inject_efi_img

# ------------------------------------------------------------------------------
# Regenerate md5sum.txt (helps media verification)
# ------------------------------------------------------------------------------
if [[ -f "$CUSTOM_DIR/md5sum.txt" ]]; then
  log "Regenerating md5sum.txt..."
  ( cd "$CUSTOM_DIR"
    find . -type f ! -name 'md5sum.txt' ! -name 'boot.cat' -print0 \
      | sort -z \
      | xargs -0 md5sum > md5sum.txt
  )
fi

# ------------------------------------------------------------------------------
# Rebuild ISO (BIOS+UEFI hybrid)
# ------------------------------------------------------------------------------
log "Rebuilding ISO..."
EFI_ELTORITO="boot/grub/efi.img"
[[ -f "$CUSTOM_DIR/$EFI_ELTORITO" ]] || die "EFI image not found at $CUSTOM_DIR/$EFI_ELTORITO"

XORR_ARGS=(
  -o "$OUTPUT_ISO"
  -r -J -joliet-long -l
  -V "KUBEOS_MASTER"
  -b isolinux/isolinux.bin
  -c isolinux/boot.cat
  -no-emul-boot -boot-load-size 4 -boot-info-table
  -eltorito-alt-boot
  -e "$EFI_ELTORITO"
  -no-emul-boot
  -isohybrid-gpt-basdat
  -partition_offset 16
  "$CUSTOM_DIR"
)

if [[ -n "$ISOHYBRID_MBR" && -f "$ISOHYBRID_MBR" ]]; then
  XORR_ARGS=( -isohybrid-mbr "$ISOHYBRID_MBR" "${XORR_ARGS[@]}" )
else
  warn "isohdpfx.bin not found; BIOS hybrid may be impacted (UEFI should still work)"
fi

xorriso -as mkisofs "${XORR_ARGS[@]}"

mv -f "$OUTPUT_ISO" "$FINAL_ISO"
log "ISO ready at: $FINAL_ISO"


#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 022

# ============================================================
# CLUSTER HEALTH / INSTALL SUPPORT BUNDLE
# - Final bundle is scp'd as todd to 10.100.10.150:incoming/
# ============================================================

DEST_USER="${DEST_USER:-todd}"
DEST_HOST="${DEST_HOST:-10.100.10.150}"
DEST_DIR="${DEST_DIR:-incoming}"        # relative to remote user's home unless absolute
OUTDIR="${OUTDIR:-/home/todd/triage-out}"

# Collection tuning
COLLECT_JOURNAL_LINES="${COLLECT_JOURNAL_LINES:-2500}"
COLLECT_ALL_JOURNAL_LINES="${COLLECT_ALL_JOURNAL_LINES:-8000}"
COLLECT_DMESG_LINES="${COLLECT_DMESG_LINES:-400}"
VARLOG_MAX_MB="${VARLOG_MAX_MB:-20}"          # pack "small files" from /var/log up to this size per file
LARGEST_LOGS="${LARGEST_LOGS:-60}"

# Salt behavior
MINION_LIST_OVERRIDE="${MINION_LIST_OVERRIDE:-}"  # space-separated explicit minions, if set
ENSURE_FILE_RECV="${ENSURE_FILE_RECV:-1}"         # 1=ensure file_recv True for cp.push
ENSURE_TODD_MINION_SSH="${ENSURE_TODD_MINION_SSH:-1}" # 1=ensure todd pubkey on minions (idempotent)

SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5)

TS="$(date +%F_%H%M%S)"
MASTER_FQDN="$(hostname -f 2>/dev/null || hostname)"
BASENAME="cluster-health-install-support-${TS}"
WORKROOT="/tmp/${BASENAME}"
META="${WORKROOT}/meta"
SALT_DIR="${WORKROOT}/salt"
NODES_DIR="${WORKROOT}/nodes"
LOG="${META}/run.log"

# ---- helpers ----
mkdir -p "$META" "$SALT_DIR" "$NODES_DIR"
exec > >(tee -a "$LOG") 2>&1

say() { echo "$*"; }
section() {
  echo
  echo "============================================================"
  echo "$*"
  echo "============================================================"
}
run() {
  local desc="$1"; shift
  section "$desc"
  # shellcheck disable=SC2068
  "$@" 2>&1 | sed -u 's/\r$//'
}
have() { command -v "$1" >/dev/null 2>&1; }

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "ERROR: run as root on the master."
    exit 2
  fi
}

ensure_outdir() {
  install -d -m 0755 -o "$DEST_USER" -g "$DEST_USER" "$OUTDIR"
}

pick_minions_from_saltkey() {
  # Parses: salt-key -l acc
  salt-key -l acc 2>/dev/null \
    | awk '
        BEGIN{acc=0}
        /^Accepted Keys:/{acc=1; next}
        acc && NF{print $1}
      ' \
    | sed '/^\s*$/d' \
    | sort -u
}

salt_minion_csv() {
  local list=("$@")
  local csv=""
  local i
  for i in "${list[@]}"; do
    if [[ -z "$csv" ]]; then csv="$i"; else csv="${csv},${i}"; fi
  done
  echo "$csv"
}

# ---- banner ----
require_root
section "CLUSTER HEALTH/INSTALL SUPPORT BUNDLE"
say "START:   $(date)"
say "MASTER:  ${MASTER_FQDN} (local collection; not a salt minion)"
say "WORKROOT:${WORKROOT}"
say "DEST:    ${DEST_USER}@${DEST_HOST}:${DEST_DIR}/"
say "OUTDIR:  ${OUTDIR}"
say "LOG:     ${LOG}"
say "JOURNAL: ${COLLECT_JOURNAL_LINES} (per-unit), ALL=${COLLECT_ALL_JOURNAL_LINES}"
say "VARLOG:  smallfiles <= ${VARLOG_MAX_MB}MB, largest=${LARGEST_LOGS}"
say "KEYS:    ENSURE_TODD_MINION_SSH=${ENSURE_TODD_MINION_SSH}"
say "SALT:    ENSURE_FILE_RECV=${ENSURE_FILE_RECV}"
section "SANITY"
run "whoami" whoami
run "hostname" hostname -f || hostname
run "date" date

# ---- build node collector script (runs locally on any node) ----
NODE_SCRIPT="${WORKROOT}/cluster-node-collect.sh"
cat >"$NODE_SCRIPT" <<'NODE'
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 022

COLLECT_JOURNAL_LINES="${COLLECT_JOURNAL_LINES:-2500}"
COLLECT_ALL_JOURNAL_LINES="${COLLECT_ALL_JOURNAL_LINES:-8000}"
COLLECT_DMESG_LINES="${COLLECT_DMESG_LINES:-400}"
VARLOG_MAX_MB="${VARLOG_MAX_MB:-20}"
LARGEST_LOGS="${LARGEST_LOGS:-60}"

TS="$(date +%F_%H%M%S)"
HOST_FQDN="$(hostname -f 2>/dev/null || hostname)"
BASENAME="node-collect-${HOST_FQDN}-${TS}"
ROOT="/tmp/${BASENAME}"

mkdir -p "$ROOT"/{identity,proc,metrics,network,systemd,logs,k8s,cri,installer,salt,pki}
LOG="$ROOT/identity/collector.log"
exec > >(tee -a "$LOG") 2>&1

section(){ echo; echo "==== $* ===="; }
have(){ command -v "$1" >/dev/null 2>&1; }

section "identity"
{
  echo "date: $(date)"
  echo "host: $HOST_FQDN"
  echo "user: $(id -un) uid=$(id -u)"
  echo "kernel: $(uname -a)"
  echo
  cat /etc/os-release 2>/dev/null || true
  echo
  uptime || true
  echo
  who || true
} >"$ROOT/identity/identity.txt" 2>&1 || true

section "proc snapshots"
for f in stat loadavg uptime meminfo cpuinfo diskstats net/dev; do
  if [[ -r "/proc/$f" ]]; then
    cat "/proc/$f" >"$ROOT/proc/$f.txt" 2>&1 || true
  fi
done

section "metrics"
{
  echo "== df -h =="; df -h || true; echo
  echo "== lsblk =="; lsblk -a -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL 2>/dev/null || lsblk || true; echo
  echo "== free -h =="; free -h || true; echo
  echo "== top (head) =="; (top -b -n1 | head -n 60) 2>/dev/null || true; echo
  echo "== vmstat =="; vmstat 1 5 2>/dev/null || true; echo
  echo "== iostat =="; (have iostat && iostat -xz 1 3) 2>/dev/null || true; echo
  echo "== mpstat =="; (have mpstat && mpstat -P ALL 1 3) 2>/dev/null || true; echo
  echo "== ps (k8s-ish) =="; ps auxww | grep -E '(^USER|etcd|kube-apiserver|kubelet|containerd|cri-o|dockerd)' || true
} >"$ROOT/metrics/system-metrics.txt" 2>&1 || true

section "network"
{
  echo "== ip addr =="; ip addr || true; echo
  echo "== ip route =="; ip route || true; echo
  echo "== ss listen =="; ss -lntup || ss -lntp || true; echo
  echo "== expected ports =="; ss -lntp 2>/dev/null | grep -nE '(:2379|:2380|:6443|:10250|:10257|:10259)\b' || echo "NO expected listeners found"; echo
  echo "== sysctl k8s-ish =="; sysctl -a 2>/dev/null | grep -E 'net\.bridge\.|net\.ipv4\.ip_forward|net\.ipv4\.conf\.all\.rp_filter|net\.ipv4\.conf\.default\.rp_filter|net\.netfilter\.|fs\.inotify|vm\.swappiness|kernel\.pid_max' || true
  echo
  echo "== wireguard =="; (have wg && wg show) 2>/dev/null || true
  echo
  echo "== nftables =="; (have nft && nft list ruleset | sed -n '1,260p') 2>/dev/null || true
} >"$ROOT/network/net.txt" 2>&1 || true

# split common net files
grep -n '' "$ROOT/network/net.txt" >"$ROOT/network/_net-lines.txt" 2>/dev/null || true
# Optional: keep separate files for convenience
(ip addr >"$ROOT/network/ip-addr.txt" 2>/dev/null) || true
(ip route >"$ROOT/network/ip-route.txt" 2>/dev/null) || true
(ss -lntup >"$ROOT/network/ss-listen.txt" 2>/dev/null || ss -lntp >"$ROOT/network/ss-listen.txt" 2>/dev/null) || true
(sysctl -a 2>/dev/null | grep -E 'net\.bridge\.|net\.ipv4\.ip_forward|net\.ipv4\.conf\.all\.rp_filter|net\.ipv4\.conf\.default\.rp_filter|net\.netfilter\.|fs\.inotify|vm\.swappiness|kernel\.pid_max' \
  >"$ROOT/network/sysctl-k8s-filtered.txt") || true
(have nft && nft list ruleset | sed -n '1,260p' >"$ROOT/network/nft-ruleset.txt") || true
(have wg && wg show >"$ROOT/network/wg-show.txt") || true
(ss -lntp 2>/dev/null | grep -nE '(:2379|:2380|:6443|:10250|:10257|:10259)\b' >"$ROOT/network/expected-ports.txt" || echo "NO expected listeners found" >"$ROOT/network/expected-ports.txt") || true

section "systemd"
{
  systemctl --no-pager -l status kubelet containerd etcd 2>&1 || true
  echo
  systemctl --no-pager -l --failed 2>&1 || true
  echo
  systemctl --no-pager -l list-units --type=service --state=running 2>&1 | head -n 200 || true
  echo
  systemctl --no-pager -l list-unit-files 2>&1 | head -n 240 || true
} >"$ROOT/systemd/status-core.txt" 2>&1 || true
(systemctl --no-pager -l --failed >"$ROOT/systemd/failed.txt" 2>&1) || true
(systemctl --no-pager -l list-units --type=service --state=running | head -n 240 >"$ROOT/systemd/running-services.txt" 2>&1) || true
(systemctl --no-pager -l list-unit-files | head -n 400 >"$ROOT/systemd/unit-files.txt" 2>&1) || true

section "logs (journald + dmesg + /var/log)"
# journald (be careful about size)
for u in kubelet containerd etcd nftables "wg-quick@wg0" "bootstrap.service" salt-minion salt-master; do
  journalctl -u "$u" -b --no-pager -n "$COLLECT_JOURNAL_LINES" >"$ROOT/logs/journalctl-${u//[@.]/_}.txt" 2>&1 || true
done
journalctl -b --no-pager -n "$COLLECT_ALL_JOURNAL_LINES" >"$ROOT/logs/journalctl-all.txt" 2>&1 || true
dmesg -T 2>/dev/null | tail -n "$COLLECT_DMESG_LINES" >"$ROOT/logs/dmesg-tail.txt" 2>&1 || true

# /var/log largest list + tar of "small" files
if [[ -d /var/log ]]; then
  find /var/log -type f -printf '%s %p\n' 2>/dev/null | sort -nr | head -n "$LARGEST_LOGS" >"$ROOT/logs/var-log-largest.txt" || true
  # pack only "small" files to avoid massive bundles
  SMALL_TAR="$ROOT/logs/var-log-smallfiles.tgz"
  (cd / && \
    find var/log -type f -size -"${VARLOG_MAX_MB}"M -print 2>/dev/null \
      | tar -czf "$SMALL_TAR" -T - 2>/dev/null) || true
else
  echo "NO /var/log" >"$ROOT/logs/var-log-largest.txt"
fi

section "k8s footprint"
{
  ls -la /etc/kubernetes 2>/dev/null || true
  echo
  ls -la /etc/kubernetes/manifests 2>/dev/null || true
  echo
  test -f /etc/kubernetes/manifests/etcd.yaml && echo "FOUND /etc/kubernetes/manifests/etcd.yaml" || true
  test -f /etc/kubernetes/manifests/kube-apiserver.yaml && echo "FOUND kube-apiserver.yaml" || true
  echo
  ls -la /var/lib/kubelet 2>/dev/null || true
  echo
  test -f /var/lib/kubelet/config.yaml && sed -n '1,260p' /var/lib/kubelet/config.yaml || true
  echo
  cat /var/lib/kubelet/kubeadm-flags.env 2>/dev/null || true
  echo
  cat /etc/default/kubelet 2>/dev/null || true
  echo
  ls -la /etc/containerd 2>/dev/null || true
  test -f /etc/containerd/config.toml && sed -n '1,220p' /etc/containerd/config.toml || true
} >"$ROOT/k8s/kubernetes-footprint.txt" 2>&1 || true

section "PKI (list + cert dates only)"
{
  ls -la /etc/kubernetes/pki /etc/kubernetes/pki/etcd 2>/dev/null || true
  echo
  find /etc/kubernetes/pki -maxdepth 2 -type f \( -name "*.crt" -o -name "*.key" \) -ls 2>/dev/null | head -n 220 || true
  echo
  for c in /etc/kubernetes/pki/etcd/*.crt /etc/kubernetes/pki/*.crt; do
    [[ -f "$c" ]] || continue
    echo "--- $c"
    openssl x509 -noout -subject -issuer -dates -in "$c" 2>/dev/null || true
  done
} >"$ROOT/pki/pki-and-certdates.txt" 2>&1 || true

section "CRI (crictl if present)"
{
  if have crictl; then
    echo "CRICTL_OK"
    crictl info 2>&1 | tail -n 200 || true
    echo
    crictl ps -a 2>/dev/null | head -n 120 || true
    echo
    crictl pods 2>/dev/null | head -n 120 || true
    echo
    crictl images 2>/dev/null | grep -Ei 'etcd|kube-apiserver' || true
    echo
    cid="$(crictl ps -a --name etcd -q 2>/dev/null | head -n 1 || true)"
    if [[ -n "${cid:-}" ]]; then
      echo "ETCD_CID=$cid"
      crictl logs --tail=250 "$cid" 2>/dev/null || true
    else
      echo "NO_ETCD_CONTAINER"
    fi
  else
    echo "NO_CRICTL_ON_NODE"
  fi
} >"$ROOT/cri/crictl.txt" 2>&1 || true

section "installer logs footprint"
{
  echo "== Debian/Ubuntu =="
  test -d /var/log/installer && ls -la /var/log/installer || true
  test -f /var/log/cloud-init.log && tail -n 250 /var/log/cloud-init.log || true
  test -f /var/log/cloud-init-output.log && tail -n 250 /var/log/cloud-init-output.log || true
  test -f /var/log/syslog && tail -n 250 /var/log/syslog || true
  test -f /var/log/apt/history.log && tail -n 220 /var/log/apt/history.log || true
  test -f /var/log/dpkg.log && tail -n 220 /var/log/dpkg.log || true
  echo
  echo "== RHEL/CentOS/Fedora =="
  test -d /var/log/anaconda && ls -la /var/log/anaconda || true
  test -f /var/log/dnf.log && tail -n 220 /var/log/dnf.log || true
  test -f /var/log/yum.log && tail -n 220 /var/log/yum.log || true
} >"$ROOT/installer/installer-footprint.txt" 2>&1 || true

section "salt footprints (if any)"
{
  ls -la /etc/salt 2>/dev/null || true
  systemctl --no-pager -l status salt-minion 2>/dev/null || true
} >"$ROOT/salt/salt-minion.txt" 2>&1 || true

# Package
OUT="/tmp/cluster-node-support.tgz"
tar -C /tmp -czf "$OUT" "$(basename "$ROOT")"
chmod 0644 "$OUT"
echo
echo "OK: wrote $OUT"
echo "DIR: $ROOT"
NODE
chmod 0755 "$NODE_SCRIPT"

# ---- salt prerequisites / minion list ----
if ! have salt || ! have salt-key || ! have salt-run; then
  echo "ERROR: salt tooling not found on master (salt/salt-key/salt-run)."
  exit 3
fi

MINIONS=()
if [[ -n "$MINION_LIST_OVERRIDE" ]]; then
  # shellcheck disable=SC2206
  MINIONS=($MINION_LIST_OVERRIDE)
else
  mapfile -t MINIONS < <(pick_minions_from_saltkey)
fi

section "MINIONS (Accepted Keys)"
if [[ "${#MINIONS[@]}" -eq 0 ]]; then
  echo "WARN: No accepted minions found via salt-key. This bundle will contain only master-local data."
else
  printf "%s\n" "${MINIONS[@]}"
fi
printf "%s\n" "${MINIONS[@]:-}" >"$META/minions.txt"

MINION_CSV="$(salt_minion_csv "${MINIONS[@]:-}")"

# ---- ensure file_recv for cp.push (idempotent) ----
if [[ "${ENSURE_FILE_RECV}" == "1" ]]; then
  section "SALT: ensure file_recv=True for cp.push"
  NEED_RESTART=0
  if grep -R -E '^\s*file_recv:\s*True' /etc/salt/master /etc/salt/master.d/* >/dev/null 2>&1; then
    echo "OK: file_recv already True somewhere in master config"
  else
    echo "Setting /etc/salt/master.d/file_recv.conf -> file_recv: True"
    cat >/etc/salt/master.d/file_recv.conf <<'C'
file_recv: True
C
    NEED_RESTART=1
  fi
  if [[ $NEED_RESTART -eq 1 ]]; then
    systemctl restart salt-master || true
  fi
  salt-run config.get master file_recv >"$META/salt-file_recv.txt" 2>&1 || true
  echo "file_recv status:"
  cat "$META/salt-file_recv.txt" || true
fi

# ---- optional: ensure todd ssh pubkey exists on minions (idempotent) ----
TODD_PUBKEY="${TODD_PUBKEY:-/home/todd/.ssh/id_ed25519.pub}"
if [[ "${ENSURE_TODD_MINION_SSH}" == "1" && -f "$TODD_PUBKEY" && "${#MINIONS[@]}" -gt 0 ]]; then
  section "SSH: ensure todd pubkey on minions (idempotent via grep)"
  KEY_B64="$(base64 -w0 <"$TODD_PUBKEY" 2>/dev/null || true)"
  if [[ -z "$KEY_B64" ]]; then
    echo "WARN: could not read/encode $TODD_PUBKEY; skipping key ensure"
  else
    echo "Recording ssh-key status (pre)"
    salt -L "$MINION_CSV" cmd.run "bash -lc '
set +e
id todd >/dev/null 2>&1 || { echo NO_TODD_USER; exit 0; }
home=\$(getent passwd todd | cut -d: -f6); [ -n \"\$home\" ] || home=/home/todd
auth=\"\$home/.ssh/authorized_keys\"
if [ -f \"\$auth\" ]; then
  grep -F \"\$(echo \"$KEY_B64\" | base64 -d)\" \"\$auth\" >/dev/null 2>&1 && echo KEY_PRESENT || echo KEY_MISSING
else
  echo NO_AUTH_KEYS
fi
'" -l quiet >"$META/ssh-key-status-pre.txt" 2>&1 || true

    echo "Installing key where missing (no-op if already present)"
    salt -L "$MINION_CSV" cmd.run "bash -lc '
set +e
id todd >/dev/null 2>&1 || { echo NO_TODD_USER; exit 0; }
home=\$(getent passwd todd | cut -d: -f6); [ -n \"\$home\" ] || home=/home/todd
install -d -m 700 -o todd -g todd \"\$home/.ssh\"
auth=\"\$home/.ssh/authorized_keys\"
touch \"\$auth\"
chown todd:todd \"\$auth\"
chmod 600 \"\$auth\"
key=\"\$(echo \"$KEY_B64\" | base64 -d)\"
grep -F \"\$key\" \"\$auth\" >/dev/null 2>&1 && { echo KEY_PRESENT; exit 0; }
echo \"\$key\" >>\"\$auth\" && echo KEY_ADDED
'" -l quiet >"$META/ssh-key-install-results.txt" 2>&1 || true

    echo "Recording ssh-key status (post)"
    salt -L "$MINION_CSV" cmd.run "bash -lc '
set +e
id todd >/dev/null 2>&1 || { echo NO_TODD_USER; exit 0; }
home=\$(getent passwd todd | cut -d: -f6); [ -n \"\$home\" ] || home=/home/todd
auth=\"\$home/.ssh/authorized_keys\"
if [ -f \"\$auth\" ]; then
  grep -F \"\$(echo \"$KEY_B64\" | base64 -d)\" \"\$auth\" >/dev/null 2>&1 && echo KEY_PRESENT || echo KEY_MISSING
else
  echo NO_AUTH_KEYS
fi
'" -l quiet >"$META/ssh-key-status-post.txt" 2>&1 || true
  fi
else
  section "SSH: todd pubkey ensure skipped"
  echo "ENSURE_TODD_MINION_SSH=${ENSURE_TODD_MINION_SSH}, MINIONS=${#MINIONS[@]}, PUBKEY_EXISTS=$( [[ -f "$TODD_PUBKEY" ]] && echo yes || echo no )"
fi

# ---- basic salt health + grains/vitals ----
if [[ "${#MINIONS[@]}" -gt 0 ]]; then
  section "SALT: test.ping + manage.up"
  salt -L "$MINION_CSV" test.ping -l quiet >"$SALT_DIR/test.ping.txt" 2>&1 || true
  salt-run manage.up >"$SALT_DIR/manage.up.txt" 2>&1 || true

  section "SALT: grains (items) + vitals (status.*)"
  salt -L "$MINION_CSV" grains.items --out=json >"$SALT_DIR/grains.items.json" 2>&1 || true
  salt -L "$MINION_CSV" status.uptime --out=json >"$SALT_DIR/status.uptime.json" 2>&1 || true
  salt -L "$MINION_CSV" status.meminfo --out=json >"$SALT_DIR/status.meminfo.json" 2>&1 || true
  salt -L "$MINION_CSV" status.cpustats --out=json >"$SALT_DIR/status.cpustats.json" 2>&1 || true
  salt -L "$MINION_CSV" status.diskusage --out=json >"$SALT_DIR/status.diskusage.json" 2>&1 || true
fi

# ---- cp.push verification (required to pull tarballs back) ----
CPPUSH_OK=0
if [[ "${#MINIONS[@]}" -gt 0 ]]; then
  section "SALT: cp.push self-test"
  salt -L "$MINION_CSV" cmd.run "bash -lc 'echo push_test_\$(hostname -s) > /tmp/push-test.txt'" -l quiet >"$META/push-results.txt" 2>&1 || true
  salt -L "$MINION_CSV" cp.push /tmp/push-test.txt -l quiet >>"$META/push-results.txt" 2>&1 || true
  find /var/cache/salt/master/minions -path '*/files/tmp/push-test.txt' -print | sort >"$META/cp-push-test.txt" 2>&1 || true

  if [[ -s "$META/cp-push-test.txt" ]]; then
    CPPUSH_OK=1
    echo "OK: cp.push test files received on master"
  else
    echo "WARN: cp.push test files NOT found on master. Collection may fail."
  fi
fi

# ---- collect master locally (always) ----
section "COLLECT MASTER LOCALLY (no salt)"
MASTER_NODE_DIR="$NODES_DIR/$MASTER_FQDN"
mkdir -p "$MASTER_NODE_DIR"
set +e
COLLECT_JOURNAL_LINES="$COLLECT_JOURNAL_LINES" \
COLLECT_ALL_JOURNAL_LINES="$COLLECT_ALL_JOURNAL_LINES" \
COLLECT_DMESG_LINES="$COLLECT_DMESG_LINES" \
VARLOG_MAX_MB="$VARLOG_MAX_MB" \
LARGEST_LOGS="$LARGEST_LOGS" \
bash "$NODE_SCRIPT" >"$META/master-local-collect.txt" 2>&1
MASTER_RC=$?
set -e
echo "master-local collector rc=${MASTER_RC}"
if [[ -f /tmp/cluster-node-support.tgz ]]; then
  cp -a /tmp/cluster-node-support.tgz "$MASTER_NODE_DIR/cluster-node-support.tgz"
  tar -xzf "$MASTER_NODE_DIR/cluster-node-support.tgz" -C "$MASTER_NODE_DIR" >/dev/null 2>&1 || true
  echo "OK: staged master node data under $MASTER_NODE_DIR"
else
  echo "FAIL: /tmp/cluster-node-support.tgz missing after master collection"
fi

# ---- collect minions via salt (run node collector + cp.push) ----
FAILURES=0
if [[ "${#MINIONS[@]}" -gt 0 ]]; then
  section "MINION COLLECTION via salt (node collector + cp.push)"
  if [[ "$CPPUSH_OK" -ne 1 ]]; then
    echo "WARN: cp.push precheck did not validate; continuing anyway."
  fi

  # Copy collector to minions
  section "salt-cp: distribute node collector to minions"
  set +e
  salt-cp -L "$MINION_CSV" "$NODE_SCRIPT" /tmp/cluster-node-collect.sh >"$META/salt-cp-node-collect.txt" 2>&1
  SCP_RC=$?
  set -e
  echo "salt-cp rc=${SCP_RC} (see $META/salt-cp-node-collect.txt)"

  # Run collector on minions (creates /tmp/cluster-node-support.tgz on each)
  section "salt: run node collector on minions"
  salt -L "$MINION_CSV" cmd.run "bash -lc 'chmod +x /tmp/cluster-node-collect.sh && COLLECT_JOURNAL_LINES=${COLLECT_JOURNAL_LINES} COLLECT_ALL_JOURNAL_LINES=${COLLECT_ALL_JOURNAL_LINES} COLLECT_DMESG_LINES=${COLLECT_DMESG_LINES} VARLOG_MAX_MB=${VARLOG_MAX_MB} LARGEST_LOGS=${LARGEST_LOGS} /tmp/cluster-node-collect.sh'" \
    -t 900 --out=txt >"$META/collect-results.txt" 2>&1 || true

  # Push tarballs back
  section "salt: cp.push node tarballs"
  salt -L "$MINION_CSV" cp.push /tmp/cluster-node-support.tgz -l quiet >"$META/cp-push-node-support.txt" 2>&1 || true

  # Stage pushed tarballs into WORKROOT
  section "stage pushed minion tarballs into bundle"
  for m in "${MINIONS[@]}"; do
    SRC="/var/cache/salt/master/minions/${m}/files/tmp/cluster-node-support.tgz"
    DST_DIR="$NODES_DIR/$m"
    mkdir -p "$DST_DIR"
    if [[ -f "$SRC" ]]; then
      cp -a "$SRC" "$DST_DIR/cluster-node-support.tgz"
      tar -xzf "$DST_DIR/cluster-node-support.tgz" -C "$DST_DIR" >/dev/null 2>&1 || true
      echo "OK: staged $m"
    else
      echo "FAIL: missing pushed tarball for $m at $SRC"
      FAILURES=$((FAILURES+1))
    fi
  done
fi

# ---- meta: per-node file counts ----
section "META: per-node file counts"
{
  echo "master: ${MASTER_FQDN}"
  echo
  echo "Files under nodes/:"
  for d in "$NODES_DIR"/*; do
    [[ -d "$d" ]] || continue
    n="$(basename "$d")"
    c="$(find "$d" -type f 2>/dev/null | wc -l | tr -d ' ')"
    printf "%-28s %8s files\n" "$n" "$c"
  done
} | tee "$META/per-node-file-counts.txt"

# ---- package + scp as todd ----
ensure_outdir
TAR_LOCAL="${OUTDIR}/${BASENAME}.tgz"

section "PACKAGE bundle"
tar -C /tmp -czf "$TAR_LOCAL" "$BASENAME"
chown "$DEST_USER:$DEST_USER" "$TAR_LOCAL"
chmod 0644 "$TAR_LOCAL"
ls -lh "$TAR_LOCAL"
sha256sum "$TAR_LOCAL" | tee "$META/sha256.txt" >/dev/null || true

section "SEND bundle (scp as ${DEST_USER})"
set +e
sudo -u "$DEST_USER" ssh "${SSH_OPTS[@]}" "${DEST_USER}@${DEST_HOST}" "mkdir -p '${DEST_DIR}'"
MK_RC=$?
sudo -u "$DEST_USER" scp "${SSH_OPTS[@]}" "$TAR_LOCAL" "${DEST_USER}@${DEST_HOST}:${DEST_DIR}/"
SCP_RC=$?
set -e

echo
if [[ $SCP_RC -eq 0 ]]; then
  echo "OK: Uploaded $(basename "$TAR_LOCAL") to ${DEST_USER}@${DEST_HOST}:${DEST_DIR}/"
else
  echo "FAIL: scp failed (rc=$SCP_RC). File remains at: $TAR_LOCAL"
  echo "mkdir rc was: $MK_RC"
fi

section "DONE"
echo "END:      $(date)"
echo "FAILURES: ${FAILURES}"
echo "BUNDLE:   $TAR_LOCAL"
echo "WORKROOT: $WORKROOT"
echo "LOG:      $LOG"


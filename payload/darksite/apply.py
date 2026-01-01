#!/usr/bin/env python3
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Dict, Any, Optional, Tuple

WG_DIR = Path("/etc/wireguard")
PLANES = ["wg1", "wg2", "wg3"]
SYSTEMD_UNIT_TEMPLATE = "wg-quick@{iface}.service"

SEED_PATHS = [
    Path("/root/darksite/cluster-seed/peers.json"),
    Path("/root/darksite/cluster-seed.json"),
]

ANSIBLE_BASE = Path("/srv/ansible")
ANSIBLE_INVENTORY = ANSIBLE_BASE / "inventory" / "hosts.ini"
ANSIBLE_SITE = ANSIBLE_BASE / "site.yml"

ANSIBLE_USER = "ansible"
ANSIBLE_HOME = Path("/home/ansible")
ANSIBLE_SSH_DIR = ANSIBLE_HOME / ".ssh"
ANSIBLE_PRIVKEY = ANSIBLE_SSH_DIR / "id_ed25519"
ANSIBLE_PUBKEY = ANSIBLE_SSH_DIR / "id_ed25519.pub"

# Unit-scoped known_hosts (do not touch user homedir known_hosts)
UNIT_KNOWN_HOSTS = Path(os.environ.get("KUBEOS_KNOWN_HOSTS", "/srv/darksite/known_hosts"))

SALT_TARGET = "*"
SALT_PING_RETRIES = int(os.environ.get("KUBEOS_SALT_PING_RETRIES", "80"))
SALT_PING_SLEEP = int(os.environ.get("KUBEOS_SALT_PING_SLEEP", "3"))
SALT_EXPECTED_MINIONS = int(os.environ.get("KUBEOS_SALT_EXPECTED_MINIONS", "15"))
SALT_REQUIRE_ALL = os.environ.get("KUBEOS_SALT_REQUIRE_ALL", "1") == "1"

POST_BOOT_PAUSE_SECONDS = int(os.environ.get("KUBEOS_POST_BOOT_PAUSE", "10"))

BACKUP_KEEP = int(os.environ.get("KUBEOS_WG_BACKUP_KEEP", "10") or "10")
ANSIBLE_STRICT = os.environ.get("KUBEOS_ANSIBLE_STRICT", "0") == "1"
ANSIBLE_VERBOSE = os.environ.get("KUBEOS_ANSIBLE_VERBOSE", "-vvv")  # "-v", "-vv", "-vvv"
ANSIBLE_COLOR = os.environ.get("KUBEOS_ANSIBLE_COLOR", "1") == "1"

# Security/behavioral toggles
SSH_ACCEPT_NEW = os.environ.get("KUBEOS_SSH_ACCEPT_NEW", "1") == "1"  # accept-new host keys to unit file
SSH_STRICT = os.environ.get("KUBEOS_SSH_STRICT", "0") == "1"          # if 1, strict checking against unit file


def log(msg: str):
    print(msg, flush=True)


def run(
    cmd,
    check: bool = True,
    env: Optional[Dict[str, str]] = None,
    cwd: Optional[Path] = None,
    timeout: Optional[int] = None,
    **kwargs
) -> str:
    kwargs.setdefault("text", True)
    kwargs.setdefault("stdout", subprocess.PIPE)
    kwargs.setdefault("stderr", subprocess.STDOUT)
    p = subprocess.run(cmd, check=check, env=env, cwd=str(cwd) if cwd else None, timeout=timeout, **kwargs)
    return (p.stdout or "").strip()


def run_rc(
    cmd,
    env: Optional[Dict[str, str]] = None,
    cwd: Optional[Path] = None,
    timeout: Optional[int] = None,
    **kwargs
) -> Tuple[int, str]:
    kwargs.setdefault("text", True)
    kwargs.setdefault("stdout", subprocess.PIPE)
    kwargs.setdefault("stderr", subprocess.STDOUT)
    p = subprocess.run(cmd, check=False, env=env, cwd=str(cwd) if cwd else None, timeout=timeout, **kwargs)
    return p.returncode, (p.stdout or "").strip()


def run_stream(
    cmd,
    env: Optional[Dict[str, str]] = None,
    cwd: Optional[Path] = None,
    timeout: Optional[int] = None,
) -> int:
    """
    Stream stdout/stderr in real time (for systemd journal + remote operator visibility).
    Returns process return code.
    """
    # Use line-buffered text mode
    p = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
        env=env,
        cwd=str(cwd) if cwd else None,
    )
    assert p.stdout is not None
    start = time.time()
    for line in p.stdout:
        sys.stdout.write(line)
        sys.stdout.flush()
        if timeout and (time.time() - start) > timeout:
            p.kill()
            return 124
    return p.wait()


def is_master() -> bool:
    hn = run(["hostname", "-f"], check=False).lower()
    return hn.startswith("master.") or hn == "master"


def load_seed() -> Dict[str, Any]:
    for p in SEED_PATHS:
        if p.exists():
            return json.loads(p.read_text())
    raise RuntimeError(f"Seed file not found. Tried: {', '.join(str(p) for p in SEED_PATHS)}")


def _extract_json_object(text: str) -> Optional[Dict[str, Any]]:
    """
    Salt output can include non-json banners. Extract last {...} block.
    """
    if not text:
        return None
    s = text.find("{")
    e = text.rfind("}")
    if s == -1 or e == -1 or e <= s:
        return None
    try:
        return json.loads(text[s : e + 1])
    except Exception:
        return None


def salt_cmd(target: str, shell_cmd: str, retries: int = 2) -> Dict[str, Any]:
    """
    Run salt cmd.run and return JSON dict (minion->output).
    Retries a couple times to ride through transient salt/mine hiccups.
    """
    last_err = None
    for _ in range(retries + 1):
        rc, out = run_rc(
            ["salt", target, "cmd.run", shell_cmd, "--out=json", "--static", "--no-color"],
            timeout=60,
        )
        if rc == 0:
            data = _extract_json_object(out)
            if isinstance(data, dict):
                return data
        last_err = out
        time.sleep(1)
    # Return empty dict rather than raising; callers can decide.
    if last_err:
        log(f"[WARN] salt_cmd failed target={target}: {last_err[:300]}")
    return {}


def salt_ping_wait():
    """
    Wait for salt minions to respond. By default requires all expected minions.
    """
    log("[INFO] waiting for salt minions ...")
    for _ in range(SALT_PING_RETRIES):
        rc, out = run_rc(["salt", SALT_TARGET, "test.ping", "--out=json", "--static", "--no-color"], timeout=30)
        if rc == 0:
            data = _extract_json_object(out)
            if isinstance(data, dict):
                up = [k for k, v in data.items() if v is True]
                if SALT_REQUIRE_ALL:
                    if len(up) >= SALT_EXPECTED_MINIONS:
                        log(f"[INFO] salt up: {len(up)} (expected={SALT_EXPECTED_MINIONS})")
                        return
                else:
                    if up:
                        log(f"[INFO] salt up: {len(up)}")
                        return
        time.sleep(SALT_PING_SLEEP)
    raise RuntimeError("salt minions did not respond in time")


def ensure_wg_keys_local(iface: str):
    key = WG_DIR / f"{iface}.key"
    pub = WG_DIR / f"{iface}.pub"
    if key.exists() and pub.exists():
        return
    key.parent.mkdir(parents=True, exist_ok=True)
    old_umask = os.umask(0o077)
    try:
        private = run(["wg", "genkey"], check=True) + "\n"
        key.write_text(private)
        pubkey = run(["bash", "-lc", f"wg pubkey < {key}"], check=True) + "\n"
        pub.write_text(pubkey)
    finally:
        os.umask(old_umask)


def read_iface_block(conf_path: Path):
    lines = []
    for line in conf_path.read_text(errors="replace").splitlines():
        if line.strip().startswith("[Peer]"):
            break
        lines.append(line)
    return lines


def prune_backups(conf_path: Path):
    if BACKUP_KEEP <= 0:
        return
    backups = sorted(conf_path.parent.glob(f"{conf_path.name}.bak.*"))
    excess = len(backups) - (BACKUP_KEEP - 1)
    if excess > 0:
        for old in backups[:excess]:
            try:
                old.unlink()
            except Exception:
                pass


def write_if_changed(conf_path: Path, desired_text: str):
    current = conf_path.read_text(errors="replace") if conf_path.exists() else ""
    if current == desired_text:
        return False

    if conf_path.exists() and BACKUP_KEEP > 0:
        prune_backups(conf_path)
        ts = time.strftime("%Y%m%d%H%M%S")
        backup_path = conf_path.with_suffix(conf_path.suffix + f".bak.{ts}")
        shutil.copy2(conf_path, backup_path)

    tmp = conf_path.with_suffix(conf_path.suffix + ".new")
    tmp.write_text(desired_text)
    os.replace(tmp, conf_path)
    return True


def render_plane_conf_from_seed(seed, iface: str):
    conf_path = WG_DIR / f"{iface}.conf"
    if not conf_path.exists():
        raise RuntimeError(f"missing {conf_path} (base interface config must exist)")

    iface_lines = read_iface_block(conf_path)

    hn = run(["hostname", "-f"], check=False).lower()
    nodes = seed["nodes"]
    if hn not in nodes:
        short = run(["hostname", "-s"], check=False).lower()
        match = None
        for k in nodes.keys():
            kl = k.lower()
            if kl.startswith(short + ".") or kl == short:
                match = k
                break
        if not match:
            raise RuntimeError(f"this node ({hn}) not found in seed nodes")
        hn = match

    pubkeys = {}
    if is_master():
        pubkeys = salt_cmd(SALT_TARGET, f"cat /etc/wireguard/{iface}.pub 2>/dev/null | tr -d '\\n' || true")
        my_pub_path = WG_DIR / f"{iface}.pub"
        if my_pub_path.exists():
            pubkeys[run(["hostname", "-f"], check=False)] = my_pub_path.read_text().strip()

    me = nodes[hn]
    my_ip = me.get(iface)
    if not my_ip:
        raise RuntimeError(f"seed missing {iface} ip for {hn}")

    desired = []
    desired.extend(iface_lines)
    desired.append("")

    if is_master():
        for node_name, node in sorted(nodes.items()):
            ip = node.get(iface)
            if not ip or ip == my_ip:
                continue
            pk = (pubkeys.get(node_name) or "").strip()
            if not pk:
                continue
            desired.append("[Peer]")
            desired.append(f"# {node_name} ({iface})")
            desired.append(f"PublicKey = {pk}")
            desired.append(f"AllowedIPs = {ip}/32")
            desired.append("PersistentKeepalive = 25")
            desired.append("")
    else:
        master_name = next((n for n in nodes.keys() if n.lower().startswith("master.")), None)
        if not master_name:
            raise RuntimeError("seed has no master.* entry")
        master = nodes[master_name]
        pk = salt_cmd("master*", f"cat /etc/wireguard/{iface}.pub 2>/dev/null | tr -d '\\n' || true")
        master_pk = ""
        for _, v in pk.items():
            master_pk = (v or "").strip()
            if master_pk:
                break
        if not master_pk:
            raise RuntimeError(f"could not obtain master {iface} pubkey via salt")
        desired.append("[Peer]")
        desired.append(f"# {master_name} ({iface})")
        desired.append(f"PublicKey = {master_pk}")
        desired.append(f"AllowedIPs = {seed['planes'][iface]['cidr']}")
        desired.append(f"Endpoint = {master['endpoint']}:{seed['planes'][iface]['port']}")
        desired.append("PersistentKeepalive = 25")
        desired.append("")

    desired_text = "\n".join(desired).rstrip() + "\n"
    changed = write_if_changed(conf_path, desired_text)
    return conf_path, changed


def restart_plane(iface: str):
    unit = SYSTEMD_UNIT_TEMPLATE.format(iface=iface)
    run(["systemctl", "restart", unit], check=False)


def ensure_unit_known_hosts():
    """
    Create/truncate unit known_hosts file so clones never conflict with stale entries.
    """
    UNIT_KNOWN_HOSTS.parent.mkdir(parents=True, exist_ok=True)
    # Truncate on every run: deterministic bootstrap behavior
    UNIT_KNOWN_HOSTS.write_text("")
    os.chmod(UNIT_KNOWN_HOSTS, 0o600)


def ensure_ansible_user_on_master():
    log("[INFO] ensuring ansible user + key on master")

    run(["bash", "-lc", f"id -u {ANSIBLE_USER} >/dev/null 2>&1 || useradd -m -s /bin/bash {ANSIBLE_USER}"], check=True)

    # Home + .ssh dirs
    run(["bash", "-lc", f"install -d -m0750 -o {ANSIBLE_USER} -g {ANSIBLE_USER} {ANSIBLE_HOME}"], check=True)
    run(["bash", "-lc", f"install -d -m0700 -o {ANSIBLE_USER} -g {ANSIBLE_USER} {ANSIBLE_SSH_DIR}"], check=True)

    # Generate key if missing
    if not ANSIBLE_PRIVKEY.exists():
        run(["bash", "-lc", f"sudo -u {ANSIBLE_USER} ssh-keygen -t ed25519 -N '' -f {ANSIBLE_PRIVKEY}"], check=True)

    # Enforce perms
    run(["bash", "-lc", f"chown -R {ANSIBLE_USER}:{ANSIBLE_USER} {ANSIBLE_SSH_DIR}"], check=True)
    run(["bash", "-lc", f"chmod 700 {ANSIBLE_SSH_DIR} && chmod 600 {ANSIBLE_PRIVKEY} && chmod 644 {ANSIBLE_PUBKEY}"], check=True)

    pub = run(["bash", "-lc", f"cat {ANSIBLE_PUBKEY}"], check=True).strip()
    if not pub.startswith("ssh-ed25519 "):
        raise RuntimeError("ansible public key missing/invalid")
    return pub


def push_ansible_key_to_minions(pubkey: str):
    log("[INFO] pushing ansible key to minions via salt")
    # Single-quote safe injection for salt shell
    safe_pub = pubkey.replace("'", r"'\''")

    cmds = [
        f"id -u {ANSIBLE_USER} >/dev/null 2>&1 || useradd -m -s /bin/bash {ANSIBLE_USER}",
        f"install -d -m0700 -o {ANSIBLE_USER} -g {ANSIBLE_USER} /home/{ANSIBLE_USER}/.ssh",
        f"touch /home/{ANSIBLE_USER}/.ssh/authorized_keys",
        f"chmod 600 /home/{ANSIBLE_USER}/.ssh/authorized_keys",
        f"chown {ANSIBLE_USER}:{ANSIBLE_USER} /home/{ANSIBLE_USER}/.ssh/authorized_keys",
        f"grep -qxF '{safe_pub}' /home/{ANSIBLE_USER}/.ssh/authorized_keys || echo '{safe_pub}' >> /home/{ANSIBLE_USER}/.ssh/authorized_keys",
        "printf '%s\n' 'ansible ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/90-ansible",
        "chmod 0440 /etc/sudoers.d/90-ansible && chown root:root /etc/sudoers.d/90-ansible",
        "visudo -cf /etc/sudoers && visudo -cf /etc/sudoers.d/90-ansible",
    ]
    for c in cmds:
        salt_cmd(SALT_TARGET, c, retries=1)


def ensure_controller_artifact_perms():
    """
    Fix class of failures where ansible (running as user) cannot read/traverse /srv/ansible/artifacts.
    Keep keys tight but allow controller-side copy operations.
    """
    log("[INFO] ensuring controller artifact permissions for ansible")
    # Ensure group exists and user is in it (idempotent)
    run(["bash", "-lc", "getent group ansible >/dev/null 2>&1 || groupadd ansible"], check=False)
    run(["bash", "-lc", f"usermod -aG ansible {ANSIBLE_USER} || true"], check=False)

    # Directories traversable by ansible
    run(["bash", "-lc", "chown -R root:ansible /srv/ansible"], check=False)
    run(["bash", "-lc", "chmod 0750 /srv/ansible /srv/ansible/artifacts 2>/dev/null || true"], check=False)
    run(["bash", "-lc", "chmod 0750 /srv/ansible/artifacts/etcd-pki 2>/dev/null || true"], check=False)

    # Keys group-readable; certs world-readable ok
    run(["bash", "-lc", "find /srv/ansible/artifacts -type f -name '*.key' -exec chown root:ansible {} \\; -exec chmod 0640 {} \\; 2>/dev/null || true"], check=False)
    run(["bash", "-lc", "find /srv/ansible/artifacts -type f -name '*.crt' -exec chmod 0644 {} \\; 2>/dev/null || true"], check=False)


def ansible_env() -> Dict[str, str]:
    """
    Build environment for ansible runs to:
      - force correct key
      - isolate hostkey handling to unit file
      - stream readable output
    """
    env = os.environ.copy()
    env["ANSIBLE_PRIVATE_KEY_FILE"] = str(ANSIBLE_PRIVKEY)

    # Hostkey behavior: always use unit known_hosts
    # Strictness:
    #   - If SSH_STRICT=1: require exact matches in unit file
    #   - Else: accept-new into unit file (or effectively ignore changes by truncating file each run)
    strict = "yes" if SSH_STRICT else ("accept-new" if SSH_ACCEPT_NEW else "no")
    ssh_common = [
        f"-o UserKnownHostsFile={UNIT_KNOWN_HOSTS}",
        f"-o StrictHostKeyChecking={strict}",
        "-o LogLevel=ERROR",
        "-o ServerAliveInterval=15",
        "-o ServerAliveCountMax=3",
    ]
    env["ANSIBLE_SSH_COMMON_ARGS"] = " ".join(ssh_common)

    # Ansible output / verbosity
    env["ANSIBLE_STDOUT_CALLBACK"] = "default"
    env["ANSIBLE_LOAD_CALLBACK_PLUGINS"] = "1"
    if ANSIBLE_COLOR:
        env["ANSIBLE_FORCE_COLOR"] = "1"
    else:
        env["ANSIBLE_NOCOLOR"] = "1"

    # Reduce “host key checking” prompt paths (we’re explicit via SSH args)
    env["ANSIBLE_HOST_KEY_CHECKING"] = "False"
    return env


def ansible_ping_and_world():
    log("[INFO] running ansible ping + world")
    if not ANSIBLE_INVENTORY.exists():
        raise RuntimeError(f"missing ansible inventory: {ANSIBLE_INVENTORY}")
    if not ANSIBLE_SITE.exists():
        raise RuntimeError(f"missing ansible site: {ANSIBLE_SITE}")

    env = ansible_env()

    # Ping with -v so you see which path it used
    rc = run_stream(
        ["bash", "-lc", f"cd {ANSIBLE_BASE} && sudo -u {ANSIBLE_USER} ansible -v -i {ANSIBLE_INVENTORY} all -m ping"],
        env=env,
        timeout=600,
    )
    if rc != 0:
        raise RuntimeError(f"ansible ping failed rc={rc}")

    # Full world apply with live output + verbosity
    rc2 = run_stream(
        ["bash", "-lc", f"cd {ANSIBLE_BASE} && sudo -u {ANSIBLE_USER} ansible-playbook {ANSIBLE_VERBOSE} -i {ANSIBLE_INVENTORY} {ANSIBLE_SITE}"],
        env=env,
        timeout=6 * 60 * 60,  # long enough for full cluster bring-up
    )
    if rc2 != 0:
        raise RuntimeError(f"ansible playbook failed rc={rc2}")


def main():
    log(f"[INFO] post-boot pause {POST_BOOT_PAUSE_SECONDS}s")
    time.sleep(POST_BOOT_PAUSE_SECONDS)

    seed = load_seed()

    for iface in PLANES:
        ensure_wg_keys_local(iface)

    salt_ping_wait()

    # WireGuard plane regeneration
    for iface in PLANES:
        conf_path, changed = render_plane_conf_from_seed(seed, iface)
        log(f"[INFO] {iface}: {'updated' if changed else 'unchanged'} {conf_path}")
        if changed:
            restart_plane(iface)

    # Keep a unit-scoped known_hosts for deterministic cloning (no user file mutations)
    ensure_unit_known_hosts()

    if is_master():
        try:
            pub = ensure_ansible_user_on_master()
            push_ansible_key_to_minions(pub)

            # Fix controller-side artifacts perms (prevents etcd-pki "file not found" under sudo -u ansible)
            ensure_controller_artifact_perms()

            # Run ansible with streaming verbose output
            ansible_ping_and_world()
        except Exception as e:
            log(f"[WARN] ansible phase failed: {e}")
            if ANSIBLE_STRICT:
                raise

    # Mine refresh (non-fatal)
    run_rc(["bash", "-lc", "salt-call --local mine.update 2>/dev/null || true"])
    log("[INFO] DONE")


if __name__ == "__main__":
    main()


https://kubedos.com/

# kubedOS: what it is, how it works, and why it’s different

kubedOS treats an entire Kubernetes platform as **one deployable object**: a sealed OS + payload + topology that can be stamped onto Proxmox and self-assemble on first boot.

It is not “a bunch of nodes you log into and fix.”
It’s a **repeatable cluster unit** that bootstraps itself into existence at *t=0*.

---

## The big idea

### The cluster is the artifact
kubedOS is designed so that:

- The **inputs** (ISO build + payload + topology) are explicit.
- The **output** is deterministic: the same inputs produce the same platform.
- “Repair” is usually **re-deploy**, not “SSH in and hand-fix one VM.”

### Proxmox is the substrate control plane
VM lifecycle is owned by Proxmox (`qm create/set/start/destroy`) and driven by a single script (`deploy.sh`), which means:

- VMIDs, names, resources, storage, firmware (UEFI), TPM2, and boot order are all reproducible.
- The platform is created by code, not by click-ops.

---

## What `deploy.sh` actually does

`deploy.sh` is a **one-shot platform deployer** that can provision a complete 16‑node environment onto a Proxmox host.

At a high level, it performs three jobs:

1. **Build role-specific installer ISOs** (Debian netinst + preseed + embedded “darksite” payload).
2. **Push the ISOs to Proxmox** and create VMs deterministically (Secure Boot + TPM2 included).
3. **Let the master orchestrate the whole cluster bring-up** after the nodes auto-install and enroll.

---

## The 16-node topology deployed by one script

`deploy.sh` defines a full inventory (VMID + hostname + LAN IP) for:

### Platform services (4 nodes)
- **master** (hub / orchestrator)
- **prometheus**
- **grafana**
- **storage**

### Kubernetes HA core: “3×3×3×3” (12 nodes)
- **3× etcd**: `etcd-1..3`
- **3× control plane**: `cp-1..3`
- **3× workers**: `w-1..3`
- **3× load balancers**: `lb-1..3`
- Optional: an API VIP is defined (`K8S_API_VIP`) for stable Kubernetes API access.

In other words: **one script deploys a complete platform + an HA Kubernetes cluster**, instead of you rebuilding or fixing a single instance by hand.

---

## How the deployment flow works (Proxmox → running platform)

### 1) ISO manufacturing: Debian + preseed + “darksite” payload
For each role (master, prom, graf, storage, etcd, lb, cp, worker), `deploy.sh` builds a custom ISO using `mk_iso()`.

That ISO contains:
- A preseeded installer (no interactive install)
- Role-specific postinstall logic
- A baked-in payload under `darksite/` (automation, configs, seed files)

It can also build a **local “darksite” APT repo snapshot** (Packages.gz / Release + `.deb` files) so installs can be repeatable and less dependent on the live internet.

### 2) Deterministic VM creation on Proxmox
For each VM, `deploy.sh` uses Proxmox commands to ensure a clean and predictable state:

- `qm destroy --purge` (remove any previous instance of the VMID)
- `qm create` with:
  - `--machine q35`
  - `--bios ovmf` (**UEFI**)
  - `--efidisk0 ... pre-enrolled-keys=1` (**Secure Boot** keys)
  - `--tpmstate ... version=v2.0` (**TPM 2.0**)
  - `--agent enabled=1` (**QEMU Guest Agent**)
- Attach the role ISO as a CD-ROM and boot from it.

This step is crucial: **the VM shape is part of the artifact**, not an afterthought.

### 3) Hands-off install and “bootstrapped at 0 seconds”
The installer runs without a user session.

Role-specific postinstall scripts run automatically, which means:
- WireGuard, nftables baseline, and system services are configured before you ever “log in.”
- The node becomes a member of the platform through bootstrap logic, not through interactive administration.

This is what “bootstraps it into existence at 0 second” means in practice:
- The node does not depend on a human-created userland workflow.
- The system comes up as a *known role*, with a *known network identity*, and a *known enrollment path*.

### 4) Master as the control point (no operator SSH into every node)
The build host uses SSH only to:
- talk to Proxmox (to run `qm`)
- optionally trigger the master’s apply step (`run_apply_on_master`)

After that, the **master is the management hub**.

Two important implementation details make this work reliably:

#### QEMU Guest Agent as a “pre-network” control channel
`deploy.sh` waits for QGA and can read files from the guest with it (example: fetching `/srv/wg/hub.env` from the master), which avoids relying on early SSH/network reachability.

#### Enrollment is controlled by the master
During deployment, the script opens an enrollment window on the master (via an `ENROLL_ENABLED` flag). Minions can then auto-register their WireGuard plane keys with the hub using a dedicated enrollment key.

That’s a big operational difference from “log into the node and configure it.”

---

## Backplanes: explicit L3 planes from first boot

kubedOS brings up kernel-native WireGuard planes as part of bootstrap.

In `deploy.sh`, the master is configured as the hub for multiple planes:
- `wg1` (control / management)
- `wg2` (metrics / observability)
- `wg3` (Kubernetes side/backplane)

Each node is assigned deterministic `/32` addresses per plane, and minion bootstrap configures:
- local WireGuard keys
- `wg-quick@wg1/wg2/wg3` units enabled at boot
- baseline firewall rules that trust the WireGuard planes

This is why the cluster behaves like a single unit: networking is **explicit, reproducible, and established immediately**.

---

## How this ties into Kubernetes

Once all VMs exist and are enrolled, the master runs the “apply” phase from the baked payload:

- A bootstrap controller (`/srv/darksite/apply.py`) coordinates bring-up.
- Salt is used as an early convergence/discovery gate (minions registering, pushing primitives).
- Ansible performs deterministic convergence:
  - etcd cluster assembly
  - container runtime (containerd)
  - kubeadm-based HA control plane
  - workers joining
  - load balancers providing stable API access
  - platform services and baseline configuration

The key point: Kubernetes is not “installed by hand.”
It is **a converged outcome** of the unit’s artifact definition.

---

## Why this is unique (the practical advantages)

### 1) Rebuild > repair
Most clusters drift because they’re repaired interactively.

kubedOS reduces drift by making **redeploy** the normal operation:
- If a node is wrong, you don’t “fix it live.”
- You recreate it from the same artifact so it returns to the defined state.

### 2) No per-node babysitting
You are not expected to SSH into 16 machines to “get to green.”

The workflow is:
- stamp the platform onto Proxmox
- let the master orchestrate enrollment and convergence

Operator SSH becomes an optional escape hatch, not the control plane.

### 3) The bootstrap does not require “a userland to exist”
The platform doesn’t depend on someone creating users, installing packages, or manually wiring networking.

The OS installs, configures, enrolls, and becomes its intended role automatically via:
- preseed + postinstall scripts
- systemd services
- deterministic identity and plane configuration

### 4) Networking is deliberate, not incidental
Because the planes exist early and are role-assigned, you can:
- separate management vs. metrics vs. cluster backplane traffic
- reason about security boundaries
- avoid hidden networking behaviors

### 5) The VM itself is part of the spec
Secure Boot, TPM2, and QGA are not “nice to have” — they are built into the VM creation step. That means the hardware/firmware assumptions are reproducible too.

---

## A quick mental model

1. **Build**: create role ISOs (installer + payload)
2. **Stamp**: destroy/recreate VMs on Proxmox deterministically
3. **Bootstrap**: each node self-configures (role + backplanes + baseline)
4. **Enroll**: nodes register with the master hub
5. **Converge**: master applies the platform state (etcd → kubeadm HA → services)

The result is a Kubernetes platform that behaves like a single artifact:
**one script, one topology, one converged outcome.** 

```bash
     _______
   <  Moo!?  >
     -------
        \   ^__^
         \  (oo)\_______
            (__)\       )\/\
                ||----w |
                ||     ||

  Role      : Kubernetes platform cattle node
  Directive : "If it breaks, replace it."
  Status    : ready to be re-provisioned
```

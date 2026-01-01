# KubeDOS (foundryBot) — Build Once, Deploy Everywhere

> **A single-step installer that treats the OS like a Kubernetes workload.**  
> Build immutable infrastructure, deploy it anywhere, and rebuild the entire world on demand.

KubeDOS exists because most infrastructure fails for the same boring reason:

**it can’t be rebuilt exactly the same way, twice.**

Images drift. Hosts turn into pets. Recovery becomes archaeology.  
And when something breaks at scale, “fixing it” becomes a lifestyle.

KubeDOS flips that.

Instead of **repairing** infrastructure, you **replace** it.  
Instead of **installing** servers, you **manufacture deployable artifacts**.

If Kubernetes can treat containers like cattle…  
KubeDOS treats the **OS itself** like cattle too.

---

## What KubeDOS actually is (in plain English)

KubeDOS is a build + deploy system that produces **sealed OS artifacts**, then deploys them as whole workloads:

- QCOW2 images for Proxmox / QEMU/KVM  
- ISO installers for bare metal  
- VMDK for ESXi (optional path)  
- Firecracker/Kata microVM rootfs + kernel bundles  
- Cloud images (AWS/Azure/GCP optional path)

But the real difference is this:

### ✅ The OS boots with “userland available at 0 seconds”
Instead of booting a VM and then waiting for layers of tooling…

KubeDOS images boot and immediately have:
- identity
- automation tooling
- networking fabric
- orchestration capability  
already present.

That means:
✅ **Ansible and Salt work instantly**  
✅ **No “waiting for cloud-init”**  
✅ **No “install dependencies after boot”**  
✅ **No “pull packages from the internet”** (dark-site safe)

The OS comes out of the foundry ready to converge.

---

## The Story: Why this exists

This project was born out of the pure joy of learning Kubernetes “the hard way” —
and the frustration of realizing that most real-world infrastructure is still built like:

- install an OS  
- patch it  
- babysit it  
- maintain it forever  
- and pray you can restore it when the underlying host dies

KubeDOS exists so you can say:

> “Cool. That node died. Deploy another one.”

No panic. No archaeology. No fragile recovery plan.

Just **build → deploy → converge**.

---

## What this example does (Beta-1 demo)

The current example deploys **16 instances**:

- ✅ **1 Master**
- ✅ **15 Minions**

Each minion is cattle:
- self-healing
- replaceable
- disposable
- and designed to be “sprayed” anywhere

This demo is intentionally designed to feel like a Kubernetes deployment:
you launch a fleet and it converges into a working environment.

---

## The Two-Part Deployment Model

KubeDOS currently uses a simple two-step process:

### **Part 1 — Deploy**
This phase creates the target fleet:
- creates VMs
- pushes images
- assigns networking
- boots everything

It can target:
- Proxmox over SSH (default)
- other hypervisors with the right tooling
- cloud providers via their CLIs
- Firecracker/Kata via your pipeline

### **Part 2 — Converge**
Once everything is booted, the system applies the platform configuration.

Here’s the key:

✅ **All automation is baked into every image.**

Infrastructure-as-Code isn’t “external glue” — it is a first-class citizen.

So instead of needing 7 external tools…
your cluster converges using what is already inside the OS artifacts:
- embedded Ansible
- embedded Salt
- embedded scripts and payloads
- embedded keys + enrollment logic
- embedded darksite packages (optional)

This is one of the biggest differences vs traditional platforms.

---

## What makes KubeDOS different from “traditional”

### Traditional approach
- install OS
- add config tools
- wait for network
- wait for DNS
- wait for repos
- configure automation tooling
- push scripts
- fix drift later
- repair broken nodes

### KubeDOS approach
- build OS artifact once
- deploy it anywhere
- boot → converge automatically
- nodes are disposable cattle
- replace instead of repair

---

## The Fabric: encrypted kernel-to-kernel “mind-meld”

By default, KubeDOS sets up multiple **encrypted Layer-3 WireGuard networks**.

Think of it like:
- Tailscale / NetBird / ZeroTier style connectivity  
…but implemented as:
✅ kernel-to-kernel WireGuard  
✅ no SaaS broker  
✅ deterministic addressing  
✅ multiple planes (not just one)

This means every node can become reachable instantly after boot
even when:
- there is no DNS
- there is no external internet
- the environment is partially broken
- the fleet spans across clouds

If UDP is reachable, the cluster can become a connected organism.

---

## No SSH login? Yes — on purpose.

KubeDOS is not a “pet server” platform.

You’re not supposed to SSH into a minion and “fix it”.

Instead:
- you rebuild it
- or you replace it

For observability and enforcement, KubeDOS promotes:
- **eBPF-first visibility**
- structured logging
- deterministic fleet state
- kill-and-replace behavior

It’s a platform designed to *run workloads*, not host fragile interactive shells.

---

## What the Beta-1 platform deploys

This Beta script is intended to bring up a complete cluster foundation including:

✅ etcd cluster  
✅ control plane nodes  
✅ worker nodes  
✅ Cilium + Hubble (CNI / observability)  
✅ Helm  
✅ ArgoCD  
✅ monitoring stack (Prometheus/Grafana)  
✅ optional LB nodes  
✅ storage node design (ZFS/Ceph-ready patterns)

In short: it builds the “platform world”, not just a kubernetes installer.

---

## Requirements (what you need to run this)

### You need two things:

## 1) A Build Server (“Foundry”)
This is where images are built and payloads are bundled.

Recommended:
- Linux x86_64
- Fast SSD/NVMe for build cache
- RAM: 16GB+ recommended
- Internet access only needed at build time (optional if you have a mirror)

Must have common tooling:
- docker or podman
- xorriso / mkisofs
- squashfs-tools
- qemu-img (qemu-utils)
- openssh-client
- rsync, curl, tar

## 2) A Target (where the fleet runs)
Targets can be:
- Proxmox (default example)
- QEMU/KVM
- ESXi/vSphere
- Firecracker/Kata hosts
- AWS/Azure/GCP

The only requirement is:
✅ it can boot an image  
✅ and you can reach it (usually SSH)

---

## Quickstart (the friendly way)

### 1) Clone this repo
```bash
git clone https://github.com/foundrybot-ca/foundrybot
cd foundrybot

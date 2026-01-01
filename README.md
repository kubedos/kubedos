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

## 2) Configure your target access (Proxmox example)

KubeDOS talks to your target using plain SSH.  
For the Proxmox example, you want **passwordless SSH** working first.

### Generate an SSH key (if you don’t already have one)

```bash
ssh-keygen -t ed25519 -C "kubedos"
```

Just press Enter through the prompts (or set a passphrase if you prefer).

### Copy your key to the Proxmox host

Replace `PROXMOX_HOST` with your Proxmox IP or hostname:

```bash
ssh-copy-id root@PROXMOX_HOST
```

✅ After this, you should be able to do:

```bash
ssh root@PROXMOX_HOST
```

…and it should **log in without asking for a password**.

---

### Recommended: add an SSH config entry (makes life easier)

Create or edit:

```bash
~/.ssh/config
```

Add an entry like this:

```sshconfig
Host proxmox
  HostName PROXMOX_HOST
  User root
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
```

Now instead of typing a long hostname every time, you can just do:

```bash
ssh proxmox
```

…and your deploy scripts can use the shortcut name `proxmox` as the target.

---

## 3) Run the example deploy

This demo deploys **16 total machines**:

- ✅ **1 master**
- ✅ **15 minions**
- ✅ everything prewired for converge (IaC baked into every node)

To deploy the whole environment, you run the deploy script:

```bash
./deploy.sh
```

That’s it.

KubeDOS handles:
- creating the VMs
- booting the artifacts
- wiring the fabrics
- converging the environment

---

## About networking in the example

The default demo uses a **/20 network plan**:

✅ **4096 total IPs**

This /20 is split into two halves:

- **8× /24 networks = Blue**
- **8× /24 networks = Green**

That makes it easy to support:

- ✅ blue/green deployments
- ✅ canary nodes
- ✅ rapid rebuilds
- ✅ full environment cloning

You *can* change the addressing plan — but the default is designed to **just work** for a large lab fleet without needing custom math.

---

## Works with your existing tools (Packer, Terraform, etc.)

KubeDOS does **not** fight your existing world.

You can absolutely:

- build artifacts using KubeDOS  
- deploy them using **Packer**
- place them with **Terraform**
- orchestrate them with whatever workflow you already use

The key difference is:

✅ the OS artifacts are consistent  
✅ the converge payload is built into every image  

So no matter how you launch nodes, they boot ready — and converge reliably.

---

## Why this is a big deal (the advantages)

### ✅ Faster disaster recovery

A cluster dying is no longer terrifying.

If AWS goes down:

- boot the same artifacts in Azure
- converge
- reattach workloads/state

Your infrastructure becomes portable and replaceable.

---

### ✅ Fewer moving parts

No stack of provisioning middleware.

Just:

- a build server
- a target
- one script

---

### ✅ Better security posture

- WireGuard by default  
- No third-party control planes  
- No random overlay defaults  
- Everything is deterministic and auditable  

---

### ✅ Less drift, less pain

- the base OS is a product  
- nodes are disposable  
- the platform stays consistent over time  

---

## Status: Beta-1

This is a **production-grade beta release** target.

The goal is:

- ✅ build all components  
- ✅ bring up the full environment  
- ✅ converge reliably  
- ✅ safe to rerun  
- ✅ no deploy script editing required  

If something fails:

- the failure should be actionable  
- logs should be captured  
- nodes should be replaceable cleanly  

---

## Contributing / Notes

Want to add new workloads?

1. add them to the payload (Ansible/Salt)
2. rebuild the artifact
3. deploy fleets

Want different fabrics or planes?

1. edit the networking profile
2. rebuild
3. redeploy

Everything starts from the artifact.

---

## Motto

> **Build the world. Every time.**

Because if it can’t be rebuilt from nothing, anywhere — it’s already broken.

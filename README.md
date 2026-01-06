# Kubedos — Build Once, Deploy Everywhere

> **A build + deploy system that treats the operating system like a Kubernetes workload.**  
> You don’t “install servers.” You **manufacture sealed OS artifacts** and **replace nodes instead of repairing them**.

KubeDOS exists to deliver **platforms as cattle** across Proxmox, bare metal, microVMs, and (optionally) cloud targets — with a sane security baseline and “quality of life” tooling baked in.

If you can’t rebuild the same platform from scratch, on demand, you don’t have infrastructure — you have archaeology.

KubeDOS flips the model:

- **Build** a deterministic OS artifact (ISO/QCOW2/etc.)
- **Deploy** it anywhere
- **Converge** the platform using tooling already inside the artifact
- **Replace** broken nodes instead of fixing them

This is an **MTTR tool** first: it turns disaster recovery into “recreate the world” instead of “recover the pets.”

---

## What KubeDOS is (in one sentence)

KubeDOS is a **foundry** that produces **sealed, portable OS artifacts** that boot with identity + automation + encrypted network planes already present, so a fleet can converge immediately (even in dark sites).

---

## Why you should care (the value)

### Lower MTTR (Mean Time To Recovery)
When a node dies, you do not troubleshoot it at 3AM.

You redeploy the same artifact and let convergence recreate the desired state.

### Disaster Recovery you can actually practice
Your DR plan becomes:

- “Can I rebuild this environment from a Git commit and a build cache?”
- “Can I deploy it in a second location with the same artifacts?”
- “Can I do it **without internet** if needed?”

KubeDOS is designed to make the answer “yes.”

### Determinism beats drift
Most stacks drift because provisioning happens *after* boot (and depends on networks, repos, DNS, time, luck).

KubeDOS bakes the important parts **into the artifact** so the boot path is predictable and repeatable.

---

## What KubeDOS produces (artifacts)

KubeDOS is built around **outputs**, not “machines.”

This repo currently supports (or scaffolds) outputs like:

- **ISO installers** (custom Debian netinst flow)
- **QCOW2 base images** (Proxmox / QEMU/KVM)
- **VMDK export** (ESXi path)
- **AWS AMI import + run** (optional path)
- **Firecracker bundle** (rootfs/kernel/initrd + helpers)
- **Packer scaffold** (emit a QEMU template)

These are driven by the `TARGET=` modes in `deploy.sh` (see below).

---

## The core idea: “Userland at 0 seconds”

KubeDOS artifacts boot with the essential “platform wiring” already available:

- identity + enrollment hooks
- automation tooling (Ansible/Salt payloads)
- backplane networking hooks
- optional offline packages / repo snapshot (darksite mode)

So you don’t do the traditional dance:

- wait for cloud-init  
- wait for apt mirrors  
- install bootstrap tools  
- hope DNS works  
- then begin convergence  

Instead: **boot → fabric → converge**.

---

## Backplanes: “built-in Tailscale/WireGuard” (without the SaaS)

When people hear “network fabric” they often think “mystery overlay.”

KubeDOS is explicit: it uses **kernel-level WireGuard** planes, similar in outcome to Tailscale/NetBird/ZeroTier connectivity, but:

- no SaaS broker
- no hidden overlay defaults
- deterministic addressing
- multiple planes with explicit intent

In this release, the model is **three planes** (interfaces):

- `wg1` — control / SSH / automation
- `wg2` — metrics / observability
- `wg3` — Kubernetes backend / service-plane plumbing

The payload includes tooling to **apply/refresh plane configs** from a seed (`payload/darksite/apply.py`, `cluster-seed/peers.json`) and to gate convergence on plane readiness (`ansible/playbooks/00_fabric_gate.yml`).

> If UDP can pass, your fleet can become reachable even when DNS/internet is broken.
> There is no **limit**  to the number of planes you can add — just extend the tooling and create your own blast radius.
---

## eBPF: why it matters (and why you’ve already seen it)

KubeDOS leans into **eBPF-first** networking and observability.

If you’ve used modern monitoring vendors (Datadog is a common example), you’ve already benefited from eBPF-style kernel visibility: low-overhead signals, network flow insight, and deep telemetry without “sidecar hell.”

In this repo, that shows up via:

- **Cilium + Hubble** (eBPF dataplane + network visibility)

This is not a “nice-to-have.” It’s part of the platform’s **replace-not-repair** posture: you need strong telemetry to confidently kill and replace nodes.

---

## Two deployment modes: Connected vs Darksite (Airgapped)

Most projects hand-wave “airgap support.” KubeDOS makes it an explicit mode.

### 1) Connected mode (fastest iteration)
Use upstream mirrors during build and/or converge.

Best for:
- labs
- fast iteration
- environments with stable outbound access

### 2) Darksite mode (offline / airgapped)
Build an **ISO-local APT repo snapshot** and stage it into the installer media (mounted at `/cdrom/darksite/` during install).

Best for:
- regulated environments
- disconnected sites
- “the internet is not allowed” realities

### 3) Both (hybrid)
Build artifacts that can operate offline but still allow connected mirrors when present.

---

## How to select modes (repo knobs you can actually use)

`deploy.sh` exposes these key controls:

- `REPO_MODE=connected|darksite|both`  
  Controls whether an ISO-local APT snapshot is built and embedded.

- `REPO_PROFILE=base|base+updates|full`  
  Controls how much of Debian you snapshot/include.

- `DARKSITE_SRC=/path/to/payload/darksite`  
  Controls where the darksite payload comes from (defaults to repo-local `payload/darksite` if present).

This is the “linkage” that matters:

- **Connected** = smaller artifacts + dependency on mirrors  
- **Darksite** = larger artifacts + independence + deterministic installs  
- **Both** = portable artifacts that survive hostile networks  

---

## Two ways to deploy: KubeDOS-native vs “bring your own IaC”

KubeDOS is intentionally **not** jealous. You can use it as a full pipeline or as an artifact factory.

### Path A — KubeDOS-native deployment (batteries included)
Use the included `deploy.sh` to build + deploy + converge.

- Default target: **Proxmox over SSH**
- Uses standard host tooling (`qm`, storage, ISO handling)
- Intended to be rerunnable and operationally boring

This is the “I want a working platform now” path.

### Path B — Use KubeDOS as an artifact factory (integrates with your stack)
Use KubeDOS to produce artifacts, then deploy them with:

- Packer (artifact workflows, registries, conversions)
- Terraform (placement, scaling, multi-site orchestration)
- Ansible (Proxmox graph control, lifecycle, drift management)
- your existing CI/CD runner

This is the “I already have an IaC universe” path.

**Key point:** even if *you* place the VMs, the nodes boot with convergence payloads already inside the OS artifact.

---

## Examples: integrating with other IaC tools (real patterns)

### Example 1 — Use KubeDOS to emit a Packer scaffold
KubeDOS includes a mode to generate a Packer QEMU template:

```bash
TARGET=packer-scaffold ./deploy.sh


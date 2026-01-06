# Kube'd'OS (kubedOS)

**Kube'd'OS is an atomic, self-deploying clustered platform.**  
It manufactures a complete, secure, reproducible infrastructure base from raw hardware, hypervisors, or cloud instances — in **one convergent operation**.

No hand-built images.  
No snowflake servers.  
No vendor control planes.  
No “day-2” glue scripts.

You boot it — **it builds the world**.

> **Borg-inspired, Kubernetes-native:** workloads are cattle — **and so are the hosts**.

---

## What Kube'd'OS Is

Kube'd'OS is a **Declarative Cluster Lifecycle Platform** built around a single, uncompromising premise:

> **If infrastructure cannot be rebuilt from nothing, anywhere, at any time, it is already broken.**

Kube'd'OS produces a **deployable, atomic platform artifact** — a clean, deterministic foundation that serves as a **reproducible blank canvas** for any workload.

Deployment and configuration are **intentionally and strictly separated**:

- **Deployment** manufactures the platform (immutable, deterministic)
- **Configuration** is layered on top (disposable, environment-specific)

This separation enables extreme portability, minimal MTTR, and long-term survivability.

---

## Why “Kube'd'OS”

**Kube'd'OS** (kubedOS) is a deliberate name:

- **Kubernetes** is the reference workload and the integration target
- **“Borg-like” operational posture**: connectivity, self-healing, and replication behaviors are *platform primitives*, not add-ons
- The goal is not “a Kubernetes installer” — it’s a **cluster operating system** that can deterministically manufacture **production-grade HA** substrate + workloads.

A nearby project in spirit is **Talos OS**: immutable, API-driven, Kubernetes-centric.  
Kube'd'OS shares the “machines are replaceable” ethos — while focusing on **self-deploying cluster artifacts**, **Proxmox-native IaC**, and explicit **backplane networking**.

---

## Atomic by Design

Kube'd'OS is **atomic**.

Each build produces a **complete, self-contained platform artifact** that includes:

- Operating system baseline (minimal, hardened)
- Kernel configuration and sysctls
- Secure networking fabric (multi-plane)
- Identity and trust model
- Automation backends (Salt + Ansible)
- Storage primitives (OpenZFS, Ceph)
- Observability and telemetry (first boot, not day-2)
- Recovery + rebuild artifacts (time-capsule safe inputs)

There are **zero external dependencies** required to complete the system after boot.

The platform either exists — or it doesn’t.

---

## Dark-Site & Time-Capsule Safe

Kube'd'OS is designed to survive **time**, not just outages.

Everything required to rebuild the platform is **baked into the artifact**:

- All packages
- All versions
- All tooling
- All orchestration logic

No live repositories.  
No broken mirrors.  
No abandoned vendors.  
No silent dependency drift.

> **If your infrastructure explodes five years from now, you can still redeploy it exactly as it was.**

Your **last successful deployment** becomes your **permanent MTTR anchor** — today, tomorrow, and forever.

Burn it to USB.  
Store it in a safe.  
Walk away.

---

## Borg-Like Platform Behavior (Without Vendor Magic)

Kube'd'OS aims for “Borg-like” outcomes via explicit, auditable mechanisms:

- **Connectivity as a primitive** (encrypted, routed, multi-plane)
- **Replication as a primitive** (storage + state patterns)
- **Self-healing as a primitive** (replace, don’t repair)
- **Determinism as the control plane** (same inputs → same cluster)

This is *not* “SaaS mesh magic.”

No Tailscale.  
No NetBird.  
No recurring bills.  
No hidden brokers.

And importantly: no accidental “just works” overlays that hide topology.

---

## Backplanes First (Explicit Planes, Explicit Intent)

All nodes participate in a **WireGuard-based encrypted mesh**, but not as a single flat network.

Kube'd'OS establishes **multiple L3 kernel backplanes** early (first boot), for example:

- **wg1** — control / SSH / Ansible / Salt / CI control
- **wg2** — metrics / observability / logging transport
- **wg3** — Kubernetes backend (control-plane + east/west)

Planes are:

- Kernel-level
- L3 routed
- Explicitly addressed
- Services bind to planes intentionally

> **Orchestration runs on top of the planes.**  
> Planes never “appear later” as a day-2 retrofit.

---

## Kubernetes: Reference Workload, Not the Product

Kube'd'OS is **not a Kubernetes installer**.

It is a **cluster operating system and lifecycle platform**.

Kubernetes is included as a reference workload because it is an excellent proof:

- Networking
- Identity
- Storage
- Automation
- Observability
- Upgrade semantics
- Failure domains

If Kube'd'OS can deterministically manufacture a production-grade, HA Kubernetes cluster, it can manufacture almost anything.

Workloads are replaceable.  
The platform is permanent.

---

## Kubernetes-Native Networking & Visibility (Cilium + Hubble)

Kube'd'OS treats Kubernetes networking and observability as **first-class platform subsystems**:

- **Cilium** for eBPF-based networking, policy, and service handling
- **Hubble** for network flow visibility and troubleshooting
- Built-in monitoring patterns (metrics + logs + traces integration-ready)

The objective is that **every cluster artifact ships with a known-good, inspectable networking posture** — not a bolt-on CNI decision made later under pressure.

---

## Observability Is Infrastructure (Not Optional)

Kube'd'OS treats observability as **infrastructure**, not an add-on.

Included from first boot (platform-level):

- eBPF-based kernel introspection where appropriate
- Network and system visibility
- Structured, machine-readable logging
- Designed for modern stacks (e.g., Prometheus / Grafana / Loki)

If something happens, **you can see it**.  
If it breaks, **you can prove why**.

---

## Storage as a Platform Primitive

Kube'd'OS integrates storage as a core substrate capability:

- **OpenZFS**
  - Integrity-first
  - Snapshots and rollback
  - Ideal for system and control-plane state anchoring

- **Ceph**
  - Distributed and fault-tolerant
  - Designed for stateful workloads and replication

State is protected, portable, and replaceable — not fragile.

---

## Salt + Ansible: Dual-Engine by Design

Kube'd'OS uses both — intentionally.

### Salt (Bootstrap & Control)
- Secure enrollment
- Fast discovery
- Reliable execution
- Cluster-wide coordination

Salt is used where **speed, identity, and coordination** matter most.

### Ansible (Lifecycle & Post-Config)
- Declarative
- Idempotent
- Auditable
- Familiar

Ansible is **prebuilt into the platform**: drop playbooks into `/srv/ansible` and they simply exist.

No installers.  
No agents beyond what the platform chooses.  
No “curl | bash”.

---

## Substrate-Agnostic, Vendor-Free

Kube'd'OS is intentionally hostile to vendor lock-in.

No:
- HashiCorp control planes
- SaaS orchestration layers
- Embedded vendor telemetry
- Proprietary networking overlays

Instead, Kube'd'OS produces **golden, agnostic platform artifacts** you control.

If AWS us-east disappears:
- Use the same artifact on Azure, GCP, or on-prem
- Boot
- Deploy

You get the **same platform**, with the same behavior and posture — every time.

The substrate is interchangeable.  
The platform is not.

---

## The Unit Is the Artifact

Kube'd'OS does not manage machines.

It manufactures **cluster artifacts**.

A cluster is a single deployable object, not a pile of nodes.

**Exact code → exact artifact → exact clone → exact behavior.**

This is the foundation for:

- Rebuilds that are mechanical
- Recovery that is boring
- Failure that is survivable

---

## Separation of Deployment and Configuration

This is not optional. It is foundational.

### Deployment (Platform Manufacturing)
- Immutable
- Deterministic
- Auditable
- Reproducible

### Configuration & Workloads (Layered On Top)
- Disposable
- Replaceable
- Environment-specific
- Drift-resistant

Rebuilds are normal.  
Repairs are the exception.

---

## Unmatched MTTR by Construction

Kube'd'OS is designed for catastrophic scenarios, not happy paths:

- Cloud region loss
- Ransomware
- Supply-chain compromise
- Vendor collapse
- Operator error at scale

With Kube'd'OS:

> **You do not repair infrastructure.  
> You replace it.**

From total failure to fully operational platform is a predictable, repeatable process — measured in minutes, not days.

---

## Fully Auditable, From the Ground Up

Kube'd'OS does not download mystery artifacts or apply opaque transformations.

The build process is:

- Transparent
- Auditable
- Deterministic
- À-la-carte

It assembles only what is required and delivers a platform that boots **directly into a fully running state**.

No post-install “wizardry.”  
No secondary provisioning systems.  
No hidden steps.

---

## Philosophy

- **Platforms are atomic**
- **Rebuilds are normal**
- **State is disposable (until explicitly replicated)**
- **Clusters are the unit of computation**
- **Security is the default**
- **Human intervention is a failure mode**

Kube'd'OS manufactures certainty.

---

## Status

Active development.  
Designed for real-world infrastructure.  
Built to be destroyed — and rebuilt — forever.

---

## Keywords (for discovery)

Kube'd'OS, kubedOS, Kubernetes, Borg-inspired, Proxmox VE, Ansible, Salt, WireGuard, Cilium, Hubble, eBPF, OpenZFS, Ceph, Prometheus, Grafana, Loki, HA, immutable infrastructure, reproducible infrastructure, dark-site, air-gapped, time-capsule safe, disaster recovery, vendor-free, Talos OS.

---

**Kube'd'OS**  
*Build the world. Every time.*


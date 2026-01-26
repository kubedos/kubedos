# kubedos — Hardware-Attested Atomic Cluster OS & Lifecycle Platform

**Status:** Draft / Test Specification (single-file)
**Audience:** Platform / SRE / Infra engineers (Linux, networking, storage, virtualization, Kubernetes fluent)
**Tagline:** *Build the world. Every time.*

**Keywords:** Proxmox VE, Ansible, Salt, WireGuard, Cilium, Hubble, eBPF, OpenZFS, Ceph, kubeadm HA, Prometheus, Grafana, Loki, TPM 2.0, UEFI Secure Boot, measured boot, attestation, sealed keys, SBOM, provenance, air-gapped, dark-site, time-capsule, Talos OS (reference)

---

## Table of Contents

1. Abstract
2. Normative Language
3. Core Philosophy
4. Goals and Non-Goals
5. System Model
6. Determinism, Reproducibility, and Supply Chain
7. Threat Model and Security Posture
8. Build System
9. Targets
10. Networking Architecture
11. Storage Architecture
12. Automation Subsystems
13. Kubernetes Reference Workload
14. Convergence DAG
15. ClusterSpec
16. Outputs
17. Acceptance Criteria
18. Operational Runbooks
19. Documentation and Code Standards
20. Glossary
21. Appendix A: One-Page Audit Checklist

---

## 1. Abstract

**kubedos** is a **hardware-attested, atomic, self-deploying cluster operating system and lifecycle platform**. It manufactures a complete, secure, reproducible infrastructure base from raw hardware, hypervisors, or cloud instances in **one convergent operation**.

The platform is built around a single uncompromising premise:

> **If infrastructure cannot be rebuilt from nothing, anywhere, at any time — and cryptographically proven authentic — it is already broken.**

kubedos produces a **single deployable cluster artifact**, not a pile of hand-maintained machines. The operating system itself is treated as a **disposable, signed artifact**. Nodes are never repaired; they are replaced.

Kubernetes is included strictly as a **reference workload**. It validates the platform surface — identity, networking, storage, HA, observability, and lifecycle — but it is **not the root of trust**.

**Workloads are cattle. Hosts are cattle. Trust is rooted in hardware.**

---

## 2. Normative Language

This document uses RFC-style key words:

* **MUST / MUST NOT** — absolute requirement
* **SHOULD / SHOULD NOT** — strong recommendation
* **MAY** — optional behavior

---

## 3. Core Philosophy

### 3.1 The Unit Is the Artifact

* A cluster is a **single deployable object**.
* **Exact inputs → exact artifact → equivalent behavior**.
* Nodes have no identity outside the artifact lineage that created them.

### 3.2 Replace, Don’t Repair

* Nodes are **never fixed in place**.
* Any drift, compromise, or upgrade results in **destruction and replacement**.
* Mean-time-to-replacement matters more than mean-time-to-repair.

### 3.3 Trust Below Orchestration

* Orchestration systems do **not** establish trust.
* Trust is established **before** orchestration exists via:

  * UEFI Secure Boot
  * TPM-based measured boot
  * Attestation-gated node existence

### 3.4 Backplanes Come First

* Kernel-native L3 backplanes (WireGuard planes) **MUST** exist before orchestration.
* Orchestration runs **on top** of verified connectivity.

### 3.5 Graph-Based Deployment

* Ordering is a DAG, not vibes.
* Dependencies are explicit, validated, and auditable.

---

## 4. Goals and Non-Goals

### 4.1 Goals

kubedos **MUST** provide:

1. Atomic manufacturing of a full platform from declared inputs
2. Hardware-rooted node identity (TPM + Secure Boot)
3. Attestation-gated node existence
4. Air-gap survivability (no external repos after boot)
5. Deterministic rebuild and provable provenance
6. Explicit multi-plane kernel backplanes
7. Host replaceability as a first-class operation
8. Auditable supply chain (SBOM + signatures + provenance)
9. HA reference workload (Kubernetes + CNI + observability)
10. Operational proof via drills and acceptance gates

### 4.2 Non-Goals

kubedos is **NOT**:

* a general-purpose Linux distribution
* a mutable snowflake platform
* a Kubernetes fork or replacement
* a runtime-only security product
* a system that assumes node trust by default

---

## 5. System Model

### 5.1 Fixed Trust and Execution Order

1. Hardware / Hypervisor (TPM, firmware)
2. UEFI Secure Boot
3. Measured boot (TPM PCRs)
4. Attestation verification
5. Node existence approval
6. Kernel networking backplanes
7. Baseline OS hardening
8. Enrollment & discovery
9. Convergent orchestration
10. Workloads (Kubernetes reference)
11. Seal & emit recovery anchors

### 5.2 Artifacts

A successful build produces:

* **Platform Artifacts:** signed, bootable images for targets
* **Recovery Bundle:** ClusterSpec, SBOM, provenance, signatures, acceptance results

The recovery bundle is the **time-capsule** that makes rebuilds and audits possible without the internet.

---

## 6. Determinism, Reproducibility, and Supply Chain

### 6.1 Determinism Contract

* **Input-deterministic:** same inputs → equivalent system
* **Audit-deterministic:** provenance explains *why* the system exists
* **Recovery-deterministic:** rebuild is mechanical

Bit-for-bit identity is a **MAY**. Functional equivalence is a **MUST**.

### 6.2 Supply-Chain Controls

* All packages pinned
* All images hashed
* All artifacts signed
* No unaudited network access after first boot

### 6.3 SBOM and Provenance

The build **MUST** emit:

* OS SBOM
* Container image SBOM
* Provenance (inputs, toolchain, signer identity)

---

## 7. Threat Model and Security Posture

### 7.1 Threats In Scope

* Supply-chain compromise
* Golden image tampering
* Firmware-level persistence
* Rootkits and bootkits
* Rogue or cloned nodes
* Insider misuse at scale

### 7.2 Hardware Root of Trust (Required)

kubedos **MUST** enforce:

* **UEFI Secure Boot** with platform-owned PK / KEK / db
* **Signed bootloader, kernel, initramfs**
* **TPM 2.0 measured boot**
* **PCR policy enforcement**

### 7.3 Attestation and Node Existence

On first boot, every node **MUST**:

1. Measure boot chain into TPM PCRs
2. Produce a nonce-bound TPM quote
3. Submit an attestation bundle
4. Be verified against artifact policy

If attestation **fails**:

* the node **MUST NOT** enroll
* the node **MUST** be destroyed or quarantined

> **If kubedos did not sign you, and attestation did not verify you — you do not exist.**

### 7.4 Enrollment and Revocation

* Enrollment is gated on attestation
* All identities are revocable
* Rotation is mandatory and scheduled

---

## 8. Build System

kubedos is manufactured by a **deterministic build server**.

Builds are **manufacturing events**, not ad-hoc installs.

### 8.1 Build Stages

1. Spec validation
2. Dependency resolution & locking
3. Artifact assembly
4. Secure Boot signing
5. TPM policy definition
6. Sealing & provenance emission

Build outputs are **immutable** and never overwritten.

---

## 9. Targets

kubedos supports multiple **target types**:

* Proxmox VM templates
* Bare-metal ISO / disk images
* Cloud-importable images

All targets **MUST**:

* Boot without internet
* Enforce Secure Boot
* Support TPM / vTPM
* Perform attestation on first boot

---

## 10. Networking Architecture

### 10.1 Backplane Model

Networking is built from **explicit kernel-level WireGuard planes**.

### 10.2 Plane Definitions

* **wg-control:** bootstrap, orchestration, SSH
* **wg-observability:** metrics, logs, traces
* **wg-kubernetes:** cluster east-west + control traffic

### 10.3 No Accidental Overlay

kubedos **MUST NOT** deploy implicit overlays.

---

## 11. Storage Architecture

### 11.1 OpenZFS

* Integrity-first storage
* Snapshots and rollback
* Artifact sealing support

### 11.2 Ceph (Optional)

If enabled:

* Failure domains **MUST** be explicit
* Network plane **MUST** be declared
* Replacement semantics **MUST** be documented

---

## 12. Automation Subsystems

### 12.1 Salt (Bootstrap & Discovery)

* Enrollment gated
* Identity-bound
* Minimal scope

### 12.2 Ansible (Convergence)

* Idempotent
* Re-runnable
* Destructive actions require explicit opt-in

---

## 13. Kubernetes Reference Workload

### 13.1 Purpose

Kubernetes exists to **prove the platform**, not define it.

### 13.2 Join Constraints

* Node CSRs **MUST NOT** be approved without attestation
* Node identity **MUST** map to artifact lineage

### 13.3 HA Model

* Odd control-plane quorum
* Failure-domain aware placement

---

## 14. Convergence DAG

kubedos convergence is a **strict DAG**:

1. Attestation gate
2. Network backplanes
3. Enrollment
4. Convergence
5. Workload bring-up
6. Seal & acceptance

---

## 15. ClusterSpec

A single declarative **ClusterSpec** defines:

* topology
* trust policy
* networking
* storage
* workloads

All destructive behavior **MUST** be explicitly enabled.

---

## 16. Outputs

Every run emits:

* Artifacts
* SBOMs
* Provenance
* Signatures
* Recovery bundle

Outputs are **append-only**.

---

## 17. Acceptance Criteria

A deployment is valid only if:

* All nodes attest successfully
* All backplanes are reachable
* Kubernetes reference workload is healthy
* Replacement drills succeed

---

## 18. Operational Runbooks

### 18.1 Node Compromise

1. Fence
2. Revoke
3. Destroy
4. Replace

### 18.2 Total Loss

1. Retrieve recovery bundle
2. Rebuild from artifact
3. Re-attest
4. Resume

---

## 19. Documentation and Code Standards

* Deterministic
* Idempotent
* No hidden state
* No silent fallbacks

---

## 20. Glossary

* **Artifact:** signed OS output
* **Attestation:** hardware-backed proof of identity
* **Recovery Bundle:** rebuild anchor

---

## 21. Appendix A: One-Page Audit Checklist

* Secure Boot enforced
* TPM measured boot verified
* Attestation gated enrollment
* Replace-not-repair drills passed

---

## Final Assertion

kubedos does not attempt to “secure Kubernetes”.

It **removes Kubernetes’ most dangerous assumption**:

> *That nodes are trustworthy by default.*

By enforcing hardware-rooted identity, measured boot, and attestation-gated existence, kubedos produces **provable, disposable, reproducible infrastructure**.

If a node drifts, fails, or is compromised — it is cheaper to delete it than to investigate it.

That is the platform.


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

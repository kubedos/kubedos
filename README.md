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

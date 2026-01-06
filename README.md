# Kube'd'OS (kubedOS) — Atomic Cluster OS & Lifecycle Platform
**Status:** Draft / Test Spec (single-file)  
**Audience:** Platform/SRE/Infra engineers (Linux + Networking + Storage + K8s + Proxmox fluent)  
**Tagline:** *Build the world. Every time.*  
**Keywords:** Proxmox VE, Ansible, Salt, WireGuard, Cilium, Hubble, eBPF, OpenZFS, Ceph, kubeadm HA, Prometheus, Grafana, Loki, SBOM, provenance, air-gapped, dark-site, time-capsule, Talos OS (reference)

---

## Table of Contents

1. [Abstract](#1-abstract)  
2. [Normative Language](#2-normative-language)  
3. [Core Philosophy](#3-core-philosophy)  
4. [Goals and Non-Goals](#4-goals-and-non-goals)  
5. [System Model](#5-system-model)  
6. [Determinism, Reproducibility, and Supply Chain](#6-determinism-reproducibility-and-supply-chain)  
7. [Threat Model and Security Posture](#7-threat-model-and-security-posture)  
8. [Build System](#8-build-system)  
   8.1 [Build Server Requirements](#81-build-server-requirements)  
   8.2 [Build Inputs and Outputs](#82-build-inputs-and-outputs)  
   8.3 [Build Stages and DAG](#83-build-stages-and-dag)  
   8.4 [Sealing, Signing, and Provenance](#84-sealing-signing-and-provenance)  
9. [Targets](#9-targets)  
   9.1 [Target Types](#91-target-types)  
   9.2 [Target Requirements](#92-target-requirements)  
   9.3 [Target Bootstrap Contract](#93-target-bootstrap-contract)  
10. [Networking Architecture](#10-networking-architecture)  
    10.1 [Backplane Model](#101-backplane-model)  
    10.2 [Planes, Addressing, Routing](#102-planes-addressing-routing)  
    10.3 [No Accidental Overlay Policy](#103-no-accidental-overlay-policy)  
11. [Storage Architecture](#11-storage-architecture)  
12. [Automation Subsystems](#12-automation-subsystems)  
13. [Kubernetes Reference Workload](#13-kubernetes-reference-workload)  
14. [Convergence DAG](#14-convergence-dag)  
15. [ClusterSpec](#15-clusterspec)  
16. [Outputs](#16-outputs)  
17. [Acceptance Criteria](#17-acceptance-criteria)  
18. [Operational Runbooks](#18-operational-runbooks)  
19. [Documentation and Code Standards](#19-documentation-and-code-standards)  
20. [Glossary](#20-glossary)  
21. [Appendix A: One-Page Audit Checklist](#21-appendix-a-one-page-audit-checklist)

---

## 1. Abstract

**Kube'd'OS** is an **atomic, self-deploying clustered platform** that manufactures a complete, secure, reproducible infrastructure base from raw hardware, hypervisors, or cloud instances — in **one convergent operation**.

The platform is built around a single uncompromising premise:

> **If infrastructure cannot be rebuilt from nothing, anywhere, at any time, it is already broken.**

Kube'd'OS produces a **single deployable cluster artifact** (the unit), not a pile of hand-tended machines. Kubernetes is included as a **reference workload** because it validates the entire platform surface: identity, networking, storage, HA, observability, and lifecycle.

Kube'd'OS aims for **Borg-like operational posture**: connectivity, replaceability, and replication are platform primitives. Workloads are cattle — **and the hosts are cattle too**.

---

## 2. Normative Language

This document uses RFC-style key words:

- **MUST / MUST NOT**: absolute requirement  
- **SHOULD / SHOULD NOT**: strong recommendation  
- **MAY**: optional behavior  

---

## 3. Core Philosophy

### 3.1 The Unit Is the Artifact
- A cluster is a **single deployable object**.
- **Exact inputs → exact artifact → exact clone → equivalent behavior**.

### 3.2 Proxmox Is Master (When Used)
- Proxmox defines VM lifecycle, templates, bridges, VLANs, storage, tags, placement.
- All Proxmox state **MUST** be representable as **idempotent Ansible IaC**.

### 3.3 Backplanes Come First
- Kernel-native L3 backplanes (WireGuard planes) **MUST** exist before orchestration.
- Orchestration runs **on top** of backplanes.

### 3.4 Graph-Based Deployment
Ordering is a DAG, not vibes. Dependencies are explicit.

---

## 4. Goals and Non-Goals

### 4.1 Goals
Kube'd'OS **MUST** provide:

1. **Atomic manufacturing** of a full platform from declared inputs  
2. **Air-gap survivability** (no external repos after boot)  
3. **Deterministic rebuild** (defined in §6)  
4. **Explicit multi-plane backplanes** (wg planes)  
5. **Host replaceability** as a first-class operation  
6. **Auditable supply chain** (SBOM + provenance + signatures)  
7. **HA reference workload** (Kubernetes + Cilium/Hubble + monitoring baseline)  

### 4.2 Non-Goals
Kube'd'OS is **NOT**:
- a general-purpose Linux distribution
- a “latest from the internet” bootstrapper
- a hosted SaaS control plane
- an implicit overlay networking platform by default

---

## 5. System Model

### 5.1 Fixed Layer Order
1. Substrate (metal / Proxmox / cloud)  
2. Node identity + first boot  
3. Kernel networking backplanes  
4. Security baseline  
5. Discovery & coordination (Salt)  
6. Idempotent convergence (Ansible)  
7. Workloads (Kubernetes reference)  
8. Seal + provenance (rebuild anchor)  

### 5.2 Artifacts
A successful build produces:
- **Platform Artifact**: bootable image(s) for one or more targets  
- **Recovery Bundle**: ClusterSpec + manifests + SBOM + signatures + tests  

---

## 6. Determinism, Reproducibility, and Supply Chain

### 6.1 Determinism Contract
Kube'd'OS determinism means:

- **Input-deterministic:** same ClusterSpec + artifact version + pinned payloads → equivalent converged state  
- **Audit-deterministic:** provenance explains exactly what was built and why  
- **Recovery-deterministic:** rebuild procedures are mechanical  

Bit-for-bit identical images are a **MAY**; functional determinism is a **MUST**.

### 6.2 Pinned Dependencies
The platform **MUST** pin versions for:
- OS packages and kernel
- Salt and Ansible runtimes
- container images required for platform and reference workload
- Kubernetes and critical addons (kubeadm components, Cilium, Hubble)
- observability stack if embedded (Prometheus/Grafana/Loki)

### 6.3 SBOM and Provenance
The build **MUST** emit:
- SBOM (OS packages + container images + shipped binaries)
- Provenance metadata (git commit, build tool versions, timestamps, build host identity policy)

### 6.4 Signatures
The build **MUST** sign:
- platform artifact(s)
- recovery bundle manifests (and optionally all payloads)

---

## 7. Threat Model and Security Posture

### 7.1 Baseline Threats
Designed to tolerate:
- total substrate loss (redeploy from artifact)
- loss/compromise of individual nodes (fence + replace)
- operator error at scale (rebuild beats repair)
- supply-chain drift (pinned + signed + offline)

### 7.2 Trust Bootstrap (Required)
Kube'd'OS **MUST** define a bootstrap trust model. Recommended default:
- offline root CA
- per-cluster intermediate CA
- per-node identity (cert/keypair) issued at enrollment

### 7.3 Enrollment and Revocation
Kube'd'OS **MUST** support:
- gated enrollment (token + pin / offline approval)
- revocation and rotation of:
  - WireGuard keys
  - node identities
  - Kubernetes certs (as defined)

### 7.4 Baseline Hardening
Kube'd'OS **MUST** define:
- SSH policy (key-only, allowed users/groups, cipher baseline)
- firewall policy (default deny inbound on non-plane interfaces)
- kernel/sysctl baseline
- logging/audit strategy

---

## 8. Build System

Kube'd'OS is manufactured by a **build server** that produces **portable target artifacts** and a **recovery bundle**.

### 8.1 Build Server Requirements

The build server is a *deterministic manufacturing environment*, not a “developer workstation”.

**Hardware / execution**
- MUST run Linux (x86_64) with a stable kernel/toolchain.
- SHOULD be dedicated (or a hardened VM) to avoid tool drift.
- MUST have sufficient CPU/RAM/storage for image construction and caching.

**Connectivity**
- MUST be able to build in two modes:
  - **Online mode:** to refresh mirrors, registries, and upstream release pins intentionally
  - **Offline mode:** rebuild artifacts from cached inputs and locked manifests
- SHOULD support a local mirror/cacher for:
  - OS packages
  - container registry content
  - git dependencies (if any)

**Security posture**
- MUST store signing keys in a controlled manner:
  - preferred: offline signing or HSM/TPM-backed keys
  - acceptable: encrypted key material with strict access and audit
- MUST produce tamper-evident logs for build runs.

**Determinism control**
- MUST pin all build tooling versions (containerized build toolchain or pinned packages).
- MUST generate a build manifest recording:
  - tool versions
  - host identity policy
  - input checksums
  - output checksums

### 8.2 Build Inputs and Outputs

**Inputs (required)**
- ClusterSpec (validated schema)
- Version locks (platform + payload pins)
- Package and image manifests (declared sets)
- Cryptographic policy (CA mode, signing policy)
- Target matrix (what images to produce)

**Outputs (required)**
- One or more **Target Artifacts** (see §9)
- Recovery Bundle:
  - ClusterSpec (final rendered)
  - artifact manifest(s)
  - SBOM(s)
  - provenance metadata
  - signatures
  - acceptance test report template/results

### 8.3 Build Stages and DAG

Build server manufacturing is a DAG with explicit gates:

1. **Spec Validation Gate**
   - Validate ClusterSpec + constraints
2. **Resolve + Lock Gate**
   - Resolve upstream versions → write immutable lockfiles
3. **Acquire Inputs Gate**
   - Download/sync packages and images into a local content store
4. **Assemble RootFS / Base Image Gate**
   - Construct base OS layer and hardening baseline
5. **Embed Payloads Gate**
   - Salt/Ansible runtime, cluster logic, offline repos, container images
6. **Target Image Build Gate**
   - Produce target-specific artifact(s) (Proxmox template image, ISO, cloud image)
7. **Seal Gate**
   - Hash, SBOM, sign, provenance emit
8. **Acceptance Preflight Gate**
   - Static checks (manifests complete, signatures valid, schema ok)

### 8.4 Sealing, Signing, and Provenance

A build is not “real” until sealed.

**Sealing MUST include**
- cryptographic hashes of every artifact output
- SBOM generation
- provenance record (git commit, lockfile hashes, toolchain versions)
- signatures over:
  - manifests
  - artifact hashes

**Sealing SHOULD include**
- reproducibility note: how to rebuild *this* artifact from the same locks
- artifact naming convention that encodes:
  - kubedOS version
  - target type
  - build date
  - content hash prefix

---

## 9. Targets

A **target** is any substrate-specific output format that can be booted or imported to create nodes.

### 9.1 Target Types

Kube'd'OS SHOULD support the following target types:

1. **Proxmox Target**
   - QEMU-compatible disk image suitable for conversion into a VM template
   - Includes cloud-init or firstboot mechanism compatible with Proxmox workflows
2. **Bare Metal Target**
   - Bootable ISO or raw disk image for direct installation/boot
3. **Cloud Target**
   - Cloud image formats (e.g., raw/qcow2) suitable for import into cloud providers
   - No dependency on hosted control planes beyond basic instance provisioning

### 9.2 Target Requirements

All targets **MUST** satisfy:
- boot-to-converge without requiring internet access
- firstboot includes:
  - identity seed
  - backplane bring-up
  - enrollment + discovery hooks
- embedded offline content:
  - OS packages required for converge
  - container images required for platform + reference workload
- clear separation:
  - platform manufacturing logic baked in
  - environment-specific config layered via ClusterSpec and/or post-config

### 9.3 Target Bootstrap Contract

On first boot, each target node **MUST**:
1. Establish baseline OS identity (hostname, users, SSH policy)
2. Apply baseline hardening
3. Bring up WireGuard backplanes (wg planes)
4. Enroll into cluster coordination (Salt) under gating rules
5. Expose readiness signals over the control plane (wg1)
6. Await converge orchestration steps (Ansible)

Targets **MUST NOT**:
- “phone home” to public repos
- silently pull latest images
- accept unauthenticated join attempts

---

## 10. Networking Architecture

### 10.1 Backplane Model
Kube'd'OS networking is defined by **explicit WireGuard L3 planes**. Planes are:
- kernel-level
- explicitly addressed (CIDR per plane)
- policy-defined (default deny between planes unless allowed)

### 10.2 Planes, Addressing, Routing

Reference plane set (names conventional):
- **wg1:** control / SSH / Salt / Ansible
- **wg2:** observability transport (metrics/logs/traces)
- **wg3:** Kubernetes backend (control-plane ↔ worker + east-west as defined)

Requirements:
- Each plane MUST have a CIDR in ClusterSpec.
- Node plane addresses MUST be static or deterministically derived.
- Inter-plane flows MUST be explicit.
- Default MUST be deny for inter-plane.

### 10.3 No Accidental Overlay Policy
Kube'd'OS **MUST NOT** deploy a userland overlay network “by surprise”.
If overlay-like behavior is required, it MUST be explicitly declared and auditable.

---

## 11. Storage Architecture

### 11.1 OpenZFS
Kube'd'OS SHOULD support OpenZFS for:
- integrity-first root/state
- snapshots/rollback
- template sealing and clone safety

### 11.2 Ceph
Kube'd'OS MAY integrate Ceph for replicated storage.
If enabled, ClusterSpec MUST define:
- failure domains
- replication size/min_size
- network binding (which plane)
- recovery behavior

---

## 12. Automation Subsystems

### 12.1 Salt (Bootstrap + Discovery)
Salt MUST be identity-bound and enrollment-gated.
Use Salt for:
- join workflows
- peer enumeration
- bootstrap coordination

### 12.2 Ansible (Idempotent Converge)
Ansible MUST:
- converge roles idempotently
- be safe to re-run
- document which operations are destructive and require explicit enablement

---

## 13. Kubernetes Reference Workload

### 13.1 HA Model
Kube'd'OS MUST document HA topology:
- control-plane replica count and quorum requirements
- etcd topology (stacked vs external) and tradeoffs
- failure domains and placement

### 13.2 Cilium + Hubble
Kube'd'OS SHOULD ship Kubernetes with:
- **Cilium** as the CNI
- **Hubble** enabled for flow visibility

The system MUST document:
- policy defaults
- plane bindings and exposure model
- minimum required kernel features

### 13.3 Observability Baseline
Kube'd'OS SHOULD include pinned patterns for:
- Prometheus
- Grafana
- Loki

Bound intentionally to the observability plane (wg2) by default.

---

## 14. Convergence DAG

Kube'd'OS convergence is a **strict DAG**. Each stage has:
- **Inputs** (what it consumes)
- **Outputs** (what it produces)
- **Idempotency contract** (what is safe to re-run)
- **Destruction boundary** (what requires explicit opt-in)

### 14.1 Canonical DAG

**Stage 0 — Spec Validation**
- **Inputs:** ClusterSpec, schema, policy constraints, version locks (or lock policy)
- **Outputs:** validated + normalized spec, rendered inventories, target matrix, plan graph
- **Idempotency:** **SAFE** (pure)
- **Destructive:** **NO**

**Stage 1 — Substrate Provision**
- **Inputs:** validated spec, substrate credentials, placement + storage policy
- **Outputs:** nodes instantiated (VMs/instances), NIC attachments, VLAN tags, storage volumes, metadata/tags
- **Idempotency:** **SAFE** if using non-destructive reconcile; drift is reconciled where possible
- **Destructive:** **MAYBE** (only when `spec.substrate.allowDestroy=true`)

**Stage 2 — Firstboot Identity + Baseline**
- **Inputs:** target artifact, node identity seed mechanism, baseline hardening policy
- **Outputs:** host identity, SSH policy enforced, firewall baseline, immutable markers, bootstrap logs
- **Idempotency:** **SAFE** (re-run results in no-op or re-assert)
- **Destructive:** **NO**

**Stage 3 — Backplanes Up (Kernel WireGuard Planes)**
- **Inputs:** plane CIDRs + node assignments, key material policy, routing policy
- **Outputs:** wg1/wg2/wg3 interfaces up, routes installed, plane firewall policy enforced
- **Idempotency:** **SAFE** (re-assert interface config + peers)
- **Destructive:** **NO** (rotation is explicit, see §18.3)

**Stage 4 — Enrollment + Discovery (Salt)**
- **Inputs:** enrollment gating policy, CA policy, join tokens/pins, node attest/identity
- **Outputs:** authenticated membership, peer inventory, role mapping, reachable matrix
- **Idempotency:** **SAFE** (repeatable enrollment checks)
- **Destructive:** **NO** (revocation is explicit)

**Stage 5 — Platform Converge (Ansible)**
- **Inputs:** rendered inventories, platform roles, offline repos, pinned payload manifests
- **Outputs:** storage primitives prepared, runtime deps installed, services configured and bound to planes
- **Idempotency:** **SAFE** by default; drift remediation per role contract
- **Destructive:** **MAYBE** (only with explicit role flags such as `allowRepartition`, `allowWipe`)

**Stage 6 — Reference Workload Bring-up (Kubernetes)**
- **Inputs:** HA topology, PKI policy, kubeadm config, Cilium/Hubble config, registries (offline)
- **Outputs:** HA control plane, workers joined, Cilium + Hubble healthy, baseline observability online
- **Idempotency:** **SAFE** for reconciliation steps; cluster init is **ONCE**
- **Destructive:** **MAYBE** (reset requires explicit `kubernetes.allowReset=true`)

**Stage 7 — Seal + Emit**
- **Inputs:** final state inventory, test results, manifests, SBOM/provenance/signature policy
- **Outputs:** recovery bundle, signed manifests, snapshot/template seals (where applicable), CI artifacts
- **Idempotency:** **SAFE** (re-emit consistent outputs; signatures may differ if timestamped)
- **Destructive:** **NO**

### 14.2 Stage Contracts: Re-run Safety Matrix

| Stage | Safe to Re-run | Drift Remediated | Can Destroy | Requires Explicit Opt-in |
|------:|:---------------:|:----------------:|:-----------:|:------------------------:|
| 0 Spec Validation | ✅ | n/a | ❌ | ❌ |
| 1 Substrate Provision | ✅ | ✅ (bounded) | ⚠️ | ✅ `allowDestroy` |
| 2 Firstboot | ✅ | ✅ | ❌ | ❌ |
| 3 Backplanes | ✅ | ✅ | ❌ | ❌ |
| 4 Enrollment/Discovery | ✅ | ✅ | ❌ | ❌ (revocation separate) |
| 5 Platform Converge | ✅ | ✅ | ⚠️ | ✅ per-role allow flags |
| 6 Kubernetes | ✅* | ✅ | ⚠️ | ✅ `allowReset` |
| 7 Seal/Emit | ✅ | n/a | ❌ | ❌ |

\* Kubernetes init is a one-time action; reconciliation is repeatable.

### 14.3 Ordering Guarantees (Non-Negotiable)
- **Backplanes MUST exist** before any orchestration that assumes connectivity.
- **Enrollment MUST be gated** before nodes are allowed to participate.
- **Workloads MUST NOT start** before platform primitives (storage, PKI, networking policy) are asserted.
- **Sealing MUST NOT occur** before acceptance results are recorded.

---

## 15. ClusterSpec

Kube'd'OS **MUST** use a single declarative ClusterSpec (YAML) as the authoritative input. It is the contract between:
- build server (manufacturing)
- substrate provisioner (targets)
- orchestration layers (Salt/Ansible)
- workload bring-up (Kubernetes)

### 15.1 Schema Design Rules
- Every field is either:
  - **declarative desired state**, or
  - **policy boundary** (explicit opt-in for destructive behavior)
- No “magic defaults” that hide topology. Defaults MUST be safe and MUST be documented.
- Version references MUST be resolved to locks during manufacturing (see §8.3 earlier).

### 15.2 Illustrative ClusterSpec (Extended)

```yaml
apiVersion: kubedos.ca/v1alpha1
kind: Cluster
metadata:
  name: lab-01
  artifactVersion: "0.1.0"
  labels:
    owner: platform
    purpose: reference
spec:
  # ---- Substrate (Target + Provision) ----
  substrate:
    type: proxmox
    allowDestroy: false        # explicit boundary for destructive reconcile
    proxmox:
      clusterName: pve-01
      vmidRange: { start: 2000, end: 2099 }
      placement:
        strategy: spread
        by: [node, failureDomain]
      bridges:
        - name: vmbr0
          vlanAware: true
          trunks: [10, 20, 30]
      storagePools:
        - name: fast-zfs
          type: zfs
      tags:
        - kubedos
        - "artifact:0.1.0"

  # ---- Nodes (Roles + Failure Domains) ----
  nodes:
    failureDomains:
      - name: rack-a
      - name: rack-b
    inventory:
      - name: cp-1
        role: control-plane
        failureDomain: rack-a
        resources: { cpu: 4, memoryMiB: 8192 }
        disks:
          - { pool: fast-zfs, sizeGiB: 64, purpose: os }
        nics:
          - { bridge: vmbr0, vlan: 10, purpose: uplink }
      - name: cp-2
        role: control-plane
        failureDomain: rack-b
        resources: { cpu: 4, memoryMiB: 8192 }
        disks:
          - { pool: fast-zfs, sizeGiB: 64, purpose: os }
        nics:
          - { bridge: vmbr0, vlan: 10, purpose: uplink }
      - name: cp-3
        role: control-plane
        failureDomain: rack-a
        resources: { cpu: 4, memoryMiB: 8192 }
        disks:
          - { pool: fast-zfs, sizeGiB: 64, purpose: os }
        nics:
          - { bridge: vmbr0, vlan: 10, purpose: uplink }
      - name: w-1
        role: worker
        failureDomain: rack-a
        resources: { cpu: 8, memoryMiB: 16384 }
        disks:
          - { pool: fast-zfs, sizeGiB: 128, purpose: os }
        nics:
          - { bridge: vmbr0, vlan: 10, purpose: uplink }

  # ---- Networking (Planes + Policy) ----
  networking:
    planes:
      wg1: { cidr: 10.101.0.0/24, purpose: control }
      wg2: { cidr: 10.102.0.0/24, purpose: observability }
      wg3: { cidr: 10.103.0.0/24, purpose: kubernetes-backend }
    addressing:
      mode: deterministic     # deterministic / static / dhcp-resolved (must be explicit)
    policy:
      defaultInterPlane: deny
      allow:
        - { from: wg1, to: wg3, ports: ["6443/tcp","2379-2380/tcp","10250/tcp"] }
        - { from: wg2, to: wg3, ports: ["9090/tcp","3000/tcp","3100/tcp"] }

  # ---- Security (Trust + Enrollment + Rotation) ----
  security:
    bootstrap:
      model: offline-ca       # offline-ca / pinned-ca / to-fu (TOFU discouraged)
      caFingerprint: "sha256:REDACTED"
    enrollment:
      mode: token+pin         # token+pin / offline-approve / cert-preseed
      joinWindowMinutes: 30
    ssh:
      allowUsers: ["ops"]
      passwordAuth: false
    rotation:
      wireguardDays: 30
      nodeCertDays: 90
      kubeCertDays: 90

  # ---- Storage (ZFS + Ceph) ----
  storage:
    zfs:
      enabled: true
      pools: ["fast-zfs"]
      snapshotPolicy:
        system: { hourly: 24, daily: 7, weekly: 4 }
    ceph:
      enabled: false
      # if enabled, must define size/min_size/failureDomains/plane binding, etc.

  # ---- Orchestration ----
  orchestration:
    salt:
      enabled: true
      purpose: bootstrap+discovery
    ansible:
      enabled: true
      purpose: converge+lifecycle
      safety:
        allowRepartition: false
        allowWipe: false

  # ---- Kubernetes Reference Workload ----
  kubernetes:
    enabled: true
    allowReset: false
    version: "v1.30.x"        # resolved to locks at build time
    ha:
      controlPlaneReplicas: 3
      etcd: stacked
    cni:
      name: cilium
      hubble: true
      policyDefault: deny
    observability:
      enabled: true
      stack:
        prometheus: true
        grafana: true
        loki: true
      bindPlane: wg2

  # ---- Acceptance + Drills ----
  acceptance:
    mttrTargetMinutes: 30
    required:
      - backplane-matrix
      - security-baseline
      - k8s-health
      - cilium-health
      - hubble-flows
    drills:
      - name: delete-worker
        expectRecoveryMinutes: 10
      - name: delete-control-plane
        expectRecoveryMinutes: 20
```
### 15.3 Mandatory Validation Constraints

A ClusterSpec is invalid unless:

- **HA control-plane replicas** are **odd** and **≥ 3** (when HA is enabled)
- **Plane CIDRs** do **not overlap**
- **Default inter-plane policy** is defined (**deny recommended**)
- **All destructive flags** are **explicit** (no implicit `true`)
- **Bridge/VLAN trunks** are consistent with **NIC VLAN assignments**
- If **Ceph** is enabled, **node count + failure domains** satisfy the **replication policy**

---

## 16. Outputs (Rebuild Anchors)

A successful run **MUST** emit artifacts that make the system **rebuildable** and **auditable** without internet.

### 16.1 Required Outputs

- **Artifact Manifest**
  - versions, hashes, target matrix, embedded payload versions (resolved locks)

- **SBOM**
  - OS packages + container images + shipped binaries

- **Provenance Record**
  - git commit, lockfile hashes, toolchain versions, build host policy

- **Recovery Bundle**
  - rendered ClusterSpec, manifests, SBOM, provenance, signatures, runbooks, acceptance report

- **Acceptance Report**
  - pass/fail per gate + captured evidence

### 16.2 Output Directory Contract (Illustrative)

```text
out/
  artifacts/
    kubedos-0.1.0-proxmox-qcow2-<hash>.img
    kubedos-0.1.0-baremetal-iso-<hash>.iso
  manifests/
    artifact-manifest.json
    locks.json
  sbom/
    os.spdx.json
    images.spdx.json
  provenance/
    build.json
    inputs.json
  signatures/
    manifests.sig
    artifacts.sig
  recovery-bundle/
    clusterspec.rendered.yaml
    runbooks.md
    acceptance-report.json
```

## 17. Acceptance Criteria (Definition of Done)

A build is **DONE** only if acceptance gates pass and results are recorded.

---

### 17.1 Mandatory Gates

#### Gate: Backplane Matrix
- Every node **MUST** be reachable over **wg1**
- If **wg2** is enabled, observability endpoints **MUST** be reachable over **wg2**
- **wg3** **MUST** provide required Kubernetes backend connectivity

#### Gate: Security Baseline
- SSH password auth disabled
- allowed users enforced
- firewall default deny on non-plane interfaces
- enrollment gating enforced (no anonymous joins)

#### Gate: Kubernetes Health (if enabled)
- kube-apiserver reachable via intended plane
- etcd quorum healthy (or external etcd reachable)
- workers Ready

#### Gate: Cilium + Hubble (if enabled)
- cilium healthy on all nodes
- hubble healthy
- a test flow is observed and recorded

#### Gate: Observability Stack (if enabled)
- Prometheus targets present (minimum: platform + k8s core)
- Grafana reachable on declared plane
- Loki sanity checks pass (ingest + query)

### 17.2 Drills (CI Mandatory; Prod Scheduled)
- **delete-worker:** destroy a worker node; replacement converges within RTO
- **delete-control-plane:** destroy a control-plane node; quorum holds; replacement converges within RTO

Reports **MUST** record timestamps, recovery time, and any manual intervention (ideally zero).

---

## 18. Operational Runbooks (Replace, Don’t Repair)

### 18.1 Total Loss (Substrate Gone)
- Retrieve last known-good artifact + recovery bundle (offline)
- Provision substrate from IaC
- Boot targets
- Enrollment/discovery under gating policy
- Converge platform (Ansible)
- Bring up workloads (Kubernetes reference)
- Restore state as declared (etcd snapshots, storage recovery as applicable)
- Run acceptance suite; archive report

### 18.2 Compromised Node
- Fence node (deny scheduling + remove from plane trust)
- Revoke node identity + WireGuard keys
- Drain workloads if possible
- Destroy node
- Provision replacement from artifact
- Rotate impacted credentials (scope depends on compromise boundary)
- Run acceptance suite; archive report

### 18.3 Rotation Procedures (Mandatory)

Rotation **MUST** be schedulable, recorded, and bounded in blast radius.

Minimum rotations:
- WireGuard keys per `security.rotation.wireguardDays`
- node certs per `nodeCertDays`
- Kubernetes PKI per `kubeCertDays` (or topology-defined policy)

Rotation runs **MUST**:
- preserve plane connectivity via staged rollout
- avoid full-cluster outage unless explicitly planned
- emit a new acceptance report

### 18.4 Upgrade Strategy (Platform + Workloads)

Upgrades **MUST** be treated as manufacturing events:
- produce a new artifact with new locks
- validate in staging
- run drills
- roll out using declared strategy:
  - rolling replace
  - surge replace
  - blue/green cluster swap (preferred when feasible)

---

## 19. Documentation and Code Standards (Ultra-High Bar)

### 19.1 Implementation Quality
- idempotent by default
- deterministic ordering (DAG enforced)
- no hidden imperative steps
- no silent fallbacks for security/network/storage

### 19.2 Shell and Systems Code
- `set -euo pipefail`
- shellcheck-clean
- structured logs (machine-readable)
- explicit error classes and consistent exit codes

### 19.3 Ansible Standards
- modular roles; single-purpose
- each role documents:
  - inputs/outputs
  - re-run behavior
  - destructive boundaries (off by default)
- avoid `shell:`; if necessary, guard for idempotency and capture outputs

### 19.4 Salt Standards
- bootstrap/discovery only (no endless config sprawl)
- enrollment gated + identity-bound
- pillar/state schema validation where feasible

### 19.5 Documentation Standards

Docs **MUST** include:
- architecture + DAG
- threat model + trust bootstrap + rotation + revocation
- target bootstrap contract
- failure domain assumptions
- acceptance gates and how to reproduce
- runbooks for loss/compromise/rotation/upgrade

---

## 20. Glossary

- **Artifact:** bootable platform output for a target.
- **Recovery Bundle:** offline rebuild anchor with ClusterSpec, manifests, SBOM, provenance, signatures, runbooks, and acceptance results.
- **Backplane/Plane:** kernel WireGuard L3 network for a specific traffic class.
- **Convergent:** re-runnable process that reaches declared state.
- **Destruction Boundary:** explicit opt-in flag required before destructive actions.
- **Reference Workload:** validation workload included to prove platform capability.

---

## 21. Appendix A: One-Page Audit Checklist

### Spec
- [ ] Schema validated
- [ ] Constraints enforced (quorum, CIDR non-overlap, VLAN trunks)
- [ ] Destructive flags explicitly set

### Manufacturing
- [ ] Locks resolved and stored
- [ ] Offline content store populated
- [ ] SBOM generated
- [ ] Provenance generated
- [ ] Artifacts hashed and signed
- [ ] Recovery bundle emitted

### Targets
- [ ] Boots without internet
- [ ] Firstboot asserts identity + hardening
- [ ] Backplanes up before orchestration
- [ ] Enrollment gated and audited

### Networking
- [ ] wg1 matrix passes
- [ ] wg2 passes (if enabled)
- [ ] wg3 backend passes
- [ ] default deny inter-plane; allow rules explicit

### Security
- [ ] SSH password auth disabled
- [ ] firewall enforced
- [ ] revocation and rotation procedures defined

### Kubernetes
- [ ] HA healthy
- [ ] Cilium healthy
- [ ] Hubble flows observed and recorded
- [ ] monitoring reachable on intended plane

### Replaceability
- [ ] delete-worker drill passes within target
- [ ] delete-control-plane drill passes within target
- [ ] acceptance report archived


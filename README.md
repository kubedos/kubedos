# Kube'd'OS (kubedOS) — Atomic Cluster OS & Lifecycle Platform
**Status:** Draft / Test Spec (single-file)  
**Audience:** Systems engineers, SREs, platform engineers (Linux/K8s/Networking/Storage/Proxmox fluent)  
**Tagline:** *Build the world. Every time.*  
**Keywords:** Proxmox VE, Ansible, Salt, WireGuard, Cilium, Hubble, eBPF, OpenZFS, Ceph, kubeadm HA, Prometheus, Grafana, Loki, SBOM, SLSA, air-gapped, dark-site, time-capsule

---

## 0. Abstract

**Kube'd'OS** is an **atomic, self-deploying clustered platform** that manufactures a complete, secure, reproducible infrastructure base from raw hardware, hypervisors, or cloud instances — in **one convergent operation**.

The system is designed around a non-negotiable premise:

> **If infrastructure cannot be rebuilt from nothing, anywhere, at any time, it is already broken.**

Kube'd'OS produces a **single deployable cluster artifact** (the unit), not a pile of manually tended machines. Kubernetes is included as a **reference workload** because it exercises the full platform surface area (networking, identity, storage, HA, observability). Kube'd'OS is intentionally **vendor-free** and **substrate-agnostic**.

Kube'd'OS aims for **Borg-like operational posture**: connectivity, replaceability, and replication are **platform primitives**, so not only workloads are cattle — **hosts are cattle too**.

> Related ethos: **Talos OS** (immutable, Kubernetes-first). Kube'd'OS shares the “replace, don’t repair” philosophy, while emphasizing **artifact-centric cluster manufacturing**, **explicit backplanes**, and **Proxmox-native IaC**.

---

## 1. Normative Language

This document uses RFC 2119-style key words:

- **MUST / MUST NOT**: absolute requirement
- **SHOULD / SHOULD NOT**: strong recommendation
- **MAY**: optional capability

Where “deterministic” is stated, it refers to the defined build contract in §5.

---

## 2. Core Philosophy (Non-Negotiables)

### 2.1 The Unit Is the Artifact
- A **cluster** is a single deployable object.
- **Exact code → exact artifact → exact clone → exact behavior.**
- Human intervention is treated as a failure mode.

### 2.2 Proxmox Is Master (When Using Proxmox)
- Proxmox defines VM lifecycle, templates, storage, bridges, VLAN trunks, placement, and tags.
- All Proxmox-managed state **MUST** be representable as **Ansible IaC** (idempotent, non-destructive).

### 2.3 Backplanes Come First
- Kernel-native L3 networking (WireGuard planes) **MUST** be established during first boot.
- Orchestration (Salt/Ansible/Kubernetes) runs **on top** of the backplanes.
- No accidental userland overlay networking “just because it works.”

### 2.4 Graph-Based Thinking
Infrastructure is a DAG. Ordering is explicit. Dependencies are explicit:
> clone → firstboot → backplanes → discovery → orchestration → workloads → seal

---

## 3. Goals and Non-Goals

### 3.1 Goals (What Kube'd'OS Guarantees)
Kube'd'OS **MUST** provide:

1. **Atomic cluster manufacturing**
   - One operation builds a complete platform from declared inputs.
2. **Air-gapped / dark-site survivability**
   - No external repos required after boot to converge the platform.
3. **Deterministic rebuild**
   - Given the same inputs and artifact, the resulting cluster behavior is equivalent per §5.
4. **Explicit multi-plane connectivity**
   - WireGuard L3 planes as first-class primitives, bound by intent.
5. **Host replaceability**
   - Hosts are cattle: platform supports fast node replacement without hand repair.
6. **Auditable supply chain**
   - SBOM + provenance + signatures for the artifact and major payloads.
7. **HA reference workload**
   - Kubernetes HA pattern with modern CNI visibility (Cilium + Hubble) and baseline monitoring.

### 3.2 Non-Goals (What This Is Not)
Kube'd'OS is **NOT**:
- A general-purpose Linux distribution
- A hosted SaaS control plane
- A “click-ops” platform
- A “download latest from the internet” bootstrapper
- A promise to run every arbitrary K8s topology without declared constraints

---

## 4. System Model

### 4.1 Conceptual Layers (Fixed Order)
1. **Substrate**
   - Bare metal, Proxmox VE, or cloud instance primitives
2. **Node identity + first boot**
3. **Kernel-native networking backplanes**
4. **Security baseline**
5. **Discovery & coordination (Salt)**
6. **Idempotent converge (Ansible)**
7. **Workload(s) (Kubernetes reference)**
8. **Seal & provenance (rebuild anchor)**

### 4.2 Artifact Types
Kube'd'OS produces **a platform artifact** plus **recovery artifacts**:

- **Platform Artifact** (bootable, self-contained):
  - ISO / raw disk image / cloud image (implementation-dependent)
- **Recovery Bundle** (offline anchor):
  - ClusterSpec, manifests, SBOM, signatures, keys policy, snapshot pointers, upgrade plan, and test results

---

## 5. Determinism, Reproducibility, and the Build Contract

### 5.1 Determinism Definition
Kube'd'OS determinism is defined as:

- **Input deterministic**: For a given *ClusterSpec* + artifact version + pinned payloads, the resulting system converges to an equivalent declared state.
- **Audit deterministic**: The build emits enough provenance to explain exactly what was built and why.
- **Operational deterministic**: Recovery and rebuild procedures are mechanical and repeatable.

Bit-for-bit identical disk images are a **MAY**, not a MUST, but functional determinism is a **MUST**.

### 5.2 Supply Chain Requirements
The build process **MUST**:
- Pin versions for:
  - OS packages
  - kernel
  - Kubernetes version + kubeadm components
  - Cilium + Hubble
  - Salt + Ansible runtimes
  - observability stack (Prometheus/Grafana/Loki) if embedded
- Produce an **SBOM** for:
  - OS packages
  - container images
  - binaries shipped (if any)
- Produce **provenance metadata**:
  - git commit, build tool versions, timestamps, build host identity policy
- Sign:
  - artifact
  - recovery bundle manifests
  - optionally individual payloads

Suggested bar: **SLSA-ish** posture (not necessarily full compliance, but aligned).

### 5.3 Air-Gap / Dark-Site Requirements
Kube'd'OS artifacts **MUST** include:
- OS package repository content sufficient for convergence
- Container images required for platform + reference workload
- All scripts and orchestration logic
- Any schema validation tooling required to interpret ClusterSpec

Kube'd'OS **MUST NOT** require:
- public apt/yum mirrors
- live GitHub fetches
- “curl | bash”
- external identity brokers

---

## 6. Threat Model and Security Posture

### 6.1 Threat Model (Baseline)
Kube'd'OS is designed to tolerate:
- Total loss of nodes / substrate (rebuild from artifact)
- Compromise of one node (containment and replaceability)
- Operator error at scale (mechanical redeploy beats artisanal repair)
- Supply chain drift (pinned + signed + offline payloads)

Out of scope unless explicitly enabled:
- Advanced side-channel resistance
- Fully byzantine fault tolerance across all components

### 6.2 Trust & Identity (Bootstrap)
Kube'd'OS **MUST** define a bootstrap trust model. Recommended default:

- **Offline Root CA** (stored out-of-band)
- **Cluster Intermediate CA** generated per cluster artifact run
- Node identity:
  - Each node gets a unique identity (cert/keypair)
  - Enrollment is gated (see §6.3)

### 6.3 Enrollment and Revocation
Kube'd'OS **MUST** support:
- Secure enrollment gating (token + cert pinning or offline join approval)
- Node revocation:
  - ability to revoke node identity and deny plane participation
  - ability to rotate WireGuard keys and relevant credentials

### 6.4 Secrets Handling
Kube'd'OS **MUST** document:
- Where secrets live (filesystem vs KMS vs TPM)
- How secrets are rotated
- How secrets are recovered in air-gapped mode

Implementation MAY use:
- sops + age (offline-friendly)
- sealed-secrets
- TPM-backed keys (optional)

### 6.5 Baseline Hardening Requirements
Kube'd'OS baseline **MUST** include:
- SSH: key-only, no password auth, strong ciphers, strict access policy
- Host firewall policy: default deny inbound on non-plane interfaces
- Kernel sysctls: sane network hardening baseline
- Audit strategy (auditd/eBPF policy) documented
- Minimal package surface: no “kitchen sink” images

---

## 7. Networking Architecture (Backplane Model)

### 7.1 Non-Negotiables
- Backplanes are **WireGuard**, kernel-level, L3 routed.
- Backplanes **MUST** come up during first boot.
- Services **MUST** bind intentionally to planes (no accidental exposure).

### 7.2 Planes (Reference)
A canonical three-plane model (names are conventional, not mandatory):

- **wg1 — Control Plane**
  - SSH, Salt control, Ansible, administrative API surfaces
- **wg2 — Observability Plane**
  - metrics/logs/traces transport, out-of-band debugging
- **wg3 — Kubernetes Backend Plane**
  - control-plane ↔ worker, east-west service transport if defined

### 7.3 Addressing and Routing
- Each plane **MUST** have an explicit CIDR in ClusterSpec.
- Nodes **MUST** have stable plane IPs (static or deterministically derived).
- Routing policy **MUST** be declared:
  - Allowed inter-plane flows
  - Default deny between planes unless explicitly allowed

### 7.4 “No Accidental Overlay” Policy
- Kube'd'OS **MUST NOT** deploy a userland overlay networking CNI by default as a convenience.
- If Kubernetes overlay behavior is required, it **MUST** be explicit in ClusterSpec, and **MUST** be auditable.

---

## 8. Storage Architecture

### 8.1 OpenZFS (Integrity + Rollback)
Kube'd'OS **SHOULD** support OpenZFS for:
- system state anchoring
- snapshots and rollback
- deterministic base template sealing

### 8.2 Ceph (Replication + Stateful Workloads)
Kube'd'OS **MAY** integrate Ceph as a platform primitive for:
- replicated block/object storage
- stateful workload durability

If Ceph is enabled, ClusterSpec **MUST** define:
- failure domains
- replication size / min_size
- network binding (which plane(s) carry Ceph traffic)
- recovery and rebuild semantics

---

## 9. Automation Subsystems (Salt + Ansible)

### 9.1 Separation of Deployment and Configuration (Mandatory)
- **Deployment** manufactures platform: immutable, deterministic, auditable.
- **Configuration** is layered: disposable, replaceable, environment-specific.

### 9.2 Salt (Bootstrap + Discovery + Coordination)
Salt is used where speed and coordination matter:
- secure enrollment / join workflow
- fast peer discovery
- cluster-wide execution for bootstrap steps

Salt usage **MUST** be:
- identity-bound
- minimal and intentional (bootstrap control, not endless configuration sprawl)

### 9.3 Ansible (Idempotent Convergence + Lifecycle)
Ansible is used for:
- declarative role application
- safe reruns
- auditing drift and applying intended state

Ansible runs **MUST** be:
- idempotent
- non-destructive by default
- safe-to-rerun documented per role

---

## 10. Kubernetes Reference Workload (HA-First)

### 10.1 What “Reference Workload” Means
Kubernetes is included to validate the platform. The platform is the product.

### 10.2 HA Pattern Requirements
Kube'd'OS **MUST** implement an HA pattern consistent with upstream kubeadm HA guidance:
- multiple control-plane nodes
- etcd topology documented (stacked or external)
- defined failure domains
- upgrade strategy defined (surge, rolling, or replace-based)

### 10.3 Networking and Visibility: Cilium + Hubble
Kube'd'OS **SHOULD** ship Kubernetes with:
- **Cilium** as CNI (eBPF-based networking + policy)
- **Hubble** for flow visibility

The system **MUST** document:
- datapath mode and assumptions
- policy defaults (deny/allow posture)
- how Hubble is exposed (plane binding + auth)

### 10.4 Baseline Monitoring
Kube'd'OS **SHOULD** provide a baseline observability stack pattern:
- Prometheus + Grafana + Loki (or equivalents) in a declared and pinned form
- plane binding (wg2 recommended)

---

## 11. Operational Model: Replace, Don’t Repair

### 11.1 Host Replaceability
Kube'd'OS **MUST** support a host lifecycle where:
- A node can be destroyed and replaced without hand reconfiguration.
- Replacement is achieved by:
  - provisioning from artifact (or template)
  - enrollment + backplane join
  - converge + workload reattachment

### 11.2 Self-Healing (Defined, Not Vague)
When this document says “self-healing,” it means:

- **Detect**: node is unhealthy or absent (criteria declared)
- **Fence**: remove it from scheduling / quorum participation safely
- **Replace**: provision a new node deterministically
- **Reintegrate**: converge, rejoin planes, restore workload placement

Mechanisms and thresholds **MUST** be specified in ClusterSpec (or documented defaults).

---

## 12. Convergence DAG (Ordering Guarantees)

Kube'd'OS convergence **MUST** follow this DAG:

1. **Validate Spec**
   - Validate ClusterSpec schema, constraints, and invariants.
2. **Provision Substrate**
   - Proxmox: VMs, bridges, VLAN trunks, storage attach, tags, placement.
   - Cloud/bare metal: instance primitives as declared.
3. **First Boot**
   - Disk layout, hostname, base users, baseline hardening.
4. **Backplanes Up**
   - WireGuard wg1/wg2/wg3 configured, routes installed, firewall rules applied.
5. **Discovery / Enrollment**
   - Salt enrollment, peer enumeration, identity verification.
6. **Converge Platform Roles**
   - Ansible idempotent application: runtime dependencies, storage primitives.
7. **Bring Up Reference Workload**
   - Kubernetes HA, Cilium/Hubble, baseline monitoring.
8. **Seal**
   - Snapshot templates (where applicable), emit recovery bundle, emit test results.

### 12.1 Idempotency and Safe Re-runs
For each stage, the system **MUST** document whether it is:
- Safe to re-run (no-op if already converged)
- Safe with drift (will remediate drift)
- Potentially destructive (requires explicit “allow-destroy”)

Default posture: **non-destructive**.

---

## 13. ClusterSpec (User-Facing Interface)

Kube'd'OS **MUST** have a single declarative ClusterSpec. Example schema (illustrative):

```yaml
apiVersion: kubedos.ca/v1alpha1
kind: Cluster
metadata:
  name: lab-01
  artifactVersion: "0.1.0"
  intent: "reproducible-platform"
spec:
  substrate:
    type: proxmox
    proxmox:
      clusterName: pve-01
      storagePools:
        - name: fast-zfs
          type: zfs
      bridges:
        - name: vmbr0
          vlanAware: true
          trunks: [10, 20, 30]
      tags:
        - kubedos
        - artifact:0.1.0

  nodes:
    vmidRange: { start: 2000, end: 2099 }
    failureDomains:
      - name: rack-a
      - name: rack-b
    inventory:
      - name: cp-1
        role: control-plane
        domain: rack-a
        cpu: 4
        memoryMiB: 8192
        disks:
          - pool: fast-zfs
            sizeGiB: 64
        nics:
          - bridge: vmbr0
            vlan: 10
      - name: cp-2
        role: control-plane
        domain: rack-b
        cpu: 4
        memoryMiB: 8192
        disks:
          - pool: fast-zfs
            sizeGiB: 64
        nics:
          - bridge: vmbr0
            vlan: 10
      - name: w-1
        role: worker
        domain: rack-a
        cpu: 8
        memoryMiB: 16384
        disks:
          - pool: fast-zfs
            sizeGiB: 128
        nics:
          - bridge: vmbr0
            vlan: 10

  networking:
    planes:
      wg1:
        cidr: 10.101.0.0/24
        purpose: control
      wg2:
        cidr: 10.102.0.0/24
        purpose: observability
      wg3:
        cidr: 10.103.0.0/24
        purpose: kubernetes-backend
    policy:
      defaultInterPlane: deny
      allow:
        - from: wg1
          to: wg3
          ports: ["6443/tcp", "2379-2380/tcp"]
        - from: wg2
          to: wg3
          ports: ["9090/tcp", "3100/tcp"]

  security:
    bootstrap:
      model: offline-ca
      caFingerprint: "sha256:REDACTED"
    ssh:
      allowUsers: ["ops"]
      passwordAuth: false
    keyRotation:
      wireguardDays: 30
      kubeCertDays: 90

  storage:
    zfs:
      enabled: true
      pools: ["fast-zfs"]
    ceph:
      enabled: false

  orchestration:
    salt:
      enabled: true
      enrollment: token+pin
    ansible:
      enabled: true
      mode: converge

  kubernetes:
    enabled: true
    version: "v1.30.x"   # pinned via artifact manifest
    ha:
      controlPlaneReplicas: 3
      etcd: stacked
    cni:
      name: cilium
      hubble: true
    observability:
      prometheus: true
      grafana: true
      loki: true

  acceptance:
    mttrTargetMinutes: 30
    drills:
      - name: "delete-worker-vm"
        expectRecoveryMinutes: 10
      - name: "delete-control-plane-vm"
        expectRecoveryMinutes: 20


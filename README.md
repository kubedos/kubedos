# KubeDos — Deterministic Platform Manufacturing

> **Build the platform like Kubernetes builds containers:**  
> immutable, reproducible, disposable infrastructure — anywhere.

KubeDos is a **build server + target deployment system** that manufactures **sealed platform artifacts**:
- ISO installers
- QCOW2 / RAW VM images
- VMDK for ESXi/vSphere
- Firecracker / Kata microVM rootfs + kernel bundles

…and then deploys them as **cattle**, not pets, across any substrate you can reach via **SSH** or provider tooling.

If a platform cannot be rebuilt from nothing, anywhere, at any time — it is already broken.

---

## Why KubeDos exists (the problem)

Modern infrastructure fails in predictable ways:

- server state drifts over time
- recovery becomes archaeology
- image pipelines rot
- vendor services disappear
- restore/backup operations are slow and unreliable
- "repair it live" becomes the default emergency behavior

KubeDos exists to make **full infrastructure replacement routine**.

Instead of:
> “revive the broken pets”

you do:
> “rebuild the herd”

---

## The model: Build Server + Targets

### 1) Build Server (Foundry)
The Foundry is the authoritative system that:
- builds the OS artifact (kernel → userspace → payload)
- repacks distro media (Debian, Ubuntu, RHEL, etc.)
- embeds packages + automation payloads
- generates keys / identity / bootstrap logic
- outputs artifacts for multiple target types

### 2) Targets (Deployment Substrates)
Targets are intentionally “dumb”:
- Proxmox
- QEMU/KVM
- ESXi/vSphere
- Firecracker hosts
- AWS / Azure / GCP
- bare metal

If it can boot an image (or accept one via SSH), it can be a target.

---

## Key idea: “Workloads” are OS images

KubeDos treats the OS itself like a workload artifact.

You can manufacture:
- a `master` image
- a `worker` image
- an `etcd` image
- a `grafana` image
- a `prometheus` image
- a `storage` image
- a `lb` image

…and then deploy **hundreds** of them the same way Kubernetes deploys pods.

### Example: “QA worker” fleet
If your build pipeline produces Firecracker images, you can build a `qa-worker` artifact once and then deploy:

- 10 → 100 → 1000 microVMs
- each one identical
- each one replaceable
- each one converging without needing internet access

---

## Ethos: Replace, Don’t Repair

KubeDos is built around this discipline:

✅ **No “SSH in and fix it”**  
✅ **Rebuild from artifact**  
✅ **Deterministic outputs**  
✅ **Immutable deployments**  
✅ **Kill and replace**  
✅ **Everything is cattle**  

During development you can inspect and iterate.

In production:
- nodes are disposable
- rebuild is expected
- drift is treated as a bug

---

## Artifact outputs

KubeDos can output multiple artifact types from the same pipeline:

| Artifact Type | Typical Use | Notes |
|---|---|---|
| ISO | bare metal installs, generic VM installs | repacked installer w/ payload |
| QCOW2 / RAW | Proxmox, QEMU/KVM | fast import + clone |
| VMDK | ESXi / vSphere | requires conversion tooling |
| rootfs + vmlinux | Firecracker / Kata microVMs | ultra-fast “pod-like” OS workloads |
| cloud images | AWS/Azure/GCP | upload + instantiate via CLI |

---

## Targets (what you need per substrate)

| Target | Artifact | What’s required |
|---|---|---|
| **Proxmox** | QCOW2 / ISO | SSH access to node, storage pool configured |
| **QEMU/KVM** | QCOW2 / RAW / ISO | qemu-system, qemu-img, KVM enabled |
| **ESXi/vSphere** | VMDK / ISO | govc or ovftool, datastore access |
| **Firecracker/Kata** | kernel + rootfs | firecracker installed on KVM host |
| **AWS/Azure/GCP** | cloud-native image | provider CLI configured, credentials |

---

## Quickstart (Noob Friendly)

### 1) Clone the repo
```bash
git clone https://github.com/foundrybot-ca/foundrybot
cd foundrybot

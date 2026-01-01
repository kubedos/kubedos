# kubedos — Deterministic Platform Manufacturing

> **Build the platform like Kubernetes builds containers:**  
> immutable, reproducible, disposable infrastructure — anywhere.

kubedos is a **build server + target deployment system** that manufactures **sealed platform artifacts**:
- ISO installers
- QCOW2 / RAW VM images
- VMDK for ESXi/vSphere
- Firecracker / Kata microVM rootfs + kernel bundles

…and then deploys them as **cattle**, not pets, across any substrate you can reach via **SSH** or provider tooling.

If a platform cannot be rebuilt from nothing, anywhere, at any time — it is already broken.

---

## Why kubedos exists

Modern infrastructure fails in predictable ways:

- server state drifts over time
- recovery becomes archaeology
- image pipelines rot
- vendor services disappear
- some AWS split brain tripps over a cable
- restore/backup operations are slow and unreliable
- "repair it live" becomes the default emergency behavior

kubedos exists to make **full infrastructure replacement routine & boaring**.

Instead of:
> “trying to revive the broken pets”

simply either:
“rebuild directly to the the new "target" 
"upload images to another provider, boot and go!"
"burn to USB and plug it into anything"

---

## The model: Build Server + Targets

### 1) Build Server (Foundry)
The "build-server" is where images, packages and darksite material is downloaded to, or where you can build your own "darksite" repository. There are 2 build "Types" "connected" -> "aka-use the default WAN" .. and "darksite" mode will "download" and build a custom apt directory that can be filled with upto 8TB of artifacts that are "re-packaged" into a fully deployable custom platfourm. ie: it creates custom, bootable "snapshots" that can be anything from an entire OS, to a single micro service.

ethos: Build a reliable platfoum dedicated to providing your services insted of paying amazon, or been locked into a vender.

- builds the OS artifact (kernel → userspace → payload)
- repacks distro media (Debian, Ubuntu, RHEL, etc.)
- embeds packages + automation payloads
- generates keys / identity / bootstrap logic
- outputs artifacts for multiple target types

### 2) Targets (Deployment Substrates)
Targets are intentionally “dumb”: but take 2 forms,

- an "image" file that can be "burnt" / "booted-from" or "uploaded"
  or
- delivered as a "VM" or "VMDK" or microvm, kubernetes container

IE:
- Proxmox
- QEMU/KVM
- ESXi/vSphere
- Firecracker hosts
- AWS / Azure / GCP
- bare metal

If it can boot an image, it can be a target. The only requirements for the deploy.sh is a bash shell and ssh access.  In this case the "example" deploys 1 master and 15 minions to proxmox, build a highly reliable "base" platfourm that can literally use AWS like a metal hypervisor and get rid of all of the "fluff" simply build your own "platfourm" Ive just "baked-in" a few quality of life toys.

---

## Key idea: “Workloads” are OS images

kubedos treats the OS itself like a workload artifact.

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

kubedos is built around this discipline:

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

kubedos can output multiple artifact types from the same pipeline:

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

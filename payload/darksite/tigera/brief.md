i# Kubernetes + Calico (Tigera Operator) + Bookinfo Workbook
_Last updated: 2026-01-24 04:52:36Z_

This is a single, end-to-end workbook capturing everything that was done—from VM creation and SSH access setup, through kubeadm + Calico installation, and finally the Calico NetworkPolicy incident (what broke, how it was fixed), including the **final working YAML** and operation sheets.

---

## Table of contents

1. Environment overview
2. VM provisioning, access, and baseline OS prep
3. Node prerequisites (swap, kernel modules, sysctls)
4. Container runtime (containerd)
5. Kubernetes packages (kubeadm/kubelet/kubectl)
6. Bootstrap the cluster (kubeadm init/join)
7. Install Calico (Tigera / Calico components)
8. Deploy Bookinfo and test pods
9. Incident: Calico/Bookinfo NetworkPolicy (broken → fixed)
10. Final “golden” YAML set (copy/paste ready)
11. Config export tree + command cheat-sheets (evidence collection)
12. Questions & answers (review checklist)

## Tool's & Utilities

1. Built custom jeOS image Debian 13 (kubedos)
2. Utilized enumerator to gather documentaion to train a custom AI bot
2. Created Installer script for "etcd" (install.sh)
3. Created Installer script for "worker" (install.sh)
4. Updated .bashrc with sub-menu & commands (inst.sh)
5. Built custom diagnostic tool-kit (ksnoop.py)
6. Created custom menu system (kubed)
7. Added and configured k9s (menu)
7. Built command alias and exporter /root/export
8. Created clush command / ssh config (clush)
8. WIP - Add realtime AI

## Outputs:
/root/export/ (workbook yamls)
/root/out/ (diag-tool output)

## Problems:

1. ips are dhcp based, the etcd's ip changed half way through causing major issues
2. 

---

## 1) Environment overview

### Nodes
- `etcd-1`  `192.168.122.60`  (control-plane)
- `worker-1` `192.168.122.232`
- `worker-2` `192.168.122.14`

> **Q:** Why is the control-plane node named etcd-1 if kubeadm also runs etcd as a static pod?
>
> **A:** In kubeadm default mode, etcd is deployed as a static pod on the control-plane node. Naming the host `etcd-1` is a lab convenience; it still runs the API server/controller/scheduler plus local etcd.


---

## 2) VM provisioning, access, and baseline OS prep

### 2.1 Created VMs
- Created 3 VMs and assigned hostnames/IPs as listed above.

### 2.2 SSH keys + remote access
- Created and placed SSH keys for user `todd` on all instances.
- Created a `clush` command / wrapper to log into instances quickly.
- Added user `todd` to sudoers.

> **Q:** What should I show as evidence for SSH + sudo setup?
>
> **A:** On each node: `id todd`, `sudo -l -U todd`, and your `~/.ssh/authorized_keys` (redact private data). If you used a clush config file, include its path and contents.


### 2.3 Updated systems
- Performed system updates (apt update/upgrade, reboot if needed).

---

## 3) Node prerequisites (hosts, swap, kernel modules, sysctls)

### 3.1 /etc/hosts on all nodes
```bash
sudo tee -a /etc/hosts >/dev/null <<'EOF'
192.168.122.60 etcd-1
192.168.122.232 worker-1
192.168.122.14  worker-2
EOF
```

> **Q:** Why add /etc/hosts entries?
>
> **A:** It ensures consistent hostname resolution without relying on external DNS—useful in small labs for kubeadm and troubleshooting.


### 3.2 Disable swap on all nodes (required)
```bash
sudo swapoff -a
sudo sed -i.bak '/\sswap\s/s/^/#/' /etc/fstab
```

> **Q:** How do I prove swap is disabled?
>
> **A:** Run `swapon --show` (should be empty) and show `/etc/fstab` where swap entries are commented.


### 3.3 Kernel modules + sysctls for Kubernetes networking
```bash
sudo tee /etc/modules-load.d/k8s.conf >/dev/null <<'EOF'
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

sudo tee /etc/sysctl.d/99-kubernetes-cri.conf >/dev/null <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system
```

> **Q:** What does `br_netfilter` + bridge-nf-call-iptables do?
>
> **A:** It ensures bridged traffic (common with CNI overlays) is visible to iptables so Kubernetes networking and NetworkPolicy enforcement work correctly.


---

## 4) Container runtime: containerd (all nodes)

> Notes: If a node runs kubelet, it needs a container runtime (containerd). In a kubeadm cluster, **every node runs kubelet → every node needs containerd**.

```bash
sudo apt-get update
sudo apt-get install -y containerd

sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml >/dev/null

# Use systemd cgroups (important for kubelet stability)
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

sudo systemctl enable --now containerd
```

> **Q:** How do I prove containerd is configured correctly?
>
> **A:** Show `systemctl status containerd`, and confirm `SystemdCgroup = true` in `/etc/containerd/config.toml`. Optionally show `crictl info` (if installed).


---

## 5) Kubernetes packages: kubeadm / kubelet / kubectl

### What goes where?
- **kubelet** — ALL nodes (required)
- **kubeadm** — ALL nodes (required for bootstrap)
- **kubectl** — control-plane (and optionally your workstation/bastion)

> **Q:** Why is kubectl optional on workers?
>
> **A:** Workers don’t need kubectl to run workloads; kubectl is only needed where you administrate the cluster.


---

## 6) Bootstrap the cluster with kubeadm

### 6.1 Control-plane bootstrap (etcd-1)

#### Fixed deploy script (control-plane)
Save as `scripts/etcd-1-bootstrap.sh` and run on `etcd-1`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# ====== EDIT IF NEEDED ======
CONTROL_IP="192.168.122.60"
POD_CIDR="192.168.0.0/16"          # Calico default-friendly
K8S_MAJOR_MINOR="v1.30"            # repo channel (example)
CALICO_VERSION="v3.28.0"
# ============================

echo "[1/9] Base OS deps"
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gpg

echo "[2/9] Disable swap (required by kubelet)"
sudo swapoff -a
sudo sed -i.bak '/\sswap\s/s/^/#/' /etc/fstab

echo "[3/9] Kernel modules + sysctls for Kubernetes networking"
sudo tee /etc/modules-load.d/k8s.conf >/dev/null <<'EOF'
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

sudo tee /etc/sysctl.d/99-kubernetes-cri.conf >/dev/null <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system

echo "[4/9] Install containerd + systemd cgroups"
sudo apt-get install -y containerd
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl enable --now containerd

echo "[5/9] Install Kubernetes repo + packages (kubelet/kubeadm/kubectl)"
sudo mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_MAJOR_MINOR}/deb/Release.key" \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MAJOR_MINOR}/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null

sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable --now kubelet

echo "[6/9] Initialize control-plane with kubeadm"
sudo kubeadm init \
  --apiserver-advertise-address="${CONTROL_IP}" \
  --pod-network-cidr="${POD_CIDR}"

echo "[7/9] Configure kubectl for current user"
mkdir -p "$HOME/.kube"
sudo cp -i /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u)":"$(id -g)" "$HOME/.kube/config"

echo "[8/9] Install Calico CNI"
kubectl apply -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"

echo "[9/9] Print worker join command (copy this to workers)"
kubeadm token create --print-join-command

echo "DONE: control-plane ready. Wait for nodes/pods:"
echo "  kubectl get nodes"
echo "  kubectl -n kube-system get pods -w"

```

#### kubeadm init output (excerpt)
```text
sudo kubeadm init \
  --apiserver-advertise-address=192.168.122.60 \
  --pod-network-cidr=192.168.0.0/16

I0123 13:18:58.759292    8288 version.go:256] remote version is much newer: v1.35.0; falling back to: stable-1.30
[init] Using Kubernetes version: v1.30.14
...
W0123 13:18:59.053191    8288 checks.go:844] detected that the sandbox image "registry.k8s.io/pause:3.8" of the container runtime is inconsistent with that used by kubeadm.It is recommended to use "registry.k8s.io/pause:3.9" as the CRI sandbox image.
...
kubeadm join 192.168.122.60:6443 --token <...> \
  --discovery-token-ca-cert-hash sha256:<...>

```

> **Q:** What is the pause image warning about?
>
> **A:** kubeadm expects a specific 'pause' image version; if containerd is using a different one, kubeadm prints a warning. It’s usually non-fatal but good to align versions in production.


### 6.2 Worker bootstrap (worker-1 and worker-2)

#### Fixed deploy script (workers)
Save as `scripts/worker-bootstrap.sh` and run on each worker:

```bash
#!/usr/bin/env bash
set -euo pipefail

# ====== EDIT IF NEEDED ======
K8S_MAJOR_MINOR="v1.30"   # must match control-plane repo channel
# ============================

echo "[1/7] Base OS deps"
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gpg

echo "[2/7] Disable swap (required by kubelet)"
sudo swapoff -a
sudo sed -i.bak '/\sswap\s/s/^/#/' /etc/fstab

echo "[3/7] Kernel modules + sysctls for Kubernetes networking"
sudo tee /etc/modules-load.d/k8s.conf >/dev/null <<'EOF'
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

sudo tee /etc/sysctl.d/99-kubernetes-cri.conf >/dev/null <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system

echo "[4/7] Install containerd + systemd cgroups"
sudo apt-get install -y containerd
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl enable --now containerd

echo "[5/7] Install Kubernetes repo + packages (kubelet/kubeadm only)"
sudo mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_MAJOR_MINOR}/deb/Release.key" \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MAJOR_MINOR}/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null

sudo apt-get update
sudo apt-get install -y kubelet kubeadm
sudo apt-mark hold kubelet kubeadm
sudo systemctl enable --now kubelet

echo "[6/7] Join the cluster"
echo "PASTE the 'kubeadm join ...' command from the control-plane here, like:"
echo "  sudo kubeadm join <CONTROL_IP>:6443 --token ... --discovery-token-ca-cert-hash sha256:..."
echo
echo "When ready, paste and run it."

echo "[7/7] After joining, verify from control-plane:"
echo "  kubectl get nodes"

```

#### Join command
> You copy the join command from `kubeadm init` output (or generate a new one with `kubeadm token create --print-join-command`) and run it on each worker:

```bash
sudo kubeadm join 192.168.122.60:6443 --token <...> --discovery-token-ca-cert-hash sha256:<...>
```

> **Q:** What’s the minimum proof that workers joined successfully?
>
> **A:** From control-plane: `kubectl get nodes -o wide` showing worker-1 and worker-2 in `Ready` state.


---

## 7) Install Calico / Tigera Operator

Your cluster ended up running Tigera operator managed components in:
- `tigera-operator`
- `calico-system`

> **Q:** How do I quickly show Calico is healthy?
>
> **A:** Run: `kubectl get pods -A -o wide | egrep -i 'calico|tigera'` and confirm `calico-node` is Running on every node.


---

## 8) Deploy Bookinfo and test pods

### 8.1 Test pod pattern (recommended images)
- Use `curlimages/curl` for HTTP testing (includes curl, DNS tools depend on image).
- For DNS tests: `nslookup` can exist in some images; otherwise use dedicated tools.

Example long-running test pods:
```bash
kubectl -n bookinfo run curl-dev1  --image=curlimages/curl:8.10.1 --restart=Never --command -- sleep 36000
kubectl -n other    run curl-other --image=curlimages/curl:8.10.1 --restart=Never --command -- sleep 36000
```

Label the “tester” pod:
```bash
kubectl -n bookinfo label pod curl-dev1 role=tester --overwrite
```

---

## 9) Incident: Calico/Bookinfo NetworkPolicy (broken → fixed)

The full, detailed incident narrative (including the original broken YAML and the fixed YAML) is included below verbatim, with formatting cleaned up.

---

# Calico / Tigera + Bookinfo NetworkPolicy Incident Report (What Broke, What Was Fixed)

> Environment: Kubernetes cluster with Tigera Operator–managed Calico (namespaces: `tigera-operator`, `calico-system`) and the Bookinfo demo app (namespace: `bookinfo`).
>
> Goal: Enforce **default deny** in `bookinfo`, allow only specific flows (DNS, productpage ingress from bookinfo, and app-to-app calls), and ensure a “dev/test” pod in `bookinfo` can reach `productpage` while a pod in another namespace (`other`) cannot.

---

## Summary

### What was broken
1. **Calico CNI RBAC mismatch**: A ClusterRoleBinding referenced the `calico-cni-plugin` ServiceAccount in the wrong namespace (`kube-system`) while the operator-managed install uses `calico-system`.
2. **Default deny blocked DNS**: Applying a namespace-wide default deny with Egress enabled blocked DNS, causing `nslookup` and any hostname-based calls to fail.
3. **Invalid Calico NetworkPolicy schema**: Some policies were written using **Kubernetes NetworkPolicy-style fields** (e.g., `spec.egress[].ports`) instead of Calico CRD structure (`destination.ports`), causing create/apply failures.
4. **Testing confusion (minor)**: `curl | head; echo $?` reported `head`’s exit code, not `curl`’s, which masked failures.

### What was fixed
1. Patched ClusterRoleBinding **subject namespace** to `calico-system` and removed the stale `kube-system` ServiceAccount.
2. Added explicit DNS egress allow to CoreDNS pods (TCP/UDP 53).
3. Rewrote egress policies in valid Calico CRD form, using `destination.ports`.
4. Verified required allow/deny outcomes with unambiguous `curl` commands.

---

## Evidence & key observations

### Calico/Tigera pods were running
- `tigera-operator` pod running
- `calico-node`, `calico-kube-controllers`, `calico-apiserver`, `calico-typha` running in `calico-system`

### Bookinfo baseline connectivity (before default deny)
- `curl-other` in namespace `other` could successfully reach `productpage.bookinfo.svc.cluster.local:9080` (HTTP 200)
- `curl-dev1` in namespace `bookinfo` could reach `productpage:9080` (HTTP 200)

### After applying default deny in `bookinfo`
- Cross-namespace access (`other` → `bookinfo/productpage`) timed out as expected.
- **Intra-namespace calls started failing due to DNS being blocked**, evidenced by:
  - `curl: (28) Resolving timed out ...`
  - `nslookup ... no servers could be reached`

After DNS egress allow was corrected, DNS resolution worked again:
- `nslookup kubernetes.default.svc.cluster.local` succeeded
- `nslookup productpage.bookinfo.svc.cluster.local` succeeded

---

# 1) RBAC problem: calico-cni-plugin ServiceAccount namespace mismatch

## Symptoms / risk
- Calico CNI plugin can fail authorization against Calico CRDs (or show errors in logs), depending on install state.
- Operator-managed Calico commonly uses `calico-system`, but older manifests often used `kube-system`.

## What was observed
Two ServiceAccounts named `calico-cni-plugin` existed:
- **Good/active**: `calico-system/calico-cni-plugin` (owned by Tigera Installation)
- **Stale**: `kube-system/calico-cni-plugin`

ClusterRoleBinding `calico-cni-plugin` was originally created with subject namespace `kube-system` (visible in last-applied annotation), but was later patched so the **actual subject** became `calico-system`.

## Fix applied
### Patch ClusterRoleBinding subject namespace
```bash
kubectl patch clusterrolebinding calico-cni-plugin \
  --type='json' \
  -p='[{"op":"replace","path":"/subjects/0/namespace","value":"calico-system"}]'
```

### Remove stale ServiceAccount
```bash
kubectl delete sa -n kube-system calico-cni-plugin
```

## Relevant exported objects (recommended)
```bash
kubectl get clusterrolebinding calico-cni-plugin -o yaml \
  > export/rbac/calico-cni-plugin-crb.yaml

kubectl -n calico-system get sa calico-cni-plugin -o yaml \
  > export/rbac/calico-cni-plugin-sa.yaml
```

---

# 2) NetworkPolicy problem: default deny blocked DNS (Egress)

## What triggered the failure
A namespace-wide default deny policy was created in `bookinfo`:

```yaml
apiVersion: projectcalico.org/v3
kind: NetworkPolicy
metadata:
  name: bookinfo-default-deny
  namespace: bookinfo
spec:
  selector: all()
  types: [Ingress, Egress]
```

This correctly denies all ingress/egress unless explicitly allowed—but it also denies DNS to CoreDNS.

## Symptoms
- `curl` to services by name failed with “Resolving timed out”
- `nslookup` failed with “no servers could be reached”

---

# 3) Broken YAML (original “bad” policies) that caused errors

This section captures the **original problematic YAML** and the exact errors it caused.

## A) Invalid: service selector + ports in Calico policy
You attempted to allow DNS egress using a `destination.services` selector and also specify ports:

```yaml
apiVersion: projectcalico.org/v3
kind: NetworkPolicy
metadata:
  name: allow-dns-egress
  namespace: bookinfo
spec:
  selector: all()
  types: [Egress]
  egress:
  - action: Allow
    protocol: UDP
    destination:
      services:
        name: kube-dns
        namespace: kube-system
      ports: [53]
  - action: Allow
    protocol: TCP
    destination:
      services:
        name: kube-dns
        namespace: kube-system
      ports: [53]
```

**Error observed:**
> `Destination.Ports: Invalid value: ... cannot specify ports with a service selector`

### Why it broke
Calico does not allow combining **service selector** with **ports** in that form for this resource.

---

## B) Invalid: Kubernetes-style `spec.egress[].ports` in Calico CRD
You attempted egress policy like this:

```yaml
apiVersion: projectcalico.org/v3
kind: NetworkPolicy
metadata:
  name: allow-tester-to-productpage
  namespace: bookinfo
spec:
  selector: role == "tester"
  types: [Egress]
  egress:
  - action: Allow
    protocol: TCP
    destination:
      selector: app == "productpage"
    ports: [9080]   # invalid for Calico v3 NetworkPolicy
```

**Error observed:**
> `strict decoding error: unknown field "spec.egress[0].ports"`

### Why it broke
In Calico `projectcalico.org/v3` NetworkPolicy, ports must be under:
- `egress[].destination.ports`

---

## C) Invalid: productpage egress policies using the wrong schema
Similarly, you attempted:

```yaml
apiVersion: projectcalico.org/v3
kind: NetworkPolicy
metadata:
  name: allow-productpage-egress
  namespace: bookinfo
spec:
  selector: app == "productpage"
  types: [Egress]
  egress:
  - action: Allow
    protocol: TCP
    destination:
      selector: app == "details"
    ports: [9080]  # invalid location
```

**Error observed:**
> `unknown field "spec.egress[0].ports"`

---

# 4) Final fixed YAML (clean, correct, working set)

> Note: You ended up with **two DNS allow policies**: one using `nets: ["10.96.0.10/32"]` and one using `namespaceSelector+selector` targeting CoreDNS pods.
> For a “final submission”, keep **only the selector-based** DNS policy below (recommended) and delete the `nets`-based one to avoid duplication.

---

## 4.1 Default deny (bookinfo)
```yaml
apiVersion: projectcalico.org/v3
kind: NetworkPolicy
metadata:
  name: bookinfo-default-deny
  namespace: bookinfo
spec:
  selector: all()
  types: [Ingress, Egress]
```

---

## 4.2 Allow productpage ingress from inside bookinfo namespace (port 9080)
```yaml
apiVersion: projectcalico.org/v3
kind: NetworkPolicy
metadata:
  name: allow-productpage-from-bookinfo
  namespace: bookinfo
spec:
  selector: app == "productpage"
  types: [Ingress]
  ingress:
  - action: Allow
    protocol: TCP
    source:
      namespaceSelector: projectcalico.org/name == "bookinfo"
    destination:
      ports: [9080]
```

---

## 4.3 Allow DNS egress to CoreDNS pods (recommended)
```yaml
apiVersion: projectcalico.org/v3
kind: NetworkPolicy
metadata:
  name: allow-dns-egress-to-coredns
  namespace: bookinfo
spec:
  selector: all()
  types: [Egress]
  egress:
  - action: Allow
    protocol: UDP
    destination:
      namespaceSelector: projectcalico.org/name == "kube-system"
      selector: k8s-app == "kube-dns"
      ports: [53]
  - action: Allow
    protocol: TCP
    destination:
      namespaceSelector: projectcalico.org/name == "kube-system"
      selector: k8s-app == "kube-dns"
      ports: [53]
```

---

## 4.4 Allow tester pod egress to productpage (bookinfo → productpage:9080)
```yaml
apiVersion: projectcalico.org/v3
kind: NetworkPolicy
metadata:
  name: allow-tester-to-productpage
  namespace: bookinfo
spec:
  selector: role == "tester"
  types: [Egress]
  egress:
  - action: Allow
    protocol: TCP
    destination:
      namespaceSelector: projectcalico.org/name == "bookinfo"
      selector: app == "productpage"
      ports: [9080]
```

---

## 4.5 Allow productpage egress to details and reviews
```yaml
apiVersion: projectcalico.org/v3
kind: NetworkPolicy
metadata:
  name: allow-productpage-egress
  namespace: bookinfo
spec:
  selector: app == "productpage"
  types: [Egress]
  egress:
  - action: Allow
    protocol: TCP
    destination:
      selector: app == "details"
      ports: [9080]
  - action: Allow
    protocol: TCP
    destination:
      selector: app == "reviews"
      ports: [9080]
```

---

## 4.6 Allow reviews egress to ratings
```yaml
apiVersion: projectcalico.org/v3
kind: NetworkPolicy
metadata:
  name: allow-reviews-egress
  namespace: bookinfo
spec:
  selector: app == "reviews"
  types: [Egress]
  egress:
  - action: Allow
    protocol: TCP
    destination:
      selector: app == "ratings"
      ports: [9080]
```

---

## 4.7 Allow details ingress from productpage
```yaml
apiVersion: projectcalico.org/v3
kind: NetworkPolicy
metadata:
  name: allow-details-ingress-from-productpage
  namespace: bookinfo
spec:
  selector: app == "details"
  types: [Ingress]
  ingress:
  - action: Allow
    protocol: TCP
    source:
      selector: app == "productpage"
    destination:
      ports: [9080]
```

---

## 4.8 Allow reviews ingress from productpage
```yaml
apiVersion: projectcalico.org/v3
kind: NetworkPolicy
metadata:
  name: allow-reviews-ingress-from-productpage
  namespace: bookinfo
spec:
  selector: app == "reviews"
  types: [Ingress]
  ingress:
  - action: Allow
    protocol: TCP
    source:
      selector: app == "productpage"
    destination:
      ports: [9080]
```

---

## 4.9 Allow ratings ingress from reviews
```yaml
apiVersion: projectcalico.org/v3
kind: NetworkPolicy
metadata:
  name: allow-ratings-ingress-from-reviews
  namespace: bookinfo
spec:
  selector: app == "ratings"
  types: [Ingress]
  ingress:
  - action: Allow
    protocol: TCP
    source:
      selector: app == "reviews"
    destination:
      ports: [9080]
```

---

# 5) Validation commands (proof of correctness)

## 5.1 Confirm tester pod labels
```bash
kubectl -n bookinfo get pod curl-dev1 --show-labels
```

Expected label:
- `role=tester`

## 5.2 From bookinfo tester pod → productpage should succeed
```bash
kubectl -n bookinfo exec -it curl-dev1 -- sh -c \
'curl -m 3 -sS -o /dev/null -w "productpage code=%{http_code} rc=%{exitcode}\n" http://productpage:9080/productpage'
```

Expected:
- `code=200 rc=0`

## 5.3 From other namespace → productpage should fail (timeout)
```bash
kubectl -n other exec -it curl-other -- sh -c \
'curl -m 3 -sS -o /dev/null -w "productpage code=%{http_code} rc=%{exitcode}\n" http://productpage.bookinfo.svc.cluster.local:9080/productpage || true'
```

Expected:
- `code=000 rc=28` (timeout)

## 5.4 DNS should work from bookinfo pods (after DNS policy)
```bash
kubectl -n bookinfo exec -it curl-dev1 -- sh -c \
'nslookup kubernetes.default.svc.cluster.local && nslookup productpage.bookinfo.svc.cluster.local'
```

Expected: returns cluster IPs.

---

# 6) Exporting the “relevant configuration files” (cluster → YAML/text)

Create a folder and export everything you need for a report/hand-in:

```bash
mkdir -p export/bookinfo export/rbac export/infra

# Calico policies in bookinfo
kubectl -n bookinfo get networkpolicy.projectcalico.org -o yaml \
  > export/bookinfo/calico-policies-bookinfo.yaml

# RBAC for calico-cni-plugin
kubectl get clusterrolebinding calico-cni-plugin -o yaml \
  > export/rbac/calico-cni-plugin-crb.yaml
kubectl -n calico-system get sa calico-cni-plugin -o yaml \
  > export/rbac/calico-cni-plugin-sa.yaml

# DNS objects (supporting evidence)
kubectl -n kube-system get svc kube-dns -o yaml \
  > export/infra/kube-dns-svc.yaml
kubectl -n kube-system get deploy coredns -o yaml \
  > export/infra/coredns-deploy.yaml
kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide \
  > export/infra/coredns-pods.txt

# Bookinfo services/deployments (optional but useful)
kubectl -n bookinfo get svc -o yaml \
  > export/bookinfo/services.yaml
kubectl -n bookinfo get deploy -o yaml \
  > export/bookinfo/deployments.yaml
```

---

## Appendix: Optional cleanup (recommended for a tidy final set)

If you kept both DNS allow policies (`allow-dns-egress` and `allow-dns-egress-to-coredns`), consider deleting the redundant one:

```bash
kubectl -n bookinfo delete networkpolicy.projectcalico.org allow-dns-egress
```

(Keep `allow-dns-egress-to-coredns`.)

---

## Appendix: Notes on Calico NetworkPolicy schema

- Calico CRD: `apiVersion: projectcalico.org/v3`, `kind: NetworkPolicy`
- Egress rule ports must be at: `egress[].destination.ports`
- Ingress rule ports must be at: `ingress[].destination.ports`

Common mistake:
- `spec.egress[].ports` (Kubernetes-style) → rejected by Calico CRD strict decoding

---

**End of report**

---

## 10) Final “golden” YAML set (copy/paste ready)

> This section is the **final working set** you can include in a brief or hand-in.
> Apply in order (default deny → DNS allow → app policies).

### 10.1 bookinfo-default-deny
```yaml
apiVersion: projectcalico.org/v3
kind: NetworkPolicy
metadata:
  name: bookinfo-default-deny
  namespace: bookinfo
spec:
  selector: all()
  types: [Ingress, Egress]
```

### 10.2 allow-dns-egress-to-coredns (recommended)
```yaml
apiVersion: projectcalico.org/v3
kind: NetworkPolicy
metadata:
  name: allow-dns-egress-to-coredns
  namespace: bookinfo
spec:
  selector: all()
  types: [Egress]
  egress:
  - action: Allow
    protocol: UDP
    destination:
      namespaceSelector: projectcalico.org/name == "kube-system"
      selector: k8s-app == "kube-dns"
      ports: [53]
  - action: Allow
    protocol: TCP
    destination:
      namespaceSelector: projectcalico.org/name == "kube-system"
      selector: k8s-app == "kube-dns"
      ports: [53]
```

### 10.3 allow-productpage-from-bookinfo
```yaml
apiVersion: projectcalico.org/v3
kind: NetworkPolicy
metadata:
  name: allow-productpage-from-bookinfo
  namespace: bookinfo
spec:
  selector: app == "productpage"
  types: [Ingress]
  ingress:
  - action: Allow
    protocol: TCP
    source:
      namespaceSelector: projectcalico.org/name == "bookinfo"
    destination:
      ports: [9080]
```

### 10.4 allow-tester-to-productpage
```yaml
apiVersion: projectcalico.org/v3
kind: NetworkPolicy
metadata:
  name: allow-tester-to-productpage
  namespace: bookinfo
spec:
  selector: role == "tester"
  types: [Egress]
  egress:
  - action: Allow
    protocol: TCP
    destination:
      namespaceSelector: projectcalico.org/name == "bookinfo"
      selector: app == "productpage"
      ports: [9080]
```

### 10.5 allow-productpage-egress
```yaml
apiVersion: projectcalico.org/v3
kind: NetworkPolicy
metadata:
  name: allow-productpage-egress
  namespace: bookinfo
spec:
  selector: app == "productpage"
  types: [Egress]
  egress:
  - action: Allow
    protocol: TCP
    destination:
      selector: app == "details"
      ports: [9080]
  - action: Allow
    protocol: TCP
    destination:
      selector: app == "reviews"
      ports: [9080]
```

### 10.6 allow-details-ingress-from-productpage
```yaml
apiVersion: projectcalico.org/v3
kind: NetworkPolicy
metadata:
  name: allow-details-ingress-from-productpage
  namespace: bookinfo
spec:
  selector: app == "details"
  types: [Ingress]
  ingress:
  - action: Allow
    protocol: TCP
    source:
      selector: app == "productpage"
    destination:
      ports: [9080]
```

### 10.7 allow-reviews-ingress-from-productpage
```yaml
apiVersion: projectcalico.org/v3
kind: NetworkPolicy
metadata:
  name: allow-reviews-ingress-from-productpage
  namespace: bookinfo
spec:
  selector: app == "reviews"
  types: [Ingress]
  ingress:
  - action: Allow
    protocol: TCP
    source:
      selector: app == "productpage"
    destination:
      ports: [9080]
```

### 10.8 allow-reviews-egress
```yaml
apiVersion: projectcalico.org/v3
kind: NetworkPolicy
metadata:
  name: allow-reviews-egress
  namespace: bookinfo
spec:
  selector: app == "reviews"
  types: [Egress]
  egress:
  - action: Allow
    protocol: TCP
    destination:
      selector: app == "ratings"
      ports: [9080]
```

### 10.9 allow-ratings-ingress-from-reviews
```yaml
apiVersion: projectcalico.org/v3
kind: NetworkPolicy
metadata:
  name: allow-ratings-ingress-from-reviews
  namespace: bookinfo
spec:
  selector: app == "ratings"
  types: [Ingress]
  ingress:
  - action: Allow
    protocol: TCP
    source:
      selector: app == "reviews"
    destination:
      ports: [9080]
```

---

## 11) Config export tree + command cheat-sheets

The following section contains the recommended on-disk “tree” and the command cheat-sheet (pods, events, calico, bookinfo, export commands).

---

# Kubernetes Config “Tree” + Calico/Bookinfo

This document complements **`calico_bookinfo_incident_report.md`** (incident narrative + fixed YAML).
It focuses on:

1) a **repeatable directory tree** for collecting/exporting *all relevant configuration*, and
2) **cheat‑sheet commands** to quickly gather cluster state (pods, health, policies, logs, DNS, etc.) with *full paths* and “save-to-file” examples.

---

## 1) Suggested on-disk folder tree (for exports + evidence)

Create a working folder (example: `~/k8s-exports`) and store everything under it.

```bash
mkdir -p ~/k8s-exports/{00-cluster,10-nodes,20-calico,30-bookinfo,40-kube-system,90-snapshots,scripts}
```

Recommended structure:

```text
~/k8s-exports/
├── 00-cluster/
│   ├── namespaces.yaml
│   ├── nodes.yaml
│   ├── crds.yaml
│   ├── events.all-ns.txt
│   └── api-resources.txt
├── 10-nodes/
│   ├── etcd-1/
│   │   ├── paths-and-versions.txt
│   │   ├── kubeadm/
│   │   │   ├── admin.conf
│   │   │   └── manifests/               (static pod manifests)
│   │   ├── cni/
│   │   │   ├── etc-cni-net.d/           (CNI conf)
│   │   │   └── opt-cni-bin/             (CNI binaries)
│   │   └── system/
│   │       ├── containerd-config.toml
│   │       ├── kubelet-config.yaml
│   │       └── iptables-save.txt
│   ├── worker-1/
│   └── worker-2/
├── 20-calico/
│   ├── tigera-operator/
│   │   ├── pods.txt
│   │   └── deployment.tigera-operator.yaml
│   ├── calico-system/
│   │   ├── all.yaml                     (all resources)
│   │   ├── pods.txt
│   │   ├── ds.calico-node.yaml
│   │   ├── deploy.typha.yaml
│   │   ├── deploy.calico-kube-controllers.yaml
│   │   ├── deploy.calico-apiserver.yaml
│   │   ├── logs/
│   │   └── policies/                    (projectcalico.org policies if any)
│   └── crds/
│       ├── projectcalico.org.crds.yaml
│       └── operator.tigera.io.crds.yaml
├── 30-bookinfo/
│   ├── namespace.yaml
│   ├── workloads.yaml
│   ├── services.yaml
│   ├── endpoints.yaml
│   ├── netpol.k8s.io.yaml               (Kubernetes NetworkPolicies)
│   ├── netpol.projectcalico.org.yaml    (Calico NetworkPolicy CRs)
│   ├── test-pods.yaml                   (curl-dev1, curl-other, etc.)
│   └── commands-and-output/
├── 40-kube-system/
│   ├── coredns/
│   │   ├── pods.txt
│   │   ├── service.kube-dns.yaml
│   │   ├── configmap.coredns.yaml
│   │   └── logs/
│   └── other/
├── 90-snapshots/
│   ├── 2026-01-24T04-xx-xxZ/
│   └── ...
└── scripts/
    ├── collect-cluster.sh
    ├── collect-calico.sh
    ├── collect-bookinfo.sh
    └── collect-node-paths.sh
```

### Why this structure?
- **Separation by scope**: cluster-wide vs node-local vs namespace-specific.
- **Evidence-friendly**: “what was the state” + “what YAML existed” + “what logs said”.
- **Git-friendly**: you can commit `*-yaml` and key `*.txt` evidence without huge binary dumps.

---

## 2) Full-path configuration locations (node filesystem)

These are the “usual suspects” for kubeadm + Calico CNI nodes. (Paths may vary slightly by distro/runtime.)

### Kubernetes control-plane / kubeadm (common)
- **Kubeconfig used in your commands**:
  - `/etc/kubernetes/admin.conf`
- Static pod manifests (control-plane components):
  - `/etc/kubernetes/manifests/`
- Kubelet config:
  - `/var/lib/kubelet/config.yaml` (or `/etc/kubernetes/kubelet.conf` for auth)
- Kubelet service overrides (systemd):
  - `/etc/systemd/system/kubelet.service.d/`
- PKI:
  - `/etc/kubernetes/pki/`

### CNI / networking (common)
- CNI config:
  - `/etc/cni/net.d/`
- CNI binaries:
  - `/opt/cni/bin/`

### Container runtime (common)
- containerd config:
  - `/etc/containerd/config.toml`
- logs:
  - `/var/log/containers/` and `/var/log/pods/`

### Useful node commands (save evidence)
```bash
# on each node:
sudo ls -la /etc/kubernetes /etc/kubernetes/manifests /etc/cni/net.d /opt/cni/bin | tee paths.txt
sudo crictl info | tee crictl-info.json
sudo ip addr | tee ip-addr.txt
sudo ip route | tee ip-route.txt
sudo iptables-save | tee iptables-save.txt
sudo nft list ruleset | tee nft-ruleset.txt 2>/dev/null || true
```

---

## 3) Cluster “collect everything” cheat-sheet (save-to-file friendly)

All commands below assume you’re running from a machine that has:

- `kubectl`
- access to `/etc/kubernetes/admin.conf`

Use a consistent env var:

```bash
export KUBECONFIG=/etc/kubernetes/admin.conf
```

### 3.1 Core cluster inventory
```bash
mkdir -p ~/k8s-exports/00-cluster

kubectl api-resources -o name | sort | tee ~/k8s-exports/00-cluster/api-resources.txt

kubectl get ns -o yaml > ~/k8s-exports/00-cluster/namespaces.yaml
kubectl get nodes -o wide  | tee ~/k8s-exports/00-cluster/nodes.wide.txt
kubectl get nodes -o yaml  > ~/k8s-exports/00-cluster/nodes.yaml
kubectl get crd -o yaml    > ~/k8s-exports/00-cluster/crds.yaml
kubectl get events -A --sort-by=.lastTimestamp | tee ~/k8s-exports/00-cluster/events.all-ns.txt
```

### 3.2 “What’s running?” (pods, deployments, daemonsets)
```bash
kubectl get pods -A -o wide | tee ~/k8s-exports/90-snapshots/pods.all-ns.wide.txt
kubectl get deploy -A -o wide | tee ~/k8s-exports/90-snapshots/deploy.all-ns.wide.txt
kubectl get ds -A -o wide | tee ~/k8s-exports/90-snapshots/ds.all-ns.wide.txt
kubectl get sts -A -o wide | tee ~/k8s-exports/90-snapshots/sts.all-ns.wide.txt
```

### 3.3 Quick triage commands
```bash
# Failed / pending pods
kubectl get pods -A --field-selector=status.phase!=Running -o wide

# Pod restarts (sort)
kubectl get pods -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,RESTARTS:.status.containerStatuses[*].restartCount' | sort -k3 -nr | head

# Recent warnings/errors
kubectl get events -A --field-selector type=Warning --sort-by=.lastTimestamp | tail -n 50
```

### 3.4 Describe + logs (template)
```bash
# Describe a pod
kubectl -n <ns> describe pod <pod>

# Logs (current + previous)
kubectl -n <ns> logs <pod> -c <container> --tail=200
kubectl -n <ns> logs <pod> -c <container> --previous --tail=200
```

---

## 4) Calico/Tigera exports + health checks

Create folder:
```bash
mkdir -p ~/k8s-exports/20-calico/{tigera-operator,calico-system,crds}
```

### 4.1 Calico components status
```bash
kubectl get pods -A -o wide | egrep -i 'calico|tigera' | tee ~/k8s-exports/20-calico/pods.calico-and-tigera.txt

kubectl -n tigera-operator get all -o wide | tee ~/k8s-exports/20-calico/tigera-operator/all.wide.txt
kubectl -n calico-system  get all -o wide | tee ~/k8s-exports/20-calico/calico-system/all.wide.txt
```

### 4.2 Export Calico/Tigera resources as YAML
```bash
kubectl -n tigera-operator get all -o yaml > ~/k8s-exports/20-calico/tigera-operator/all.yaml
kubectl -n calico-system  get all -o yaml > ~/k8s-exports/20-calico/calico-system/all.yaml

# Common key objects
kubectl -n calico-system get ds calico-node -o yaml > ~/k8s-exports/20-calico/calico-system/ds.calico-node.yaml
kubectl -n calico-system get deploy calico-typha -o yaml > ~/k8s-exports/20-calico/calico-system/deploy.typha.yaml 2>/dev/null || true
kubectl -n calico-system get deploy calico-kube-controllers -o yaml > ~/k8s-exports/20-calico/calico-system/deploy.calico-kube-controllers.yaml
kubectl -n calico-system get deploy -o yaml > ~/k8s-exports/20-calico/calico-system/deployments.yaml
```

### 4.3 Export CRDs (Calico + Tigera operator)
```bash
kubectl get crd | egrep -i 'projectcalico|tigera|operator' | tee ~/k8s-exports/20-calico/crds/crd-list.txt

kubectl get crd -o yaml | egrep -i 'projectcalico|tigera|operator' -n >/dev/null || true
kubectl get crd -o yaml > ~/k8s-exports/20-calico/crds/all-crds.yaml
```

### 4.4 Calico logs (node + controllers)
```bash
mkdir -p ~/k8s-exports/20-calico/calico-system/logs

# calico-node is a DaemonSet -> one pod per node
for p in $(kubectl -n calico-system get pod -l k8s-app=calico-node -o name); do
  kubectl -n calico-system logs "$p" --tail=300 > ~/k8s-exports/20-calico/calico-system/logs/$(basename "$p").log 2>/dev/null || true
done

# typha (if present)
kubectl -n calico-system logs deploy/calico-typha --tail=300 > ~/k8s-exports/20-calico/calico-system/logs/calico-typha.log 2>/dev/null || true
```

---

## 5) Bookinfo exports + “policy debugging” commands

Create folder:
```bash
mkdir -p ~/k8s-exports/30-bookinfo
```

### 5.1 Export Bookinfo workloads/services/endpoints
```bash
kubectl -n bookinfo get ns bookinfo -o yaml > ~/k8s-exports/30-bookinfo/namespace.yaml

kubectl -n bookinfo get deploy,ds,sts,po -o yaml > ~/k8s-exports/30-bookinfo/workloads.yaml
kubectl -n bookinfo get svc -o yaml            > ~/k8s-exports/30-bookinfo/services.yaml
kubectl -n bookinfo get endpoints -o yaml      > ~/k8s-exports/30-bookinfo/endpoints.yaml
kubectl -n bookinfo get ep -o wide | tee ~/k8s-exports/30-bookinfo/endpoints.wide.txt
```

### 5.2 Export network policies (both types)
```bash
# Kubernetes NetworkPolicy (networking.k8s.io)
kubectl -n bookinfo get networkpolicy -o yaml > ~/k8s-exports/30-bookinfo/netpol.k8s.io.yaml 2>/dev/null || true

# Calico NetworkPolicy CRD (projectcalico.org)
kubectl -n bookinfo get networkpolicy.projectcalico.org -o yaml > ~/k8s-exports/30-bookinfo/netpol.projectcalico.org.yaml
kubectl -n bookinfo get networkpolicy.projectcalico.org -o wide | tee ~/k8s-exports/30-bookinfo/netpol.projectcalico.org.wide.txt
```

### 5.3 “Does policy block me?” quick tests (curl + DNS)

#### A) DNS test from a pod
```bash
kubectl -n bookinfo exec -it curl-dev1 -- sh -c 'cat /etc/resolv.conf; echo; nslookup kubernetes.default.svc.cluster.local'
kubectl -n bookinfo exec -it curl-dev1 -- sh -c 'nslookup productpage.bookinfo.svc.cluster.local'
```

#### B) HTTP test from inside namespace vs outside namespace
```bash
# inside bookinfo namespace (should be allowed)
kubectl -n bookinfo exec -it curl-dev1 -- sh -c 'curl -m 3 -sS -o /dev/null -w "productpage code=%{http_code} rc=%{exitcode}
" http://productpage:9080/productpage'

# from another namespace (should be blocked by ingress policy)
kubectl -n other exec -it curl-other -- sh -c 'curl -m 3 -sS -o /dev/null -w "productpage code=%{http_code} rc=%{exitcode}
" http://productpage.bookinfo.svc.cluster.local:9080/productpage || true'
```

---

## 6) Known “gotchas” captured in your incident (so you can explain it clearly)

### 6.1 What was “broken”
1) **Default-deny included Egress**, but there was **no DNS egress allow**, so pods in `bookinfo` could not resolve service names (you saw `nslookup ... timed out`).
2) Some early Calico NetworkPolicy attempts failed due to **schema differences** (Calico CRD expects ports under `destination.ports`, not `spec.egress[].ports` in the way you tried).
3) Productpage ingress was correctly restricted to `bookinfo`, and that’s why `other` namespace could no longer connect after policy apply.

### 6.2 What fixed it
- Added a Calico NetworkPolicy allowing **DNS egress to CoreDNS** (selector + namespaceSelector) on port 53 (TCP/UDP).
- Added/adjusted a Calico NetworkPolicy allowing the **tester pod’s egress** to `productpage` (namespaceSelector + selector + destination ports).
- Added missing app-to-app egress policies (e.g., `productpage -> details/reviews`, `reviews -> ratings`) using **Calico CRD schema** (ports inside `destination`).

(Full “final YAML” is in `calico_bookinfo_incident_report.md`.)

---

## 7) Scripts (optional but handy)

### 7.1 `scripts/collect-bookinfo.sh`
```bash
#!/usr/bin/env bash
set -euo pipefail
export KUBECONFIG=${KUBECONFIG:-/etc/kubernetes/admin.conf}

OUT=${1:-"$HOME/k8s-exports/30-bookinfo"}
mkdir -p "$OUT"

kubectl -n bookinfo get ns bookinfo -o yaml > "$OUT/namespace.yaml"
kubectl -n bookinfo get deploy,ds,sts,po -o yaml > "$OUT/workloads.yaml"
kubectl -n bookinfo get svc -o yaml > "$OUT/services.yaml"
kubectl -n bookinfo get endpoints -o yaml > "$OUT/endpoints.yaml"
kubectl -n bookinfo get networkpolicy -o yaml > "$OUT/netpol.k8s.io.yaml" 2>/dev/null || true
kubectl -n bookinfo get networkpolicy.projectcalico.org -o yaml > "$OUT/netpol.projectcalico.org.yaml"
kubectl -n bookinfo get events --sort-by=.lastTimestamp > "$OUT/events.txt"
kubectl -n bookinfo get pod -o wide > "$OUT/pods.wide.txt"
```

Make executable:
```bash
chmod +x ~/k8s-exports/scripts/collect-bookinfo.sh
```

---

## 8) “tree” command to print what you collected

If `tree` is installed:

```bash
tree -a ~/k8s-exports | tee ~/k8s-exports/90-snapshots/tree.txt
```

If `tree` is not installed, you can still do:

```bash
find ~/k8s-exports -maxdepth 4 -type f | sort | tee ~/k8s-exports/90-snapshots/find-files.txt
```

---

### Appendix: quick one-liners you’ll use constantly

```bash
# All pods, sorted by namespace
kubectl get pods -A -o wide | sort

# Only calico/tigera
kubectl get pods -A -o wide | egrep -i 'calico|tigera'

# Policy objects in bookinfo
kubectl -n bookinfo get networkpolicy,networkpolicy.projectcalico.org -o wide

# CoreDNS quick check
kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide
kubectl -n kube-system get svc kube-dns -o wide

# Events (latest)
kubectl get events -A --sort-by=.lastTimestamp | tail -n 50
```

---

## 12) Questions & answers (review checklist)

> **Q:** If something breaks again, what’s the fastest way to determine if it’s DNS or L4 connectivity?
>
> **A:** Run `nslookup kubernetes.default.svc.cluster.local` from the pod. If DNS fails, fix DNS egress. If DNS succeeds, `curl -v` to the service IP/port and look for timeouts vs refusals.


> **Q:** How do I prove the policies are doing what we claim?
>
> **A:** Show: (1) `curl-dev1` in bookinfo gets HTTP 200 from productpage; (2) `curl-other` in other namespace times out; (3) `nslookup` works from bookinfo pods; (4) `kubectl -n bookinfo get networkpolicy.projectcalico.org -o wide` lists the applied policies.


> **Q:** What files should I hand in as 'relevant configuration'?
>
> **A:** At minimum: your bootstrap scripts (control-plane + worker), exported YAML for Calico policies (`kubectl -n bookinfo get networkpolicy.projectcalico.org -o yaml`), and RBAC objects changed (ClusterRoleBinding + ServiceAccount). Include CoreDNS service/deploy YAML for DNS evidence.


> **Q:** What are the common Calico policy authoring mistakes to call out?
>
> **A:** Mixing Kubernetes NetworkPolicy schema with Calico CRDs (e.g., placing ports at `spec.egress[].ports`), forgetting DNS egress when enabling default-deny egress, and misunderstanding namespaceSelector/selector matching.

---

What broke:

“After applying bookinfo-default-deny (Ingress+Egress), DNS egress was blocked, so Bookinfo pods could not resolve service names (CoreDNS at 10.96.0.10), causing nslookup and curl http://service-name to time out.”

What was fixed:

“Added explicit Calico egress allow for DNS to CoreDNS pods (TCP/UDP 53) and rewrote egress allow policies using correct Calico CRD schema (destination.ports). After that, DNS resolution and allowed service-to-service flows returned, while cross-namespace access remained blocked.”

Quick Q&A you can paste into slides/defense

Q: Was the Bookinfo YAML broken?
A: No. It deployed and served traffic correctly before network policy enforcement.

Q: Why did curl http://productpage:9080 fail from a pod in bookinfo?
A: DNS was blocked by default-deny egress, so the hostname productpage could not resolve.

Q: Why did some policy YAML fail to apply?
A: It used Kubernetes-style fields (spec.egress[].ports) instead of Calico CRD structure (destination.ports).

Q: Why did a pod in namespace other time out to productpage?
A: Productpage ingress was allowed only from the bookinfo namespace; cross-namespace traffic was denied as intended.

### End of workbook
(eBPF) todd@sapphire:~$ ls
bin  books  Desktop  Documents  Downloads  go  k8s-triage  linux-tools  Music  notes.md  Pictures  Public  Templates  venvs  Videos  walkthrough.md
(eBPF) todd@sapphire:~$ cat walkthrough.md 
# Tigera / Calico Customer Success Technical Assessment  
## Demo runbook + commands + config locations (end‑to‑end)

> This document is written so you can **demo every step live**: build cluster → install Calico → deploy Bookinfo → apply policy strategy → run tests (dev1 vs non‑dev1 vs outside cluster) → explain routing and what broke / how it was fixed.

---

## 0) Environment inventory (what was built)

### VMs (3 nodes)
| Role | Hostname | IP |
|---|---|---|
| control-plane | `etcd-1` | `192.168.122.60` |
| worker | `worker-1` | `192.168.122.231` |
| worker | `worker-2` | `192.168.122.13` |

### Hostname + `/etc/hosts` on every node
**File:** `/etc/hosts`

```bash
sudo tee -a /etc/hosts >/dev/null <<'EOF'
192.168.122.60 etcd-1
192.168.122.231 worker-1
192.168.122.13  worker-2
EOF
```

### Access automation
- SSH keys placed for user `todd`
- `clush` command created to log into instances quickly
- `todd` added to sudoers

> **Demo question:** “How do you access all nodes quickly?”
> **Answer:** “SSH keys + clush + consistent hostnames and /etc/hosts.”

---

## 1) Node prep (all nodes)

### 1.1 Disable swap (kubelet requirement)
**Files:**
- `/etc/fstab` (swap entry commented)
- runtime swap disabled via `swapoff`

```bash
sudo swapoff -a
sudo sed -i.bak '/\sswap\s/s/^/#/' /etc/fstab
```

**Verify**
```bash
swapon --show
free -h
```

### 1.2 Kernel modules + sysctls (K8s networking)
**Files:**
- `/etc/modules-load.d/k8s.conf`
- `/etc/sysctl.d/99-kubernetes-cri.conf`

```bash
sudo tee /etc/modules-load.d/k8s.conf >/dev/null <<'EOF'
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

sudo tee /etc/sysctl.d/99-kubernetes-cri.conf >/dev/null <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system
```

**Verify**
```bash
lsmod | egrep 'overlay|br_netfilter'
sysctl net.ipv4.ip_forward
```

> **Demo question:** “Why `br_netfilter` + `ip_forward`?”
> **Answer:** “So pod traffic can be forwarded and iptables/nftables can see bridged traffic.”

---

## 2) Container runtime (all nodes)

### 2.1 Install + configure containerd
**File:** `/etc/containerd/config.toml`

```bash
sudo apt-get update
sudo apt-get install -y containerd
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml >/dev/null

# Use systemd cgroups (recommended for kubelet stability)
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl enable --now containerd
```

**Verify**
```bash
systemctl status containerd --no-pager
containerd --version
```

> **Demo question:** “Why systemd cgroups?”
> **Answer:** “Kubelet defaults and most distros are systemd-based; mismatch can cause instability.”

---

## 3) Kubernetes packages

### What goes where (rule of thumb)
- `kubelet`: **ALL nodes** (node agent, required)
- `kubeadm`: **ALL nodes** (bootstrap/init/join)
- `kubectl`: **control-plane** (and optionally your laptop)

### 3.1 Install repo + packages (control-plane and workers)
**Repo/key paths:**
- `/etc/apt/keyrings/kubernetes-apt-keyring.gpg`
- `/etc/apt/sources.list.d/kubernetes.list`

```bash
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gpg

sudo mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key" \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null

sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl   # on control-plane
# workers: kubelet kubeadm
sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable --now kubelet
```

**Verify**
```bash
kubeadm version
kubelet --version
kubectl version --client
systemctl status kubelet --no-pager
```

---

## 4) Cluster bootstrap (control-plane `etcd-1`)

### 4.1 kubeadm init
**Key output files created by kubeadm:**
- `/etc/kubernetes/admin.conf`
- `/etc/kubernetes/manifests/` (static pods)
- `/etc/kubernetes/pki/`
- `/var/lib/kubelet/config.yaml`

```bash
sudo kubeadm init \
  --apiserver-advertise-address=192.168.122.192 \
  --pod-network-cidr=192.168.0.0/16
```

### 4.2 Configure kubectl
**File:** `$HOME/.kube/config` (or use `/etc/kubernetes/admin.conf` directly)

```bash
mkdir -p "$HOME/.kube"
sudo cp -i /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u)":"$(id -g)" "$HOME/.kube/config"
```

**Verify**
```bash
kubectl get nodes -o wide
kubectl -n kube-system get pods -o wide
```

### 4.3 Join workers
On each worker, run the join command printed by `kubeadm init`:

```bash
sudo kubeadm join 192.168.122.192:6443 --token <...> \
  --discovery-token-ca-cert-hash sha256:<...>
```

**Verify from control-plane**
```bash
kubectl get nodes -o wide
kubectl get pods -A -o wide
```

---

## 5) Install Calico (Tigera Operator managed)

### 5.1 Expected namespaces / components
- `tigera-operator`
- `calico-system` (calico-node, typha, calico-apiserver, etc.)

**Verify Calico/Tigera pods**
```bash
kubectl get pods -A -o wide | egrep -i 'calico|tigera'
kubectl -n tigera-operator get pods -o wide
kubectl -n calico-system get pods -o wide
```

> **Demo question:** “What creates pod networking?”
> **Answer:** “Calico CNI (calico-node daemonset) configures routes/encap + programs dataplane rules on each node.”

---

## 6) Deploy Bookinfo (dev1 app)

### 6.1 Bookinfo manifest (what you actually applied)
**File path (your VM):** `root@etcd-1:~/bookinfo.yaml`

Apply:
```bash
kubectl create ns bookinfo || true
kubectl -n bookinfo apply -f ~/bookinfo.yaml
kubectl -n bookinfo get pods -o wide
kubectl -n bookinfo get svc -o wide
```

### 6.2 What was “wrong” with the original Bookinfo YAML?
**Nothing was fundamentally wrong with the Bookinfo YAML you pasted.**
It’s a standard Istio sample manifest and it created Services, ServiceAccounts, and Deployments successfully.

**What *looked* “broken” during testing was not Bookinfo YAML — it was network policy.**
Specifically, after you applied a **default deny with Egress**, DNS got blocked, so service-name resolution failed and made the app appear broken.

**Proof it was fine before policy:**
- Pods were Running
- `curl` from `bookinfo` and from `other` worked (HTTP 200) before default deny.

> **Interview-safe phrasing:**
> “Bookinfo deployment was correct. The outage symptoms (timeouts / DNS failures) were caused by Calico NetworkPolicy changes, not the app manifests.”

---

## 7) Test pods (dev1 vs non-dev1)

### 7.1 Create “dev1 tester” inside bookinfo
```bash
kubectl -n bookinfo run curl-dev1 --image=curlimages/curl:8.10.1 \
  --restart=Never --command -- sleep 36000

kubectl -n bookinfo wait --for=condition=Ready pod/curl-dev1 --timeout=120s
kubectl -n bookinfo label pod curl-dev1 role=tester --overwrite
kubectl -n bookinfo get pod curl-dev1 --show-labels
```

### 7.2 Create “outside dev1” tester in other namespace
```bash
kubectl create ns other || true
kubectl -n other run curl-other --image=curlimages/curl:8.10.1 \
  --restart=Never --command -- sleep 36000

kubectl -n other wait --for=condition=Ready pod/curl-other --timeout=120s
kubectl -n other get pod curl-other -o wide
```

---

## 8) Policy strategy (what we enforced and why)

### Strategy chosen: **Ingress + Egress controls**
Reason:
- **Ingress-only** can prevent unwanted inbound traffic, but does not stop a compromised pod from exfiltrating outward.
- **Egress-only** can limit where pods can go, but doesn’t prevent other pods from reaching services.
- **Ingress + Egress** gives “least privilege” and best aligns with “bare minimum microservice flows.”

> **Demo question:** “Why not ingress-only?”
> **Answer:** “Ingress-only would still allow any pod to talk out (including DNS exfil, metadata, etc.). Egress is key for least privilege.”

---

## 9) The incident: what broke + how it was fixed

### 9.1 What broke
1) **Namespace-wide default deny** in `bookinfo` included Egress → **DNS blocked** → service-name resolution failed:
   - `nslookup` timed out
   - `curl http://productpage:9080/...` failed with `Resolving timed out`
2) Several early Calico policies used the **wrong schema**:
   - used `spec.egress[].ports` (Kubernetes style) → Calico rejected with strict decoding errors
3) Calico CNI RBAC mismatch:
   - ClusterRoleBinding initially pointed at `kube-system/calico-cni-plugin`
   - operator-managed install uses `calico-system/calico-cni-plugin`

### 9.2 Fixes applied

#### A) Fix Calico CNI RBAC
```bash
kubectl patch clusterrolebinding calico-cni-plugin \
  --type='json' \
  -p='[{"op":"replace","path":"/subjects/0/namespace","value":"calico-system"}]'

kubectl delete sa -n kube-system calico-cni-plugin
```

#### B) Add DNS allow (Egress) to CoreDNS pods
Working policy (Calico CRD; note ports under `destination`):

**YAML location (recommended):** `~/policies/bookinfo/allow-dns-egress-to-coredns.yaml`

```yaml
apiVersion: projectcalico.org/v3
kind: NetworkPolicy
metadata:
  name: allow-dns-egress-to-coredns
  namespace: bookinfo
spec:
  selector: all()
  types: [Egress]
  egress:
  - action: Allow
    protocol: UDP
    destination:
      namespaceSelector: projectcalico.org/name == "kube-system"
      selector: k8s-app == "kube-dns"
      ports: [53]
  - action: Allow
    protocol: TCP
    destination:
      namespaceSelector: projectcalico.org/name == "kube-system"
      selector: k8s-app == "kube-dns"
      ports: [53]
```

Apply:
```bash
kubectl apply -f ~/policies/bookinfo/allow-dns-egress-to-coredns.yaml
```

#### C) Correct Calico policy schema mistakes
**Bad (original) pattern that caused errors:**
- `spec.egress[].ports`

**Correct Calico pattern:**
- `spec.egress[].destination.ports`

#### D) Add minimal app-to-app and tester egress flows
- dev1 tester → productpage
- productpage → details + reviews
- reviews → ratings
- keep productpage ingress limited to bookinfo ns
- keep default deny on

---

## 10) FINAL working YAML set (for demonstration)

### 10.1 Default deny (bookinfo)
**YAML location:** `~/policies/bookinfo/00-default-deny.yaml`

```yaml
apiVersion: projectcalico.org/v3
kind: NetworkPolicy
metadata:
  name: bookinfo-default-deny
  namespace: bookinfo
spec:
  selector: all()
  types: [Ingress, Egress]
```

### 10.2 Allow productpage ingress from bookinfo (port 9080)
**YAML location:** `~/policies/bookinfo/10-allow-productpage-ingress-from-bookinfo.yaml`

```yaml
apiVersion: projectcalico.org/v3
kind: NetworkPolicy
metadata:
  name: allow-productpage-from-bookinfo
  namespace: bookinfo
spec:
  selector: app == "productpage"
  types: [Ingress]
  ingress:
  - action: Allow
    protocol: TCP
    source:
      namespaceSelector: projectcalico.org/name == "bookinfo"
    destination:
      ports: [9080]
```

### 10.3 Allow DNS egress to CoreDNS
**YAML location:** `~/policies/bookinfo/20-allow-dns-egress-to-coredns.yaml`
(see section 9.2.B)

### 10.4 Allow dev1 tester egress to productpage
**YAML location:** `~/policies/bookinfo/30-allow-tester-egress-to-productpage.yaml`

```yaml
apiVersion: projectcalico.org/v3
kind: NetworkPolicy
metadata:
  name: allow-tester-to-productpage
  namespace: bookinfo
spec:
  selector: role == "tester"
  types: [Egress]
  egress:
  - action: Allow
    protocol: TCP
    destination:
      namespaceSelector: projectcalico.org/name == "bookinfo"
      selector: app == "productpage"
      ports: [9080]
```

### 10.5 Allow productpage egress to details + reviews
**YAML location:** `~/policies/bookinfo/40-allow-productpage-egress.yaml`

```yaml
apiVersion: projectcalico.org/v3
kind: NetworkPolicy
metadata:
  name: allow-productpage-egress
  namespace: bookinfo
spec:
  selector: app == "productpage"
  types: [Egress]
  egress:
  - action: Allow
    protocol: TCP
    destination:
      selector: app == "details"
      ports: [9080]
  - action: Allow
    protocol: TCP
    destination:
      selector: app == "reviews"
      ports: [9080]
```

### 10.6 Allow reviews egress to ratings
**YAML location:** `~/policies/bookinfo/50-allow-reviews-egress.yaml`

```yaml
apiVersion: projectcalico.org/v3
kind: NetworkPolicy
metadata:
  name: allow-reviews-egress
  namespace: bookinfo
spec:
  selector: app == "reviews"
  types: [Egress]
  egress:
  - action: Allow
    protocol: TCP
    destination:
      selector: app == "ratings"
      ports: [9080]
```

### 10.7 Ingress allow rules for internal calls
These complement egress rules (they make the service reachable when default deny ingress is present).

**YAML location:** `~/policies/bookinfo/60-allow-details-ingress-from-productpage.yaml`
```yaml
apiVersion: projectcalico.org/v3
kind: NetworkPolicy
metadata:
  name: allow-details-ingress-from-productpage
  namespace: bookinfo
spec:
  selector: app == "details"
  types: [Ingress]
  ingress:
  - action: Allow
    protocol: TCP
    source:
      selector: app == "productpage"
    destination:
      ports: [9080]
```

**YAML location:** `~/policies/bookinfo/61-allow-reviews-ingress-from-productpage.yaml`
```yaml
apiVersion: projectcalico.org/v3
kind: NetworkPolicy
metadata:
  name: allow-reviews-ingress-from-productpage
  namespace: bookinfo
spec:
  selector: app == "reviews"
  types: [Ingress]
  ingress:
  - action: Allow
    protocol: TCP
    source:
      selector: app == "productpage"
    destination:
      ports: [9080]
```

**YAML location:** `~/policies/bookinfo/62-allow-ratings-ingress-from-reviews.yaml`
```yaml
apiVersion: projectcalico.org/v3
kind: NetworkPolicy
metadata:
  name: allow-ratings-ingress-from-reviews
  namespace: bookinfo
spec:
  selector: app == "ratings"
  types: [Ingress]
  ingress:
  - action: Allow
    protocol: TCP
    source:
      selector: app == "reviews"
    destination:
      ports: [9080]
```

### Apply all policies (example)
```bash
kubectl apply -f ~/policies/bookinfo/
kubectl -n bookinfo get networkpolicy.projectcalico.org -o wide
```

---

## 11) Required demo tests + exact commands

### 11.1 Test access from within dev1 (bookinfo) environment
**DNS should work**
```bash
kubectl -n bookinfo exec -it curl-dev1 -- sh -c \
'nslookup kubernetes.default.svc.cluster.local && nslookup productpage.bookinfo.svc.cluster.local'
```

**dev1 tester → productpage should succeed**
```bash
kubectl -n bookinfo exec -it curl-dev1 -- sh -c \
'curl -m 3 -sS -o /dev/null -w "productpage code=%{http_code} rc=%{exitcode}\n" http://productpage:9080/productpage'
```

Expected:
- `code=200 rc=0`

### 11.2 Test access from within the cluster, outside dev1 environment
**other namespace → productpage should fail (timeout)**
```bash
kubectl -n other exec -it curl-other -- sh -c \
'curl -m 3 -sS -o /dev/null -w "productpage code=%{http_code} rc=%{exitcode}\n" http://productpage.bookinfo.svc.cluster.local:9080/productpage || true'
```

Expected:
- `code=000 rc=28` (timeout)

### 11.3 Test access from outside the cluster
> **Important honesty note:** your transcript doesn’t show an external exposure method being configured (NodePort/Ingress/LB).
> Below is a clean demo‑ready method you can implement quickly **if you choose NodePort** (simple and reliable for a lab).

#### Option A (simple lab): NodePort + Calico host endpoint controls
1) Expose productpage via NodePort (example 30080)
```bash
kubectl -n bookinfo patch svc productpage -p '
spec:
  type: NodePort
  ports:
  - name: http
    port: 9080
    targetPort: 9080
    nodePort: 30080
'
kubectl -n bookinfo get svc productpage -o wide
```

2) External test (from a machine on an allowed network):
```bash
curl -m 3 -v http://192.168.122.231:30080/productpage
# or worker-2 IP
curl -m 3 -v http://192.168.122.13:30080/productpage
```

3) Restrict to “well-defined network range”
- If you need strict source range enforcement, do it at:
  - infrastructure firewall/security group **or**
  - Calico HostEndpoint + GlobalNetworkPolicy (advanced) **or**
  - node firewall (iptables/nft)

> If you want, I can add the exact Calico HostEndpoint + GlobalNetworkPolicy YAML for a source CIDR allowlist (tell me the CIDR).

---

## 12) Explain routing (how pods talk)

### Key building blocks you can explain in the interview
- **Service VIP** (ClusterIP): kube-proxy (iptables or IPVS) rewrites traffic destined for `10.x.y.z` to a backend pod IP.
- **Pod IP routing**: Calico installs routes (and/or encapsulation) so node A knows how to reach pod CIDRs on node B.
- **Policy enforcement**: Calico programs dataplane rules (iptables/nft or eBPF) to allow/deny flows based on policy selectors.
- **DNS**: pods use `/etc/resolv.conf` → `kube-dns` service (e.g., `10.96.0.10`) → CoreDNS pods.

**Quick “show me” commands**
```bash
kubectl -n kube-system get svc kube-dns -o wide
kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide

kubectl -n bookinfo get svc productpage -o wide
kubectl -n bookinfo get ep productpage -o wide
```

---

## 13) Where the YAML and configs live (for your demo)

### On disk (your VM)
- Bookinfo manifest: `~/bookinfo.yaml`
- Recommended policy folder: `~/policies/bookinfo/*.yaml`
- kubeconfig for cluster admin: `/etc/kubernetes/admin.conf`

### In cluster (export these live)
```bash
mkdir -p ~/k8s-exports/bookinfo ~/k8s-exports/calico ~/k8s-exports/rbac

kubectl -n bookinfo get networkpolicy.projectcalico.org -o yaml \
  > ~/k8s-exports/bookinfo/calico-policies.yaml

kubectl get clusterrolebinding calico-cni-plugin -o yaml \
  > ~/k8s-exports/rbac/calico-cni-plugin-crb.yaml

kubectl -n calico-system get sa calico-cni-plugin -o yaml \
  > ~/k8s-exports/rbac/calico-cni-plugin-sa.yaml
```

---

## 14) Q&A prompts (use throughout the demo)

### Kubernetes basics
- **Q:** “Which components interact to deploy an app?”
  **A:** “API server stores desired state; scheduler places pods; kubelet pulls images via containerd and runs pods; kube-proxy handles Services.”
- **Q:** “Where do manifests go in kubeadm?”
  **A:** “Static pods are in `/etc/kubernetes/manifests`. Admin kubeconfig is `/etc/kubernetes/admin.conf`.”

### Calico networking
- **Q:** “How are pod IPs reachable across nodes?”
  **A:** “Calico programs routes/encapsulation and ensures node-to-node reachability; kube-proxy handles service VIP → endpoints.”
- **Q:** “Where is Calico running?”
  **A:** “`calico-node` as a DaemonSet on each node + supporting controllers in `calico-system`.”

### Calico security
- **Q:** “Why did DNS break?”
  **A:** “Default deny with Egress blocked access to CoreDNS; pods couldn’t resolve service names.”
- **Q:** “What was the schema issue?”
  **A:** “Calico CRD uses `destination.ports`; Kubernetes NetworkPolicy uses `ports` at a different level.”

### Exposure outside cluster
- **Q:** “How do you restrict to a CIDR?”
  **A:** “Firewall/SG easiest; or Calico HostEndpoint + GlobalNetworkPolicy for host ingress allowlist.”

---

## 15) “Get status fast” command bundle (paste during demo)

```bash
# cluster
kubectl get nodes -o wide
kubectl get pods -A -o wide

# calico
kubectl get pods -A -o wide | egrep -i 'calico|tigera'
kubectl -n calico-system get pods -o wide
kubectl -n tigera-operator get pods -o wide

# bookinfo
kubectl -n bookinfo get pods -o wide
kubectl -n bookinfo get svc -o wide
kubectl -n bookinfo get networkpolicy.projectcalico.org -o wide

# dns
kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide
kubectl -n kube-system get svc kube-dns -o wide

# events
kubectl get events -A --sort-by=.lastTimestamp | tail -n 30
```

---

## Appendix A) Fixed deploy scripts (as used in your workbook)

### Control-plane script (etcd-1)
> You already have this in your notes/workbook. Keep it as the “fixed deploy script”.

```bash
#!/usr/bin/env bash
set -euo pipefail

CONTROL_IP="192.168.122.192"
POD_CIDR="192.168.0.0/16"
K8S_MAJOR_MINOR="v1.30"
CALICO_VERSION="v3.28.0"

sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gpg

sudo swapoff -a
sudo sed -i.bak '/\sswap\s/s/^/#/' /etc/fstab

sudo tee /etc/modules-load.d/k8s.conf >/dev/null <<'EOF'
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

sudo tee /etc/sysctl.d/99-kubernetes-cri.conf >/dev/null <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system

sudo apt-get install -y containerd
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl enable --now containerd

sudo mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_MAJOR_MINOR}/deb/Release.key" \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MAJOR_MINOR}/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null

sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable --now kubelet

sudo kubeadm init \
  --apiserver-advertise-address="${CONTROL_IP}" \
  --pod-network-cidr="${POD_CIDR}"

mkdir -p "$HOME/.kube"
sudo cp -i /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u)":"$(id -g)" "$HOME/.kube/config"

kubectl apply -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"

kubeadm token create --print-join-command
```

### Worker script (worker-1/worker-2)
```bash
#!/usr/bin/env bash
set -euo pipefail

K8S_MAJOR_MINOR="v1.30"

sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gpg

sudo swapoff -a
sudo sed -i.bak '/\sswap\s/s/^/#/' /etc/fstab

sudo tee /etc/modules-load.d/k8s.conf >/dev/null <<'EOF'
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

sudo tee /etc/sysctl.d/99-kubernetes-cri.conf >/dev/null <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system

sudo apt-get install -y containerd
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl enable --now containerd

sudo mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_MAJOR_MINOR}/deb/Release.key" \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MAJOR_MINOR}/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null

sudo apt-get update
sudo apt-get install -y kubelet kubeadm
sudo apt-mark hold kubelet kubeadm
sudo systemctl enable --now kubelet

echo "Paste and run kubeadm join from control-plane:"
echo "  sudo kubeadm join <CONTROL_IP>:6443 --token ... --discovery-token-ca-cert-hash sha256:..."
```

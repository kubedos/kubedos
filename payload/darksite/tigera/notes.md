# Kubernetes Walkthrough

This is an end-to-end runbook that merges all your notes into one coherent, copy/paste‑ready workflow:
- Proxmox‑hosted Debian JeOS nodes
- kubeadm bootstrap (single control-plane)
- Calico installed **via Tigera Operator** (authoritative)
- Bookinfo deployment + test pods
- The NetworkPolicy incident (what broke → why → how you fixed it)
- The final “golden” Calico NetworkPolicy YAML set
- A clean export/evidence tree + collector scripts

> **Primary lesson learned:** DHCP-based node IPs are a cluster killer. Fix node addressing first (DHCP reservations or static IPs), then bootstrap.

---

## Table of contents
1. Parameters (edit these first)
2. Environment + inventory
3. Baseline node prep (all nodes)
4. Container runtime (containerd)
5. Kubernetes packages (kubelet/kubeadm/kubectl)
6. Bootstrap the cluster (kubeadm init/join)
7. Install Calico (Tigera Operator)
8. Deploy Bookinfo + test pods
9. Policy strategy
10. Incident report (broken → fixed)
11. Golden YAML set (single file + apply order)
12. Validation commands (proof)
13. Evidence collection (export tree + scripts)
14. Known gotchas + hardening checklist

---

## 1) Parameters (edit these first)

Set these values once and reuse them everywhere.

```bash
# Control-plane hostname
export CP_HOST="etcd-1"

# Control-plane IP (MUST be stable; use DHCP reservation or static IP)
export CP_IP="192.168.122.60"

# Kubernetes version channel used for pkgs.k8s.io repo
export K8S_MAJOR_MINOR="v1.30"

# Pod CIDR (Calico-friendly default)
export POD_CIDR="192.168.0.0/16"

# Service CIDR (default kubeadm; only change if you know why)
export SVC_CIDR="10.96.0.0/12"

# Bookinfo namespace + test namespaces
export NS_APP="bookinfo"
export NS_OTHER="other"
```

> If your lab had multiple IP sets (e.g., 192.168.122.232 vs .231), that’s the DHCP drift issue. Standardize addresses now.

---

## 2) Environment + inventory

### 2.1 Nodes (example inventory)
| Role | Hostname | IP |
|---|---|---|
| control-plane | `etcd-1` | `${CP_IP}` |
| worker | `worker-1` | `192.168.122.231` *(example)* |
| worker | `worker-2` | `192.168.122.13` *(example)* |

### 2.2 Tools you built/used (for context)
- kubedos Debian 13 JeOS image
- installer scripts for control-plane/worker (`install.sh`)
- shell menu + aliases (`kubed`, `.bashrc` sub-menu)
- diagnostic toolkit `ksnoop.py`
- `clush` wrapper / SSH config
- export locations:
  - `/root/export/` (workbook yamls)
  - `/root/out/` (diag-tool output)

### 2.3 Problem statement (root cause)
- Node IPs were DHCP-based; **control-plane IP changed mid-flight** → kubeadm + kubelet + clients/joins broke and/or became inconsistent.

**Fix recommendation (do before anything else):**
- Either configure **static IP** on each node, or set **DHCP reservations** on the DHCP server for each VM MAC.
- Confirm `ip addr` + `ip route` are stable across reboots.

---

## 3) Baseline node prep (all nodes)

### 3.1 `/etc/hosts` (recommended for small labs)
On **each node**:

```bash
sudo tee -a /etc/hosts >/dev/null <<EOF
${CP_IP} etcd-1
192.168.122.231 worker-1
192.168.122.13  worker-2
EOF
```

### 3.2 Disable swap (required)
```bash
sudo swapoff -a
sudo sed -i.bak '/\sswap\s/s/^/#/' /etc/fstab
```

Verify:
```bash
swapon --show
free -h
```

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

Verify:
```bash
lsmod | egrep 'overlay|br_netfilter'
sysctl net.ipv4.ip_forward
```

---

## 4) Container runtime: containerd (all nodes)

```bash
sudo apt-get update
sudo apt-get install -y containerd

sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml >/dev/null

# Use systemd cgroups (recommended for kubelet stability)
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

sudo systemctl enable --now containerd
```

Verify:
```bash
systemctl status containerd --no-pager
grep -n "SystemdCgroup" /etc/containerd/config.toml
```

---

## 5) Kubernetes packages (kubelet/kubeadm/kubectl)

### 5.1 Install repo + packages
On **control-plane** install `kubelet kubeadm kubectl`.  
On **workers** install `kubelet kubeadm`.

```bash
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gpg

sudo mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_MAJOR_MINOR}/deb/Release.key" \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MAJOR_MINOR}/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null

sudo apt-get update
```

Control-plane:
```bash
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable --now kubelet
```

Workers:
```bash
sudo apt-get install -y kubelet kubeadm
sudo apt-mark hold kubelet kubeadm
sudo systemctl enable --now kubelet
```

Verify:
```bash
kubeadm version
kubelet --version
```

---

## 6) Bootstrap the cluster (kubeadm)

### 6.1 Control-plane: `kubeadm init` (run on `${CP_HOST}`)
```bash
sudo kubeadm init \
  --apiserver-advertise-address="${CP_IP}" \
  --pod-network-cidr="${POD_CIDR}"
```

**Key files created:**
- `/etc/kubernetes/admin.conf`
- `/etc/kubernetes/manifests/`
- `/etc/kubernetes/pki/`
- `/var/lib/kubelet/config.yaml`

### 6.2 Configure kubectl (on control-plane)
```bash
mkdir -p "$HOME/.kube"
sudo cp -i /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u)":"$(id -g)" "$HOME/.kube/config"
```

Verify:
```bash
kubectl get nodes -o wide
kubectl -n kube-system get pods -o wide
```

### 6.3 Workers: join the cluster
On control-plane, print a join command:
```bash
kubeadm token create --print-join-command
```

Run it on each worker:
```bash
sudo kubeadm join ${CP_IP}:6443 --token <...> --discovery-token-ca-cert-hash sha256:<...>
```

Verify from control-plane:
```bash
kubectl get nodes -o wide
```

---

## 7) Install Calico via Tigera Operator (authoritative path)

> Your final cluster state referenced these namespaces:
> - `tigera-operator`
> - `calico-system`

### 7.1 Install Tigera Operator
Apply operator manifest (example pattern — keep the manifest in your repo for repeatability):
```bash
# Example:
# kubectl apply -f tigera-operator.yaml
#
# (Store this as a pinned, versioned file in git. Avoid floating "latest".)
```

### 7.2 Create the Installation CR
Create `calico-installation.yaml`:

```yaml
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
    - blockSize: 26
      cidr: 192.168.0.0/16
      encapsulation: VXLANCrossSubnet
      natOutgoing: Enabled
      nodeSelector: all()
```

Apply:
```bash
kubectl apply -f calico-installation.yaml
```

Verify:
```bash
kubectl get pods -A -o wide | egrep -i 'calico|tigera'
kubectl -n calico-system get pods -o wide
```

> If you used the “raw calico.yaml” manifest earlier, keep it as a **fallback** but treat Operator-managed as the final.

---

## 8) Deploy Bookinfo + test pods

### 8.1 Deploy Bookinfo
```bash
kubectl create ns ${NS_APP} || true
kubectl -n ${NS_APP} apply -f ~/bookinfo.yaml

kubectl -n ${NS_APP} get pods -o wide
kubectl -n ${NS_APP} get svc  -o wide
```

### 8.2 Create test pods (inside + outside namespace)
Bookinfo tester:
```bash
kubectl -n ${NS_APP} run curl-dev1 --image=curlimages/curl:8.10.1 --restart=Never --command -- sleep 36000
kubectl -n ${NS_APP} wait --for=condition=Ready pod/curl-dev1 --timeout=120s
kubectl -n ${NS_APP} label pod curl-dev1 role=tester --overwrite
kubectl -n ${NS_APP} get pod curl-dev1 --show-labels
```

Outside namespace tester:
```bash
kubectl create ns ${NS_OTHER} || true
kubectl -n ${NS_OTHER} run curl-other --image=curlimages/curl:8.10.1 --restart=Never --command -- sleep 36000
kubectl -n ${NS_OTHER} wait --for=condition=Ready pod/curl-other --timeout=120s
kubectl -n ${NS_OTHER} get pod curl-other -o wide
```

---

## 9) Policy strategy (what you enforced)

**Goal**
- Enforce **default deny** in `bookinfo` (Ingress + Egress).
- Allow only:
  - DNS egress to CoreDNS (TCP/UDP 53)
  - productpage ingress **only from** `bookinfo`
  - required app-to-app calls (productpage→details/reviews, reviews→ratings)
  - tester pod egress to productpage

**Why Ingress + Egress**
- Ingress-only blocks inbound but allows arbitrary outbound.
- Egress is required for least privilege.

---

## 10) Incident report: what broke → why → how it was fixed

### 10.1 What broke
1. **DHCP IP drift**: node IPs changed mid-run; kubeadm/join and client assumptions broke.
2. **Default deny blocked DNS**: once you enabled default deny with **Egress**, pods could not resolve service names.
3. **Calico policy schema errors**: early policies used Kubernetes NetworkPolicy-style fields like `spec.egress[].ports` instead of Calico CRD schema (`destination.ports`).
4. **RBAC mismatch**: ClusterRoleBinding referenced `calico-cni-plugin` ServiceAccount in `kube-system` instead of operator-managed `calico-system`.

### 10.2 Symptoms you saw
- `curl: (28) Resolving timed out ...`
- `nslookup ... no servers could be reached`
- Calico CRD apply failures:
  - `unknown field "spec.egress[0].ports"`
  - `cannot specify ports with a service selector`

### 10.3 Fixes applied
**A) Fix Calico CNI RBAC**
```bash
kubectl patch clusterrolebinding calico-cni-plugin \
  --type='json' \
  -p='[{"op":"replace","path":"/subjects/0/namespace","value":"calico-system"}]'

kubectl delete sa -n kube-system calico-cni-plugin
```

**B) Add DNS egress allow**
- Explicit allow to CoreDNS pods, TCP/UDP 53.

**C) Rewrite policies using valid Calico CRD structure**
- Ports belong under `destination.ports`.

**D) Fix the testing foot-gun**
- Don’t do `curl ... | head; echo $?` because that returns `head`’s status.
- Use `curl -w "rc=%{exitcode}"` or check `$?` immediately.

---

## 11) Golden YAML set (single file + apply order)

Create **one** file: `bookinfo-calico-policies.yaml` and apply it as a unit.

> Apply order is implicitly handled by Calico; still, conceptually: default deny → DNS allow → app allow rules.

```yaml
---
apiVersion: projectcalico.org/v3
kind: NetworkPolicy
metadata:
  name: bookinfo-default-deny
  namespace: bookinfo
spec:
  selector: all()
  types: [Ingress, Egress]

---
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

---
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

---
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

---
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

---
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

---
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

---
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

---
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

Apply:
```bash
kubectl apply -f bookinfo-calico-policies.yaml
kubectl -n bookinfo get networkpolicy.projectcalico.org -o wide
```

---

## 12) Validation commands (proof)

### 12.1 DNS works in bookinfo after policy
```bash
kubectl -n bookinfo exec -it curl-dev1 -- sh -c \
'cat /etc/resolv.conf; echo; nslookup kubernetes.default.svc.cluster.local && nslookup productpage.bookinfo.svc.cluster.local'
```

### 12.2 Bookinfo tester can reach productpage (allowed)
```bash
kubectl -n bookinfo exec -it curl-dev1 -- sh -c \
'curl -m 3 -sS -o /dev/null -w "productpage code=%{http_code} rc=%{exitcode}\n" http://productpage:9080/productpage'
```

Expected: `code=200 rc=0`

### 12.3 Other namespace cannot reach productpage (denied)
```bash
kubectl -n other exec -it curl-other -- sh -c \
'curl -m 3 -sS -o /dev/null -w "productpage code=%{http_code} rc=%{exitcode}\n" http://productpage.bookinfo.svc.cluster.local:9080/productpage || true'
```

Expected: `code=000 rc=28`

---

## 13) Evidence collection (export tree + scripts)

### 13.1 Recommended folder tree
```bash
mkdir -p ~/k8s-exports/{00-cluster,10-nodes,20-calico,30-bookinfo,40-kube-system,90-snapshots,scripts}
```

### 13.2 Minimal “hand-in” exports (cluster-side)
```bash
export KUBECONFIG=/etc/kubernetes/admin.conf

# Cluster inventory
kubectl get ns -o yaml > ~/k8s-exports/00-cluster/namespaces.yaml
kubectl get nodes -o yaml > ~/k8s-exports/00-cluster/nodes.yaml
kubectl get events -A --sort-by=.lastTimestamp > ~/k8s-exports/00-cluster/events.all-ns.txt

# Calico/Tigera evidence
kubectl get pods -A -o wide | egrep -i 'calico|tigera' > ~/k8s-exports/20-calico/pods.calico-and-tigera.txt
kubectl -n calico-system get all -o yaml > ~/k8s-exports/20-calico/calico-system.all.yaml
kubectl -n tigera-operator get all -o yaml > ~/k8s-exports/20-calico/tigera-operator.all.yaml

# Bookinfo + policies
kubectl -n bookinfo get deploy,po,svc,ep -o yaml > ~/k8s-exports/30-bookinfo/bookinfo.workloads-and-svcs.yaml
kubectl -n bookinfo get networkpolicy.projectcalico.org -o yaml > ~/k8s-exports/30-bookinfo/bookinfo.calico-policies.yaml

# DNS evidence
kubectl -n kube-system get svc kube-dns -o yaml > ~/k8s-exports/40-kube-system/kube-dns.svc.yaml
kubectl -n kube-system get deploy coredns -o yaml > ~/k8s-exports/40-kube-system/coredns.deploy.yaml
kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide > ~/k8s-exports/40-kube-system/coredns.pods.txt

# RBAC fix evidence
kubectl get clusterrolebinding calico-cni-plugin -o yaml > ~/k8s-exports/20-calico/calico-cni-plugin.crb.yaml
kubectl -n calico-system get sa calico-cni-plugin -o yaml > ~/k8s-exports/20-calico/calico-cni-plugin.sa.yaml
```

### 13.3 Node-side evidence (run on each node)
```bash
sudo ip addr > ip-addr.txt
sudo ip route > ip-route.txt
sudo iptables-save > iptables-save.txt
sudo ls -la /etc/kubernetes /etc/kubernetes/manifests /etc/cni/net.d /opt/cni/bin > paths.txt
sudo cp -a /etc/containerd/config.toml containerd-config.toml 2>/dev/null || true
```

---

## 14) Known gotchas + hardening checklist

### 14.1 DHCP drift (top priority)
- **Do**: static IPs or DHCP reservations
- **Do**: pin `--apiserver-advertise-address` to the stable CP IP
- **Do**: consider `--control-plane-endpoint` for HA / stable VIP usage later

### 14.2 Calico policy schema (don’t mix with k8s NetworkPolicy)
- Calico CRD ports must be at:
  - `egress[].destination.ports`
  - `ingress[].destination.ports`

### 14.3 DNS allow is mandatory with default deny + Egress
- Always include TCP/UDP 53 egress allow to CoreDNS.

### 14.4 Testing correctness
- Use:
  - `curl -m 3 -w "rc=%{exitcode} code=%{http_code}\n"`
- Avoid pipelines that hide exit codes.

### 14.5 Operator vs raw manifest
- Pick **one** as authoritative.
- For repeatable production-style setups, prefer Tigera Operator + pinned manifests in git.

---

## Appendix A — One-liner status bundle (demo-friendly)

```bash
kubectl get nodes -o wide
kubectl get pods -A -o wide
kubectl get pods -A -o wide | egrep -i 'calico|tigera'
kubectl -n bookinfo get pods,svc -o wide
kubectl -n bookinfo get networkpolicy.projectcalico.org -o wide
kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide
kubectl get events -A --sort-by=.lastTimestamp | tail -n 30
```


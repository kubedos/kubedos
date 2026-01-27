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

(eBPF) todd@sapphire:~$ 

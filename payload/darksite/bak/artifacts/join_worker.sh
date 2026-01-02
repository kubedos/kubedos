#!/usr/bin/env bash
set -euo pipefail
kubeadm join k8s-api.unixbox.net:6443 --token y87b4v.20uqkatpjp4hrrkf --discovery-token-ca-cert-hash sha256:ea74f8b59efa860765513fea3da9964138926aa6fef31199989798ed4870a137  --node-name "${HOSTNAME}"

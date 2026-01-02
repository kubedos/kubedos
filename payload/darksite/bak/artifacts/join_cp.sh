#!/usr/bin/env bash
set -euo pipefail
kubeadm join k8s-api.unixbox.net:6443 --token v7550c.imtoszwvofielnud --discovery-token-ca-cert-hash sha256:ea74f8b59efa860765513fea3da9964138926aa6fef31199989798ed4870a137  \
  --control-plane \
  --certificate-key 9199c1acf21a806d1c7b944b9b069482d0af104744dd261c2a84d2cf0db678e8 \
  --node-name "${HOSTNAME}" \
  --apiserver-advertise-address "10.100.10.219"

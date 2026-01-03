#!/usr/bin/env bash
set -euo pipefail

DIR="inventory/host_vars"
mkdir -p "$DIR"

declare -A IPMAP=(
  ["cp-1.unixbox.net"]="10.100.10.217"
  ["cp-2.unixbox.net"]="10.100.10.216"
  ["cp-3.unixbox.net"]="10.100.10.215"

  ["etcd-1.unixbox.net"]="10.100.10.220"
  ["etcd-2.unixbox.net"]="10.100.10.219"
  ["etcd-3.unixbox.net"]="10.100.10.218"

  ["lb-1.unixbox.net"]="10.100.10.222"
  ["lb-2.unixbox.net"]="10.100.10.223"
  ["lb-3.unixbox.net"]="10.100.10.221"

  ["w-1.unixbox.net"]="10.100.10.214"
  ["w-2.unixbox.net"]="10.100.10.213"
  ["w-3.unixbox.net"]="10.100.10.212"

  ["prometheus.unixbox.net"]="10.100.10.211"
  ["grafana.unixbox.net"]="10.100.10.210"
  ["storage.unixbox.net"]="10.100.10.209"
)

for host in "${!IPMAP[@]}"; do
  file="${DIR}/${host}.yml"
  ip="${IPMAP[$host]}"
  echo "Writing $file -> $ip"
  cat > "$file" <<EOF
---
k8s_node_ip: "${ip}"
EOF
done

echo "DONE. Host vars created in $DIR"


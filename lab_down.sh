#!/usr/bin/env bash
set -euo pipefail
# Stop only the processes that run inside the lab namespaces. A network namespace does not
# hide other processes, so "ip netns exec rtr pkill dnsmasq" would also kill every dnsmasq
# on the host, such as the one libvirt or NetworkManager runs.
for ns in sw rtr hostA hostB; do
  if ip netns list 2>/dev/null | grep -qw "$ns"; then
    for pid in $(ip netns pids "$ns" 2>/dev/null); do
      kill -9 "$pid" 2>/dev/null || true
    done
  fi
done
for ns in sw rtr hostA hostB; do ip netns del "$ns" 2>/dev/null || true; done
rm -rf /tmp/switching_l3_lab 2>/dev/null || true
echo "Lab torn down."

#!/usr/bin/env bash
set -euo pipefail
for ns in sw rtr hostA hostB; do
  ip netns pids "$ns" >/dev/null 2>&1 && ip netns exec "$ns" pkill -9 dnsmasq >/dev/null 2>&1 || true
done
for ns in sw rtr hostA hostB; do ip netns del "$ns" 2>/dev/null || true; done
rm -rf /tmp/switching_l3_lab 2>/dev/null || true
echo "Lab torn down."

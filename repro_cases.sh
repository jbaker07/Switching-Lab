#!/usr/bin/env bash
# Repro toggles for Switching/L3 Lab
# Usage: ./repro_cases.sh list | native-mismatch on|off | mtu-low on|off | drop-route on|off
set -euo pipefail

SW=sw
RTR=rtr
TRUNK_SW=v_trunk_sw
SVI20=v_trunk_rtr.20

usage(){ echo "Usage: $0 list | native-mismatch on|off | mtu-low on|off | drop-route on|off"; exit 2; }
[[ $# -ge 1 ]] || usage

case "$1" in
  list)
    cat <<EOF
Cases:
  native-mismatch on|off   # make trunk untagged VLAN 10 (bad) / restore tagged-only trunk
  mtu-low on|off           # set MTU 1300 on VLAN20 SVI / restore 1500
  drop-route on|off        # remove default on hostB / restore default via 192.168.20.1
EOF
    ;;

  native-mismatch)
    [[ $# -eq 2 ]] || usage
    if [[ "$2" == "on" ]]; then
      # BAD: make trunk carry VLAN 10 untagged (native), 20 tagged
      ip -n "$SW" bridge vlan del dev "$TRUNK_SW" vid 10 2>/dev/null || true
      ip -n "$SW" bridge vlan add dev "$TRUNK_SW" vid 10 pvid untagged
      ip -n "$SW" bridge vlan add dev "$TRUNK_SW" vid 20 2>/dev/null || true
      echo "Native VLAN mismatch enabled: trunk now untagged VLAN 10."
    elif [[ "$2" == "off" ]]; then
      # GOOD: remove untagged on 10; trunk carries 10,20 tagged. Give the port a harmless native (1).
      ip -n "$SW" bridge vlan del dev "$TRUNK_SW" vid 10 pvid untagged 2>/dev/null || true
      ip -n "$SW" bridge vlan add dev "$TRUNK_SW" vid 10 2>/dev/null || true
      ip -n "$SW" bridge vlan add dev "$TRUNK_SW" vid 20 2>/dev/null || true
      # ensure some native exists (Linux bridge likes a PVID); VLAN 1 untagged is a neutral choice.
      ip -n "$SW" bridge vlan add dev "$TRUNK_SW" vid 1 pvid untagged 2>/dev/null || true
      echo "Native VLAN mismatch disabled: trunk tagged for 10,20; PVID set to VLAN 1."
    else usage; fi
    ;;

  mtu-low)
    [[ $# -eq 2 ]] || usage
    if [[ "$2" == "on" ]]; then
      ip -n "$RTR" link set dev "$SVI20" mtu 1300
      echo "Set MTU 1300 on $SVI20."
    elif [[ "$2" == "off" ]]; then
      ip -n "$RTR" link set dev "$SVI20" mtu 1500
      echo "Restored MTU 1500 on $SVI20."
    else usage; fi
    ;;

  drop-route)
    [[ $# -eq 2 ]] || usage
    if [[ "$2" == "on" ]]; then
      ip -n hostB route del default || true
      echo "Removed default route on hostB."
    elif [[ "$2" == "off" ]]; then
      ip -n hostB route add default via 192.168.20.1 || true
      echo "Restored default route on hostB."
    else usage; fi
    ;;

  *) usage ;;
esac

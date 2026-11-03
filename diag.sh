#!/usr/bin/env bash
set -euo pipefail

say(){ printf "[%s] %s\n" "$1" "$2"; }

# ---- Reachability quick checks ----
if ip netns exec hostA ping -c1 -W1 192.168.10.1 >/dev/null 2>&1; then
  say PASS "hostA→R10"
else
  say FAIL "hostA→R10 (GW/SVI or VLAN10 on access port)"
fi

if ip netns exec hostB ping -c1 -W1 192.168.20.1 >/dev/null 2>&1; then
  say PASS "hostB→R20"
else
  say FAIL "hostB→R20 (GW/SVI or VLAN20 on access port)"
fi

if ip netns exec hostA ping -c1 -W1 192.168.20.2 >/dev/null 2>&1; then
  say PASS "hostA→hostB (inter-VLAN)"
else
  say FAIL "hostA→hostB (inter-VLAN path broken)"
fi

# ---- MTU path probe (hostA -> hostB, so it leaves the router on the VLAN20 SVI that mtu-low shrinks) ----
SIZE=1472
OKMTU=0
while (( SIZE >= 1200 )); do
  if ip netns exec hostA ping -c1 -M do -s "$SIZE" 192.168.20.2 >/dev/null 2>&1; then
    say PASS "Path MTU supports $SIZE bytes (DF)"
    OKMTU=1
    break
  fi
  SIZE=$((SIZE-40))
done
(( OKMTU == 0 )) && say INFO "Path MTU < 1200 or DF not honored (possible PMTUD issue)"

# ---- Trunk sanity (native VLAN / tagging) ----
# Parse Linux bridge VLAN flags for the trunk port (v_trunk_sw)
# We consider:
#  - GOOD: VLAN 10 and 20 present on trunk and both are TAGGED
#  - BAD : VLAN 10 or 20 appears as 'Egress Untagged' (native mismatch)
#  - WARN: one of 10/20 missing on trunk

TRUNK=v_trunk_sw
mapfile -t VLAN_LINES < <(bridge -n sw -d vlan show dev "$TRUNK" 2>/dev/null | sed 's/ \+/ /g')

present_10=0; present_20=0
untag_10=0;  untag_20=0

for ln in "${VLAN_LINES[@]}"; do
  # bridge prints the VLAN id as a bare number: "v_trunk_sw 1 PVID Egress Untagged" or " 10"
  if [[ "$ln" =~ (^|[[:space:]])10([[:space:]]|$) ]]; then
    present_10=1
    [[ "$ln" =~ Egress[[:space:]]+Untagged ]] && untag_10=1
  fi
  if [[ "$ln" =~ (^|[[:space:]])20([[:space:]]|$) ]]; then
    present_20=1
    [[ "$ln" =~ Egress[[:space:]]+Untagged ]] && untag_20=1
  fi
done

if (( present_10==1 && present_20==1 && untag_10==0 && untag_20==0 )); then
  say PASS "Trunk tagging OK: VLANs 10 and 20 are tagged on $TRUNK"
else
  if (( untag_10==1 || untag_20==1 )); then
    bads=()
    (( untag_10==1 )) && bads+=("10 untagged (native)")
    (( untag_20==1 )) && bads+=("20 untagged (native)")
    say FAIL "Native-VLAN mismatch on trunk $TRUNK → $(IFS=', '; echo "${bads[*]}")"
    say INFO "Fix: ensure trunk carries VLANs 10/20 as TAGGED only; set a harmless native/PVID (e.g., VLAN 1)."
  fi
  if (( present_10==0 || present_20==0 )); then
    miss=()
    (( present_10==0 )) && miss+=("10")
    (( present_20==0 )) && miss+=("20")
    say FAIL "Trunk $TRUNK missing VLAN(s): $(IFS=', '; echo "${miss[*]}")"
    say INFO "Fix: bridge -n sw vlan add dev $TRUNK vid 10 ; bridge -n sw vlan add dev $TRUNK vid 20"
  fi
fi

# ---- Helpful next-steps ----
echo "---- Hints ----"
echo "Native mismatch?  → ./repro_cases.sh native-mismatch off"
echo "MTU problems?     → ./repro_cases.sh mtu-low off"
echo "Missing route H2? → ./repro_cases.sh drop-route off"

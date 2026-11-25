#!/usr/bin/env bash
# End to end checks for the switching lab. Prints one PASS, FAIL or INFO line per check,
# then hints for the failures it found.
# Exit code: 0 when nothing failed, 1 when at least one check failed, 2 when the lab is not up.
set -uo pipefail

FAILED_CHECKS=0
HINTS=()

say(){ printf "[%s] %s\n" "$1" "$2"; }
fail(){ say FAIL "$1"; FAILED_CHECKS=$((FAILED_CHECKS+1)); }
hint(){ HINTS+=("$1"); }

if [[ $EUID -ne 0 ]]; then
  echo "diag.sh needs root to enter the lab namespaces. Run: sudo ./diag.sh"
  exit 2
fi
for ns in sw rtr hostA hostB; do
  if ! ip netns list 2>/dev/null | awk '{print $1}' | grep -qx "$ns"; then
    echo "Namespace $ns is missing. Build the lab first: sudo ./lab_up.sh"
    exit 2
  fi
done

# ---- Reachability quick checks ----
if ip netns exec hostA ping -c1 -W1 192.168.10.1 >/dev/null 2>&1; then
  say PASS "hostA→R10"
else
  fail "hostA→R10 (GW/SVI or VLAN10 on access port)"
fi

if ip netns exec hostB ping -c1 -W1 192.168.20.1 >/dev/null 2>&1; then
  say PASS "hostB→R20"
else
  fail "hostB→R20 (GW/SVI or VLAN20 on access port)"
fi

# ---- Default routes on the hosts ----
# A host without a default route can still ping its own gateway, so check the route itself
for pair in hostA:192.168.10.1 hostB:192.168.20.1; do
  host=${pair%%:*}
  gw=${pair#*:}
  if ip -n "$host" route show default 2>/dev/null | grep -q "via $gw"; then
    say PASS "$host default route via $gw"
  else
    fail "$host has no default route via $gw, so it cannot answer anything off its own subnet"
    if [[ "$host" == hostB ]]; then
      hint "Missing route on hostB → ./repro_cases.sh drop-route off (or: ip -n hostB route add default via $gw)"
    else
      hint "Missing route on hostA → ip -n hostA route add default via $gw"
    fi
  fi
done

INTER_VLAN_OK=0
if ip netns exec hostA ping -c1 -W1 192.168.20.2 >/dev/null 2>&1; then
  say PASS "hostA→hostB (inter-VLAN)"
  INTER_VLAN_OK=1
else
  fail "hostA→hostB (inter-VLAN path broken)"
fi

# ---- MTU path probe (hostA -> hostB, so it leaves the router on the VLAN20 SVI that mtu-low shrinks) ----
df_ping(){ ip netns exec hostA ping -c1 -W1 -M "do" -s "$1" 192.168.20.2 >/dev/null 2>&1; }

if (( INTER_VLAN_OK == 0 )); then
  say INFO "Path MTU probe skipped because hostA cannot reach hostB at all"
else
  SIZE=1472
  OKSIZE=0
  while (( SIZE >= 1200 )); do
    if df_ping "$SIZE"; then
      OKSIZE=$SIZE
      break
    fi
    SIZE=$((SIZE-40))
  done
  if (( OKSIZE == 1472 )); then
    say PASS "Path MTU hostA→hostB is 1500 (1472 byte DF ping gets through)"
  elif (( OKSIZE == 0 )); then
    fail "No DF ping of 1200 bytes or more gets through hostA→hostB (MTU below 1228 or PMTUD broken)"
    hint "MTU problems → ./repro_cases.sh mtu-low off, and compare the interface MTUs above"
  else
    # The ladder steps by 40. Search between the size that worked and the one that failed for the exact value.
    LOW=$OKSIZE
    HIGH=$((OKSIZE+39))
    while (( LOW < HIGH )); do
      MID=$(( (LOW+HIGH+1)/2 ))
      if df_ping "$MID"; then LOW=$MID; else HIGH=$((MID-1)); fi
    done
    fail "Path MTU hostA→hostB is $((LOW+28)), below 1500 (largest DF ping payload is $LOW bytes)"
    hint "MTU problems → ./repro_cases.sh mtu-low off, or set the same MTU on every hop"
  fi
fi

# ---- Interface MTUs along the path ----
LOW_MTU=()
for entry in hostA:v_h1 hostB:v_h2 sw:v_h1_sw sw:v_h2_sw sw:v_trunk_sw sw:br0 rtr:v_trunk_rtr rtr:v_trunk_rtr.10 rtr:v_trunk_rtr.20; do
  ns=${entry%%:*}
  dev=${entry#*:}
  mtu=$(ip -n "$ns" -o link show dev "$dev" 2>/dev/null | sed -n 's/.* mtu \([0-9]*\).*/\1/p')
  if [[ -z "$mtu" ]]; then
    LOW_MTU+=("$dev in $ns is missing")
  elif (( mtu != 1500 )); then
    LOW_MTU+=("$dev in $ns has MTU $mtu")
  fi
done
if (( ${#LOW_MTU[@]} == 0 )); then
  say PASS "Every lab interface uses MTU 1500"
else
  fail "Interface MTU mismatch: $(IFS=','; echo "${LOW_MTU[*]}" | sed 's/,/, /g'). The rest of the path uses 1500"
fi

# ---- Trunk sanity (native VLAN / tagging) ----
# port_vlans PORT prints one "VID flags" line per VLAN on that switch port.
# bridge prints the port name only on the first line, for example
#   v_trunk_sw        1 PVID Egress Untagged
#                     10
port_vlans(){
  bridge -n sw vlan show dev "$1" 2>/dev/null | sed 's/ \+/ /g' | awk -v PORT="$1" '
    $0 ~ /vlan-id/ { next }
    $1 == PORT { $1 = "" }
    { sub(/^ +/, ""); if ($1 ~ /^[0-9]+$/) print }'
}

# We consider:
#  - GOOD: VLAN 10 and 20 present on trunk and both are TAGGED
#  - BAD : VLAN 10 or 20 appears as 'Egress Untagged' (native mismatch)
#  - BAD : one of 10/20 missing on trunk
TRUNK=v_trunk_sw
mapfile -t VLAN_LINES < <(port_vlans "$TRUNK")

present_10=0; present_20=0
untag_10=0;  untag_20=0

for ln in "${VLAN_LINES[@]}"; do
  vid=${ln%% *}
  if [[ "$vid" == 10 ]]; then
    present_10=1
    [[ "$ln" =~ Egress[[:space:]]+Untagged ]] && untag_10=1
  fi
  if [[ "$vid" == 20 ]]; then
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
    fail "Native-VLAN mismatch on trunk $TRUNK → $(IFS=','; echo "${bads[*]}" | sed 's/,/, /g')"
    say INFO "Fix: carry VLANs 10 and 20 tagged on the trunk and leave VLAN 1 as the untagged PVID"
    hint "Native mismatch → ./repro_cases.sh native-mismatch off"
  fi
  if (( present_10==0 || present_20==0 )); then
    miss=()
    (( present_10==0 )) && miss+=("10")
    (( present_20==0 )) && miss+=("20")
    fail "Trunk $TRUNK missing VLAN(s): $(IFS=','; echo "${miss[*]}" | sed 's/,/, /g')"
    say INFO "Fix: bridge -n sw vlan add dev $TRUNK vid 10 && bridge -n sw vlan add dev $TRUNK vid 20"
    hint "Missing trunk VLAN → bridge -n sw vlan add dev $TRUNK vid <10 or 20>"
  fi
fi

# ---- Access ports carry exactly one VLAN, untagged ----
for entry in v_h1_sw:10 v_h2_sw:20; do
  port=${entry%%:*}
  want=${entry#*:}
  mapfile -t PORT_LINES < <(port_vlans "$port")
  vids=()
  pvid_ok=0
  for ln in "${PORT_LINES[@]}"; do
    vids+=("${ln%% *}")
    [[ "${ln%% *}" == "$want" && "$ln" =~ PVID && "$ln" =~ Egress[[:space:]]+Untagged ]] && pvid_ok=1
  done
  if (( ${#vids[@]} == 1 && pvid_ok == 1 )); then
    say PASS "Access port $port is untagged in VLAN $want only"
  else
    fail "Access port $port should be untagged in VLAN $want only, it has VLANs: ${vids[*]:-none}"
    hint "Access port $port → bridge -n sw vlan add dev $port vid $want pvid untagged, and delete any other VID"
  fi
done

# ---- Helpful next-steps ----
if (( FAILED_CHECKS == 0 )); then
  echo "All checks passed."
  exit 0
fi
echo "---- Hints ----"
if (( ${#HINTS[@]} == 0 )); then
  echo "No known lab fault matches. Compare: bridge -n sw vlan show, ip -n rtr -br a, ip -n rtr -d link show"
else
  printf '%s\n' "${HINTS[@]}"
fi
echo "$FAILED_CHECKS check(s) failed."
exit 1

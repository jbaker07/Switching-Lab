#!/usr/bin/env bash
# Self test for the switching lab. It builds the lab, checks that diag.sh passes on the
# healthy lab, turns each fault case on, checks that diag.sh reports exactly the failures
# that fault should cause, turns it off again, checks DHCP on both VLANs and then tears
# the lab down and checks that nothing is left behind.
#
# Needs root on Linux with iproute2, dnsmasq and ping. dhclient (isc-dhcp-client) is
# optional. Without it the DHCP checks are skipped.
#
# Usage: sudo ./tests/self_test.sh
set -uo pipefail

LAB_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR=$(mktemp -d)
PASSED_COUNT=0
FAILED_COUNT=0
SKIPPED_COUNT=0
OUTSIDE_DNSMASQ_PID=""

pass() { echo "[PASS] $1"; PASSED_COUNT=$((PASSED_COUNT+1)); }
fail() { echo "[FAIL] $1"; FAILED_COUNT=$((FAILED_COUNT+1)); }
skip() { echo "[SKIP] $1"; SKIPPED_COUNT=$((SKIPPED_COUNT+1)); }

cleanup() {
  bash "$LAB_DIR/lab_down.sh" >/dev/null 2>&1
  if [[ -n "$OUTSIDE_DNSMASQ_PID" ]]; then kill "$OUTSIDE_DNSMASQ_PID" 2>/dev/null; fi
  rm -f /run/dhclient-switching-lab-*
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

if [[ $EUID -ne 0 ]]; then
  echo "self_test.sh needs root to create namespaces. Run: sudo ./tests/self_test.sh"
  exit 2
fi

run_diag() {
  bash "$LAB_DIR/diag.sh" >"$WORK_DIR/diag.out" 2>&1
  DIAG_EXIT_CODE=$?
}

show_diag() {
  sed 's/^/    /' "$WORK_DIR/diag.out"
}

#expect_diag NAME EXIT_CODE FAIL_COUNT PATTERN... checks the last diag run
expect_diag() {
  local CHECK_NAME="$1" WANTED_EXIT="$2" WANTED_FAILS="$3"
  shift 3
  local ACTUAL_FAILS
  ACTUAL_FAILS=$(grep -c '^\[FAIL\]' "$WORK_DIR/diag.out")
  local PROBLEMS=""
  [[ "$DIAG_EXIT_CODE" == "$WANTED_EXIT" ]] || PROBLEMS+=" exit code $DIAG_EXIT_CODE, wanted $WANTED_EXIT."
  [[ "$ACTUAL_FAILS" == "$WANTED_FAILS" ]] || PROBLEMS+=" $ACTUAL_FAILS FAIL lines, wanted $WANTED_FAILS."
  local PATTERN
  for PATTERN in "$@"; do
    grep -Eq "$PATTERN" "$WORK_DIR/diag.out" || PROBLEMS+=" no line matching: $PATTERN."
  done
  if [[ -z "$PROBLEMS" ]]; then
    pass "$CHECK_NAME"
  else
    fail "$CHECK_NAME:$PROBLEMS"
    show_diag
  fi
}

#dhcp_offer HOST_NS DEV prints "address router" from a DHCP lease, or nothing if no lease came back.
#The lease and pid files live under /run because the Ubuntu AppArmor profile for dhclient only allows those paths.
dhcp_offer() {
  local HOST_NS="$1" DEV="$2"
  local LEASE_FILE="/run/dhclient-switching-lab-$HOST_NS.leases"
  local PID_FILE="/run/dhclient-switching-lab-$HOST_NS.pid"
  rm -f "$LEASE_FILE"
  #-sf /bin/true keeps dhclient from changing the host's static address
  timeout 12 ip netns exec "$HOST_NS" dhclient -1 -sf /bin/true -lf "$LEASE_FILE" -pf "$PID_FILE" "$DEV" >/dev/null 2>&1
  ip netns exec "$HOST_NS" dhclient -x -sf /bin/true -lf "$LEASE_FILE" -pf "$PID_FILE" >/dev/null 2>&1
  [[ -f "$LEASE_FILE" ]] || return 0
  local ADDRESS ROUTER
  ADDRESS=$(sed -n 's/.*fixed-address \([0-9.]*\);.*/\1/p' "$LEASE_FILE" | head -1)
  ROUTER=$(sed -n 's/.*option routers \([0-9.]*\);.*/\1/p' "$LEASE_FILE" | head -1)
  [[ -n "$ADDRESS" ]] && echo "$ADDRESS $ROUTER"
}

echo "== Build the lab"
if bash "$LAB_DIR/lab_up.sh" >"$WORK_DIR/lab_up.out" 2>&1; then
  pass "lab_up.sh exits 0"
else
  fail "lab_up.sh failed"
  sed 's/^/    /' "$WORK_DIR/lab_up.out"
  exit 1
fi
MISSING_NAMESPACES=""
for NS in sw rtr hostA hostB; do
  ip netns list | awk '{print $1}' | grep -qx "$NS" || MISSING_NAMESPACES+=" $NS"
done
if [[ -z "$MISSING_NAMESPACES" ]]; then
  pass "namespaces sw, rtr, hostA and hostB exist"
else
  fail "namespaces missing:$MISSING_NAMESPACES"
fi

echo "== Healthy lab"
run_diag
expect_diag "diag.sh passes on the healthy lab" 0 0 "^All checks passed\.$" \
  "Path MTU hostA→hostB is 1500" "Trunk tagging OK"

echo "== DHCP on both VLANs"
if command -v dhclient >/dev/null; then
  for ENTRY in hostA:v_h1:10 hostB:v_h2:20; do
    IFS=: read -r HOST_NS DEV VLAN <<<"$ENTRY"
    OFFER=$(dhcp_offer "$HOST_NS" "$DEV")
    ADDRESS=${OFFER%% *}
    ROUTER=${OFFER#* }
    if [[ "$ADDRESS" =~ ^192\.168\.$VLAN\.(5[0-9]|[6-9][0-9])$ && "$ROUTER" == "192.168.$VLAN.1" ]]; then
      pass "DHCP on VLAN $VLAN gives $HOST_NS $ADDRESS with router $ROUTER"
    else
      fail "DHCP on VLAN $VLAN gave $HOST_NS '${OFFER:-no lease}', wanted 192.168.$VLAN.50 to .99 with router 192.168.$VLAN.1"
    fi
  done
else
  skip "dhclient is not installed, DHCP checks skipped"
fi

echo "== Fault case native-mismatch"
bash "$LAB_DIR/repro_cases.sh" native-mismatch on >/dev/null
run_diag
expect_diag "diag.sh finds the native VLAN mismatch" 1 3 \
  "^\[FAIL\] Native-VLAN mismatch on trunk v_trunk_sw → 10 untagged" \
  "^\[FAIL\] hostA→R10" "^\[FAIL\] hostA→hostB" \
  "^Native mismatch → \./repro_cases\.sh native-mismatch off$"
if command -v dhclient >/dev/null; then
  OFFER=$(dhcp_offer hostA v_h1)
  if [[ -z "$OFFER" ]]; then
    pass "DHCP on VLAN 10 gets no answer while the native VLAN is wrong"
  else
    fail "DHCP on VLAN 10 still answered during native-mismatch: $OFFER"
  fi
fi
bash "$LAB_DIR/repro_cases.sh" native-mismatch off >/dev/null
run_diag
expect_diag "diag.sh passes after native-mismatch off" 0 0 "^All checks passed\.$"

echo "== Fault case mtu-low"
bash "$LAB_DIR/repro_cases.sh" mtu-low on >/dev/null
run_diag
expect_diag "diag.sh finds the low MTU on the VLAN 20 SVI" 1 2 \
  "^\[FAIL\] Path MTU hostA→hostB is 1300, below 1500 \(largest DF ping payload is 1272 bytes\)$" \
  "^\[FAIL\] Interface MTU mismatch: v_trunk_rtr\.20 in rtr has MTU 1300" \
  "mtu-low off"
bash "$LAB_DIR/repro_cases.sh" mtu-low off >/dev/null
run_diag
expect_diag "diag.sh passes after mtu-low off" 0 0 "^All checks passed\.$" "Path MTU hostA→hostB is 1500"

echo "== Fault case drop-route"
bash "$LAB_DIR/repro_cases.sh" drop-route on >/dev/null
run_diag
expect_diag "diag.sh finds hostB's missing default route" 1 2 \
  "^\[FAIL\] hostB has no default route via 192\.168\.20\.1" "^\[FAIL\] hostA→hostB" \
  "^\[INFO\] Path MTU probe skipped" "drop-route off"
bash "$LAB_DIR/repro_cases.sh" drop-route off >/dev/null
run_diag
expect_diag "diag.sh passes after drop-route off" 0 0 "^All checks passed\.$"

echo "== repro_cases.sh arguments"
if bash "$LAB_DIR/repro_cases.sh" list >/dev/null; then pass "repro_cases.sh list exits 0"; else fail "repro_cases.sh list failed"; fi
bash "$LAB_DIR/repro_cases.sh" no-such-case on >/dev/null 2>&1
if [[ $? -eq 2 ]]; then pass "repro_cases.sh rejects an unknown case with exit 2"; else fail "repro_cases.sh accepted an unknown case"; fi

echo "== Tear down"
#a dnsmasq outside the lab must survive lab_down.sh. --port=0 and no DHCP range means it serves nothing.
if command -v dnsmasq >/dev/null; then
  dnsmasq --conf-file=/dev/null --port=0 --keep-in-foreground --pid-file="$WORK_DIR/outside.pid" &
  OUTSIDE_DNSMASQ_PID=$!
  sleep 0.5
fi
bash "$LAB_DIR/lab_down.sh" >/dev/null 2>&1
LEFT_OVER=""
for NS in sw rtr hostA hostB; do
  ip netns list | awk '{print $1}' | grep -qx "$NS" && LEFT_OVER+=" namespace $NS"
done
[[ -e /tmp/switching_l3_lab ]] && LEFT_OVER+=" /tmp/switching_l3_lab"
if [[ -z "$LEFT_OVER" ]]; then
  pass "lab_down.sh removes the namespaces and the state folder"
else
  fail "left behind after lab_down.sh:$LEFT_OVER"
fi
if [[ -n "$OUTSIDE_DNSMASQ_PID" ]]; then
  if kill -0 "$OUTSIDE_DNSMASQ_PID" 2>/dev/null; then
    pass "a dnsmasq outside the lab is still running after lab_down.sh"
  else
    fail "lab_down.sh killed a dnsmasq that was not part of the lab"
  fi
fi
run_diag
if [[ $DIAG_EXIT_CODE -eq 2 ]]; then
  pass "diag.sh exits 2 when the lab is not up"
else
  fail "diag.sh exit code $DIAG_EXIT_CODE when the lab is not up, wanted 2"
fi

echo "Summary: $PASSED_COUNT passed, $FAILED_COUNT failed, $SKIPPED_COUNT skipped"
[[ $FAILED_COUNT -eq 0 ]]

# Decision Tree: Switching/L3 Issues

**Symptom:** hostA can’t reach hostB
1) On hostA: `ip netns exec hostA ping -c1 192.168.10.1`
   - Fail → GW/SVI or VLAN 10 problem on hostA side
2) On hostB: `ip netns exec hostB ping -c1 192.168.20.1`
   - Fail → GW/SVI or VLAN 20 problem on hostB side
3) If both pass GW pings → inter-VLAN path:
   - `ip netns exec hostA ping -c1 192.168.20.2`
   - If fail, run on SW: `bridge -n sw vlan show dev v_trunk_sw`
     - VLAN 10 or 20 listed as `Egress Untagged` → native VLAN mismatch. **Fix:** make trunk VLANs 10 and 20 tagged. VLAN 1 as the untagged PVID is expected.

**Symptom:** Some large payloads fail, small pings OK (TLS resets/black-holes)
- `ip netns exec hostA ping -c1 -M do -s 1472 192.168.20.2` (this crosses the VLAN 20 SVI, the same path `diag.sh` probes)
- If fail but small works → MTU/PMTUD issue.
  - Check SVI MTU: `ip -n rtr link show v_trunk_rtr.20`
  - **Fix:** standardize MTU (1500) or enable MSS clamping.

**Symptom:** Only hostB has no internet/L3 reachability
- `ip netns exec hostB ip route`
- Missing `default via 192.168.20.1` → **Fix**: add default.

**Escalation packet checklist**
- `bridge -n sw vlan show` (trunk and access port VLAN membership)
- `ip -n rtr -br a` (SVI addresses)
- `ip -n rtr -d link show` (MTU of the trunk and both SVIs)
- A short `ip netns exec rtr tcpdump -i v_trunk_rtr -vvv vlan and icmp` while reproducing

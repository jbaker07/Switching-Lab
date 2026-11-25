# Switching Lab

A Linux network namespace lab that builds a small switched network on one machine: two access ports on different VLANs, an 802.1Q trunk, and a router on a stick doing inter-VLAN routing. Three common faults can be switched on and off, a diagnostic script checks the network from end to end, and a decision tree walks from symptom to fix.

Everything runs in network namespaces with veth pairs and a VLAN-aware Linux bridge, so it needs no switch hardware or VMs.

## Topology

```text
hostA (192.168.10.2/24)                          hostB (192.168.20.2/24)
   v_h1 ── access VLAN 10 ──┐        ┌── access VLAN 20 ── v_h2
                            │        │
                        [ sw: br0, vlan_filtering ]
                                 │
                         trunk, VLANs 10 and 20 tagged
                                 │
                 [ rtr: v_trunk_rtr.10 = 192.168.10.1/24 ]
                 [      v_trunk_rtr.20 = 192.168.20.1/24 ]
```

| Namespace | Role |
|-----------|------|
| `sw` | Linux bridge `br0` with VLAN filtering. `v_h1_sw` is an access port on VLAN 10 only, `v_h2_sw` an access port on VLAN 20 only, and `v_trunk_sw` a trunk carrying both VLANs tagged with VLAN 1 as the untagged PVID. |
| `rtr` | Router on a stick. VLAN subinterfaces `v_trunk_rtr.10` and `v_trunk_rtr.20` act as the gateways, IPv4 forwarding is on, and dnsmasq serves DHCP ranges .50 to .99 on each VLAN with that VLAN's own gateway as the router option. |
| `hostA` | 192.168.10.2/24, default route via 192.168.10.1 |
| `hostB` | 192.168.20.2/24, default route via 192.168.20.1 |

The hosts use static addresses. The dnsmasq config, log and PID file live in `/tmp/switching_l3_lab`.

Two settings make the lab behave like real switch and router hardware rather than like a default Linux box:

- A VLAN aware Linux bridge puts every new port in VLAN 1 untagged. `lab_up.sh` removes VLAN 1 from the two access ports, so untagged traffic on the trunk's native VLAN cannot reach the hosts.
- Linux answers ARP for any of its addresses on any interface and accepts packets for a local address on any interface. On the router that hides a native VLAN mismatch, because hostA's untagged frames land on the parent `v_trunk_rtr` and are still answered. `lab_up.sh` sets `arp_ignore=1` and `rp_filter=1` in the `rtr` namespace, so the router only answers on the subinterface that owns the address.

## Fault cases

`repro_cases.sh` injects and clears each fault:

| Case | `on` | `off` |
|------|------|-------|
| `native-mismatch` | VLAN 10 becomes the untagged native VLAN on the trunk, so hostA's frames reach the router untagged instead of on its VLAN 10 subinterface. hostA loses its gateway, inter-VLAN routing and DHCP. | Trunk carries 10 and 20 tagged, with VLAN 1 as the untagged PVID |
| `mtu-low` | MTU 1300 on the VLAN 20 SVI | MTU 1500, and hostA's cached path MTU is flushed |
| `drop-route` | Removes hostB's default route | Restores `default via 192.168.20.1` |

## What `diag.sh` checks

1. hostA can ping its gateway 192.168.10.1
2. hostB can ping its gateway 192.168.20.1
3. hostA and hostB each have a default route via their own gateway. A host without one can still ping its gateway, so the route is checked directly.
4. hostA can ping hostB (inter-VLAN routing)
5. Path MTU from hostA to hostB, using don't-fragment pings from 1472 bytes down in 40-byte steps, then a binary search between the size that worked and the one that failed for the exact value. PASS at 1500, FAIL below it. This path crosses the VLAN 20 SVI, so `mtu-low on` reports a path MTU of 1300 (a 1272 byte payload). The probe is skipped when check 4 fails, since a dead path says nothing about MTU.
6. The MTU of every lab interface on the path. FAIL names any interface that is not at 1500, which points at the cause of a low result in check 5.
7. Trunk tagging on `v_trunk_sw`: PASS when VLANs 10 and 20 are both present and tagged, FAIL when either is untagged (native VLAN mismatch) or missing, with the command that fixes it.
8. Each access port is untagged in its own VLAN and in no other VLAN.

Each check prints a `[PASS]`, `[FAIL]` or `[INFO]` line. When something fails, a hints section names the fault case or command that fixes it. Example with `mtu-low on`:

```text
[PASS] hostA→R10
[PASS] hostB→R20
[PASS] hostA default route via 192.168.10.1
[PASS] hostB default route via 192.168.20.1
[PASS] hostA→hostB (inter-VLAN)
[FAIL] Path MTU hostA→hostB is 1300, below 1500 (largest DF ping payload is 1272 bytes)
[FAIL] Interface MTU mismatch: v_trunk_rtr.20 in rtr has MTU 1300. The rest of the path uses 1500
[PASS] Trunk tagging OK: VLANs 10 and 20 are tagged on v_trunk_sw
[PASS] Access port v_h1_sw is untagged in VLAN 10 only
[PASS] Access port v_h2_sw is untagged in VLAN 20 only
---- Hints ----
MTU problems → ./repro_cases.sh mtu-low off, or set the same MTU on every hop
2 check(s) failed.
```

| Exit code | Meaning |
|-----------|---------|
| 0 | Every check passed |
| 1 | At least one check failed |
| 2 | Not run as root, or the lab namespaces do not exist |

What each fault case makes `diag.sh` report:

| Case | FAIL lines |
|------|------------|
| `native-mismatch on` | hostA to its gateway, hostA to hostB, and the native VLAN mismatch on `v_trunk_sw` |
| `mtu-low on` | Path MTU 1300 and the 1300 MTU on `v_trunk_rtr.20` |
| `drop-route on` | hostB has no default route, and hostA to hostB |

## Requirements

- Linux with root access
- iproute2 (`ip` and `bridge`), `sysctl` and `dnsmasq`
- For the DHCP part of the self test, `dhclient` (the `isc-dhcp-client` package). Without it those checks are skipped.

The scripts and the self test were last run in a privileged Ubuntu 24.04 Docker container.

## Usage

```bash
sudo ./lab_up.sh                        # build the namespaces, bridge, trunk and router
sudo ./diag.sh                          # baseline, everything should pass

sudo ./repro_cases.sh list              # show the fault cases
sudo ./repro_cases.sh native-mismatch on
sudo ./diag.sh                          # find the fault
sudo ./repro_cases.sh native-mismatch off

sudo ./lab_down.sh                      # remove the namespaces and state
```

`lab_up.sh` runs `lab_down.sh` first, so it can be rerun to reset the lab. `lab_down.sh` stops only the processes that run inside the lab namespaces, so a dnsmasq the host runs for something else is left alone.

To see the DHCP side by hand, ask for a lease on VLAN 10 without changing hostA's static address:

```bash
sudo ip netns exec hostA dhclient -1 -v -sf /bin/true -lf /run/dhclient-lab.leases -pf /run/dhclient-lab.pid v_h1
grep -E "fixed-address|option routers" /run/dhclient-lab.leases   # an address in .50 to .99 and router 192.168.10.1
sudo ip netns exec hostA dhclient -x -pf /run/dhclient-lab.pid
```

## Self test

`tests/self_test.sh` builds the lab, checks that `diag.sh` passes, turns each fault case on and checks that `diag.sh` exits 1 with exactly the FAIL lines in the table above, turns it off and checks that everything passes again, checks that DHCP on each VLAN hands out an address from that VLAN's range with that VLAN's gateway (and that VLAN 10 gets no answer during `native-mismatch`), checks that `repro_cases.sh` rejects an unknown case, and then tears the lab down and checks that the namespaces and state folder are gone and that a dnsmasq outside the lab is still running.

```bash
sudo ./tests/self_test.sh
```

```text
== Build the lab
[PASS] lab_up.sh exits 0
[PASS] namespaces sw, rtr, hostA and hostB exist
== Healthy lab
[PASS] diag.sh passes on the healthy lab
== DHCP on both VLANs
[PASS] DHCP on VLAN 10 gives hostA 192.168.10.95 with router 192.168.10.1
[PASS] DHCP on VLAN 20 gives hostB 192.168.20.96 with router 192.168.20.1
...
[PASS] diag.sh exits 2 when the lab is not up
Summary: 17 passed, 0 failed, 0 skipped
```

It takes about 35 seconds, most of it waiting for the DHCP request that is meant to go unanswered. The GitHub Actions workflow in `.github/workflows/self-test.yml` runs the same script with sudo on an Ubuntu 24.04 runner on every push and pull request.

## Troubleshooting guide

[RUNBOOK_decision_tree.md](RUNBOOK_decision_tree.md) maps each symptom (no inter-VLAN reachability, large packets failing, one host with no L3 reachability) to the commands that isolate it and the fix, plus the outputs to attach when escalating.

## Files

| File | Purpose |
|------|---------|
| `lab_up.sh` | Builds the lab |
| `lab_down.sh` | Tears it down |
| `diag.sh` | Reachability, MTU and trunk checks |
| `repro_cases.sh` | Turns fault cases on and off |
| `RUNBOOK_decision_tree.md` | Symptom to fix decision tree |
| `tests/self_test.sh` | Builds the lab, injects and clears each fault, checks the diagnosis and DHCP, tears down |
| `.github/workflows/self-test.yml` | Runs the self test on GitHub Actions |

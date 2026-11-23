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
| `sw` | Linux bridge `br0` with VLAN filtering. `v_h1_sw` is an access port on VLAN 10, `v_h2_sw` an access port on VLAN 20, and `v_trunk_sw` a trunk carrying both VLANs tagged. |
| `rtr` | Router on a stick. VLAN subinterfaces `v_trunk_rtr.10` and `v_trunk_rtr.20` act as the gateways, IPv4 forwarding is on, and dnsmasq serves DHCP ranges .50 to .99 on each VLAN. |
| `hostA` | 192.168.10.2/24, default route via 192.168.10.1 |
| `hostB` | 192.168.20.2/24, default route via 192.168.20.1 |

The hosts use static addresses. The dnsmasq config, log and PID file live in `/tmp/switching_l3_lab`.

## Fault cases

`repro_cases.sh` injects and clears each fault:

| Case | `on` | `off` |
|------|------|-------|
| `native-mismatch` | VLAN 10 becomes the untagged native VLAN on the trunk, so the router no longer sees hostA's frames on its VLAN 10 subinterface | Trunk carries 10 and 20 tagged, with VLAN 1 as the untagged PVID |
| `mtu-low` | MTU 1300 on the VLAN 20 SVI | MTU 1500, and hostA's cached path MTU is flushed |
| `drop-route` | Removes hostB's default route | Restores `default via 192.168.20.1` |

## What `diag.sh` checks

1. hostA can ping its gateway 192.168.10.1
2. hostB can ping its gateway 192.168.20.1
3. hostA can ping hostB (inter-VLAN routing)
4. Path MTU from hostA to hostB, using don't-fragment pings from 1472 bytes down in 40-byte steps. It reports the largest size that gets through. This path crosses the VLAN 20 SVI, so `mtu-low on` brings the result down from 1472 to 1272 bytes.
5. Trunk tagging on `v_trunk_sw`: PASS when VLANs 10 and 20 are both present and tagged, FAIL when either is untagged (native VLAN mismatch) or missing, with the command that fixes it.

Each check prints a `[PASS]`, `[FAIL]` or `[INFO]` line, followed by hints for which fault case to turn off.

## Requirements

- Linux with root access
- iproute2 (`ip` and `bridge`), `sysctl` and `dnsmasq`

The scripts were last tested on Ubuntu 22.04. DHCP from dnsmasq was not exercised in that test.

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

`lab_up.sh` runs `lab_down.sh` first, so it can be rerun to reset the lab.

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

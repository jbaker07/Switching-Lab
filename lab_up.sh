#!/usr/bin/env bash
set -euo pipefail

require() { command -v "$1" >/dev/null || { echo "Missing $1"; exit 1; }; }
for x in ip bridge sysctl dnsmasq; do require "$x"; done

# Vars
SW=sw ; RTR=rtr ; H1=hostA ; H2=hostB
BR=br0
V10=10 ; V20=20
H1_IP=192.168.10.2/24 ; H2_IP=192.168.20.2/24
R10_IP=192.168.10.1/24 ; R20_IP=192.168.20.1/24
H1_GW=192.168.10.1 ; H2_GW=192.168.20.1
STATE=/tmp/switching_l3_lab

# Clean if exists (lab_down.sh deletes $STATE, so create it after this)
bash "$(dirname "$0")/lab_down.sh" || true
mkdir -p "$STATE"

# Namespaces
for ns in "$SW" "$RTR" "$H1" "$H2"; do ip netns add "$ns"; done

# Linux bridge acts like a switch (with vlan filtering)
ip -n "$SW" link add name "$BR" type bridge vlan_filtering 1
ip -n "$SW" link set "$BR" up

# veth: hostA <-> sw
ip link add v_h1 type veth peer name v_h1_sw
ip link set v_h1 netns "$H1"
ip link set v_h1_sw netns "$SW"

# veth: hostB <-> sw
ip link add v_h2 type veth peer name v_h2_sw
ip link set v_h2 netns "$H2"
ip link set v_h2_sw netns "$SW"

# veth: rtr trunk <-> sw trunk
ip link add v_trunk_rtr type veth peer name v_trunk_sw
ip link set v_trunk_rtr netns "$RTR"
ip link set v_trunk_sw netns "$SW"

# Attach switch ports to bridge
ip -n "$SW" link set v_h1_sw master "$BR"
ip -n "$SW" link set v_h2_sw master "$BR"
ip -n "$SW" link set v_trunk_sw master "$BR"

# Bring switch ports up
for i in v_h1_sw v_h2_sw v_trunk_sw ; do ip -n "$SW" link set "$i" up; done

# VLANs on the switch
# - hostA port untagged VLAN 10 (PVID 10)
bridge -n "$SW" vlan add dev v_h1_sw vid $V10 pvid untagged
# - hostB port untagged VLAN 20 (PVID 20)
bridge -n "$SW" vlan add dev v_h2_sw vid $V20 pvid untagged
# - the bridge puts every new port in VLAN 1 untagged. Take the access ports out of it,
#   or anything sent untagged in VLAN 1 (such as the router's native VLAN) reaches both hosts.
bridge -n "$SW" vlan del dev v_h1_sw vid 1
bridge -n "$SW" vlan del dev v_h2_sw vid 1
# - trunk carries 10 and 20 tagged
bridge -n "$SW" vlan add dev v_trunk_sw vid $V10
bridge -n "$SW" vlan add dev v_trunk_sw vid $V20

# Host interfaces
ip -n "$H1" link set lo up
ip -n "$H1" link set v_h1 up
ip -n "$H2" link set lo up
ip -n "$H2" link set v_h2 up

# Router trunk subinterfaces
ip -n "$RTR" link set lo up
ip -n "$RTR" link set v_trunk_rtr up
ip -n "$RTR" link add link v_trunk_rtr name v_trunk_rtr.$V10 type vlan id $V10
ip -n "$RTR" link add link v_trunk_rtr name v_trunk_rtr.$V20 type vlan id $V20
ip -n "$RTR" addr add "$R10_IP" dev v_trunk_rtr.$V10
ip -n "$RTR" addr add "$R20_IP" dev v_trunk_rtr.$V20
ip -n "$RTR" link set v_trunk_rtr.$V10 up
ip -n "$RTR" link set v_trunk_rtr.$V20 up

# IPs + default routes on hosts
ip -n "$H1" addr add "$H1_IP" dev v_h1
ip -n "$H1" route add default via "$H1_GW"
ip -n "$H2" addr add "$H2_IP" dev v_h2
ip -n "$H2" route add default via "$H2_GW"

# Enable IP forwarding on router
ip netns exec "$RTR" sysctl -w net.ipv4.ip_forward=1 >/dev/null
# Make the router bind addresses to interfaces like a real router does.
# By default Linux answers ARP for any local address on any interface and accepts
# packets for a local address on any interface. Then an untagged frame that lands on
# the parent v_trunk_rtr still reaches 192.168.10.1, and a native VLAN mismatch looks
# healthy to ping. arp_ignore=1 answers ARP only on the interface that owns the address,
# and rp_filter=1 drops packets that arrive on an interface the reply would not use.
ip netns exec "$RTR" sysctl -w net.ipv4.conf.all.arp_ignore=1 >/dev/null
ip netns exec "$RTR" sysctl -w net.ipv4.conf.all.rp_filter=1 >/dev/null

# DHCP per VLAN using dnsmasq in router ns
# Each range sets a tag and each router option is limited to its tag. An untagged
# dhcp-option is global in dnsmasq, so two of them would leave the last one (the
# VLAN 20 gateway) as the router for every client on both VLANs.
DNSMASQ_PID="$STATE/dnsmasq.pid"
cat >"$STATE/dnsmasq.conf" <<CONF
port=0
interface=v_trunk_rtr.$V10
dhcp-range=set:vlan$V10,192.168.10.50,192.168.10.99,255.255.255.0,12h
dhcp-option=tag:vlan$V10,option:router,192.168.10.1
interface=v_trunk_rtr.$V20
dhcp-range=set:vlan$V20,192.168.20.50,192.168.20.99,255.255.255.0,12h
dhcp-option=tag:vlan$V20,option:router,192.168.20.1
log-dhcp
log-facility=$STATE/dnsmasq.log
pid-file=$DNSMASQ_PID
CONF

ip netns exec "$RTR" dnsmasq --conf-file="$STATE/dnsmasq.conf"

echo "Lab up. Namespaces: $SW $RTR $H1 $H2"

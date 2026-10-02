#!/usr/bin/env bash
# End-to-end tests against the vip-test VMs (homelab-az-ocp artifacts/design2/vip-test) on one cluster.
# Env: KUBECONFIG, OC, SSHKEY (private key for the VMs' fedora user). Network: vip-net (192.168.252.0/24, VIP .10).
set -u; OC=${OC:-oc}; NS=vip-test; NET=vip-net; VIP=192.168.252.10; PFX=192.168.252; A=portsec.lab/allowed-addresses
S="virtctl ssh -n $NS -i $SSHKEY --local-ssh-opts=-oStrictHostKeyChecking=no --local-ssh-opts=-oUserKnownHostsFile=/dev/null --local-ssh-opts=-oLogLevel=ERROR"
ip_of(){ $OC get vmi $1 -n $NS -o jsonpath='{.status.interfaces[?(@.name=="vipnic")].ipAddress}'; }
node_of(){ $OC get vmi $1 -n $NS -o jsonpath='{.status.nodeName}'; }
nb_pod(){ $OC get pods -n openshift-ovn-kubernetes -l app=ovnkube-node --field-selector spec.nodeName=$1 -o name; }
ps_of(){ local vm=$1 n; n=$(node_of $vm); $OC -n openshift-ovn-kubernetes exec $(nb_pod $n) -c nbdb -- ovn-nbctl --no-leader-only --bare --columns=port_security find logical_switch_port "external_ids:\"k8s.ovn.org/nad\"=\"$NS/$NET\"" 2>/dev/null | grep -i "$($OC get vmi $vm -n $NS -o jsonpath='{.status.interfaces[?(@.name=="vipnic")].mac}')" | head -1; }
wait_ps(){ local vm=$1 want=$2 t0=$(date +%s.%N); while :; do ps=$(ps_of $vm); [ "$ps" = "$want" ] && { printf '%.1fs' "$(echo "$(date +%s.%N) - $t0" | bc 2>/dev/null || python3 -c "import time;print(time.time()-$t0)")"; return 0; }; [ $(python3 -c "import time;print(int(time.time()-$t0))") -gt ${3:-90} ] && { echo "TIMEOUT (have '$ps')"; return 1; }; sleep 0.5; done; }
curlvip(){ $S fedora@vm/vip-client -c "sudo ip neigh flush dev vip0; for i in 1 2 3; do curl -s -m 2 http://$VIP/ || echo FAIL; done | sort | uniq -c | tr '\n' ' '"; }

MA=$($OC get vmi haproxy-a -n $NS -o jsonpath='{.status.interfaces[?(@.name=="vipnic")].mac}'); MB=$($OC get vmi haproxy-b -n $NS -o jsonpath='{.status.interfaces[?(@.name=="vipnic")].mac}'); MC=$($OC get vmi vip-client -n $NS -o jsonpath='{.status.interfaces[?(@.name=="vipnic")].mac}')
want(){ [[ " ${TESTS:-T1 T2 T3 T4 T5 T6 T7 T8} " == *" $1 "* ]]; }
IA=$(ip_of haproxy-a); IB=$(ip_of haproxy-b); IC=$(ip_of vip-client)
echo "VMs: haproxy-a $IA on $(node_of haproxy-a) | haproxy-b $IB on $(node_of haproxy-b) | vip-client $IC on $(node_of vip-client)"
for vm in haproxy-a haproxy-b vip-client; do echo "  before $vm: $(ps_of $vm)"; done

if want T1; then
echo "== T1 annotate (a: declared, b: guest-agent, client: declared)"
$OC annotate vm -n $NS haproxy-a --overwrite "$A={\"$NET\":{\"ips\":[\"$VIP\"],\"ownIP\":\"$IA\"}}" >/dev/null
$OC annotate vm -n $NS haproxy-b --overwrite "$A={\"$NET\":{\"ips\":[\"$VIP\"],\"ownIPSource\":\"guest-agent\"}}" >/dev/null
$OC annotate vm -n $NS vip-client --overwrite "$A={\"$NET\":{\"ips\":[],\"ownIP\":\"$IC\"}}" >/dev/null
echo "  haproxy-a applied in $(wait_ps haproxy-a "$MA $IA $VIP"): $(ps_of haproxy-a)"
echo "  haproxy-b applied in $(wait_ps haproxy-b "$MB $IB $VIP"): $(ps_of haproxy-b)"
echo "  vip-client applied in $(wait_ps vip-client "$MC $IC"): $(ps_of vip-client)"

fi
if want T2; then
echo "== T2 VIP + failover + failback"; echo "  baseline: $(curlvip)"
$S fedora@vm/haproxy-a -c 'sudo systemctl stop haproxy'; sleep 8; echo "  haproxy-a stopped: $(curlvip)"
$S fedora@vm/haproxy-a -c 'sudo systemctl start haproxy'; sleep 8; echo "  failback: $(curlvip)"

fi
if want T3; then
echo "== T3 client spoofing"; $S fedora@vm/vip-client -c "sudo ip addr add $VIP/32 dev vip0; sudo ip addr add $PFX.200/32 dev vip0; for s in $IC $VIP $PFX.200; do printf '     ping kea from %-16s %s\n' \$s \"\$(ping -c3 -W1 -I \$s $PFX.2 2>/dev/null | grep -o '[0-9]* received')\"; done; sudo ip addr del $VIP/32 dev vip0; sudo ip addr del $PFX.200/32 dev vip0"

fi
if want T4; then
echo "== T4 ovnkube-controller restart on haproxy-a's node ($(node_of haproxy-a))"
N=$(node_of haproxy-a); P=$(nb_pod $N); r0=$($OC get $P -n openshift-ovn-kubernetes -o jsonpath='{.status.containerStatuses[?(@.name=="ovnkube-controller")].restartCount}')
# ovnkube-node runs with hostPID: `kill 1` inside it signals the node's systemd. Stop just this container instead.
timeout 120 $OC debug node/$N -q -- chroot /host sh -c 'crictl stop $(crictl ps --name "^ovnkube-controller$" -q)' >/dev/null 2>&1
t1=$(date +%s); until [ "$($OC get $P -n openshift-ovn-kubernetes -o jsonpath='{.status.containerStatuses[?(@.name=="ovnkube-controller")].restartCount}')" != "$r0" ] || [ $(($(date +%s)-t1)) -gt 180 ]; do sleep 1; done
echo "  ovnkube-controller restartCount $r0 -> $($OC get $P -n openshift-ovn-kubernetes -o jsonpath='{.status.containerStatuses[?(@.name=="ovnkube-controller")].restartCount}')"
t0=$(date +%s); seen_reset=no; until [ $(($(date +%s)-t0)) -gt 240 ]; do ps=$(ps_of haproxy-a); [ "$ps" = "$MA" ] && seen_reset=yes; [ "$seen_reset" = yes ] && [ "$ps" = "$MA $IA $VIP" ] && break; sleep 0.5; done
echo "  reset to MAC-only observed: $seen_reset; allow-list back: $(ps_of haproxy-a) (within $(($(date +%s)-t0))s of controller restart)"
$OC logs -n portsec-allowlist $($OC get pods -n portsec-allowlist --field-selector spec.nodeName=$(node_of haproxy-a) -o name) --since=5m | grep -E 'set port_security' | grep haproxy-a | tail -2 | cut -c1-150

fi
if want T5; then
echo "== T5 VM restart (haproxy-b): new pod, new port"
virtctl restart haproxy-b -n $NS >/dev/null 2>&1; sleep 5; t1=$(date +%s); until { [ "$($OC get vmi haproxy-b -n $NS -o jsonpath='{.status.phase}' 2>/dev/null)" = Running ] && [ -n "$(ip_of haproxy-b)" ]; } || [ $(($(date +%s)-t1)) -gt 600 ]; do sleep 3; done
IB2=$(ip_of haproxy-b); echo "  haproxy-b back on $(node_of haproxy-b), guest IP $IB2; allow-list applied in $(wait_ps haproxy-b "$MB $IB2 $VIP" 240): $(ps_of haproxy-b)"

fi
if want T6; then
echo "== T6 live migration (haproxy-a)"; src=$(node_of haproxy-a)
virtctl migrate haproxy-a -n $NS >/dev/null 2>&1; t1=$(date +%s); until [ "$($OC get vmim -n $NS -o jsonpath='{.items[-1:].status.phase}' 2>/dev/null)" = Succeeded ] || [ "$($OC get vmim -n $NS -o jsonpath='{.items[-1:].status.phase}' 2>/dev/null)" = Failed ] || [ $(($(date +%s)-t1)) -gt 600 ]; do sleep 3; done
echo "  migration $($OC get vmim -n $NS -o jsonpath='{.items[-1:].status.phase}'): $src -> $(node_of haproxy-a); allow-list on target: $(wait_ps haproxy-a "$MA $IA $VIP" 120) $(ps_of haproxy-a); VIP: $(curlvip)"

fi
if want T7; then
echo "== T7 remove client annotation -> release"; $OC annotate vm -n $NS vip-client $A- >/dev/null
echo "  released in $(wait_ps vip-client "$MC"): $(ps_of vip-client)"

fi
if want T8; then
echo "== T8 guest-agent trust gap: haproxy-b adds $PFX.201 inside the guest"
$S fedora@vm/haproxy-b -c "sudo ip addr add $PFX.201/24 dev vip0"; t0=$(date +%s); until ps_of haproxy-b | grep -q "$PFX.201" || [ $(($(date +%s)-t0)) -gt 120 ]; do sleep 2; done
echo "  haproxy-b port_security now: $(ps_of haproxy-b)  (after $(($(date +%s)-t0))s)"; $S fedora@vm/haproxy-b -c "sudo ip addr del $PFX.201/24 dev vip0"

fi
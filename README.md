# ovnk-portsec-allowlist

Per-port **allowed address pairs** for OpenShift Virtualization VMs on OVN-Kubernetes secondary
networks: let named VMs use extra IPs (for example a keepalived VIP) while every other VM stays locked to its
own address.

OVN already enforces this. OpenStack's Neutron ML2/OVN driver implements allowed address pairs by
writing extra IPs into a port's `Logical_Switch_Port.port_security`. OVN-Kubernetes has no API for it
and resets the column whenever it rebuilds a port. This repo is a small per-node reconciler that keeps
the column in the state the VM asks for.

> **Unsupported workaround.** It writes into a database OVN-Kubernetes owns. Use it in the lab, remove
> it before opening a Red Hat networking case, and track the upstream fix: OKEP-3926 (MAC security per
> network) and a request for a per-attachment allowed-addresses field.

## How it works

```
VM annotation ──► reconciler (DaemonSet, one per node) ──► node's OVN northbound DB
                     ▲   watches: oc get vm,vmi -w             /var/run/ovn-ic/ovnnb_db.sock
                     │            ovsdb-client monitor Logical_Switch_Port
                     └── periodic resync (30 s)
```

For each annotated VM whose `virt-launcher` pod runs on this node, the reconciler:

1. Finds the VM's interface for the named Multus network (`spec.networks[].multus.networkName`) and its MAC.
2. Finds the OVN port **by pod name**: the name ends in `_<namespace>_<virt-launcher pod>`. It
   **confirms the port by MAC**, because the pod-network port shares the name suffix.
3. Writes **one** `port_security` entry: `"<MAC> <own IP(s)> <allowed IP(s)>"`. It never touches
   `addresses`, so OVN's ARP responder never answers for a VIP. This is the same split Neutron uses.
4. Tags the port `external_ids:portsec.lab/managed=true`. If the VM drops its annotation, the port is put
   back to MAC-only, the value OVN-Kubernetes writes on IPAM-disabled networks.

Every node runs its own northbound database (OpenShift 4.20+ interconnect), so each reconciler only
sees, and only writes, the ports of pods on its own node. VM restarts and live migrations create a new
pod and port, and the reconciler on the new node picks them up.

## The annotation

On the **VirtualMachine** (read live, so no VM restart is needed):

```yaml
metadata:
  annotations:
    portsec.lab/allowed-addresses: |
      {"vip-net": {"ips": ["192.168.252.10"], "ownIP": "192.168.252.101"}}
```

| Field | Meaning |
| --- | --- |
| key (`vip-net`) | Multus `networkName` of the VM interface to protect |
| `ips` | extra IPs this VM may send and receive as (VIPs); may be empty |
| `ownIP` | the VM's own IP on that network, string or list (**preferred**) |
| `ownIPSource: "guest-agent"` | instead of `ownIP`: take the VM's own IPv4 addresses from the guest agent (`vmi.status.interfaces[].ipAddresses`), minus the declared `ips` |

Use `ownIP` wherever you can. With `guest-agent`, whatever the guest reports is allowed, so a
compromised guest can widen its own allow-list (test T8 shows it). Use it only where addresses come from
DHCP and are not known up front, and pair it with MultiNetworkPolicy `ipBlock` limits.

## Install

```bash
export KUBECONFIG=<cluster kubeconfig>
deploy/install.sh        # uses the cluster's own ovnkube-node image (ovn-nbctl, ovsdb-client, oc, python3)
oc -n portsec-allowlist logs ds/portsec-allowlist -f
```

Uninstall: `RELEASE=true deploy/uninstall.sh` puts every managed port back to MAC-only first.

Requirements: OpenShift 4.20+ with OVN-Kubernetes interconnect (per-node NB at `/var/run/ovn-ic`),
OpenShift Virtualization, and a secondary localnet or layer2 network. With IPAM disabled, OVN-Kubernetes
writes MAC-only `port_security`; with IPAM it already locks the port to its assigned IP.
The pod runs privileged as root, because the NB socket is `root:root 0750`.

## Tests

`test/run-tests.sh` runs against the `vip-test` VMs from `homelab-az-ocp`: two HAProxy VMs sharing VIP
192.168.252.10 through keepalived, and a client, on localnet `vip-net`, VLAN 520, IPAM disabled.
See [Results](#results).

## Results

2026-10-02, cluster `az1`: OpenShift 4.22.15, OVN-Kubernetes 1.3.0, OVN 26.03.3, OpenShift Virtualization 4.22.9,
three nodes, VMs spread across them.

| VM | Annotation |
| --- | --- |
| `haproxy-a` | `{"vip-net": {"ips": ["192.168.252.10"], "ownIP": "192.168.252.101"}}` (declared) |
| `haproxy-b` | `{"vip-net": {"ips": ["192.168.252.10"], "ownIPSource": "guest-agent"}}` |
| `vip-client` | `{"vip-net": {"ips": [], "ownIP": "192.168.252.102"}}` (declared) |

| Test | Result |
| --- | --- |
| T1 annotate the three VMs | `port_security` became `MAC own-IP VIP` (client: `MAC own-IP`): 0.8-0.9 s, first VM 17.5 s |
| T2 VIP, failover, failback | served by haproxy-a; HAProxy stopped → haproxy-b; restarted → haproxy-a |
| T3 client spoofing | own IP 3/3 replies; VIP `.10` 0/3; unlisted `.200` 0/3 (blocked) |
| T4 `ovnkube-controller` restart | port reset to MAC-only (observed), allow-list back within **3 s** |
| T5 VM restart (new pod and port), guest-agent mode | re-applied **21 s** after the VM was Running (waits for the guest agent to report its IP) |
| T6 live migration, master0 → master2 | target node's reconciler applied it **0.8 s** after migration; VIP kept serving |
| T7 annotation removed | port released to MAC-only in **7 s** |
| T8 guest adds `.201` in guest-agent mode | `.201` **allowed** after 24 s: the trust gap of `ownIPSource: guest-agent` |

Notes from testing:

- `ovnkube-node` pods run with `hostPID`, so `kill 1` inside the `ovnkube-controller` container signals
  the **node's systemd** (SIGTERM makes it re-exec), not the container. To restart that container, use
  `crictl stop` from `oc debug node/...`, as `test/run-tests.sh` does.
- Guest-agent mode is only as fast as the guest agent's reporting interval (about 20 s here) and only as
  trustworthy as the guest. Prefer `ownIP`.

## Not done yet

- VRRP virtual MACs: OVN 26.03 (OpenShift 4.22) supports the `VRRPv3` port-security keyword, which could
  allow `use_vmac` for the VIP holders only.
- A Go controller (informers + libovsdb) in place of the Python loop; distribution to many clusters by
  ACM policy.

#!/usr/bin/env python3
"""Per-node reconciler: per-port allowed address pairs for OpenShift Virtualization VMs on
OVN-Kubernetes secondary (localnet / layer2) networks.

Desired state comes from an annotation on the VirtualMachine:

  portsec.lab/allowed-addresses: |
    {"<multus networkName>": {"ips": ["<VIP>", ...],
                              "ownIP": "<ip>"            # declared own IP (preferred), or
                              "ownIPSource": "guest-agent"}}  # take own IPs from the guest agent

For each annotated VM running on this node the reconciler finds the VM's OVN logical switch port
(by virt-launcher pod name, confirmed by MAC) in this node's northbound DB and writes ONE
port_security entry:  "<MAC> <own IP(s)> <allowed IP(s)>".  It never touches `addresses`.

Ports it manages are tagged external_ids:portsec.lab/managed=true. When a VM drops its annotation
the port is put back to the MAC-only value OVN-Kubernetes writes on IPAM-disabled networks.

Triggers: an `ovsdb-client monitor` on Logical_Switch_Port (OVN-Kubernetes rewrote a port),
an `oc get vm,vmi -w` watch (VM/VMI changed), and a periodic resync as a safety net.
"""
import ipaddress, json, os, subprocess, sys, threading, time

ANNOTATION = os.environ.get("ANNOTATION", "portsec.lab/allowed-addresses")
MANAGED_KEY = "portsec.lab/managed"
NODE = os.environ["NODE_NAME"]
NB = os.environ.get("NB_DB", "unix:/run/ovn/ovnnb_db.sock")
RESYNC = int(os.environ.get("RESYNC_SECONDS", "30"))
DRY_RUN = os.environ.get("DRY_RUN", "false") == "true"

wake = threading.Event()


def log(msg, **kv):
    print(json.dumps({"ts": time.strftime("%Y-%m-%dT%H:%M:%S"), "node": NODE, "msg": msg, **kv}), flush=True)


def sh(*args, check=True):
    r = subprocess.run(args, capture_output=True, text=True)
    if check and r.returncode != 0:
        raise RuntimeError(f"{' '.join(args[:4])}...: {r.stderr.strip()[:300]}")
    return r.stdout


def oc_json(*args):
    return json.loads(sh("oc", *args, "-o", "json"))


def nbctl(*args):
    return sh("ovn-nbctl", f"--db={NB}", "--no-leader-only", *args)


def nb_ports():
    """All pod ports in this node's NB: name -> {addresses, port_security, external_ids}."""
    out = json.loads(nbctl("--format=json", "--columns=name,addresses,port_security,external_ids",
                           "find", "logical_switch_port", 'external_ids:pod="true"'))
    def val(v):  # OVSDB JSON: ["set", [...]] / ["map", [[k, v]...]] / scalar
        if isinstance(v, list) and v and v[0] == "set": return v[1]
        if isinstance(v, list) and v and v[0] == "map": return dict(v[1])
        return [v] if isinstance(v, str) and v else v
    cols = out["headings"]
    return {r[0]: dict(zip(cols[1:], (val(c) for c in r[1:]))) for r in out["data"]}


def v4(ips):
    keep = []
    for ip in ips:
        try:
            a = ipaddress.ip_address(ip)
        except ValueError:
            continue
        if a.version == 4 and not a.is_link_local:
            keep.append(str(a))
    return keep


def desired_entries():
    """(port-name-suffix, mac, entry, vm) for every annotated VM whose launcher pod runs here."""
    vms = {(v["metadata"]["namespace"], v["metadata"]["name"]): v for v in oc_json("get", "vm", "-A")["items"]
           if ANNOTATION in v["metadata"].get("annotations", {})}
    if not vms:
        return []
    vmis = {(i["metadata"]["namespace"], i["metadata"]["name"]): i for i in oc_json("get", "vmi", "-A")["items"]}
    pods = oc_json("get", "pods", "-A", "-l", "kubevirt.io=virt-launcher", "--field-selector",
                   f"spec.nodeName={NODE},status.phase=Running")["items"]
    out = []
    for (ns, name), vm in vms.items():
        vmi = vmis.get((ns, name))
        if not vmi:
            continue
        try:
            want = json.loads(vm["metadata"]["annotations"][ANNOTATION])
        except json.JSONDecodeError as e:
            log("bad annotation", vm=f"{ns}/{name}", error=str(e)); continue
        launchers = [p for p in pods if p["metadata"]["namespace"] == ns
                     and p["metadata"]["labels"].get("kubevirt.io/created-by") == vmi["metadata"]["uid"]]
        if not launchers:
            continue  # VM is not running on this node
        nets = {n["name"]: n.get("multus", {}).get("networkName") for n in vmi["spec"].get("networks", [])}
        status = {i.get("name"): i for i in vmi.get("status", {}).get("interfaces", [])}
        spec_if = {i["name"]: i for i in vmi["spec"]["domain"]["devices"].get("interfaces", [])}
        for netname, cfg in want.items():
            iface = next((k for k, v in nets.items() if v and v.split("/")[-1] == netname.split("/")[-1]), None)
            if not iface:
                log("network not on VM", vm=f"{ns}/{name}", network=netname); continue
            mac = (spec_if.get(iface, {}).get("macAddress") or status.get(iface, {}).get("mac") or "").lower()
            if not mac:
                log("no MAC yet", vm=f"{ns}/{name}", iface=iface); continue
            extra = v4(cfg.get("ips", []))
            if cfg.get("ownIPSource") == "guest-agent":
                own = [ip for ip in v4(status.get(iface, {}).get("ipAddresses", [])) if ip not in extra]
                src = "guest-agent"
            else:
                own = v4([cfg["ownIP"]] if isinstance(cfg.get("ownIP"), str) else cfg.get("ownIP", []))
                src = "declared"
            if not own:
                log("no own IP; leaving port as is", vm=f"{ns}/{name}", source=src); continue
            entry = " ".join([mac] + own + [ip for ip in extra if ip not in own])
            for p in launchers:
                out.append((f"_{ns}_{p['metadata']['name']}", mac, entry, f"{ns}/{name}", src))
    return out


def reconcile():
    ports = nb_ports()
    seen = set()
    for suffix, mac, entry, vm, src in desired_entries():
        matches = [n for n, p in ports.items()
                   if n.endswith(suffix) and any(a.split()[0].lower() == mac for a in p["addresses"])]
        if not matches:
            continue  # port lives in another node's NB, or OVN-K has not created it yet
        for name in matches:
            seen.add(name)
            cur = ports[name]["port_security"]
            if cur == [entry] and ports[name]["external_ids"].get(MANAGED_KEY) == "true":
                continue
            log("set port_security", port=name, vm=vm, ownIP_source=src, was=cur, now=entry, dry_run=DRY_RUN)
            if not DRY_RUN:
                nbctl("lsp-set-port-security", name, entry, "--", "set", "logical_switch_port", name,
                      f'external_ids:"{MANAGED_KEY}"="true"')
    for name, p in ports.items():  # VM lost its annotation or stopped: hand the port back
        if p["external_ids"].get(MANAGED_KEY) == "true" and name not in seen:
            macs = [a.split()[0] for a in p["addresses"] if a and a != "unknown"]
            log("release port", port=name, was=p["port_security"], now=macs, dry_run=DRY_RUN)
            if not DRY_RUN:
                nbctl("lsp-set-port-security", name, *macs, "--", "remove", "logical_switch_port", name,
                      "external_ids", MANAGED_KEY)


def watch(cmd, label):
    while True:
        try:
            p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
            for _ in p.stdout:
                wake.set()
            p.wait()
        except Exception as e:  # noqa: BLE001
            log("watch error", watch=label, error=str(e))
        time.sleep(2)


def main():
    log("starting", annotation=ANNOTATION, nb=NB, resync=RESYNC, dry_run=DRY_RUN)
    threading.Thread(target=watch, daemon=True, args=(
        ["ovsdb-client", "monitor", NB, "OVN_Northbound", "Logical_Switch_Port", "name", "port_security",
         "addresses"], "ovn-nb")).start()
    threading.Thread(target=watch, daemon=True, args=(["oc", "get", "vm,vmi", "-A", "-w", "--no-headers"], "k8s")).start()
    while True:
        try:
            reconcile()
        except Exception as e:  # noqa: BLE001
            log("reconcile failed", error=str(e))
        wake.wait(RESYNC)
        wake.clear()
        time.sleep(0.5)  # debounce bursts of events


if __name__ == "__main__":
    sys.exit(main())

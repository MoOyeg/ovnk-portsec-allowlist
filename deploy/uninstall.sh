#!/usr/bin/env bash
# Remove the reconciler. Managed ports keep their allow-list until OVN-Kubernetes next rebuilds them;
# run with RELEASE=true first to put every managed port back to MAC-only.
set -euo pipefail; OC=${OC:-oc}
if [ "${RELEASE:-false}" = true ]; then
  for p in $($OC get pods -n openshift-ovn-kubernetes -l app=ovnkube-node -o name); do
    $OC -n openshift-ovn-kubernetes exec "$p" -c nbdb -- sh -c 'for n in $(ovn-nbctl --no-leader-only --bare --columns=name find logical_switch_port external_ids:"portsec.lab/managed"=true); do m=$(ovn-nbctl --no-leader-only --bare --columns=addresses list logical_switch_port $n | cut -d" " -f1); ovn-nbctl --no-leader-only lsp-set-port-security $n $m -- remove logical_switch_port $n external_ids portsec.lab/managed; echo "released $n"; done'
  done
fi
$OC delete ns portsec-allowlist --ignore-not-found
$OC delete clusterrole,clusterrolebinding portsec-allowlist --ignore-not-found

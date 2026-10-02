#!/usr/bin/env bash
# Install or update the reconciler on the cluster in $KUBECONFIG. Uses the cluster's own ovnkube image.
set -euo pipefail
cd "$(dirname "$0")"; OC=${OC:-oc}
IMG=$($OC -n openshift-ovn-kubernetes get ds ovnkube-node -o jsonpath='{.spec.template.spec.containers[?(@.name=="nbdb")].image}')
[ -n "$IMG" ] || { echo "cannot read ovnkube-node image" >&2; exit 1; }
$OC apply -f rbac.yaml
$OC -n portsec-allowlist create configmap portsec-allowlist-code --from-file=../reconciler/reconcile.py --dry-run=client -o yaml | $OC apply -f -
sed "s#OVNKUBE_IMAGE#$IMG#" daemonset.yaml | $OC apply -f -
$OC -n portsec-allowlist rollout restart ds/portsec-allowlist >/dev/null
$OC -n portsec-allowlist rollout status ds/portsec-allowlist --timeout=180s

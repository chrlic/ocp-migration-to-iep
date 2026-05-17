#!/bin/bash
# Post-migration Cilium / IEP health check.
# Run after the OVN→Cilium migration is complete.

set -uo pipefail

export KUBECONFIG="${INSTALL_DIR:-/root/ocp-upi-migrate}/auth/kubeconfig"
export PATH=/usr/local/bin:$PATH

source /root/tools-upi-migrate/lab-config.sh

echo "=== Nodes ==="
oc get nodes -o wide

echo ""
echo "=== Cilium pods ==="
oc get pods -n cilium -o wide

echo ""
echo "=== Cilium DS image ==="
oc get ds cilium -n cilium -o jsonpath='{.spec.template.spec.containers[0].image}'
echo ""

echo ""
echo "=== CLife controller logs (last 30) ==="
oc logs -n cilium deploy/clife-controller-manager --tail=30 2>/dev/null || \
  echo "  (clife-controller-manager not found)"

echo ""
echo "=== Cilium status (via CLI on first running pod) ==="
CILIUM_POD=$(oc get pods -n cilium -l app.kubernetes.io/name=cilium-agent \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [ -n "${CILIUM_POD}" ]; then
  oc exec -n cilium "${CILIUM_POD}" -- cilium status --brief 2>/dev/null || \
    echo "  (cilium status unavailable)"
else
  echo "  No running cilium-agent pod found."
fi

echo ""
echo "=== ClusterVersion ==="
oc get clusterversion

echo ""
echo "=== Cluster operators ==="
oc get co | grep -v " True   False  False" || true

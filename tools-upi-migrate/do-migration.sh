#!/bin/bash
# Execute the OCP -> Isovalent Networking for Kubernetes (Cilium) migration.
# Mirrors Section 7 of OCP_IEP_Migration_Guide.md step-for-step.
#
# Prerequisites:
#   - Section 5 pre-flight gate already passed (cluster healthy, kernel non-RT, etc.)
#   - Section 6 already done: clife tarball extracted to ${CLIFE_DIR} and the
#     three manifests customized (ciliumconfig.yaml, controller-manager
#     Deployment, subscription.yaml). See gen-cilium-manifests.sh / Section 6
#     of the guide.
#
# This script is interactive — it pauses between phases when the impact is
# high (Phase 6 reboots) so the operator can confirm. Pass -y to skip prompts.
#
# Idempotent within reason: patches use --type=merge and oc apply / scale to
# zero are safe to re-run. The CVO override block is overwritten cleanly each
# time. Manual checks at each phase are still recommended.

set -euo pipefail

AUTO_CONFIRM="${1:-}"

source /etc/profile.d/proxy.sh
source /root/tools-upi-migrate/lab-config.sh
export KUBECONFIG="${INSTALL_DIR}/auth/kubeconfig"

confirm() {
  [ "${AUTO_CONFIRM}" = "-y" ] && return 0
  read -p "  Proceed? [y/N] " ans
  [ "${ans}" = "y" ] || [ "${ans}" = "Y" ]
}

header() {
  echo ""
  echo "=================================================================="
  echo " $1"
  echo "=================================================================="
}

# --------------------------------------------------------------------------
# Phase 1 — Disable the Cluster Network Operator
# --------------------------------------------------------------------------
header "Phase 1 — Disable CNO"

cat > /tmp/cno-disable.yaml <<'EOF'
- op: add
  path: /spec/overrides
  value:
  - kind: Deployment
    group: apps
    name: network-operator
    namespace: openshift-network-operator
    unmanaged: true
EOF

echo "1.1 CVO override (network-operator unmanaged)..."
oc patch clusterversion version --type json --patch-file /tmp/cno-disable.yaml

echo "1.2 Scale network-operator to 0..."
oc scale deployment -n openshift-network-operator network-operator --replicas=0
# iptables-alerter-* DaemonSet pods stay running — that is the expected leftover.
# Only the network-operator Deployment pod must be gone.
for i in $(seq 1 30); do
  REMAIN=$(oc get pods -n openshift-network-operator -l name=network-operator --no-headers 2>/dev/null | wc -l)
  [ "${REMAIN}" = "0" ] && break
  echo "  (${i}/30) waiting for network-operator pod to terminate..."
  sleep 3
done

echo "1.3 Delete applied-cluster ConfigMap..."
oc delete configmap applied-cluster -n openshift-network-operator --ignore-not-found

# --------------------------------------------------------------------------
# Phase 2 — Pause MCPs
# --------------------------------------------------------------------------
header "Phase 2 — Pause MCPs"
oc patch --type=merge --patch='{"spec":{"paused":true}}' mcp/master
oc patch --type=merge --patch='{"spec":{"paused":true}}' mcp/worker
oc get mcp -o custom-columns='NAME:.metadata.name,PAUSED:.spec.paused'

# --------------------------------------------------------------------------
# Phase 3 — Switch network plugin to Cilium
# --------------------------------------------------------------------------
header "Phase 3 — Switch network plugin to Cilium"

echo "3.1 Patch network.config..."
oc patch network.config cluster --type=merge --patch="{
  \"spec\":{
    \"clusterNetwork\":[{\"cidr\":\"${CILIUM_CLUSTER_CIDR}\",\"hostPrefix\":${CILIUM_HOST_PREFIX}}],
    \"networkType\":\"Cilium\"
  },
  \"status\":null
}"

echo "3.2 Patch network.operator..."
oc patch network.operator cluster --type=merge --patch="{
  \"spec\":{
    \"clusterNetwork\":[{\"cidr\":\"${CILIUM_CLUSTER_CIDR}\",\"hostPrefix\":${CILIUM_HOST_PREFIX}}],
    \"defaultNetwork\":{\"type\":\"Cilium\"},
    \"deployKubeProxy\":false
  },
  \"status\":null
}"

# --------------------------------------------------------------------------
# Phase 4 — Deploy CLife + Cilium
# --------------------------------------------------------------------------
header "Phase 4 — Deploy CLife + Cilium"

if [ ! -d "${CLIFE_DIR}" ] || [ -z "$(ls -A "${CLIFE_DIR}" 2>/dev/null)" ]; then
  echo "ERROR: ${CLIFE_DIR} is empty. Run Section 6 (gen-cilium-manifests.sh or manual)."
  exit 1
fi

echo "4.1 Apply CLife manifests (with retry until CRD + ns propagate)..."
ATTEMPT=0
until oc apply -f "${CLIFE_DIR}/" 2>&1; do
  ATTEMPT=$((ATTEMPT+1))
  echo "  retry ${ATTEMPT}..."
  [ "${ATTEMPT}" -gt 30 ] && echo "ERROR: too many retries on oc apply" && exit 1
  sleep 2
done

echo ""
echo "4.2 Wait for clife-controller-manager + Cilium DaemonSet to come up..."
for i in $(seq 1 120); do
  CLIFE_READY=$(oc get deploy -n cilium clife-controller-manager -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "")
  DS_READY=$(oc get ds -n cilium cilium -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
  DS_DESIRED=$(oc get ds -n cilium cilium -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
  echo "  (${i}/120) clife=${CLIFE_READY:-0}/1 cilium-ds=${DS_READY}/${DS_DESIRED}"
  if [ "${CLIFE_READY}" = "1" ] && [ "${DS_READY}" = "${DS_DESIRED}" ] && [ "${DS_DESIRED}" != "0" ]; then
    echo "  CLife + Cilium DS ready."
    break
  fi
  sleep 5
done

echo ""
echo "4.3 Patch Multus daemon-config to use Cilium conflist as readiness indicator..."
KUBE_EDITOR="sed -i s;host/run/multus/cni/net.d/10-ovn-kubernetes.conf;host/run/multus/cni/net.d/05-cilium.conflist;" \
  oc edit cm -n openshift-multus multus-daemon-config

oc get cm -n openshift-multus multus-daemon-config -o jsonpath='{.data.daemon-config\.json}' | \
  python3 -c "import json,sys; print('  readinessindicatorfile:', json.load(sys.stdin)['readinessindicatorfile'])"

echo "4.4 Restart Multus DS..."
oc rollout restart -n openshift-multus ds/multus
oc rollout status -n openshift-multus ds/multus --timeout=5m

# --------------------------------------------------------------------------
# Phase 5 — Re-enable operator management
# --------------------------------------------------------------------------
header "Phase 5 — Re-enable operator management"

echo "5.1 Restart kube-apiserver pods..."
oc delete pod -n openshift-kube-apiserver -l apiserver=true
for i in $(seq 1 30); do
  oc get nodes &>/dev/null && break
  echo "  (${i}/30) API server still recovering..."
  sleep 5
done

echo "5.2 Restart MCC + MCO..."
oc -n openshift-machine-config-operator rollout restart deploy/machine-config-controller
oc -n openshift-machine-config-operator rollout restart deploy/machine-config-operator
oc rollout status -n openshift-machine-config-operator deploy/machine-config-controller --timeout=3m
oc rollout status -n openshift-machine-config-operator deploy/machine-config-operator   --timeout=3m

echo "5.3 Scale CNO back up..."
oc scale deployment -n openshift-network-operator network-operator --replicas=1
oc rollout status -n openshift-network-operator deploy/network-operator --timeout=3m

echo "5.4 Restore CVO management (clear overrides)..."
oc patch clusterversions version --type=merge --patch '{"spec":{"overrides":null}}'

# --------------------------------------------------------------------------
# Phase 6 — Reboot via MCP (the maintenance-window part)
# --------------------------------------------------------------------------
header "Phase 6 — Reboot nodes via MCP"
echo "  WARNING: this unpauses MCPs and rolls all nodes one at a time."
echo "  Workers first (cluster control plane stays stable), then masters."
echo "  Expected duration: ~30-60 min for 3+3."
if ! confirm; then
  echo "  Aborted before Phase 6. MCPs remain paused; CLife + Cilium are deployed."
  echo "  Resume by running 'oc patch ... mcp/worker' (and master) manually."
  exit 0
fi

echo ""
echo "6.1 Unpause worker MCP..."
oc patch --type=merge --patch='{"spec":{"paused":false}}' mcp/worker

echo ""
echo "Waiting for worker MCP rollout (UPDATED=True, UPDATING=False)..."
while true; do
  W=$(oc get mcp worker -o jsonpath='{.status.conditions[?(@.type=="Updated")].status},{.status.conditions[?(@.type=="Updating")].status},{.status.conditions[?(@.type=="Degraded")].status}' 2>/dev/null)
  echo "$(date +%H:%M:%S) worker MCP: Updated/Updating/Degraded = ${W}"
  echo "${W}" | grep -q "True,False,False" && break
  echo "${W}" | grep -q "True$" && echo "  WORKER MCP DEGRADED — investigate" && exit 1
  sleep 30
done

echo ""
echo "6.2 Unpause master MCP..."
oc patch --type=merge --patch='{"spec":{"paused":false}}' mcp/master

echo ""
echo "Waiting for master MCP rollout..."
while true; do
  M=$(oc get mcp master -o jsonpath='{.status.conditions[?(@.type=="Updated")].status},{.status.conditions[?(@.type=="Updating")].status},{.status.conditions[?(@.type=="Degraded")].status}' 2>/dev/null)
  echo "$(date +%H:%M:%S) master MCP: Updated/Updating/Degraded = ${M}"
  echo "${M}" | grep -q "True,False,False" && break
  echo "${M}" | grep -q "True$" && echo "  MASTER MCP DEGRADED — investigate" && exit 1
  sleep 30
done

header "Migration complete — proceed to Section 8 (Post-Migration Verification)"
oc get nodes
echo ""
oc get mcp
echo ""
oc get co | awk 'NR==1 || $3!="True" || $4!="False" || $5!="False"'

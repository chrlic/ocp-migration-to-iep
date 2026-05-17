#!/bin/bash
# Patches KUBERNETES_SERVICE_HOST into the Cilium DaemonSet (main container + init containers)
# and cilium-operator Deployment so they bypass the ClusterIP and reach the API server
# directly — required because CLife does not propagate this env var to the workloads it creates.
#
# Also adds iptables DNAT rules on every master node so that host-network processes
# (MCS, machine-approver, etc.) can reach the kubernetes ClusterIP 172.30.0.1:443.
# With kubeProxyReplacement: false + CNI chaining, Cilium programs ClusterIP only in BPF
# for pod-network traffic; host-network traffic has no iptables rules and times out.
#
# Waits for the cilium DS and operator to exist before patching.

set -euo pipefail

source /root/tools-upi-migrate/lab-config.sh

export KUBECONFIG="${INSTALL_DIR}/auth/kubeconfig"
K8S_API_HOST="api.${CLUSTER_NAME}.${BASE_DOMAIN}"
K8S_API_PORT="6443"
K8S_CLUSTERIP="172.30.0.1"

echo "Waiting for API server..."
until oc get ns cilium &>/dev/null; do
  sleep 5
done

echo "Patching iptables DNAT for ClusterIP on all master nodes..."
for node in $(oc get nodes -l node-role.kubernetes.io/master \
    -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' 2>/dev/null); do
  echo "  Adding DNAT on $node -> $node:${K8S_API_PORT}"
  ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 core@${node} \
    "sudo iptables -t nat -C OUTPUT -d ${K8S_CLUSTERIP} -p tcp --dport 443 -j DNAT --to-destination ${node}:${K8S_API_PORT} 2>/dev/null || \
     sudo iptables -t nat -I OUTPUT 1 -d ${K8S_CLUSTERIP} -p tcp --dport 443 -j DNAT --to-destination ${node}:${K8S_API_PORT}; echo done" || true
done

echo "Waiting for cilium DaemonSet to exist..."
until oc get ds cilium -n cilium &>/dev/null; do
  sleep 5
done

echo "Waiting for cilium-operator Deployment to exist..."
until oc get deploy cilium-operator -n cilium &>/dev/null; do
  sleep 5
done

echo "Patching cilium DS main container..."
oc set env ds/cilium -n cilium \
  KUBERNETES_SERVICE_HOST=${K8S_API_HOST} \
  KUBERNETES_SERVICE_PORT=${K8S_API_PORT}

echo "Patching cilium DS init containers..."
oc get ds cilium -n cilium -o json | jq '
  .spec.template.spec.initContainers |= map(
    .env = ((.env // []) + [
      {"name":"KUBERNETES_SERVICE_HOST","value":"'"${K8S_API_HOST}"'"},
      {"name":"KUBERNETES_SERVICE_PORT","value":"'"${K8S_API_PORT}"'"}
    ] | unique_by(.name))
  )' | oc apply -f -

echo "Patching cilium-operator Deployment..."
oc set env deploy/cilium-operator -n cilium \
  KUBERNETES_SERVICE_HOST=${K8S_API_HOST} \
  KUBERNETES_SERVICE_PORT=${K8S_API_PORT}

echo "Done. Cilium pods will restart with correct API server address."
oc get pods -n cilium

#!/bin/bash
# Recovers a working kubeconfig and prints console access info after cluster installation.
#
# The UPI installer embeds a bootstrap CA in the kubeconfig. After the cluster comes up
# the API TLS cert is rotated (kube-apiserver-lb-signer), making the installer's kubeconfig
# invalid. This script recovers the system:admin client-cert kubeconfig from the first
# master that has the kube-apiserver static pod running (not always master-0).
#
# Usage: bash get-kubeconfig.sh
# Result: INSTALL_DIR/auth/kubeconfig is overwritten with a working kubeconfig.

set -euo pipefail

source /root/tools-upi-migrate/lab-config.sh

KUBECONFIG_OUT="${INSTALL_DIR}/auth/kubeconfig"
KUBECONFIG_PATH="/etc/kubernetes/static-pod-resources/kube-apiserver-certs/secrets/node-kubeconfigs/localhost.kubeconfig"

echo "Checking API server reachability (timeout 5 min)..."
# Some shells run this in a default-everywhere-no_proxy setup; force --noproxy so
# we don't accidentally go through a corporate HTTP proxy that returns its own 503.
for i in $(seq 1 30); do
  if curl -sk --noproxy "*" --connect-timeout 5 \
      "https://api.${CLUSTER_NAME}.${BASE_DOMAIN}:6443/readyz" \
      -o /dev/null -w "%{http_code}" 2>/dev/null | grep -q "200"; then
    echo "  API is up."
    break
  fi
  echo "  API not ready yet (attempt ${i}/30), retrying in 10s..."
  sleep 10
done

# Try each master in order — kube-apiserver static pod may not be on master-0 yet
FOUND_IP=""
for ip in "${MASTER0_IP}" "${MASTER1_IP}" "${MASTER2_IP}"; do
  ssh-keygen -R "${ip}" &>/dev/null || true
  if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 core@${ip} \
      "sudo test -f ${KUBECONFIG_PATH}" 2>/dev/null; then
    FOUND_IP="${ip}"
    break
  fi
done

if [[ -z "${FOUND_IP}" ]]; then
  echo "ERROR: localhost.kubeconfig not found on any master — kube-apiserver may still be starting."
  exit 1
fi

echo "Fetching kubeconfig from ${FOUND_IP}..."
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 core@${FOUND_IP} \
  "sudo cat ${KUBECONFIG_PATH}" \
  | sed "s|https://localhost:6443|https://api.${CLUSTER_NAME}.${BASE_DOMAIN}:6443|g" \
  > "${KUBECONFIG_OUT}"

echo "Verifying..."
export KUBECONFIG="${KUBECONFIG_OUT}"
oc whoami

echo ""
echo "=== Cluster Access ==="
echo "KUBECONFIG: ${KUBECONFIG_OUT}"
echo "Console:    $(oc whoami --show-console)"
echo "User:       kubeadmin"
echo "Password:   $(cat ${INSTALL_DIR}/auth/kubeadmin-password)"
echo ""
echo "Nodes:"
oc get nodes

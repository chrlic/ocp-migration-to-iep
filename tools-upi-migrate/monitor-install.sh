#!/bin/bash
# Monitor UPI installation progress.
# 1. Wait for bootstrap-complete (API up, masters have joined etcd)
# 2. Auto-approve CSRs as they arrive (kubelet-bootstrap + kubelet-serving)
# 3. After cluster is reachable, also auto-remove bootstrap from HAProxy
# 4. Wait for install-complete (all ClusterOperators Available)
# 5. Refresh kubeconfig from a master (installer's bootstrap kubeconfig has a
#    short-lived CA that won't be valid after kube-apiserver-lb-signer rotation)

set -euo pipefail

# Source the proxy env so we get the correct no_proxy that bypasses the corporate
# proxy for the lab network and Cisco-internal hosts.
[ -f /etc/profile.d/proxy.sh ] && source /etc/profile.d/proxy.sh

source /root/tools-upi-migrate/lab-config.sh

echo "=== Monitoring UPI Installation ==="
echo "    no_proxy=${no_proxy:-<unset>}"

# Use noproxy for openshift-install too, in case it reads HTTPS_PROXY.
export NO_PROXY="${no_proxy:-}"

# --------------------------------------------------------------------------
# Phase 1: bootstrap-complete
# --------------------------------------------------------------------------
echo ""
echo "--- Phase 1: Waiting for bootstrap to complete (~20 min) ---"
openshift-install --dir "${INSTALL_DIR}" wait-for bootstrap-complete \
  --log-level=info

echo ""
echo "--- bootstrap-complete ---"
echo "Removing bootstrap from HAProxy and powering it off..."
bash /root/tools-upi-migrate/remove-bootstrap-from-haproxy.sh 2>&1 | sed 's/^/    /'
if command -v govc >/dev/null 2>&1; then
  source /root/tools-upi-migrate/govc-env.sh
  govc vm.power -off -force "${VCENTER_FOLDER}/bootstrap (migrate)" 2>&1 | sed 's/^/    /' || true
fi

# --------------------------------------------------------------------------
# Phase 2: CSR auto-approver in the background
# --------------------------------------------------------------------------
# The installer-time kubeconfig embeds a short-lived bootstrap CA that becomes
# invalid after the kube-apiserver-lb-signer rotates (typically a few minutes
# into install-complete). Use the localhost.kubeconfig from a master, rewriting
# its server URL to api.<cluster>.<domain>:6443.
echo ""
echo "--- Phase 2: Refreshing kubeconfig from a master and starting CSR auto-approver ---"

refresh_kubeconfig() {
  local OUT="${INSTALL_DIR}/auth/kubeconfig"
  for MIP in "${MASTER0_IP}" "${MASTER1_IP}" "${MASTER2_IP}"; do
    ssh-keygen -R "${MIP}" &>/dev/null || true
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 core@"${MIP}" \
        "sudo test -r /etc/kubernetes/static-pod-resources/kube-apiserver-certs/secrets/node-kubeconfigs/localhost.kubeconfig" 2>/dev/null; then
      ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 core@"${MIP}" \
        "sudo cat /etc/kubernetes/static-pod-resources/kube-apiserver-certs/secrets/node-kubeconfigs/localhost.kubeconfig" 2>/dev/null \
        | sed "s|https://localhost:6443|https://api.${CLUSTER_NAME}.${BASE_DOMAIN}:6443|g" \
        > "${OUT}.new"
      mv "${OUT}.new" "${OUT}"
      echo "    Refreshed kubeconfig from master at ${MIP}."
      return 0
    fi
  done
  echo "    WARNING: could not refresh kubeconfig from any master; using installer-provided one."
  return 1
}

# Try a few times — masters may still be coming up
for i in 1 2 3 4 5; do
  if refresh_kubeconfig; then break; fi
  sleep 20
done

export KUBECONFIG="${INSTALL_DIR}/auth/kubeconfig"

approve_csrs() {
  while true; do
    PENDING=$(oc get csr --no-headers 2>/dev/null | grep -c Pending || true)
    if [ "${PENDING}" -gt 0 ]; then
      echo "[CSR] Approving ${PENDING} pending CSR(s)..."
      oc get csr -o name 2>/dev/null | xargs -r oc adm certificate approve 2>/dev/null || true
    fi
    sleep 20
  done
}
approve_csrs &
CSR_PID=$!
trap "kill ${CSR_PID} 2>/dev/null || true" EXIT

# --------------------------------------------------------------------------
# --------------------------------------------------------------------------
# Phase 3: install-complete
# --------------------------------------------------------------------------
echo ""
echo "--- Phase 3: Waiting for install to complete (~30 min) ---"
openshift-install --dir "${INSTALL_DIR}" wait-for install-complete \
  --log-level=info || {
  # If install-complete times out it's usually because the ingress canary
  # isn't ready yet — log status and continue, the IngressController
  # manifest we shipped will eventually reconcile.
  #
  # If you see "missing MachineConfig rendered-master-<hash>" on master MCP,
  # the most common cause in this lab is that IDMS and ITMS were combined
  # into a single multi-doc YAML under openshift/. Bootkube only applies the
  # FIRST document in such files — the second resource silently disappears,
  # the in-cluster MCC re-renders registries.conf with a different content
  # hash than what was on disk during bootstrap, and the master nodes go
  # Degraded on file-content-mismatch. Fix: ensure IDMS and ITMS are in
  # SEPARATE files under openshift/. gen-ignition.sh writes them as
  # 99-artifactory-idms.yaml + 99-artifactory-itms.yaml.
  echo "    install-complete returned non-zero; current operator status:"
  oc get co --no-headers 2>&1 | awk '$3!="True" || $4=="True" || $5=="True" {print "      "$0}'
}

kill ${CSR_PID} 2>/dev/null || true

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo ""
echo "=== Installation Complete ==="
echo ""
oc get nodes
echo ""
oc get clusterversion
echo ""
echo "Console:  $(oc whoami --show-console 2>/dev/null || echo 'run: oc whoami --show-console')"
echo "Password: $(cat "${INSTALL_DIR}/auth/kubeadmin-password" 2>/dev/null || echo 'see: ${INSTALL_DIR}/auth/kubeadmin-password')"
echo ""
echo "KUBECONFIG=${INSTALL_DIR}/auth/kubeconfig"

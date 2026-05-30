#!/bin/bash
# Print OCP web console URL + kubeadmin credentials and the hosts-file lines
# needed for a workstation to reach the console through the bastion HAProxy.
set -euo pipefail

source /etc/profile.d/proxy.sh
source /root/tools-upi-install/lab-config.sh

KUBEADMIN_FILE="${INSTALL_DIR}/auth/kubeadmin-password"
export KUBECONFIG="${INSTALL_DIR}/auth/kubeconfig"

if [ ! -f "${KUBEADMIN_FILE}" ]; then
  echo "ERROR: ${KUBEADMIN_FILE} not found — has the cluster finished installing?"
  exit 1
fi

CONSOLE_URL=$(oc whoami --show-console 2>/dev/null || true)
if [ -z "${CONSOLE_URL}" ]; then
  echo "ERROR: could not reach the API to fetch console URL."
  echo "       Check that /etc/profile.d/proxy.sh has .md.prglab.local in no_proxy"
  echo "       and that the cluster API is responding."
  exit 1
fi

CONSOLE_HOST="${CONSOLE_URL#https://}"
OAUTH_HOST="oauth-openshift.apps.${CLUSTER_NAME}.${BASE_DOMAIN}"

cat <<EOF
=== OCP Console ===
URL:      ${CONSOLE_URL}
Username: kubeadmin
Password: $(cat "${KUBEADMIN_FILE}")

=== Workstation hosts entries (if not using ${BASE_DOMAIN} DNS) ===
${INGRESS_VIP}  ${CONSOLE_HOST}
${INGRESS_VIP}  ${OAUTH_HOST}

The cluster uses a self-signed CA — accept the browser warning for both
hostnames above (the console login bounces through the oauth host).
EOF

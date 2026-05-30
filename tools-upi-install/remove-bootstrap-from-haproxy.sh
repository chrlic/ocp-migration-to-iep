#!/bin/bash
# Remove bootstrap node from the install lab's HAProxy after bootstrap-complete.
# Run this once openshift-install reports "Bootstrap status: complete".
#
# Operates on /etc/haproxy/haproxy-install.cfg + haproxy-install.service —
# the migration lab's haproxy.cfg / haproxy.service are untouched.

set -euo pipefail

source /root/tools-upi-install/lab-config.sh

CFG=/etc/haproxy/haproxy-install.cfg
SVC=haproxy-install

echo "Removing bootstrap (${BOOTSTRAP_IP}) from ${CFG}..."
sed -i "/server bootstrap *${BOOTSTRAP_IP}/d" "${CFG}"

systemctl reload "${SVC}"
echo "Done. Bootstrap removed from api_backend and mcs_backend."
haproxy -c -f "${CFG}" && echo "Config valid."

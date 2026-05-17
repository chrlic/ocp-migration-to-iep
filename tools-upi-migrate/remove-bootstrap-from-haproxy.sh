#!/bin/bash
# Remove bootstrap node from HAProxy after bootstrap-complete.
# Run this once openshift-install reports "Bootstrap status: complete".

set -euo pipefail

source /root/tools-upi-migrate/lab-config.sh

echo "Removing bootstrap (${BOOTSTRAP_IP}) from HAProxy backends..."

sed -i "/server bootstrap ${BOOTSTRAP_IP}/d" /etc/haproxy/haproxy.cfg

systemctl reload haproxy
echo "Done. Bootstrap removed from api_backend and mcs_backend."
haproxy -c -f /etc/haproxy/haproxy.cfg && echo "Config valid."

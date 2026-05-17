#!/bin/bash
# UPI migration lab — ordered script reference.
# Run steps manually in sequence; each script is idempotent or safe to re-run.
#
# Phase 1: Prepare bastion (run once, internet-connected)
#   ./setup-artifactory.sh      # start Artifactory, create remote/virtual repos
#   ./download-rhcos.sh         # download RHCOS live ISO for OCP_VERSION
#   ./upload-iso.sh             # push ISO to vSphere datastore
#   ./setup-haproxy.sh          # configure HAProxy for API/MCS/Ingress VIPs
#   ./setup-httpd.sh            # configure Apache to serve ignition files on :8080
#
# Phase 2: Generate ignition and create VMs
#   ./gen-ignition.sh           # write install-config, manifests (ICSP + CA), ignition files
#   ./recreate-vms.sh           # create/re-create all 7 VMs, attach RHCOS ISO
#
# Phase 3: Install RHCOS on each node (manual — open VM consoles)
#   For each VM (bootstrap first, then masters, then workers):
#     sudo coreos-installer install /dev/sda \
#       --ignition-url http://<BASTION_IP>:8080/ignition/<role>.ign \
#       --insecure-ignition && sudo reboot
#
# Phase 4: Boot and monitor
#   ./start-vms.sh              # power on: bootstrap → masters → workers
#   ./monitor-install.sh        # wait-for bootstrap-complete, approve CSRs, wait-for install-complete
#   ./remove-bootstrap-from-haproxy.sh   # run after bootstrap-complete
#
# Phase 5: Post-install (if kubeconfig is stale after cert rotation)
#   ./get-kubeconfig.sh         # recover working system:admin kubeconfig from master
#
# Phase 6: OVN→Cilium migration
#   (Follow OCP_IEP_Migration_Guide.md Sections 5–7)
#   ./patch-cilium-k8s-host.sh  # run after CLife deploys Cilium
#
# Phase 7: Verify
#   ./check-cilium.sh           # Cilium pod status, clife logs, cilium status
#
# Teardown:
#   ./delete-vms.sh             # power off and destroy all 7 VMs

set -euo pipefail

source /root/tools-upi-migrate/lab-config.sh
source /root/tools-upi-migrate/govc-env.sh

echo "This script is a reference — run individual phase scripts manually."
echo "See comments in all.sh for the correct execution order."
exit 0

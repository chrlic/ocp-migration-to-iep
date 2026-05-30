#!/bin/bash
# Upload RHCOS live ISO to the vSphere datastore.
# Run this once before creating VMs.
# The ISO must have been downloaded first via download-rhcos.sh.

set -euo pipefail

source /root/tools-upi-install/lab-config.sh
source /root/tools-upi-install/govc-env.sh

ISO_LOCAL="${INSTALL_DIR}/rhcos/rhcos-live.iso"
ISO_REMOTE="_mdivis-install/rhcos-live.iso"   # Distinct from migration lab's _mdivis-migrate/

if [ ! -f "${ISO_LOCAL}" ]; then
  echo "ERROR: ISO not found at ${ISO_LOCAL}"
  echo "       Run download-rhcos.sh first."
  exit 1
fi

echo "=== Uploading RHCOS live ISO to vSphere ==="
echo "  Source:      ${ISO_LOCAL}"
echo "  Destination: [${VCENTER_DATASTORE}] ${ISO_REMOTE}"
echo ""

# Remove existing if present (govc upload does not overwrite cleanly)
govc datastore.rm "${ISO_REMOTE}" 2>/dev/null && echo "  Removed existing ISO." || true

govc datastore.upload "${ISO_LOCAL}" "${ISO_REMOTE}"

echo ""
echo "Upload complete: [${VCENTER_DATASTORE}] ${ISO_REMOTE}"

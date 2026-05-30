#!/bin/bash
# Download RHCOS live ISO and rootfs for the OCP version set in lab-config.sh.
# Files are placed in INSTALL_DIR/rhcos/ and served via httpd.
# Run after setup-httpd.sh.

set -euo pipefail

source /root/tools-upi-install/lab-config.sh

RHCOS_DIR="${INSTALL_DIR}/rhcos"
mkdir -p "${RHCOS_DIR}"

echo "=== Downloading RHCOS boot artifacts for OCP ${OCP_VERSION} ==="

# openshift-install prints the stream JSON for the configured version
STREAM_JSON=$(openshift-install coreos print-stream-json 2>/dev/null)

ISO_URL=$(echo "${STREAM_JSON}" | \
  jq -r '.architectures.x86_64.artifacts.metal.formats["iso"].disk.location')

ROOTFS_URL=$(echo "${STREAM_JSON}" | \
  jq -r '.architectures.x86_64.artifacts.metal.formats["pxe"].rootfs.location')

ISO_FILE="${RHCOS_DIR}/rhcos-live.iso"
ROOTFS_FILE="${RHCOS_DIR}/rhcos-rootfs.img"

echo "ISO URL:    ${ISO_URL}"
echo "Rootfs URL: ${ROOTFS_URL}"
echo ""

if [ -f "${ISO_FILE}" ]; then
  echo "ISO already exists — skipping (delete ${ISO_FILE} to re-download)"
else
  echo "Downloading ISO (~1 GB)..."
  curl -L --progress-bar -o "${ISO_FILE}" "${ISO_URL}"
fi

if [ -f "${ROOTFS_FILE}" ]; then
  echo "Rootfs already exists — skipping (delete ${ROOTFS_FILE} to re-download)"
else
  echo "Downloading rootfs (~1 GB)..."
  curl -L --progress-bar -o "${ROOTFS_FILE}" "${ROOTFS_URL}"
fi

# SELinux context so httpd can serve the files
restorecon -R "${RHCOS_DIR}" 2>/dev/null || true

echo ""
echo "=== RHCOS artifacts ready ==="
ls -lh "${RHCOS_DIR}"
echo ""
echo "ISO:    http://${BASTION_IP}:8080/rhcos-install/rhcos-live.iso"
echo "Rootfs: http://${BASTION_IP}:8080/rhcos-install/rhcos-rootfs.img"

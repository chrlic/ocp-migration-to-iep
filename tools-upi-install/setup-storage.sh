#!/bin/bash
# Install nfs-subdir-external-provisioner into the install lab cluster so the
# bastion's NFS export becomes a dynamic StorageClass. The SC name and the
# NFS path come from lab-config (NFS_STORAGE_CLASS, NFS_EXPORT_PATH).
#
# Prerequisite: ./setup-nfs.sh on the bastion (NFS export ready).

set -euo pipefail

source /root/tools-upi-install/lab-config.sh
export KUBECONFIG="${INSTALL_DIR}/auth/kubeconfig"

echo "=== StorageClass setup (install lab) ==="

if ! command -v helm >/dev/null 2>&1; then
  echo "ERROR: helm not on PATH. Install it first:"
  echo "  curl -fL https://get.helm.sh/helm-v3.16.3-linux-amd64.tar.gz | tar xz -C /tmp linux-amd64/helm"
  echo "  mv /tmp/linux-amd64/helm /usr/local/bin/helm && chmod +x /usr/local/bin/helm"
  exit 1
fi

source /etc/profile.d/proxy.sh 2>/dev/null || true

# Add the upstream chart repo (idempotent — same as migration lab uses)
helm repo add nfs-subdir-external-provisioner \
  https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/ 2>/dev/null || true
helm repo update

# Namespace + SCC (privileged is needed because the provisioner mounts NFS via
# hostPath helpers)
oc create namespace nfs-provisioner-install 2>/dev/null || true
oc adm policy add-scc-to-user privileged \
  -z nfs-subdir-external-provisioner-install -n nfs-provisioner-install \
  2>/dev/null || true

# Install (or upgrade)
helm upgrade --install nfs-subdir-external-provisioner-install \
  nfs-subdir-external-provisioner/nfs-subdir-external-provisioner \
  --namespace nfs-provisioner-install \
  --set nfs.server="${BASTION_IP}" \
  --set nfs.path="${NFS_EXPORT_PATH}" \
  --set storageClass.name="${NFS_STORAGE_CLASS}" \
  --set storageClass.defaultClass=true \
  --set storageClass.archiveOnDelete=false

oc -n nfs-provisioner-install rollout status \
  deploy/nfs-subdir-external-provisioner-install --timeout=3m

echo ""
echo "=== StorageClasses available ==="
oc get sc
echo ""
echo "Next: deploy Timescape (Section 9 of the install guide) using ${NFS_STORAGE_CLASS}."

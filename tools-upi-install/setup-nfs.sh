#!/bin/bash
# Stand up an NFS export on the bastion dedicated to the install lab.
# Coexists with the migration lab's export at /srv/nfs/openshift; this one is
# at ${NFS_EXPORT_PATH} (default /srv/nfs/openshift-install).
#
# Outcome: a directory exported to 192.168.39.0/24 that the install lab's
# nfs-subdir-external-provisioner will use as the backing store for
# StorageClass ${NFS_STORAGE_CLASS} (default nfs-storage-install).

set -euo pipefail

source /root/tools-upi-install/lab-config.sh

echo "=== NFS Setup (install lab) ==="

# nfs-server is presumably already installed by the migration lab; idempotent.
rpm -q nfs-utils >/dev/null 2>&1 || dnf install -y nfs-utils
systemctl enable --now nfs-server

mkdir -p "${NFS_EXPORT_PATH}"
chown nobody:nobody "${NFS_EXPORT_PATH}"
chmod 0777 "${NFS_EXPORT_PATH}"
echo "    Export dir: ${NFS_EXPORT_PATH}"

# Separate exports.d file so the migration lab's export is undisturbed.
cat > /etc/exports.d/openshift-install.exports <<EOF
${NFS_EXPORT_PATH}  ${NODE_NETWORK}(rw,sync,no_root_squash,no_subtree_check)
EOF

exportfs -ra
exportfs -v | grep -E "${NFS_EXPORT_PATH}" || true

# Firewall already opened by migration lab; idempotent.
firewall-cmd --add-service=nfs --permanent 2>/dev/null || true
firewall-cmd --reload

echo ""
echo "=== NFS export ready ==="
echo "Export:  ${BASTION_IP}:${NFS_EXPORT_PATH}"
echo "Networks: ${NODE_NETWORK}"
echo ""
echo "Next: ./setup-storage.sh to deploy nfs-subdir-external-provisioner"
echo "      in the cluster, creating the ${NFS_STORAGE_CLASS} StorageClass."

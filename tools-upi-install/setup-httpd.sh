#!/bin/bash
# Configure Apache httpd on the bastion to serve the INSTALL lab's:
#   - RHCOS live ISO and rootfs (for node boot)
#   - Ignition files (fetched by coreos-installer during RHCOS install)
#
# Coexists with /root/tools-upi-migrate/setup-httpd.sh — both labs share the
# same Apache instance on port 8080. This script writes a SEPARATE config
# file (ocp-upi-install.conf) and uses distinct URL aliases (/ignition-install/
# and /rhcos-install/) so per-MAC PXE configs from the two labs don't collide.

set -euo pipefail

source /root/tools-upi-install/lab-config.sh

echo "=== httpd Setup (install lab — adds to existing config) ==="

# httpd is presumably already installed by the migration lab.
# Install only if it's not there yet.
rpm -q httpd >/dev/null 2>&1 || dnf install -y httpd

# Make sure :8080 listener exists (idempotent — sed only replaces 'Listen 80')
sed -i 's/^Listen 80$/Listen 8080/' /etc/httpd/conf/httpd.conf

# Distinct config file from the migration lab's (which is at ocp-upi.conf)
cat > /etc/httpd/conf.d/ocp-upi-install.conf <<EOF
Alias /ignition-install  ${INSTALL_DIR}/ignition
Alias /rhcos-install     ${INSTALL_DIR}/rhcos

<Directory "${INSTALL_DIR}/ignition">
    Options Indexes FollowSymLinks
    AllowOverride None
    Require all granted
</Directory>

<Directory "${INSTALL_DIR}/rhcos">
    Options Indexes FollowSymLinks
    AllowOverride None
    Require all granted
</Directory>
EOF

mkdir -p "${INSTALL_DIR}/ignition"
mkdir -p "${INSTALL_DIR}/rhcos"

# SELinux: ${INSTALL_DIR} lives under /root which is admin_home_t — httpd_t
# cannot read it by default. Relabel as httpd_sys_content_t persistently.
semanage fcontext -a -t httpd_sys_content_t "${INSTALL_DIR}(/.*)?" 2>/dev/null || \
  semanage fcontext -m -t httpd_sys_content_t "${INSTALL_DIR}(/.*)?"
restorecon -R "${INSTALL_DIR}"

# Search bit on /root for the apache user is already granted by the migration
# lab's setup-httpd.sh, but be idempotent.
setfacl -m u:apache:x /root 2>/dev/null || true

# httpd may already be running; reload to pick up the new conf.d file.
systemctl enable --now httpd
systemctl reload httpd

# Firewall already opened by migration lab; idempotent here.
firewall-cmd --permanent --add-port=8080/tcp 2>/dev/null || true
firewall-cmd --reload

echo ""
echo "=== httpd configured (install lab) ==="
echo "Ignition files: http://${BASTION_IP}:8080/ignition-install/"
echo "RHCOS images:   http://${BASTION_IP}:8080/rhcos-install/"
echo ""
echo "Coexists with migration lab at /ignition/ and /rhcos/."
echo ""
echo "Next: run download-rhcos.sh to populate the rhcos directory."

#!/bin/bash
# Configure Apache httpd on the bastion to serve:
#   - RHCOS live ISO and rootfs (for node boot)
#   - Ignition files (fetched by coreos-installer during RHCOS install)
#
# Listens on port 8080 to avoid conflict with HAProxy on port 80.

set -euo pipefail

source /root/tools-upi-migrate/lab-config.sh

echo "=== httpd Setup ==="

dnf install -y httpd

# Use port 8080 — port 80 is taken by HAProxy ingress frontend
sed -i 's/^Listen 80$/Listen 8080/' /etc/httpd/conf/httpd.conf

# Serve files from the install directory
cat > /etc/httpd/conf.d/ocp-upi.conf <<EOF
Alias /ignition  ${INSTALL_DIR}/ignition
Alias /rhcos     ${INSTALL_DIR}/rhcos

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

# httpd_t also needs to traverse /root (mode 0550 on RHEL) to reach INSTALL_DIR.
# Grant only the apache user the search bit via POSIX ACL — no world access.
setfacl -m u:apache:x /root

systemctl enable --now httpd

firewall-cmd --permanent --add-port=8080/tcp
firewall-cmd --reload

echo ""
echo "=== httpd configured ==="
echo "Ignition files: http://${BASTION_IP}:8080/ignition/"
echo "RHCOS images:   http://${BASTION_IP}:8080/rhcos/"
echo ""
echo "Next: run download-rhcos.sh to populate the rhcos directory."

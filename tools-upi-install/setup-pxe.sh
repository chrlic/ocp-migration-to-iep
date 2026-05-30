#!/bin/bash
# Add the install lab's MAC reservations and per-MAC PXE configs to the
# existing dnsmasq + TFTP service set up by /root/tools-upi-migrate/setup-pxe.sh
# on the bastion. This script does NOT touch the global dnsmasq config
# (interface, dhcp-range, tftp settings) — only adds per-host entries.
#
# Prerequisite: /root/tools-upi-migrate/setup-pxe.sh has been run on this
# bastion (it installed dnsmasq, syslinux, shim, grub2-efi, set up
# /var/lib/tftpboot, etc.). The install lab borrows all of that.
#
# Re-running is idempotent: dnsmasq config and per-MAC grub configs are
# rewritten in place.

set -euo pipefail

source /root/tools-upi-install/lab-config.sh
source /root/tools-upi-install/govc-env.sh

echo "=== PXE Setup (install lab — additive) ==="

# --------------------------------------------------------------------------
# 1. Sanity check — the migration lab's PXE machinery must be in place
# --------------------------------------------------------------------------
for required in /var/lib/tftpboot/shimx64.efi /var/lib/tftpboot/grubx64.efi \
                /var/lib/tftpboot/grub.cfg /var/lib/tftpboot/EFI/grub-cfg \
                /etc/dnsmasq.d/ocp-pxe.conf; do
  if [ ! -e "${required}" ]; then
    echo "ERROR: ${required} not present."
    echo "       Run /root/tools-upi-migrate/setup-pxe.sh first to lay down the"
    echo "       shared TFTP root and dnsmasq config."
    exit 1
  fi
done

# --------------------------------------------------------------------------
# 2. Extract RHCOS PXE artifacts for THIS lab's OCP version
#    (kept in install lab's INSTALL_DIR; copy kernel/initramfs into TFTP root)
# --------------------------------------------------------------------------
echo "--- Extracting RHCOS PXE artifacts ---"
RHCOS_DIR="${INSTALL_DIR}/rhcos"
ISO="${RHCOS_DIR}/rhcos-live.iso"
if [ ! -f "${ISO}" ]; then
  echo "ERROR: ${ISO} not found. Run download-rhcos.sh first."
  exit 1
fi

mkdir -p /mnt/rhcos-iso-install
mount -o loop,ro "${ISO}" /mnt/rhcos-iso-install
cp -f /mnt/rhcos-iso-install/images/pxeboot/vmlinuz    "${RHCOS_DIR}/rhcos-vmlinuz"
cp -f /mnt/rhcos-iso-install/images/pxeboot/initrd.img "${RHCOS_DIR}/rhcos-initrd.img"
umount /mnt/rhcos-iso-install
rmdir  /mnt/rhcos-iso-install
restorecon -R "${RHCOS_DIR}" 2>/dev/null || true
echo "    Extracted: rhcos-vmlinuz, rhcos-initrd.img"

# Each lab needs distinct kernel/initrd filenames at the TFTP root so the
# two clusters can run different OCP releases at the same time. Migration
# lab uses /rhcos-vmlinuz; install lab uses /rhcos-install-vmlinuz.
TFTPROOT=/var/lib/tftpboot
\cp -f "${RHCOS_DIR}/rhcos-vmlinuz"    "${TFTPROOT}/rhcos-install-vmlinuz"
\cp -f "${RHCOS_DIR}/rhcos-initrd.img" "${TFTPROOT}/rhcos-install-initrd.img"
chmod o+r "${TFTPROOT}/rhcos-install-vmlinuz" "${TFTPROOT}/rhcos-install-initrd.img"
echo "    Copied to TFTP as rhcos-install-vmlinuz / rhcos-install-initrd.img"

# --------------------------------------------------------------------------
# 3. Helpers: query MAC of a VM by full name
# --------------------------------------------------------------------------
get_mac() {
  local FULL="$1"
  govc vm.info -json "${VCENTER_FOLDER}/${FULL}" 2>/dev/null \
    | python3 -c "
import sys, json
d = json.load(sys.stdin)
devs = d['virtualMachines'][0]['config']['hardware']['device']
nics = [x for x in devs if 'macAddress' in x]
print(nics[0]['macAddress'] if nics else '')
"
}

# --------------------------------------------------------------------------
# 4. Write per-VM grub.cfg files under /var/lib/tftpboot/EFI/grub-cfg/<mac>.cfg
# --------------------------------------------------------------------------
echo "--- Writing per-MAC PXE configs (install lab) ---"
HTTPD_BASE="http://${BASTION_IP}:8080"
KERNEL_TFTP="(tftp)/rhcos-install-vmlinuz"
INITRD_TFTP="(tftp)/rhcos-install-initrd.img"
ROOTFS_URL="${HTTPD_BASE}/rhcos-install/rhcos-rootfs.img"

write_pxe_cfg() {
  local FULL="$1" IP="$2" ROLE="$3" SHORT="$4"
  local MAC=$(get_mac "${FULL}")
  if [ -z "${MAC}" ]; then
    echo "    WARNING: could not get MAC for ${FULL} — skipping"
    return
  fi
  local MAC_LOWER=$(echo "${MAC}" | tr 'A-Z' 'a-z')
  local IGNITION_URL="${HTTPD_BASE}/ignition-install/${ROLE}.ign"
  local CFG="${TFTPROOT}/EFI/grub-cfg/${MAC_LOWER}.cfg"

  cat > "${CFG}" <<EOF
set default=0
set timeout=2
menuentry "RHCOS UPI ${ROLE} ${SHORT} (${IP})" {
  linux ${KERNEL_TFTP} \\
    ip=${IP}::${NODE_GATEWAY}:255.255.255.0:${SHORT}.${CLUSTER_NAME}.${BASE_DOMAIN}:${PRIMARY_NIC}:none \\
    nameserver=${DNS_SERVER} \\
    rd.neednet=1 \\
    coreos.live.rootfs_url=${ROOTFS_URL} \\
    coreos.inst.install_dev=/dev/sda \\
    coreos.inst.ignition_url=${IGNITION_URL} \\
    coreos.inst.insecure_ignition \\
    coreos.inst.skip_reboot
  initrd ${INITRD_TFTP}
}
EOF
  echo "    ${SHORT} (${MAC_LOWER}) → ${ROLE}, ip ${IP}"
}

write_pxe_cfg "${VM_BOOTSTRAP}" "${BOOTSTRAP_IP}" bootstrap bootstrap-i
write_pxe_cfg "${VM_MASTER0}"   "${MASTER0_IP}"   master    master-i-0
write_pxe_cfg "${VM_MASTER1}"   "${MASTER1_IP}"   master    master-i-1
write_pxe_cfg "${VM_MASTER2}"   "${MASTER2_IP}"   master    master-i-2
write_pxe_cfg "${VM_WORKER0}"   "${WORKER0_IP}"   worker    worker-i-0
write_pxe_cfg "${VM_WORKER1}"   "${WORKER1_IP}"   worker    worker-i-1
write_pxe_cfg "${VM_WORKER2}"   "${WORKER2_IP}"   worker    worker-i-2

# --------------------------------------------------------------------------
# 5. Write the install lab's dnsmasq dhcp-host entries to a SEPARATE file
#    (the migration lab's /etc/dnsmasq.d/ocp-pxe.conf already provides the
#    global interface/range/tftp settings; we just add hosts here).
# --------------------------------------------------------------------------
echo "--- Writing /etc/dnsmasq.d/ocp-pxe-install.conf (host reservations only) ---"

DHCP_HOSTS=""
add_host() {
  local FULL="$1" IP="$2" SHORT="$3"
  local MAC=$(get_mac "${FULL}" | tr 'A-Z' 'a-z')
  if [ -n "${MAC}" ]; then
    DHCP_HOSTS+="dhcp-host=${MAC},${IP},${SHORT},infinite,set:known"$'\n'
  fi
}
add_host "${VM_BOOTSTRAP}" "${BOOTSTRAP_IP}" bootstrap-i
add_host "${VM_MASTER0}"   "${MASTER0_IP}"   master-i-0
add_host "${VM_MASTER1}"   "${MASTER1_IP}"   master-i-1
add_host "${VM_MASTER2}"   "${MASTER2_IP}"   master-i-2
add_host "${VM_WORKER0}"   "${WORKER0_IP}"   worker-i-0
add_host "${VM_WORKER1}"   "${WORKER1_IP}"   worker-i-1
add_host "${VM_WORKER2}"   "${WORKER2_IP}"   worker-i-2

cat > /etc/dnsmasq.d/ocp-pxe-install.conf <<EOF
# UPI install lab — DHCP host reservations only.
# Global dnsmasq config (interface, dhcp-range, enable-tftp, tftp-root, dhcp-match
# for client-arch, dhcp-ignore=tag:!known) is provided by ocp-pxe.conf from the
# migration lab. Each lab only contributes its own host reservations here.
${DHCP_HOSTS}
EOF

# --------------------------------------------------------------------------
# 6. Reload dnsmasq so the new hosts take effect
# --------------------------------------------------------------------------
systemctl reload dnsmasq || systemctl restart dnsmasq
sleep 1
systemctl --no-pager status dnsmasq | head -8

# --------------------------------------------------------------------------
# 7. Set vSphere boot order: ethernet,disk
# --------------------------------------------------------------------------
echo "--- Setting vSphere boot order: ethernet,disk ---"
for VM in "${VM_BOOTSTRAP}" "${VM_MASTER0}" "${VM_MASTER1}" "${VM_MASTER2}" \
          "${VM_WORKER0}" "${VM_WORKER1}" "${VM_WORKER2}"; do
  govc device.boot -vm "${VCENTER_FOLDER}/${VM}" \
    -order ethernet,disk -delay 2000 2>&1 \
    | sed "s/^/  ${VM}: /"
done

echo ""
echo "=== PXE setup complete (install lab) ==="
echo "Per-VM grub configs at /var/lib/tftpboot/EFI/grub-cfg/<mac>.cfg"
echo "DHCP hosts at /etc/dnsmasq.d/ocp-pxe-install.conf"
echo ""
echo "Next: ./pxe-install-and-boot.sh — orchestrated PXE install of all 7 VMs"

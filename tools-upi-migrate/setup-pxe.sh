#!/bin/bash
# Stand up DHCP + TFTP (via dnsmasq) on the bastion so the 7 lab VMs can PXE-boot
# and run coreos-installer unattended with the role-specific ignition URL.
#
# - DHCP is restricted to known MACs only (dhcp-host entries), with dhcp-ignore
#   for unknown clients. Safe to coexist with other lab networks.
# - TFTP serves syslinux pxelinux.0 (BIOS) and grubx64.efi (UEFI). VMs are
#   UEFI-firmware (created with -firmware=efi), so the EFI path is what matters.
# - RHCOS kernel + initramfs + rootfs are extracted from rhcos-live.iso and
#   served via httpd (already set up on :8080). pxelinux/grub config files
#   reference these by URL.
#
# Re-running is idempotent: dhcp-host entries and pxelinux configs are rewritten.

set -euo pipefail

source /root/tools-upi-migrate/lab-config.sh

echo "=== PXE / dnsmasq Setup ==="

# --------------------------------------------------------------------------
# 1. Install dnsmasq, syslinux, grub2-efi tools
# --------------------------------------------------------------------------
echo "--- Installing packages ---"
dnf install -y dnsmasq syslinux-tftpboot shim-x64 grub2-efi-x64

# --------------------------------------------------------------------------
# 2. Extract RHCOS PXE artifacts (kernel + initramfs) from the ISO
# --------------------------------------------------------------------------
echo "--- Extracting RHCOS PXE artifacts from ISO ---"
RHCOS_DIR="${INSTALL_DIR}/rhcos"
ISO="${RHCOS_DIR}/rhcos-live.iso"
if [ ! -f "${ISO}" ]; then
  echo "ERROR: ${ISO} not found. Run download-rhcos.sh first."
  exit 1
fi

mkdir -p /mnt/rhcos-iso
mount -o loop,ro "${ISO}" /mnt/rhcos-iso
cp -f /mnt/rhcos-iso/images/pxeboot/vmlinuz     "${RHCOS_DIR}/rhcos-vmlinuz"
cp -f /mnt/rhcos-iso/images/pxeboot/initrd.img  "${RHCOS_DIR}/rhcos-initrd.img"
# rootfs is already downloaded by download-rhcos.sh as rhcos-rootfs.img
umount /mnt/rhcos-iso
rmdir  /mnt/rhcos-iso
restorecon -R "${RHCOS_DIR}" 2>/dev/null || true
echo "    Extracted: rhcos-vmlinuz, rhcos-initrd.img"

# --------------------------------------------------------------------------
# 3. TFTP root: /var/lib/tftpboot
# --------------------------------------------------------------------------
echo "--- Setting up TFTP root ---"
TFTPROOT=/var/lib/tftpboot
mkdir -p "${TFTPROOT}/EFI/grub-cfg"

# BIOS bootloader (kept for completeness; lab VMs are EFI). On CentOS Stream 9
# the syslinux-tftpboot package installs to /tftpboot — copy what we need.
for f in pxelinux.0 ldlinux.c32 libutil.c32 menu.c32; do
  cp -f "/tftpboot/${f}" "${TFTPROOT}/" 2>/dev/null || true
done

# UEFI bootloader at the TFTP root. shim looks for grubx64.efi (and the
# optional revocations.efi) relative to its own load path — keeping both at
# the root sidesteps any path-discovery ambiguity.
for SRC in /boot/efi/EFI/centos /boot/efi/EFI/redhat /usr/share/shim-x64/*/; do
  if [ -f "${SRC}/shimx64.efi" ]; then
    cp -f "${SRC}/shimx64.efi" "${TFTPROOT}/shimx64.efi"
    break
  fi
done
for SRC in /boot/efi/EFI/centos /boot/efi/EFI/redhat /usr/lib/grub2/x86_64-efi; do
  if [ -f "${SRC}/grubx64.efi" ]; then
    cp -f "${SRC}/grubx64.efi" "${TFTPROOT}/grubx64.efi"
    break
  fi
done

# Single grub.cfg at the TFTP root. shim+grub built into el9 default to looking
# for grub.cfg next to grubx64.efi, so the root is the simplest place.
# grub's net module exposes $net_default_mac as aa:bb:cc:dd:ee:ff which we use
# to pick the per-VM config from EFI/grub-cfg/.
cat > "${TFTPROOT}/grub.cfg" <<'GRUB'
set timeout=3
set default=0
insmod efi_gop
insmod efi_uga
insmod all_video

configfile (tftp)/EFI/grub-cfg/${net_default_mac}.cfg

menuentry "RHCOS — no per-MAC config for ${net_default_mac}" {
  echo "No PXE config for MAC ${net_default_mac} — check bastion."
  sleep 30
  halt
}
GRUB

# --------------------------------------------------------------------------
# 4. Write per-VM grub.cfg files (one per role/MAC)
# --------------------------------------------------------------------------
echo "--- Writing per-MAC PXE configs ---"

# Read VM MACs from vSphere (recreate-vms.sh printed them earlier — query again)
source /root/tools-upi-migrate/govc-env.sh

get_mac() {
  local VM="$1"
  govc vm.info -json "${VCENTER_FOLDER}/${VM} (migrate)" 2>/dev/null \
    | python3 -c "
import sys, json
d = json.load(sys.stdin)
devs = d['virtualMachines'][0]['config']['hardware']['device']
nics = [x for x in devs if 'macAddress' in x]
print(nics[0]['macAddress'] if nics else '')
"
}

# Kernel + initramfs are served via TFTP (grub's `linux` directive doesn't
# fetch from HTTP — only TFTP). Place copies at the TFTP root.
\cp -f "${RHCOS_DIR}/rhcos-vmlinuz"    "${TFTPROOT}/rhcos-vmlinuz"
\cp -f "${RHCOS_DIR}/rhcos-initrd.img" "${TFTPROOT}/rhcos-initrd.img"
chmod o+r "${TFTPROOT}/rhcos-vmlinuz" "${TFTPROOT}/rhcos-initrd.img"

# The rootfs IS fetched via HTTP — RHCOS supports `coreos.live.rootfs_url=<http://>`
HTTPD_BASE="http://${BASTION_IP}:8080"
KERNEL_TFTP="(tftp)/rhcos-vmlinuz"
INITRD_TFTP="(tftp)/rhcos-initrd.img"
ROOTFS_URL="${HTTPD_BASE}/rhcos/rhcos-rootfs.img"

write_pxe_cfg() {
  local VM="$1" IP="$2" ROLE="$3"
  local MAC=$(get_mac "${VM}")
  if [ -z "${MAC}" ]; then
    echo "    WARNING: could not get MAC for ${VM} — skipping"
    return
  fi
  local MAC_LOWER=$(echo "${MAC}" | tr 'A-Z' 'a-z')
  local IGNITION_URL="${HTTPD_BASE}/ignition/${ROLE}.ign"
  local CFG="${TFTPROOT}/EFI/grub-cfg/${MAC_LOWER}.cfg"

  # Kernel command line:
  #   ip=<ip>::<gw>:<mask>:<hostname>:<iface>:none
  #   nameserver=<dns>
  #   rd.neednet=1                          (force network bring-up in initrd)
  #   coreos.live.rootfs_url=<url>          (fetch rootfs after kernel boots)
  #   coreos.inst.install_dev=/dev/sda      (target disk)
  #   coreos.inst.ignition_url=<url>        (apply this ignition during install)
  #   coreos.inst.insecure_ignition          (allow HTTP ignition URL — lab only)
  # coreos.inst.skip_reboot makes coreos-installer leave the box powered-on at the
  # live environment after writing the disk. We then power-cycle externally with
  # boot order = disk,ethernet to skip PXE on the second boot. This avoids the
  # PXE→install→reboot→PXE→install loop that would otherwise occur with the
  # ethernet-first boot order.
  cat > "${CFG}" <<EOF
set default=0
set timeout=2
menuentry "RHCOS UPI ${ROLE} ${VM} (${IP})" {
  linux ${KERNEL_TFTP} \\
    ip=${IP}::${NODE_GATEWAY}:255.255.255.0:${VM}.${CLUSTER_NAME}.${BASE_DOMAIN}:ens192:none \\
    nameserver=192.168.33.10 \\
    rd.neednet=1 \\
    coreos.live.rootfs_url=${ROOTFS_URL} \\
    coreos.inst.install_dev=/dev/sda \\
    coreos.inst.ignition_url=${IGNITION_URL} \\
    coreos.inst.insecure_ignition \\
    coreos.inst.skip_reboot
  initrd ${INITRD_TFTP}
}
EOF
  echo "    ${VM} (${MAC_LOWER}) → ${ROLE}, ip ${IP}"
}

write_pxe_cfg bootstrap  "${BOOTSTRAP_IP}" bootstrap
write_pxe_cfg master-m-0 "${MASTER0_IP}"   master
write_pxe_cfg master-m-1 "${MASTER1_IP}"   master
write_pxe_cfg master-m-2 "${MASTER2_IP}"   master
write_pxe_cfg worker-m-0 "${WORKER0_IP}"   worker
write_pxe_cfg worker-m-1 "${WORKER1_IP}"   worker
write_pxe_cfg worker-m-2 "${WORKER2_IP}"   worker

# --------------------------------------------------------------------------
# 5. dnsmasq config — DHCP restricted to known MACs, TFTP from /var/lib/tftpboot
# --------------------------------------------------------------------------
echo "--- Writing dnsmasq config ---"

# Build dhcp-host lines from the MACs we just queried
DHCP_HOSTS=""
add_host() {
  local VM="$1" IP="$2"
  local MAC=$(get_mac "${VM}" | tr 'A-Z' 'a-z')
  if [ -n "${MAC}" ]; then
    DHCP_HOSTS+="dhcp-host=${MAC},${IP},${VM},infinite"$'\n'
  fi
}
add_host bootstrap  "${BOOTSTRAP_IP}"
add_host master-m-0 "${MASTER0_IP}"
add_host master-m-1 "${MASTER1_IP}"
add_host master-m-2 "${MASTER2_IP}"
add_host worker-m-0 "${WORKER0_IP}"
add_host worker-m-1 "${WORKER1_IP}"
add_host worker-m-2 "${WORKER2_IP}"

cat > /etc/dnsmasq.d/ocp-pxe.conf <<EOF
# UPI migration lab — DHCP + TFTP for RHCOS PXE install
# DHCP is limited to the lab MACs below; unknown clients are ignored.

# Interface selection
interface=ens192
bind-interfaces

# Do not act as a DNS server here — lab DNS lives on 192.168.33.10
port=0

# DHCP scope
dhcp-range=${NODE_NETWORK%/*},static,255.255.255.0
dhcp-option=option:router,${NODE_GATEWAY}
dhcp-option=option:dns-server,192.168.33.10
dhcp-option=option:domain-search,${CLUSTER_NAME}.${BASE_DOMAIN}
dhcp-option=option:domain-name,${CLUSTER_NAME}.${BASE_DOMAIN}

# Only serve known MACs (dhcp-host entries below are tagged "known")
dhcp-ignore=tag:!known

# Per-MAC static assignments
${DHCP_HOSTS}
# PXE / TFTP
enable-tftp
tftp-root=/var/lib/tftpboot

# Architecture-specific bootfile (UEFI x64). vmxnet3 firmware reports option 93 = 0x0007.
dhcp-match=set:efi64,option:client-arch,7
dhcp-match=set:efi64,option:client-arch,9
dhcp-boot=tag:efi64,shimx64.efi

# Fallback for legacy BIOS (option 93 = 0)
dhcp-match=set:bios,option:client-arch,0
dhcp-boot=tag:bios,pxelinux.0

# Logging — useful while bringing nodes up
log-dhcp
EOF

# dnsmasq's "dhcp-ignore" needs hosts tagged "known" to actually serve them.
# Re-emit the dhcp-host lines with the known tag.
sed -i 's|^dhcp-host=\(.*\)|dhcp-host=\1,set:known|' /etc/dnsmasq.d/ocp-pxe.conf

# --------------------------------------------------------------------------
# 6. Firewall + SELinux
# --------------------------------------------------------------------------
echo "--- Firewall / SELinux ---"
firewall-cmd --permanent --add-service=dhcp
firewall-cmd --permanent --add-service=tftp
firewall-cmd --reload

# dnsmasq's tftp runs as the dnsmasq user. shim/grub from /boot/efi land at 0700
# (root-only) when copied — relax to o+r so the daemon can serve them.
chmod -R o+r /var/lib/tftpboot
find /var/lib/tftpboot -type d -exec chmod o+x {} \;
restorecon -R /var/lib/tftpboot 2>/dev/null || true

# --------------------------------------------------------------------------
# 7. Enable / restart dnsmasq
# --------------------------------------------------------------------------
echo "--- Enabling dnsmasq ---"
systemctl enable dnsmasq
systemctl restart dnsmasq
sleep 1
systemctl --no-pager status dnsmasq | head -12

# --------------------------------------------------------------------------
# 8. Set VM boot order: ethernet first, then disk (the RHCOS ISO is still
#    attached as a fallback; cdrom is left out of the order so it won't
#    re-trigger the installer on subsequent boots).
# --------------------------------------------------------------------------
echo "--- Setting vSphere boot order: ethernet,disk ---"
for VM in bootstrap master-m-0 master-m-1 master-m-2 worker-m-0 worker-m-1 worker-m-2; do
  govc device.boot -vm "${VCENTER_FOLDER}/${VM} (migrate)" \
    -order ethernet,disk -delay 2000 2>&1 \
    | sed "s/^/  ${VM}: /"
done

echo ""
echo "=== PXE setup complete ==="
echo ""
echo "TFTP root:  /var/lib/tftpboot"
echo "DHCP scope: ${NODE_NETWORK} (lab MACs only)"
echo "HTTP base:  ${HTTPD_BASE}"
echo ""
echo "Per-VM PXE configs (UEFI):"
ls -1 /var/lib/tftpboot/EFI/grub-cfg/ | sed 's/^/  /'
echo ""
echo "Next: set vSphere VM boot order to network-first, then power on the bootstrap VM."

#!/bin/bash
# Create all OCP VMs for the UPI install lab from scratch.
# VMs have a single NIC (no secondary NIC — no KubeVirt in this lab).
# RHCOS live ISO is attached to each VM's CD-ROM for first boot.
# After creation, MAC addresses are printed for DNS/DHCP reference.
#
# NOTE: Does NOT boot VMs. Boot order: bootstrap first, then masters, then workers.
#       Use pxe-install-and-boot.sh (or start-vms.sh + manual coreos-installer)
#       after running setup-pxe.sh.

set -euo pipefail

source /root/tools-upi-install/lab-config.sh
source /root/tools-upi-install/govc-env.sh

FOLDER="${VCENTER_FOLDER}"
DATASTORE="${VCENTER_DATASTORE}"
HOST="${VCENTER_HOST_TARGET}"
RESOURCE_POOL="${VCENTER_RESOURCE_POOL}"
NETWORK="/$(echo ${VCENTER_DATACENTER})/network/${VCENTER_NETWORK}"

# RHCOS live ISO — must have been uploaded to the datastore by upload-iso.sh.
# The install lab uses its OWN ISO subdirectory to keep it distinct from the
# migration lab's `_mdivis-migrate/`.
ISO_PATH="_mdivis-install/rhcos-live.iso"                 # « CHANGE-IF-NEEDED »

MASTER_CPU=8;  MASTER_MEM=16384;  MASTER_DISK=120
WORKER_CPU=8;  WORKER_MEM=16384;  WORKER_DISK=120
BOOTSTRAP_CPU=4; BOOTSTRAP_MEM=16384; BOOTSTRAP_DISK=120

# VM display names come from lab-config (VM_BOOTSTRAP, VM_MASTER0..2, VM_WORKER0..2).
# Each ends in `(install)` so the two labs never collide in the same vSphere folder.

# --------------------------------------------------------------------------
create_vm() {
  local FULL_NAME="$1"     # e.g. "bootstrap-i (install)"
  local CPU=$2
  local MEM=$3
  local DISK=$4

  echo ">>> Creating: ${FULL_NAME}"

  # Destroy existing VM if present. `govc vm.info` exits 0 even when the VM
  # doesn't exist (prints nothing) — check the output for "Name:" instead.
  if govc vm.info "${FOLDER}/${FULL_NAME}" 2>/dev/null | grep -q "^Name:"; then
    echo "    Existing VM found — destroying..."
    govc vm.power -off -force "${FOLDER}/${FULL_NAME}" 2>/dev/null || true
    govc vm.destroy "${FOLDER}/${FULL_NAME}"
  fi

  govc vm.create \
    -folder="${FOLDER}" \
    -ds="${DATASTORE}" \
    -host="${HOST}" \
    -pool="${RESOURCE_POOL}" \
    -net="${NETWORK}" \
    -c=${CPU} \
    -m=${MEM} \
    -disk="${DISK}GB" \
    -disk.controller=pvscsi \
    -net.adapter=vmxnet3 \
    -g=rhel9_64Guest \
    -firmware=efi \
    -on=false \
    "${FULL_NAME}"

  # Attach RHCOS live ISO to CD-ROM
  govc device.cdrom.add -vm "${FOLDER}/${FULL_NAME}" 2>/dev/null || true
  govc device.cdrom.insert \
    -vm "${FOLDER}/${FULL_NAME}" \
    -ds="${DATASTORE}" \
    "${ISO_PATH}"

  # disk.EnableUUID required for RHCOS (needed by OCP storage)
  govc vm.change \
    -vm "${FOLDER}/${FULL_NAME}" \
    -e="disk.EnableUUID=TRUE"

  echo "    Done: ${FULL_NAME}"
}
# --------------------------------------------------------------------------

# Create folder in vSphere if it doesn't exist
govc folder.create "${FOLDER}" 2>/dev/null || true

echo "=== Creating bootstrap VM ==="
create_vm "${VM_BOOTSTRAP}" ${BOOTSTRAP_CPU} ${BOOTSTRAP_MEM} ${BOOTSTRAP_DISK}

echo ""
echo "=== Creating master VMs ==="
for VM in "${VM_MASTER0}" "${VM_MASTER1}" "${VM_MASTER2}"; do
  create_vm "${VM}" ${MASTER_CPU} ${MASTER_MEM} ${MASTER_DISK}
done

echo ""
echo "=== Creating worker VMs ==="
for VM in "${VM_WORKER0}" "${VM_WORKER1}" "${VM_WORKER2}"; do
  create_vm "${VM}" ${WORKER_CPU} ${WORKER_MEM} ${WORKER_DISK}
done

# --------------------------------------------------------------------------
# Print MAC addresses
# --------------------------------------------------------------------------
echo ""
echo "=== MAC Addresses ==="
for VM in "${VM_BOOTSTRAP}" "${VM_MASTER0}" "${VM_MASTER1}" "${VM_MASTER2}" "${VM_WORKER0}" "${VM_WORKER1}" "${VM_WORKER2}"; do
  MAC=$(govc vm.info -json "${FOLDER}/${VM}" 2>/dev/null \
    | python3 -c "
import sys,json
d=json.load(sys.stdin)
devs=d['virtualMachines'][0]['config']['hardware']['device']
nics=[x for x in devs if 'macAddress' in x]
print(nics[0]['macAddress'] if nics else 'unknown')
" 2>/dev/null || echo "unknown")
  printf "  %-30s %s\n" "${VM}:" "${MAC}"
done

echo ""
echo "=== All VMs created ==="
echo ""
echo "Next steps:"
echo "  1. ./upload-iso.sh        — push RHCOS ISO to vSphere datastore"
echo "  2. ./setup-pxe.sh         — refresh dnsmasq per-MAC PXE configs"
echo "  3. ./pxe-install-and-boot.sh — orchestrated PXE install of all 7 VMs"
echo "  4. ./monitor-install.sh   — bootstrap → CSRs → install-complete"

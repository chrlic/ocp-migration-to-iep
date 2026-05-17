#!/bin/bash
# Create all OCP VMs for the UPI migration lab from scratch.
# VMs have a single NIC (no secondary NIC — no KubeVirt in this lab).
# RHCOS live ISO is attached to each VM's CD-ROM for first boot.
# After creation, MAC addresses are printed for DNS/DHCP reference.
#
# NOTE: Does NOT boot VMs. Boot order: bootstrap first, then masters, then workers.
#       Use start-vms.sh after RHCOS coreos-installer has been run on each.

set -euo pipefail

source /root/tools-upi-migrate/lab-config.sh
source /root/tools-upi-migrate/govc-env.sh

FOLDER="${VCENTER_FOLDER}"
DATASTORE="${VCENTER_DATASTORE}"
HOST="${VCENTER_HOST_TARGET}"
RESOURCE_POOL="${VCENTER_RESOURCE_POOL}"
NETWORK="/$(echo ${VCENTER_DATACENTER})/network/${VCENTER_NETWORK}"

# RHCOS live ISO — must have been uploaded to the datastore
# Update the path below to match where you uploaded it
ISO_PATH="_mdivis-migrate/rhcos-live.iso"               # « CHANGE »

MASTER_CPU=8;  MASTER_MEM=16384;  MASTER_DISK=120
WORKER_CPU=8;  WORKER_MEM=16384;  WORKER_DISK=120
BOOTSTRAP_CPU=4; BOOTSTRAP_MEM=16384; BOOTSTRAP_DISK=120

BOOTSTRAP_VMS=(bootstrap)
MASTER_VMS=(master-m-0 master-m-1 master-m-2)
WORKER_VMS=(worker-m-0 worker-m-1 worker-m-2)

# --------------------------------------------------------------------------
create_vm() {
  local NAME="$1"
  local CPU=$2
  local MEM=$3
  local DISK=$4
  local FULL_NAME="${NAME} (migrate)"

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
for VM in "${BOOTSTRAP_VMS[@]}"; do
  create_vm "${VM}" ${BOOTSTRAP_CPU} ${BOOTSTRAP_MEM} ${BOOTSTRAP_DISK}
done

echo ""
echo "=== Creating master VMs ==="
for VM in "${MASTER_VMS[@]}"; do
  create_vm "${VM}" ${MASTER_CPU} ${MASTER_MEM} ${MASTER_DISK}
done

echo ""
echo "=== Creating worker VMs ==="
for VM in "${WORKER_VMS[@]}"; do
  create_vm "${VM}" ${WORKER_CPU} ${WORKER_MEM} ${WORKER_DISK}
done

# --------------------------------------------------------------------------
# Print MAC addresses
# --------------------------------------------------------------------------
echo ""
echo "=== MAC Addresses ==="
for VM in bootstrap master-m-0 master-m-1 master-m-2 worker-m-0 worker-m-1 worker-m-2; do
  FULL="${VM} (migrate)"
  MAC=$(govc vm.info -json "${FOLDER}/${FULL}" 2>/dev/null \
    | python3 -c "
import sys,json
d=json.load(sys.stdin)
devs=d['virtualMachines'][0]['config']['hardware']['device']
nics=[x for x in devs if 'macAddress' in x]
print(nics[0]['macAddress'] if nics else 'unknown')
" 2>/dev/null || echo "unknown")
  printf "  %-12s %s\n" "${VM}:" "${MAC}"
done

echo ""
echo "=== All VMs created ==="
echo ""
echo "Next steps:"
echo "  1. Power on bootstrap VM: govc vm.power -on 'bootstrap (migrate)'"
echo "  2. Open VM console in vSphere — the RHCOS live system will boot"
echo "  3. In the RHCOS live shell, run coreos-installer:"
echo "       sudo coreos-installer install /dev/sda \\"
echo "         --ignition-url http://${BASTION_IP}:8080/ignition/bootstrap.ign \\"
echo "         --insecure-ignition && sudo reboot"
echo "  4. Repeat for masters (use master.ign) and workers (use worker.ign)"
echo "  5. Once all nodes have installed RHCOS and rebooted, run: ./monitor-install.sh"

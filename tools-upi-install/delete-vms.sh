#!/bin/bash
# Power off and destroy all VMs for the UPI install lab.

set -euo pipefail

source /root/tools-upi-install/lab-config.sh
source /root/tools-upi-install/govc-env.sh

FOLDER="${VCENTER_FOLDER}"

VMS=(
  "${VM_BOOTSTRAP}"
  "${VM_MASTER0}"
  "${VM_MASTER1}"
  "${VM_MASTER2}"
  "${VM_WORKER0}"
  "${VM_WORKER1}"
  "${VM_WORKER2}"
)

echo "=== Deleting UPI install lab VMs ==="

for VM in "${VMS[@]}"; do
  VMPATH="${FOLDER}/${VM}"
  if govc vm.info "${VMPATH}" &>/dev/null 2>&1; then
    echo "Deleting: ${VM}"
    govc vm.power -off -force "${VMPATH}" 2>/dev/null || true
    govc vm.destroy "${VMPATH}"
  else
    echo "Not found (skipping): ${VM}"
  fi
done

echo "Done."

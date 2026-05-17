#!/bin/bash
# Power off and destroy all VMs for the UPI migration lab.

set -euo pipefail

source /root/tools-upi-migrate/lab-config.sh
source /root/tools-upi-migrate/govc-env.sh

FOLDER="${VCENTER_FOLDER}"

VMS=(
  "bootstrap (migrate)"
  "master-m-0 (migrate)"
  "master-m-1 (migrate)"
  "master-m-2 (migrate)"
  "worker-m-0 (migrate)"
  "worker-m-1 (migrate)"
  "worker-m-2 (migrate)"
)

echo "=== Deleting UPI migration lab VMs ==="

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

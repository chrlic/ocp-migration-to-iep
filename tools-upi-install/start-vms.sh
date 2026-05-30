#!/bin/bash
# Power on VMs in the correct UPI boot order:
#   bootstrap first, then masters, then workers.
# Use this fallback if you bypass pxe-install-and-boot.sh — e.g. when each VM
# was already installed via console and just needs to be powered on in order.

set -uo pipefail

source /root/tools-upi-install/lab-config.sh
source /root/tools-upi-install/govc-env.sh

FOLDER="${VCENTER_FOLDER}"

echo "=== Starting bootstrap ==="
govc vm.power -on "${FOLDER}/${VM_BOOTSTRAP}"

echo "Waiting 60s for bootstrap to start etcd and API..."
sleep 60

echo "=== Starting masters ==="
for VM in "${VM_MASTER0}" "${VM_MASTER1}" "${VM_MASTER2}"; do
  echo "  Starting: ${VM}"
  govc vm.power -on "${FOLDER}/${VM}"
done

echo "Waiting 30s before starting workers..."
sleep 30

echo "=== Starting workers ==="
for VM in "${VM_WORKER0}" "${VM_WORKER1}" "${VM_WORKER2}"; do
  echo "  Starting: ${VM}"
  govc vm.power -on "${FOLDER}/${VM}"
done

echo ""
echo "All VMs started. Run ./monitor-install.sh to track progress."

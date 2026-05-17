#!/bin/bash
# Power on VMs in the correct UPI boot order:
#   bootstrap first, then masters, then workers.
# Run this after coreos-installer has been executed on each node
# and the VMs have been shut down (post-install reboot will come from the disk).

set -uo pipefail

source /root/tools-upi-migrate/lab-config.sh
source /root/tools-upi-migrate/govc-env.sh

FOLDER="${VCENTER_FOLDER}"

echo "=== Starting bootstrap ==="
govc vm.power -on "${FOLDER}/bootstrap (migrate)"

echo "Waiting 60s for bootstrap to start etcd and API..."
sleep 60

echo "=== Starting masters ==="
for VM in "master-m-0 (migrate)" "master-m-1 (migrate)" "master-m-2 (migrate)"; do
  echo "  Starting: ${VM}"
  govc vm.power -on "${FOLDER}/${VM}"
done

echo "Waiting 30s before starting workers..."
sleep 30

echo "=== Starting workers ==="
for VM in "worker-m-0 (migrate)" "worker-m-1 (migrate)" "worker-m-2 (migrate)"; do
  echo "  Starting: ${VM}"
  govc vm.power -on "${FOLDER}/${VM}"
done

echo ""
echo "All VMs started. Run ./monitor-install.sh to track progress."

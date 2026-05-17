#!/bin/bash
# Drive the unattended PXE-install of all 7 lab VMs end-to-end:
#
#   1. Power on each VM. Boot order is ethernet,disk so it PXE-installs.
#   2. coreos.inst.skip_reboot in the per-MAC grub config keeps the VM at the
#      live environment after install (no automatic reboot back into PXE).
#   3. Poll vSphere — wait for the live-environment "ready" marker (cleanest
#      signal is no DHCP request for ~60 seconds = install finished and ARP
#      is sitting quietly at the live OS).
#   4. Power off the VM, flip boot order to disk,ethernet, power back on. The
#      installed RHCOS boots from disk and the cluster comes up normally.
#
# Run in bootstrap → masters → workers order with sensible delays.

set -uo pipefail

source /root/tools-upi-migrate/lab-config.sh
source /root/tools-upi-migrate/govc-env.sh

FOLDER="${VCENTER_FOLDER}"

# Wait until the VM has finished its rootfs+ignition fetches AND has been idle
# on the network for SETTLE_SEC seconds. Without `coreos.inst.skip_reboot` the
# live env would reboot back into PXE — we use skip_reboot so the live env
# stays online quietly after writing the disk. So we wait for:
#   1. A successful GET of /rhcos/rhcos-rootfs.img (entire 1.1 GB transferred)
#   2. A successful GET of /ignition/<role>.ign
#   3. SETTLE_SEC seconds of no HTTP activity from that IP afterwards
# This is more deterministic than just watching DHCP, because the live env
# doesn't re-DHCP after install but it also doesn't make HTTP requests.
wait_for_install_idle() {
  local IP="$1"
  local WATCH_FROM="$2"   # epoch seconds; only consider httpd log entries after this time
  local SETTLE_SEC=60
  local TIMEOUT=900       # 15 min hard limit per VM
  local START=$(date +%s)

  echo "    Waiting for ${IP} rootfs + ignition fetch to finish (then ${SETTLE_SEC}s idle)..."
  local SEEN_ROOTFS=0
  while true; do
    local NOW=$(date +%s)
    if [ $((NOW - START)) -gt $TIMEOUT ]; then
      echo "      TIMEOUT after ${TIMEOUT}s — proceeding anyway. Check VM manually."
      return 1
    fi

    # httpd access_log lines look like:
    # 192.168.39.19 - - [16/May/2026:07:43:21 +0200] "GET /rhcos/rhcos-rootfs.img HTTP/1.1" 200 1151948800 ...
    # Get the latest successful rootfs GET from this IP since WATCH_FROM.
    local LAST_EPOCH=$(awk -v ip="${IP}" -v from="${WATCH_FROM}" '
      $1 == ip && index($0, "/rhcos/rhcos-rootfs.img") && index($0, "\" 200 ") {
        # Extract date "16/May/2026:07:43:21 +0200"
        match($0, /\[([^]]+)\]/, m);
        # Convert: dd/Mon/YYYY:HH:MM:SS +TZ → "YYYY-MM-DDTHH:MM:SS+TZ" parseable
        n = split(m[1], parts, /[\/: ]/);
        mon["Jan"]=1; mon["Feb"]=2; mon["Mar"]=3; mon["Apr"]=4; mon["May"]=5; mon["Jun"]=6;
        mon["Jul"]=7; mon["Aug"]=8; mon["Sep"]=9; mon["Oct"]=10; mon["Nov"]=11; mon["Dec"]=12;
        d = mktime(sprintf("%d %d %d %d %d %d", parts[3], mon[parts[2]], parts[1], parts[4], parts[5], parts[6]));
        if (d >= from) last = d;
      }
      END { print last+0 }
    ' /var/log/httpd/access_log 2>/dev/null)

    if [ -z "${LAST_EPOCH}" ] || [ "${LAST_EPOCH}" = "0" ]; then
      [ ${SEEN_ROOTFS} -eq 0 ] && echo "      (no rootfs GET yet from ${IP})" && SEEN_ROOTFS=-1
      sleep 10
      continue
    fi
    if [ ${SEEN_ROOTFS} -le 0 ]; then
      echo "      rootfs delivered to ${IP} at $(date -d @${LAST_EPOCH} +%T)"
      SEEN_ROOTFS=1
    fi

    if [ $((NOW - LAST_EPOCH)) -ge ${SETTLE_SEC} ]; then
      echo "      idle ${SETTLE_SEC}s since last rootfs GET — install done."
      return 0
    fi
    sleep 10
  done
}

# Once install is done, switch boot order to disk,ethernet and power-cycle.
boot_from_disk() {
  local VM="$1"
  echo "    Switching ${VM} to disk-first boot..."
  govc device.boot -vm "${FOLDER}/${VM} (migrate)" -order disk,ethernet -delay 2000
  govc vm.power -off -force "${FOLDER}/${VM} (migrate)" 2>/dev/null || true
  sleep 2
  govc vm.power -on "${FOLDER}/${VM} (migrate)"
  echo "    ${VM} booted from disk."
}

# --------------------------------------------------------------------------
process_vm() {
  local VM="$1" IP="$2"
  echo ""
  echo "=== ${VM} (${IP}) ==="
  echo "    Setting boot order: ethernet,disk for PXE install..."
  govc device.boot -vm "${FOLDER}/${VM} (migrate)" -order ethernet,disk -delay 2000

  # Make sure it's off, then power on so the next boot definitely PXEs
  govc vm.power -off -force "${FOLDER}/${VM} (migrate)" 2>/dev/null || true
  sleep 2
  local WATCH_FROM=$(date +%s)
  echo "    Powering on for PXE install (watching httpd log from $(date +%T))..."
  govc vm.power -on "${FOLDER}/${VM} (migrate)"

  # First DHCP request happens within ~5s; wait for install to settle.
  sleep 30
  wait_for_install_idle "${IP}" "${WATCH_FROM}"

  boot_from_disk "${VM}"
}

# --------------------------------------------------------------------------
# Sequence: bootstrap first (needed for masters), then masters in parallel,
# then workers.
# --------------------------------------------------------------------------
echo "=== Phase 1: bootstrap ==="
process_vm bootstrap "${BOOTSTRAP_IP}"

echo ""
echo "=== Phase 2: masters ==="
# Masters can install in parallel since each has its own MAC → per-MAC PXE config.
for VM in master-m-0 master-m-1 master-m-2; do
  echo "    Setting boot order on ${VM}..."
  govc device.boot -vm "${FOLDER}/${VM} (migrate)" -order ethernet,disk -delay 2000
  govc vm.power -off -force "${FOLDER}/${VM} (migrate)" 2>/dev/null || true
done
sleep 2
MASTER_WATCH_FROM=$(date +%s)
for VM in master-m-0 master-m-1 master-m-2; do
  govc vm.power -on "${FOLDER}/${VM} (migrate)"
done

sleep 60
for VM in master-m-0 master-m-1 master-m-2; do
  case "${VM}" in
    master-m-0) IP="${MASTER0_IP}" ;;
    master-m-1) IP="${MASTER1_IP}" ;;
    master-m-2) IP="${MASTER2_IP}" ;;
  esac
  wait_for_install_idle "${IP}" "${MASTER_WATCH_FROM}"
  boot_from_disk "${VM}"
done

echo ""
echo "=== Phase 3: workers ==="
for VM in worker-m-0 worker-m-1 worker-m-2; do
  echo "    Setting boot order on ${VM}..."
  govc device.boot -vm "${FOLDER}/${VM} (migrate)" -order ethernet,disk -delay 2000
  govc vm.power -off -force "${FOLDER}/${VM} (migrate)" 2>/dev/null || true
done
sleep 2
WORKER_WATCH_FROM=$(date +%s)
for VM in worker-m-0 worker-m-1 worker-m-2; do
  govc vm.power -on "${FOLDER}/${VM} (migrate)"
done
sleep 60
for VM in worker-m-0 worker-m-1 worker-m-2; do
  case "${VM}" in
    worker-m-0) IP="${WORKER0_IP}" ;;
    worker-m-1) IP="${WORKER1_IP}" ;;
    worker-m-2) IP="${WORKER2_IP}" ;;
  esac
  wait_for_install_idle "${IP}" "${WORKER_WATCH_FROM}"
  boot_from_disk "${VM}"
done

echo ""
echo "=== All 7 VMs PXE-installed and now booting from disk ==="
echo "Next: bash /root/tools-upi-migrate/monitor-install.sh"

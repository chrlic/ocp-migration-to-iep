#!/bin/bash
# Configure a SECOND HAProxy instance on the bastion (`haproxy-install`) for
# the install lab cluster. Frontends bind to ${API_VIP} = 192.168.39.30 only,
# so the migration lab's HAProxy (which binds on `*:6443` / `*:22623` / `*:80`
# / `*:443`) is undisturbed and continues to front the .20 traffic.
#
# This script does NOT touch /etc/haproxy/haproxy.cfg or the migration lab's
# haproxy.service. It writes:
#   - /etc/haproxy/haproxy-install.cfg
#   - /etc/systemd/system/haproxy-install.service
#
# Run once before starting the install cluster. After bootstrap-complete,
# run: remove-bootstrap-from-haproxy.sh

set -euo pipefail

source /root/tools-upi-install/lab-config.sh

echo "=== HAProxy Setup (install lab — second instance) ==="

# haproxy package presumably already installed by the migration lab.
rpm -q haproxy >/dev/null 2>&1 || dnf install -y haproxy

# --------------------------------------------------------------------------
# 1. Write /etc/haproxy/haproxy-install.cfg
# --------------------------------------------------------------------------
# All frontends bind to ${API_VIP} (192.168.39.30) — distinct from the
# migration lab's wildcard binds. Stats port is on a different port (1937)
# to avoid colliding with the migration lab's :1936.
cat > /etc/haproxy/haproxy-install.cfg <<EOF
global
    log         127.0.0.1 local2
    maxconn     4000
    daemon

defaults
    mode        tcp
    log         global
    option      tcplog
    option      redispatch
    retries     3
    timeout connect 10s
    timeout client  1m
    timeout server  1m

# ── Stats ──────────────────────────────────────────────────────────────────
frontend stats
    mode http
    bind ${API_VIP}:1937
    stats enable
    stats uri /
    stats refresh 5s

# ── API server (port 6443) — bootstrap + 3 masters ─────────────────────────
frontend api
    bind ${API_VIP}:6443
    default_backend api_backend

backend api_backend
    balance     roundrobin
    server bootstrap  ${BOOTSTRAP_IP}:6443  check
    server master-i-0 ${MASTER0_IP}:6443   check
    server master-i-1 ${MASTER1_IP}:6443   check
    server master-i-2 ${MASTER2_IP}:6443   check

# ── Machine Config server (port 22623) — bootstrap + 3 masters ─────────────
frontend mcs
    bind ${API_VIP}:22623
    default_backend mcs_backend

backend mcs_backend
    balance     roundrobin
    server bootstrap  ${BOOTSTRAP_IP}:22623  check
    server master-i-0 ${MASTER0_IP}:22623   check
    server master-i-1 ${MASTER1_IP}:22623   check
    server master-i-2 ${MASTER2_IP}:22623   check

# ── Ingress HTTP (port 80) — all 3 workers ─────────────────────────────────
frontend ingress_http
    bind ${INGRESS_VIP}:80
    default_backend ingress_http_backend

backend ingress_http_backend
    balance     roundrobin
    server worker-i-0 ${WORKER0_IP}:80   check
    server worker-i-1 ${WORKER1_IP}:80   check
    server worker-i-2 ${WORKER2_IP}:80   check

# ── Ingress HTTPS (port 443) — all 3 workers ───────────────────────────────
frontend ingress_https
    bind ${INGRESS_VIP}:443
    default_backend ingress_https_backend

backend ingress_https_backend
    balance     roundrobin
    server worker-i-0 ${WORKER0_IP}:443  check
    server worker-i-1 ${WORKER1_IP}:443  check
    server worker-i-2 ${WORKER2_IP}:443  check
EOF
echo "    Written /etc/haproxy/haproxy-install.cfg"

# --------------------------------------------------------------------------
# 2. Bring up the ${API_VIP} IP on the bastion's primary interface
# --------------------------------------------------------------------------
# HAProxy can only bind to an address that exists on a local interface.
# Use NetworkManager to add a secondary IP persistently to the connection
# carrying ${BASTION_IP} (so the address comes back after reboot).
echo "--- Adding ${API_VIP}/32 as a secondary IP on the bastion ---"
PRIMARY_CONN=$(nmcli -t -f NAME,DEVICE,STATE c show --active | awk -F: -v ip="${BASTION_IP}" '
  $3=="activated" {
    if (system("ip -4 addr show dev " $2 " | grep -q " ip) == 0) { print $1; exit }
  }')
if [ -z "${PRIMARY_CONN}" ]; then
  echo "    ERROR: could not find the NetworkManager connection holding ${BASTION_IP}"
  exit 1
fi
echo "    Found connection: ${PRIMARY_CONN}"
# Idempotent: nmcli ignores +ipv4.addresses if the address already present
nmcli c modify "${PRIMARY_CONN}" +ipv4.addresses "${API_VIP}/32"
nmcli c up "${PRIMARY_CONN}" >/dev/null
ip -4 addr show | grep -q "${API_VIP}" && echo "    ${API_VIP} is up on the bastion."

# --------------------------------------------------------------------------
# 3. SELinux + firewall
# --------------------------------------------------------------------------
# haproxy_connect_any is set by the migration lab; idempotent here.
setsebool -P haproxy_connect_any on

# Stats port 1937 + the standard OCP ports are already open from the
# migration lab; idempotent here.
firewall-cmd --permanent --add-port=1937/tcp 2>/dev/null || true
firewall-cmd --reload

# --------------------------------------------------------------------------
# 4. Drop-in systemd unit
# --------------------------------------------------------------------------
cat > /etc/systemd/system/haproxy-install.service <<EOF
[Unit]
Description=HAProxy Load Balancer (install lab)
After=network-online.target syslog.service
Wants=network-online.target

[Service]
Environment="OPTIONS="
EnvironmentFile=-/etc/sysconfig/haproxy-install
# Type=forking + 'daemon' in haproxy global section avoids sd_notify quirks
# that fail HAProxy 2.8 under Type=notify on RHEL 9. Pidfile is supplied on
# the command line only — putting it in global as well triggers an "already
# specified" parse error.
ExecStartPre=/usr/sbin/haproxy -f /etc/haproxy/haproxy-install.cfg -c -q
ExecStart=/usr/sbin/haproxy -f /etc/haproxy/haproxy-install.cfg -p /run/haproxy-install.pid \$OPTIONS
ExecReload=/usr/sbin/haproxy -f /etc/haproxy/haproxy-install.cfg -c -q
ExecReload=/bin/kill -USR2 \$MAINPID
PIDFile=/run/haproxy-install.pid
KillMode=mixed
SuccessExitStatus=143
Type=forking

[Install]
WantedBy=multi-user.target
EOF
echo "    Wrote /etc/systemd/system/haproxy-install.service"

systemctl daemon-reload
systemctl enable --now haproxy-install
systemctl --no-pager status haproxy-install | head -10

echo ""
echo "=== haproxy-install configured ==="
echo "API:     ${API_VIP}:6443  → bootstrap + 3 masters"
echo "MCS:     ${API_VIP}:22623 → bootstrap + 3 masters"
echo "Ingress: ${INGRESS_VIP}:80,443 → 3 workers"
echo "Stats:   http://${API_VIP}:1937/"
echo ""
echo "Migration lab's haproxy.service on *:6443/22623/80/443 is untouched."
echo "After bootstrap completes, run: remove-bootstrap-from-haproxy.sh"

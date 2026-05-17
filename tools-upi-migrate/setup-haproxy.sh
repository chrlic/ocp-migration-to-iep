#!/bin/bash
# Configure HAProxy on the bastion as the load balancer for:
#   - API server (port 6443): bootstrap + all four masters
#   - Machine Config server (port 22623): bootstrap + all four masters
#   - Ingress HTTP (port 80): all four workers
#   - Ingress HTTPS (port 443): all four workers
#
# Run once before starting the cluster.
# After bootstrap completes, run: remove-bootstrap-from-haproxy.sh

set -euo pipefail

source /root/tools-upi-migrate/lab-config.sh

echo "=== HAProxy Setup ==="

dnf install -y haproxy

cat > /etc/haproxy/haproxy.cfg <<EOF
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

# ── API server ─────────────────────────────────────────────────────────────
# bootstrap + masters (bootstrap entry removed after install completes)
frontend api
    bind *:6443
    default_backend api_backend

backend api_backend
    balance     roundrobin
    server bootstrap  ${BOOTSTRAP_IP}:6443  check
    server master-m-0 ${MASTER0_IP}:6443   check
    server master-m-1 ${MASTER1_IP}:6443   check
    server master-m-2 ${MASTER2_IP}:6443   check

# ── Machine Config server ──────────────────────────────────────────────────
frontend mcs
    bind *:22623
    default_backend mcs_backend

backend mcs_backend
    balance     roundrobin
    server bootstrap  ${BOOTSTRAP_IP}:22623 check
    server master-m-0 ${MASTER0_IP}:22623   check
    server master-m-1 ${MASTER1_IP}:22623   check
    server master-m-2 ${MASTER2_IP}:22623   check

# ── Ingress HTTP ───────────────────────────────────────────────────────────
frontend ingress_http
    bind *:80
    default_backend ingress_http_backend

backend ingress_http_backend
    balance     roundrobin
    server worker-m-0 ${WORKER0_IP}:80 check
    server worker-m-1 ${WORKER1_IP}:80 check
    server worker-m-2 ${WORKER2_IP}:80 check

# ── Ingress HTTPS ──────────────────────────────────────────────────────────
frontend ingress_https
    bind *:443
    default_backend ingress_https_backend

backend ingress_https_backend
    balance     roundrobin
    server worker-m-0 ${WORKER0_IP}:443 check
    server worker-m-1 ${WORKER1_IP}:443 check
    server worker-m-2 ${WORKER2_IP}:443 check
EOF

# SELinux: allow HAProxy to connect to any port
setsebool -P haproxy_connect_any=1

# Validate the merged config (haproxy.cfg + any drop-ins in conf.d/) before reloading
haproxy -c -f /etc/haproxy/haproxy.cfg -f /etc/haproxy/conf.d/

# enable + restart — restart (not just enable --now) so a previously-running
# HAProxy picks up the new haproxy.cfg. The TLS frontend from setup-artifactory.sh
# in /etc/haproxy/conf.d/ continues to be loaded by the stock systemd unit.
systemctl enable haproxy
systemctl restart haproxy
systemctl status haproxy --no-pager

# Open firewall ports
for PORT in 6443 22623 80 443; do
  firewall-cmd --permanent --add-port=${PORT}/tcp
done
firewall-cmd --reload

echo ""
echo "=== HAProxy configured ==="
echo "API:     ${BASTION_IP}:6443 → bootstrap + masters"
echo "MCS:     ${BASTION_IP}:22623 → bootstrap + masters"
echo "Ingress: ${BASTION_IP}:80,443 → workers"
echo ""
echo "After bootstrap completes, run: remove-bootstrap-from-haproxy.sh"

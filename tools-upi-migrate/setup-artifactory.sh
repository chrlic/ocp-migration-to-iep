#!/bin/bash
# Set up Nexus OSS as a pull-through proxy cache for OCP image registries.
# Run this once before generating ignition configs.
# After this script completes, PULL_SECRET_ART_FILE will contain Nexus credentials
# merged into the Red Hat pull secret — use that file in gen-ignition.sh.
#
# Architecture:
#   Nexus container (--network=host) listens on HTTP :8081.
#   HAProxy terminates TLS on :8443 and proxies to localhost:8081.
#   OCP nodes pull images via https://ARTIFACTORY_HOST:8443/<image>
#   HAProxy rewrites bare /v2/ paths to /repository/ocp-images/v2/ for Nexus.
#
# Note: "ARTIFACTORY_*" variable names are kept from lab-config.sh for compatibility.

set -euo pipefail

source /root/tools-upi-migrate/lab-config.sh

echo "=== Nexus OSS Setup ==="

# --------------------------------------------------------------------------
# 1. Persistent storage
# --------------------------------------------------------------------------
echo "--- Creating storage directory ---"
mkdir -p "${ARTIFACTORY_DATA_DIR}"
chown -R 200:200 "${ARTIFACTORY_DATA_DIR}"

# --------------------------------------------------------------------------
# 2. Start Nexus container
# --------------------------------------------------------------------------
echo "--- Starting Nexus OSS container ---"

podman rm -f nexus-migrate 2>/dev/null || true

# INSTALL4J_ADD_VM_PARAMS: Nexus uses Apache HttpClient which ignores JVM proxy
# env vars by default. These flags configure the proxy at the JVM level; the
# actual HTTP proxy is then set via the Nexus ExtDirect API after startup.
podman run -d \
  --name nexus-migrate \
  --restart=always \
  --network=host \
  -v "${ARTIFACTORY_DATA_DIR}:/nexus-data:Z" \
  -e "INSTALL4J_ADD_VM_PARAMS=-Xms2703m -Xmx2703m -XX:MaxDirectMemorySize=2703m \
-Dhttp.proxyHost=proxy.esl.cisco.com \
-Dhttp.proxyPort=80 \
-Dhttps.proxyHost=proxy.esl.cisco.com \
-Dhttps.proxyPort=80 \
-Dhttp.nonProxyHosts=localhost|127.0.0.1|10.*|192.168.*" \
  docker.io/sonatype/nexus3:latest

# Systemd unit for reboot survival (start/stop existing container; env is baked in)
cat > /etc/systemd/system/nexus-migrate.service <<SVC
[Unit]
Description=Nexus OSS (UPI migration lab)
After=network.target

[Service]
ExecStart=/usr/bin/podman start -a nexus-migrate
ExecStop=/usr/bin/podman stop nexus-migrate
Restart=on-failure

[Install]
WantedBy=multi-user.target
SVC
systemctl daemon-reload
systemctl enable nexus-migrate

# --------------------------------------------------------------------------
# 3. TLS certificate for HAProxy
# --------------------------------------------------------------------------
echo "--- Generating TLS certificate ---"
mkdir -p /etc/haproxy/certs

# Generate a dedicated CA (separate from the server cert so Go/curl chain verification works)
openssl genrsa -out /etc/haproxy/certs/ca.key 4096 2>/dev/null
openssl req -x509 -new -nodes -key /etc/haproxy/certs/ca.key -sha256 -days 3650 \
  -out /etc/haproxy/certs/ca.crt \
  -subj "/CN=Nexus Lab CA" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null

# Generate server cert signed by the CA
openssl genrsa -out /etc/haproxy/certs/nexus.key 4096 2>/dev/null
openssl req -new -key /etc/haproxy/certs/nexus.key \
  -out /tmp/nexus.csr \
  -subj "/CN=${ARTIFACTORY_HOST}" 2>/dev/null
cat > /tmp/nexus-ext.cnf <<EOF
[v3_server]
subjectAltName = DNS:${ARTIFACTORY_HOST},IP:${BASTION_IP}
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth,clientAuth
EOF
openssl x509 -req -in /tmp/nexus.csr \
  -CA /etc/haproxy/certs/ca.crt -CAkey /etc/haproxy/certs/ca.key -CAcreateserial \
  -days 3650 -extfile /tmp/nexus-ext.cnf -extensions v3_server \
  -out /etc/haproxy/certs/nexus.crt 2>/dev/null

# HAProxy pem: server cert + CA cert (chain) + server key
cat /etc/haproxy/certs/nexus.crt \
    /etc/haproxy/certs/ca.crt \
    /etc/haproxy/certs/nexus.key \
    > /etc/haproxy/artifactory.pem
chmod 600 /etc/haproxy/artifactory.pem

# --------------------------------------------------------------------------
# 4. HAProxy TLS frontend (port 8443 → localhost:8081)
# --------------------------------------------------------------------------
echo "--- Configuring HAProxy TLS frontend on port ${ARTIFACTORY_PORT} ---"

mkdir -p /etc/haproxy/conf.d
cat > /etc/haproxy/conf.d/artifactory.cfg <<HAPCFG
frontend artifactory_https
    bind *:${ARTIFACTORY_PORT} ssl crt /etc/haproxy/artifactory.pem alpn http/1.1
    mode http
    option httplog
    option forwardfor
    http-request set-header X-Forwarded-Proto https
    http-request set-header X-Forwarded-Port ${ARTIFACTORY_PORT}
    # Rewrite bare /v2 paths to /repository/ocp-images/v2 for Nexus path routing
    # Only rewrite if path does NOT already start with /repository/
    acl is_repo_path path_beg /repository/
    http-request replace-path ^/v2(/.*)?$ /repository/ocp-images/v2\1 if !is_repo_path
    default_backend artifactory_http

backend artifactory_http
    mode http
    option httpchk GET /service/rest/v1/status
    # Rewrite Nexus Bearer token realm URL from internal http://localhost:8081 to
    # the external HTTPS endpoint so clients can reach the token server.
    http-response replace-header WWW-Authenticate "Bearer realm=\"http://localhost:8081(/[^\"]+)\"(.*)" "Bearer realm=\"https://${ARTIFACTORY_HOST}:${ARTIFACTORY_PORT}\1\"\2"
    server nexus 127.0.0.1:8081 check
HAPCFG

# The stock CentOS 9 haproxy.service already loads /etc/haproxy/conf.d/ via
# $CFGDIR, so no systemd override is needed.
haproxy -c -f /etc/haproxy/haproxy.cfg -f /etc/haproxy/conf.d/artifactory.cfg

# Remove any stale override from earlier iterations of this script
rm -f /etc/systemd/system/haproxy.service.d/artifactory.conf
systemctl daemon-reload

# Restart unconditionally so a previously running HAProxy picks up the new conf
systemctl enable haproxy
systemctl restart haproxy

# Open firewall port for the HTTPS endpoint exposed to OCP nodes
firewall-cmd --permanent --add-port=${ARTIFACTORY_PORT}/tcp
firewall-cmd --reload

# SELinux: by default haproxy_t can only connect to a small set of ports.
# Enabling haproxy_connect_any lets HAProxy connect to Nexus on 8081 (labeled
# transproxy_port_t). Simpler than relabeling the port and persists across reboots.
setsebool -P haproxy_connect_any on

# --------------------------------------------------------------------------
# 5. Wait for Nexus to be ready
# --------------------------------------------------------------------------
echo "--- Waiting for Nexus to start (may take ~3 min on first boot) ---"
for i in $(seq 1 36); do
  if curl -s --noproxy "*" -o /dev/null -w "%{http_code}" \
      "http://localhost:8081/service/rest/v1/status" 2>/dev/null | grep -q "200"; then
    echo "    Nexus is up."
    break
  fi
  echo "    Attempt ${i}/36 — not ready yet..."
  sleep 10
done

# --------------------------------------------------------------------------
# 6. Trust Nexus TLS certificate on the bastion
# --------------------------------------------------------------------------
echo "--- Trusting Nexus CA on bastion ---"
\cp -f /etc/haproxy/certs/ca.crt \
   /etc/pki/ca-trust/source/anchors/artifactory-migrate.crt
update-ca-trust

# Install the CA for containers/image tools (skopeo, podman). These tools look up
# certs under /etc/containers/certs.d/<hostname>:<port>/ca.crt.
mkdir -p "/etc/containers/certs.d/${ARTIFACTORY_HOST}:${ARTIFACTORY_PORT}"
\cp -f /etc/haproxy/certs/ca.crt \
   "/etc/containers/certs.d/${ARTIFACTORY_HOST}:${ARTIFACTORY_PORT}/ca.crt"

# OpenSSL 3.x on CentOS 9 doesn't fully trust user-added CAs from the system
# pem bundle for curl. Set CURL_CA_BUNDLE so subsequent curl calls in this
# script use the CA directly.
export CURL_CA_BUNDLE=/etc/haproxy/certs/ca.crt
echo "    CA trusted."

# --------------------------------------------------------------------------
# 7. Accept EULA (required before Docker token endpoint works in Community)
# --------------------------------------------------------------------------
echo "--- Accepting Nexus Community Edition EULA ---"
NEXUS_INIT_PASS_EULA=$(cat "${ARTIFACTORY_DATA_DIR}/admin.password" 2>/dev/null || echo "admin")
curl -s --noproxy "*" -u "admin:${NEXUS_INIT_PASS_EULA}" \
  "http://localhost:8081/service/rest/v1/system/eula" | \
  python3 -c "
import sys, json
d = json.load(sys.stdin)
if d.get('disclaimer'):
    out = {'disclaimer': d['disclaimer'], 'accepted': True}
    with open('/tmp/nexus-eula.json', 'w') as f:
        json.dump(out, f)
    print('    EULA text retrieved.')
else:
    print('    No EULA required.')
" 2>/dev/null

if [ -f /tmp/nexus-eula.json ]; then
  curl -s --noproxy "*" -u "admin:${NEXUS_INIT_PASS_EULA}" \
    -X POST "http://localhost:8081/service/rest/v1/system/eula" \
    -H "Content-Type: application/json" \
    -d @/tmp/nexus-eula.json \
    -o /dev/null && echo "    EULA accepted."
  rm -f /tmp/nexus-eula.json
fi

# --------------------------------------------------------------------------
# 8. Set admin password
# --------------------------------------------------------------------------
echo "--- Setting admin password ---"
NEXUS_INIT_PASS=$(cat "${ARTIFACTORY_DATA_DIR}/admin.password" 2>/dev/null || echo "")
if [ -z "${NEXUS_INIT_PASS}" ]; then
  echo "    WARNING: admin.password not found — Nexus may not have finished initialising."
  echo "    Re-run this script or set the password manually via the UI."
else
  curl -s --noproxy "*" -u "admin:${NEXUS_INIT_PASS}" \
    -X PUT "http://localhost:8081/service/rest/v1/security/users/admin/change-password" \
    -H "Content-Type: text/plain" \
    -d "${ARTIFACTORY_PASS}" \
    && echo "    Password set." \
    || echo "    Password change failed — may already be set."
fi

# --------------------------------------------------------------------------
# 9. Configure outbound proxy for Nexus (via ExtDirect RPC)
# --------------------------------------------------------------------------
echo "--- Configuring Nexus outbound HTTP proxy ---"
curl -s --noproxy "*" -u "admin:${ARTIFACTORY_PASS}" \
  -X POST "http://localhost:8081/service/extdirect" \
  -H "Content-Type: application/json" \
  -d '{
    "action": "coreui_HttpSettings",
    "method": "update",
    "data": [{
      "httpEnabled": true,
      "httpHost": "proxy.esl.cisco.com",
      "httpPort": 80,
      "httpAuthEnabled": false,
      "httpAuthUsername": null,
      "httpAuthPassword": null,
      "httpsEnabled": true,
      "httpsHost": "proxy.esl.cisco.com",
      "httpsPort": 80,
      "httpsAuthEnabled": false,
      "httpsAuthUsername": null,
      "httpsAuthPassword": null,
      "nonProxyHosts": ["localhost","127.0.0.1","10.*","192.168.*"]
    }],
    "type": "rpc",
    "tid": 1
  }' | python3 -c "
import sys, json
d = json.load(sys.stdin)
if d.get('result',{}).get('success'):
    print('    Proxy configured.')
else:
    print('    WARNING: proxy config failed:', json.dumps(d)[:200])
" 2>/dev/null || echo "    WARNING: proxy config call failed"

# --------------------------------------------------------------------------
# 10. Create remote (proxy) repositories
# --------------------------------------------------------------------------
echo "--- Creating remote repositories ---"

# Extract credentials from pull secret
if [ ! -f "${PULL_SECRET_FILE}" ]; then
  echo "ERROR: ${PULL_SECRET_FILE} not found. Place your Red Hat pull secret there first."
  exit 1
fi

get_creds() {
  local registry="$1"
  python3 -c "
import json, base64
with open('${PULL_SECRET_FILE}') as f:
    d = json.load(f)
auth_b64 = d['auths']['${registry}']['auth']
print(base64.b64decode(auth_b64).decode())
" 2>/dev/null
}

RH_AUTH=$(get_creds "registry.redhat.io")
RH_USER=$(echo "${RH_AUTH}" | cut -d: -f1)
RH_PASS=$(echo "${RH_AUTH}" | cut -d: -f2-)

CONNECT_AUTH=$(get_creds "registry.connect.redhat.com")
CONNECT_USER=$(echo "${CONNECT_AUTH}" | cut -d: -f1)
CONNECT_PASS=$(echo "${CONNECT_AUTH}" | cut -d: -f2-)

QUAY_AUTH=$(get_creds "quay.io")
QUAY_USER=$(echo "${QUAY_AUTH}" | cut -d: -f1)
QUAY_PASS=$(echo "${QUAY_AUTH}" | cut -d: -f2-)

create_proxy_repo() {
  local NAME="$1" URL="$2" INDEX_TYPE="${3:-REGISTRY}" INDEX_URL="${4:-}"
  local USER="${5:-}" PASS="${6:-}"

  # Write args to a temp file so Python reads them safely (avoids shell quoting
  # issues with JWTs containing newlines, quotes, or backslashes)
  printf '%s' "${NAME}"       > /tmp/nx-arg-name
  printf '%s' "${URL}"        > /tmp/nx-arg-url
  printf '%s' "${INDEX_TYPE}" > /tmp/nx-arg-itype
  printf '%s' "${INDEX_URL:-${URL}}" > /tmp/nx-arg-iurl
  printf '%s' "${USER}"       > /tmp/nx-arg-user
  printf '%s' "${PASS}"       > /tmp/nx-arg-pass

  python3 - > /tmp/nx-create.json <<'PYEOF'
import json

def read(path):
    with open(path) as f:
        return f.read().strip()

name       = read('/tmp/nx-arg-name')
url        = read('/tmp/nx-arg-url')
index_type = read('/tmp/nx-arg-itype')
index_url  = read('/tmp/nx-arg-iurl') or url
user       = read('/tmp/nx-arg-user')
passwd     = read('/tmp/nx-arg-pass')

httpclient = {"blocked": False, "autoBlock": False,
              "connection": {"retries": None, "timeout": None,
                             "enableCircularRedirects": False,
                             "enableCookies": False, "useTrustStore": False}}
if user:
    httpclient["authentication"] = {"type": "username",
                                    "username": user, "password": passwd}

docker_proxy = {"indexType": index_type, "foreignLayerUrlWhitelist": []}
if index_type in ("REGISTRY", "CUSTOM"):
    docker_proxy["indexUrl"] = index_url

payload = {
    "name": name, "online": True,
    "storage": {"blobStoreName": "default", "strictContentTypeValidation": True},
    "proxy": {"remoteUrl": url, "contentMaxAge": 1440, "metadataMaxAge": 1440},
    "negativeCache": {"enabled": False, "timeToLive": 1440},
    "httpClient": httpclient,
    "docker": {"v1Enabled": False, "forceBasicAuth": False},
    "dockerProxy": docker_proxy,
}
print(json.dumps(payload))
PYEOF

  HTTP=$(curl -s --noproxy "*" -u "admin:${ARTIFACTORY_PASS}" \
    -o /tmp/nx-resp.txt -w "%{http_code}" \
    -X POST "http://localhost:8081/service/rest/v1/repositories/docker/proxy" \
    -H "Content-Type: application/json" \
    -d @/tmp/nx-create.json)
  echo "    ${NAME}: HTTP ${HTTP}"
  if [ "${HTTP}" != "201" ]; then cat /tmp/nx-resp.txt; echo ""; fi
}

# quay.io — OCP release images + Isovalent images (requires pull secret quay.io creds)
create_proxy_repo "remote-quay" "https://quay.io" "REGISTRY" "" "${QUAY_USER}" "${QUAY_PASS}"

# docker.io — community images.
# IMPORTANT: Docker Hub rate-limits anonymous IPs to 100 pulls / 6h (`TOOMANYREQUESTS`).
# In a lab where many pods share the bastion's NAT egress that quota is exhausted
# almost immediately. Use an authenticated Docker Hub PAT (free tier raises the
# limit to 200 pulls/6h per account). Generate at https://hub.docker.com/settings/security
# with at least 'Public Repo Read' scope.
create_proxy_repo "remote-dockerhub" "https://registry-1.docker.io" \
  "" "" "${DOCKERHUB_USER}" "${DOCKERHUB_PASS}"

# registry.redhat.io — uses CUSTOM indexType with correct service= parameter
# Nexus defaults to service="registry.redhat.io" but RHCC token server requires service="docker-registry"
create_proxy_repo "remote-redhat" "https://registry.redhat.io" \
  "CUSTOM" "https://registry.redhat.io/auth/realms/rhcc/protocol/redhat-docker-v2/auth?service=docker-registry" \
  "${RH_USER}" "${RH_PASS}"

# registry.connect.redhat.com — same token server quirk
create_proxy_repo "remote-connect" "https://registry.connect.redhat.com" \
  "CUSTOM" "https://registry.connect.redhat.com/auth/realms/rhcc/protocol/redhat-docker-v2/auth?service=docker-registry" \
  "${CONNECT_USER}" "${CONNECT_PASS}"

# registry.k8s.io — Kubernetes SIG images (nfs-subdir-external-provisioner,
# local-storage, etc.). Public, no auth.
create_proxy_repo "remote-k8s" "https://registry.k8s.io"

# --------------------------------------------------------------------------
# 11. Create Docker group repository
# --------------------------------------------------------------------------
echo "--- Creating group repository: ${ARTIFACTORY_OCP_REPO} ---"
HTTP=$(curl -s --noproxy "*" -u "admin:${ARTIFACTORY_PASS}" \
  -o /tmp/nx-resp.txt -w "%{http_code}" \
  -X POST "http://localhost:8081/service/rest/v1/repositories/docker/group" \
  -H "Content-Type: application/json" \
  -d "{
    \"name\": \"${ARTIFACTORY_OCP_REPO}\",
    \"online\": true,
    \"storage\": {\"blobStoreName\": \"default\", \"strictContentTypeValidation\": true},
    \"group\": {
      \"memberNames\": [\"remote-quay\", \"remote-redhat\", \"remote-connect\", \"remote-dockerhub\", \"remote-k8s\"]
    },
    \"docker\": {\"v1Enabled\": false, \"forceBasicAuth\": true, \"pathEnabled\": true}
  }")
echo "    ${ARTIFACTORY_OCP_REPO}: HTTP ${HTTP}"
if [ "${HTTP}" != "201" ]; then cat /tmp/nx-resp.txt; echo ""; fi

# Set nexus.base-url so Nexus generates correct URLs in API responses
echo "nexus.base-url=https://${ARTIFACTORY_HOST}:${ARTIFACTORY_PORT}" \
  >> "${ARTIFACTORY_DATA_DIR}/etc/nexus.properties"

# --------------------------------------------------------------------------
# 12. Merge Nexus credentials into pull secret
# --------------------------------------------------------------------------
echo "--- Merging Nexus credentials into pull secret ---"

ART_AUTH_B64=$(echo -n "${ARTIFACTORY_USER}:${ARTIFACTORY_PASS}" | base64 -w0)
jq --arg host "${ARTIFACTORY_HOST}:${ARTIFACTORY_PORT}" \
   --arg auth "${ART_AUTH_B64}" \
   '.auths[$host] = {"auth": $auth}' \
   "${PULL_SECRET_FILE}" > "${PULL_SECRET_ART_FILE}"
echo "    Written: ${PULL_SECRET_ART_FILE}"

# --------------------------------------------------------------------------
# 13. Add Nexus hostname to no_proxy so local tools bypass the corporate proxy
# --------------------------------------------------------------------------
if ! grep -q "${ARTIFACTORY_HOST}" /etc/profile.d/proxy.sh 2>/dev/null; then
  sed -i "s/^no_proxy=\"\(.*\)\"/no_proxy=\"\1,${ARTIFACTORY_HOST}\"/" /etc/profile.d/proxy.sh
  echo "    Added ${ARTIFACTORY_HOST} to /etc/profile.d/proxy.sh no_proxy."
fi

# --------------------------------------------------------------------------
# 14. Smoke test
# --------------------------------------------------------------------------
echo ""
echo "=== Smoke Test ==="
echo "Nexus status (HTTPS via HAProxy):"
curl -sk --noproxy "*" -u "admin:${ARTIFACTORY_PASS}" \
  -o /dev/null -w "  HTTP %{http_code}\n" \
  "https://${ARTIFACTORY_HOST}:${ARTIFACTORY_PORT}/service/rest/v1/status"

echo "Docker v2 API (via HAProxy, bare path):"
curl -sk --noproxy "${ARTIFACTORY_HOST}" \
  -u "admin:${ARTIFACTORY_PASS}" \
  -o /dev/null -w "  HTTP %{http_code}\n" \
  "https://${ARTIFACTORY_HOST}:${ARTIFACTORY_PORT}/v2/"

echo "Repositories:"
curl -s --noproxy "*" -u "admin:${ARTIFACTORY_PASS}" \
  "http://localhost:8081/service/rest/v1/repositories" \
  | python3 -c "
import sys, json
for r in json.load(sys.stdin):
    if r['format'] == 'docker':
        print('  ', r['name'], '(' + r['type'] + ')')
"

echo ""
echo "=== Nexus setup complete ==="
echo "URL:         https://${ARTIFACTORY_HOST}:${ARTIFACTORY_PORT}"
echo "Pull secret: ${PULL_SECRET_ART_FILE}"
echo ""
echo "Image pull (from OCP nodes): ${ARTIFACTORY_HOST}:${ARTIFACTORY_PORT}/<image>"
echo "(HAProxy rewrites /v2/... → /repository/${ARTIFACTORY_OCP_REPO}/v2/...)"
echo ""
echo "Next: run gen-ignition.sh"

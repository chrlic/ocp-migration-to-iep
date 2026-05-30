#!/bin/bash
# Generate OCP UPI ignition configs for a FRESH install with Isovalent
# Networking for Kubernetes (Cilium) as the CNI — no OVN, no migration.
#
# Differences vs the migration lab's gen-ignition.sh:
#   - install-config.yaml uses `networkType: Cilium` directly
#   - cluster-network-02-config.yml is patched to also set deployKubeProxy: false
#   - CLife tarball contents (ciliumconfig.yaml, subscription.yaml, controller-manager
#     Deployment, RBAC, CRD, etc.) are dropped into `manifests/` so bootkube applies
#     them at bootstrap time. The cluster comes up with Cilium from day one.
#   - ciliumconfig.yaml is customized BEFORE being copied into manifests/, so the
#     bootstrap-time render already has the lab's pod CIDR + KPR + k8sServiceHost.
#
# Steps:
#   1. Sanity-check prerequisites (pull secret, SSH key, CLife tarball)
#   2. Download + extract CLife tarball if not already present
#   3. Customize the 3 CLife manifests (ciliumconfig, controller-manager, subscription)
#   4. Write install-config.yaml with networkType: Cilium
#   5. Generate manifests (`openshift-install create manifests`)
#   6. Patch cluster-network-02-config.yml to add deployKubeProxy: false
#   7. Patch Scheduler manifest (mastersSchedulable: false)
#   8. Write IDMS + ITMS as two separate files under openshift/
#   9. Write CA-trust MachineConfig under openshift/
#  10. Write IngressController (HostNetwork, worker-only) under openshift/
#  11. Copy customized CLife manifests into manifests/
#  12. Generate ignition configs
#  13. Publish ignition files to httpd
#
# Prerequisite: setup-artifactory.sh on the bastion has already created
# ${PULL_SECRET_ART_FILE} (shared with the migration lab).

set -euo pipefail

source /root/tools-upi-install/lab-config.sh

echo "=== Generating UPI Ignition Configs — FRESH INSTALL with Cilium ==="

if [ ! -f "${PULL_SECRET_ART_FILE}" ]; then
  echo "ERROR: ${PULL_SECRET_ART_FILE} not found."
  echo "       This lab reuses the migration lab's Nexus + pull-secret."
  echo "       Run /root/tools-upi-migrate/setup-artifactory.sh first."
  exit 1
fi

if [ ! -f "${SSH_KEY_FILE}" ]; then
  echo "SSH key not found at ${SSH_KEY_FILE} — generating..."
  ssh-keygen -t ed25519 -f "${SSH_KEY_FILE%.pub}" -N ""
fi

# --------------------------------------------------------------------------
# 1. Download + extract CLife tarball (if not already done in Section 6 manually)
# --------------------------------------------------------------------------
if [ ! -d "${CLIFE_DIR}" ] || [ -z "$(ls -A "${CLIFE_DIR}" 2>/dev/null)" ]; then
  echo "--- Downloading CLife tarball ${CLIFE_TARBALL} ---"
  mkdir -p "${CLIFE_DIR}"
  TARBALL_PATH="/root/${CLIFE_TARBALL}"
  if [ ! -f "${TARBALL_PATH}" ]; then
    curl -fL -o "${TARBALL_PATH}" "${CLIFE_URL}"
    sha256sum "${TARBALL_PATH}" | tee "${TARBALL_PATH}.sha256"
  fi
  tar -xzf "${TARBALL_PATH}" -C "${CLIFE_DIR}"
  echo "    Extracted to ${CLIFE_DIR}"
fi

# --------------------------------------------------------------------------
# 2. Customize CiliumConfig — full-replacement KPR=true, pod CIDR from lab-config
# --------------------------------------------------------------------------
echo "--- Customizing CiliumConfig (KPR=true, pod CIDR ${CILIUM_CLUSTER_CIDR}) ---"
CILIUMCONFIG_FILE=$(find "${CLIFE_DIR}" -name "ciliumconfig.yaml" | head -1)
[ -z "${CILIUMCONFIG_FILE}" ] && { echo "ERROR: ciliumconfig.yaml not in CLife tarball"; exit 1; }
[ ! -f "${CILIUMCONFIG_FILE}.orig" ] && cp "${CILIUMCONFIG_FILE}" "${CILIUMCONFIG_FILE}.orig"

cat > "${CILIUMCONFIG_FILE}" <<EOF
apiVersion: cilium.io/v1alpha1
kind: CiliumConfig
metadata:
  name: ciliumconfig
  namespace: cilium
  labels:
    app.kubernetes.io/name: clife
spec:
  securityContext:
    privileged: true
  ipam:
    mode: "cluster-pool"
    operator:
      clusterPoolIPv4PodCIDRList:
        - "${CILIUM_CLUSTER_CIDR}"
      clusterPoolIPv4MaskSize: ${CILIUM_HOST_PREFIX}
  cni:
    binPath: "/var/lib/cni/bin"
    confPath: "/var/run/multus/cni/net.d"
    exclusive: false
  prometheus:
    enabled: true
    serviceMonitor:
      enabled: true
  hubble:
    enabled: true
    serviceMonitor:
      enabled: true
    metrics:
      enabled:
        - dns:labelsContext=source_namespace,destination_namespace
        - drop:labelsContext=source_namespace,destination_namespace
        - tcp:labelsContext=source_namespace,destination_namespace
        - icmp:labelsContext=source_namespace,destination_namespace
        - flow:labelsContext=source_namespace,destination_namespace;sourceContext=workload-name|reserved-identity;destinationContext=workload-name|reserved-identity
        - "httpV2:exemplars=true;labelsContext=source_ip,source_namespace,source_workload,destination_ip,destination_namespace,destination_workload,traffic_direction;sourceContext=workload-name|reserved-identity;destinationContext=workload-name|reserved-identity"
        - flow_export
  operator:
    prometheus:
      enabled: true
      serviceMonitor:
        enabled: true
  sessionAffinity: true
  kubeProxyReplacement: "true"
  k8sServiceHost: "${K8S_API_HOST}"
  k8sServicePort: ${K8S_API_PORT}
  clusterHealthPort: 9940
  tunnelPort: 4789
EOF
# NOTE: no `devices:` here — fresh install has no OVS bridges to coexist with.
# Cilium auto-detects the primary NIC during bootstrap.
echo "    Customized."

# --------------------------------------------------------------------------
# 3. Customize CLife controller-manager Deployment (inject API host/port env)
# --------------------------------------------------------------------------
echo "--- Customizing clife-controller-manager Deployment ---"
MANAGER_FILE=$(find "${CLIFE_DIR}" -name "apps_v1_deployment_clife-controller-manager.yaml" | head -1)
[ ! -f "${MANAGER_FILE}.orig" ] && cp "${MANAGER_FILE}" "${MANAGER_FILE}.orig"
yq -i "(.spec.template.spec.containers[] | select(.name == \"manager\")).env += [
  {\"name\": \"KUBERNETES_SERVICE_HOST\", \"value\": \"${K8S_API_HOST}\"},
  {\"name\": \"KUBERNETES_SERVICE_PORT\", \"value\": \"${K8S_API_PORT}\"}
]" "${MANAGER_FILE}"
echo "    Customized."

# --------------------------------------------------------------------------
# 4. Customize OLM Subscription (inject API host/port env)
# --------------------------------------------------------------------------
echo "--- Customizing CLife Subscription ---"
SUBSCRIPTION_FILE=$(find "${CLIFE_DIR}" -name "subscription.yaml" | head -1)
[ ! -f "${SUBSCRIPTION_FILE}.orig" ] && cp "${SUBSCRIPTION_FILE}" "${SUBSCRIPTION_FILE}.orig"
yq -i ".spec.config.env = [
  {\"name\": \"KUBERNETES_SERVICE_HOST\", \"value\": \"${K8S_API_HOST}\"},
  {\"name\": \"KUBERNETES_SERVICE_PORT\", \"value\": \"${K8S_API_PORT}\"}
]" "${SUBSCRIPTION_FILE}"
echo "    Customized."

# --------------------------------------------------------------------------
# 5. Prepare install directory
# --------------------------------------------------------------------------
echo "--- Preparing install directory: ${INSTALL_DIR} ---"
mkdir -p "${INSTALL_DIR}/openshift"
mkdir -p "${INSTALL_DIR}/ignition"

# --------------------------------------------------------------------------
# 6. Write install-config.yaml — networkType: Cilium for fresh install
# --------------------------------------------------------------------------
echo "--- Writing install-config.yaml (networkType: Cilium) ---"
ART_REPO="${ARTIFACTORY_HOST}:${ARTIFACTORY_PORT}"
# CA chain is shared with the migration lab — same Nexus, same cert.
ART_CA=$(sed 's/^/    /' /etc/haproxy/certs/ca.crt)

cat > "${INSTALL_DIR}/install-config.yaml" <<EOF
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
metadata:
  name: ${CLUSTER_NAME}
compute:
  - architecture: amd64
    hyperthreading: Enabled
    name: worker
    replicas: 0
controlPlane:
  architecture: amd64
  hyperthreading: Enabled
  name: master
  replicas: 3
networking:
  clusterNetwork:
    - cidr: ${POD_CIDR}
      hostPrefix: ${POD_HOST_PREFIX}
  machineNetwork:
    - cidr: ${NODE_NETWORK}
  networkType: Cilium
  serviceNetwork:
    - ${SERVICE_CIDR}
platform:
  none: {}
fips: false
pullSecret: '$(cat "${PULL_SECRET_ART_FILE}")'
sshKey: '$(cat "${SSH_KEY_FILE}")'
imageContentSources:
- mirrors:
  - ${ART_REPO}/openshift-release-dev
  source: quay.io/openshift-release-dev
- mirrors:
  - ${ART_REPO}
  source: registry.redhat.io
- mirrors:
  - ${ART_REPO}
  source: registry.connect.redhat.com
- mirrors:
  - ${ART_REPO}/isovalent
  source: quay.io/isovalent
- mirrors:
  - ${ART_REPO}
  source: quay.io
- mirrors:
  - ${ART_REPO}
  source: docker.io
- mirrors:
  - ${ART_REPO}
  source: registry.k8s.io
additionalTrustBundle: |
${ART_CA}
EOF

cp "${INSTALL_DIR}/install-config.yaml" "${INSTALL_DIR}/install-config.yaml.bak"
echo "    Written and backed up."

# --------------------------------------------------------------------------
# 7. Generate manifests (install-config.yaml is consumed here)
# --------------------------------------------------------------------------
echo "--- Generating manifests ---"
openshift-install create manifests --dir "${INSTALL_DIR}"

# --------------------------------------------------------------------------
# 8. Patch cluster-network-02-config.yml — add deployKubeProxy: false
# --------------------------------------------------------------------------
# `networkType: Cilium` already propagates from install-config. With KPR=true
# the OCP network operator must NOT deploy its own kube-proxy DaemonSet —
# Cilium takes that role.
echo "--- Patching cluster-network-02-config.yml (deployKubeProxy=false) ---"
NETCONFIG="${INSTALL_DIR}/manifests/cluster-network-02-config.yml"
if [ -f "${NETCONFIG}" ]; then
  # Use yq to inject deployKubeProxy under spec — preserve everything else.
  yq -i '.spec.deployKubeProxy = false' "${NETCONFIG}"
  echo "    Patched: ${NETCONFIG}"
  grep -E "networkType|deployKubeProxy" "${NETCONFIG}" | sed 's/^/      /'
else
  echo "    WARNING: ${NETCONFIG} not found"
fi

# --------------------------------------------------------------------------
# 9. Patch Scheduler manifest (mastersSchedulable=false)
# --------------------------------------------------------------------------
# When compute.replicas: 0 (UPI), the installer defaults Scheduler.mastersSchedulable=true,
# which auto-labels masters with node-role.kubernetes.io/worker="". That makes
# the IngressController nodeSelector match masters AND workers — routers can
# end up on masters and HAProxy ingress backends to actual workers stay DOWN.
# Setting mastersSchedulable=false strips the worker label from masters.
echo "--- Patching Scheduler manifest (mastersSchedulable=false) ---"
SCHED_FILE="${INSTALL_DIR}/manifests/cluster-scheduler-02-config.yml"
if [ -f "${SCHED_FILE}" ]; then
  sed -i 's/mastersSchedulable: true/mastersSchedulable: false/' "${SCHED_FILE}"
  echo "    Patched."
fi

# --------------------------------------------------------------------------
# 10. Write IDMS + ITMS as SEPARATE files (one resource per file under openshift/)
# --------------------------------------------------------------------------
# See [[feedback-ocp-upi-idms-itms]] in memory for the lesson.
echo "--- Writing IDMS + ITMS (two files) ---"
cat > "${INSTALL_DIR}/openshift/99-artifactory-idms.yaml" <<EOF
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: artifactory-digest-mirror
spec:
  imageDigestMirrors:
  - mirrors:
    - ${ART_REPO}/openshift-release-dev
    source: quay.io/openshift-release-dev
  - mirrors:
    - ${ART_REPO}
    source: registry.redhat.io
  - mirrors:
    - ${ART_REPO}
    source: registry.connect.redhat.com
  - mirrors:
    - ${ART_REPO}/isovalent
    source: quay.io/isovalent
  - mirrors:
    - ${ART_REPO}
    source: quay.io
  - mirrors:
    - ${ART_REPO}
    source: docker.io
  - mirrors:
    - ${ART_REPO}
    source: registry.k8s.io
EOF
echo "    Written: ${INSTALL_DIR}/openshift/99-artifactory-idms.yaml"

cat > "${INSTALL_DIR}/openshift/99-artifactory-itms.yaml" <<EOF
apiVersion: config.openshift.io/v1
kind: ImageTagMirrorSet
metadata:
  name: artifactory-tag-mirror
spec:
  imageTagMirrors:
  - mirrors:
    - ${ART_REPO}/openshift-release-dev
    source: quay.io/openshift-release-dev
  - mirrors:
    - ${ART_REPO}
    source: registry.redhat.io
  - mirrors:
    - ${ART_REPO}
    source: registry.connect.redhat.com
  - mirrors:
    - ${ART_REPO}/isovalent
    source: quay.io/isovalent
  - mirrors:
    - ${ART_REPO}
    source: quay.io
  - mirrors:
    - ${ART_REPO}
    source: docker.io
  - mirrors:
    - ${ART_REPO}
    source: registry.k8s.io
EOF
echo "    Written: ${INSTALL_DIR}/openshift/99-artifactory-itms.yaml"

# --------------------------------------------------------------------------
# 11. Write MachineConfig to trust Artifactory CA on every node
# --------------------------------------------------------------------------
# Trust the CA cert (which signed the server cert), not the leaf — chain validation
# requires the CA in /etc/pki/ca-trust/source/anchors on every node.
echo "--- Writing MachineConfig for Artifactory CA trust ---"
ART_CA_B64=$(base64 -w0 /etc/haproxy/certs/ca.crt)
for ROLE in worker master; do
  cat > "${INSTALL_DIR}/openshift/99-${ROLE}-artifactory-ca.yaml" <<EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: ${ROLE}
  name: 99-${ROLE}-artifactory-ca
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
        - path: /etc/pki/ca-trust/source/anchors/artifactory-install.crt
          mode: 0644
          contents:
            source: "data:text/plain;base64,${ART_CA_B64}"
EOF
  echo "    Written: ${INSTALL_DIR}/openshift/99-${ROLE}-artifactory-ca.yaml"
done

# --------------------------------------------------------------------------
# 12. IngressController — HostNetwork on worker nodes
# --------------------------------------------------------------------------
echo "--- Writing IngressController (HostNetwork, worker-only) ---"
cat > "${INSTALL_DIR}/openshift/99-cluster-ingress-default.yaml" <<EOF
apiVersion: operator.openshift.io/v1
kind: IngressController
metadata:
  name: default
  namespace: openshift-ingress-operator
spec:
  replicas: 2
  endpointPublishingStrategy:
    type: HostNetwork
    hostNetwork:
      protocol: TCP
      httpPort: 80
      httpsPort: 443
      statsPort: 1936
  nodePlacement:
    nodeSelector:
      matchLabels:
        node-role.kubernetes.io/worker: ""
EOF

# --------------------------------------------------------------------------
# 13. Copy CLife manifests into manifests/ — bootkube applies them at bootstrap
# --------------------------------------------------------------------------
# Per the IEP install doc: "Copy the prepared manifests from the temporary
# clife-tmp directory into manifests". Bootkube loads everything in manifests/
# at cluster bring-up, so Cilium is up before the first OCP control-plane pod
# starts looking for a CNI.
#
# IMPORTANT: the *.orig backup files we kept in CLIFE_DIR must NOT be copied,
# otherwise bootkube would try to apply them as resources too. Filter explicitly.
echo "--- Copying CLife manifests into manifests/ ---"
for f in "${CLIFE_DIR}"/*.yaml; do
  base=$(basename "${f}")
  # Skip our .orig backups
  case "${base}" in *.orig|*.orig.yaml) continue;; esac
  cp "${f}" "${INSTALL_DIR}/manifests/clife-${base}"
done
echo "    Copied $(ls "${INSTALL_DIR}/manifests/clife-"*.yaml | wc -l) CLife manifests."

# --------------------------------------------------------------------------
# 14. Generate ignition configs (manifests are consumed here)
# --------------------------------------------------------------------------
echo "--- Generating ignition configs ---"
openshift-install create ignition-configs --dir "${INSTALL_DIR}"
ls -lh "${INSTALL_DIR}"/*.ign

# --------------------------------------------------------------------------
# 15. Publish ignition files via httpd
# --------------------------------------------------------------------------
echo "--- Copying ignition files to httpd directory ---"
cp "${INSTALL_DIR}"/*.ign "${INSTALL_DIR}/ignition/"
chmod 644 "${INSTALL_DIR}/ignition/"*.ign
restorecon -R "${INSTALL_DIR}/ignition/" 2>/dev/null || true

echo ""
echo "=== Ignition generation complete ==="
echo ""
echo "Ignition URLs:"
echo "  Bootstrap: http://${BASTION_IP}:8080/ignition-install/bootstrap.ign"
echo "  Master:    http://${BASTION_IP}:8080/ignition-install/master.ign"
echo "  Worker:    http://${BASTION_IP}:8080/ignition-install/worker.ign"
echo ""
echo "Note: httpd serves the install lab's ignition under /ignition-install/ to"
echo "      keep it distinct from the migration lab's /ignition/."
echo ""
echo "Next:"
echo "  1. Create VMs: ./recreate-vms.sh"
echo "  2. ./setup-pxe.sh (refreshes per-MAC grub configs)"
echo "  3. ./pxe-install-and-boot.sh"
echo "  4. ./monitor-install.sh"

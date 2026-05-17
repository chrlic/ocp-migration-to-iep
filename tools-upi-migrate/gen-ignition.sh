#!/bin/bash
# Generate OCP UPI ignition configs.
# Steps:
#   1. Write install-config.yaml (uses Artifactory pull secret)
#   2. Write OpenShift manifests:
#      - ImageContentSourcePolicy pointing at Artifactory
#      - MachineConfig to trust Artifactory CA on every node
#   3. Generate ignition files
#   4. Copy ignition files to httpd serving directory
#
# Prerequisite: setup-artifactory.sh must have run so PULL_SECRET_ART_FILE exists.

set -euo pipefail

source /root/tools-upi-migrate/lab-config.sh

echo "=== Generating UPI Ignition Configs ==="

if [ ! -f "${PULL_SECRET_ART_FILE}" ]; then
  echo "ERROR: ${PULL_SECRET_ART_FILE} not found."
  echo "       Run setup-artifactory.sh first."
  exit 1
fi

if [ ! -f "${SSH_KEY_FILE}" ]; then
  echo "SSH key not found at ${SSH_KEY_FILE} — generating..."
  ssh-keygen -t ed25519 -f "${SSH_KEY_FILE%.pub}" -N ""
fi

# --------------------------------------------------------------------------
# 1. Prepare install directory
# --------------------------------------------------------------------------
echo "--- Preparing install directory: ${INSTALL_DIR} ---"
mkdir -p "${INSTALL_DIR}/openshift"
mkdir -p "${INSTALL_DIR}/ignition"
mkdir -p "${CLIFE_DIR}"

# --------------------------------------------------------------------------
# 2. Write install-config.yaml
# --------------------------------------------------------------------------
echo "--- Writing install-config.yaml ---"
# imageContentSources + additionalTrustBundle must be embedded in install-config
# itself so the BOOTSTRAP node redirects pulls (release-image fetch) to Nexus.
# An ICSP CRD only applies post-cluster — too late for bootkube.
ART_REPO="${ARTIFACTORY_HOST}:${ARTIFACTORY_PORT}"
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
  networkType: OVNKubernetes
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
additionalTrustBundle: |
${ART_CA}
EOF

# Back it up — the installer consumes (deletes) it
cp "${INSTALL_DIR}/install-config.yaml" "${INSTALL_DIR}/install-config.yaml.bak"
echo "    Written and backed up."

# --------------------------------------------------------------------------
# 3. Generate manifests (install-config.yaml is consumed here)
# --------------------------------------------------------------------------
echo "--- Generating manifests ---"
openshift-install create manifests --dir "${INSTALL_DIR}"

# --------------------------------------------------------------------------
# 4. Write ImageDigestMirrorSet + ImageTagMirrorSet for Artifactory
# --------------------------------------------------------------------------
# ICSP (ImageContentSourcePolicy) only mirrors digest references (image@sha256:…).
# Tag references (image:1.18.0) fall through to the original source. For lab
# workloads like Bookinfo that pull by tag (docker.io/istio/...:1.18.0), we
# also need an ImageTagMirrorSet so CRI-O's registries.conf has
# pull-from-mirror = "tag-and-digest" for those sources.
#
# OCP 4.13+ supports IDMS+ITMS (config.openshift.io/v1). ICSP is still accepted
# but is deprecated; use IDMS/ITMS going forward.
#
# CRITICAL: write IDMS and ITMS to SEPARATE files. Bootkube's openshift-config
# loader applies each file under openshift/ as a single resource — multi-doc
# YAML separated by `---` results in only the FIRST document being applied.
# Symptom if combined: cluster gets IDMS but no ITMS; the in-cluster MCC then
# renders registries.conf with only `pull-from-mirror = "digest-only"`, which
# mismatches the on-disk content from the previous render that included both
# digest and tag mirrors, and the master MCP goes Degraded on file content
# mismatch for /etc/containers/registries.conf.
echo "--- Writing IDMS + ITMS for Artifactory (two files) ---"
ART_REPO="${ARTIFACTORY_HOST}:${ARTIFACTORY_PORT}"

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
EOF
echo "    Written: ${INSTALL_DIR}/openshift/99-artifactory-itms.yaml"

# --------------------------------------------------------------------------
# 5. Write MachineConfig to trust Artifactory CA on every node
# --------------------------------------------------------------------------
echo "--- Writing MachineConfig for Artifactory CA trust ---"
# Trust the CA cert (which signed the server cert), not the leaf — chain validation
# requires the CA in /etc/pki/ca-trust/source/anchors on every node.
ART_CA_B64=$(base64 -w0 /etc/haproxy/certs/ca.crt)

for ROLE in worker master; do
  # NB: the `extensions:` MachineConfig field accepts only specific named OCP
  # extensions (usbguard, kerberos, kernel-devel, …). `update-ca-trust` is NOT a
  # MachineConfig extension — it's a binary on the node. Writing the CA file
  # under /etc/pki/ca-trust/source/anchors/ is enough; MCO renders the
  # certificates into /etc/pki/ca-trust/extracted on the node via a systemd unit
  # that runs update-ca-trust as part of the OS firstboot. We do NOT need
  # extensions[] here; including it makes bootkube fail with
  # "invalid extensions found: [update-ca-trust]".
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
        - path: /etc/pki/ca-trust/source/anchors/artifactory-migrate.crt
          mode: 0644
          contents:
            source: "data:text/plain;base64,${ART_CA_B64}"
EOF
  echo "    Written: ${INSTALL_DIR}/openshift/99-${ROLE}-artifactory-ca.yaml"
done

# --------------------------------------------------------------------------
# 6. Scheduler: mastersSchedulable=false so masters don't get the `worker` label
# --------------------------------------------------------------------------
# When compute.replicas: 0 (UPI), the installer defaults Scheduler.mastersSchedulable=true,
# which auto-labels masters with node-role.kubernetes.io/worker="". That makes
# the IngressController nodeSelector match masters AND workers — routers can
# end up on masters and HAProxy ingress backends to actual workers stay DOWN.
# Setting mastersSchedulable=false strips the worker label from masters so
# router placement uses only the real workers.
#
# The installer already produces manifests/cluster-scheduler-02-config.yml at
# manifests-creation time. We patch it in-place instead of adding a duplicate
# Scheduler under openshift/ (which would fail with "multiple manifests for
# group config.openshift.io kind Scheduler").
echo "--- Patching Scheduler manifest (mastersSchedulable=false) ---"
SCHED_FILE="${INSTALL_DIR}/manifests/cluster-scheduler-02-config.yml"
if [ -f "${SCHED_FILE}" ]; then
  sed -i 's/mastersSchedulable: true/mastersSchedulable: false/' "${SCHED_FILE}"
  echo "    Patched: ${SCHED_FILE}"
else
  echo "    WARNING: ${SCHED_FILE} not found — installer may have changed layout"
fi

# --------------------------------------------------------------------------
# 7. IngressController: use HostNetwork on worker nodes
# --------------------------------------------------------------------------
# Default UPI/platform-none ingress uses NodePortService; with our external
# HAProxy fronting :80/:443 we want the router pods to bind directly to the
# worker host network. Without this, the routers run with a ClusterIP service
# and HAProxy backends (worker:80 / worker:443) all stay DOWN — operator
# 'authentication' degrades because the oauth route is unreachable.
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
echo "    Written: ${INSTALL_DIR}/openshift/99-cluster-ingress-default.yaml"

# --------------------------------------------------------------------------
# 7. Generate ignition configs
# --------------------------------------------------------------------------
echo "--- Generating ignition configs ---"
openshift-install create ignition-configs --dir "${INSTALL_DIR}"

ls -lh "${INSTALL_DIR}"/*.ign

# --------------------------------------------------------------------------
# 7. Publish ignition files via httpd
# --------------------------------------------------------------------------
echo "--- Copying ignition files to httpd directory ---"
cp "${INSTALL_DIR}"/*.ign "${INSTALL_DIR}/ignition/"
chmod 644 "${INSTALL_DIR}/ignition/"*.ign
restorecon -R "${INSTALL_DIR}/ignition/" 2>/dev/null || true

echo ""
echo "=== Ignition generation complete ==="
echo ""
echo "Ignition URLs:"
echo "  Bootstrap: http://${BASTION_IP}:8080/ignition/bootstrap.ign"
echo "  Master:    http://${BASTION_IP}:8080/ignition/master.ign"
echo "  Worker:    http://${BASTION_IP}:8080/ignition/worker.ign"
echo ""
echo "Next:"
echo "  1. Create VMs: ./recreate-vms.sh"
echo "  2. Boot each VM from RHCOS ISO and run coreos-installer with the ignition URL"
echo "  3. Monitor installation: ./monitor-install.sh"

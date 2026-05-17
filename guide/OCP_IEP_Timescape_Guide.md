# Hubble Timescape on OCP 4.16 + Isovalent Networking for Kubernetes

Follow-up guide to [`OCP_IEP_Migration_Guide.md`](OCP_IEP_Migration_Guide.md).
Deploys **Hubble Timescape** (the standalone, ClickHouse-backed persistent flow
observability backend) on top of the migrated OCP + Cilium cluster from the
main guide.

This is the **standalone Timescape** path — separate ClickHouse instance
managed by the Altinity ClickHouse Operator, persistent PVC, full production-
shaped layout. The simpler "integrated mode" (`featureGate: HubbleTimescape`
embedded in the Cilium Helm release) is not covered here.

The guide stops at the **CLI + Hubble UI**. Grafana dashboards are not in scope.

## Overview

```
cilium DaemonSet (each of 6 nodes)
  └─ built-in Timescape exporter (gRPC :4261)
                    │
            Timescape Ingester (gRPC server)
                    │
                writes flows
                    ▼
             ClickHouse cluster (1 replica + PVC)
                    │
              read queries
                    ▼
            Timescape Server (gRPC API :4244)
                    │
              ┌─────┴──────┐
              ▼            ▼
     hubble CLI       Hubble Timescape UI
   (port-forward)        (OCP Route)
```

**Components added by this guide:**

| Component | Namespace | What it does |
|---|---|---|
| nfs-subdir-external-provisioner | `nfs-provisioner` | Dynamic NFS-backed StorageClass for the ClickHouse PVC |
| Altinity ClickHouse Operator | `clickhouse-operator` | Manages `ClickHouseInstallation` CRs |
| Hubble Timescape (Helm release) | `hubble-timescape` | Ingester + Server + UI + ClickHouseInstallation |
| Route `hubble-timescape-ui` | `hubble-timescape` | Edge-terminated TLS route to the UI |

**Prerequisites:**
- Section 8 of the main guide complete (Cilium 1.17.x healthy, all CO green)
- Bastion at `192.168.39.20` with `oc`, root SSH, and outbound HTTPS to `helm.isovalent.com` and `docs.altinity.com`
- `helm` v3 on the bastion (install one-liner below if missing)
- Free disk on the bastion for the NFS export (recommend ≥ 50 GiB; the Timescape PVC defaults to 100 GiB but the lab can run smaller)
- IDMS + ITMS for `quay.io/isovalent`, `quay.io`, `docker.io`, **and `registry.k8s.io`** already in the cluster. Shipped by `gen-ignition.sh` from this repo; verify with:
  ```bash
  oc get idms artifactory-digest-mirror -o jsonpath='{range .spec.imageDigestMirrors[*]}{.source}{"\n"}{end}'
  ```
  must list `registry.k8s.io` (the NFS provisioner image is at `registry.k8s.io/sig-storage/nfs-subdir-external-provisioner`). For clusters installed before this entry was added, see the live-patch snippet in Section A.0 below.

If `helm` isn't installed yet:
```bash
source /etc/profile.d/proxy.sh
curl -fL https://get.helm.sh/helm-v3.16.3-linux-amd64.tar.gz \
  | tar xz -C /tmp linux-amd64/helm
mv /tmp/linux-amd64/helm /usr/local/bin/helm && chmod +x /usr/local/bin/helm
rmdir /tmp/linux-amd64
helm version --short
```

## Section A — NFS storage on the bastion

The lab is `platform: none`: no cloud disks, no ODF. We export a directory
from the bastion over NFS and use `nfs-subdir-external-provisioner` to give
the cluster a dynamic `StorageClass`.

### A.0 Patch IDMS+ITMS for registry.k8s.io (only on clusters built before this fix)

The `nfs-subdir-external-provisioner` image lives at `registry.k8s.io/sig-storage/...`.
If your `gen-ignition.sh` already includes `registry.k8s.io` in the IDMS+ITMS
manifests (current version of this repo), skip this step. If `oc get idms artifactory-digest-mirror -o yaml` does NOT list `registry.k8s.io`, patch it
live — note that this triggers an MCP rolling reboot (~15–25 min):

```bash
source /root/tools-upi-migrate/lab-config.sh
export KUBECONFIG="${INSTALL_DIR}/auth/kubeconfig"

# Nexus needs a remote proxy for registry.k8s.io and it needs to be in the group
ART_PASS="${ARTIFACTORY_PASS}"
curl -s --noproxy "*" -u "admin:${ART_PASS}" \
  -X POST "http://localhost:8081/service/rest/v1/repositories/docker/proxy" \
  -H "Content-Type: application/json" -d '{
    "name": "remote-k8s",
    "online": true,
    "storage": {"blobStoreName": "default", "strictContentTypeValidation": true},
    "proxy": {"remoteUrl": "https://registry.k8s.io", "contentMaxAge": 1440, "metadataMaxAge": 1440},
    "negativeCache": {"enabled": false, "timeToLive": 1440},
    "httpClient": {"blocked": false, "autoBlock": false, "connection": {"retries": null, "timeout": null, "enableCircularRedirects": false, "enableCookies": false, "useTrustStore": false}},
    "docker": {"v1Enabled": false, "forceBasicAuth": false},
    "dockerProxy": {"indexType": "REGISTRY", "foreignLayerUrlWhitelist": []}
  }'

curl -s --noproxy "*" -u "admin:${ART_PASS}" \
  -X PUT "http://localhost:8081/service/rest/v1/repositories/docker/group/${ARTIFACTORY_OCP_REPO}" \
  -H "Content-Type: application/json" -d "{
    \"name\": \"${ARTIFACTORY_OCP_REPO}\",
    \"online\": true,
    \"storage\": {\"blobStoreName\": \"default\", \"strictContentTypeValidation\": true},
    \"group\": {\"memberNames\": [\"remote-quay\", \"remote-redhat\", \"remote-connect\", \"remote-dockerhub\", \"remote-k8s\"]},
    \"docker\": {\"v1Enabled\": false, \"forceBasicAuth\": true, \"pathEnabled\": true}
  }"

# Live IDMS+ITMS patch — triggers MCP rolling reboot
oc patch imagedigestmirrorset artifactory-digest-mirror --type=json -p="[
  {\"op\":\"add\",\"path\":\"/spec/imageDigestMirrors/-\",\"value\":{
    \"mirrors\":[\"${ARTIFACTORY_HOST}:${ARTIFACTORY_PORT}\"],
    \"source\":\"registry.k8s.io\"}}]"
oc patch imagetagmirrorset artifactory-tag-mirror --type=json -p="[
  {\"op\":\"add\",\"path\":\"/spec/imageTagMirrors/-\",\"value\":{
    \"mirrors\":[\"${ARTIFACTORY_HOST}:${ARTIFACTORY_PORT}\"],
    \"source\":\"registry.k8s.io\"}}]"

# Wait for the rolling reboot
oc wait mcp master worker --for condition=Updated --timeout=30m
```

### A.1 Configure the NFS server

```bash
# Install + start the NFS server
dnf install -y nfs-utils
systemctl enable --now nfs-server

# Create the export
mkdir -p /srv/nfs/openshift
chown nobody:nobody /srv/nfs/openshift
chmod 0777 /srv/nfs/openshift

# Export to the node network only (192.168.39.0/24)
cat > /etc/exports.d/openshift.exports <<EOF
/srv/nfs/openshift  192.168.39.0/24(rw,sync,no_root_squash,no_subtree_check)
EOF

exportfs -ra
exportfs -v

# Firewall — NFSv4 needs TCP 2049 reachable from the node network
firewall-cmd --add-service=nfs --permanent
firewall-cmd --reload

# Smoke test from the bastion itself
mount -t nfs 127.0.0.1:/srv/nfs/openshift /mnt && umount /mnt && echo "NFS export OK"
```

> **Reachability:** every worker and master must be able to TCP-connect to
> `192.168.39.20:2049`. If you have `iptables`/`firewalld` rules on the bastion
> that scope HAProxy ports, double-check 2049 isn't blocked.

### A.2 Deploy nfs-subdir-external-provisioner

```bash
source /root/tools-upi-migrate/lab-config.sh
export KUBECONFIG="${INSTALL_DIR}/auth/kubeconfig"

# Add the upstream Helm repo
helm repo add nfs-subdir-external-provisioner \
  https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/
helm repo update

# Namespace + privileged SCC (the provisioner mounts NFS via hostPath helpers)
oc create namespace nfs-provisioner
oc adm policy add-scc-to-user privileged \
  -z nfs-subdir-external-provisioner -n nfs-provisioner

# Install
helm install nfs-subdir-external-provisioner \
  nfs-subdir-external-provisioner/nfs-subdir-external-provisioner \
  --namespace nfs-provisioner \
  --set nfs.server=${BASTION_IP} \
  --set nfs.path=/srv/nfs/openshift \
  --set storageClass.name=nfs-storage \
  --set storageClass.defaultClass=true \
  --set storageClass.archiveOnDelete=false

# Verify
oc -n nfs-provisioner rollout status deploy/nfs-subdir-external-provisioner --timeout=3m
oc get sc
# Expected:
#   NAME                    PROVISIONER                                     ...   DEFAULT
#   nfs-storage (default)   cluster.local/nfs-subdir-external-provisioner   ...   true
```

### A.3 Smoke-test the StorageClass

```bash
cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: nfs-smoke
  namespace: default
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
  storageClassName: nfs-storage
EOF

oc get pvc -n default nfs-smoke -w &
W=$!; sleep 10; kill ${W} 2>/dev/null
oc get pvc -n default nfs-smoke
# Expected: STATUS=Bound, with a CAPACITY of 1Gi

oc delete pvc -n default nfs-smoke
```

If the PVC reaches `Bound`, the StorageClass works. Continue to Section B.
If it stays `Pending`, check the provisioner pod logs:
`oc -n nfs-provisioner logs deploy/nfs-subdir-external-provisioner`.

## Section B — Altinity ClickHouse Operator

The Altinity operator manages ClickHouse via the `ClickHouseInstallation` CR.
It runs in its **own namespace** (`clickhouse-operator`) — keeping it separate
from `hubble-timescape` prevents the Timescape namespace from getting stuck in
`Terminating` if it owns the operator.

```bash
source /root/tools-upi-migrate/lab-config.sh
export KUBECONFIG="${INSTALL_DIR}/auth/kubeconfig"

CLICKHOUSE_OPERATOR_VERSION=0.23.5    # « CHANGE » https://docs.altinity.com/clickhouse-operator

helm repo add altinity-clickhouse-operator https://docs.altinity.com/clickhouse-operator
helm repo update

oc create namespace clickhouse-operator
oc adm policy add-scc-to-user privileged \
  -z clickhouse-operator-altinity-clickhouse-operator -n clickhouse-operator

# The chart references images bare (no docker.io/ prefix), which the IDMS does
# match (source = "docker.io" matches bare image refs).
#
# Chart bug: the chart's default `metrics.image.tag` falls back to the chart's
# appVersion (e.g. 0.23.5). That tag exists for altinity/clickhouse-operator
# but NOT for altinity/metrics-exporter, which is versioned independently
# (latest stable at time of writing: 0.27.1). The result is a half-ready pod
# (clickhouse-operator container Running, metrics-exporter ImagePullBackOff).
# Override the metrics tag explicitly.
METRICS_EXPORTER_TAG=0.27.1     # « CHANGE » check https://hub.docker.com/r/altinity/metrics-exporter/tags

helm install clickhouse-operator \
  altinity-clickhouse-operator/altinity-clickhouse-operator \
  --namespace clickhouse-operator \
  --version ${CLICKHOUSE_OPERATOR_VERSION} \
  --set metrics.image.tag=${METRICS_EXPORTER_TAG} \
  --set 'operator.env[0].name=WATCH_NAMESPACES,operator.env[0].value=hubble-timescape'

oc -n clickhouse-operator rollout status deploy/clickhouse-operator-altinity-clickhouse-operator --timeout=3m
```

Expected:
```
clickhouse-operator-altinity-clickhouse-operator-...   2/2   Running   0   30s
```

> **Watch-namespace scoping** (`WATCH_NAMESPACES=hubble-timescape`) is important.
> Without it the operator watches all namespaces and can race with other
> Helm releases. Section 8.3 of the air-gapped guide has more detail.

## Section C — Hubble Timescape

### C.1 Namespace, SCC, credentials

```bash
source /root/tools-upi-migrate/lab-config.sh
export KUBECONFIG="${INSTALL_DIR}/auth/kubeconfig"

oc create namespace hubble-timescape

# ClickHouse pods run as fixed UID 101; Timescape pods as 65532. Both fall outside
# OCP's per-namespace UID range and the pods use seccomp-localhost annotations.
# The privileged SCC lets them bind those UIDs.
oc label namespace hubble-timescape \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/enforce-version=latest

for sa in default \
          hubble-timescape-ingester \
          hubble-timescape-server \
          hubble-timescape-ui; do
  oc adm policy add-scc-to-user privileged -z ${sa} -n hubble-timescape
done

# Per-component credentials. Use STRONG unique passwords for production.
for c in migrate trimmer ingester server analyzer; do
  oc -n hubble-timescape create secret generic hubble-timescape-${c}-creds \
    --from-literal "CLICKHOUSE_PASSWORD=Passw0rd.-${c}"   # « CHANGE »
done
```

### C.2 Helm values

```bash
cat > /root/hubble-timescape-values.yaml <<EOF
# ClickHouse cluster — single shard, single replica, PVC-backed via nfs-storage
clickhouse:
  cluster:
    enabled: true
    # Resource limits — IMPORTANT for a small lab. Cilium with KPR=true and
    # full Hubble export easily produces 20-30k flows/s on a 6-node cluster.
    # Without a memory limit, ClickHouse will allocate up to the node's total
    # RAM and get OOM-killed by the kernel under any non-trivial query
    # ("(total) memory limit exceeded: would use 14.06 GiB"). Cap it well
    # below worker RAM and let queries fail gracefully with a CH-level
    # over-commit error instead of taking out the whole pod.
    resources:
      requests:
        cpu: "500m"
        memory: "2Gi"
      limits:
        cpu: "2"
        memory: "4Gi"
    volumes:
      data:
        size: 50Gi              # « CHANGE » bigger for longer retention; ~100 GiB ≈ 1B flows
        storageClassName: nfs-storage

# Stream API ingester — Cilium will push flows here over gRPC :4261
ingester:
  bucket:
    # Local-disk staging path for the ingester before it writes to ClickHouse.
    # The default emptyDir is fine for a lab; for production use S3/MinIO/GCS.
    uri: "file:///var/run/hubble-timescape/flows"
  server:
    grpc:
      enabled: true            # enable Stream API on port 4261

# UI is enabled by default since Timescape v1.7.1; explicit for clarity
ui:
  enabled: true
EOF
```

> **Flow rate vs ClickHouse capacity:** at ~30k flows/s (typical for a 6-node
> Cilium cluster with full Hubble + Bookinfo), 50 GiB of PVC fills in roughly
> 6-12 hours. Either size the PVC accordingly or enable Cilium-side
> aggregation via `--hubble-export-timescape-aggregation=connection` to cut
> the rate by ~10×. Production deployments should use S3/MinIO instead of the
> local-disk bucket and use ClickHouse TTL on the `hubble.flows` table for
> automatic retention.

> **Production note:** the local-disk ingester bucket caps at the ingester pod's
> ephemeral storage. For real workloads, switch `ingester.bucket.uri` to S3/MinIO
> and add `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` to
> `hubble-timescape-ingester-creds`. See Section 8.5 of the air-gapped guide.

### C.3 Install Timescape

```bash
source /root/tools-upi-migrate/lab-config.sh
export KUBECONFIG="${INSTALL_DIR}/auth/kubeconfig"

TIMESCAPE_VERSION=v1.8.4    # « CHANGE » https://docs.isovalent.com — check matching IEP version

helm repo add isovalent https://helm.isovalent.com
helm repo update

# List available versions for sanity check
helm search repo isovalent/hubble-timescape -l | head -5

helm upgrade --install hubble-timescape isovalent/hubble-timescape \
  --version ${TIMESCAPE_VERSION#v} \
  --namespace hubble-timescape \
  --values /root/hubble-timescape-values.yaml

# Wait for all components
oc -n hubble-timescape get pods -w &
W=$!; sleep 5

for i in $(seq 1 60); do
  TOTAL=$(oc -n hubble-timescape get pods --no-headers 2>/dev/null | wc -l)
  READY=$(oc -n hubble-timescape get pods --no-headers 2>/dev/null | awk '$3=="Running" && $2 ~ /^([0-9]+)\/\1$/' | wc -l)
  echo "  (${i}/60) ${READY}/${TOTAL} ready"
  [ "${TOTAL}" -gt 0 ] && [ "${READY}" -eq "${TOTAL}" ] && break
  sleep 10
done
kill ${W} 2>/dev/null

oc -n hubble-timescape get pods
```

Expected: ClickHouse server (`chi-hubble-timescape-...-0-0-0`), ingester,
server, UI, and a one-shot migrate job (Completed).

## Section D — Connect Cilium to Timescape (Stream API)

Cilium agents will stream flows to the ingester over gRPC. This is a single
`CiliumConfig` patch — CLife reconciles, restarts the DS, and Cilium starts
pushing.

```bash
source /root/tools-upi-migrate/lab-config.sh
export KUBECONFIG="${INSTALL_DIR}/auth/kubeconfig"

oc -n cilium patch ciliumconfig ciliumconfig --type=merge -p '
spec:
  hubble:
    export:
      timescape:
        enabled: true
        target: "hubble-timescape-ingester.hubble-timescape.svc.cluster.local:4261"
'

# CLife reconciles the patch and restarts the Cilium DS
oc -n cilium rollout status ds/cilium --timeout=5m

# IMPORTANT: the CLife auto-restart of the DS often fires BEFORE CLife has
# finished rendering the cilium-config ConfigMap. When that happens, the new
# agent pods come up reading a stale ConfigMap and the hubble-export-timescape-*
# keys never reach /tmp/cilium/config-map/. Symptom: the ingester logs
# only "tick" with 0% utilization, no `stream.insert.flows.flushed` line.
# Fix: confirm the ConfigMap has the keys, then restart the DS one more time.
oc -n cilium get cm cilium-config -o jsonpath='{.data.hubble-export-timescape-enabled}{"\n"}{.data.hubble-export-timescape-target}{"\n"}'
# Expected: "true" and the ingester FQDN. If both are present, force a fresh
# rollout so the agents re-mount the up-to-date ConfigMap:
oc -n cilium rollout restart ds/cilium
oc -n cilium rollout status ds/cilium --timeout=5m
```

### Verify the stream

```bash
# Cilium agents log when they start streaming
oc -n cilium logs ds/cilium -c cilium-agent --tail=200 2>/dev/null \
  | grep -i "stream" | tail -5
# Expected line: "...start streaming flow logs..."

# Ingester reports flows/s flushed
oc -n hubble-timescape logs -l app.kubernetes.io/name=hubble-timescape-ingester \
  --tail=30 | grep -E "flushed|insert"
# Expected: stream.insert.flows.flushed=NN.NN/s
```

If you see `flushed=0.00/s` for more than a couple of minutes, generate
traffic — `curl` the Bookinfo route, hit the OCP console — and re-check.

## Section E — Query historical flows

### E.1 CLI — `hubble observe` against Timescape

The OSS `hubble` CLI talks to Timescape's gRPC server. Install it once if you
don't have it:

```bash
# NOTE: the hubble CLI version must align with TIMESCAPE_VERSION, NOT
# Cilium's runtime version. Timescape 1.8.4 ships an older server-side
# Flow schema; hubble v1.19.x sends fields the server rejects with
# `error mapping flows: error creating FieldMaskFinalizer: path "ip_trace_id" invalid: unsupported field`.
# Use a hubble CLI from the same minor as Cilium 1.17.x → hubble 1.17.5.
# Available hubble release tags: https://github.com/cilium/hubble/releases
HUBBLE_CLI_VERSION=v1.17.5
source /etc/profile.d/proxy.sh
curl -fL -o /tmp/hubble.tgz \
  "https://github.com/cilium/hubble/releases/download/${HUBBLE_CLI_VERSION}/hubble-linux-amd64.tar.gz"
tar xz -f /tmp/hubble.tgz -C /usr/local/bin hubble
chmod +x /usr/local/bin/hubble
hubble version
```

Port-forward the Timescape gRPC API:

```bash
source /root/tools-upi-migrate/lab-config.sh
export KUBECONFIG="${INSTALL_DIR}/auth/kubeconfig"

# Detach the port-forward from the shell job group so it survives subshell exit
setsid oc port-forward -n hubble-timescape svc/hubble-timescape 4244:80 \
  > /tmp/pf-timescape.log 2>&1 < /dev/null &
sleep 3
ss -ltnp | grep ':4244' && echo "port-forward up"
```

Query:

```bash
# The corporate WSA proxy intercepts everything by default; tell hubble to
# bypass it for the local port-forward.
export NO_PROXY="localhost,127.0.0.1,${NO_PROXY}"

# Flows from the last 5 minutes
hubble observe --server localhost:4244 --since 5m | head -20

# Dropped flows in openshift-ingress in the last hour
hubble observe --server localhost:4244 \
  --namespace openshift-ingress --verdict DROPPED --since 1h

# Bookinfo namespace flows, as JSON
hubble observe --server localhost:4244 \
  --namespace bookinfo --since 1h -o json | head -3

# Confirm Timescape actually has data
oc -n hubble-timescape exec chi-hubble-timescape-hubble-data-0-0-0 -- \
  clickhouse-client --query \
  "SELECT count(), toString(min(time)), toString(max(time)) FROM hubble.flows"
```

> **Relative `--since` (e.g. `5m`, `24h`) is the safe form.** Absolute
> timestamps must fall within the window of data Timescape has actually
> ingested; querying earlier than that returns empty without error.

### E.2 Tear down the port-forward when done

```bash
pkill -f "port-forward -n hubble-timescape" || true
```

## Section F — Hubble Timescape UI (OCP Route)

The UI ships with Timescape and serves on port 8081 inside the cluster.
Expose it with an edge-terminated OCP Route:

```bash
cat <<EOF | oc apply -f -
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: hubble-timescape-ui
  namespace: hubble-timescape
spec:
  to:
    kind: Service
    name: hubble-timescape-ui
  port:
    targetPort: ui-http
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
EOF

oc -n hubble-timescape get route hubble-timescape-ui
# URL: https://hubble-timescape-ui-hubble-timescape.apps.${CLUSTER_NAME}.${BASE_DOMAIN}
```

For workstations not using the lab DNS, add to `/etc/hosts`:
```
192.168.39.20  hubble-timescape-ui-hubble-timescape.apps.ocp-migrate.md.prglab.local
```

> **Long-lived gRPC:** the UI keeps streaming gRPC connections open. If you
> front this route with a corporate proxy, raise its idle/read timeouts to at
> least a few minutes or the UI will look like it's hanging.

## Section F.5 — Sizing & capacity

Numbers below are **measured on this 6-node lab** (3 masters + 3 workers, 16 GiB RAM each, RHCOS 4.16, Cilium 1.17.15-cee.1 with KPR=true, Bookinfo + idle cluster traffic). They are the right starting point for any small Timescape lab; production deployments should benchmark against their own traffic.

### Flow rate

| Source | Sustained | Peak |
|---|---|---|
| **Cilium agents → Timescape ingester** (this lab, no aggregation) | **~10,000 flows/s** | **~30,000 flows/s** burst right after a `rollout restart` of Cilium |
| Bookinfo alone (one `curl` of the route) | ~50–100 flows | (transient) |
| Idle cluster (kube-system + ingress + monitoring) | ~5,000–8,000 flows/s | — |

The Hubble flow rate is **dominated by the cluster itself**, not the workload. Adding Bookinfo doesn't meaningfully change the steady-state. This is normal — OCP has chatty intra-cluster control plane traffic (kubelet → kube-apiserver, OVN → endpoints, etc.).

### Storage

| Metric | Value |
|---|---|
| Bytes per flow in ClickHouse (after compression) | ~80–120 B |
| 1 GiB of ClickHouse storage | ~10–13 M flows |
| **50 GiB PVC at 10k flows/s** | **fills in ~14 hours** |
| **100 GiB PVC at 10k flows/s** | **fills in ~28 hours** |
| **500 GiB PVC at 10k flows/s** | **~6 days** |
| **1 TiB PVC at 10k flows/s** | **~12 days** |
| Same with `aggregation=connection` (~10× compression) | multiply above by 10 |

This lab uses **50 GiB on NFS-on-bastion** — fine for an afternoon of demos, **not** for multi-day analysis. Bump `clickhouse.cluster.volumes.data.size` in [`hubble-timescape-values.yaml`](#c2-helm-values) before re-deploying if you want longer retention.

### Memory

| Component | Lab footprint | Recommended limit |
|---|---|---|
| ClickHouse server | **2.5–4 GiB** under steady ingest | **`limits.memory: 4Gi`** (this lab's setting) |
| ClickHouse + a single 5-minute unfiltered query | spikes to **>14 GiB** without a limit — gets OOM-killed by the kernel | The 4Gi limit makes CH return a graceful `(total) memory limit exceeded` error instead of dying — query fails, pod survives |
| Timescape ingester | ~200–400 MiB | default (unlimited) is fine |
| Timescape server | ~100–200 MiB | default is fine |
| Timescape UI | ~50 MiB | default is fine |

The single most important sizing knob is `clickhouse.cluster.resources.limits.memory`. Without it, any wide query against a few million flows takes out the pod.

### Retention strategy

For this lab (50 GiB PVC, 10k flows/s) you have three options to keep the disk from filling:

1. **Apply a ClickHouse `TTL` to the `hubble.flows` table** — the operator-correct way. Example: keep 24 hours.
   ```bash
   oc -n hubble-timescape exec chi-hubble-timescape-hubble-data-0-0-0 -- \
     clickhouse-client --query \
     "ALTER TABLE hubble.flows MODIFY TTL time + INTERVAL 24 HOUR"
   ```
2. **Enable Cilium-side aggregation** to cut the ingest rate ~10×. Add to CiliumConfig:
   ```yaml
   spec:
     hubble:
       export:
         timescape:
           enabled: true
           target: hubble-timescape-ingester.hubble-timescape.svc.cluster.local:4261
           aggregation:
             - connection      # one flow per (5-tuple) connection, not per packet
   ```
3. **Use a Timescape trimmer cron** (the `hubble-timescape-trimmer-creds` secret created in Section C.1 is for this). The Timescape Helm chart can deploy a trimmer Job that periodically deletes oldest entries — see `helm show values isovalent/hubble-timescape | grep -A 10 trimmer`.

For production at any meaningful scale, **option 1 (CH TTL) + S3-backed `ingester.bucket.uri`** instead of local-disk is the durable design. The standalone bucket also unblocks horizontal ingester scaling — multiple ingesters can read from the same bucket.

### When to grow / when to switch architectures

| Symptom | Action |
|---|---|
| PVC > 80% full | Increase `clickhouse.cluster.volumes.data.size`, `helm upgrade`, wait for STS to expand (or apply CH TTL) |
| `oc -n hubble-timescape get pod chi-...` shows `RESTARTS > 0` in the last hour | Tighten `limits.memory` or narrow your queries |
| Hubble UI / `hubble observe` slow (>10s) for short windows | ClickHouse needs more CPU — bump `limits.cpu` to 4 |
| Sustained ingest > 20k flows/s | Enable Cilium-side `aggregation: connection` or move to a dedicated ClickHouse cluster |
| Multi-node ClickHouse needed (HA + sharding) | Replace the single-replica CHI with a multi-replica setup. See [Altinity Operator docs](https://github.com/Altinity/clickhouse-operator/tree/master/docs) for the CR shape |

## Section G — Verification checklist

```bash
source /root/tools-upi-migrate/lab-config.sh
export KUBECONFIG="${INSTALL_DIR}/auth/kubeconfig"

# All four Timescape components Running
oc -n hubble-timescape get pods

# ClickHouse cluster healthy
oc -n hubble-timescape get chi
oc -n hubble-timescape exec chi-hubble-timescape-hubble-data-0-0-0 -- \
  clickhouse-client --query "SELECT version()"

# Cilium DS still healthy after the patch
cilium status -n cilium | head -10

# Live flow count
oc -n hubble-timescape exec chi-hubble-timescape-hubble-data-0-0-0 -- \
  clickhouse-client --query "SELECT count() FROM hubble.flows WHERE time > now() - INTERVAL 5 MINUTE"

# UI Route is admitted
oc -n hubble-timescape get route hubble-timescape-ui -o jsonpath='{.status.ingress[0].conditions[?(@.type=="Admitted")].status}'
echo
```

A healthy deployment shows:
- 4–5 Running pods in `hubble-timescape` (ClickHouse server, ingester, server, UI, possibly migrate-Completed)
- `chi` `Status: Completed`
- Non-zero `count()` from the flows table (after some traffic)
- Route Admitted=True
- `cilium status` still OK

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| ClickHouse PVC stuck Pending | NFS provisioner can't write to export | Check `oc -n nfs-provisioner logs deploy/nfs-subdir-external-provisioner`; verify `mount -t nfs ${BASTION_IP}:/srv/nfs/openshift /mnt` works from a worker |
| Ingester logs `flushed=0.00/s` (only `tick`) | Cilium agents reading stale cilium-config ConfigMap | Verify `/tmp/cilium/config-map/` inside an agent pod has `hubble-export-timescape-enabled` + `hubble-export-timescape-target` files. If missing, force a second `oc -n cilium rollout restart ds/cilium` — CLife's auto-restart races the ConfigMap render. See Section D. |
| `rpc error: code = InvalidArgument ... path "ip_trace_id" invalid` | hubble CLI newer than the Timescape server | Use a hubble CLI matching Timescape's age (v1.17.5 for Timescape 1.8.4), not the latest hubble. See Section E.1 |
| ClickHouse pod OOM-killed under any query | Default no-limit deploy on a small-RAM lab | Add `resources.limits.memory` to `clickhouse.cluster` in the values file (Section C.2) and `helm upgrade`. The query will fail with a graceful CH over-commit error instead of restarting the pod |
| `code = Internal desc = internal server error` from hubble observe | Timescape server can't reach ClickHouse (just restarted), or ClickHouse mid-OOM | `oc -n hubble-timescape get pod chi-...` — if `RESTARTS > 0` recently, wait 30s and retry. If persistent, lower memory pressure (limit flows in time, narrow filters) |
| `hubble observe` returns nothing | Proxy intercepting localhost gRPC | `export NO_PROXY=localhost,127.0.0.1,${NO_PROXY}` before running |
| Pod stuck `CreateContainerConfigError` | SCC not granted | Re-run `oc adm policy add-scc-to-user privileged -z <sa> -n hubble-timescape` |
| UI route 503 | Service `hubble-timescape-ui` has 0 endpoints | `oc -n hubble-timescape get endpoints hubble-timescape-ui`; if empty, check the UI pod's logs |
| ClickHouse pod crashlooping with `image not found` | IDMS/ITMS missing `quay.io/isovalent/clickhouse-server` | `oc get idms,itms` should both list a `quay.io/isovalent` source. If not, see [main guide Section 3.6](OCP_IEP_Migration_Guide.md) |

## Teardown

```bash
oc -n hubble-timescape delete route hubble-timescape-ui
helm -n hubble-timescape uninstall hubble-timescape
oc delete namespace hubble-timescape
helm -n clickhouse-operator uninstall clickhouse-operator
oc delete namespace clickhouse-operator
helm -n nfs-provisioner uninstall nfs-subdir-external-provisioner
oc delete namespace nfs-provisioner
# NFS export on the bastion stays — remove manually if no longer needed
```

Revert the CiliumConfig stream by removing the `hubble.export.timescape` block:

```bash
oc -n cilium patch ciliumconfig ciliumconfig --type=json -p '[
  {"op":"remove","path":"/spec/hubble/export"}
]' 2>/dev/null || true
oc -n cilium rollout restart ds/cilium
```

## References

- Upstream source: [`doc-sources/OCP_AirGapped_Deployment_Guide.md`](../doc-sources/OCP_AirGapped_Deployment_Guide.md) Section 8 (this lab adapts it to a Nexus pull-through proxy + NFS-on-bastion topology)
- Main migration guide: [`OCP_IEP_Migration_Guide.md`](OCP_IEP_Migration_Guide.md)
- Isovalent docs (Cisco): https://docs.cisco.com/iep/
- Altinity ClickHouse Operator: https://docs.altinity.com/clickhouse-operator
- `nfs-subdir-external-provisioner`: https://github.com/kubernetes-sigs/nfs-subdir-external-provisioner

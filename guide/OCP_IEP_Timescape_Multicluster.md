# Centralized Hubble Timescape — Multi-Cluster Fan-In (Object Storage)

Follow-up to [`OCP_IEP_Timescape_Guide.md`](OCP_IEP_Timescape_Guide.md).

That guide deploys Timescape in **Stream API** mode: Cilium pushes flows over
gRPC to an in-cluster ingester (`...svc.cluster.local:4261`) with a local-disk
`emptyDir` bucket. That topology is **single-cluster by construction** — the
agents and the ingester must live in the same cluster.

This guide switches the coupling point to **shared object storage (MinIO)** so
**one central Timescape can ingest flows from many clusters**. Source clusters
write Hubble flow-log files to a MinIO bucket under a per-cluster prefix; the
central ingester is pointed at the bucket and attributes each prefix to a
cluster via `overrideClusterName`. Source clusters never talk to Timescape
directly — they only need write access to MinIO.

> **Deployment mode: STANDALONE.**
> This guide uses the **standalone** Timescape deployment — a separate Helm
> release with its own ClickHouse (via the Altinity operator) and its own
> ingester Deployment, exactly as built in
> [`OCP_IEP_Timescape_Guide.md`](OCP_IEP_Timescape_Guide.md). Standalone is the
> **only** mode that supports object-store fan-in: the `config.buckets[]` /
> `overrideClusterName` machinery used below lives on the standalone ingester
> and is **not** exposed by the integrated/Lite mode (`featureGate:
> HubbleTimescape` / `hubble-timescape-lite`), which is bound to a single
> cluster's agent lifecycle. Do **not** use the integrated/Lite mode for
> centralized multi-cluster collection.

> **Verified against the charts on this bastion (2026-06-01):**
> `isovalent/cilium 1.18.9` and `isovalent/hubble-timescape 1.18.8`.
> Key names below are taken verbatim from `helm show values`. The install lab
> Timescape line is **1.18.x** (not the `v1.8.4` pinned in the migration-lab
> Timescape guide).

## Topology

```
  ocp-install   Cilium static exporter ─► file ─► uploader sidecar ─┐
  (Phase 1:                                                          │ S3 PUT
   loopback)                                                         ▼
  cluster-2     Cilium static exporter ─► file ─► uploader sidecar ─► MinIO bucket  s3://timescape
  cluster-3     ...                                                  │   ├─ ocp-install/%Y/%m/%d/hubble.log
                                                                     │   ├─ cluster-2/%Y/%m/%d/hubble.log
                                                                     │   └─ cluster-3/%Y/%m/%d/hubble.log
                                                                     ▼
                                        [central cluster] Timescape ingester (config.buckets[])
                                                                     │  overrideClusterName per prefix
                                                                     ▼
                                                          ClickHouse ─► Server ─► UI / hubble CLI
```

- **Coupling point = MinIO**, not cluster-to-cluster gRPC. Source availability
  and central availability are decoupled; the ingester replays from the bucket
  on restart.
- **Cluster identity** comes from the object **prefix** + `overrideClusterName`.
  Two clusters must never share a prefix or their flows collide.
- The central cluster can also be a source (it writes its own prefix). In
  **Phase 1** we run it as a *cluster-of-one* — it writes `ocp-install/...` and
  reads it straight back — to validate the entire object-store path before any
  second cluster exists. **Phase 2** adds remote clusters as pure writers.

## Prerequisites

- The single-cluster Timescape guide completed at least once (you know
  ClickHouse + ingester + UI come up healthy on `nfs-storage-install`).
- `helm`, `oc`, root SSH on the bastion `192.168.39.20`.
- ClickHouse/Server/UI from the base guide are reused unchanged. **Only the
  ingester input changes** (`file://` → `config.buckets[]`), plus the Cilium
  export mode (Stream API → static file + uploader).
- Decide retention up front: N source clusters multiply ingest. The base guide
  measured **~10k flows/s sustained per 6-node cluster**; 3 clusters ≈ 30k/s
  into one ClickHouse. Plan on `aggregation: connection` (Cilium side, ~10×) +
  a ClickHouse TTL, and a PVC sized for the sum — NFS-on-bastion at 50 GiB
  fills in **<5 h** at 30k/s.

---

## Section M — MinIO on the bastion

MinIO is the only genuinely new component. Single-node, single-binary, backed
by bastion disk. Plain HTTP on the node network keeps the lab simple
(`disable_https=true` in the DSNs below). For TLS, front it with the existing
Nexus cert and drop `disable_https` — see the TLS note at the end of this section.

### M.1 Run MinIO as a container (podman, systemd-managed)

```bash
source /root/tools-upi-install/lab-config.sh

# Data dir on the bastion (separate disk from NFS if you have one)
mkdir -p /srv/minio/data
MINIO_ROOT_USER=minioadmin                 # « CHANGE »
MINIO_ROOT_PASSWORD=Passw0rd.-minio        # « CHANGE » strong, unique

# MinIO image is on Docker Hub → pull via the Nexus group over :8443.
# IMPORTANT: use the bare-host path with NO `ocp-images/` prefix — the HAProxy
# front (conf.d/artifactory.cfg) injects /repository/ocp-images/ itself. Adding
# the prefix double-paths and returns `manifest unknown`. (See migration guide
# §3.10 for the Docker Hub PAT-expiry failure mode, which presents identically.)
# /srv lives on the root FS; ensure it has space (this lab grew / to ~200 GiB
# for the shared Nexus + ClickHouse + MinIO pool — see sizing §X.3).
podman login "${ARTIFACTORY_HOST}:${ARTIFACTORY_PORT}" -u "${ARTIFACTORY_USER}" -p "${ARTIFACTORY_PASS}"
mkdir -p /srv/minio/data
podman run -d --name minio \
  -p 9000:9000 -p 9001:9001 \
  -e MINIO_ROOT_USER="${MINIO_ROOT_USER}" \
  -e MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD}" \
  -v /srv/minio/data:/data:Z \
  "${ARTIFACTORY_HOST}:${ARTIFACTORY_PORT}/minio/minio:latest" \
  server /data --console-address ":9001"

# Firewall — S3 API (9000) reachable from the node network; console (9001) optional
firewall-cmd --add-port=9000/tcp --permanent
firewall-cmd --add-port=9001/tcp --permanent
firewall-cmd --reload

podman ps --filter name=minio
```

> **Promote to a systemd unit so it survives reboots (done on this lab 2026-06-01):**
> ```bash
> podman generate systemd --new --name minio > /etc/systemd/system/minio.service
> systemctl daemon-reload
> podman stop minio                         # stop the manual `podman run` container
> systemctl enable --now minio              # the --new unit recreates it from /srv/minio/data
> systemctl is-active minio                 # → active
> ```
> The `--new` unit recreates the container on each start; the bucket data lives in
> the `/srv/minio/data` bind mount and persists across the recreate (verified:
> `timescape` bucket + `tsexport` user intact afterward).

### M.2 Create the bucket + a scoped access key

```bash
# mc client (Docker Hub via Nexus group)
podman run --rm --entrypoint=/bin/sh \
  "${ARTIFACTORY_HOST}:${ARTIFACTORY_PORT}/minio/mc:latest" -c 'true' 2>/dev/null || true

alias mc='podman run --rm --network host \
  "${ARTIFACTORY_HOST}:${ARTIFACTORY_PORT}/minio/mc:latest"'

mc alias set lab http://${BASTION_IP}:9000 "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}"
mc mb lab/timescape
mc ls lab

# A dedicated key the clusters use (least privilege: rw on the one bucket).
# For a lab the root key is fine; for fleet hygiene create a scoped user:
mc admin user add lab tsexport Passw0rd.-tsexport          # « CHANGE »
mc admin policy attach lab readwrite --user tsexport
```

Record the values the clusters will use:

| Field | Value |
|---|---|
| Endpoint | `http://192.168.39.20:9000` |
| Bucket | `timescape` |
| Access key | `tsexport` |
| Secret key | `Passw0rd.-tsexport` (« CHANGE ») |
| Path-style | **required** (MinIO) → `use_path_style=true` |

> **TLS variant:** if you front MinIO with the Nexus cert (or run MinIO with
> `--certs-dir`), use `endpoint=https://...`, drop `disable_https=true` from every DSN, and
> give the ingester the CA via `ingester.bucket.tls.ca.configMap` (Section R.2).
> Every **source** cluster must also trust that CA for the uploader sidecar —
> same ICSP/MachineConfig CA-trust pattern you bake into ignition.

---

## Section R — Re-point the central ingester at the bucket (Reader side)

This edits the Timescape Helm release from the base guide. ClickHouse, Server,
and UI values are unchanged; we replace the ingester's input and add S3
credentials.

### R.1 S3 credentials secret for the ingester

The ingester reads `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` from its
environment (gocloud blob S3 driver). Inject them via `ingester.extraEnv`
referencing a secret.

```bash
source /root/tools-upi-install/lab-config.sh
export KUBECONFIG="${INSTALL_DIR}/auth/kubeconfig"

oc -n hubble-timescape create secret generic hubble-timescape-s3-creds \
  --from-literal=AWS_ACCESS_KEY_ID=tsexport \
  --from-literal=AWS_SECRET_ACCESS_KEY=Passw0rd.-tsexport      # « CHANGE »
```

### R.2 Ingester values — `config.buckets[]` with per-cluster prefixes

The multi-cluster key is **`config.buckets[]`** (chart comment: *"Incompatible
with `ingester.bucket.uri`. If you have multiple buckets, or different prefixes
containing files to be ingested, you should configure it using
`config.buckets`."*).

> **DSN query-param form — VERIFIED on Timescape 1.18.8 runtime, differs from the chart's `values.yaml` comments.** The chart comments still show the old gocloud/aws-sdk-v1 form
> (`endpoint=host:port&disableSSL=true&s3ForcePathStyle=true`). On the **1.18.8
> ingester that form crashloops** with:
> `failed to parse endpoint URL: parse "192.168.39.20:9000": first path segment in URL cannot contain colon`
> and `s3 query parameter is no longer supported … param=disableSSL replacement=disable_https`.
> The 1.18.8 ingester uses the **AWS SDK v2** form:
> - `endpoint` **must include a scheme**: `endpoint=http://host:port`
> - `disableSSL` → **`disable_https=true`**
> - `s3ForcePathStyle` → **`use_path_style=true`**
> - add **`region=us-east-1`** (MinIO ignores it but the SDK requires one)
>
> Correct MinIO DSN: `s3://timescape?endpoint=http://192.168.39.20:9000&disable_https=true&use_path_style=true&region=us-east-1`

Append this to your existing `/root/hubble-timescape-values.yaml` (keep the
`clickhouse:` and `ui:` blocks from the base guide):

```yaml
# --- Ingester: read flows from the MinIO bucket instead of the Stream API ---
ingester:
  enabled: true
  # Pull the S3 creds in from the secret created in R.1
  extraEnv:
    - name: AWS_ACCESS_KEY_ID
      valueFrom:
        secretKeyRef:
          name: hubble-timescape-s3-creds
          key: AWS_ACCESS_KEY_ID
    - name: AWS_SECRET_ACCESS_KEY
      valueFrom:
        secretKeyRef:
          name: hubble-timescape-s3-creds
          key: AWS_SECRET_ACCESS_KEY
  # IMPORTANT: leave ingester.bucket.uri EMPTY — it is mutually exclusive with
  # config.buckets below. The Stream API server is no longer needed.
  bucket:
    uri: ""

config:
  # One entry per source cluster. The prefix isolates each cluster's objects;
  # overrideClusterName stamps the cluster identity onto every ingested flow.
  buckets:
    # Phase 1 — the central cluster as a cluster-of-one (loopback)
    - uri: "s3://timescape?endpoint=http://192.168.39.20:9000&disable_https=true&use_path_style=true&region=us-east-1"
      overrideClusterName: "ocp-install"
      flows:
        pattern: "hubble\\.log"
      paths:
        - prefixPattern: "ocp-install/%Y/%m/%d"
    # Phase 2 — add a block per remote source cluster (see Section S)
    # - uri: "s3://timescape?endpoint=http://192.168.39.20:9000&disable_https=true&use_path_style=true&region=us-east-1"
    #   overrideClusterName: "cluster-2"
    #   flows:
    #     pattern: "hubble\\.log"
    #   paths:
    #     - prefixPattern: "cluster-2/%Y/%m/%d"
```

> **Why per-prefix and not per-bucket?** Either works. One bucket with
> per-cluster prefixes keeps lifecycle/TTL in one place and only needs one
> access key. `overrideClusterName` is settable per bucket *and* per path, so a
> single shared bucket scales cleanly to many clusters.

> **TLS variant:** add under each bucket (or under `ingester.bucket`):
> ```yaml
>      tls:
>        ca:
>          configMap:
>            name: minio-ca
>            key: ca.crt
> ```
> and `oc -n hubble-timescape create configmap minio-ca --from-file=ca.crt=...`.

### R.3 Apply

```bash
source /root/tools-upi-install/lab-config.sh
export KUBECONFIG="${INSTALL_DIR}/auth/kubeconfig"
TIMESCAPE_VERSION=1.18.8     # « CHANGE » match your installed release / IEP 1.18

helm upgrade --install hubble-timescape isovalent/hubble-timescape \
  --version ${TIMESCAPE_VERSION} \
  --namespace hubble-timescape \
  --values /root/hubble-timescape-values.yaml

oc -n hubble-timescape rollout status deploy/hubble-timescape-ingester --timeout=3m
```

The ingester now polls MinIO. It will log `tick` with 0 files until something
writes to the bucket — that's Section S.

---

## Section S — Source-cluster export to MinIO (Writer side)

Each source cluster runs the Cilium **static file exporter** (writes flow-log
files to a host path) plus an **uploader sidecar** that ships rotated files to
MinIO under that cluster's prefix. Cilium has no native S3 PUT — the
file-exporter + uploader is the supported pattern, which is why the chart's
`prefixPattern` examples list the fluent-bit/fluentd key formats.

> Do this on **every source cluster**, including `ocp-install` itself in
> Phase 1. Use a **distinct prefix per cluster** matching the `prefixPattern`
> you registered in R.2.

### S.1 Enable the Cilium static exporter (CiliumConfig / CLife)

On `ocp-install` the CNI is managed by CLife, so patch `CiliumConfig`. The
static exporter is `hubble.export.static` (verified keys: `filePath`,
`fileMaxSizeMb`, `fileMaxBackups`, `fileRotationInterval`, `aggregation`).

```bash
source /root/tools-upi-install/lab-config.sh
export KUBECONFIG="${INSTALL_DIR}/auth/kubeconfig"

oc -n cilium patch ciliumconfig ciliumconfig --type=merge -p '
spec:
  hubble:
    export:
      static:
        enabled: true
        filePath: /var/run/cilium/hubble/hubble.log
        fileMaxSizeMb: 10
        fileMaxBackups: 5
        fileRotationInterval: "1m"
        # ~10x ingest reduction — strongly recommended for fan-in. Remove for
        # full per-packet fidelity (and size MinIO + ClickHouse accordingly).
        aggregation:
          - connection
'

oc -n cilium rollout status ds/cilium --timeout=5m

# Same CLife ConfigMap race as the base guide (Section D): CLife may restart the
# DS before rendering the new cilium-config. Confirm the keys landed, then force
# one more rollout.
oc -n cilium get cm cilium-config -o jsonpath='{.data.hubble-export-file-path}{"\n"}'
# Expected: /var/run/cilium/hubble/hubble.log
oc -n cilium rollout restart ds/cilium
oc -n cilium rollout status ds/cilium --timeout=5m
```

### S.2 Uploader sidecar — ship rotated files to MinIO

Add a fluent-bit (or `mc mirror`) sidecar to the Cilium agent DS that watches
`/var/run/cilium/hubble/` and PUTs rotated files to
`s3://timescape/<clusterName>/%Y/%m/%d/`. The key format **must** match the
`prefixPattern` in R.2 (`%Y/%m/%d`). Minimal fluent-bit DaemonSet example:

```bash
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: hubble-s3-uploader
  namespace: cilium
data:
  fluent-bit.conf: |
    [SERVICE]
        Flush 5
        Log_Level info
    [INPUT]
        Name tail
        Path /var/run/cilium/hubble/hubble.log*
        Tag hubble
        Refresh_Interval 5
    [OUTPUT]
        Name s3
        Match hubble
        bucket timescape
        endpoint http://192.168.39.20:9000
        # « CHANGE » per source cluster — MUST be unique and match R.2 prefix
        s3_key_format /ocp-install/%Y/%m/%d/hubble-$UUID.log
        use_put_object On
        total_file_size 10M
        upload_timeout 1m
EOF
```

> Provide the S3 creds to the uploader (`AWS_ACCESS_KEY_ID` /
> `AWS_SECRET_ACCESS_KEY` env from a secret, same key as R.1) and mount the
> Cilium host path read-only. The cleanest packaging is a small Helm values
> overlay that adds the sidecar + hostPath volume to the agent DS; wire it in
> via CLife's `extraContainers` if your IEP build exposes it, otherwise run the
> uploader as its own DaemonSet mounting the same `hostPath`
> (`/var/run/cilium/hubble`).

### S.3 Phase 2 — add a remote source cluster

For each additional cluster:
1. Repeat **S.1** with its own CNI management (CiliumConfig if CLife-managed).
2. Repeat **S.2** with a **unique `s3_key_format` prefix** (`/cluster-2/...`).
3. Add a matching block to **`config.buckets[]`** in R.2 with
   `overrideClusterName: cluster-2` and `prefixPattern: cluster-2/%Y/%m/%d`,
   then `helm upgrade` the central Timescape (R.3).
4. Ensure the cluster has L3 reach to `192.168.39.20:9000` and (TLS variant)
   trusts the MinIO CA.

---

## Section V — Verify the fan-in

> **Namespace on this lab is `hubble-timescape-install`** (not `hubble-timescape`).
> The ClickHouse pod is `chi-hubble-timescape-hubble-data-0-0-0`. Adjust the
> commands below if your release name/namespace differ.

```bash
source /root/tools-upi-install/lab-config.sh
export KUBECONFIG="${INSTALL_DIR}/auth/kubeconfig"
NS=hubble-timescape-install
CHPOD=chi-hubble-timescape-hubble-data-0-0-0

# 1. Files are landing in MinIO under the cluster prefix (see Section W.1 for the
#    mc-in-podman one-liner — the alias does NOT persist between `podman run`s)
mc ls --recursive lab/timescape/ocp-install/ | tail

# 2. Ingester is consuming them — look for "already ingested, skipping" / the
#    lister job, NOT just msg=tick. (`tick` alone = nothing matched the prefix.)
oc -n $NS logs deploy/hubble-timescape-ingester --tail=60 \
  | grep -Ei "insert|flush|ingest|lister|file|skip|error"

# 3. ClickHouse has flows, broken down by cluster — this is the money check.
#    IMPORTANT: there is NO bare `cluster_name` column. The per-endpoint columns
#    are `flow/source/cluster_name` and `flow/destination/cluster_name`
#    (slashes in the name → must be backtick-quoted).
oc -n $NS exec $CHPOD -- clickhouse-client --query \
  "SELECT \`flow/source/cluster_name\` AS cluster, count(), max(time)
   FROM hubble.flows WHERE time > now() - INTERVAL 30 MINUTE
   GROUP BY cluster ORDER BY count() DESC"
# Expected (Phase 1): ocp-install <count>
# Expected (Phase 2): one row per source cluster

# 4. hubble CLI / UI can filter by cluster (port-forward the server first)
hubble observe --server localhost:4244 --cluster ocp-install --since 10m | head
```

A healthy fan-in shows **one cluster row per source cluster** with non-zero
counts, and the ingester logging file ingestion rather than only `tick`.

### V.1 — `cluster_name` shows `default`/empty instead of the cluster name (IMPORTANT)

> **Verified on this lab 2026-06-01.** This bit us during bring-up and is the
> single most confusing part of the fan-in.

`config.buckets[].overrideClusterName` does **NOT** rewrite the
`flow/source/cluster_name` / `flow/destination/cluster_name` columns that
ClickHouse stores and that the UI / `hubble observe --cluster` filter on. Those
per-endpoint cluster names are stamped **by the source Cilium agent at
flow-generation time**, from the agent's own `cluster-name`. If a source cluster
still has the default identity (`cluster-name: default`, `cluster-id: 0`) every
flow lands as `default` (or empty for non-Cilium-managed endpoints), regardless
of `overrideClusterName`. The override is applied at a different layer and does
not surface in these columns on Timescape 1.18.8.

**Fix — set the Cilium cluster identity on every source cluster** (CLife-managed
→ patch `CiliumConfig`; each cluster needs a **unique** `id`):

```bash
oc -n cilium patch ciliumconfig ciliumconfig --type=merge -p '
spec:
  cluster:
    name: ocp-install      # « CHANGE » unique per source cluster
    id: 1                   # « CHANGE » unique 1..255 per source cluster
'
oc -n cilium get cm cilium-config -o jsonpath='cluster-name={.data.cluster-name} cluster-id={.data.cluster-id}{"\n"}'
# Expected: cluster-name=ocp-install cluster-id=1
```

> **GOTCHA — the patch alone does NOT restart the agents, so it silently does
> nothing until you force a rollout.** `cluster-name` is read from `cilium-config`
> **only at agent start-up**; it is not live-reloaded. CLife re-renders the
> ConfigMap but leaves the DaemonSet *pod template* unchanged, so no rolling
> restart is triggered — `oc rollout status ds/cilium` reports "successfully
> rolled out" against pods that **never cycled** (check `.status.startTime`).
> You must force it:
> ```bash
> oc -n cilium rollout restart ds/cilium
> oc -n cilium rollout status  ds/cilium --timeout=6m
> # Confirm pods actually cycled (startTime is recent):
> oc -n cilium get pods -l k8s-app=cilium \
>   -o custom-columns='NAME:.metadata.name,START:.status.startTime' --no-headers
> ```

**Verify at the source before waiting on the ClickHouse round-trip** (fastest
confirmation — no upload/ingest lag):

```bash
POD=$(oc -n cilium get pod -l k8s-app=cilium -o jsonpath='{.items[0].metadata.name}')
oc -n cilium exec $POD -c cilium-agent -- hubble observe --last 6 -o json \
  | python3 -c 'import sys,json
for L in sys.stdin:
    try: f=json.loads(L)
    except: continue
    fl=f.get("flow",f)
    print((fl.get("source") or {}).get("cluster_name","-"),"->",(fl.get("destination") or {}).get("cluster_name","-"))'
# Expected: ocp-install -> ...   (`-` on world/host endpoints is normal — they
# are not Cilium-managed and legitimately carry no cluster name)
```

Then it propagates through the pipeline (static-exporter rotation ~1 min →
uploader → ingester `schedule-interval` 5 min) before the new name appears in
ClickHouse. **Existing rows keep their old `default`/empty name** and age out via
the ClickHouse TTL — only flows generated *after* the restart carry the new name.

---

## Section W — Inspecting data in MinIO and ClickHouse (troubleshooting)

The fan-in has three places data can stall: **(1) the object in MinIO**,
**(2) the ingester** that reads it, **(3) the rows in ClickHouse**. Walk them in
that order — it isolates a writer problem from a reader problem from a query
problem. Everything below is verified against this lab (MinIO single-node podman
on the bastion, Timescape 1.18.8, ClickHouse 25.8).

### W.1 — Inspect the MinIO bucket (the writer's output)

The `mc` client runs from the MinIO image via podman. **The alias is stored in
the container's home dir, so it does NOT survive between `podman run --rm`
invocations** — set the alias and run your commands in the **same** container
(`--entrypoint=/bin/sh -c '...'`), or you get
`No valid configuration found for 'lab' host alias`.

```bash
source /root/tools-upi-install/lab-config.sh
MINIO_ROOT_USER=minioadmin                 # « CHANGE » match Section M
MINIO_ROOT_PASSWORD=Passw0rd.-minio        # « CHANGE »
IMG="${ARTIFACTORY_HOST}:${ARTIFACTORY_PORT}/minio/mc:latest"

# Helper: run any mc command(s) with the alias pre-set, in one container.
mcsh() { podman run --rm --network host --entrypoint=/bin/sh "$IMG" -c \
  "mc alias set lab http://${BASTION_IP}:9000 '$MINIO_ROOT_USER' '$MINIO_ROOT_PASSWORD' >/dev/null 2>&1; $*"; }

mcsh 'mc ls lab'                                    # buckets exist?
mcsh 'mc ls --recursive lab/timescape | tail -20'   # newest objects + sizes + timestamps
mcsh 'mc du lab/timescape'                           # total bytes in the bucket
mcsh 'mc admin user list lab'                        # the tsexport key exists + enabled?
mcsh 'mc admin info lab'                              # MinIO health / disk
```

What "healthy writer" looks like: a **new** object every `fileRotationInterval`
(1 min in this lab), one series per node, under `<cluster>/%Y/%m/%d/`, each
~150–165 KiB compressed. Per-node naming is
`<node-fqdn>-hubble-<ISO-timestamp>.log.gz`. **The bucket prefix must match the
`prefixPattern` in R.2 exactly** (`ocp-install/%Y/%m/%d`).

> If only ONE node's files appear: the uploader sidecar/DaemonSet isn't running
> on the others, or those agents aren't rotating. Check
> `oc -n cilium get pods -l <uploader-label>` and that the static exporter is
> enabled cluster-wide (S.1).

### W.2 — Inspect the *content* of an object (decode a flow log)

This is the definitive "what cluster name / fields are in the data" check —
independent of any ingest lag. Copy one object out (mount a host dir so the file
lands on the bastion), gunzip, and parse the newline-delimited JSON:

```bash
rm -rf /tmp/tsfile && mkdir -p /tmp/tsfile
# Grab the newest object for a given prefix:
podman run --rm --network host -v /tmp/tsfile:/out:Z --entrypoint=/bin/sh "$IMG" -c "
  mc alias set lab http://${BASTION_IP}:9000 '$MINIO_ROOT_USER' '$MINIO_ROOT_PASSWORD' >/dev/null 2>&1
  KEY=\$(mc ls --recursive lab/timescape/ocp-install/ | grep '\.log\.gz' | tail -1 | tr -s ' ' | cut -d' ' -f6-)
  echo \"key=\$KEY\"; mc cp \"lab/timescape/ocp-install/\$KEY\" /out/newest.log.gz"

# Decode it: count flows + tally the per-endpoint cluster names (the V.1 check)
gunzip -c /tmp/tsfile/newest.log.gz | python3 -c '
import sys,json,collections
src=collections.Counter(); dst=collections.Counter(); n=0; sample=None
for L in sys.stdin:
    L=L.strip()
    if not L: continue
    try: f=json.loads(L)
    except: continue
    fl=f.get("flow",f)
    if sample is None: sample=fl
    src[(fl.get("source") or {}).get("cluster_name","<missing>")]+=1
    dst[(fl.get("destination") or {}).get("cluster_name","<missing>")]+=1
    n+=1
print("flows:",n,"| node:",sample.get("node_name"))
print("source cluster_name:",dict(src))
print("dest   cluster_name:",dict(dst))'

# Or just eyeball a couple of raw flows pretty-printed:
gunzip -c /tmp/tsfile/newest.log.gz | head -2 | python3 -m json.tool
```

Each line is one Hubble flow (the v1 export schema). Useful top-level keys:
`time`, `node_name`, `source`/`destination` (each with `cluster_name`,
`namespace`, `pod_name`, `labels`, `identity`), `l4`, `verdict`, `Type`. Note
the `<node>-hubble-...` files contain flows from **all** pods scheduled on that
node, not just that node's own traffic.

### W.3 — Is the ingester actually consuming objects?

```bash
NS=hubble-timescape-install
# Live log — distinguish the states:
oc -n $NS logs deploy/hubble-timescape-ingester --tail=80 \
  | grep -viE 'no supported checksum'        # drop the noisy AWS-SDK WARN spam
```

Reading the log:
| Log line | Meaning |
|---|---|
| `msg=tick ... bucket.walker.channel=0%` only | Lister found **0 matching objects** — prefix/pattern mismatch, or bucket empty |
| `subsys=lister ... job starting` / `sleeping ... next=...` | Lister is scanning on its `schedule-interval` (default **5 m**) — normal |
| `already ingested, skipping source-uri=s3://...` | Object was seen before and is in `ingestionlog_events` — **normal** steady state |
| `insert` / `flush` | Actively writing rows to ClickHouse |
| `error-count=N>0` / `error/message` populated | Parse or insert failure — inspect that object with W.2 |
| `SDK ... WARN Response has no supported checksum` | Harmless MinIO/AWS-SDK-v2 noise — ignore |

> The ingester only scans every **5 minutes** (`schedule-interval`), so a freshly
> uploaded object can take up to 5 min + the report interval to appear in
> ClickHouse. Don't conclude "broken" inside that window.

The **ingestion bookkeeping table** records every object the ingester processed —
the authoritative "did this file get ingested" answer:

```bash
CHPOD=chi-hubble-timescape-hubble-data-0-0-0
oc -n $NS exec $CHPOD -- clickhouse-client --query \
  "SELECT \`source/uri\`, done, error, \`error/message\`
   FROM hubble.ingestionlog_events ORDER BY time DESC LIMIT 10 FORMAT Vertical"
# done=1 error=0 → ingested OK. error=1 → see error/message; pull that object (W.2).
```

### W.4 — Inspect the data in ClickHouse

```bash
NS=hubble-timescape-install
CHPOD=chi-hubble-timescape-hubble-data-0-0-0
CH() { oc -n $NS exec $CHPOD -- clickhouse-client --query "$1"; }

# Tables in the hubble DB
CH "SHOW TABLES FROM hubble"

# Schema of flows (note: column names contain slashes → backtick-quote them)
CH "DESCRIBE hubble.flows" | head -40
CH "SELECT name FROM system.columns WHERE database='hubble' AND table='flows' AND name LIKE '%cluster%'"
#   → flow/source/cluster_name , flow/destination/cluster_name   (NO bare cluster_name)

# Row count + time span (is data fresh? is the backlog the old Stream-API data?)
CH "SELECT count(), min(time), max(time) FROM hubble.flows"

# Flows by source cluster, last 30 min (the attribution money-check, see V.1)
CH "SELECT \`flow/source/cluster_name\` AS cluster, count(), max(time)
    FROM hubble.flows WHERE time > now() - INTERVAL 30 MINUTE
    GROUP BY cluster ORDER BY count() DESC"

# Newest few flows with node + cluster (spot-check attribution)
CH "SELECT time, \`flow/source/cluster_name\`, \`flow/node_name\`
    FROM hubble.flows ORDER BY time DESC LIMIT 5 FORMAT TSV"

# Top talker namespaces in the last hour
CH "SELECT \`flow/source/namespace\` AS ns, count() FROM hubble.flows
    WHERE time > now() - INTERVAL 1 HOUR GROUP BY ns ORDER BY count() DESC LIMIT 15"

# On-disk size per table + active part count (storage + merge-pressure view)
CH "SELECT table, formatReadableSize(sum(bytes_on_disk)) sz, count() parts
    FROM system.parts WHERE active AND database='hubble' GROUP BY table ORDER BY sum(bytes_on_disk) DESC"
```

> **Reading `max(time)`:** `time` is the **flow event time**, not ingest time. If
> `max(time)` is stuck while MinIO keeps getting new objects, the ingester isn't
> consuming (W.3) — but a few minutes of lag is just the 5-min scan interval.

### W.5 — ClickHouse memory / merge pressure

Memory pressure here shows up as background **merges** failing (Code 241,
`memory limit exceeded ... in merge_task`), *not* the pod OOM-killing — CH rejects
the merge gracefully and retries. The pod limit on this lab is **8 GiB**; CH's
server-level cap (`max_server_memory_usage`) is auto-set to **0.9 × the cgroup
limit** (≈7.73 GiB). A per-query read cap (`max_memory_usage` = 4 GiB) is applied
via the `timescape_readonly_role` profile so a wide UI query fails gracefully
instead of starving merges.

```bash
NS=hubble-timescape-install
CHPOD=chi-hubble-timescape-hubble-data-0-0-0
CH() { oc -n $NS exec $CHPOD -- clickhouse-client --query "$1"; }

# Did the pod OOM-kill / restart? (RESTARTS should be 0; lastState empty)
oc -n $NS get pod $CHPOD -o jsonpath='restarts={.status.containerStatuses[0].restartCount} lastState={.status.containerStatuses[0].lastState}{"\n"}'

# cgroup current vs limit (the gap above MemoryTracking is reclaimable page cache)
oc -n $NS exec $CHPOD -- sh -c 'echo current=$(cat /sys/fs/cgroup/memory.current) max=$(cat /sys/fs/cgroup/memory.max)'

# CH's own tracked memory + the effective caps
CH "SELECT 'tracking', formatReadableSize(value) FROM system.metrics WHERE metric='MemoryTracking'"
CH "SELECT name, value FROM system.server_settings WHERE name IN ('max_server_memory_usage','max_server_memory_usage_to_ram_ratio')"
CH "SELECT setting_name, value FROM system.settings_profile_elements WHERE setting_name='max_memory_usage'"

# THE key signal: are memory-limit exceptions still happening, and how recently?
CH "SELECT toStartOfHour(event_time) h, count() FROM system.text_log
    WHERE event_time > now() - INTERVAL 6 HOUR AND message ILIKE '%memory limit exceeded%'
    GROUP BY h ORDER BY h FORMAT TSV"
CH "SELECT max(event_time), now() FROM system.text_log WHERE message ILIKE '%memory limit exceeded%' FORMAT TSV"

# Active merges right now + their memory use
CH "SELECT count() merges, formatReadableSize(sum(memory_usage)) FROM system.merges"
```

Interpretation: a falling-to-zero exception-per-hour trend after the limit bump
means it's resolved (the backlog merges that were thrashing at the old 4 GiB
limit drained). A flat non-zero trend means the limit is still too small for the
working set — raise `clickhouse.cluster.resources.limits.memory` (and re-check
that `max_server_memory_usage_to_ram_ratio` leaves merge headroom), reduce
`maxConcurrentQueries`, or apply `aggregation: connection` (X.4) to cut the part
churn. See X.6 for the production CH knobs.

---

## Section X — Production sizing & ClickHouse tuning

> **Source of the numbers below.** The per-flow byte sizes and flow rates are
> **measured on this lab** (base guide §F.5: 6-node cluster, Cilium 1.18.x,
> KPR=true). The formulas are vendor-neutral arithmetic. The chart keys
> (`clickhouse.ttl`, `clickhouse.userProfiles.*.maxMemoryUsage`,
> `clickhouse.storage.policy`, etc.) are verbatim from
> `helm show values isovalent/hubble-timescape --version 1.18.8`.
> **Reconcile these against the official Cisco/Isovalent sizing tables** (gated;
> open logged-in) before committing a large production deployment:
> - Export event sizes: `…/timescape/configure/configure-event-export-and-ingestion.html#object-storage-events-size`
> - ClickHouse storage: `…/timescape/configure/configure-clickhouse.html#clickhouse-storage`
> - ClickHouse tuning: `…/timescape/configure/configure-clickhouse.html#tuning-clickhouse`
> - Export monitoring: `…/timescape/hubble-flow-export/monitoring.html#export-events-monitoring`
>   (hosts: `iep-docs.cisco.com` or `docs.isovalent.com`). Where Cisco's figures
>   differ from the lab numbers here, **their figures win** — update this table.

### X.1 The sizing inputs you must establish first

Three numbers drive everything. Measure them, don't guess:

| Input | Symbol | How to get it (per source cluster) |
|---|---|---|
| Flow rate | `R` (flows/s) | Monitor the Cilium export metrics on each source — see X.5. Lab baseline: **~10k/s sustained, ~30k/s burst** per 6-node cluster |
| Bytes per flow (compressed, in ClickHouse) | `B_ch` | Lab-measured **~80–120 B/flow** (use 100 B). Equivalent to **~10–13 M flows per GiB** |
| Bytes per flow (in object storage, pre-ClickHouse) | `B_s3` | Hubble JSON flow log, gzip-rotated: budget **~150–250 B/flow** (larger than CH; less aggressive compression, full field set). Verify against the object-storage-events-size doc |
| Retention window | `T` (seconds) | Your policy. Set via `clickhouse.ttl` |
| Number of source clusters | `N` | Fan-in multiplier |

### X.2 ClickHouse storage formula

```
ClickHouse disk (bytes) ≈ Σ over clusters( R_i ) × B_ch × T × safety

  Σ R_i   = total ingest across all source clusters (flows/s)
  B_ch    = ~100 B/flow compressed   (lab; verify vs docs)
  T       = retention window in seconds (clickhouse.ttl)
  safety  = 1.3–1.5  (merges, parts, system logs, headroom)
```

**Worked examples** (using `B_ch = 100 B`, `safety = 1.35`):

| Scenario | Σ R | Retention | Raw | With safety |
|---|---|---|---|---|
| Lab, 1 cluster, no aggregation | 10k/s | 24 h | ~83 GiB | **~112 GiB** |
| Lab, 1 cluster, `aggregation: connection` (~10×) | 1k/s | 24 h | ~8 GiB | **~11 GiB** |
| Prod, 10 clusters, aggregation | 10×10k/10 = 10k/s effective* | 7 d | ~580 GiB | **~785 GiB** |
| Prod, 25 clusters, aggregation, 14 d | ~25k/s effective* | 14 d | ~2.9 TiB | **~3.9 TiB** |
| Prod, 50 clusters, aggregation, 30 d | ~50k/s effective* | 30 d | ~12.4 TiB | **~16.8 TiB** |

\* *effective* = raw rate × ~0.1 after `aggregation: connection`. **Always assume
aggregation in production** — per-packet fidelity at fleet scale is rarely
affordable. Without it, multiply the disk figures by ~10×.

> **Rule of thumb:** at `B_ch = 100 B`, **1 GiB ≈ 1 day of one cluster at
> ~120 flows/s** post-aggregation. Scale linearly by clusters, rate, and days.

### X.3 Object-storage (MinIO) sizing

MinIO is a **transit buffer**, not the system of record — size it for the
ingest lag window, not full retention.

```
MinIO disk (bytes) ≈ Σ R_i × B_s3 × L × safety
  L = max time data sits in the bucket before ingest + deletion (seconds)
```

- With `deleteAfterIngest: true` (X.4) and a healthy ingester, `L` is minutes →
  MinIO needs only **tens of GiB** even for a large fleet.
- With `deleteAfterIngest: false` (audit/replay use case), MinIO must hold full
  retention at `B_s3` — that's **larger** than ClickHouse. Add a bucket
  lifecycle rule as a hard backstop regardless:
  ```bash
  mc ilm rule add lab/timescape --expire-days 7
  ```
- **Production hardening:** the lab MinIO is single-node on NFS-backed bastion
  disk. For a real fleet use **distributed MinIO (erasure-coded, ≥4 drives)** on
  dedicated disks, not NFS-stacked, so uploader throughput from N clusters isn't
  bottlenecked on one spindle.

### X.4 Retention controls (apply at least one; production: all three)

1. **ClickHouse table TTL — the system of record.** Top-level `clickhouse.ttl`
   (chart default **2 weeks**; `1h` if running without persistent storage). Per
   event type via `clickhouse.flows.ttl`, `clickhouse.connectionLogs.ttl`, etc.
   ```yaml
   clickhouse:
     ttl: "336h"          # 14 days, all tables
     # flows:
     #   ttl: "168h"      # override flows to 7 days
   ```
   Or live, without a redeploy:
   ```bash
   oc -n hubble-timescape exec chi-hubble-timescape-hubble-data-0-0-0 -- \
     clickhouse-client --query \
     "ALTER TABLE hubble.flows MODIFY TTL time + INTERVAL 14 DAY"
   ```
2. **Object-store reclaim** — `deleteAfterIngest: true` on the ingester bucket
   so MinIO doesn't accumulate, plus the `mc ilm` lifecycle rule as backstop.
3. **Cilium-side aggregation** — `aggregation: [connection]` in the static
   exporter (Section S.1). The single biggest lever: ~10× on rate, disk, *and*
   object-store size simultaneously.

### X.5 Monitoring the export rate (to validate your `R`)

Establish the real `R` per cluster from metrics rather than the lab baseline.
Cilium exposes Hubble export counters on the agent metrics endpoint
(`cilium-agent` `--prometheus-serve-addr`, scraped by the
`cilium-agent` ServiceMonitor). Key series to graph:

```promql
# Exported events rate per node (flows/s) — sum for the cluster total R
sum(rate(hubble_export_events_total[5m]))

# Files written / rotated by the static exporter (sanity vs uploader)
rate(hubble_export_file_rotated_total[5m])

# Ingester side (central cluster): files ingested + flows inserted
rate(hubble_timescape_ingester_files_processed_total[5m])
rate(hubble_timescape_ingester_flows_inserted_total[5m])
```

> Metric names vary by Timescape/Cilium minor — **confirm against the
> export-events-monitoring doc** and `oc -n cilium exec ds/cilium -c cilium-agent
> -- cilium metrics list | grep -i export`. Use the *measured* `sum(rate(...))`
> as `Σ R_i` in the X.2 formula; don't carry the lab's 10k/s into a different
> workload mix.

### X.6 ClickHouse tuning for production (chart keys)

The base guide's single-node CH with `limits.memory: 4Gi` is a **lab** shape.
For fan-in at scale:

| Concern | Lab | Production guidance | Chart key |
|---|---|---|---|
| Memory cap | `4Gi` limit, no CH-level cap | Set a CH-level per-query cap *below* the pod limit so a wide query fails gracefully instead of OOM-killing the pod | `clickhouse.userProfiles.readOnly.maxMemoryUsage` (bytes) |
| Pod resources | 2Gi/4Gi | Size to the working set; CH likes RAM for merges + mark cache. Start `requests.memory: 8Gi`, `limits: 16Gi+` for multi-TiB datasets | `clickhouse.cluster.resources` |
| Concurrent queries | default 100 | Lower if UI + CLI + Grafana contend and you see memory pressure | `clickhouse.settings.maxConcurrentQueries` |
| System log bloat | default on, large over time | Cap aggressively — system logs can rival flow data | `clickhouse.settings.systemLogs.ttl` (e.g. `"3 day"`) |
| Broken parts at startup | 500 | Leave unless CH refuses to start after a crash | `clickhouse.settings.maxSuspiciousBrokenParts` |
| HA / sharding | single replica | Multi-replica CHI for HA; sharding for horizontal scale beyond one node's disk/CPU. Requires ClickHouse Keeper/ZooKeeper | `clickhouse.cluster.replicaCount` / operator CHI shape |
| Tiered storage (very large retention) | local PVC | Offload cold parts to S3 so the hot PVC stays small while keeping long retention queryable | `clickhouse.storage.policy: s3_cache` + `clickhouse.storage.s3.*` (experimental) |

Example production CH overrides:

```yaml
clickhouse:
  ttl: "336h"                              # 14-day retention
  userProfiles:
    readOnly:
      maxMemoryUsage: 10737418240          # 10 GiB per read query (< pod limit)
  settings:
    maxConcurrentQueries: 50
    systemLogs:
      ttl: "3 day"
  cluster:
    enabled: true
    replicaCount: 2                        # HA pair (needs Keeper/ZK)
    resources:
      requests: { cpu: "4",  memory: "8Gi" }
      limits:   { cpu: "8",  memory: "16Gi" }
    volumes:
      data:
        size: 4Ti                          # from the X.2 formula
        storageClassName: <fast-block-sc>  # NOT nfs-storage for production
```

> **Storage class:** NFS-on-bastion is fine for the lab but a poor fit for
> multi-TiB ClickHouse — merges are IOPS-heavy. Production wants a real block
> StorageClass (ODF/Ceph RBD, vSphere CSI, or local NVMe), not NFS.

### X.7 Fan-in deltas at a glance

| Knob | Single-cluster (lab) | Fan-in (N clusters, prod) |
|---|---|---|
| Ingest into ClickHouse | ~10k flows/s | Σ over clusters; **assume `aggregation: connection`** (~10×) |
| ClickHouse disk | 50 GiB ≈ 14 h | X.2 formula; fast block SC, not NFS |
| ClickHouse memory | `4Gi` pod limit | pod `16Gi+` *and* `maxMemoryUsage` per-query cap; filter queries by `--cluster` |
| ClickHouse topology | 1 replica | multi-replica (HA) ± shards; consider `s3_cache` tiering for long retention |
| MinIO disk | n/a | transit buffer only with `deleteAfterIngest: true`; distributed MinIO on dedicated disks |
| Retention | manual TTL | `clickhouse.ttl` + `deleteAfterIngest` + `mc ilm` + aggregation (all four) |

---

## Alternative — cross-cluster gRPC (no object store)

If you want the lightweight path instead of MinIO, the Cilium chart's
`hubble.export.timescape` block streams directly to a remote ingester:

```yaml
# Source cluster CiliumConfig
spec:
  hubble:
    export:
      timescape:
        enabled: true
        target: "<central-ingester-host>:4261"
        # REQUIRED when Timescape is in a different cluster without clustermesh:
        useCiliumServiceResolver: false
```

Expose the central ingester's `streamPort: 4261` off-cluster (NodePort/Route/LB)
and ensure each source can reach it. **Trade-offs:** no buffering or replay (a
central outage drops flows), every source needs L3 reach to 4261, and there's no
object-store audit trail. Fine for 2–3 clusters and a demo; object storage is
the durable design. (Chart comment confirms this mode is explicitly intended for
"Timescape running in a different cluster not using clustermesh.")

---

## Section P — Turning observed flows into NetworkPolicy

> **Common question: "can Timescape create network policy from the flows it
> sees?"** **No — not directly and not automatically.** Timescape is a flow
> *datastore + viewer* (ingester → ClickHouse → server → UI). It has no
> policy-authoring or recommendation engine and never pushes anything back to
> Cilium. The flow→policy workflow lives in **Hubble**, not Timescape. Below are
> the three real paths, and how to deploy the one that gives an interactive
> editor (the **Enterprise Hubble UI**).

### P.1 The three paths (least → most automated)

1. **Hand-write from what you see.** Use the Timescape UI (or `hubble observe`)
   to read the real source→dest→port flows, then author `CiliumNetworkPolicy`
   allowing exactly those and default-deny the rest. Timescape is the *evidence*;
   you write the YAML.
2. **Generate from flow JSON.** Your S3 buckets already hold gzipped Hubble flow
   JSON (`<cluster>/%Y/%m/%d/...log.gz`) — the exact format the **Network Policy
   Editor** (networkpolicy.io) and `cilium`/`hubble` CLI tooling consume. Pull a
   file (§W.2), decode it, feed it in, get a starter policy. No extra components.
3. **Interactive, in-cluster — the Enterprise Hubble UI** (deployed in P.2). The
   UI's Service Map lets you select flows and generate/refine policy visually.
   The building block is **`hubble-network-policy-correlation-enabled=true`** (it
   tags each flow with the policy that allowed/denied it) — already set on this
   lab's Cilium. The UI is what surfaces it.

> The Enterprise Hubble UI and **Timescape's** UI are **different UIs**. The
> Timescape UI (`hubble-timescape-ui` route) is historical flow forensics from
> ClickHouse. The Hubble UI (`hubble-ui`, deployed below) is the live Service Map
> + policy workflow, fed by `hubble-relay` reading the agents directly.

### P.2 Deploy the Enterprise Hubble UI (CLife-managed Cilium)

Cilium here is **CLife-operator managed** (no Helm release — `helm list` is
empty), so enable the UI through the `CiliumConfig` CR. `CiliumConfig.spec` is a
free-form passthrough (`x-kubernetes-preserve-unknown-fields: true`), so the keys
are the upstream Cilium Helm keys. The UI **requires `hubble-relay`** — enable
both. Images are `quay.io/isovalent/hubble-relay` and `quay.io/cilium/hubble-ui*`
(public; on this lab they route through the catch-all `quay.io → artifactory…`
IDMS/ITMS mirror, so they pull via Nexus).

```bash
source /root/tools-upi-install/lab-config.sh
export KUBECONFIG="${INSTALL_DIR}/auth/kubeconfig"

oc -n cilium patch ciliumconfig ciliumconfig --type=merge -p '
spec:
  hubble:
    relay:
      enabled: true
    ui:
      enabled: true
'
oc -n cilium rollout status deploy/hubble-ui    --timeout=3m
oc -n cilium rollout status deploy/hubble-relay --timeout=3m
```

### P.3 IMPORTANT — relay crashloops after a cluster-name change (cert SAN)

> **Hit on this lab 2026-06-01, immediately caused by the §V.1 cluster-name
> rename.** If you set the Cilium `cluster-name` *after* the cluster was first
> installed (as §V.1 does), the **Hubble server certificate is stale** — it was
> minted for the old name. `hubble-relay` then crashloops:
> ```
> tls: failed to verify certificate: x509: certificate is valid for
>   *.default.hubble-grpc.cilium.io, not hubble-peer.ocp-install.hubble-grpc.cilium.io
> ```
> The Hubble gRPC server SAN is `*.<cluster-name>.hubble-grpc.cilium.io`, baked
> into `hubble-server-certs` at issue time; renaming the cluster invalidates it.

**Fix — reissue the Hubble leaf certs as a coherent set.** Delete **both**
`hubble-server-certs` and `hubble-relay-client-certs` *together* and let the
operator re-mint them from one CA in a single reconcile, then reload:

```bash
# Delete BOTH leaf certs together — do NOT delete only the server cert.
oc -n cilium delete secret hubble-server-certs hubble-relay-client-certs
oc -n cilium rollout restart deploy/cilium-operator     # reissues both
# Agents serve the server cert from the mounted secret → must reload it:
oc -n cilium rollout restart ds/cilium
oc -n cilium rollout restart deploy/hubble-relay
oc -n cilium rollout status  ds/cilium --timeout=6m
oc -n cilium rollout status  deploy/hubble-relay --timeout=3m
```

> **Why delete both, not just the server cert (learned the hard way):** deleting
> only `hubble-server-certs` makes the operator mint a fresh **Hubble CA** for
> the new server cert, but `hubble-relay-client-certs` still trusts the *old* CA
> → the SAN error is replaced by `certificate signed by unknown authority
> ("Cilium CA")`. Deleting both forces server cert and relay-client to be
> re-issued under the **same** CA. Verify the keys line up:
> ```bash
> echo -n "server cert AKI:    "; oc -n cilium get secret hubble-server-certs \
>   -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -text | grep -A1 "Authority Key" | tail -1
> echo -n "relay-client trust: "; oc -n cilium get secret hubble-relay-client-certs \
>   -o jsonpath='{.data.ca\.crt}' | base64 -d | openssl x509 -noout -text | grep -A1 "Subject Key"  | tail -1
> # The two key IDs MUST match. Server SAN must read *.<cluster-name>.hubble-grpc.cilium.io.
> ```
>
> **Avoid this entirely on fresh builds** by baking `cluster.name`/`cluster.id`
> into the install (gen-ignition / first CiliumConfig) so the certs are minted
> right the first time — see §V.1.

### P.4 Expose and use the UI

```bash
# Route (edge TLS), same pattern as the Timescape UI route
oc -n cilium create route edge hubble-ui --service=hubble-ui --port=http --insecure-policy=Redirect
oc -n cilium get route hubble-ui -o jsonpath='{.spec.host}{"\n"}'
```

In the UI: pick a namespace → **Service Map** shows live identities and flows
(allowed vs dropped, correlated to the policy that decided each, thanks to
`hubble-network-policy-correlation-enabled`). Selecting connections lets you
build a `CiliumNetworkPolicy` from the observed edges; export the YAML and apply
it with `oc apply`. Validate it in **audit mode** first
(`policy-audit-mode`/`CiliumNetworkPolicy` dry-run) before flipping to enforce,
so you don't blackhole real traffic.

> **Scope note:** the Hubble UI shows **live** flows from the local cluster's
> agents (via relay) — it is *not* the multi-cluster historical view. For
> cross-cluster / historical policy evidence use Timescape (filter by
> `--cluster`, §V). Workflow: Timescape to *find* what talks across the fleet
> over time → Hubble UI (or flow-JSON → editor) to *author* the policy.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Ingester logs only `tick`, 0 files | Nothing in the bucket, or `prefixPattern` ≠ uploader `s3_key_format` | `mc ls lab/timescape/<cluster>/`; align the `%Y/%m/%d` prefix exactly |
| `helm upgrade` error: bucket config conflict | Both `ingester.bucket.uri` and `config.buckets` set | They are mutually exclusive — leave `ingester.bucket.uri: ""` |
| Flows ingested but `flow/source/cluster_name` is `default`/empty | **`overrideClusterName` does NOT stamp these columns** — they come from the source Cilium agent's `cluster-name` (still `default`) | Set `cluster.name`/`cluster.id` in the source `CiliumConfig`, then **force** `oc -n cilium rollout restart ds/cilium` (the patch alone won't restart agents). See **Section V.1** |
| `SELECT cluster_name ...` → `Unknown identifier cluster_name` | No bare column; names contain slashes | Use `` `flow/source/cluster_name` `` / `` `flow/destination/cluster_name` `` (backtick-quoted). See W.4 |
| `oc rollout status ds/cilium` says "rolled out" but flows unchanged | ConfigMap-only change → DS pod template unchanged → **agents never cycled** | Force `oc -n cilium rollout restart ds/cilium`; confirm `.status.startTime` is recent (V.1 gotcha) |
| Two clusters' flows merged under one name | Shared prefix, or duplicate Cilium `cluster-name`/`cluster-id` | Give each cluster a unique prefix **and** a unique Cilium `cluster.name`+`cluster.id` (V.1) |
| `mc: No valid configuration found for 'lab' host alias` | `mc` alias doesn't persist across `podman run --rm` | Set the alias and run commands in the **same** container (`--entrypoint=/bin/sh -c '...'`); see the `mcsh` helper in W.1 |
| ClickHouse `memory limit exceeded ... in merge_task` (Code 241), pod NOT OOM-killed | Background merges hitting `max_server_memory_usage`; pod limit too small for working set | Graceful (CH retries). If recurring: raise `clickhouse.cluster.resources.limits.memory`, lower `maxConcurrentQueries`, or apply `aggregation: connection`. Diagnose with W.5 |
| `hubble-relay` crashloops: `certificate is valid for *.default.hubble-grpc... not ...ocp-install...` | Cluster renamed after install → stale `hubble-server-certs` SAN | Reissue Hubble certs — **delete both** `hubble-server-certs` + `hubble-relay-client-certs`, restart operator + agents + relay (P.3) |
| `hubble-relay` crashloops: `certificate signed by unknown authority ("Cilium CA")` | Only the server cert was reissued → server CA ≠ relay-client's trusted CA | Delete **both** leaf certs together so they re-mint under one CA; verify server AKI == relay-client trusted SKI (P.3) |
| Hubble UI deploys but shows no flows / backend errors | `hubble-relay` not Ready (UI backend depends on relay) | Fix relay first (P.3); UI needs relay healthy |
| Ingester `AccessDenied` / `SignatureDoesNotMatch` | Missing/incorrect S3 creds or path-style | Verify R.1 secret; ensure `use_path_style=true` (MinIO needs path-style) |
| Ingester `failed to parse endpoint URL: … first path segment in URL cannot contain colon` | `endpoint=` missing a scheme (1.18.8 AWS SDK v2 needs it) | Use `endpoint=http://host:port` (with scheme); see the DSN callout in R.2 |
| Ingester `s3 query parameter is no longer supported … param=disableSSL` | Old chart-comment DSN form on 1.18.8 | Replace `disableSSL`→`disable_https`, `s3ForcePathStyle`→`use_path_style`; add `region=us-east-1` |
| Ingester TLS handshake error to MinIO | HTTPS MinIO without CA, or `disable_https` left on | Add `bucket.tls.ca.configMap` and drop `disable_https=true`, or use plain HTTP consistently |
| Uploader sidecar `connection refused` to :9000 | Firewall / no L3 reach from source cluster | `firewall-cmd --add-port=9000/tcp`; verify routing from a source node |
| Cilium DS has no `hubble.log` files | static exporter keys didn't render (CLife race) | Confirm `cilium-config` has `hubble-export-file-path`, force a second `rollout restart ds/cilium` (Section S.1) |
| MinIO disk filling | `deleteAfterIngest` off | Set `deleteAfterIngest: true` once ingest is trusted; add a bucket lifecycle rule as backstop |

## References

- Base single-cluster guide: [`OCP_IEP_Timescape_Guide.md`](OCP_IEP_Timescape_Guide.md)
- Chart values (authoritative): `helm show values isovalent/hubble-timescape --version 1.18.8`, `helm show values isovalent/cilium --version 1.18.9`
- gocloud blob DSN form (S3-compatible, **Timescape 1.18.8 / AWS SDK v2** — verified at runtime, not the chart-comment form): `s3://<bucket>?endpoint=http://<host:port>&disable_https=true&use_path_style=true&region=us-east-1`
- Isovalent docs (Cisco, gated): https://docs.cisco.com/iep/

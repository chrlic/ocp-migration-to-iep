# Timescape PolicyGen

A Timescape-style web GUI that turns **observed Hubble flows** (already in
Timescape's ClickHouse) into **CiliumNetworkPolicy**. You pick a target
**cluster → namespace → workload(s)** (or the whole namespace), an optional
source filter, and a timeframe; it aggregates the flows seen in that window and
emits ready-to-apply CNP YAML.

**Phase 1 (this version): L4** — protocol + port, ingress (and optional egress),
FORWARDED flows by default (DROPPED optionally, for audit). **Phase 2: L7** —
the ClickHouse schema already exposes `flow/l7/http/*`, `flow/l7/dns/query`,
`flow/l7/kafka/topic`; the `Edge`/`PortRule` types have `TODO(l7)` hooks to add
`toPorts.rules`.

## Why a separate app and not the Hubble UI

The OSS Hubble UI (`quay.io/cilium/hubble-ui:v0.13.5`, deployed in this lab) is
**observe/correlate only** — it shows flows and which policy allowed/denied them,
but has no policy *generator*. Timescape itself is a flow datastore, not a policy
tool. This app fills that gap, and unlike the Network Policy Editor it works
directly against the **historical, multi-cluster** Timescape data: because the
central Timescape ClickHouse ingests every source cluster's flows (the S3 fan-in,
attributed by `flow/source/cluster_name`), the **cluster selector** lets you
author policy for any cluster in the fleet from one place — including remote
Phase-2 clusters as they come online, with no app change.

## Architecture

```
 Vue 3 SPA ──/api──► Go backend ──native :9000──► Timescape ClickHouse (hubble.flows)
 (selectors,         (parameterized queries,        read-only SELECTs
  YAML view)          CNP synthesis, YAML)          default user)
```

- **Backend (Go).** Holds the only ClickHouse credentials; the browser never
  touches CH. Every flows query is **parameterized** — user input is bound, never
  string-interpolated (the `flow/...` slash-column names are hard-coded constants).
  Endpoints: `/api/clusters`, `/api/namespaces`, `/api/workloads`, `/api/generate`.
- **Policy synthesis (`internal/policy`).** Groups edges by peer selector, nests
  `(proto,port)` under one rule's `toPorts`, and emits CNP. Two scopes:
  - `workload` — one CNP per target, `endpointSelector` = identity labels
    (pod-template-hash / controller-revision / reserved labels stripped so it
    survives rollouts).
  - `namespace` — one CNP, `endpointSelector` = namespace only.
  Peers with no pod (host/world/kube-apiserver/…) become `fromEntities`/`toEntities`
  via the reserved-identity map, not bogus endpoint selectors.
- **Frontend (Vue 3 + Pinia + Vite).** Cascading selectors, edge tables, YAML
  pane with copy/download.

## Build (air-gapped via Nexus)

Neither Go nor Node is on the bastion; build as a container so the toolchain
images come through the lab Nexus mirror:

```bash
cd /root/timescape-policygen
podman build -t artifactory.ocp-migrate.md.prglab.local:8443/timescape-policygen:0.1 .
podman push artifactory.ocp-migrate.md.prglab.local:8443/timescape-policygen:0.1
```

> **npm proxy prerequisite:** the frontend stage runs `npm install`. If the lab
> Nexus doesn't yet proxy the npm registry, either add an `npm` proxy repo (same
> pattern as the docker proxies) and an `.npmrc` pointing at it, or vendor
> `frontend/node_modules` and drop the `npm install` line. The Go module proxy is
> handled the same way (`GOPROXY` / vendored `backend/vendor`).

## Deploy

```bash
oc apply -f deploy/policygen.yaml      # edit the image ref first
oc -n timescape-policygen get route timescape-policygen -o jsonpath='https://{.spec.host}{"\n"}'
```

Runs in the install cluster next to Timescape so it reaches ClickHouse over the
`clickhouse-hubble-timescape` Service. Read-only and non-root.

## Local dev

```bash
# backend (needs a CH it can reach — port-forward the lab's):
oc -n hubble-timescape-install port-forward svc/clickhouse-hubble-timescape 9000:9000 &
cd backend && CH_ADDR=localhost:9000 CH_USER=default go run .
# frontend (proxies /api → :8080):
cd frontend && npm install && npm run dev
```

## Using it

1. Pick timeframe, **cluster**, **namespace**.
2. Scope = **per workload** (select Deployments/DaemonSets/StatefulSets) or
   **whole namespace**.
3. Optional: restrict the **source namespace**; toggle **egress** and **include
   DROPPED** (audit — shows what a default-deny *would* block).
4. **Generate** → review the edge tables and the CNP YAML → Copy/Download.
5. **Apply in audit mode first** (`policy-audit-mode`, or a CNP dry-run) before
   enforcing, so you don't blackhole real traffic. The generator only ever
   *allows* what was observed; anything it didn't see in the window is implicitly
   denied once you enforce — widen the timeframe to avoid missing periodic jobs.

## Worked example (validated against the lab, 2026-06-01)

Target = Deployment `metrics-server` in `openshift-monitoring`, scope=workload,
ingress, 60-min window. The observed edges (from `hubble.flows`) include
`reserved:remote-node → metrics-server TCP/10250` and `reserved:host →
metrics-server TCP/...`. The generator emits:

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-observed-metrics-server
  namespace: openshift-monitoring
  labels:
    generated-by: timescape-policygen
    target-kind: deployment
    target-name: metrics-server
spec:
  endpointSelector:
    matchLabels:
      k8s:io.kubernetes.pod.namespace: openshift-monitoring
      k8s:app.kubernetes.io/name: metrics-server   # identity labels only
  ingress:
    - fromEntities: [remote-node]                   # node-sourced scrape, no pod
      toPorts:
        - ports:
            - { port: "10250", protocol: TCP }
```

Note the node-scrape peer becomes `fromEntities: [remote-node]` (not a bogus pod
selector) — this is why the generator reads `flow/source/identity` and maps
reserved identities to entities.

## Caveats / honest limits

- **Observed ⊂ required.** A short window misses cron/backup/failover traffic.
  Generate over a representative window; treat output as a strong starting draft,
  not gospel.
- **Identity labels heuristic.** Label stripping targets common k8s plumbing; an
  app using an unusual identifying label may need a manual selector tweak.
- **Egress to world/DNS** is emitted as entities/ports at L4; real egress policy
  usually wants L7 DNS rules (phase 2) for `toFQDNs`.
- **No clustermesh assumptions.** Cross-cluster peers appear by their
  `cluster_name`; in-cluster selectors assume same-cluster enforcement.

# OCP UPI ↔ Isovalent Networking for Kubernetes Labs

End-to-end automation and runbooks for two parallel OpenShift UPI labs on
vSphere (`platform: none`), both fronted by a shared Nexus OSS pull-through
proxy on the same bastion host:

1. **Migration lab** ([`OCP_IEP_Migration_Guide.md`](guide/OCP_IEP_Migration_Guide.md)) — OCP 4.16 + OVN-Kubernetes, then migrated in-place to **Isovalent Networking for Kubernetes 1.17** via the CLife operator. Validated end-to-end across multiple wipe-and-rebuild iterations.
2. **Fresh-install lab** ([`OCP_IEP_Install_Guide.md`](guide/OCP_IEP_Install_Guide.md)) — OCP 4.20 + **IEP 1.18 baked in at bootstrap** (`networkType: Cilium`, no OVN). Parallel to the migration lab on the same bastion, distinct IP block (`.29-.37` vs `.19-.27`), distinct vSphere folder + ISO + HAProxy instance.

Both labs include an inline / sibling Hubble Timescape deployment.

## Status

### Migration lab (`tools-upi-migrate/`, validated)

- **OCP version:** 4.16.36 UPI, `platform: none`
- **IEP version:** 1.17.15 (latest 1.17.x certified on OCP 4.16 per Red Hat
  article [5436171](https://access.redhat.com/articles/5436171); IEP 1.18 is
  **not** certified on 4.16)
- **Topology:** 3 masters + 3 workers + 1 (temporary) bootstrap, all RHCOS on
  vSphere
- **Registry:** Nexus OSS 3.x as a pull-through proxy for `quay.io`,
  `registry.redhat.io`, `registry.connect.redhat.com`, `quay.io/isovalent`,
  `quay.io/openshift-release-dev`, `docker.io`
- **Cilium config:** `kubeProxyReplacement: "true"`, pod CIDR `10.253.0.0/16`
  (non-overlapping with OVN's `10.128.0.0/14`)

### Fresh-install lab (`tools-upi-install/`, **validated end-to-end 2026-05-30**)

- **OCP version:** 4.20.x UPI, `platform: none`, `networkType: Cilium`
- **IEP version:** 1.18.x (latest 1.18 — 4.20-certified per
  [Red Hat 5436171](https://access.redhat.com/articles/5436171))
- **Topology:** 3 masters + 3 workers + 1 bootstrap, `*-i-N (install)` in vSphere
- **Coexistence:** shares the migration lab's bastion, Nexus, dnsmasq/TFTP and
  httpd; runs its own `haproxy-install.service` bound to `192.168.39.30`
- **Pod / service CIDRs:** `10.244.0.0/14` / `172.31.0.0/16` (non-overlapping
  with migration cluster)
- **Status:** **validated end-to-end on 2026-05-30**. OCP 4.20.24 installed cleanly first try (no MCP autofix needed); CLife auto-upgraded to 1.18.10-cee.1 via OLM; Timescape 1.18.8 deployed via the public Helm chart (devhub entitlement gap pivoted to Helm); 10k flows/s sustained; UI Route HTTP 200; hubble CLI 1.18.6 + Timescape 1.18.8 queries clean.

## Compatibility references

| Topic | Authoritative link |
|---|---|
| OCP support phases (Full / Maintenance / EUS) | https://access.redhat.com/support/policy/updates/openshift |
| IEP CNI certification matrix | https://access.redhat.com/articles/5436171 |
| Isovalent install procedure | https://docs.isovalent.com/iep/latest/ink/install/openshift.html (login) |

## Repository layout

```
/root/
├── README.md                              ← this file
├── CLAUDE.md                              ← assistant context (project conventions)
├── guide/
│   ├── OCP_IEP_Migration_Guide.md         ← migration lab runbook (install → migrate → cleanup)
│   ├── OCP_IEP_Timescape_Guide.md         ← migration-cluster follow-up: persistent flow observability
│   └── OCP_IEP_Install_Guide.md           ← fresh-install lab (OCP 4.20 + IEP 1.18, inline Timescape)
├── tools-upi-migrate/                     ← migration lab scripts (single source of truth)
│   ├── lab-config.sh                      ← edit «CHANGE» items before anything else
│   ├── setup-artifactory.sh               ← Nexus pull-through proxy
│   ├── setup-haproxy.sh                   ← API/MCS/Ingress/Nexus load balancing
│   ├── setup-httpd.sh                     ← httpd:8080 for ignition + rootfs
│   ├── download-rhcos.sh                  ← RHCOS live ISO + rootfs
│   ├── gen-ignition.sh                    ← install-config → manifests → ignition
│   ├── recreate-vms.sh                    ← create/recreate VMs in vSphere
│   ├── upload-iso.sh                      ← push ISO to datastore (VMs off!)
│   ├── setup-pxe.sh                       ← dnsmasq DHCP+TFTP, per-MAC grub
│   ├── pxe-install-and-boot.sh            ← orchestrated PXE install of all VMs
│   ├── monitor-install.sh                 ← bootstrap → CSRs → install-complete
│   ├── remove-bootstrap-from-haproxy.sh   ← drop bootstrap from HAProxy
│   ├── get-kubeconfig.sh                  ← recover kubeconfig after cert rotation
│   ├── get-console-creds.sh               ← console URL + kubeadmin creds + hosts
│   ├── do-migration.sh                    ← FULL OVN→Cilium migration Phase 1-6
│   ├── check-cilium.sh                    ← post-migration health check
│   ├── patch-cilium-k8s-host.sh           ← LEGACY: only for KPR=false setups
│   ├── all.sh                             ← convenience: run install end-to-end
│   ├── delete-vms.sh                      ← teardown
│   └── govc-env.sh                        ← sourced GOVC_* exports
├── tools-upi-install/                     ← fresh-install lab scripts (parallel to tools-upi-migrate)
│   ├── lab-config.sh                      ← « CHANGE » items + reuses Nexus from migration lab
│   ├── setup-haproxy.sh                   ← second HAProxy instance on .30 (untouched migration LB)
│   ├── setup-httpd.sh                     ← adds /ignition-install/ + /rhcos-install/ aliases
│   ├── download-rhcos.sh                  ← RHCOS 4.20 ISO + rootfs
│   ├── setup-nfs.sh                       ← separate /srv/nfs/openshift-install export
│   ├── gen-ignition.sh                    ← networkType: Cilium baked in, CLife manifests in manifests/
│   ├── recreate-vms.sh, upload-iso.sh, setup-pxe.sh, pxe-install-and-boot.sh   ← install path
│   ├── monitor-install.sh                 ← bootstrap → CSRs → install-complete
│   ├── remove-bootstrap-from-haproxy.sh   ← edits haproxy-install.cfg only
│   ├── get-kubeconfig.sh, get-console-creds.sh   ← post-install helpers
│   ├── setup-storage.sh                   ← nfs-storage-install StorageClass in the cluster
│   ├── start-vms.sh, delete-vms.sh, govc-env.sh
│   └── (no patch-cilium-k8s-host.sh — not needed for fresh KPR=true install)
├── doc-sources/                           ← upstream Isovalent reference docs
│   ├── iep-installation.txt               ← (older 1.17-era install reference)
│   ├── iep-migration.txt
│   ├── iep-claude-guide.txt
│   ├── iep-1.18-openshift-install.txt     ← fresh-fetched 1.18 OCP install procedure
│   ├── iep-1.18-timescape-on-openshift.txt ← fresh-fetched 1.18 Timescape operator procedure
│   └── OCP_AirGapped_Deployment_Guide.md
├── ocp-upi-migrate/                       ← migration lab openshift-install working dir (generated)
│   ├── auth/kubeconfig                    ← migration cluster kubeconfig
│   ├── auth/kubeadmin-password
│   └── clife/                             ← downloaded + customized CLife 1.17 manifests
├── ocp-upi-install/                       ← install lab openshift-install working dir (generated)
│   ├── auth/kubeconfig                    ← install cluster kubeconfig
│   └── clife/                             ← downloaded + customized CLife 1.18 manifests
├── pull-secret.json                       ← Red Hat pull secret (your file — shared)
├── pull-secret-with-art.json              ← merged pull secret incl. Nexus creds (shared)
├── clife-v1.17.15.tar.gz                  ← migration lab CLife tarball
├── clife-v1.18.9.tar.gz                   ← install lab CLife tarball
└── networkpolicies-backup.yaml            ← migration Section 5.4 backup
```

## Quick start

### Migration lab (OCP 4.16 + IEP 1.17 via OVN→Cilium)

```bash
# 1. Edit lab variables
vi /root/tools-upi-migrate/lab-config.sh
source /root/tools-upi-migrate/lab-config.sh

# 2. Bastion setup (one-time)
cd /root/tools-upi-migrate
./setup-artifactory.sh
./setup-haproxy.sh
./setup-httpd.sh
./download-rhcos.sh

# 3. Install OCP 4.16
./gen-ignition.sh
./recreate-vms.sh        # VMs powered off
./upload-iso.sh
./setup-pxe.sh
./pxe-install-and-boot.sh
./monitor-install.sh     # waits for install-complete
./get-console-creds.sh   # show console URL + kubeadmin password

# 4. Deploy a test workload + run pre-migration gates (Sections 4, 5 of the guide)
# 5. Customize CLife manifests (Section 6 of the guide)
# 6. Migrate to Cilium
./do-migration.sh -y     # full Phase 1-6 unattended
# 7. Approve OLM InstallPlan and verify (Section 8)
# 8. Post-migration cleanup (Section 9)
```

Full runbook: [`guide/OCP_IEP_Migration_Guide.md`](guide/OCP_IEP_Migration_Guide.md).
Follow-up Timescape: [`guide/OCP_IEP_Timescape_Guide.md`](guide/OCP_IEP_Timescape_Guide.md).

### Fresh-install lab (OCP 4.20 + IEP 1.18, Cilium baked in)

Assumes the migration lab's bastion services (Nexus, dnsmasq, httpd) are
already running. The install lab adds its own pieces around them.

```bash
# 1. Edit install-lab variables (most defaults are fine)
vi /root/tools-upi-install/lab-config.sh
source /root/tools-upi-install/lab-config.sh

# 2. Bastion additions
cd /root/tools-upi-install
./setup-haproxy.sh       # second HAProxy instance bound to 192.168.39.30
./setup-httpd.sh         # /ignition-install/ + /rhcos-install/ aliases
./download-rhcos.sh      # RHCOS 4.20 ISO + rootfs
./setup-nfs.sh           # /srv/nfs/openshift-install export

# 3. Install OCP 4.20 with Cilium baked in
./gen-ignition.sh        # networkType: Cilium, CLife manifests in manifests/
./recreate-vms.sh        # 7 VMs in vSphere folder OCP-Install
./upload-iso.sh
./setup-pxe.sh           # additive: per-MAC + dhcp-host entries only
./pxe-install-and-boot.sh
./monitor-install.sh
./get-console-creds.sh

# 4. Approve CLife OLM InstallPlan (Section 6 of the guide)
# 5. Verify (Section 7)
# 6. (Optional) Bookinfo sanity workload (Section 8)
# 7. Hubble Timescape via the IEP 1.18 operator (Section 9)
./setup-storage.sh       # nfs-storage-install SC
# ... then apply Timescape CatalogSource + Subscription + TimescapeConfig per Section 9
```

Full runbook: [`guide/OCP_IEP_Install_Guide.md`](guide/OCP_IEP_Install_Guide.md).

## Validated procedure

The full sequence (install → Bookinfo deploy → pre-migration gates → CLife
customize → migration via `do-migration.sh -y` → post-migration verification
→ cleanup) has been run end-to-end multiple times. Last full validation
took ~75 minutes wall-clock on the lab hardware:

| Phase | Time |
|---|---|
| PXE install (rebuild-test.sh) | ~38 min |
| Bookinfo deploy | ~5 min |
| Pre-migration gates | <1 min |
| CLife customize (Section 6) | <1 min |
| Migration (`do-migration.sh -y`) | ~26 min |
| Verify + cleanup | ~5 min |

## Key gotchas (resolved in current scripts/guide)

1. **IDMS and ITMS must be in separate files under `openshift/`.** Bootkube
   applies one resource per file under `openshift/`; multi-doc YAML drops the
   second document silently. If combined, IDMS lands but ITMS doesn't, and
   the master MCP goes Degraded on `/etc/containers/registries.conf` content
   mismatch. `gen-ignition.sh` writes them as two files.
2. **CLife tarball URL path depends on the IEP minor.** 1.18.x is under
   `docs.isovalent.com/v25.11/public/clife/`; 1.17.x under `v1.17/public/clife/`.
   Filename has no `-cee.N` suffix for 1.17+; legacy `-cee.N` for 1.16 and
   earlier. The image tag in the deployment still carries `-cee.N`. See
   `lab-config.sh` `CLIFE_DOCS_PATH`.
3. **Bookinfo deploy names have a `-v1` suffix** for productpage/details/ratings
   (upstream YAML quirk). The `reviews` app has explicit v1/v2/v3 deployments.
4. **`productpage` image has no `curl`.** Use `python -c "import urllib.request..."`
   for pod-to-pod tests.
5. **OLM `BundleUnpackFailed` after migration** is a known race when the
   unpack job lands during the network-in-flux window of Phase 4. Recovery:
   delete the stale job in `openshift-marketplace`, recreate the Subscription.
   Documented in Section 8.3.
6. **`patch-cilium-k8s-host.sh` is NOT needed under `kubeProxyReplacement: "true"`.**
   Cilium's BPF socket-LB handles ClusterIP routing for both pod-network and
   host-network sockets. The script is kept for `kubeProxyReplacement: false`
   + CNI-chaining setups only.

## Prerequisites

- **Bastion:** CentOS Stream 9 or RHEL 9, internet access via the corporate
  WSA proxy, `podman`, `oc`, `openshift-install`, `yq` v4, `jq`, `skopeo`,
  HAProxy, `httpd`, `dnsmasq`, syslinux/shim/grub2-efi for PXE
- **vSphere:** account with VM create/delete/power; one DVS port group on
  `192.168.39.0/24`
- **DNS:** working DNS server resolving `*.apps.<cluster>.<base-domain>` and
  `api{,-int}.<cluster>.<base-domain>` to the bastion IP (HAProxy frontend)
- **Pull secret:** Red Hat pull secret from
  [console.redhat.com/openshift/install/pull-secret](https://console.redhat.com/openshift/install/pull-secret)
  saved to `/root/pull-secret.json`
- **License:** Isovalent license is **not** required for downloading the
  public CLife tarball or pulling images from `quay.io/isovalent` (those are
  public). It is required for production support

## Doc sources

The procedure is based on the upstream Isovalent documentation:

- [`doc-sources/iep-installation.txt`](doc-sources/iep-installation.txt) —
  *Install Networking for Kubernetes on Red Hat OpenShift*
- [`doc-sources/iep-migration.txt`](doc-sources/iep-migration.txt) —
  *Migrate from OpenShift OVN-Kubernetes to Networking for Kubernetes*
- [`doc-sources/iep-claude-guide.txt`](doc-sources/iep-claude-guide.txt) —
  vendor-provided runbook draft
- [`doc-sources/OCP_AirGapped_Deployment_Guide.md`](doc-sources/OCP_AirGapped_Deployment_Guide.md) —
  reference for fully air-gapped variant (this lab uses the proxy variant)

For canonical IEP/OCP compatibility, consult Red Hat article
[5436171](https://access.redhat.com/articles/5436171). The compatibility table
is also reproduced in the guide's "Important Notices" section.

## Support boundary

This lab is for **development/validation**. Per Red Hat, an in-place network
migration on a live cluster is not Red Hat-supported; it is supported by
Isovalent/Cisco. Engage Isovalent support before any production migration.

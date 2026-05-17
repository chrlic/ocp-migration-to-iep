# OCP UPI → Isovalent Networking for Kubernetes Migration Lab

End-to-end automation and runbook for installing OpenShift 4.16 UPI on vSphere
(`platform: none`) with a Nexus OSS pull-through proxy, then migrating the
cluster in-place from OVN-Kubernetes to **Isovalent Networking for Kubernetes**
(Isovalent Enterprise Cilium / IEP) using the CLife operator.

This repository lives entirely on the bastion host. The procedure has been
validated end-to-end across multiple wipe-and-rebuild iterations.

## Status

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

## Repository layout

```
/root/
├── README.md                              ← this file
├── CLAUDE.md                              ← assistant context (project conventions)
├── guide/
│   └── OCP_IEP_Migration_Guide.md         ← step-by-step runbook
├── tools-upi-migrate/                     ← all scripts (single source of truth)
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
├── doc-sources/                           ← upstream Isovalent reference docs
│   ├── iep-installation.txt
│   ├── iep-migration.txt
│   ├── iep-claude-guide.txt
│   └── OCP_AirGapped_Deployment_Guide.md
├── ocp-upi-migrate/                       ← openshift-install working dir (generated)
│   ├── auth/kubeconfig                    ← cluster kubeconfig
│   ├── auth/kubeadmin-password
│   └── clife/                             ← downloaded + customized CLife manifests
├── pull-secret.json                       ← Red Hat pull secret (your file)
├── pull-secret-with-art.json              ← merged pull secret incl. Nexus creds
├── clife-v1.17.15.tar.gz                  ← downloaded CLife tarball
└── networkpolicies-backup.yaml            ← Section 5.4 backup
```

## Quick start

```bash
# 1. Edit lab variables — all « CHANGE » items in lab-config.sh
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

# 4. Deploy a test workload + run pre-migration gates
# (see Section 4 and Section 5 of the guide)

# 5. Customize CLife manifests
# (Section 6 of the guide — three files in ${CLIFE_DIR})

# 6. Migrate to Cilium
./do-migration.sh -y     # full Phase 1-6 unattended

# 7. Approve OLM InstallPlan and verify
# (Section 8 of the guide)

# 8. Post-migration cleanup
# (Section 9 of the guide)
```

The full runbook with commands, expected output, and troubleshooting is
[`guide/OCP_IEP_Migration_Guide.md`](guide/OCP_IEP_Migration_Guide.md). See
**Section 1.4 — Scripts Overview** in the guide for the script-by-script
ordering with cross-references to the guide sections that explain each step.

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

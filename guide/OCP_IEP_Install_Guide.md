# OCP 4.20 UPI + Isovalent Networking for Kubernetes 1.18 — Fresh Install Lab

End-to-end runbook for installing OpenShift 4.20 UPI on vSphere
(`platform: none`) with **Isovalent Networking for Kubernetes 1.18** (Cilium)
as the CNI from day one — **no OVN-Kubernetes, no migration**. Includes inline
Hubble Timescape deployment.

This is a **parallel guide** to
[`OCP_IEP_Migration_Guide.md`](OCP_IEP_Migration_Guide.md). The two labs share
a bastion (192.168.39.20) and a Nexus pull-through proxy but are otherwise
independent: separate VMs, separate IP block, separate HAProxy instance,
separate NFS export, separate StorageClass, separate vSphere folder.

## Compatibility & support

**OCP support policy:** OpenShift minor releases have defined Full Support,
Maintenance Support, and Extended Update Support phases. Always check the
current support phase for your target version before planning a new install:
[https://access.redhat.com/support/policy/updates/openshift](https://access.redhat.com/support/policy/updates/openshift).

**IEP / OCP compatibility:** Cisco Isovalent Networking for Kubernetes
certifications on OCP are tracked in
[Red Hat article 5436171 — *OpenShift CNI Plug-in Support*](https://access.redhat.com/articles/5436171)
(Cisco Isovalent section). Snapshot for OCP 4.20:

| Product name | IEP version | Install methods | Certified OCP versions | Tests passed |
|---|---|---|---|---|
| Isovalent Networking for Kubernetes | 1.17 | UPI and IPI | 4.16, 4.18, 4.19, 4.20 | Net, Virt, Mesh, HCP |
| Isovalent Networking for Kubernetes | 1.18 | UPI and IPI | 4.20 | Net, Virt, Mesh, HCP |

This guide installs **1.18 on 4.20** — the newest 4.20-certified row.

## Status snapshot of what the guide builds

- **OCP version:** 4.20.x UPI, `platform: none`, `networkType: Cilium`
- **IEP version:** 1.18.x (chart and tarball both follow Cilium minor)
- **Topology:** 3 masters + 3 workers + 1 bootstrap VM (`*-i-N (install)` in vSphere)
- **IP block:** `192.168.39.29–.37` on the migration lab's `/24` (HAProxy `.30` VIP)
- **Nexus:** **reused** from the migration lab (`artifactory.ocp-migrate.md.prglab.local:8443`)
- **HAProxy:** **second instance** (`haproxy-install.service`) on the same bastion, bound to `.30:6443/22623/80/443`
- **dnsmasq + httpd + TFTP:** **shared** with the migration lab, additive config
- **NFS for Timescape PVCs:** separate export at `/srv/nfs/openshift-install`, separate SC `nfs-storage-install`
- **Cilium config:** `kubeProxyReplacement: "true"`, pod CIDR `10.244.0.0/14`, service `172.31.0.0/16` (both non-overlapping with migration cluster)

## What's already on the bastion (don't re-do)

This guide is **additive** to whatever the migration lab set up. The bastion at
`192.168.39.20` already has:

- Nexus pull-through with `remote-quay`, `remote-redhat`, `remote-connect`, authenticated `remote-dockerhub`, `remote-k8s`
- A merged pull secret at `/root/pull-secret-with-art.json`
- HAProxy on `:8443` for Nexus + on `*:6443/22623/80/443` for the migration cluster
- httpd on `:8080` for the migration lab's ignition + RHCOS rootfs
- dnsmasq for DHCP + TFTP with shim/grub/per-MAC config dir under `/var/lib/tftpboot`
- `openshift-install` and `oc` binaries on PATH (you may need new ones — see Section 3.5)
- `helm`, `yq`, `jq`, `skopeo`, `govc`, `hubble` CLI
- An NFS export at `/srv/nfs/openshift` (migration lab) and `nfs-subdir-external-provisioner` providing `nfs-storage` (default SC for the migration cluster)

You don't need to re-run those. This guide only adds the install lab's pieces.

---

## Table of contents

1. Lab plan (DNS, IPs, VMs)
2. Prerequisites & shared bastion services
3. Generate ignition (CLife baked in for fresh Cilium install)
4. Provision vSphere VMs + PXE-install
5. Monitor install → cluster ready
6. Approve the CLife OLM InstallPlan
7. Post-install verification
8. Deploy a test app (Bookinfo) — optional sanity workload
9. Hubble Timescape (Helm-based, inline) — operator-based path is documented as 9-alt
10. Cleanup / teardown

---

## 1. Lab plan

### 1.1 Node sizing

Same as the migration lab — 3 control + 3 workers + 1 bootstrap, all RHCOS on
vSphere. The bastion is shared and already sized for both labs.

| Role | Count | vCPU | RAM | Disk |
|------|-------|------|-----|------|
| Bootstrap | 1 | 4 | 16 GiB | 120 GiB |
| Control plane | 3 | 8 | 16 GiB | 120 GiB |
| Worker | 3 | 8 | 16 GiB | 120 GiB |

### 1.2 IP plan (shared 192.168.39.0/24)

| Role | Migration cluster | **Install cluster (this guide)** |
|---|---|---|
| Cluster name | `ocp-migrate` | **`ocp-install`** |
| Bastion + Nexus + dnsmasq + httpd | `192.168.39.20` (shared) | `192.168.39.20` (shared) |
| API VIP / Ingress VIP | `.20` (HAProxy `*:6443`) | **`.30`** (HAProxy bound to `.30:6443`) |
| Bootstrap | `.19` | **`.29`** |
| Master 0/1/2 | `.21–.23` | **`.31–.33`** |
| Worker 0/1/2 | `.25–.27` | **`.35–.37`** |
| Reserved | `.24`, `.28` | `.34`, `.38` |
| Pod CIDR | `10.128.0.0/14` | **`10.244.0.0/14`** (non-overlapping) |
| Service CIDR | `172.30.0.0/16` | **`172.31.0.0/16`** (non-overlapping) |

### 1.3 DNS records needed (add to `192.168.33.10`)

```
; A records — forward zone md.prglab.local
api.ocp-install                    IN A 192.168.39.30
api-int.ocp-install                IN A 192.168.39.30
*.apps.ocp-install                 IN A 192.168.39.30
bootstrap-i.ocp-install            IN A 192.168.39.29
master-i-0.ocp-install             IN A 192.168.39.31
master-i-1.ocp-install             IN A 192.168.39.32
master-i-2.ocp-install             IN A 192.168.39.33
worker-i-0.ocp-install             IN A 192.168.39.35
worker-i-1.ocp-install             IN A 192.168.39.36
worker-i-2.ocp-install             IN A 192.168.39.37

; Reverse zone 39.168.192.in-addr.arpa
30   IN PTR master-i-0.ocp-install.md.prglab.local.
29   IN PTR bootstrap-i.ocp-install.md.prglab.local.
31   IN PTR master-i-0.ocp-install.md.prglab.local.
32   IN PTR master-i-1.ocp-install.md.prglab.local.
33   IN PTR master-i-2.ocp-install.md.prglab.local.
35   IN PTR worker-i-0.ocp-install.md.prglab.local.
36   IN PTR worker-i-1.ocp-install.md.prglab.local.
37   IN PTR worker-i-2.ocp-install.md.prglab.local.
```

Reload BIND after adding. Verify from the bastion:
```bash
dig +short api.ocp-install.md.prglab.local @192.168.33.10        # expect 192.168.39.30
dig +short -x 192.168.39.31 @192.168.33.10                       # expect master-i-0...
```

### 1.4 Scripts overview

All install-lab scripts live in [`/root/tools-upi-install/`](../tools-upi-install/)
and source [`lab-config.sh`](../tools-upi-install/lab-config.sh). Listed in
execution order:

| Order | Script | Section | What it does |
|---|---|---|---|
| **Bastion additions (run once)** | | | |
| 1 | `lab-config.sh` | 2 | Edit `« CHANGE »` items first — same vSphere creds as migration lab |
| 2 | `setup-haproxy.sh` | 2.2 | New `haproxy-install.service` bound to `.30` — does NOT touch the migration lab's HAProxy |
| 3 | `setup-httpd.sh` | 2.3 | Adds `/ignition-install/` + `/rhcos-install/` aliases to the shared Apache on `:8080` |
| 4 | `download-rhcos.sh` | 2.4 | Downloads RHCOS 4.20 live ISO + rootfs into the install lab's INSTALL_DIR |
| 5 | `setup-nfs.sh` | 2.5 | Separate NFS export at `/srv/nfs/openshift-install` |
| **Install cluster** | | | |
| 6 | `gen-ignition.sh` | 3 | Downloads CLife 1.18 tarball, customizes 3 manifests, writes `install-config.yaml` with `networkType: Cilium`, drops CLife into `manifests/`, generates ignition |
| 7 | `recreate-vms.sh` | 4.1 | Create 7 VMs in vSphere folder `OCP-Install` with names `*-i-N (install)` |
| 8 | `upload-iso.sh` | 4.2 | Upload RHCOS ISO to `_mdivis-install/` on the datastore (distinct from migration lab's `_mdivis-migrate/`) |
| 9 | `setup-pxe.sh` | 4.3 | Adds per-MAC PXE configs to the shared TFTP root + per-VM `dhcp-host` entries to dnsmasq |
| 10 | `pxe-install-and-boot.sh` | 4.4 | Orchestrated PXE install of all 7 VMs |
| 11 | `monitor-install.sh` | 5 | Waits for `bootstrap-complete` → CSRs → `install-complete`; refreshes kubeconfig from a master |
| 12 | `remove-bootstrap-from-haproxy.sh` | 5 | Auto-called by `monitor-install.sh` once bootstrap is done |
| **Post-install** | | | |
| 13 | `get-kubeconfig.sh` | 6 | Recover kubeconfig from a master after cert rotation (rarely needed) |
| 14 | `get-console-creds.sh` | 6 | Print console URL + kubeadmin password + workstation `/etc/hosts` entries |
| 15 | `setup-storage.sh` | 9.1 | Helm-installs nfs-subdir-external-provisioner into the cluster, creates `nfs-storage-install` SC |
| **Teardown** | | | |
| — | `delete-vms.sh` | | Powers off and removes the 7 install-lab VMs |
| — | `all.sh` (if used) | | Optional convenience wrapper around the install sequence |
| — | `govc-env.sh` | | Sourced by other scripts |

---

## 2. Prerequisites & shared bastion services

### 2.1 Edit lab-config.sh

```bash
vi /root/tools-upi-install/lab-config.sh
source /root/tools-upi-install/lab-config.sh
echo "${CLUSTER_NAME} / API ${API_VIP} / IEP ${CILIUM_EE_VERSION}"
```

Items to change at minimum:

- `OCP_VERSION` — verify against
  [openshift-install version](https://access.redhat.com/support/policy/updates/openshift)
  and what your bastion's `openshift-install` binary supports
- `CILIUM_EE_VERSION` — current 1.18.z; verify against
  [docs.cisco.com/iep](https://docs.cisco.com/iep/) and the support matrix
- `VCENTER_*` — same as migration lab if reusing vCenter
- (Network IPs default to the plan in Section 1; change only if your DNS plan differs)

### 2.2 Second HAProxy instance for the install cluster

```bash
cd /root/tools-upi-install
./setup-haproxy.sh
```

This script:
- Adds `192.168.39.30/32` as a secondary IP on the bastion via NetworkManager
- Writes `/etc/haproxy/haproxy-install.cfg` with frontends bound to `${API_VIP}:6443`, `:22623`, `:80`, `:443`, and stats on `:1937`
- Installs `/etc/systemd/system/haproxy-install.service` and starts it

The migration lab's `haproxy.service` and `/etc/haproxy/haproxy.cfg` are NOT
touched — the two services coexist because the migration uses `*:6443` (wildcard)
while the install lab binds explicitly to `.30:6443`. Wait — wildcard would in
fact swallow `.30:6443` too. **Important nuance:** the kernel routes `.30:6443`
into the haproxy-install process first because it's bound more specifically.
This works on Linux. Verify after starting:

```bash
ss -ltnp '( sport = :6443 )'
# Expected: TWO listeners — one *:6443 (migration lab) and one 192.168.39.30:6443 (install lab).
# The kernel picks the more specific bind for connections to .30.
```

> **Drift captured on first run (2026-05-30):** the initial version of `setup-haproxy.sh` produced a unit that failed to start with `Result: protocol`. Two fixes are now in the script:
> 1. Removed `pidfile /run/haproxy-install.pid` from the `global` section of `haproxy-install.cfg`. The pidfile is supplied on the command line via `-p`; declaring it in both places makes HAProxy 2.8 emit `'pidfile' already specified` and abort.
> 2. Changed the systemd unit from `Type=notify` (which expects `sd_notify(READY=1)`) to `Type=forking` with `PIDFile=/run/haproxy-install.pid`. HAProxy 2.8 on RHEL 9 + systemd 252 doesn't reliably notify under `-W` master-worker mode; `forking` works with `daemon` in the global config.

### 2.3 httpd additions

```bash
./setup-httpd.sh
```

This adds `/etc/httpd/conf.d/ocp-upi-install.conf` with two new aliases:
- `/ignition-install/` → `/root/ocp-upi-install/ignition/`
- `/rhcos-install/` → `/root/ocp-upi-install/rhcos/`

The migration lab's `/ignition/` and `/rhcos/` keep working.

### 2.4 RHCOS 4.20 ISO + rootfs

```bash
./download-rhcos.sh
```

Pulls the OCP 4.20 RHCOS live ISO and rootfs into the install lab's INSTALL_DIR.
This is fast (~2 GB) — fetched through the corporate proxy.

### 2.5 Separate NFS export

```bash
./setup-nfs.sh
```

Creates `/srv/nfs/openshift-install`, exports it to `192.168.39.0/24`, opens
the NFS firewall service (idempotent if migration lab already opened it). The
in-cluster `nfs-subdir-external-provisioner` deployment comes later in Section 9.1.

### 2.6 Sanity-check shared services

```bash
# Nexus reachable + serves the IEP images?
source /root/tools-upi-install/lab-config.sh
PULL_USER=$(jq -r ".auths.\"${ARTIFACTORY_HOST}:${ARTIFACTORY_PORT}\".auth" \
  /root/pull-secret-with-art.json | base64 -d | cut -d: -f1)
PULL_PASS=$(jq -r ".auths.\"${ARTIFACTORY_HOST}:${ARTIFACTORY_PORT}\".auth" \
  /root/pull-secret-with-art.json | base64 -d | cut -d: -f2-)
skopeo inspect --creds "${PULL_USER}:${PULL_PASS}" \
  docker://${ARTIFACTORY_HOST}:${ARTIFACTORY_PORT}/isovalent/cilium-ubi:v${CILIUM_EE_VERSION}-cee.1 \
  2>&1 | head -3
# Expected: JSON with "Name": "artifactory.ocp-migrate.md.prglab.local:8443/isovalent/cilium-ubi"

# dnsmasq + TFTP root from migration lab
ls /var/lib/tftpboot/EFI/grub-cfg/  # should contain one .cfg per migration VM MAC
systemctl is-active dnsmasq
```

If anything fails here, fix the shared-bastion service from the migration lab's
guide before continuing.

### 2.7 OCP installer binary

```bash
# Check the installed openshift-install version
openshift-install version
```

If it's 4.16.x (the migration lab's version), download the 4.20 release-image
client tools:

```bash
source /etc/profile.d/proxy.sh
source /root/tools-upi-install/lab-config.sh
cd /tmp

# Find a 4.20 release tag
oc adm release info quay.io/openshift-release-dev/ocp-release:${OCP_VERSION}-x86_64 \
  --image-for=installer || true

# Extract the installer binary from the release image, via Nexus
oc adm release extract \
  --tools \
  --from "${ARTIFACTORY_HOST}:${ARTIFACTORY_PORT}/openshift-release-dev/ocp-release:${OCP_VERSION}-x86_64" \
  --registry-config /root/pull-secret-with-art.json
tar xzvf openshift-install-linux*.tar.gz openshift-install
mv openshift-install /usr/local/bin/openshift-install-${OCP_VERSION}
ln -sf /usr/local/bin/openshift-install-${OCP_VERSION} /usr/local/bin/openshift-install
openshift-install version
```

> Both labs can share `/usr/local/bin/openshift-install` — only one cluster
> is being created at a time and the binary is stateless. If you flip back to
> the migration cluster, repeat for that 4.16.z.

---

## 3. Generate ignition (Cilium baked in)

OCP 4.20 supports `networkType: Cilium` directly in `install-config.yaml`. The
official Isovalent install procedure is to:

1. Drop the CLife OLM manifests into `manifests/` so bootkube applies them
   alongside the standard cluster-config manifests at bootstrap time
2. Set `networkType: Cilium` and `deployKubeProxy: false`
3. Provide `k8sServiceHost` and `k8sServicePort` in the `CiliumConfig` so the
   Cilium agents can reach the API before the in-cluster service layer is up

`gen-ignition.sh` does all of this:

```bash
cd /root/tools-upi-install
./gen-ignition.sh
```

What it does (in order):
1. Downloads `clife-v${CILIUM_EE_VERSION}.tar.gz` from
   `docs.isovalent.com/v25.11/public/clife/` if not already present
2. Extracts to `${CLIFE_DIR}` and **customizes 3 files in place** (with `.orig` backups):
   - `ciliumconfig.yaml` — KPR=true, pod CIDR from `lab-config.sh`,
     `k8sServiceHost: api-int.ocp-install.md.prglab.local`, Hubble + metrics
     enabled. Note: no `devices:` field — fresh install has no OVS bridges to
     coexist with, Cilium auto-detects the primary NIC.
   - `apps_v1_deployment_clife-controller-manager.yaml` — inject
     `KUBERNETES_SERVICE_HOST`/`PORT` env into the `manager` container
   - `subscription.yaml` — inject the same env into `.spec.config.env`
3. Writes `install-config.yaml` with:
   - `networkType: Cilium`
   - `platform: none`, `compute.replicas: 0`, `controlPlane.replicas: 3`
   - `imageContentSources` for `quay.io/openshift-release-dev`,
     `registry.redhat.io`, `quay.io`, `quay.io/isovalent`, `docker.io`,
     **and `registry.k8s.io`** (needed by the NFS provisioner image)
   - `additionalTrustBundle` with the Nexus CA chain
4. Runs `openshift-install create manifests`
5. Patches `manifests/cluster-network-02-config.yml` to add `deployKubeProxy: false`
6. Patches `manifests/cluster-scheduler-02-config.yml` to set `mastersSchedulable: false`
7. Writes `openshift/99-artifactory-idms.yaml` and `openshift/99-artifactory-itms.yaml`
   (**two separate files** — bootkube applies one resource per file under `openshift/`)
8. Writes `openshift/99-master-artifactory-ca.yaml` and `openshift/99-worker-artifactory-ca.yaml`
   (CA-trust MachineConfigs)
9. Writes `openshift/99-cluster-ingress-default.yaml` (HostNetwork, worker-only)
10. **Copies the customized CLife manifests into `manifests/`** prefixed with
    `clife-` so bootkube loads them. The `.orig` backups are skipped.
11. Runs `openshift-install create ignition-configs`
12. Copies `*.ign` to `${INSTALL_DIR}/ignition/` so httpd can serve them

Verify the result:

```bash
ls -la /root/ocp-upi-install/manifests/clife-*.yaml | wc -l
# Expected: 18 (or whatever the tarball has)
grep -E "networkType|deployKubeProxy" /root/ocp-upi-install/manifests/cluster-network-02-config.yml
# Expected:
#   networkType: Cilium
#   deployKubeProxy: false
ls /root/ocp-upi-install/ignition/
# Expected: bootstrap.ign  master.ign  worker.ign
```

> **About the `.orig` files:** the customizations are idempotent on re-runs.
> If `ciliumconfig.yaml.orig` already exists, `gen-ignition.sh` does NOT
> overwrite it. The customized file is rewritten each run from the
> `lab-config.sh` values.

---

## 4. Provision VMs + PXE install

### 4.1 Create the 7 VMs

```bash
./recreate-vms.sh
```

Creates `bootstrap-i (install)` plus 3 masters and 3 workers in folder
`/PRG-LAB/vm/mdivis/OCP-Install/`. CPU/RAM/disk per Section 1.1. RHCOS live ISO
is attached to each VM's CD-ROM. MAC addresses are printed at the end —
verify against the DNS plan you set up in Section 1.3.

### 4.2 Push the ISO to the vSphere datastore

```bash
./upload-iso.sh
```

Uploads to `_mdivis-install/rhcos-live.iso` (distinct from the migration lab's
`_mdivis-migrate/`). All install-lab VMs must be powered off — the ISO upload
fails on a datastore that has a VM with the ISO locked in its CD-ROM.

### 4.3 Per-MAC PXE configs + dnsmasq host reservations

```bash
./setup-pxe.sh
```

This is the **additive** variant. It does NOT touch the migration lab's
dnsmasq config — instead it:
- Extracts RHCOS 4.20 `vmlinuz`/`initramfs` to `/var/lib/tftpboot/` as
  `rhcos-install-vmlinuz` / `rhcos-install-initrd.img` (distinct filenames)
- Writes per-MAC grub configs to `/var/lib/tftpboot/EFI/grub-cfg/<mac>.cfg`
- Writes `/etc/dnsmasq.d/ocp-pxe-install.conf` with **only `dhcp-host=` lines**
  (the global interface/range/tftp settings stay in the migration lab's
  `ocp-pxe.conf`)
- Reloads dnsmasq
- Sets vSphere boot order to ethernet,disk on all 7 VMs

### 4.4 Orchestrated PXE install

```bash
./pxe-install-and-boot.sh
```

End-to-end install of all 7 VMs:
- Phase 1: bootstrap (sequential — needed by masters)
- Phase 2: 3 masters in parallel
- Phase 3: 3 workers in parallel

Each phase: power-on for PXE → wait for `rhcos-install-rootfs.img` GET to
settle for 60 s → flip boot order to disk → power-cycle. ~25 minutes total.

---

## 5. Monitor install → cluster ready

```bash
./monitor-install.sh
```

Watches:
- Phase 1: `openshift-install wait-for bootstrap-complete` (~20 min)
- After bootstrap-complete: auto-calls `remove-bootstrap-from-haproxy.sh` and
  powers off the bootstrap VM via govc
- Phase 2: refreshes kubeconfig from a master (the installer's bootstrap
  kubeconfig has a short-lived CA that won't survive cert rotation in Phase 3)
  and starts a background CSR auto-approver
- Phase 3: `openshift-install wait-for install-complete` (~30 min)

Total bring-up: ~50 minutes from `pxe-install-and-boot.sh` to all-green. At
the end you'll see:

```
=== Installation Complete ===
master-i-0   Ready   ...
master-i-1   Ready   ...
master-i-2   Ready   ...
worker-i-0   Ready   ...
worker-i-1   Ready   ...
worker-i-2   Ready   ...

Console:  https://console-openshift-console.apps.ocp-install.md.prglab.local
Password: <kubeadmin password>
KUBECONFIG=/root/ocp-upi-install/auth/kubeconfig
```

---

## 6. Approve the CLife OLM InstallPlan

When the cluster comes up, CLife is already running as a Deployment (from the
manifests we baked into `manifests/`). OLM also creates a Subscription which
generates an InstallPlan with `installPlanApproval: Manual`. Approve it:

```bash
source /root/tools-upi-install/lab-config.sh
export KUBECONFIG="${INSTALL_DIR}/auth/kubeconfig"

# Watch CLife + Cilium
oc -n cilium get pods
oc -n cilium get csv,installplan,subscription

# Approve
IP=$(oc get installplan -n cilium -o jsonpath='{.items[0].metadata.name}')
oc patch installplan ${IP} -n cilium --type merge --patch '{"spec":{"approved":true}}'

# Wait for CSV Succeeded
oc get csv -n cilium -w
```

> **Known race (from the migration lab — applies here too):** if the
> Subscription shows `BundleUnpackFailed: BackoffLimitExceeded` and no
> InstallPlan exists, OLM tried to unpack mid-bootstrap when the network was
> in flux. Delete the failed unpack job in `openshift-marketplace`, then
> recreate the Subscription. The recipe is documented in
> [migration guide Section 8.3](OCP_IEP_Migration_Guide.md#83-approve-the-olm-installplan).

---

## 7. Post-install verification

```bash
source /root/tools-upi-install/lab-config.sh
export KUBECONFIG="${INSTALL_DIR}/auth/kubeconfig"

echo "=== ClusterOperators (non-green only) ==="
oc get co | awk 'NR==1 || $3!="True" || $4!="False" || $5!="False"'

echo "=== Nodes ==="
oc get nodes -o wide

echo "=== Cilium status ==="
cilium status -n cilium     # if Isovalent cilium CLI is on the bastion
oc exec -n cilium ds/cilium -- cilium status

echo "=== Pod CIDRs (should all be 10.244.x.x — Cilium) ==="
oc get pods -A -o wide | grep -v "^NAMESPACE\|hostNet\|^openshift-" | head -20

echo "=== Multus pointing at Cilium? ==="
oc -n openshift-multus get cm multus-daemon-config -o jsonpath='{.data.daemon-config\.json}' \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['readinessindicatorfile'])"
# Expected: /host/run/multus/cni/net.d/05-cilium.conflist
```

The cluster should pass: all 33 CO green (with the usual `insights` exception
if your bastion can't reach `console.redhat.com`), 6 nodes Ready, all pods on
the Cilium pod CIDR, Multus indicating Cilium.

### Console access

```bash
./get-console-creds.sh
```

Prints the OCP console URL, kubeadmin password, and the hosts-file entries to
add on your workstation if it doesn't use the lab DNS.

---

## 8. Optional: Bookinfo sanity workload

Same as the migration lab — useful to confirm tag-based pulls work through
Nexus and that pod-to-pod traffic actually flows on Cilium.

```bash
oc new-project bookinfo
oc apply -n bookinfo -f \
  https://raw.githubusercontent.com/istio/istio/release-1.20/samples/bookinfo/platform/kube/bookinfo.yaml
oc expose svc/productpage -n bookinfo

for d in productpage-v1 details-v1 ratings-v1 reviews-v1 reviews-v2 reviews-v3; do
  oc rollout status deploy/$d -n bookinfo --timeout=5m
done

curl -s -o /dev/null -w "HTTP %{http_code}\n" \
  "http://$(oc get route productpage -n bookinfo -o jsonpath='{.spec.host}')/productpage"
# Expected: HTTP 200
```

If any deployment hangs in `ImagePullBackOff`, check that `quay.io/istio/...`
images are reaching Nexus (`oc describe pod` will show the actual error).

---

## 9. Hubble Timescape (Helm-based, IEP 1.18)

IEP 1.18 ships Timescape via **two parallel distribution channels**:

1. **Operator-based** (`TimescapeConfig` CR + `hubble-timescape-operator-cat` CatalogSource from `artifactory.devhub-cloud.cisco.com/isovalent-iep-docker/`) — the Isovalent docs' preferred path, but **requires a Cisco/Isovalent entitlement on devhub** that not all customers have.
2. **Helm-based** (chart `isovalent/hubble-timescape` at version `1.18.x` from the **public** `helm.isovalent.com`) — same approach as the migration lab's Timescape guide, just with a newer chart. **No devhub entitlement needed.**

**This section documents the Helm-based path.** It's the one we actually validated on the rebuild. If you have devhub access and want the operator-based path, see [Section 9-alt](#9-alt-operator-based-timescape-needs-devhub-entitlement) below.

> **Validated 2026-05-30**: chart `isovalent/hubble-timescape` version `1.18.8` deployed cleanly on OCP 4.20.24 + IEP 1.18.10-cee.1. End-to-end: 4 Timescape pods Running, Cilium streaming ~10k flows/s, ClickHouse accumulating 1.4M rows in ~14 minutes, hubble CLI 1.18.6 queries successful, Hubble UI Route HTTP 200.

### 9.1 Storage class for ClickHouse

```bash
./setup-storage.sh
```

Installs `nfs-subdir-external-provisioner` into `nfs-provisioner-install`
namespace; creates StorageClass **`nfs-storage-install`** (marked default
for this cluster). The bastion's NFS export from Section 2.5 backs it.

Smoke test the SC:
```bash
oc apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: nfs-smoke, namespace: default }
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 1Gi } }
  storageClassName: nfs-storage-install
EOF
oc -n default get pvc nfs-smoke         # → Bound within a few seconds
oc -n default delete pvc nfs-smoke
```

### 9.2 Altinity ClickHouse Operator

Same as the migration lab's Timescape guide — the chart wraps an Altinity-operator-managed ClickHouse. Drift hits, copy-paste ready:

```bash
source /root/tools-upi-install/lab-config.sh
export KUBECONFIG="${INSTALL_DIR}/auth/kubeconfig"

CLICKHOUSE_OPERATOR_VERSION=0.23.5
METRICS_EXPORTER_TAG=0.27.1

helm repo add altinity-clickhouse-operator https://docs.altinity.com/clickhouse-operator
helm repo update altinity-clickhouse-operator

oc create namespace clickhouse-operator-install
oc adm policy add-scc-to-user privileged \
  -z chop-install-altinity-clickhouse-operator -n clickhouse-operator-install

# IMPORTANT: keep the Helm release name short. The chart appends
# `-altinity-clickhouse-operator-metrics` (39 chars) to the release name when
# generating the metrics Service; Kubernetes Service names are capped at 63.
# `chop-install` (12) fits; the previous attempt with `clickhouse-operator-install`
# (27) produced `Service "...metrics" is invalid: metadata.name: must be no
# more than 63 characters` and the Service didn't get created.
helm install chop-install \
  altinity-clickhouse-operator/altinity-clickhouse-operator \
  --namespace clickhouse-operator-install \
  --version ${CLICKHOUSE_OPERATOR_VERSION} \
  --set metrics.image.tag=${METRICS_EXPORTER_TAG} \
  --set 'operator.env[0].name=WATCH_NAMESPACES,operator.env[0].value=hubble-timescape-install'

oc -n clickhouse-operator-install get pods -w
# Wait for 2/2 Running (~3.5 min)
```

> **Drift captured on first install (2026-05-30):**
> 1. Helm release name must be short to avoid the 63-char Service-name cap. Use `chop-install`, not the namespace-matching `clickhouse-operator-install`.
> 2. `metrics.image.tag` must be overridden — the chart's default falls back to `appVersion` (0.23.5), which is the right tag for `clickhouse-operator` but NOT for `metrics-exporter` (the latter is independently versioned, latest is 0.27.1). Without the override, the metrics-exporter container hangs in `ImagePullBackOff` and the operator pod stays 1/2 Ready.

### 9.3 Timescape namespace + privileged SCC + credentials

```bash
oc create namespace hubble-timescape-install

# Pod-security policy + SCC for the four Timescape SAs
oc label namespace hubble-timescape-install \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/enforce-version=latest

for sa in default hubble-timescape-ingester hubble-timescape-server hubble-timescape-ui; do
  oc adm policy add-scc-to-user privileged -z ${sa} -n hubble-timescape-install
done

# Per-component ClickHouse credentials (lab passwords — change for production)
for c in migrate trimmer ingester server analyzer; do
  oc -n hubble-timescape-install create secret generic hubble-timescape-${c}-creds \
    --from-literal "CLICKHOUSE_PASSWORD=Passw0rd.-${c}"
done
```

### 9.4 Install Timescape via Helm

Values file:

```bash
cat > /root/ocp-upi-install/hubble-timescape-values.yaml <<EOF
clickhouse:
  cluster:
    enabled: true
    resources:
      requests: { cpu: "500m", memory: "2Gi" }
      limits:   { cpu: "2",    memory: "4Gi" }
    volumes:
      data:
        size: 50Gi
        storageClassName: nfs-storage-install

ingester:
  bucket:
    uri: "file:///var/run/hubble-timescape/flows"
  server:
    grpc:
      enabled: true

ui:
  enabled: true
EOF
```

Install:

```bash
helm repo add isovalent https://helm.isovalent.com
helm repo update isovalent

TIMESCAPE_CHART_VERSION=1.18.8

helm upgrade --install hubble-timescape isovalent/hubble-timescape \
  --version ${TIMESCAPE_CHART_VERSION} \
  --namespace hubble-timescape-install \
  --values /root/ocp-upi-install/hubble-timescape-values.yaml

# 4 pods should reach Running (~3-5 min):
#   chi-hubble-timescape-hubble-data-0-0-0
#   hubble-timescape-ingester-...
#   hubble-timescape-server-...
#   hubble-timescape-ui-...
oc -n hubble-timescape-install get pods -w
```

> **Sizing guardrail copied from the migration lab:** the explicit
> `clickhouse.cluster.resources.limits.memory: 4Gi` is essential. Without it,
> any meaningful `hubble observe` query against millions of flows can blow
> ClickHouse to ~14 GiB and OOM-kill the pod (kernel OOM, not graceful CH
> over-commit error). 4 GiB cap makes CH return a clean `(total) memory
> limit exceeded` instead of restarting. Section F.5 of the migration lab's
> [Timescape guide](OCP_IEP_Timescape_Guide.md#section-f5--sizing--capacity)
> has the full sizing analysis — equally applicable here.

### 9.5 Connect Cilium's flow export to Timescape

```bash
oc -n cilium patch ciliumconfig ciliumconfig --type=merge -p '
spec:
  hubble:
    export:
      timescape:
        enabled: true
        target: "hubble-timescape-ingester.hubble-timescape-install.svc.cluster.local:4261"
'

oc -n cilium rollout status ds/cilium --timeout=5m

# Verify ConfigMap and agent-pod mount both got the keys
oc -n cilium get cm cilium-config -o jsonpath='{.data.hubble-export-timescape-enabled}{"\n"}{.data.hubble-export-timescape-target}{"\n"}'
# Expected: "true" and the ingester FQDN

oc -n cilium exec ds/cilium -c cilium-agent -- ls /tmp/cilium/config-map/ | grep timescape
# Expected: both hubble-export-timescape-* files

# If the agent's mounted /tmp/cilium/config-map/ doesn't show them yet,
# CLife's auto-restart raced the ConfigMap render — force a fresh rollout:
oc -n cilium rollout restart ds/cilium
oc -n cilium rollout status ds/cilium --timeout=5m
```

> **CLife race observed again on this rebuild (2026-05-30):** the first
> rollout (triggered by CLife auto-reconcile) finished before the
> `cilium-config` ConfigMap had the new keys. A second `oc rollout restart
> ds/cilium` made the agents pick them up. Same recipe as the migration lab.

### 9.6 Verify Timescape flows

```bash
# Ingester reports flushed flows (~10k/s sustained on a 6-node cluster)
oc -n hubble-timescape-install logs -l app.kubernetes.io/name=hubble-timescape-ingester --tail=20 \
  | grep -iE "flush|insert|tick"

# Direct ClickHouse count
oc -n hubble-timescape-install exec chi-hubble-timescape-hubble-data-0-0-0 -- clickhouse-client \
  --query "SELECT count(), toString(min(time)), toString(max(time)) FROM hubble.flows"
```

### 9.7 Hubble UI Route + CLI

Expose the UI service via an edge-terminated OCP Route:

```bash
cat <<EOF | oc apply -f -
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: hubble-timescape-ui
  namespace: hubble-timescape-install
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
oc -n hubble-timescape-install get route hubble-timescape-ui
# URL: https://hubble-timescape-ui-hubble-timescape-install.apps.ocp-install.md.prglab.local
```

CLI access (matching CLI version to Timescape's chart minor):

```bash
HUBBLE_CLI_VERSION=v1.18.6   # match Timescape 1.18.x schema
source /etc/profile.d/proxy.sh
curl -fL -o /tmp/hubble.tgz \
  "https://github.com/cilium/hubble/releases/download/${HUBBLE_CLI_VERSION}/hubble-linux-amd64.tar.gz"
tar xz -f /tmp/hubble.tgz -C /usr/local/bin hubble
chmod +x /usr/local/bin/hubble

# Port-forward (use setsid + < /dev/null so the bg job survives parent shell exit)
setsid oc port-forward -n hubble-timescape-install svc/hubble-timescape 4244:80 \
  > /tmp/pf-timescape-install.log 2>&1 < /dev/null &
sleep 4

# Corporate proxy can intercept the localhost port-forward — exempt it explicitly
export NO_PROXY="localhost,127.0.0.1,${NO_PROXY:-}"

# Query
hubble observe --server localhost:4244 --since 30s --last 10 -o compact
```

> **hubble CLI ↔ Timescape schema rule (from migration lab):** the CLI's
> minor must match the Timescape server's minor. v1.19.x hubble against
> Timescape 1.8 produced `rpc error: code = InvalidArgument ... path
> "ip_trace_id" invalid: unsupported field`. v1.18.6 against Timescape 1.18.8
> works clean (validated 2026-05-30).

### 9.8 Sizing notes

Same shape as the migration lab — see
[`OCP_IEP_Timescape_Guide.md` Section F.5](OCP_IEP_Timescape_Guide.md#section-f5--sizing--capacity)
for the full sizing analysis. Quick rule of thumb for this 6-node OCP 4.20 lab,
**measured on the install rebuild (2026-05-30):**

- Sustained Cilium flow rate: ~10k flows/s, transient peaks ~30k/s after DS restarts
- 1 GiB of ClickHouse storage ≈ 10-13M flows
- At 10k/s, **50 GiB PVC fills in ~14 hours**
- ClickHouse memory limit `4Gi` is the right starting point — anything less makes
  wider queries OOM-kill the pod; anything more is unnecessary for a 6-node lab

If you plan to keep this lab running unattended, apply a ClickHouse TTL:

```bash
oc -n hubble-timescape-install exec chi-hubble-timescape-hubble-data-0-0-0 -- clickhouse-client \
  --query "ALTER TABLE hubble.flows MODIFY TTL time + INTERVAL 24 HOUR"
```

---

## 9-alt. Operator-based Timescape — needs devhub entitlement (untested)

The Isovalent docs prefer an operator-based install model for Timescape 1.18 via a CatalogSource pointing at `artifactory.devhub-cloud.cisco.com/isovalent-iep-docker/hubble-timescape-operator-cat:v1.0.0`. This path **requires a Cisco/Isovalent enterprise entitlement on devhub**. Without it the CatalogSource pod fails to pull the operator image.

If your devhub identity has access to `isovalent-iep-docker`, the procedure is to (a) add a new `remote-isovalent-devhub` Nexus proxy repo with auth, (b) add it to the `ocp-images` group, (c) patch IDMS+ITMS to redirect the source path to Nexus (or bake it into `gen-ignition.sh` at install time), (d) apply a `CatalogSource` + `OperatorGroup` + `Subscription` per the Isovalent doc, (e) create a `TimescapeConfig` CR with `spec.timescape.lite.enabled: true`.

We did NOT validate this path on this rebuild (the available devhub identity did not have the `isovalent-iep-docker` entitlement). The Helm path in Section 9 above produces the same Timescape components and works without devhub entitlement.

---

## 10. Optional Day-2: switch to Isovalent Load Balancer (ILB) — **proposal, not tested**

> **⚠️ Thought exercise, not validated.** ILB ships with the same CLife/Cilium release we already install. The path below is reasoned through against the official Isovalent ILB-on-OpenShift docs but has **not** been run end-to-end in this lab. Treat as planning input for a follow-up rebuild test, not as a known-good procedure. Validate every command in a non-production cluster before committing.

### What ILB is and what it changes

ILB (Isovalent Load Balancer) is **a richer profile of the same CiliumConfig** — no separate operator, no separate Helm chart, no separate tarball. Activating ILB flips a set of `spec.enterprise.*` and `spec.loadBalancer.*` toggles in the `ciliumconfig.yaml` we already ship. The cluster's CLife operator reconciles, restarts the Cilium DaemonSet with the new profile, and the BGP control plane comes online.

**Hard prerequisite the install cannot satisfy on its own:** ILB advertises service VIPs via **BGP**. Without an upstream BGP peer (a router, FRR on the bastion, etc.), VIPs are computed but unreachable. The bastion HAProxy stays in place for API/MCS during install no matter what (the cluster doesn't exist yet at bootstrap time), but ingress can be migrated to ILB once a BGP peer exists.

### Realistic placement

| Service | LB during install | Day 2 destination |
|---|---|---|
| API (`:6443`), MCS (`:22623`) | bastion HAProxy on `${API_VIP}` | Stays on bastion HAProxy (no compelling reason to switch — cluster API works fine without ILB fronting it) |
| Ingress (`:80`/`:443`) for `*.apps.*` | bastion HAProxy on `${INGRESS_VIP}` | **ILB-announced VIP** on a separate IP via BGP |
| Nexus TLS frontend (`:8443`) | bastion HAProxy | Stays on bastion (cluster-external) |

### Required CiliumConfig delta (vs the current install lab's CiliumConfig)

Compared to what `gen-ignition.sh` writes today:

```yaml
spec:
  # Add these:
  routingMode: native             # was: implicit "tunnel" + tunnelPort: 4789 (REMOVE the tunnelPort line)
  ipv4NativeRoutingCIDR: "10.244.0.0/14"   # same as your POD_CIDR
  autoDirectNodeRoutes: true      # each node installs routes to peer pod CIDRs via the node IP
  directRoutingSkipUnreachable: true
  endpointRoutes:
    enabled: true                 # required by ILB
  socketLB:
    hostNamespaceOnly: true       # mandatory under ILB — host-network sockets still go through Cilium LB
  bpf:
    masquerade: true              # eBPF masquerade in place of iptables-masquerade
    ctAccounting: true
    lbAlgorithmAnnotation: true
    lbModeAnnotation: true
  enableIPv4Masquerade: true
  loadBalancer:
    mode: dsr                     # Direct Server Return; more efficient than SNAT-based LB
    dsrDispatch: ipip
    acceleration: disabled        # XDP acceleration disabled (lab — no SR-IOV / no fancy NIC offload)
  enterprise:
    loadbalancer:
      enabled: true               # turns on ILB controllers
    bgpControlPlane:
      enabled: true
      enableServiceHealthChecking: true
    bfd:
      enabled: true               # bidirectional forwarding detection for fast peer-down detection
    featureGate:
      minimumMaturity: Alpha
      approved:
        - BFD
        - EnterpriseBGPControlPlane
        - IPAMMultiPool
  envoy:
    nodeSelector:
      service.cilium.io/node: "t2"   # ILB Envoy data plane runs only on T2-labeled workers
    dnsPolicy: ClusterFirstWithHostNet
  envoyConfig:
    enabled: true
```

And remove these from the current CiliumConfig:
- `tunnelPort: 4789` (we're going native, no tunnel)

### Prerequisites you'd need to set up first

1. **A BGP peer.** The cleanest lab option is **FRR on the bastion**, peering with each master via the management network (`192.168.39.0/24`). The masters would announce service VIPs to FRR; FRR redistributes them upstream or just installs the routes locally so the bastion can route traffic to them.

2. **A VIP pool.** Choose a CIDR distinct from the node network — e.g. `192.168.39.240/28` for service VIPs. Create a `CiliumLoadBalancerIPPool` CR.

3. **Worker labeling.** Label some workers as T2 (the Envoy data plane runs there):
   ```bash
   oc label node worker-i-0 service.cilium.io/node=t2
   oc label node worker-i-1 service.cilium.io/node=t2
   ```
   In a 6-node lab you can label all three workers as T2. ILB's reference architecture separates T1 (control plane) and T2 (data plane) onto different node pools for production; for a lab they can overlap on the worker nodes.

4. **A `CiliumBGPClusterConfig` + `CiliumBGPPeerConfig`** pair declaring the cluster ASN, the peer ASN (FRR's), the peer IP (bastion), and authentication. The exact CR shapes are in the IEP ILB docs.

### Why "ILB from day one" is *not* what you'd want for the install lab

In principle nothing stops `gen-ignition.sh` from emitting the ILB-profile CiliumConfig at install time. The cluster would come up, ILB controllers would start, BGP control plane would attempt peering — and find no peer, because FRR isn't up yet. Cilium would still work for pod-to-pod (native routing across `autoDirectNodeRoutes`), so the cluster would be functional, but no service VIPs would be reachable from outside. Ingress would be broken until you either (a) bring up FRR, or (b) flip ingress back to the bastion HAProxy.

The right shape for a real test is:
1. Complete the install with the current INK-only CiliumConfig (VXLAN, no ILB, bastion HAProxy)
2. Day 2: stand up FRR on the bastion
3. Day 2: patch the CiliumConfig CR to the ILB profile, wait for CLife to reconcile
4. Day 2: drop the `ingress_http`/`ingress_https` backends from `haproxy-install.cfg` and update DNS to point `*.apps.ocp-install` at the ILB-announced VIP

Treating ILB as Day 2 lets you validate each layer independently.

### Sketch: minimal FRR-on-bastion setup (untested)

```bash
dnf install -y frr
systemctl enable --now frr
vi /etc/frr/frr.conf  # add BGP peers on .39.31/.32/.33 (masters)

# example: cluster ASN 64512, bastion ASN 64500
cat > /etc/frr/frr.conf <<'EOF'
frr defaults traditional
hostname bastion-frr
log syslog informational
!
router bgp 64500
 bgp router-id 192.168.39.20
 no bgp ebgp-requires-policy
 neighbor 192.168.39.31 remote-as 64512
 neighbor 192.168.39.32 remote-as 64512
 neighbor 192.168.39.33 remote-as 64512
 address-family ipv4 unicast
  neighbor 192.168.39.31 activate
  neighbor 192.168.39.32 activate
  neighbor 192.168.39.33 activate
 exit-address-family
!
EOF
systemctl restart frr
```

Then a `CiliumBGPClusterConfig` in the cluster pointing back at .20 as the peer. After convergence, `vtysh -c "show bgp summary"` on the bastion should show 3 established sessions.

### Open questions to validate before relying on this

- Does `routingMode: native` with `autoDirectNodeRoutes` work over the `192.168.39.0/24` flat L2 with no router (other than the .1 gateway)? **Probably yes** — every node can reach every other node directly.
- Does the BGP control plane peer with FRR cleanly on RHCOS hosts? Untested.
- Do you need any kernel-module/kargs prerequisites for native routing on RHCOS 4.20? Untested.
- ILB's Envoy data plane on T2 nodes uses `:80` by default — **conflicts with the OCP IngressController also on `:80` if both land on the same node**. The ILB docs explicitly call this out (Section 218 of the doc snapshot at [`doc-sources/iep-1.18-openshift-install.txt`](../doc-sources/iep-1.18-openshift-install.txt)). The recommended workaround in the docs is to **host the IngressController only on masters and T1 nodes**, leaving T2 nodes for ILB Envoy. Our current IngressController is worker-only — would need to be rescheduled.

These need a dedicated ILB-Day-2 test run in the lab.

### Bottom line

**ILB is shipped with IEP 1.18, activatable via CiliumConfig.** The current install lab uses HAProxy for simplicity and to keep the very first install rebuild test on known ground. Once that baseline works, ILB is the natural follow-up — replace bastion-HAProxy ingress with an ILB-announced VIP, peered via FRR on the bastion. The work is well-scoped (one CiliumConfig patch + FRR + a few CRs) but introduces a new failure surface (native routing, BGP peering, DSR mode) that warrants its own test pass.

---

## 11. Cleanup / teardown

To tear down just the install lab (leaves the migration lab and shared
bastion services intact):

```bash
# 1. In-cluster cleanup (optional — saves you from CRD-finalizer hangs later)
helm -n hubble-timescape-install uninstall hubble-timescape
oc delete namespace hubble-timescape-install
helm -n clickhouse-operator-install uninstall chop-install
oc delete namespace clickhouse-operator-install
oc delete sc nfs-storage-install
helm -n nfs-provisioner-install uninstall nfs-subdir-external-provisioner-install
oc delete namespace nfs-provisioner-install

# 2. VMs
./delete-vms.sh

# 3. HAProxy install instance
systemctl disable --now haproxy-install
rm -f /etc/systemd/system/haproxy-install.service /etc/haproxy/haproxy-install.cfg
systemctl daemon-reload
# Remove the secondary IP
PRIMARY_CONN=$(nmcli -t -f NAME,DEVICE,STATE c show --active | head -1 | cut -d: -f1)
nmcli c modify "${PRIMARY_CONN}" -ipv4.addresses "192.168.39.30/32"
nmcli c up "${PRIMARY_CONN}" >/dev/null

# 4. dnsmasq host reservations
rm -f /etc/dnsmasq.d/ocp-pxe-install.conf
systemctl reload dnsmasq

# 5. httpd aliases
rm -f /etc/httpd/conf.d/ocp-upi-install.conf
systemctl reload httpd

# 6. NFS export
rm -f /etc/exports.d/openshift-install.exports
exportfs -ra
rm -rf /srv/nfs/openshift-install

# 7. Install dir + tarball + ignition
rm -rf /root/ocp-upi-install /root/clife-v${CILIUM_EE_VERSION}.tar.gz*

# 8. (Optional) DNS records — remove from 192.168.33.10 BIND zone
```

The migration lab continues to work after all of this.

---

## References

- [`OCP_IEP_Migration_Guide.md`](OCP_IEP_Migration_Guide.md) — the parallel
  migration lab (OCP 4.16 + IEP 1.17 via OVN→Cilium migration)
- [`OCP_IEP_Timescape_Guide.md`](OCP_IEP_Timescape_Guide.md) — Timescape on
  the migration cluster (standalone Helm chart, useful as a deeper reference)
- Upstream Isovalent installation docs (login required):
  https://docs.isovalent.com/iep/latest/ink/install/openshift.html
- Local snapshots:
  [`doc-sources/iep-1.18-openshift-install.txt`](../doc-sources/iep-1.18-openshift-install.txt),
  [`doc-sources/iep-1.18-timescape-on-openshift.txt`](../doc-sources/iep-1.18-timescape-on-openshift.txt)
- OCP support policy: https://access.redhat.com/support/policy/updates/openshift
- IEP/OCP certified compatibility: https://access.redhat.com/articles/5436171

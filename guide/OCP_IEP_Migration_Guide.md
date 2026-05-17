# OCP to Isovalent Enterprise Platform — Migration Lab Guide

## Overview

This guide walks through a complete lab scenario:

1. Set up Nexus OSS as a pull-through proxy cache for all required container registries
2. Install OpenShift 4.16 using User-Provisioned Infrastructure (UPI) with OVN-Kubernetes, with all images sourced via Nexus
3. Deploy a representative test application to establish a connectivity baseline
4. Migrate the cluster in-place to Isovalent Enterprise Platform (IEP) — Isovalent Networking for Kubernetes
5. Verify full cluster and application health after migration

**Source:** All migration procedure steps are based exclusively on the official Isovalent documentation:
- *Install Networking for Kubernetes on Red Hat OpenShift* (CLife 1.18.x)
- *Migrate from OpenShift OVN-Kubernetes to Networking for Kubernetes*

---

## Table of Contents

- [Important Notices](#important-notices)
- [1. Lab Environment](#1-lab-environment)
  - [1.1 Node Sizing](#11-node-sizing)
  - [1.2 Network Planning](#12-network-planning)
  - [1.3 Lab Configuration File](#13-lab-configuration-file)
  - [1.4 Scripts Overview](#14-scripts-overview)
  - [1.5 Required Tools on Bastion](#15-required-tools-on-bastion)
- [2. Nexus OSS — Pull-Through Registry Proxy](#2-nexus-oss--pull-through-registry-proxy)
  - [2.1 Why Nexus Instead of a Full Mirror](#21-why-nexus-instead-of-a-full-mirror)
  - [2.2 Install and Configure Nexus OSS on the Bastion](#22-install-and-configure-nexus-oss-on-the-bastion)
  - [2.3 Verify Pull-Through Works](#23-verify-pull-through-works)
- [3. Install OpenShift 4.16 UPI with OVN-Kubernetes](#3-install-openshift-416-upi-with-ovn-kubernetes)
  - [3.1 DNS Records](#31-dns-records)
  - [3.2 Load Balancer](#32-load-balancer)
  - [3.3 Pull Secret and SSH Key](#33-pull-secret-and-ssh-key)
  - [3.4 install-config.yaml](#34-install-configyaml)
  - [3.5 Download RHCOS, Serve It, and Generate Ignition Configs](#35-download-rhcos-serve-it-and-generate-ignition-configs)
  - [3.6 Cluster Manifests Dropped Into `openshift/`](#36-cluster-manifests-dropped-into-openshift)
  - [3.7 PXE Boot and Unattended RHCOS Install](#37-pxe-boot-and-unattended-rhcos-install)
  - [3.8 Monitor and Complete the Installation](#38-monitor-and-complete-the-installation)
  - [3.9 Verify Cluster Health](#39-verify-cluster-health)
  - [3.10 UPI Install Pitfalls / Troubleshooting](#310-upi-install-pitfalls--troubleshooting)
- [4. Deploy the Test Application](#4-deploy-the-test-application)
  - [4.1 Application Architecture](#41-application-architecture)
  - [4.2 Deploy Bookinfo](#42-deploy-bookinfo)
  - [4.3 Record Baseline Connectivity](#43-record-baseline-connectivity)
- [5. Pre-Migration Checks](#5-pre-migration-checks)
  - [5.1 Cluster Health Gate](#51-cluster-health-gate)
  - [5.2 Record Network Configuration](#52-record-network-configuration)
  - [5.3 Kernel Variant Check](#53-kernel-variant-check)
  - [5.4 Backup NetworkPolicies](#54-backup-networkpolicies)
- [6. Prepare Isovalent Enterprise Manifests](#6-prepare-isovalent-enterprise-manifests)
  - [6.1 Download and Verify CLife Tarball](#61-download-and-verify-clife-tarball)
  - [6.2 Configure CiliumConfig](#62-configure-ciliumconfig)
  - [6.3 Configure the CLife Controller Manager](#63-configure-the-clife-controller-manager)
  - [6.4 Configure the OLM Subscription](#64-configure-the-olm-subscription)
- [7. Migration Procedure](#7-migration-procedure)
  - [Phase 1 — Disable the Cluster Network Operator](#phase-1--disable-the-cluster-network-operator)
  - [Phase 2 — Pause the Machine Config Operator](#phase-2--pause-the-machine-config-operator)
  - [Phase 3 — Switch the Network Plugin](#phase-3--switch-the-network-plugin)
  - [Phase 4 — Deploy Isovalent Networking for Kubernetes](#phase-4--deploy-isovalent-networking-for-kubernetes)
  - [Phase 5 — Re-enable OpenShift Operator Management](#phase-5--re-enable-openshift-operator-management)
  - [Phase 6 — Reboot Nodes via MCP](#phase-6--reboot-nodes-via-mcp)
- [8. Post-Migration Verification](#8-post-migration-verification)
  - [8.1 Cluster Operator Health](#81-cluster-operator-health)
  - [8.2 Cilium Health](#82-cilium-health)
  - [8.3 Approve the OLM InstallPlan](#83-approve-the-olm-installplan)
  - [8.4 Application Connectivity](#84-application-connectivity)
  - [8.5 Cilium Connectivity Test](#85-cilium-connectivity-test)
- [9. Post-Migration Cleanup](#9-post-migration-cleanup)
  - [9.1 Remove the devices Setting](#91-remove-the-devices-setting)
  - [9.2 Remove OVN-Kubernetes Namespace](#92-remove-ovn-kubernetes-namespace)
  - [9.3 Restore NetworkPolicies](#93-restore-networkpolicies)
- [10. Risk Register](#10-risk-register)

---

## Important Notices

> **Red Hat support position:** Red Hat provides no support for performing a network migration on an active existing OpenShift cluster. This migration is supported by Isovalent. Contact your Red Hat account team and Isovalent support before proceeding in a production environment.

> **Downtime:** This migration incurs downtime. All nodes are rebooted sequentially by the Machine Config Operator. Total downtime is proportional to the number of nodes and the time required for each to drain, reboot, and rejoin. Plan a maintenance window.

> **Development first:** Always complete this procedure in a development cluster before attempting it in production.

> **Kernel requirement:** Cilium requires the standard RHCOS kernel. The Real-Time (RT) kernel disables eBPF program types required by Cilium. If any node shows `rt` in its kernel version, switch it to the standard kernel via MachineConfig before proceeding.

### IEP / OpenShift Compatibility Matrix

Source of truth: Red Hat Customer Portal article 5436171, *OpenShift CNI Plug-in Support* (Cisco Isovalent section). The product was renamed from **Isovalent Enterprise for Cilium** to **Isovalent Networking for Kubernetes** starting at 1.17.

| Product name | IEP version | Install methods | Certified OCP versions | Tests passed |
|---|---|---|---|---|
| Isovalent Enterprise for Cilium | 1.14 | UPI and IPI | 4.13, 4.14, 4.15, 4.16 | Net, Virt |
| Isovalent Enterprise for Cilium | 1.15 | UPI and IPI | 4.14, 4.15, 4.16, 4.17 | Net, Virt |
| Isovalent Enterprise for Cilium | 1.16 | UPI and IPI | 4.16, 4.17, 4.18, 4.19 | Net, Virt, Mesh |
| Isovalent Networking for Kubernetes | 1.17 | UPI and IPI | 4.16, 4.18, 4.19, 4.20 | Net, Virt, Mesh, HCP |
| Isovalent Networking for Kubernetes | 1.18 | UPI and IPI | 4.19, 4.20 | Net, Virt, Mesh, HCP |

Legend: **Net** = Network Conformance, **Virt** = OpenShift Virtualization, **Mesh** = ClusterMesh, **HCP** = Hosted Control Planes. Red Hat requires only Net + Virt for certification.

> **Lab choice — IEP 1.17 on OCP 4.16:** this lab uses **IEP 1.17.15**, the latest 1.17.x at the time of writing — a certified row in the table above. IEP 1.18 is **not certified on OCP 4.16** (Red Hat lists 1.18 against OCP 4.19/4.20 only). To use a different IEP minor, set `CILIUM_EE_VERSION` *and* `CLIFE_DOCS_PATH` in `lab-config.sh` and re-run Section 6.1. The CLife tarball is hosted under a per-minor docs path: `v1.17/public/clife/...` for 1.17, `v25.11/public/clife/...` for 1.18.

---

## 1. Lab Environment

### 1.1 Node Sizing

This guide targets a minimal but representative lab cluster running on vSphere VMs. No vSphere cloud integration is used — nodes are treated as bare metal (`platform: none`).

| Role | Count | vCPU | RAM | Disk | Notes |
|------|-------|------|-----|------|-------|
| Bastion | 1 | 4 | 8 GB | 200 GB | Runs Nexus OSS, HAProxy, HTTP server |
| Bootstrap | 1 | 4 | 16 GB | 120 GB | Temporary — removed after install completes |
| Control plane | 3 | 8 | 16 GB | 120 GB | RHCOS, `platform: none` |
| Worker | 3 | 8 | 16 GB | 120 GB | RHCOS, `platform: none` |

> A 3-control-plane / 2-worker topology ensures MCP rolling reboots do not take the cluster offline — one control plane remains available while others reboot.

> **vSphere — no cloud integration:** VMs are created manually (or via Terraform/govc) and booted from RHCOS ISO. The `platform: none` setting in `install-config.yaml` tells the OpenShift installer not to attempt any vSphere API calls. No vSphere credentials, datastores, or cloud provider configuration is needed.

> **DNS:** DNS is served by the existing lab server at `192.168.33.10`. Add the OCP cluster zone records there (Section 3.1). No DNS server is needed on the bastion.

### 1.2 Network Planning

| Network | CIDR / Address | Notes |
|---------|----------------|-------|
| Machine network | `192.168.39.0/24` | OCP node network |
| Bastion IP | `192.168.39.20` | HAProxy, HTTP, Nexus OSS |
| Bootstrap IP | `192.168.39.19` | Temporary |
| Control plane IPs | `192.168.39.21–23` | master-m-0, master-m-1, master-m-2 (`.24` reserved for future expansion) |
| Worker IPs | `192.168.39.25–27` | worker-m-0, worker-m-1, worker-m-2 (`.28` reserved for future expansion) |
| API VIP | `192.168.39.20` | HAProxy frontend on bastion (port 6443/22623 → masters) |
| Ingress VIP | `192.168.39.20` | HAProxy frontend on bastion (port 80/443 → workers) |
| DNS server | `192.168.33.10` | Existing lab DNS — add OCP zone records here |
| OVN-Kubernetes pod CIDR | `10.128.0.0/14` | OCP default — will be replaced at migration |
| **Cilium pod CIDR** | `10.253.0.0/16` | **Must not overlap with OVN CIDR** |
| Service network | `172.30.0.0/16` | Unchanged across migration |

> **The Cilium pod CIDR (`10.253.0.0/16`) is the most critical planning decision.** It must not overlap with the existing OVN-Kubernetes network. During the migration both CNIs briefly coexist on nodes, so overlapping CIDRs will cause routing conflicts.

### 1.3 Lab Configuration File

All lab variables live in `/root/tools-upi-migrate/lab-config.sh`. Copy the tools directory to the bastion and edit the variables marked `« CHANGE »` before running any script or command in this guide:

```bash
# Copy tools to bastion (from wherever the repo lives)
# scp -r tools-upi-migrate root@192.168.39.20:/root/

# Edit variables marked « CHANGE » — at minimum:
#   OCP_VERSION, CLUSTER_NAME, BASE_DOMAIN
#   ARTIFACTORY_USER, ARTIFACTORY_PASS
#   CILIUM_EE_VERSION, CEE_SUFFIX
#   VCENTER_* settings
#   PULL_SECRET_FILE, SSH_KEY_FILE
vi /root/tools-upi-migrate/lab-config.sh

chmod 700 /root/tools-upi-migrate/*.sh
source /root/tools-upi-migrate/lab-config.sh
```

Key variables and their defaults for this lab:

| Variable | Default | Notes |
|----------|---------|-------|
| `OCP_VERSION` | `4.16.36` | Latest 4.16.z — check mirror.openshift.com |
| `CLUSTER_NAME` | `ocp-migrate` | Cluster name, part of all FQDNs |
| `BASE_DOMAIN` | `md.prglab.local` | Base DNS domain |
| `BASTION_IP` | `192.168.39.20` | This machine |
| `BOOTSTRAP_IP` | `192.168.39.19` | Temporary — removed after install |
| `MASTER{0-2}_IP` | `192.168.39.21–23` | Control plane nodes (`.24` reserved) |
| `WORKER{0-2}_IP` | `192.168.39.25–27` | Worker nodes (`.28` reserved) |
| `API_VIP` | `192.168.39.20` | HAProxy frontend for API on bastion |
| `INGRESS_VIP` | `192.168.39.20` | HAProxy frontend for Ingress on bastion |
| `INSTALL_DIR` | `/root/ocp-upi-migrate` | openshift-install working directory |
| `CILIUM_CLUSTER_CIDR` | `10.253.0.0/16` | **Must not overlap OVN `10.128.0.0/14`** |

### 1.4 Scripts Overview

The `/root/tools-upi-migrate/` directory contains every script used by this guide. The phases match the script execution order in `all.sh`:

All scripts live in [`/root/tools-upi-migrate/`](../tools-upi-migrate/) and source [`lab-config.sh`](../tools-upi-migrate/lab-config.sh). Run them from the bastion as `root`. Listed in execution order — Sections column links to the matching guide section.

| Order | Script | Section | What it does |
|-------|--------|---------|--------------|
| **Bastion setup (run once)** | | | |
| 1 | `lab-config.sh` | 1.3 | **Sourced by every other script.** Single source of truth for all lab variables (`« CHANGE »` items must be edited first) |
| 2 | `setup-artifactory.sh` | 2 | Stand up Nexus OSS pull-through proxy, configure repos, merge pull secret |
| 3 | `setup-haproxy.sh` | 3.2 | HAProxy frontends for API (`:6443`), MCS (`:22623`), Ingress (`:80`/`:443`), Nexus (`:8443`) on the bastion |
| 4 | `setup-httpd.sh` | 3.5 | Apache on `:8080` to serve ignition and RHCOS rootfs over HTTP |
| 5 | `download-rhcos.sh` | 3.5 | Download RHCOS live ISO + rootfs matching `OCP_VERSION` |
| **Install cluster (run per install)** | | | |
| 6 | `gen-ignition.sh` | 3.4–3.6 | Render `install-config.yaml` (with `imageContentSources` + `additionalTrustBundle`), run `openshift-install create manifests`, drop the lab's `openshift/` manifests (CA trust, **IDMS + ITMS as two separate files**, IngressController, Scheduler patch), then generate ignition |
| 7 | `recreate-vms.sh` | 3.7 | Create or re-create the 7 lab VMs (bootstrap + 3 masters + 3 workers) in vSphere, attach RHCOS ISO |
| 8 | `upload-iso.sh` | 3.5 | Push the RHCOS live ISO to the vSphere datastore. **All VMs must be powered off** — the upload fails on a locked datastore |
| 9 | `setup-pxe.sh` | 3.7 | dnsmasq (DHCP + TFTP) on bastion. Reads VM MACs from vSphere and writes per-MAC grub configs that pin each VM to its role (bootstrap/master/worker) |
| 10 | `pxe-install-and-boot.sh` | 3.7 | Orchestrates the PXE install: power-cycles VMs, watches `httpd` rootfs-fetch for the install-idle signal, flips boot order to disk, power-cycles to the installed OS |
| 11 | `monitor-install.sh` | 3.8 | Waits for `bootstrap-complete`, auto-approves kubelet CSRs, then waits for `install-complete`. Refreshes the kubeconfig from a master so it survives bootstrap teardown |
| 12 | `remove-bootstrap-from-haproxy.sh` | 3.8 | Drops bootstrap entries from `api_backend` and `mcs_backend` in HAProxy. Called automatically by `monitor-install.sh` after `bootstrap-complete` |
| **Post-install helpers** | | | |
| — | `start-vms.sh` | manual | Power up VMs in order (bootstrap → masters → workers) if you didn't use `pxe-install-and-boot.sh` |
| — | `get-kubeconfig.sh` | 3.9 | Recover `kubeconfig` from a master after cert rotation (rarely needed) |
| — | `get-console-creds.sh` | post-install | Print the OCP web console URL, `kubeadmin` credentials, and the workstation `/etc/hosts` entries needed to reach the console from outside the lab DNS |
| **Migration to Isovalent** | | | |
| 13 | `do-migration.sh` | 7 | Full Phase 1–6 migration in one script (CNO disable → MCP pause → network patch → CLife apply → Multus repoint → operator restart → MCP reboot). Pauses before Phase 6 reboots; pass `-y` to skip the confirmation in a known-good lab |
| 14 | `check-cilium.sh` | 8 | Quick post-migration health check on the Cilium-managed cluster |
| — | `patch-cilium-k8s-host.sh` | **DO NOT RUN under KPR=true** | Legacy: injects `KUBERNETES_SERVICE_HOST/_PORT` into Cilium DS + iptables DNAT on masters. Written for `kubeProxyReplacement: false` + CNI chaining. With `kubeProxyReplacement: "true"` (this lab's setting), Cilium's BPF socket-LB programs ClusterIP routing for both pod-network and host-network traffic — no DNAT needed. Kept for setups that intentionally use KPR=false |
| **Plumbing / teardown** | | | |
| — | `all.sh` | convenience | Runs the install scripts end-to-end; stops on the first failure |
| — | `delete-vms.sh` | teardown | Powers off and deletes all lab VMs |
| — | `govc-env.sh` | sourced | Exports `GOVC_*` from `lab-config.sh` for the `govc` vSphere CLI |

### 1.5 Required Tools on Bastion

The bastion requires internet access to download tools and to proxy registry requests via Nexus. All commands in this guide run as `root` on the bastion.

```bash
source /root/tools-upi-migrate/lab-config.sh

# OpenShift CLI and installer — OCP 4.16.x
curl -L https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${OCP_VERSION}/openshift-client-linux.tar.gz \
  | tar xz -C /usr/local/bin oc kubectl

curl -L https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${OCP_VERSION}/openshift-install-linux.tar.gz \
  | tar xz -C /usr/local/bin openshift-install

oc version --client
openshift-install version

# yq — must be mikefarah/yq v4+
# The migration manifests use yq syntax specific to this variant.
YQ_VERSION=4.45.4   # « CHANGE » check github.com/mikefarah/yq/releases
curl -L https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_amd64 \
  -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq
yq --version   # Expected: yq (https://github.com/mikefarah/yq/) version v4.x.x

# Cilium CLI (IEP) — for connectivity tests (optional; status checks use oc exec instead)
# IEP/CLife status is checked via: oc exec -n cilium ds/cilium -- cilium status
# Use the Isovalent cilium CLI, NOT the upstream OSS cilium/cilium-cli release.
# Releases: https://github.com/isovalent/cilium-cli-releases/releases
# « CHANGE » set to the version matching your CILIUM_EE_VERSION
CILIUM_CLI_VERSION=v0.19.2-cee.3   # « CHANGE » check isovalent/cilium-cli-releases
curl -L https://github.com/isovalent/cilium-cli-releases/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz \
  | tar xz -C /usr/local/bin cilium

# skopeo — for verifying registry pull-through
dnf install -y skopeo jq

# HAProxy — for API and Ingress load balancing
dnf install -y haproxy

# bind-utils — for DNS record verification (no server needed on bastion)
dnf install -y bind-utils

# httpd — serves RHCOS rootfs and ignition files to booting nodes
dnf install -y httpd
```

> **DNS records must be added before installation** — add these to the existing lab DNS server at `192.168.33.10`. Detailed instructions and the bastion-hosted fallback option are in [Section 3.1](#31-dns-records).
>
> | Name | Type | Value | Purpose |
> |------|------|-------|---------|
> | `api.ocp-migrate.md.prglab.local` | A | `192.168.39.20` | API server — HAProxy frontend on bastion |
> | `api-int.ocp-migrate.md.prglab.local` | A | `192.168.39.20` | API server internal — HAProxy frontend on bastion |
> | `*.apps.ocp-migrate.md.prglab.local` | A | `192.168.39.20` | Ingress wildcard — HAProxy frontend on bastion |
> | `bootstrap.ocp-migrate.md.prglab.local` | A | `192.168.39.19` | Bootstrap node (remove after install) |
> | `master-m-0.ocp-migrate.md.prglab.local` | A | `192.168.39.21` | Control plane 0 |
> | `master-m-1.ocp-migrate.md.prglab.local` | A | `192.168.39.22` | Control plane 1 |
> | `master-m-2.ocp-migrate.md.prglab.local` | A | `192.168.39.23` | Control plane 2 |
> | `worker-m-0.ocp-migrate.md.prglab.local` | A | `192.168.39.25` | Worker 0 |
> | `worker-m-1.ocp-migrate.md.prglab.local` | A | `192.168.39.26` | Worker 1 |
> | `worker-m-2.ocp-migrate.md.prglab.local` | A | `192.168.39.27` | Worker 2 |
> | `artifactory.ocp-migrate.md.prglab.local` | A | `192.168.39.20` | Artifactory pull-through proxy |

---

## 2. Nexus OSS — Pull-Through Registry Proxy

### 2.1 Why Nexus Instead of a Full Mirror

A full oc-mirror pipeline (as used in air-gapped deployments) downloads all OCP release images to a local registry before installation. This requires significant disk space (50–100 GB for a single OCP release) and must be refreshed for every update.

For this lab, Nexus OSS is used as a **pull-through proxy cache** instead:

- Nodes and the bastion pull images from Nexus
- Nexus forwards cache-miss requests to the upstream public registry (internet access required only on the bastion)
- Subsequent pulls for the same image digest are served from Nexus's local cache — no round-trip to the internet
- Red Hat subscription credentials are stored on the Nexus proxy repos, so OCP nodes never need their own RH credentials

```
OCP node / bastion
        │  pull image (HTTPS:8443)
        ▼
  HAProxy (TLS termination, bastion)
        │  HTTP:8081
        ▼
  Nexus OSS (bastion)
        │  cache miss → forward to upstream
        ▼
  upstream registry
  (quay.io, registry.redhat.io,
   quay.io/isovalent, docker.io)
```

**Requirements:**
- Nexus must have outbound HTTPS access to `quay.io`, `registry.redhat.io`, `docker.io` (via the corporate WSA proxy)
- OCP nodes only need HTTPS access to Nexus on port `${ARTIFACTORY_PORT}` — not to the internet directly
- Nexus OSS (free) supports Docker proxy and group repositories with pull-through caching

> **Variable naming:** `lab-config.sh` uses `ARTIFACTORY_*` variable names for historical reasons. They configure the Nexus instance.

### 2.2 Install and Configure Nexus OSS on the Bastion

#### Architecture

Nexus listens on **HTTP port 8081**. HAProxy provides TLS termination on **port 8443**, proxying inbound HTTPS to `localhost:8081`. OCP nodes pull images via `https://${ARTIFACTORY_HOST}:${ARTIFACTORY_PORT}/repository/ocp-images/v2/...`.

```
OCP node  ──HTTPS:8443──►  HAProxy (TLS termination)  ──HTTP:8081──►  Nexus OSS  ──►  upstream registry (cache miss)
```

#### Run the setup script

The script handles everything end-to-end: storage, TLS cert generation, Nexus container start, HAProxy TLS frontend, systemd units, CA trust on the bastion, all four Docker proxy repos, the `ocp-images` group repo, firewall rule, and pull secret merge.

```bash
# Edit lab-config.sh first: set ARTIFACTORY_PASS, PULL_SECRET_FILE, SSH_KEY_FILE
vi /root/tools-upi-migrate/lab-config.sh

bash /root/tools-upi-migrate/setup-artifactory.sh
```

The script performs these steps:
1. Creates `/home/nexus-data` (UID 200 — Nexus's runtime user)
2. Starts `sonatype/nexus3:latest` via podman (`--network=host`, with `INSTALL4J_ADD_VM_PARAMS` baked in for upstream proxy) and creates `nexus-migrate.service` systemd unit
3. Generates a 2-level TLS chain — a `Nexus Lab CA` self-signed root, and a server cert (CN=`${ARTIFACTORY_HOST}`, SAN includes `${BASTION_IP}`) signed by it. HAProxy serves the full chain.
4. Configures HAProxy TLS frontend at `/etc/haproxy/conf.d/artifactory.cfg`, validates with `haproxy -c`, restarts haproxy. The stock CentOS 9 haproxy.service already loads `/etc/haproxy/conf.d/` via `$CFGDIR` — no systemd override is needed.
5. Opens `${ARTIFACTORY_PORT}/tcp` in firewalld and enables the SELinux boolean `haproxy_connect_any` so HAProxy can connect to Nexus on `:8081` (which is labeled `transproxy_port_t` by default).
6. Waits up to 6 minutes for Nexus to be ready.
7. Trusts the CA on the bastion: copies `ca.crt` to `/etc/pki/ca-trust/source/anchors/` and runs `update-ca-trust`; also installs it under `/etc/containers/certs.d/${ARTIFACTORY_HOST}:${ARTIFACTORY_PORT}/ca.crt` for skopeo/podman; exports `CURL_CA_BUNDLE` so in-script curls work under OpenSSL 3.x.
8. Accepts the Nexus Community Edition EULA (required before Docker token endpoint works) via the REST API.
9. Sets the admin password from `${ARTIFACTORY_PASS}` (reads initial password from `/home/nexus-data/admin.password`).
10. Configures the Nexus outbound HTTP proxy via the ExtDirect RPC endpoint (`/service/extdirect`) — the REST API equivalent was removed in Nexus 3.71+.
11. Creates Docker proxy repos: `remote-quay`, `remote-dockerhub`, `remote-redhat` (with RH credentials, `indexType=CUSTOM`), `remote-connect` (with RH credentials, `indexType=CUSTOM`).
12. Creates Docker group repo `ocp-images` aggregating all four proxies with `forceBasicAuth: true` (required — see note below).
13. Merges Nexus credentials into the pull secret → `${PULL_SECRET_ART_FILE}`.
14. Adds `${ARTIFACTORY_HOST}` to `/etc/profile.d/proxy.sh` `no_proxy` so future shells bypass the corporate proxy for local Nexus calls.

#### Verify

```bash
source /root/tools-upi-migrate/lab-config.sh

# Confirm all repos
curl -s --noproxy "*" -u "${ARTIFACTORY_USER}:${ARTIFACTORY_PASS}" \
  "http://localhost:8081/service/rest/v1/repositories" \
  | jq -r '.[] | select(.format=="docker") | .name + " (" + .type + ")"'
# Expected:
# remote-quay (proxy)
# remote-dockerhub (proxy)
# remote-redhat (proxy)
# remote-connect (proxy)
# ocp-images (group)

# Docker v2 API via HTTPS
curl -sk --noproxy "*" -u "${ARTIFACTORY_USER}:${ARTIFACTORY_PASS}" \
  -o /dev/null -w "%{http_code}\n" \
  "https://${ARTIFACTORY_HOST}:${ARTIFACTORY_PORT}/repository/ocp-images/v2/"
# Expected: 200
```

**How image routing works:**

OCP nodes pull images using the bare Nexus hostname (`${ARTIFACTORY_HOST}:${ARTIFACTORY_PORT}/<image>`). HAProxy rewrites the Docker v2 path (`/v2/...` → `/repository/ocp-images/v2/...`) before forwarding to Nexus on port 8081. Nexus then routes to the appropriate upstream proxy repo based on which one has the image.

1. Node requests `${ARTIFACTORY_HOST}:8443/v2/openshift4/ose-cli/manifests/latest`
2. HAProxy rewrites to `/repository/ocp-images/v2/openshift4/ose-cli/manifests/latest`
3. Nexus `ocp-images` group checks each member repo (remote-quay, remote-redhat, remote-connect, remote-dockerhub) in order
4. Matching repo fetches from upstream through the corporate proxy and caches locally
5. Subsequent pulls for the same digest are served from cache

The ICSP in Section 3.6 maps OCP's original registry paths to this Nexus endpoint transparently.

### 2.3 Verify Pull-Through Works

Before installing OCP, confirm that Nexus can pull-through images from each upstream. The pull path uses the bare hostname — **no `/repository/ocp-images/` prefix** — because HAProxy handles that rewrite.

```bash
source /etc/profile.d/proxy.sh   # picks up the updated no_proxy with the Nexus hostname
source /root/tools-upi-migrate/lab-config.sh

# Test OCP release image (quay.io → remote-quay)
skopeo inspect --tls-verify=true --authfile "${PULL_SECRET_ART_FILE}" \
  "docker://${ARTIFACTORY_HOST}:${ARTIFACTORY_PORT}/openshift-release-dev/ocp-release:${OCP_VERSION}-x86_64" \
  2>&1 | head -5
# Expected: JSON with Name, Digest, RepoTags, etc.

# Test Isovalent image (quay.io/isovalent — public, no upstream auth required)
skopeo inspect --tls-verify=true --authfile "${PULL_SECRET_ART_FILE}" \
  "docker://${ARTIFACTORY_HOST}:${ARTIFACTORY_PORT}/isovalent/cilium-ubi:v${CILIUM_EE_VERSION}-${CEE_SUFFIX}" \
  2>&1 | head -5

# Test Red Hat operator image (registry.redhat.io → remote-redhat)
skopeo inspect --tls-verify=true --authfile "${PULL_SECRET_ART_FILE}" \
  "docker://${ARTIFACTORY_HOST}:${ARTIFACTORY_PORT}/openshift4/ose-cli:latest" \
  2>&1 | head -5
```

> **First pull is slow** — Nexus fetches from upstream and caches locally. Subsequent pulls for the same digest are fast.

> **Use `--authfile`, not `--creds`:** the merged `${PULL_SECRET_ART_FILE}` contains both the Nexus admin credentials (for skopeo↔Nexus auth) and the upstream credentials (used by Nexus when proxying to Red Hat / quay.io). Passing `--creds` alone strips the upstream context.

#### Why these specific Nexus settings matter

- **`forceBasicAuth: true` on the group repo:** with the default `forceBasicAuth: false`, Nexus issues Bearer tokens whose `service` claim doesn't match the externally-visible service identity (HAProxy rewrites the path, so Nexus and the client disagree on what "service" means). Manifest GETs then fail with 401. `forceBasicAuth: true` skips the token dance and uses HTTP Basic, which works cleanly through HAProxy.
- **`indexType=CUSTOM` for `registry.redhat.io` / `registry.connect.redhat.com`:** the RHCC token endpoint requires `service="docker-registry"`, but Nexus defaults to `service="<registry-hostname>"`. The repos hardcode the token URL with `?service=docker-registry`.
- **`/etc/containers/certs.d/${ARTIFACTORY_HOST}:${ARTIFACTORY_PORT}/ca.crt`:** skopeo/podman on CentOS Stream 9 don't fully honour the system trust store (OpenSSL 3.x trust marker quirk) for user-added CAs. They must read the CA from `certs.d` directly.
- **SELinux `haproxy_connect_any` boolean:** without it, HAProxy can't connect to Nexus on `:8081` (`transproxy_port_t` is not in haproxy_t's default allow-list) and the backend gets marked DOWN.
- **`INSTALL4J_ADD_VM_PARAMS` with `-Dhttp.proxyHost=…` baked into `podman run`:** Nexus's internal Apache HttpClient ignores process-env `HTTPS_PROXY`. The JVM flags must be set at container start; the script then also configures Nexus's logical proxy settings via ExtDirect once Nexus is up.

---

## 3. Install OpenShift 4.16 UPI with OVN-Kubernetes

UPI (User-Provisioned Infrastructure) means the OpenShift installer generates ignition configs and you are responsible for provisioning nodes and boot infrastructure. This section covers:

- DNS records for the cluster
- HAProxy as the load balancer for API and Ingress
- RHCOS PXE or ISO boot via vSphere VMs
- No vSphere cloud provider integration (`platform: none`)

### 3.1 DNS Records

UPI requires DNS to be configured before installation. The lab has an existing DNS server at `192.168.33.10` — **add the OCP cluster zone records there**. No second DNS server is needed on the bastion.

> **Do you need a second DNS server?** No. The existing DNS at `192.168.33.10` is reachable from both the `192.168.33.0/24` and `192.168.39.0/24` subnets. OCP nodes are configured to use this server via the DHCP or static network configuration baked into their ignition. A bastion-hosted DNS would only be needed if the existing DNS is not reachable from the `192.168.39.0/24` network, or if you do not have rights to add records to it.

**Required records — add to the DNS server at `192.168.33.10`:**

| Name | Type | Value | Purpose |
|------|------|-------|---------|
| `api.${CLUSTER_NAME}.${BASE_DOMAIN}` | A | `192.168.39.20` | API server (external) — HAProxy on bastion |
| `api-int.${CLUSTER_NAME}.${BASE_DOMAIN}` | A | `192.168.39.20` | API server (internal) — HAProxy on bastion |
| `*.apps.${CLUSTER_NAME}.${BASE_DOMAIN}` | A | `192.168.39.20` | Ingress wildcard — HAProxy on bastion |
| `bootstrap.${CLUSTER_NAME}.${BASE_DOMAIN}` | A | `192.168.39.19` | Bootstrap node (temporary) |
| `master-m-0.${CLUSTER_NAME}.${BASE_DOMAIN}` | A | `192.168.39.21` | Control plane 0 |
| `master-m-1.${CLUSTER_NAME}.${BASE_DOMAIN}` | A | `192.168.39.22` | Control plane 1 |
| `master-m-2.${CLUSTER_NAME}.${BASE_DOMAIN}` | A | `192.168.39.23` | Control plane 2 |
| `worker-m-0.${CLUSTER_NAME}.${BASE_DOMAIN}` | A | `192.168.39.25` | Worker 0 |
| `worker-m-1.${CLUSTER_NAME}.${BASE_DOMAIN}` | A | `192.168.39.26` | Worker 1 |
| `worker-m-2.${CLUSTER_NAME}.${BASE_DOMAIN}` | A | `192.168.39.27` | Worker 2 |
| `artifactory.${CLUSTER_NAME}.${BASE_DOMAIN}` | A | `192.168.39.20` | Artifactory pull-through proxy |

> **All client-facing endpoints front through the bastion at `.20`:** `api`, `api-int`, and `*.apps` all point at `192.168.39.20` where HAProxy listens on `:6443`, `:22623`, `:80`, `:443`. HAProxy then load-balances to the masters/workers on their actual IPs (`.21–.23` / `.25–.27`). The `.24` and `.28` records are not needed for this 3+3 topology — leave them out unless you expand the cluster.
>
> **Reverse PTR records are required** for OCP UPI on `platform: none`. Each node IP must have a PTR pointing to its node name (e.g. `21.39.168.192.in-addr.arpa. PTR master-m-0.${CLUSTER_NAME}.${BASE_DOMAIN}.`). PTRs for `.20` (bastion), `.19` (bootstrap), and `.21–.23`/`.25–.27` (nodes) must all return their unique hostnames — **not** `api` or `*.apps`.

**Verify DNS from the bastion after adding records:**

```bash
source /root/tools-upi-migrate/lab-config.sh

# Point dig at the existing DNS server
dig api.${CLUSTER_NAME}.${BASE_DOMAIN}      @${DNS_SERVER} +short
dig api-int.${CLUSTER_NAME}.${BASE_DOMAIN}  @${DNS_SERVER} +short
dig test.apps.${CLUSTER_NAME}.${BASE_DOMAIN} @${DNS_SERVER} +short
dig master-m-0.${CLUSTER_NAME}.${BASE_DOMAIN} @${DNS_SERVER} +short
dig worker-m-2.${CLUSTER_NAME}.${BASE_DOMAIN} @${DNS_SERVER} +short
dig artifactory.${CLUSTER_NAME}.${BASE_DOMAIN} @${DNS_SERVER} +short
```

**Alternative — if you cannot add records to the existing DNS server**, configure named on the bastion as an authoritative server for the cluster zone only, and point the bastion and OCP node static network configs at `192.168.39.20`:

```bash
source /root/tools-upi-migrate/lab-config.sh

dnf install -y bind bind-utils

ZONE_FILE="/var/named/${CLUSTER_NAME}.${BASE_DOMAIN}.zone"
cat > ${ZONE_FILE} <<EOF
\$TTL 300
@   IN SOA  ns1.${CLUSTER_NAME}.${BASE_DOMAIN}. admin.${BASE_DOMAIN}. (
            $(date +%Y%m%d01) 3600 900 604800 300 )
@           IN NS   ns1.${CLUSTER_NAME}.${BASE_DOMAIN}.
ns1         IN A    ${BASTION_IP}

api         IN A    ${API_VIP}
api-int     IN A    ${API_VIP}
*.apps      IN A    ${INGRESS_VIP}

bootstrap     IN A    ${BOOTSTRAP_IP}
master-m-0    IN A    ${MASTER0_IP}
master-m-1    IN A    ${MASTER1_IP}
master-m-2    IN A    ${MASTER2_IP}
worker-m-0    IN A    ${WORKER0_IP}
worker-m-1    IN A    ${WORKER1_IP}
worker-m-2    IN A    ${WORKER2_IP}
artifactory   IN A    ${BASTION_IP}
EOF

cat >> /etc/named.conf <<EOF
zone "${CLUSTER_NAME}.${BASE_DOMAIN}" IN {
    type master;
    file "${ZONE_FILE}";
    allow-query { any; };
};
EOF

systemctl enable --now named
named-checkzone ${CLUSTER_NAME}.${BASE_DOMAIN} ${ZONE_FILE}

dig api.${CLUSTER_NAME}.${BASE_DOMAIN} @${BASTION_IP} +short
```

### 3.2 Load Balancer

HAProxy on the bastion load-balances API (port 6443), Machine Config (port 22623), and Ingress (ports 80/443) traffic to the appropriate backend nodes. `setup-haproxy.sh` writes the full config and enables the service:

```bash
bash /root/tools-upi-migrate/setup-haproxy.sh
```

The frontends/backends it creates:

| Frontend | Bind | Backends | Notes |
|----------|------|----------|-------|
| `api` | `*:6443` | bootstrap + 3 masters | bootstrap entry removed after install — see `remove-bootstrap-from-haproxy.sh` |
| `mcs` | `*:22623` | bootstrap + 3 masters | Machine Config Server |
| `ingress_http` | `*:80` | 3 workers | |
| `ingress_https` | `*:443` | 3 workers | |

The script also runs `setsebool -P haproxy_connect_any=1` (required for HAProxy to connect to backends on arbitrary ports under SELinux — the same boolean is set by `setup-artifactory.sh` so this is idempotent) and opens 6443/22623/80/443 in firewalld.

> If you ran `setup-artifactory.sh` first, its TLS frontend on `:8443` lives in `/etc/haproxy/conf.d/artifactory.cfg` and survives — `setup-haproxy.sh` only writes `/etc/haproxy/haproxy.cfg`, and the stock systemd unit loads both via `-f $CONFIG -f $CFGDIR`.

> **After installation:** run `bash /root/tools-upi-migrate/remove-bootstrap-from-haproxy.sh` to strip the bootstrap entries from `api_backend` and `mcs_backend` and reload HAProxy.

### 3.3 Pull Secret and SSH Key

```bash
# Generate an SSH key if you don't have one
ssh-keygen -t ed25519 -f /root/.ssh/id_rsa -N ""

# Confirm the merged pull secret from Section 2.2 exists (includes Nexus credentials)
source /root/tools-upi-migrate/lab-config.sh
jq '.auths | keys' ${PULL_SECRET_FILE}
```

### 3.4 install-config.yaml

UPI with `platform: none` — no cloud provider, no VIPs managed by the installer. The cluster nodes are treated as bare metal.

`gen-ignition.sh` writes `install-config.yaml` automatically from `lab-config.sh` values in step 5 of [Section 3.5](#35-download-rhcos-serve-it-and-generate-ignition-configs); you do not need to write the file by hand. The generated content is equivalent to:

```yaml
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
metadata:
  name: ${CLUSTER_NAME}
compute:
  - architecture: amd64
    hyperthreading: Enabled
    name: worker
    replicas: 0           # UPI: workers are provisioned manually
controlPlane:
  architecture: amd64
  hyperthreading: Enabled
  name: master
  replicas: 3
networking:
  clusterNetwork:
    - cidr: ${POD_CIDR}            # 10.128.0.0/14 (OVN default)
      hostPrefix: ${POD_HOST_PREFIX}  # 23
  machineNetwork:
    - cidr: ${NODE_NETWORK}        # 192.168.39.0/24
  networkType: OVNKubernetes
  serviceNetwork:
    - ${SERVICE_CIDR}              # 172.30.0.0/16
platform:
  none: {}              # No cloud provider — VMs treated as bare metal
fips: false
pullSecret: '<contents of ${PULL_SECRET_ART_FILE}>'   # merged: Red Hat + Nexus creds
sshKey: '<contents of ${SSH_KEY_FILE}>'
```

Key points:

- **`replicas: 0` for workers**: in UPI, workers are provisioned manually and join after bootstrap. The installer does not create them.
- **`replicas: 3` for control plane**: odd number required for etcd quorum. The lab uses `master-m-0`, `master-m-1`, `master-m-2`. The IPs `.24` (`master-m-3`) and `.28` (`worker-m-3`) are reserved in `lab-config.sh`/DNS for future expansion but are not part of this install — no VM created, not in any HAProxy backend, and `MASTER3_IP`/`WORKER3_IP` are not exported.
- **`pullSecret: ${PULL_SECRET_ART_FILE}`** (not `${PULL_SECRET_FILE}`): `setup-artifactory.sh` produces a merged pull secret that includes Nexus credentials. OCP nodes need this merged file so they can authenticate to Nexus.
- **`platform: none`**: the installer doesn't provision VMs or VIPs. DNS + HAProxy do all the work.
- **`imageContentSources:`** (rendered into install-config by gen-ignition.sh): tells the **bootstrap** node to redirect `quay.io/openshift-release-dev/...` → `${ARTIFACTORY_HOST}:${ARTIFACTORY_PORT}/openshift-release-dev/...`, and the same for `registry.redhat.io`, `quay.io/isovalent`, etc. This must be in `install-config.yaml` itself, not just as an ICSP manifest. Reason: the bootstrap node pulls the OCP release image **before** any cluster API exists, so an ICSP CRD applied at cluster creation time is too late. Without `imageContentSources` the bootstrap node tries to reach `quay.io` directly, times out, and the install hangs at `release-image.service`.
- **`additionalTrustBundle:`** (rendered into install-config by gen-ignition.sh): the Nexus CA cert, so the bootstrap node trusts the HTTPS endpoint on the bastion when fetching the release image.

gen-ignition.sh also drops two cluster-config manifests under `openshift/` that are consumed at install time:

- **`99-cluster-scheduler.yaml`** — sets `Scheduler.spec.mastersSchedulable: false`. With `compute.replicas: 0` (UPI default), the installer otherwise leaves masters schedulable for normal workloads and auto-labels them with `node-role.kubernetes.io/worker=""`. Any nodeSelector that uses the `worker` label then matches both masters and workers — and the scheduler can place router pods on masters, leaving HAProxy backends to real workers permanently DOWN. Forcing `mastersSchedulable: false` strips the worker label from masters so workload placement targets only the real workers.
- **`99-cluster-ingress-default.yaml`** — pins the default `IngressController` to `endpointPublishingStrategy.type: HostNetwork` with `nodePlacement.nodeSelector` matching `node-role.kubernetes.io/worker`. Without this, the operator defaults to `NodePortService` (or a cloud LB), and the routers run with a `ClusterIP` Service that no external HAProxy can reach. With HostNetwork + worker-only selector, routers bind directly to `:80`/`:443` on the worker host network and HAProxy's `ingress_http_backend`/`ingress_https_backend` checks pass.

The generated `imageContentSources` block:

```yaml
imageContentSources:
- mirrors:
  - ${ARTIFACTORY_HOST}:${ARTIFACTORY_PORT}/openshift-release-dev
  source: quay.io/openshift-release-dev
- mirrors:
  - ${ARTIFACTORY_HOST}:${ARTIFACTORY_PORT}
  source: registry.redhat.io
- mirrors:
  - ${ARTIFACTORY_HOST}:${ARTIFACTORY_PORT}
  source: registry.connect.redhat.com
- mirrors:
  - ${ARTIFACTORY_HOST}:${ARTIFACTORY_PORT}/isovalent
  source: quay.io/isovalent
- mirrors:
  - ${ARTIFACTORY_HOST}:${ARTIFACTORY_PORT}
  source: quay.io
- mirrors:
  - ${ARTIFACTORY_HOST}:${ARTIFACTORY_PORT}
  source: docker.io
additionalTrustBundle: |
  <PEM contents of /etc/haproxy/certs/ca.crt>
```

> Edit `${INSTALL_DIR}/install-config.yaml` only if you need to tweak something gen-ignition.sh doesn't expose. Re-run gen-ignition.sh whenever the values in `lab-config.sh` change.

### 3.5 Download RHCOS, Serve It, and Generate Ignition Configs

Phase 1 of the lab (bastion-only, needs internet) splits into four scripts. Run them in order:

```bash
# 1. Download the RHCOS live ISO + rootfs for the configured OCP_VERSION
#    Output: ${INSTALL_DIR}/rhcos/rhcos-live.iso, rhcos-rootfs.img
bash /root/tools-upi-migrate/download-rhcos.sh

# 2. Upload the live ISO into the vSphere datastore so VMs can boot from it
#    Uses the VCENTER_* settings from lab-config.sh
bash /root/tools-upi-migrate/upload-iso.sh

# 3. Stand up the API/MCS/Ingress HAProxy frontend on the bastion (Section 3.2 detail)
bash /root/tools-upi-migrate/setup-haproxy.sh

# 4. Stand up Apache on port 8080 to serve ignition + RHCOS rootfs to booting nodes
bash /root/tools-upi-migrate/setup-httpd.sh

# 5. Generate install-config.yaml, manifests (including the ICSP + CA MachineConfig),
#    and ignition configs; copy ignition files into the httpd docroot
bash /root/tools-upi-migrate/gen-ignition.sh

ls "${INSTALL_DIR}"
# Expected: auth/  bootstrap.ign  master.ign  worker.ign  metadata.json  openshift/  rhcos/
ls /var/www/html/ignition/
# Expected: bootstrap.ign  master.ign  worker.ign
```

What each script does:

| Script | Purpose |
|--------|---------|
| `download-rhcos.sh` | Resolves the RHCOS artifacts for `OCP_VERSION` from `openshift-install coreos print-stream-json` and downloads `rhcos-live.iso` and `rhcos-rootfs.img` into `${INSTALL_DIR}/rhcos/`. Idempotent — skips files that already exist. |
| `upload-iso.sh` | Pushes `rhcos-live.iso` to the vSphere datastore via `govc`. **VMs must be powered off first** — vSphere locks ISOs that are attached to running VMs. |
| `setup-haproxy.sh` | Writes the API/MCS/Ingress HAProxy backends (`api`, `api-int`, `*.apps`, `machine-config-server`) — see Section 3.2 for the configuration detail. |
| `setup-httpd.sh` | Installs httpd, enables it on port 8080, opens the firewall, and creates `/var/www/html/ignition/` with SELinux contexts so ignition files are reachable from RHCOS during first boot. |
| `gen-ignition.sh` | Writes `install-config.yaml` from `lab-config.sh` values, runs `openshift-install create manifests`, drops the Nexus `ImageContentSourcePolicy` and a CA-trust `MachineConfig` into `openshift/`, runs `openshift-install create ignition-configs`, and copies the three `.ign` files into `/var/www/html/ignition/`. |

> Run `bash /root/tools-upi-migrate/all.sh` to chain all of Phase 1 in one go (it stops on the first failure).

After this step, ignition files are reachable at `http://${BASTION_IP}:8080/ignition/<role>.ign`.

### 3.6 Cluster Manifests Dropped Into `openshift/`

`gen-ignition.sh` writes several cluster-config manifests under `${INSTALL_DIR}/openshift/` before running `openshift-install create ignition-configs`. The installer merges them into the manifest set that bootkube renders on the bootstrap node, so they take effect from the moment the cluster API comes up.

| File | Purpose |
|------|---------|
| `99-artifactory-idms.yaml` + `99-artifactory-itms.yaml` | `ImageDigestMirrorSet` (IDMS) and `ImageTagMirrorSet` (ITMS) for ongoing pulls after bootstrap. **Shipped as two separate files** — see warning below. Mirrors `quay.io/openshift-release-dev`, `registry.redhat.io`, `registry.connect.redhat.com`, `quay.io/isovalent`, `quay.io`, `docker.io` → Nexus. **Both are needed** — IDMS alone (or its predecessor ICSP) only mirrors `image@sha256:digest` references; tag references like `docker.io/istio/...:1.18.0` fall through to the original source and time out in air-gapped/proxy-only environments. ITMS adds `pull-from-mirror = "tag-and-digest"` to CRI-O's `registries.conf` so tag pulls are mirrored too. Complements `imageContentSources` in `install-config.yaml`, which is required for the **bootstrap-time** release-image pull (Section 3.4). |
| `99-master-artifactory-ca.yaml`, `99-worker-artifactory-ca.yaml` | `MachineConfig` per role that drops `/etc/pki/ca-trust/source/anchors/artifactory-migrate.crt` (the Nexus CA cert) on every node. RHCOS runs `update-ca-trust` automatically on firstboot. Do **not** add `spec.extensions: [update-ca-trust]` — that's not a valid OCP MachineConfig extension and makes bootkube's machine-config-controller crashloop with `invalid extensions found: [update-ca-trust]`, which leaves MCS on `:22623` down so masters never get their configs. |
| `manifests/cluster-scheduler-02-config.yml` (patched in-place) | The installer already generates this manifest. `gen-ignition.sh` flips `spec.mastersSchedulable: true → false`. Stops masters from getting the `worker` label automatically (which UPI does when `compute.replicas: 0`). Adding a second `Scheduler` under `openshift/` would fail the installer with `multiple manifests for group config.openshift.io kind Scheduler`. |
| `99-cluster-ingress-default.yaml` | Default `IngressController` configured for `HostNetwork` + worker-only `nodePlacement`. Routers bind to `:80`/`:443` on worker host network so the bastion HAProxy ingress backends actually work. |

Verify the generated set:

```bash
ls /root/ocp-upi-migrate/openshift/
# Expected:
# 99-artifactory-icsp.yaml
# 99-cluster-ingress-default.yaml
# 99-cluster-scheduler.yaml
# 99-master-artifactory-ca.yaml
# 99-worker-artifactory-ca.yaml
```

> **IDMS vs ITMS vs ICSP:** OCP 4.13+ supports `ImageDigestMirrorSet` (IDMS) and `ImageTagMirrorSet` (ITMS) as the new mirror APIs; `ImageContentSourcePolicy` (ICSP) is the deprecated predecessor. IDMS/ICSP mirror **digest** references only (`image@sha256:digest`); ITMS is required for **tag** references (`image:tag`). The Bookinfo deployment in Section 4 uses tags, so ITMS is mandatory. This guide ships IDMS as `99-artifactory-idms.yaml` and ITMS as `99-artifactory-itms.yaml` (two separate files) to cover both pull styles.

> **Critical: IDMS and ITMS must be in SEPARATE files under `openshift/`.** Bootkube's manifest loader applies each file under `openshift/` as a single resource. Multi-doc YAML separated by `---` results in only the FIRST document being applied. If you combine IDMS + ITMS into one file, only IDMS lands in the cluster; ITMS is silently dropped. The in-cluster MCC then renders `/etc/containers/registries.conf` with only `pull-from-mirror = "digest-only"`, but the on-disk file written during bootstrap also has `tag-only` mirrors. The MCD sees the content mismatch and marks every master node Degraded with `"unexpected on-disk state validating against rendered-master-<hash>: content mismatch for file '/etc/containers/registries.conf'"`. The master MCP gets stuck and the cluster never reaches `install-complete`. `gen-ignition.sh` writes them as two separate files. If you generate manifests by hand, do the same.

### 3.7 PXE Boot and Unattended RHCOS Install

All 7 VMs install RHCOS unattended via PXE. The bastion runs **dnsmasq** (DHCP + TFTP) restricted to the 7 known lab MACs; per-MAC grub configs in TFTP hand the right kernel command line — static IP, ignition URL — to each VM. The RHCOS kernel, initramfs, and rootfs are served by httpd on `:8080` (set up in Section 3.5).

#### 3.7.1 Stand up PXE on the bastion

```bash
bash /root/tools-upi-migrate/setup-pxe.sh
```

The script:
1. Installs `dnsmasq`, `syslinux-tftpboot`, `shim-x64`, `grub2-efi-x64`
2. Extracts `vmlinuz` + `initrd.img` from the uploaded RHCOS ISO into `${INSTALL_DIR}/rhcos/`
3. Populates `/var/lib/tftpboot/` with `shimx64.efi`, `grubx64.efi`, and a top-level `EFI/grub.cfg` that loads `EFI/grub-cfg/<mac>.cfg` based on `${net_default_mac}`
4. Queries each VM's MAC via govc and writes a per-MAC grub config containing the role-specific kernel args (static IP `${IP}::${NODE_GATEWAY}:255.255.255.0:<hostname>:ens192:none`, `coreos.live.rootfs_url`, `coreos.inst.ignition_url`)
5. Writes `/etc/dnsmasq.d/ocp-pxe.conf` with DHCP scope restricted to the known MACs (`dhcp-ignore=tag:!known`) and TFTP enabled; opens DHCP + TFTP in firewalld
6. Loosens permissions on `/var/lib/tftpboot` so the `dnsmasq` user can serve the EFI binaries (default `0700` from `/boot/efi/EFI/centos/`)
7. Sets vSphere VM boot order to `ethernet,disk` with a 2-second delay so the firmware actually tries PXE first

> **DHCP safety:** the dnsmasq config uses `dhcp-host=<mac>,<ip>,<hostname>,infinite,set:known` for the 7 lab MACs only and rejects everything else with `dhcp-ignore=tag:!known`. Even if another DHCP server appears on `192.168.39.0/24`, this dnsmasq only answers for known MACs and won't clash for any client it doesn't recognise — but **don't** run two DHCP servers on the same broadcast domain in production.

#### 3.7.2 PXE-install and switch to disk-boot

```bash
bash /root/tools-upi-migrate/pxe-install-and-boot.sh
```

This script handles the full PXE-install lifecycle for all 7 VMs:

1. **For each VM** (bootstrap → masters in parallel → workers in parallel):
   - Set vSphere boot order to `ethernet,disk` and power off if running
   - Power on — EFI firmware does DHCP, fetches `shimx64.efi` then `grubx64.efi` then `grub.cfg`, and loads `EFI/grub-cfg/<vm-mac>.cfg` (the per-VM config)
   - grub fetches `vmlinuz` + `initrd.img` via TFTP and starts the RHCOS live environment with kernel args:
     - `ip=<static>` — assigns the static IP for the role (no second DHCP from the live OS)
     - `coreos.live.rootfs_url` — HTTP URL for the 1.1 GB rootfs (TFTP can't carry it efficiently)
     - `coreos.inst.install_dev=/dev/sda` — target disk
     - `coreos.inst.ignition_url` — role-specific ignition URL on httpd
     - `coreos.inst.insecure_ignition` — allow HTTP ignition URL (lab only)
     - **`coreos.inst.skip_reboot`** — critical: keeps the VM in the live environment after writing the disk, instead of rebooting straight back into PXE and re-installing forever
   - Wait until the VM stops re-DHCPing for 90 seconds — proxy signal that the install finished
   - Flip vSphere boot order to `disk,ethernet` and power-cycle — now the VM boots from the freshly-installed disk and starts as a real cluster node

2. **Phase ordering**:
   - Bootstrap goes first because masters need it to fetch the rendered MachineConfig and to form etcd
   - Masters install in parallel (each has its own MAC → its own grub config) once bootstrap is on disk
   - Workers install in parallel after masters

Watch progress in two places:

```bash
# dnsmasq DHCP + TFTP activity (one terminal)
journalctl -fu dnsmasq

# httpd accesses — rootfs + ignition pulls (another terminal)
tail -f /var/log/httpd/access_log
```

Total install time for all 7 VMs: roughly **15–25 minutes** depending on disk and network speed.

> **Why `skip_reboot`?** With boot order `ethernet,disk`, the post-install reboot would PXE again before the disk gets a chance. `skip_reboot` keeps the VM idle in the live environment until the bastion script flips the boot order and power-cycles it. Without this, you get an infinite PXE→install→reboot→PXE loop.

> **Troubleshooting PXE:** `journalctl -fu dnsmasq` shows DHCPDISCOVER/OFFER/REQUEST and TFTP file fetches. Common failures:
> - "PXE-E53: no boot filename received" — the MAC isn't in dnsmasq `dhcp-host`. Re-run `setup-pxe.sh`.
> - "file not found" for `grubx64.efi` or `revocations.efi` — shim looks in the TFTP root, not under `EFI/`. `setup-pxe.sh` puts them at the root; if you moved them, the chain breaks.
> - VM hangs after kernel banner — check `journalctl -fu dnsmasq` for kernel/initrd TFTP fetches and `tail -f /var/log/httpd/access_log` for the rootfs/ignition fetches.

### 3.8 Monitor and Complete the Installation

```bash
source /root/tools-upi-migrate/lab-config.sh

# Watch bootstrap progress (takes ~20 minutes)
openshift-install --dir /root/ocp-upi-migrate wait-for bootstrap-complete \
  --log-level=info
# Expected: "Bootstrap status: complete" and "It is now safe to remove the bootstrap resources"

# Once bootstrap is complete:
# 1. Remove the bootstrap VM (or power it off)
# 2. Remove the bootstrap entries from HAProxy:
sed -i '/bootstrap/d' /etc/haproxy/haproxy.cfg
systemctl reload haproxy

# Approve worker CSRs (workers generate CSRs when they first contact the API)
# Run this loop until all nodes are Ready
for i in {1..10}; do
  oc get csr -o name | grep Pending | xargs -r oc adm certificate approve
  sleep 30
done

# Monitor node readiness
oc get nodes -w

# Wait for full installation to complete (~30 more minutes after bootstrap)
openshift-install --dir /root/ocp-upi-migrate wait-for install-complete \
  --log-level=info
# Expected: "Install complete! ... Access the OpenShift web-console here: ..."
```

### 3.9 Verify Cluster Health

```bash
source /root/tools-upi-migrate/lab-config.sh

# All operators Available, not Progressing, not Degraded
oc get clusteroperators

# All nodes Ready
oc get nodes

# OVN-Kubernetes pods running
oc get pods -n openshift-ovn-kubernetes -o wide | head -20

# Verify images were pulled via Nexus
# Check that nodes are using the ICSP (look for mirror entries in CRI-O config)
oc debug node/${WORKER0_IP/./-} -- chroot /host \
  cat /etc/containers/registries.conf.d/999-artificial-icsp.conf 2>/dev/null | head -20

# Verify Nexus cache has been populated
curl -sk -u ${ARTIFACTORY_USER}:${ARTIFACTORY_PASS} \
  "${ARTIFACTORY_URL}/artifactory/api/storage/${ARTIFACTORY_OCP_REPO}" \
  | jq '.children | length'
# Should show non-zero — images are cached
```

Expected output: all cluster operators `AVAILABLE=True`, `PROGRESSING=False`, `DEGRADED=False`. All 6 nodes `STATUS=Ready` (3 masters + 3 workers).

### 3.10 UPI Install Pitfalls / Troubleshooting

These are concrete failure modes seen during this lab's bring-up. Each is handled correctly by the current scripts; this is the reference if you need to debug a deviation.

**`no_proxy` matching is IP-only for bare-number entries.** A common stock value `no_proxy="...,10,192"` only matches IP addresses starting with `10.` or `192.` — it does **not** match an FQDN that resolves to `192.168.x.x`. Result: `oc get nodes` against `api.${CLUSTER}.${DOMAIN}` is sent through the corporate proxy, which returns its own `Service Unavailable` when it can't reach the internal IP. Symptoms look identical to "kube-apiserver is broken." Fix: use `192.168.0.0/16` and `.${BASE_DOMAIN}` (Go-style suffix match). The current `/etc/profile.d/proxy.sh` uses:
```
no_proxy="localhost,127.0.0.1,10,192.168.0.0/16,.cisco.com,.md.prglab.local"
```

**Bootstrap pulls the OCP release image *before* any cluster API exists.** `release-image-download.sh` on bootstrap is what fetches `quay.io/openshift-release-dev/ocp-release@sha256:...` and pivots the bootstrap pods. An `ImageContentSourcePolicy` CRD applied at cluster creation time is too late — bootstrap never gets to that point. You must put `imageContentSources:` (and `additionalTrustBundle:` for HTTPS to the private registry) **into `install-config.yaml` itself**, which is what `gen-ignition.sh` does. Symptom of the missing block: bootstrap log shows repeating `dial tcp <quay-ip>:443: i/o timeout` for the full 20 minutes that `openshift-install wait-for bootstrap-complete` allows.

**Invalid MachineConfig `extensions:` keep MCS down.** OCP's `MachineConfig.spec.extensions` accepts only a fixed list of named extensions (`usbguard`, `kerberos`, `kernel-devel`, …). `update-ca-trust` is NOT in that list. If you include it, bootkube's machine-config-controller crashloops with:
```
F bootstrap.go:47] error running MCC[BOOTSTRAP]: invalid extensions found: [update-ca-trust]
```
which prevents MCS from ever starting on `:22623`. Masters then PXE into the live env, fetch their pointer ignition (which says "go ask MCS for the real config"), and stall — no failures, just nothing happens. RHCOS already runs `update-ca-trust` automatically on firstboot when files land in `/etc/pki/ca-trust/source/anchors/`, so the `extensions:` field is never needed for CA trust.

**Bootstrap kubeconfig becomes invalid after lb-signer rotation.** The kubeconfig the installer writes to `${INSTALL_DIR}/auth/kubeconfig` is signed by a short-lived bootstrap CA. After bootstrap-complete fires, the kube-apiserver-lb-signer rotates and the original kubeconfig stops working — `oc get nodes` returns `Service Unavailable` (or the corporate-proxy variant, if `no_proxy` is wrong). `monitor-install.sh` refreshes the kubeconfig from `localhost.kubeconfig` on one of the masters and rewrites the server URL to `https://api.${CLUSTER}.${DOMAIN}:6443`. If you run `oc` manually before this refresh, expect 503s.

**`compute.replicas: 0` makes masters dual-role workers.** UPI sets `Scheduler.mastersSchedulable=true` and auto-labels masters with `node-role.kubernetes.io/worker=""`. The ingress operator's default placement (`nodeSelector: node-role.kubernetes.io/worker=""`) then matches masters too, and routers can land on masters — leaving HAProxy backends to real workers DOWN forever. Result: `ingress`, `authentication`, `console` operators degrade because their routes are unreachable via the LB. Fix: drop `99-cluster-scheduler.yaml` with `mastersSchedulable: false` into `openshift/` so masters never get the worker label. Then the default IngressController scheduler hits only real workers, and `99-cluster-ingress-default.yaml` (HostNetwork + worker-only) makes them bind host ports `:80`/`:443` so HAProxy can reach them.

**Containers/image cert trust on CentOS 9.** Skopeo/podman on CentOS Stream 9 don't fully honor user-added CAs in the system trust pem bundle (OpenSSL 3.x trust-marker quirk). `setup-artifactory.sh` works around this by copying the Nexus CA into `/etc/containers/certs.d/<host>:<port>/ca.crt` so the containers/image library reads it directly. Symptom of the missing copy: skopeo gets `x509: certificate signed by unknown authority` even though `curl --cacert` succeeds.

---

## 4. Deploy the Test Application

The test application establishes a connectivity baseline before migration. It must remain functional through and after the migration. We use **Bookinfo** — the standard Istio sample app — because it has multiple services with HTTP dependencies between them, making it easy to detect connectivity regressions.

### 4.1 Application Architecture

```
Browser / curl
     │
     ▼
 productpage (port 9080)
     │
     ├─▶ details (port 9080)
     └─▶ reviews (port 9080)
           └─▶ ratings (port 9080)
```

Four services, four deployments, multiple pod-to-pod connections across namespaces — a good representative workload.

### 4.2 Deploy Bookinfo

```bash
source /root/tools-upi-migrate/lab-config.sh

# Create namespace
oc new-project bookinfo

# Deploy Bookinfo (upstream YAML — no Istio required)
# Images (docker.io/istio/*) are transparently redirected to Nexus by the
# ImageTagMirrorSet (ITMS) from `99-artifactory-itms.yaml` configured in
# Section 3.6 — Bookinfo pulls by tag (e.g. examples-bookinfo-productpage-v1:1.20.3),
# so ITMS is essential here; IDMS alone won't help since it only handles digests.
# No change to the YAML is needed.
oc apply -n bookinfo -f \
  https://raw.githubusercontent.com/istio/istio/release-1.20/samples/bookinfo/platform/kube/bookinfo.yaml

# Expose the productpage service
oc expose svc/productpage -n bookinfo

# Wait for all pods to be ready. NOTE: the upstream YAML names deployments
# with a -v1 suffix (productpage-v1, details-v1, ratings-v1) — only the
# reviews app has explicit v1/v2/v3 deployments without the trailing -v1.
for d in productpage-v1 details-v1 ratings-v1 reviews-v1 reviews-v2 reviews-v3; do
  oc rollout status deploy/$d -n bookinfo --timeout=5m
done
```

### 4.3 Record Baseline Connectivity

Record the route and confirm end-to-end connectivity. Save the output — you will compare against this after migration.

```bash
source /root/tools-upi-migrate/lab-config.sh

# Get the route
BOOKINFO_URL="http://$(oc get route productpage -n bookinfo -o jsonpath='{.spec.host}')/productpage"
echo "Bookinfo URL: ${BOOKINFO_URL}"

# Confirm the page loads (HTTP 200)
curl -s -o /dev/null -w "%{http_code}" ${BOOKINFO_URL}
# Expected: 200

# Record pod IPs — these will be in the OVN-Kubernetes CIDR (10.128.x.x)
# After migration they will be in the Cilium CIDR (10.253.x.x)
echo "=== Baseline pod IPs (OVN-Kubernetes CIDR) ==="
oc get pods -n bookinfo -o wide

# Save the baseline
oc get pods -n bookinfo -o wide > /root/baseline-pod-ips.txt
echo "Baseline saved to /root/baseline-pod-ips.txt"

# Test internal pod-to-pod connectivity. The productpage image does NOT ship
# curl, so we use the Python interpreter it does include.
PRODUCTPAGE_POD=$(oc get pod -n bookinfo -l app=productpage -o jsonpath='{.items[0].metadata.name}')
oc exec -n bookinfo ${PRODUCTPAGE_POD} -- python -c "
import urllib.request, sys
r = urllib.request.urlopen('http://details:9080/details/0', timeout=5)
print('HTTP', r.status)
print(r.read(200).decode())
"
# Expected: HTTP 200 + JSON with book details (William Shakespeare, year 1595, ...)
```

---

## 5. Pre-Migration Checks

These checks are a hard gate. Do not proceed if any check fails.

### 5.1 Cluster Health Gate

```bash
source /root/tools-upi-migrate/lab-config.sh

# All operators must be: AVAILABLE=True, PROGRESSING=False, DEGRADED=False
oc get clusteroperators

# All nodes must be: STATUS=Ready
oc get nodes

# No pods in CrashLoopBackOff or Error state
oc get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded 2>/dev/null | \
  grep -v "Completed\|^NAME"
```

**Gate:** Zero degraded operators. Zero nodes not Ready. No actively crash-looping pods.

> **Expected exceptions in error state:** `installer-N-master-X` pods in `openshift-kube-apiserver` / `openshift-kube-controller-manager` / `openshift-kube-scheduler` namespaces frequently show `Status: Error` long after install — they're one-shot installer-revision pods that have been superseded by newer revisions. As long as the corresponding ClusterOperator is `AVAILABLE=True, PROGRESSING=False, DEGRADED=False`, these are artifacts and safe to ignore. Same for `insights` operator showing `Degraded=True` due to inability to phone home to `console.redhat.com` in a proxy-only / air-gapped lab — this does not affect cluster functionality and does not block migration.

### 5.2 Record Network Configuration

```bash
source /root/tools-upi-migrate/lab-config.sh

echo "=== Current cluster network configuration ==="
oc get network.config.openshift.io cluster -o yaml

# Extract and save the key values you will need for CiliumConfig
echo ""
echo "=== Values to note for CiliumConfig ==="
echo "clusterNetwork CIDR:"
oc get network.config.openshift.io cluster \
  -o jsonpath='{.spec.clusterNetwork[0].cidr}'
echo ""
echo "clusterNetwork hostPrefix:"
oc get network.config.openshift.io cluster \
  -o jsonpath='{.spec.clusterNetwork[0].hostPrefix}'
echo ""
echo "serviceNetwork:"
oc get network.config.openshift.io cluster \
  -o jsonpath='{.spec.serviceNetwork[0]}'
echo ""
echo "networkType (should be OVNKubernetes):"
oc get network.config.openshift.io cluster \
  -o jsonpath='{.spec.networkType}'
echo ""
```

### 5.3 Kernel Variant Check

```bash
# List all nodes with their kernel versions
oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.nodeInfo.kernelVersion}{"\n"}{end}'
```

**Gate:** No node kernel version contains `rt`. If any does, that node must be switched to the standard RHCOS kernel via a MachineConfig **before continuing**. Contact Isovalent support for the specific MachineConfig to use.

### 5.4 Backup NetworkPolicies

```bash
# Back up all existing NetworkPolicy resources
oc get networkpolicy -A -o yaml > /root/networkpolicies-backup.yaml
echo "NetworkPolicies backed up: $(oc get networkpolicy -A --no-headers | wc -l) policies"
```

---

## 6. Prepare Isovalent Enterprise Manifests

This section downloads and customizes the CLife manifests before touching any cluster configuration. Complete all steps here before beginning Phase 1 of the migration.

### 6.1 Download and Verify CLife Tarball

The CLife tarball is published by Isovalent at `https://docs.isovalent.com/v<DOCS_VERSION>/public/clife/<TARBALL>`. The current docs version is `v25.11` (this may change with future Isovalent doc rollups — check the latest *Install Networking for Kubernetes on Red Hat OpenShift* page if `404`).

> **Canonical source page:** the current direct link to the tarball is published on the Cisco/Isovalent docs site at
> [https://docs.cisco.com/iep/latest/ink/install/openshift.html](https://docs.cisco.com/iep/latest/ink/install/openshift.html).
> If the `docs.isovalent.com/v25.11/...` URL ever stops returning `200`, go to this page to find the new path/version.

**URL + filename conventions (observed):**

| IEP minor | Docs path (`CLIFE_DOCS_PATH`) | Filename | `CEE_SUFFIX` |
|---|---|---|---|
| 1.18.x | `v25.11` | `clife-v<X.Y.Z>.tar.gz` | _empty_ |
| 1.17.x | `v1.17`  | `clife-v<X.Y.Z>.tar.gz` | _empty_ |
| 1.16.x and earlier | per-minor (e.g. `v1.16`) | `clife-v<X.Y.Z>-cee.N.tar.gz` | `cee.N` |

`lab-config.sh` builds the URL automatically from `CILIUM_EE_VERSION`, `CLIFE_DOCS_PATH`, and `CEE_SUFFIX`.

```bash
source /root/tools-upi-migrate/lab-config.sh
echo "URL:     ${CLIFE_URL}"          # e.g. .../v1.17/public/clife/clife-v1.17.15.tar.gz
echo "Tarball: ${CLIFE_TARBALL}"

curl -fL -o /root/${CLIFE_TARBALL} "${CLIFE_URL}"
ls -lh /root/${CLIFE_TARBALL}

# No public .sha256 is published alongside this tarball — record the local
# hash so a future re-download can be compared:
sha256sum /root/${CLIFE_TARBALL} | tee /root/${CLIFE_TARBALL}.sha256

# Extract
mkdir -p ${CLIFE_DIR}
tar -xzvf /root/${CLIFE_TARBALL} -C ${CLIFE_DIR}

echo "Contents:"
ls ${CLIFE_DIR}/
```

> **Air-gapped bastion:** download on a connected host and `scp` the tarball to `/root/` on the bastion. The tarball contains only OLM manifests (Namespace, OperatorGroup, Subscription, CiliumConfig, Deployment) — the actual Cilium container images are pulled separately and must be mirrored into Nexus/Artifactory ahead of time.

### 6.2 Configure CiliumConfig

The CiliumConfig for migration uses kube-proxy Replacement (KPR) enabled — Cilium fully replaces OVN-Kubernetes' kube-proxy functionality. Key differences from the upstream `ciliumconfig.yaml` shipped in the CLife tarball:

| Field | Upstream default | Migration value | Why |
|---|---|---|---|
| `ipam.operator.clusterPoolIPv4PodCIDRList` | _unset_ | `10.253.0.0/16` | Must not overlap OVN's `10.128.0.0/14` (the single most critical setting) |
| `kubeProxyReplacement` | `false` | `"true"` | Cilium replaces kube-proxy; CNO is patched to `deployKubeProxy: false` in Section 7 |
| `cni.chainingMode` | `portmap` | _removed_ | Chaining is for non-KPR setups; we do full replacement |
| `enterprise.featureGate` | `[CNIChainingMode]` | _removed_ | Goes with the above |
| `k8sServiceHost` / `k8sServicePort` | _unset_ | `api-int.<cluster>.<domain>` / `6443` | Cilium needs to reach the API before its own service layer is up |
| `devices` | _unset_ (auto-detect) | `br-ex,${PRIMARY_NIC}` | Auto-detect skips OVS bridges; while OVN coexists we must list them explicitly. Removed after Section 9.1 |
| `tunnelPort` | `4789` (same) | `4789` | OCP default VXLAN port; firewall rules typically already allow it |
| `clusterHealthPort` | `9940` (same) | `9940` | Avoids conflict with OVN's health port |
| Hubble metrics | minimal | extended | Adds dns/drop/tcp/icmp/flow/httpV2/flow_export for observability during migration |

Run this on the bastion. `PRIMARY_NIC` comes from `lab-config.sh` (`ens192` for this lab). To verify on your own cluster:
```bash
WORKER=$(oc get nodes -l node-role.kubernetes.io/worker= -o jsonpath='{.items[0].metadata.name}')
oc debug node/${WORKER} -q -- chroot /host ip route show default
# default via <gw> dev <NIC>   ← that NIC goes in the `devices` field
```

```bash
source /root/tools-upi-migrate/lab-config.sh

CILIUMCONFIG_FILE=$(find ${CLIFE_DIR} -name "ciliumconfig.yaml" | head -1)
echo "Editing: ${CILIUMCONFIG_FILE}"
cp "${CILIUMCONFIG_FILE}" "${CILIUMCONFIG_FILE}.orig"   # keep upstream for reference

cat > ${CILIUMCONFIG_FILE} <<EOF
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
  # avoid conflicts with OVN-Kubernetes health check port
  clusterHealthPort: 9940
  # match OCP default VXLAN port (OCP uses 4789, Cilium default is 8472)
  tunnelPort: 4789
  # explicit devices while OVS bridges still exist on nodes during migration.
  # Both are removed after migration (Section 9.1) so Cilium can auto-detect.
  devices: "br-ex,${PRIMARY_NIC}"
EOF

echo "CiliumConfig written."
```

### 6.3 Configure the CLife Controller Manager

The CLife controller manager deployment needs the Kubernetes API endpoint configured so it can communicate before the service layer is established.

```bash
source /root/tools-upi-migrate/lab-config.sh

MANAGER_FILE=$(find ${CLIFE_DIR} -name "apps_v1_deployment_clife-controller-manager.yaml" | head -1)
echo "Editing: ${MANAGER_FILE}"

# Inject KUBERNETES_SERVICE_HOST and KUBERNETES_SERVICE_PORT into the manager container
yq -i '
  (.spec.template.spec.containers[] |
    select(has("name")) |
    select(.name == "manager")).env +=
    [
      {"name": "KUBERNETES_SERVICE_HOST", "value": "'"${K8S_API_HOST}"'"},
      {"name": "KUBERNETES_SERVICE_PORT", "value": "'"${K8S_API_PORT}"'"}
    ]
' ${MANAGER_FILE}

# Verify
echo "=== env section in manager deployment ==="
yq '.spec.template.spec.containers[] | select(.name == "manager") | .env' ${MANAGER_FILE}
```

### 6.4 Configure the OLM Subscription

The OLM Subscription also needs the API endpoint so it can communicate with the API server before Cilium has established the service layer.

```bash
source /root/tools-upi-migrate/lab-config.sh

SUBSCRIPTION_FILE=$(find ${CLIFE_DIR} -name "subscription.yaml" | head -1)
echo "Editing: ${SUBSCRIPTION_FILE}"

yq -i '
  .spec.config.env +=
    [
      {"name": "KUBERNETES_SERVICE_HOST", "value": "'"${K8S_API_HOST}"'"},
      {"name": "KUBERNETES_SERVICE_PORT", "value": "'"${K8S_API_PORT}"'"}
    ]
' ${SUBSCRIPTION_FILE}

# Verify
echo "=== config.env in subscription ==="
yq '.spec.config.env' ${SUBSCRIPTION_FILE}
```

---

## 7. Migration Procedure

> **This is the maintenance window.** From Phase 1 through Phase 6, the cluster network is in a transitional state. Application pods will experience disruption during node reboots in Phase 6. Expect downtime proportional to cluster size.

> **Automation:** [`do-migration.sh`](#14-scripts-overview) runs Phase 1-5 end-to-end and pauses before Phase 6 for explicit confirmation. The step-by-step commands below remain useful for understanding what the script does, for debugging, and for partial re-runs. Pass `-y` to skip the Phase 6 confirmation when re-running in a known-good lab.

> **Expected degraded state between Phase 5 and end of Phase 6:** `oc get co` will show several operators Degraded=True during the window where Cilium is deployed but nodes have not yet rebooted to actually use it. Typical:
> - `etcd` — "1 of 3 members are available, master-m-X is unhealthy" (etcd pods still on OVN cannot reach each other through the mixed-CNI overlay)
> - `authentication`, `console`, `ingress` — `context deadline exceeded` reaching the route URL (router pods still on OVN)
> - `machine-config` — "MachineConfigPool master is paused" (expected, we paused it in Phase 2)
> - `insights` — DNS lookup for `console.redhat.com` (corporate-proxy quirk, unrelated)
>
> These all clear once the corresponding nodes reboot in Phase 6 and come back on Cilium. Do **not** treat them as a reason to roll back.

### Phase 1 — Disable the Cluster Network Operator

The Cluster Network Operator (CNO) manages OVN-Kubernetes. It must be stopped first to prevent it from reverting the network configuration changes we are about to make.

**Step 1.1 — Mark the network operator as unmanaged in the CVO:**

```bash
source /root/tools-upi-migrate/lab-config.sh

cat > /tmp/cno-disable.yaml <<EOF
- op: add
  path: /spec/overrides
  value:
  - kind: Deployment
    group: apps
    name: network-operator
    namespace: openshift-network-operator
    unmanaged: true
EOF

oc patch clusterversion version --type json --patch-file /tmp/cno-disable.yaml
```

**Step 1.2 — Scale the network operator to zero:**

```bash
oc scale deployment -n openshift-network-operator network-operator --replicas=0

# Confirm no network-operator pods are running before proceeding
oc get pods -n openshift-network-operator
```

> **Expected leftover pods:** `iptables-alerter-*` (one per node, ~6 pods) is a separate DaemonSet that lives in this namespace; it's harmless and remains running. Only the `network-operator` Deployment pod itself must be gone before continuing.

**Step 1.3 — Delete the applied-cluster ConfigMap:**

This removes the initial deployment state file. Without this, the network operator will try to reconcile back to OVN-Kubernetes when re-enabled.

```bash
oc delete configmap applied-cluster -n openshift-network-operator
```

### Phase 2 — Pause the Machine Config Operator

Without this pause, the Machine Config Operator will detect changes to network objects and begin rebooting nodes immediately — before Cilium is deployed. This must be prevented.

```bash
source /root/tools-upi-migrate/lab-config.sh

oc patch --type=merge --patch='{"spec":{"paused":true}}' mcp/master
oc patch --type=merge --patch='{"spec":{"paused":true}}' mcp/worker

# Confirm both are paused
oc get mcp
# Expected: UPDATED=False, DEGRADED=False for both pools (pause takes effect)
```

### Phase 3 — Switch the Network Plugin

**Step 3.1 — Patch `network.config` with the new Cilium CIDR and network type:**

```bash
source /root/tools-upi-migrate/lab-config.sh

oc patch network.config cluster \
  --type=merge \
  --patch="{
    \"spec\": {
      \"clusterNetwork\": [{\"cidr\": \"${CILIUM_CLUSTER_CIDR}\", \"hostPrefix\": ${CILIUM_HOST_PREFIX}}],
      \"networkType\": \"Cilium\"
    },
    \"status\": null
  }"
```

**Step 3.2 — Patch `network.operator` with Cilium as the default network and disable kube-proxy:**

```bash
source /root/tools-upi-migrate/lab-config.sh

oc patch network.operator cluster \
  --type=merge \
  --patch="{
    \"spec\": {
      \"clusterNetwork\": [{\"cidr\": \"${CILIUM_CLUSTER_CIDR}\", \"hostPrefix\": ${CILIUM_HOST_PREFIX}}],
      \"defaultNetwork\": {\"type\": \"Cilium\"},
      \"deployKubeProxy\": false
    },
    \"status\": null
  }"
```

**Verify the patches:**

```bash
echo "=== network.config ==="
oc get network.config cluster -o jsonpath='{.spec}' | python3 -m json.tool

echo "=== network.operator ==="
oc get network.operator cluster -o jsonpath='{.spec}' | python3 -m json.tool
```

### Phase 4 — Deploy Isovalent Networking for Kubernetes

**Step 4.1 — Apply the CLife manifests:**

The `until` loop handles transient API server failures that can occur while the cluster network is in transition.

```bash
source /root/tools-upi-migrate/lab-config.sh

until oc apply -f ${CLIFE_DIR}/
do
  echo "Retrying apply..."
  sleep 1
done
```

**Step 4.2 — Reconfigure Multus to use Cilium:**

Multus is the meta-CNI on OpenShift. The `multus-daemon-config` ConfigMap currently has its `readinessindicatorfile` pointing at the OVN-Kubernetes CNI config file. The sed substitution swaps that path to the Cilium conflist.

```bash
KUBE_EDITOR="sed -i s;host/run/multus/cni/net.d/10-ovn-kubernetes.conf;host/run/multus/cni/net.d/05-cilium.conflist;" \
  oc edit cm -n openshift-multus multus-daemon-config

# Verify the change took effect
oc get cm -n openshift-multus multus-daemon-config -o jsonpath='{.data.daemon-config\.json}' | \
  python3 -c "import json,sys; print('readinessindicatorfile:', json.load(sys.stdin)['readinessindicatorfile'])"
# Expected: readinessindicatorfile: /host/run/multus/cni/net.d/05-cilium.conflist

oc rollout restart -n openshift-multus ds/multus
oc rollout status -n openshift-multus ds/multus --timeout=5m
```

**Step 4.3 — Wait for Cilium to deploy:**

```bash
source /root/tools-upi-migrate/lab-config.sh

# Watch Cilium DaemonSet appear and pods start
oc get ds -n cilium cilium -w &
DS_WATCH=$!

# Wait for pods to be created (will not yet be Running on all nodes — nodes need rebooting)
oc get pods -n cilium -l k8s-app=cilium

# Stop the watch
kill ${DS_WATCH} 2>/dev/null

# Confirm CLife controller manager is running
oc get pods -n cilium -l app.kubernetes.io/name=clife
```

> At this point Cilium pods may not be fully running on all nodes — that is expected. Nodes are still running OVN-Kubernetes. The actual CNI switch happens during the node reboots in Phase 6.

### Phase 5 — Re-enable OpenShift Operator Management

**Step 5.1 — Restart the API server pods:**

```bash
oc delete pod -n openshift-kube-apiserver -l apiserver=true

# Wait for API server to come back — oc may briefly be unreachable
until oc get nodes &>/dev/null; do
  echo "Waiting for API server..."
  sleep 5
done
echo "API server ready."
```

**Step 5.2 — Restart the Machine Config Operator:**

```bash
oc -n openshift-machine-config-operator rollout restart deploy/machine-config-controller
oc -n openshift-machine-config-operator rollout restart deploy/machine-config-operator

oc rollout status -n openshift-machine-config-operator deploy/machine-config-controller
oc rollout status -n openshift-machine-config-operator deploy/machine-config-operator
```

**Step 5.3 — Scale the Cluster Network Operator back up:**

```bash
oc scale deployment -n openshift-network-operator network-operator --replicas=1

# Wait for the network operator to start
oc rollout status -n openshift-network-operator deploy/network-operator
```

**Step 5.4 — Restore CVO management of the network operator:**

```bash
oc patch clusterversions version --type=merge --patch '{"spec":{"overrides":null}}'
```

### Phase 6 — Reboot Nodes via MCP

Unpausing the Machine Config Operator pools triggers a controlled, sequential node reboot. The MCO cordons and drains each node before rebooting it, respecting PodDisruptionBudgets. During this phase:

- Nodes will reboot one at a time within each pool
- OVN-Kubernetes is replaced by Cilium as the active CNI on each node as it reboots
- Application pods are evicted and rescheduled as nodes drain

```bash
source /root/tools-upi-migrate/lab-config.sh

# Unpause workers first — workload nodes
oc patch --type=merge --patch='{"spec":{"paused":false}}' mcp/worker

# Monitor worker node reboots
echo "Watching worker MCP — waiting for UPDATED=True..."
oc get mcp worker -w &

# In a separate terminal or after workers complete, unpause masters
# Workers typically complete first; masters can be started in parallel for speed
oc patch --type=merge --patch='{"spec":{"paused":false}}' mcp/master
```

**Monitor progress:**

```bash
# Overall MCP status — wait for UPDATED=True, UPDATING=False, DEGRADED=False
oc get mcp

# Per-node reboot progress
oc get nodes -w

# MCO controller logs — check for eviction issues
oc logs -n openshift-machine-config-operator \
  -l k8s-app=machine-config-controller -f --tail=50
```

> **If pods cannot be evicted:** The MCO logs will show which pods are blocking drain. Common causes: missing PodDisruptionBudgets, tolerations preventing eviction. Handle each on a case-by-case basis — do not force-delete pods without understanding the impact.

**Wait for all nodes to complete:**

```bash
# All nodes Ready
oc get nodes

# Both MCPs updated
oc get mcp
# Expected: UPDATED=True, UPDATING=False, DEGRADED=False for both master and worker
```

---

## 8. Post-Migration Verification

### 8.1 Cluster Operator Health

```bash
oc get clusteroperators
```

All operators must be `AVAILABLE=True`, `PROGRESSING=False`, `DEGRADED=False`.

### 8.2 Cilium Health

```bash
source /root/tools-upi-migrate/lab-config.sh

# All Cilium pods Running
oc get pods -n cilium

# Cilium DaemonSet — all nodes covered
oc get ds -n cilium cilium

# Full Cilium status (exec into a Cilium pod — do not use a local cilium binary for this)
oc exec -n cilium ds/cilium -- cilium status
# Expected:
#    Cilium:             OK
#    Operator:           OK
#    Envoy DaemonSet:    OK
#    Hubble Relay:       OK (if enabled)
```

**Verify pod IPs have migrated to the Cilium CIDR:**

```bash
source /root/tools-upi-migrate/lab-config.sh

echo "=== Current pod IPs (should be in ${CILIUM_CLUSTER_CIDR}) ==="
oc get pods -A -o wide | grep -v "^NAME\|^openshift-" | head -20

echo "=== Bookinfo pod IPs ==="
oc get pods -n bookinfo -o wide

echo "=== Baseline (OVN-Kubernetes IPs, was in ${OVN_CLUSTER_CIDR}) ==="
cat /root/baseline-pod-ips.txt
```

All pod IPs should now be in the Cilium CIDR (`10.253.x.x`). None should remain in the old OVN-Kubernetes CIDR (`10.128.x.x`).

### 8.3 Approve the OLM InstallPlan

The CLife OLM Subscription is created with `installPlanApproval: Manual`. Without approving the InstallPlan, the OLM-managed version of Cilium will not be activated. This is normal expected behavior.

> **Common pitfall: stale bundle-unpack job from mid-migration.** If `oc get installplan -n cilium` shows "No resources found" and `oc get subscription -n cilium clife -o yaml` shows `BundleUnpackFailed: BackoffLimitExceeded`, OLM's first unpack attempt happened **during Phase 4** (network in flux) and was retried until it hit the backoff limit. The condition is sticky — OLM won't retry on its own. Fix:
>
> ```bash
> # Find the failed unpack job (its name is a SHA hash)
> oc get jobs -n openshift-marketplace
> # Delete it
> oc delete job -n openshift-marketplace <hash>
> # Recreate the subscription so OLM generates a new unpack job
> oc delete subscription -n cilium clife
> oc apply -f ${CLIFE_DIR}/subscription.yaml
> # Within ~30s an InstallPlan should appear:
> oc get installplan -n cilium
> ```

```bash
source /root/tools-upi-migrate/lab-config.sh

# Find the InstallPlan
oc get installplan -n cilium
# Expected: install-xxxxx  clife.vX.Y.Z-cee.N  Manual  false

# Approve it
INSTALL_PLAN=$(oc get installplan -n cilium -o jsonpath='{.items[0].metadata.name}')
oc patch installplan ${INSTALL_PLAN} -n cilium \
  --type merge --patch '{"spec":{"approved":true}}'

echo "InstallPlan ${INSTALL_PLAN} approved."

# Watch the CSV come up
oc get csv -n cilium -w
# Expected: clife.vX.Y.Z-cee.N  Succeeded
```

### 8.4 Application Connectivity

Verify the Bookinfo application is fully functional.

```bash
source /root/tools-upi-migrate/lab-config.sh

# Route URL
BOOKINFO_URL="http://$(oc get route productpage -n bookinfo -o jsonpath='{.spec.host}')/productpage"

# HTTP response code
curl -s -o /dev/null -w "%{http_code}" ${BOOKINFO_URL}
# Expected: 200

# Full page content (look for "Book Details" section)
curl -s ${BOOKINFO_URL} | grep -i "book details\|stars\|author" | head -5

# Internal pod-to-pod connectivity
PRODUCTPAGE_POD=$(oc get pod -n bookinfo -l app=productpage -o jsonpath='{.items[0].metadata.name}')

echo "=== productpage → details ==="
oc exec -n bookinfo ${PRODUCTPAGE_POD} -- \
  curl -s http://details:9080/details/0 | python3 -m json.tool

echo "=== productpage → reviews ==="
oc exec -n bookinfo ${PRODUCTPAGE_POD} -- \
  curl -s -o /dev/null -w "%{http_code}" http://reviews:9080/reviews/0
# Expected: 200

echo "=== reviews → ratings ==="
REVIEWS_POD=$(oc get pod -n bookinfo -l app=reviews -o jsonpath='{.items[0].metadata.name}')
oc exec -n bookinfo ${REVIEWS_POD} -- \
  curl -s -o /dev/null -w "%{http_code}" http://ratings:9080/ratings/0
# Expected: 200
```

### 8.5 Cilium Connectivity Test

The connectivity test validates Cilium's data plane end-to-end. It requires a custom SCC on OpenShift.

**Create the SCC:**

```bash
oc apply -f - <<'EOF'
apiVersion: security.openshift.io/v1
kind: SecurityContextConstraints
metadata:
  name: cilium-test
allowHostPorts: true
allowHostNetwork: true
users:
  - system:serviceaccount:cilium-test:default
  - system:serviceaccount:cilium-test:client
  - system:serviceaccount:cilium-test:client2
  - system:serviceaccount:cilium-test:client3
  - system:serviceaccount:cilium-test:echo-other-node
  - system:serviceaccount:cilium-test:echo-same-node
  - system:serviceaccount:cilium-test:echo-external-node
  - system:serviceaccount:cilium-test-1:default
  - system:serviceaccount:cilium-test-1:client
  - system:serviceaccount:cilium-test-1:client2
  - system:serviceaccount:cilium-test-1:client3
  - system:serviceaccount:cilium-test-1:echo-other-node
  - system:serviceaccount:cilium-test-1:echo-same-node
  - system:serviceaccount:cilium-test-1:echo-external-node
  - system:serviceaccount:cilium-test-ccnp1:client-ccnp
  - system:serviceaccount:cilium-test-ccnp2:client-ccnp
priority: null
readOnlyRootFilesystem: false
runAsUser:
  type: RunAsAny
seLinuxContext:
  type: MustRunAs
volumes: null
allowHostDirVolumePlugin: false
allowHostIPC: false
allowHostPID: false
allowPrivilegeEscalation: false
allowPrivilegedContainer: false
allowedCapabilities:
  - NET_RAW
  - NET_ADMIN
defaultAddCapabilities: null
requiredDropCapabilities: null
groups: null
EOF
```

**Run the tests:**

```bash
cilium connectivity test -n cilium \
  --flow-validation=disabled \
  --hubble=false \
  --test='!check-log-errors'
```

**Clean up test resources:**

```bash
oc delete ns cilium-test-1
oc delete scc cilium-test
```

---

## 9. Post-Migration Cleanup

### 9.1 Remove the devices Setting

The `devices: "br-ex,${PRIMARY_NIC}"` setting in CiliumConfig was required during migration while OVS bridges were still present. Now that all nodes have rebooted with Cilium as the CNI, Cilium can auto-detect non-OVS network devices and this setting should be removed.

```bash
source /root/tools-upi-migrate/lab-config.sh

# Locate the CiliumConfig file
CILIUMCONFIG_FILE=$(find ${CLIFE_DIR} -name "ciliumconfig.yaml" | head -1)

# Strip the devices line
sed -i '/^  devices:/d' ${CILIUMCONFIG_FILE}

# Verify it's gone
grep -E "devices|br-ex" ${CILIUMCONFIG_FILE} || echo "devices field removed"

# Apply the updated config
oc apply -f ${CILIUMCONFIG_FILE}

# Restart Cilium DaemonSet to pick up the change
oc -n cilium rollout restart ds/cilium
oc -n cilium rollout status ds/cilium --timeout=5m
# Expected: daemon set "cilium" successfully rolled out

# Verify Cilium is healthy after restart (KPR True, auto-detected NIC)
oc exec -n cilium ds/cilium -- cilium status | grep -E "Cilium:|KubeProxyReplacement:"
```

### 9.2 Remove OVN-Kubernetes Namespace

```bash
oc delete namespace openshift-ovn-kubernetes
```

Verify deletion completes:

```bash
oc get ns openshift-ovn-kubernetes 2>/dev/null && echo "Still present" || echo "Deleted"
```

### 9.3 Restore NetworkPolicies

```bash
# Review backed-up policies
cat /root/networkpolicies-backup.yaml

# Re-apply if any were removed during migration
# oc apply -f /root/networkpolicies-backup.yaml

# Verify policies are enforced by Cilium
oc get networkpolicy -A

# For workloads requiring L7 policy, consider migrating to CiliumNetworkPolicy
# which provides HTTP method/path-level enforcement:
# oc explain ciliumnetworkpolicy
```

---

## 10. Risk Register

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Overlapping CIDR causes routing conflict | High if not checked | Connectivity loss | Use a completely non-overlapping Cilium CIDR (e.g. `10.253.0.0/16`). Verify with `oc get network.config cluster` before patching. |
| Pod eviction blocked during MCP reboot | Medium | Node drain stalls; migration pauses | Monitor MCO logs. Handle PDB violations individually. Never force-delete without understanding impact. |
| RT kernel on a node prevents Cilium | Low | Cilium pod CrashLoopBackOff on that node | Check all nodes in Section 5.3. Switch to standard kernel before starting. |
| `devices` field incorrect (wrong NIC name) | Medium | Cilium cannot detect network devices post-reboot | Verify NIC name on a live node before setting. Can be corrected via CiliumConfig after migration. |
| MCP pause forgotten — premature node reboot | Low | Nodes reboot before Cilium deployed | Always follow Phase 2 before Phase 3. Check `oc get mcp` shows paused before patching network objects. |
| Multus not updated — traffic still routed via OVN | Medium | Pods appear Running but no connectivity | Confirm `oc edit cm -n openshift-multus multus-daemon-config` shows `05-cilium.conflist` and Multus DaemonSet is restarted. |
| OLM InstallPlan not approved — Cilium stalls | High if unknown | CLife appears deployed but Cilium operator not running | Always check `oc get installplan -n cilium` and approve as in Section 8.3. |
| Red Hat support unavailable for issues | Certain | Must rely on Isovalent support | Engage Isovalent support before starting. Have support contact ready during the maintenance window. |

---

## Next steps

After the cluster is migrated and healthy:

- **[Hubble Timescape deployment](OCP_IEP_Timescape_Guide.md)** — add persistent flow observability on top of the migrated cluster. Standalone ClickHouse-backed Timescape with NFS-on-bastion storage, Stream API from Cilium, CLI + UI access. ~30 min end-to-end.

---

*Based on official Isovalent documentation: "Install Networking for Kubernetes on Red Hat OpenShift" and "Migrate from OpenShift OVN-Kubernetes to Networking for Kubernetes" (CLife 1.18.x)*

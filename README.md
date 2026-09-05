# homelab-platform

A project-independent local home lab platform layer: single-node k3s, a local
Docker registry, dnsmasq-based local DNS, Terraform-managed namespaces, and a
generic backup routine.

This repository contains **platform only**. It intentionally has no
application-specific deployment code — projects such as `homestreamlab` and `homeops` are
deployed onto this platform from their own separate repositories.

## Status

**Bootstrapping.** Single-node k3s, the local Docker registry, k3s registry trust,
and dnsmasq wildcard DNS are implemented and verified on a real host. The standalone
`dnsmasq/lan-ufw-install.sh` / `-rollback.sh` lifecycle that opens LAN-scoped DNS
through `ufw` has now been **runtime-verified on the host** (clean install →
ownership/state checks → same-state no-op → rollback restoring the exact UFW
baseline → reinstall; final host state **INSTALLED**), with dnsmasq wildcard /
upstream / normal-resolver regression checks passing. Still **not verified**:
resolution from a **second physical LAN device** (none was available) and browser
access to `http://homestreamlab.homelab.home.arpa` from another device; the
failure-injection / recovery paths remain repository-local-tested only. See
[`docs/dnsmasq-runbook.md`](./docs/dnsmasq-runbook.md#verification-status).

The Platform Terraform Workspace — HCP Terraform remote state in **Local**
execution mode, with the `kubernetes` and `helm` providers configured against
this host's k3s cluster — is **implemented and verified**: the HCP workspace
exists in Local execution mode, and `terraform init` initializes successfully
against it. The reusable Namespace Pattern — a child module producing a
`Namespace` and matching `ResourceQuota` for any Project — is implemented
under
[`terraform/modules/namespace-resourcequota/`](./terraform/modules/namespace-resourcequota/)
and repo-locally verified (`validate.sh` + `plan-check.sh`; see
[`docs/terraform-runbook.md#namespace-pattern-module`](./docs/terraform-runbook.md#namespace-pattern-module)).
This root module instantiates that pattern for HomeStreamLab: a
`homestreamlab` Namespace and ResourceQuota, created by a real `terraform
apply` against this host's cluster and verified live — see
[`docs/terraform-runbook.md`](./docs/terraform-runbook.md#homestreamlab-namespace-instantiation-issue-8).
It also manages HomeStreamLab's **deployment identity** (issue #31): a
`homestreamlab-deployer` ServiceAccount plus a least-privilege Role/RoleBinding
(`get,create,patch,delete` on `secrets`, `persistentvolumeclaims`, `services`,
`deployments`, `ingressroutes`) and a ClusterRole with two cluster-scoped reads
(`get Namespace/homestreamlab`, `list customresourcedefinitions`), so a
future `local-jenkins-platform` job can deploy HomeStreamLab without the host
administrator kubeconfig — see
[`docs/homestreamlab-deployer-runbook.md`](./docs/homestreamlab-deployer-runbook.md).
This repository manages the Namespace, ResourceQuota and that deployment
identity/RBAC — no HomeStreamLab application resource exists here or is deployed
by this repo, and no ServiceAccount token or kubeconfig is Terraform-managed or
committed.

Issue #38 adds the HomeOps platform configuration: `module.homeops` with its
explicit quota, a separate read-only `homeops-observer` runtime identity, and a
`homeops-deployer` Jenkins identity limited to HomeOps Services, Deployments,
IngressRoutes, and the two provider-required cluster reads. A reviewed saved
plan (`10 to add, 0 to change, 0 to destroy`) was applied against the existing
HCP Terraform `homelab-platform` workspace (`10 added, 0 changed, 0 destroyed`),
and the post-apply plan reported no changes. The Namespace, quota, both
ServiceAccounts, and the complete observer/deployer allow and deny RBAC matrices
were verified live. See
[`docs/homeops-platform-runbook.md`](./docs/homeops-platform-runbook.md).

The generic local backup and restore mechanism — timestamped `tar.gz`
archives with SHA-256 sidecars, application-independent, script-only — is
**implemented and verified with smoke/dummy data only**: 177 passing test
cases across four suites, entirely under `mktemp` scratch directories, plus
one continuous end-to-end scenario matching the issue's acceptance steps. No
real project data, no real PostgreSQL, and no HomeStreamLab integration have
exercised it yet — see
[`docs/backup-runbook.md`](./docs/backup-runbook.md#verification-status) for
the exact evidence and boundaries.

Every other platform component is still planned.

See [`CLAUDE.md`](./CLAUDE.md) for the current milestone, scope, and planned
platform pieces.

## k3s

Install (both variables are required and have no defaults):

```sh
sudo K3S_VERSION=vX.Y.Z+k3sN HOST_LAN_IP=<your-lan-ip> bash k3s/install.sh
```

Operate the service:

```sh
systemctl status k3s      # current state
systemctl start k3s       # start
systemctl stop k3s        # stop
journalctl -u k3s         # logs
```

Verify the cluster:

```sh
sudo k3s kubectl get nodes
```

Re-running the install script is safe: it inspects the existing installation
and either no-ops or refuses, never silently reinstalling or restarting.

Uninstalling is a **separate, destructive** procedure — it is not part of the
install script. See [`docs/k3s-runbook.md`](./docs/k3s-runbook.md) for that,
plus LAN access, kubeconfig backups, and troubleshooting.

### Local registry trust

For the cluster to pull from the local registry, k3s needs
`/etc/rancher/k3s/registries.yaml` to trust that plain-HTTP endpoint. This is
**separate from** the Docker daemon trust below: containerd, the runtime k3s
runs Pods with, never reads `/etc/docker/daemon.json`.

Creating the file and restarting k3s is a **manual, fail-closed host
transaction**, documented in
[`docs/k3s-runbook.md`](./docs/k3s-runbook.md#local-registry-trust). This
repository deliberately ships no script for it — restarting k3s stops the
control plane and every workload on this single-node cluster.

Verify it with two runs of the pull test, one on each side of a restart:

```sh
HOST_LAN_IP=<your-lan-ip> KUBECONFIG=/path/to/k3s.yaml \
  bash k3s/registry-pull-test.sh
```

Each run builds a throwaway image with a unique marker, pushes it, runs it as a
Pod, and checks the Pod resolved to exactly that image — so a cached image
cannot produce a false pass. The script refuses an ambient kubectl context and
requires the target to be **this host's** single-node k3s node — the node's
InternalIP must equal this host's default-route source address, so a foreign
cluster advertising a shared bridge address cannot pass. See
[Verifying the registry trust](./docs/k3s-runbook.md#verifying-the-registry-trust)
for the full flow, the persistence checks and the rollback procedures.

**Status: verified on a real host** — setup transaction, setup restart, Run A,
a separate verification restart, the post-restart persistence checks, and Run B
with a fresh image identity. The **rollback and failure-injection paths were
not runtime-exercised**; they are documented and statically checked only. See
[Verification status](./docs/k3s-runbook.md#verification-status) for the exact
limits of that evidence.

## Registry

A local, unauthenticated Docker registry for images built on this host. Set
`HOST_LAN_IP` in `.env` first (copy [`.env.example`](./.env.example)), then run
from the repository root:

```sh
docker compose -f registry/docker-compose.yml --env-file .env up -d
docker compose -f registry/docker-compose.yml --env-file .env stop
```

Verify the full push/pull/delete cycle:

```sh
HOST_LAN_IP=<your-lan-ip> bash registry/smoke-test.sh
```

Pushing from this host also needs a one-time Docker daemon change, because the
registry serves plain HTTP. That, along with operations, backups, the
destructive reset, and rollback, is in
[`docs/registry-runbook.md`](./docs/registry-runbook.md).

This has been exercised end to end on a real host: Compose startup, the
LAN-only port binding, `/v2/` readiness, the `unless-stopped` restart policy,
push, pull by immutable digest, manifest deletion, and the final `404`.

**Security scope.** This registry is intended for a **trusted, single-user
local area network only**. It **must not be exposed to the public internet**.
Any production or cloud use would require **authentication and TLS** first;
neither is configured here.

## DNS (dnsmasq)

Wildcard DNS for the home lab: `*.HOMELAB_DOMAIN` resolves to `HOST_LAN_IP` via a
dedicated `/etc/dnsmasq.d/homelab.conf`, never merged into the system's own dnsmasq
configuration. Set `HOST_LAN_IP` and `HOMELAB_DOMAIN` in `.env` first (copy
[`.env.example`](./.env.example)), then run from the repository root:

```sh
sudo HOST_LAN_IP=<your-lan-ip> HOMELAB_DOMAIN=<your-domain> bash dnsmasq/install.sh
```

Operate the service:

```sh
systemctl status dnsmasq
systemctl restart dnsmasq
journalctl -u dnsmasq
```

Verify:

```sh
sudo HOST_LAN_IP=<your-lan-ip> HOMELAB_DOMAIN=<your-domain> bash dnsmasq/smoke-test.sh
```

To point another device on the LAN at this resolver, set its DNS server to
`HOST_LAN_IP`. LAN devices need `ufw` to admit port 53 from the LAN, which is the
**separate**, explicitly-invoked `dnsmasq/lan-ufw-install.sh` (rolled back with
`dnsmasq/lan-ufw-rollback.sh`) — a standalone, `flock`-serialised lifecycle that
opens exactly the derived
`<LAN_SUBNET> -> <HOST_LAN_IP>:53/udp+tcp on <LAN_INTERFACE>` rules, never an
`Anywhere` rule, and never touches the dnsmasq service or `/etc`. On this host it
has been applied and runtime-verified (final state **installed**); resolution from
a genuinely separate LAN device is still unverified. Host-local verification is
unaffected and needs no firewall change. See
[`docs/dnsmasq-runbook.md`](./docs/dnsmasq-runbook.md#lan-dns-firewall-access-separate-lifecycle).

Rolling back fully restores the previous DNS behavior — stops and disables dnsmasq,
then removes only the files this platform proves it owns:

```sh
sudo bash dnsmasq/rollback.sh
```

`.local` domains are deliberately avoided (ADR-0005): RFC 6762 reserves `.local` for
mDNS, which makes it unreliable for this exact use case, so this platform's canonical
domain is `homelab.home.arpa` per RFC 8375 instead.

**Status: verified on a real host** — install, wildcard resolution, public DNS
forwarding, dnsmasq active/enabled state, rollback, normal host DNS after rollback,
and reinstall with a final smoke test all passed. The separate LAN-UFW lifecycle
(`dnsmasq/lan-ufw-install.sh` / `-rollback.sh`) is now **runtime-verified on the
host** (`HOST_LAN_IP=192.168.1.197`, `wlan0`, `192.168.1.0/24`, UFW 0.36.2): clean
install, post-install ownership/state (`root:root` `0700`/`0600`, exactly the two
owned rules), same-state no-op, rollback restoring the exact pre-apply UFW baseline,
reinstall — **final host state INSTALLED**, dnsmasq/wildcard/upstream regressions
green. **Deferred / not verified:** second-physical-LAN-client DNS and
`http://homestreamlab.homelab.home.arpa` browser access from another device.
**Repository-local only:** the interrupted-install / `rolling_back` / snapshot-read /
transactional-failure recovery paths. See
[`docs/dnsmasq-runbook.md`](./docs/dnsmasq-runbook.md#verification-status) for the
full matrix.

## Terraform (platform workspace)

The Platform's own Terraform root module lives in
[`terraform/platform/`](./terraform/platform/): HCP Terraform for remote state,
**Local** execution mode (ADR-0001), and the `kubernetes` and `helm` providers
pointed at this host's k3s cluster.

It instantiates the reusable Namespace Pattern module
([`terraform/modules/namespace-resourcequota/`](./terraform/modules/namespace-resourcequota/))
in `terraform/platform/main.tf`, reserving the `homestreamlab` and `homeops`
Namespaces with matching ResourceQuotas. It declares HomeStreamLab's
deployment identity in `terraform/platform/homestreamlab-deployer.tf` — a
`homestreamlab-deployer` ServiceAccount, a least-privilege namespace-scoped
Role/RoleBinding (`secrets`, `persistentvolumeclaims`, `services`, `deployments`,
`ingressroutes`), and a ClusterRole with two cluster-scoped reads
(`get Namespace/homestreamlab`, `list customresourcedefinitions` — the latter
required by `kubernetes_manifest` v3.2.1)
(see [`docs/homestreamlab-deployer-runbook.md`](./docs/homestreamlab-deployer-runbook.md)).
No HomeStreamLab application resource is declared here — no Deployment, Service,
Ingress/IngressRoute, application Secret, or Helm release belongs in this
repository — and no ServiceAccount token or kubeconfig is Terraform-managed.

HomeOps identities are explicit in `homeops-observer.tf` and
`homeops-deployer.tf`: runtime cluster observation is read-only and separate
from the Jenkins deployment identity. The deployer can manage only Services,
Deployments, and IngressRoutes in `homeops`, plus `get` on only the `homeops`
Namespace and provider-required CRD `list`. No HomeOps application workload,
token Secret, kubeconfig, Jenkins credential, or application-specific DNS
record is managed here. See
[`docs/homeops-platform-runbook.md`](./docs/homeops-platform-runbook.md).

Repo-local checks (never contacts HCP Terraform, never touches the cluster):

```sh
bash terraform/platform/validate.sh
```

Against HCP Terraform, once the workspace exists in **Local** execution mode and
a user-readable kubeconfig copy is configured, initialize the working directory:

```sh
cd terraform/platform
export TF_CLOUD_ORGANIZATION=<your-hcp-organization>
terraform init
```

Do not follow this with an ungated generic plan or apply. Follow the applicable
issue-specific runbook and keep unrelated changes out of the saved plan. Issue
#38's completed gated apply is documented in
[`docs/homeops-platform-runbook.md`](./docs/homeops-platform-runbook.md).

The workspace name is fixed in `versions.tf` (ADR-0002); only the
account-specific organization comes from the environment. The kubeconfig path is
machine-specific and lives in a gitignored `terraform.tfvars` — copy
[`terraform/platform/terraform.tfvars.example`](./terraform/platform/terraform.tfvars.example)
to start.

Workspace creation, Local-mode setup, the kubeconfig copy and its refresh
procedure, verification and rollback are all in
[`docs/terraform-runbook.md`](./docs/terraform-runbook.md).

**Workspace status: implemented and verified.** The `homelab-platform` HCP
workspace exists in Local execution mode; `terraform init`, `terraform
validate` and the historical empty/namespace-only baseline plans succeeded.
The workspace manages real cluster
resources — the `homestreamlab` Namespace and ResourceQuota, created by a real,
reviewed `terraform apply` and verified live with `kubectl` — see the runbook's
[`homestreamlab` namespace instantiation](./docs/terraform-runbook.md#homestreamlab-namespace-instantiation-issue-8)
section for the exact evidence. The HomeStreamLab **deployment identity** (issue
#31 — `homestreamlab-deployer` ServiceAccount + least-privilege RBAC, since
widened for `services` / `deployments` / `ingressroutes` and a cluster-scoped
`list customresourcedefinitions` to match HomeStreamLab's `infra/`) is
implemented and passes repo-local validation; its live `plan`/`apply` and RBAC
verification are pending — see
[`docs/homestreamlab-deployer-runbook.md`](./docs/homestreamlab-deployer-runbook.md#verification-status).
The HomeOps prerequisites and both separate identities (issue #38) are
implemented, applied against the existing HCP workspace, and live-verified in
Kubernetes, including the quota and both allow/deny RBAC matrices. The
post-apply plan reported no changes. HomeOps name resolution on this workstation
uses an operator-managed `/etc/hosts` entry, not wildcard DNS or a
Terraform-managed record; see
[`docs/homeops-platform-runbook.md`](./docs/homeops-platform-runbook.md#verification-status).

## Backup

A generic, application-independent local backup and restore mechanism:
timestamped `tar.gz` archives with SHA-256 sidecars, published only after a
full structural/manifest validation, restored only into an explicitly
separate Recovery Target with a required workload-specific validator.
Script-only — there is no CronJob or other scheduler — and supports either a
filesystem/data-directory payload or an opaque database-style dump produced
by an external command.

```sh
BACKUP_DESTINATION=/absolute/path/to/backup-destination \
BACKUP_ID=example-workload BACKUP_SOURCE_KIND=dir \
BACKUP_SOURCE_DIR=/absolute/path/to/live-data \
  bash backup/backup.sh
```

The backup destination has no built-in default, must already exist, and
must already be mode `0700` — this repository never creates or `chmod`s it
for you. Restore always requires a separate, not-yet-existing Recovery
Target and a workload-specific validator; nothing is ever written directly
over live data. There is no automatic pruning or retention — the operator
owns destination capacity.

Full interface, safety model, permissions, retention, and verified evidence
are in [`docs/backup-runbook.md`](./docs/backup-runbook.md).

**Status: verified with smoke/dummy data only** — four test suites, 177
passing cases, 0 failures, entirely under `mktemp` scratch directories. No
real project data, no real PostgreSQL, and no HomeStreamLab integration —
see
[`docs/backup-runbook.md#verification-status`](./docs/backup-runbook.md#verification-status)
for the exact evidence and boundaries.

## Layout

- `docs/` — platform documentation and runbooks
  - [`docs/showcase.html`](./docs/showcase.html) — self-contained, static
    demo/overview page (Hungarian) for live presentations of the project
  - [`docs/runbook.md`](./docs/runbook.md) — the platform runbook:
    fresh-machine bootstrap order, day-to-day operations, disaster recovery,
    and onboarding a new project
  - [`docs/k3s-runbook.md`](./docs/k3s-runbook.md) — k3s install, operations,
    verification, and the destructive reset procedure
  - [`docs/registry-runbook.md`](./docs/registry-runbook.md) — registry
    operations, Docker daemon trust, reset, and rollback
  - [`docs/dnsmasq-runbook.md`](./docs/dnsmasq-runbook.md) — dnsmasq install,
    operations, verification, and rollback
  - [`docs/terraform-runbook.md`](./docs/terraform-runbook.md) — HCP workspace
    setup, kubeconfig handling, validation, verification, and rollback
  - [`docs/homestreamlab-deployer-runbook.md`](./docs/homestreamlab-deployer-runbook.md) —
    the HomeStreamLab deployment identity: RBAC rationale, verification matrix,
    and the operator credential/kubeconfig handoff for `local-jenkins-platform`
  - [`docs/homeops-platform-runbook.md`](./docs/homeops-platform-runbook.md) —
    HomeOps namespace/quota, separate runtime and deployer identities, RBAC
    verification, and operator credential handoff
  - [`docs/backup-runbook.md`](./docs/backup-runbook.md) — backup/restore
    usage, safety model, permissions, retention, and verified evidence
  - `docs/adr/` — architecture decision records
- `k3s/` — k3s install script and the local-registry pull test
- `dnsmasq/` — wildcard DNS: `install.sh`, `rollback.sh`, `smoke-test.sh`, `lib.sh`,
  and their tests; plus the separate LAN-UFW firewall lifecycle
  (`lan-ufw-lib.sh`, `lan-ufw-install.sh`, `lan-ufw-rollback.sh`, `lan-ufw.test.sh`)
- `registry/` — local Docker registry: `docker-compose.yml` and `smoke-test.sh`
- `terraform/platform/` — the Platform's HCP-backed Terraform root module;
  instantiates the Namespace Pattern module for `homestreamlab` and `homeops`
  (`main.tf`) and declares their platform-owned identities and RBAC
- `terraform/modules/namespace-resourcequota/` — the reusable Namespace
  Pattern child module (`Namespace` + matching `ResourceQuota`), with its own
  repo-local throwaway-plan verification (`plan-check.sh`)
- `backup/` — the generic backup/restore mechanism: `backup.sh`, `restore.sh`,
  shared helpers in `lib.sh`, the Python archive-contract validator
  `tar_metadata_check.py`, and their tests

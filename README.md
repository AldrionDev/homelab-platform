# homelab-platform

A project-independent local home lab platform layer: single-node k3s, a local
Docker registry, dnsmasq-based local DNS, Terraform-managed namespaces, and a
generic backup routine.

This repository contains **platform only**. It intentionally has no
application-specific deployment code — projects such as `homestreamlab` are
deployed onto this platform from their own separate repositories.

## Status

**Bootstrapping.** Single-node k3s, the local Docker registry, k3s registry trust,
and dnsmasq wildcard DNS are implemented and verified on a real host. dnsmasq's
LAN-device resolution from a second physical device is not yet exercised, since it
needs a separate `ufw` change — see
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
This root module now instantiates that pattern once, for HomeStreamLab: a
`homestreamlab` Namespace and ResourceQuota, created by a real `terraform
apply` against this host's cluster and verified live — see
[`docs/terraform-runbook.md`](./docs/terraform-runbook.md#homestreamlab-namespace-instantiation-issue-8).
This repository manages only that Namespace and ResourceQuota — no
HomeStreamLab application resource exists here or is deployed by this repo.

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
`HOST_LAN_IP`. This host's firewall (`ufw`) currently has no rule admitting port 53,
so a separate, explicitly-approved firewall change is needed first for LAN devices
(not for host-local verification, which is unaffected) — see
[`docs/dnsmasq-runbook.md`](./docs/dnsmasq-runbook.md#lan-device-verification-and-ufw).

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
and reinstall with a final smoke test all passed. **Not exercised: LAN-device
resolution** from a second physical device, since it needs a separate, explicitly
approved `ufw` change this component's installer never performs automatically. See
[`docs/dnsmasq-runbook.md`](./docs/dnsmasq-runbook.md#verification-status) for the
exact boundary.

## Terraform (platform workspace)

The Platform's own Terraform root module lives in
[`terraform/platform/`](./terraform/platform/): HCP Terraform for remote state,
**Local** execution mode (ADR-0001), and the `kubernetes` and `helm` providers
pointed at this host's k3s cluster.

It instantiates the reusable Namespace Pattern module
([`terraform/modules/namespace-resourcequota/`](./terraform/modules/namespace-resourcequota/))
once, in `terraform/platform/main.tf`, reserving the `homestreamlab`
Namespace and a matching ResourceQuota. No other Kubernetes resource is
declared here — no Deployment, Service, Ingress/IngressRoute, Secret, or Helm
release belongs in this repository.

Repo-local checks (never contacts HCP Terraform, never touches the cluster):

```sh
bash terraform/platform/validate.sh
```

Against HCP Terraform, once the workspace exists in **Local** execution mode and
a user-readable kubeconfig copy is configured:

```sh
cd terraform/platform
export TF_CLOUD_ORGANIZATION=<your-hcp-organization>
terraform init
terraform plan
# expected: no changes, now that the homestreamlab Namespace/ResourceQuota
# already exist — see docs/terraform-runbook.md for the first plan/apply that
# created them
```

The workspace name is fixed in `versions.tf` (ADR-0002); only the
account-specific organization comes from the environment. The kubeconfig path is
machine-specific and lives in a gitignored `terraform.tfvars` — copy
[`terraform/platform/terraform.tfvars.example`](./terraform/platform/terraform.tfvars.example)
to start.

Workspace creation, Local-mode setup, the kubeconfig copy and its refresh
procedure, verification and rollback are all in
[`docs/terraform-runbook.md`](./docs/terraform-runbook.md).

**Status: implemented and verified.** The `homelab-platform` HCP workspace
exists in Local execution mode; `terraform init`, `terraform validate` and
`terraform plan` all succeed against it. The workspace now manages real
cluster resources — the `homestreamlab` Namespace and ResourceQuota, created
by a real, reviewed `terraform apply` and verified live with `kubectl` — see
the runbook's
[`homestreamlab` namespace instantiation](./docs/terraform-runbook.md#homestreamlab-namespace-instantiation-issue-8)
section for the exact evidence.

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
  - [`docs/k3s-runbook.md`](./docs/k3s-runbook.md) — k3s install, operations,
    verification, and the destructive reset procedure
  - [`docs/registry-runbook.md`](./docs/registry-runbook.md) — registry
    operations, Docker daemon trust, reset, and rollback
  - [`docs/dnsmasq-runbook.md`](./docs/dnsmasq-runbook.md) — dnsmasq install,
    operations, verification, and rollback
  - [`docs/terraform-runbook.md`](./docs/terraform-runbook.md) — HCP workspace
    setup, kubeconfig handling, validation, verification, and rollback
  - [`docs/backup-runbook.md`](./docs/backup-runbook.md) — backup/restore
    usage, safety model, permissions, retention, and verified evidence
  - `docs/adr/` — architecture decision records
- `k3s/` — k3s install script and the local-registry pull test
- `dnsmasq/` — wildcard DNS: `install.sh`, `rollback.sh`, `smoke-test.sh`, `lib.sh`,
  and their tests
- `registry/` — local Docker registry: `docker-compose.yml` and `smoke-test.sh`
- `terraform/platform/` — the Platform's HCP-backed Terraform root module;
  instantiates the Namespace Pattern module once, for `homestreamlab`
- `terraform/modules/namespace-resourcequota/` — the reusable Namespace
  Pattern child module (`Namespace` + matching `ResourceQuota`), with its own
  repo-local throwaway-plan verification (`plan-check.sh`)
- `backup/` — the generic backup/restore mechanism: `backup.sh`, `restore.sh`,
  shared helpers in `lib.sh`, the Python archive-contract validator
  `tar_metadata_check.py`, and their tests

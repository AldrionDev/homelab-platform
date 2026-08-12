# CLAUDE.md

Guidance for Claude Code in this repo.

## Project

`homelab-platform` is a reusable local home lab platform repo for HomeStreamLab and future projects.

Current status: **bootstrapping**. Do not claim any platform component works until implemented and verified here.

Current milestone: **Home Lab Platform Bootstrap**.

## Scope

Implemented and verified:

- single-node bare-metal k3s — `k3s/install.sh`, requires `K3S_VERSION`
  (exact `vX.Y.Z+k3sN` tag) and `HOST_LAN_IP`; tests `k3s/install.test.sh`;
  runbook `docs/k3s-runbook.md`
- local Docker registry — `registry/docker-compose.yml` (`registry:2.8.3`,
  `restart: unless-stopped`, requires `HOST_LAN_IP` and binds to that address
  only, delete API enabled, no auth/TLS, named volume
  `homelab-registry-data`); smoke test `registry/smoke-test.sh`; runbook
  `docs/registry-runbook.md`. Verified on a real host: Compose startup,
  LAN-only bind, `/v2/` readiness, runtime restart policy, push, pull by
  immutable digest, manifest DELETE returning `202`, and the final `404`.
  The Docker daemon `insecure-registries` step is manual and documented in the
  runbook, not scripted.
- k3s registry trust — `/etc/rancher/k3s/registries.yaml` with a `mirrors`
  entry whose endpoint uses the `http://` scheme (no `configs`, no TLS section,
  no `insecure_skip_verify`), `root:root 0600`. Creating it and restarting k3s
  is a **manual, fail-closed runbook transaction**, not a script — it never
  overwrites a configuration it did not write. Verification is
  `k3s/registry-pull-test.sh`, run once on each side of a k3s restart, each run
  with its own marker/tag/manifest; it requires an explicit `KUBECONFIG` and
  refuses any cluster whose node InternalIP is not this host's default-route
  source IPv4 (`ip -4 route get`), so `HOST_LAN_IP` is never the node-identity
  oracle and shared bridge addresses cannot fake locality. Unit tests:
  `k3s/registry-pull-test.test.sh`. Runbook: `docs/k3s-runbook.md`.
  Host-verified: the `absent` branch of the setup transaction, the setup
  restart and post-restart health, Run A, a separate verification restart, the
  post-restart persistence checks, and Run B with a fresh image identity.
  **Not runtime-exercised**: every rollback and failure path, the manual-merge
  branch, and the `identical`/`differs` config states. Run B evidence is
  cache-immune, not cache-free, and the local-node identity check was added
  after Runs A and B (and later replaced by the route-derived predicate), so it
  was not in force during them. See the runbook's Verification status section
  before claiming more than this.
- dnsmasq wildcard DNS for `*.HOMELAB_DOMAIN` — `dnsmasq/install.sh`
  (idempotent, transactional, fail-closed `noop`/`mismatch`/`install`,
  requires `HOST_LAN_IP` and `HOMELAB_DOMAIN` with no defaults),
  `dnsmasq/rollback.sh` (ownership-aware, byte-exact `cmp` against durable
  state, never a comment marker), `dnsmasq/smoke-test.sh`. Config is isolated
  to `/etc/dnsmasq.d/homelab.conf`, loaded via a systemd drop-in that
  explicitly passes both `--conf-file=/etc/dnsmasq.conf
  --conf-file=/etc/dnsmasq.d/homelab.conf` — `/etc/dnsmasq.conf` itself is
  never edited. Durable ownership state lives under
  `/var/lib/homelab-platform/dnsmasq/` (root:root 0700), beneath the shared
  `/var/lib/homelab-platform/` root (root:root 0755, created explicitly if
  absent, never removed by rollback or by install's own failure cleanup).
  Tests: `dnsmasq/lib.test.sh`, `dnsmasq/install.test.sh`,
  `dnsmasq/rollback.test.sh`. Runbook: `docs/dnsmasq-runbook.md`.
  Host-verified with `HOST_LAN_IP=192.168.1.197` and
  `HOMELAB_DOMAIN=homelab.home.arpa`: install (including the
  `/var/lib/homelab-platform` state-root creation fix found by this same
  verification run), dnsmasq active and enabled, wildcard
  `*.homelab.home.arpa` resolution to `HOST_LAN_IP`, normal public DNS
  forwarding through dnsmasq, the host's own normal resolver path unaffected,
  full rollback (service stopped and disabled, both managed files and the
  component state directory removed, `DropInPaths` empty, a direct query to
  `HOST_LAN_IP:53` refused, normal DNS still working, the shared
  `/var/lib/homelab-platform/` root correctly left in place), and a clean
  reinstall afterward with a second passing smoke test. **Not exercised**:
  LAN-device resolution from a second physical device — this host's `ufw`
  default-denies inbound traffic and admits no port 53 rule; issue #5 marks
  that check as "if convenient," no `ufw` mutation was performed, and none is
  automated by this component. See the runbook's Verification status section
  before claiming more than this.
- HCP Terraform remote state with Local execution mode — the Platform Terraform
  Workspace, `terraform/platform/` (`versions.tf` pins
  `required_version = "~> 1.15"`, a `cloud` block naming the `homelab-platform`
  workspace per ADR-0002, and `hashicorp/kubernetes ~> 3.2` /
  `hashicorp/helm ~> 3.2`); `providers.tf` configures both providers from
  `var.kubeconfig_path`; the machine-specific path lives in a gitignored
  `terraform.tfvars`, and the HCP organization only in `TF_CLOUD_ORGANIZATION`.
  Repo-local gate: `bash terraform/platform/validate.sh` (fmt, `init
  -backend=false`, validate, leak gate) — verified locally on Terraform
  v1.15.8, with the lock file selecting `helm` 3.2.0 and `kubernetes` 3.2.1.
  Live-verified: the `homelab-platform` HCP workspace exists with Execution
  Mode Local; `terraform -chdir=terraform/platform init -input=false` against
  it reports "HCP Terraform has been successfully initialized!"; `terraform
  validate` reports the configuration valid; `terraform plan -input=false`
  reports "No changes. Your infrastructure matches the configuration." against
  the empty baseline, with the workspace showing 0 resources, unlocked, and no
  saved state afterward. This bootstrap (issue #6) itself declares **no
  Kubernetes resources** (#7 below adds the reusable Namespace +
  ResourceQuota pattern as a module; #8 below performs the first concrete
  project instantiation and the first real runtime `apply` against this same
  workspace — see the `homestreamlab` namespace instantiation entry below).
  **Not runtime-exercised by this empty-baseline plan itself**:
  provider-to-cluster connectivity — the configuration contained no resources
  or data sources requiring Kubernetes API operations at that point, so that
  empty baseline plan was not by itself evidence of a live provider
  connection; live provider connectivity is now evidenced by issue #8 below.
  Runbook: `docs/terraform-runbook.md`.
- Namespace Pattern Terraform module — a reusable, generic child module at
  `terraform/modules/namespace-resourcequota/` (owns
  `kubernetes_namespace_v1.this` and `kubernetes_resource_quota_v1.this`;
  required inputs `project_name`, `cpu_request`, `cpu_limit`,
  `memory_request`, `memory_limit`, no defaults; declares only
  `required_providers`, no `provider`/backend/cloud block — it inherits the
  caller's `kubernetes` provider). Repo-locally verified: `bash
  terraform/platform/validate.sh` (extended to also `init`/`validate` every
  `terraform/modules/*/` entry from an isolated scratch copy, never the
  module directory itself, and to reject any committed module-level
  `.terraform.lock.hcl`) and `bash
  terraform/modules/namespace-resourcequota/plan-check.sh` (a throwaway plan
  against a synthetic, non-functional kubeconfig, asserting via `terraform
  show -json` + `jq` exactly 2 resource creates —
  `module.throwaway.kubernetes_namespace_v1.this` and
  `module.throwaway.kubernetes_resource_quota_v1.this` — with the expected
  name, namespace, and `spec.hard` values). No project is instantiated by
  issue #7 itself: no `module` block in `terraform/modules/` calls this
  module from its own source.
  **Not live-verified by issue #7's own checks**: `plan-check.sh`
  deliberately uses no real kubeconfig, no real k3s API endpoint, no HCP
  backend/state, and never runs `apply`, so passing it is not by itself
  evidence of live Kubernetes provider-to-cluster connectivity. Issue #8
  (below) is the first concrete caller of this module and the first real
  runtime `apply`. Runbook: `docs/terraform-runbook.md`.
- `homestreamlab` namespace instantiation — the first concrete caller of the
  Namespace Pattern module: `terraform/platform/main.tf` declares
  `module "homestreamlab"` (`source = "../modules/namespace-resourcequota"`,
  `project_name = "homestreamlab"`), with these explicitly approved platform
  quota policy values:
  ```hcl
  cpu_request    = "1"
  cpu_limit      = "2"
  memory_request = "2Gi"
  memory_limit   = "4Gi"
  ```
  Repo-locally verified: `bash terraform/platform/validate.sh` passes with
  this module block in place. Live-verified against the real
  `homelab-platform` HCP workspace (Execution Mode confirmed Local in the HCP
  UI immediately before planning) and this host's real k3s cluster: a real
  `terraform plan` showed exactly 2 creates
  (`module.homestreamlab.kubernetes_namespace_v1.this`,
  `module.homestreamlab.kubernetes_resource_quota_v1.this`) with the expected
  names and `spec.hard` values, verified via `terraform show -json` + `jq`,
  not just the human-readable summary; the reviewed saved plan was applied
  without recomputing it (external drift could still cause an apply to
  fail); `terraform apply` reported `2 added, 0 changed, 0 destroyed`;
  `kubectl get namespace homestreamlab` shows `Active`, and `kubectl get
  resourcequota homestreamlab-quota -n homestreamlab -o yaml` shows
  `spec.hard` matching the four values above exactly; `pods`,
  `deployments.apps`, `statefulsets.apps`, `daemonsets.apps`, `jobs.batch`,
  `cronjobs.batch`, `services`, `ingresses.networking.k8s.io`, `secrets`, and
  (where the CRD is registered) `ingressroutes.traefik.io` were all confirmed
  empty in the namespace; a subsequent real `terraform plan` reported `No
  changes. Your infrastructure matches the configuration.` with both managed
  resources appearing only as `no-op`. The saved plan and its JSON rendering
  were kept outside this repository throughout, with restrictive
  permissions, and deleted after use. No Deployment, Service, IngressRoute,
  Secret, ConfigMap, Helm release, or Jenkinsfile exists as a result of this
  issue. Runbook: `docs/terraform-runbook.md`.
- generic local backup/restore mechanism — script-only (no CronJob or other
  scheduler), fully application-independent. `backup/backup.sh` requires
  `BACKUP_DESTINATION` (absolute, must already exist, must already be mode
  `0700`, no default, never created/`chmod`'d by the script), `BACKUP_ID`
  (`[A-Za-z0-9-]+`), and `BACKUP_SOURCE_KIND` (`dir`|`db`); dir mode requires
  `BACKUP_SOURCE_DIR`; db mode requires `BACKUP_LIVE_DATA_PATH` (a pure
  locality guard, never read/archived) plus a dump-producer executed
  directly as argv after `--` (never `eval`, never a shell string).
  `backup/restore.sh` requires `BACKUP_ARCHIVE`, a not-yet-existing
  `RECOVERY_TARGET`, `RESTORE_LIVE_DATA_PATH`, and a required
  workload-validator argv after `--`. Shared helpers: `backup/lib.sh`. The
  archive-contract validator `backup/tar_metadata_check.py` (Python 3
  standard library only, no pip packages — the one dependency this feature
  adds) implements ADR-0004's full member-path/type, layout, manifest, and
  payload-consistency checks via `tarfile`, run synchronously before backup
  publication and before restore extraction — never by parsing `tar -tv`
  text. Publication is checksum-first/archive-last via collision-refusing
  hardlinks (archive visibility is the validity boundary); restore
  snapshots the external archive exactly once and never reopens it; the
  Recovery Target is claimed via `mkdir` and destructively cleaned up only
  when a device+inode+random-token (`secrets.token_hex(32)`) ownership
  proof matches. No automatic pruning or retention. Tests:
  `backup/lib.test.sh`, `backup/tar_metadata_check.test.sh`,
  `backup/backup.test.sh`, `backup/restore.test.sh`. Runbook:
  `docs/backup-runbook.md`. **Verified with smoke/dummy data only, entirely
  under `mktemp` scratch directories**: 177 passing test cases
  (61+41+37+38), 0 failures, covering both the directory-payload path and a
  synthetic opaque-dump db-payload path, plus one continuous 13-step
  end-to-end scenario matching issue #9's acceptance steps. **Not
  verified**: any real project/application data, any real PostgreSQL or
  other database engine (the synthetic dump smoke test proves byte-exact
  transport only, never `pg_dump`/`pg_restore` compatibility), and no
  HomeStreamLab-specific wiring exists anywhere in this repository.

Planned platform pieces:

- platform runbook

This repo is **platform-only**.

Do not add:

- HomeStreamLab app deployment
- HomeStreamLab Dockerfiles
- HomeStreamLab Jenkinsfile
- HomeStreamLab app Terraform workspace
- app Secrets, IngressRoute, database deployment, or app manifests

HomeStreamLab-specific deployment belongs in the separate `homestreamlab` repo.

Out of scope now: AWS/EKS/ECS, TLS/mkcert, Vault/sealed-secrets, ArgoCD/Flux, Prometheus/Grafana, multi-node/KVM workers, production hardening beyond local-lab safety notes.

## Safety

- Never modify host-level services without explicit user approval.
- Host-level includes k3s, dnsmasq, registry, systemd, Terraform backend/state, backup/restore.
- Host-level scripts need safety checks and rollback notes.
- Never commit secrets, kubeconfigs, Terraform state, `.env`, backup archives, or machine-specific values.
- `.env.example` may contain placeholders only.

## Workflow

- Work one GitHub issue at a time.
- Plan first; implement only after approval.
- Keep changes scoped to the approved issue.
- Prefer simple scripts/docs over abstractions.
- Mark planned items as planned, never as done.
- Commit/push/PR only after review PASS and explicit user approval.

Repo safety rules still apply. Host-mutating commands require separate approval.

## Issue standard

Use:

```md
## Goal

## Acceptance criteria

## Out of scope

## Verification steps

## Definition of Done
```

Default DoD:

- Acceptance criteria met.
- Verification steps pass.
- Scope respected.
- No secrets or machine-specific values committed.
- Safety/rollback notes documented for host-level changes.
- README/runbook updated when install, operation, verification, or recovery changes.
- Review passes before merge.

## Git

- One branch per issue.
- Use issue-based branch names, e.g. `chore/init-repo-structure`.
- Use Conventional Commits.
- No unrelated changes.
- No direct merge to `main`.

## Update rule

When a planned component becomes implemented and verified, update this file with real paths/commands.

## Agent skills

### Issue tracker

Issues live in this repo's GitHub Issues, using the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Domain docs

Single-context layout (`CONTEXT.md` + `docs/adr/` at the repo root). See `docs/agents/domain.md`.

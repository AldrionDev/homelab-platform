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

Planned platform pieces:

- dnsmasq `*.homelab.local`
- Terraform-managed namespaces and ResourceQuotas
- HCP Terraform remote state with Local execution mode
- `homestreamlab` namespace placeholder only
- generic local backup routine
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

Global issue workflow is available:

```txt
/issue-orchestrator <issue-number> [--repo owner/repo]
```

It handles plan → approval → implementation → review/security review → fix loop → DoD report → approval for commit/push/PR.

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

# CLAUDE.md

Guidance for Claude Code in this repo.

## Project

`homelab-platform` is a reusable local home lab platform repo for HomeStreamLab and future projects.

Current status: **bootstrapping**. Do not claim any platform component works until implemented and verified here.

Current milestone: **Home Lab Platform Bootstrap**.

## Scope

Planned platform pieces:

- single-node bare-metal k3s
- local Docker registry
- k3s registry trust
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

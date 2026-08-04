# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project purpose

`homelab-platform` is a reusable, project-independent local home lab platform repository. It owns the platform layer (cluster, registry, DNS, namespace scaffolding, backups) used to run home lab workloads such as HomeStreamLab and future projects. It does not contain any application-specific deployment code.

## Current status

Bootstrapping. Only the initial repository scaffold exists (`README.md`, git history). No platform code, scripts, or Terraform configuration has been implemented yet. Do not assume any component below is working until it has actually been implemented and verified in this repo.

## Current milestone

**Home Lab Platform Bootstrap**

Goal: create a reusable, replayable, single-node k3s home lab platform on the local machine.

## Planned architecture

Everything in this section is **planned, not implemented**, unless a corresponding issue has been completed and verified in the repo history.

* k3s bare-metal single-node cluster
* Local Docker registry running on the host
* k3s registry trust configuration for the local registry
* dnsmasq wildcard DNS for `*.homelab.local`
* Terraform-managed in-cluster scaffolding
* HCP Terraform remote state with Local execution mode
* Reusable namespace + ResourceQuota pattern
* `homestreamlab` namespace placeholder with a ResourceQuota (namespace scaffolding only, no app deployment)
* Generic local backup routine for future stateful workloads
* Platform runbook documenting setup and recovery steps

## Repository boundaries

This repository is **platform-only**. It must never contain:

* HomeStreamLab application deployment code
* HomeStreamLab Dockerfiles
* HomeStreamLab Jenkinsfile
* HomeStreamLab app Terraform workspace
* App Secrets, IngressRoute, database deployment, or other application manifests

HomeStreamLab-specific deployment belongs in the separate `homestreamlab` repository.

## Out of scope (current milestone)

* AWS/EKS/ECS or any cloud infrastructure
* TLS/mkcert
* Vault/sealed-secrets
* ArgoCD/Flux
* Prometheus/Grafana
* Multi-node or KVM worker nodes
* HomeStreamLab app deployment
* Production-grade hardening beyond basic local-lab safety notes

## Safety rules

* Never modify host-level services (k3s, dnsmasq, Docker registry, etc.) without explicit user confirmation first.
* Any host-level script must include safety and rollback instructions.
* Never commit secrets, kubeconfigs, Terraform state, `.env` files, backup archives, or machine-specific values.

## Workflow rules

* Work issue by issue; keep changes small and scoped to one issue.
* Plan first, implement after the plan is accepted.
* Prefer small, practical steps over speculative architecture — do not build beyond the approved milestone scope.
* Mark planned-but-unimplemented items clearly as planned in docs/comments, never as done.

## GitHub issue template

All issues use this standardized structure:

```md
## Goal

## Acceptance criteria

## Out of scope

## Verification steps

## Definition of Done
```

* `Verification steps` means Testing / Validation — the concrete steps used to confirm the acceptance criteria hold.
* `Definition of Done` is required on every issue and always includes at least:
  * Acceptance criteria are met.
  * Verification steps pass.
  * Changes are scoped to this issue only.
  * No secrets, kubeconfigs, Terraform state, `.env` files, backup archives, or machine-specific values are committed.
  * Safety and rollback notes are documented when host-level behavior is changed.
  * README or runbook is updated when the issue changes how the platform is installed, operated, verified, or recovered.
  * Review passes before merge.

## Git / commit conventions

* Branch naming derived from the issue, e.g.:
  * `chore/init-repo-structure`
  * `feature/k3s-install-script`
* Conventional Commit style (`feat:`, `fix:`, `chore:`, `docs:`, `refactor:`, `test:`).
* Small, meaningful commits; no unrelated changes bundled together.

## Notes for future updates

Update this file as the platform is actually implemented:

* Move completed items from "Planned architecture" into a new "Implemented architecture" section, with real file paths and commands (build/lint/test/deploy) once they exist.
* Keep "Out of scope" accurate — only remove an item once a milestone explicitly brings it into scope.
* Do not describe any component as working until it has been implemented and verified in this repo.

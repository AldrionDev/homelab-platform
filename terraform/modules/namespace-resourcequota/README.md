# namespace-resourcequota

The **Namespace Pattern** (see `CONTEXT.md`): a reusable, parameterized Terraform child
module that produces a Kubernetes `Namespace` together with a matching
`ResourceQuota` for a Project, generic across all Projects. Not hardcoded to any
specific project — no concrete project is instantiated by this module's own source.

## Purpose

Every Project onboarded onto this Platform gets its own Namespace and a matching
ResourceQuota bounding that Project's CPU/memory consumption. This module is the single
reusable definition of that pattern; a Project is onboarded by calling this module with
that Project's own values, not by writing new resource blocks per Project.

Issue #7 adds this module only. It instantiates nothing — no `module` block anywhere in
the repo calls it yet. Issue #8 performs the first concrete instantiation (the
`homestreamlab` namespace placeholder).

## Inputs

| Name             | Type   | Required | Description                                                                                          |
|-------------------|--------|----------|--------------------------------------------------------------------------------------------------------|
| `project_name`     | string | yes      | Namespace name and ResourceQuota name prefix. Must be a valid Kubernetes DNS-1123 label (max 63 chars). |
| `cpu_request`      | string | yes      | `spec.hard["requests.cpu"]`. See "Supported CPU/memory quantity subset" below.                        |
| `cpu_limit`        | string | yes      | `spec.hard["limits.cpu"]`. See "Supported CPU/memory quantity subset" below.                          |
| `memory_request`   | string | yes      | `spec.hard["requests.memory"]`. See "Supported CPU/memory quantity subset" below.                     |
| `memory_limit`     | string | yes      | `spec.hard["limits.memory"]`. See "Supported CPU/memory quantity subset" below.                        |

None of these have defaults — every caller must supply explicit values.

## Outputs

| Name                  | Description                                  |
|------------------------|-----------------------------------------------|
| `namespace_name`        | The created Namespace's name (= `project_name`). |
| `resource_quota_name`   | The created ResourceQuota's name.             |

## Naming convention

- Namespace name: `var.project_name`, verbatim.
- ResourceQuota name: `"${var.project_name}-quota"`.

## Supported CPU/memory quantity subset

The `cpu_request`/`cpu_limit`/`memory_request`/`memory_limit` variables validate only a
**platform-supported canonical subset** of Kubernetes' quantity syntax — this is not a
complete implementation of Kubernetes' full quantity grammar (no exponent notation, no
binary CPU suffixes, etc.).

- CPU: whole or decimal cores (`"1"`, `"0.5"`), or millicores (`"500m"`).
- Memory: a number with an optional binary or decimal suffix (`"512Mi"`, `"1Gi"`,
  `"256M"`).

If a future Project needs a quantity form outside this subset, extend the
`validation` blocks in `variables.tf` deliberately rather than relaxing them broadly.

## `spec.hard` mapping

```
requests.cpu    = var.cpu_request
requests.memory = var.memory_request
limits.cpu      = var.cpu_limit
limits.memory   = var.memory_limit
```

## Provider inheritance

This module declares only `required_providers` in `versions.tf` — no `provider
"kubernetes" {}` configuration block. It inherits the caller's default `kubernetes`
provider instance implicitly, exactly as configured in
`terraform/platform/providers.tf`.

## Repo-local verification

- `bash terraform/platform/validate.sh` — formats and validates this module (via an
  isolated scratch copy — see that script's `check_modules_init_and_validate`), among
  the repo's other repo-local checks.
- `bash terraform/modules/namespace-resourcequota/plan-check.sh` — a throwaway
  `terraform plan` against a synthetic, non-functional kubeconfig, asserting the exact
  expected Namespace + ResourceQuota creation. See that script's header comment for its
  precise contract (repo-local; no HCP backend/state; no real k3s kubeconfig or API
  endpoint; no `apply`; provider installation may still contact the public Terraform
  provider registry). See `docs/terraform-runbook.md` for the full procedure.

Neither check applies anything to a real cluster or touches HCP Terraform.

terraform {
  # Verified on Terraform v1.15.8.
  # Pinned to the 1.x line: the `cloud` block and the provider syntax below are
  # 1.x contracts, and a future 2.0 must be adopted deliberately, not silently.
  required_version = "~> 1.15"

  # HCP Terraform is used for remote state only. Execution mode is Local
  # (ADR-0001) — that is workspace-side configuration and cannot be expressed
  # here; see docs/terraform-runbook.md.
  #
  # The organization is account-specific and is supplied through the
  # TF_CLOUD_ORGANIZATION environment variable. It is deliberately absent from
  # this file and must never be committed.
  cloud {
    workspaces {
      # ADR-0002: the Platform workspace is deliberately named `homelab-platform`,
      # not `homelab-platform-k8s`. Do not "fix" this to the tenant convention.
      name = "homelab-platform"
    }
  }

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.2"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.2"
    }
  }
}

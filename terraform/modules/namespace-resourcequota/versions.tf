# Child module: no required_version, no cloud/backend block, no provider
# configuration block. Those are root-module concerns (see
# terraform/platform/versions.tf and providers.tf). This module inherits the
# caller's default "kubernetes" provider instance implicitly.

terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.2"
    }
  }
}

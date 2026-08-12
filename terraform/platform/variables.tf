variable "kubeconfig_path" {
  description = <<-EOT
    Absolute path to a kubeconfig for this host's k3s cluster, readable by the
    user running Terraform. Machine-specific: supply it from a gitignored
    terraform.tfvars (or TF_VAR_kubeconfig_path). Never commit a real path.
  EOT
  type        = string

  validation {
    condition     = startswith(var.kubeconfig_path, "/")
    error_message = "kubeconfig_path must be an absolute path."
  }
}

variable "kube_context" {
  description = "kubeconfig context to use. k3s generates a single context named \"default\"."
  type        = string
  default     = "default"
}

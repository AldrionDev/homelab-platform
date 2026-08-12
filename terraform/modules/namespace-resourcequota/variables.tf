variable "project_name" {
  description = <<-EOT
    Project name. Used verbatim as the Namespace name, and as the prefix for
    the ResourceQuota name ("<project_name>-quota"). Must be a valid
    Kubernetes DNS-1123 label: lowercase alphanumeric characters or '-',
    starting and ending with an alphanumeric character, max 63 characters.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.project_name)) && length(var.project_name) <= 63
    error_message = "project_name must be a valid DNS-1123 label: lowercase alphanumeric or '-', starting and ending with an alphanumeric character, max 63 characters."
  }
}

# CPU and memory variables below validate only the canonical subset of
# Kubernetes quantity syntax this platform supports — not the full Kubernetes
# quantity grammar (e.g. no exponent notation, no binary CPU suffixes). Keep
# this simple and reviewable; extend only if a real project needs a form
# outside this subset.

variable "cpu_request" {
  description = <<-EOT
    spec.hard["requests.cpu"]. A Kubernetes CPU quantity in this platform's
    supported canonical subset: whole or decimal cores (e.g. "1", "0.5") or
    millicores (e.g. "500m").
  EOT
  type        = string

  validation {
    condition     = can(regex("^([0-9]+(\\.[0-9]+)?|[0-9]+m)$", var.cpu_request))
    error_message = "cpu_request must match this platform's supported CPU quantity subset, e.g. \"1\", \"0.5\" or \"500m\"."
  }
}

variable "cpu_limit" {
  description = <<-EOT
    spec.hard["limits.cpu"]. A Kubernetes CPU quantity in this platform's
    supported canonical subset: whole or decimal cores (e.g. "1", "0.5") or
    millicores (e.g. "500m").
  EOT
  type        = string

  validation {
    condition     = can(regex("^([0-9]+(\\.[0-9]+)?|[0-9]+m)$", var.cpu_limit))
    error_message = "cpu_limit must match this platform's supported CPU quantity subset, e.g. \"1\", \"0.5\" or \"500m\"."
  }
}

variable "memory_request" {
  description = <<-EOT
    spec.hard["requests.memory"]. A Kubernetes memory quantity in this
    platform's supported canonical subset: a number followed by an optional
    binary or decimal suffix (e.g. "512Mi", "1Gi", "256M").
  EOT
  type        = string

  validation {
    condition     = can(regex("^[0-9]+(\\.[0-9]+)?(Ei|Pi|Ti|Gi|Mi|Ki|E|P|T|G|M|k)?$", var.memory_request))
    error_message = "memory_request must match this platform's supported memory quantity subset, e.g. \"512Mi\", \"1Gi\" or \"256M\"."
  }
}

variable "memory_limit" {
  description = <<-EOT
    spec.hard["limits.memory"]. A Kubernetes memory quantity in this
    platform's supported canonical subset: a number followed by an optional
    binary or decimal suffix (e.g. "512Mi", "1Gi", "256M").
  EOT
  type        = string

  validation {
    condition     = can(regex("^[0-9]+(\\.[0-9]+)?(Ei|Pi|Ti|Gi|Mi|Ki|E|P|T|G|M|k)?$", var.memory_limit))
    error_message = "memory_limit must match this platform's supported memory quantity subset, e.g. \"512Mi\", \"1Gi\" or \"256M\"."
  }
}

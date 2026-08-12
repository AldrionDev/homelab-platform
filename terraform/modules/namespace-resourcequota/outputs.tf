output "namespace_name" {
  description = "The created Namespace's name (equals var.project_name)."
  value       = kubernetes_namespace_v1.this.metadata[0].name
}

output "resource_quota_name" {
  description = "The created ResourceQuota's name."
  value       = kubernetes_resource_quota_v1.this.metadata[0].name
}

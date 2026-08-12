resource "kubernetes_namespace_v1" "this" {
  metadata {
    name = var.project_name
  }
}

resource "kubernetes_resource_quota_v1" "this" {
  metadata {
    name      = "${var.project_name}-quota"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }

  spec {
    hard = {
      "requests.cpu"    = var.cpu_request
      "requests.memory" = var.memory_request
      "limits.cpu"      = var.cpu_limit
      "limits.memory"   = var.memory_limit
    }
  }
}

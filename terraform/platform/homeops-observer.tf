# Issue #38: runtime identity for the HomeOps backend. This identity is
# deliberately separate from homeops-deployer and has read-only access only to
# the cluster resources displayed by HomeOps v0.1.

resource "kubernetes_service_account_v1" "homeops_observer" {
  metadata {
    name      = "homeops-observer"
    namespace = module.homeops.namespace_name
  }

  # HomeOps uses standard in-cluster ServiceAccount authentication.
  automount_service_account_token = true
}

resource "kubernetes_cluster_role_v1" "homeops_observer" {
  metadata {
    name = "homeops-observer"
  }

  rule {
    api_groups = [""]
    resources  = ["namespaces"]
    verbs      = ["get", "list"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "list"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods/log"]
    verbs      = ["get"]
  }

  rule {
    api_groups = ["apps"]
    resources  = ["deployments"]
    verbs      = ["get", "list"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "homeops_observer" {
  metadata {
    name = "homeops-observer"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.homeops_observer.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.homeops_observer.metadata[0].name
    namespace = module.homeops.namespace_name
  }
}

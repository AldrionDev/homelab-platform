# Issue #38: external Jenkins deployment identity for HomeOps. Terraform owns
# only this ServiceAccount and its RBAC; token issuance, kubeconfig construction
# and the `k3s-homeops` Jenkins credential are operator-managed.
#
# The namespaced verbs match the hashicorp/kubernetes 3.2.1 lifecycle already
# established for HomeStreamLab: Get/Create/Patch/Delete for Services and
# Deployments, and dynamic Get/Server-Side Apply/Delete for IngressRoutes. No
# lifecycle requires update, list or watch on these workload resources.

resource "kubernetes_service_account_v1" "homeops_deployer" {
  metadata {
    name      = "homeops-deployer"
    namespace = module.homeops.namespace_name
  }

  # Jenkins uses an out-of-band kubeconfig; this identity is not mounted into a
  # Pod by the platform.
  automount_service_account_token = false
}

resource "kubernetes_role_v1" "homeops_deployer" {
  metadata {
    name      = "homeops-deployer"
    namespace = module.homeops.namespace_name
  }

  rule {
    api_groups = [""]
    resources  = ["services"]
    verbs      = ["get", "create", "patch", "delete"]
  }

  rule {
    api_groups = ["apps"]
    resources  = ["deployments"]
    verbs      = ["get", "create", "patch", "delete"]
  }

  rule {
    api_groups = ["traefik.io"]
    resources  = ["ingressroutes"]
    verbs      = ["get", "create", "patch", "delete"]
  }
}

resource "kubernetes_role_binding_v1" "homeops_deployer" {
  metadata {
    name      = "homeops-deployer"
    namespace = module.homeops.namespace_name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.homeops_deployer.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.homeops_deployer.metadata[0].name
    namespace = module.homeops.namespace_name
  }
}

# A namespaced Role cannot grant these two provider-required cluster reads.
# Namespace get is restricted to homeops. hashicorp/kubernetes 3.2.1's
# kubernetes_manifest resource unconditionally lists CRDs for schema discovery;
# Kubernetes cannot restrict list by resourceNames. Neither rule permits writes.
resource "kubernetes_cluster_role_v1" "homeops_deployer_cluster_read" {
  metadata {
    name = "homeops-deployer-cluster-read"
  }

  rule {
    api_groups     = [""]
    resources      = ["namespaces"]
    resource_names = ["homeops"]
    verbs          = ["get"]
  }

  rule {
    api_groups = ["apiextensions.k8s.io"]
    resources  = ["customresourcedefinitions"]
    verbs      = ["list"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "homeops_deployer_cluster_read" {
  metadata {
    name = "homeops-deployer-cluster-read"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.homeops_deployer_cluster_read.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.homeops_deployer.metadata[0].name
    namespace = module.homeops.namespace_name
  }
}

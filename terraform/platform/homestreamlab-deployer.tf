# Issue #31: platform-owned Kubernetes deployment identity for the HomeStreamLab
# Project. A future local-jenkins-platform J6 credential (`k3s-homestreamlab`)
# consumes this identity through a self-contained kubeconfig — never the host
# administrator kubeconfig, never cluster-admin.
#
# Terraform manages ONLY the identity and RBAC objects below. The ServiceAccount
# token and the handoff kubeconfig are operator-issued out of band, after apply,
# and never enter Terraform state, variables, or outputs. See
# docs/homestreamlab-deployer-runbook.md.
#
# The Namespace and ResourceQuota are owned by module.homestreamlab (issue #8)
# and are only referenced here via its `namespace_name` output — never recreated
# or modified.
#
# Permissions are exactly the CRUD lifecycle the hashicorp/kubernetes provider
# (locked at 3.2.1) performs for the resources HomeStreamLab's own Terraform
# currently manages, verified against provider source at tag v3.2.1:
#
#   kubernetes_secret_v1                  Create -> Secrets(ns).Create()
#                                        Read   -> Secrets(ns).Get()
#                                        Update -> Secrets(ns).Patch(JSONPatchType)
#                                        Delete -> Secrets(ns).Delete()
#   kubernetes_persistent_volume_claim_v1 same shape:
#                                        Create()/Get()/Patch(JSONPatchType)/Delete()
#                                        (wait_until_bound = false on both HSL PVCs,
#                                        so no watch/list on PVCs or PVs)
#   data.kubernetes_namespace_v1         Read -> Namespaces().Get(name)  [cluster-scoped]
#
# => namespaced verbs: get, create, patch, delete   (no update, no list, no watch)
# => one narrow cluster-scoped exception: get on Namespace/homestreamlab only.

resource "kubernetes_service_account_v1" "homestreamlab_deployer" {
  metadata {
    name      = "homestreamlab-deployer"
    namespace = module.homestreamlab.namespace_name
  }

  # This identity is used by an external client (Jenkins) via an out-of-band
  # kubeconfig; it is never mounted into a Pod, so disable token automount.
  automount_service_account_token = false
}

resource "kubernetes_role_v1" "homestreamlab_deployer" {
  metadata {
    name      = "homestreamlab-deployer"
    namespace = module.homestreamlab.namespace_name
  }

  rule {
    api_groups = [""]
    resources  = ["secrets"]
    verbs      = ["get", "create", "patch", "delete"]
  }

  rule {
    api_groups = [""]
    resources  = ["persistentvolumeclaims"]
    verbs      = ["get", "create", "patch", "delete"]
  }
}

resource "kubernetes_role_binding_v1" "homestreamlab_deployer" {
  metadata {
    name      = "homestreamlab-deployer"
    namespace = module.homestreamlab.namespace_name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.homestreamlab_deployer.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.homestreamlab_deployer.metadata[0].name
    namespace = module.homestreamlab.namespace_name
  }
}

# --- Narrow cluster-scoped exception (RBAC_SCOPE_REVIEW_REQUIRED, approved) -----
#
# HomeStreamLab's current Terraform reads the cluster-scoped object
# Namespace/homestreamlab via `data "kubernetes_namespace_v1" "homestreamlab"`.
# A namespaced Role cannot grant access to a cluster-scoped resource, so this
# ClusterRole is required for HomeStreamLab's Terraform to plan/apply as this
# identity.
#
# It is the narrowest grant that satisfies that need: `get` only, restricted by
# resourceNames to the single `homestreamlab` namespace, bound to exactly one
# subject. It grants no `list`, no `watch`, no access to any other namespace, and
# no cluster-scoped write of any kind. Operator-approved for this reason; see
# docs/homestreamlab-deployer-runbook.md.

resource "kubernetes_cluster_role_v1" "homestreamlab_deployer_namespace_read" {
  metadata {
    name = "homestreamlab-deployer-namespace-read"
  }

  rule {
    api_groups     = [""]
    resources      = ["namespaces"]
    resource_names = ["homestreamlab"]
    verbs          = ["get"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "homestreamlab_deployer_namespace_read" {
  metadata {
    name = "homestreamlab-deployer-namespace-read"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.homestreamlab_deployer_namespace_read.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.homestreamlab_deployer.metadata[0].name
    namespace = module.homestreamlab.namespace_name
  }
}

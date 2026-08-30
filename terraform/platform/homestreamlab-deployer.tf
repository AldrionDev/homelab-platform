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
#   kubernetes_service_v1                 Create()/Get()/Patch(JSONPatchType)/Delete()
#                                        (all HSL Services are ClusterIP, so the
#                                        LoadBalancer wait never runs; endpoints /
#                                        endpointslices are never touched)
#   kubernetes_deployment_v1             Create()/Get()/Patch(JSONPatchType)/Delete()
#                                        wait_for_rollout defaults true and polls
#                                        Deployments(ns).Get() only -- no pods,
#                                        replicasets, watch, or deployments/status
#   kubernetes_manifest                  Apply  -> dynamic Patch(ApplyPatchType)
#     (Traefik IngressRoute,             Read   -> dynamic Get()
#      traefik.io/v1alpha1)              Delete -> dynamic Delete()
#                                        Server-Side Apply that creates an absent
#                                        object is authorized as create + patch.
#   data.kubernetes_namespace_v1         Read -> Namespaces().Get(name)  [cluster-scoped]
#
# => namespaced verbs: get, create, patch, delete   (no update, no list, no watch)
# => cluster-scoped, read only (see the ClusterRole below):
#      - get  on Namespace/homestreamlab               (name-restricted)
#      - list on customresourcedefinitions             (kubernetes_manifest)

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

# --- Cluster-scoped reads (RBAC_SCOPE_REVIEW_REQUIRED, approved) ----------------
#
# HomeStreamLab's Terraform needs two cluster-scoped reads to plan/apply as this
# identity. Both are read-only; a namespaced Role cannot grant either. There is
# no cluster-scoped write, no `watch`, and no access beyond what is listed.
#
# 1. get on Namespace/homestreamlab. `data "kubernetes_namespace_v1"
#    "homestreamlab"` reads the cluster-scoped Namespace object. Restricted by
#    resourceNames to the single `homestreamlab` namespace -- no `list`, no
#    `watch`, no `get` on any other namespace.
#
# 2. list on customresourcedefinitions.apiextensions.k8s.io. The
#    hashicorp/kubernetes v3.2.1 `kubernetes_manifest` resource (the Traefik
#    IngressRoute) unconditionally lists every CRD cluster-wide during schema /
#    type resolution on every plan, read and apply
#    (manifest/provider/resource.go: fetchCRDs -> RESTMappings +
#    Resource(crd).List()); a `forbidden` there fails the operation with no
#    fallback. The RBAC `list` verb ignores resourceNames, so this cannot be
#    name-restricted. It is a read: no `get` past the list, no `watch`, no CRD
#    write, no other apiextensions.k8s.io verb.
#
# Both grants are bound to exactly the `homestreamlab-deployer` ServiceAccount
# via the ClusterRoleBinding below. Operator-approved; see
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

  rule {
    api_groups = ["apiextensions.k8s.io"]
    resources  = ["customresourcedefinitions"]
    verbs      = ["list"]
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

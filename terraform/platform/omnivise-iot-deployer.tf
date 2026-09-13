# Issue #42: platform-owned least-privilege Kubernetes deployment identity for
# OmniVise IoT. A future `omnivise-iot-k8s` HCP workspace consumes this identity
# through an operator-issued, self-contained kubeconfig (later registered as the
# `k3s-omnivise-iot` credential by a separate OmniVise deployment issue — not
# configured here). Never the host administrator kubeconfig, never cluster-admin.
#
# Terraform manages ONLY the identity and RBAC objects below. The ServiceAccount
# token and the handoff kubeconfig are operator-issued out of band, after apply,
# and never enter Terraform state, variables, or outputs. See
# docs/omnivise-iot-deployer-runbook.md.
#
# The Namespace and ResourceQuota are owned by module.omnivise_iot (issue #41)
# and are only referenced here via its `namespace_name` output — never recreated
# or modified.
#
# Permissions are exactly the CRUD lifecycle the hashicorp/kubernetes provider
# (locked at 3.2.1, the same version OmniVise pins) performs for the resources
# OmniVise's own Terraform manages after omnivise-iot#39, verified against
# provider source at tag v3.2.1:
#
#   kubernetes_service_v1        Create -> Services(ns).Create()
#     (mongodb, backend,         Read   -> Services(ns).Get()
#      frontend; all ClusterIP)  Update -> Services(ns).Patch(JSONPatchType)
#                                Delete -> Services(ns).Delete() + Get() poll
#                                ClusterIP => the LoadBalancer wait never runs;
#                                endpoints / endpointslices are never touched.
#   kubernetes_deployment_v1     Create()/Get()/Patch(JSONPatchType)/Delete()
#     (backend, frontend,        wait_for_rollout = false on all three => no
#      sensor_simulator)         rollout polling; pods / replicasets / status
#                                are never touched.
#   kubernetes_stateful_set_v1   Create()/Get()/Patch(JSONPatchType)/Delete()
#     (mongodb)                  wait_for_rollout = false => no rollout polling;
#                                pods / PVCs / controllerrevisions are never
#                                touched. The volumeClaimTemplates PVC is
#                                created by the StatefulSet controller, not by
#                                this identity.
#   kubernetes_job_v1            Create()/Get()/Patch(JSONPatchType)/Delete()
#     (mongodb-bootstrap)        wait_for_completion = true polls the Job OBJECT
#                                via BatchV1().Jobs(ns).Get() for its status
#                                conditions; it never lists or watches, and
#                                never touches the bootstrap Pod (created by the
#                                Job controller).
#   kubernetes_manifest          Apply  -> dynamic Patch(ApplyPatchType)
#     (Traefik IngressRoute,     Read   -> dynamic Get()
#      traefik.io/v1alpha1)      Delete -> dynamic Delete()
#                                Server-Side Apply that creates an absent object
#                                is authorized as create + patch.
#   data.kubernetes_namespace_v1 Read -> Namespaces().Get(name)  [cluster-scoped]
#
# => namespaced verbs: get, create, patch, delete   (no update, no list, no watch)
# => cluster-scoped, read only (see the ClusterRole below):
#      - get  on Namespace/omnivise-iot                (name-restricted)
#      - list on customresourcedefinitions             (kubernetes_manifest)

resource "kubernetes_service_account_v1" "omnivise_iot_deployer" {
  metadata {
    name      = "omnivise-iot-deployer"
    namespace = module.omnivise_iot.namespace_name
  }

  # This identity is used by an external client via an out-of-band kubeconfig;
  # it is never mounted into a Pod, so disable token automount.
  automount_service_account_token = false
}

resource "kubernetes_role_v1" "omnivise_iot_deployer" {
  metadata {
    name      = "omnivise-iot-deployer"
    namespace = module.omnivise_iot.namespace_name
  }

  rule {
    api_groups = [""]
    resources  = ["services"]
    verbs      = ["get", "create", "patch", "delete"]
  }

  rule {
    api_groups = [""]
    resources  = ["configmaps"]
    verbs      = ["get", "create", "patch", "delete"]
  }

  rule {
    api_groups = ["apps"]
    resources  = ["deployments"]
    verbs      = ["get", "create", "patch", "delete"]
  }

  rule {
    api_groups = ["apps"]
    resources  = ["statefulsets"]
    verbs      = ["get", "create", "patch", "delete"]
  }

  rule {
    api_groups = ["batch"]
    resources  = ["jobs"]
    verbs      = ["get", "create", "patch", "delete"]
  }

  rule {
    api_groups = ["traefik.io"]
    resources  = ["ingressroutes"]
    verbs      = ["get", "create", "patch", "delete"]
  }
}

resource "kubernetes_role_binding_v1" "omnivise_iot_deployer" {
  metadata {
    name      = "omnivise-iot-deployer"
    namespace = module.omnivise_iot.namespace_name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.omnivise_iot_deployer.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.omnivise_iot_deployer.metadata[0].name
    namespace = module.omnivise_iot.namespace_name
  }
}

# --- Cluster-scoped reads (RBAC_SCOPE_REVIEW_REQUIRED, approved) ----------------
#
# OmniVise's Terraform needs two cluster-scoped reads to plan/apply as this
# identity. Both are read-only; a namespaced Role cannot grant either. There is
# no cluster-scoped write, no `watch`, and no access beyond what is listed.
#
# 1. get on Namespace/omnivise-iot. `data "kubernetes_namespace_v1"` reads the
#    cluster-scoped Namespace object. Restricted by resourceNames to the single
#    `omnivise-iot` namespace -- no `list`, no `watch`, no `get` on any other
#    namespace.
#
# 2. list on customresourcedefinitions.apiextensions.k8s.io. The
#    hashicorp/kubernetes v3.2.1 `kubernetes_manifest` resource (the Traefik
#    IngressRoute) unconditionally lists every CRD cluster-wide during schema /
#    type resolution on every plan, read and apply (manifest/provider fetchCRDs
#    -> RESTMappings + Resource(crd).List()); a `forbidden` there fails the
#    operation with no fallback. The RBAC `list` verb ignores resourceNames, so
#    this cannot be name-restricted. It is a read: no `get` past the list, no
#    `watch`, no CRD write, no other apiextensions.k8s.io verb.
#
# Both grants are bound to exactly the `omnivise-iot-deployer` ServiceAccount
# via the ClusterRoleBinding below. Operator-approved; see
# docs/omnivise-iot-deployer-runbook.md.

resource "kubernetes_cluster_role_v1" "omnivise_iot_deployer_cluster_read" {
  metadata {
    name = "omnivise-iot-deployer-cluster-read"
  }

  rule {
    api_groups     = [""]
    resources      = ["namespaces"]
    resource_names = ["omnivise-iot"]
    verbs          = ["get"]
  }

  rule {
    api_groups = ["apiextensions.k8s.io"]
    resources  = ["customresourcedefinitions"]
    verbs      = ["list"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "omnivise_iot_deployer_cluster_read" {
  metadata {
    name = "omnivise-iot-deployer-cluster-read"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.omnivise_iot_deployer_cluster_read.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.omnivise_iot_deployer.metadata[0].name
    namespace = module.omnivise_iot.namespace_name
  }
}

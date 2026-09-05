# HomeOps platform onboarding runbook

Issue #38 adds only the platform prerequisites for HomeOps. The
`homelab-platform` HCP workspace owns the `homeops` Namespace, ResourceQuota,
runtime observer identity, Jenkins deployer identity, and their RBAC. The
separate HomeOps repository owns the backend, frontend, images, Deployments,
Services, Traefik IngressRoute, CI, Jenkinsfile, and application Terraform.

## Verification status

**Implemented and live-verified.** Issue #38 was applied against the existing
HCP Terraform `homelab-platform` workspace from a reviewed saved plan: `10 to
add, 0 to change, 0 to destroy`. Apply completed with `10 added, 0 changed, 0
destroyed`, and the post-apply plan reported no changes.

Live Kubernetes verification confirmed that the `homeops` Namespace,
`homeops-quota`, `homeops-observer` ServiceAccount, and `homeops-deployer`
ServiceAccount exist. The quota matches the four limits below, and every
observer and deployer allow/deny check in the RBAC matrix passed. Local
`homeops.homelab.home.arpa` name resolution was also verified through the
operator-managed `/etc/hosts` entry documented below. Credential handoff was
not part of this verification.

## Platform resources

| Object | Scope | Purpose |
| --- | --- | --- |
| `homeops` Namespace | cluster | Project isolation, through `module.homeops` |
| `homeops-quota` ResourceQuota | `homeops` | CPU/memory allocation, through `module.homeops` |
| `homeops-observer` ServiceAccount | `homeops` | HomeOps backend runtime identity |
| `homeops-observer` ClusterRole | cluster | Purpose-built, read-only observability permissions |
| `homeops-observer` ClusterRoleBinding | cluster | Binds only `system:serviceaccount:homeops:homeops-observer` |
| `homeops-deployer` ServiceAccount | `homeops` | External Jenkins deployment identity |
| `homeops-deployer` Role | `homeops` | HomeOps workload deployment permissions |
| `homeops-deployer` RoleBinding | `homeops` | Binds only `system:serviceaccount:homeops:homeops-deployer` |
| `homeops-deployer-cluster-read` ClusterRole | cluster | Two provider-required cluster reads |
| `homeops-deployer-cluster-read` ClusterRoleBinding | cluster | Binds only `system:serviceaccount:homeops:homeops-deployer` |

The ResourceQuota hard limits are exactly:

```text
requests.cpu    = 500m
limits.cpu      = 1
requests.memory = 512Mi
limits.memory   = 1Gi
```

HomeOps workloads must declare requests and limits that fit within this quota.
No application workload is declared by the platform Terraform.

## Runtime observer

`homeops-observer` is intended to be assigned only to the future HomeOps
backend. Standard in-cluster ServiceAccount authentication is enabled;
Terraform creates no token Secret or kubeconfig for it. It is not bound to any
deployment Role.

Its ClusterRole contains exactly these rules:

| API group | Resource | Verbs |
| --- | --- | --- |
| core (`""`) | `namespaces` | `get`, `list` |
| core (`""`) | `pods` | `get`, `list` |
| core (`""`) | `pods/log` | `get` |
| `apps` | `deployments` | `get`, `list` |

It has no write verb, wildcard, `watch`, Secret access, node access, event
access, storage access, service access, IngressRoute access, or RBAC access.

## Jenkins deployer

`homeops-deployer` is a separate external deployment identity. Its
ServiceAccount has token automount disabled. In the `homeops` namespace only,
its Role grants:

| API group | Resource | Verbs |
| --- | --- | --- |
| core (`""`) | `services` | `get`, `create`, `patch`, `delete` |
| `apps` | `deployments` | `get`, `create`, `patch`, `delete` |
| `traefik.io` | `ingressroutes` | `get`, `create`, `patch`, `delete` |

These are the provider operations already established by the platform's
`hashicorp/kubernetes` 3.2.1 deployment pattern. Service and Deployment updates
use JSON Patch. `kubernetes_manifest` uses Server-Side Apply for the
IngressRoute; creating an absent object requires both `create` and `patch`.
There is no demonstrated requirement for `update`, `list`, or `watch` on these
workload resources.

The deployer has no permission on Secrets, ConfigMaps, Pods, PVCs,
ServiceAccounts, Roles, RoleBindings, or resources in another namespace.

### Required cluster reads

A namespaced Role cannot grant the two reads required by the existing
application Terraform/provider pattern:

1. `get` on core `namespaces`, restricted by `resourceNames: ["homeops"]`.
   This supports the expected `data.kubernetes_namespace_v1` lookup without
   allowing namespace `list`, `watch`, or access to another named Namespace.
2. `list` on `customresourcedefinitions.apiextensions.k8s.io`.
   `kubernetes_manifest` 3.2.1 unconditionally lists CRDs during schema
   discovery and fails if denied. Kubernetes RBAC cannot name-restrict a
   `list`, so this is the only grant broader than one named object. It is still
   read-only: no CRD `get`, `watch`, or write verb is granted.

No permission differs from issue #38. The CRD `list` is the issue-approved
exception required by the existing provider pattern. There is no cluster-scoped
write permission.

## Repository-local validation

These commands do not initialize the HCP backend, contact k3s, or apply
resources:

```sh
terraform fmt -check -recursive
bash terraform/platform/validate.sh
bash terraform/modules/namespace-resourcequota/plan-check.sh
git diff --check
```

The module plan check uses a synthetic, non-functional kubeconfig and validates
the reusable module contract, not the real `module.homeops` instance.

## Gated live workflow

This operator procedure was completed for issue #38. It mutates HCP state and
the cluster, so future applies still require separate explicit approval.

Keep issue-scoped changes isolated. If a future HomeOps plan contains any
HomeStreamLab create, update, delete, or replace, stop; do not combine the two
issues in one apply.

1. Confirm the `homelab-platform` HCP workspace is in Local execution mode.
2. Initialize with the operator's `TF_CLOUD_ORGANIZATION` and local
   `terraform.tfvars`.
3. Save a full plan outside the repository in a mode `0700` scratch directory.
4. Render it with `terraform show -json` and inspect the JSON with `jq`.
5. Fail closed unless the only non-`no-op` actions are exactly 10 creates:

```text
module.homeops.kubernetes_namespace_v1.this
module.homeops.kubernetes_resource_quota_v1.this
kubernetes_service_account_v1.homeops_observer
kubernetes_cluster_role_v1.homeops_observer
kubernetes_cluster_role_binding_v1.homeops_observer
kubernetes_service_account_v1.homeops_deployer
kubernetes_role_v1.homeops_deployer
kubernetes_role_binding_v1.homeops_deployer
kubernetes_cluster_role_v1.homeops_deployer_cluster_read
kubernetes_cluster_role_binding_v1.homeops_deployer_cluster_read
```

6. Confirm the quota and every RBAC rule exactly match this runbook; confirm
   there is no wildcard and no HomeOps Deployment, Service, IngressRoute,
   Secret, token, kubeconfig, or Jenkins credential in the plan.
7. Confirm every existing `module.homestreamlab.*` and HomeStreamLab identity
   resource is `no-op`; otherwise the prerequisite above is not satisfied.
8. Obtain separate apply approval, apply the exact reviewed plan artifact, run
   the checks below, then require a convergence plan with zero non-`no-op`
   actions.

Recorded result: the saved plan reported `10 to add, 0 to change, 0 to
destroy`; apply reported `10 added, 0 changed, 0 destroyed`; the post-apply
plan reported no changes.

## RBAC verification matrix

Run after a live apply with an administrator authorized to impersonate both
ServiceAccounts. These checks query authorization only and do not mutate or
read resource contents. Do not replace them with `kubectl auth can-i --list`.

```sh
OBSERVER_AS='--as=system:serviceaccount:homeops:homeops-observer'
DEPLOYER_AS='--as=system:serviceaccount:homeops:homeops-deployer'
```

### Runtime observer: expected `yes`

```sh
kubectl auth can-i get  namespaces                              $OBSERVER_AS
kubectl auth can-i list namespaces                              $OBSERVER_AS
kubectl auth can-i get  deployments.apps --all-namespaces       $OBSERVER_AS
kubectl auth can-i list deployments.apps --all-namespaces       $OBSERVER_AS
kubectl auth can-i get  pods --all-namespaces                   $OBSERVER_AS
kubectl auth can-i list pods --all-namespaces                   $OBSERVER_AS
kubectl auth can-i get  pods --subresource=log --all-namespaces $OBSERVER_AS
```

### Runtime observer: expected `no`

```sh
kubectl auth can-i watch  deployments.apps --all-namespaces $OBSERVER_AS
kubectl auth can-i create deployments.apps -n homeops        $OBSERVER_AS
kubectl auth can-i patch  deployments.apps -n homeops        $OBSERVER_AS
kubectl auth can-i delete pods -n homeops                     $OBSERVER_AS
kubectl auth can-i get    secrets -n homeops                  $OBSERVER_AS
kubectl auth can-i create services -n homeops                 $OBSERVER_AS
kubectl auth can-i get    nodes                               $OBSERVER_AS
kubectl auth can-i get    configmaps -n homeops               $OBSERVER_AS
kubectl auth can-i get    persistentvolumeclaims -n homeops   $OBSERVER_AS
kubectl auth can-i create roles.rbac.authorization.k8s.io -n homeops $OBSERVER_AS
kubectl auth can-i create clusterroles.rbac.authorization.k8s.io     $OBSERVER_AS
```

### Jenkins deployer: expected `yes`

```sh
kubectl auth can-i get    services                 -n homeops $DEPLOYER_AS
kubectl auth can-i create services                 -n homeops $DEPLOYER_AS
kubectl auth can-i patch  services                 -n homeops $DEPLOYER_AS
kubectl auth can-i delete services                 -n homeops $DEPLOYER_AS
kubectl auth can-i get    deployments.apps         -n homeops $DEPLOYER_AS
kubectl auth can-i create deployments.apps         -n homeops $DEPLOYER_AS
kubectl auth can-i patch  deployments.apps         -n homeops $DEPLOYER_AS
kubectl auth can-i delete deployments.apps         -n homeops $DEPLOYER_AS
kubectl auth can-i get    ingressroutes.traefik.io -n homeops $DEPLOYER_AS
kubectl auth can-i create ingressroutes.traefik.io -n homeops $DEPLOYER_AS
kubectl auth can-i patch  ingressroutes.traefik.io -n homeops $DEPLOYER_AS
kubectl auth can-i delete ingressroutes.traefik.io -n homeops $DEPLOYER_AS
kubectl auth can-i get    namespace homeops                  $DEPLOYER_AS
kubectl auth can-i list   customresourcedefinitions.apiextensions.k8s.io $DEPLOYER_AS
```

### Jenkins deployer: expected `no`

```sh
kubectl auth can-i create deployments.apps -n homestreamlab $DEPLOYER_AS
kubectl auth can-i list   namespaces                          $DEPLOYER_AS
kubectl auth can-i watch  namespaces                          $DEPLOYER_AS
kubectl auth can-i get    namespace homestreamlab             $DEPLOYER_AS
kubectl auth can-i get    secrets -n homeops                  $DEPLOYER_AS
kubectl auth can-i list   secrets -n homeops                  $DEPLOYER_AS
kubectl auth can-i get    pods -n homeops                     $DEPLOYER_AS
kubectl auth can-i list   deployments.apps --all-namespaces   $DEPLOYER_AS
kubectl auth can-i update services -n homeops                 $DEPLOYER_AS
kubectl auth can-i list   services -n homeops                 $DEPLOYER_AS
kubectl auth can-i watch  services -n homeops                 $DEPLOYER_AS
kubectl auth can-i update deployments.apps -n homeops         $DEPLOYER_AS
kubectl auth can-i list   deployments.apps -n homeops         $DEPLOYER_AS
kubectl auth can-i watch  deployments.apps -n homeops         $DEPLOYER_AS
kubectl auth can-i update ingressroutes.traefik.io -n homeops $DEPLOYER_AS
kubectl auth can-i list   ingressroutes.traefik.io -n homeops $DEPLOYER_AS
kubectl auth can-i watch  ingressroutes.traefik.io -n homeops $DEPLOYER_AS
kubectl auth can-i create roles.rbac.authorization.k8s.io -n homeops $DEPLOYER_AS
kubectl auth can-i create clusterroles.rbac.authorization.k8s.io     $DEPLOYER_AS
kubectl auth can-i create namespaces                                $DEPLOYER_AS
kubectl auth can-i get    customresourcedefinitions.apiextensions.k8s.io $DEPLOYER_AS
kubectl auth can-i watch  customresourcedefinitions.apiextensions.k8s.io $DEPLOYER_AS
kubectl auth can-i create customresourcedefinitions.apiextensions.k8s.io $DEPLOYER_AS
```

Also verify the Namespace, quota, and absence of platform-created workloads:

```sh
kubectl get namespace homeops
kubectl get resourcequota homeops-quota -n homeops -o yaml
kubectl get deployments.apps,services,ingressroutes.traefik.io -n homeops
```

## Jenkins credential handoff

Terraform does not create a ServiceAccount token Secret, kubeconfig, or Jenkins
credential. After apply and RBAC verification, an operator follows the same
process documented for HomeStreamLab, substituting:

```text
ServiceAccount: homeops-deployer
Namespace:      homeops
Token Secret:   homeops-deployer-token
Kubeconfig:     k3s-homeops.kubeconfig
Jenkins ID:     k3s-homeops
API endpoint:   https://<HOST_LAN_IP>:6443
```

The operator issues dedicated credential material for only this ServiceAccount,
embeds the cluster CA with normal TLS verification, sets the kubeconfig's
default namespace to `homeops`, verifies the matrix without impersonation, and
delivers it as a Jenkins Secret File over a secure channel. Never use the host
administrator kubeconfig, `cluster-admin`, `insecure-skip-tls-verify`, a
host-only certificate path, Terraform state/variables/outputs, or Git. Destroy
the temporary kubeconfig after handoff. Token issuance and rotation remain
operator responsibilities; deleting and reissuing the dedicated token revokes
the old credential without changing Terraform-managed RBAC.

See [`homestreamlab-deployer-runbook.md`](./homestreamlab-deployer-runbook.md#credential-handoff-operator-managed)
for the existing command-level operator procedure.

## Name resolution

There is no wildcard DNS covering HomeOps on this workstation. Local name
resolution is operator-managed through `/etc/hosts`; Terraform does not manage
this entry. The verified local entry is:

```text
192.168.1.197 homeops.homelab.home.arpa
```

This verifies name resolution only; the HomeOps repository must deploy the
IngressRoute before HTTP routing can work.

## Rollback

Removing `module.homeops` deletes the Namespace and therefore every namespaced
HomeOps object. Before rollback, stop and inventory the namespace. If an
application has ever been deployed, coordinate its decommission from the
HomeOps repository first. Revert the three issue #38 Terraform additions, run a
full untargeted plan, and require exactly the 10 expected deletes with no other
non-`no-op` action before separate apply approval. Never use a broad
`terraform destroy` as routine rollback. Delete any operator-managed deployer
token separately; it is not in Terraform state.

# OmniVise IoT deployer identity runbook

The platform-owned Kubernetes **deployment identity** for the OmniVise IoT
Project: a dedicated `ServiceAccount`, a namespace-scoped `Role` + `RoleBinding`,
and one narrow cluster-scoped read exception, all in / around the existing
`omnivise-iot` namespace. Terraform
(`terraform/platform/omnivise-iot-deployer.tf`, the `homelab-platform` HCP
workspace) owns these objects. A later OmniVise deployment issue registers a
`k3s-omnivise-iot` credential that consumes this identity through an
operator-built kubeconfig — never the host administrator kubeconfig, never
cluster-admin.

This repository owns the identity, its RBAC, the approved exception, and the
credential/kubeconfig **procedure**. It does not own token issuance, the
kubeconfig file itself, or any Jenkins configuration. `k3s-omnivise-iot` is only
a future consumer credential-name contract; this issue creates no Jenkins
credential and does not modify Jenkins or `local-jenkins-platform`.

## Verification status

**Implemented, live-applied and verified.** Repo-local validation passes
(`bash terraform/platform/validate.sh`,
`terraform -chdir=terraform fmt -check -recursive`,
`bash terraform/modules/namespace-resourcequota/plan-check.sh`). The
provider-source audit below was completed against `hashicorp/kubernetes`
`v3.2.1` (the version both this repo and OmniVise pin).

**Gate 1 — platform Terraform apply (completed).** Prerequisites re-verified
read-only first: Namespace `omnivise-iot` `Active`; ResourceQuota
`omnivise-iot-quota` `spec.hard` = `requests.cpu=1`, `limits.cpu=2`,
`requests.memory=2Gi`, `limits.memory=4Gi` (the approved #41 allocation); HCP
workspace `homelab-platform` Execution Mode `local`, unlocked. `terraform init`
reported success with `.terraform.lock.hcl` unchanged. The reviewed saved plan
(`Plan: 5 to add, 0 to change, 0 to destroy`) passed the strict `jq` gate —
exactly 5 non-`no-op` `resource_changes`, all `["create"]`, addresses exactly
the ServiceAccount, Role, RoleBinding, ClusterRole and ClusterRoleBinding; no
create/update/delete/replace on any other resource (all 19 pre-existing
resources, HomeStreamLab #31 and HomeOps #38 identities included, refreshed as
`no-op`); no wildcard; SA `automount_service_account_token = false`; Role and
ClusterRole rules exactly the least-privilege matrix below. The reported
`resource_drift` on `module.omnivise_iot` (and, post-apply, on the five new
objects) is `hashicorp/kubernetes` 3.2.1 refresh serialization normalization
(`null` → `{}` / `[]` for empty `labels`/`annotations`/`resource_names`); it
alters no `spec.hard` or RBAC rule value, changes no `resource_version`, and
produces no planned action. `terraform apply` of the exact saved plan reported
`Apply complete! Resources: 5 added, 0 changed, 0 destroyed`. The post-apply
convergence plan reported `No changes. Your infrastructure matches the
configuration.` with zero non-`no-op` `resource_changes`.

**Gate 1 RBAC matrix (impersonation, `--as`): all pass.** 21/21 positive checks
`yes`, 32/32 negative checks `no`, matching the
[RBAC verification matrix](#rbac-verification-matrix) below. Live objects
confirmed: `sa/omnivise-iot-deployer` `automountServiceAccountToken: false`;
`role/omnivise-iot-deployer` five rules each `[get,create,patch,delete]` on
`services` / `deployments.apps` / `statefulsets.apps` / `jobs.batch` /
`ingressroutes.traefik.io`; `clusterrole/omnivise-iot-deployer-cluster-read`
`get namespaces` (`resourceNames: [omnivise-iot]`) + `list
customresourcedefinitions`; both bindings target only
`ServiceAccount omnivise-iot/omnivise-iot-deployer`.

**Gate 2 — operator credential issuance (completed).** An operator-managed
`Secret/omnivise-iot-deployer-token` (`kubernetes.io/service-account-token`) was
created in `omnivise-iot` outside Terraform (not in state). One self-contained
kubeconfig was issued: cluster `homelab-k3s` at the LAN API endpoint with the
embedded cluster CA and normal TLS, user + context `omnivise-iot-deployer`,
default namespace `omnivise-iot`. Verified with that kubeconfig only (no
`--as`): current context `omnivise-iot-deployer`; default namespace
`omnivise-iot`; `kubectl auth whoami` →
`system:serviceaccount:omnivise-iot:omnivise-iot-deployer` (UID matching the SA
token); normal-TLS reachability OK; 22/22 positive authorization checks `yes`;
33/33 negative checks `no`. The kubeconfig was handed off to the operator
credential store outside this repository (reserved for later `#40` consumption
under the `k3s-omnivise-iot` name contract); no Jenkins credential was created
and `local-jenkins-platform` was not modified. Temporary credential-generation
material was securely removed (`shred -u` + `rm -rf`). No token, kubeconfig,
Secret material, host-specific value, Terraform plan or state is committed.

## Pre-implementation audit (issue #42)

### OmniVise Terraform-managed Kubernetes resource set

Audited on `omnivise-iot` `main` after `omnivise-iot#39`, under `infra/`:

| Terraform | Kubernetes object | Scope |
| --- | --- | --- |
| `data.kubernetes_namespace_v1.application` | `Namespace/omnivise-iot` (read) | cluster |
| `kubernetes_service_v1.mongodb` / `.backend` / `.frontend` | core `services` (ClusterIP) | `omnivise-iot` |
| `kubernetes_stateful_set_v1.mongodb` | `apps/statefulsets` | `omnivise-iot` |
| `kubernetes_job_v1.mongodb_bootstrap` | `batch/jobs` | `omnivise-iot` |
| `kubernetes_deployment_v1.backend` / `.frontend` / `.sensor_simulator` | `apps/deployments` | `omnivise-iot` |
| `kubernetes_manifest.frontend_ingressroute` | `traefik.io/ingressroutes` (SSA) | `omnivise-iot` |

No other managed Kubernetes resource exists in the OmniVise application
Terraform. There is **no** `kubernetes_secret_v1`, `kubernetes_config_map_v1`,
`kubernetes_persistent_volume_claim_v1`, `kubernetes_service_account_v1`, or RBAC
resource. The MongoDB PVC is produced by the StatefulSet controller from
`volumeClaimTemplates`; the bootstrap Pod is produced by the Job controller —
neither is created by this deployment identity.

If a future OmniVise change adds a managed Kubernetes resource outside this set,
stop and reassess the permission matrix before widening this Role/ClusterRole.

### Pinned provider

`omnivise-iot/infra/homelab/.terraform.lock.hcl` pins
`hashicorp/kubernetes` **3.2.1**, byte-identical to this repo's
`terraform/platform/.terraform.lock.hcl`. This issue introduces no new provider,
so the platform lock file does not change.

## What Terraform manages

| Object | Kind | Scope |
| --- | --- | --- |
| `omnivise-iot-deployer` | `ServiceAccount` | `omnivise-iot` namespace, `automount_service_account_token = false` |
| `omnivise-iot-deployer` | `Role` | `omnivise-iot` namespace |
| `omnivise-iot-deployer` | `RoleBinding` | `omnivise-iot` namespace → binds the SA to the Role |
| `omnivise-iot-deployer-cluster-read` | `ClusterRole` | cluster; rule 1 — `get` on `namespaces`, `resourceNames: ["omnivise-iot"]`; rule 2 — `list` on `customresourcedefinitions` (`apiextensions.k8s.io`) |
| `omnivise-iot-deployer-cluster-read` | `ClusterRoleBinding` | cluster → binds the SA to that ClusterRole |

Terraform does **not** manage: the ServiceAccount token, any `Secret`, or the
kubeconfig. Those are operator actions (below) and must never enter Terraform
state, variables, or outputs, or be committed to Git.

The `omnivise-iot` `Namespace` and its `ResourceQuota` are owned by
`module.omnivise_iot` (issue #41). This identity only references the namespace
name via that module's `namespace_name` output; it never recreates or modifies
the Namespace or ResourceQuota.

## Why these permissions, and only these

Derived from the resource set above, provider `hashicorp/kubernetes` `3.2.1`,
cross-checked against the provider source at tag `v3.2.1`
(`kubernetes/resource_kubernetes_service_v1.go`,
`…_deployment_v1.go`, `…_stateful_set_v1.go`, `…_job_v1.go`,
`manifest/provider/resource.go`).

| OmniVise Terraform | API group / resource | Scope | Provider lifecycle (v3.2.1) | Granted verbs |
| --- | --- | --- | --- | --- |
| `data.kubernetes_namespace_v1.application` | core / `namespaces` | cluster | `Namespaces().Get(name)` only | `get` (name-restricted, ClusterRole) |
| `kubernetes_service_v1.{mongodb,backend,frontend}` | core / `services` | `omnivise-iot` | `Create()` / `Get()` / `Patch(JSONPatchType)` / `Delete()` + `Get()` delete-poll; all ClusterIP → the LoadBalancer wait never runs, `endpoints` / `endpointslices` never touched | `get, create, patch, delete` |
| `kubernetes_deployment_v1.{backend,frontend,sensor_simulator}` | `apps` / `deployments` | `omnivise-iot` | `Create()` / `Get()` / `Patch(JSONPatchType)` / `Delete()` + `Get()` delete-poll; `wait_for_rollout = false` → no rollout poll; pods / replicasets / `deployments/status` never touched | `get, create, patch, delete` |
| `kubernetes_stateful_set_v1.mongodb` | `apps` / `statefulsets` | `omnivise-iot` | `Create()` / `Get()` / `Patch(JSONPatchType)` / `Delete()` + `Get()` delete-poll; `wait_for_rollout = false` → no rollout poll; pods / PVCs / controllerrevisions never touched | `get, create, patch, delete` |
| `kubernetes_job_v1.mongodb_bootstrap` | `batch` / `jobs` | `omnivise-iot` | `Create()` / `Get()` / `Patch(JSONPatchType)` / `Delete()` + `Get()` delete-poll; `wait_for_completion = true` polls the **Job object** via `BatchV1().Jobs(ns).Get()` for status conditions — no `list`, no `watch`, the bootstrap Pod is never touched | `get, create, patch, delete` |
| `kubernetes_manifest.frontend_ingressroute` | `traefik.io` / `ingressroutes` | `omnivise-iot` | Server-Side Apply: `Patch(ApplyPatchType)` for create+update, `Get()` for read, `Delete()` for destroy. SSA that creates an absent object is authorized as `create` + `patch` | `get, create, patch, delete` |
| `kubernetes_manifest.frontend_ingressroute` (schema resolution) | `apiextensions.k8s.io` / `customresourcedefinitions` | cluster | `fetchCRDs` → `RESTMappings` + `Resource(crd).List()` on every plan/read/apply, no fallback if denied | `list` (ClusterRole; cannot be name-restricted) |

Deliberately **not** granted:

- `update` — every workload update path calls `Patch(JSONPatchType)`, and the
  IngressRoute uses Server-Side Apply (`Patch(ApplyPatchType)`); no path calls
  `Update()`.
- `list`, `watch` on any namespaced workload resource — no lifecycle path calls
  them. `wait_for_rollout = false` on the Deployments and the StatefulSet;
  `wait_for_completion` polls the Job object with `Get()` only; every Service is
  ClusterIP (no LoadBalancer wait); `kubernetes_manifest` has no `wait` block.
- any verb on `pods`, `pods/log`, `replicasets`, `endpoints`,
  `endpointslices`, `persistentvolumeclaims`, `configmaps`, `secrets`,
  `serviceaccounts`, `roles`, `rolebindings`, `resourcequotas`, `events`,
  `leases`, `daemonsets`, `cronjobs`, `ingresses` (`networking.k8s.io`),
  `networkpolicies`, `horizontalpodautoscalers`, `poddisruptionbudgets`,
  `nodes`. The PVC is created by the StatefulSet controller and the bootstrap
  Pod by the Job controller — persistent storage and a bootstrap Job do not
  justify PVC or Pod verbs for the external deployment identity.
- any **write** on `customresourcedefinitions`, and any `apiextensions.k8s.io`
  verb other than the single `list`. CRDs stay platform-owned.
- any wildcard (`*`) group / resource / verb.
- any cluster-scoped write, `kube-system` access, RBAC-object write, namespace
  `list` / `watch` / write, or cross-namespace access.

### The cluster-scoped reads (RBAC_SCOPE_REVIEW_REQUIRED)

Two cluster-scoped **reads** are unavoidable — a namespaced `Role` cannot grant
either. Both are the narrowest grants that satisfy the provider, bound to only
the `omnivise-iot-deployer` ServiceAccount. Neither grants any write.

1. OmniVise's `data "kubernetes_namespace_v1" "application"` reads the
   cluster-scoped object `Namespace/omnivise-iot`:

   ```text
   apiGroups:     [""]
   resources:     ["namespaces"]
   resourceNames: ["omnivise-iot"]
   verbs:         ["get"]
   ```

   No `list` / `watch` on namespaces, no `get` on any other namespace.

2. `hashicorp/kubernetes` `v3.2.1` `kubernetes_manifest` (the Traefik
   IngressRoute) unconditionally **lists every CRD in the cluster** during
   schema/type resolution on every plan, read and apply
   (`manifest/provider/resource.go`: `fetchCRDs`), and fails the operation with
   no fallback if that `list` is denied:

   ```text
   apiGroups: ["apiextensions.k8s.io"]
   resources: ["customresourcedefinitions"]
   verbs:     ["list"]
   ```

   The RBAC `list` verb ignores `resourceNames`, so this cannot be
   name-restricted. Read-only: no `get` past the `list`, no `watch`, no CRD
   write, no other `apiextensions.k8s.io` verb. This identity never creates,
   updates or deletes a CRD.

Repository conventions do not require an ADR for an issue-scoped RBAC exception;
this section is its record.

## Apply workflow

Host-level (mutates the cluster and HCP state) — follow the same gated procedure
as the
[`homestreamlab` namespace instantiation](./terraform-runbook.md#homestreamlab-namespace-instantiation-issue-8).

**Prerequisite (Gate 1a):** `homelab-platform#41` is already applied and the live
`omnivise-iot` Namespace + `omnivise-iot-quota` ResourceQuota exist
independently of this change:

```sh
kubectl get namespace omnivise-iot
kubectl get resourcequota -n omnivise-iot
```

Only then:

1. `bash terraform/platform/validate.sh` — repo-local, must pass.
2. Confirm the `homelab-platform` HCP workspace is **Execution Mode = Local** in
   the UI immediately beforehand.
3. `export TF_CLOUD_ORGANIZATION=<your-hcp-organization>` and
   `terraform -chdir=terraform/platform init -input=false`; confirm
   `.terraform.lock.hcl` is unchanged (no new providers are introduced).
4. Save a plan to a scratch dir **outside** the repository (mode `0700`):
   `terraform -chdir=terraform/platform plan -input=false -out="$SCRATCH/omnivise-deployer.tfplan"`
   then `terraform -chdir=terraform/platform show -json "$SCRATCH/omnivise-deployer.tfplan" > "$SCRATCH/omnivise-deployer-plan.json"`.
5. **Plan gate** — assert with `jq` on the JSON (not the human summary). Terraform
   plan JSON can list unchanged resources as `["no-op"]`, so filter before
   counting:
   - `CHANGING = [ .resource_changes[] | select(.change.actions != ["no-op"]) ]`;
   - `CHANGING | length == 5`, every entry `.change.actions == ["create"]`,
     addresses exactly
     `kubernetes_service_account_v1.omnivise_iot_deployer`,
     `kubernetes_role_v1.omnivise_iot_deployer`,
     `kubernetes_role_binding_v1.omnivise_iot_deployer`,
     `kubernetes_cluster_role_v1.omnivise_iot_deployer_cluster_read`,
     `kubernetes_cluster_role_binding_v1.omnivise_iot_deployer_cluster_read`;
   - no other resource has a non-`no-op` action —
     `[ .resource_changes[] | select(.change.actions != ["no-op"]) | select((.address | startswith("kubernetes_") and (.address | test("omnivise_iot_deployer"))) | not) ] | length == 0`;
     in particular no `module.homestreamlab.*`, `module.homeops.*`,
     `module.omnivise_iot.*`, `homestreamlab-deployer`, `homeops-deployer` or
     `homeops-observer` entry is create/update/delete/replace. An unchanged
     resource that Terraform omits from `resource_changes` entirely is fine; a
     resource present with a non-`no-op` action is a hard STOP.
   - the SA's `automount_service_account_token` is `false`;
   - the Role has exactly five rules — `services` (core), `deployments` (`apps`),
     `statefulsets` (`apps`), `jobs` (`batch`), `ingressroutes` (`traefik.io`) —
     each `["get","create","patch","delete"]` and nothing else (no `update`,
     `list`, `watch`);
   - the ClusterRole has exactly two rules — `namespaces` +
     `resource_names ["omnivise-iot"]` + `verbs ["get"]`, and
     `customresourcedefinitions` (`apiextensions.k8s.io`) + `verbs ["list"]`
     (no `resource_names`, no other verb);
   - no wildcard `*` anywhere.
6. Separate, explicit operator approval of the apply (Gate 1).
7. `terraform -chdir=terraform/platform apply "$SCRATCH/omnivise-deployer.tfplan"`
   — the exact reviewed artifact. Then delete `$SCRATCH`.
8. Run the RBAC verification matrix (below).
9. Convergence: `terraform -chdir=terraform/platform plan`. Authoritative check —
   the plan JSON has **zero** `resource_changes` with
   `.change.actions != ["no-op"]`. The human `No changes.` line is supporting
   evidence only.

## RBAC verification matrix

Non-mutating, impersonation-based. No resources are created/updated/deleted and
no Secret contents are read.

```sh
AS='--as=system:serviceaccount:omnivise-iot:omnivise-iot-deployer'
```

### Positive — every check must print `yes`

```sh
kubectl auth can-i get    services                 -n omnivise-iot $AS
kubectl auth can-i create services                 -n omnivise-iot $AS
kubectl auth can-i patch  services                 -n omnivise-iot $AS
kubectl auth can-i delete services                 -n omnivise-iot $AS
kubectl auth can-i get    deployments.apps         -n omnivise-iot $AS
kubectl auth can-i create deployments.apps         -n omnivise-iot $AS
kubectl auth can-i patch  deployments.apps         -n omnivise-iot $AS
kubectl auth can-i delete deployments.apps         -n omnivise-iot $AS
kubectl auth can-i get    statefulsets.apps        -n omnivise-iot $AS
kubectl auth can-i create statefulsets.apps        -n omnivise-iot $AS
kubectl auth can-i patch  statefulsets.apps        -n omnivise-iot $AS
kubectl auth can-i delete statefulsets.apps        -n omnivise-iot $AS
kubectl auth can-i get    jobs.batch               -n omnivise-iot $AS
kubectl auth can-i create jobs.batch               -n omnivise-iot $AS
kubectl auth can-i patch  jobs.batch               -n omnivise-iot $AS
kubectl auth can-i delete jobs.batch               -n omnivise-iot $AS
kubectl auth can-i get    ingressroutes.traefik.io -n omnivise-iot $AS
kubectl auth can-i create ingressroutes.traefik.io -n omnivise-iot $AS
kubectl auth can-i patch  ingressroutes.traefik.io -n omnivise-iot $AS
kubectl auth can-i delete ingressroutes.traefik.io -n omnivise-iot $AS
kubectl auth can-i get    namespace omnivise-iot                   $AS
kubectl auth can-i list   customresourcedefinitions.apiextensions.k8s.io    $AS
```

### Negative — every check must print `no`

```sh
kubectl auth can-i list   services                 -n omnivise-iot $AS
kubectl auth can-i watch  services                 -n omnivise-iot $AS
kubectl auth can-i update services                 -n omnivise-iot $AS
kubectl auth can-i list   deployments.apps         -n omnivise-iot $AS
kubectl auth can-i watch  deployments.apps         -n omnivise-iot $AS
kubectl auth can-i update deployments.apps         -n omnivise-iot $AS
kubectl auth can-i list   statefulsets.apps        -n omnivise-iot $AS
kubectl auth can-i watch  statefulsets.apps        -n omnivise-iot $AS
kubectl auth can-i update statefulsets.apps        -n omnivise-iot $AS
kubectl auth can-i list   jobs.batch               -n omnivise-iot $AS
kubectl auth can-i watch  jobs.batch               -n omnivise-iot $AS
kubectl auth can-i update jobs.batch               -n omnivise-iot $AS
kubectl auth can-i list   ingressroutes.traefik.io -n omnivise-iot $AS
kubectl auth can-i watch  ingressroutes.traefik.io -n omnivise-iot $AS
kubectl auth can-i update ingressroutes.traefik.io -n omnivise-iot $AS
kubectl auth can-i get    pods                     -n omnivise-iot $AS
kubectl auth can-i list   pods                     -n omnivise-iot $AS
kubectl auth can-i get    persistentvolumeclaims   -n omnivise-iot $AS
kubectl auth can-i get    secrets                  -n omnivise-iot $AS
kubectl auth can-i get    configmaps               -n omnivise-iot $AS
kubectl auth can-i get    resourcequotas           -n omnivise-iot $AS
kubectl auth can-i create serviceaccounts          -n omnivise-iot $AS
kubectl auth can-i create roles.rbac.authorization.k8s.io -n omnivise-iot $AS
kubectl auth can-i get    customresourcedefinitions.apiextensions.k8s.io $AS
kubectl auth can-i watch  customresourcedefinitions.apiextensions.k8s.io $AS
kubectl auth can-i create customresourcedefinitions.apiextensions.k8s.io $AS
kubectl auth can-i list   namespaces                                     $AS
kubectl auth can-i watch  namespaces                                     $AS
kubectl auth can-i delete namespace omnivise-iot                         $AS
kubectl auth can-i get    namespace homestreamlab                        $AS
kubectl auth can-i get    namespace kube-system                          $AS
kubectl auth can-i create deployments.apps -n default                    $AS
```

Do not use `kubectl auth can-i --list` as the check — run the explicit matrix so
each granted and each withheld permission is individually asserted.

If the provider-source audit ever demonstrates that one of these expected
negatives is genuinely required by a real OmniVise Terraform operation, update
the matrix narrowly, document the exact provider operation that needs it, and get
fresh approval **before** apply. Do not broaden permissions merely to make a
failing apply succeed — stop and reassess.

## Credential handoff (operator-managed)

Performed **after** the identity exists and the RBAC matrix passes (Gate 2 — a
maintainer must explicitly authorize credential issuance first). Terraform is not
involved. `<HOST_LAN_IP>` is this host's LAN address (the same value used
elsewhere in the platform), never `127.0.0.1`.

### Credential lifetime — deliberate homelab simplification

The Kubernetes-preferred model is short-lived TokenRequest credentials
(`kubectl create token`). This runbook's **primary** procedure instead
provisions a long-lived `kubernetes.io/service-account-token` Secret, because the
eventual downstream consumer is a static credential (`k3s-omnivise-iot`, a later
OmniVise deployment issue) with no rotation automation in this milestone. The
long-lived token is a conscious trade-off: manually managed, manually rotated,
dedicated to `omnivise-iot-deployer` only, never cluster-admin, never committed.
`kubectl create token … --duration=…` is the bounded-lifetime alternative;
rotation is manual either way.

### 1. Identify the ServiceAccount

```sh
kubectl get serviceaccount omnivise-iot-deployer -n omnivise-iot
```

### 2. Issue dedicated credential material (operator, not Terraform)

k3s is Kubernetes ≥1.24, so no token Secret is auto-created. Create one
explicitly — a cluster-side namespaced Secret in `omnivise-iot`, operator-created
and never Terraform-managed or imported into Terraform state:

```sh
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: omnivise-iot-deployer-token
  namespace: omnivise-iot
  annotations:
    kubernetes.io/service-account.name: omnivise-iot-deployer
type: kubernetes.io/service-account-token
EOF

kubectl -n omnivise-iot wait --for=jsonpath='{.data.token}' \
  secret/omnivise-iot-deployer-token --timeout=30s
```

### 3. Extract the token and the cluster CA trust material

The CA comes from the token Secret itself (`ca.crt`) so the resulting kubeconfig
is portable and depends on no host-only path:

```sh
WORK="$(umask 077; mktemp -d)"      # outside the repository

kubectl get secret omnivise-iot-deployer-token -n omnivise-iot \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > "$WORK/k3s-ca.crt"

TOKEN="$(kubectl get secret omnivise-iot-deployer-token -n omnivise-iot \
  -o jsonpath='{.data.token}' | base64 -d)"
```

Do not echo `$TOKEN` or the Secret's `token` field to the terminal, a log, or a
commit.

### 4. Build a self-contained kubeconfig

```sh
KUBECONFIG_OUT="$WORK/k3s-omnivise-iot.kubeconfig"

KUBECONFIG="$KUBECONFIG_OUT" kubectl config set-cluster homelab-k3s \
  --server="https://<HOST_LAN_IP>:6443" \
  --certificate-authority="$WORK/k3s-ca.crt" \
  --embed-certs=true

KUBECONFIG="$KUBECONFIG_OUT" kubectl config set-credentials omnivise-iot-deployer \
  --token="$TOKEN"

KUBECONFIG="$KUBECONFIG_OUT" kubectl config set-context omnivise-iot-deployer \
  --cluster=homelab-k3s \
  --user=omnivise-iot-deployer \
  --namespace=omnivise-iot

KUBECONFIG="$KUBECONFIG_OUT" kubectl config use-context omnivise-iot-deployer
```

The API server is the LAN endpoint `https://<HOST_LAN_IP>:6443`. Do not use
`https://127.0.0.1:6443`, `insecure-skip-tls-verify: true`,
`/etc/rancher/k3s/k3s.yaml`, or any host-only CA / client-certificate path.

### 5. Verify identity, context, namespace and least privilege (no mutation)

```sh
KUBECONFIG="$KUBECONFIG_OUT" kubectl config current-context   # omnivise-iot-deployer
KUBECONFIG="$KUBECONFIG_OUT" kubectl config view --minify \
  -o jsonpath='{.contexts[0].context.namespace}'; echo         # omnivise-iot

# Normal TLS, no verification disabled:
KUBECONFIG="$KUBECONFIG_OUT" kubectl get namespace omnivise-iot -o name

# Then run the full positive + negative RBAC matrix above, replacing
#   kubectl auth can-i ... $AS
# with
#   KUBECONFIG="$KUBECONFIG_OUT" kubectl auth can-i ...
# (no --as: the kubeconfig already IS the deployer identity).
```

Record only non-sensitive results (the `yes`/`no` grid, the context and
namespace). Never print token contents.

### 6. Secure handoff and cleanup

Transfer `k3s-omnivise-iot.kubeconfig` to the approved operator-managed
credential store over a secure channel — not through this repository, not through
chat, not via a commit. It is reserved for later consumption under the
credential-name contract `k3s-omnivise-iot` by a separate OmniVise deployment
issue; **this issue configures no Jenkins credential**. Then destroy the local
working copy:

```sh
rm -rf "$WORK"
```

`.gitignore` already blocks `*.kubeconfig`, `.kube/`, `*.pem`, `*.key`, so the
working material cannot be committed by accident.

### 7. Manual rotation / replacement

```sh
kubectl delete secret omnivise-iot-deployer-token -n omnivise-iot
# re-run steps 2–6
```

The `ServiceAccount`, `Role`, `RoleBinding`, `ClusterRole` and
`ClusterRoleBinding` are unaffected by rotation — only the token Secret and the
kubeconfig are reissued. Revoking the old token is immediate on Secret deletion.

## Rollback

Repository side — revert `terraform/platform/omnivise-iot-deployer.tf`, then run
a full (untargeted) `terraform -chdir=terraform/platform plan`; require the plan
JSON to show **exactly** five deletes (the five objects above) and **zero** other
`resource_changes` with `.change.actions != ["no-op"]`, under a separate explicit
apply approval. The `omnivise-iot` Namespace and ResourceQuota
(`module.omnivise_iot`) are untouched by this.

Operator side — the token Secret is not Terraform-managed, so delete it
separately:

```sh
kubectl delete secret omnivise-iot-deployer-token -n omnivise-iot --ignore-not-found
```

## Scope boundary

This runbook and issue #42 change only `homelab-platform`. OmniVise IoT is
inspected read-only and not modified. `local-jenkins-platform` is not touched —
the `k3s-omnivise-iot` credential, any JCasC wiring, and Jenkins-side
verification belong to a later OmniVise deployment issue in a different repo. No
OmniVise application resource (Deployment, StatefulSet, Job, Service,
IngressRoute, Secret, ConfigMap, PVC, Helm release, Jenkinsfile) is created here.
HomeStreamLab and HomeOps RBAC are unchanged.

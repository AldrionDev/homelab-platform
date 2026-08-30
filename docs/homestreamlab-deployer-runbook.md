# HomeStreamLab deployer identity runbook

The platform-owned Kubernetes **deployment identity** for the HomeStreamLab
Project: a dedicated `ServiceAccount`, a namespace-scoped `Role` + `RoleBinding`,
and one narrow cluster-scoped exception, all in / around the existing
`homestreamlab` namespace. Terraform (`terraform/platform/homestreamlab-deployer.tf`,
the `homelab-platform` HCP workspace) owns these objects. A later
`local-jenkins-platform` J6 credential (`k3s-homestreamlab`) consumes the
identity through an operator-built kubeconfig — never the host administrator
kubeconfig, never cluster-admin.

This repository owns the identity, its RBAC, the approved exception, and the
credential/kubeconfig **procedure**. It does not own token issuance, the
kubeconfig file itself, or any Jenkins configuration.

## Verification status

**Implemented, not yet verified.** The Terraform in
`terraform/platform/homestreamlab-deployer.tf` and this runbook exist and pass
repo-local validation (`bash terraform/platform/validate.sh`,
`terraform fmt -check -recursive`). No live `terraform plan`/`apply` against the
`homelab-platform` HCP workspace has been run for this identity yet, and no
ServiceAccount token or kubeconfig has been issued. The RBAC verification matrix
below is the procedure to run **after** the first apply; its recorded results
belong in the issue #31 completion report / PR description, not in this file.

The Role/ClusterRole were subsequently **widened** for `services`,
`deployments` (`apps`), `ingressroutes` (`traefik.io`) and a cluster-scoped
`list` on `customresourcedefinitions`, to match HomeStreamLab's `infra/` after it
grew to manage Deployments, Services and a Traefik IngressRoute (its PRs #142 /
#144 / #145). That widening also passes repo-local validation and is **pending
the same live `plan`/`apply` + RBAC matrix**; the matrix below already reflects
the widened contract.

## What Terraform manages

| Object | Kind | Scope |
| --- | --- | --- |
| `homestreamlab-deployer` | `ServiceAccount` | `homestreamlab` namespace, `automount_service_account_token = false` |
| `homestreamlab-deployer` | `Role` | `homestreamlab` namespace |
| `homestreamlab-deployer` | `RoleBinding` | `homestreamlab` namespace → binds the SA to the Role |
| `homestreamlab-deployer-namespace-read` | `ClusterRole` | cluster; rule 1 — `get` on `namespaces`, `resourceNames: ["homestreamlab"]`; rule 2 — `list` on `customresourcedefinitions` (`apiextensions.k8s.io`) |
| `homestreamlab-deployer-namespace-read` | `ClusterRoleBinding` | cluster → binds the SA to that ClusterRole |

Terraform does **not** manage: the ServiceAccount token, any `Secret`, or the
kubeconfig. Those are operator actions (below) and must never enter Terraform
state, variables, or outputs, or be committed to Git.

The `homestreamlab` `Namespace` and its `ResourceQuota` are owned by
`module.homestreamlab` (issue #8). This identity only references the namespace
name via that module's `namespace_name` output; it never recreates or modifies
the Namespace or ResourceQuota.

## Why these permissions, and only these

Derived from a read-only inspection of HomeStreamLab's **current** Terraform
(`infra/`, provider `hashicorp/kubernetes` `3.2.1`, matching this repo's lock),
cross-checked against the provider source at tag `v3.2.1`. The workload rows
(`services`, `deployments`, `ingressroutes`) and the `customresourcedefinitions`
row were added when HomeStreamLab's `infra/` grew to manage Deployments, Services
and a Traefik IngressRoute (its PRs #142 / #144 / #145).

| HomeStreamLab Terraform | API group / resource | Scope | Provider lifecycle | Granted verbs |
| --- | --- | --- | --- | --- |
| `data.kubernetes_namespace_v1.homestreamlab` | core / `namespaces` | cluster | `Namespaces().Get(name)` only | `get` (name-restricted, ClusterRole) |
| `kubernetes_secret_v1.app` | core / `secrets` | `homestreamlab` | `Create()` / `Get()` / `Patch(JSONPatchType)` / `Delete()` | `get, create, patch, delete` |
| `kubernetes_persistent_volume_claim_v1.postgres_data` | core / `persistentvolumeclaims` | `homestreamlab` | `Create()` / `Get()` / `Patch(JSONPatchType)` / `Delete()` | `get, create, patch, delete` |
| `kubernetes_persistent_volume_claim_v1.uploads` | core / `persistentvolumeclaims` | `homestreamlab` | same as above | `get, create, patch, delete` |
| `kubernetes_service_v1.{postgres,backend,frontend}` | core / `services` | `homestreamlab` | `Create()` / `Get()` / `Patch(JSONPatchType)` / `Delete()`; all ClusterIP → no LoadBalancer wait, no `endpoints` / `endpointslices` | `get, create, patch, delete` |
| `kubernetes_deployment_v1.{postgres,backend,frontend}` | `apps` / `deployments` | `homestreamlab` | `Create()` / `Get()` / `Patch(JSONPatchType)` / `Delete()`; `wait_for_rollout` (default true) polls `Deployments().Get()` only — no pods, replicasets, `deployments/status` or watch | `get, create, patch, delete` |
| `kubernetes_manifest.ingressroute` | `traefik.io` / `ingressroutes` | `homestreamlab` | Server-Side Apply: `Patch(ApplyPatchType)` for create+update, `Get()` for read, `Delete()` for destroy. SSA that creates an absent object is authorized as `create` + `patch` | `get, create, patch, delete` |
| `kubernetes_manifest.ingressroute` (schema resolution) | `apiextensions.k8s.io` / `customresourcedefinitions` | cluster | `fetchCRDs` → `Resource(crd).List()` on every plan/read/apply, no fallback if denied | `list` (ClusterRole; cannot be name-restricted) |

Deliberately **not** granted:

- `update` — the provider uses JSON Patch (`Patch(JSONPatchType)`) for Secret /
  PVC / Service / Deployment updates and Server-Side Apply
  (`Patch(ApplyPatchType)`) for the IngressRoute; no path calls `Update()`.
- `list`, `watch` on any namespaced workload resource — no lifecycle path calls
  them. `wait_until_bound = false` on both PVCs (no status watch, no
  `persistentvolumes` / `storageclasses` read); `wait_for_rollout` polls
  `Deployments().Get()` only; every Service is ClusterIP (no LoadBalancer wait);
  `kubernetes_manifest` has no `wait` block.
- `events` — read by the provider only on a create-time wait *failure*, to
  enrich the error message; never on a successful plan/apply. Withheld.
- any verb on `configmaps`, `ingresses` (`networking.k8s.io`), `pods`,
  `replicasets`, `endpoints`, `endpointslices`, `persistentvolumes`,
  `storageclasses`, `resourcequotas`, `serviceaccounts`, or `nodes`.
- any **write** on `customresourcedefinitions`, and any `apiextensions.k8s.io`
  verb other than the single `list` (below). CRDs stay platform-owned.
- any wildcard (`*`) group/resource/verb.
- any cluster-scoped write, `kube-system` access, RBAC-object write, or
  namespace `list` / `watch`.

### The cluster-scoped reads (RBAC_SCOPE_REVIEW_REQUIRED)

Two cluster-scoped **reads** are unavoidable — a namespaced `Role` cannot grant
either. Both were flagged `RBAC_SCOPE_REVIEW_REQUIRED` and **explicitly approved**
as the narrowest grants that satisfy the provider, bound to only the
`homestreamlab-deployer` ServiceAccount. Neither grants any write.

1. HomeStreamLab's `data "kubernetes_namespace_v1" "homestreamlab"` reads the
   cluster-scoped object `Namespace/homestreamlab`:

   ```text
   apiGroups:     [""]
   resources:     ["namespaces"]
   resourceNames: ["homestreamlab"]
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
as the runbook's
[`homestreamlab` namespace instantiation](./terraform-runbook.md#homestreamlab-namespace-instantiation-issue-8):

1. `bash terraform/platform/validate.sh` — repo-local, must pass.
2. Confirm the `homelab-platform` HCP workspace is **Execution Mode = Local** in
   the UI immediately beforehand.
3. `export TF_CLOUD_ORGANIZATION=<your-hcp-organization>` and
   `terraform -chdir=terraform/platform init -input=false`; confirm
   `.terraform.lock.hcl` is unchanged (no new providers are introduced).
4. Save a plan to a scratch dir **outside** the repository (mode `0700`):
   `terraform -chdir=terraform/platform plan -input=false -out="$SCRATCH/hsl-deployer.tfplan"`
   then `terraform -chdir=terraform/platform show -json "$SCRATCH/hsl-deployer.tfplan" > "$SCRATCH/hsl-deployer-plan.json"`.
5. **Plan gate** — assert with `jq` on the JSON (not the human summary). Terraform
   plan JSON can list unchanged resources as `["no-op"]`, so filter before
   counting:
   - `CHANGING = [ .resource_changes[] | select(.change.actions != ["no-op"]) ]`;
   - `CHANGING` shape depends on whether the identity already exists in the
     cluster/state:
     - **first apply** (identity not yet applied): `CHANGING | length == 5`,
       every entry `.change.actions == ["create"]`, addresses exactly
       `kubernetes_service_account_v1.homestreamlab_deployer`,
       `kubernetes_role_v1.homestreamlab_deployer`,
       `kubernetes_role_binding_v1.homestreamlab_deployer`,
       `kubernetes_cluster_role_v1.homestreamlab_deployer_namespace_read`,
       `kubernetes_cluster_role_binding_v1.homestreamlab_deployer_namespace_read`;
     - **re-apply of the workloads/CRD widening** (identity already applied):
       `CHANGING | length == 2`, every entry `.change.actions == ["update"]`,
       addresses exactly `kubernetes_role_v1.homestreamlab_deployer` and
       `kubernetes_cluster_role_v1.homestreamlab_deployer_namespace_read`;
   - no `module.homestreamlab.*` resource has a non-`no-op` action
     (`[ .resource_changes[] | select(.address | startswith("module.homestreamlab.")) | select(.change.actions != ["no-op"]) ] | length == 0`);
   - the SA's `automount_service_account_token` is `false`;
   - the Role has exactly five rules — `secrets` / `persistentvolumeclaims` /
     `services` (core), `deployments` (`apps`), `ingressroutes` (`traefik.io`) —
     each `["get","create","patch","delete"]` and nothing else (no `update`,
     `list`, `watch`);
   - the ClusterRole has exactly two rules — `namespaces` +
     `resource_names ["homestreamlab"]` + `verbs ["get"]`, and
     `customresourcedefinitions` (`apiextensions.k8s.io`) + `verbs ["list"]`
     (no `resource_names`, no other verb);
   - no wildcard `*` anywhere.
6. Separate, explicit operator approval of the apply.
7. `terraform -chdir=terraform/platform apply "$SCRATCH/hsl-deployer.tfplan"` —
   the exact reviewed artifact. Then delete `$SCRATCH`.
8. Run the RBAC verification matrix (below).
9. Convergence: `terraform -chdir=terraform/platform plan`. Authoritative check —
   the plan JSON has **zero** `resource_changes` with
   `.change.actions != ["no-op"]`. The human `No changes.` line is supporting
   evidence only.

## RBAC verification matrix

Non-mutating, impersonation-based. No resources are created/updated/deleted and
no Secret contents are read.

```sh
AS='--as=system:serviceaccount:homestreamlab:homestreamlab-deployer'
```

### Positive — every check must print `yes`

```sh
kubectl auth can-i get    secrets                  -n homestreamlab $AS
kubectl auth can-i create secrets                  -n homestreamlab $AS
kubectl auth can-i patch  secrets                  -n homestreamlab $AS
kubectl auth can-i delete secrets                  -n homestreamlab $AS
kubectl auth can-i get    persistentvolumeclaims   -n homestreamlab $AS
kubectl auth can-i create persistentvolumeclaims   -n homestreamlab $AS
kubectl auth can-i patch  persistentvolumeclaims   -n homestreamlab $AS
kubectl auth can-i delete persistentvolumeclaims   -n homestreamlab $AS
kubectl auth can-i get    services                 -n homestreamlab $AS
kubectl auth can-i create services                 -n homestreamlab $AS
kubectl auth can-i patch  services                 -n homestreamlab $AS
kubectl auth can-i delete services                 -n homestreamlab $AS
kubectl auth can-i get    deployments.apps         -n homestreamlab $AS
kubectl auth can-i create deployments.apps         -n homestreamlab $AS
kubectl auth can-i patch  deployments.apps         -n homestreamlab $AS
kubectl auth can-i delete deployments.apps         -n homestreamlab $AS
kubectl auth can-i get    ingressroutes.traefik.io -n homestreamlab $AS
kubectl auth can-i create ingressroutes.traefik.io -n homestreamlab $AS
kubectl auth can-i patch  ingressroutes.traefik.io -n homestreamlab $AS
kubectl auth can-i delete ingressroutes.traefik.io -n homestreamlab $AS
kubectl auth can-i get    namespace homestreamlab                   $AS
kubectl auth can-i list   customresourcedefinitions.apiextensions.k8s.io    $AS
```

### Negative — every check must print `no`

```sh
kubectl auth can-i get    nodes                            $AS
kubectl auth can-i list   nodes                            $AS
kubectl auth can-i list   namespaces                       $AS
kubectl auth can-i watch  namespaces                       $AS
kubectl auth can-i get    namespace kube-system            $AS
kubectl auth can-i create clusterroles                     $AS
kubectl auth can-i create clusterrolebindings              $AS
kubectl auth can-i create deployments.apps -n default      $AS
kubectl auth can-i get    secrets     -n default           $AS
kubectl auth can-i list   secrets     -n homestreamlab     $AS
kubectl auth can-i update secrets     -n homestreamlab     $AS
kubectl auth can-i watch  secrets     -n homestreamlab     $AS
kubectl auth can-i update deployments.apps         -n homestreamlab $AS
kubectl auth can-i list   deployments.apps         -n homestreamlab $AS
kubectl auth can-i watch  deployments.apps         -n homestreamlab $AS
kubectl auth can-i update services                 -n homestreamlab $AS
kubectl auth can-i list   services                 -n homestreamlab $AS
kubectl auth can-i update ingressroutes.traefik.io -n homestreamlab $AS
kubectl auth can-i list   ingressroutes.traefik.io -n homestreamlab $AS
kubectl auth can-i get    customresourcedefinitions.apiextensions.k8s.io    $AS
kubectl auth can-i watch  customresourcedefinitions.apiextensions.k8s.io    $AS
kubectl auth can-i create customresourcedefinitions.apiextensions.k8s.io    $AS
kubectl auth can-i list   pods           -n homestreamlab $AS
kubectl auth can-i get    endpoints      -n homestreamlab $AS
kubectl auth can-i get    resourcequotas -n homestreamlab $AS
kubectl auth can-i delete namespace homestreamlab          $AS
```

Do not use `kubectl auth can-i --list` as the check — run the explicit matrix so
each granted and each withheld permission is individually asserted.

## Credential handoff (operator-managed)

Performed **after** the identity exists. Terraform is not involved. `<HOST_LAN_IP>`
is this host's LAN address (the same value used elsewhere in the platform), never
`127.0.0.1`.

### Credential lifetime — deliberate homelab simplification

The Kubernetes-preferred model is short-lived TokenRequest credentials
(`kubectl create token`, projected service-account-token volumes). This runbook's
**primary** procedure instead provisions a long-lived
`kubernetes.io/service-account-token` Secret, because the downstream consumer is
a static Jenkins *Secret File* credential (`k3s-homestreamlab`) with no rotation
automation in this milestone. The long-lived token is a conscious trade-off:
manually managed, manually rotated, dedicated to `homestreamlab-deployer` only,
never cluster-admin, never committed. `kubectl create token … --duration=…` is
the bounded-lifetime alternative if the operator prefers it; rotation is manual
either way.

### 1. Identify the ServiceAccount

```sh
kubectl get serviceaccount homestreamlab-deployer -n homestreamlab
```

### 2. Issue dedicated credential material (operator, not Terraform)

k3s is Kubernetes ≥1.24, so no token Secret is auto-created. Create one
explicitly — a cluster-side namespaced Secret in `homestreamlab`, operator-created
and never Terraform-managed or imported into Terraform state:

```sh
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: homestreamlab-deployer-token
  namespace: homestreamlab
  annotations:
    kubernetes.io/service-account.name: homestreamlab-deployer
type: kubernetes.io/service-account-token
EOF

kubectl -n homestreamlab wait --for=jsonpath='{.data.token}' \
  secret/homestreamlab-deployer-token --timeout=30s
```

### 3. Extract the token and the cluster CA trust material

The CA comes from the token Secret itself (`ca.crt`) so the resulting kubeconfig
is portable and depends on no host-only path:

```sh
WORK="$(umask 077; mktemp -d)"      # outside the repository

kubectl get secret homestreamlab-deployer-token -n homestreamlab \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > "$WORK/k3s-ca.crt"

TOKEN="$(kubectl get secret homestreamlab-deployer-token -n homestreamlab \
  -o jsonpath='{.data.token}' | base64 -d)"
```

### 4. Build a self-contained kubeconfig

```sh
KUBECONFIG_OUT="$WORK/k3s-homestreamlab.kubeconfig"

KUBECONFIG="$KUBECONFIG_OUT" kubectl config set-cluster homelab-k3s \
  --server="https://<HOST_LAN_IP>:6443" \
  --certificate-authority="$WORK/k3s-ca.crt" \
  --embed-certs=true

KUBECONFIG="$KUBECONFIG_OUT" kubectl config set-credentials homestreamlab-deployer \
  --token="$TOKEN"

KUBECONFIG="$KUBECONFIG_OUT" kubectl config set-context homestreamlab-deployer \
  --cluster=homelab-k3s \
  --user=homestreamlab-deployer \
  --namespace=homestreamlab

KUBECONFIG="$KUBECONFIG_OUT" kubectl config use-context homestreamlab-deployer
```

The API server is the LAN endpoint `https://<HOST_LAN_IP>:6443`. Do not use
`https://127.0.0.1:6443`, `insecure-skip-tls-verify: true`,
`/etc/rancher/k3s/k3s.yaml`, or any host-only CA / client-certificate path.

### 5. Verify TLS and authorization without mutating anything

```sh
# Normal TLS, no verification disabled:
KUBECONFIG="$KUBECONFIG_OUT" kubectl get namespace homestreamlab -o name

# Then run the full positive + negative RBAC matrix above, replacing
#   kubectl auth can-i ... $AS
# with
#   KUBECONFIG="$KUBECONFIG_OUT" kubectl auth can-i ...
# (no --as: the kubeconfig already IS the deployer identity).
```

### 6. Deliver to local-jenkins-platform

Transfer `k3s-homestreamlab.kubeconfig` to the `local-jenkins-platform` operator
over a secure channel (not through this repository, not through chat, not via a
commit). There it becomes the Jenkins **Secret File** credential
`k3s-homestreamlab` (J6, that repository's concern). Then destroy the local
working copy:

```sh
rm -rf "$WORK"
```

### 7. Manual rotation / replacement

```sh
kubectl delete secret homestreamlab-deployer-token -n homestreamlab
# re-run steps 2–6
```

The `ServiceAccount`, `Role`, `RoleBinding`, `ClusterRole` and `ClusterRoleBinding`
are unaffected by rotation — only the token Secret and the kubeconfig are
reissued. Revoking the old token is immediate on Secret deletion. `.gitignore`
already blocks `*.kubeconfig`, `.kube/`, `*.pem`, `*.key`, so the working
material cannot be committed by accident.

## Rollback

Repository side — revert `terraform/platform/homestreamlab-deployer.tf`, then run
a full (untargeted) `terraform plan`; require the plan JSON to show **exactly**
five deletes (the five objects above) and **zero** other non-`no-op` changes,
under a separate explicit apply approval. The `homestreamlab` Namespace and
ResourceQuota are untouched by this.

To roll back **only** the workloads/CRD widening (keeping the identity), revert
just the added rules: the plan JSON must then show exactly
`kubernetes_role_v1.homestreamlab_deployer` and
`kubernetes_cluster_role_v1.homestreamlab_deployer_namespace_read` as `update`
(Role back to `secrets` / `persistentvolumeclaims`, ClusterRole back to the
single `namespaces` rule) and zero other non-`no-op` changes.

Operator side — the token Secret is not Terraform-managed, so delete it
separately:

```sh
kubectl delete secret homestreamlab-deployer-token -n homestreamlab --ignore-not-found
```

## Scope boundary

This runbook and issue #31 change only `homelab-platform`. HomeStreamLab is
inspected read-only and not modified. `local-jenkins-platform` is not touched — the
Jenkins Secret File credential, JCasC wiring, and Jenkins-side verification are
J6, in that repository. No HomeStreamLab application resource (Deployment,
Service, IngressRoute, Secret, ConfigMap, Helm release, Jenkinsfile) is created
here.

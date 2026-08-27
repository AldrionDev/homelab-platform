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

## What Terraform manages

| Object | Kind | Scope |
| --- | --- | --- |
| `homestreamlab-deployer` | `ServiceAccount` | `homestreamlab` namespace, `automount_service_account_token = false` |
| `homestreamlab-deployer` | `Role` | `homestreamlab` namespace |
| `homestreamlab-deployer` | `RoleBinding` | `homestreamlab` namespace → binds the SA to the Role |
| `homestreamlab-deployer-namespace-read` | `ClusterRole` | cluster, `resourceNames: ["homestreamlab"]`, `verbs: ["get"]` on `namespaces` |
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
cross-checked against the provider source at tag `v3.2.1`.

| HomeStreamLab Terraform | API group / resource | Scope | Provider lifecycle | Granted verbs |
| --- | --- | --- | --- | --- |
| `data.kubernetes_namespace_v1.homestreamlab` | core / `namespaces` | cluster | `Namespaces().Get(name)` only | `get` (name-restricted, ClusterRole) |
| `kubernetes_secret_v1.app` | core / `secrets` | `homestreamlab` | `Create()` / `Get()` / `Patch(JSONPatchType)` / `Delete()` | `get, create, patch, delete` |
| `kubernetes_persistent_volume_claim_v1.postgres_data` | core / `persistentvolumeclaims` | `homestreamlab` | `Create()` / `Get()` / `Patch(JSONPatchType)` / `Delete()` | `get, create, patch, delete` |
| `kubernetes_persistent_volume_claim_v1.uploads` | core / `persistentvolumeclaims` | `homestreamlab` | same as above | `get, create, patch, delete` |

Deliberately **not** granted:

- `update` — the provider uses JSON Patch for updates, not `Update()`.
- `list`, `watch` — no lifecycle path calls them (`wait_until_bound = false` on
  both PVCs, so no status watch and no `persistentvolumes` / `storageclasses`
  read).
- any verb on `deployments`, `services`, `configmaps`, `ingresses` /
  `ingressroutes`, or any non-core API group — HomeStreamLab manages none of
  them today. When HomeStreamLab adds application manifests (its own later
  issues), this Role must be widened by a follow-up `homelab-platform` change,
  not pre-granted here.
- any wildcard (`*`) group/resource/verb.
- any cluster-scoped write, node access, or namespace `list`/`watch`.

### The cluster-scoped exception (RBAC_SCOPE_REVIEW_REQUIRED)

HomeStreamLab's `data "kubernetes_namespace_v1" "homestreamlab"` reads the
cluster-scoped object `Namespace/homestreamlab`. A namespaced `Role` cannot grant
that, so this identity needs a `ClusterRole`. This was flagged as
`RBAC_SCOPE_REVIEW_REQUIRED` and **explicitly approved** as the narrowest
possible grant:

```text
apiGroups:     [""]
resources:     ["namespaces"]
resourceNames: ["homestreamlab"]
verbs:         ["get"]
```

bound to only the `homestreamlab-deployer` ServiceAccount. It does not permit
`list` or `watch` on namespaces, does not permit `get` on any other namespace,
and grants no cluster-scoped write. Repository conventions do not require an ADR
for an issue-scoped RBAC exception; this section is its record.

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
   - `CHANGING | length == 5`, every entry `.change.actions == ["create"]`;
   - `CHANGING` addresses are exactly
     `kubernetes_service_account_v1.homestreamlab_deployer`,
     `kubernetes_role_v1.homestreamlab_deployer`,
     `kubernetes_role_binding_v1.homestreamlab_deployer`,
     `kubernetes_cluster_role_v1.homestreamlab_deployer_namespace_read`,
     `kubernetes_cluster_role_binding_v1.homestreamlab_deployer_namespace_read`;
   - no `module.homestreamlab.*` resource has a non-`no-op` action
     (`[ .resource_changes[] | select(.address | startswith("module.homestreamlab.")) | select(.change.actions != ["no-op"]) ] | length == 0`);
   - the SA's `automount_service_account_token` is `false`;
   - the Role rules are `secrets` / `persistentvolumeclaims` ×
     `["get","create","patch","delete"]` only; the ClusterRole rule is
     `namespaces` + `resource_names ["homestreamlab"]` + `verbs ["get"]`;
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
kubectl auth can-i get    secrets                -n homestreamlab $AS
kubectl auth can-i create secrets                -n homestreamlab $AS
kubectl auth can-i patch  secrets                -n homestreamlab $AS
kubectl auth can-i delete secrets                -n homestreamlab $AS
kubectl auth can-i get    persistentvolumeclaims -n homestreamlab $AS
kubectl auth can-i create persistentvolumeclaims -n homestreamlab $AS
kubectl auth can-i patch  persistentvolumeclaims -n homestreamlab $AS
kubectl auth can-i delete persistentvolumeclaims -n homestreamlab $AS
kubectl auth can-i get    namespace homestreamlab                 $AS
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
kubectl auth can-i create deployments -n default           $AS
kubectl auth can-i create deployments -n homestreamlab     $AS
kubectl auth can-i get    secrets     -n default           $AS
kubectl auth can-i list   secrets     -n homestreamlab     $AS
kubectl auth can-i update secrets     -n homestreamlab     $AS
kubectl auth can-i watch  secrets     -n homestreamlab     $AS
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

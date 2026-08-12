# Terraform runbook

The Platform Terraform Workspace: HCP Terraform remote state with **Local**
execution mode, and the `kubernetes` and `helm` providers pointed at this host's
k3s cluster. The root module lives in
[`terraform/platform/`](../terraform/platform/).

This bootstrap (issue #6) itself declared no Kubernetes resources. The
reusable namespace and ResourceQuota pattern is issue #7 (see
[Namespace Pattern module](#namespace-pattern-module)); its first concrete
instantiation — the `homestreamlab` Namespace and ResourceQuota — is issue #8
(see
[`homestreamlab` namespace instantiation](#homestreamlab-namespace-instantiation-issue-8)).

## Verification status

**Implemented and verified**, both repo-locally and against HCP Terraform.

Verified repo-locally on this host (Terraform v1.15.8):

- `terraform fmt -check -recursive`, run from the repository's `terraform/`
  root, passes;
- `terraform init -backend=false -input=false` completes cleanly **with the
  `cloud` block present** — run against an isolated, scratch `TF_DATA_DIR` (see
  [below](#repo-local-validation)), it initialises provider plugins only and
  does not contact HCP Terraform;
- `terraform validate` reports the configuration valid;
- the generated `.terraform.lock.hcl` selects `hashicorp/helm` v3.2.0 and
  `hashicorp/kubernetes` v3.2.1;
- the leak gate in [`terraform/platform/validate.sh`](../terraform/platform/validate.sh)
  passes on this repository, and was confirmed to fail against synthetic
  credential fixtures, a synthetic `credentials.tfrc.json`, and a simulated
  candidate-enumeration failure (missing git work tree);
- **re-verified with the real, live HCP-initialized `terraform/platform/.terraform/`
  left in place** (the state created by the live verification below): `bash
  terraform/platform/validate.sh` still passes, with `TF_CLOUD_ORGANIZATION`
  and `TF_WORKSPACE` both explicitly unset, and the live `.terraform/` was
  confirmed unchanged afterward — same directory listing, same file sizes, same
  modification times. This is what makes the script
  safe to run at any time, in the same checkout an operator uses for real HCP
  work, without needing to clean anything up first.

Verified live, against HCP Terraform:

- the `homelab-platform` HCP Terraform workspace exists, with **Execution Mode
  = Local** confirmed in the workspace UI;
- `terraform -chdir=terraform/platform init -input=false`, run against that
  workspace with `TF_CLOUD_ORGANIZATION` set and `kubeconfig_path` supplied via
  a local `terraform.tfvars`, reports **"HCP Terraform has been successfully
  initialized!"**;
- `terraform -chdir=terraform/platform validate` reports **"Success! The
  configuration is valid."**;
- `terraform -chdir=terraform/platform plan -input=false` reports **"No
  changes. Your infrastructure matches the configuration."** against the empty
  baseline;
- after that plan, the workspace shows **0 resources**, is **unlocked**, and
  **"This workspace currently has no states saved"** — Local execution mode
  produced no remote run and left no managed state behind, exactly as
  expected for a resource-free configuration;
- the user-owned kubeconfig copy authenticates, verified separately with
  `kubectl --kubeconfig "$HOME/.kube/homelab-k3s.yaml" get namespace
  kube-system -o name` → `namespace/kube-system`.

**A gap this design closes:** once a working directory has gone through a real
HCP-backed `init`, `.terraform/` there locally caches that the backend is
`cloud`. A bare `terraform init -backend=false` run directly against that same
directory then fails with a missing-organization error — `-backend=false`
still has to reconcile against the cached cloud backend pointer. Setting
`TF_CLOUD_ORGANIZATION` to work around that was tried and rejected: it makes
Terraform attempt to reach `app.terraform.io` to validate the organization,
which would defeat the repo-local gate's own "never contacts HCP Terraform"
guarantee. `validate.sh` avoids this entirely by never running Terraform
against the live `terraform/platform/.terraform/` in the first place — see
[Repo-local validation](#repo-local-validation) for how.

Rollback of the HCP workspace binding, and any workspace deletion or
provenance-preflight STOP path, were **not** exercised — this issue's workspace
was created clean and never needed either.

**A limitation of the evidence above, on its own:** because the
empty-baseline configuration verified in issue #6 contained no resources or
data sources that require Kubernetes API operations, that empty baseline plan
— live or repo-local — was not by itself evidence of live provider-to-cluster
connectivity. Issue #7 added the first real resources (the Namespace Pattern
module — see [below](#namespace-pattern-module)), but its `plan-check.sh`
verification deliberately never uses a real k3s kubeconfig or API endpoint
either. **The first real evidence of live provider-to-cluster connectivity is
issue #8's actual `apply`** — see
[`homestreamlab` namespace instantiation](#homestreamlab-namespace-instantiation-issue-8)
for the full record.

## Prerequisites

- k3s running on this host (see [`docs/k3s-runbook.md`](./k3s-runbook.md)).
- Terraform CLI matching `~> 1.15`. Verified on v1.15.8.
- An HCP Terraform account, and a local credential at
  `~/.terraform.d/credentials.tfrc.json` (created by `terraform login`).
- The `homelab-platform` workspace existing in that account with Execution Mode
  set to **Local** — see [HCP workspace setup](#hcp-workspace-setup).

## Repository layout

| File | Role |
| --- | --- |
| `main.tf` | instantiates the Namespace Pattern module once, as `module "homestreamlab"` — see [`homestreamlab` namespace instantiation](#homestreamlab-namespace-instantiation-issue-8) |
| `versions.tf` | `required_version`, the `cloud` block, provider constraints |
| `providers.tf` | `kubernetes` and `helm` provider configuration |
| `variables.tf` | `kubeconfig_path` (required), `kube_context` (defaults to `default`) |
| `terraform.tfvars.example` | committed template, placeholders only |
| `validate.sh` | repo-local validation: fmt, validate, leak gate — also now covers `terraform/modules/*/`, see [Namespace Pattern module](#namespace-pattern-module) |
| `.terraform.lock.hcl` | committed provider lock — see [below](#why-the-lockfile-is-committed) |

Reusable child modules live under
[`terraform/modules/`](../terraform/modules/), sibling to `platform/`. Each
module directory never carries its own committed `.terraform.lock.hcl` — see
[Namespace Pattern module](#namespace-pattern-module).

### Workspace identity

The workspace name is fixed in `versions.tf`:

```hcl
cloud {
  workspaces {
    name = "homelab-platform"
  }
}
```

That name is deliberate (ADR-0002) and lives in version control so the decision
stays visible in review. `TF_WORKSPACE` is intentionally absent from
`.env.example`: a second, non-version-controlled source of workspace identity
would be redundant and misleading.

The **organization** is account-specific and never committed. Supply it from the
environment:

```sh
export TF_CLOUD_ORGANIZATION=<your-hcp-organization>
```

Terraform does **not** automatically read `.env`. `.env.example` records the
variable name; the real value must be exported into your shell environment.
If you keep it in the gitignored `.env`, source it explicitly first:

```sh
set -a
. ./.env
set +a
```

## HCP workspace setup

This is a **manual UI transaction**, performed by the operator, not scripted and
not performed by any command in this repository. Local execution mode must be in
force **before** any `terraform init` runs against HCP.

### If the workspace does not exist

1. Sign in to HCP Terraform and select the organization.
2. **Workspaces → New workspace → CLI-driven workflow.**
3. Name it exactly `homelab-platform`. Attach **no** VCS repository.
4. Create it.
5. **Settings → General → Execution Mode → Local → Save.**
6. Reload the page and re-read the setting to confirm it now reads `Local`.
7. Add **no** workspace variables. `kubeconfig_path` and every other
   machine-specific value stay local and must never reach HCP.

### If a workspace of that name already exists

A name match is **not** permission to reuse it. Before any `terraform init`,
check the following read-only in the UI and record what you find:

| # | Check | Where | Expectation |
| --- | --- | --- | --- |
| 1 | Execution Mode | Settings → General | record the current value; either value is acceptable at this point |
| 2 | Resource count | Workspace overview | **0 resources** |
| 3 | Existing managed state | States | no unexpected managed resources |
| 4 | VCS connection | Settings → Version Control | none attached |
| 5 | Provenance | Variables, description, tags, creator, run history | nothing suggesting the workspace belongs to another configuration |
| 6 | Runs baseline | Runs | record the newest run's ID and timestamp, or that the list is empty |

**Stop** if the state is non-empty, a VCS connection exists, or the provenance is
uncertain. Do not bind this root module to it — `terraform init` would adopt the
existing state. Resolving that is a separate decision, and using a different
workspace name would require amending ADR-0002 rather than drifting from it.

Execution Mode is **not** a provenance question. If checks 2–5 pass and the
workspace is merely still set to `Remote`, that is a setting to change, not a
failure: set it to **Local**, save, then reload and re-read it to prove the
change took effect.

**Under no circumstances run `terraform init` while the workspace is in Remote
mode.** HCP Terraform's runners cannot reach this LAN-only k3s API (ADR-0001).

## Kubeconfig for Terraform

k3s writes `/etc/rancher/k3s/k3s.yaml` as `root:root 0600`, which the user
running Terraform cannot read. Terraform is **not** run as root — the HCP
credential lives in the user's `~/.terraform.d/`. Instead, make a user-owned
copy outside the repository:

```sh
mkdir -p "$HOME/.kube"
sudo install -m 600 -o "$(id -un)" -g "$(id -gn)" \
  /etc/rancher/k3s/k3s.yaml "$HOME/.kube/homelab-k3s.yaml"
```

The owner and group are read from the actual account; do not assume the group
name matches the user name.

Verify the copy authenticates, with a resource API request:

```sh
stat -c '%n owner=%U:%G mode=%a' "$HOME/.kube/homelab-k3s.yaml"
kubectl --kubeconfig "$HOME/.kube/homelab-k3s.yaml" get namespace kube-system -o name
# expected: namespace/kube-system
```

`kubectl --kubeconfig ... get --raw='/readyz'` may be used as a separate API
health check, but it is not proof that the credential authenticates.

Then point Terraform at it:

```sh
cp terraform/platform/terraform.tfvars.example terraform/platform/terraform.tfvars
# edit terraform.tfvars: kubeconfig_path = "/home/<you>/.kube/homelab-k3s.yaml"
```

`terraform.tfvars` is gitignored and must never be committed.

### Refreshing the copy

**This copy is not permanent.** k3s rotates the client certificates embedded in
its admin kubeconfig over time; an external copy does not follow along, so its
embedded credential eventually goes stale and Terraform starts failing on TLS or
authorization errors.

Refresh it when:

- k3s has been upgraded or reinstalled;
- `terraform plan`/`apply` reports certificate expiry or `Unauthorized`;
- `/etc/rancher/k3s/k3s.yaml` is newer than the copy;
- routinely, before the embedded certificate expires.

Check before refreshing:

```sh
stat -c '%n %y' /etc/rancher/k3s/k3s.yaml "$HOME/.kube/homelab-k3s.yaml"
kubectl --kubeconfig "$HOME/.kube/homelab-k3s.yaml" get namespace kube-system -o name
```

Refresh with the same command as the initial copy — `install` overwrites the
target — then re-verify ownership, mode and authentication:

```sh
sudo install -m 600 -o "$(id -un)" -g "$(id -gn)" \
  /etc/rancher/k3s/k3s.yaml "$HOME/.kube/homelab-k3s.yaml"

stat -c '%n owner=%U:%G mode=%a' "$HOME/.kube/homelab-k3s.yaml"   # expect <user>:<group> 600
kubectl --kubeconfig "$HOME/.kube/homelab-k3s.yaml" get namespace kube-system -o name
```

`kubeconfig_path` does not change, so nothing on the Terraform side needs
updating. Never print the kubeconfig's contents.

## Repo-local validation

```sh
bash terraform/platform/validate.sh
```

This is **not** an offline check: `terraform init -backend=false` may contact the
public Terraform provider registry. What it does guarantee is that it never
contacts HCP Terraform and never touches the cluster.

**Safe to run at any time, in any working directory state — including one
where you have already run a real HCP-backed `terraform init`.** The
`init`/`validate` step runs against an isolated, scratch `TF_DATA_DIR`
(created with `mktemp -d`, removed by a trap on exit), never against the live
`terraform/platform/.terraform/`. A bare `terraform init -backend=false`
invoked directly (without going through `validate.sh`) does **not** have this
protection: once `terraform/platform/.terraform/` has gone through a real
HCP-backed `init`, it locally caches that the backend is `cloud`, and a direct
`-backend=false` re-run there fails demanding `TF_CLOUD_ORGANIZATION` to
reconcile that cached pointer. Setting `TF_CLOUD_ORGANIZATION` to work around
that direct-invocation case is **not** a fix: it makes Terraform attempt to
reach `app.terraform.io` to validate the organization, contacting HCP. Always
use `validate.sh` rather than invoking `terraform init -backend=false` by hand
in this module.

It runs `terraform fmt -check -recursive` from the repository's `terraform/`
root (so a future `terraform/modules/` tree is covered by the same check, not
just `terraform/platform/`), `terraform init -backend=false -input=false` and
`terraform validate` against the isolated `TF_DATA_DIR` described above, and
then a leak gate over a **single, validated snapshot** of every tracked,
staged and untracked-but-not-ignored file. The snapshot is enumerated exactly
once; if `git` is missing, the repository is not a git work tree, the
enumeration command itself fails, or the resulting set is empty, the script
hard-fails rather than silently scanning nothing. Gitignored local material —
a real `terraform.tfvars`, `.terraform/`, state files, kubeconfig copies, the
Terraform CLI's `credentials.tfrc.json` — is excluded from the candidate set by
`--exclude-standard`, so the gate never reads it.

The leak gate rejects:

- any `*.tfvars` (other than `*.tfvars.example`), `*.tfstate*`, a file literally
  named `kubeconfig`, `*.kubeconfig`, anything under a `.kube/` directory,
  `.terraform/`, `*.tfplan`, or a `credentials.tfrc.json` / `.terraform.d/`
  entry in the candidate set;
- real credential material: a PEM certificate or private key header, or a
  kubeconfig credential key carrying an actual base64 value;
- `/home/`, `/Users/` or `/root/` absolute paths under `terraform/`;
- an `organization =` assignment in a committed `.tf` file.

Detection is content-based, not keyword-based, so this runbook and the validator
itself can name the credential keys without tripping the gate — while a genuinely
embedded kubeconfig, certificate or private key still fails hard. Path-only
checks (forbidden filenames, machine-specific paths) match against the path
string with bash's native regex engine rather than an external command, so
there is no matcher-failure mode there to misread as "clean"; content checks
still use `grep`, wrapped so any exit status other than "match" or "no match"
is itself a hard failure.

## Namespace Pattern module

Issue #7 added the first real Kubernetes resources in this repo: a reusable
child module,
[`terraform/modules/namespace-resourcequota/`](../terraform/modules/namespace-resourcequota/)
(the **Namespace Pattern** — see `CONTEXT.md`), producing a `Namespace` and a
matching `ResourceQuota` for any Project. The module itself instantiates
nothing — issue #8 is its first concrete caller, from
`terraform/platform/main.tf` (see
[`homestreamlab` namespace instantiation](#homestreamlab-namespace-instantiation-issue-8)).
See the module's own
[`README.md`](../terraform/modules/namespace-resourcequota/README.md) for its
inputs, outputs, and naming convention.

### Validation coverage

`bash terraform/platform/validate.sh` now also validates every directory under
`terraform/modules/*/`, including this one: it copies each module's `.tf`
files into an isolated scratch directory and runs `terraform init
-backend=false` + `terraform validate` there — never against the module
directory itself, since `terraform init` always writes `.terraform.lock.hcl`
next to the config files it runs against, and a committed module-level
lockfile is exactly what this repo must avoid. The leak gate also now rejects
any committed `terraform/modules/*/.terraform.lock.hcl` as defense-in-depth.

### Throwaway plan verification

```sh
bash terraform/modules/namespace-resourcequota/plan-check.sh
```

This asserts, via `terraform show -json` captured to a file and then read by
`jq` in separate assertions (never text-matching on human-readable plan
output), that instantiating the module with
representative throwaway values plans **exactly** two resource creates — a
`Namespace` and a matching `ResourceQuota`, with the expected names,
namespace, and `spec.hard` values — failing closed on any mismatch,
extra/missing resource, or non-`create` action. `jq` is a hard prerequisite;
the script fails closed if it is missing rather than skipping the check.

**Its precise contract:**

- repo-local verification only;
- no HCP Terraform backend or state is ever configured;
- no real k3s kubeconfig or API endpoint is ever used — the kubeconfig it
  writes carries no real cluster credentials and names no real cluster;
- `terraform apply` is never run;
- `terraform init` may still contact the public Terraform provider registry to
  download the provider plugin — this is **not** an offline or network-free
  check in that sense.

**What it does not prove:** that the `kubernetes` provider can reach a real
Kubernetes API server, or that `terraform apply` would succeed against one.
One empirical observation motivated this design — with the tested provider
version (`hashicorp/kubernetes` 3.2.1) and an empty throwaway state, planning
these two brand-new resources did not require reaching a live API server —
but that is a narrow, version-specific observation, not a relied-upon safety
property; a future provider release could behave differently. This script's
safety instead comes entirely from never configuring a real backend, real
credentials, or running `apply` — never from an assumption about provider
connectivity behavior. **`plan-check.sh` passing is not evidence of live
provider-to-cluster connectivity.** That real evidence now exists — see
[`homestreamlab` namespace instantiation](#homestreamlab-namespace-instantiation-issue-8)
below.

## homestreamlab namespace instantiation (issue #8)

`terraform/platform/main.tf` calls the Namespace Pattern module once:

```hcl
module "homestreamlab" {
  source = "../modules/namespace-resourcequota"

  project_name = "homestreamlab"

  cpu_request    = "1"
  cpu_limit      = "2"
  memory_request = "2Gi"
  memory_limit   = "4Gi"
}
```

The four quota values are explicitly approved platform policy for this
project, not derived from any value committed elsewhere in this repository.

### Workflow followed

1. **Repo-local validation** — `bash terraform/platform/validate.sh` (and
   `terraform -chdir=terraform fmt -check -recursive`), against the isolated,
   backend-disabled `TF_DATA_DIR` described in
   [Repo-local validation](#repo-local-validation). This also exercises the
   module's own `variable` `validation` blocks against the literal values
   above, since they are no longer only reachable via `plan-check.sh`'s
   throwaway values.
2. **Live plan** — after confirming Execution Mode = Local for the
   `homelab-platform` workspace in the HCP UI immediately beforehand, a real
   `terraform plan` was run and saved to a plan file:

   ```sh
   cd terraform/platform
   export TF_CLOUD_ORGANIZATION=<your-hcp-organization>
   SCRATCH_DIR="$(umask 077; mktemp -d)"   # outside the repository
   terraform init -input=false
   terraform validate
   terraform plan -input=false -out="$SCRATCH_DIR/homestreamlab.tfplan"
   terraform show -json "$SCRATCH_DIR/homestreamlab.tfplan" \
     > "$SCRATCH_DIR/homestreamlab-plan.json"
   ```

   The saved plan file is a potentially sensitive local artifact — same
   handling as `terraform.tfvars` — kept outside the repository, at
   restrictive permissions, never committed.
3. **Machine-readable plan proof**, via `terraform show -json` + `jq` against
   `homestreamlab-plan.json` (never the human-readable summary alone):
   exactly 2 `resource_changes`; both `.change.actions == ["create"]`;
   addresses exactly `module.homestreamlab.kubernetes_namespace_v1.this` and
   `module.homestreamlab.kubernetes_resource_quota_v1.this`; namespace name
   `homestreamlab`; ResourceQuota name `homestreamlab-quota` in namespace
   `homestreamlab`; `spec.hard` exactly
   `{"requests.cpu":"1","limits.cpu":"2","requests.memory":"2Gi","limits.memory":"4Gi"}`.
   All assertions passed. Only after they passed did the human-readable
   `Plan: 2 to add, 0 to change, 0 to destroy` summary count as
   corroboration.
4. **Apply** — the reviewed saved plan artifact was applied without
   recomputing it:

   ```sh
   terraform apply "$SCRATCH_DIR/homestreamlab.tfplan"
   ```

   Applying the exact artifact that was JSON-inspected removes the window
   for drift between plan and apply; it does not, however, prevent external
   infrastructure drift from causing the apply itself to fail. `terraform
   apply` reported `Apply complete! Resources: 2 added, 0 changed, 0
   destroyed.` — the namespace and ResourceQuota were created successfully
   and HCP Terraform's state updated accordingly.
5. **Cleanup** — after apply, `$SCRATCH_DIR` (both the saved plan and its
   JSON rendering) was deleted entirely; the working tree was confirmed clean
   of any leaked artifact.
6. **Runtime verification**, read-only:

   ```sh
   KC="$HOME/.kube/homelab-k3s.yaml"
   kubectl --kubeconfig "$KC" get namespace homestreamlab
   kubectl --kubeconfig "$KC" get resourcequota -n homestreamlab -o yaml
   ```

   Confirmed: `namespace/homestreamlab` exists with `status.phase == Active`;
   `resourcequota/homestreamlab-quota` exists in `homestreamlab` with
   `spec.hard` exactly matching the four approved values above. `pods`,
   `deployments.apps`, `statefulsets.apps`, `daemonsets.apps`, `jobs.batch`,
   `cronjobs.batch`, `services`, `ingresses.networking.k8s.io`, and `secrets`
   were all confirmed empty in the namespace; `ingressroutes.traefik.io` (the
   Traefik CRD is registered on this cluster) was also confirmed empty. A
   namespace's Kubernetes-generated built-ins (`kube-root-ca.crt` ConfigMap,
   `default` ServiceAccount) are expected and are not application resources.
7. **Post-apply convergence plan** — a further real `terraform plan` (also a
   live HCP/cluster interaction, gated the same as step 2, not run
   automatically) reported `No changes. Your infrastructure matches the
   configuration.`; its JSON rendering showed exactly the same two managed
   resources, both with `.change.actions == ["no-op"]`, and zero non-no-op
   changes elsewhere.

### Rollback

Kubernetes namespace deletion can remove **all** namespaced content in one
action — not only what Terraform created. `-target` is therefore **not**
used as the normal rollback strategy; a full, untargeted plan is required so
nothing outside `module.homestreamlab`'s own two resources is silently swept
in or missed.

**Case A — immediate, same-issue rollback (before HomeStreamLab has ever been
deployed into the namespace):**

1. Inventory the namespace first and prove no application workload exists
   beyond the ResourceQuota and Kubernetes-generated built-ins.
2. Revert/remove the `module "homestreamlab"` block from `main.tf`.
3. Run a normal, full `terraform plan` (no `-target`), saving both the
   binary plan and its JSON, exactly as in the forward-apply flow above.
4. Fail closed unless the plan JSON shows **exactly** the two expected
   deletes and **zero** other changes anywhere.
5. Apply only after a separate, explicit approval distinct from the plan
   review.

**Case B — later rollback (HomeStreamLab may by then have been deployed into
the namespace, from its own separate repository):**

1. **Stop.** Do not delete the namespace automatically or as a routine
   Terraform operation.
2. Coordinated application decommission/inventory must happen first, from
   the `homestreamlab` application repository's own process.
3. Only after the namespace is independently proven safe to remove may the
   platform configuration be reverted here and a full (untargeted) destroy
   plan reviewed, under the same fail-closed JSON gate and separate apply
   approval as Case A.

Do not run a broad `terraform destroy` as a routine rollback in either case.

## Verifying against HCP Terraform

This sequence has been run against the live `homelab-platform` workspace with
the results recorded in [Verification status](#verification-status). It
remains the procedure for re-verifying after any change to this root module.

Only after [HCP workspace setup](#hcp-workspace-setup) confirms Local mode:

```sh
cd terraform/platform
export TF_CLOUD_ORGANIZATION=<your-hcp-organization>

terraform init
terraform validate
terraform plan
```

Expected:

- `init` — successful initialisation against HCP Terraform, providers installed,
  `.terraform.lock.hcl` unchanged;
- `validate` — `Success! The configuration is valid.`;
- `plan` — **`No changes. Your infrastructure matches the configuration.`**

The plan reports no changes because the configuration matches the
workspace's current state — for the empty baseline (issue #6) that meant no
resources on either side; after issue #8's apply it means the
`homestreamlab` Namespace and ResourceQuota already exist and match
`main.tf` exactly (see
[`homestreamlab` namespace instantiation](#homestreamlab-namespace-instantiation-issue-8)).
`kubeconfig_path` still has to be set — it has no default — which is what
proves the machine-specific value is wired through a variable rather than
committed.

Then, in the HCP UI, confirm that **the `terraform plan` created no new run**:
compare the Runs list against the baseline recorded during setup. The newest run
must be unchanged and there must be no entry near the time of the plan. Local
execution mode creates no remote runs; a new run would mean the workspace is not
in Local mode.

## Before committing

`validate.sh` deliberately does not require the lockfile to be staged — during
implementation it is legitimately untracked. Prove that separately, and review
the working tree **before** touching the index:

```sh
git status --short
git diff --stat
git diff
git ls-files --others --exclude-standard
git status --ignored --short -- terraform/
```

Stage explicit paths only — never `git add -A`:

```sh
git add terraform/platform/main.tf terraform/platform/versions.tf \
        terraform/platform/providers.tf terraform/platform/variables.tf \
        terraform/platform/terraform.tfvars.example terraform/platform/validate.sh \
        terraform/platform/.terraform.lock.hcl \
        docs/terraform-runbook.md \
        .gitignore .env.example README.md CLAUDE.md
git rm terraform/platform/.gitkeep
```

`git rm` removes the file from both the index and the working tree; `git rm
--cached` would leave a stale untracked `.gitkeep` behind.

Then check the staged set. Both commands actually block — neither is a mere
report:

```sh
git diff --cached --name-only | grep -Fxq 'terraform/platform/.terraform.lock.hcl' \
  && echo "lockfile staged" \
  || { echo "lockfile NOT staged — fix before commit"; exit 1; }

if git diff --cached --name-only \
     | grep -E '\.tfvars$|\.tfstate|(^|/)kubeconfig$|\.kubeconfig$|(^|/)\.kube/|^\.terraform/|\.tfplan$|(^|/)credentials\.tfrc\.json$|(^|/)\.terraform\.d/'; then
  echo "LEAK — do not commit"
  exit 1
fi
echo "staged set clean"
```

`grep -Fxq` is a fixed-string, whole-line match — `.terraform.lock.hcl` is
otherwise a regex where every `.` matches any character, which could
false-match an unrelated path.

### Why the lockfile is committed

`.terraform.lock.hcl` is version-controlled on purpose, and `.gitignore` says so
explicitly. The `~> 3.2` constraints allow a range; the lockfile records the
exact provider versions actually selected, together with their checksums, so
issues #7 and #8 resolve the same ones and a tampered provider artifact fails
`terraform init`. It contains public registry metadata, not credentials —
being Terraform-generated is not by itself a reason to ignore a file.

## Rollback

Three independent layers.

**Repository** — fully reversible, nothing on the host or in the cluster changes:

```sh
git checkout -- .
git restore --staged .
git branch -D feature/terraform-hcp-workspace-bootstrap
```

**Local, unversioned state** — regenerable, safe to delete:

```sh
rm -rf terraform/platform/.terraform        # provider cache and cached backend config
rm -f  terraform/platform/terraform.tfvars  # local configuration only
rm -f  "$HOME/.kube/homelab-k3s.yaml"       # the kubeconfig copy
```

Deleting the kubeconfig copy does **not** revoke the credential — the k3s admin
client certificate stays valid. Real revocation means resetting k3s (see
[`docs/k3s-runbook.md`](./k3s-runbook.md#destructive-uninstall--reset-procedure)).

**HCP workspace** — an external system, changed only with explicit intent:

- The cheapest rollback is not binding at all: if the provenance preflight fails,
  no `terraform init` runs and there is nothing to undo.
- This applied to the workspace's empty-state period only (through issue #7).
  Since issue #8's apply, the workspace's state is **not** empty: deleting
  the workspace now would orphan the real `homestreamlab` Namespace and
  ResourceQuota it manages. Removing those resources first (see
  [`homestreamlab` namespace instantiation → Rollback](#homestreamlab-namespace-instantiation-issue-8))
  is a prerequisite to any workspace deletion, not an afterthought.
- Switching Execution Mode back to Remote is not a rollback — it violates
  ADR-0001 and breaks every apply against this cluster.

## Safety notes

- Terraform runs **locally**. Remote execution is not used, and HCP Terraform's
  runners cannot reach this LAN-only k3s API (ADR-0001).
- The kubeconfig copy is a **cluster-admin client credential**. Keep it at mode
  `0600`, outside the repository, and never print its contents.
- Terraform state is stored in HCP Terraform, a third-party service. It was
  empty through issue #7; issue #8's apply is what first made it describe
  real cluster resources (the `homestreamlab` Namespace and ResourceQuota).
- No machine-specific value ever goes into an HCP workspace variable.
- This issue changes no host service: no systemd unit, no `/etc`, no k3s, no UFW,
  no Docker. The only host-touching step is the user-owned kubeconfig copy, which
  creates a file under `$HOME`.

## Tests

```sh
bash terraform/platform/validate.sh
bash terraform/modules/namespace-resourcequota/plan-check.sh
```

There are no unit tests for the root module: it declares no resources and no
logic, so the meaningful behavioural checks are formatting, configuration
validity, the provider lock, and the leak gate — which is exactly what
`validate.sh` runs (now also covering every `terraform/modules/*/` child
module, including `namespace-resourcequota`). The live `terraform init` and
empty `terraform plan` against HCP Terraform are covered under
[Verifying against HCP Terraform](#verifying-against-hcp-terraform).

The `namespace-resourcequota` module does declare real resources, so it has
its own behavioural check: `plan-check.sh`, asserting the exact expected plan
output — see [Namespace Pattern module](#namespace-pattern-module) for its
precise contract.

ShellCheck is not assumed to be installed on the host. Run it in a container:

```sh
docker run --rm -v "$PWD:/mnt:ro" -w /mnt koalaman/shellcheck:stable \
  terraform/platform/validate.sh \
  terraform/modules/namespace-resourcequota/plan-check.sh
```

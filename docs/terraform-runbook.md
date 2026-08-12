# Terraform runbook

The Platform Terraform Workspace: HCP Terraform remote state with **Local**
execution mode, and the `kubernetes` and `helm` providers pointed at this host's
k3s cluster. The root module lives in
[`terraform/platform/`](../terraform/platform/).

This bootstrap deliberately declares **no Kubernetes resources**. The reusable
namespace and ResourceQuota pattern is issue #7; the `homestreamlab` namespace
placeholder is issue #8.

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

**A permanent limitation, independent of the verification above:** because the
configuration contains no resources or data sources that require Kubernetes API
operations, the empty baseline plan — live or repo-local — is not evidence of
live provider-to-cluster connectivity. The first real evidence arrives with
issue #7's first resource.

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
| `versions.tf` | `required_version`, the `cloud` block, provider constraints |
| `providers.tf` | `kubernetes` and `helm` provider configuration |
| `variables.tf` | `kubeconfig_path` (required), `kube_context` (defaults to `default`) |
| `terraform.tfvars.example` | committed template, placeholders only |
| `validate.sh` | repo-local validation: fmt, validate, leak gate |
| `.terraform.lock.hcl` | committed provider lock — see [below](#why-the-lockfile-is-committed) |

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

The plan is empty because the configuration declares no resources and the new
workspace's state is empty. `kubeconfig_path` still has to be set — it has no
default — which is what proves the machine-specific value is wired through a
variable rather than committed.

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
git add terraform/platform/versions.tf terraform/platform/providers.tf \
        terraform/platform/variables.tf terraform/platform/terraform.tfvars.example \
        terraform/platform/validate.sh terraform/platform/.terraform.lock.hcl \
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
- While the workspace's state is empty, deleting it (Settings → Destruction and
  Deletion) destroys no real infrastructure.
- After issues #7 and #8 apply resources this is no longer true: deleting the
  workspace would orphan Terraform-managed cluster resources.
- Switching Execution Mode back to Remote is not a rollback — it violates
  ADR-0001 and breaks every apply against this cluster.

## Safety notes

- Terraform runs **locally**. Remote execution is not used, and HCP Terraform's
  runners cannot reach this LAN-only k3s API (ADR-0001).
- The kubeconfig copy is a **cluster-admin client credential**. Keep it at mode
  `0600`, outside the repository, and never print its contents.
- Terraform state is stored in HCP Terraform, a third-party service. It is empty
  for this issue; from issue #7 onward it will describe cluster resources.
- No machine-specific value ever goes into an HCP workspace variable.
- This issue changes no host service: no systemd unit, no `/etc`, no k3s, no UFW,
  no Docker. The only host-touching step is the user-owned kubeconfig copy, which
  creates a file under `$HOME`.

## Tests

```sh
bash terraform/platform/validate.sh
```

There are no unit tests for this component: the module declares no resources and
no logic, so the meaningful behavioural checks are formatting, configuration
validity, the provider lock, and the leak gate — which is exactly what
`validate.sh` runs. The live `terraform init` and empty `terraform plan` against
HCP Terraform are covered under
[Verifying against HCP Terraform](#verifying-against-hcp-terraform).

ShellCheck is not assumed to be installed on the host. Run it in a container:

```sh
docker run --rm -v "$PWD:/mnt:ro" -w /mnt koalaman/shellcheck:stable \
  terraform/platform/validate.sh
```

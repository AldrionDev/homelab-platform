# Platform Runbook

The operator-facing sequence that ties this repository's five platform
components — k3s, dnsmasq, the local registry, the Platform Terraform
Workspace, and the generic backup/restore mechanism — into one bootstrap
order, day-to-day operating procedure, disaster-recovery decision flow, and
new-project onboarding convention.

Each component has its own detailed runbook with the full verification
status, failure paths, and rollback procedures:
[`docs/k3s-runbook.md`](./k3s-runbook.md),
[`docs/dnsmasq-runbook.md`](./dnsmasq-runbook.md),
[`docs/registry-runbook.md`](./registry-runbook.md),
[`docs/terraform-runbook.md`](./terraform-runbook.md),
[`docs/backup-runbook.md`](./backup-runbook.md). This document sequences and
cross-references them; it does not replace them — follow the linked runbook
for any command shown here as a large, fail-closed host transaction.

## Scope

This repository is **platform-only**. Everything below is generic platform
operation and onboarding — no HomeStreamLab-specific command, value,
configuration, or worked onboarding example appears anywhere in this
document. Onboarding a project always uses generic `<project>` placeholders.

HomeStreamLab-specific onboarding — its Dockerfile, its Jenkinsfile, its
IngressRoute, its Secrets, its own application Terraform workspace — belongs
in the separate `homestreamlab` repository, never here. This repository does
not add HomeStreamLab app deployment, HomeStreamLab Dockerfiles, a
HomeStreamLab Jenkinsfile, a HomeStreamLab app Terraform workspace, or app
Secrets/IngressRoute/database deployment/app manifests of any kind (see
`CLAUDE.md`).

## Fresh-machine bootstrap

Four ordered phases.

### 1. k3s install

```sh
sudo K3S_VERSION=vX.Y.Z+k3sN HOST_LAN_IP=<your-lan-ip> bash k3s/install.sh
```

Both variables are required, with no defaults (`k3s/install.sh`). Re-running
is safe: the script inspects the existing installation and resolves to
`noop` or `mismatch` — it never silently reinstalls (`docs/k3s-runbook.md`,
"Re-running the script").

Verify:

```sh
sudo k3s kubectl get nodes
```

Expect one node, `Ready`.

### 2. dnsmasq

```sh
sudo HOST_LAN_IP=<your-lan-ip> HOMELAB_DOMAIN=<your-domain> bash dnsmasq/install.sh
```

Both variables are required, with no defaults (`dnsmasq/install.sh`).
Re-running is likewise safe: `noop` or `mismatch`, never a silent overwrite
(`docs/dnsmasq-runbook.md`, "Install").

Verify:

```sh
sudo HOST_LAN_IP=<your-lan-ip> HOMELAB_DOMAIN=<your-domain> bash dnsmasq/smoke-test.sh
```

Host-local verification needs no firewall change. Letting a **separate** LAN device
use this host as its resolver does: run the standalone, `flock`-serialised
`dnsmasq/lan-ufw-install.sh` (rolled back with `dnsmasq/lan-ufw-rollback.sh`), which
opens exactly the derived `<LAN_SUBNET> -> <HOST_LAN_IP>:53/udp+tcp on
<LAN_INTERFACE>` rules and touches nothing else — see
[`docs/dnsmasq-runbook.md`](./dnsmasq-runbook.md#lan-dns-firewall-access-separate-lifecycle).
It is not part of the dnsmasq service lifecycle and is not required for the smoke
test above. On the reference host this lifecycle has been runtime-verified end to end
(install → no-op → rollback → reinstall, final state **installed**); resolution from
a genuinely separate LAN client is not yet verified — see the runbook's
[Verification status](./dnsmasq-runbook.md#verification-status).

### 3. local registry

Four sub-steps — registry up, Docker daemon trust, k3s registry trust, then
verification.

**a. Registry up**, run from the repository root:

```sh
docker compose -f registry/docker-compose.yml --env-file .env up -d
docker compose -f registry/docker-compose.yml --env-file .env ps
```

`HOST_LAN_IP` must be set in `.env` first (copy `.env.example`) — the
compose file refuses to start without it rather than falling back to a
wildcard bind (`registry/docker-compose.yml`). `--env-file .env` is required
in every invocation: a bare `.env` resolves relative to `registry/`, not the
repository root (`docs/registry-runbook.md`, "Starting and stopping").

**b. Docker daemon trust.** The registry serves plain HTTP; Docker treats
every non-loopback registry as HTTPS by default, so `docker push` fails
until the daemon is told to trust this endpoint. This is a manual,
one-time, host-level transaction — not scripted by this repository. Copy
the full fail-closed block from `docs/registry-runbook.md`, section
"Docker daemon trust", and run it as a unit with `HOST_LAN_IP` set.

**c. k3s registry trust.** containerd — the runtime k3s actually runs Pods
with — never reads `/etc/docker/daemon.json`, so a separate trust step is
required for k3s itself: `/etc/rancher/k3s/registries.yaml` must name the
registry as an `http://` mirror. This is also a manual, fail-closed
transaction that **restarts k3s** (stopping every workload on this
single-node cluster for the duration) — copy the full block from
`docs/k3s-runbook.md`, section "Local registry trust" → "Setup
transaction", and run it as a unit with `HOST_LAN_IP` set.

**d. Verification** — two runs of the pull test, one on each side of the
k3s restart the trust transaction just performed:

```sh
HOST_LAN_IP=<your-lan-ip> KUBECONFIG=/path/to/k3s.yaml bash k3s/registry-pull-test.sh
```

The script refuses an ambient kubectl context and requires the target
cluster's node InternalIP to equal this host's own default-route source
address, so a foreign cluster cannot produce a false pass
(`docs/k3s-runbook.md`, "Verifying the registry trust"). Follow that
section's full flow — Run A, the verification restart, the post-restart
persistence checks, then Run B — before treating registry trust as
confirmed.

### 4. Terraform init/apply

Repo-local check (never contacts HCP Terraform or the cluster):

```sh
bash terraform/platform/validate.sh
```

Make a user-owned kubeconfig copy Terraform can read (k3s writes
`/etc/rancher/k3s/k3s.yaml` `root:root 0600`):

```sh
mkdir -p "$HOME/.kube"
sudo install -m 600 -o "$(id -un)" -g "$(id -gn)" \
  /etc/rancher/k3s/k3s.yaml "$HOME/.kube/homelab-k3s.yaml"
```

Point Terraform at it via a gitignored `terraform.tfvars`:

```sh
cp terraform/platform/terraform.tfvars.example terraform/platform/terraform.tfvars
# edit terraform.tfvars: kubeconfig_path = "/home/<you>/.kube/homelab-k3s.yaml"
```

Confirm the `homelab-platform` HCP workspace exists in **Local** execution
mode (a manual, one-time UI transaction — see `docs/terraform-runbook.md`,
"HCP workspace setup"; ADR-0001 explains why Local mode is required: HCP
Terraform's cloud-hosted runners cannot reach this LAN-only k3s API). Then:

```sh
cd terraform/platform
export TF_CLOUD_ORGANIZATION=<your-hcp-organization>

terraform init
terraform validate
terraform plan
```

Review the plan, then `terraform apply`. For a more rigorous, reviewable
apply — save the plan (`terraform plan -out=<file>`), inspect it as JSON
(`terraform show -json <file>`) before trusting the human-readable summary,
and apply that exact saved plan (`terraform apply <file>`) rather than
recomputing a new one — see `docs/terraform-runbook.md`. The same rigor
applies to any deliberate apply against this workspace.

## Day-to-day operations

**Cluster health:**

```sh
sudo k3s kubectl get nodes
sudo k3s kubectl get pods -n <namespace>
```

(`docs/k3s-runbook.md`; the namespaced `get pods` form is the same flag
pattern used by this repo's own orphan-artifact check in
`k3s/registry-pull-test.sh`'s runbook section, generalized from `-n
default` to any namespace.)

**Logs:**

```sh
sudo journalctl -u k3s          # or -f to follow
journalctl -u dnsmasq
docker compose -f registry/docker-compose.yml --env-file .env logs -f
```

**Restarting k3s:**

```sh
sudo systemctl restart k3s
```

Stops the control plane and every workload on this single-node cluster for
the duration (`docs/k3s-runbook.md`). Registry trust survives the restart
without any extra step: k3s reads `/etc/rancher/k3s/registries.yaml` at
startup and regenerates containerd's
`.../certs.d/<registry>/hosts.toml` from it on every start
(`docs/k3s-runbook.md`, "Local registry trust" → "The mechanism").

**Registry inspection/logs:**

```sh
docker compose -f registry/docker-compose.yml --env-file .env ps
docker compose -f registry/docker-compose.yml --env-file .env logs -f
docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' homelab-registry
curl --fail --silent --show-error \
  --retry 10 --retry-delay 1 --retry-connrefused \
  "http://<HOST_LAN_IP>:5000/v2/"
```

(`docs/registry-runbook.md`, "Starting and stopping" / "Verifying".)

**Pruning old images / build cache.** These are standard Docker CLI
operations — this repository does not script or test them. Two independent
axes control scope, per this host's locally installed
`docker image prune --help` / `docker builder prune --help`: `-a`/`--all`
switches the target set from *dangling only* to *all unused*; `--filter
until=<duration>` is a time filter applied within whichever target set is
already selected — it does not by itself broaden dangling-only to
all-unused. Always inspect before pruning:

```sh
docker images -f dangling=true
docker system df
```

Images:

```sh
docker image prune                              # dangling images only
docker image prune --filter until=<duration>     # dangling only, time-filtered
docker image prune -a                            # all unused images, not just dangling ones
docker image prune -a --filter until=<duration>  # all unused, time-filtered — broadest
```

`-a` can remove images still wanted for a rebuild — confirm with the
read-only inspection commands above before using it.

Build cache, same four combinations, plus a narrower alternative that
retains a target amount of cache instead of an all-or-nothing/time cutoff:

```sh
docker builder prune                              # dangling cache only
docker builder prune --filter until=<duration>     # dangling only, time-filtered
docker builder prune -a                            # all unused build cache, not just dangling ones
docker builder prune -a --filter until=<duration>  # all unused, time-filtered — broadest
docker builder prune --keep-storage <bytes>        # narrower: retain a target cache size
```

**Registry-side garbage collection is not implemented or documented as a
capability of this repository.** `docs/registry-runbook.md`, "Delete,
upload purge, and garbage collection": reclaiming unreferenced blob disk
space "requires a garbage collection run, which is deliberately out of
scope here... disk usage grows monotonically until someone runs garbage
collection manually." Nothing here automates or schedules it.

`docker compose up` on this host's installed Compose (5.4.0) exposes a
`--dry-run` flag ("Execute command in dry run mode" per its own `--help`
output) — usable to preview the registry start/reconciliation step before
running it for real. No semantics beyond that `--help` line are claimed.

## Disaster recovery

A decision flow, not a blind reinstall.

### A. The host does not boot at all

- Platform scripts cannot run until there is a working OS/environment —
  `k3s/install.sh` and `dnsmasq/install.sh` both require a booted host with
  systemd as PID 1, root access, and standard tooling in `PATH` before they
  do anything else. There is nothing in this repository to run yet.
- Host/OS-level rescue and hardware diagnosis are **outside this
  repository's scope** — no distro-specific rescue commands are documented
  here, because none are proven by this repo.
- If the existing disk/state is readable from a rescue or recovery
  environment, **preserve it before reinstalling or reformatting anything**.
  A boot failure alone is not evidence that platform state (the k3s
  datastore, dnsmasq config, the registry volume, any locally staged
  backups) should be discarded.
- Move to fresh/replacement-host bootstrap (below) only once the existing
  installation is determined unrecoverable, or the operator deliberately
  chooses a rebuild.

### B. The host boots and its disk is reachable

Diagnose before mutating anything:

```sh
sudo systemctl status k3s
sudo journalctl -u k3s
ls -la /var/lib/rancher/k3s /etc/rancher/k3s   # present and readable?
systemctl status dnsmasq
docker compose -f registry/docker-compose.yml --env-file .env ps
docker compose -f registry/docker-compose.yml --env-file .env logs
```

If state is intact, the fix is usually restarting the affected service, not
reinstalling.

**k3s and dnsmasq have a guarded, provable idempotency contract.**
`k3s/install.sh` and `dnsmasq/install.sh` are both documented as
transactional: they inspect the existing installation first and resolve to
exactly `noop` (already correct, no mutation) or `mismatch` (refuse, exit
1, no mutation) — they never silently reinstall over live state
(`docs/k3s-runbook.md` "Re-running the script"; `docs/dnsmasq-runbook.md`
"Install"). Re-running them against intact state is safe specifically
because of this guard.

**Docker Compose does not carry that same guarantee.** `docker compose ...
up -d` is documented as a no-op *against an unchanged configuration*
(`docs/registry-runbook.md`, "Starting and stopping"), but that is
conditional on the configuration actually being unchanged — Compose does
not give the registry the explicit `noop`/`mismatch` inspect-first contract
the guarded install scripts have, and it may recreate or restart containers
when it decides reconciliation is needed. In disaster recovery: inspect
`ps`/logs first (above); do not run `up -d` — or any other mutating
recovery command — against a stack that is already healthy; run it only
when actually bringing up or reconciling the registry is required. The
`--dry-run` flag noted above can preview what `up -d` would do first.

### C. Fresh/replacement-host bootstrap

Applies once branch A or B concludes the existing installation is
unrecoverable, or a genuine replacement host is being provisioned: follow
the [four-phase bootstrap sequence](#fresh-machine-bootstrap) above in
full.

### D. Explicit capability gap: k3s cluster state

This repository has **no k3s datastore/etcd snapshot or restore
mechanism**. If the disk holding `/var/lib/rancher/k3s` is lost, cluster
state — every Kubernetes object — is lost with it. Recovery is a fresh
bootstrap plus whatever workload data was independently backed up, never a
cluster-state restore.

The automatic kubeconfig backup `k3s/install.sh` takes before a fresh
install (`/etc/rancher/k3s/k3s.yaml.backup-<timestamp>`) is client-credential
backup only. Quoting `docs/k3s-runbook.md` directly: "A kubeconfig backup is
a copy of the admin **client credentials** only. It is not a cluster-state
backup and not a workload-data backup. It cannot restore a destroyed
cluster."

### E. Registry content is exposed to the same kind of loss

Registry image data lives in the Docker named volume
`homelab-registry-data` (`registry/docker-compose.yml`). What this
repository actually proves: the volume is **node-local** from this
repository's perspective, and this repository does **not** configure or
prove any independent/off-host durable backing for it. What it does
**not** prove: that the volume necessarily sits on the same physical disk
as k3s or anything else — Docker's storage driver/data-root placement is
host-level Docker configuration this repo neither sets nor inspects, so no
same-physical-disk claim is made here.

`docs/registry-runbook.md`, "Data and backups", calls the named volume "a
stable target" for "the future platform backup routine" — that routine
does not exist yet; nothing in this repository currently backs up this
volume. If the volume's backing storage is lost, registry contents are
lost with it. Repopulating images (rebuilding, re-pushing) is a
project-repository concern, not something this repo automates or
documents.

### F. Restoring workload data from backup

```sh
BACKUP_ARCHIVE=/absolute/path/to/backup-destination/<backup-id>-<timestamp>.tar.gz \
RECOVERY_TARGET=/absolute/path/to/a-new-recovery-target \
RESTORE_LIVE_DATA_PATH=/absolute/path/to/the-live-data-this-protects \
  bash backup/restore.sh -- /absolute/path/to/workload-validator --flag value
```

(`backup/restore.sh`, `docs/backup-runbook.md` "Restore usage".)

**Survivability wording.** ADR-0004 requires `BACKUP_DESTINATION` to be a
separate, pre-existing, `0700` directory from the live data path — that
proves isolation from the *source*, not survival of a *node or disk
failure*. A destination on the same disk as the workload it protects is
lost in the same failure. Node/disk-loss recovery is only possible when the
backup destination's storage remains accessible after the failure — an
external drive, a network share, another host — which is an operator
configuration choice this repository does not enforce or default.

**Restore boundary.** `backup/restore.sh` extracts and validates a backup
into a separate, initially non-existing Recovery Target
(`RECOVERY_TARGET` "must not currently exist" — `docs/backup-runbook.md`
"Restore usage"). It does **not** overwrite the live data path, promote the
Recovery Target into production, restart an application against it, or
perform any workload-specific cutover. Moving validated recovered data into
a live workload is project/workload-specific and belongs in that project's
own repository and runbook — `backup/restore.sh` alone does not complete an
application recovery.

## Onboarding a new project

Generic `<project>` placeholders throughout — see [Scope](#scope).

**Namespace + ResourceQuota.** Add a `module` block in
`terraform/platform/main.tf` calling
`terraform/modules/namespace-resourcequota/`:

```hcl
module "<project>" {
  source = "../modules/namespace-resourcequota"

  project_name = "<project>"

  cpu_request    = "<cpu-request>"
  cpu_limit      = "<cpu-limit>"
  memory_request = "<memory-request>"
  memory_limit   = "<memory-limit>"
}
```

All five inputs are required, with no defaults
(`terraform/modules/namespace-resourcequota/variables.tf`). The module
creates a `Namespace` named exactly `project_name` and a matching
`ResourceQuota` named `"<project_name>-quota"` in that namespace
(`terraform/modules/namespace-resourcequota/main.tf`).

**Ownership boundary.** This module block lives in, and is applied by, the
existing `homelab-platform` HCP workspace (Local execution mode) —
namespace and quota policy is **platform-owned**. It must never be
duplicated into, or moved to, the project's own Terraform workspace.

**Registry naming convention:** `<project>/<image>:<tag>`. The registry
endpoint (LAN IP or hostname) is deliberately excluded from the convention
— it is host-specific and environment-dependent, while `<project>/<image>`
is the portable, stable part every project references (ADR-0003).

**HCP Terraform workspace convention for project-owned Terraform:**
`<project>-k8s`, Local execution mode (ADR-0002, ADR-0001) — for Terraform
that lives in and is applied from the project's own repository (e.g. its
application resources). This is a separate workspace from, and not a
replacement for, the platform's `homelab-platform` workspace that owns the
namespace/quota above.

**Caveat.** No project has actually onboarded through a separate
`<project>-k8s` workspace yet. This section documents the committed
convention (ADR-0002), not a runtime-exercised procedure.

## Out of scope

HomeStreamLab-specific onboarding — Dockerfile, Jenkinsfile, IngressRoute,
Secrets, database deployment, app manifests, and its own application
Terraform workspace — belongs entirely in the separate `homestreamlab`
repository. Nothing in this document, and nothing this repository adds,
performs any of that (`CLAUDE.md`, "Do not add").

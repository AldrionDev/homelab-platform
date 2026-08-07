# homelab-platform

A project-independent local home lab platform layer: single-node k3s, a local
Docker registry, dnsmasq-based local DNS, Terraform-managed namespaces, and a
generic backup routine.

This repository contains **platform only**. It intentionally has no
application-specific deployment code — projects such as `homestreamlab` are
deployed onto this platform from their own separate repositories.

## Status

**Bootstrapping.** Single-node k3s, the local Docker registry and k3s registry
trust are implemented and verified on a real host. Every other platform
component is still planned.

See [`CLAUDE.md`](./CLAUDE.md) for the current milestone, scope, and planned
platform pieces.

## k3s

Install (both variables are required and have no defaults):

```sh
sudo K3S_VERSION=vX.Y.Z+k3sN HOST_LAN_IP=<your-lan-ip> bash k3s/install.sh
```

Operate the service:

```sh
systemctl status k3s      # current state
systemctl start k3s       # start
systemctl stop k3s        # stop
journalctl -u k3s         # logs
```

Verify the cluster:

```sh
sudo k3s kubectl get nodes
```

Re-running the install script is safe: it inspects the existing installation
and either no-ops or refuses, never silently reinstalling or restarting.

Uninstalling is a **separate, destructive** procedure — it is not part of the
install script. See [`docs/k3s-runbook.md`](./docs/k3s-runbook.md) for that,
plus LAN access, kubeconfig backups, and troubleshooting.

### Local registry trust

For the cluster to pull from the local registry, k3s needs
`/etc/rancher/k3s/registries.yaml` to trust that plain-HTTP endpoint. This is
**separate from** the Docker daemon trust below: containerd, the runtime k3s
runs Pods with, never reads `/etc/docker/daemon.json`.

Creating the file and restarting k3s is a **manual, fail-closed host
transaction**, documented in
[`docs/k3s-runbook.md`](./docs/k3s-runbook.md#local-registry-trust). This
repository deliberately ships no script for it — restarting k3s stops the
control plane and every workload on this single-node cluster.

Verify it with two runs of the pull test, one on each side of a restart:

```sh
HOST_LAN_IP=<your-lan-ip> KUBECONFIG=/path/to/k3s.yaml \
  bash k3s/registry-pull-test.sh
```

Each run builds a throwaway image with a unique marker, pushes it, runs it as a
Pod, and checks the Pod resolved to exactly that image — so a cached image
cannot produce a false pass. The script refuses an ambient kubectl context and
requires the target to be **this host's** single-node k3s node — the node's
InternalIP must equal this host's default-route source address, so a foreign
cluster advertising a shared bridge address cannot pass. See
[Verifying the registry trust](./docs/k3s-runbook.md#verifying-the-registry-trust)
for the full flow, the persistence checks and the rollback procedures.

**Status: verified on a real host** — setup transaction, setup restart, Run A,
a separate verification restart, the post-restart persistence checks, and Run B
with a fresh image identity. The **rollback and failure-injection paths were
not runtime-exercised**; they are documented and statically checked only. See
[Verification status](./docs/k3s-runbook.md#verification-status) for the exact
limits of that evidence.

## Registry

A local, unauthenticated Docker registry for images built on this host. Set
`HOST_LAN_IP` in `.env` first (copy [`.env.example`](./.env.example)), then run
from the repository root:

```sh
docker compose -f registry/docker-compose.yml --env-file .env up -d
docker compose -f registry/docker-compose.yml --env-file .env stop
```

Verify the full push/pull/delete cycle:

```sh
HOST_LAN_IP=<your-lan-ip> bash registry/smoke-test.sh
```

Pushing from this host also needs a one-time Docker daemon change, because the
registry serves plain HTTP. That, along with operations, backups, the
destructive reset, and rollback, is in
[`docs/registry-runbook.md`](./docs/registry-runbook.md).

This has been exercised end to end on a real host: Compose startup, the
LAN-only port binding, `/v2/` readiness, the `unless-stopped` restart policy,
push, pull by immutable digest, manifest deletion, and the final `404`.

**Security scope.** This registry is intended for a **trusted, single-user
local area network only**. It **must not be exposed to the public internet**.
Any production or cloud use would require **authentication and TLS** first;
neither is configured here.

## Layout

- `docs/` — platform documentation and runbooks
  - [`docs/k3s-runbook.md`](./docs/k3s-runbook.md) — k3s install, operations,
    verification, and the destructive reset procedure
  - [`docs/registry-runbook.md`](./docs/registry-runbook.md) — registry
    operations, Docker daemon trust, reset, and rollback
- `k3s/` — k3s install script and the local-registry pull test
- `dnsmasq/` — local DNS configuration
- `registry/` — local Docker registry: `docker-compose.yml` and `smoke-test.sh`
- `terraform/platform/` — Terraform-managed namespaces and resource quotas
- `backup/` — local backup routine

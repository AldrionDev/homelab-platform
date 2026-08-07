# homelab-platform

A project-independent local home lab platform layer: single-node k3s, a local
Docker registry, dnsmasq-based local DNS, Terraform-managed namespaces, and a
generic backup routine.

This repository contains **platform only**. It intentionally has no
application-specific deployment code — projects such as `homestreamlab` are
deployed onto this platform from their own separate repositories.

## Status

**Bootstrapping.** Single-node k3s and the local Docker registry are
implemented and verified on a real host. Every other platform component is
still planned.

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
- `k3s/` — k3s configuration
- `dnsmasq/` — local DNS configuration
- `registry/` — local Docker registry: `docker-compose.yml` and `smoke-test.sh`
- `terraform/platform/` — Terraform-managed namespaces and resource quotas
- `backup/` — local backup routine

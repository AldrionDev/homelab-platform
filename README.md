# homelab-platform

A project-independent local home lab platform layer: single-node k3s, a local
Docker registry, dnsmasq-based local DNS, Terraform-managed namespaces, and a
generic backup routine.

This repository contains **platform only**. It intentionally has no
application-specific deployment code — projects such as `homestreamlab` are
deployed onto this platform from their own separate repositories.

## Status

**Bootstrapping.** No platform component is implemented or verified yet.

See [`CLAUDE.md`](./CLAUDE.md) for the current milestone, scope, and planned
platform pieces.

## Layout

- `docs/` — platform documentation and runbooks
- `k3s/` — k3s configuration
- `dnsmasq/` — local DNS configuration
- `registry/` — local Docker registry configuration
- `terraform/platform/` — Terraform-managed namespaces and resource quotas
- `backup/` — local backup routine

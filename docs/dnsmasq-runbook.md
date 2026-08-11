# dnsmasq runbook

Wildcard DNS for the home lab: `*.HOMELAB_DOMAIN` resolves to `HOST_LAN_IP` via a
dedicated dnsmasq drop-in, without editing the system's own dnsmasq configuration or
disturbing normal DNS resolution for anything else.

## Verification status

**Verified on a real host** with `HOST_LAN_IP=192.168.1.197` and
`HOMELAB_DOMAIN=homelab.home.arpa`:

- **Install**: the first reviewed attempt exposed one real bug —
  `/var/lib/homelab-platform` (the shared platform state root) did not exist, and
  `dnsmasq/install.sh` tried to create the dnsmasq-private directory beneath it with a
  single non-`-p` `mkdir`, which fails when its parent is missing. The failure-cleanup
  path left the host completely clean (confirmed: no managed `/etc` files, no
  `/var/lib/homelab-platform` tree, dnsmasq still inactive/disabled, `DropInPaths`
  still empty). After the fix (`dnsmasq/install.sh` now creates the platform state
  root explicitly, as its own step, before the component directory — see
  [Install](#install)) and a full Standards+Spec re-review, a real install succeeded:
  dnsmasq became active and enabled, and the installer's own inline post-install check
  (wildcard `dig`) passed.
- **Wildcard resolution**: a unique `*.homelab.home.arpa` query resolved exactly to
  `192.168.1.197`.
- **Public DNS forwarding**: `example.com` resolved successfully through dnsmasq.
- **Active/enabled state**: confirmed both directly after install and via
  `dnsmasq/smoke-test.sh`.
- **Normal resolver path**: this host's own normal resolver (never touched by this
  component) still resolved `example.com` throughout.
- **Rollback**: `dnsmasq/rollback.sh` stopped and disabled dnsmasq, removed the
  managed `homelab.conf` and systemd drop-in, `DropInPaths` returned to empty, the
  component state directory `/var/lib/homelab-platform/dnsmasq` was removed, and —
  correctly — the shared `/var/lib/homelab-platform` root was **not** removed. A
  direct query to `192.168.1.197:53` afterward failed with connection refused (nothing
  listening), and the host's normal DNS still worked.
- **Reinstall**: running `dnsmasq/install.sh` again afterward cleanly restored the
  installed/active/enabled state, and a second full `dnsmasq/smoke-test.sh` run passed
  with the same checks as the first.

**Not exercised: LAN-device resolution from a second physical device.** This host's
`ufw` is active with a default-deny inbound policy and currently admits no rule for
port 53 (see [LAN-device verification and UFW](#lan-device-verification-and-ufw)).
Issue #5 marks the other-LAN-device check as "if convenient," not required; no `ufw`
mutation was performed as part of this verification, and `dnsmasq/install.sh` never
performs one automatically. Do not treat LAN-device resolution as verified until that
separate, explicitly-approved firewall step is actually taken and re-tested from a
real second device.

## Prerequisites

- dnsmasq installed via your distro's package manager. This repository never installs
  packages — `dnsmasq/install.sh` fails closed with a clear error if the `dnsmasq`
  binary isn't present.
- `dig` (`dnsutils`/`bind-tools`, depending on distro) — required by
  `dnsmasq/install.sh`'s own post-install verification and by `dnsmasq/smoke-test.sh`.
- A systemd host (`systemctl` in `PATH`).
- `HOST_LAN_IP` (dotted-quad IPv4) and `HOMELAB_DOMAIN` (a multi-label DNS domain, e.g.
  `homelab.home.arpa` — see `.env.example` and ADR-0005) — both required, neither has
  a default.

## Install

```sh
sudo HOST_LAN_IP=<your-lan-ip> HOMELAB_DOMAIN=<your-domain> bash dnsmasq/install.sh
```

Re-running is safe: it inspects the existing installation and either no-ops (already
installed with the same values) or refuses with a clear reason (`docs/dnsmasq-runbook.md`
below covers every refusal case) — it never silently overwrites a differing config or
adopts an already-running dnsmasq it didn't set up itself.

**What it does**, in order (see `dnsmasq/lib.sh`/`dnsmasq/install.sh` for the exact
mechanism):

1. Validates `HOST_LAN_IP`/`HOMELAB_DOMAIN` and prerequisites.
2. Inspects the existing state (read-only) and decides `noop` / `mismatch` / `install`.
   The platform only ever takes ownership of dnsmasq's lifecycle from a **provably
   clean baseline** — inactive, disabled, and no prior platform state. An already
   active or enabled dnsmasq with no platform state is treated as a foreign,
   pre-existing deployment and refused outright, never adopted.
3. On `install`: stages the proposed `/etc/dnsmasq.d/homelab.conf` and runs
   `dnsmasq --test` against it (plus the real `/etc/dnsmasq.conf`) before touching
   anything under `/etc`.
4. Creates `/var/lib/homelab-platform/` (root:root, 0755) if it doesn't already
   exist — the shared, persistent platform state root, not owned by dnsmasq alone —
   then creates `/var/lib/homelab-platform/dnsmasq/` (root:root, 0700) beneath it,
   dnsmasq's own component-private directory. Each is an explicit `mkdir`, never a
   single `mkdir -p`, so a missing root is never created implicitly as a side effect
   of creating the component directory. If the root already exists but is not a
   directory, install fails closed before any mutation. Exact-byte copies of both
   managed files are then persisted in the component directory — this is what makes
   `dnsmasq/rollback.sh` provably safe later (see [Rollback](#rollback)).
5. Writes `/etc/dnsmasq.d/homelab.conf` and a systemd drop-in at
   `/etc/systemd/system/dnsmasq.service.d/homelab.conf`, `daemon-reload`s, then
   `enable`s and `start`s dnsmasq (tracked as separate steps, not one atomic
   `enable --now`).
6. Runs an inline post-install check (service active+enabled, one wildcard `dig`).

**If anything fails after the first mutation**, `install.sh` automatically rolls back
exactly what that invocation did — never leaving a silently half-installed DNS
configuration. See [Safety notes](#safety-notes).

### The dnsmasq configuration

`/etc/dnsmasq.d/homelab.conf`:

```
address=/<HOMELAB_DOMAIN>/<HOST_LAN_IP>
listen-address=<HOST_LAN_IP>
bind-interfaces
```

- `address=/domain/ip` matches the domain and **all** subdomains — this is what makes
  `*.HOMELAB_DOMAIN` resolve to `HOST_LAN_IP`.
- No `no-resolv`, `no-hosts`, or exclusive `server=` — dnsmasq's own default upstream
  forwarding (via this host's `/etc/resolv.conf`) stays intact for every other domain,
  so a client pointed at dnsmasq gets full normal DNS resolution for anything that
  isn't `*.HOMELAB_DOMAIN`.
- `listen-address` + `bind-interfaces` together force dnsmasq to bind only to
  `HOST_LAN_IP` — never `0.0.0.0`, which would expose it on every interface including
  any VPN or hotspot one (the same reasoning as `registry/docker-compose.yml`'s
  LAN-only port bind).

### Why the system's own dnsmasq.conf is never touched

`/etc/dnsmasq.conf` is never opened for writing by anything in this component, and the
whole `/etc/dnsmasq.d` directory is never `conf-dir`'d — only the single named
`homelab.conf` file is ever read or written. Instead, a systemd drop-in at
`/etc/systemd/system/dnsmasq.service.d/homelab.conf` overrides `ExecStart` to pass
**both** config files explicitly:

```
ExecStart=<the package's own ExecStart, read live from its unit file> --conf-file=/etc/dnsmasq.conf --conf-file=/etc/dnsmasq.d/homelab.conf
```

`man dnsmasq`: `-C`/`--conf-file` "stops dnsmasq from reading the default
configuration file... Multiple files may be specified by repeating the option" — so
both flags are required together, or dnsmasq would silently stop reading the system's
own `/etc/dnsmasq.conf` entirely. The base `ExecStart` is read from the package unit's
`FragmentPath` at install time, never hardcoded — if a package update changes it, a
re-run of `install.sh` detects the drift and refuses (`mismatch`) rather than silently
adopting or silently going stale; see [Changing values](#changing-host_lan_ip-or-homelab_domain).

The drop-in also adds an **additional** `ExecStartPre` alongside the package's own:

```
ExecStartPre=/usr/bin/dnsmasq --test --conf-file=/etc/dnsmasq.conf --conf-file=/etc/dnsmasq.d/homelab.conf
```

systemd only clears prior `ExecStartPre=` directives on an *empty* assignment, which
this drop-in never does — so the package's own default-file precheck still runs, and
this line additionally validates the actual two-file set. An ordinary
`systemctl restart dnsmasq`, run outside `install.sh`, now validates what will really
start, not just the package default.

## Operating the service

```sh
systemctl status dnsmasq
systemctl restart dnsmasq   # re-validates both config files first, see above
journalctl -u dnsmasq
```

## Verifying resolution

```sh
sudo HOST_LAN_IP=<your-lan-ip> HOMELAB_DOMAIN=<your-domain> bash dnsmasq/smoke-test.sh
```

Runs, read-only, no root required:

1. `dig @<HOST_LAN_IP> <unique-marker>.<HOMELAB_DOMAIN>` → must equal `HOST_LAN_IP`. A
   fresh marker every run, so a cached answer can't produce a false pass.
2. `dig @<HOST_LAN_IP> example.com` → must return a non-empty answer (proves dnsmasq's
   own upstream forwarding still works).
3. `systemctl is-active` / `is-enabled dnsmasq` → both true.
4. Plain `dig example.com` (this host's own normal resolver path, never touched by
   this component) → must still return an answer.

**Important — run wildcard queries against dnsmasq explicitly.** Do not rely on a
bare `dig anything.<HOMELAB_DOMAIN>` with no `@server` to prove this component works:
that query goes through this host's own configured resolver (`/etc/resolv.conf`),
which this component never changes — always use `dig @<HOST_LAN_IP> ...` (or point a
client's resolver at `HOST_LAN_IP` first) to actually exercise dnsmasq.

### LAN-device verification and UFW

To point another device on the LAN at this resolver, set its DNS server to
`HOST_LAN_IP`. This works for any client that queries its configured DNS server as
ordinary unicast DNS (Windows, Android, most Linux/IoT).

**This host's firewall currently blocks it.** `ufw` is active here with a default-deny
inbound policy and, as shipped, admits no rule for port 53 — confirmed read-only
during planning (`ufw status`, `/etc/ufw/user.rules`, `/etc/default/ufw`). Host-local
verification (`dig @<HOST_LAN_IP> ...` run *on* this host) still works regardless,
because this host's own traffic to its own LAN address is routed via `lo`
(`ip route get <HOST_LAN_IP>` shows `dev lo`), which `ufw` always allows — but a query
from a genuinely separate LAN device will be dropped until a LAN-scoped rule admits
UDP+TCP 53.

`dnsmasq/install.sh` **deliberately never touches `ufw`.** Opening port 53 is a
separate, explicitly-approved host mutation, scoped to the actual LAN
interface/subnet at the time it's performed (not assumed in advance) — e.g.:

```sh
sudo ufw allow in on <lan-iface> to any port 53 proto udp
sudo ufw allow in on <lan-iface> to any port 53 proto tcp
```

Only do this if LAN-device verification is actually wanted — issue #5's acceptance
criteria mark it "if convenient," not required.

## Changing `HOST_LAN_IP` or `HOMELAB_DOMAIN`

There is no in-place update. Re-running `install.sh` with different values against an
existing install is a `mismatch` by design — roll back first, then install with the
new values:

```sh
sudo bash dnsmasq/rollback.sh
sudo HOST_LAN_IP=<new-ip> HOMELAB_DOMAIN=<new-domain> bash dnsmasq/install.sh
```

## Rollback

```sh
sudo bash dnsmasq/rollback.sh
```

Takes no configuration — `rollback.sh` never requires `HOST_LAN_IP`/`HOMELAB_DOMAIN`.
The durable state in dnsmasq's own component directory,
`/var/lib/homelab-platform/dnsmasq/`, already holds the exact bytes of both managed
files, and every live path is fixed, so an operator rolling back to change values
doesn't need to supply the *old* ones just to remove the install.

**Ownership proof, not a comment marker.** A `# Managed by homelab-platform` comment
in a file only proves the content *looks like* something this platform would write —
it can't catch a hand-edit that preserves the comment. Rollback instead does a
byte-exact `cmp` of each live managed file against the copy recorded at install time.
If either file is missing, or either differs from its recorded copy, rollback refuses
**entirely** — neither file is touched, even the one that does match — and reports
manual recovery is required.

**Ordering, once both files are proven owned:**

1. `systemctl disable --now dnsmasq`, then an explicit `is-active`/`is-enabled` check
   confirming the disabled/inactive baseline — **before** any file is removed. The
   already-running process has the old config loaded in memory regardless of what
   happens to the files on disk until it's actually stopped, so stopping it first is
   what makes "fully restore the previous DNS behavior" (issue #5's AC) true rather
   than aspirational. If this step fails, rollback stops immediately: nothing is
   removed, manual recovery is required.
2. Remove `/etc/dnsmasq.d/homelab.conf` and the systemd drop-in.
3. `systemctl daemon-reload`.
4. Conditionally `rmdir` — **only** a directory the platform's own manifest recorded
   as created by the install transaction, and only if it's now empty. A directory the
   manifest doesn't name is left in place, full stop, even if it looks empty: an
   unnecessary leftover empty directory is preferred over deleting something
   creation-ownership can't prove.
5. Remove dnsmasq's own component state directory (`/var/lib/homelab-platform/dnsmasq/`)
   **last**, so any earlier refusal always leaves the one thing that proves ownership
   intact for a retry or manual recovery. **The shared platform state root,
   `/var/lib/homelab-platform/` itself, is never removed by rollback** — even though
   `install.sh` may have created it — since other platform components may come to rely
   on it existing.

After rollback, `dig @<HOST_LAN_IP> anything.<HOMELAB_DOMAIN>` fails to connect /
times out — nothing is listening on that address:port anymore — rather than returning
any particular DNS answer; that connection failure is the correct proof of rollback.
Plain `dig example.com` (this host's normal resolver, never touched) is unaffected.

To fully restore the intended running state afterward (e.g. after a rollback
demonstration during verification), simply re-run `dnsmasq/install.sh` with the same
values — rollback leaves exactly the clean baseline `install.sh` requires.

## Safety notes

- Host-level includes writing under `/etc` and `/var/lib`, `daemon-reload`,
  `enable`/`start`/`disable`ing dnsmasq — every one of these requires explicit
  approval per invocation; none of it happens automatically.
- `install.sh`'s own transaction is fail-closed: any failure after the first mutation
  triggers automatic cleanup of exactly what that invocation did, using the same
  byte-exact ownership proof `rollback.sh` uses — it never removes a file that no
  longer matches what it just wrote, and if the service can't be proven returned to
  its baseline, cleanup stops and reports manual recovery rather than guessing.
- No `ufw`/firewall mutation is ever automatic — see
  [LAN-device verification and UFW](#lan-device-verification-and-ufw).
- TLS, HTTPS, and application-specific ingress routing are explicitly out of scope for
  this component (issue #5).

## Tests

```sh
bash dnsmasq/lib.test.sh
bash dnsmasq/install.test.sh
bash dnsmasq/rollback.test.sh
```

Plain bash, no framework, no root/systemd/real `/etc` or `/var/lib` required — every
case runs in a fresh subshell against a tmpdir, with `systemctl`/`dnsmasq`/`dig`
shadowed. Covers: input validation; the `noop`/`mismatch`/`install` decision for every
branch (foreign/pre-existing dnsmasq, foreign drop-in, content drift including a
changed package `ExecStart` or changed `HOST_LAN_IP`/`HOMELAB_DOMAIN`, inconsistent
state); the rendered config and drop-in content, including the additive
`ExecStartPre`; the transactional install failure cleanup for a failure at every step
(including the split `enable`/`start` tracking and the case where restoring the
baseline itself fails); and rollback's ownership proof and ordering, including the
partial-match and manifest-directory-only-removal cases.

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

**LAN DNS firewall access (`dnsmasq/lan-ufw-*.sh`) — runtime-verified on this host,
final state INSTALLED.** With `HOST_LAN_IP=192.168.1.197`, `LAN_INTERFACE=wlan0`,
`LAN_SUBNET=192.168.1.0/24` (UFW 0.36.2), the full lifecycle was exercised on the
real host: a clean pre-apply baseline (no component state, no pre-existing DNS/53
user rule, dnsmasq healthy), a first `dnsmasq/lan-ufw-install.sh` (rc=0, exactly the
two `192.168.1.0/24 → 192.168.1.197:53/{udp,tcp} on wlan0` rules with the platform
ownership comments, `state.env` `PHASE=installed`), post-install ownership/state
verification (`/var/lib/homelab-platform/dnsmasq-lan-ufw` `root:root 0700`,
`state.env` `root:root 0600`, exactly one owned UDP + one owned TCP rule, the UFW
baseline diff containing only those two rules), a same-state re-run ("No changes
made", byte-identical UFW state, `PHASE=installed` unchanged), a real
`dnsmasq/lan-ufw-rollback.sh` (rc=0, both owned rules deleted, component state
removed, UFW state returned exactly to the pre-apply baseline), a real reinstall
(rc=0, both rules re-added, `PHASE=installed`), and a final installed-state check.
dnsmasq wildcard resolution (`192.168.1.197`), dnsmasq upstream forwarding, and this
host's normal resolver stayed healthy throughout. **The final host state is
INSTALLED, not rolled back.** See
[LAN DNS firewall access (separate lifecycle)](#lan-dns-firewall-access-separate-lifecycle)
for the full flow and the exact boundary.

**Not verified — deferred:** a **second physical LAN client** using
`192.168.1.197` as its resolver (unique `*.homelab.home.arpa` → host, a public
domain, and `http://homestreamlab.homelab.home.arpa` browser access) — no second
device was available. **Repository-local only:** every failure-injection path
(interrupted-install recovery, `PHASE=rolling_back` resume/failure, snapshot-read
failure, transactional mutation failure, lock contention beyond the tmpdir test).
`dnsmasq/install.sh` still never touches `ufw` itself.

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
bind-dynamic
```

- `address=/domain/ip` matches the domain and **all** subdomains — this is what makes
  `*.HOMELAB_DOMAIN` resolve to `HOST_LAN_IP`.
- No `no-resolv`, `no-hosts`, or exclusive `server=` — dnsmasq's own default upstream
  forwarding (via this host's `/etc/resolv.conf`) stays intact for every other domain,
  so a client pointed at dnsmasq gets full normal DNS resolution for anything that
  isn't `*.HOMELAB_DOMAIN`.
- `listen-address` + `bind-dynamic` together force dnsmasq to bind only to
  `HOST_LAN_IP` — never `0.0.0.0`, which would expose it on every interface including
  any VPN or hotspot one (the same reasoning as `registry/docker-compose.yml`'s
  LAN-only port bind).

#### Why `bind-dynamic` instead of `bind-interfaces`

At boot, dnsmasq's systemd unit can start before `HOST_LAN_IP` has actually
been assigned to the LAN interface. With `bind-interfaces`, dnsmasq requires
the configured address to already exist and fails to start
(`Cannot assign requested address`) if it doesn't; if this happens on every
boot-time attempt, repeated failures can exhaust systemd's start-limit,
leaving the unit enabled but failed for the rest of boot even after the
address becomes available seconds later. `dnsmasq` still binds only to
`HOST_LAN_IP`, never `0.0.0.0` — the same address-specific intent as before.

`man dnsmasq` directly documents that `bind-dynamic` automatically listens on
newly appearing interfaces/addresses, and upstream dnsmasq guidance
recommends `bind-dynamic` specifically for the `Cannot assign requested
address` startup case, since it can wait for the requested address/interface
to become available rather than requiring it up front. This is why
`bind-dynamic` was selected as the candidate fix for the boot-time race
described above.

This change does not alter systemd unit ordering or boot sequencing in any
way — dnsmasq's unit still starts whenever systemd schedules it; `bind-dynamic`
only changes how dnsmasq itself behaves if the configured address isn't yet
present when it does. Whether this actually resolves the race on a given host
across a real reboot is verified separately — see
[Verification status](#verification-status) for what has and has not been
confirmed.

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

**This host's firewall blocks it until a LAN-scoped rule is added.** `ufw` is active
here with a default-deny inbound policy and, as shipped, admits no rule for port 53.
Host-local verification (`dig @<HOST_LAN_IP> ...` run *on* this host) still works
regardless, because this host's own traffic to its own LAN address is routed via `lo`
(`ip route get <HOST_LAN_IP>` shows `dev lo`), which `ufw` always allows — but a query
from a genuinely separate LAN device is dropped until UDP+TCP 53 is admitted from the
LAN.

`dnsmasq/install.sh` **deliberately never touches `ufw`.** Opening port 53 is a
separate, explicitly-invoked host mutation with its own ownership state and its own
lifecycle lock — see the next section.

### LAN DNS firewall access (separate lifecycle)

`dnsmasq/lan-ufw-install.sh` and `dnsmasq/lan-ufw-rollback.sh` are a **standalone**
lifecycle. They never edit `/etc`, never call `systemctl`, and never touch the
dnsmasq service or its configuration — the dnsmasq install/rollback contract in the
rest of this runbook is completely unchanged. They exist solely to add or remove
exactly two narrowly-scoped UFW rules.

**Why it is separate from `dnsmasq/install.sh`.** Firewall exposure is a distinct
security decision with a different blast radius, a different approval, and its own
recoverable state. Coupling it into the dnsmasq service lifecycle would mean every
`dnsmasq/install.sh` re-run reasoned about firewall state, and every dnsmasq rollback
risked touching `ufw`. Keeping them apart means each lifecycle stays small and
independently verifiable.

**Invocation.**

```sh
sudo HOST_LAN_IP=<your-lan-ip> bash dnsmasq/lan-ufw-install.sh
sudo bash dnsmasq/lan-ufw-rollback.sh
```

`HOST_LAN_IP` is the only input and has no default. Rollback takes no configuration —
it reads the durable ownership descriptor.

**Concurrency.** Both scripts take a single exclusive, non-blocking `flock` on
`/run/homelab-platform-dnsmasq-lan-ufw.lock` **before** any UFW state is inspected,
and hold it through completion (including transactional cleanup). A second
install/rollback started while one is running refuses immediately with no mutation.

**Runtime discovery.** The LAN interface and its directly-connected subnet are
derived from `HOST_LAN_IP` at run time via `ip` — nothing is hard-coded. Discovery
fails closed unless **all** of the following hold: the exact IPv4 address exists on
exactly one interface; that address has global scope; the interface is not a
loopback; the derived subnet is a directly-connected (`scope link`) route on that
interface; and that interface also carries an IPv4 default route (so a Docker/CNI
bridge that merely has a connected route cannot be selected). A `/31` or `/32`
address is rejected (no usable LAN subnet); there is otherwise **no** minimum-prefix
policy — a `/8` LAN is accepted.

**Exact security boundary.** The only effective policy this lifecycle can ever
produce is:

```text
<LAN_SUBNET> -> <HOST_LAN_IP>:53/udp on <LAN_INTERFACE>
<LAN_SUBNET> -> <HOST_LAN_IP>:53/tcp on <LAN_INTERFACE>
```

Each rule carries a fixed platform ownership comment
(`homelab-platform:dnsmasq-lan-ufw udp/53` / `tcp/53`). It never adds an
unrestricted `ufw allow 53` / `Anywhere` DNS rule, and it treats **any**
non-owned UFW rule whose destination port covers 53 as foreign — a bare `53`,
`53/udp`, `53/tcp`, a range that spans 53 (`53:60/udp`, `50:53/tcp`) or a
comma list containing 53 (`53,67/udp`) all force `mismatch` / refusal
(`5353` and other unrelated ports do not).

**Ownership state.** `/var/lib/homelab-platform/dnsmasq-lan-ufw/state.env`
(`root:root 0600`), a fixed six-key schema
(`PHASE` ∈ {`installing`, `installed`, `rolling_back`}, `HOST_LAN_IP`,
`LAN_SUBNET`, `LAN_INTERFACE`, `UDP_COMMENT`, `TCP_COMMENT`).
It is **never** `source`d or `eval`uated — it is parsed key-by-key, every value is
revalidated on read, and the persisted comments must exactly equal the code-defined
ownership constants (the code constants, never the stored text, are the ownership
authority). A symlinked or non-regular state file/dir is refused; under root the
component dir/file must be `root:root` `0700`/`0600`. The shared
`/var/lib/homelab-platform/` root is created if absent but is **never** removed by
this component.

**PHASE state machine.** `PHASE` is one of `installing`, `installed`, `rolling_back`.

- **install** writes `PHASE=installing` *before* the first firewall mutation, and
  flips it to `PHASE=installed` only after both rules exist exactly, ownership is
  proven, no foreign DNS rule is present, and post-mutation verification passes.
- **normal rollback** requires `PHASE=installed` and **both** exact platform-owned
  rules present with no foreign state *before* it begins; it then atomically
  transitions `state.env` to `PHASE=rolling_back` *before* the first delete.
- `PHASE=rolling_back` is a supported, **resumable** recovery phase. If a delete or a
  verification fails, `state.env` stays at `PHASE=rolling_back` and re-running
  `dnsmasq/lan-ufw-rollback.sh` re-enters recovery mode and finishes. So a rollback
  that deleted UDP but failed on TCP is completed correctly by the next invocation —
  it never wedges into "can't roll back because both rules aren't present".
- `PHASE=installing` (interrupted install) and `PHASE=rolling_back` (interrupted
  rollback) are both **recovery states**: rollback removes whichever of the two owned
  rules (0, 1 or 2) are provably present, still refusing any foreign / drifted /
  ambiguous / duplicated rule, and only clears `state.env` once every owned rule is
  proven absent and the unrelated-rule fingerprint is unchanged. `PHASE=installed`
  is **not** weakened — it still requires both exact rules before starting.
- `classify_state` returns `mismatch` for a recorded `installing` or `rolling_back`,
  pointing the operator at `dnsmasq/lan-ufw-rollback.sh`.

**Fail-closed UFW reads.** Every firewall inspection works from an explicitly
captured snapshot: `LC_ALL=C ufw status` must exit 0 **and** its first line must be
`Status: active`, otherwise the operation aborts. A failed or later-inactive
`ufw status` is never allowed to degrade into "zero rules" — install will not treat
it as a clean baseline, and rollback/recovery will not treat it as "no owned rules"
or clear state. Snapshots are re-captured and re-validated at each safety boundary
(classification, before mutation, after each mutation, final verification).

**Cleanup armed before the first durable write.** `do_install` captures its
pre-state snapshot, then creates the component state directory, then arms the
EXIT/INT/TERM cleanup, and only then writes `state.env`. A failed initial state
write therefore unwinds cleanly: the component directory this run created is
removed, no UFW mutation has happened, and no malformed state is left to wedge a
later run. The shared `/var/lib/homelab-platform/` root is still never removed.

**Idempotency.** Re-running `dnsmasq/lan-ufw-install.sh` against the exact applied
state is a no-op (`classify_state` returns `noop` before any mutation).

**Mismatch / fail-closed.** A pre-existing foreign, partial, or differing DNS
firewall rule — or an unparseable `state.env`, or an unreadable firewall — is
refused, never silently adopted or overwritten.

**Transactional cleanup.** If the first rule is added and the second mutation fails,
the run removes only the exact rule it created (by stable spec, not by UFW number),
verifies the removal and that unrelated rules are untouched, and clears the recovery
state. If a clean result cannot be proven, it preserves `state.env` at
`PHASE=installing`, prints `MANUAL RECOVERY REQUIRED` with the exact outstanding
`ufw delete` command(s), and exits non-zero. Recovery is then
`sudo bash dnsmasq/lan-ufw-rollback.sh`.

**Verification (host, after a real apply).**

```sh
sudo LC_ALL=C ufw status
```

Expect exactly two rows of the form
`<HOST_LAN_IP> 53/udp on <LAN_INTERFACE>  ALLOW  <LAN_SUBNET>  # homelab-platform:dnsmasq-lan-ufw udp/53`
and the `tcp` twin — and every unrelated rule unchanged. Plain `ufw status` on
this host (UFW 0.36.2) renders the action as bare `ALLOW`; `ufw status numbered`
renders the same rule as `ALLOW IN`. The ownership matcher accepts either form but
still requires the exact destination IP, `53/<proto>`, interface, `ALLOW` action
and source subnet, plus the exact ownership comment.

**LAN-client verification — DEFERRED, not yet performed** (no second physical LAN
client was available). When one is: from a genuinely separate LAN device configured
to use `<HOST_LAN_IP>` as its DNS server —

1. Resolve a unique `<marker>.<HOMELAB_DOMAIN>` and confirm it returns `<HOST_LAN_IP>`.
2. Resolve a normal public domain (proves upstream forwarding still works).
3. Open `http://homestreamlab.homelab.home.arpa` and confirm the HomeStreamLab
   frontend responds.

**Rollback.**

```sh
sudo bash dnsmasq/lan-ufw-rollback.sh
```

Removes only the two platform-owned rules (by stable spec, so the second delete is
unaffected by the first renumbering), verifies both are gone and unrelated rules are
untouched, then clears the component state. Refuses when ownership or expected live
state cannot be proven.

### Verification status

**Repository-local (all four scripts):** `bash -n`; `bash dnsmasq/lan-ufw.test.sh`
(93 cases, fake `ufw`/`ip`/`flock`, tmpdir state, no root); `git diff --check`.

**Runtime-verified on this host** — `HOST_LAN_IP=192.168.1.197`,
`LAN_INTERFACE=wlan0`, `LAN_SUBNET=192.168.1.0/24`, UFW 0.36.2 — **final host state
INSTALLED**:

| Step | Evidence |
| --- | --- |
| Clean pre-apply baseline | no `/var/lib/homelab-platform/dnsmasq-lan-ufw` state; no pre-existing DNS/53 user rule; dnsmasq active+enabled; direct wildcard lookup → `192.168.1.197`; direct public-domain forwarding OK |
| First real install | `lan-ufw-install.sh` rc=0; exactly two rules added — `192.168.1.0/24 → 192.168.1.197:53/udp on wlan0` and the `tcp` twin — with the exact ownership comments; `state.env` `PHASE=installed` |
| Post-install ownership/state | component dir `root:root 0700`; `state.env` `root:root 0600`; exactly 1 owned UDP + 1 owned TCP rule; UFW baseline diff = only those two rules added; dnsmasq still active+enabled; wildcard / upstream / normal host DNS all healthy |
| Runtime idempotency | a second identical install rc=0, "No changes made", no "Rule added" output; owned count still 1 UDP + 1 TCP; `PHASE=installed` unchanged; `ufw` added-rule set byte-identical before/after |
| Real rollback | `lan-ufw-rollback.sh` rc=0; both owned rules deleted; component state removed; `ufw` added-rule set returned **exactly** to the pre-apply baseline; no owned rule left; dnsmasq active+enabled; wildcard + upstream DNS still OK |
| Real reinstall | rc=0; both owned rules re-added; `PHASE=installed` |
| Final installed verification | component dir `root:root 0700`; `state.env` `root:root 0600`; final UFW diff vs the original baseline = exactly the two intended DNS rules; dnsmasq active+enabled; wildcard lookup → `192.168.1.197`; public forwarding OK |

**Repository-local only — NOT exercised on the host:** interrupted-install recovery;
the `PHASE=rolling_back` resume path and its delete/verify failure injection;
`ufw status` snapshot-read failure injection; transactional mutation-failure cleanup
(`MANUAL RECOVERY REQUIRED`); lock contention beyond the single real-`flock`
tmpdir test.

**Deferred — NOT verified:** a **second physical LAN client** resolving a unique
`*.homelab.home.arpa` name to `192.168.1.197`, resolving a public domain, and
reaching `http://homestreamlab.homelab.home.arpa` in a browser — no second physical
LAN client was available.

## Changing `HOST_LAN_IP` or `HOMELAB_DOMAIN`

There is no in-place update. Re-running `install.sh` with different values against an
existing install is a `mismatch` by design — roll back first, then install with the
new values:

```sh
sudo bash dnsmasq/rollback.sh
sudo HOST_LAN_IP=<new-ip> HOMELAB_DOMAIN=<new-domain> bash dnsmasq/install.sh
```

The same guard applies whenever the *rendered configuration itself* changes —
for example a platform update to this component, not just a change in
`HOST_LAN_IP`/`HOMELAB_DOMAIN`. An existing installation whose on-disk
`homelab.conf` no longer byte-matches what the current `dnsmasq/install.sh`
would render reports `mismatch` and refuses to reinstall in place, by the
same `inspect_installation` logic. The supported way to pick up such a
change is the same rollback-then-reinstall procedure above, never a manual
edit of the managed files under `/etc`. Rolling back and reinstalling opens a
temporary window with no wildcard `*.HOMELAB_DOMAIN` resolution — see
[Rollback](#rollback) for exactly what is and isn't affected during that
window.

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
- No `ufw`/firewall mutation is ever automatic. `dnsmasq/install.sh` never touches
  `ufw`; LAN DNS firewall access is the separate, explicitly-invoked lifecycle in
  [LAN DNS firewall access (separate lifecycle)](#lan-dns-firewall-access-separate-lifecycle),
  which itself never touches the dnsmasq service or `/etc`.
- TLS, HTTPS, and application-specific ingress routing are explicitly out of scope for
  this component (issue #5).

## Tests

```sh
bash dnsmasq/lib.test.sh
bash dnsmasq/install.test.sh
bash dnsmasq/rollback.test.sh
bash dnsmasq/lan-ufw.test.sh
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

`dnsmasq/lan-ufw.test.sh` (93 cases) covers the separate LAN-UFW lifecycle with fake
`ufw`/`ip`/`flock` and tmpdir state (no root, no real firewall): input / root /
command-availability failures; the lock being acquired **before** any UFW inspection;
concurrent install and install-vs-rollback both refused without mutation (including
one case driving the real `flock` binary against a tmpdir lock); fail-closed LAN
discovery (absent / ambiguous address, loopback, non-global scope, connected-but-non-
default-route bridge, non-connected subnet, `/31` and `/32` rejected while `/8` is
accepted); `install`/`noop`/`mismatch` classification; hardened `state.env` parsing
(symlink / non-regular file, missing / duplicate / unknown key, control chars, bad
`PHASE`, non-canonical subnet, bad interface name, persisted-comment ≠ code constant,
strict root perms, and a proof the file contents are never executed); the
transactional install cleanup (UDP added / TCP fails → spec delete + state cleared;
delete also fails → `MANUAL RECOVERY REQUIRED` with state preserved at
`PHASE=installing`); **attempt-vs-success reconciliation** — a mutating `ufw allow`
that applies its rule but then returns non-zero: cleanup still discovers and removes
the live owned rule(s) by stable spec even though the success flag was never set
(UDP-applies-then-fails; UDP-applies-then-fails + delete also fails → `MANUAL
RECOVERY REQUIRED`, `PHASE=installing` kept; TCP-applies-then-fails after UDP
succeeds → both removed), and the outstanding-delete hint names every *attempted*
protocol; the cleanup being armed **before** the first `state.env` write
(injected write failure → component dir removed, no UFW mutation, next clean run not
wedged); `PHASE=installed` rollback and refusal cases; the `PHASE=rolling_back`
resumable recovery phase, incl. the regression where a rollback deletes UDP, fails on
TCP, and a second invocation finishes it; `PHASE=installing` / `PHASE=rolling_back`
recovery rollback for 0 / 1 / 2 owned rules and its refusals; fail-closed UFW
snapshots (a later `ufw status` that fails or reports inactive aborts and is never
seen as a clean baseline or as zero owned rules); foreign port-53 expression
detection (bare 53, ranges, comma lists — not `5353`); **the real plain `ufw status`
row shape** (bare `ALLOW`, no `IN` — the shape observed on the host during preflight)
recognized as owned by `owned_rule_count` / excluded by `list_foreign_dns_rules` and
the fingerprint / classified `noop` at `PHASE=installed`, plus the same for the
`ufw status numbered` `ALLOW IN` shape and per-field ownership rejection (wrong
subnet / iface / ip / proto / action / extra token); the unrelated-rules-untouched
invariant; that the shared `/var/lib/homelab-platform/` root is never removed; and
locale-independent parsing.

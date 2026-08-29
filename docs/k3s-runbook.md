# k3s runbook

Single-node k3s on bare metal, installed as a systemd service by
[`k3s/install.sh`](../k3s/install.sh).

## Verification status

The install script and its test suite were exercised on a real host.

**[Local registry trust](#local-registry-trust) is implemented and verified on
a real host.** The primary setup and verification path was exercised
end to end. The recovery and failure procedures were not — they are written and
statically checked, not runtime-verified. Know which is which before you rely
on one.

### Verified on a real host

- the [setup transaction](#setup-transaction), on a host where
  `/etc/rancher/k3s` existed but **`registries.yaml` did not** — the `absent`
  branch: pre-change health baseline, directory left untouched, staging,
  commit, and the resulting file at `root:root 0600`;
- the **setup restart** and the bounded post-restart service, API and
  single-node Ready checks;
- the generated
  `/var/lib/rancher/k3s/agent/etc/containerd/certs.d/<HOST_LAN_IP>:5000/hosts.toml`
  containing the expected `http://` host entry;
- **Run A** of [`k3s/registry-pull-test.sh`](../k3s/registry-pull-test.sh):
  build, push, tag-to-digest agreement, Pod `Running`, resolved `imageID`
  matching a digest owned by that run, and cleanup;
- a **separate verification restart**, distinct from the setup restart;
- the [post-restart persistence checks](#post-restart-persistence-checks): the
  file still present, byte-matching the deterministic expected content, still
  `uid=0 gid=0 mode=600`, the `http://` entry present in the generated
  `hosts.toml`, service active, API reachable, one node Ready;
- **Run B**, with a completely fresh identity — new marker, tag, manifest
  digest and Pod name, reusing nothing from Run A — reaching `Running` and
  resolving to a Run B-owned digest.

### Exercised but with limits worth stating

- **Run B was cache-immune, not cache-free.** Its manifest, image config and
  marker layer were new and had to come from the registry. The shared BusyBox
  base layer was already present from Run A, in the registry and in
  containerd's content store, so that layer was not re-fetched. Broken registry
  trust would still have failed the run at manifest resolution.
- **The distinct-digest case was never exercised.** On this host Docker uses
  the containerd image store, where `docker image inspect .Id` reports the
  manifest digest, so the push digest and the image config digest were the same
  value. The dual-digest tolerance was therefore never put to the test with two
  different digests.
- **The local-node identity check was added after Runs A and B, and then
  replaced.** Those runs verified exactly one node, Ready, a `+k3s` kubelet and
  a `containerd://` runtime — nothing more. A first locality rule (node
  InternalIP present in this host's non-loopback address list) was added
  afterwards; review found it too weak, because shared bridge addresses such as
  `172.17.0.1` would satisfy it. It was replaced by the current
  default-route-source predicate, which was also added after Runs A and B and
  verified separately as a read-only check. **Neither locality rule was in
  force during Run A or Run B.** The registry-trust evidence from those runs is
  unaffected; the identity check guards which cluster a *future* run may target.
- The persistence check observed that `registries.yaml` was unchanged across
  the verification restart, content and metadata alike. That is an observation
  about this restart, not a general proof about what k3s does or does not write.

### Documented but not executed

Reviewed and documented procedures. Their shell blocks were syntax-checked with
`bash -n` and linted with ShellCheck, and the changed comparison and metadata
logic was exercised in isolation — but **static validation is not host
execution**. Do not describe any of them as runtime-verified:

- the automatic rollback inside the setup transaction, including its ownership
  gate — unreachable, because the restart succeeded;
- [rollback A](#a-restoring-an-operator-merged-configuration) and
  [rollback B](#b-removing-a-configuration-the-setup-transaction-created);
- the [manual merge procedure](#merging-into-an-existing-registriesyaml) — the
  host had no pre-existing `registries.yaml`, so the `identical` and `differs`
  branches were never taken;
- the setup-verification failure path, where the cluster is healthy but the
  generated `hosts.toml` cannot be confirmed;
- orphan smoke-test artifact cleanup.

The failure-injection paths were **deliberately** left unexercised: proving
them on a working host would have meant breaking a healthy cluster on purpose.

## Prerequisites

- A systemd host, with `systemctl` and `curl` available.
- Root privileges (`sudo`).
- The host's LAN IP address (`ip -4 addr`).
- The exact k3s release tag you intend to pin, in `vX.Y.Z+k3sN` form. Take it
  from the k3s releases page. Channels such as `latest` or `stable` are
  rejected by design.

## Install

Both variables are required and have no defaults. An unset or malformed value
is a hard error before anything on the host is touched.

```sh
sudo K3S_VERSION=vX.Y.Z+k3sN HOST_LAN_IP=<your-lan-ip> bash k3s/install.sh
```

`HOST_LAN_IP` is passed to k3s as `--tls-san`, so the API server certificate is
valid when the cluster is reached over the LAN IP rather than `127.0.0.1`.

The script prints a summary of the intended action — version, `HOST_LAN_IP`,
resulting `--tls-san`, kubeconfig path — **before** it changes anything.

Neither value belongs in the repository. They are supplied per host at run time.

## Operating the service

```sh
sudo systemctl status k3s      # current state
sudo systemctl start k3s       # start
sudo systemctl stop k3s        # stop (workloads stop with it)
sudo journalctl -u k3s         # logs
sudo journalctl -u k3s -f      # follow logs
```

## Verifying the cluster

```sh
sudo k3s kubectl get nodes
```

The node should report `Ready`.

`sudo` is needed because the kubeconfig at `/etc/rancher/k3s/k3s.yaml` stays
root-owned with mode 0600. That is deliberate — it holds cluster-admin
credentials.

To confirm the effective service configuration:

```sh
systemctl show k3s --property=ExecStart --value
```

The `argv[]` entry should be exactly
`/usr/local/bin/k3s server --tls-san <your-lan-ip>`.

## Re-running the script: the existing-installation policy

The script enforces its own idempotency. It does not rely on the upstream
installer being safe to re-run — re-running that installer can regenerate the
systemd unit, restart the service, and drop options set earlier.

On every run it inspects the host first and resolves to exactly one of three
outcomes:

| Outcome | Meaning |
| --- | --- |
| `install` | No k3s binary and no k3s unit present. Installs. |
| `noop` | The existing installation is exactly equivalent and healthy. Exits 0 without touching anything. |
| `mismatch` | Anything else. Exits 1 **before** any change, and prints why. |

### What `noop` does and does not claim

A `noop` asserts equivalence of the state this script manages:

- the installed k3s version matches the requested one exactly;
- the effective systemd `ExecStart` is exactly
  `/usr/local/bin/k3s server --tls-san <HOST_LAN_IP>` — same executable, the
  `server` subcommand, exactly one `--tls-san`, exactly the requested IP, and
  no other arguments;
- the service is both active and enabled;
- the kubeconfig file exists;
- no external k3s configuration is present.

It does **not** claim that the full k3s runtime configuration is unchanged.
k3s also reads `/etc/rancher/k3s/config.yaml` and
`/etc/rancher/k3s/config.yaml.d/*`, which can alter cluster behaviour in ways
the version and `ExecStart` cannot reveal. The script does not model those
files, so it refuses to act whenever any of them exists. Reconciling custom
k3s configuration is out of scope for this script.

`/etc/rancher/k3s/registries.yaml` is a further input the script does not
model. It is deliberately **not** part of the `mismatch` check — the
[registry trust](#local-registry-trust) transaction owns that file, and its
presence neither blocks nor is asserted by a `noop`. So a `noop` says nothing
about whether registry trust is configured; verify that separately.

The comparison against `ExecStart` is deliberately exact. `k3s agent` mode, an
added flag such as `--disable=traefik`, a different executable path, a second
`--tls-san`, or an ambiguous unit definition (for example, systemd drop-ins
producing more than one `ExecStart`) all resolve to `mismatch`.

### Handling a `mismatch`

The script never repairs a `mismatch` for you, because doing so would mean
silently mutating host state it cannot fully verify is safe to touch. Resolve
it manually:

- **Service not active or not enabled** — `sudo systemctl start k3s` and
  `sudo systemctl enable k3s`, then re-run.
- **Kubeconfig missing** — restore it from a backup (see below), or reinstall
  deliberately via the reset procedure.
- **Version differs** — upgrading or downgrading k3s is a separate manual
  procedure, not automated here.
- **`ExecStart` differs** — the running cluster was configured outside this
  script. Decide explicitly whether to keep that configuration or to reset.
- **External config present** — the cluster is configured through
  `config.yaml` or a drop-in. This script does not manage those.
- **Binary and unit inconsistent** — a partial or interrupted install. Use the
  reset procedure below before installing again.

## Kubeconfig backups

If a kubeconfig already exists at `/etc/rancher/k3s/k3s.yaml` when a fresh
install runs, it is copied to a timestamped sibling before the install
proceeds:

```
/etc/rancher/k3s/k3s.yaml.backup-20260101T120000Z
```

An existing backup is never overwritten; a collision gets a numeric suffix
(`...-1`, `...-2`). The original file is never modified or removed.

Backups are **not** pruned automatically. They accumulate until you remove
them. That is a deliberate choice — silently deleting credential files is
worse than unbounded growth on a home lab host.

They live in `/etc/rancher/k3s/`, which is exactly the directory the reset
procedure below deletes. If you intend to keep a backup across a reset, copy
it somewhere else first — otherwise the reset destroys the backups along with
everything else.

A kubeconfig backup is a copy of the admin **client credentials** only. It is
not a cluster-state backup and not a workload-data backup. It cannot restore a
destroyed cluster.

## Accessing the cluster from another machine on the LAN

`--tls-san` only adds the LAN IP to the API server certificate's subject
alternative names. It does **not** change the `server:` field inside the
generated kubeconfig, which still points at `https://127.0.0.1:6443`.

To use the cluster from another machine:

```sh
# on the k3s host
sudo cat /etc/rancher/k3s/k3s.yaml
```

Copy the content over a secure channel, save it on the client machine with
restrictive permissions (`chmod 600`), and edit the `server:` field to
`https://<HOST_LAN_IP>:6443`.

That file grants **cluster-admin** access. Treat it as a secret: never commit
it, never paste it into shared locations, and remove it when no longer needed.

## Local registry trust

The local registry (see [`docs/registry-runbook.md`](./registry-runbook.md))
serves plain HTTP. k3s's container runtime treats every registry except
loopback as HTTPS by default, so a Pod using `<HOST_LAN_IP>:5000/...` fails to
pull until k3s is told to trust that endpoint.

This is **not** the same thing as the Docker daemon trust configured in
`/etc/docker/daemon.json`. That file governs the host Docker daemon, which
builds and pushes images. containerd — the runtime k3s actually runs Pods with
— never reads it. Both are needed, and they are configured separately.

### The mechanism

k3s reads `/etc/rancher/k3s/registries.yaml` **at startup** and generates
containerd's registry configuration from it, under
`/var/lib/rancher/k3s/agent/etc/containerd/certs.d/<registry>/hosts.toml`.
Never edit the generated files: k3s regenerates them on every start, so any
hand edit is lost at the next restart.

The configuration this repository uses is minimal:

```yaml
mirrors:
  "<HOST_LAN_IP>:5000":
    endpoint:
      - "http://<HOST_LAN_IP>:5000"
```

- only a `mirrors` entry is needed; the key is the registry authority
  (`<HOST_LAN_IP>:5000`) and the endpoint is the full URL;
- **the `http://` scheme is what selects plain HTTP.** Without it k3s defaults
  to HTTPS;
- there is deliberately **no `configs` section**. That is where auth and TLS
  settings live, and this registry has neither. In particular
  `tls.insecure_skip_verify` is **not** used: it bypasses certificate
  verification on an HTTPS connection, which is a different thing from not
  using TLS at all. Adding it would falsely imply TLS is in play;
- **a restart is mandatory** after creating or changing the file.

The file is created `root:root` mode **0600**. It has no secrets today, but the
schema can carry `configs.<registry>.auth` credentials, and k3s reads it as
root — so 0600 costs nothing and protects a future addition by default. This
deliberately differs from `/etc/docker/daemon.json`, which is 0644.

### Recovery: `registries.yaml` missing

**Symptom.** A Pod that pulls from `<HOST_LAN_IP>:5000/...` fails with

```
http: server gave HTTP response to HTTPS client
```

while `curl http://<HOST_LAN_IP>:5000/v2/` from the host is healthy and the
Docker daemon still pushes and pulls fine.

**Cause.** `/etc/rancher/k3s/registries.yaml` is absent, so k3s generated no
`certs.d/<HOST_LAN_IP>:5000/hosts.toml` and containerd falls back to its default
of treating every non-loopback registry as HTTPS. This is a k3s/containerd
concern only — the Docker daemon trust in `/etc/docker/daemon.json` is a
separate mechanism and is unaffected. The file can go missing without a reboot
(for example a k3s reset/reinstall wipes `/etc/rancher/k3s`, and
[rollback B](#b-removing-a-configuration-the-setup-transaction-created) removes
it deliberately); its disappearance is not always explained.

**Recovery.** Re-run the [Setup transaction](#setup-transaction). With the file
absent it takes the `absent` branch, recreates it `root:root 0600`, performs the
mandatory k3s restart, and confirms the regenerated `hosts.toml`. Then run the
full [verification flow](#verifying-the-registry-trust) — Run A, the separate
verification restart, the post-restart persistence checks, and a fresh-identity
Run B — before treating the trust as restored.

### Setup transaction

**Copy the whole block below and run it as a unit.** It is a single
`set -euo pipefail` subshell, and it is only fail-closed as a unit: pasted line
by line into a normal shell, execution would continue past a failed check,
`install`, `mv` or `systemctl`. The subshell keeps the strict options from
leaking into your interactive shell.

Set `HOST_LAN_IP` in your shell first.

**Operational impact.** This restarts k3s. On a single-node cluster that stops
the control plane and every workload on the node for the duration of the
restart. Do not run it while anything depends on the cluster.

```sh
(
  set -euo pipefail

  RANCHER_K3S_DIR="/etc/rancher/k3s"
  REGISTRIES_CONFIG="${RANCHER_K3S_DIR}/registries.yaml"
  CERTS_D_DIR="/var/lib/rancher/k3s/agent/etc/containerd/certs.d"
  SERVICE_TIMEOUT_SECONDS=60
  NODE_READY_TIMEOUT_SECONDS=120

  CREATED_RANCHER_K3S_DIR=false  # true only if this transaction created it
  CONFIG_STATE=""                # absent | identical | differs
  PROPOSED_CONFIG=""             # user-owned scratch: the exact proposed bytes
  STAGED_CONFIG=""               # root-owned staging file next to the target
  CONFIG_COMMITTED=false         # true only after a successful rename
  SETUP_VERIFIED=false           # true only after the hosts.toml check passes

  # Removes scratch and staging files only. It never restores configuration:
  # not every failure happens after the commit, the rollback itself can fail,
  # and its result has to be checked explicitly.
  #
  # PROPOSED_CONFIG is removed LAST and only when it can no longer be needed:
  # it is the rollback's ownership token, not just a scratch file.
  cleanup_registry_trust() {
    local rc="$?"
    trap - EXIT INT TERM

    if [ -n "$STAGED_CONFIG" ]; then
      if ! sudo rm -f -- "$STAGED_CONFIG"; then
        printf 'WARNING: failed to remove %s\n' "$STAGED_CONFIG" >&2
      fi
    fi

    # Only take back a directory this transaction created, and only with
    # rmdir, so a directory anything else has since written to is left alone.
    # Never recursive, and never against a directory that already existed.
    if [ "$CREATED_RANCHER_K3S_DIR" = true ] && [ "$CONFIG_COMMITTED" = false ]; then
      if ! sudo rmdir -- "$RANCHER_K3S_DIR" 2>/dev/null; then
        printf 'WARNING: %s was created by this transaction but could not be removed (not empty?); leaving it in place\n' \
          "$RANCHER_K3S_DIR" >&2
      fi
    fi

    if [ "$rc" -ne 0 ] && [ "$CONFIG_COMMITTED" = true ]; then
      printf 'NOTE: %s was committed by this transaction and is still in place (setup verification completed: %s).\n' \
        "$REGISTRIES_CONFIG" "$SETUP_VERIFIED" >&2
      printf 'NOTE: the exact bytes committed are preserved at %s — keep this file, it is what proves ownership if you roll back.\n' \
        "$PROPOSED_CONFIG" >&2
    elif [ -n "$PROPOSED_CONFIG" ]; then
      if ! rm -f -- "$PROPOSED_CONFIG"; then
        printf 'WARNING: failed to remove %s\n' "$PROPOSED_CONFIG" >&2
      fi
    fi

    exit "$rc"
  }

  # Ownership-safe rollback. Two gates, both mandatory:
  #   (a) this transaction actually committed the file, and
  #   (b) the live file is still byte-for-byte what it committed.
  # Without (b), a writer that replaced the file after the commit would have
  # its content deleted here.
  #
  # Every step returns explicitly: `set -e` is suspended inside a function
  # called from an `if !` condition, so a failed rm must be reported by hand.
  rollback_created_config() {
    if [ "$CONFIG_COMMITTED" != true ]; then
      printf '%s\n' \
        "No filesystem configuration change from this transaction is available to roll back." >&2
      printf '%s\n' \
        "The pre-existing ${REGISTRIES_CONFIG} is left untouched." >&2
      printf '%s\n' \
        "The k3s restart/recovery failure requires manual diagnosis." >&2
      return 1
    fi

    # The status is captured in the `else` branch, never after `if ! cmp`:
    # there `$?` would be the status of the `!` itself (always 0), losing the
    # difference between "files differ" and "the comparison failed".
    local cmp_rc=0
    if sudo cmp -s -- "$REGISTRIES_CONFIG" "$PROPOSED_CONFIG"; then
      : # live is byte-for-byte what this transaction committed
    else
      cmp_rc=$?
      case "$cmp_rc" in
        1)
          # cmp uses 1 for "files differ", but a sudo that fails on its own
          # also exits 1, and the two are indistinguishable from out here.
          # Either way ownership was not established, so nothing is deleted.
          printf 'ERROR: %s differs from what this transaction committed, or the privileged comparison could not be conclusively completed (status 1).\n' \
            "$REGISTRIES_CONFIG" >&2
          ;;
        *)
          printf 'ERROR: the ownership comparison for %s failed (cmp exit %s).\n' \
            "$REGISTRIES_CONFIG" "$cmp_rc" >&2
          ;;
      esac
      printf '%s\n' \
        "NOT deleting it: this transaction can no longer prove it owns that file. Manual recovery is required." >&2
      printf 'The bytes this transaction committed are preserved at %s for comparison.\n' \
        "$PROPOSED_CONFIG" >&2
      return 1
    fi

    if ! sudo rm -f -- "$REGISTRIES_CONFIG"; then
      printf 'ERROR: failed to remove %s; manual recovery is required.\n' \
        "$REGISTRIES_CONFIG" >&2
      return 1
    fi
    CONFIG_COMMITTED=false

    if [ "$CREATED_RANCHER_K3S_DIR" = true ]; then
      if ! sudo rmdir -- "$RANCHER_K3S_DIR" 2>/dev/null; then
        printf 'WARNING: %s was created by this transaction but is not empty; leaving it in place\n' \
          "$RANCHER_K3S_DIR" >&2
      fi
    fi
    return 0
  }

  # Exactly one node, Ready. A second node adds a second line, so the string
  # comparison enforces the node count as well.
  read_node_ready() {
    sudo k3s kubectl get nodes \
      -o jsonpath='{range .items[*]}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\n"}{end}' \
      2>/dev/null || true
  }

  wait_for_service_active() {
    local waited=0
    while [ "$waited" -lt "$SERVICE_TIMEOUT_SECONDS" ]; do
      if systemctl is-active --quiet k3s; then return 0; fi
      sleep 2
      waited=$((waited + 2))
    done
    return 1
  }

  wait_for_node_ready() {
    local waited=0
    while [ "$waited" -lt "$NODE_READY_TIMEOUT_SECONDS" ]; do
      if [ "$(read_node_ready)" = "True" ]; then return 0; fi
      sleep 5
      waited=$((waited + 5))
    done
    return 1
  }

  check_cluster_baseline() {
    if ! systemctl is-active --quiet k3s; then
      printf 'ERROR: the k3s service is not active. Fix that before changing registry trust.\n' >&2
      return 1
    fi
    local ready
    ready="$(read_node_ready)"
    if [ -z "$ready" ]; then
      printf 'ERROR: the Kubernetes API did not answer, or reported no nodes.\n' >&2
      return 1
    fi
    if [ "$ready" != "True" ]; then
      printf 'ERROR: expected exactly one Ready node; got node Ready conditions: %s\n' \
        "$(printf '%s' "$ready" | tr '\n' ' ')" >&2
      return 1
    fi
    return 0
  }

  verify_generated_hosts_toml() {
    local hosts_toml="${CERTS_D_DIR}/${HOST_LAN_IP}:5000/hosts.toml"
    if ! sudo test -f "$hosts_toml"; then
      printf 'ERROR: k3s did not generate %s\n' "$hosts_toml" >&2
      sudo ls -la "$CERTS_D_DIR" >&2 || true
      return 1
    fi
    if ! sudo grep -q "http://${HOST_LAN_IP}:5000" "$hosts_toml"; then
      printf 'ERROR: %s contains no http:// host entry for %s:5000\n' \
        "$hosts_toml" "$HOST_LAN_IP" >&2
      sudo cat "$hosts_toml" >&2 || true
      return 1
    fi
    printf 'Generated containerd config confirmed: %s\n' "$hosts_toml"
    return 0
  }

  trap cleanup_registry_trust EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  # --- 1. input validation --------------------------------------------------

  if [ -z "${HOST_LAN_IP:-}" ]; then
    printf 'ERROR: HOST_LAN_IP is not set.\n' >&2
    exit 1
  fi
  # Anchored over the WHOLE value before any splitting: `read` stops at the
  # first newline, so a first-line-valid value would otherwise pass while the
  # untruncated original still reached the generated configuration.
  if ! printf '%s' "$HOST_LAN_IP" \
    | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
    printf 'ERROR: HOST_LAN_IP "%s" is not a dotted-quad IPv4 address.\n' "$HOST_LAN_IP" >&2
    exit 1
  fi
  (
    IFS=.
    for octet in $HOST_LAN_IP; do
      case "$octet" in
        0|[1-9]|[1-9][0-9]|[1-9][0-9][0-9]) ;;
        *) printf 'ERROR: malformed or leading-zero octet: "%s"\n' "$octet" >&2; exit 1 ;;
      esac
      if [ "$octet" -gt 255 ]; then
        printf 'ERROR: out-of-range octet: %s\n' "$octet" >&2
        exit 1
      fi
    done
  )
  case "$HOST_LAN_IP" in
    127.*)
      printf 'ERROR: HOST_LAN_IP "%s" is a loopback address; the registry binds to the LAN address.\n' \
        "$HOST_LAN_IP" >&2
      exit 1
      ;;
  esac

  if [ "$(systemctl show k3s --property=LoadState --value 2>/dev/null)" != "loaded" ]; then
    printf 'ERROR: the k3s systemd unit is not loaded. Install k3s first (k3s/install.sh).\n' >&2
    exit 1
  fi

  # --- 2. read-only filesystem state detection ------------------------------

  if sudo test -e "$RANCHER_K3S_DIR" && ! sudo test -d "$RANCHER_K3S_DIR"; then
    printf 'ERROR: %s exists but is not a directory\n' "$RANCHER_K3S_DIR" >&2
    exit 1
  fi

  # --- 3. generate the proposed configuration (nothing touched yet) ---------

  PROPOSED_CONFIG="$(mktemp)"
  chmod 0600 "$PROPOSED_CONFIG"
  cat >"$PROPOSED_CONFIG" <<EOF
# Managed by homelab-platform (see docs/k3s-runbook.md).
# Trusts the local plain-HTTP registry from registry/docker-compose.yml.
# No TLS and no auth by design: trusted single-user LAN only.
mirrors:
  "${HOST_LAN_IP}:5000":
    endpoint:
      - "http://${HOST_LAN_IP}:5000"
EOF

  # --- 4. static self-check -------------------------------------------------
  #
  # This is NOT YAML validation — there is no YAML parser assumed on this host.
  # It only rules out an empty variable or a broken heredoc. It does not prove
  # that k3s will accept the configuration; only the generated hosts.toml and a
  # real pull can show that.
  if ! grep -q "^  \"${HOST_LAN_IP}:5000\":\$" "$PROPOSED_CONFIG" \
    || ! grep -q "^      - \"http://${HOST_LAN_IP}:5000\"\$" "$PROPOSED_CONFIG"; then
    printf 'ERROR: the generated configuration does not contain the expected mirror entry; refusing to continue.\n' >&2
    exit 1
  fi

  # --- 5. existing-file decision (still no mutation) ------------------------

  if ! sudo test -e "$REGISTRIES_CONFIG"; then
    CONFIG_STATE="absent"
  else
    cmp_rc=0
    if sudo cmp -s -- "$REGISTRIES_CONFIG" "$PROPOSED_CONFIG"; then
      CONFIG_STATE="identical"
    else
      cmp_rc=$?
      CONFIG_STATE="differs"
    fi
  fi

  if [ "$CONFIG_STATE" = "differs" ]; then
    printf '%s\n' \
      "ERROR: ${REGISTRIES_CONFIG} already exists and is not the configuration this transaction would write" >&2
    if [ "${cmp_rc:-0}" -gt 1 ]; then
      printf 'ERROR: (the comparison itself failed, cmp exit %s)\n' "$cmp_rc" >&2
    fi
    printf '%s\n' \
      "Nothing has been changed. This transaction never overwrites a configuration it did not write, and does not merge YAML." >&2
    printf '%s\n' "" >&2
    printf '%s\n' "Merge this entry by hand instead — see 'Merging into an existing registries.yaml':" >&2
    printf '%s\n' "" >&2
    printf '%s\n' "mirrors:" >&2
    printf '%s\n' "  \"${HOST_LAN_IP}:5000\":" >&2
    printf '%s\n' "    endpoint:" >&2
    printf '%s\n' "      - \"http://${HOST_LAN_IP}:5000\"" >&2
    exit 1
  fi

  printf 'Existing configuration state: %s\n' "$CONFIG_STATE"
  if [ "$CONFIG_STATE" = "identical" ]; then
    printf '%s\n' \
      "The file already holds exactly this content: no write, no backup. That proves filesystem state only, NOT that the running k3s has loaded it — so the restart and verification below still run."
  fi

  # --- 6. pre-change cluster health baseline (before ANY mutation) ----------

  printf 'Checking cluster health before changing anything...\n'
  if ! check_cluster_baseline; then
    printf '%s\n' \
      "Refusing to change registry trust on an unhealthy cluster. Nothing under ${RANCHER_K3S_DIR} was touched." >&2
    exit 1
  fi
  printf 'Baseline OK: k3s active, exactly one Ready node.\n'

  # --- 7-10. create the configuration (absent case only) --------------------

  if [ "$CONFIG_STATE" = "absent" ]; then
    if ! sudo test -d "$RANCHER_K3S_DIR"; then
      sudo install -d -o root -g root -m 0755 "$RANCHER_K3S_DIR"
      CREATED_RANCHER_K3S_DIR=true
      printf 'Created %s (root:root 0755).\n' "$RANCHER_K3S_DIR"
    fi

    STAGED_CONFIG="$(sudo mktemp "${RANCHER_K3S_DIR}/.registries.yaml.XXXXXXXX")"
    sudo install -o root -g root -m 0600 "$PROPOSED_CONFIG" "$STAGED_CONFIG"

    # Last check before the commit point. It narrows the window, it does not
    # close it: a writer landing between this check and the rename still wins.
    if sudo test -e "$REGISTRIES_CONFIG"; then
      printf 'ERROR: %s appeared while this transaction was staging; refusing to commit over it.\n' \
        "$REGISTRIES_CONFIG" >&2
      exit 1
    fi

    sudo mv -fT -- "$STAGED_CONFIG" "$REGISTRIES_CONFIG"
    CONFIG_COMMITTED=true
    STAGED_CONFIG=""
    printf 'Committed %s\n' "$REGISTRIES_CONFIG"
    sudo stat --format='  owner=%u:%g mode=%a path=%n' "$REGISTRIES_CONFIG"
  fi

  # --- 11-12. setup restart, then health --------------------------------------

  printf '\nRestarting k3s (SETUP restart). The control plane and every workload\n'
  printf 'on this node stop for the duration.\n'

  restart_ok=true
  sudo systemctl restart k3s || restart_ok=false
  if [ "$restart_ok" = true ]; then
    wait_for_service_active || restart_ok=false
  fi
  if [ "$restart_ok" = true ]; then
    wait_for_node_ready || restart_ok=false
  fi

  if [ "$restart_ok" = false ]; then
    printf '%s\n' "ERROR: k3s did not come back healthy after the setup restart." >&2

    if rollback_created_config; then
      printf '%s\n' "The configuration this transaction created was removed. Restarting k3s again." >&2
      if sudo systemctl restart k3s && wait_for_service_active && wait_for_node_ready; then
        printf '%s\n' \
          "ERROR: the new registry configuration was rejected. The original state was restored successfully." >&2
      else
        printf '%s\n' \
          "ERROR: the original state was restored, but k3s did not recover; manual recovery is required." >&2
      fi
    fi

    printf '%s\n' "Start with: sudo journalctl -u k3s -n 200 ; sudo systemctl cat k3s" >&2
    printf '%s\n' "Do NOT reinstall k3s to paper over this." >&2
    exit 1
  fi

  printf 'k3s is active and the node is Ready again.\n'

  # --- 13. generated configuration verification -----------------------------
  #
  # A failure here is NOT an operational failure: the cluster is healthy. The
  # generated containerd output is version-sensitive enough that an inspection
  # mismatch must not automatically destroy a configuration that may well be
  # usable. So nothing is deleted — the operator decides.
  if verify_generated_hosts_toml; then
    SETUP_VERIFIED=true
    printf '\nSetup verification PASSED. Next: the registry pull test below.\n'
  else
    printf '%s\n' "" >&2
    printf '%s\n' "ERROR: setup verification FAILED." >&2
    printf '%s\n' \
      "k3s is active and the node is Ready, but the expected http:// entry could not be confirmed in the generated containerd configuration." >&2
    printf '%s\n' \
      "No configuration has been deleted automatically. Resolve the discrepancy, or use 'Rolling back the registry trust'." >&2
    printf '%s\n' "Do NOT proceed to the registry pull test until this is settled." >&2
    sudo journalctl -u k3s --since '-5 minutes' >&2 || true
    exit 1
  fi
)
```

Expect a `server = "https://<HOST_LAN_IP>:5000/v2"` line in the generated
`hosts.toml` alongside the `http://` host entry. That is normal: containerd
tries the explicit `[host."..."]` entries first and only falls back to `server`
if they all fail. Its presence is not a misconfiguration — see
[k3s#11340](https://github.com/k3s-io/k3s/issues/11340). The `http://` entry
must be there, which is what the check above requires.

### What the transaction guarantees

- **nothing under `/etc/rancher/k3s` is written before the input, the proposed
  configuration and the cluster's health have all been checked.** A rejected
  input, a malformed generated file, an existing differing configuration or an
  unhealthy cluster all leave the host byte-for-byte as it was;
- an existing configuration is **never overwritten**. Byte-identical means no
  write at all; anything else stops the transaction and prints the fragment to
  merge by hand;
- **byte-identical is not treated as "done".** It proves filesystem state, not
  that the running k3s loaded it, so the restart and verification still run;
- `mv -fT` between two files in `/etc/rancher/k3s` is the commit point, and the
  only atomic step. It **replaces** the file atomically; it is not an atomic
  compare-and-swap;
- automatic rollback removes the configuration only when this transaction
  committed it **and** the live file is still byte-for-byte what it committed;
- `/etc/rancher/k3s` is created only if missing, and ever removed again only
  with `rmdir` — never recursively, and never if it existed beforehand.

### Concurrency: what is and is not guaranteed

| | |
| --- | --- |
| **Guaranteed** | No `/etc/rancher/k3s` mutation before every pre-check passes. A *detected* pre-existing file stops the transaction before any write. `mv -fT` replaces the file atomically. Automatic rollback is gated on proven ownership, and its result is checked. No recursive deletion under `/etc`, ever. |
| **Best effort** | Detecting an external writer at all. |
| **Your responsibility** | Giving the transaction exclusive operational access to `/etc/rancher/k3s/registries.yaml` while it runs. |

Two windows cannot be closed from a shell:

- **compare-to-rename** — between the final existence check and `mv -fT`;
- **compare-to-delete** — between the rollback's ownership comparison and the
  `rm`, in this transaction and in the standalone rollbacks below.

An advisory lock such as `flock` would not help: it only coordinates writers
that agree to take the same lock, and a package script, a configuration
management run or someone with an editor open will not consult it.

### Merging into an existing registries.yaml

If `registries.yaml` already exists with different content, the transaction
above refuses and changes nothing. Merge by hand with the procedure below.
**No YAML merging happens in a shell here** — you edit a copy in an editor.

Once you have merged, the file is **yours**, not this repository's. Re-running
the deterministic setup transaction will keep reporting `differs`, correctly and
permanently: that is the "never overwrite a configuration I did not write"
invariant doing its job, not a bug. Maintain the file with this procedure from
then on.

| # | Step | Command / note |
| --- | --- | --- |
| 1 | Record the original metadata and snapshot the file | `sudo stat -c '%u %g %a' /etc/rancher/k3s/registries.yaml`; `SNAPSHOT="$(mktemp)"; chmod 0600 "$SNAPSHOT"; sudo cat /etc/rancher/k3s/registries.yaml >"$SNAPSHOT"` |
| 2 | **Fail-closed backup**, then verify it | `BACKUP="$(sudo mktemp /etc/rancher/k3s/registries.yaml.backup-XXXXXXXX)"; sudo cp -p /etc/rancher/k3s/registries.yaml "$BACKUP"`, then `sudo cmp -s "$BACKUP" "$SNAPSHOT"` — **stop unless it exits 0**. Print and keep the path: it is rollback A's input. `cp -p` preserves the original uid, gid and mode onto the backup, which is why rollback A can read them back rather than asking you to transcribe them |
| 3 | Edit a **copy**, never the live file | `MERGED_CONFIG="$(umask 077; mktemp "${TMPDIR:-/tmp}/registries.yaml.merged-XXXXXXXX")"; cp "$SNAPSHOT" "$MERGED_CONFIG"` then edit it. Add the `"<HOST_LAN_IP>:5000"` key under `mirrors:` with the `http://` endpoint. If a `mirrors:` key already exists, add the entry under it rather than adding a second `mirrors:`. If an entry for this registry already exists, decide deliberately which one wins |
| 4 | Sanity-check the merged copy | it contains the mirror key and the `http://` endpoint, **and** every top-level key the original had. This is a `grep`-level check, **not YAML validation** |
| 5 | Stage with the **original** metadata | `STAGED="$(sudo mktemp /etc/rancher/k3s/.registries.yaml.XXXXXXXX)"; sudo install -o <orig uid> -g <orig gid> -m <orig mode> "$MERGED_CONFIG" "$STAGED"`. Do not force 0600 onto a file you did not create — but if the mode is world-readable and the file carries `configs.*.auth` credentials, tighten it deliberately and note that you did |
| 6 | Re-check for concurrent change, then commit | `sudo cmp -s /etc/rancher/k3s/registries.yaml "$SNAPSHOT"` — stop unless 0 — then `sudo mv -fT "$STAGED" /etc/rancher/k3s/registries.yaml` |
| 7 | **Record what was committed** | `sudo stat -c '%u %g %a' /etc/rancher/k3s/registries.yaml` → keep as `MERGED_UID` / `MERGED_GID` / `MERGED_MODE`, used by the [post-restart persistence checks](#post-restart-persistence-checks). Keep the `MERGED_CONFIG` path too. Rollback A does **not** need these values — it reads the original metadata off the backup itself |
| 8 | Restart and verify | `sudo systemctl restart k3s`, wait for the service and for the node to be Ready, then confirm the generated `hosts.toml` contains the `http://` entry. Same two failure classes as the setup transaction: an operational failure calls for rollback A, an inspection mismatch calls for a decision, not an automatic restore |
| 9 | On success | continue with the normal [verification flow](#verifying-the-registry-trust), unchanged |
| 10 | On failure | [rollback A](#a-restoring-an-operator-merged-configuration) — which first proves the live file is still your merged version |

**Keep `MERGED_CONFIG` (mode 0600, outside this repository) until the whole
verification flow has finished** — through Run B — or until you no longer want
the option to roll back. It is what proves rollback A is replacing your own
state rather than somebody else's later change. It may carry credentials
inherited from the original file: treat it as a secret and never commit it.

### Verifying the registry trust

Two live runs of [`k3s/registry-pull-test.sh`](../k3s/registry-pull-test.sh),
one on each side of a restart. Every run builds a fresh marker, so its manifest
and image config digests have never been seen by containerd and a cached image
cannot produce a false pass.

The script needs a kubeconfig it can read, and refuses to use an ambient
kubectl context — an unrelated cluster would otherwise produce a meaningless
pass. On this host the default context is in fact a different cluster, so this
is not a hypothetical risk.

#### The cluster-identity model

Before touching the registry, the script requires **all** of:

| Requirement | Rules out |
| --- | --- |
| exactly one node | multi-node clusters this repository does not target |
| that node is `Ready` | an unhealthy cluster |
| `kubeletVersion` contains `+k3s` | minikube, kind, a managed cluster |
| `containerRuntimeVersion` starts `containerd://` | a non-containerd runtime |
| exactly one node InternalIP, and it **equals this host's default-route source IPv4** | a valid k3s cluster that simply runs somewhere else |

The last one closes a real gap: the first four are satisfied by *any* reachable
single-node k3s cluster, so a kubeconfig pointing at another machine's lab
would pass them, and the pull test would then prove nothing about this host.

The expected address comes from the kernel's own routing decision:

```sh
ip -4 route get 1.1.1.1
```

and the `src` field of that answer. This is a **route lookup, not a
connectivity probe** — `ip route get` consults the routing table and returns
immediately; no packet is sent, and `1.1.1.1` is never contacted. It is simply
an off-link destination that forces a default-route lookup.

Why not "any address this host happens to have"? Because `docker0`, `cni0`,
`flannel.1` and bridge addresses such as `172.17.0.1` or `10.42.0.1` exist
identically on countless machines. A foreign k3s node advertising one of them
would satisfy a membership test. The default-route source is a single
host-specific value, so it cannot be borrowed that way.

Interface names are never consulted. Blacklisting `docker0`, `cni0`, `veth*` or
`br-*` would only be another environment-specific heuristic; asking the kernel
which address it routes from answers the question directly.

**`HOST_LAN_IP` is not the node-identity oracle.** It is the registry's
bind/reference address and nothing more. Node network identity is derived
independently from host routing, so a multihomed host whose registry address
differs from its routing address still verifies correctly — and a wrong
`HOST_LAN_IP` can never make a foreign cluster look local.

**Scope.** This models the bare-metal single-node k3s installation this
repository manages, where k3s takes its node IP from the default route. An
installation deliberately started with a different `--node-ip` will fail this
check. That is the intended behaviour: revisit this identity model and this
runbook rather than silently accepting the mismatch.

Each condition fails with its own message, and the locality failure is worded
distinctly from the version, runtime and Ready failures — a valid k3s cluster
that is not this host's is a different problem from a broken one. The mismatch
diagnostic prints the node's InternalIP and the route-derived expected address,
and nothing else: no interface or address inventory.

Two supported ways to supply the kubeconfig:

```sh
# 1. You already have a safe, user-owned kubeconfig for this cluster:
HOST_LAN_IP=<lan-ip> KUBECONFIG=/path/to/k3s.yaml bash k3s/registry-pull-test.sh

# 2. You do not. Make a temporary, user-owned 0600 copy:
KC="$(umask 077; mktemp "${TMPDIR:-/tmp}/k3s-kubeconfig-XXXXXXXX")"
sudo cat /etc/rancher/k3s/k3s.yaml >"$KC"
HOST_LAN_IP=<lan-ip> KUBECONFIG="$KC" bash k3s/registry-pull-test.sh
# ... and when the whole verification is done:
rm -f "$KC"
```

That copy holds **cluster-admin credentials**. Keep it mode 0600, keep it under
`${TMPDIR:-/tmp}` and outside this repository, never commit it, and delete it
when you are finished. The rest of this runbook stays on `sudo k3s kubectl` for
ordinary operations; the user-owned copy exists only because the test script
deliberately never calls `sudo`.

The full flow:

```text
GATE     setup verification PASSED (the transaction confirmed hosts.toml)

Run A    HOST_LAN_IP=... KUBECONFIG=... bash k3s/registry-pull-test.sh

MANUAL   pre-restart health check
         sudo systemctl restart k3s          <- VERIFICATION restart
         wait for the service and node Ready

PERSIST  post-restart persistence checks (below)

Run B    HOST_LAN_IP=... KUBECONFIG=... bash k3s/registry-pull-test.sh
```

The **setup restart** and the **verification restart** are two different
events. The first one loads the configuration; the second one proves it
survives a later restart. A single restart cannot be counted as both.

#### The verification restart

```sh
systemctl is-active k3s
sudo k3s kubectl get nodes
sudo systemctl restart k3s
```

Then wait for `systemctl is-active k3s` and for `sudo k3s kubectl get nodes` to
report `Ready`. If the node does not recover, read
`sudo journalctl -u k3s -n 200` and `sudo systemctl cat k3s`. Do not reinstall
k3s, and do not run any broad recovery.

#### Post-restart persistence checks

Run these **before** Run B. Passing Run B alone would only show that a pull
works now; these show the configuration itself survived.

| Check | Expected |
| --- | --- |
| `sudo test -f /etc/rancher/k3s/registries.yaml` | the file is still there |
| Content — issue-created file | byte-identical to the deterministic content: regenerate it the same way and `sudo cmp` |
| Content — operator-merged file | `sudo cmp /etc/rancher/k3s/registries.yaml "$MERGED_CONFIG"` |
| Metadata — issue-created file | `sudo stat -c '%u %g %a'` → exactly `0 0 600` |
| Metadata — operator-merged file | exactly the `MERGED_UID` / `MERGED_GID` / `MERGED_MODE` recorded at merge time. **Not** a hardcoded `root:root` — a legitimately non-root-owned pre-existing file must not fail here |
| `sudo grep 'http://<HOST_LAN_IP>:5000' /var/lib/rancher/k3s/agent/etc/containerd/certs.d/<HOST_LAN_IP>:5000/hosts.toml` | the HTTP entry was regenerated |
| `systemctl is-active k3s` | `active` |
| `sudo k3s kubectl get nodes` | exactly one node, `Ready` |

If any of these fails, **do not run Run B**: the failure is the result. Collect
diagnostics and go to the rollback section.

#### What the pull test proves

1. a per-run unique marker makes the image, its manifest digest and its image
   config digest unique to that run;
2. the tag is unique per run, so no mutable `latest` and no collision with an
   earlier run;
3. the push succeeds and its digest is taken from Docker's own push output;
4. a `HEAD` on the tag must still resolve to that same digest, or another
   client interfered and the run stops;
5. containerd keeps its own content store, **separate from Docker's**, so an
   image present to Docker cannot by itself satisfy the Pod's pull. A base
   layer already in containerd's store from an earlier run may still be reused;
   what cannot be reused is the run's own manifest and config, which is what
   makes the evidence cache-immune rather than cache-free;
6. the Pod pulls by **tag**, exercising tag resolution over plain HTTP;
7. `imagePullPolicy: Always`;
8. the Pod must reach `Running` — `Succeeded`/`Completed` is rejected;
9. the resolved `imageID` must be one of the two digests the run owns (the
   push manifest digest or the image config digest — the CRI reports either,
   depending on runtime version), and anything else fails closed. Where Docker
   uses the containerd image store those two digests are the same value, so
   that tolerance goes untested on such a host; the check is no weaker for it.

It deliberately does **not** use the literal `test:latest` from the issue text.
A mutable tag on an unauthenticated registry cannot be proven to be the image
this run pushed, and a fixed Pod name collides with leftovers. The unique
repository and tag exercise exactly the same registry tag-resolution and pull
path, with cleanup that can only touch this run's own artifacts.

#### Orphan smoke-test artifacts

An interrupted run (`SIGKILL`, host crash, unreachable registry) can leave a
Pod or a manifest behind. Nothing cleans those up automatically, and a later
run will **not** remove them by prefix — guessing could delete something that
is not its own. List them read-only:

```sh
sudo k3s kubectl get pods -n default | grep '^homelab-k3s-pull-test-' || true
curl -sS "http://<HOST_LAN_IP>:5000/v2/homelab-k3s-pull-test/tags/list"
```

Then remove by exact name, having decided each one is unwanted:

```sh
sudo k3s kubectl delete pod <exact-pod-name> -n default
```

An orphan Pod exits by itself after its `sleep 3600` and stays as `Completed`.
Removing a leftover manifest is the same digest-based `DELETE` the registry
runbook documents; reclaiming the disk space needs garbage collection, which
stays out of scope.

### Rolling back the registry trust

Each block is **complete and standalone**: paste it into a fresh shell. None of
them depends on variables left over from the setup transaction — that ran in
its own subshell, which is long gone. Where a value cannot be derived, the
block starts with an explicitly marked line for you to edit.

Pick one:

- **A** — you merged into a pre-existing `registries.yaml` by hand, and want
  the original file back.
- **B** — the setup transaction created `registries.yaml`, and you want it gone.

Both restart k3s, with the same single-node impact as the setup transaction.

#### A. Restoring an operator-merged configuration

Restores your backup **only after proving the live file is still the merged
version you committed**. If someone changed it since, restoring the backup
would destroy their change, so the block stops instead.

Two separate artifacts, two separate jobs — and **no metadata is entered by
hand**:

| Artifact | What it establishes |
| --- | --- |
| `BACKUP_PATH` | both **what content** to restore **and what metadata belonged to that original file**. It was made with `cp -p`, so its uid, gid and mode *are* the original's; the block reads them with `sudo stat` after validating the path, and fails closed on an empty, malformed or unreadable result |
| `MERGED_CONFIG` | that the **live state about to be replaced is still yours** — the version this merge procedure committed, not somebody's later change |

Neither role can stand in for the other: the backup says nothing about what is
live *now*, and the merged candidate says nothing about what the file looked
like *before* the merge. Transcribing uid/gid/mode by hand is deliberately not
part of this procedure — a mistyped or defaulted `0/0/0600` would silently
re-own a legitimately non-root or differently-permissioned original.

```sh
(
  set -euo pipefail

  # EDIT: the backup path from step 2 of the merge procedure.
  BACKUP_PATH="/etc/rancher/k3s/registries.yaml.backup-REPLACE_ME"
  # EDIT: the merged candidate you kept — the ownership token from step 3/7.
  MERGED_CONFIG="/tmp/registries.yaml.merged-REPLACE_ME"

  # No metadata is entered by hand. The backup was created with `cp -p` from
  # the original file, so it carries that file's uid, gid and mode; those are
  # read off it below. A transcribed default such as 0/0/0600 would silently
  # re-own a legitimately non-root or differently-permissioned original.
  REGISTRIES_CONFIG="/etc/rancher/k3s/registries.yaml"
  STAGED_CONFIG=""
  ORIGINAL_UID=""
  ORIGINAL_GID=""
  ORIGINAL_MODE=""

  cleanup_rollback() {
    local rc="$?"
    trap - EXIT INT TERM
    if [ -n "$STAGED_CONFIG" ]; then
      if ! sudo rm -f -- "$STAGED_CONFIG"; then
        printf 'WARNING: failed to remove %s\n' "$STAGED_CONFIG" >&2
      fi
    fi
    exit "$rc"
  }

  trap cleanup_rollback EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  case "$BACKUP_PATH$MERGED_CONFIG" in
    *REPLACE_ME*)
      printf 'ERROR: fill in BACKUP_PATH and MERGED_CONFIG first.\n' >&2
      exit 1
      ;;
  esac
  if ! sudo test -f "$BACKUP_PATH"; then
    printf 'ERROR: %s is not a regular file.\n' "$BACKUP_PATH" >&2
    exit 1
  fi
  if ! sudo test -f "$MERGED_CONFIG"; then
    printf 'ERROR: %s is not a regular file. Without it this rollback cannot prove it owns the state it would replace; recover by hand.\n' \
      "$MERGED_CONFIG" >&2
    exit 1
  fi

  # --- ownership gate -------------------------------------------------------
  #
  # The status is captured in the `else` branch, never after `if ! cmp`: there
  # `$?` would be the status of the `!` itself (always 0), losing the
  # difference between "files differ" and "the comparison failed".
  cmp_rc=0
  if sudo cmp -s -- "$REGISTRIES_CONFIG" "$MERGED_CONFIG"; then
    : # the live file is still exactly what this merge committed
  else
    cmp_rc=$?
    case "$cmp_rc" in
      1)
        printf 'ERROR: %s differs from the merged configuration you committed, or the privileged comparison was inconclusive (status 1).\n' \
          "$REGISTRIES_CONFIG" >&2
        ;;
      *)
        printf 'ERROR: the ownership comparison failed (cmp exit %s).\n' "$cmp_rc" >&2
        ;;
    esac
    printf '%s\n' \
      "NOT restoring: the live file is no longer provably the version this procedure committed, and overwriting it could destroy someone else's change. Manual recovery is required." >&2
    exit 1
  fi

  printf 'Ownership confirmed: the live configuration is still the merged version.\n'

  # --- original metadata, derived from the verified backup --------------------
  #
  # `cp -p` in step 2 of the merge procedure preserved the original uid, gid
  # and mode onto the backup, so the backup is the authority for both the
  # content to restore AND the metadata that belonged to it. Nothing is typed
  # in by the operator, so nothing can be mistyped or defaulted.
  if ! backup_meta="$(sudo stat -c '%u %g %a' -- "$BACKUP_PATH")"; then
    printf 'ERROR: could not read the metadata of %s; refusing to restore with guessed ownership.\n' \
      "$BACKUP_PATH" >&2
    exit 1
  fi
  read -r ORIGINAL_UID ORIGINAL_GID ORIGINAL_MODE <<EOF
$backup_meta
EOF

  # Fail closed on anything that is not a plain decimal id / octal mode.
  # An empty or malformed value must never reach `install`.
  case "$ORIGINAL_UID" in ''|*[!0-9]*)
    printf 'ERROR: backup uid "%s" is not a non-negative decimal integer.\n' "$ORIGINAL_UID" >&2
    exit 1 ;;
  esac
  case "$ORIGINAL_GID" in ''|*[!0-9]*)
    printf 'ERROR: backup gid "%s" is not a non-negative decimal integer.\n' "$ORIGINAL_GID" >&2
    exit 1 ;;
  esac
  case "$ORIGINAL_MODE" in ''|*[!0-7]*)
    printf 'ERROR: backup mode "%s" is not a numeric permission mode.\n' "$ORIGINAL_MODE" >&2
    exit 1 ;;
  esac
  if [ "${#ORIGINAL_MODE}" -lt 3 ] || [ "${#ORIGINAL_MODE}" -gt 4 ]; then
    printf 'ERROR: backup mode "%s" is not 3 or 4 octal digits.\n' "$ORIGINAL_MODE" >&2
    exit 1
  fi

  printf 'Restoring from: %s (uid=%s gid=%s mode=%s, read from the backup)\n' \
    "$BACKUP_PATH" "$ORIGINAL_UID" "$ORIGINAL_GID" "$ORIGINAL_MODE"

  STAGED_CONFIG="$(sudo mktemp /etc/rancher/k3s/.registries.yaml.rollback.XXXXXXXX)"
  sudo install -o "$ORIGINAL_UID" -g "$ORIGINAL_GID" -m "$ORIGINAL_MODE" \
    "$BACKUP_PATH" "$STAGED_CONFIG"
  sudo mv -fT -- "$STAGED_CONFIG" "$REGISTRIES_CONFIG"
  STAGED_CONFIG=""

  sudo systemctl restart k3s
  waited=0
  while [ "$waited" -lt 60 ] && ! systemctl is-active --quiet k3s; do
    sleep 2; waited=$((waited + 2))
  done
  if ! systemctl is-active --quiet k3s; then
    printf '%s\n' \
      "ERROR: the original configuration was restored, but k3s is not active; manual recovery is required." >&2
    exit 1
  fi

  waited=0
  while [ "$waited" -lt 120 ]; do
    ready="$(sudo k3s kubectl get nodes -o jsonpath='{range .items[*]}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\n"}{end}' 2>/dev/null || true)"
    if [ "$ready" = "True" ]; then break; fi
    sleep 5; waited=$((waited + 5))
  done
  if [ "${ready:-}" != "True" ]; then
    printf '%s\n' \
      "ERROR: the original configuration was restored, but the node did not become Ready; manual recovery is required. Start with: sudo journalctl -u k3s -n 200" >&2
    exit 1
  fi

  printf 'Rollback complete: %s restored from %s.\n' "$REGISTRIES_CONFIG" "$BACKUP_PATH"
)
```

#### B. Removing a configuration the setup transaction created

The original state was the file's *absence*, so this removes it. It regenerates
the deterministic content from `HOST_LAN_IP` and **only removes the file if the
live one matches byte for byte** — otherwise it is no longer this procedure's
to delete. A copy is kept first, purely as a recovery aid; it is not what
authorises the deletion.

```sh
(
  set -euo pipefail

  # EDIT: the LAN address the trust was configured for, or export HOST_LAN_IP.
  HOST_LAN_IP="${HOST_LAN_IP:-}"
  # EDIT: true only if you know the setup transaction created /etc/rancher/k3s
  # itself. On a host where k3s is installed it did not — k3s.yaml lives there.
  REMOVE_CREATED_RANCHER_K3S_DIR=false

  RANCHER_K3S_DIR="/etc/rancher/k3s"
  REGISTRIES_CONFIG="${RANCHER_K3S_DIR}/registries.yaml"
  EXPECTED_CONFIG=""
  EMERGENCY_COPY=""   # deliberately kept, never cleaned up

  cleanup_rollback() {
    local rc="$?"
    trap - EXIT INT TERM
    if [ -n "$EXPECTED_CONFIG" ]; then
      rm -f -- "$EXPECTED_CONFIG" || true
    fi
    exit "$rc"
  }

  trap cleanup_rollback EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  if [ -z "$HOST_LAN_IP" ]; then
    printf 'ERROR: HOST_LAN_IP is not set; it decides what the expected content is.\n' >&2
    exit 1
  fi
  if ! sudo test -e "$REGISTRIES_CONFIG"; then
    printf 'Nothing to do: %s does not exist.\n' "$REGISTRIES_CONFIG"
    exit 0
  fi

  # Regenerate exactly what the setup transaction would have written.
  EXPECTED_CONFIG="$(mktemp)"
  chmod 0600 "$EXPECTED_CONFIG"
  cat >"$EXPECTED_CONFIG" <<EOF
# Managed by homelab-platform (see docs/k3s-runbook.md).
# Trusts the local plain-HTTP registry from registry/docker-compose.yml.
# No TLS and no auth by design: trusted single-user LAN only.
mirrors:
  "${HOST_LAN_IP}:5000":
    endpoint:
      - "http://${HOST_LAN_IP}:5000"
EOF

  # --- ownership gate -------------------------------------------------------
  #
  # The status is captured in the `else` branch, never after `if ! cmp`: there
  # `$?` would be the status of the `!` itself (always 0), losing the
  # difference between "files differ" and "the comparison failed".
  cmp_rc=0
  if sudo cmp -s -- "$REGISTRIES_CONFIG" "$EXPECTED_CONFIG"; then
    : # the live file is exactly what this repository generates
  else
    cmp_rc=$?
    case "$cmp_rc" in
      1)
        printf 'ERROR: %s is not the configuration this repository generates, or the privileged comparison was inconclusive (status 1).\n' \
          "$REGISTRIES_CONFIG" >&2
        ;;
      *)
        printf 'ERROR: the ownership comparison failed (cmp exit %s).\n' "$cmp_rc" >&2
        ;;
    esac
    printf '%s\n' \
      "NOT deleting it. If you merged this entry into a pre-existing file, use rollback A instead. Otherwise recover by hand." >&2
    exit 1
  fi

  EMERGENCY_COPY="$(umask 077; mktemp "${TMPDIR:-/tmp}/registries.yaml.removed-XXXXXXXX")"
  # shellcheck disable=SC2024
  # The redirect deliberately runs as your user, so the copy stays user-owned;
  # only cat's read of the root-owned file needs elevation.
  sudo cat "$REGISTRIES_CONFIG" >"$EMERGENCY_COPY"
  printf 'Copy of the file about to be removed: %s\n' "$EMERGENCY_COPY"

  sudo rm -f -- "$REGISTRIES_CONFIG"

  # rmdir, never rm -r: it succeeds only while the directory is empty, so
  # anything else that put files there survives untouched.
  if [ "$REMOVE_CREATED_RANCHER_K3S_DIR" = true ]; then
    if sudo rmdir -- "$RANCHER_K3S_DIR" 2>/dev/null; then
      printf 'Removed %s (it was empty).\n' "$RANCHER_K3S_DIR"
    else
      printf 'WARNING: %s is not empty; leaving it in place.\n' "$RANCHER_K3S_DIR" >&2
    fi
  fi

  sudo systemctl restart k3s
  waited=0
  while [ "$waited" -lt 60 ] && ! systemctl is-active --quiet k3s; do
    sleep 2; waited=$((waited + 2))
  done
  if ! systemctl is-active --quiet k3s; then
    printf '%s\n' \
      "ERROR: ${REGISTRIES_CONFIG} was removed, but k3s is not active; manual recovery is required. The removed file is preserved at ${EMERGENCY_COPY}." >&2
    exit 1
  fi

  waited=0
  while [ "$waited" -lt 120 ]; do
    ready="$(sudo k3s kubectl get nodes -o jsonpath='{range .items[*]}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\n"}{end}' 2>/dev/null || true)"
    if [ "$ready" = "True" ]; then break; fi
    sleep 5; waited=$((waited + 5))
  done
  if [ "${ready:-}" != "True" ]; then
    printf '%s\n' \
      "ERROR: the file was removed, but the node did not become Ready; manual recovery is required. The removed file is preserved at ${EMERGENCY_COPY}." >&2
    exit 1
  fi

  printf 'Rollback complete: %s removed (no configuration existed originally).\n' \
    "$REGISTRIES_CONFIG"
)
```

### Registry trust security notes

- Trusting a plain-HTTP registry means **more of this host's runtimes now
  accept unencrypted registry traffic** — previously only the Docker daemon,
  now the cluster runtime as well. Anyone able to intercept that traffic on the
  LAN could serve arbitrary images to the cluster.
- It does **not** change the registry's own security properties. That registry
  is still unauthenticated and still plain HTTP; see the safety notes in
  [`docs/registry-runbook.md`](./registry-runbook.md).
- This is for a **trusted, single-user local area network only**, and must
  never be exposed to the public internet. Any production or cloud use needs
  **authentication and TLS** first.
- A k3s uninstall removes `/etc/rancher/k3s`, and with it this configuration.
  Surviving a service restart is not the same as surviving a reinstall.

## Destructive uninstall / reset procedure

This is intentionally **not** part of `install.sh`, and `install.sh` never
invokes it. It is not a rollback — there is no clean undo for an install.

The k3s installer generates an uninstall script on the host:

```sh
sudo /usr/local/bin/k3s-uninstall.sh
```

Running it stops all workloads and **permanently removes**:

- the local cluster datastore (etcd/SQLite) — all Kubernetes objects;
- Local Storage Provider persistent volume data under `/var/lib/rancher/k3s`;
- node configuration under `/etc/rancher/k3s`, including the kubeconfig;
- the installed k3s binaries, scripts, and helper tools.

It does **not** delete data held by persistent volumes backed by external
storage (NFS, iSCSI, or any other out-of-cluster system). The fate of that data
is governed by the external storage system, not by the uninstaller. Whether it
is still reachable after a reinstall depends on how you re-declare those
volumes.

Before running it, make sure anything you care about is backed up elsewhere. A
kubeconfig backup does not qualify.

Use this procedure when you need to clear a partial or unwanted installation
before installing again.

## Safety notes

- The script performs all validation and inspection **before** any mutation,
  and prints its summary before acting.
- Only two operations change the host: the timestamped kubeconfig copy, and
  the upstream installer invocation. Both are reachable only from the
  `install` outcome.
- The `noop` and `mismatch` outcomes are fully read-only.
- Fixed paths (`/etc/rancher/k3s/k3s.yaml`, `/usr/local/bin/k3s`) are constants
  in the script and cannot be redirected by environment variables.
- `HOST_LAN_IP` is validated against the whole string before use, so a
  multi-line value — for example the output of `ip -4 -o addr show` on a host
  with several interfaces — is rejected rather than passed through into the
  generated systemd unit. Supply exactly one address.
- The install pipes the upstream installer from `https://get.k3s.io` into a
  root shell, which is the method k3s documents. Its integrity rests on HTTPS
  and on the k3s project itself; the script does not independently verify the
  installer's signature. The installer does verify the checksum of the k3s
  binary it downloads.

## Tests

Both scripts are covered by plain-bash suites that require no root, no systemd,
no real k3s unit, no access to `/etc/rancher`, no Docker, no registry, no
cluster and no network:

```sh
bash k3s/install.test.sh
bash k3s/registry-pull-test.test.sh
```

`registry-pull-test.test.sh` covers the input validation, the mandatory
explicit `KUBECONFIG`, the cluster-identity checks, the run-identity
generation, the push-digest and `imageID` parsers, the Pod phase handling, and
the cleanup ownership rules — including that cleanup never selects by prefix,
label or `--all`. It is **not** a substitute for the runtime proof: that is the
two live runs described under
[Verifying the registry trust](#verifying-the-registry-trust).

ShellCheck is not assumed to be installed on the host. Run it in a container:

```sh
docker run --rm -v "$PWD:/mnt:ro" -w /mnt koalaman/shellcheck:stable \
  k3s/install.sh k3s/install.test.sh \
  k3s/registry-pull-test.sh k3s/registry-pull-test.test.sh
```

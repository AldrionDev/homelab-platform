# Local registry runbook

An unauthenticated, plain-HTTP Docker registry on the host, defined by
[`registry/docker-compose.yml`](../registry/docker-compose.yml) and verified by
[`registry/smoke-test.sh`](../registry/smoke-test.sh).

Read [Safety notes](#safety-notes) before exposing this to anything.

## Verification status

The primary setup and verification path documented below was successfully
exercised on a real host. The recovery, failure and destructive procedures were
not — they are written and statically checked, not runtime-verified. Know which
is which before you rely on one.

### Verified on a real host

- the [Docker daemon trust](#docker-daemon-trust) transaction, on a host where
  **neither `/etc/docker` nor `daemon.json` existed**: the proposed
  configuration validated, the directory was created `root:root 0755` and the
  config `root:root 0644`;
- Docker reloaded successfully and the service stayed active;
- Compose rendering, and registry startup;
- the port binding restricted to the configured LAN IPv4 address — no wildcard
  listener and no loopback listener;
- `/v2/` readiness returning HTTP `200`;
- the `unless-stopped` restart policy, read back from the running container;
- the named volume attached at the expected mount point;
- the absence of any authentication or TLS configuration;
- the smoke test end to end: build, push, extraction and validation of the
  push-owned digest, the post-push tag resolving to that same digest, removal
  of the local tagged image, pull by immutable digest, manifest `DELETE`
  returning `202`, and both the digest and the tag returning `404` afterwards;
- cleanup, which produced no warnings and left no local image, tag, or scratch
  file behind;
- the registry still running and reachable after the test.

Because there was no original daemon configuration on that host, **no setup
backup was created**. No reload error occurred, so **no rollback path was
needed or executed**.

### Documented but not executed during this verification

These are reviewed and documented procedures. Their shell blocks were
syntax-checked with `bash -n` and linted with ShellCheck, but **static
validation is not host execution** — do not describe any of them as
runtime-verified:

- the [destructive reset](#destructive-reset) (`docker compose down -v`);
- [standalone exact rollback from a backup](#a-exact-rollback-from-a-backup);
- [standalone rollback for an originally absent config](#b-exact-rollback-when-no-config-existed-before);
- [logical rollback of only the registry trust entry](#c-logical-rollback--drop-only-this-registry);
- the automatic reload-failure rollback path inside the setup transaction, and
  the handling of a rollback whose own reload fails — neither was reachable,
  because the reload succeeded;
- garbage collection;
- routine lifecycle commands beyond those listed above — `stop`, `logs`, plain
  `down`, and the restart fallback.

The destructive and failure-injection procedures were **deliberately** left
unexercised: proving them on a working host would have meant destroying the
registry volume or breaking a healthy Docker daemon on purpose. Treat them as
carefully written instructions, and read them before you need them.

### What a successful delete looks like afterwards

Expect this, and do not mistake it for a failed deletion:

- the repository name **stays visible** in `GET /v2/_catalog`;
- `GET /v2/<repo>/tags/list` returns `"tags": null`;
- unreferenced blobs remain on disk until a garbage collection run.

The manifest is gone — that is what the `404` on both the digest and the tag
proves. Nothing here reclaims disk space, and garbage collection stays out of
scope; see
[Delete, upload purge, and garbage collection](#delete-upload-purge-and-garbage-collection).

## Prerequisites

- Docker Engine with the Compose plugin.
- The host's LAN IPv4 address (`ip -4 addr`), set as `HOST_LAN_IP` in `.env`
  at the repository root. Copy `.env.example` and fill it in. There is no
  default: the compose file refuses to start without it, rather than falling
  back to a `0.0.0.0` bind.
- `jq` and `cmp` — only for the [Docker daemon trust](#docker-daemon-trust)
  section. `cmp` ships with GNU diffutils and is present on any ordinary
  GNU/Linux host; `jq` may need installing. The smoke test needs neither.

## Starting and stopping

All commands run from the repository root.

```sh
docker compose -f registry/docker-compose.yml --env-file .env up -d
docker compose -f registry/docker-compose.yml --env-file .env ps
docker compose -f registry/docker-compose.yml --env-file .env logs -f
docker compose -f registry/docker-compose.yml --env-file .env stop
```

`--env-file .env` is not optional in these commands. Compose resolves a bare
`.env` relative to the compose file's directory (`registry/`), not the
repository root, so without the flag the root `.env` would be ignored.

Re-running `up -d` against an unchanged configuration is a no-op.

## Verifying

```sh
curl --fail --silent --show-error \
  --retry 10 --retry-delay 1 --retry-connrefused \
  "http://<HOST_LAN_IP>:5000/v2/"
```

A healthy registry answers `{}`. The retry is bounded (about ten seconds): it
absorbs the startup gap after `up -d` or `docker restart`, and still fails
loudly — with curl's own last error — if the registry is genuinely down.

Confirm the restart policy at runtime, rather than trusting the file:

```sh
docker inspect \
  --format '{{.HostConfig.RestartPolicy.Name}}' \
  homelab-registry
```

Expected: `unless-stopped`.

Then run the full push/pull/delete cycle:

```sh
HOST_LAN_IP=<lan-ip> bash registry/smoke-test.sh
```

See [Tests](#tests) for what that covers and what it cannot promise.

## Data and backups

Image data lives in the Docker volume `homelab-registry-data`. The name is
fixed in the compose file so the future platform backup routine has a stable
target.

```sh
docker volume inspect homelab-registry-data
```

## Destructive reset

```sh
docker compose -f registry/docker-compose.yml --env-file .env down -v
```

`-v` removes `homelab-registry-data` and with it **every image ever pushed to
this registry**. There is no undo. Without `-v`, `down` only removes the
container and the volume survives.

## Delete, upload purge, and garbage collection

Three different things, often confused:

- **Manifest DELETE** — what the smoke test does, and what
  `REGISTRY_STORAGE_DELETE_ENABLED=true` enables. It removes the manifest
  reference. It does not by itself guarantee that disk space is reclaimed.
- **Unfinished upload directories** — left behind when a push is interrupted
  mid-transfer. The registry image's default upload-purge behaviour may deal
  with them. This repository neither reconfigures nor automates that
  behaviour.
- **Unreferenced finalized blobs** — blobs left with no manifest pointing at
  them. Reclaiming that disk space requires a garbage collection run, which is
  deliberately out of scope here, as are custom retention and upload-purge
  policies.

Practical consequence: on this registry, disk usage grows monotonically until
someone runs garbage collection manually. For a home lab that is an accepted,
documented trade-off.

## Docker daemon trust

The registry serves plain HTTP on the LAN address. Docker treats every registry
except loopback as HTTPS by default, so `docker push <HOST_LAN_IP>:5000/...`
fails with `http: server gave HTTP response to HTTPS client` until the daemon
is told to trust this endpoint.

This is a **host-level change**, performed manually and once. This repository
deliberately ships no script for it.

**Copy the whole block below and run it as a unit.** It is a single
`set -euo pipefail` subshell, and it is only fail-closed as a unit: pasted line
by line into a normal shell, execution would continue past a failed `jq`,
`dockerd --validate`, `install`, `mv`, or `systemctl`. The subshell keeps the
strict options from leaking into your interactive shell.

Set `HOST_LAN_IP` in your shell first.

```sh
(
  set -euo pipefail

  readonly DOCKER_CONFIG_DIR="/etc/docker"
  readonly DAEMON_CONFIG="${DOCKER_CONFIG_DIR}/daemon.json"

  HAD_DOCKER_CONFIG_DIR=false      # did /etc/docker exist beforehand
  CREATED_DOCKER_CONFIG_DIR=false  # true only if this transaction created it
  HAD_DAEMON_CONFIG=false   # did a config exist before we touched anything
  ORIGINAL_MODE=""          # original file mode, for an exact rollback
  ORIGINAL_UID=""           # original owner uid
  ORIGINAL_GID=""           # original owner gid
  BACKUP_PATH=""            # surviving backup; input to the rollback
  ORIGINAL_CONFIG_SNAPSHOT=""  # user-owned copy of the config as first read
  TMP_CONFIG=""             # user-owned scratch copy of the new content
  STAGED_CONFIG=""          # root-owned staging file next to the target
  RESTORE_STAGED=""         # root-owned staging file used by the rollback
  CONFIG_COMMITTED=false    # true only after a successful rename
  RELOAD_SUCCEEDED=false    # true only after reload AND is-active both pass
  TARGET_MODE="0644"
  TARGET_UID="0"
  TARGET_GID="0"

  # Removes scratch and staging files only. It never restores the daemon
  # config: not every failure happens after the commit, the rollback itself
  # can fail, and its result has to be checked explicitly.
  cleanup_daemon_transaction() {
    local rc="$?"
    trap - EXIT INT TERM

    # Scratch files this shell owns. BACKUP_PATH is deliberately not here: it
    # has to outlive the transaction as the rollback's input.
    local user_tmp
    for user_tmp in "$TMP_CONFIG" "$ORIGINAL_CONFIG_SNAPSHOT"; do
      [ -n "$user_tmp" ] || continue
      if ! rm -f -- "$user_tmp"; then
        printf 'WARNING: failed to remove %s\n' "$user_tmp" >&2
      fi
    done

    # Files created under /etc/docker with sudo mktemp are root-owned, so a
    # plain rm is not enough.
    local root_tmp
    for root_tmp in "$STAGED_CONFIG" "$RESTORE_STAGED"; do
      [ -n "$root_tmp" ] || continue
      if ! sudo rm -f -- "$root_tmp"; then
        printf 'WARNING: failed to remove %s\n' "$root_tmp" >&2
      fi
    done

    # If this transaction created /etc/docker but never committed a config
    # into it, take the directory back out — but only with rmdir, so a
    # directory anything else has since written to is left alone. Never
    # recursive, and never against a directory that already existed.
    if [ "$CREATED_DOCKER_CONFIG_DIR" = true ] \
      && [ "$CONFIG_COMMITTED" = false ]; then
      if ! sudo rmdir -- "$DOCKER_CONFIG_DIR" 2>/dev/null; then
        printf 'WARNING: %s was created by this transaction but could not be removed (not empty?); leaving it in place\n' \
          "$DOCKER_CONFIG_DIR" >&2
      fi
    fi

    # Covers the window between the commit and a confirmed reload: an interrupt
    # there leaves a new config on disk that Docker has never loaded.
    if [ "$rc" -ne 0 ] \
      && [ "$CONFIG_COMMITTED" = true ] \
      && [ "$RELOAD_SUCCEEDED" = false ]; then
      printf 'NOTE: %s was replaced but no reload was confirmed. Backup: %s\n' \
        "$DAEMON_CONFIG" \
        "${BACKUP_PATH:-<none - no config existed before>}" >&2
    fi

    exit "$rc"
  }

  # Compares two files and ends the transaction unless they are proven
  # identical. Only status 0 counts as equal; every other outcome stops the
  # run. Calling `exit` here ends the subshell even when errexit is suspended
  # in a conditional, so no caller can bypass it.
  #
  # Status 1 is deliberately reported as inconclusive rather than as a proven
  # content difference: `cmp` uses 1 for "files differ", but a `sudo` that
  # fails on its own also exits 1, and the two are indistinguishable from out
  # here. Either way the answer is "equality was not established", and the
  # transaction stops. Status above 1 is a definite comparison failure.
  compare_files_or_die() {
    local left="$1"
    local right="$2"
    local inconclusive_message="$3"
    local failure_message="$4"
    local cmp_rc=0

    if sudo cmp -s -- "$left" "$right"; then
      return 0
    else
      cmp_rc=$?
    fi

    case "$cmp_rc" in
      1)
        printf 'ERROR: %s\n' "$inconclusive_message" >&2
        ;;
      *)
        printf 'ERROR: %s (comparing %s and %s; cmp exit %s)\n' \
          "$failure_message" "$left" "$right" "$cmp_rc" >&2
        ;;
    esac

    exit 1
  }

  # Every step returns explicitly. `set -e` is suspended inside a function
  # called from an `if !` condition, so implicit errexit cannot be relied on
  # here — without these `|| return 1` guards a failed install or mv would be
  # ignored and the caller would report a successful restore.
  rollback_daemon_config() {
    if [ "$HAD_DAEMON_CONFIG" = true ]; then
      RESTORE_STAGED="$(
        sudo mktemp "${DOCKER_CONFIG_DIR}/.daemon.json.restore.XXXXXXXX"
      )" || return 1
      sudo install \
        -o "$ORIGINAL_UID" \
        -g "$ORIGINAL_GID" \
        -m "$ORIGINAL_MODE" \
        "$BACKUP_PATH" \
        "$RESTORE_STAGED" \
        || return 1
      sudo mv -fT -- "$RESTORE_STAGED" "$DAEMON_CONFIG" || return 1
      RESTORE_STAGED=""
    else
      # We created the file; the exact original state is its absence.
      sudo rm -f -- "$DAEMON_CONFIG" || return 1

      # And if we created the directory too, take that back as well — but only
      # if it is empty. A non-empty directory means something else put files
      # there; warn and leave it. Never `rm -rf` under /etc.
      if [ "$CREATED_DOCKER_CONFIG_DIR" = true ]; then
        if ! sudo rmdir -- "$DOCKER_CONFIG_DIR" 2>/dev/null; then
          printf 'WARNING: %s was created by this transaction but is not empty; leaving it in place\n' \
            "$DOCKER_CONFIG_DIR" >&2
        fi
      fi
    fi
    return 0
  }

  trap cleanup_daemon_transaction EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  # --- original state -------------------------------------------------------

  # Not every Docker installation ships /etc/docker: the daemon only needs it
  # when there is something to read. Record whether it was already there, so
  # rollback knows whether it may take it away again. Read-only.
  if sudo test -d "$DOCKER_CONFIG_DIR"; then
    HAD_DOCKER_CONFIG_DIR=true
  elif sudo test -e "$DOCKER_CONFIG_DIR"; then
    printf 'ERROR: %s exists but is not a directory\n' "$DOCKER_CONFIG_DIR" >&2
    exit 1
  fi

  if sudo test -e "$DAEMON_CONFIG"; then
    HAD_DAEMON_CONFIG=true
    ORIGINAL_MODE="$(sudo stat -c '%a' "$DAEMON_CONFIG")"
    ORIGINAL_UID="$(sudo stat -c '%u' "$DAEMON_CONFIG")"
    ORIGINAL_GID="$(sudo stat -c '%g' "$DAEMON_CONFIG")"
    # Preserve whatever is there. root:root 0644 is the normal expectation,
    # but if this host had something stricter, do not quietly loosen it.
    TARGET_MODE="$ORIGINAL_MODE"
    TARGET_UID="$ORIGINAL_UID"
    TARGET_GID="$ORIGINAL_GID"
  fi

  # --- snapshot the original configuration (read-only) ----------------------

  # A user-owned copy of the config exactly as it was first read. Everything
  # downstream is derived from and compared against this, so a config that
  # changes underneath us is detected rather than silently overwritten.
  if [ "$HAD_DAEMON_CONFIG" = true ]; then
    ORIGINAL_CONFIG_SNAPSHOT="$(mktemp)"
    sudo cat -- "$DAEMON_CONFIG" >"$ORIGINAL_CONFIG_SNAPSHOT"
  fi

  # --- new configuration, in a scratch file (read-only w.r.t. the host) -----

  TMP_CONFIG="$(mktemp)"

  if [ "$HAD_DAEMON_CONFIG" = true ]; then
    # Built from the snapshot, not from the live file.
    jq --arg registry "${HOST_LAN_IP}:5000" '
      .["insecure-registries"] =
        (
          (.["insecure-registries"] // []) +
          [$registry]
          | unique
        )
    ' "$ORIGINAL_CONFIG_SNAPSHOT" >"$TMP_CONFIG"
  else
    jq -n --arg registry "${HOST_LAN_IP}:5000" '
      {
        "insecure-registries": [$registry]
      }
    ' >"$TMP_CONFIG"
  fi

  # --- validate before ANY mutation under /etc/docker -----------------------

  # Nothing above this line has written to /etc/docker: not a backup, not the
  # directory, not a staging file. Invalid JSON or a rejected config therefore
  # leaves the host byte-for-byte as it was.
  jq empty "$TMP_CONFIG"
  sudo dockerd --validate --config-file="$TMP_CONFIG"

  # --- backup: the first host mutation, and only now ------------------------

  if [ "$HAD_DAEMON_CONFIG" = true ]; then
    compare_files_or_die \
      "$DAEMON_CONFIG" \
      "$ORIGINAL_CONFIG_SNAPSHOT" \
      "${DAEMON_CONFIG} differs from the snapshot taken moments ago, or the privileged comparison could not be conclusively completed (status 1); refusing to back it up or overwrite it." \
      "Cannot verify the active configuration; refusing to continue"

    BACKUP_PATH="$(
      sudo mktemp "${DOCKER_CONFIG_DIR}/daemon.json.backup-XXXXXXXX"
    )"
    sudo cp -p -- "$DAEMON_CONFIG" "$BACKUP_PATH"
    printf 'Backup created: %s\n' "$BACKUP_PATH"
    sudo stat --format='Backup owner=%u:%g mode=%a path=%n' "$BACKUP_PATH"

    # The rollback restores this file, so it must hold the same bytes the
    # proposed config was derived from.
    compare_files_or_die \
      "$BACKUP_PATH" \
      "$ORIGINAL_CONFIG_SNAPSHOT" \
      "Equality between the backup at ${BACKUP_PATH} and the configuration snapshot used to generate the proposed update was not established (the files differ, or the privileged comparison could not be conclusively completed with status 1); refusing to continue." \
      "Cannot verify backup consistency; refusing to continue. The backup is left at ${BACKUP_PATH} for inspection"
  fi

  # --- stage next to the target, then commit with a rename ------------------

  # Creating the directory earlier would leave a stray /etc/docker behind
  # whenever validation rejects the config.
  if [ "$HAD_DOCKER_CONFIG_DIR" = false ]; then
    sudo install \
      -d \
      -o root \
      -g root \
      -m 0755 \
      "$DOCKER_CONFIG_DIR"
    CREATED_DOCKER_CONFIG_DIR=true
    printf 'Created %s (root:root 0755).\n' "$DOCKER_CONFIG_DIR"
  fi

  STAGED_CONFIG="$(sudo mktemp "${DOCKER_CONFIG_DIR}/.daemon.json.XXXXXXXX")"
  sudo install \
    -o "$TARGET_UID" \
    -g "$TARGET_GID" \
    -m "$TARGET_MODE" \
    "$TMP_CONFIG" \
    "$STAGED_CONFIG"

  # Last check before the commit point: validation and backup took time, and
  # the rename is irreversible for anything written meanwhile. It narrows the
  # window, it does not close it — see "Concurrency" below.
  if [ "$HAD_DAEMON_CONFIG" = true ]; then
    compare_files_or_die \
      "$DAEMON_CONFIG" \
      "$ORIGINAL_CONFIG_SNAPSHOT" \
      "${DAEMON_CONFIG} differs from the snapshot, or the privileged comparison could not be conclusively completed (status 1); refusing to commit. The backup at ${BACKUP_PATH} remains available and holds the earlier content." \
      "The final consistency check failed; refusing to commit"
  fi

  sudo mv -fT -- "$STAGED_CONFIG" "$DAEMON_CONFIG"
  CONFIG_COMMITTED=true
  STAGED_CONFIG=""

  # --- reload, with an explicit failure branch ------------------------------

  if sudo systemctl reload docker \
    && sudo systemctl is-active --quiet docker; then
    RELOAD_SUCCEEDED=true
    printf 'Docker reloaded with %s trusted.\n' "${HOST_LAN_IP}:5000"
  else
    printf '%s\n' \
      "ERROR: Docker reload failed; restoring the original configuration." >&2

    if ! rollback_daemon_config; then
      printf '%s\n' \
        "ERROR: Failed to restore the original Docker configuration; manual recovery is required. The newly committed /etc/docker/daemon.json may still be in place — compare it against the backup printed above." >&2
      exit 1
    fi

    if ! sudo systemctl reload docker \
      || ! sudo systemctl is-active --quiet docker; then
      printf '%s\n' \
        "ERROR: The original configuration was restored, but Docker could not reload it; manual recovery is required." >&2
      exit 1
    fi

    printf '%s\n' \
      "ERROR: The new configuration was rejected. The original configuration was restored successfully." >&2
    exit 1
  fi
)
```

Then verify with a real push:

```sh
HOST_LAN_IP=<lan-ip> bash registry/smoke-test.sh
```

What this transaction guarantees:

- **nothing under `/etc/docker` is written before both `jq empty` and
  `dockerd --validate` pass** — not the backup, not the directory, not a
  staging file. A rejected configuration leaves the host exactly as it was;
- the proposed config is generated from a user-owned snapshot of the original,
  and **any difference the comparisons detect** stops the transaction before the
  overwrite (best-effort detection — see [Concurrency](#concurrency-what-is-and-is-not-guaranteed));
- the backup is verified against that same snapshot, so the rollback restores
  the bytes the update was actually derived from;
- every comparison is fail-closed: a content difference and a failed comparison
  both stop the transaction, with different diagnostics;
- the same file is never read and written in one pipeline;
- existing keys survive — only `insecure-registries` changes, and `unique`
  keeps the list free of duplicates;
- `mv -fT` between two files in `/etc/docker` is the commit point, and the
  only step here that is atomic; `install` is a validated, controlled copy,
  not an atomic replacement. The rename atomically **replaces** the file — it
  is not an atomic compare-and-swap;
- `CONFIG_COMMITTED` and `RELOAD_SUCCEEDED` are set only after the operation
  they describe actually succeeded;
- a failed reload triggers a restore attempt whose result is checked, and the
  transaction exits non-zero even when the restore worked;
- `/etc/docker` is created only if it was missing, only after both validations
  pass, and only ever removed again with `rmdir` — never recursively, and never
  if it existed beforehand.

### Concurrency: what is and is not guaranteed

The transaction performs **best-effort** concurrent-change detection by
comparing the active configuration against the original snapshot at three
checkpoints: after validation, after backup creation, and — the last one —
**after staging and immediately before commit**. A detected difference stops
the transaction before the overwrite, and a comparison that cannot be carried
out stops it too. Staging is harmless to repeat or abandon: it writes a
throwaway file next to the target, and only the rename replaces anything.

**A narrow residual race remains** between the final comparison and the
`mv -fT` rename. A writer that modifies `daemon.json` inside that window still
has its change replaced. The rename is atomic in the filesystem sense — readers
see either the old file or the new one, never a partial write — but it is not an
atomic compare-and-swap, and nothing here makes the check-then-rename pair
indivisible.

So:

| | |
| --- | --- |
| **Guaranteed** | No `/etc/docker` mutation before both validations pass. A *detected* mismatch, or a failed comparison, stops the transaction before commit. Backup creation is fail-closed. `mv -fT` replaces the file atomically. Rollback is attempted and checked on reload failure. No recursive directory deletion, ever. |
| **Best effort** | Detecting an external writer at all. |
| **Your responsibility** | Giving the transaction exclusive operational access to `/etc/docker/daemon.json`: nothing else — configuration management, a package postinstall script, another administrator, an open editor — may write it while this runs. Closing the final comparison-to-rename window is not something the transaction can do for you. |

This is a deliberate fit for what this repository targets: a trusted,
single-user home lab, where the operator knows what else touches the host. Do
not run this transaction while another process or person may be updating
`daemon.json`.

Stronger protection is not a matter of adding a lock here. An advisory
mechanism such as `flock` only coordinates writers that agree to take the same
lock; it does nothing about a package script, a config-management run, or
someone with an editor open — none of which will consult it. Real safety would
require every writer on the host to honour the same protocol, which is well
outside the scope of this runbook.

### When `/etc/docker` does not exist

Not every Docker installation ships the directory; the daemon creates it only
when it has something to store there. The transaction records that up front:

| Original state | What the transaction does | What rollback does |
| --- | --- | --- |
| Directory exists | leaves it untouched, including its owner and mode | leaves it |
| Directory missing | creates it `root:root 0755`, **after** `jq empty` and `dockerd --validate` both pass | `rmdir` it, only if empty |
| Path exists but is not a directory | fails immediately, before any mutation | n/a |

Two consequences worth stating plainly. First, a configuration that fails
validation leaves the host completely untouched — no stray `/etc/docker`.
Second, if something else writes into the directory before a rollback runs, the
`rmdir` fails and the directory stays. That is deliberate: an empty or
unexpectedly populated `/etc/docker` is a far smaller problem than an
`rm -rf` under `/etc`, so the rollback warns and leaves it.

### Control-flow reference

The order of operations is the whole safety argument, so it is written out here
for both host states. Walk the matching sequence before running the transaction.

#### Case 1 — an existing `daemon.json` (and therefore `/etc/docker`)

| Step | Expected | Touches `/etc/docker`? |
| --- | --- | --- |
| 1. Directory detection | `HAD_DOCKER_CONFIG_DIR=true` | no |
| 2. File detection | `HAD_DAEMON_CONFIG=true`, original uid/gid/mode recorded | no |
| 3. Original snapshot | `sudo cat` into a user-owned temp file | no |
| 4. JSON generation | `jq` reads the **snapshot**, writes a user-owned temp file | no |
| 5. `jq empty` | passes | no |
| 6. `dockerd --validate` | prints `configuration OK` | no |
| 7. Change check | `cmp` live file against snapshot — a detected difference, or a failed comparison, aborts | no |
| 8. **Backup** | `mktemp` + `cp -p`, path and metadata printed | **first mutation** |
| 9. Backup consistency check | `cmp` backup against snapshot — same two failure modes | no |
| 10. Staging | `mktemp` + `install` with the original uid/gid/mode | yes |
| 11. Change re-check | `cmp` live file against snapshot — **after staging, immediately before the rename**; narrows the race, does not close it | no |
| 12. Commit | `mv -fT`, `CONFIG_COMMITTED=true` | yes |
| 13. Reload | succeeds → done; fails → checked rollback from the backup | n/a |

#### Case 2 — neither `daemon.json` nor `/etc/docker`

This is the case that broke an earlier version of this runbook, which called
`sudo mktemp /etc/docker/.daemon.json.XXXXXXXX` against a directory that did not
exist and failed with `No such file or directory` — safely, before any mutation,
but with a confusing message.

| Step | Expected | Touches `/etc/docker`? |
| --- | --- | --- |
| 1. Directory detection | `HAD_DOCKER_CONFIG_DIR=false` | no |
| 2. File detection | `HAD_DAEMON_CONFIG=false`; no snapshot, no backup — there is nothing to snapshot or back up | no |
| 3. JSON generation | `jq -n` writes a user-owned temp file | no |
| 4. `jq empty` | passes | no |
| 5. `dockerd --validate` | prints `configuration OK` | no |
| 6. **Directory creation** | `/etc/docker` created `root:root 0755`, `CREATED_DOCKER_CONFIG_DIR=true`, message printed | **first mutation** |
| 7. Staging | `mktemp` + `install` `root:root 0644` | yes |
| 8. Commit | `mv -fT`, `CONFIG_COMMITTED=true` | yes |
| 9. Reload | succeeds → done; fails → checked rollback | n/a |
| 10. Rollback (if reached) | removes the file, then `rmdir`s the directory only if this transaction created it and it is empty | yes |

#### The invariants both cases share

- **Invalid JSON writes nothing under `/etc/docker`** — no backup, no
  directory, no staging file, no active config. Same for a `dockerd --validate`
  rejection.
- The **first** mutation under `/etc/docker` is the backup when an original
  config exists, or the directory creation when neither exists — and both come
  strictly after validation.
- Failure before the first mutation leaves the host byte-for-byte unchanged.
- In case 2, failure after step 6 but before step 8 leaves the directory
  removed again by the EXIT cleanup — via `rmdir` only.
- A concurrent edit to `daemon.json` that one of the three comparisons *detects*
  aborts the transaction rather than overwriting it, and any backup already
  taken is left in place. Detection is best effort: an edit landing between the
  final comparison and the rename is still replaced — see
  [Concurrency](#concurrency-what-is-and-is-not-guaranteed).

Only `cmp` status 0 counts as equal. The diagnostics separate the two ways a
comparison can stop the run:

| Checkpoint | Status 1 — differ **or** inconclusive | Status > 1 — comparison failed |
| --- | --- | --- |
| Before backup | `<config> differs from the snapshot taken moments ago, or the privileged comparison could not be conclusively completed (status 1); refusing to back it up or overwrite it.` | `Cannot verify the active configuration; refusing to continue` |
| Backup consistency | `Equality between the backup at <path> and the configuration snapshot … was not established (the files differ, or the privileged comparison could not be conclusively completed with status 1); refusing to continue.` | `Cannot verify backup consistency; refusing to continue. The backup is left at <path> for inspection` |
| Before commit | `<config> differs from the snapshot, or the privileged comparison could not be conclusively completed (status 1); refusing to commit. The backup at <path> remains available and holds the earlier content.` | `The final consistency check failed; refusing to commit` |

Status 1 is reported as **inconclusive on purpose**. `cmp` uses 1 for "files
differ", but a `sudo` that fails on its own also exits 1, and from outside the
privileged call the two cannot be told apart. Rather than build a root-side
status channel to disambiguate them, the transaction treats both as "equality
was not established" and stops — the same safe action either way. Do not read a
status-1 message as proof that the file was edited.

Both columns are fail-closed: a content difference, an inconclusive privileged
comparison, an unreadable or missing file, and a failed `sudo cmp` all stop the
run before the backup, staging, or commit can proceed.

The rollback path has no comparison of its own: after a failed reload it writes
the backup back unconditionally. If a third party changed `daemon.json` between
the commit and the rollback, that change is overwritten too. The same operator
exclusivity applies for the whole run, rollback included.

What it does **not** guarantee: that restoration always succeeds. The restore
itself writes to the filesystem and can fail — on a full disk, on a permission
problem, or if `/etc/docker` has changed underneath. Each outcome gets its own
message:

| Message | State the host is left in |
| --- | --- |
| `The new configuration was rejected. The original configuration was restored successfully.` | Original config back in place, Docker reloaded and active. |
| `Failed to restore the original Docker configuration; manual recovery is required.` | The **newly committed config may still be active**. Compare `/etc/docker/daemon.json` against the printed backup path and restore it by hand. |
| `The original configuration was restored, but Docker could not reload it; manual recovery is required.` | Correct file on disk, daemon in an unknown state. |

For the last two, start with `sudo journalctl -u docker` and
`sudo systemctl cat docker`. Do not reach for `systemctl restart docker` to
paper over a failed reload — see [Restart as a fallback](#restart-as-a-fallback).

Leftover `/etc/docker/.daemon.json.*` files mean the cleanup could not remove
them; check for them after a failed run. The backup is intentionally **not**
removed — it is the rollback's input.

### Restart as a fallback

`sudo systemctl restart docker` is a last resort, permitted only when **all**
of these hold:

- the reload command succeeded;
- the daemon is still active;
- the configuration nevertheless did not take effect;
- the service unit and its `ExecStart` have been inspected;
- the daemon logs have been read;
- there is no conflict between the JSON config and a startup flag;
- you have accepted the potential downtime.

Inspect first:

```sh
sudo systemctl is-active docker
sudo systemctl cat docker
sudo systemctl show docker --property=ExecStart
sudo journalctl -u docker --since '-10 minutes'
```

The same Docker option given both in `daemon.json` and as a `dockerd` startup
flag can conflict. `dockerd --validate` validates the JSON file; it does not
necessarily model that clash with the systemd unit's runtime arguments.

A restart may interrupt or restart running containers, depending on their
restart policies and on whether `live-restore` is enabled. It is not safe to
assume every container comes back.

**After a failed reload, a restart is not permitted** — roll back instead.

## Rolling back the daemon trust

Two of these restore the original file state exactly; the third only removes
what this issue added.

Each block below is **complete and standalone**: paste it into a fresh shell.
None of them depends on variables left over from the setup transaction — that
ran in its own subshell, which is long gone. Where a value cannot be derived,
the block starts with an explicitly marked line for you to edit.

Pick one:

- **A** — a `daemon.json` existed before the setup transaction, and you have
  the backup path it printed.
- **B** — no `daemon.json` existed before; the setup transaction created it.
- **C** — you want to keep the rest of the file and drop only this registry.

### A. Exact rollback from a backup

"Exact" means content *and* ownership and mode. Fill in the backup path the
setup transaction printed, plus the original metadata it reported.

```sh
(
  set -euo pipefail

  # EDIT: the path printed as "Backup created:" by the setup transaction.
  BACKUP_PATH="/etc/docker/daemon.json.backup-REPLACE_ME"

  # EDIT if the original file was not root:root 0644. The setup transaction
  # printed these as "Backup owner=UID:GID mode=MODE".
  ORIGINAL_UID="0"
  ORIGINAL_GID="0"
  ORIGINAL_MODE="0644"

  readonly DAEMON_CONFIG="/etc/docker/daemon.json"
  TMP_CONFIG=""      # user-owned scratch copy
  STAGED_CONFIG=""   # root-owned staging file next to the target

  cleanup_rollback() {
    local rc="$?"
    trap - EXIT INT TERM
    if [ -n "$TMP_CONFIG" ]; then
      if ! rm -f -- "$TMP_CONFIG"; then
        printf 'WARNING: failed to remove %s\n' "$TMP_CONFIG" >&2
      fi
    fi
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

  if [ "$BACKUP_PATH" = "/etc/docker/daemon.json.backup-REPLACE_ME" ]; then
    printf 'ERROR: set BACKUP_PATH to the real backup path first.\n' >&2
    exit 1
  fi
  if ! sudo test -f "$BACKUP_PATH"; then
    printf 'ERROR: %s is not a regular file.\n' "$BACKUP_PATH" >&2
    exit 1
  fi

  printf 'Restoring from: %s\n' "$BACKUP_PATH"
  sudo stat --format='Backup owner=%u:%g mode=%a path=%n' "$BACKUP_PATH"

  TMP_CONFIG="$(mktemp)"
  sudo cat "$BACKUP_PATH" >"$TMP_CONFIG"

  jq empty "$TMP_CONFIG"
  sudo dockerd --validate --config-file="$TMP_CONFIG"

  STAGED_CONFIG="$(sudo mktemp /etc/docker/.daemon.json.rollback.XXXXXXXX)"
  sudo install \
    -o "$ORIGINAL_UID" \
    -g "$ORIGINAL_GID" \
    -m "$ORIGINAL_MODE" \
    "$TMP_CONFIG" \
    "$STAGED_CONFIG"

  sudo mv -fT -- "$STAGED_CONFIG" "$DAEMON_CONFIG"
  STAGED_CONFIG=""

  if sudo systemctl reload docker \
    && sudo systemctl is-active --quiet docker; then
    printf 'Rollback complete: %s restored from %s.\n' \
      "$DAEMON_CONFIG" "$BACKUP_PATH"
  else
    printf '%s\n' \
      "ERROR: The backup was restored to ${DAEMON_CONFIG}, but Docker could not reload it; manual recovery is required." >&2
    exit 1
  fi
)
```

### B. Exact rollback when no config existed before

The original state was the file's *absence*, so this removes it rather than
leaving an empty `{}` behind. A copy is kept first, in case the file turns out
to have been wanted after all.

There are two sub-cases, and only you know which applies. The setup transaction
prints `Created /etc/docker (root:root 0755).` when it had to create the
directory as well:

- **the directory already existed** — leave it alone. Set
  `REMOVE_CREATED_DOCKER_CONFIG_DIR=false` (the safe default).
- **the setup transaction created the directory too** — set
  `REMOVE_CREATED_DOCKER_CONFIG_DIR=true` to take it back out. Removal uses
  `rmdir`, so it only succeeds while the directory is empty.

When in doubt, leave it `false`: a leftover empty `/etc/docker` is harmless.

```sh
(
  set -euo pipefail

  # EDIT: true only if you know the setup transaction created /etc/docker
  # itself (it prints "Created /etc/docker" when it does).
  REMOVE_CREATED_DOCKER_CONFIG_DIR=false

  readonly DOCKER_CONFIG_DIR="/etc/docker"
  readonly DAEMON_CONFIG="${DOCKER_CONFIG_DIR}/daemon.json"
  EMERGENCY_COPY=""   # deliberately kept, never cleaned up
  REMOVED=false

  cleanup_rollback() {
    local rc="$?"
    trap - EXIT INT TERM
    if [ "$rc" -ne 0 ] && [ "$REMOVED" = true ]; then
      printf 'NOTE: %s was already removed. A copy is at %s.\n' \
        "$DAEMON_CONFIG" "$EMERGENCY_COPY" >&2
    fi
    exit "$rc"
  }

  trap cleanup_rollback EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  if ! sudo test -e "$DAEMON_CONFIG"; then
    printf 'Nothing to do: %s does not exist.\n' "$DAEMON_CONFIG"
    exit 0
  fi

  # Keep the copy outside the directory that may be removed below.
  EMERGENCY_COPY="$(mktemp "${TMPDIR:-/tmp}/daemon.json.removed-XXXXXXXX")"
  sudo cat "$DAEMON_CONFIG" >"$EMERGENCY_COPY"
  printf 'Copy of the file about to be removed: %s\n' "$EMERGENCY_COPY"

  sudo rm -f -- "$DAEMON_CONFIG"
  REMOVED=true

  # rmdir, never rm -r: it succeeds only while the directory is empty, so
  # anything else that put files there survives untouched.
  if [ "$REMOVE_CREATED_DOCKER_CONFIG_DIR" = true ]; then
    if sudo rmdir -- "$DOCKER_CONFIG_DIR" 2>/dev/null; then
      printf 'Removed %s (it was empty).\n' "$DOCKER_CONFIG_DIR"
    else
      printf 'WARNING: %s is not empty; leaving it in place.\n' \
        "$DOCKER_CONFIG_DIR" >&2
    fi
  fi

  if sudo systemctl reload docker \
    && sudo systemctl is-active --quiet docker; then
    printf 'Rollback complete: %s removed (no config existed originally).\n' \
      "$DAEMON_CONFIG"
  else
    printf '%s\n' \
      "ERROR: ${DAEMON_CONFIG} was removed, but Docker could not reload; manual recovery is required. The removed file is preserved at ${EMERGENCY_COPY}." >&2
    exit 1
  fi
)
```

### C. Logical rollback — drop only this registry

Keeps every unrelated key and every other insecure registry. Takes its own
fail-closed backup first, and restores it if the reload fails.

```sh
(
  set -euo pipefail

  # EDIT: the LAN address this registry was trusted on, or export
  # HOST_LAN_IP before running the block.
  HOST_LAN_IP="${HOST_LAN_IP:-}"

  readonly DAEMON_CONFIG="/etc/docker/daemon.json"
  ORIGINAL_MODE=""
  ORIGINAL_UID=""
  ORIGINAL_GID=""
  BACKUP_PATH=""      # kept; input to the restore below
  TMP_CONFIG=""       # user-owned scratch copy
  STAGED_CONFIG=""    # root-owned staging file
  RESTORE_STAGED=""   # root-owned staging file for the restore path

  cleanup_rollback() {
    local rc="$?"
    trap - EXIT INT TERM
    if [ -n "$TMP_CONFIG" ]; then
      if ! rm -f -- "$TMP_CONFIG"; then
        printf 'WARNING: failed to remove %s\n' "$TMP_CONFIG" >&2
      fi
    fi
    local root_tmp
    for root_tmp in "$STAGED_CONFIG" "$RESTORE_STAGED"; do
      [ -n "$root_tmp" ] || continue
      if ! sudo rm -f -- "$root_tmp"; then
        printf 'WARNING: failed to remove %s\n' "$root_tmp" >&2
      fi
    done
    exit "$rc"
  }

  # Every step returns explicitly: `set -e` is suspended in a function called
  # from an `if !` condition, so a failed install or mv must be reported here.
  restore_pre_rollback_config() {
    RESTORE_STAGED="$(sudo mktemp /etc/docker/.daemon.json.restore.XXXXXXXX)" \
      || return 1
    sudo install \
      -o "$ORIGINAL_UID" \
      -g "$ORIGINAL_GID" \
      -m "$ORIGINAL_MODE" \
      "$BACKUP_PATH" \
      "$RESTORE_STAGED" \
      || return 1
    sudo mv -fT -- "$RESTORE_STAGED" "$DAEMON_CONFIG" || return 1
    RESTORE_STAGED=""
    return 0
  }

  trap cleanup_rollback EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  if [ -z "$HOST_LAN_IP" ]; then
    printf 'ERROR: HOST_LAN_IP is not set; it decides which entry to remove.\n' >&2
    exit 1
  fi
  if ! sudo test -f "$DAEMON_CONFIG"; then
    printf 'ERROR: %s does not exist; nothing to roll back logically.\n' \
      "$DAEMON_CONFIG" >&2
    exit 1
  fi

  ORIGINAL_MODE="$(sudo stat -c '%a' "$DAEMON_CONFIG")"
  ORIGINAL_UID="$(sudo stat -c '%u' "$DAEMON_CONFIG")"
  ORIGINAL_GID="$(sudo stat -c '%g' "$DAEMON_CONFIG")"

  BACKUP_PATH="$(sudo mktemp /etc/docker/daemon.json.backup-XXXXXXXX)"
  sudo cp -p -- "$DAEMON_CONFIG" "$BACKUP_PATH"
  printf 'Backup created: %s\n' "$BACKUP_PATH"

  TMP_CONFIG="$(mktemp)"
  sudo jq --arg registry "${HOST_LAN_IP}:5000" '
    .["insecure-registries"] =
      ((.["insecure-registries"] // []) - [$registry])
    | if (.["insecure-registries"] | length) == 0
      then del(.["insecure-registries"])
      else .
      end
  ' "$DAEMON_CONFIG" >"$TMP_CONFIG"

  jq empty "$TMP_CONFIG"
  sudo dockerd --validate --config-file="$TMP_CONFIG"

  STAGED_CONFIG="$(sudo mktemp /etc/docker/.daemon.json.XXXXXXXX)"
  sudo install \
    -o "$ORIGINAL_UID" \
    -g "$ORIGINAL_GID" \
    -m "$ORIGINAL_MODE" \
    "$TMP_CONFIG" \
    "$STAGED_CONFIG"

  sudo mv -fT -- "$STAGED_CONFIG" "$DAEMON_CONFIG"
  STAGED_CONFIG=""

  if sudo systemctl reload docker \
    && sudo systemctl is-active --quiet docker; then
    printf 'Logical rollback complete: %s:5000 no longer trusted.\n' \
      "$HOST_LAN_IP"
  else
    printf '%s\n' \
      "ERROR: Docker reload failed; restoring the pre-rollback configuration." >&2

    if ! restore_pre_rollback_config; then
      printf '%s\n' \
        "ERROR: Failed to restore the pre-rollback configuration; manual recovery is required. The edited ${DAEMON_CONFIG} may still be in place — compare it against ${BACKUP_PATH}." >&2
      exit 1
    fi

    if ! sudo systemctl reload docker \
      || ! sudo systemctl is-active --quiet docker; then
      printf '%s\n' \
        "ERROR: The pre-rollback configuration was restored, but Docker could not reload it; manual recovery is required." >&2
      exit 1
    fi

    printf '%s\n' \
      "ERROR: The edited configuration was rejected. The pre-rollback configuration was restored successfully." >&2
    exit 1
  fi
)
```

If the `insecure-registries` list empties out, the key is dropped rather than
left as `[]` — same meaning, cleaner file.

A note on the `sudo jq ... >"$TMP_CONFIG"` lines in these blocks: the redirect
deliberately runs as *your* user, not under `sudo`, so the scratch file stays
user-owned. Only `jq`'s read of the root-owned config needs elevation. That is
also why the same file is never both the input and the output.

## Tests

```sh
HOST_LAN_IP=<lan-ip> bash registry/smoke-test.sh
```

The registry must already be running; the script never starts, stops, or
reconfigures it, and never touches the Docker daemon configuration.

What it does:

1. validates `HOST_LAN_IP` (dotted-quad IPv4, loopback rejected) and its
   dependencies (`docker`, `curl`, `od`, `mktemp`);
2. checks `GET /v2/` with a bounded retry;
3. prints the full image reference it is about to use;
4. confirms via `HEAD` that the tag is free, regenerating tag and reference
   together if it is not;
5. builds a `FROM scratch` image whose only layer contains this run's own
   image reference;
6. pushes, and takes the digest **from the push output itself**;
7. checks that the tag still resolves to that digest;
8. removes the local image and pulls it back **by digest**;
9. `DELETE`s that digest and requires `202`;
10. confirms the digest returns `404`, then inspects the tag.

The build content is per-run on purpose. A unique tag alone does not imply a
unique manifest digest — an identical build context reproduces an identical
manifest — and deletion happens by digest, so identical content across runs
could mean deleting an earlier run's artifact.

If the push fails, the script prints Docker's own error first, exits with
Docker's own status, and then points at the
[daemon trust](#docker-daemon-trust) section. It does not claim that every push
failure has that cause.

### Digest ownership, and what concurrency does

This registry has no authentication, so any client on the LAN can move a tag at
any moment. Tags are mutable; digests are not. The script therefore treats the
digest reported by its **own `docker push`** as the single thing it owns:

- that digest is what it pulls, what it deletes, and what cleanup targets;
- a `HEAD` on the tag is used only to *compare* against it, never to decide
  what may be deleted;
- if the push reports no digest, or two conflicting ones, the script fails
  rather than falling back to a tag lookup.

If the tag stops resolving to this run's digest — before the pull, or after the
delete — someone else wrote to it. That manifest belongs to them, so the script
**fails with an interference message and leaves it alone**. It will not pull it,
delete it, or overwrite it to force a tidy `404`. Clean up such a leftover
yourself if it is unwanted.

### Cleanup guarantees

Cleanup runs on success, on shell errors, on an explicit failure, on `SIGINT`
(exit 130), and on `SIGTERM` (exit 143). It deletes this run's pushed digest,
removes the local tag and digest references and the build context, preserves the
original exit code, and reports any cleanup problem as a warning rather than
hiding the real failure. A cleanup delete counts as done only on HTTP `202`;
anything else — `404`, `401`, `405`, `500`, or a transport failure — produces a
warning saying so, never a claim of success.

If the run was interrupted after the push completed but before the digest was
captured, cleanup deliberately deletes nothing: resolving the tag at that point
could hand it someone else's manifest. It prints the tag to inspect by hand.

It cannot run after `SIGKILL`, a host crash or power loss, a Docker daemon
crash, or if the registry becomes unreachable — and it has nothing to delete if
a push was interrupted before the manifest existed, though partial upload data
may remain. Such leftovers are not cleaned up here; see
[Delete, upload purge, and garbage collection](#delete-upload-purge-and-garbage-collection).

To verify the interrupt path: start the test, note the printed
`Smoke-test image:` reference and `Push digest:` value, press `Ctrl-C` after the
push completes but before the delete, and once the script has exited check the
digest:

```sh
curl -sS -I -o /dev/null -w '%{http_code}\n' \
  -H 'Accept: application/vnd.docker.distribution.manifest.v2+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.oci.image.index.v1+json' \
  "http://<HOST_LAN_IP>:5000/v2/homelab-smoke-test/manifests/<push-digest>"
```

Expect `404`. Interrupting *before* the push finishes gives no such promise:
no manifest was created in the first place.

## Safety notes

- This registry is for a **trusted, single-user local area network only**.
- It **must not be exposed to the public internet**.
- Any production or cloud use would require **authentication and TLS** first.
  Neither is configured here, deliberately.
- Anyone who can reach it on the LAN can push images — and, because the delete
  API is enabled, delete them too.
- Docker publishes ports ahead of the usual host firewall rules, so a UFW
  policy alone may not keep this port closed. That is why the compose file
  binds to `$HOST_LAN_IP` only and never to `0.0.0.0`.
- The compose file fails loudly when `HOST_LAN_IP` is unset rather than
  falling back to a wildcard bind.
- Deleting a manifest is not the same as reclaiming disk space.
- The daemon trust transaction may create `/etc/docker` if this host does not
  have it. It does so only after the configuration validates, and it removes it
  again only with `rmdir` — so removal happens only while the directory is
  empty. A pre-existing `/etc/docker` is never modified or removed, and no path
  under `/etc` is ever deleted recursively.

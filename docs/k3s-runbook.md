# k3s runbook

Single-node k3s on bare metal, installed as a systemd service by
[`k3s/install.sh`](../k3s/install.sh).

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

The script's logic is covered by a plain-bash suite that requires no root, no
systemd, no real k3s unit, no access to `/etc/rancher`, and no network:

```sh
bash k3s/install.test.sh
```

# Backup runbook

A generic, application-independent local backup and restore mechanism for
stateful workloads on this platform: a timestamped `tar.gz` archive with a
SHA-256 sidecar, published only after passing a full structural/manifest
validation, restored only into an explicitly separate Recovery Target after
the same validation and a required workload-specific check.

## Verification status

**Verified with smoke/dummy data only, entirely under `mktemp` scratch
directories — not yet exercised against any real Project data.** No
HomeStreamLab or other real application has adopted this mechanism yet; that
integration is explicitly out of scope for this repository (see
[Scope and guarantees](#scope-and-guarantees)).

Four plain-bash/Python test suites, run directly against the real
`backup.sh`, `restore.sh`, and `tar_metadata_check.py`, currently pass in
full:

| Suite | Result |
|---|---|
| `backup/lib.test.sh` | 61 passed, 0 failed |
| `backup/tar_metadata_check.test.sh` | 41 passed, 0 failed |
| `backup/backup.test.sh` | 37 passed, 0 failed |
| `backup/restore.test.sh` | 38 passed, 0 failed |
| **Total** | **177 passed, 0 failed** |

One continuous, 13-step end-to-end scenario matching issue #9's acceptance
verification steps was also exercised successfully, entirely under a single
`mktemp` scratch root: no-destination failure, an explicit `0700`
destination, successful directory and synthetic-DB backups, artifact and
permission verification, checksum and exact-timestamp collision refusal,
deletion of the original dummy data, refusal to restore directly onto that
deleted live path, restore into two separate Recovery Targets, real
workload-validator invocation, byte-exact recovery of both the directory
tree and the synthetic dump, a second backup with a different timestamp, and
confirmation the first backup was not pruned.

**Not exercised, and not claimed:** any real database engine (no PostgreSQL
was installed or run — see [Scope and guarantees](#scope-and-guarantees));
`SIGKILL`/power-loss timing (see
[Backup safety / publication](#backup-safety--publication) and
[Recovery Target ownership and failure handling](#recovery-target-ownership-and-failure-handling)
for the documented, un-live-tested residual in each); any host mutation,
`sudo`, Kubernetes, or HCP Terraform interaction — none of that is part of
this mechanism.

## Scope and guarantees

**This is:**

- a generic local backup/restore **transport** mechanism — shell scripts
  plus one Python helper, nothing else
- fully application-independent: no workload's name, configuration, or
  credentials appear anywhere in this repository
- capable of backing up either a filesystem/data-directory tree, or an
  opaque logical dump produced by an external command (e.g. something like
  `pg_dump`, though the mechanism itself never runs or knows about
  PostgreSQL specifically)
- a timestamped `.tar.gz` archive plus a SHA-256 sidecar per backup
- always given an explicit backup destination — there is no built-in default
- always restored into an explicit Recovery Target, distinct from the live
  source
- always gated, on restore, by a required workload-specific validator

**This is not:**

- a HomeStreamLab backup implementation, or wired to any specific project
- an automatic scheduler or Kubernetes CronJob — nothing in this repository
  schedules backups; that remains a separate, future concern
- automatic retention or pruning — see
  [Retention and destination capacity](#retention-and-destination-capacity)
- application-consistency machinery — see the consistency note in
  [Supported filesystem payload](#supported-filesystem-payload)
- a PostgreSQL logical restore implementation. The synthetic
  database-transport smoke test proves this mechanism moves a dump's exact
  bytes through backup and restore correctly; it does **not** prove
  `pg_dump`/`pg_restore` compatibility, and must never be read as such
- a substitute for workload-specific semantic validation on restore — see
  [Workload validator contract](#workload-validator-contract)

## Prerequisites

- A GNU/Linux environment with `bash`.
- GNU `tar` and `gzip` (archive creation/extraction).
- `sha256sum` (GNU coreutils).
- Standard GNU coreutils already used elsewhere in this repository:
  `find`, `stat`, `realpath`, `mktemp`, `mkdir`, `chmod`, `ln`, `mv`, `cp`,
  `dirname`, `basename`.
- **Python 3, standard library only — no `pip` packages.** Used exclusively
  by `backup/tar_metadata_check.py` to inspect tar member paths, types, and
  the manifest via Python's own `tarfile` module, rather than parsing
  `tar -tv`'s human-formatted text output, which is not a robust,
  machine-readable format for that purpose.

## Backup usage

```sh
BACKUP_DESTINATION=/absolute/path/to/backup-destination \
BACKUP_ID=example-workload \
BACKUP_SOURCE_KIND=dir \
BACKUP_SOURCE_DIR=/absolute/path/to/live-data \
  bash backup/backup.sh
```

Required, always:

- `BACKUP_DESTINATION` — absolute path. **Has no built-in default and is
  never created or `chmod`'d by the script.** It must already exist and
  already be mode exactly `0700` before the script runs — an operator
  provisions it once (`mkdir -m 0700 -- /path/to/destination`) before the
  first backup.
- `BACKUP_ID` — `[A-Za-z0-9-]+` only (letters, digits, hyphens).
- `BACKUP_SOURCE_KIND` — `dir` or `db`.

For `dir` mode:

- `BACKUP_SOURCE_DIR` — absolute path to an existing directory. Also serves
  as the live-data path for the destination/live-data locality guard below.

For `db` mode:

- `BACKUP_LIVE_DATA_PATH` — absolute path, must already exist. A pure
  locality safety gate against `BACKUP_DESTINATION` — never read, archived,
  or logged.
- Trailing CLI argv after `--`: the dump-producer executable and its
  arguments, e.g.:

  ```sh
  BACKUP_DESTINATION=/absolute/path/to/backup-destination \
  BACKUP_ID=example-db \
  BACKUP_SOURCE_KIND=db \
  BACKUP_LIVE_DATA_PATH=/absolute/path/to/db-data-directory \
    bash backup/backup.sh -- /absolute/path/to/dump-producer --flag value
  ```

  The producer is **executed directly as argv** — never through `eval` or a
  shell command string. Its stdout becomes the archived `dump.bin`
  byte-for-byte. A non-zero producer exit fails the backup, including when
  the producer already wrote some stdout before failing. A producer that
  exits `0` but writes zero bytes is also refused — a "successful" backup
  of nothing is not allowed. Any credentials or connection configuration the
  producer needs are entirely its own concern (its own environment, or a
  wrapper script the operator supplies) — never arguments to `backup.sh`
  itself.

Optional:

- `BACKUP_TIMESTAMP` — **test-only** override. If set, it must match
  `^[0-9]{8}T[0-9]{6}Z$` (UTC, `YYYYMMDDTHHMMSSZ`) exactly, or the backup
  fails immediately — there is no fallback and no random collision-avoidance
  behavior. The normal, unset path always uses the real current UTC time in
  the same format and is held to the identical validation.

Destination and live-data path must be **disjoint in both directions** —
equal, the destination nested inside the live path, or the live path nested
inside the destination are all refused before any mutation.

## Supported filesystem payload

For `dir`-mode backups, the source tree may contain only:

- regular files
- directories

and explicitly refuses, before any archive is built:

- symbolic links
- multiply-linked regular files (hardlinks, `nlink > 1`)
- FIFOs, sockets, block/character devices, and any other special entry

This is a deliberate restriction, not an oversight — it keeps the restore
side's extraction contract simple and safe (see
[Restore safety flow](#restore-safety-flow)) and matches exactly what the
mechanism is designed to move: plain data.

**Archiving a live, actively-written directory does not, by itself, create
an application-consistent snapshot.** This generic routine guarantees the
safe transport, publication, and integrity of whatever bytes it is given —
not that those bytes represent a consistent point-in-time state. A workload
that needs consistency must quiesce, snapshot, flush, or otherwise establish
it before invoking `backup.sh` — for example, stopping the service
temporarily, or (for database-shaped data) using an inherently consistent
dump producer in `db` mode instead of archiving a live data directory.

## Archive format

Final published names:

```
<backup-id>-<timestamp>.tar.gz
<backup-id>-<timestamp>.tar.gz.sha256
```

Internal layout, one top-level directory `<backup-id>-<timestamp>/`:

```
<topdir>/manifest              # KEY=value text, see below

# dir-kind:
<topdir>/data/<source-basename>/...

# db-kind:
<topdir>/dump/dump.bin
```

The manifest records `BACKUP_ID`, `SOURCE_KIND`, `CREATED_AT`,
`FORMAT_VERSION`, and either `FILE_COUNT`/`TOTAL_BYTES` (dir-kind) or
`DUMP_SIZE_BYTES`/`DUMP_SHA256` (db-kind) — enough to cross-check the
archived payload against what the manifest claims. It never contains an
absolute source path, a hostname, or any credential.

## Backup safety / publication

1. Validate every input — nothing is mutated yet.
2. Create a private staging area **inside** `BACKUP_DESTINATION`.
3. Build the manifest and archive there.
4. Run the full Python structural/manifest/payload-consistency check
   (`tar_metadata_check.py`) against the **staged** archive. A staged backup
   that would later fail restore's own validation is refused here, before
   any publication — it never reaches the destination at all.
5. Compute the SHA-256 checksum of the validated staged archive.
6. Set the staged archive and checksum to mode `0600`.
7. Publish the **checksum first**, using a collision-refusing hardlink.
8. Publish the **archive last**, the same way.

**Archive visibility is the valid-backup boundary** — nothing else. A
consumer that can see the final archive path is guaranteed its checksum
sidecar is already present and valid.

Collision behavior:

- **Checksum collision** (a file already exists at the final `.sha256`
  path): the pre-existing sidecar is left completely untouched, and the
  archive publish is never attempted.
- **Archive collision** (a file already exists at the final `.tar.gz`
  path): the pre-existing archive is left completely untouched. This
  invocation removes only the checksum it just published, and only after
  re-verifying — by device and inode, not just the path — that it is still
  exactly the file this invocation created.
- **An exact backup-id+timestamp repeat** after an already-successful
  backup fails closed on the checksum collision above; the earlier backup's
  archive and checksum are never touched.

`SIGINT`/`SIGTERM` arriving between the checksum and archive publish steps
are handled explicitly and were exercised directly: the process exits `130`
or `143` respectively, the checksum this invocation published is cleaned up
(again only after the same device+inode ownership check), the archive
remains absent, and no staging directory is left behind.

**The archive/checksum pair is not claimed to be transactionally atomic.**
An untrappable interruption — `SIGKILL`, or power loss — between the
checksum and archive publish steps is a real, disclosed, un-live-tested
residual: it can leave an orphan checksum sidecar with no matching archive.
Such a sidecar is **not** a valid backup (archive visibility is the only
validity boundary), but it does block an exact same-name retry, since that
retry will hit the same checksum-collision refusal above. Recovering from
this requires an operator to manually confirm no matching archive exists at
that path and then remove the orphan sidecar file before retrying with the
same backup ID and timestamp — or simply retry with a different timestamp,
which sidesteps the collision entirely.

## Restore usage

```sh
BACKUP_ARCHIVE=/absolute/path/to/backup-destination/example-workload-20260101T000000Z.tar.gz \
RECOVERY_TARGET=/absolute/path/to/a-new-recovery-target \
RESTORE_LIVE_DATA_PATH=/absolute/path/to/the-live-data-this-protects \
  bash backup/restore.sh -- /absolute/path/to/workload-validator --flag value
```

Required, always:

- `BACKUP_ARCHIVE` — path to a previously published `.tar.gz`, with its
  `.tar.gz.sha256` sidecar alongside it.
- `RECOVERY_TARGET` — absolute path. **Has no default and must not
  currently exist** as a file, directory, or symlink (including a dangling
  one) — restore never writes into live data directly, always into a
  separate, freshly-claimed target.
- `RESTORE_LIVE_DATA_PATH` — absolute path, a pure safety gate. Required
  even when the original live data no longer exists — that is exactly the
  disaster-recovery scenario this guard is for. `RECOVERY_TARGET` and
  `RESTORE_LIVE_DATA_PATH` must be disjoint in both directions (equal,
  either nested inside the other), and this is still enforced correctly
  even after the original live leaf has been deleted. An existing symlink
  at the live-data path that resolves to the recovery target's location is
  refused after resolution; a **dangling** symlink at the live-data path is
  refused outright, as ambiguous, rather than guessed at.
- Trailing CLI argv after `--`: the workload validator executable and its
  arguments (see
  [Workload validator contract](#workload-validator-contract)).

## Restore safety flow

1. Parse the checksum sidecar strictly (exactly one line, a 64-character
   hex digest, and a filename field that must equal `BACKUP_ARCHIVE`'s own
   basename exactly).
2. Create a private restore scratch directory, and copy `BACKUP_ARCHIVE`
   into it **once**, as a private snapshot. **The external archive path is
   never reopened after this point** — every subsequent step operates only
   on the snapshot. This is what closes the "the archive changed between
   being checked and being used" race: checksum verification, the full
   Python validation, and the actual extraction all read the identical
   snapshot bytes.
3. Compute the SHA-256 of the snapshot and compare it to the sidecar's
   digest.
4. Run the same `tar_metadata_check.py` full-contract check against the
   snapshot. This is what rejects an unsafe tar entry (an absolute path, a
   `..` component, a symlink/hardlink/FIFO/device member, a duplicate or
   aliased member path, an unsupported extra member, or a malformed
   manifest) — **before any extraction happens at all.**
5. Only after both of those gates pass, atomically claim `RECOVERY_TARGET`
   with `mkdir` (mode `0700`) — the real, POSIX-guaranteed exclusive-create
   primitive this mechanism relies on. No stronger directory-level
   transactional atomicity than that is claimed anywhere.
6. Record the claimed target's device and inode, and a token generated with
   Python's `secrets.token_hex(32)` (a cryptographically strong random
   value, not shell `$RANDOM`), into `RECOVERY_TARGET/.restore-control`
   (mode `0600`) — outside the extraction subtree entirely, so archive
   payload can never overwrite it.
7. Extract the snapshot into `RECOVERY_TARGET/payload`, under `umask 0077`,
   with GNU tar's `--no-same-owner --no-same-permissions`.
8. Run a second, independent filesystem-level scan of the extracted tree
   (regular files and directories only, no `nlink > 1`) as defense in
   depth — the Python check in step 4 is the primary, authoritative gate;
   this is a belt-and-suspenders second layer, not a replacement for it.
9. Run the required workload validator against the restored payload path.
10. Only after the validator exits `0` is `.restore-control` removed and
    the Recovery Target declared viable.

## Recovery Target ownership and failure handling

- `RECOVERY_TARGET`'s root is mode `0700`; `.restore-control` inside it is
  mode `0600`.
- "Ownership" of a claimed target is proven by **both** its device+inode
  identity **and** the random control token matching what this invocation
  recorded — never by path alone.
- Destructive cleanup (removing a target this invocation claimed) is only
  ever performed when that proof matches. Any mismatch means the script
  **refuses to delete**, leaves the target exactly as found, and reports
  the path for manual review instead.
- A validator failure removes the target this invocation created — but
  only through that same ownership-proof check, never an unconditional
  `rm -rf`.

**Interrupted-target residual.** An untrappable interruption between
claiming a target and declaring it viable can leave `RECOVERY_TARGET` on
disk with `.restore-control` still present. This is disclosed, not hidden:
a later restore attempt to that exact same path fails closed immediately
(`mkdir` sees the path already exists) rather than silently overwriting or
resuming it. Recovering from this is a manual, cautious operator step, not
an automated one:

1. Confirm the exact path really is the leftover interrupted target you
   intend to deal with, not a live path or something else entirely.
2. Inspect `RECOVERY_TARGET/.restore-control` and the partial
   `RECOVERY_TARGET/payload/` contents before touching anything.
3. Confirm the path is not, and does not overlap, any live data.
4. Only once satisfied it is genuinely an abandoned, interrupted attempt,
   remove it manually and retry the restore against a clean path.

Do not reflexively `rm -rf` a target that fails to claim — treat "already
exists" as a signal to inspect first, not an instruction to clear a path.

## Workload validator contract

Restore **always** requires a validator argv after `--`; there is no
default and no way to skip it.

- For `dir`-kind restores, the validator receives the restored source-root
  directory (i.e. the equivalent of the original `BACKUP_SOURCE_DIR`) as
  its final argument.
- For `db`-kind restores, the validator receives the restored `dump.bin`
  path as its final argument.
- Exit `0` means the workload accepts the restored data as viable; any
  non-zero exit fails the restore, and the Recovery Target is not declared
  viable (see [ownership-gated cleanup](#recovery-target-ownership-and-failure-handling)
  above).

What the **generic** mechanism proves on its own — checksum integrity,
archive structure, layout, and manifest/payload consistency, all via
`tar_metadata_check.py` — is deliberately not the same thing as what the
**workload validator** proves. The generic layer can tell you the bytes are
exactly what was published and structurally well-formed; it cannot tell you
whether a directory tree satisfies an application's invariants, or whether
a database dump is actually loadable. That is exactly what the required
validator argv is for.

The synthetic database smoke validator used in this repository's own tests
does a byte-exact comparison against a known fixture — it proves the
generic transport mechanism reproduces a producer's output exactly. It does
**not** prove, and must never be represented as proving, `pg_dump`/
`pg_restore` compatibility or any other real database engine's logical
restore semantics. A future adopting workload must supply its own
semantically meaningful validator.

## Permissions

| Path | Mode |
|---|---|
| Backup destination (operator-provisioned) | `0700` |
| Published archive | `0600` |
| Published checksum sidecar | `0600` |
| Recovery Target root | `0700` |
| `.restore-control` | `0600` |

Extraction runs under `umask 0077` with GNU tar's `--no-same-owner
--no-same-permissions` — restored files get predictable, owner-only
permissions. This mechanism does **not** claim to faithfully preserve a
source tree's original, arbitrary permission bits.

## Retention and destination capacity

**There is no automatic pruning, rotation, or delete-old-backups behavior
of any kind in this mechanism.** Every successful backup remains at its
destination until an operator removes it. Two backups with distinct
timestamps were verified to coexist correctly, with the earlier pair
completely unchanged after the later one was published — see
[Smoke verification evidence](#smoke-verification-evidence).

**The operator is responsible for monitoring backup-destination capacity
and for any retention/rotation policy.** Nothing here will warn about, or
prevent, a destination filling up.

## Verified failure paths

Exercised directly against the real scripts (not simulated): missing or
wrong-mode destination; source/destination or live-data/destination overlap
in both directions; unsupported filesystem entry types in the source
(symlink, FIFO, hardlink); dump-producer failure (including after partial
output) and zero-byte producer output; malformed or path-like
`BACKUP_TIMESTAMP`; archive and checksum path collisions, and an exact
backup-id+timestamp repeat; a staged archive that fails the full
pre-publication contract check; a malformed or corrupted archive/sidecar on
restore, including a checksum-format mismatch and a sidecar whose filename
field doesn't match the archive; hand-crafted archives containing unsafe
tar paths or member types (absolute paths, `..`, symlinks, hardlinks,
FIFOs, duplicate/aliased members); manifest/payload count and digest
mismatches; an already-existing Recovery Target (file, directory, symlink,
dangling symlink); restoring directly onto a live path that was already
deleted; workload validator failure; Recovery Target ownership-proof
mismatch (token and device/inode); an interrupted Recovery Target from a
prior run; and `SIGINT`/`SIGTERM` signal behavior on both scripts. The
exhaustive, executable coverage lives in the four test scripts referenced
in [Tests](#tests) — this list is a summary, not a substitute for reading
them.

## Smoke verification evidence

- Four independent test suites, `177` passing cases total, `0` failures.
- No `sudo` anywhere in any test.
- Every fixture — dummy directory trees, synthetic dump producers, workload
  validators, and hand-crafted malicious archives — lives under `mktemp`
  scratch directories created and torn down by the tests themselves.
- No real project or application data was used anywhere.
- No Kubernetes, no HCP Terraform, no host configuration mutation.
- No real PostgreSQL (or any other real database engine) was installed or
  run — see the explicit scope note in
  [Workload validator contract](#workload-validator-contract).
- No backup artifact from any test run persists anywhere; every scratch
  root is removed via a trap when its test process exits.
- One continuous, 13-step end-to-end scenario matching issue #9's
  acceptance verification steps was exercised successfully — see
  [Verification status](#verification-status).

This is smoke/dummy-data verification of the generic mechanism, not
production validation of any real workload's backup/restore behavior.

## Operator verification commands

All paths below are placeholders — substitute your own.

Inspect what a backup published:

```sh
ls -la /absolute/path/to/backup-destination
stat -c '%a %n' /absolute/path/to/backup-destination/*.tar.gz*
```

Independently confirm an archive's integrity and structure the same way the
scripts themselves do:

```sh
python3 backup/tar_metadata_check.py \
  /absolute/path/to/backup-destination/example-workload-20260101T000000Z.tar.gz \
  example-workload-20260101T000000Z
```

A quick manual digest sanity-check (for a human glancing at a file, not a
substitute for the above):

```sh
sha256sum /absolute/path/to/backup-destination/example-workload-20260101T000000Z.tar.gz
cat /absolute/path/to/backup-destination/example-workload-20260101T000000Z.tar.gz.sha256
```

Compare the two digests by eye. Note that `restore.sh` itself does **not**
use `sha256sum -c` against the sidecar as-is — the sidecar's filename field
is never trusted to select what gets hashed. `restore.sh` parses the
sidecar strictly (exactly one line, exact filename match) and then computes
the digest independently over the explicit archive path itself. A manual
`sha256sum -c` is a reasonable quick human check, but it is not what the
production restore path relies on.

Run the test suites:

```sh
bash backup/lib.test.sh
bash backup/tar_metadata_check.test.sh
bash backup/backup.test.sh
bash backup/restore.test.sh
```

## Rollback / removal

This issue added only repo-local tooling and documentation — no host
service, systemd unit, or cluster resource was created, so there is nothing
running to roll back. Removing `backup/*` and this runbook removes the
platform feature entirely; nothing else in the platform depends on it.

**Any backup archives an operator has actually published are that
operator's data, not this feature's installation artifacts.** Removing this
tooling must never be taken as an instruction to delete real backup
archives — they are not created or managed by "the feature" in the sense
that rolling it back would imply removing them. All smoke-test artifacts
produced while verifying this mechanism lived under `mktemp` and were
already removed by the tests' own teardown; there is nothing left over from
verification to clean up.

## Tests

```sh
bash backup/lib.test.sh
bash backup/tar_metadata_check.test.sh
bash backup/backup.test.sh
bash backup/restore.test.sh
```

Plain bash (plus a small Python stdlib fixture builder for
`tar_metadata_check.test.sh`), no test framework dependency, no root/`sudo`
required. Every test suite creates its own `mktemp` scratch root and tears
it down via a trap. `backup.test.sh` and `restore.test.sh` run the real
`backup.sh`/`restore.sh` executables end to end, including two PATH-shadowed
tool wrappers used only inside the test environment (never a production
code change) to deterministically prove the checksum-then-archive signal
race window and the restore snapshot TOCTOU protection under real timing,
not just by inspecting the source.

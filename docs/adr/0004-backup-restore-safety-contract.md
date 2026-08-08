# Backup and restore safety contract

The Backup Mechanism must be safe to run against real Project data even though this
milestone only exercises it against smoke-test data, so we adopted a full safety
contract up front rather than the minimal "timestamped archive + checksum" issue #9
originally named. The contract, generalized from the equivalent mechanism in the
`AldrionDev/local-jenkins-platform` repository (inspected read-only via `gh` on
2026-08-08; **not** a runtime or repository dependency of this Platform — the
convention is captured here in full so nothing here or in implementation ever needs to
consult that repository again):

- an archive is written to a temporary path and atomically renamed into its final name
  only after creation succeeds;
- the archive must pass integrity validation, and any available workload-specific
  content validation, before it is considered valid;
- the SHA-256 sidecar (`<backup-id>-<timestamp>.tar.gz.sha256`) is generated only
  after validation passes;
- publication refuses to overwrite an already-existing final archive path or an
  already-existing checksum sidecar path — a Backup ID/timestamp collision is an
  error, not a silent overwrite;
- the backup destination directory is `0700`; archive and checksum files are `0600`;
- restore never writes into the live production source/target directly — it always
  targets a separate, explicitly named Recovery Target, and refuses to overwrite an
  existing one;
- restored data must pass a workload-appropriate validation (the concrete check is
  workload-specific — e.g. starting a service against it, or a database import check —
  not a single universal mechanism) before the Recovery Target counts as a viable
  recovery;
- no automatic pruning or retention in this milestone — operators are responsible for
  destination capacity, and this must be called out explicitly in the runbook;
- there is no built-in default backup destination — it must always be explicitly
  configured by the caller, since a bare-metal Host has no dev-repo-relative directory
  that's a safe universal default the way it might be for a single-machine Compose
  project.

Rejected alternative: implementing only the two items issue #9 originally named
(timestamped archive, SHA-256 checksum) and leaving the rest to implementation
discretion. Rejected because the safety-critical parts of the contract (atomic write,
restore-into-separate-target, refuse-to-overwrite) are exactly the parts most likely to
be skipped under time pressure, and skipping them is what turns a backup mechanism into
a data-loss risk during its own use.

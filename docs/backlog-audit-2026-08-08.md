# Backlog audit — 2026-08-08

Produced under issue #16. Read-only with respect to GitHub issues: this document
records findings and proposed corrections; no issue listed below was created,
edited, closed, relabeled, or reordered while producing it.

**Audited against**: `CONTEXT.md` and `docs/adr/0001`–`0004` as of commit
`4862a5d3cb34e8bbb6d362da951cdabd4a89d7db` on branch
`chore/16-platform-spec-backlog-audit`.

**Audited issues**: #5, #6, #7, #8, #9, #10 (all `OPEN`, milestone "Home Lab Platform
Bootstrap"), as of 2026-08-08. Issues #1–#4 are `CLOSED` and are treated as
already-implemented Platform state, not as audit subjects.

## Current platform state

Per `CLAUDE.md`, implemented and verified: single-node k3s (`k3s/install.sh`), the
local Docker registry (`registry/docker-compose.yml`), and k3s registry trust
(`/etc/rancher/k3s/registries.yaml`). This audit does not re-verify or restate their
runtime status beyond what `CLAUDE.md` already claims — see that file for the exact
verified/not-verified boundary, which is more granular than "done".

## Spec coverage by issue

| Issue | Spec area | Coverage |
|---|---|---|
| #5 (dnsmasq) | Bootstrap ordering, LAN DNS | Fully covered by existing AC; no gap found. |
| #6 (Terraform HCP workspace) | Platform Terraform Workspace, Local execution mode | Fully covered. Workspace name `homelab-platform` matches ADR-0002 exactly — not a defect. |
| #7 (Namespace Pattern) | Namespace Pattern | Fully covered. AC already correctly excludes backup scheduling (matches ADR-0004's boundary decision) and any specific Project. |
| #8 (namespace placeholder) | Project onboarding instance | Fully covered; correctly scoped to namespace + ResourceQuota only, no app resources. |
| #9 (backup mechanism) | Backup Mechanism | **Gap — see below.** |
| #10 (runbook) | Bootstrap, Registry Repository convention, Terraform Workspace convention, DR | Partially covered — see below. |

## Findings

### 1. Issue #9 acceptance criteria are narrower than the canonical backup safety contract (ADR-0004) — gap

Issue #9's current acceptance criteria require only: a generic mechanism, a
configurable destination separate from live data, Postgres-dump/data-directory
support, a timestamped archive with a SHA-256 checksum consistent with
`local-jenkins-platform`'s conventions, and a tested restore procedure.

ADR-0004 (adopted in this spec session, after inspecting `local-jenkins-platform`
directly rather than relying on issue #9's informal cross-reference) is more specific
and includes several requirements issue #9 does not currently state:

- atomic write (temp path, rename only after validation passes);
- archive/workload-specific content validation before checksum generation;
- `0700` destination directory, `0600` archive and checksum files;
- restore must target a separate, explicitly named Recovery Target and refuse to
  overwrite an existing one (issue #9 only requires restore to work, not this
  specific safety shape);
- no default backup destination permitted (issue #9 allows "configurable" without
  ruling out a built-in default);
- explicit no-automatic-retention statement and an operator-facing capacity warning
  in the runbook.

**Recommendation**: expand issue #9's acceptance criteria to reference ADR-0004
explicitly, rather than the current informal "consistent with `local-jenkins-platform`"
phrasing — which is not independently checkable by a reviewer without repository
access to `local-jenkins-platform`, whereas ADR-0004 is self-contained in this
repository. Not applied to the issue as part of this audit.

### 2. Issue #10 has no source for the Registry Repository and Platform/Project Terraform Workspace conventions until now — resolved, not a defect

Issue #10 requires the runbook to document "the registry naming convention" and "the
HCP Terraform workspace naming convention" for onboarding, but no prior issue defined
either. This audit resolved both as ADR-0003 and ADR-0002/`CONTEXT.md` respectively.
No backlog change is needed — issue #10 can now cite these documents directly. Noted
here only so it's traceable why the convention did not previously exist in the
backlog.

### 3. No issue owns the milestone-level Definition of Done beyond the sum of #5–#10

This spec session's milestone-level DoD requires: all of #5–#10 individually done,
`CONTEXT.md`/docs matching implemented state, and the runbook (#10) providing one
coherent, ordered, verifiable bootstrap path establishing the platform as a usable
Project substrate. Issue #10's existing acceptance criteria already effectively cover
the "coherent ordered path" and "onboarding steps" requirements, so no new issue is
needed — but no issue explicitly states this milestone-level bar as an acceptance
criterion in its own right. Documented here as the canonical milestone DoD; not
proposed as a new backlog item, since #10 already carries the substance of it.

### 4. No duplication, overlapping scope, or dependency/ordering problems found

Dependency chain (#5→#1, #6→#2, #7→#6, #8→#7, #9→loosely #2, #10→#2‑#9) is internally
consistent and matches the Bootstrap order (k3s → DNS → registry → Terraform) recorded
in `CONTEXT.md`. No two issues claim the same deliverable.

### 5. No contradictions found between issue text and repository documentation

Specifically checked and cleared: #6's workspace name vs. #10's onboarding convention
(resolved by ADR-0002, not a contradiction); #7/#8's Terraform pattern scope vs. #9's
backup CronJob mention (resolved by ADR-0004's boundary decision — they are
independent artifacts by design, not a scope conflict).

## Summary

One real acceptance-criteria gap (#9, backup safety contract). No duplication, no
ordering problems, no unresolved contradictions. Two issues (#6, #10) initially looked
like possible naming inconsistencies but resolved cleanly once ADR-0002/0003 existed —
recorded above for traceability, not as defects requiring correction.

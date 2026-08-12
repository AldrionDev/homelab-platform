#!/usr/bin/env bash
#
# Repo-local validation for the Platform Terraform root module.
#
# This is NOT an offline check: `terraform init -backend=false` may contact the
# public Terraform provider registry. What it does guarantee is that it never
# contacts HCP Terraform and never touches the k3s cluster — no backend is
# initialised and no plan is run.
#
# It has two parts:
#   1. formatting, provider installation and configuration validation, run
#      against an isolated, scratch TF_DATA_DIR — never the live
#      terraform/platform/.terraform/ — so this check has no dependency on,
#      and makes no change to, whatever state that directory happens to be in;
#   2. a leak gate that refuses machine-specific paths, Terraform state,
#      local tfvars, Terraform CLI credentials and real credential material.
#
# The leak gate is content-based, never keyword-based, so this script and the
# runbook can mention the credential key names as documentation and still be
# scanned by the gate itself without false positives.
#
# The candidate file set is enumerated exactly once into a validated,
# NUL-separated snapshot. Enumeration failure — no git, not a work tree, the
# `git ls-files` invocation itself failing, or an empty result — is a hard
# failure: this script must never report "All repo-local checks passed" on top
# of a leak gate that silently scanned nothing.
#
# See docs/terraform-runbook.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
readonly REPO_ROOT
readonly MODULE_DIR="$SCRIPT_DIR"
readonly TERRAFORM_ROOT="${REPO_ROOT}/terraform"
readonly LOCKFILE="${MODULE_DIR}/.terraform.lock.hcl"

# Populated by check_candidate_enumeration; every leak check reads this
# snapshot instead of invoking `git ls-files` again.
CANDIDATE_SNAPSHOT=""

# Populated by check_init_and_validate: an isolated, scratch Terraform data
# directory, used instead of the live terraform/platform/.terraform/.
TF_VALIDATE_DATA_DIR=""

# Single EXIT trap covering every piece of temporary state this script creates.
cleanup_temp_state() {
  [[ -n "$CANDIDATE_SNAPSHOT" && -f "$CANDIDATE_SNAPSHOT" ]] && rm -f "$CANDIDATE_SNAPSHOT"
  [[ -n "$TF_VALIDATE_DATA_DIR" && -d "$TF_VALIDATE_DATA_DIR" ]] && rm -rf "$TF_VALIDATE_DATA_DIR"
}
trap cleanup_temp_state EXIT

die() {
  echo "FAIL: $*" >&2
  exit 1
}

ok() { echo "PASS: $*"; }

has_command() { command -v "$1" >/dev/null 2>&1; }

# Returns 0 on match, 1 on no match. Any other grep exit status is fatal rather
# than being silently read as "clean" — a pattern the shell mis-parses must not
# turn into a passing check. `-e` is required because a PEM pattern starts with
# a dash and would otherwise be taken for an option.
file_matches() {
  local pattern="$1" file="$2" status=0
  LC_ALL=C grep -aqE -e "$pattern" -- "$file" || status=$?
  case "$status" in
    0) return 0 ;;
    1) return 1 ;;
    *) die "grep exited ${status} while scanning ${file}" ;;
  esac
}

# --- detection patterns -------------------------------------------------------

# A kubeconfig credential key only counts when it carries an actual value:
# the key name alone is documentation, a key name followed by base64 payload is
# a leaked credential.
readonly KUBECONFIG_CREDENTIAL_PATTERN='(client-key-data|client-certificate-data|certificate-authority-data)[[:space:]]*:[[:space:]]*[A-Za-z0-9+/]{32,}={0,2}'

# The complete PEM header must never appear verbatim in this file, otherwise the
# gate would flag its own source. Assembling it from two fragments keeps the
# scanner able to scan itself.
readonly PEM_OPEN='-----BEGIN'
readonly PEM_PATTERN="${PEM_OPEN} (CERTIFICATE|[A-Z ]*PRIVATE KEY)-----"

# Same self-matching problem, solved with bracketed letters: the source below
# does not literally contain any of the three paths it looks for.
readonly ABSOLUTE_USER_PATH_PATTERN='/h[o]me/|/U[s]ers/|/r[o]ot/'

# Files that must never be tracked or left untracked-but-committable. Evaluated
# as a bash [[ =~ ]] pattern against the path string only (never file content),
# so there is no external-command failure mode to guard against here.
#
# - *.tfvars (other than *.tfvars.example, filtered separately by name)
# - *.tfstate / *.tfstate.*
# - a file literally named "kubeconfig", or ending in ".kubeconfig", or
#   anything under a ".kube/" directory — not a broad "kubeconfig" prefix,
#   which would also flag an innocent "kubeconfig-notes.md"
# - .terraform/ working directories
# - *.tfplan
# - the Terraform CLI's HCP credential file, and its containing directory
readonly FORBIDDEN_PATH_PATTERN='(^|/)[^/]*\.tfvars$|\.tfstate($|\.)|(^|/)kubeconfig$|\.kubeconfig$|(^|/)\.kube/|(^|/)\.terraform/|\.tfplan$|(^|/)credentials\.tfrc\.json$|(^|/)\.terraform\.d/'

# --- candidate set enumeration -------------------------------------------------

# Enumerates tracked, staged and untracked-but-not-ignored files EXACTLY ONCE
# into a validated, NUL-separated snapshot file. --exclude-standard keeps
# gitignored local material (a real terraform.tfvars, .terraform/, state
# files, kubeconfig copies, credentials.tfrc.json) out of the candidate set,
# so the gate never reads it.
#
# Fails closed: missing git, a repo root that is not a git work tree, the
# `git ls-files` invocation itself failing, or an empty result are all hard
# failures. A leak gate that silently scanned zero files must never be allowed
# to report success.
check_candidate_enumeration() {
  has_command git || die "git is required for the leak gate."

  git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "${REPO_ROOT} is not a git work tree; the leak gate cannot enumerate candidates."

  CANDIDATE_SNAPSHOT="$(mktemp "${TMPDIR:-/tmp}/homelab-tf-validate-candidates.XXXXXX")"

  if ! git -C "$REPO_ROOT" ls-files --cached --others --exclude-standard -z \
        > "$CANDIDATE_SNAPSHOT"; then
    die "git ls-files failed while enumerating candidate files."
  fi

  [[ -s "$CANDIDATE_SNAPSHOT" ]] \
    || die "candidate file set is empty; refusing to report a passing leak gate."

  local count
  count=$(tr -cd '\0' < "$CANDIDATE_SNAPSHOT" | wc -c)
  ok "candidate set enumerated into a validated snapshot (${count} files)"
}

# All leak checks read the validated snapshot rather than invoking git again.
candidate_files() {
  [[ -n "$CANDIDATE_SNAPSHOT" && -f "$CANDIDATE_SNAPSHOT" ]] \
    || die "internal error: candidate snapshot not initialised before use"
  cat "$CANDIDATE_SNAPSHOT"
}

# --- terraform checks ---------------------------------------------------------

check_terraform_available() {
  has_command terraform || die "terraform is required but was not found in PATH."
  ok "terraform found: $(terraform version | head -1)"
}

# Runs from the repository's terraform/ root, not just terraform/platform/, so
# a future terraform/modules/ tree (issue #7) is covered by the same check.
check_fmt() {
  terraform -chdir="$TERRAFORM_ROOT" fmt -check -recursive \
    || die "terraform fmt -check failed; run 'terraform -chdir=${TERRAFORM_ROOT} fmt -recursive'"
  ok "terraform fmt -check (repo-wide terraform/ tree)"
}

# -backend=false deliberately skips HCP Terraform initialisation. Providers are
# still installed, which is what makes `terraform validate` meaningful.
#
# Runs against an isolated, scratch TF_DATA_DIR (via mktemp -d), never the live
# terraform/platform/.terraform/. An operator may legitimately have already run
# a real HCP-backed `terraform init` in that directory; once they have,
# `.terraform/` there caches that the backend is `cloud`, and a bare
# `init -backend=false` against it fails demanding TF_CLOUD_ORGANIZATION to
# reconcile that cached pointer — even though no backend re-initialisation was
# requested. Pointing both `init` and `validate` at a fresh, empty TF_DATA_DIR
# for the duration of this one check sidesteps that entirely: there is no
# cached backend state to reconcile, so this check has no dependency on, and
# makes no change to, whatever state the live .terraform/ happens to be in.
#
# TF_DATA_DIR is set only as a command prefix on the two Terraform invocations
# below, not exported for the rest of the script — every other check keeps
# using the process's ambient environment.
check_init_and_validate() {
  TF_VALIDATE_DATA_DIR="$(mktemp -d "${TMPDIR:-/tmp}/homelab-tf-validate-data.XXXXXX")"

  TF_DATA_DIR="$TF_VALIDATE_DATA_DIR" \
    terraform -chdir="$MODULE_DIR" init -backend=false -input=false >/dev/null \
    || die "terraform init -backend=false failed"
  ok "terraform init -backend=false (isolated TF_DATA_DIR, no HCP backend initialised, live .terraform/ untouched)"

  TF_DATA_DIR="$TF_VALIDATE_DATA_DIR" \
    terraform -chdir="$MODULE_DIR" validate \
    || die "terraform validate failed"
  ok "terraform validate"
}

# --- leak gate ----------------------------------------------------------------

# Path-only check: matched against the candidate path string, never file
# content, using bash's native regex engine — no external command, so there is
# no grep-exit-code failure mode to misread as "clean" here.
check_no_forbidden_paths() {
  local offenders="" file
  while IFS= read -r -d '' file; do
    [[ "$file" =~ $FORBIDDEN_PATH_PATTERN ]] && offenders+="${file}"$'\n'
  done < <(candidate_files)
  [[ -z "$offenders" ]] \
    || die "state / tfvars / kubeconfig / plan / CLI-credential files must never be committed:"$'\n'"$offenders"
  ok "no state, tfvars, kubeconfig, plan or CLI-credential files in the candidate set"
}

check_no_credential_material() {
  local offenders="" file
  while IFS= read -r -d '' file; do
    [[ -f "${REPO_ROOT}/${file}" ]] || continue
    if file_matches "$PEM_PATTERN" "${REPO_ROOT}/${file}" \
      || file_matches "$KUBECONFIG_CREDENTIAL_PATTERN" "${REPO_ROOT}/${file}"; then
      offenders+="${file}"$'\n'
    fi
  done < <(candidate_files)
  [[ -z "$offenders" ]] \
    || die "embedded certificate, private key or kubeconfig credential detected in:"$'\n'"$offenders"
  ok "no embedded certificates, private keys or kubeconfig credentials"
}

check_no_machine_specific_paths() {
  local offenders="" file
  while IFS= read -r -d '' file; do
    [[ "$file" == terraform/* ]] || continue
    [[ -f "${REPO_ROOT}/${file}" ]] || continue
    if file_matches "$ABSOLUTE_USER_PATH_PATTERN" "${REPO_ROOT}/${file}"; then
      offenders+="${file}"$'\n'
    fi
  done < <(candidate_files)
  [[ -z "$offenders" ]] \
    || die "machine-specific absolute path under terraform/ in:"$'\n'"$offenders"
  ok "no machine-specific absolute paths under terraform/"
}

check_no_hcp_organization() {
  local offenders="" file
  while IFS= read -r -d '' file; do
    [[ "$file" == *.tf ]] || continue
    [[ -f "${REPO_ROOT}/${file}" ]] || continue
    if file_matches '^[[:space:]]*organization[[:space:]]*=' "${REPO_ROOT}/${file}"; then
      offenders+="${file}"$'\n'
    fi
  done < <(candidate_files)
  [[ -z "$offenders" ]] \
    || die "the HCP organization is account-specific and must come from TF_CLOUD_ORGANIZATION, not:"$'\n'"$offenders"
  ok "no HCP organization assignment in committed Terraform files"
}

# The lockfile must exist and must be committable. Whether it is actually staged
# is proven separately by the pre-commit gate in docs/terraform-runbook.md, not
# here: during implementation it is legitimately still untracked.
#
# git check-ignore exit codes: 0 = ignored, 1 = not ignored, anything else is a
# validation-infrastructure error and must not be read as either answer.
check_lockfile() {
  [[ -f "$LOCKFILE" ]] || die "expected ${LOCKFILE} to exist after init"

  local status=0
  git -C "$REPO_ROOT" check-ignore -q "$LOCKFILE" || status=$?
  case "$status" in
    0) die ".terraform.lock.hcl is gitignored; it must be committed (see docs/terraform-runbook.md)" ;;
    1) ok ".terraform.lock.hcl exists and is not ignored" ;;
    *) die "git check-ignore exited ${status} while checking ${LOCKFILE}" ;;
  esac
}

# --- entrypoint ---------------------------------------------------------------

main() {
  echo "Repo-local Terraform validation (no HCP Terraform, no cluster)"
  echo "-------------------------------------------------------------"
  check_terraform_available
  check_fmt
  check_init_and_validate
  check_lockfile
  check_candidate_enumeration
  check_no_forbidden_paths
  check_no_credential_material
  check_no_machine_specific_paths
  check_no_hcp_organization
  echo
  echo "All repo-local checks passed."
}

if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
  main "$@"
fi

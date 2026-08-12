#!/usr/bin/env bash
#
# Repo-local, throwaway `terraform plan` verification for the
# namespace-resourcequota module (the Namespace Pattern).
#
# Precise contract — read this before trusting what this script proves:
#   - repo-local verification only;
#   - no HCP Terraform backend or state is ever configured;
#   - no real k3s kubeconfig or API endpoint is ever used — the kubeconfig
#     this script writes carries no real cluster credentials and names no
#     real cluster;
#   - terraform apply is never run;
#   - terraform init may still contact the public Terraform provider registry
#     to download the kubernetes provider plugin — this is NOT an offline
#     check in that sense.
#
# What this script does NOT prove: that the kubernetes provider can reach a
# real Kubernetes API server, or that `terraform apply` would succeed against
# one. That evidence is issue #8's job, not this script's. A one-time
# empirical observation (this provider version did not need to reach a real
# API server to plan two brand-new resources) motivated this script's design,
# but that observation is not relied upon as a safety property here: safety
# comes from never configuring a real backend, real credentials, or running
# apply — not from an assumption about provider connectivity behavior that
# could change in a future provider release.
#
# See docs/terraform-runbook.md for the full procedure and rationale.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

WORK_DIR=""
cleanup() {
  [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]] && rm -rf "$WORK_DIR"
}
trap cleanup EXIT

die() {
  echo "FAIL: $*" >&2
  exit 1
}

ok() { echo "PASS: $*"; }

has_command() { command -v "$1" >/dev/null 2>&1; }

# terraform and jq are both hard prerequisites. A missing prerequisite must
# never be silently skipped or treated as a soft pass.
check_prerequisites() {
  has_command terraform || die "terraform is required but was not found in PATH."
  has_command jq || die "jq is required but was not found in PATH."
  ok "terraform and jq found"
}

readonly THROWAWAY_PROJECT_NAME="throwaway-test-project"
readonly THROWAWAY_CPU_REQUEST="500m"
readonly THROWAWAY_CPU_LIMIT="1"
readonly THROWAWAY_MEMORY_REQUEST="512Mi"
readonly THROWAWAY_MEMORY_LIMIT="1Gi"

# A syntactically valid kubeconfig with no real credentials and no real
# cluster endpoint. Whatever connectivity behavior the provider version in
# use exhibits at plan time, this file cannot authenticate to, or name, any
# real cluster.
write_synthetic_kubeconfig() {
  cat >"${WORK_DIR}/fake-kubeconfig.yaml" <<'EOF'
apiVersion: v1
kind: Config
clusters:
- name: throwaway
  cluster:
    server: https://192.0.2.1:6443
    insecure-skip-tls-verify: true
contexts:
- name: throwaway
  context:
    cluster: throwaway
    user: throwaway
current-context: throwaway
users:
- name: throwaway
  user:
    token: throwaway-non-functional-token
EOF
  ok "synthetic kubeconfig written (no real cluster credentials, no real endpoint)"
}

# No backend/cloud block anywhere in this wrapper — no HCP Terraform state is
# ever touched by this script.
write_wrapper_root() {
  cat >"${WORK_DIR}/main.tf" <<EOF
terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.2"
    }
  }
}

provider "kubernetes" {
  config_path = "${WORK_DIR}/fake-kubeconfig.yaml"
}

module "throwaway" {
  source = "${SCRIPT_DIR}"

  project_name   = "${THROWAWAY_PROJECT_NAME}"
  cpu_request    = "${THROWAWAY_CPU_REQUEST}"
  cpu_limit      = "${THROWAWAY_CPU_LIMIT}"
  memory_request = "${THROWAWAY_MEMORY_REQUEST}"
  memory_limit   = "${THROWAWAY_MEMORY_LIMIT}"
}
EOF
  ok "wrapper root configuration written (no backend/cloud block, synthetic provider config)"
}

run_plan() {
  local data_dir="${WORK_DIR}/.terraform-data"

  TF_DATA_DIR="$data_dir" terraform -chdir="$WORK_DIR" init -backend=false -input=false >/dev/null \
    || die "terraform init -backend=false failed"
  ok "terraform init -backend=false (no HCP backend initialised)"

  TF_DATA_DIR="$data_dir" terraform -chdir="$WORK_DIR" plan -input=false -out="${WORK_DIR}/plan.tfplan" >/dev/null \
    || die "terraform plan failed"
  ok "terraform plan (no apply)"

  TF_DATA_DIR="$data_dir" terraform -chdir="$WORK_DIR" show -json "${WORK_DIR}/plan.tfplan" >"${WORK_DIR}/plan.json" \
    || die "terraform show -json failed"
}

# Asserts the plan JSON via jq, never via text-matching on human-readable
# plan output. Fails closed on any mismatch: missing field, extra/missing
# resource, wrong action, or wrong value.
assert_plan_json() {
  local plan_json="${WORK_DIR}/plan.json"

  local count
  count="$(jq '.resource_changes | length' "$plan_json")"
  [[ "$count" -eq 2 ]] || die "expected exactly 2 resource_changes, found ${count}"
  ok "exactly 2 resource_changes"

  local non_create
  non_create="$(jq '[.resource_changes[] | select(.change.actions != ["create"])] | length' "$plan_json")"
  [[ "$non_create" -eq 0 ]] \
    || die "found a resource_change whose actions are not exactly [\"create\"] (update/delete/replace/no-op present)"
  ok "both resource_changes have actions exactly [\"create\"]"

  local addresses expected_addresses
  addresses="$(jq -r '.resource_changes[].address' "$plan_json" | sort)"
  expected_addresses="$(printf '%s\n' \
    "module.throwaway.kubernetes_namespace_v1.this" \
    "module.throwaway.kubernetes_resource_quota_v1.this" | sort)"
  [[ "$addresses" == "$expected_addresses" ]] \
    || die "resource addresses did not match exactly. Got:"$'\n'"${addresses}"
  ok "resource addresses are exactly the expected Namespace and ResourceQuota"

  local ns_name
  ns_name="$(jq -r '.resource_changes[] | select(.address=="module.throwaway.kubernetes_namespace_v1.this") | .change.after.metadata[0].name' "$plan_json")"
  [[ "$ns_name" == "$THROWAWAY_PROJECT_NAME" ]] \
    || die "Namespace planned name '${ns_name}' does not equal the throwaway project name '${THROWAWAY_PROJECT_NAME}'"
  ok "Namespace planned name equals the throwaway project name"

  local rq_name
  rq_name="$(jq -r '.resource_changes[] | select(.address=="module.throwaway.kubernetes_resource_quota_v1.this") | .change.after.metadata[0].name' "$plan_json")"
  [[ "$rq_name" == "${THROWAWAY_PROJECT_NAME}-quota" ]] \
    || die "ResourceQuota planned name '${rq_name}' does not equal '${THROWAWAY_PROJECT_NAME}-quota'"
  ok "ResourceQuota planned name equals '<throwaway-project>-quota'"

  local rq_namespace
  rq_namespace="$(jq -r '.resource_changes[] | select(.address=="module.throwaway.kubernetes_resource_quota_v1.this") | .change.after.metadata[0].namespace' "$plan_json")"
  [[ "$rq_namespace" == "$THROWAWAY_PROJECT_NAME" ]] \
    || die "ResourceQuota planned namespace '${rq_namespace}' does not equal the throwaway project name '${THROWAWAY_PROJECT_NAME}'"
  ok "ResourceQuota planned namespace equals the throwaway project name"

  local hard_json expected_hard_json
  hard_json="$(jq -Sc '.resource_changes[] | select(.address=="module.throwaway.kubernetes_resource_quota_v1.this") | .change.after.spec[0].hard' "$plan_json")"
  expected_hard_json="$(jq -nSc \
    --arg cpu_request "$THROWAWAY_CPU_REQUEST" \
    --arg cpu_limit "$THROWAWAY_CPU_LIMIT" \
    --arg memory_request "$THROWAWAY_MEMORY_REQUEST" \
    --arg memory_limit "$THROWAWAY_MEMORY_LIMIT" \
    '{"requests.cpu": $cpu_request, "requests.memory": $memory_request, "limits.cpu": $cpu_limit, "limits.memory": $memory_limit}')"
  [[ "$hard_json" == "$expected_hard_json" ]] \
    || die "ResourceQuota spec.hard did not match exactly. Got: ${hard_json}, expected: ${expected_hard_json}"
  ok "ResourceQuota spec.hard contains exactly the four expected keys and values"
}

main() {
  echo "Repo-local throwaway plan verification for namespace-resourcequota"
  echo "-------------------------------------------------------------------"
  check_prerequisites

  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/homelab-tf-module-plan.XXXXXX")"

  write_synthetic_kubeconfig
  write_wrapper_root
  run_plan
  assert_plan_json

  echo
  echo "PASS: throwaway plan shows exactly the expected Namespace + ResourceQuota create. Nothing applied, nothing committed, no real cluster or HCP backend contacted."
}

if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
  main "$@"
fi

#!/usr/bin/env bash
#
# Tests for k3s/registry-pull-test.sh.
#
# Plain bash, no test framework dependency. Run with:
#   bash k3s/registry-pull-test.test.sh
#
# Every case runs in a fresh `bash -c` that sources the script under test, so
# its own `set -euo pipefail` is active exactly as in production. Collaborators
# are replaced with bash function shadows inside those subshells.
#
# No case requires Docker, a registry, a Kubernetes cluster, root, sudo, k3s,
# network access, or any dependency the script itself does not already need.
#
# Addresses used as fixtures are RFC 5737 documentation space (192.0.2.0/24)
# or obviously malformed, never a real host's address — the same convention
# .env.example follows. Nothing machine-specific belongs in this repository.
# This suite covers the script's decision and safety logic only — it is not a
# substitute for the real runtime proof, which is two live runs of
# registry-pull-test.sh on either side of a k3s restart.
#
# shellcheck disable=SC2016
# Test bodies are single-quoted on purpose: they must reach the case subshell
# unexpanded, and are evaluated there against the sourced script's functions.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_UNDER_TEST="$SCRIPT_DIR/registry-pull-test.sh"

PASSED=0
FAILED=0
FAILED_NAMES=()

# Every mktemp in this suite — in the runner, in the case subshells, and in the
# sourced script — honours TMPDIR, so pointing it at one run-owned directory
# confines all scratch to a single place. Cleanup then removes exactly that
# directory and nothing else: never a /tmp glob, which would sweep up files
# belonging to unrelated runs and processes.
TEST_TMPDIR="$(mktemp -d)"
export TMPDIR="$TEST_TMPDIR"

cleanup_test_tmpdir() {
  local rc="$?"
  trap - EXIT INT TERM
  if [[ -n "$TEST_TMPDIR" && -d "$TEST_TMPDIR" ]]; then
    # A case deliberately chmod 000s a file; make the tree removable again
    # rather than leaving it behind or reaching for anything broader.
    chmod -R u+rwX "$TEST_TMPDIR" 2>/dev/null || true
    if ! rm -rf -- "$TEST_TMPDIR"; then
      echo "WARNING: failed to remove the test scratch directory $TEST_TMPDIR" >&2
    fi
  fi
  exit "$rc"
}

trap cleanup_test_tmpdir EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Helpers injected into every case. Note: $1 inside a case body is the path to
# the script under test (see run_case), so case bodies must not use positional
# parameters.
read -r -d '' PRELUDE <<'PRELUDE_EOF' || true
assert_eq() {
  [[ "$1" == "$2" ]] || { echo "assert_eq failed: expected [$2], got [$1]"; exit 90; }
}
assert_contains() {
  [[ "$1" == *"$2"* ]] || { echo "assert_contains failed: [$2] not found in [$1]"; exit 90; }
}
assert_not_contains() {
  [[ "$1" != *"$2"* ]] || { echo "assert_not_contains failed: [$2] unexpectedly found in [$1]"; exit 90; }
}
assert_ok() {
  "$@" || { echo "assert_ok failed: $*"; exit 90; }
}
assert_not_ok() {
  if "$@"; then echo "assert_not_ok failed (unexpected success): $*"; exit 90; fi
}
# expect_die <expected message substring> <command...>
expect_die() {
  local expected="$1"; shift
  local out rc=0
  out=$("$@" 2>&1) || rc=$?
  ((rc == 1)) || { echo "expect_die: expected exit 1, got $rc (output: $out)"; exit 90; }
  [[ "$out" == *"$expected"* ]] || { echo "expect_die: [$expected] not found in [$out]"; exit 90; }
}

# A tab-separated node record as fetch_node_records emits them.
mk_node_record() {
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4"
}
mk_healthy_node() {
  mk_node_record "homelab" "v1.36.2+k3s1" "containerd://2.1.4-k3s1" "True"
}

# Records every shadowed command invocation, one per line, into $CALL_LOG.
CALL_LOG=""
init_call_log() { CALL_LOG="$(mktemp)"; }
log_call() { printf '%s\n' "$*" >>"$CALL_LOG"; }
calls() { cat "$CALL_LOG" 2>/dev/null || true; }
PRELUDE_EOF

# run_case <name> <bash code>
run_case() {
  local name="$1" code="$2"
  local out rc=0
  out=$(bash -c "source \"\$1\"
$PRELUDE
$code" "k3s-registry-pull-test" "$SCRIPT_UNDER_TEST" 2>&1) || rc=$?
  if ((rc == 0)); then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
    FAILED_NAMES+=("$name")
    echo "FAIL: $name"
    # shellcheck disable=SC2001  # per-line prefix; sed is clearer than a loop
    echo "$out" | sed 's/^/      /'
  fi
}

echo "== HOST_LAN_IP validation =="

run_case "validate_env: unset HOST_LAN_IP fails before anything else" '
  unset HOST_LAN_IP
  expect_die "HOST_LAN_IP is required" validate_env
'

run_case "validate_env: empty HOST_LAN_IP fails" '
  HOST_LAN_IP=""
  expect_die "HOST_LAN_IP is required" validate_env
'

run_case "validate_env: valid LAN address passes silently" '
  HOST_LAN_IP="192.0.2.10"
  out=$(validate_env 2>&1)
  assert_eq "$out" ""
'

for good in "192.0.2.10" "10.0.0.1" "172.16.31.42" "255.255.255.255"; do
  run_case "validate_ipv4 accepts $good" "
    validate_ipv4 '$good'
  "
done

for bad in "999.999.999.999" "256.1.1.1" "192.168.1" "192.168.1.1.1" "homelab.local" "" "192.168.01.1" "192..1.1" "192.168.1.-5" "1.2.3.4a" "192.168.1.1000"; do
  run_case "validate_ipv4 rejects '$bad'" "
    expect_die 'HOST_LAN_IP' validate_ipv4 '$bad'
  "
done

for loopback in "127.0.0.1" "127.1.2.3"; do
  run_case "validate_ipv4 rejects loopback $loopback" "
    expect_die 'loopback' validate_ipv4 '$loopback'
  "
done

run_case "SECURITY: validate_ipv4 rejects an embedded newline" '
  # `read` stops at the first newline, so a first-line-valid value would
  # otherwise pass while the untruncated value still reached docker and kubectl.
  probe=$(printf "192.0.2.10\nrm -rf /")
  expect_die "not a dotted-quad" validate_ipv4 "$probe"
'

run_case "SECURITY: validate_ipv4 rejects a multi-line address list" '
  probe=$(printf "192.0.2.10\n172.17.0.1\n10.42.0.1")
  expect_die "not a dotted-quad" validate_ipv4 "$probe"
'

echo "== KUBECONFIG preflight =="

run_case "validate_kubeconfig: unset is rejected (no ambient context)" '
  unset KUBECONFIG
  expect_die "KUBECONFIG is required" validate_kubeconfig
'

run_case "validate_kubeconfig: empty is rejected" '
  KUBECONFIG=""
  expect_die "KUBECONFIG is required" validate_kubeconfig
'

run_case "validate_kubeconfig: missing file is rejected" '
  KUBECONFIG="$(mktemp -u)"
  expect_die "does not exist" validate_kubeconfig
'

run_case "validate_kubeconfig: a directory is rejected" '
  KUBECONFIG="$(mktemp -d)"
  expect_die "not a regular file" validate_kubeconfig
'

run_case "validate_kubeconfig: unreadable file is rejected" '
  KUBECONFIG="$(mktemp)"
  chmod 000 "$KUBECONFIG"
  if [[ -r "$KUBECONFIG" ]]; then
    # Running as root (or with CAP_DAC_OVERRIDE): mode 000 is still readable,
    # so this case cannot be exercised deterministically here.
    echo "SKIP: cannot make a file unreadable as this user"
    exit 0
  fi
  expect_die "not readable" validate_kubeconfig
'

run_case "validate_kubeconfig: a readable regular file passes silently" '
  KUBECONFIG="$(mktemp)"
  out=$(validate_kubeconfig 2>&1)
  assert_eq "$out" ""
'

run_case "run_kubectl always passes --kubeconfig explicitly" '
  init_call_log
  KUBECONFIG="/tmp/explicit-kubeconfig"
  kubectl() { log_call "kubectl $*"; }
  run_kubectl get pods -n default
  assert_eq "$(calls)" "kubectl --kubeconfig /tmp/explicit-kubeconfig get pods -n default"
'

run_case "run_kubectl puts --kubeconfig before the subcommand" '
  init_call_log
  KUBECONFIG="/tmp/kc"
  kubectl() { log_call "$1 $2"; }
  run_kubectl get nodes
  assert_eq "$(calls)" "--kubeconfig /tmp/kc"
'

echo "== cluster identity =="

run_case "assert_single_k3s_node accepts one Ready k3s containerd node" '
  out=$(assert_single_k3s_node "$(mk_healthy_node)")
  assert_contains "$out" "single-node k3s"
  assert_contains "$out" "homelab"
'

run_case "assert_single_k3s_node rejects an empty record set" '
  expect_die "no node records" assert_single_k3s_node ""
'

run_case "assert_single_k3s_node rejects whitespace-only output" '
  expect_die "no node records" assert_single_k3s_node "$(printf "\n \n")"
'

run_case "assert_single_k3s_node rejects a multi-node cluster" '
  records=$(mk_healthy_node; mk_node_record "worker" "v1.36.2+k3s1" "containerd://2.1.4-k3s1" "True")
  expect_die "expected exactly 1 node, found 2" assert_single_k3s_node "$records"
'

run_case "assert_single_k3s_node rejects a NotReady node" '
  records=$(mk_node_record "homelab" "v1.36.2+k3s1" "containerd://2.1.4-k3s1" "False")
  expect_die "is not Ready" assert_single_k3s_node "$records"
'

run_case "assert_single_k3s_node rejects a missing Ready condition" '
  records=$(mk_node_record "homelab" "v1.36.2+k3s1" "containerd://2.1.4-k3s1" "")
  expect_die "is not Ready" assert_single_k3s_node "$records"
'

run_case "assert_single_k3s_node rejects a non-k3s cluster (minikube shape)" '
  records=$(mk_node_record "minikube" "v1.30.0" "docker://24.0.7" "True")
  expect_die "not a k3s build" assert_single_k3s_node "$records"
'

run_case "assert_single_k3s_node rejects a k3s node with a non-containerd runtime" '
  records=$(mk_node_record "homelab" "v1.36.2+k3s1" "docker://24.0.7" "True")
  expect_die "expected a containerd:// runtime" assert_single_k3s_node "$records"
'

run_case "assert_single_k3s_node reports each failed check distinctly" '
  notready=$( (assert_single_k3s_node "$(mk_node_record homelab v1.36.2+k3s1 containerd://2.1.4 False)") 2>&1 ) || true
  nonk3s=$(   (assert_single_k3s_node "$(mk_node_record minikube v1.30.0 containerd://1.7.0 True)")     2>&1 ) || true
  assert_not_contains "$notready" "not a k3s build"
  assert_not_contains "$nonk3s" "is not Ready"
'

run_case "check_cluster_identity dies when the API is unreachable" '
  fetch_node_records() { return 1; }
  KUBECONFIG="/tmp/kc"
  expect_die "could not reach the Kubernetes API" check_cluster_identity
'

echo "== local-node identity (route-derived) =="

# `ip -4 route get` output shapes, as fixtures. The second line is the routing
# cache entry the kernel appends; it carries no src field.
mk_route() { printf '1.1.1.1 via 192.0.2.1 dev wlan0 src %s uid 1000\n    cache\n' "$1"; }
mk_route_no_src() { printf '1.1.1.1 via 192.0.2.1 dev wlan0 uid 1000\n    cache\n'; }

run_case "route source equal to the node InternalIP passes" '
  mk_route() { printf "1.1.1.1 via 192.0.2.1 dev wlan0 src %s uid 1000\n    cache\n" "$1"; }
  out=$(assert_node_is_this_hosts_node "192.0.2.10" "$(mk_route 192.0.2.10)")
  assert_contains "$out" "192.0.2.10"
  assert_contains "$out" "default-route source address"
'

run_case "node InternalIP differing from the route source fails closed" '
  mk_route() { printf "1.1.1.1 via 192.0.2.1 dev wlan0 src %s uid 1000\n    cache\n" "$1"; }
  expect_die "NOT this host" assert_node_is_this_hosts_node "198.51.100.7" "$(mk_route 192.0.2.10)"
'

run_case "SECURITY: a foreign node advertising a common bridge address fails" '
  # The exact hole the previous host-address-set model left open: 172.17.0.1
  # (docker0) exists on countless machines, so a foreign k3s node claiming it
  # used to pass. Pinning to the route source closes that.
  mk_route() { printf "1.1.1.1 via 192.0.2.1 dev wlan0 src %s uid 1000\n    cache\n" "$1"; }
  expect_die "NOT this host" assert_node_is_this_hosts_node "172.17.0.1" "$(mk_route 192.0.2.10)"
'

run_case "SECURITY: a foreign node advertising a CNI address fails too" '
  mk_route() { printf "1.1.1.1 via 192.0.2.1 dev wlan0 src %s uid 1000\n    cache\n" "$1"; }
  expect_die "NOT this host" assert_node_is_this_hosts_node "10.42.0.1" "$(mk_route 192.0.2.10)"
'

run_case "the mismatch diagnostic prints both addresses" '
  mk_route() { printf "1.1.1.1 via 192.0.2.1 dev wlan0 src %s uid 1000\n    cache\n" "$1"; }
  out=$( (assert_node_is_this_hosts_node "172.17.0.1" "$(mk_route 192.0.2.10)") 2>&1 ) || true
  assert_contains "$out" "Node InternalIP: 172.17.0.1"
  assert_contains "$out" "default-route source address): 192.0.2.10"
'

run_case "the mismatch diagnostic prints no address inventory" '
  mk_route() { printf "1.1.1.1 via 192.0.2.1 dev wlan0 src %s uid 1000\n    cache\n" "$1"; }
  out=$( (assert_node_is_this_hosts_node "172.17.0.1" "$(mk_route 192.0.2.10)") 2>&1 ) || true
  assert_not_contains "$out" "10.42"
  assert_not_contains "$out" "wlan0"
'

run_case "a missing route src field fails closed" '
  route=$(printf "1.1.1.1 via 192.0.2.1 dev wlan0 uid 1000\n    cache\n")
  expect_die "lookup returned no " assert_node_is_this_hosts_node "192.0.2.10" "$route"
'

run_case "empty route output fails closed" '
  expect_die "lookup returned no " assert_node_is_this_hosts_node "192.0.2.10" ""
'

for bad_src in "not-an-ip" "192.0.2" "192.0.2.999" "192.0.2.010"; do
  # Asserting on the malformed-value wording specifically: the generic
  # mismatch message also mentions the route source, so a looser substring
  # would still pass with the validation removed.
  run_case "a malformed route src '$bad_src' fails closed" "
    route=\$(printf '1.1.1.1 via 192.0.2.1 dev wlan0 src %s uid 1000\n    cache\n' '$bad_src')
    rc=0
    out=\$( (assert_node_is_this_hosts_node '192.0.2.10' \"\$route\") 2>&1 ) || rc=\$?
    assert_eq \"\$rc\" '1'
    assert_contains \"\$out\" 'route source address'
    assert_contains \"\$out\" 'is not a dotted-quad IPv4 address'
  "
done

run_case "ambiguous multiple route src values fail closed" '
  route=$(printf "1.1.1.1 via 192.0.2.1 dev wlan0 src 192.0.2.10 uid 1000\n1.1.1.1 via 10.0.0.1 dev eth1 src 10.0.0.5 uid 1000\n")
  expect_die "ambiguous" assert_node_is_this_hosts_node "192.0.2.10" "$route"
'

run_case "a loopback route source fails closed" '
  mk_route() { printf "1.1.1.1 via 192.0.2.1 dev lo src %s uid 1000\n    cache\n" "$1"; }
  expect_die "is loopback" assert_node_is_this_hosts_node "127.0.0.1" "$(mk_route 127.0.0.1)"
'

run_case "a missing node InternalIP fails closed" '
  mk_route() { printf "1.1.1.1 via 192.0.2.1 dev wlan0 src %s uid 1000\n    cache\n" "$1"; }
  expect_die "reports no InternalIP" assert_node_is_this_hosts_node "" "$(mk_route 192.0.2.10)"
'

run_case "multiple node InternalIPs fail closed" '
  mk_route() { printf "1.1.1.1 via 192.0.2.1 dev wlan0 src %s uid 1000\n    cache\n" "$1"; }
  ips=$(printf "192.0.2.10\n192.0.2.11\n")
  expect_die "refusing to guess which one identifies it" assert_node_is_this_hosts_node "$ips" "$(mk_route 192.0.2.10)"
'

for bad_node in "not-an-ip" "192.0.2" "192.0.2.999" "192.0.2.010"; do
  # Same reasoning: the mismatch message also prints "Node InternalIP", so the
  # assertion has to name the malformed-value branch explicitly.
  run_case "a malformed node InternalIP '$bad_node' fails closed" "
    route=\$(printf '1.1.1.1 via 192.0.2.1 dev wlan0 src 192.0.2.10 uid 1000\n    cache\n')
    rc=0
    out=\$( (assert_node_is_this_hosts_node '$bad_node' \"\$route\") 2>&1 ) || rc=\$?
    assert_eq \"\$rc\" '1'
    assert_contains \"\$out\" 'InternalIP'
    assert_contains \"\$out\" 'is not a dotted-quad IPv4 address'
  "
done

run_case "route-source parsing ignores an unrelated trailing token named src" '
  # Only a token immediately following the literal "src" counts.
  route=$(printf "1.1.1.1 via 192.0.2.1 dev wlan0 src 192.0.2.10 uid 1000 srcfoo bar\n    cache\n")
  out=$(assert_node_is_this_hosts_node "192.0.2.10" "$route")
  assert_contains "$out" "192.0.2.10"
'

run_case "extract_route_source_ipv4 emits one line per src field" '
  route=$(printf "a src 1.2.3.4 b\nc src 5.6.7.8 d\n")
  assert_eq "$(extract_route_source_ipv4 "$route")" "$(printf "1.2.3.4\n5.6.7.8")"
'

run_case "extract_route_source_ipv4 emits nothing when there is no src" '
  assert_eq "$(extract_route_source_ipv4 "1.1.1.1 dev wlan0 uid 1000")" ""
'

run_case "extract_route_source_ipv4 ignores a trailing bare src token" '
  assert_eq "$(extract_route_source_ipv4 "1.1.1.1 dev wlan0 src")" ""
'

run_case "check_cluster_identity propagates a route lookup failure" '
  KUBECONFIG="/tmp/kc"
  fetch_node_records() { mk_healthy_node; }
  fetch_node_internal_ips() { echo "192.0.2.10"; }
  fetch_host_route_source() { return 1; }
  expect_die "default-route lookup failed" check_cluster_identity
'

run_case "check_cluster_identity dies when the InternalIP cannot be read" '
  KUBECONFIG="/tmp/kc"
  fetch_node_records() { mk_healthy_node; }
  fetch_node_internal_ips() { return 1; }
  expect_die "could not read the node" check_cluster_identity
'

run_case "check_cluster_identity wires both assertions together on the happy path" '
  KUBECONFIG="/tmp/kc"
  fetch_node_records() { mk_healthy_node; }
  fetch_node_internal_ips() { echo "192.0.2.10"; }
  fetch_host_route_source() { printf "1.1.1.1 via 192.0.2.1 dev wlan0 src 192.0.2.10 uid 1000\n    cache\n"; }
  out=$(check_cluster_identity)
  assert_contains "$out" "single-node k3s"
  assert_contains "$out" "default-route source address"
'

run_case "fetch_host_route_source performs a route lookup, never a connection" '
  init_call_log
  ip() { log_call "ip $*"; }
  fetch_host_route_source
  assert_eq "$(calls)" "ip -4 route get 1.1.1.1"
'

run_case "the foreign-cluster diagnostic stays distinct from version/Ready ones" '
  mk_route() { printf "1.1.1.1 via 192.0.2.1 dev wlan0 src %s uid 1000\n    cache\n" "$1"; }
  foreign=$( (assert_node_is_this_hosts_node "198.51.100.7" "$(mk_route 192.0.2.10)") 2>&1 ) || true
  notready=$( (assert_single_k3s_node "$(mk_node_record homelab v1.36.2+k3s1 containerd://2.1.4 False)") 2>&1 ) || true
  nonk3s=$( (assert_single_k3s_node "$(mk_node_record minikube v1.30.0 docker://24.0.7 True)") 2>&1 ) || true
  assert_contains "$foreign" "valid single-node k3s/containerd cluster"
  assert_not_contains "$foreign" "is not Ready"
  assert_not_contains "$foreign" "not a k3s build"
  assert_not_contains "$notready" "managed local k3s node"
  assert_not_contains "$nonk3s" "managed local k3s node"
'

run_case "validate_dependencies requires ip" '
  has_command() { [[ "$1" != "ip" ]]; }
  expect_die "missing required command" validate_dependencies
'

echo "== IPv4 predicates =="

for good in "192.0.2.10" "10.0.0.1" "0.0.0.0" "255.255.255.255" "127.0.0.1"; do
  run_case "is_valid_ipv4 accepts $good" "assert_ok is_valid_ipv4 '$good'"
done
for bad in "" "192.0.2" "192.0.2.10.5" "192.0.2.256" "192.0.2.010" "1.2.3.4a" "not-an-ip" "-1.2.3.4"; do
  run_case "is_valid_ipv4 rejects '$bad'" "assert_not_ok is_valid_ipv4 '$bad'"
done
run_case "is_valid_ipv4 rejects an embedded newline" '
  probe=$(printf "192.0.2.10\n198.51.100.7")
  assert_not_ok is_valid_ipv4 "$probe"
'
run_case "is_loopback_ipv4 identifies the whole 127/8 range" '
  assert_ok is_loopback_ipv4 "127.0.0.1"
  assert_ok is_loopback_ipv4 "127.1.2.3"
  assert_not_ok is_loopback_ipv4 "192.0.2.10"
'

echo "== run identity =="

run_case "generate_run_id is lowercase and RFC 1123 safe" '
  id=$(generate_run_id)
  [[ "$id" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] \
    || { echo "run id is not a legal RFC 1123 name: [$id]"; exit 90; }
  assert_eq "$id" "${id,,}"
'

run_case "generate_run_id varies between calls" '
  a=$(generate_run_id)
  b=$(generate_run_id)
  [[ "$a" != "$b" ]] || { echo "two run ids collided: [$a]"; exit 90; }
'

run_case "prepare_unique_run derives tag, image ref and Pod name from one id" '
  REGISTRY_HOST="192.0.2.10:5000"
  head_manifest() { echo "404"; }
  prepare_unique_run >/dev/null
  assert_eq "$TAG" "$RUN_ID"
  assert_eq "$IMAGE_REF" "192.0.2.10:5000/homelab-k3s-pull-test:$RUN_ID"
  assert_eq "$POD_NAME" "homelab-k3s-pull-test-$RUN_ID"
'

run_case "prepare_unique_run produces an RFC 1123 compliant Pod name" '
  REGISTRY_HOST="192.0.2.10:5000"
  head_manifest() { echo "404"; }
  prepare_unique_run >/dev/null
  [[ "$POD_NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] \
    || { echo "pod name is not a legal RFC 1123 name: [$POD_NAME]"; exit 90; }
  ((${#POD_NAME} <= 253)) || { echo "pod name too long: ${#POD_NAME}"; exit 90; }
'

run_case "prepare_unique_run regenerates every derived value on a tag collision" '
  REGISTRY_HOST="192.0.2.10:5000"
  # A file-backed counter, not a variable: head_manifest is called inside a
  # command substitution, so a shell variable it assigns dies with the subshell.
  COUNTER=$(mktemp)
  head_manifest() {
    printf "x" >>"$COUNTER"
    if (($(wc -c <"$COUNTER") == 1)); then echo "200"; else echo "404"; fi
  }
  prepare_unique_run >/dev/null
  # The surviving identity must be internally consistent, not a mix of the
  # colliding first attempt and the second one.
  assert_eq "$TAG" "$RUN_ID"
  assert_eq "$IMAGE_REF" "192.0.2.10:5000/homelab-k3s-pull-test:$RUN_ID"
  assert_eq "$POD_NAME" "homelab-k3s-pull-test-$RUN_ID"
'

run_case "prepare_unique_run gives up after a persistent collision" '
  REGISTRY_HOST="192.0.2.10:5000"
  head_manifest() { echo "200"; }
  expect_die "without touching the registry" prepare_unique_run
'

run_case "prepare_unique_run dies on an unexpected registry status" '
  REGISTRY_HOST="192.0.2.10:5000"
  head_manifest() { echo "500"; }
  expect_die "unexpected HTTP status 500" prepare_unique_run
'

echo "== push digest parser =="

run_case "parse_push_digest accepts a single reported digest" '
  PUSH_OUTPUT=$(mktemp)
  printf "latest: digest: sha256:%064d size: 527\n" 1 >"$PUSH_OUTPUT"
  parse_push_digest
  assert_eq "$PUSH_DIGEST" "sha256:$(printf "%064d" 1)"
'

run_case "parse_push_digest accepts the same digest repeated" '
  PUSH_OUTPUT=$(mktemp)
  d="sha256:$(printf "%064d" 2)"
  printf "a: digest: %s size: 1\nb: digest: %s size: 1\n" "$d" "$d" >"$PUSH_OUTPUT"
  parse_push_digest
  assert_eq "$PUSH_DIGEST" "$d"
'

run_case "parse_push_digest dies when no digest was reported" '
  PUSH_OUTPUT=$(mktemp)
  printf "The push refers to repository [x]\nnothing useful here\n" >"$PUSH_OUTPUT"
  expect_die "reported no digest" parse_push_digest
'

run_case "parse_push_digest never falls back to a tag lookup" '
  PUSH_OUTPUT=$(mktemp)
  : >"$PUSH_OUTPUT"
  out=$( (parse_push_digest) 2>&1 ) || true
  assert_contains "$out" "refusing to fall back to a tag lookup"
'

run_case "parse_push_digest dies on conflicting digests" '
  PUSH_OUTPUT=$(mktemp)
  printf "a: digest: sha256:%064d size: 1\nb: digest: sha256:%064d size: 1\n" 3 4 >"$PUSH_OUTPUT"
  expect_die "conflicting digests" parse_push_digest
'

run_case "parse_push_digest ignores a malformed digest-shaped line" '
  PUSH_OUTPUT=$(mktemp)
  # 63 hex digits, and an uppercase variant: neither is a valid digest, and
  # neither may be silently accepted as an artifact owned by this run.
  printf "a: digest: sha256:%063d size: 1\nb: digest: SHA256:%064d size: 1\n" 5 6 >"$PUSH_OUTPUT"
  expect_die "reported no digest" parse_push_digest
'

echo "== registry HTTP helpers =="

run_case "head_manifest returns the HTTP status curl reports" '
  REGISTRY_HOST="192.0.2.10:5000"
  HEADERS_FILE=$(mktemp)
  curl() { echo "200"; }
  assert_eq "$(head_manifest sometag)" "200"
'

run_case "head_manifest dies on a curl transport failure" '
  REGISTRY_HOST="192.0.2.10:5000"
  HEADERS_FILE=$(mktemp)
  curl() { return 7; }
  expect_die "HEAD request for" head_manifest sometag
'

run_case "read_digest_from_headers is case-insensitive about the header name" '
  HEADERS_FILE=$(mktemp)
  printf "HTTP/1.1 200 OK\r\nDocker-Content-Digest: sha256:%064d\r\n" 7 >"$HEADERS_FILE"
  assert_eq "$(read_digest_from_headers)" "sha256:$(printf "%064d" 7)"
'

run_case "read_digest_from_headers dies when the header is absent" '
  HEADERS_FILE=$(mktemp)
  printf "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" >"$HEADERS_FILE"
  expect_die "no Docker-Content-Digest header" read_digest_from_headers
'

run_case "read_digest_from_headers dies on a malformed digest" '
  HEADERS_FILE=$(mktemp)
  printf "docker-content-digest: sha256:nothex\r\n" >"$HEADERS_FILE"
  expect_die "malformed digest" read_digest_from_headers
'

run_case "delete_manifest_digest treats only 202 as success" '
  REGISTRY_HOST="192.0.2.10:5000"
  curl() { echo "202"; }
  delete_manifest_digest "sha256:$(printf "%064d" 8)"
  assert_eq "$REMOTE_DELETE_ATTEMPTED" "true"
  assert_eq "$REMOTE_DELETED" "true"
'

for status in 404 401 405 500 200; do
  run_case "delete_manifest_digest reports HTTP $status as a failure" "
    REGISTRY_HOST='192.0.2.10:5000'
    curl() { echo '$status'; }
    rc=0
    delete_manifest_digest \"sha256:\$(printf '%064d' 9)\" 2>/dev/null || rc=\$?
    assert_eq \"\$rc\" '1'
    assert_eq \"\$REMOTE_DELETE_ATTEMPTED\" 'true'
    assert_eq \"\$REMOTE_DELETED\" 'false'
  "
done

run_case "delete_manifest_digest reports a transport failure as status 2" '
  REGISTRY_HOST="192.0.2.10:5000"
  curl() { return 7; }
  rc=0
  delete_manifest_digest "sha256:$(printf "%064d" 10)" || rc=$?
  assert_eq "$rc" "2"
  assert_eq "$REMOTE_DELETE_ATTEMPTED" "true"
  assert_eq "$REMOTE_DELETED" "false"
'

echo "== imageID digest parser =="

run_case "extract_image_digest accepts a bare digest" '
  d="sha256:$(printf "%064d" 11)"
  assert_eq "$(extract_image_digest "$d")" "$d"
'

run_case "extract_image_digest accepts the containerd:// form" '
  d="sha256:$(printf "%064d" 12)"
  assert_eq "$(extract_image_digest "containerd://$d")" "$d"
'

run_case "extract_image_digest accepts the docker-pullable:// repo@digest form" '
  d="sha256:$(printf "%064d" 13)"
  assert_eq "$(extract_image_digest "docker-pullable://192.0.2.10:5000/repo@$d")" "$d"
'

run_case "extract_image_digest accepts the bare repo@digest form" '
  d="sha256:$(printf "%064d" 14)"
  assert_eq "$(extract_image_digest "192.0.2.10:5000/homelab-k3s-pull-test@$d")" "$d"
'

for bad_desc in "empty::" "too-short:sha256:abc" "wrong-algo:md5:$(printf '%032d' 1)" "uppercase-hex:sha256:ABCDEF" "trailing-junk:sha256:0000000000000000000000000000000000000000000000000000000000000000x" "no-prefix:0000000000000000000000000000000000000000000000000000000000000000"; do
  desc="${bad_desc%%:*}"
  value="${bad_desc#*:}"
  run_case "extract_image_digest rejects $desc" "
    assert_not_ok extract_image_digest '$value'
  "
done

run_case "extract_image_digest rejects a 65-hex-digit value rather than truncating it" '
  assert_not_ok extract_image_digest "sha256:$(printf "%064d" 0)a"
'

echo "== Pod image verification =="

run_case "verify_pod_image accepts the manifest digest and says so" '
  PUSH_DIGEST="sha256:$(printf "%064d" 20)"
  OWN_CONFIG_DIGEST="sha256:$(printf "%064d" 21)"
  IMAGE_REF="192.0.2.10:5000/homelab-k3s-pull-test:tag"
  run_kubectl() { echo "containerd://$PUSH_DIGEST"; }
  out=$(verify_pod_image)
  assert_contains "$out" "Matched:                  PUSH_DIGEST"
  assert_not_contains "$out" "OWN_CONFIG_DIGEST (image config digest)"
'

run_case "verify_pod_image accepts the image config digest and says so" '
  PUSH_DIGEST="sha256:$(printf "%064d" 22)"
  OWN_CONFIG_DIGEST="sha256:$(printf "%064d" 23)"
  IMAGE_REF="192.0.2.10:5000/homelab-k3s-pull-test:tag"
  run_kubectl() { echo "containerd://$OWN_CONFIG_DIGEST"; }
  out=$(verify_pod_image)
  assert_contains "$out" "Matched:                  OWN_CONFIG_DIGEST"
'

run_case "verify_pod_image reports both when the two accepted digests coincide" '
  # What the containerd image store produces: docker inspect .Id is the
  # manifest digest, so the config and manifest identities are the same value.
  PUSH_DIGEST="sha256:$(printf "%064d" 24)"
  OWN_CONFIG_DIGEST="$PUSH_DIGEST"
  IMAGE_REF="192.0.2.10:5000/homelab-k3s-pull-test:tag"
  run_kubectl() { echo "$PUSH_DIGEST"; }
  out=$(verify_pod_image)
  assert_contains "$out" "Matched:                  both"
'

run_case "verify_pod_image prints the RAW imageID on success, not only on failure" '
  # Run A showed the raw value was observable only when the check failed, which
  # is exactly the run where the evidence is least useful.
  PUSH_DIGEST="sha256:$(printf "%064d" 25)"
  OWN_CONFIG_DIGEST="sha256:$(printf "%064d" 26)"
  IMAGE_REF="192.0.2.10:5000/homelab-k3s-pull-test:tag"
  RAW="docker-pullable://192.0.2.10:5000/homelab-k3s-pull-test@$PUSH_DIGEST"
  run_kubectl() { echo "$RAW"; }
  out=$(verify_pod_image)
  assert_contains "$out" "Resolved imageID (raw):   $RAW"
  assert_contains "$out" "Resolved digest:          $PUSH_DIGEST"
  assert_contains "$out" "Pod image reference:      $IMAGE_REF"
'

run_case "verify_pod_image success output names both expected digests" '
  PUSH_DIGEST="sha256:$(printf "%064d" 27)"
  OWN_CONFIG_DIGEST="sha256:$(printf "%064d" 28)"
  IMAGE_REF="192.0.2.10:5000/homelab-k3s-pull-test:tag"
  run_kubectl() { echo "$PUSH_DIGEST"; }
  out=$(verify_pod_image)
  assert_contains "$out" "Expected manifest digest: $PUSH_DIGEST"
  assert_contains "$out" "Expected config digest:   $OWN_CONFIG_DIGEST"
'

run_case "verify_pod_image success output goes to stdout, not stderr" '
  PUSH_DIGEST="sha256:$(printf "%064d" 29)"
  OWN_CONFIG_DIGEST="sha256:$(printf "%064d" 30)"
  IMAGE_REF="192.0.2.10:5000/homelab-k3s-pull-test:tag"
  run_kubectl() { echo "$PUSH_DIGEST"; }
  errout=$(verify_pod_image 2>&1 >/dev/null)
  assert_eq "$errout" ""
'

run_case "verify_pod_image fails closed on a foreign but well-formed digest" '
  PUSH_DIGEST="sha256:$(printf "%064d" 24)"
  OWN_CONFIG_DIGEST="sha256:$(printf "%064d" 25)"
  IMAGE_REF="192.0.2.10:5000/homelab-k3s-pull-test:tag"
  run_kubectl() { echo "containerd://sha256:$(printf "%064d" 26)"; }
  dump_pod_diagnostics() { :; }
  expect_die "does not resolve to either digest this run owns" verify_pod_image
'

run_case "verify_pod_image fails closed on an empty imageID" '
  PUSH_DIGEST="sha256:$(printf "%064d" 27)"
  OWN_CONFIG_DIGEST="sha256:$(printf "%064d" 28)"
  run_kubectl() { echo ""; }
  dump_pod_diagnostics() { :; }
  expect_die "did not yield exactly one well-formed sha256 digest" verify_pod_image
'

run_case "verify_pod_image fails closed on a malformed imageID" '
  PUSH_DIGEST="sha256:$(printf "%064d" 29)"
  OWN_CONFIG_DIGEST="sha256:$(printf "%064d" 30)"
  run_kubectl() { echo "containerd://sha256:not-a-digest"; }
  dump_pod_diagnostics() { :; }
  expect_die "did not yield exactly one well-formed sha256 digest" verify_pod_image
'

run_case "verify_pod_image mismatch diagnostics name both expected digests" '
  PUSH_DIGEST="sha256:$(printf "%064d" 31)"
  OWN_CONFIG_DIGEST="sha256:$(printf "%064d" 32)"
  IMAGE_REF="192.0.2.10:5000/homelab-k3s-pull-test:tag"
  run_kubectl() { echo "sha256:$(printf "%064d" 33)"; }
  dump_pod_diagnostics() { :; }
  rc=0
  out=$( (verify_pod_image) 2>&1 ) || rc=$?
  # The success output now carries the same field names, so asserting on the
  # text alone would pass even if the acceptance check were removed. Requiring
  # the non-zero exit is what keeps this case discriminating.
  assert_eq "$rc" "1"
  assert_contains "$out" "does not resolve to either digest this run owns"
  assert_contains "$out" "Expected manifest digest: $PUSH_DIGEST"
  assert_contains "$out" "Expected config digest:   $OWN_CONFIG_DIGEST"
  assert_contains "$out" "Resolved imageID (raw)"
'

echo "== Pod phase waiting =="

run_case "wait_for_pod_running accepts Running" '
  POD_NAME="p"
  pod_phase() { echo "Running"; }
  out=$(wait_for_pod_running)
  assert_contains "$out" "reached Running"
'

for terminal in Succeeded Failed; do
  run_case "wait_for_pod_running rejects the terminal phase $terminal" "
    POD_NAME='p'
    pod_phase() { echo '$terminal'; }
    dump_pod_diagnostics() { :; }
    expect_die \"terminal phase '$terminal' instead of Running\" wait_for_pod_running
  "
done

run_case "wait_for_pod_running keeps waiting through Pending, then passes" '
  POD_NAME="p"
  # File-backed: pod_phase runs in a command substitution, so a variable it
  # assigns would never survive back into the loop.
  COUNTER=$(mktemp)
  pod_phase() {
    printf "x" >>"$COUNTER"
    if (($(wc -c <"$COUNTER") < 3)); then echo "Pending"; else echo "Running"; fi
  }
  sleep() { :; }
  dump_pod_diagnostics() { :; }
  out=$(wait_for_pod_running)
  assert_contains "$out" "reached Running"
  # It really did wait rather than passing on the first look.
  (($(wc -c <"$COUNTER") >= 3)) || { echo "did not poll repeatedly"; exit 90; }
'

run_case "wait_for_pod_running times out and points at the registry trust" '
  POD_NAME="p"
  pod_phase() { echo "Pending"; }
  sleep() { :; }
  dump_pod_diagnostics() { :; }
  expect_die "did not reach Running within" wait_for_pod_running
'

echo "== cleanup ownership =="

run_case "cleanup deletes exactly this run's Pod, by name" '
  init_call_log
  KUBECONFIG="/tmp/kc"
  POD_CREATED=true
  POD_NAME="homelab-k3s-pull-test-abc123"
  run_kubectl() { log_call "kubectl $*"; }
  ( cleanup 0 ) >/dev/null 2>&1
  assert_contains "$(calls)" "delete pod homelab-k3s-pull-test-abc123"
  assert_contains "$(calls)" "--ignore-not-found"
'

run_case "cleanup never selects Pods by label or prefix" '
  init_call_log
  POD_CREATED=true
  POD_NAME="homelab-k3s-pull-test-abc123"
  run_kubectl() { log_call "kubectl $*"; }
  ( cleanup 0 ) >/dev/null 2>&1
  assert_not_contains "$(calls)" "--selector"
  assert_not_contains "$(calls)" "-l "
  assert_not_contains "$(calls)" "--all"
'

run_case "cleanup deletes no Pod when none was created" '
  init_call_log
  POD_CREATED=false
  POD_NAME="homelab-k3s-pull-test-abc123"
  run_kubectl() { log_call "kubectl $*"; }
  ( cleanup 0 ) >/dev/null 2>&1
  assert_not_contains "$(calls)" "delete pod"
'

run_case "cleanup deletes no Pod when the name was never assigned" '
  init_call_log
  POD_CREATED=true
  POD_NAME=""
  run_kubectl() { log_call "kubectl $*"; }
  ( cleanup 0 ) >/dev/null 2>&1
  assert_not_contains "$(calls)" "delete pod"
'

run_case "cleanup deletes no manifest when the push never succeeded" '
  init_call_log
  PUSH_ATTEMPTED=true
  PUSH_SUCCEEDED=false
  PUSH_DIGEST=""
  curl() { log_call "curl $*"; echo "202"; }
  ( cleanup 0 ) >/dev/null 2>&1
  assert_not_contains "$(calls)" "DELETE"
'

run_case "cleanup deletes this run's manifest by digest after a successful push" '
  init_call_log
  REGISTRY_HOST="192.0.2.10:5000"
  PUSH_ATTEMPTED=true
  PUSH_SUCCEEDED=true
  PUSH_DIGEST="sha256:$(printf "%064d" 40)"
  curl() { log_call "curl $*"; echo "202"; }
  ( cleanup 0 ) >/dev/null 2>&1
  assert_contains "$(calls)" "$PUSH_DIGEST"
  assert_contains "$(calls)" "DELETE"
'

run_case "cleanup does not resolve the tag when no digest was captured" '
  init_call_log
  REGISTRY_HOST="192.0.2.10:5000"
  PUSH_ATTEMPTED=true
  PUSH_SUCCEEDED=true
  PUSH_DIGEST=""
  TAG="sometag"
  curl() { log_call "curl $*"; echo "202"; }
  out=$( ( cleanup 0 ) 2>&1 )
  # A tag lookup here could hand this run a foreign manifest to delete.
  assert_not_contains "$(calls)" "DELETE"
  assert_contains "$out" "no digest was captured"
'

run_case "cleanup removes only this run's local image tag, not the base image" '
  init_call_log
  LOCAL_TAG_PRESENT=true
  IMAGE_REF="192.0.2.10:5000/homelab-k3s-pull-test:abc"
  docker() { log_call "docker $*"; }
  ( cleanup 0 ) >/dev/null 2>&1
  assert_contains "$(calls)" "docker image rm -f 192.0.2.10:5000/homelab-k3s-pull-test:abc"
  assert_not_contains "$(calls)" "busybox"
'

run_case "cleanup preserves the original exit code" '
  rc=0
  ( cleanup 42 ) >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "42"
'

run_case "cleanup preserves a signal exit code" '
  rc=0
  ( cleanup 130 ) >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "130"
'

run_case "cleanup with fully uninitialised state performs no deletion at all" '
  init_call_log
  run_kubectl() { log_call "kubectl $*"; }
  docker()      { log_call "docker $*"; }
  curl()        { log_call "curl $*"; }
  ( cleanup 0 ) >/dev/null 2>&1
  assert_eq "$(calls)" ""
'

echo "== static checks =="

# The script must not reach for host-level privilege or service control: those
# belong to the documented runbook transaction, behind their own approval.
for forbidden in "sudo" "systemctl" "registries.yaml"; do
  if grep -nE "^[^#]*\b${forbidden}\b" "$SCRIPT_UNDER_TEST" >/dev/null 2>&1; then
    FAILED=$((FAILED + 1))
    FAILED_NAMES+=("no '$forbidden' in executable code")
    echo "FAIL: registry-pull-test.sh must not use '$forbidden' outside comments"
    grep -nE "^[^#]*\b${forbidden}\b" "$SCRIPT_UNDER_TEST" | sed 's/^/      /'
  else
    PASSED=$((PASSED + 1))
  fi
done

if bash -n "$SCRIPT_UNDER_TEST"; then
  PASSED=$((PASSED + 1))
else
  FAILED=$((FAILED + 1)); FAILED_NAMES+=("bash -n registry-pull-test.sh"); echo "FAIL: bash -n registry-pull-test.sh"
fi

if bash -n "$SCRIPT_DIR/registry-pull-test.test.sh"; then
  PASSED=$((PASSED + 1))
else
  FAILED=$((FAILED + 1)); FAILED_NAMES+=("bash -n registry-pull-test.test.sh"); echo "FAIL: bash -n registry-pull-test.test.sh"
fi

if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck "$SCRIPT_UNDER_TEST"; then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1)); FAILED_NAMES+=("shellcheck registry-pull-test.sh"); echo "FAIL: shellcheck registry-pull-test.sh"
  fi
else
  echo "SKIP: shellcheck not installed (run it in a container — see docs/k3s-runbook.md)"
fi

echo
echo "passed: $PASSED  failed: $FAILED"
if ((FAILED > 0)); then
  printf 'failed cases:\n'
  printf '  - %s\n' "${FAILED_NAMES[@]}"
  exit 1
fi

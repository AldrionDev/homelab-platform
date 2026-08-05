#!/usr/bin/env bash
#
# Tests for k3s/install.sh.
#
# Plain bash, no test framework dependency. Run with:
#   bash k3s/install.test.sh
#
# Every case runs in a fresh `bash -c` that sources install.sh, so the script's
# own `set -euo pipefail` is active exactly as in production. Collaborators are
# replaced with bash function shadows inside those subshells; install.sh itself
# has no environment-variable seams. No case requires root, systemd, a real k3s
# unit, the real /etc/rancher filesystem, or network access.
#
# shellcheck disable=SC2016
# Test bodies are single-quoted on purpose: they must reach the case subshell
# unexpanded, and are evaluated there against the sourced script's functions.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_UNDER_TEST="$SCRIPT_DIR/install.sh"

PASSED=0
FAILED=0
FAILED_NAMES=()

# Helpers injected into every case. Note: $1 inside a case body is the path to
# install.sh (see run_case), so case bodies must not use positional parameters.
read -r -d '' PRELUDE <<'PRELUDE_EOF' || true
assert_eq() {
  [[ "$1" == "$2" ]] || { echo "assert_eq failed: expected [$2], got [$1]"; exit 90; }
}
assert_contains() {
  [[ "$1" == *"$2"* ]] || { echo "assert_contains failed: [$2] not found in [$1]"; exit 90; }
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

# Builds a systemd `systemctl show -p ExecStart --value` style record.
mk_execstart() {
  echo "{ path=/usr/local/bin/k3s ; argv[]=$1 ; ignore_errors=no ; start_time=[n/a] }"
}

# Creates an executable fake k3s that prints the given --version first line.
make_fake_k3s() {
  local dir
  dir=$(mktemp -d)
  printf '#!/bin/sh\necho "%s"\n' "$1" > "$dir/k3s"
  chmod +x "$dir/k3s"
  echo "$dir/k3s"
}

# Extracts one KEY=value field from an inspect_installation block.
inspect_field() {
  awk -F= -v k="$1" '$1==k{sub(/^[^=]*=/,""); print}' <<< "$2"
}

# Defaults for the systemctl shadow below; individual cases override them.
FAKE_UNIT="k3s-test-fake"
FAKE_LOADSTATE="loaded"
FAKE_ACTIVESTATE="active"
FAKE_EXECSTART=""
FAKE_ENABLED_RC=0

# Replaces the real systemctl for the fake unit only. Any query about a unit
# other than $FAKE_UNIT fails, so a real k3s unit on the host can never leak in.
systemctl() {
  case "$*" in
    "show $FAKE_UNIT --property=LoadState --value")   echo "$FAKE_LOADSTATE" ;;
    "show $FAKE_UNIT --property=ActiveState --value") echo "$FAKE_ACTIVESTATE" ;;
    "show $FAKE_UNIT --property=ExecStart --value")   echo "$FAKE_EXECSTART" ;;
    "is-enabled $FAKE_UNIT")                          return "$FAKE_ENABLED_RC" ;;
    *) return 1 ;;
  esac
}
PRELUDE_EOF

# run_case <name> <bash code>
run_case() {
  local name="$1" code="$2"
  local out rc=0
  out=$(bash -c "source \"\$1\"
$PRELUDE
$code" "k3s-install-test" "$SCRIPT_UNDER_TEST" 2>&1) || rc=$?
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

echo "== validate_env =="

run_case "validate_env: both unset fails and names both" '
  expect_die "K3S_VERSION" validate_env
  out=$( (validate_env) 2>&1 ) || true
  assert_contains "$out" "HOST_LAN_IP"
'

run_case "validate_env: only K3S_VERSION unset" '
  HOST_LAN_IP="192.168.1.50"
  out=$( (validate_env) 2>&1 ) || true
  assert_contains "$out" "K3S_VERSION"
  [[ "$out" == *"HOST_LAN_IP"* ]] && { echo "should not report HOST_LAN_IP"; exit 90; }
  true
'

run_case "validate_env: only HOST_LAN_IP unset" '
  K3S_VERSION="v1.30.3+k3s1"
  out=$( (validate_env) 2>&1 ) || true
  assert_contains "$out" "HOST_LAN_IP"
  [[ "$out" == *"K3S_VERSION"* ]] && { echo "should not report K3S_VERSION"; exit 90; }
  true
'

run_case "validate_env: both set succeeds silently" '
  K3S_VERSION="v1.30.3+k3s1"
  HOST_LAN_IP="192.168.1.50"
  out=$(validate_env 2>&1)
  assert_eq "$out" ""
'

echo "== version validation =="

for good in "v1.30.3+k3s1" "v1.28.15+k3s2" "v1.33.0+k3s10"; do
  run_case "is_well_formed_version accepts $good" "
    assert_ok is_well_formed_version '$good'
    validate_version '$good'
  "
done

for bad in "latest" "stable" "v1.33" "v1.30.3" "1.30.3+k3s1" "v1.30.3+k3s" "v1.30.3-k3s1" "" "v1.30.3+k3s1 " "vX.Y.Z+k3sN"; do
  run_case "is_well_formed_version rejects '$bad'" "
    assert_not_ok is_well_formed_version '$bad'
    expect_die 'not an exact k3s release tag' validate_version '$bad'
  "
done

echo "== IPv4 validation =="

for good in "192.168.1.50" "10.0.0.1" "0.0.0.0" "255.255.255.255"; do
  run_case "validate_ipv4 accepts $good" "
    validate_ipv4 '$good'
  "
done

for bad in "999.999.999.999" "256.1.1.1" "192.168.1" "192.168.1.1.1" "homelab.local" "" "192.168.01.1" "192..1.1" "192.168.1.-5" "1.2.3.4a" "192.168.1.1000"; do
  run_case "validate_ipv4 rejects '$bad'" "
    expect_die 'HOST_LAN_IP' validate_ipv4 '$bad'
  "
done

run_case "SECURITY: validate_ipv4 rejects an embedded newline" '
  # `read` stops at the first newline, so a first-line-valid value would
  # otherwise pass while the untruncated value reached the installer and the
  # generated systemd unit gained an injected directive.
  probe=$(printf "192.168.1.50\nrm -rf /")
  expect_die "not a dotted-quad" validate_ipv4 "$probe"
'

run_case "SECURITY: validate_ipv4 rejects a multi-homed multi-line address list" '
  # The realistic operator mistake: `ip -4 -o addr show | awk ... | cut ...`
  # on a host with several interfaces yields several lines.
  probe=$(printf "192.168.1.50\n172.17.0.1\n10.42.0.1")
  expect_die "not a dotted-quad" validate_ipv4 "$probe"
'

run_case "SECURITY: validate_ipv4 rejects a trailing newline plus payload" '
  probe=$(printf "192.168.1.50\nExecStartPost=/bin/sh -c evil")
  expect_die "not a dotted-quad" validate_ipv4 "$probe"
'

echo "== preflight (read-only) =="

run_case "is_root false for non-root uid" '
  id() { echo "1000"; }
  assert_not_ok is_root
'

run_case "is_root true for uid 0" '
  id() { echo "0"; }
  assert_ok is_root
'

run_case "check_prerequisites dies with root message when not root" '
  id() { echo "1000"; }
  expect_die "must be run as root" check_prerequisites
'

run_case "check_prerequisites dies when curl missing" '
  id() { echo "0"; }
  has_command() { [[ "$1" != "curl" ]]; }
  expect_die "curl is required" check_prerequisites
'

run_case "check_prerequisites dies when systemctl missing" '
  id() { echo "0"; }
  has_command() { [[ "$1" != "systemctl" ]]; }
  expect_die "systemctl is required" check_prerequisites
'

run_case "check_prerequisites dies when grep lacks PCRE support" '
  id() { echo "0"; }
  has_command() { return 0; }
  has_pcre_grep() { return 1; }
  expect_die "PCRE support" check_prerequisites
'

run_case "check_prerequisites dies when systemd not running" '
  id() { echo "0"; }
  has_command() { return 0; }
  has_pcre_grep() { return 0; }
  systemd_running() { return 1; }
  expect_die "systemd does not appear to be running" check_prerequisites
'

run_case "check_prerequisites passes when all satisfied" '
  id() { echo "0"; }
  has_command() { return 0; }
  has_pcre_grep() { return 0; }
  systemd_running() { return 0; }
  check_prerequisites
'

run_case "has_pcre_grep is true on this host (grep -P available)" '
  assert_ok has_pcre_grep
'

run_case "has_command true for bash, false for bogus binary" '
  assert_ok has_command bash
  assert_not_ok has_command definitely-not-a-real-binary-xyz
'

run_case "systemd_running true for real dir, false for missing path" '
  d=$(mktemp -d)
  assert_ok systemd_running "$d"
  assert_not_ok systemd_running "$d/nope"
'

echo "== parse_exec_start_argv =="

run_case "parse_exec_start_argv extracts and trims a single argv block" '
  raw=$(mk_execstart "/usr/local/bin/k3s server --tls-san 192.168.1.50")
  assert_eq "$(parse_exec_start_argv "$raw")" "/usr/local/bin/k3s server --tls-san 192.168.1.50"
'

run_case "parse_exec_start_argv fails on zero argv blocks" '
  assert_not_ok parse_exec_start_argv "{ path=/usr/local/bin/k3s ; ignore_errors=no }"
'

run_case "parse_exec_start_argv fails on empty input" '
  assert_not_ok parse_exec_start_argv ""
'

run_case "parse_exec_start_argv fails on garbage input" '
  assert_not_ok parse_exec_start_argv "totally unrelated text"
'

run_case "parse_exec_start_argv fails on two argv blocks" '
  raw="$(mk_execstart "/usr/local/bin/k3s server") $(mk_execstart "/usr/local/bin/k3s agent")"
  assert_not_ok parse_exec_start_argv "$raw"
'

echo "== get_tls_san_values (diagnostics) =="

run_case "get_tls_san_values reads the separated form" '
  assert_eq "$(get_tls_san_values "/usr/local/bin/k3s server --tls-san 192.168.1.50")" "192.168.1.50"
'

run_case "get_tls_san_values reads the = form" '
  assert_eq "$(get_tls_san_values "/usr/local/bin/k3s server --tls-san=192.168.1.50")" "192.168.1.50"
'

run_case "get_tls_san_values ignores similarly named flags" '
  argv="/usr/local/bin/k3s server --tls-sans 1.1.1.1 --other-tls-san 2.2.2.2 --tls-san2 3.3.3.3"
  assert_eq "$(get_tls_san_values "$argv")" ""
'

run_case "get_tls_san_values returns empty for a trailing --tls-san" '
  assert_eq "$(get_tls_san_values "/usr/local/bin/k3s server --tls-san")" ""
'

run_case "get_tls_san_values reports both of two SAN args" '
  argv="/usr/local/bin/k3s server --tls-san 1.1.1.1 --tls-san 2.2.2.2"
  assert_eq "$(get_tls_san_values "$argv")" "$(printf "1.1.1.1\n2.2.2.2")"
'

run_case "REGRESSION: --tls-san as the first token does not abort under set -e" '
  # ((i++)) returns status 1 when i is 0, which aborts the function under
  # set -e. This must be called as a bare command: bash suppresses set -e
  # inside $(...) assignments and inside &&/|| lists, so those forms cannot
  # observe the abort at all.
  tmp=$(mktemp)
  get_tls_san_values "--tls-san 1.1.1.1 --tls-san 2.2.2.2" > "$tmp"
  echo DONE >> "$tmp"
  assert_eq "$(cat "$tmp")" "$(printf "1.1.1.1\n2.2.2.2\nDONE")"
'

echo "== effective_exec_start_is_managed (the decision) =="

run_case "managed: exact expected server argv matches" '
  assert_ok effective_exec_start_is_managed \
    "/usr/local/bin/k3s server --tls-san 192.168.1.50" "192.168.1.50"
'

run_case "managed: agent mode with the requested SAN is a mismatch" '
  assert_not_ok effective_exec_start_is_managed \
    "/usr/local/bin/k3s agent --tls-san 192.168.1.50" "192.168.1.50"
'

run_case "managed: extra flag after the SAN is a mismatch" '
  assert_not_ok effective_exec_start_is_managed \
    "/usr/local/bin/k3s server --tls-san 192.168.1.50 --disable=traefik" "192.168.1.50"
'

run_case "managed: extra flag before the SAN is a mismatch" '
  assert_not_ok effective_exec_start_is_managed \
    "/usr/local/bin/k3s server --disable=traefik --tls-san 192.168.1.50" "192.168.1.50"
'

run_case "managed: unexpected executable path is a mismatch" '
  assert_not_ok effective_exec_start_is_managed \
    "/usr/bin/k3s server --tls-san 192.168.1.50" "192.168.1.50"
'

run_case "managed: missing server subcommand is a mismatch" '
  assert_not_ok effective_exec_start_is_managed \
    "/usr/local/bin/k3s --tls-san 192.168.1.50" "192.168.1.50"
'

run_case "managed: zero --tls-san is a mismatch" '
  assert_not_ok effective_exec_start_is_managed "/usr/local/bin/k3s server" "192.168.1.50"
'

run_case "managed: two --tls-san args are a mismatch" '
  assert_not_ok effective_exec_start_is_managed \
    "/usr/local/bin/k3s server --tls-san 192.168.1.50 --tls-san 10.0.0.1" "192.168.1.50"
'

run_case "managed: correct shape but differing IP is a mismatch" '
  assert_not_ok effective_exec_start_is_managed \
    "/usr/local/bin/k3s server --tls-san 10.0.0.1" "192.168.1.50"
'

run_case "managed: the --tls-san=IP form is a mismatch (never produced by install_k3s)" '
  assert_not_ok effective_exec_start_is_managed \
    "/usr/local/bin/k3s server --tls-san=192.168.1.50" "192.168.1.50"
'

run_case "managed: empty argv is a mismatch" '
  assert_not_ok effective_exec_start_is_managed "" "192.168.1.50"
'

run_case "managed: honours an injected binary path" '
  assert_ok effective_exec_start_is_managed \
    "/opt/k3s server --tls-san 192.168.1.50" "192.168.1.50" "/opt/k3s"
'

echo "== has_external_k3s_config =="

run_case "external config: absent file and absent dir is false" '
  d=$(mktemp -d)
  assert_not_ok has_external_k3s_config "$d/config.yaml" "$d/config.yaml.d"
'

run_case "external config: existing main config file is true" '
  d=$(mktemp -d)
  touch "$d/config.yaml"
  assert_ok has_external_k3s_config "$d/config.yaml" "$d/config.yaml.d"
'

run_case "external config: existing but empty drop-in dir is false" '
  d=$(mktemp -d)
  mkdir "$d/config.yaml.d"
  assert_not_ok has_external_k3s_config "$d/config.yaml" "$d/config.yaml.d"
'

run_case "external config: drop-in dir with one file is true" '
  d=$(mktemp -d)
  mkdir "$d/config.yaml.d"
  touch "$d/config.yaml.d/10-custom.yaml"
  assert_ok has_external_k3s_config "$d/config.yaml" "$d/config.yaml.d"
'

run_case "external config: drop-in dir containing only a dotfile is true (fail-closed)" '
  d=$(mktemp -d)
  mkdir "$d/config.yaml.d"
  touch "$d/config.yaml.d/.hidden.yaml"
  assert_ok has_external_k3s_config "$d/config.yaml" "$d/config.yaml.d"
'

echo "== inspect_installation =="

# Shared scaffolding for inspect cases: a temp dir with absent config paths, a
# fake unit name, and no real host state involved.
INSPECT_SETUP='
  d=$(mktemp -d)
  CFG="$d/config.yaml"
  CFGDIR="$d/config.yaml.d"
  KUBECFG="$d/k3s.yaml"
  ABSENT_BIN="$d/no-such-k3s"
  FAKE_EXECSTART=$(mk_execstart "/usr/local/bin/k3s server --tls-san 192.168.1.50")
'

run_case "inspect: binary absent + unit not loaded => install" "
  $INSPECT_SETUP
  FAKE_LOADSTATE='not-found'
  out=\$(inspect_installation 'v1.30.3+k3s1' '192.168.1.50' \"\$ABSENT_BIN\" \"\$FAKE_UNIT\" \"\$KUBECFG\" \"\$CFG\" \"\$CFGDIR\")
  assert_eq \"\$(inspect_field ACTION \"\$out\")\" 'install'
"

run_case "inspect: fully matching healthy install => noop" "
  $INSPECT_SETUP
  bin=\$(make_fake_k3s 'k3s version v1.30.3+k3s1 (deadbeef)')
  FAKE_EXECSTART=\$(mk_execstart \"\$bin server --tls-san 192.168.1.50\")
  touch \"\$KUBECFG\"
  out=\$(inspect_installation 'v1.30.3+k3s1' '192.168.1.50' \"\$bin\" \"\$FAKE_UNIT\" \"\$KUBECFG\" \"\$CFG\" \"\$CFGDIR\")
  assert_eq \"\$(inspect_field ACTION \"\$out\")\" 'noop'
  assert_eq \"\$(inspect_field INSTALLED_VERSION \"\$out\")\" 'v1.30.3+k3s1'
  assert_eq \"\$(inspect_field EFFECTIVE_SANS \"\$out\")\" '192.168.1.50'
"

run_case "inspect: binary present but unit not loaded => mismatch (inconsistent)" "
  $INSPECT_SETUP
  bin=\$(make_fake_k3s 'k3s version v1.30.3+k3s1 (deadbeef)')
  FAKE_LOADSTATE='not-found'
  out=\$(inspect_installation 'v1.30.3+k3s1' '192.168.1.50' \"\$bin\" \"\$FAKE_UNIT\" \"\$KUBECFG\" \"\$CFG\" \"\$CFGDIR\")
  assert_eq \"\$(inspect_field ACTION \"\$out\")\" 'mismatch'
  assert_contains \"\$(inspect_field REASON \"\$out\")\" 'inconsistent state'
"

run_case "inspect: binary absent but unit loaded => mismatch (inconsistent)" "
  $INSPECT_SETUP
  out=\$(inspect_installation 'v1.30.3+k3s1' '192.168.1.50' \"\$ABSENT_BIN\" \"\$FAKE_UNIT\" \"\$KUBECFG\" \"\$CFG\" \"\$CFGDIR\")
  assert_eq \"\$(inspect_field ACTION \"\$out\")\" 'mismatch'
  assert_contains \"\$(inspect_field REASON \"\$out\")\" 'inconsistent state'
"

run_case "inspect: unparseable version output => mismatch" "
  $INSPECT_SETUP
  bin=\$(make_fake_k3s 'garbage output with no version')
  out=\$(inspect_installation 'v1.30.3+k3s1' '192.168.1.50' \"\$bin\" \"\$FAKE_UNIT\" \"\$KUBECFG\" \"\$CFG\" \"\$CFGDIR\")
  assert_eq \"\$(inspect_field ACTION \"\$out\")\" 'mismatch'
  assert_contains \"\$(inspect_field REASON \"\$out\")\" 'not a well-formed release tag'
"

run_case "inspect: unparseable ExecStart (zero argv blocks) => mismatch" "
  $INSPECT_SETUP
  bin=\$(make_fake_k3s 'k3s version v1.30.3+k3s1 (deadbeef)')
  FAKE_EXECSTART='{ path=/usr/local/bin/k3s ; ignore_errors=no }'
  out=\$(inspect_installation 'v1.30.3+k3s1' '192.168.1.50' \"\$bin\" \"\$FAKE_UNIT\" \"\$KUBECFG\" \"\$CFG\" \"\$CFGDIR\")
  assert_eq \"\$(inspect_field ACTION \"\$out\")\" 'mismatch'
  assert_contains \"\$(inspect_field REASON \"\$out\")\" 'could not be parsed unambiguously'
"

run_case "inspect: two argv blocks (drop-in ambiguity) => mismatch" "
  $INSPECT_SETUP
  bin=\$(make_fake_k3s 'k3s version v1.30.3+k3s1 (deadbeef)')
  FAKE_EXECSTART=\"\$(mk_execstart \"\$bin server --tls-san 192.168.1.50\") \$(mk_execstart \"\$bin agent\")\"
  out=\$(inspect_installation 'v1.30.3+k3s1' '192.168.1.50' \"\$bin\" \"\$FAKE_UNIT\" \"\$KUBECFG\" \"\$CFG\" \"\$CFGDIR\")
  assert_eq \"\$(inspect_field ACTION \"\$out\")\" 'mismatch'
  assert_contains \"\$(inspect_field REASON \"\$out\")\" 'could not be parsed unambiguously'
"

run_case "inspect: differing installed version => mismatch naming both versions" "
  $INSPECT_SETUP
  bin=\$(make_fake_k3s 'k3s version v1.29.0+k3s1 (deadbeef)')
  FAKE_EXECSTART=\$(mk_execstart \"\$bin server --tls-san 192.168.1.50\")
  touch \"\$KUBECFG\"
  out=\$(inspect_installation 'v1.30.3+k3s1' '192.168.1.50' \"\$bin\" \"\$FAKE_UNIT\" \"\$KUBECFG\" \"\$CFG\" \"\$CFGDIR\")
  assert_eq \"\$(inspect_field ACTION \"\$out\")\" 'mismatch'
  assert_contains \"\$(inspect_field REASON \"\$out\")\" 'v1.29.0+k3s1'
  assert_contains \"\$(inspect_field REASON \"\$out\")\" 'v1.30.3+k3s1'
"

run_case "inspect: effective SAN overridden to a different IP => mismatch" "
  $INSPECT_SETUP
  bin=\$(make_fake_k3s 'k3s version v1.30.3+k3s1 (deadbeef)')
  FAKE_EXECSTART=\$(mk_execstart \"\$bin server --tls-san 10.9.9.9\")
  touch \"\$KUBECFG\"
  out=\$(inspect_installation 'v1.30.3+k3s1' '192.168.1.50' \"\$bin\" \"\$FAKE_UNIT\" \"\$KUBECFG\" \"\$CFG\" \"\$CFGDIR\")
  assert_eq \"\$(inspect_field ACTION \"\$out\")\" 'mismatch'
  assert_contains \"\$(inspect_field REASON \"\$out\")\" 'not exactly'
  assert_eq \"\$(inspect_field EFFECTIVE_SANS \"\$out\")\" '10.9.9.9'
"

run_case "inspect: agent mode with the requested SAN => mismatch" "
  $INSPECT_SETUP
  bin=\$(make_fake_k3s 'k3s version v1.30.3+k3s1 (deadbeef)')
  FAKE_EXECSTART=\$(mk_execstart \"\$bin agent --tls-san 192.168.1.50\")
  touch \"\$KUBECFG\"
  out=\$(inspect_installation 'v1.30.3+k3s1' '192.168.1.50' \"\$bin\" \"\$FAKE_UNIT\" \"\$KUBECFG\" \"\$CFG\" \"\$CFGDIR\")
  assert_eq \"\$(inspect_field ACTION \"\$out\")\" 'mismatch'
  assert_contains \"\$(inspect_field REASON \"\$out\")\" 'not exactly'
"

run_case "inspect: extra flag alongside a correct SAN => mismatch" "
  $INSPECT_SETUP
  bin=\$(make_fake_k3s 'k3s version v1.30.3+k3s1 (deadbeef)')
  FAKE_EXECSTART=\$(mk_execstart \"\$bin server --tls-san 192.168.1.50 --disable=traefik\")
  touch \"\$KUBECFG\"
  out=\$(inspect_installation 'v1.30.3+k3s1' '192.168.1.50' \"\$bin\" \"\$FAKE_UNIT\" \"\$KUBECFG\" \"\$CFG\" \"\$CFGDIR\")
  assert_eq \"\$(inspect_field ACTION \"\$out\")\" 'mismatch'
  assert_contains \"\$(inspect_field REASON \"\$out\")\" 'not exactly'
"

run_case "inspect: matching but service not active => mismatch" "
  $INSPECT_SETUP
  bin=\$(make_fake_k3s 'k3s version v1.30.3+k3s1 (deadbeef)')
  FAKE_EXECSTART=\$(mk_execstart \"\$bin server --tls-san 192.168.1.50\")
  FAKE_ACTIVESTATE='inactive'
  touch \"\$KUBECFG\"
  out=\$(inspect_installation 'v1.30.3+k3s1' '192.168.1.50' \"\$bin\" \"\$FAKE_UNIT\" \"\$KUBECFG\" \"\$CFG\" \"\$CFGDIR\")
  assert_eq \"\$(inspect_field ACTION \"\$out\")\" 'mismatch'
  assert_contains \"\$(inspect_field REASON \"\$out\")\" 'not both active and enabled'
  assert_eq \"\$(inspect_field UNIT_ACTIVE \"\$out\")\" 'false'
"

run_case "inspect: matching and active but not enabled => mismatch" "
  $INSPECT_SETUP
  bin=\$(make_fake_k3s 'k3s version v1.30.3+k3s1 (deadbeef)')
  FAKE_EXECSTART=\$(mk_execstart \"\$bin server --tls-san 192.168.1.50\")
  FAKE_ENABLED_RC=1
  touch \"\$KUBECFG\"
  out=\$(inspect_installation 'v1.30.3+k3s1' '192.168.1.50' \"\$bin\" \"\$FAKE_UNIT\" \"\$KUBECFG\" \"\$CFG\" \"\$CFGDIR\")
  assert_eq \"\$(inspect_field ACTION \"\$out\")\" 'mismatch'
  assert_contains \"\$(inspect_field REASON \"\$out\")\" 'not both active and enabled'
  assert_eq \"\$(inspect_field UNIT_ENABLED \"\$out\")\" 'false'
"

run_case "inspect: matching and healthy but kubeconfig missing => mismatch" "
  $INSPECT_SETUP
  bin=\$(make_fake_k3s 'k3s version v1.30.3+k3s1 (deadbeef)')
  FAKE_EXECSTART=\$(mk_execstart \"\$bin server --tls-san 192.168.1.50\")
  out=\$(inspect_installation 'v1.30.3+k3s1' '192.168.1.50' \"\$bin\" \"\$FAKE_UNIT\" \"\$KUBECFG\" \"\$CFG\" \"\$CFGDIR\")
  assert_eq \"\$(inspect_field ACTION \"\$out\")\" 'mismatch'
  assert_contains \"\$(inspect_field REASON \"\$out\")\" 'kubeconfig file is missing'
  assert_eq \"\$(inspect_field KUBECONFIG_PRESENT \"\$out\")\" 'false'
"

run_case "inspect: stale kubeconfig with binary+unit absent => still install" "
  $INSPECT_SETUP
  FAKE_LOADSTATE='not-found'
  touch \"\$KUBECFG\"
  out=\$(inspect_installation 'v1.30.3+k3s1' '192.168.1.50' \"\$ABSENT_BIN\" \"\$FAKE_UNIT\" \"\$KUBECFG\" \"\$CFG\" \"\$CFGDIR\")
  assert_eq \"\$(inspect_field ACTION \"\$out\")\" 'install'
  assert_eq \"\$(inspect_field KUBECONFIG_PRESENT \"\$out\")\" 'true'
"

run_case "inspect: existing main config file => mismatch (out of scope)" "
  $INSPECT_SETUP
  bin=\$(make_fake_k3s 'k3s version v1.30.3+k3s1 (deadbeef)')
  FAKE_EXECSTART=\$(mk_execstart \"\$bin server --tls-san 192.168.1.50\")
  touch \"\$KUBECFG\" \"\$CFG\"
  out=\$(inspect_installation 'v1.30.3+k3s1' '192.168.1.50' \"\$bin\" \"\$FAKE_UNIT\" \"\$KUBECFG\" \"\$CFG\" \"\$CFGDIR\")
  assert_eq \"\$(inspect_field ACTION \"\$out\")\" 'mismatch'
  assert_contains \"\$(inspect_field REASON \"\$out\")\" 'external k3s configuration present'
"

run_case "inspect: existing drop-in config => mismatch (out of scope)" "
  $INSPECT_SETUP
  bin=\$(make_fake_k3s 'k3s version v1.30.3+k3s1 (deadbeef)')
  FAKE_EXECSTART=\$(mk_execstart \"\$bin server --tls-san 192.168.1.50\")
  touch \"\$KUBECFG\"
  mkdir \"\$CFGDIR\"
  touch \"\$CFGDIR/10-custom.yaml\"
  out=\$(inspect_installation 'v1.30.3+k3s1' '192.168.1.50' \"\$bin\" \"\$FAKE_UNIT\" \"\$KUBECFG\" \"\$CFG\" \"\$CFGDIR\")
  assert_eq \"\$(inspect_field ACTION \"\$out\")\" 'mismatch'
  assert_contains \"\$(inspect_field REASON \"\$out\")\" 'external k3s configuration present'
"

run_case "inspect: config gate precedes the fresh-install branch" "
  $INSPECT_SETUP
  FAKE_LOADSTATE='not-found'
  touch \"\$CFG\"
  out=\$(inspect_installation 'v1.30.3+k3s1' '192.168.1.50' \"\$ABSENT_BIN\" \"\$FAKE_UNIT\" \"\$KUBECFG\" \"\$CFG\" \"\$CFGDIR\")
  assert_eq \"\$(inspect_field ACTION \"\$out\")\" 'mismatch'
  assert_contains \"\$(inspect_field REASON \"\$out\")\" 'external k3s configuration present'
"

echo "== backup_kubeconfig =="

run_case "backup: existing file is copied to a timestamped sibling, original untouched" '
  d=$(mktemp -d)
  f="$d/k3s.yaml"
  echo "original-content" > "$f"
  backup_kubeconfig "$f" >/dev/null
  mapfile -t backups < <(find "$d" -name "k3s.yaml.backup-*" | sort)
  assert_eq "${#backups[@]}" "1"
  assert_eq "$(cat "${backups[0]}")" "original-content"
  assert_eq "$(cat "$f")" "original-content"
'

run_case "backup: missing path is a no-op that creates nothing" '
  d=$(mktemp -d)
  backup_kubeconfig "$d/absent.yaml" >/dev/null
  assert_eq "$(find "$d" -type f | wc -l)" "0"
'

run_case "backup: deterministic collision gets a -1 suffix and never overwrites" '
  # date is shadowed to a fixed stamp so the outcome cannot depend on the clock.
  FIXED_TS="20260101T000000Z"
  date() { echo "$FIXED_TS"; }
  d=$(mktemp -d)
  f="$d/k3s.yaml"
  echo "current-kubeconfig" > "$f"
  echo "pre-existing-backup" > "$f.backup-$FIXED_TS"
  backup_kubeconfig "$f" >/dev/null
  assert_eq "$(cat "$f.backup-$FIXED_TS")" "pre-existing-backup"
  assert_eq "$(cat "$f.backup-$FIXED_TS-1")" "current-kubeconfig"
  assert_eq "$(cat "$f")" "current-kubeconfig"
'

run_case "backup: a second collision gets a -2 suffix" '
  FIXED_TS="20260101T000000Z"
  date() { echo "$FIXED_TS"; }
  d=$(mktemp -d)
  f="$d/k3s.yaml"
  echo "current-kubeconfig" > "$f"
  echo "a" > "$f.backup-$FIXED_TS"
  echo "b" > "$f.backup-$FIXED_TS-1"
  backup_kubeconfig "$f" >/dev/null
  assert_eq "$(cat "$f.backup-$FIXED_TS")" "a"
  assert_eq "$(cat "$f.backup-$FIXED_TS-1")" "b"
  assert_eq "$(cat "$f.backup-$FIXED_TS-2")" "current-kubeconfig"
'

run_case "constants: KUBECONFIG_PATH is the fixed production path and is readonly" '
  assert_eq "$KUBECONFIG_PATH" "/etc/rancher/k3s/k3s.yaml"
  assert_eq "$K3S_BINARY_PATH" "/usr/local/bin/k3s"
  assert_eq "$K3S_CONFIG_FILE" "/etc/rancher/k3s/config.yaml"
  assert_eq "$K3S_CONFIG_DIR" "/etc/rancher/k3s/config.yaml.d"
  if ( KUBECONFIG_PATH="/tmp/hijacked" ) 2>/dev/null; then
    echo "KUBECONFIG_PATH is not readonly"; exit 90
  fi
'

echo "== print_summary content =="

run_case "print_summary states version, IP, resulting --tls-san, path and action" '
  K3S_VERSION="v1.30.3+k3s1"
  HOST_LAN_IP="192.168.1.50"
  out=$(print_summary "install" "" "" "")
  assert_contains "$out" "v1.30.3+k3s1"
  assert_contains "$out" "192.168.1.50"
  assert_contains "$out" "Resulting --tls-san:      192.168.1.50"
  assert_contains "$out" "/etc/rancher/k3s/k3s.yaml"
  assert_contains "$out" "Intended action:          install"
'

run_case "print_summary on mismatch reports existing state and the reason" '
  K3S_VERSION="v1.30.3+k3s1"
  HOST_LAN_IP="192.168.1.50"
  out=$(print_summary "mismatch" "v1.29.0+k3s1" "10.9.9.9" "installed version differs")
  assert_contains "$out" "Intended action:          mismatch"
  assert_contains "$out" "v1.29.0+k3s1"
  assert_contains "$out" "10.9.9.9"
  assert_contains "$out" "installed version differs"
  assert_contains "$out" "docs/k3s-runbook.md"
'

run_case "print_summary on install omits the mismatch block" '
  K3S_VERSION="v1.30.3+k3s1"
  HOST_LAN_IP="192.168.1.50"
  out=$(print_summary "install" "" "" "")
  [[ "$out" == *"Existing installation state"* ]] && { echo "should not print mismatch block"; exit 90; }
  true
'

echo "== install_k3s (no network, no host mutation) =="

run_case "install_k3s propagates the pinned version and argv to the installer" '
  # curl is shadowed to emit a harmless local script; the real sh interprets it.
  curl() {
    cat <<"STUB"
#!/bin/sh
echo "INSTALLER_ENV_VERSION=$INSTALL_K3S_VERSION"
echo "INSTALLER_ARGV=$*"
STUB
  }
  K3S_VERSION="v1.30.3+k3s1"
  HOST_LAN_IP="192.168.1.50"
  out=$(install_k3s)
  assert_contains "$out" "INSTALLER_ENV_VERSION=v1.30.3+k3s1"
  assert_contains "$out" "INSTALLER_ARGV=server --tls-san 192.168.1.50"
'

run_case "SECURITY: install_k3s clears inherited INSTALL_K3S_*/K3S_* before invoking the installer" '
  # INSTALL_K3S_COMMIT and INSTALL_K3S_PR outrank INSTALL_K3S_VERSION upstream,
  # and INSTALL_K3S_EXEC prepends arguments — either would silently install
  # something other than what the summary promised.
  curl() {
    cat <<"STUB"
#!/bin/sh
echo "COMMIT=[$INSTALL_K3S_COMMIT]"
echo "PR=[$INSTALL_K3S_PR]"
echo "EXEC=[$INSTALL_K3S_EXEC]"
echo "BIN_DIR=[$INSTALL_K3S_BIN_DIR]"
echo "URL=[$K3S_URL]"
echo "VERSION=[$INSTALL_K3S_VERSION]"
echo "ARGV=[$*]"
STUB
  }
  export INSTALL_K3S_COMMIT="deadbeefcafe"
  export INSTALL_K3S_PR="1234"
  export INSTALL_K3S_EXEC="--disable=traefik"
  export INSTALL_K3S_BIN_DIR="/opt/hijack"
  export K3S_URL="https://elsewhere.lan:6443"
  K3S_VERSION="v1.30.3+k3s1"
  HOST_LAN_IP="192.168.1.50"
  out=$(install_k3s)
  assert_contains "$out" "COMMIT=[]"
  assert_contains "$out" "PR=[]"
  assert_contains "$out" "EXEC=[]"
  assert_contains "$out" "BIN_DIR=[]"
  assert_contains "$out" "URL=[]"
  assert_contains "$out" "VERSION=[v1.30.3+k3s1]"
  assert_contains "$out" "ARGV=[server --tls-san 192.168.1.50]"
'

run_case "install_k3s works when no INSTALL_K3S_*/K3S_* vars are set" '
  curl() { printf "#!/bin/sh\necho ARGV=[\$*]\n"; }
  K3S_VERSION="v1.30.3+k3s1"
  HOST_LAN_IP="192.168.1.50"
  out=$(install_k3s)
  assert_contains "$out" "ARGV=[server --tls-san 192.168.1.50]"
'

run_case "install_k3s propagates a downloader failure" '
  curl() { return 1; }
  K3S_VERSION="v1.30.3+k3s1"
  HOST_LAN_IP="192.168.1.50"
  rc=0
  install_k3s >/dev/null 2>&1 || rc=$?
  [[ "$rc" -ne 0 ]] || { echo "expected non-zero exit"; exit 90; }
'

run_case "install_k3s propagates an installer failure" '
  curl() { printf "#!/bin/sh\nexit 3\n"; }
  K3S_VERSION="v1.30.3+k3s1"
  HOST_LAN_IP="192.168.1.50"
  rc=0
  install_k3s >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" "3"
'

echo "== main() (fully stubbed, host-independent) =="

# Replaces every collaborator main() touches, so these cases need no root, no
# systemd, no real k3s unit, no /etc/rancher, and no network.
MAIN_SETUP='
  LOG=$(mktemp)
  K3S_VERSION="v1.30.3+k3s1"
  HOST_LAN_IP="192.168.1.50"
  check_prerequisites() { echo check_prerequisites >> "$LOG"; }
  print_summary()       { echo print_summary >> "$LOG"; }
  backup_kubeconfig()   { echo backup_kubeconfig >> "$LOG"; }
  install_k3s()         { echo install_k3s >> "$LOG"; }
  print_next_steps()    { echo print_next_steps >> "$LOG"; }
  curl()                { echo curl >> "$LOG"; }
'

run_case "main: mismatch exits 1 and mutates nothing" "
  $MAIN_SETUP
  inspect_installation() { echo 'ACTION=mismatch'; echo 'REASON=forced'; }
  rc=0
  ( main ) >/dev/null 2>&1 || rc=\$?
  assert_eq \"\$rc\" '1'
  assert_contains \"\$(cat \"\$LOG\")\" 'print_summary'
  assert_eq \"\$(grep -c 'backup_kubeconfig\|install_k3s\|curl' \"\$LOG\" || true)\" '0'
"

run_case "main: noop exits 0 and mutates nothing" "
  $MAIN_SETUP
  inspect_installation() { echo 'ACTION=noop'; }
  rc=0
  ( main ) >/dev/null 2>&1 || rc=\$?
  assert_eq \"\$rc\" '0'
  assert_eq \"\$(grep -c 'backup_kubeconfig\|install_k3s\|curl' \"\$LOG\" || true)\" '0'
"

run_case "main: install backs up before installing, after the summary" "
  $MAIN_SETUP
  inspect_installation() { echo 'ACTION=install'; }
  rc=0
  ( main ) >/dev/null 2>&1 || rc=\$?
  assert_eq \"\$rc\" '0'
  assert_eq \"\$(cat \"\$LOG\")\" \"\$(printf 'check_prerequisites\nprint_summary\nbackup_kubeconfig\ninstall_k3s\nprint_next_steps')\"
"

run_case "main: unrecognized action hits the fail-closed backstop" "
  $MAIN_SETUP
  inspect_installation() { echo 'ACTION=surprise'; }
  rc=0
  out=\$( ( main ) 2>&1 ) || rc=\$?
  assert_eq \"\$rc\" '1'
  assert_contains \"\$out\" 'unrecognized action'
  assert_eq \"\$(grep -c 'backup_kubeconfig\|install_k3s\|curl' \"\$LOG\" || true)\" '0'
"

run_case "main: invalid K3S_VERSION is rejected before any collaborator runs" "
  $MAIN_SETUP
  K3S_VERSION='latest'
  inspect_installation() { echo install_k3s >> \"\$LOG\"; echo 'ACTION=install'; }
  rc=0
  out=\$( ( main ) 2>&1 ) || rc=\$?
  assert_eq \"\$rc\" '1'
  assert_contains \"\$out\" 'not an exact k3s release tag'
  assert_eq \"\$(wc -l < \"\$LOG\")\" '0'
"

run_case "main: invalid HOST_LAN_IP is rejected before any collaborator runs" "
  $MAIN_SETUP
  HOST_LAN_IP='homelab.local'
  inspect_installation() { echo 'ACTION=install'; }
  rc=0
  out=\$( ( main ) 2>&1 ) || rc=\$?
  assert_eq \"\$rc\" '1'
  assert_contains \"\$out\" 'HOST_LAN_IP'
  assert_eq \"\$(wc -l < \"\$LOG\")\" '0'
"

run_case "SECURITY: main never reaches install_k3s with a newline-injected HOST_LAN_IP" "
  $MAIN_SETUP
  HOST_LAN_IP=\$(printf '192.168.1.50\nExecStartPost=/bin/sh -c evil')
  inspect_installation() { echo 'ACTION=install'; }
  rc=0
  out=\$( ( main ) 2>&1 ) || rc=\$?
  assert_eq \"\$rc\" '1'
  assert_contains \"\$out\" 'not a dotted-quad'
  assert_eq \"\$(wc -l < \"\$LOG\")\" '0'
"

echo "== static checks =="

if bash -n "$SCRIPT_UNDER_TEST"; then
  PASSED=$((PASSED + 1))
else
  FAILED=$((FAILED + 1)); FAILED_NAMES+=("bash -n install.sh"); echo "FAIL: bash -n install.sh"
fi

if bash -n "$SCRIPT_DIR/install.test.sh"; then
  PASSED=$((PASSED + 1))
else
  FAILED=$((FAILED + 1)); FAILED_NAMES+=("bash -n install.test.sh"); echo "FAIL: bash -n install.test.sh"
fi

if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck "$SCRIPT_UNDER_TEST"; then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1)); FAILED_NAMES+=("shellcheck install.sh"); echo "FAIL: shellcheck install.sh"
  fi
else
  echo "SKIP: shellcheck not installed (optional, not a hard dependency)"
fi

echo
echo "passed: $PASSED  failed: $FAILED"
if ((FAILED > 0)); then
  printf 'failed cases:\n'
  printf '  - %s\n' "${FAILED_NAMES[@]}"
  exit 1
fi

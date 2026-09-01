#!/usr/bin/env bash
#
# Tests for the dnsmasq LAN-UFW lifecycle:
#   dnsmasq/lan-ufw-lib.sh, dnsmasq/lan-ufw-install.sh, dnsmasq/lan-ufw-rollback.sh
#
# Plain bash, no test framework dependency. Run with:
#   bash dnsmasq/lan-ufw.test.sh
#
# Every case runs in a fresh `bash -c` that sources one script under test
# (install.sh / rollback.sh source lan-ufw-lib.sh, so their own `set -euo
# pipefail` is active exactly as in production; lib-only cases source the lib
# alone). `ufw`, `ip`, `flock`, `id` and `command` are shadowed per case, and
# every managed path (state dir/file, lock file) is redirected into a per-case
# tmpdir by reassigning the deliberately non-readonly globals from the lib.
#
# NO case touches the real firewall, the real /etc, the real /var/lib, the
# real /run, or requires root. The one case that drives the real `flock`
# binary does so against a tmpdir lock file only.
#
# shellcheck disable=SC2016
# Test bodies are single-quoted on purpose: they must reach the case subshell
# unexpanded, and are evaluated there against the sourced scripts.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/lan-ufw-lib.sh"
INSTALL="$SCRIPT_DIR/lan-ufw-install.sh"
ROLLBACK="$SCRIPT_DIR/lan-ufw-rollback.sh"

PASSED=0
FAILED=0
FAILED_NAMES=()

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
expect_die() {
  local expected="$1"; shift
  local out rc=0
  out=$("$@" 2>&1) || rc=$?
  ((rc == 1)) || { echo "expect_die: expected exit 1, got $rc (output: $out)"; exit 90; }
  [[ "$out" == *"$expected"* ]] || { echo "expect_die: [$expected] not found in [$out]"; exit 90; }
}
# Runs an entrypoint `main` in a subshell, capturing OUT and RC without
# tripping the sourced script's `set -e`.
run_main() { RC=0; OUT="$("$@" 2>&1)" || RC=$?; }
decision_field() { awk -F= -v k="$1" '$1==k{sub(/^[^=]*=/,"");print}' <<< "$2"; }

# --- shadowed collaborators -------------------------------------------------

FAKE_UID=0
id() { if [[ "${1:-}" == "-u" ]]; then printf '%s\n' "$FAKE_UID"; return 0; fi; builtin command id "$@"; }

MISSING_CMD=""
command() {
  if [[ "${1:-}" == "-v" && -n "$MISSING_CMD" && "${2:-}" == "$MISSING_CMD" ]]; then
    return 1
  fi
  builtin command "$@"
}

FAKE_FLOCK_RC=0
flock() { return "$FAKE_FLOCK_RC"; }

FAKE_IP_ADDR=""
FAKE_IP_ROUTE_LINK=""
FAKE_IP_ROUTE_DEFAULT=""
FAKE_IP_LINK=""
ip() {
  local s="$*"
  case "$s" in
    "-o -4 addr show")                    printf '%s\n' "$FAKE_IP_ADDR" ;;
    "-o -4 route show default")            printf '%s\n' "$FAKE_IP_ROUTE_DEFAULT" ;;
    "-o -4 route show dev "*" scope link") printf '%s\n' "$FAKE_IP_ROUTE_LINK" ;;
    "-o link show dev "*)                  printf '%s\n' "$FAKE_IP_LINK" ;;
    *) return 1 ;;
  esac
}

FAKE_UFW_ACTIVE=1
FAKE_UFW_ADD_RC=0
FAKE_UFW_ADD_TCP_RC=""
# Model a mutating `ufw allow` that applies its rule but still returns non-zero.
FAKE_UFW_UDP_APPLY_ON_FAIL=false
FAKE_UFW_TCP_APPLY_ON_FAIL=false
FAKE_UFW_DEL_RC=0
FAKE_UFW_DEL_TCP_RC=""
UFW_CALLS=""
# The live rule set is kept in a FILE (not a variable) so mutations made by
# `ufw` inside a `main` subshell survive back into the case body for
# assertions.
UFW_STATUS_FILE=""
# Fail-injection for `ufw status`: from the Nth call (1-based) onward it either
# exits non-zero (FAIL_FROM) or prints "Status: inactive" (INACTIVE_FROM). The
# call counter is a file so it persists across the `main` subshell.
UFW_STATUS_CALLS_FILE=""
FAKE_UFW_STATUS_FAIL_FROM=""
FAKE_UFW_STATUS_INACTIVE_FROM=""
ufw_status_set()   { : > "$UFW_STATUS_FILE"; (($#)) && printf '%s\n' "$@" > "$UFW_STATUS_FILE"; }
ufw_status_add()   { (($#)) && printf '%s\n' "$@" >> "$UFW_STATUS_FILE"; }
ufw_status_dump()  { cat "$UFW_STATUS_FILE"; }
# Build a validated-shape snapshot file from the current fake rule set, for
# calling ownership helpers directly from a case body.
mk_snap() {
  local f; f="$(mktemp)"
  { printf 'Status: active\n\n'
    printf 'To                         Action      From\n'
    printf -- '--                         ------      ----\n'
    [[ -s "$UFW_STATUS_FILE" ]] && grep -v '^[[:space:]]*$' "$UFW_STATUS_FILE"
  } > "$f"
  printf '%s\n' "$f"
}

_ufw_spec_parse() {
  local s="${1#delete }"
  [[ "$s" =~ ^allow\ in\ on\ ([^ ]+)\ from\ ([^ ]+)\ to\ ([^ ]+)\ port\ 53\ proto\ (udp|tcp)(\ comment\ (.*))?$ ]] || return 1
  SP_IFACE="${BASH_REMATCH[1]}"
  SP_SUBNET="${BASH_REMATCH[2]}"
  SP_IP="${BASH_REMATCH[3]}"
  SP_PROTO="${BASH_REMATCH[4]}"
  SP_COMMENT="${BASH_REMATCH[6]}"
}
# Emulates the PRODUCTION input source: plain `ufw status`, whose rows on the
# real host (UFW 0.36.2) render the action as bare `ALLOW` (no `IN`).
_ufw_status_line() {
  printf '%s 53/%s on %s          ALLOW       %s               # %s' "$1" "$2" "$3" "$4" "$5"
}
_ufw_apply_add() {
  local SP_IFACE SP_SUBNET SP_IP SP_PROTO SP_COMMENT
  _ufw_spec_parse "$1" || return 0
  _ufw_status_line "$SP_IP" "$SP_PROTO" "$SP_IFACE" "$SP_SUBNET" "$SP_COMMENT" >> "$UFW_STATUS_FILE"
  printf '\n' >> "$UFW_STATUS_FILE"
}
# Spec-based delete: drop any row matching the rule tuple, tolerating either
# `ALLOW` or `ALLOW IN` (a standalone `IN` right after `ALLOW` is squeezed out).
_ufw_apply_delete() {
  local SP_IFACE SP_SUBNET SP_IP SP_PROTO SP_COMMENT want l norm tmp
  _ufw_spec_parse "$1" || return 0
  want="$SP_IP 53/$SP_PROTO on $SP_IFACE ALLOW $SP_SUBNET"
  tmp="$(mktemp)"
  while IFS= read -r l; do
    [[ -n "$l" ]] || continue
    norm="$(printf '%s' "${l%% # *}" | tr -s ' ' ' ' | sed -e 's/^ //' -e 's/ $//' -e 's/ ALLOW IN / ALLOW /')"
    [[ "$norm" == "$want" ]] && continue
    printf '%s\n' "$l" >> "$tmp"
  done < "$UFW_STATUS_FILE"
  mv -f "$tmp" "$UFW_STATUS_FILE"
}
ufw() {
  local sub="$*"
  case "$sub" in
    "status")
      local n=1
      if [[ -n "$UFW_STATUS_CALLS_FILE" ]]; then
        n=$(( $(cat "$UFW_STATUS_CALLS_FILE" 2>/dev/null || echo 0) + 1 ))
        printf '%s\n' "$n" > "$UFW_STATUS_CALLS_FILE"
      fi
      if [[ -n "$FAKE_UFW_STATUS_FAIL_FROM" ]] && (( n >= FAKE_UFW_STATUS_FAIL_FROM )); then
        return 1
      fi
      if [[ -n "$FAKE_UFW_STATUS_INACTIVE_FROM" ]] && (( n >= FAKE_UFW_STATUS_INACTIVE_FROM )); then
        printf 'Status: inactive\n'; return 0
      fi
      if [[ "$FAKE_UFW_ACTIVE" == 1 ]]; then
        printf 'Status: active\n\n'
        printf 'To                         Action      From\n'
        printf -- '--                         ------      ----\n'
        [[ -s "$UFW_STATUS_FILE" ]] && grep -v '^[[:space:]]*$' "$UFW_STATUS_FILE"
      else
        printf 'Status: inactive\n'
      fi
      return 0 ;;
    "--version") printf 'ufw 0.36.2\n'; return 0 ;;
    "allow in on "*)
      [[ -n "$UFW_CALLS" ]] && printf 'ADD %s\n' "$sub" >> "$UFW_CALLS"
      # Return code and side effect are INDEPENDENT seams. Real `ufw allow`
      # can apply its rule and still exit non-zero, so the fake must be able to
      # model: apply+rc0 (default) / no-apply+rc!=0 / apply+rc!=0.
      local rc="$FAKE_UFW_ADD_RC" apply_on_fail="$FAKE_UFW_UDP_APPLY_ON_FAIL"
      if [[ "$sub" == *"proto tcp"* ]]; then
        [[ -n "$FAKE_UFW_ADD_TCP_RC" ]] && rc="$FAKE_UFW_ADD_TCP_RC"
        apply_on_fail="$FAKE_UFW_TCP_APPLY_ON_FAIL"
      fi
      if [[ "$rc" == 0 || "$apply_on_fail" == true ]]; then
        _ufw_apply_add "$sub"
      fi
      return "$rc" ;;
    "delete allow in on "*)
      [[ -n "$UFW_CALLS" ]] && printf 'DEL %s\n' "${sub#delete }" >> "$UFW_CALLS"
      local rc="$FAKE_UFW_DEL_RC"
      [[ "$sub" == *"proto tcp"* && -n "$FAKE_UFW_DEL_TCP_RC" ]] && rc="$FAKE_UFW_DEL_TCP_RC"
      [[ "$rc" == 0 ]] && _ufw_apply_delete "$sub"
      return "$rc" ;;
    *) return 1 ;;
  esac
}

# --- canonical fixtures (RFC 5737 doc space + a neutral fake iface name) ---
#
# Primary shape = REAL plain `ufw status` (bare `ALLOW`, observed on the host
# during preflight, UFW 0.36.2). `_mk_owned_line_allowin` keeps the
# `ufw status numbered`-style `ALLOW IN` shape for regression coverage.

_mk_owned_line() {
  local proto="$1" c
  case "$proto" in
    udp) c='homelab-platform:dnsmasq-lan-ufw udp/53' ;;
    tcp) c='homelab-platform:dnsmasq-lan-ufw tcp/53' ;;
  esac
  printf '192.0.2.10 53/%s on lan0          ALLOW       192.0.2.0/24               # %s' "$proto" "$c"
}
_mk_owned_line_allowin() {
  local proto="$1" c
  case "$proto" in
    udp) c='homelab-platform:dnsmasq-lan-ufw udp/53' ;;
    tcp) c='homelab-platform:dnsmasq-lan-ufw tcp/53' ;;
  esac
  printf '192.0.2.10 53/%s on lan0          ALLOW IN    192.0.2.0/24               # %s' "$proto" "$c"
}
_mk_owned_line_wrongsubnet() {
  local proto="$1" c
  case "$proto" in
    udp) c='homelab-platform:dnsmasq-lan-ufw udp/53' ;;
    tcp) c='homelab-platform:dnsmasq-lan-ufw tcp/53' ;;
  esac
  printf '192.0.2.10 53/%s on lan0          ALLOW       198.51.100.0/24               # %s' "$proto" "$c"
}
_mk_unrelated_line()   { printf '22/tcp                     ALLOW       Anywhere'; }
_mk_foreign_dns_line() { printf '53                         ALLOW       Anywhere'; }

# The EXACT plain `ufw status` rows observed on the host during preflight
# (UFW 0.36.2): bare "ALLOW", NO "IN" token.
UDP_PLAIN='192.0.2.10 53/udp on lan0          ALLOW       192.0.2.0/24               # homelab-platform:dnsmasq-lan-ufw udp/53'
TCP_PLAIN='192.0.2.10 53/tcp on lan0          ALLOW       192.0.2.0/24               # homelab-platform:dnsmasq-lan-ufw tcp/53'

setup_env() {
  D="$(mktemp -d)"
  PLATFORM_STATE_ROOT="$D/var/lib/homelab-platform"
  LAN_UFW_STATE_DIR="$PLATFORM_STATE_ROOT/dnsmasq-lan-ufw"
  LAN_UFW_STATE_FILE="$LAN_UFW_STATE_DIR/state.env"
  LOCK_FILE="$D/lock"
  LAN_UFW_STATE_STRICT_PERMS=0
  # /var/lib always exists on a real host (FHS); PLATFORM_STATE_ROOT itself is
  # left absent so do_install must create it.
  mkdir -p "$D/var/lib"

  UFW_CALLS="$D/ufw-calls.log"; : > "$UFW_CALLS"
  UFW_STATUS_FILE="$D/ufw-status"; : > "$UFW_STATUS_FILE"
  UFW_STATUS_CALLS_FILE="$D/ufw-status-calls"; printf '0\n' > "$UFW_STATUS_CALLS_FILE"

  FAKE_UID=0
  MISSING_CMD=""
  FAKE_FLOCK_RC=0
  FAKE_UFW_ACTIVE=1
  FAKE_UFW_STATUS_FAIL_FROM=""
  FAKE_UFW_STATUS_INACTIVE_FROM=""
  FAKE_UFW_ADD_RC=0; FAKE_UFW_ADD_TCP_RC=""
  FAKE_UFW_UDP_APPLY_ON_FAIL=false; FAKE_UFW_TCP_APPLY_ON_FAIL=false
  FAKE_UFW_DEL_RC=0; FAKE_UFW_DEL_TCP_RC=""

  HOST_LAN_IP="192.0.2.10"
  FAKE_IP_ADDR="2: lan0    inet 192.0.2.10/24 brd 192.0.2.255 scope global lan0"
  FAKE_IP_ROUTE_LINK="192.0.2.0/24 dev lan0 proto kernel scope link src 192.0.2.10 metric 100"
  FAKE_IP_ROUTE_DEFAULT="default via 192.0.2.1 dev lan0 proto dhcp src 192.0.2.10 metric 100"
  FAKE_IP_LINK="2: lan0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP mode DEFAULT group default qlen 1000"
}

seed_state() {
  local phase="$1"
  mkdir -p "$LAN_UFW_STATE_DIR"
  printf '%s\n' \
    "PHASE=${phase}" \
    'HOST_LAN_IP=192.0.2.10' \
    'LAN_SUBNET=192.0.2.0/24' \
    'LAN_INTERFACE=lan0' \
    'UDP_COMMENT=homelab-platform:dnsmasq-lan-ufw udp/53' \
    'TCP_COMMENT=homelab-platform:dnsmasq-lan-ufw tcp/53' > "$LAN_UFW_STATE_FILE"
}
seed_installed()     { seed_state installed;    ufw_status_set "$(_mk_owned_line udp)" "$(_mk_owned_line tcp)"; }
seed_installing()    { seed_state installing;   ufw_status_set "$(_mk_owned_line udp)" "$(_mk_owned_line tcp)"; }
seed_rolling_back()  { seed_state rolling_back; ufw_status_set "$(_mk_owned_line udp)" "$(_mk_owned_line tcp)"; }
PRELUDE_EOF

run_case() {
  local name="$1" script="$2" code="$3"
  local out rc=0
  out=$(bash -c "source \"\$1\"
$PRELUDE
$code" "lan-ufw-test" "$script" 2>&1) || rc=$?
  if ((rc == 0)); then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
    FAILED_NAMES+=("$name")
    echo "FAIL: $name"
    # shellcheck disable=SC2001
    echo "$out" | sed 's/^/      /'
  fi
}

# =========================================================================
echo "== validate_ipv4 / validate_cidr / cidr_network / assert_usable_lan_prefix =="

run_case "cidr_network derives the canonical network" "$LIB" '
  assert_eq "$(cidr_network 192.0.2.10 24)" "192.0.2.0/24"
  assert_eq "$(cidr_network 10.1.2.3 8)"    "10.0.0.0/8"
  assert_eq "$(cidr_network 172.16.40.9 20)" "172.16.32.0/20"
'

run_case "validate_cidr accepts a canonical /8 and rejects a non-canonical address" "$LIB" '
  validate_cidr "10.0.0.0/8"
  expect_die "canonical network address" validate_cidr "192.0.2.7/24"
'

run_case "assert_usable_lan_prefix rejects /31 and /32, accepts /8 and /30" "$LIB" '
  assert_usable_lan_prefix 8
  assert_usable_lan_prefix 30
  expect_die "point-to-point / single-host prefix" assert_usable_lan_prefix 31
  expect_die "point-to-point / single-host prefix" assert_usable_lan_prefix 32
'

run_case "validate_ipv4 rejects malformed HOST_LAN_IP incl. embedded newline" "$LIB" '
  expect_die "HOST_LAN_IP" validate_ipv4 "192.168.1"
  expect_die "HOST_LAN_IP" validate_ipv4 "256.1.1.1"
  probe=$(printf "192.0.2.10\nADD rule")
  expect_die "not a dotted-quad" validate_ipv4 "$probe"
'

# =========================================================================
echo "== check_prerequisites: input / root / command availability =="

run_case "install: missing HOST_LAN_IP -> die naming it" "$INSTALL" '
  setup_env
  unset HOST_LAN_IP
  expect_die "Missing required variable: HOST_LAN_IP" main
'

run_case "install: malformed HOST_LAN_IP -> die" "$INSTALL" '
  setup_env
  HOST_LAN_IP="192.0.2"
  expect_die "not a dotted-quad" main
'

run_case "install: non-root -> die before any lock / ufw call" "$INSTALL" '
  setup_env
  FAKE_UID=1000
  expect_die "must be run as root" main
  [[ -s "$UFW_CALLS" ]] && { echo "no ufw call expected"; exit 90; }
  true
'

run_case "install: missing ip -> die" "$INSTALL" '
  setup_env
  MISSING_CMD="ip"
  expect_die "required command '"'"'ip'"'"'" main
'

run_case "install: missing ufw -> die" "$INSTALL" '
  setup_env
  MISSING_CMD="ufw"
  expect_die "required command '"'"'ufw'"'"'" main
'

run_case "install: missing flock -> die" "$INSTALL" '
  setup_env
  MISSING_CMD="flock"
  expect_die "required command '"'"'flock'"'"'" main
'

run_case "rollback: missing flock -> die" "$ROLLBACK" '
  setup_env
  seed_installed
  MISSING_CMD="flock"
  expect_die "required command '"'"'flock'"'"'" main
'

# =========================================================================
echo "== lock is acquired BEFORE any UFW state inspection =="

run_case "install: UFW inactive is only detected AFTER the lock (lock contended wins)" "$INSTALL" '
  setup_env
  FAKE_UFW_ACTIVE=0
  FAKE_FLOCK_RC=1
  # If ufw_is_active were checked before the lock this would say "UFW is not
  # active"; instead the concurrency refusal must win.
  expect_die "already in progress" main
'

run_case "install: UFW inactive -> die (after lock)" "$INSTALL" '
  setup_env
  FAKE_UFW_ACTIVE=0
  expect_die "UFW is not active" main
'

run_case "rollback: UFW inactive -> die (after lock)" "$ROLLBACK" '
  setup_env
  seed_installed
  FAKE_UFW_ACTIVE=0
  expect_die "UFW is not active" main
'

# =========================================================================
echo "== concurrency: a second lifecycle operation is refused without mutation =="

run_case "install: contended lock -> refuse, zero ufw calls, zero state" "$INSTALL" '
  setup_env
  FAKE_FLOCK_RC=1
  expect_die "already in progress" main
  [[ -e "$LAN_UFW_STATE_DIR" ]] && { echo "no state dir expected"; exit 90; }
  [[ -s "$UFW_CALLS" ]] && { echo "no ufw call expected"; exit 90; }
  [[ -s "$UFW_STATUS_FILE" ]] && { echo "firewall must be untouched"; exit 90; }
  true
'

run_case "rollback: contended lock -> refuse, rules and state untouched" "$ROLLBACK" '
  setup_env
  seed_installed
  before="$(ufw_status_dump)"
  FAKE_FLOCK_RC=1
  expect_die "already in progress" main
  assert_eq "$(ufw_status_dump)" "$before"
  [[ -f "$LAN_UFW_STATE_FILE" ]] || { echo "state file must remain"; exit 90; }
  [[ -s "$UFW_CALLS" ]] && { echo "no ufw call expected"; exit 90; }
  true
'

run_case "install vs a really-held flock: refused via the real flock binary" "$INSTALL" '
  setup_env
  unset -f flock
  ( exec 9>"$LOCK_FILE"; command flock -n 9 || exit 7; : > "$D/held"; sleep 2 ) &
  bg=$!
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do [[ -e "$D/held" ]] && break; sleep 0.1; done
  [[ -e "$D/held" ]] || { echo "background holder never took the lock"; kill "$bg" 2>/dev/null; exit 90; }
  RC=0; OUT="$(main 2>&1)" || RC=$?
  kill "$bg" 2>/dev/null; wait "$bg" 2>/dev/null || true
  ((RC == 1)) || { echo "expected refusal, got rc=$RC ($OUT)"; exit 90; }
  assert_contains "$OUT" "already in progress"
  [[ -s "$UFW_CALLS" ]] && { echo "no ufw call expected"; exit 90; }
  true
'

# =========================================================================
echo "== LAN discovery: fail closed =="

run_case "discovery: HOST_LAN_IP on no interface -> die" "$LIB" '
  FAKE_IP_ADDR="2: lan0    inet 198.51.100.7/24 scope global lan0"
  expect_die "not present on any interface" discover_lan_interface "192.0.2.10"
'

run_case "discovery: HOST_LAN_IP on two interfaces -> ambiguous" "$LIB" '
  FAKE_IP_ADDR=$(printf "2: lan0 inet 192.0.2.10/24 scope global lan0\n3: lan1 inet 192.0.2.10/24 scope global lan1")
  expect_die "ambiguous LAN interface discovery" discover_lan_interface "192.0.2.10"
'

run_case "discovery: loopback HOST_LAN_IP -> refuse" "$LIB" '
  FAKE_IP_ADDR="1: lo    inet 127.0.0.1/8 scope host lo"
  FAKE_IP_LINK="1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN"
  expect_die "scope" discover_lan_interface "127.0.0.1"
'

run_case "discovery: non-global (link-local) address -> refuse" "$LIB" '
  FAKE_IP_ADDR="4: lan0    inet 169.254.5.5/16 scope link lan0"
  expect_die "non-global scope" discover_lan_interface "169.254.5.5"
'

run_case "discovery: address on a connected but non-default-route bridge -> refuse" "$LIB" '
  FAKE_IP_ADDR="7: br0    inet 192.0.2.10/24 brd 192.0.2.255 scope global br0"
  FAKE_IP_LINK="7: br0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP"
  FAKE_IP_ROUTE_LINK="192.0.2.0/24 dev br0 proto kernel scope link src 192.0.2.10"
  FAKE_IP_ROUTE_DEFAULT="default via 10.9.0.1 dev wan0 proto dhcp src 10.9.0.44 metric 100"
  expect_die "does not carry an IPv4 default route" discover_lan_interface "192.0.2.10"
'

run_case "discovery: derived subnet not directly connected -> inconsistent" "$LIB" '
  setup_env
  FAKE_IP_ROUTE_LINK="198.51.100.0/24 dev lan0 proto kernel scope link src 198.51.100.9"
  expect_die "not a directly-connected route" discover_lan_interface "192.0.2.10"
'

run_case "discovery: /32 host address -> refuse (no minimum-prefix policy imposed)" "$LIB" '
  FAKE_IP_ADDR="2: lan0    inet 192.0.2.10/32 scope global lan0"
  FAKE_IP_ROUTE_LINK="192.0.2.10/32 dev lan0 proto kernel scope link src 192.0.2.10"
  expect_die "point-to-point / single-host prefix" discover_lan_interface "192.0.2.10"
'

run_case "discovery: /31 address -> refuse" "$LIB" '
  FAKE_IP_ADDR="2: lan0    inet 192.0.2.10/31 scope global lan0"
  FAKE_IP_ROUTE_LINK="192.0.2.10/31 dev lan0 proto kernel scope link src 192.0.2.10"
  expect_die "point-to-point / single-host prefix" discover_lan_interface "192.0.2.10"
'

run_case "discovery: valid global address on the default-route LAN interface -> pass" "$LIB" '
  setup_env
  assert_eq "$(discover_lan_interface 192.0.2.10)" "lan0 24 192.0.2.0/24"
'

run_case "discovery: a /8 LAN is accepted (no undocumented minimum prefix)" "$LIB" '
  FAKE_IP_ADDR="2: lan0    inet 10.1.2.3/8 scope global lan0"
  FAKE_IP_ROUTE_LINK="10.0.0.0/8 dev lan0 proto kernel scope link src 10.1.2.3"
  FAKE_IP_ROUTE_DEFAULT="default via 10.0.0.1 dev lan0 proto dhcp src 10.1.2.3"
  FAKE_IP_LINK="2: lan0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500"
  assert_eq "$(discover_lan_interface 10.1.2.3)" "lan0 8 10.0.0.0/8"
'

# =========================================================================
echo "== classify_state =="

run_case "classify: clean baseline -> install" "$LIB" '
  setup_env
  out="$(classify_state 192.0.2.10 lan0 192.0.2.0/24)"
  assert_eq "$(decision_field ACTION "$out")" "install"
'

run_case "classify: no state but a DNS rule exists -> mismatch (foreign)" "$LIB" '
  setup_env
  ufw_status_set "$(_mk_foreign_dns_line)"
  out="$(classify_state 192.0.2.10 lan0 192.0.2.0/24)"
  assert_eq "$(decision_field ACTION "$out")" "mismatch"
  assert_contains "$out" "foreign or pre-existing"
'

run_case "classify: PHASE=installed + both owned rules + no foreign -> noop" "$LIB" '
  setup_env
  seed_installed
  out="$(classify_state 192.0.2.10 lan0 192.0.2.0/24)"
  assert_eq "$(decision_field ACTION "$out")" "noop"
'

run_case "classify: PHASE=installed but only the udp rule live -> mismatch (partial)" "$LIB" '
  setup_env
  seed_installed
  ufw_status_set "$(_mk_owned_line udp)"
  out="$(classify_state 192.0.2.10 lan0 192.0.2.0/24)"
  assert_eq "$(decision_field ACTION "$out")" "mismatch"
  assert_contains "$out" "udp=1 tcp=0"
'

run_case "classify: PHASE=installed + a foreign :53 rule alongside -> mismatch" "$LIB" '
  setup_env
  seed_installed
  ufw_status_add "$(_mk_foreign_dns_line)"
  out="$(classify_state 192.0.2.10 lan0 192.0.2.0/24)"
  assert_eq "$(decision_field ACTION "$out")" "mismatch"
  assert_contains "$out" "foreign or drifted"
'

run_case "classify: recorded subnet differs from freshly-derived -> mismatch" "$LIB" '
  setup_env
  seed_installed
  out="$(classify_state 192.0.2.10 lan0 198.51.100.0/24)"
  assert_eq "$(decision_field ACTION "$out")" "mismatch"
  assert_contains "$out" "differs from freshly-derived"
'

run_case "classify: PHASE=installing recorded -> mismatch pointing at recovery rollback" "$LIB" '
  setup_env
  seed_installing
  out="$(classify_state 192.0.2.10 lan0 192.0.2.0/24)"
  assert_eq "$(decision_field ACTION "$out")" "mismatch"
  assert_contains "$out" "recovery mode"
'

# =========================================================================
echo "== durable state hardening (never sourced/evaluated; fixed schema) =="

run_case "state: symlinked state file -> refuse" "$LIB" '
  setup_env
  mkdir -p "$LAN_UFW_STATE_DIR"
  printf "x\n" > "$D/real"
  ln -s "$D/real" "$LAN_UFW_STATE_FILE"
  expect_die "symlink or not a regular file" read_and_validate_state
'

run_case "state: non-regular state file (directory) -> refuse" "$LIB" '
  setup_env
  mkdir -p "$LAN_UFW_STATE_DIR" "$LAN_UFW_STATE_FILE"
  expect_die "symlink or not a regular file" read_and_validate_state
'

run_case "state: symlinked state directory -> refuse" "$LIB" '
  setup_env
  mkdir -p "$D/realdir"
  mkdir -p "$(dirname "$LAN_UFW_STATE_DIR")"
  ln -s "$D/realdir" "$LAN_UFW_STATE_DIR"
  expect_die "symlink or not a directory" read_and_validate_state
'

run_case "state: missing key -> refuse" "$LIB" '
  setup_env
  mkdir -p "$LAN_UFW_STATE_DIR"
  printf "%s\n" "PHASE=installed" "HOST_LAN_IP=192.0.2.10" "LAN_SUBNET=192.0.2.0/24" "LAN_INTERFACE=lan0" "UDP_COMMENT=homelab-platform:dnsmasq-lan-ufw udp/53" > "$LAN_UFW_STATE_FILE"
  expect_die "missing required key" read_and_validate_state
'

run_case "state: duplicate key -> refuse" "$LIB" '
  setup_env
  seed_installed
  printf "PHASE=installed\n" >> "$LAN_UFW_STATE_FILE"
  expect_die "duplicate key" read_and_validate_state
'

run_case "state: unknown key -> refuse" "$LIB" '
  setup_env
  seed_installed
  printf "EXTRA=1\n" >> "$LAN_UFW_STATE_FILE"
  expect_die "unknown key" read_and_validate_state
'

run_case "state: not KEY=VALUE line -> refuse" "$LIB" '
  setup_env
  mkdir -p "$LAN_UFW_STATE_DIR"
  printf "%s\n" "phase=installed" "HOST_LAN_IP=192.0.2.10" "LAN_SUBNET=192.0.2.0/24" "LAN_INTERFACE=lan0" "UDP_COMMENT=homelab-platform:dnsmasq-lan-ufw udp/53" "TCP_COMMENT=homelab-platform:dnsmasq-lan-ufw tcp/53" > "$LAN_UFW_STATE_FILE"
  expect_die "not KEY=VALUE" read_and_validate_state
'

run_case "state: control character in a value -> refuse" "$LIB" '
  setup_env
  mkdir -p "$LAN_UFW_STATE_DIR"
  printf "PHASE=inst\x01alled\nHOST_LAN_IP=192.0.2.10\nLAN_SUBNET=192.0.2.0/24\nLAN_INTERFACE=lan0\nUDP_COMMENT=homelab-platform:dnsmasq-lan-ufw udp/53\nTCP_COMMENT=homelab-platform:dnsmasq-lan-ufw tcp/53\n" > "$LAN_UFW_STATE_FILE"
  expect_die "control character" read_and_validate_state
'

run_case "state: invalid PHASE -> refuse" "$LIB" '
  setup_env
  seed_installed
  sed -i "s/^PHASE=installed/PHASE=bogus/" "$LAN_UFW_STATE_FILE"
  expect_die "invalid PHASE" read_and_validate_state
'

run_case "state: non-canonical LAN_SUBNET -> refuse" "$LIB" '
  setup_env
  seed_installed
  sed -i "s#^LAN_SUBNET=.*#LAN_SUBNET=192.0.2.7/24#" "$LAN_UFW_STATE_FILE"
  expect_die "canonical network address" read_and_validate_state
'

run_case "state: /31 LAN_SUBNET -> refuse" "$LIB" '
  setup_env
  seed_installed
  sed -i "s#^LAN_SUBNET=.*#LAN_SUBNET=192.0.2.0/31#" "$LAN_UFW_STATE_FILE"
  expect_die "point-to-point / single-host prefix" read_and_validate_state
'

run_case "state: malformed LAN_INTERFACE -> refuse" "$LIB" '
  setup_env
  seed_installed
  sed -i "s#^LAN_INTERFACE=.*#LAN_INTERFACE=bad/iface#" "$LAN_UFW_STATE_FILE"
  expect_die "not a valid network interface name" read_and_validate_state
'

run_case "state: persisted UDP_COMMENT != code constant -> refuse" "$LIB" '
  setup_env
  seed_installed
  sed -i "s#^UDP_COMMENT=.*#UDP_COMMENT=attacker-supplied#" "$LAN_UFW_STATE_FILE"
  expect_die "does not equal the platform ownership constant" read_and_validate_state
'

run_case "state: value text is never executed" "$LIB" '
  setup_env
  mkdir -p "$LAN_UFW_STATE_DIR"
  printf "PHASE=installed\nHOST_LAN_IP=\$(touch %s/pwned)\nLAN_SUBNET=192.0.2.0/24\nLAN_INTERFACE=lan0\nUDP_COMMENT=homelab-platform:dnsmasq-lan-ufw udp/53\nTCP_COMMENT=homelab-platform:dnsmasq-lan-ufw tcp/53\n" "$D" > "$LAN_UFW_STATE_FILE"
  expect_die "HOST_LAN_IP" read_and_validate_state
  [[ -e "$D/pwned" ]] && { echo "state file contents were executed!"; exit 90; }
  true
'

run_case "state: strict root perms enforced under root -> refuse on wrong owner" "$LIB" '
  setup_env
  seed_installed
  LAN_UFW_STATE_STRICT_PERMS=1
  is_root() { return 0; }
  stat() { printf "someuser someuser 644\n"; }
  expect_die "unsafe ownership/permissions" read_and_validate_state
'

run_case "state: strict root perms pass for root:root 0700/0600" "$LIB" '
  setup_env
  seed_installed
  LAN_UFW_STATE_STRICT_PERMS=1
  is_root() { return 0; }
  stat() { if [[ "${4:-}" == "$LAN_UFW_STATE_DIR" ]]; then printf "root root 700\n"; else printf "root root 600\n"; fi; }
  read_and_validate_state
  assert_eq "$ST_PHASE" "installed"
  assert_eq "$ST_LAN_SUBNET" "192.0.2.0/24"
'

# =========================================================================
echo "== install: happy path =="

run_case "install: clean baseline -> persists state, adds exactly the two commented rules, PHASE flips to installed" "$INSTALL" '
  setup_env
  run_main main
  ((RC == 0)) || { echo "rc=$RC: $OUT"; exit 90; }
  grep -q "^PHASE=installed\$" "$LAN_UFW_STATE_FILE" || { echo "state not installed"; exit 90; }
  grep -q "^HOST_LAN_IP=192.0.2.10\$" "$LAN_UFW_STATE_FILE"
  grep -q "^LAN_SUBNET=192.0.2.0/24\$" "$LAN_UFW_STATE_FILE"
  grep -q "^LAN_INTERFACE=lan0\$" "$LAN_UFW_STATE_FILE"
  assert_eq "$(grep -c "^ADD allow in on lan0 " "$UFW_CALLS")" "2"
  grep -q "proto udp comment homelab-platform:dnsmasq-lan-ufw udp/53" "$UFW_CALLS"
  grep -q "proto tcp comment homelab-platform:dnsmasq-lan-ufw tcp/53" "$UFW_CALLS"
  grep -q "^DEL " "$UFW_CALLS" && { echo "no delete expected on happy path"; exit 90; }
  assert_eq "$(owned_rule_count "$(mk_snap)" udp 192.0.2.10 lan0 192.0.2.0/24)" "1"
  assert_eq "$(owned_rule_count "$(mk_snap)" tcp 192.0.2.10 lan0 192.0.2.0/24)" "1"
  assert_not_contains "$(ufw_status_dump)" "Anywhere"
  [[ -d "$PLATFORM_STATE_ROOT" ]] || { echo "state root must exist"; exit 90; }
  true
'

run_case "install: exact applied state -> noop, no mutation" "$INSTALL" '
  setup_env
  seed_installed
  run_main main
  ((RC == 0)) || { echo "rc=$RC: $OUT"; exit 90; }
  assert_contains "$OUT" "No changes made"
  [[ -s "$UFW_CALLS" ]] && { echo "no ufw call expected on noop"; exit 90; }
  true
'

run_case "install: interrupted prior install recorded -> mismatch, points at recovery" "$INSTALL" '
  setup_env
  seed_installing
  expect_die "interrupted prior install" main
  [[ -s "$UFW_CALLS" ]] && { echo "no ufw mutation expected"; exit 90; }
  true
'

run_case "install: a pre-existing foreign DNS rule and no state -> mismatch, refuse to adopt" "$INSTALL" '
  setup_env
  ufw_status_set "$(_mk_foreign_dns_line)"
  expect_die "foreign or pre-existing" main
  [[ -e "$LAN_UFW_STATE_DIR" ]] && { echo "no state should be written"; exit 90; }
  [[ -s "$UFW_CALLS" ]] && { echo "no ufw mutation expected"; exit 90; }
  true
'

# =========================================================================
echo "== install: transactional failure handling =="

run_case "install: UDP added, TCP add fails -> UDP removed by spec, state cleared, root kept, unrelated rule intact" "$INSTALL" '
  setup_env
  ufw_status_set "$(_mk_unrelated_line)"
  FAKE_UFW_ADD_TCP_RC=1
  run_main main
  ((RC != 0)) || { echo "expected failure"; exit 90; }
  assert_contains "$OUT" "rolled back"
  grep -q "^DEL allow in on lan0 .* proto udp\$" "$UFW_CALLS" || { echo "udp not deleted by spec"; exit 90; }
  assert_eq "$(owned_rule_count "$(mk_snap)" udp 192.0.2.10 lan0 192.0.2.0/24)" "0"
  [[ -e "$LAN_UFW_STATE_FILE" ]] && { echo "recovery state should be cleared when cleanup is provable"; exit 90; }
  [[ -e "$LAN_UFW_STATE_DIR" ]] && { echo "component state dir should be removed"; exit 90; }
  [[ -d "$PLATFORM_STATE_ROOT" ]] || { echo "shared state root must NOT be removed"; exit 90; }
  assert_contains "$(ufw_status_dump)" "22/tcp"
  true
'

run_case "install: cleanup cannot be proven -> MANUAL RECOVERY REQUIRED, state preserved at PHASE=installing" "$INSTALL" '
  setup_env
  FAKE_UFW_ADD_TCP_RC=1
  FAKE_UFW_DEL_RC=1
  run_main main
  ((RC != 0)) || { echo "expected failure"; exit 90; }
  assert_contains "$OUT" "MANUAL RECOVERY REQUIRED"
  assert_contains "$OUT" "ufw delete allow in on lan0 from 192.0.2.0/24 to 192.0.2.10 port 53 proto udp"
  grep -q "^PHASE=installing\$" "$LAN_UFW_STATE_FILE" || { echo "recovery state must be preserved at PHASE=installing"; exit 90; }
  [[ -d "$PLATFORM_STATE_ROOT" ]] || { echo "shared state root must NOT be removed"; exit 90; }
  true
'

run_case "install: first (UDP) add fails with NO side effect -> reconcile-on-attempt runs, finds 0 owned, state cleared, root kept" "$INSTALL" '
  setup_env
  FAKE_UFW_ADD_RC=1
  run_main main
  ((RC != 0)) || { echo "expected failure"; exit 90; }
  assert_contains "$OUT" "rolled back"
  grep -q "^DEL " "$UFW_CALLS" && { echo "no delete expected when the failed add had no side effect"; exit 90; }
  assert_eq "$(owned_rule_count "$(mk_snap)" udp 192.0.2.10 lan0 192.0.2.0/24)" "0"
  [[ -e "$LAN_UFW_STATE_DIR" ]] && { echo "state dir should be removed"; exit 90; }
  [[ -d "$PLATFORM_STATE_ROOT" ]] || { echo "shared state root must NOT be removed"; exit 90; }
  true
'

# =========================================================================
echo "== install: mutating-command-applied-then-returned-non-zero (attempt != success) =="

run_case "A: first UDP add APPLIES the exact owned rule but returns non-zero -> cleanup discovers & removes it by spec, state cleared, root kept, unrelated intact" "$INSTALL" '
  setup_env
  ufw_status_set "$(_mk_unrelated_line)"
  FAKE_UFW_ADD_RC=1              # `ufw allow` returns non-zero ...
  FAKE_UFW_UDP_APPLY_ON_FAIL=true   # ... but it already applied the rule
  run_main main
  ((RC != 0)) || { echo "install must exit non-zero"; exit 90; }
  assert_contains "$OUT" "rolled back"
  grep -q "^DEL allow in on lan0 from 192.0.2.0/24 to 192.0.2.10 port 53 proto udp\$" "$UFW_CALLS" \
    || { echo "cleanup must remove the live UDP rule by stable spec even though UDP success was never recorded"; exit 90; }
  assert_eq "$(owned_rule_count "$(mk_snap)" udp 192.0.2.10 lan0 192.0.2.0/24)" "0"
  assert_eq "$(owned_rule_count "$(mk_snap)" tcp 192.0.2.10 lan0 192.0.2.0/24)" "0"
  [[ -e "$LAN_UFW_STATE_FILE" ]] && { echo "state must be cleared when cleanup is provably clean"; exit 90; }
  [[ -e "$LAN_UFW_STATE_DIR" ]] && { echo "component dir must be removed"; exit 90; }
  [[ -d "$PLATFORM_STATE_ROOT" ]] || { echo "shared state root must NOT be removed"; exit 90; }
  assert_contains "$(ufw_status_dump)" "22/tcp"
  true
'

run_case "B: UDP add applies + returns non-zero AND cleanup deletion fails -> MANUAL RECOVERY REQUIRED, state.env stays PHASE=installing" "$INSTALL" '
  setup_env
  FAKE_UFW_ADD_RC=1
  FAKE_UFW_UDP_APPLY_ON_FAIL=true
  FAKE_UFW_DEL_RC=1             # cleanup cannot remove the live rule
  run_main main
  ((RC != 0)) || { echo "install must exit non-zero"; exit 90; }
  assert_contains "$OUT" "MANUAL RECOVERY REQUIRED"
  assert_contains "$OUT" "ufw delete allow in on lan0 from 192.0.2.0/24 to 192.0.2.10 port 53 proto udp"
  grep -q "^PHASE=installing\$" "$LAN_UFW_STATE_FILE" || { echo "recovery state must remain at PHASE=installing"; exit 90; }
  [[ -e "$LAN_UFW_STATE_DIR" ]] || { echo "component state dir must NOT be cleared"; exit 90; }
  [[ -d "$PLATFORM_STATE_ROOT" ]] || { echo "shared state root must NOT be removed"; exit 90; }
  true
'

run_case "C: UDP succeeds, then TCP add applies its rule but returns non-zero -> cleanup removes BOTH owned rules, state cleared only after proof, unrelated fingerprint unchanged" "$INSTALL" '
  setup_env
  ufw_status_set "$(_mk_unrelated_line)"
  FAKE_UFW_ADD_TCP_RC=1
  FAKE_UFW_TCP_APPLY_ON_FAIL=true
  run_main main
  ((RC != 0)) || { echo "install must exit non-zero"; exit 90; }
  assert_contains "$OUT" "rolled back"
  grep -q "^DEL allow in on lan0 .* proto udp\$" "$UFW_CALLS" || { echo "UDP must be removed by spec"; exit 90; }
  grep -q "^DEL allow in on lan0 .* proto tcp\$" "$UFW_CALLS" || { echo "TCP must be removed by spec"; exit 90; }
  assert_eq "$(owned_rule_count "$(mk_snap)" udp 192.0.2.10 lan0 192.0.2.0/24)" "0"
  assert_eq "$(owned_rule_count "$(mk_snap)" tcp 192.0.2.10 lan0 192.0.2.0/24)" "0"
  [[ -e "$LAN_UFW_STATE_DIR" ]] && { echo "state must be cleared after proof"; exit 90; }
  [[ -d "$PLATFORM_STATE_ROOT" ]] || { echo "shared state root must NOT be removed"; exit 90; }
  assert_contains "$(ufw_status_dump)" "22/tcp"
  true
'

run_case "diagnostics: an attempted protocol is listed as \"if still present\" even when its ufw allow returned non-zero" "$INSTALL" '
  setup_env
  FAKE_UFW_ADD_RC=1
  FAKE_UFW_UDP_APPLY_ON_FAIL=true
  FAKE_UFW_DEL_RC=1
  run_main main
  # UDP was attempted (and applied); the outstanding-delete hint must name it.
  assert_contains "$OUT" "proto udp"
  # TCP add was never reached (udp add returned non-zero) -> not attempted -> not listed.
  assert_not_contains "$OUT" "proto tcp"
  true
'

# =========================================================================
echo "== rollback: PHASE=installed =="

run_case "rollback installed: removes exactly the two owned rules by spec, keeps unrelated, clears state, keeps root" "$ROLLBACK" '
  setup_env
  seed_installed
  ufw_status_add "$(_mk_unrelated_line)"
  run_main main
  ((RC == 0)) || { echo "rc=$RC: $OUT"; exit 90; }
  assert_eq "$(owned_rule_count "$(mk_snap)" udp 192.0.2.10 lan0 192.0.2.0/24)" "0"
  assert_eq "$(owned_rule_count "$(mk_snap)" tcp 192.0.2.10 lan0 192.0.2.0/24)" "0"
  assert_contains "$(ufw_status_dump)" "22/tcp"
  assert_eq "$(grep -c "^DEL " "$UFW_CALLS")" "2"
  grep -q "^DEL allow in on lan0 .* proto udp\$" "$UFW_CALLS"
  grep -q "^DEL allow in on lan0 .* proto tcp\$" "$UFW_CALLS"
  [[ -e "$LAN_UFW_STATE_DIR" ]] && { echo "component state must be cleared"; exit 90; }
  [[ -d "$PLATFORM_STATE_ROOT" ]] || { echo "shared state root must NOT be removed"; exit 90; }
  true
'

run_case "rollback installed: one owned rule missing -> refuse before any delete" "$ROLLBACK" '
  setup_env
  seed_installed
  ufw_status_set "$(_mk_owned_line udp)"
  expect_die "expected exactly the two platform-owned DNS rules" main
  grep -q "^DEL " "$UFW_CALLS" && { echo "nothing should be deleted"; exit 90; }
  [[ -f "$LAN_UFW_STATE_FILE" ]] || { echo "state must remain"; exit 90; }
  true
'

run_case "rollback: no state at all -> refuse" "$ROLLBACK" '
  setup_env
  expect_die "nothing to roll back" main
'

run_case "rollback installed: a foreign :53 rule appeared -> refuse before any delete" "$ROLLBACK" '
  setup_env
  seed_installed
  ufw_status_add "$(_mk_foreign_dns_line)"
  expect_die "foreign or drifted DNS firewall rule is present" main
  grep -q "^DEL " "$UFW_CALLS" && { echo "nothing should be deleted"; exit 90; }
  true
'

run_case "rollback installed: an owned comment on a changed tuple -> treated as drift, refuse" "$ROLLBACK" '
  setup_env
  seed_state installed
  ufw_status_set "$(_mk_owned_line udp)" "$(_mk_owned_line_wrongsubnet tcp)"
  expect_die "foreign or drifted DNS firewall rule is present" main
  grep -q "^DEL " "$UFW_CALLS" && { echo "nothing should be deleted"; exit 90; }
  true
'

# =========================================================================
echo "== rollback: PHASE=installing (recovery mode) =="

run_case "recovery: two exact owned rules -> both removed, state cleared" "$ROLLBACK" '
  setup_env
  seed_installing
  ufw_status_add "$(_mk_unrelated_line)"
  run_main main
  ((RC == 0)) || { echo "rc=$RC: $OUT"; exit 90; }
  assert_contains "$OUT" "Recovery rollback complete"
  assert_eq "$(grep -c "^DEL " "$UFW_CALLS")" "2"
  assert_eq "$(owned_rule_count "$(mk_snap)" udp 192.0.2.10 lan0 192.0.2.0/24)" "0"
  assert_eq "$(owned_rule_count "$(mk_snap)" tcp 192.0.2.10 lan0 192.0.2.0/24)" "0"
  assert_contains "$(ufw_status_dump)" "22/tcp"
  [[ -e "$LAN_UFW_STATE_DIR" ]] && { echo "recovery state must be cleared"; exit 90; }
  [[ -d "$PLATFORM_STATE_ROOT" ]] || { echo "shared state root must NOT be removed"; exit 90; }
  true
'

run_case "recovery: exactly one owned rule remains -> that one removed, state cleared" "$ROLLBACK" '
  setup_env
  seed_installing
  ufw_status_set "$(_mk_owned_line udp)"
  run_main main
  ((RC == 0)) || { echo "rc=$RC: $OUT"; exit 90; }
  assert_eq "$(grep -c "^DEL " "$UFW_CALLS")" "1"
  grep -q "^DEL allow in on lan0 .* proto udp\$" "$UFW_CALLS"
  assert_eq "$(owned_rule_count "$(mk_snap)" udp 192.0.2.10 lan0 192.0.2.0/24)" "0"
  [[ -e "$LAN_UFW_STATE_DIR" ]] && { echo "recovery state must be cleared"; exit 90; }
  true
'

run_case "recovery: zero owned rules remain -> no delete, recovery state cleared" "$ROLLBACK" '
  setup_env
  seed_installing
  ufw_status_set "$(_mk_unrelated_line)"
  run_main main
  ((RC == 0)) || { echo "rc=$RC: $OUT"; exit 90; }
  assert_contains "$OUT" "no platform-owned DNS rule was present"
  grep -q "^DEL " "$UFW_CALLS" && { echo "no delete expected"; exit 90; }
  assert_contains "$(ufw_status_dump)" "22/tcp"
  [[ -e "$LAN_UFW_STATE_DIR" ]] && { echo "recovery state must be cleared"; exit 90; }
  [[ -d "$PLATFORM_STATE_ROOT" ]] || { echo "shared state root must NOT be removed"; exit 90; }
  true
'

run_case "recovery: a foreign/drifted rule present -> refuse, recovery state preserved" "$ROLLBACK" '
  setup_env
  seed_installing
  ufw_status_set "$(_mk_owned_line udp)" "$(_mk_foreign_dns_line)"
  expect_die "refusing recovery rollback: a foreign or drifted DNS firewall rule is present" main
  grep -q "^DEL " "$UFW_CALLS" && { echo "nothing should be deleted"; exit 90; }
  [[ -f "$LAN_UFW_STATE_FILE" ]] || { echo "recovery state must be preserved"; exit 90; }
  true
'

run_case "recovery: a duplicated owned tuple -> refuse" "$ROLLBACK" '
  setup_env
  seed_installing
  ufw_status_set "$(_mk_owned_line udp)" "$(_mk_owned_line udp)"
  expect_die "an owned DNS rule tuple is duplicated" main
  grep -q "^DEL " "$UFW_CALLS" && { echo "nothing should be deleted"; exit 90; }
  true
'

# =========================================================================
echo "== rollback: PHASE=rolling_back state machine (Fix #1) =="

run_case "state: read_and_validate_state accepts PHASE=rolling_back" "$LIB" '
  setup_env
  seed_rolling_back
  read_and_validate_state
  assert_eq "$ST_PHASE" "rolling_back"
'

run_case "classify install: PHASE=rolling_back recorded -> mismatch pointing at finishing rollback" "$LIB" '
  setup_env
  seed_rolling_back
  out="$(classify_state 192.0.2.10 lan0 192.0.2.0/24)"
  assert_eq "$(decision_field ACTION "$out")" "mismatch"
  assert_contains "$out" "interrupted rollback"
'

run_case "BLOCKER regression: installed rollback, UDP delete ok + TCP delete fails -> PHASE=rolling_back, resumable; second run finishes" "$ROLLBACK" '
  setup_env
  seed_installed
  ufw_status_add "$(_mk_unrelated_line)"
  FAKE_UFW_DEL_TCP_RC=1
  run_main main
  ((RC != 0)) || { echo "expected first run to fail"; exit 90; }
  assert_contains "$OUT" "MANUAL RECOVERY REQUIRED"
  grep -q "^PHASE=rolling_back\$" "$LAN_UFW_STATE_FILE" || { echo "state must be preserved at PHASE=rolling_back"; exit 90; }
  assert_eq "$(owned_rule_count "$(mk_snap)" udp 192.0.2.10 lan0 192.0.2.0/24)" "0"
  assert_eq "$(owned_rule_count "$(mk_snap)" tcp 192.0.2.10 lan0 192.0.2.0/24)" "1"
  # second invocation: TCP delete now succeeds -> recovery finishes cleanly
  FAKE_UFW_DEL_TCP_RC=""
  run_main main
  ((RC == 0)) || { echo "resume run failed rc=$RC: $OUT"; exit 90; }
  assert_eq "$(owned_rule_count "$(mk_snap)" tcp 192.0.2.10 lan0 192.0.2.0/24)" "0"
  [[ -e "$LAN_UFW_STATE_DIR" ]] && { echo "state must be cleared after resume"; exit 90; }
  [[ -d "$PLATFORM_STATE_ROOT" ]] || { echo "shared root must remain"; exit 90; }
  assert_contains "$(ufw_status_dump)" "22/tcp"
  true
'

run_case "recovery: PHASE=rolling_back with two owned rules -> both removed, state cleared" "$ROLLBACK" '
  setup_env
  seed_rolling_back
  ufw_status_add "$(_mk_unrelated_line)"
  run_main main
  ((RC == 0)) || { echo "rc=$RC: $OUT"; exit 90; }
  assert_eq "$(grep -c "^DEL " "$UFW_CALLS")" "2"
  assert_eq "$(owned_rule_count "$(mk_snap)" udp 192.0.2.10 lan0 192.0.2.0/24)" "0"
  assert_eq "$(owned_rule_count "$(mk_snap)" tcp 192.0.2.10 lan0 192.0.2.0/24)" "0"
  assert_contains "$(ufw_status_dump)" "22/tcp"
  [[ -e "$LAN_UFW_STATE_DIR" ]] && { echo "state must be cleared"; exit 90; }
  true
'

run_case "recovery: PHASE=rolling_back, a delete fails -> preserved at PHASE=rolling_back" "$ROLLBACK" '
  setup_env
  seed_rolling_back
  FAKE_UFW_DEL_TCP_RC=1
  expect_die "MANUAL RECOVERY REQUIRED" main
  grep -q "^PHASE=rolling_back\$" "$LAN_UFW_STATE_FILE" || { echo "must stay at PHASE=rolling_back"; exit 90; }
  true
'

# =========================================================================
echo "== fail-closed UFW snapshots (Fix #2) =="

run_case "install: initial active check ok but a later ufw status read fails -> die, NOT a clean baseline, no mutation" "$INSTALL" '
  setup_env
  FAKE_UFW_STATUS_FAIL_FROM=2
  expect_die "valid live UFW snapshot for classification" main
  [[ -e "$LAN_UFW_STATE_DIR" ]] && { echo "no state should be written"; exit 90; }
  [[ -s "$UFW_CALLS" ]] && { echo "no ufw mutation expected"; exit 90; }
  true
'

run_case "install: a later snapshot reports inactive -> die, no mutation" "$INSTALL" '
  setup_env
  FAKE_UFW_STATUS_INACTIVE_FROM=2
  expect_die "valid live UFW snapshot for classification" main
  [[ -e "$LAN_UFW_STATE_DIR" ]] && { echo "no state should be written"; exit 90; }
  [[ -s "$UFW_CALLS" ]] && { echo "no ufw mutation expected"; exit 90; }
  true
'

run_case "install: post-mutation snapshot fails -> transactional cleanup, not silently accepted" "$INSTALL" '
  setup_env
  # calls: 1=ufw_is_active 2=classify 3=PRE_FP 4=post-verify (fail here)
  FAKE_UFW_STATUS_FAIL_FROM=4
  run_main main
  ((RC != 0)) || { echo "expected failure"; exit 90; }
  assert_contains "$OUT" "post-install check failed"
  true
'

run_case "rollback installed: a later ufw status read fails -> die, nothing removed, state kept" "$ROLLBACK" '
  setup_env
  seed_installed
  FAKE_UFW_STATUS_FAIL_FROM=2
  expect_die "cannot capture a valid live UFW snapshot" main
  grep -q "^DEL " "$UFW_CALLS" && { echo "nothing should be deleted"; exit 90; }
  grep -q "^PHASE=installed\$" "$LAN_UFW_STATE_FILE" || { echo "state must be untouched"; exit 90; }
  true
'

run_case "rollback recovery: a later snapshot fails -> die, recovery state kept, not cleared" "$ROLLBACK" '
  setup_env
  seed_installing
  FAKE_UFW_STATUS_FAIL_FROM=2
  expect_die "cannot capture a valid live UFW snapshot" main
  [[ -f "$LAN_UFW_STATE_FILE" ]] || { echo "recovery state must be kept"; exit 90; }
  grep -q "^DEL " "$UFW_CALLS" && { echo "nothing should be deleted"; exit 90; }
  true
'

run_case "classify_state: a failed ufw status is never a clean baseline" "$LIB" '
  setup_env
  FAKE_UFW_STATUS_FAIL_FROM=1
  expect_die "is never treated as a clean baseline" classify_state 192.0.2.10 lan0 192.0.2.0/24
'

# =========================================================================
echo "== install: cleanup armed before first durable state write (Fix #3) =="

run_case "install: initial state write fails -> component dir removed, no ufw mutation, next clean run is not wedged" "$INSTALL" '
  setup_env
  mv() {
    if [[ "$*" == *"/dnsmasq-lan-ufw/state.env" && -f "$D/mvfail" ]]; then rm -f "$D/mvfail"; return 1; fi
    builtin command mv "$@"
  }
  : > "$D/mvfail"
  run_main main
  ((RC != 0)) || { echo "expected failure"; exit 90; }
  [[ -s "$UFW_CALLS" ]] && { echo "no ufw mutation must have happened"; exit 90; }
  [[ -e "$LAN_UFW_STATE_DIR" ]] && { echo "component dir created by this run must be removed"; exit 90; }
  [[ -e "$LAN_UFW_STATE_FILE" ]] && { echo "no malformed state may remain"; exit 90; }
  [[ -d "$PLATFORM_STATE_ROOT" ]] || { echo "shared root must remain"; exit 90; }
  # not wedged:
  run_main main
  ((RC == 0)) || { echo "next clean run was wedged rc=$RC: $OUT"; exit 90; }
  grep -q "^PHASE=installed\$" "$LAN_UFW_STATE_FILE" || { echo "clean run should reach PHASE=installed"; exit 90; }
  true
'

# =========================================================================
echo "== foreign port-53 expression detection (Fix #4) =="

run_case "line_is_dns_rule: matches every numeric form that includes port 53" "$LIB" '
  assert_ok line_is_dns_rule "53                         ALLOW       Anywhere"
  assert_ok line_is_dns_rule "53/udp                     ALLOW       Anywhere"
  assert_ok line_is_dns_rule "53/tcp                     ALLOW       Anywhere"
  assert_ok line_is_dns_rule "53 (v6)                    ALLOW       Anywhere (v6)"
  assert_ok line_is_dns_rule "53:60/udp                  ALLOW       Anywhere"
  assert_ok line_is_dns_rule "50:53/tcp                  ALLOW       Anywhere"
  assert_ok line_is_dns_rule "53,67/udp                  ALLOW       Anywhere"
  # documented dest-specific interface rule shape:
  assert_ok line_is_dns_rule "192.0.2.10 53/udp on lan0          ALLOW       192.0.2.0/24"
'

run_case "line_is_dns_rule: does not match unrelated ports" "$LIB" '
  assert_not_ok line_is_dns_rule "5353/udp                   ALLOW       Anywhere"
  assert_not_ok line_is_dns_rule "22/tcp                     ALLOW       Anywhere"
  assert_not_ok line_is_dns_rule "80,443/tcp                 ALLOW       Anywhere"
  assert_not_ok line_is_dns_rule "1024:2000/udp              ALLOW       Anywhere"
  assert_not_ok line_is_dns_rule "192.0.2.0/24               ALLOW       Anywhere"
'

run_case "classify: a foreign 53:60/udp range rule with no state -> mismatch" "$LIB" '
  setup_env
  ufw_status_set "53:60/udp                  ALLOW       Anywhere"
  out="$(classify_state 192.0.2.10 lan0 192.0.2.0/24)"
  assert_eq "$(decision_field ACTION "$out")" "mismatch"
  assert_contains "$out" "foreign or pre-existing"
'

run_case "rollback installed: a foreign 53,67/udp list rule appeared -> refuse before any delete" "$ROLLBACK" '
  setup_env
  seed_installed
  ufw_status_add "53,67/udp                  ALLOW       Anywhere"
  expect_die "foreign or drifted DNS firewall rule is present" main
  grep -q "^DEL " "$UFW_CALLS" && { echo "nothing should be deleted"; exit 90; }
  true
'

# =========================================================================
echo "== real plain-UFW status shape: bare ALLOW (host preflight regression) =="

run_case "plain ALLOW: an owned rule row is recognized as owned (count==1, not foreign, fingerprint excludes it)" "$LIB" '
  setup_env
  ufw_status_set "$UDP_PLAIN" "$TCP_PLAIN"
  s="$(mk_snap)"
  assert_eq "$(owned_rule_count "$s" udp 192.0.2.10 lan0 192.0.2.0/24)" "1"
  assert_eq "$(owned_rule_count "$s" tcp 192.0.2.10 lan0 192.0.2.0/24)" "1"
  assert_eq "$(list_foreign_dns_rules "$s" 192.0.2.10 lan0 192.0.2.0/24)" ""
  assert_eq "$(ufw_fingerprint_excluding_owned "$s" 192.0.2.10 lan0 192.0.2.0/24)" ""
'

run_case "plain ALLOW: PHASE=installed with the real-shape rows classifies as noop" "$LIB" '
  setup_env
  seed_state installed
  ufw_status_set "$UDP_PLAIN" "$TCP_PLAIN"
  out="$(classify_state 192.0.2.10 lan0 192.0.2.0/24)"
  assert_eq "$(decision_field ACTION "$out")" "noop"
'

run_case "ALLOW IN: numbered-style rows are still recognized as owned (both representations accepted)" "$LIB" '
  setup_env
  seed_state installed
  ufw_status_set "$(_mk_owned_line_allowin udp)" "$(_mk_owned_line_allowin tcp)"
  s="$(mk_snap)"
  assert_eq "$(owned_rule_count "$s" udp 192.0.2.10 lan0 192.0.2.0/24)" "1"
  assert_eq "$(owned_rule_count "$s" tcp 192.0.2.10 lan0 192.0.2.0/24)" "1"
  assert_eq "$(list_foreign_dns_rules "$s" 192.0.2.10 lan0 192.0.2.0/24)" ""
  out="$(classify_state 192.0.2.10 lan0 192.0.2.0/24)"
  assert_eq "$(decision_field ACTION "$out")" "noop"
'

run_case "plain ALLOW: ownership still requires every field (wrong subnet / iface / proto / action / extra token -> not owned)" "$LIB" '
  # wrong source subnet
  assert_not_ok _tuple_is_owned_rule "192.0.2.10 53/udp on lan0 ALLOW 198.51.100.0/24" udp 192.0.2.10 lan0 192.0.2.0/24
  # wrong interface
  assert_not_ok _tuple_is_owned_rule "192.0.2.10 53/udp on br0 ALLOW 192.0.2.0/24" udp 192.0.2.10 lan0 192.0.2.0/24
  # wrong dest ip
  assert_not_ok _tuple_is_owned_rule "203.0.113.9 53/udp on lan0 ALLOW 192.0.2.0/24" udp 192.0.2.10 lan0 192.0.2.0/24
  # wrong proto
  assert_not_ok _tuple_is_owned_rule "192.0.2.10 53/tcp on lan0 ALLOW 192.0.2.0/24" udp 192.0.2.10 lan0 192.0.2.0/24
  # DENY instead of ALLOW
  assert_not_ok _tuple_is_owned_rule "192.0.2.10 53/udp on lan0 DENY 192.0.2.0/24" udp 192.0.2.10 lan0 192.0.2.0/24
  # trailing extra token
  assert_not_ok _tuple_is_owned_rule "192.0.2.10 53/udp on lan0 ALLOW 192.0.2.0/24 extra" udp 192.0.2.10 lan0 192.0.2.0/24
  # accepted: bare ALLOW and ALLOW IN
  assert_ok _tuple_is_owned_rule "192.0.2.10 53/udp on lan0 ALLOW 192.0.2.0/24" udp 192.0.2.10 lan0 192.0.2.0/24
  assert_ok _tuple_is_owned_rule "192.0.2.10 53/udp on lan0 ALLOW IN 192.0.2.0/24" udp 192.0.2.10 lan0 192.0.2.0/24
'

run_case "plain ALLOW: a drifted row carrying our comment on a wrong tuple is still foreign" "$LIB" '
  setup_env
  seed_state installed
  ufw_status_set "$UDP_PLAIN" "$(_mk_owned_line_wrongsubnet tcp)"
  s="$(mk_snap)"
  assert_eq "$(owned_rule_count "$s" tcp 192.0.2.10 lan0 192.0.2.0/24)" "0"
  [[ -n "$(list_foreign_dns_rules "$s" 192.0.2.10 lan0 192.0.2.0/24)" ]] || { echo "the drifted tcp row must be foreign"; exit 90; }
  true
'

# =========================================================================
echo "== locale independence =="

run_case "parsing is locale-deterministic (LC_ALL forced to C on ufw/ip reads and sort)" "$LIB" '
  setup_env
  seed_installed
  export LC_ALL=tr_TR.UTF-8 LANG=tr_TR.UTF-8
  assert_eq "$(discover_lan_interface 192.0.2.10)" "lan0 24 192.0.2.0/24"
  assert_eq "$(owned_rule_count "$(mk_snap)" udp 192.0.2.10 lan0 192.0.2.0/24)" "1"
  out="$(classify_state 192.0.2.10 lan0 192.0.2.0/24)"
  assert_eq "$(decision_field ACTION "$out")" "noop"
'

# =========================================================================
echo
echo "== summary =="
echo "$PASSED passed, $FAILED failed"
if ((FAILED > 0)); then
  echo "Failed cases:"
  printf '  - %s\n' "${FAILED_NAMES[@]}"
  exit 1
fi

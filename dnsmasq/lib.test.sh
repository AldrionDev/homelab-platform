#!/usr/bin/env bash
#
# Tests for dnsmasq/lib.sh.
#
# Plain bash, no test framework dependency. Run with:
#   bash dnsmasq/lib.test.sh
#
# Every case runs in a fresh `bash -c` that sources lib.sh, so `set -euo
# pipefail` is not forced on (lib.sh itself sets nothing — it's sourced-only)
# but each case controls its own failure handling explicitly via the assert
# helpers below. Collaborators (systemctl) are shadowed per case. No case
# requires root, systemd, or the real /etc or /var/lib paths.
#
# shellcheck disable=SC2016
# Test bodies are single-quoted on purpose: they must reach the case subshell
# unexpanded, and are evaluated there against the sourced library.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_UNDER_TEST="$SCRIPT_DIR/lib.sh"

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

FAKE_UNIT="dnsmasq-test-fake"
FAKE_LOADSTATE="loaded"
FAKE_ACTIVESTATE="inactive"
FAKE_FRAGMENTPATH=""
FAKE_DROPINPATHS=""
FAKE_ENABLED_RC=1

# Replaces the real systemctl for the fake unit only. Any query about a unit
# other than $FAKE_UNIT fails, so a real dnsmasq unit on the host can never
# leak into a test result.
systemctl() {
  case "$*" in
    "show $FAKE_UNIT --property=LoadState --value")    echo "$FAKE_LOADSTATE" ;;
    "show $FAKE_UNIT --property=ActiveState --value")  echo "$FAKE_ACTIVESTATE" ;;
    "show $FAKE_UNIT --property=FragmentPath --value") echo "$FAKE_FRAGMENTPATH" ;;
    "show $FAKE_UNIT --property=DropInPaths --value")  echo "$FAKE_DROPINPATHS" ;;
    "is-enabled --quiet $FAKE_UNIT")                   return "$FAKE_ENABLED_RC" ;;
    *) return 1 ;;
  esac
}
PRELUDE_EOF

run_case() {
  local name="$1" code="$2"
  local out rc=0
  out=$(bash -c "source \"\$1\"
$PRELUDE
$code" "dnsmasq-lib-test" "$LIB_UNDER_TEST" 2>&1) || rc=$?
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

echo "== validate_ipv4 =="

for good in "192.168.1.50" "10.0.0.1" "0.0.0.0" "255.255.255.255"; do
  run_case "validate_ipv4 accepts $good" "
    validate_ipv4 '$good'
  "
done

for bad in "999.999.999.999" "256.1.1.1" "192.168.1" "192.168.1.1.1" "homelab.home.arpa" "" "192.168.01.1" "192..1.1" "192.168.1.-5" "1.2.3.4a"; do
  run_case "validate_ipv4 rejects '$bad'" "
    expect_die 'HOST_LAN_IP' validate_ipv4 '$bad'
  "
done

run_case "SECURITY: validate_ipv4 rejects an embedded newline" '
  probe=$(printf "192.168.1.50\nExecStartPost=/bin/sh -c evil")
  expect_die "not a dotted-quad" validate_ipv4 "$probe"
'

echo "== validate_domain =="

for good in "homelab.home.arpa" "a.b" "example.com" "sub.example.co.uk" "xn--exampl-gva.com"; do
  run_case "validate_domain accepts $good" "
    validate_domain '$good'
  "
done

for bad in "" "homelab" "homelab." ".homelab.home.arpa" "homelab..home.arpa" "-homelab.home.arpa" "homelab-.home.arpa" "home lab.arpa"; do
  run_case "validate_domain rejects '$bad'" "
    expect_die 'HOMELAB_DOMAIN' validate_domain '$bad'
  "
done

run_case "validate_domain rejects a label over 63 chars" '
  long_label=$(printf "a%.0s" $(seq 1 64))
  expect_die "HOMELAB_DOMAIN" validate_domain "${long_label}.arpa"
'

run_case "validate_domain rejects a domain over 253 chars" '
  # 4 * 63-char labels + 3 dots = 255 chars, safely over the limit.
  label=$(printf "a%.0s" $(seq 1 63))
  domain="${label}.${label}.${label}.${label}"
  expect_die "253 characters" validate_domain "$domain"
'

run_case "SECURITY: validate_domain rejects an embedded newline" '
  probe=$(printf "homelab.home.arpa\naddress=/evil.com/1.2.3.4")
  expect_die "HOMELAB_DOMAIN" validate_domain "$probe"
'

echo "== atomic_write =="

run_case "atomic_write creates the target with the requested content and mode" '
  d=$(mktemp -d)
  atomic_write "$d/out" "hello" 0640
  assert_eq "$(cat "$d/out")" "hello"
  assert_eq "$(stat -c%a "$d/out")" "640"
'

run_case "atomic_write replaces existing content atomically" '
  d=$(mktemp -d)
  printf "old" > "$d/out"
  atomic_write "$d/out" "new" 0644
  assert_eq "$(cat "$d/out")" "new"
'

run_case "atomic_write never leaves a partial file when the rename fails" '
  d=$(mktemp -d)
  printf "old" > "$d/out"
  mv() { return 1; }
  expect_die "atomic_write" atomic_write "$d/out" "new" 0644
  assert_eq "$(cat "$d/out")" "old"
'

echo "== files_match =="

run_case "files_match true for identical content" '
  d=$(mktemp -d)
  printf "same" > "$d/a"
  printf "same" > "$d/b"
  assert_ok files_match "$d/a" "$d/b"
'

run_case "files_match false for differing content" '
  d=$(mktemp -d)
  printf "one" > "$d/a"
  printf "two" > "$d/b"
  assert_not_ok files_match "$d/a" "$d/b"
'

echo "== extract_base_execstart (no PCRE) =="

run_case "extract_base_execstart succeeds with exactly one ExecStart= line" '
  d=$(mktemp -d)
  cat > "$d/unit" <<UNIT
[Unit]
Description=fake
[Service]
ExecStart=/usr/bin/dnsmasq -k --enable-dbus --user=dnsmasq --pid-file
ExecStartPre=/usr/bin/dnsmasq --test
UNIT
  assert_eq "$(extract_base_execstart "$d/unit")" "/usr/bin/dnsmasq -k --enable-dbus --user=dnsmasq --pid-file"
'

run_case "extract_base_execstart fails closed with zero ExecStart= lines" '
  d=$(mktemp -d)
  printf "[Service]\nExecStartPre=/usr/bin/dnsmasq --test\n" > "$d/unit"
  expect_die "expected exactly one ExecStart=" extract_base_execstart "$d/unit"
'

run_case "extract_base_execstart fails closed with two ExecStart= lines" '
  d=$(mktemp -d)
  printf "[Service]\nExecStart=/bin/one\nExecStart=/bin/two\n" > "$d/unit"
  expect_die "expected exactly one ExecStart=" extract_base_execstart "$d/unit"
'

echo "== dropin_state =="

run_case "dropin_state reports none when DropInPaths is empty" '
  FAKE_DROPINPATHS=""
  assert_eq "$(dropin_state "$FAKE_UNIT" "/etc/systemd/system/dnsmasq.service.d/homelab.conf")" "none"
'

run_case "dropin_state reports own when DropInPaths is exactly the platform path" '
  FAKE_DROPINPATHS="/etc/systemd/system/dnsmasq.service.d/homelab.conf"
  assert_eq "$(dropin_state "$FAKE_UNIT" "/etc/systemd/system/dnsmasq.service.d/homelab.conf")" "own"
'

run_case "dropin_state reports foreign for any other path" '
  FAKE_DROPINPATHS="/etc/systemd/system/dnsmasq.service.d/99-other.conf"
  assert_eq "$(dropin_state "$FAKE_UNIT" "/etc/systemd/system/dnsmasq.service.d/homelab.conf")" "foreign"
'

echo "== unit_is_loaded / unit_is_active / unit_is_enabled =="

run_case "unit_is_loaded true when LoadState=loaded" '
  FAKE_LOADSTATE="loaded"
  assert_ok unit_is_loaded "$FAKE_UNIT"
'

run_case "unit_is_loaded false when LoadState=not-found" '
  FAKE_LOADSTATE="not-found"
  assert_not_ok unit_is_loaded "$FAKE_UNIT"
'

run_case "unit_is_active true when ActiveState=active" '
  FAKE_ACTIVESTATE="active"
  assert_ok unit_is_active "$FAKE_UNIT"
'

run_case "unit_is_active false when ActiveState=inactive" '
  FAKE_ACTIVESTATE="inactive"
  assert_not_ok unit_is_active "$FAKE_UNIT"
'

run_case "unit_is_enabled true when is-enabled succeeds" '
  FAKE_ENABLED_RC=0
  assert_ok unit_is_enabled "$FAKE_UNIT"
'

run_case "unit_is_enabled false when is-enabled fails" '
  FAKE_ENABLED_RC=1
  assert_not_ok unit_is_enabled "$FAKE_UNIT"
'

echo "== verify_baseline_disabled_inactive =="

run_case "verify_baseline_disabled_inactive passes when inactive and disabled" '
  FAKE_ACTIVESTATE="inactive"
  FAKE_ENABLED_RC=1
  assert_ok verify_baseline_disabled_inactive "$FAKE_UNIT"
'

run_case "verify_baseline_disabled_inactive fails when still active" '
  FAKE_ACTIVESTATE="active"
  FAKE_ENABLED_RC=1
  assert_not_ok verify_baseline_disabled_inactive "$FAKE_UNIT"
'

run_case "verify_baseline_disabled_inactive fails when still enabled" '
  FAKE_ACTIVESTATE="inactive"
  FAKE_ENABLED_RC=0
  assert_not_ok verify_baseline_disabled_inactive "$FAKE_UNIT"
'

echo "== created-dirs manifest =="

run_case "read_created_dirs returns nothing for an absent file" '
  d=$(mktemp -d)
  assert_eq "$(read_created_dirs "$d/created-dirs.list")" ""
'

run_case "append_created_dir then read_created_dirs round-trips one entry" '
  d=$(mktemp -d)
  append_created_dir "$d/created-dirs.list" "/etc/dnsmasq.d"
  assert_eq "$(read_created_dirs "$d/created-dirs.list")" "/etc/dnsmasq.d"
'

run_case "append_created_dir twice keeps both entries" '
  d=$(mktemp -d)
  append_created_dir "$d/created-dirs.list" "/etc/dnsmasq.d"
  append_created_dir "$d/created-dirs.list" "/etc/systemd/system/dnsmasq.service.d"
  out="$(read_created_dirs "$d/created-dirs.list")"
  assert_contains "$out" "/etc/dnsmasq.d"
  assert_contains "$out" "/etc/systemd/system/dnsmasq.service.d"
'

echo
echo "== summary =="
echo "$PASSED passed, $FAILED failed"
if ((FAILED > 0)); then
  echo "Failed cases:"
  printf '  - %s\n' "${FAILED_NAMES[@]}"
  exit 1
fi

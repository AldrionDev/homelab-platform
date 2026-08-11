#!/usr/bin/env bash
#
# Tests for dnsmasq/rollback.sh.
#
# Plain bash, no test framework dependency. Run with:
#   bash dnsmasq/rollback.test.sh
#
# Every case runs in a fresh `bash -c` that sources rollback.sh (which
# sources lib.sh), so `set -euo pipefail` is active exactly as in production.
# systemctl is shadowed per case; every managed path is redirected into a
# per-case tmpdir by reassigning the (deliberately non-readonly) path globals
# from lib.sh. No case requires root, systemd, or the real /etc or /var/lib
# paths, and no case ever supplies HOST_LAN_IP/HOMELAB_DOMAIN — rollback
# needs neither.
#
# shellcheck disable=SC2016
# Test bodies are single-quoted on purpose: they must reach the case subshell
# unexpanded, and are evaluated there against the sourced scripts.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_UNDER_TEST="$SCRIPT_DIR/rollback.sh"

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
expect_die() {
  local expected="$1"; shift
  local out rc=0
  out=$("$@" 2>&1) || rc=$?
  ((rc == 1)) || { echo "expect_die: expected exit 1, got $rc (output: $out)"; exit 90; }
  [[ "$out" == *"$expected"* ]] || { echo "expect_die: [$expected] not found in [$out]"; exit 90; }
}

FAKE_UNIT="dnsmasq-test-fake"
FAKE_ACTIVESTATE="active"
FAKE_ENABLED_RC=0
FAKE_DISABLE_NOW_RC=0
FAKE_DAEMON_RELOAD_RC=0
CALL_LOG=""

log_call() { [[ -z "$CALL_LOG" ]] || echo "$1" >> "$CALL_LOG"; }

systemctl() {
  case "$*" in
    "show $FAKE_UNIT --property=ActiveState --value") echo "$FAKE_ACTIVESTATE" ;;
    "is-enabled --quiet $FAKE_UNIT")                  return "$FAKE_ENABLED_RC" ;;
    "disable --now $FAKE_UNIT")
      log_call "disable-now"
      if [[ "$FAKE_DISABLE_NOW_RC" == 0 ]]; then
        FAKE_ACTIVESTATE="inactive"
        FAKE_ENABLED_RC=1
      fi
      return "$FAKE_DISABLE_NOW_RC" ;;
    "daemon-reload")
      log_call "daemon-reload"
      return "$FAKE_DAEMON_RELOAD_RC" ;;
    *) return 1 ;;
  esac
}

# Redirects every managed path into a fresh tmpdir. By default builds a
# fully-installed, ownership-provable state: live files exist and match
# their .expected copies, service is active+enabled, both managed
# directories are recorded as created-by-this-transaction. Individual cases
# mutate from there.
setup_installed_env() {
  D="$(mktemp -d)"
  DNSMASQ_UNIT_NAME="$FAKE_UNIT"
  HOMELAB_CONF_DIR="$D/etc/dnsmasq.d"
  HOMELAB_CONF_FILE="$HOMELAB_CONF_DIR/homelab.conf"
  SYSTEMD_DROPIN_DIR="$D/etc/systemd/system/dnsmasq.service.d"
  SYSTEMD_DROPIN_FILE="$SYSTEMD_DROPIN_DIR/homelab.conf"
  PLATFORM_STATE_ROOT="$D/var/lib/homelab-platform"
  STATE_DIR="$PLATFORM_STATE_ROOT/dnsmasq"
  STATE_HOMELAB_CONF_EXPECTED="$STATE_DIR/homelab.conf.expected"
  STATE_DROPIN_EXPECTED="$STATE_DIR/dropin.expected"
  STATE_CREATED_DIRS_LIST="$STATE_DIR/created-dirs.list"

  mkdir -p "$HOMELAB_CONF_DIR" "$SYSTEMD_DROPIN_DIR" "$STATE_DIR"
  printf 'homelab-conf-content\n' > "$HOMELAB_CONF_FILE"
  printf 'dropin-content\n' > "$SYSTEMD_DROPIN_FILE"
  cp "$HOMELAB_CONF_FILE" "$STATE_HOMELAB_CONF_EXPECTED"
  cp "$SYSTEMD_DROPIN_FILE" "$STATE_DROPIN_EXPECTED"
  printf '%s\n%s\n' "$HOMELAB_CONF_DIR" "$SYSTEMD_DROPIN_DIR" > "$STATE_CREATED_DIRS_LIST"

  FAKE_ACTIVESTATE="active"
  FAKE_ENABLED_RC=0
  FAKE_DISABLE_NOW_RC=0
  FAKE_DAEMON_RELOAD_RC=0
  CALL_LOG="$D/calls.log"
  : > "$CALL_LOG"
}
PRELUDE_EOF

run_case() {
  local name="$1" code="$2"
  local out rc=0
  out=$(bash -c "source \"\$1\"
$PRELUDE
$code" "dnsmasq-rollback-test" "$SCRIPT_UNDER_TEST" 2>&1) || rc=$?
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

echo "== do_rollback: state absent =="

run_case "do_rollback: refuses when no platform state directory exists" '
  D="$(mktemp -d)"
  STATE_DIR="$D/var/lib/homelab-platform/dnsmasq"
  STATE_HOMELAB_CONF_EXPECTED="$STATE_DIR/homelab.conf.expected"
  STATE_DROPIN_EXPECTED="$STATE_DIR/dropin.expected"
  expect_die "nothing to roll back" do_rollback
'

echo "== do_rollback: inconsistent state (live file missing) =="

run_case "do_rollback: refuses entirely when homelab.conf is already missing" '
  setup_installed_env
  rm -f "$HOMELAB_CONF_FILE"
  expect_die "inconsistent prior state" do_rollback
  [[ -e "$SYSTEMD_DROPIN_FILE" ]] || { echo "the still-present drop-in must not be touched either"; exit 90; }
  if [[ -s "$CALL_LOG" ]]; then echo "no systemctl mutation should have been attempted"; exit 90; fi
  true
'

run_case "do_rollback: refuses entirely when the drop-in is already missing" '
  setup_installed_env
  rm -f "$SYSTEMD_DROPIN_FILE"
  expect_die "inconsistent prior state" do_rollback
  [[ -e "$HOMELAB_CONF_FILE" ]] || { echo "the still-present homelab.conf must not be touched either"; exit 90; }
  true
'

echo "== do_rollback: ownership not proven =="

run_case "do_rollback: refuses entirely when homelab.conf content differs, leaves the matching drop-in alone too" '
  setup_installed_env
  printf "hand-edited\n" > "$HOMELAB_CONF_FILE"
  expect_die "ownership not proven" do_rollback
  [[ -e "$HOMELAB_CONF_FILE" ]] || { echo "homelab.conf must not be removed"; exit 90; }
  [[ -e "$SYSTEMD_DROPIN_FILE" ]] || { echo "drop-in must not be removed even though it matches"; exit 90; }
  if [[ -s "$CALL_LOG" ]]; then echo "no systemctl mutation should have been attempted"; exit 90; fi
  true
'

run_case "do_rollback: refuses entirely when the drop-in content differs" '
  setup_installed_env
  printf "hand-edited\n" > "$SYSTEMD_DROPIN_FILE"
  expect_die "ownership not proven" do_rollback
  [[ -e "$SYSTEMD_DROPIN_FILE" ]] || { echo "drop-in must not be removed"; exit 90; }
  [[ -e "$HOMELAB_CONF_FILE" ]] || { echo "homelab.conf must not be removed even though it matches"; exit 90; }
  true
'

echo "== do_rollback: ordering — stop/verify before any file removal =="

run_case "do_rollback: disable-now failure leaves everything untouched, manual recovery reported" '
  setup_installed_env
  FAKE_DISABLE_NOW_RC=1
  expect_die "manual recovery required" do_rollback
  assert_contains "$(cat "$CALL_LOG")" "disable-now"
  [[ -e "$HOMELAB_CONF_FILE" ]] || { echo "homelab.conf must not be removed"; exit 90; }
  [[ -e "$SYSTEMD_DROPIN_FILE" ]] || { echo "drop-in must not be removed"; exit 90; }
  [[ -e "$STATE_DIR" ]] || { echo "platform state must not be removed"; exit 90; }
  if grep -q "daemon-reload" "$CALL_LOG"; then echo "daemon-reload must not run if disable failed"; exit 90; fi
  true
'

run_case "do_rollback: baseline verification failure (still enabled) leaves everything untouched" '
  setup_installed_env
  # disable --now itself "succeeds" at the systemctl-call level but the unit
  # stubbornly reports enabled afterward — verify_baseline must still catch
  # this and refuse to proceed.
  systemctl() {
    case "$*" in
      "show $FAKE_UNIT --property=ActiveState --value") echo "inactive" ;;
      "is-enabled --quiet $FAKE_UNIT") return 0 ;;
      "disable --now $FAKE_UNIT") log_call "disable-now"; return 0 ;;
      "daemon-reload") log_call "daemon-reload"; return 0 ;;
      *) return 1 ;;
    esac
  }
  expect_die "did not verify inactive/disabled" do_rollback
  [[ -e "$HOMELAB_CONF_FILE" ]] || { echo "homelab.conf must not be removed"; exit 90; }
  [[ -e "$STATE_DIR" ]] || { echo "platform state must not be removed"; exit 90; }
  true
'

echo "== do_rollback: happy path =="

run_case "do_rollback: stops the service before removing any file, then removes files, daemon-reloads, and clears state last" '
  setup_installed_env
  do_rollback
  [[ -e "$HOMELAB_CONF_FILE" ]] && { echo "homelab.conf should have been removed"; exit 90; }
  [[ -e "$SYSTEMD_DROPIN_FILE" ]] && { echo "drop-in should have been removed"; exit 90; }
  [[ -e "$STATE_DIR" ]] && { echo "component state dir should have been removed"; exit 90; }
  [[ -e "$HOMELAB_CONF_DIR" ]] && { echo "the manifest-listed, now-empty directory should have been removed"; exit 90; }
  [[ -e "$SYSTEMD_DROPIN_DIR" ]] && { echo "the manifest-listed, now-empty directory should have been removed"; exit 90; }
  assert_eq "$(cat "$CALL_LOG")" $'"'"'disable-now\ndaemon-reload'"'"'
  true
'

run_case "do_rollback: leaves the shared platform state root in place, even though this component created it" '
  setup_installed_env
  [[ -d "$PLATFORM_STATE_ROOT" ]] || { echo "test fixture invariant broken: root should exist before rollback"; exit 90; }
  do_rollback
  [[ -e "$STATE_DIR" ]] && { echo "component state dir should have been removed"; exit 90; }
  [[ -d "$PLATFORM_STATE_ROOT" ]] || { echo "platform state root must NOT be removed by rollback"; exit 90; }
  true
'

run_case "do_rollback: only removes a directory the manifest explicitly names" '
  setup_installed_env
  # Re-record the manifest with only one of the two directories, and leave
  # an extra file in the other so it would fail to rmdir even if attempted —
  # proving the *manifest*, not emptiness, is what gates removal.
  printf "%s\n" "$HOMELAB_CONF_DIR" > "$STATE_CREATED_DIRS_LIST"
  do_rollback
  [[ -e "$HOMELAB_CONF_DIR" ]] && { echo "the manifest-listed directory should have been removed"; exit 90; }
  [[ -d "$SYSTEMD_DROPIN_DIR" ]] || { echo "the unlisted directory must be left in place even though it is now empty"; exit 90; }
  true
'

echo
echo "== summary =="
echo "$PASSED passed, $FAILED failed"
if ((FAILED > 0)); then
  echo "Failed cases:"
  printf '  - %s\n' "${FAILED_NAMES[@]}"
  exit 1
fi

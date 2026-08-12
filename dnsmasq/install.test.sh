#!/usr/bin/env bash
#
# Tests for dnsmasq/install.sh.
#
# Plain bash, no test framework dependency. Run with:
#   bash dnsmasq/install.test.sh
#
# Every case runs in a fresh `bash -c` that sources install.sh (which sources
# lib.sh), so the scripts' own `set -euo pipefail` is active exactly as in
# production. systemctl/dnsmasq/dig are shadowed per case, and every managed
# path is redirected into a per-case tmpdir by reassigning the (deliberately
# non-readonly) path globals from lib.sh — no case requires root, systemd, a
# real dnsmasq install, or the real /etc or /var/lib paths.
#
# shellcheck disable=SC2016
# Test bodies are single-quoted on purpose: they must reach the case subshell
# unexpanded, and are evaluated there against the sourced scripts.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_UNDER_TEST="$SCRIPT_DIR/install.sh"

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
inspect_field() {
  awk -F= -v k="$1" '$1==k{sub(/^[^=]*=/,""); print}' <<< "$2"
}

FAKE_UNIT="dnsmasq-test-fake"
FAKE_LOADSTATE="loaded"
FAKE_ACTIVESTATE="inactive"
FAKE_FRAGMENTPATH=""
FAKE_DROPINPATHS=""
FAKE_ENABLED_RC=1
FAKE_DAEMON_RELOAD_RC=0
FAKE_ENABLE_RC=0
FAKE_START_RC=0
FAKE_DISABLE_NOW_RC=0
FAKE_DNSMASQ_TEST_RC=0
FAKE_DIG_ANSWER=""
CALL_LOG=""

log_call() { [[ -z "$CALL_LOG" ]] || echo "$1" >> "$CALL_LOG"; }

# Replaces the real systemctl for the fake unit only. Any query about a unit
# other than $FAKE_UNIT fails, so a real dnsmasq unit on the host can never
# leak into a test result. Mutating commands only update the simulated
# active/enabled state on success, mirroring a real partially-failed command.
systemctl() {
  case "$*" in
    "show $FAKE_UNIT --property=LoadState --value")    echo "$FAKE_LOADSTATE" ;;
    "show $FAKE_UNIT --property=ActiveState --value")  echo "$FAKE_ACTIVESTATE" ;;
    "show $FAKE_UNIT --property=FragmentPath --value") echo "$FAKE_FRAGMENTPATH" ;;
    "show $FAKE_UNIT --property=DropInPaths --value")  echo "$FAKE_DROPINPATHS" ;;
    "is-enabled --quiet $FAKE_UNIT")                   return "$FAKE_ENABLED_RC" ;;
    "daemon-reload")
      log_call "daemon-reload"
      return "$FAKE_DAEMON_RELOAD_RC" ;;
    "enable $FAKE_UNIT")
      log_call "enable"
      [[ "$FAKE_ENABLE_RC" != 0 ]] || FAKE_ENABLED_RC=0
      return "$FAKE_ENABLE_RC" ;;
    "start $FAKE_UNIT")
      log_call "start"
      [[ "$FAKE_START_RC" != 0 ]] || FAKE_ACTIVESTATE="active"
      return "$FAKE_START_RC" ;;
    "disable --now $FAKE_UNIT")
      log_call "disable-now"
      if [[ "$FAKE_DISABLE_NOW_RC" == 0 ]]; then
        FAKE_ACTIVESTATE="inactive"
        FAKE_ENABLED_RC=1
      fi
      return "$FAKE_DISABLE_NOW_RC" ;;
    *) return 1 ;;
  esac
}

dnsmasq() {
  case "$1" in
    --test) return "$FAKE_DNSMASQ_TEST_RC" ;;
    *) return 1 ;;
  esac
}

dig() { echo "$FAKE_DIG_ANSWER"; }

# Redirects every managed path into a fresh tmpdir and resets every FAKE_*
# control variable to a clean, install-eligible baseline. Individual cases
# override specific FAKE_* variables afterward.
setup_env() {
  D="$(mktemp -d)"
  DNSMASQ_UNIT_NAME="$FAKE_UNIT"
  HOMELAB_CONF_DIR="$D/etc/dnsmasq.d"
  HOMELAB_CONF_FILE="$HOMELAB_CONF_DIR/homelab.conf"
  SYSTEMD_DROPIN_DIR="$D/etc/systemd/system/dnsmasq.service.d"
  SYSTEMD_DROPIN_FILE="$SYSTEMD_DROPIN_DIR/homelab.conf"
  # Deliberately NOT pre-created below: the platform state root must be
  # created by do_install itself (or accepted if a case pre-creates it), not
  # assumed present by the test fixture — that assumption previously masked
  # a real bug (do_install's single mkdir for STATE_DIR failed on a real
  # host where /var/lib/homelab-platform did not yet exist).
  PLATFORM_STATE_ROOT="$D/var/lib/homelab-platform"
  STATE_DIR="$PLATFORM_STATE_ROOT/dnsmasq"
  STATE_HOMELAB_CONF_EXPECTED="$STATE_DIR/homelab.conf.expected"
  STATE_DROPIN_EXPECTED="$STATE_DIR/dropin.expected"
  STATE_CREATED_DIRS_LIST="$STATE_DIR/created-dirs.list"
  MAIN_DNSMASQ_CONF="$D/etc/dnsmasq.conf"

  # $D/var/lib stands in for the real /var/lib, which always exists on a
  # real host (FHS) — only $PLATFORM_STATE_ROOT itself is left absent, since
  # that is the thing under test.
  mkdir -p "$D/etc/systemd/system" "$D/var/lib"
  touch "$MAIN_DNSMASQ_CONF"

  mkdir -p "$D/fragment"
  cat > "$D/fragment/dnsmasq.service" <<UNIT
[Service]
ExecStart=/usr/bin/dnsmasq -k --enable-dbus --user=dnsmasq --pid-file
ExecStartPre=/usr/bin/dnsmasq --test
UNIT
  FAKE_FRAGMENTPATH="$D/fragment/dnsmasq.service"

  FAKE_LOADSTATE="loaded"
  FAKE_ACTIVESTATE="inactive"
  FAKE_ENABLED_RC=1
  FAKE_DROPINPATHS=""
  FAKE_DAEMON_RELOAD_RC=0
  FAKE_ENABLE_RC=0
  FAKE_START_RC=0
  FAKE_DISABLE_NOW_RC=0
  FAKE_DNSMASQ_TEST_RC=0
  FAKE_DIG_ANSWER="192.0.2.10"
  CALL_LOG="$D/calls.log"
  : > "$CALL_LOG"
}
PRELUDE_EOF

run_case() {
  local name="$1" code="$2"
  local out rc=0
  out=$(bash -c "source \"\$1\"
$PRELUDE
$code" "dnsmasq-install-test" "$SCRIPT_UNDER_TEST" 2>&1) || rc=$?
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

echo "== validate_env =="

run_case "validate_env: both unset fails and names both" '
  expect_die "HOST_LAN_IP" validate_env
  out=$( (validate_env) 2>&1 ) || true
  assert_contains "$out" "HOMELAB_DOMAIN"
'

run_case "validate_env: both set succeeds silently" '
  HOST_LAN_IP="192.0.2.10"
  HOMELAB_DOMAIN="homelab.home.arpa"
  out=$(validate_env 2>&1)
  assert_eq "$out" ""
'

echo "== rendering =="

run_case "render_homelab_conf produces the wildcard address/listen-address/bind-dynamic lines" '
  out="$(render_homelab_conf "homelab.home.arpa" "192.0.2.10")"
  assert_contains "$out" "address=/homelab.home.arpa/192.0.2.10"
  assert_contains "$out" "listen-address=192.0.2.10"
  assert_contains "$out" "bind-dynamic"
  if grep -qxF "bind-interfaces" <<< "$out"; then
    echo "must not reintroduce bind-interfaces (does not tolerate late address assignment)"
    exit 90
  fi
  if grep -qE "^(no-resolv|no-hosts|server=)" <<< "$out"; then
    echo "must not disable normal upstream forwarding"
    exit 90
  fi
'

run_case "render_dropin includes the additive two-file ExecStartPre with matching --conf-file order" '
  MAIN_DNSMASQ_CONF="/etc/dnsmasq.conf"
  HOMELAB_CONF_FILE="/etc/dnsmasq.d/homelab.conf"
  out="$(render_dropin "/usr/bin/dnsmasq -k --enable-dbus --user=dnsmasq --pid-file")"
  assert_contains "$out" "ExecStart=/usr/bin/dnsmasq -k --enable-dbus --user=dnsmasq --pid-file --conf-file=/etc/dnsmasq.conf --conf-file=/etc/dnsmasq.d/homelab.conf"
  assert_contains "$out" "ExecStartPre=/usr/bin/dnsmasq --test --conf-file=/etc/dnsmasq.conf --conf-file=/etc/dnsmasq.d/homelab.conf"
'

run_case "render_dropin never emits an empty ExecStartPre= reset (would clear the inherited package precheck)" '
  out="$(render_dropin "/usr/bin/dnsmasq -k --enable-dbus --user=dnsmasq --pid-file")"
  if grep -qxF "ExecStartPre=" <<< "$out"; then
    echo "found an empty ExecStartPre= reset line"
    exit 90
  fi
'

run_case "render_dropin does not duplicate the bare package precheck line; the base unit fixture keeps its own" '
  base_unit_fixture=$'"'"'[Service]\nExecStart=/usr/bin/dnsmasq -k --enable-dbus --user=dnsmasq --pid-file\nExecStartPre=/usr/bin/dnsmasq --test'"'"'
  assert_contains "$base_unit_fixture" "ExecStartPre=/usr/bin/dnsmasq --test"
  out="$(render_dropin "/usr/bin/dnsmasq -k --enable-dbus --user=dnsmasq --pid-file")"
  if grep -qxF "ExecStartPre=/usr/bin/dnsmasq --test" <<< "$out"; then
    echo "drop-in should not reproduce the bare package precheck line, only add the two-file one"
    exit 90
  fi
'

run_case "render_dropin only clears ExecStart=, never ExecStartPre=" '
  out="$(render_dropin "/usr/bin/dnsmasq -k --enable-dbus --user=dnsmasq --pid-file")"
  assert_contains "$out" $'"'"'ExecStart=\nExecStart=/usr/bin/dnsmasq'"'"'
'

echo "== inspect_installation: no state present =="

run_case "inspect_installation: unit not loaded -> mismatch" '
  setup_env
  FAKE_LOADSTATE="not-found"
  out=$(inspect_installation "homelab.home.arpa" "192.0.2.10")
  assert_eq "$(inspect_field ACTION "$out")" "mismatch"
  assert_contains "$(inspect_field REASON "$out")" "not loaded"
'

run_case "inspect_installation: active with no state -> mismatch (foreign)" '
  setup_env
  FAKE_ACTIVESTATE="active"
  out=$(inspect_installation "homelab.home.arpa" "192.0.2.10")
  assert_eq "$(inspect_field ACTION "$out")" "mismatch"
  assert_contains "$(inspect_field REASON "$out")" "foreign"
'

run_case "inspect_installation: enabled with no state -> mismatch (foreign)" '
  setup_env
  FAKE_ENABLED_RC=0
  out=$(inspect_installation "homelab.home.arpa" "192.0.2.10")
  assert_eq "$(inspect_field ACTION "$out")" "mismatch"
  assert_contains "$(inspect_field REASON "$out")" "foreign"
'

run_case "inspect_installation: foreign drop-in with no state -> mismatch" '
  setup_env
  FAKE_DROPINPATHS="/etc/systemd/system/dnsmasq.service.d/99-other.conf"
  out=$(inspect_installation "homelab.home.arpa" "192.0.2.10")
  assert_eq "$(inspect_field ACTION "$out")" "mismatch"
  assert_contains "$(inspect_field REASON "$out")" "drop-in"
'

run_case "inspect_installation: homelab.conf already on disk with no state -> mismatch" '
  setup_env
  mkdir -p "$HOMELAB_CONF_DIR"
  touch "$HOMELAB_CONF_FILE"
  out=$(inspect_installation "homelab.home.arpa" "192.0.2.10")
  assert_eq "$(inspect_field ACTION "$out")" "mismatch"
  assert_contains "$(inspect_field REASON "$out")" "already exists"
'

run_case "inspect_installation: clean baseline, nothing present -> install" '
  setup_env
  out=$(inspect_installation "homelab.home.arpa" "192.0.2.10")
  assert_eq "$(inspect_field ACTION "$out")" "install"
'

echo "== inspect_installation: platform state present (re-run) =="

run_case "inspect_installation: state present, foreign drop-in -> mismatch" '
  setup_env
  mkdir -p "$STATE_DIR"
  echo x > "$STATE_HOMELAB_CONF_EXPECTED"
  echo y > "$STATE_DROPIN_EXPECTED"
  FAKE_DROPINPATHS="/etc/systemd/system/dnsmasq.service.d/99-other.conf"
  out=$(inspect_installation "homelab.home.arpa" "192.0.2.10")
  assert_eq "$(inspect_field ACTION "$out")" "mismatch"
  assert_contains "$(inspect_field REASON "$out")" "foreign"
'

run_case "inspect_installation: state present, drop-in missing -> mismatch (inconsistent state)" '
  setup_env
  mkdir -p "$STATE_DIR"
  echo x > "$STATE_HOMELAB_CONF_EXPECTED"
  echo y > "$STATE_DROPIN_EXPECTED"
  FAKE_DROPINPATHS=""
  out=$(inspect_installation "homelab.home.arpa" "192.0.2.10")
  assert_eq "$(inspect_field ACTION "$out")" "mismatch"
  assert_contains "$(inspect_field REASON "$out")" "missing"
'

run_case "inspect_installation: state present, homelab.conf missing on disk -> mismatch" '
  setup_env
  mkdir -p "$STATE_DIR" "$SYSTEMD_DROPIN_DIR"
  echo x > "$STATE_HOMELAB_CONF_EXPECTED"
  echo y > "$STATE_DROPIN_EXPECTED"
  echo y > "$SYSTEMD_DROPIN_FILE"
  FAKE_DROPINPATHS="$SYSTEMD_DROPIN_FILE"
  out=$(inspect_installation "homelab.home.arpa" "192.0.2.10")
  assert_eq "$(inspect_field ACTION "$out")" "mismatch"
  assert_contains "$(inspect_field REASON "$out")" "missing"
'

run_case "inspect_installation: everything matches, active+enabled -> noop" '
  setup_env
  FAKE_ACTIVESTATE="active"
  FAKE_ENABLED_RC=0
  domain="homelab.home.arpa"; ip="192.0.2.10"
  base="/usr/bin/dnsmasq -k --enable-dbus --user=dnsmasq --pid-file"
  conf_content="$(render_homelab_conf "$domain" "$ip")"
  dropin_content="$(render_dropin "$base")"
  mkdir -p "$HOMELAB_CONF_DIR" "$SYSTEMD_DROPIN_DIR" "$STATE_DIR"
  printf "%s" "$conf_content" > "$HOMELAB_CONF_FILE"
  printf "%s" "$dropin_content" > "$SYSTEMD_DROPIN_FILE"
  printf "%s" "$conf_content" > "$STATE_HOMELAB_CONF_EXPECTED"
  printf "%s" "$dropin_content" > "$STATE_DROPIN_EXPECTED"
  FAKE_DROPINPATHS="$SYSTEMD_DROPIN_FILE"
  out=$(inspect_installation "$domain" "$ip")
  assert_eq "$(inspect_field ACTION "$out")" "noop"
'

run_case "inspect_installation: HOST_LAN_IP changed since last install -> mismatch, no auto-adopt" '
  setup_env
  FAKE_ACTIVESTATE="active"
  FAKE_ENABLED_RC=0
  domain="homelab.home.arpa"
  base="/usr/bin/dnsmasq -k --enable-dbus --user=dnsmasq --pid-file"
  conf_content="$(render_homelab_conf "$domain" "192.0.2.10")"
  dropin_content="$(render_dropin "$base")"
  mkdir -p "$HOMELAB_CONF_DIR" "$SYSTEMD_DROPIN_DIR" "$STATE_DIR"
  printf "%s" "$conf_content" > "$HOMELAB_CONF_FILE"
  printf "%s" "$dropin_content" > "$SYSTEMD_DROPIN_FILE"
  printf "%s" "$conf_content" > "$STATE_HOMELAB_CONF_EXPECTED"
  printf "%s" "$dropin_content" > "$STATE_DROPIN_EXPECTED"
  FAKE_DROPINPATHS="$SYSTEMD_DROPIN_FILE"
  out=$(inspect_installation "$domain" "192.0.2.99")
  assert_eq "$(inspect_field ACTION "$out")" "mismatch"
  assert_contains "$(inspect_field REASON "$out")" "HOST_LAN_IP/HOMELAB_DOMAIN"
'

run_case "inspect_installation: package ExecStart changed since last install -> mismatch, no auto-adopt" '
  setup_env
  FAKE_ACTIVESTATE="active"
  FAKE_ENABLED_RC=0
  domain="homelab.home.arpa"; ip="192.0.2.10"
  old_base="/usr/bin/dnsmasq -k --enable-dbus --user=dnsmasq --pid-file"
  conf_content="$(render_homelab_conf "$domain" "$ip")"
  dropin_content="$(render_dropin "$old_base")"
  mkdir -p "$HOMELAB_CONF_DIR" "$SYSTEMD_DROPIN_DIR" "$STATE_DIR"
  printf "%s" "$conf_content" > "$HOMELAB_CONF_FILE"
  printf "%s" "$dropin_content" > "$SYSTEMD_DROPIN_FILE"
  printf "%s" "$conf_content" > "$STATE_HOMELAB_CONF_EXPECTED"
  printf "%s" "$dropin_content" > "$STATE_DROPIN_EXPECTED"
  FAKE_DROPINPATHS="$SYSTEMD_DROPIN_FILE"
  # Simulate a package update that added a flag to the base ExecStart.
  cat > "$FAKE_FRAGMENTPATH" <<UNIT
[Service]
ExecStart=/usr/bin/dnsmasq -k --enable-dbus --user=dnsmasq --pid-file --new-flag
ExecStartPre=/usr/bin/dnsmasq --test
UNIT
  out=$(inspect_installation "$domain" "$ip")
  assert_eq "$(inspect_field ACTION "$out")" "mismatch"
  assert_contains "$(inspect_field REASON "$out")" "ExecStart"
'

run_case "inspect_installation: matches but not active -> mismatch" '
  setup_env
  FAKE_ACTIVESTATE="inactive"
  FAKE_ENABLED_RC=0
  domain="homelab.home.arpa"; ip="192.0.2.10"
  base="/usr/bin/dnsmasq -k --enable-dbus --user=dnsmasq --pid-file"
  conf_content="$(render_homelab_conf "$domain" "$ip")"
  dropin_content="$(render_dropin "$base")"
  mkdir -p "$HOMELAB_CONF_DIR" "$SYSTEMD_DROPIN_DIR" "$STATE_DIR"
  printf "%s" "$conf_content" > "$HOMELAB_CONF_FILE"
  printf "%s" "$dropin_content" > "$SYSTEMD_DROPIN_FILE"
  printf "%s" "$conf_content" > "$STATE_HOMELAB_CONF_EXPECTED"
  printf "%s" "$dropin_content" > "$STATE_DROPIN_EXPECTED"
  FAKE_DROPINPATHS="$SYSTEMD_DROPIN_FILE"
  out=$(inspect_installation "$domain" "$ip")
  assert_eq "$(inspect_field ACTION "$out")" "mismatch"
  assert_contains "$(inspect_field REASON "$out")" "active: false"
'

echo "== inspect_installation: platform state root =="

run_case "inspect_installation: platform state root exists but is not a directory -> mismatch" '
  setup_env
  mkdir -p "$(dirname "$PLATFORM_STATE_ROOT")"
  : > "$PLATFORM_STATE_ROOT"
  out=$(inspect_installation "homelab.home.arpa" "192.0.2.10")
  assert_eq "$(inspect_field ACTION "$out")" "mismatch"
  assert_contains "$(inspect_field REASON "$out")" "$PLATFORM_STATE_ROOT"
'

echo "== do_install: platform state root =="

run_case "do_install: platform state root absent -> root and component directory both created with intended modes" '
  setup_env
  [[ -e "$PLATFORM_STATE_ROOT" ]] && { echo "fixture should not pre-create the root"; exit 90; }
  do_install "homelab.home.arpa" "192.0.2.10"
  [[ -d "$PLATFORM_STATE_ROOT" ]] || { echo "platform state root should have been created"; exit 90; }
  assert_eq "$(stat -c%a "$PLATFORM_STATE_ROOT")" "755"
  [[ -d "$STATE_DIR" ]] || { echo "component state directory should have been created"; exit 90; }
  assert_eq "$(stat -c%a "$STATE_DIR")" "700"
'

run_case "do_install: platform state root already exists as a directory -> accepted" '
  setup_env
  mkdir -p "$PLATFORM_STATE_ROOT"
  do_install "homelab.home.arpa" "192.0.2.10"
  [[ -d "$STATE_DIR" ]] || { echo "component state directory should have been created"; exit 90; }
  assert_eq "$(stat -c%a "$STATE_DIR")" "700"
'

run_case "do_install: platform state root exists but is not a directory -> fails closed before any mutation" '
  setup_env
  mkdir -p "$(dirname "$PLATFORM_STATE_ROOT")"
  : > "$PLATFORM_STATE_ROOT"
  expect_die "$PLATFORM_STATE_ROOT exists but is not a directory" do_install "homelab.home.arpa" "192.0.2.10"
  [[ -e "$HOMELAB_CONF_FILE" ]] && { echo "nothing should have been written"; exit 90; }
  [[ -e "$STATE_DIR" ]] && { echo "nothing should have been written"; exit 90; }
  if [[ -s "$CALL_LOG" ]]; then echo "no systemctl mutation should have been attempted"; exit 90; fi
  true
'

echo "== do_install: happy path =="

run_case "do_install: succeeds, writes matching files, calls enable+start, never disable-now" '
  setup_env
  out=$(do_install "homelab.home.arpa" "192.0.2.10")
  assert_eq "$(cat "$HOMELAB_CONF_FILE")" "$(render_homelab_conf "homelab.home.arpa" "192.0.2.10")"
  assert_eq "$(cat "$SYSTEMD_DROPIN_FILE")" "$(render_dropin "/usr/bin/dnsmasq -k --enable-dbus --user=dnsmasq --pid-file")"
  assert_ok files_match "$HOMELAB_CONF_FILE" "$STATE_HOMELAB_CONF_EXPECTED"
  assert_ok files_match "$SYSTEMD_DROPIN_FILE" "$STATE_DROPIN_EXPECTED"
  assert_contains "$(cat "$STATE_CREATED_DIRS_LIST")" "$HOMELAB_CONF_DIR"
  assert_contains "$(cat "$STATE_CREATED_DIRS_LIST")" "$SYSTEMD_DROPIN_DIR"
  assert_contains "$(cat "$CALL_LOG")" "daemon-reload"
  assert_contains "$(cat "$CALL_LOG")" "enable"
  assert_contains "$(cat "$CALL_LOG")" "start"
  if grep -q "disable-now" "$CALL_LOG"; then echo "disable-now must not be called on success"; exit 90; fi
'

echo "== do_install: transactional failure cleanup =="

run_case "do_install: daemon-reload failure removes dnsmasq-owned state but leaves the platform state root" '
  setup_env
  FAKE_DAEMON_RELOAD_RC=1
  expect_die "systemctl daemon-reload failed" do_install "homelab.home.arpa" "192.0.2.10"
  [[ -e "$HOMELAB_CONF_FILE" ]] && { echo "homelab.conf should have been removed"; exit 90; }
  [[ -e "$SYSTEMD_DROPIN_FILE" ]] && { echo "drop-in should have been removed"; exit 90; }
  [[ -e "$STATE_DIR" ]] && { echo "component state dir should have been removed"; exit 90; }
  [[ -d "$PLATFORM_STATE_ROOT" ]] || { echo "platform state root should NOT have been removed"; exit 90; }
  if grep -q "enable" "$CALL_LOG"; then echo "enable should never have been called"; exit 90; fi
  true
'

run_case "do_install: enable succeeds, start fails -> disable-now + verify + full file cleanup" '
  setup_env
  FAKE_START_RC=1
  expect_die "systemctl start" do_install "homelab.home.arpa" "192.0.2.10"
  assert_contains "$(cat "$CALL_LOG")" "enable"
  assert_contains "$(cat "$CALL_LOG")" "disable-now"
  [[ -e "$HOMELAB_CONF_FILE" ]] && { echo "homelab.conf should have been removed"; exit 90; }
  [[ -e "$SYSTEMD_DROPIN_FILE" ]] && { echo "drop-in should have been removed"; exit 90; }
  [[ -e "$STATE_DIR" ]] && { echo "state dir should have been removed"; exit 90; }
  true
'

run_case "do_install: enable itself fails -> disable-now attempted anyway, start never called, full cleanup" '
  setup_env
  FAKE_ENABLE_RC=1
  expect_die "systemctl enable" do_install "homelab.home.arpa" "192.0.2.10"
  assert_contains "$(cat "$CALL_LOG")" "disable-now"
  if grep -qx "start" "$CALL_LOG"; then echo "start should never have been called"; exit 90; fi
  [[ -e "$HOMELAB_CONF_FILE" ]] && { echo "homelab.conf should have been removed"; exit 90; }
  true
'

run_case "do_install: failed post-install dig check triggers disable-now and full cleanup" '
  setup_env
  FAKE_DIG_ANSWER=""
  expect_die "post-install check failed" do_install "homelab.home.arpa" "192.0.2.10"
  assert_contains "$(cat "$CALL_LOG")" "disable-now"
  [[ -e "$HOMELAB_CONF_FILE" ]] && { echo "homelab.conf should have been removed"; exit 90; }
  [[ -e "$STATE_DIR" ]] && { echo "state dir should have been removed"; exit 90; }
  true
'

run_case "do_install: disable/verify itself failing stops cleanup and preserves everything" '
  setup_env
  FAKE_START_RC=1
  FAKE_DISABLE_NOW_RC=1
  expect_die "MANUAL RECOVERY REQUIRED" do_install "homelab.home.arpa" "192.0.2.10"
  [[ -e "$HOMELAB_CONF_FILE" ]] || { echo "homelab.conf should NOT have been removed"; exit 90; }
  [[ -e "$SYSTEMD_DROPIN_FILE" ]] || { echo "drop-in should NOT have been removed"; exit 90; }
  [[ -e "$STATE_DIR" ]] || { echo "state dir should NOT have been removed"; exit 90; }
'

run_case "do_install: staged dnsmasq --test failure aborts before any /etc write" '
  setup_env
  FAKE_DNSMASQ_TEST_RC=1
  expect_die "dnsmasq --test failed" do_install "homelab.home.arpa" "192.0.2.10"
  [[ -e "$HOMELAB_CONF_FILE" ]] && { echo "nothing should have been written"; exit 90; }
  [[ -e "$STATE_DIR" ]] && { echo "nothing should have been written"; exit 90; }
  if [[ -s "$CALL_LOG" ]]; then echo "no systemctl mutation should have been attempted"; exit 90; fi
'

echo
echo "== summary =="
echo "$PASSED passed, $FAILED failed"
if ((FAILED > 0)); then
  echo "Failed cases:"
  printf '  - %s\n' "${FAILED_NAMES[@]}"
  exit 1
fi

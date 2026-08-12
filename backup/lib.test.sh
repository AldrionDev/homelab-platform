#!/usr/bin/env bash
#
# Tests for backup/lib.sh.
#
# Plain bash, no test framework dependency. Run with:
#   bash backup/lib.test.sh
#
# Every case runs in a fresh `bash -c` that sources lib.sh, matching the
# style of dnsmasq/lib.test.sh and k3s/install.test.sh. lib.sh itself sets
# no shell options (sourced-only), so each case controls its own failure
# handling via the assert helpers below. Every case gets a fresh, trapped
# mktemp scratch directory ($d) -- nothing is written under the repo tree,
# nothing requires sudo, and no case depends on sleep.
#
# shellcheck disable=SC2016
# Test bodies are single-quoted on purpose: they must reach the case
# subshell unexpanded, and are evaluated there against the sourced library.

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
assert_file_exists() {
  [[ -f "$1" ]] || { echo "assert_file_exists failed: $1"; exit 90; }
}
assert_file_absent() {
  [[ -e "$1" || -L "$1" ]] && { echo "assert_file_absent failed (still present): $1"; exit 90; }
  return 0
}

# Every case gets its own trapped scratch root -- created here so it exists
# before the case body runs, and removed when this subshell exits for any
# reason (normal completion or an assert_* failure calling exit 90).
d="$(mktemp -d)"
trap 'rm -rf -- "$d"' EXIT
PRELUDE_EOF

run_case() {
  local name="$1" code="$2"
  local out rc=0
  out=$(bash -c "source \"\$1\"
$PRELUDE
$code" "backup-lib-test" "$LIB_UNDER_TEST" 2>&1) || rc=$?
  if ((rc == 0)); then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
    FAILED_NAMES+=("$name")
    echo "FAIL: $name"
    echo "$out" | sed 's/^/      /'
  fi
}

echo "== require_absolute_path =="

run_case "require_absolute_path accepts an absolute path" '
  require_absolute_path "X" "/tmp/foo"
'
run_case "require_absolute_path rejects a relative path" '
  expect_die "must be an absolute path" require_absolute_path "X" "relative/foo"
'
run_case "require_absolute_path rejects an empty value" '
  expect_die "must be an absolute path" require_absolute_path "X" ""
'

echo "== paths_conflict =="

run_case "paths_conflict detects equality" '
  assert_ok paths_conflict "/tmp/a" "/tmp/a"
'
run_case "paths_conflict detects parent containing child" '
  assert_ok paths_conflict "/tmp/a/b" "/tmp/a"
'
run_case "paths_conflict detects child containing parent" '
  assert_ok paths_conflict "/tmp/a" "/tmp/a/b"
'
run_case "paths_conflict treats a prefix-only lookalike as no conflict" '
  assert_not_ok paths_conflict "/tmp/data2" "/tmp/data"
'
run_case "paths_conflict treats a prefix-only lookalike as no conflict (reversed)" '
  assert_not_ok paths_conflict "/tmp/data" "/tmp/data2"
'
run_case "paths_conflict treats unrelated paths as no conflict" '
  assert_not_ok paths_conflict "/tmp/a" "/tmp/b"
'

echo "== canonicalize_recovery_target =="

run_case "canonicalize_recovery_target accepts a missing plain leaf under an existing parent" '
  target="$d/leaf"
  result="$(canonicalize_recovery_target "$target")"
  assert_eq "$result" "$(realpath -e "$d")/leaf"
'
run_case "canonicalize_recovery_target rejects an existing regular file" '
  target="$d/leaf"
  : > "$target"
  expect_die "already exists" canonicalize_recovery_target "$target"
'
run_case "canonicalize_recovery_target rejects an existing directory" '
  target="$d/leaf"
  mkdir "$target"
  expect_die "already exists" canonicalize_recovery_target "$target"
'
run_case "canonicalize_recovery_target rejects an existing symlink" '
  real="$d/real"; mkdir "$real"
  target="$d/leaf"
  ln -s "$real" "$target"
  expect_die "already exists" canonicalize_recovery_target "$target"
'
run_case "canonicalize_recovery_target rejects a dangling symlink" '
  target="$d/leaf"
  ln -s "$d/does-not-exist" "$target"
  expect_die "already exists" canonicalize_recovery_target "$target"
'
run_case "canonicalize_recovery_target rejects unsafe leaf ." '
  expect_die "unsafe basename" canonicalize_recovery_target "$d/nonexistent/."
'
run_case "canonicalize_recovery_target rejects unsafe leaf .." '
  expect_die "unsafe basename" canonicalize_recovery_target "$d/nonexistent/.."
'
run_case "canonicalize_recovery_target dies when the parent does not exist" '
  expect_die "does not exist" canonicalize_recovery_target "$d/missing-parent/leaf"
'

echo "== canonicalize_restore_live_data_path =="

run_case "canonicalize_restore_live_data_path fully resolves an existing normal path" '
  real="$d/real"; mkdir "$real"
  result="$(canonicalize_restore_live_data_path "$real")"
  assert_eq "$result" "$(realpath -e "$real")"
'
run_case "canonicalize_restore_live_data_path resolves an existing symlink to its target" '
  real="$d/real"; mkdir "$real"
  link="$d/link"; ln -s "$real" "$link"
  result="$(canonicalize_restore_live_data_path "$link")"
  assert_eq "$result" "$(realpath -e "$real")"
'
run_case "canonicalize_restore_live_data_path resolves a plain missing leaf via canonical parent+basename" '
  path="$d/missing"
  result="$(canonicalize_restore_live_data_path "$path")"
  assert_eq "$result" "$(realpath -e "$d")/missing"
'
run_case "canonicalize_restore_live_data_path fails closed on a dangling symlink" '
  path="$d/dangling"
  ln -s "$d/does-not-exist" "$path"
  expect_die "dangling symlink" canonicalize_restore_live_data_path "$path"
'
run_case "canonicalize_restore_live_data_path rejects unsafe leaf . for a missing path" '
  expect_die "unsafe basename" canonicalize_restore_live_data_path "$d/nonexistent/."
'
run_case "canonicalize_restore_live_data_path rejects unsafe leaf .. for a missing path" '
  expect_die "unsafe basename" canonicalize_restore_live_data_path "$d/nonexistent/.."
'

echo "== scan_payload_safety =="

run_case "scan_payload_safety passes ordinary nested directories and files" '
  mkdir -p "$d/a/b"
  : > "$d/a/file1"
  : > "$d/a/b/file2"
  assert_ok scan_payload_safety "$d"
'
run_case "scan_payload_safety rejects a symlink" '
  : > "$d/real"
  ln -s "$d/real" "$d/link"
  expect_die "unsupported entry type" scan_payload_safety "$d"
'
run_case "scan_payload_safety rejects a FIFO" '
  mkfifo "$d/fifo"
  expect_die "unsupported entry type" scan_payload_safety "$d"
'
run_case "scan_payload_safety rejects a hardlinked regular file" '
  : > "$d/original"
  ln "$d/original" "$d/hardlink"
  expect_die "hardlinked regular file" scan_payload_safety "$d"
'

echo "== stat_dev_inode =="

run_case "stat_dev_inode returns a stable identity for the same file" '
  : > "$d/f"
  a="$(stat_dev_inode "$d/f")"
  b="$(stat_dev_inode "$d/f")"
  assert_eq "$a" "$b"
'
run_case "stat_dev_inode differs for two distinct files" '
  : > "$d/f1"
  : > "$d/f2"
  a="$(stat_dev_inode "$d/f1")"
  b="$(stat_dev_inode "$d/f2")"
  assert_not_ok test "$a" = "$b"
'

echo "== cleanup_pending_checksum_if_owned =="

run_case "cleanup_pending_checksum_if_owned removes an owned hardlink" '
  echo content > "$d/staged"
  ln "$d/staged" "$d/final"
  PUBLISH_PENDING_CHECKSUM_PATH="$d/final"
  PUBLISH_PENDING_CHECKSUM_ID="$(stat_dev_inode "$d/staged")"
  cleanup_pending_checksum_if_owned
  assert_file_absent "$d/final"
'
run_case "cleanup_pending_checksum_if_owned does not remove a different/swapped file" '
  echo content > "$d/staged"
  echo other > "$d/final"
  PUBLISH_PENDING_CHECKSUM_PATH="$d/final"
  PUBLISH_PENDING_CHECKSUM_ID="$(stat_dev_inode "$d/staged")"
  cleanup_pending_checksum_if_owned
  assert_file_exists "$d/final"
  assert_eq "$(cat "$d/final")" "other"
'
run_case "cleanup_pending_checksum_if_owned is harmless when no path is pending" '
  PUBLISH_PENDING_CHECKSUM_PATH=""
  PUBLISH_PENDING_CHECKSUM_ID=""
  cleanup_pending_checksum_if_owned
'
run_case "cleanup_pending_checksum_if_owned is harmless when the pending path was never created" '
  PUBLISH_PENDING_CHECKSUM_PATH="$d/never-created"
  PUBLISH_PENDING_CHECKSUM_ID="0:0"
  cleanup_pending_checksum_if_owned
  assert_file_absent "$d/never-created"
'
run_case "cleanup_pending_checksum_if_owned disarms state after running (idempotent)" '
  echo content > "$d/staged"
  ln "$d/staged" "$d/final"
  PUBLISH_PENDING_CHECKSUM_PATH="$d/final"
  PUBLISH_PENDING_CHECKSUM_ID="$(stat_dev_inode "$d/staged")"
  cleanup_pending_checksum_if_owned
  assert_eq "$PUBLISH_PENDING_CHECKSUM_PATH" ""
  assert_eq "$PUBLISH_PENDING_CHECKSUM_ID" ""
  # a second call must be a pure no-op, not an error
  cleanup_pending_checksum_if_owned
'

echo "== validate_backup_id =="

for good in "abc" "abc-123" "ABC" "a1-B2" "a"; do
  run_case "validate_backup_id accepts '$good'" "
    validate_backup_id '$good'
  "
done

for bad in "" "abc_def" "abc def" "abc/def" "abc.def"; do
  run_case "validate_backup_id rejects '$bad'" "
    expect_die 'BACKUP_ID is malformed' validate_backup_id '$bad'
  "
done

echo "== validate_timestamp =="

run_case "validate_timestamp accepts a valid UTC timestamp" '
  validate_timestamp "20260101T000000Z"
'

for bad in \
  "2026/01/01T000000Z" \
  "20260101T000000Z/.." \
  "20260101T000000Z " \
  " 20260101T000000Z" \
  "20260101t000000z" \
  "2026101T000000Z" \
  "20260101T00000Z" \
  "20260101T000000" \
  "20260101T000000ZZ" \
  ""
do
  run_case "validate_timestamp rejects '$bad'" "
    expect_die 'timestamp is malformed' validate_timestamp '$bad'
  "
done

echo "== validate_archive_basename =="

run_case "validate_archive_basename accepts a well-formed basename" '
  validate_archive_basename "my-id-20260101T000000Z.tar.gz"
'
for bad in \
  "my-id-20260101T000000Z.tar" \
  "../my-id-20260101T000000Z.tar.gz" \
  "my_id-20260101T000000Z.tar.gz" \
  "my-id-2026-01-01T000000Z.tar.gz" \
  "my-id-20260101T000000Z.tar.gz.sha256"
do
  run_case "validate_archive_basename rejects '$bad'" "
    expect_die 'does not match the expected pattern' validate_archive_basename '$bad'
  "
done

echo
echo "== summary =="
echo "$PASSED passed, $FAILED failed"
if ((FAILED > 0)); then
  echo "Failed cases:"
  printf '  - %s\n' "${FAILED_NAMES[@]}"
  exit 1
fi

#!/usr/bin/env bash
#
# End-to-end tests for backup/backup.sh, run as the real executable (not
# sourced), under mktemp scratch directories only. No sudo, no real
# databases, no repo-tree writes, no sleep-based determinism.
#
# Run with:
#   bash backup/backup.test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_SH="$SCRIPT_DIR/backup.sh"
VALIDATOR_PY="$SCRIPT_DIR/tar_metadata_check.py"

D="$(mktemp -d)"
trap 'rm -rf -- "$D"' EXIT

PASSED=0
FAILED=0
FAILED_NAMES=()
CASE_NAME=""

fail_case() {
    echo "FAIL: $CASE_NAME"
    echo "      $1" | sed 's/^/      /'
}

run_case() {
    CASE_NAME="$1"
    local fn="$2"
    if "$fn"; then
        PASSED=$((PASSED + 1))
    else
        FAILED=$((FAILED + 1))
        FAILED_NAMES+=("$CASE_NAME")
    fi
}

newdir() {
    # mktemp guarantees a fresh, unique directory on every call -- unlike a
    # hand-rolled counter, this needs no state that could get lost across
    # the command-substitution subshell each `dir="$(newdir)"` call runs in.
    mktemp -d -p "$D"
}

mkdest() {
    mkdir -m 0700 -- "$1"
}

# Runs backup.sh. Args before a bare "--" are KEY=VALUE env assignments
# (passed via `env`, never exported into this test process); args after
# "--" are passed straight through to backup.sh as its own trailing argv.
# Sets LAST_RC / LAST_OUT.
run_backup() {
    local -a env_args=() script_args=()
    local seen_dashdash=0 a
    for a in "$@"; do
        if [[ "$seen_dashdash" == 0 && "$a" == "--" ]]; then
            seen_dashdash=1
            script_args+=("--")
            continue
        fi
        if [[ "$seen_dashdash" == 0 ]]; then
            env_args+=("$a")
        else
            script_args+=("$a")
        fi
    done
    local rc=0
    LAST_OUT="$(env "${env_args[@]}" bash "$BACKUP_SH" "${script_args[@]}" 2>&1)" || rc=$?
    LAST_RC=$rc
}

assert_backup_rc_nonzero() {
    [[ "$LAST_RC" != "0" ]] || { fail_case "expected non-zero exit, got 0. output: $LAST_OUT"; return 1; }
    return 0
}
assert_backup_rc_eq() {
    [[ "$LAST_RC" == "$1" ]] || { fail_case "expected exit $1, got $LAST_RC. output: $LAST_OUT"; return 1; }
    return 0
}
assert_out_contains() {
    [[ "$LAST_OUT" == *"$1"* ]] || { fail_case "expected output to contain [$1], got: $LAST_OUT"; return 1; }
    return 0
}
assert_no_final_artifacts() {
    local dest="$1" hits
    hits="$(find "$dest" -maxdepth 1 \( -name '*.tar.gz' -o -name '*.tar.gz.sha256' \) 2>/dev/null)"
    [[ -z "$hits" ]] || { fail_case "unexpected final artifact(s) present: $hits"; return 1; }
    return 0
}
assert_eq_file_line() {
    local file="$1" lineno="$2" expected="$3" actual
    actual="$(sed -n "${lineno}p" "$file")"
    [[ "$actual" == "$expected" ]] || { fail_case "line $lineno of $file: expected [$expected], got [$actual]"; return 1; }
    return 0
}

# --- producer fixtures -------------------------------------------------

SUCCESS_PRODUCER="$D/producer-success.sh"
cat >"$SUCCESS_PRODUCER" <<'EOF'
#!/usr/bin/env bash
printf '%s' "DETERMINISTIC_DUMP_BYTES_ABC123"
EOF
chmod +x "$SUCCESS_PRODUCER"

FAIL_PRODUCER="$D/producer-fail.sh"
cat >"$FAIL_PRODUCER" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
chmod +x "$FAIL_PRODUCER"

FAIL_AFTER_OUTPUT_PRODUCER="$D/producer-fail-after-output.sh"
cat >"$FAIL_AFTER_OUTPUT_PRODUCER" <<'EOF'
#!/usr/bin/env bash
printf 'partial output'
exit 3
EOF
chmod +x "$FAIL_AFTER_OUTPUT_PRODUCER"

EMPTY_PRODUCER="$D/producer-empty.sh"
cat >"$EMPTY_PRODUCER" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$EMPTY_PRODUCER"

ARGV_ECHO_PRODUCER="$D/producer-argv-echo.sh"
cat >"$ARGV_ECHO_PRODUCER" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$ARGV_CAPTURE_FILE"
printf '%s' "ARGV_ECHO_DUMP_BYTES"
EOF
chmod +x "$ARGV_ECHO_PRODUCER"

build_dummy_source_tree() {
    local src="$1"
    mkdir -p "$src/nested/deep"
    printf 'hello world' >"$src/file.txt"
    : >"$src/empty.txt"
    printf 'spaced content' >"$src/file with spaces.txt"
    printf 'quoted content' >"$src/file'"'"'with'"'"'quotes.txt"
    printf 'hidden content' >"$src/.hidden-file"
    printf 'deep content' >"$src/nested/deep/deepfile.txt"
}

# --- A. input / fail-closed ---------------------------------------------

t_missing_destination() {
    local dir; dir="$(newdir)"
    local src="$dir/src"; mkdir -p "$src"
    run_backup "BACKUP_ID=myid" "BACKUP_SOURCE_KIND=dir" "BACKUP_SOURCE_DIR=$src"
    assert_backup_rc_nonzero || return 1
    assert_out_contains "BACKUP_DESTINATION" || return 1
}
run_case "missing BACKUP_DESTINATION fails" t_missing_destination

t_relative_destination() {
    local dir; dir="$(newdir)"
    local src="$dir/src"; mkdir -p "$src"
    run_backup "BACKUP_DESTINATION=relative/path" "BACKUP_ID=myid" "BACKUP_SOURCE_KIND=dir" "BACKUP_SOURCE_DIR=$src"
    assert_backup_rc_nonzero || return 1
    assert_out_contains "absolute path" || return 1
}
run_case "relative BACKUP_DESTINATION fails" t_relative_destination

t_nonexistent_destination() {
    local dir; dir="$(newdir)"
    local src="$dir/src"; mkdir -p "$src"
    run_backup "BACKUP_DESTINATION=$dir/does-not-exist" "BACKUP_ID=myid" "BACKUP_SOURCE_KIND=dir" "BACKUP_SOURCE_DIR=$src"
    assert_backup_rc_nonzero || return 1
    assert_out_contains "does not exist" || return 1
}
run_case "nonexistent BACKUP_DESTINATION fails" t_nonexistent_destination

t_wrong_mode_destination() {
    local dir; dir="$(newdir)"
    local dest="$dir/dest"; mkdir -m 0755 -- "$dest"
    local src="$dir/src"; mkdir -p "$src"
    run_backup "BACKUP_DESTINATION=$dest" "BACKUP_ID=myid" "BACKUP_SOURCE_KIND=dir" "BACKUP_SOURCE_DIR=$src"
    assert_backup_rc_nonzero || return 1
    assert_out_contains "0700" || return 1
    assert_no_final_artifacts "$dest" || return 1
}
run_case "wrong-mode BACKUP_DESTINATION fails" t_wrong_mode_destination

t_invalid_backup_id() {
    local dir; dir="$(newdir)"
    local dest="$dir/dest"; mkdest "$dest"
    local src="$dir/src"; mkdir -p "$src"
    run_backup "BACKUP_DESTINATION=$dest" "BACKUP_ID=bad id" "BACKUP_SOURCE_KIND=dir" "BACKUP_SOURCE_DIR=$src"
    assert_backup_rc_nonzero || return 1
    assert_no_final_artifacts "$dest" || return 1
}
run_case "invalid BACKUP_ID fails" t_invalid_backup_id

t_invalid_source_kind() {
    local dir; dir="$(newdir)"
    local dest="$dir/dest"; mkdest "$dest"
    run_backup "BACKUP_DESTINATION=$dest" "BACKUP_ID=myid" "BACKUP_SOURCE_KIND=bogus"
    assert_backup_rc_nonzero || return 1
}
run_case "invalid BACKUP_SOURCE_KIND fails" t_invalid_source_kind

t_malformed_timestamp() {
    local dir; dir="$(newdir)"
    local dest="$dir/dest"; mkdest "$dest"
    local src="$dir/src"; mkdir -p "$src"
    run_backup "BACKUP_DESTINATION=$dest" "BACKUP_ID=myid" "BACKUP_SOURCE_KIND=dir" "BACKUP_SOURCE_DIR=$src" "BACKUP_TIMESTAMP=bad"
    assert_backup_rc_nonzero || return 1
    assert_no_final_artifacts "$dest" || return 1
}
run_case "malformed BACKUP_TIMESTAMP fails" t_malformed_timestamp

t_path_like_timestamp() {
    local dir; dir="$(newdir)"
    local dest="$dir/dest"; mkdest "$dest"
    local src="$dir/src"; mkdir -p "$src"
    run_backup "BACKUP_DESTINATION=$dest" "BACKUP_ID=myid" "BACKUP_SOURCE_KIND=dir" "BACKUP_SOURCE_DIR=$src" "BACKUP_TIMESTAMP=../../etc"
    assert_backup_rc_nonzero || return 1
    assert_no_final_artifacts "$dest" || return 1
}
run_case "path-like BACKUP_TIMESTAMP fails" t_path_like_timestamp

t_missing_dir_source() {
    local dir; dir="$(newdir)"
    local dest="$dir/dest"; mkdest "$dest"
    run_backup "BACKUP_DESTINATION=$dest" "BACKUP_ID=myid" "BACKUP_SOURCE_KIND=dir"
    assert_backup_rc_nonzero || return 1
}
run_case "missing BACKUP_SOURCE_DIR for kind=dir fails" t_missing_dir_source

t_forbidden_combo_dir_with_live_path() {
    local dir; dir="$(newdir)"
    local dest="$dir/dest"; mkdest "$dest"
    local src="$dir/src"; mkdir -p "$src"
    local live="$dir/live"; mkdir -p "$live"
    run_backup "BACKUP_DESTINATION=$dest" "BACKUP_ID=myid" "BACKUP_SOURCE_KIND=dir" "BACKUP_SOURCE_DIR=$src" "BACKUP_LIVE_DATA_PATH=$live"
    assert_backup_rc_nonzero || return 1
}
run_case "kind=dir with BACKUP_LIVE_DATA_PATH set fails" t_forbidden_combo_dir_with_live_path

t_forbidden_combo_db_with_source_dir() {
    local dir; dir="$(newdir)"
    local dest="$dir/dest"; mkdest "$dest"
    local live="$dir/live"; mkdir -p "$live"
    local src="$dir/src"; mkdir -p "$src"
    run_backup "BACKUP_DESTINATION=$dest" "BACKUP_ID=myid" "BACKUP_SOURCE_KIND=db" "BACKUP_LIVE_DATA_PATH=$live" "BACKUP_SOURCE_DIR=$src" -- "$SUCCESS_PRODUCER"
    assert_backup_rc_nonzero || return 1
}
run_case "kind=db with BACKUP_SOURCE_DIR set fails" t_forbidden_combo_db_with_source_dir

t_db_missing_live_path() {
    local dir; dir="$(newdir)"
    local dest="$dir/dest"; mkdest "$dest"
    run_backup "BACKUP_DESTINATION=$dest" "BACKUP_ID=myid" "BACKUP_SOURCE_KIND=db" -- "$SUCCESS_PRODUCER"
    assert_backup_rc_nonzero || return 1
}
run_case "kind=db missing BACKUP_LIVE_DATA_PATH fails" t_db_missing_live_path

t_db_live_path_nonexistent() {
    local dir; dir="$(newdir)"
    local dest="$dir/dest"; mkdest "$dest"
    run_backup "BACKUP_DESTINATION=$dest" "BACKUP_ID=myid" "BACKUP_SOURCE_KIND=db" "BACKUP_LIVE_DATA_PATH=$dir/nope" -- "$SUCCESS_PRODUCER"
    assert_backup_rc_nonzero || return 1
}
run_case "kind=db nonexistent BACKUP_LIVE_DATA_PATH fails" t_db_live_path_nonexistent

t_db_missing_producer_argv() {
    local dir; dir="$(newdir)"
    local dest="$dir/dest"; mkdest "$dest"
    local live="$dir/live"; mkdir -p "$live"
    run_backup "BACKUP_DESTINATION=$dest" "BACKUP_ID=myid" "BACKUP_SOURCE_KIND=db" "BACKUP_LIVE_DATA_PATH=$live"
    assert_backup_rc_nonzero || return 1
}
run_case "kind=db missing producer argv fails" t_db_missing_producer_argv

t_producer_missing_executable() {
    local dir; dir="$(newdir)"
    local dest="$dir/dest"; mkdest "$dest"
    local live="$dir/live"; mkdir -p "$live"
    run_backup "BACKUP_DESTINATION=$dest" "BACKUP_ID=myid" "BACKUP_SOURCE_KIND=db" "BACKUP_LIVE_DATA_PATH=$live" -- "$dir/does-not-exist"
    assert_backup_rc_nonzero || return 1
    assert_no_final_artifacts "$dest" || return 1
}
run_case "producer executable missing/not executable fails" t_producer_missing_executable

# --- B. source/destination separation ------------------------------------

t_dir_dest_eq_source() {
    local dir; dir="$(newdir)"
    local shared="$dir/shared"; mkdir -m 0700 -- "$shared"
    run_backup "BACKUP_DESTINATION=$shared" "BACKUP_ID=myid" "BACKUP_SOURCE_KIND=dir" "BACKUP_SOURCE_DIR=$shared"
    assert_backup_rc_nonzero || return 1
}
run_case "dir mode: destination == source fails" t_dir_dest_eq_source

t_dir_dest_inside_source() {
    local dir; dir="$(newdir)"
    local src="$dir/src"; mkdir -p "$src"
    local dest="$src/dest"; mkdir -m 0700 -- "$dest"
    run_backup "BACKUP_DESTINATION=$dest" "BACKUP_ID=myid" "BACKUP_SOURCE_KIND=dir" "BACKUP_SOURCE_DIR=$src"
    assert_backup_rc_nonzero || return 1
}
run_case "dir mode: destination inside source fails" t_dir_dest_inside_source

t_dir_source_inside_dest() {
    local dir; dir="$(newdir)"
    local dest="$dir/dest"; mkdir -m 0700 -- "$dest"
    local src="$dest/src"; mkdir -p "$src"
    run_backup "BACKUP_DESTINATION=$dest" "BACKUP_ID=myid" "BACKUP_SOURCE_KIND=dir" "BACKUP_SOURCE_DIR=$src"
    assert_backup_rc_nonzero || return 1
}
run_case "dir mode: source inside destination fails" t_dir_source_inside_dest

t_db_dest_eq_live() {
    local dir; dir="$(newdir)"
    local shared="$dir/shared"; mkdir -m 0700 -- "$shared"
    run_backup "BACKUP_DESTINATION=$shared" "BACKUP_ID=myid" "BACKUP_SOURCE_KIND=db" "BACKUP_LIVE_DATA_PATH=$shared" -- "$SUCCESS_PRODUCER"
    assert_backup_rc_nonzero || return 1
}
run_case "db mode: destination == live-data path fails" t_db_dest_eq_live

t_db_dest_inside_live() {
    local dir; dir="$(newdir)"
    local live="$dir/live"; mkdir -p "$live"
    local dest="$live/dest"; mkdir -m 0700 -- "$dest"
    run_backup "BACKUP_DESTINATION=$dest" "BACKUP_ID=myid" "BACKUP_SOURCE_KIND=db" "BACKUP_LIVE_DATA_PATH=$live" -- "$SUCCESS_PRODUCER"
    assert_backup_rc_nonzero || return 1
}
run_case "db mode: destination inside live-data path fails" t_db_dest_inside_live

t_db_live_inside_dest() {
    local dir; dir="$(newdir)"
    local dest="$dir/dest"; mkdir -m 0700 -- "$dest"
    local live="$dest/live"; mkdir -p "$live"
    run_backup "BACKUP_DESTINATION=$dest" "BACKUP_ID=myid" "BACKUP_SOURCE_KIND=db" "BACKUP_LIVE_DATA_PATH=$live" -- "$SUCCESS_PRODUCER"
    assert_backup_rc_nonzero || return 1
}
run_case "db mode: live-data path inside destination fails" t_db_live_inside_dest

# --- C. directory source safety -------------------------------------------

t_source_symlink() {
    local dir; dir="$(newdir)"
    local dest="$dir/dest"; mkdest "$dest"
    local src="$dir/src"; mkdir -p "$src"
    : >"$src/real"
    ln -s "$src/real" "$src/link"
    run_backup "BACKUP_DESTINATION=$dest" "BACKUP_ID=myid" "BACKUP_SOURCE_KIND=dir" "BACKUP_SOURCE_DIR=$src"
    assert_backup_rc_nonzero || return 1
    assert_no_final_artifacts "$dest" || return 1
}
run_case "dir source containing a symlink is refused" t_source_symlink

t_source_fifo() {
    local dir; dir="$(newdir)"
    local dest="$dir/dest"; mkdest "$dest"
    local src="$dir/src"; mkdir -p "$src"
    mkfifo "$src/fifo"
    run_backup "BACKUP_DESTINATION=$dest" "BACKUP_ID=myid" "BACKUP_SOURCE_KIND=dir" "BACKUP_SOURCE_DIR=$src"
    assert_backup_rc_nonzero || return 1
    assert_no_final_artifacts "$dest" || return 1
}
run_case "dir source containing a FIFO is refused" t_source_fifo

t_source_hardlink() {
    local dir; dir="$(newdir)"
    local dest="$dir/dest"; mkdest "$dest"
    local src="$dir/src"; mkdir -p "$src"
    : >"$src/original"
    ln "$src/original" "$src/hardlink"
    run_backup "BACKUP_DESTINATION=$dest" "BACKUP_ID=myid" "BACKUP_SOURCE_KIND=dir" "BACKUP_SOURCE_DIR=$src"
    assert_backup_rc_nonzero || return 1
    assert_no_final_artifacts "$dest" || return 1
}
run_case "dir source containing a hardlinked regular file is refused" t_source_hardlink

# --- D. db producer ---------------------------------------------------

t_producer_nonzero_exit() {
    local dir; dir="$(newdir)"
    local dest="$dir/dest"; mkdest "$dest"
    local live="$dir/live"; mkdir -p "$live"
    run_backup "BACKUP_DESTINATION=$dest" "BACKUP_ID=myid" "BACKUP_SOURCE_KIND=db" "BACKUP_LIVE_DATA_PATH=$live" -- "$FAIL_PRODUCER"
    assert_backup_rc_nonzero || return 1
    assert_no_final_artifacts "$dest" || return 1
}
run_case "producer non-zero exit fails the backup" t_producer_nonzero_exit

t_producer_fail_after_output() {
    local dir; dir="$(newdir)"
    local dest="$dir/dest"; mkdest "$dest"
    local live="$dir/live"; mkdir -p "$live"
    run_backup "BACKUP_DESTINATION=$dest" "BACKUP_ID=myid" "BACKUP_SOURCE_KIND=db" "BACKUP_LIVE_DATA_PATH=$live" -- "$FAIL_AFTER_OUTPUT_PRODUCER"
    assert_backup_rc_nonzero || return 1
    assert_no_final_artifacts "$dest" || return 1
}
run_case "producer non-zero exit after partial stdout still fails" t_producer_fail_after_output

t_producer_zero_byte_stdout() {
    local dir; dir="$(newdir)"
    local dest="$dir/dest"; mkdest "$dest"
    local live="$dir/live"; mkdir -p "$live"
    run_backup "BACKUP_DESTINATION=$dest" "BACKUP_ID=myid" "BACKUP_SOURCE_KIND=db" "BACKUP_LIVE_DATA_PATH=$live" -- "$EMPTY_PRODUCER"
    assert_backup_rc_nonzero || return 1
    assert_out_contains "zero bytes" || return 1
    assert_no_final_artifacts "$dest" || return 1
}
run_case "producer exit 0 with zero-byte stdout fails" t_producer_zero_byte_stdout

t_producer_success_and_argv_quoting() {
    local dir; dir="$(newdir)"
    local dest="$dir/dest"; mkdest "$dest"
    local live="$dir/live"; mkdir -p "$live"
    local capture="$dir/argv-capture.txt"
    run_backup "BACKUP_DESTINATION=$dest" "BACKUP_ID=myid" "BACKUP_SOURCE_KIND=db" "BACKUP_LIVE_DATA_PATH=$live" "ARGV_CAPTURE_FILE=$capture" -- "$ARGV_ECHO_PRODUCER" "arg with spaces" "plainarg"
    assert_backup_rc_eq 0 || return 1
    [[ -f "$capture" ]] || { fail_case "argv capture file missing"; return 1; }
    assert_eq_file_line "$capture" 1 "arg with spaces" || return 1
    assert_eq_file_line "$capture" 2 "plainarg" || return 1
}
run_case "producer succeeds with deterministic bytes; an arg containing spaces passes through argv intact" t_producer_success_and_argv_quoting

# --- E. pre-publication validation is load-bearing ------------------------
#
# Uses a test-only `tar` shadowed via PATH (never a production code change)
# that excludes the manifest from the archive it builds -- proving that
# backup.sh's synchronous call to the Python contract validator against the
# STAGED archive genuinely blocks publication. The validator's own full
# failure-injection matrix (member safety, layout, manifest strictness,
# payload/manifest consistency) is exhaustively covered directly in
# tar_metadata_check.test.sh; this case proves backup.sh actually wires that
# exact gate in before checksum/archive publication, not a re-test of the
# validator's own logic.

t_staged_archive_gate_is_load_bearing() {
    local dir; dir="$(newdir)"
    local dest="$dir/dest"; mkdest "$dest"
    local src="$dir/src"; mkdir -p "$src"
    : >"$src/file.txt"

    local wrapperdir="$dir/wrapper-bin"
    mkdir -p "$wrapperdir"
    local real_tar; real_tar="$(command -v tar)"
    cat >"$wrapperdir/tar" <<EOF
#!/usr/bin/env bash
exec "$real_tar" --exclude=*/manifest "\$@"
EOF
    chmod +x "$wrapperdir/tar"

    local rc=0
    LAST_OUT="$(env PATH="$wrapperdir:$PATH" BACKUP_DESTINATION="$dest" BACKUP_ID=myid BACKUP_SOURCE_KIND=dir BACKUP_SOURCE_DIR="$src" bash "$BACKUP_SH" 2>&1)" || rc=$?
    LAST_RC=$rc
    assert_backup_rc_nonzero || return 1
    assert_out_contains "archive contract validator" || return 1
    assert_no_final_artifacts "$dest" || return 1
}
run_case "a staged archive missing its manifest fails the contract validator and blocks publication" t_staged_archive_gate_is_load_bearing

# --- F. successful directory backup ---------------------------------------

t_success_dir_backup() {
    local dir; dir="$(newdir)"
    local dest="$dir/dest"; mkdest "$dest"
    local src="$dir/src"; mkdir -p "$src"
    build_dummy_source_tree "$src"

    run_backup "BACKUP_DESTINATION=$dest" "BACKUP_ID=dirtest" "BACKUP_SOURCE_KIND=dir" "BACKUP_SOURCE_DIR=$src" "BACKUP_TIMESTAMP=20260101T010101Z"
    assert_backup_rc_eq 0 || return 1

    local archive="$dest/dirtest-20260101T010101Z.tar.gz"
    local checksum="$dest/dirtest-20260101T010101Z.tar.gz.sha256"
    [[ -f "$archive" ]] || { fail_case "expected archive missing: $archive"; return 1; }
    [[ -f "$checksum" ]] || { fail_case "expected checksum missing: $checksum"; return 1; }

    local count; count="$(find "$dest" -maxdepth 1 -type f | wc -l)"
    [[ "$count" == "2" ]] || { fail_case "expected exactly 2 files in destination, found $count"; return 1; }

    [[ "$(stat -c '%a' "$dest")" == "700" ]] || { fail_case "destination mode changed"; return 1; }
    [[ "$(stat -c '%a' "$archive")" == "600" ]] || { fail_case "archive mode wrong"; return 1; }
    [[ "$(stat -c '%a' "$checksum")" == "600" ]] || { fail_case "checksum mode wrong"; return 1; }

    local sidecar_lines; sidecar_lines="$(wc -l <"$checksum")"
    [[ "$sidecar_lines" == "1" ]] || { fail_case "sidecar does not have exactly one record ($sidecar_lines)"; return 1; }
    local sidecar_filename; sidecar_filename="$(awk '{print $2}' "$checksum")"
    [[ "$sidecar_filename" == "dirtest-20260101T010101Z.tar.gz" ]] || { fail_case "sidecar filename wrong: $sidecar_filename"; return 1; }

    local expected_digest actual_digest
    expected_digest="$(sha256sum "$archive" | awk '{print $1}')"
    actual_digest="$(awk '{print $1}' "$checksum")"
    [[ "$expected_digest" == "$actual_digest" ]] || { fail_case "digest mismatch"; return 1; }

    local pyerr="$dir/pyerr.txt"
    python3 "$VALIDATOR_PY" "$archive" "dirtest-20260101T010101Z" >/dev/null 2>"$pyerr" \
        || { fail_case "python validator failed on published archive: $(cat "$pyerr")"; return 1; }

    local manifest_dump
    manifest_dump="$(tar -xzOf "$archive" "dirtest-20260101T010101Z/manifest")"
    [[ "$manifest_dump" != *"$src"* ]] || { fail_case "manifest leaks the absolute source path"; return 1; }
    [[ "$manifest_dump" != *"$(hostname)"* ]] || { fail_case "manifest leaks the hostname"; return 1; }

    local stray; stray="$(find "$dest" -maxdepth 1 -name '.backup-staging.*')"
    [[ -z "$stray" ]] || { fail_case "staging directory left behind: $stray"; return 1; }

    local restored; restored="$(mktemp -d)"
    tar -xzf "$archive" -C "$restored"
    [[ "$(cat "$restored/dirtest-20260101T010101Z/data/src/file.txt")" == "hello world" ]] || { fail_case "regular file content wrong"; rm -rf "$restored"; return 1; }
    [[ ! -s "$restored/dirtest-20260101T010101Z/data/src/empty.txt" ]] || { fail_case "empty file not empty"; rm -rf "$restored"; return 1; }
    [[ "$(cat "$restored/dirtest-20260101T010101Z/data/src/file with spaces.txt")" == "spaced content" ]] || { fail_case "spaced filename content wrong"; rm -rf "$restored"; return 1; }
    [[ "$(cat "$restored/dirtest-20260101T010101Z/data/src/file'"'"'with'"'"'quotes.txt")" == "quoted content" ]] || { fail_case "quoted filename content wrong"; rm -rf "$restored"; return 1; }
    [[ "$(cat "$restored/dirtest-20260101T010101Z/data/src/.hidden-file")" == "hidden content" ]] || { fail_case "hidden dotfile content wrong"; rm -rf "$restored"; return 1; }
    [[ "$(cat "$restored/dirtest-20260101T010101Z/data/src/nested/deep/deepfile.txt")" == "deep content" ]] || { fail_case "nested file content wrong"; rm -rf "$restored"; return 1; }
    rm -rf "$restored"
}
run_case "successful directory backup produces correct artifacts/permissions/content" t_success_dir_backup

# --- G. successful db backup ----------------------------------------------

t_success_db_backup() {
    local dir; dir="$(newdir)"
    local dest="$dir/dest"; mkdest "$dest"
    local live="$dir/live"; mkdir -p "$live"

    run_backup "BACKUP_DESTINATION=$dest" "BACKUP_ID=dbtest" "BACKUP_SOURCE_KIND=db" "BACKUP_LIVE_DATA_PATH=$live" "BACKUP_TIMESTAMP=20260101T020202Z" -- "$SUCCESS_PRODUCER"
    assert_backup_rc_eq 0 || return 1

    local archive="$dest/dbtest-20260101T020202Z.tar.gz"
    local checksum="$dest/dbtest-20260101T020202Z.tar.gz.sha256"
    [[ -f "$archive" && -f "$checksum" ]] || { fail_case "missing final artifacts"; return 1; }
    [[ "$(stat -c '%a' "$archive")" == "600" ]] || { fail_case "archive mode wrong"; return 1; }
    [[ "$(stat -c '%a' "$checksum")" == "600" ]] || { fail_case "checksum mode wrong"; return 1; }

    local pyerr="$dir/pyerr.txt"
    python3 "$VALIDATOR_PY" "$archive" "dbtest-20260101T020202Z" >/dev/null 2>"$pyerr" \
        || { fail_case "python validator failed: $(cat "$pyerr")"; return 1; }

    local extracted
    extracted="$(tar -xzOf "$archive" "dbtest-20260101T020202Z/dump/dump.bin")"
    [[ "$extracted" == "DETERMINISTIC_DUMP_BYTES_ABC123" ]] || { fail_case "dump payload bytes do not match producer output: $extracted"; return 1; }
    # This proves the generic transport/publication mechanism reproduces the
    # producer's exact bytes -- it is not, and does not claim to be, a test
    # of pg_dump/pg_restore compatibility.
}
run_case "successful synthetic db backup: correct artifacts, exact dump bytes, transport-only" t_success_db_backup

# --- H. collisions ----------------------------------------------------

t_checksum_collision() {
    local dir; dir="$(newdir)"
    local dest="$dir/dest"; mkdest "$dest"
    local src="$dir/src"; mkdir -p "$src"; : >"$src/f"
    local ts="20260101T030303Z"
    local sentinel="$dest/collidetest-$ts.tar.gz.sha256"
    printf 'sentinel content, not a real checksum' >"$sentinel"
    chmod 0600 "$sentinel"

    run_backup "BACKUP_DESTINATION=$dest" "BACKUP_ID=collidetest" "BACKUP_SOURCE_KIND=dir" "BACKUP_SOURCE_DIR=$src" "BACKUP_TIMESTAMP=$ts"
    assert_backup_rc_nonzero || return 1
    [[ "$(cat "$sentinel")" == "sentinel content, not a real checksum" ]] || { fail_case "sentinel checksum was modified"; return 1; }
    [[ ! -e "$dest/collidetest-$ts.tar.gz" ]] || { fail_case "archive was published despite the checksum collision"; return 1; }
}
run_case "checksum path collision refuses and leaves the pre-existing sentinel untouched" t_checksum_collision

t_archive_collision() {
    local dir; dir="$(newdir)"
    local dest="$dir/dest"; mkdest "$dest"
    local src="$dir/src"; mkdir -p "$src"; : >"$src/f"
    local ts="20260101T040404Z"
    local sentinel="$dest/collidetest2-$ts.tar.gz"
    printf 'sentinel archive content' >"$sentinel"
    chmod 0600 "$sentinel"

    run_backup "BACKUP_DESTINATION=$dest" "BACKUP_ID=collidetest2" "BACKUP_SOURCE_KIND=dir" "BACKUP_SOURCE_DIR=$src" "BACKUP_TIMESTAMP=$ts"
    assert_backup_rc_nonzero || return 1
    [[ "$(cat "$sentinel")" == "sentinel archive content" ]] || { fail_case "sentinel archive was modified"; return 1; }
    [[ ! -e "$dest/collidetest2-$ts.tar.gz.sha256" ]] || { fail_case "this run's checksum was not cleaned up after the archive collision"; return 1; }
}
run_case "archive path collision refuses, leaves pre-existing archive untouched, cleans up this run's checksum" t_archive_collision

t_full_timestamp_collision_after_success() {
    local dir; dir="$(newdir)"
    local dest="$dir/dest"; mkdest "$dest"
    local src="$dir/src"; mkdir -p "$src"; : >"$src/f"
    local ts="20260101T050505Z"

    run_backup "BACKUP_DESTINATION=$dest" "BACKUP_ID=repeatid" "BACKUP_SOURCE_KIND=dir" "BACKUP_SOURCE_DIR=$src" "BACKUP_TIMESTAMP=$ts"
    assert_backup_rc_eq 0 || return 1

    local archive="$dest/repeatid-$ts.tar.gz"
    local checksum="$dest/repeatid-$ts.tar.gz.sha256"
    local before_archive_digest before_checksum_content
    before_archive_digest="$(sha256sum "$archive")"
    before_checksum_content="$(cat "$checksum")"

    run_backup "BACKUP_DESTINATION=$dest" "BACKUP_ID=repeatid" "BACKUP_SOURCE_KIND=dir" "BACKUP_SOURCE_DIR=$src" "BACKUP_TIMESTAMP=$ts"
    assert_backup_rc_nonzero || return 1

    [[ "$(sha256sum "$archive")" == "$before_archive_digest" ]] || { fail_case "first archive was modified by the second run"; return 1; }
    [[ "$(cat "$checksum")" == "$before_checksum_content" ]] || { fail_case "first checksum was modified by the second run"; return 1; }
}
run_case "an exact backup-id+timestamp collision after a successful backup fails closed, first backup unchanged" t_full_timestamp_collision_after_success

# --- I. signal / interruption behavior -------------------------------
#
# A test-only `ln` shadowed via PATH performs the real hardlink, then --
# only when explicitly armed by this test via an env var, and only for the
# checksum-sidecar link specifically -- sends the requested signal to its
# own parent (the backup.sh process) before returning. This deterministically
# lands the signal in the narrow window between checksum publication and
# archive publication without any production code change. SIGKILL/power-loss
# timing is not attempted this way (see note below): it cannot be trapped or
# deterministically synchronized by any child-process technique, so it is
# left as a documented residual, covered instead by the direct
# cleanup_pending_checksum_if_owned ownership-proof unit tests in
# lib.test.sh.

LN_SIGNAL_WRAPPER_DIR="$D/ln-signal-wrapper"
mkdir -p "$LN_SIGNAL_WRAPPER_DIR"
REAL_LN_PATH="$(command -v ln)"
cat >"$LN_SIGNAL_WRAPPER_DIR/ln" <<EOF
#!/usr/bin/env bash
"$REAL_LN_PATH" "\$@"
rc=\$?
if [[ -n "\${TEST_SIGNAL_AFTER_CHECKSUM_LN:-}" ]]; then
    case "\$*" in
        *.sha256*)
            kill -s "\$TEST_SIGNAL_AFTER_CHECKSUM_LN" "\$PPID"
            ;;
    esac
fi
exit "\$rc"
EOF
chmod +x "$LN_SIGNAL_WRAPPER_DIR/ln"

run_backup_with_signal_wrapper() {
    local dest="$1" src="$2" id="$3" ts="$4" signal="$5"
    local rc=0
    LAST_OUT="$(env PATH="$LN_SIGNAL_WRAPPER_DIR:$PATH" TEST_SIGNAL_AFTER_CHECKSUM_LN="$signal" \
        BACKUP_DESTINATION="$dest" BACKUP_ID="$id" BACKUP_SOURCE_KIND=dir BACKUP_SOURCE_DIR="$src" BACKUP_TIMESTAMP="$ts" \
        bash "$BACKUP_SH" 2>&1)" || rc=$?
    LAST_RC=$rc
}

t_sigint_after_checksum_before_archive() {
    local dir; dir="$(newdir)"
    local dest="$dir/dest"; mkdest "$dest"
    local src="$dir/src"; mkdir -p "$src"; : >"$src/f"
    local ts="20260101T060606Z"

    run_backup_with_signal_wrapper "$dest" "$src" "sigint-test" "$ts" INT
    assert_backup_rc_eq 130 || return 1
    [[ ! -e "$dest/sigint-test-$ts.tar.gz" ]] || { fail_case "archive present despite SIGINT before archive publish"; return 1; }
    [[ ! -e "$dest/sigint-test-$ts.tar.gz.sha256" ]] || { fail_case "checksum was not cleaned up after SIGINT"; return 1; }
    local stray; stray="$(find "$dest" -maxdepth 1 -name '.backup-staging.*')"
    [[ -z "$stray" ]] || { fail_case "staging directory left behind after SIGINT"; return 1; }
}
run_case "SIGINT after checksum publish but before archive publish: exits 130, checksum cleaned, archive absent" t_sigint_after_checksum_before_archive

t_sigterm_after_checksum_before_archive() {
    local dir; dir="$(newdir)"
    local dest="$dir/dest"; mkdest "$dest"
    local src="$dir/src"; mkdir -p "$src"; : >"$src/f"
    local ts="20260101T070707Z"

    run_backup_with_signal_wrapper "$dest" "$src" "sigterm-test" "$ts" TERM
    assert_backup_rc_eq 143 || return 1
    [[ ! -e "$dest/sigterm-test-$ts.tar.gz" ]] || { fail_case "archive present despite SIGTERM before archive publish"; return 1; }
    [[ ! -e "$dest/sigterm-test-$ts.tar.gz.sha256" ]] || { fail_case "checksum was not cleaned up after SIGTERM"; return 1; }
    local stray; stray="$(find "$dest" -maxdepth 1 -name '.backup-staging.*')"
    [[ -z "$stray" ]] || { fail_case "staging directory left behind after SIGTERM"; return 1; }
}
run_case "SIGTERM after checksum publish but before archive publish: exits 143, checksum cleaned, archive absent" t_sigterm_after_checksum_before_archive

# --- J. no retention / pruning ------------------------------------------

t_no_pruning() {
    local dir; dir="$(newdir)"
    local dest="$dir/dest"; mkdest "$dest"
    local src="$dir/src"; mkdir -p "$src"; : >"$src/f"

    run_backup "BACKUP_DESTINATION=$dest" "BACKUP_ID=prunetest" "BACKUP_SOURCE_KIND=dir" "BACKUP_SOURCE_DIR=$src" "BACKUP_TIMESTAMP=20260101T080808Z"
    assert_backup_rc_eq 0 || return 1
    run_backup "BACKUP_DESTINATION=$dest" "BACKUP_ID=prunetest" "BACKUP_SOURCE_KIND=dir" "BACKUP_SOURCE_DIR=$src" "BACKUP_TIMESTAMP=20260101T090909Z"
    assert_backup_rc_eq 0 || return 1

    [[ -f "$dest/prunetest-20260101T080808Z.tar.gz" ]] || { fail_case "first archive missing after second backup"; return 1; }
    [[ -f "$dest/prunetest-20260101T080808Z.tar.gz.sha256" ]] || { fail_case "first checksum missing after second backup"; return 1; }
    [[ -f "$dest/prunetest-20260101T090909Z.tar.gz" ]] || { fail_case "second archive missing"; return 1; }
    [[ -f "$dest/prunetest-20260101T090909Z.tar.gz.sha256" ]] || { fail_case "second checksum missing"; return 1; }
}
run_case "two successful backups with different timestamps both remain (no pruning)" t_no_pruning

echo
echo "== summary =="
echo "$PASSED passed, $FAILED failed"
if ((FAILED > 0)); then
    echo "Failed cases:"
    printf '  - %s\n' "${FAILED_NAMES[@]}"
    exit 1
fi

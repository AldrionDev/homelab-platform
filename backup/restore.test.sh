#!/usr/bin/env bash
#
# End-to-end tests for backup/restore.sh, run as the real executable (not
# sourced, except for the two direct ownership-proof unit tests which
# intentionally source it in an isolated subshell), under mktemp scratch
# directories only. No sudo, no real databases, no repo-tree writes, no
# sleep-based determinism.
#
# Run with:
#   bash backup/restore.test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_SH="$SCRIPT_DIR/backup.sh"
RESTORE_SH="$SCRIPT_DIR/restore.sh"
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
    mktemp -d -p "$D"
}

# Runs restore.sh. Args before a bare "--" are KEY=VALUE env assignments
# (via `env`, never exported into this test process); args after "--" are
# passed straight through as restore.sh's own trailing argv. Sets
# LAST_RC / LAST_OUT.
run_restore() {
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
    LAST_OUT="$(env "${env_args[@]}" bash "$RESTORE_SH" "${script_args[@]}" 2>&1)" || rc=$?
    LAST_RC=$rc
}

assert_restore_rc_nonzero() {
    [[ "$LAST_RC" != "0" ]] || { fail_case "expected non-zero exit, got 0. output: $LAST_OUT"; return 1; }
    return 0
}
assert_restore_rc_eq() {
    [[ "$LAST_RC" == "$1" ]] || { fail_case "expected exit $1, got $LAST_RC. output: $LAST_OUT"; return 1; }
    return 0
}
assert_out_contains() {
    [[ "$LAST_OUT" == *"$1"* ]] || { fail_case "expected output to contain [$1], got: $LAST_OUT"; return 1; }
    return 0
}
assert_target_absent() {
    [[ ! -e "$1" && ! -L "$1" ]] || { fail_case "RECOVERY_TARGET unexpectedly exists: $1"; return 1; }
    return 0
}

# --- validator fixtures --------------------------------------------------

ALWAYS_PASS_VALIDATOR="$D/validator-pass.sh"
cat >"$ALWAYS_PASS_VALIDATOR" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$ALWAYS_PASS_VALIDATOR"

ALWAYS_FAIL_VALIDATOR="$D/validator-fail.sh"
cat >"$ALWAYS_FAIL_VALIDATOR" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$ALWAYS_FAIL_VALIDATOR"

# $1 = restored source-root path. EXPECTED_TREE env var = reference copy.
# Also records that it ran, so tests can prove invocation actually happened.
DIR_EXACT_MATCH_VALIDATOR="$D/validator-dir-exact.sh"
cat >"$DIR_EXACT_MATCH_VALIDATOR" <<'EOF'
#!/usr/bin/env bash
set -u
: >"${VALIDATOR_INVOKED_MARKER:?}"
diff -r "${EXPECTED_TREE:?}" "$1"
EOF
chmod +x "$DIR_EXACT_MATCH_VALIDATOR"

# $1 = restored dump.bin path. EXPECTED_DUMP_FILE env var = reference bytes.
DB_EXACT_MATCH_VALIDATOR="$D/validator-db-exact.sh"
cat >"$DB_EXACT_MATCH_VALIDATOR" <<'EOF'
#!/usr/bin/env bash
set -u
: >"${VALIDATOR_INVOKED_MARKER:?}"
cmp "${EXPECTED_DUMP_FILE:?}" "$1"
EOF
chmod +x "$DB_EXACT_MATCH_VALIDATOR"

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

# Produces a real backup via backup.sh. Prints "archive checksum" (space
# separated) on success; the caller supplies destination/id/timestamp.
make_dir_backup() {
    local dest="$1" src="$2" id="$3" ts="$4"
    env BACKUP_DESTINATION="$dest" BACKUP_ID="$id" BACKUP_SOURCE_KIND=dir BACKUP_SOURCE_DIR="$src" BACKUP_TIMESTAMP="$ts" \
        bash "$BACKUP_SH" >/dev/null
    printf '%s %s\n' "$dest/$id-$ts.tar.gz" "$dest/$id-$ts.tar.gz.sha256"
}

make_db_backup() {
    local dest="$1" live="$2" id="$3" ts="$4" producer="$5"
    env BACKUP_DESTINATION="$dest" BACKUP_ID="$id" BACKUP_SOURCE_KIND=db BACKUP_LIVE_DATA_PATH="$live" BACKUP_TIMESTAMP="$ts" \
        bash "$BACKUP_SH" -- "$producer" >/dev/null
    printf '%s %s\n' "$dest/$id-$ts.tar.gz" "$dest/$id-$ts.tar.gz.sha256"
}

DB_PRODUCER="$D/producer.sh"
cat >"$DB_PRODUCER" <<'EOF'
#!/usr/bin/env bash
printf '%s' "DETERMINISTIC_DUMP_BYTES_FOR_RESTORE_TESTS"
EOF
chmod +x "$DB_PRODUCER"

# --- Python archive fixture builder (for hand-crafted malicious archives) -

BUILDER_PY="$D/build_archive.py"
cat >"$BUILDER_PY" <<'PYEOF'
import sys
import tarfile
import io

def main():
    out_path = sys.argv[1]
    tf = tarfile.open(out_path, mode='w:gz')
    for line in sys.stdin:
        line = line.rstrip('\n')
        if line == '':
            continue
        parts = line.split('\t')
        kind, name = parts[0], parts[1]
        ti = tarfile.TarInfo(name=name)
        if kind == 'dir':
            ti.type = tarfile.DIRTYPE
            ti.mode = 0o755
            tf.addfile(ti)
        elif kind == 'reg':
            content = parts[2].encode() if len(parts) > 2 else b''
            ti.type = tarfile.REGTYPE
            ti.mode = 0o644
            ti.size = len(content)
            tf.addfile(ti, io.BytesIO(content))
        elif kind == 'regfile':
            with open(parts[2], 'rb') as f:
                content = f.read()
            ti.type = tarfile.REGTYPE
            ti.mode = 0o644
            ti.size = len(content)
            tf.addfile(ti, io.BytesIO(content))
        elif kind == 'sym':
            ti.type = tarfile.SYMTYPE
            ti.linkname = parts[2] if len(parts) > 2 else '/etc/passwd'
            tf.addfile(ti)
        elif kind == 'hardlink':
            ti.type = tarfile.LNKTYPE
            ti.linkname = parts[2]
            tf.addfile(ti)
        elif kind == 'fifo':
            ti.type = tarfile.FIFOTYPE
            ti.mode = 0o644
            tf.addfile(ti)
        else:
            raise SystemExit('build_archive.py: unknown kind: ' + kind)
    tf.close()

main()
PYEOF

build_archive() {
    python3 "$BUILDER_PY" "$1"
}

TOPDIR="crafted-id-20260101T000000Z"

crafted_dir_manifest_file() {
    local f="$D/crafted-manifest-dir-$$-$RANDOM.txt"
    printf 'BACKUP_ID=crafted-id\nSOURCE_KIND=dir\nCREATED_AT=20260101T000000Z\nFORMAT_VERSION=1\nFILE_COUNT=1\nTOTAL_BYTES=5\n' >"$f"
    printf '%s' "$f"
}

crafted_db_manifest_file() {
    local content="$1" f="$D/crafted-manifest-db-$$-$RANDOM.txt"
    local size sha
    size="${#content}"
    sha="$(printf '%s' "$content" | sha256sum | cut -d' ' -f1)"
    printf 'BACKUP_ID=crafted-id\nSOURCE_KIND=db\nCREATED_AT=20260101T000000Z\nFORMAT_VERSION=1\nDUMP_SIZE_BYTES=%s\nDUMP_SHA256=%s\n' "$size" "$sha" >"$f"
    printf '%s' "$f"
}

# Builds a hand-crafted archive from the given tab-separated member spec,
# publishes it with a correctly-computed, valid-format sidecar (so checksum
# verification passes and the test genuinely exercises structural rejection,
# not checksum rejection), and returns "archive sidecar".
publish_crafted_archive() {
    local spec="$1"
    # The archive's own basename must match <backup-id>-<timestamp>.tar.gz,
    # since restore.sh derives its expected top-level identity from that
    # filename -- it must equal $TOPDIR, which every crafted member/manifest
    # in this file is built against. Cases run sequentially, so reusing one
    # fixed path per call (freshly rebuilt each time) is safe.
    local archive="$D/${TOPDIR}.tar.gz"
    printf '%s' "$spec" | build_archive "$archive"
    local sidecar="${archive}.sha256"
    (cd "$(dirname "$archive")" && sha256sum -- "$(basename "$archive")" >"$(basename "$sidecar")")
    chmod 0600 "$archive" "$sidecar"
    printf '%s %s\n' "$archive" "$sidecar"
}

# --- A. checksum failures -------------------------------------------------

t_checksum_mismatch() {
    local dir; dir="$(newdir)"
    local dest="$dir/dest"; mkdir -m 0700 -- "$dest"
    local src="$dir/src"; mkdir -p "$src"; : >"$src/f"
    read -r archive checksum < <(make_dir_backup "$dest" "$src" "cksumtest" "20260101T010101Z")
    printf '%s  %s\n' "$(printf 'a%.0s' $(seq 1 64))" "$(basename "$archive")" >"$checksum"

    local target="$dir/target"
    run_restore "BACKUP_ARCHIVE=$archive" "RECOVERY_TARGET=$target" "RESTORE_LIVE_DATA_PATH=$dir/nolive" -- "$ALWAYS_PASS_VALIDATOR"
    assert_restore_rc_nonzero || return 1
    assert_target_absent "$target" || return 1
}
run_case "checksum mismatch fails, target not created" t_checksum_mismatch

t_sidecar_empty() {
    local dir; dir="$(newdir)"
    local dest="$dir/dest"; mkdir -m 0700 -- "$dest"
    local src="$dir/src"; mkdir -p "$src"; : >"$src/f"
    read -r archive checksum < <(make_dir_backup "$dest" "$src" "sidecarempty" "20260101T020202Z")
    : >"$checksum"

    local target="$dir/target"
    run_restore "BACKUP_ARCHIVE=$archive" "RECOVERY_TARGET=$target" "RESTORE_LIVE_DATA_PATH=$dir/nolive" -- "$ALWAYS_PASS_VALIDATOR"
    assert_restore_rc_nonzero || return 1
    assert_target_absent "$target" || return 1
}
run_case "empty sidecar fails, target not created" t_sidecar_empty

t_sidecar_multiple_lines() {
    local dir; dir="$(newdir)"
    local dest="$dir/dest"; mkdir -m 0700 -- "$dest"
    local src="$dir/src"; mkdir -p "$src"; : >"$src/f"
    read -r archive checksum < <(make_dir_backup "$dest" "$src" "sidecarmulti" "20260101T030303Z")
    printf '%s\nextra line\n' "$(cat "$checksum")" >"$checksum.tmp"
    mv "$checksum.tmp" "$checksum"

    local target="$dir/target"
    run_restore "BACKUP_ARCHIVE=$archive" "RECOVERY_TARGET=$target" "RESTORE_LIVE_DATA_PATH=$dir/nolive" -- "$ALWAYS_PASS_VALIDATOR"
    assert_restore_rc_nonzero || return 1
    assert_out_contains "more than one line" || return 1
    assert_target_absent "$target" || return 1
}
run_case "multi-line sidecar fails, target not created" t_sidecar_multiple_lines

t_sidecar_digest_wrong_length() {
    local dir; dir="$(newdir)"
    local dest="$dir/dest"; mkdir -m 0700 -- "$dest"
    local src="$dir/src"; mkdir -p "$src"; : >"$src/f"
    read -r archive checksum < <(make_dir_backup "$dest" "$src" "sidecarshort" "20260101T040404Z")
    printf '%s  %s\n' "$(printf 'a%.0s' $(seq 1 63))" "$(basename "$archive")" >"$checksum"

    local target="$dir/target"
    run_restore "BACKUP_ARCHIVE=$archive" "RECOVERY_TARGET=$target" "RESTORE_LIVE_DATA_PATH=$dir/nolive" -- "$ALWAYS_PASS_VALIDATOR"
    assert_restore_rc_nonzero || return 1
    assert_target_absent "$target" || return 1
}
run_case "wrong-length sidecar digest fails, target not created" t_sidecar_digest_wrong_length

t_sidecar_digest_non_hex() {
    local dir; dir="$(newdir)"
    local dest="$dir/dest"; mkdir -m 0700 -- "$dest"
    local src="$dir/src"; mkdir -p "$src"; : >"$src/f"
    read -r archive checksum < <(make_dir_backup "$dest" "$src" "sidecarnonhex" "20260101T050505Z")
    printf '%s  %s\n' "$(printf 'g%.0s' $(seq 1 64))" "$(basename "$archive")" >"$checksum"

    local target="$dir/target"
    run_restore "BACKUP_ARCHIVE=$archive" "RECOVERY_TARGET=$target" "RESTORE_LIVE_DATA_PATH=$dir/nolive" -- "$ALWAYS_PASS_VALIDATOR"
    assert_restore_rc_nonzero || return 1
    assert_target_absent "$target" || return 1
}
run_case "non-hex sidecar digest fails, target not created" t_sidecar_digest_non_hex

t_sidecar_wrong_filename() {
    local dir; dir="$(newdir)"
    local dest="$dir/dest"; mkdir -m 0700 -- "$dest"
    local src="$dir/src"; mkdir -p "$src"; : >"$src/f"
    read -r archive checksum < <(make_dir_backup "$dest" "$src" "sidecarwrongname" "20260101T060606Z")
    local digest; digest="$(awk '{print $1}' "$checksum")"
    printf '%s  some-other-name.tar.gz\n' "$digest" >"$checksum"

    local target="$dir/target"
    run_restore "BACKUP_ARCHIVE=$archive" "RECOVERY_TARGET=$target" "RESTORE_LIVE_DATA_PATH=$dir/nolive" -- "$ALWAYS_PASS_VALIDATOR"
    assert_restore_rc_nonzero || return 1
    assert_out_contains "does not match the archive" || return 1
    assert_target_absent "$target" || return 1
}
run_case "sidecar filename field not matching the archive fails, target not created" t_sidecar_wrong_filename

t_sidecar_digest_valid_for_other_file() {
    local dir; dir="$(newdir)"
    local dest="$dir/dest"; mkdir -m 0700 -- "$dest"
    local src="$dir/src"; mkdir -p "$src"; : >"$src/f"
    read -r archive checksum < <(make_dir_backup "$dest" "$src" "sidecarotherfile" "20260101T070707Z")
    local other_digest; other_digest="$(printf 'not the archive' | sha256sum | cut -d' ' -f1)"
    printf '%s  %s\n' "$other_digest" "$(basename "$archive")" >"$checksum"

    local target="$dir/target"
    run_restore "BACKUP_ARCHIVE=$archive" "RECOVERY_TARGET=$target" "RESTORE_LIVE_DATA_PATH=$dir/nolive" -- "$ALWAYS_PASS_VALIDATOR"
    assert_restore_rc_nonzero || return 1
    assert_target_absent "$target" || return 1
}
run_case "sidecar digest valid-format but for a different file fails, target not created" t_sidecar_digest_valid_for_other_file

# --- B. full pre-extraction archive rejection ------------------------------

assert_crafted_rejected() {
    local spec="$1" expected="$2"
    local archive checksum
    read -r archive checksum < <(publish_crafted_archive "$spec")
    local target="$D/target-$$-$RANDOM"
    run_restore "BACKUP_ARCHIVE=$archive" "RECOVERY_TARGET=$target" "RESTORE_LIVE_DATA_PATH=$D/nolive-$$-$RANDOM" -- "$ALWAYS_PASS_VALIDATOR"
    assert_restore_rc_nonzero || return 1
    [[ -n "$expected" ]] && { assert_out_contains "$expected" || return 1; }
    assert_target_absent "$target" || return 1
    return 0
}

t_crafted_dotdot() {
    local mf; mf="$(crafted_dir_manifest_file)"
    assert_crafted_rejected "$(printf 'dir\t%s\nregfile\t%s/manifest\t%s\nreg\t%s/data/mysrc/../evil\thello\n' "$TOPDIR" "$TOPDIR" "$mf" "$TOPDIR")" "unsafe component"
}
run_case "hand-crafted archive with a .. member is rejected before extraction" t_crafted_dotdot

t_crafted_absolute() {
    local mf; mf="$(crafted_dir_manifest_file)"
    assert_crafted_rejected "$(printf 'dir\t%s\nregfile\t%s/manifest\t%s\nreg\t/evil\thello\n' "$TOPDIR" "$TOPDIR" "$mf")" "absolute path"
}
run_case "hand-crafted archive with an absolute member is rejected before extraction" t_crafted_absolute

t_crafted_symlink() {
    local mf; mf="$(crafted_dir_manifest_file)"
    assert_crafted_rejected "$(printf 'dir\t%s\nregfile\t%s/manifest\t%s\ndir\t%s/data\ndir\t%s/data/mysrc\nreg\t%s/data/mysrc/f.txt\thello\nsym\t%s/data/mysrc/evil\t/etc/passwd\n' "$TOPDIR" "$TOPDIR" "$mf" "$TOPDIR" "$TOPDIR" "$TOPDIR" "$TOPDIR")" "not a regular file or directory"
}
run_case "hand-crafted archive with a symlink member is rejected before extraction" t_crafted_symlink

t_crafted_hardlink() {
    local mf; mf="$(crafted_dir_manifest_file)"
    assert_crafted_rejected "$(printf 'dir\t%s\nregfile\t%s/manifest\t%s\ndir\t%s/data\ndir\t%s/data/mysrc\nreg\t%s/data/mysrc/f.txt\thello\nhardlink\t%s/data/mysrc/evil\t%s/manifest\n' "$TOPDIR" "$TOPDIR" "$mf" "$TOPDIR" "$TOPDIR" "$TOPDIR" "$TOPDIR" "$TOPDIR")" "not a regular file or directory"
}
run_case "hand-crafted archive with a hardlink member is rejected before extraction" t_crafted_hardlink

t_crafted_fifo() {
    local mf; mf="$(crafted_dir_manifest_file)"
    assert_crafted_rejected "$(printf 'dir\t%s\nregfile\t%s/manifest\t%s\ndir\t%s/data\ndir\t%s/data/mysrc\nreg\t%s/data/mysrc/f.txt\thello\nfifo\t%s/data/mysrc/evil\n' "$TOPDIR" "$TOPDIR" "$mf" "$TOPDIR" "$TOPDIR" "$TOPDIR" "$TOPDIR")" "not a regular file or directory"
}
run_case "hand-crafted archive with a FIFO member is rejected before extraction" t_crafted_fifo

t_crafted_duplicate_normalized() {
    local mf; mf="$(crafted_dir_manifest_file)"
    assert_crafted_rejected "$(printf 'dir\t%s\nregfile\t%s/manifest\t%s\ndir\t%s/data\ndir\t%s/data/\n' "$TOPDIR" "$TOPDIR" "$mf" "$TOPDIR" "$TOPDIR")" "duplicate member path"
}
run_case "hand-crafted archive with a normalized duplicate member is rejected before extraction" t_crafted_duplicate_normalized

t_crafted_unsupported_extra_member() {
    local mf; mf="$(crafted_dir_manifest_file)"
    assert_crafted_rejected "$(printf 'dir\t%s\nregfile\t%s/manifest\t%s\ndir\t%s/data\ndir\t%s/data/mysrc\nreg\t%s/data/mysrc/f.txt\thello\nreg\t%s/stray.txt\tx\n' "$TOPDIR" "$TOPDIR" "$mf" "$TOPDIR" "$TOPDIR" "$TOPDIR" "$TOPDIR")" "outside the supported layout"
}
run_case "hand-crafted archive with an unsupported extra member is rejected before extraction" t_crafted_unsupported_extra_member

t_crafted_malformed_manifest() {
    local badmf="$D/bad-manifest-$$-$RANDOM.txt"
    printf 'BACKUP_ID=crafted-id\nSOURCE_KIND=dir\nCREATED_AT=20260101T000000Z\n' >"$badmf"
    assert_crafted_rejected "$(printf 'dir\t%s\nregfile\t%s/manifest\t%s\ndir\t%s/data\ndir\t%s/data/mysrc\nreg\t%s/data/mysrc/f.txt\thello\n' "$TOPDIR" "$TOPDIR" "$badmf" "$TOPDIR" "$TOPDIR" "$TOPDIR")" "missing required key"
}
run_case "hand-crafted archive with a malformed manifest is rejected before extraction" t_crafted_malformed_manifest

t_crafted_count_mismatch() {
    local badmf="$D/bad-manifest-count-$$-$RANDOM.txt"
    printf 'BACKUP_ID=crafted-id\nSOURCE_KIND=dir\nCREATED_AT=20260101T000000Z\nFORMAT_VERSION=1\nFILE_COUNT=99\nTOTAL_BYTES=5\n' >"$badmf"
    assert_crafted_rejected "$(printf 'dir\t%s\nregfile\t%s/manifest\t%s\ndir\t%s/data\ndir\t%s/data/mysrc\nreg\t%s/data/mysrc/f.txt\thello\n' "$TOPDIR" "$TOPDIR" "$badmf" "$TOPDIR" "$TOPDIR" "$TOPDIR")" "FILE_COUNT does not match"
}
run_case "hand-crafted archive with manifest/payload count mismatch is rejected before extraction" t_crafted_count_mismatch

t_crafted_db_digest_mismatch() {
    local badmf="$D/bad-manifest-dbdigest-$$-$RANDOM.txt"
    printf 'BACKUP_ID=crafted-id\nSOURCE_KIND=db\nCREATED_AT=20260101T000000Z\nFORMAT_VERSION=1\nDUMP_SIZE_BYTES=5\nDUMP_SHA256=%s\n' "$(printf 'b%.0s' $(seq 1 64))" >"$badmf"
    assert_crafted_rejected "$(printf 'dir\t%s\nregfile\t%s/manifest\t%s\ndir\t%s/dump\nreg\t%s/dump/dump.bin\thello\n' "$TOPDIR" "$TOPDIR" "$badmf" "$TOPDIR" "$TOPDIR")" "DUMP_SHA256 does not match"
}
run_case "hand-crafted db-kind archive with digest mismatch is rejected before extraction" t_crafted_db_digest_mismatch

t_crafted_db_zero_byte_payload() {
    local badmf="$D/bad-manifest-dbzero-$$-$RANDOM.txt"
    printf 'BACKUP_ID=crafted-id\nSOURCE_KIND=db\nCREATED_AT=20260101T000000Z\nFORMAT_VERSION=1\nDUMP_SIZE_BYTES=0\nDUMP_SHA256=%s\n' "$(printf 'b%.0s' $(seq 1 64))" >"$badmf"
    assert_crafted_rejected "$(printf 'dir\t%s\nregfile\t%s/manifest\t%s\ndir\t%s/dump\nreg\t%s/dump/dump.bin\t\n' "$TOPDIR" "$TOPDIR" "$badmf" "$TOPDIR" "$TOPDIR")" "greater than zero"
}
run_case "hand-crafted db-kind archive with a zero-byte dump payload is rejected before extraction" t_crafted_db_zero_byte_payload

# --- C. external archive TOCTOU / snapshot ---------------------------------
#
# A test-only `cp` shadowed via PATH performs the real snapshot copy, then --
# only when armed by this test -- corrupts the EXTERNAL archive path
# immediately afterward, before returning to restore.sh. This deterministically
# proves restore.sh's checksum verification, Python validation, and
# extraction all operate on the pre-corruption snapshot bytes, not the
# now-corrupted external file, without any production code change.

CP_TOCTOU_WRAPPER_DIR="$D/cp-toctou-wrapper"
mkdir -p "$CP_TOCTOU_WRAPPER_DIR"
REAL_CP_PATH="$(command -v cp)"
cat >"$CP_TOCTOU_WRAPPER_DIR/cp" <<EOF
#!/usr/bin/env bash
"$REAL_CP_PATH" "\$@"
rc=\$?
if [[ -n "\${TEST_CORRUPT_AFTER_SNAPSHOT:-}" ]]; then
    printf 'CORRUPTED-BY-TEST-AFTER-SNAPSHOT' > "\$TEST_CORRUPT_AFTER_SNAPSHOT"
fi
exit "\$rc"
EOF
chmod +x "$CP_TOCTOU_WRAPPER_DIR/cp"

t_snapshot_toctou() {
    local dir; dir="$(newdir)"
    local dest="$dir/dest"; mkdir -m 0700 -- "$dest"
    local src="$dir/src"; mkdir -p "$src"
    build_dummy_source_tree "$src"
    local archive checksum
    read -r archive checksum < <(make_dir_backup "$dest" "$src" "toctoutest" "20260101T080808Z")

    local expected_tree="$dir/expected-tree"
    cp -a "$src" "$expected_tree"

    local target="$dir/target"
    local marker="$dir/validator-invoked"
    local rc=0
    LAST_OUT="$(env PATH="$CP_TOCTOU_WRAPPER_DIR:$PATH" TEST_CORRUPT_AFTER_SNAPSHOT="$archive" \
        BACKUP_ARCHIVE="$archive" RECOVERY_TARGET="$target" RESTORE_LIVE_DATA_PATH="$dir/nolive" \
        EXPECTED_TREE="$expected_tree" VALIDATOR_INVOKED_MARKER="$marker" \
        bash "$RESTORE_SH" -- "$DIR_EXACT_MATCH_VALIDATOR" 2>&1)" || rc=$?
    LAST_RC=$rc

    assert_restore_rc_eq 0 || return 1
    [[ -f "$marker" ]] || { fail_case "validator was not invoked"; return 1; }
    # the external archive path really was corrupted by the wrapper --
    # confirming the corruption happened, not that restore somehow avoided it
    [[ "$(cat "$archive")" == "CORRUPTED-BY-TEST-AFTER-SNAPSHOT" ]] || { fail_case "test harness failed to corrupt the external archive"; return 1; }
}
run_case "restore validates/extracts the pre-corruption snapshot even after the external archive is corrupted post-snapshot" t_snapshot_toctou

# --- D. recovery target refusal -------------------------------------------

t_target_existing_directory() {
    local dir; dir="$(newdir)"
    local dest="$dir/dest"; mkdir -m 0700 -- "$dest"
    local src="$dir/src"; mkdir -p "$src"; : >"$src/f"
    local archive checksum
    read -r archive checksum < <(make_dir_backup "$dest" "$src" "targetdir" "20260101T090909Z")
    local target="$dir/target"; mkdir "$target"
    run_restore "BACKUP_ARCHIVE=$archive" "RECOVERY_TARGET=$target" "RESTORE_LIVE_DATA_PATH=$dir/nolive" -- "$ALWAYS_PASS_VALIDATOR"
    assert_restore_rc_nonzero || return 1
}
run_case "RECOVERY_TARGET already existing as a directory is refused" t_target_existing_directory

t_target_existing_file() {
    local dir; dir="$(newdir)"
    local dest="$dir/dest"; mkdir -m 0700 -- "$dest"
    local src="$dir/src"; mkdir -p "$src"; : >"$src/f"
    local archive checksum
    read -r archive checksum < <(make_dir_backup "$dest" "$src" "targetfile" "20260101T101010Z")
    local target="$dir/target"; : >"$target"
    run_restore "BACKUP_ARCHIVE=$archive" "RECOVERY_TARGET=$target" "RESTORE_LIVE_DATA_PATH=$dir/nolive" -- "$ALWAYS_PASS_VALIDATOR"
    assert_restore_rc_nonzero || return 1
}
run_case "RECOVERY_TARGET already existing as a regular file is refused" t_target_existing_file

t_target_existing_symlink() {
    local dir; dir="$(newdir)"
    local dest="$dir/dest"; mkdir -m 0700 -- "$dest"
    local src="$dir/src"; mkdir -p "$src"; : >"$src/f"
    local archive checksum
    read -r archive checksum < <(make_dir_backup "$dest" "$src" "targetsym" "20260101T111111Z")
    local real="$dir/real"; mkdir "$real"
    local target="$dir/target"; ln -s "$real" "$target"
    run_restore "BACKUP_ARCHIVE=$archive" "RECOVERY_TARGET=$target" "RESTORE_LIVE_DATA_PATH=$dir/nolive" -- "$ALWAYS_PASS_VALIDATOR"
    assert_restore_rc_nonzero || return 1
}
run_case "RECOVERY_TARGET already existing as a symlink is refused" t_target_existing_symlink

t_target_dangling_symlink() {
    local dir; dir="$(newdir)"
    local dest="$dir/dest"; mkdir -m 0700 -- "$dest"
    local src="$dir/src"; mkdir -p "$src"; : >"$src/f"
    local archive checksum
    read -r archive checksum < <(make_dir_backup "$dest" "$src" "targetdangling" "20260101T121212Z")
    local target="$dir/target"; ln -s "$dir/nowhere" "$target"
    run_restore "BACKUP_ARCHIVE=$archive" "RECOVERY_TARGET=$target" "RESTORE_LIVE_DATA_PATH=$dir/nolive" -- "$ALWAYS_PASS_VALIDATOR"
    assert_restore_rc_nonzero || return 1
}
run_case "RECOVERY_TARGET as a dangling symlink is refused" t_target_dangling_symlink

t_target_parent_missing() {
    local dir; dir="$(newdir)"
    local dest="$dir/dest"; mkdir -m 0700 -- "$dest"
    local src="$dir/src"; mkdir -p "$src"; : >"$src/f"
    local archive checksum
    read -r archive checksum < <(make_dir_backup "$dest" "$src" "targetnoparent" "20260101T131313Z")
    local target="$dir/missing-parent/target"
    run_restore "BACKUP_ARCHIVE=$archive" "RECOVERY_TARGET=$target" "RESTORE_LIVE_DATA_PATH=$dir/nolive" -- "$ALWAYS_PASS_VALIDATOR"
    assert_restore_rc_nonzero || return 1
}
run_case "RECOVERY_TARGET whose parent is missing is refused" t_target_parent_missing

# --- E. live-data guard ----------------------------------------------------

t_live_target_equal() {
    local dir; dir="$(newdir)"
    local dest="$dir/dest"; mkdir -m 0700 -- "$dest"
    local src="$dir/src"; mkdir -p "$src"; : >"$src/f"
    local archive checksum
    read -r archive checksum < <(make_dir_backup "$dest" "$src" "liveeq" "20260101T141414Z")
    local live="$dir/live"; mkdir -p "$live"
    run_restore "BACKUP_ARCHIVE=$archive" "RECOVERY_TARGET=$live" "RESTORE_LIVE_DATA_PATH=$live" -- "$ALWAYS_PASS_VALIDATOR"
    assert_restore_rc_nonzero || return 1
}
run_case "RECOVERY_TARGET == RESTORE_LIVE_DATA_PATH is refused" t_live_target_equal

t_live_target_nested_under_live() {
    local dir; dir="$(newdir)"
    local dest="$dir/dest"; mkdir -m 0700 -- "$dest"
    local src="$dir/src"; mkdir -p "$src"; : >"$src/f"
    local archive checksum
    read -r archive checksum < <(make_dir_backup "$dest" "$src" "livenest" "20260101T151515Z")
    local live="$dir/live"; mkdir -p "$live"
    local target="$live/nested-target"
    run_restore "BACKUP_ARCHIVE=$archive" "RECOVERY_TARGET=$target" "RESTORE_LIVE_DATA_PATH=$live" -- "$ALWAYS_PASS_VALIDATOR"
    assert_restore_rc_nonzero || return 1
}
run_case "RECOVERY_TARGET nested under RESTORE_LIVE_DATA_PATH is refused" t_live_target_nested_under_live

t_live_nested_under_target() {
    local dir; dir="$(newdir)"
    local dest="$dir/dest"; mkdir -m 0700 -- "$dest"
    local src="$dir/src"; mkdir -p "$src"; : >"$src/f"
    local archive checksum
    read -r archive checksum < <(make_dir_backup "$dest" "$src" "targetnestlive" "20260101T161616Z")
    local target="$dir/target"
    local live="$target/nested-live"
    run_restore "BACKUP_ARCHIVE=$archive" "RECOVERY_TARGET=$target" "RESTORE_LIVE_DATA_PATH=$live" -- "$ALWAYS_PASS_VALIDATOR"
    assert_restore_rc_nonzero || return 1
}
run_case "RESTORE_LIVE_DATA_PATH nested under RECOVERY_TARGET is refused" t_live_nested_under_target

t_live_existing_symlink_aliasing_target() {
    local dir; dir="$(newdir)"
    local dest="$dir/dest"; mkdir -m 0700 -- "$dest"
    local src="$dir/src"; mkdir -p "$src"; : >"$src/f"
    local archive checksum
    read -r archive checksum < <(make_dir_backup "$dest" "$src" "livesymalias" "20260101T171717Z")
    local target="$dir/target"
    local live="$dir/live-alias"
    ln -s "$target" "$live"
    run_restore "BACKUP_ARCHIVE=$archive" "RECOVERY_TARGET=$target" "RESTORE_LIVE_DATA_PATH=$live" -- "$ALWAYS_PASS_VALIDATOR"
    assert_restore_rc_nonzero || return 1
}
run_case "existing live-path symlink resolving to the recovery target's location is refused" t_live_existing_symlink_aliasing_target

t_live_dangling_symlink() {
    local dir; dir="$(newdir)"
    local dest="$dir/dest"; mkdir -m 0700 -- "$dest"
    local src="$dir/src"; mkdir -p "$src"; : >"$src/f"
    local archive checksum
    read -r archive checksum < <(make_dir_backup "$dest" "$src" "livedangling" "20260101T181818Z")
    local target="$dir/target"
    local live="$dir/live-dangling"
    ln -s "$dir/nowhere" "$live"
    run_restore "BACKUP_ARCHIVE=$archive" "RECOVERY_TARGET=$target" "RESTORE_LIVE_DATA_PATH=$live" -- "$ALWAYS_PASS_VALIDATOR"
    assert_restore_rc_nonzero || return 1
}
run_case "dangling live-path symlink is refused as ambiguous" t_live_dangling_symlink

t_live_deleted_ordinary_path_still_refused() {
    local dir; dir="$(newdir)"
    local dest="$dir/dest"; mkdir -m 0700 -- "$dest"
    local src="$dir/src"; mkdir -p "$src"; : >"$src/f"
    local archive checksum
    read -r archive checksum < <(make_dir_backup "$dest" "$src" "livedeleted" "20260101T191919Z")
    local live="$dir/live"; mkdir -p "$live"
    rm -rf "$live"
    run_restore "BACKUP_ARCHIVE=$archive" "RECOVERY_TARGET=$live" "RESTORE_LIVE_DATA_PATH=$live" -- "$ALWAYS_PASS_VALIDATOR"
    assert_restore_rc_nonzero || return 1
}
run_case "restoring onto the exact path of an already-deleted ordinary live source is still refused" t_live_deleted_ordinary_path_still_refused

# --- F. successful directory restore ---------------------------------------

t_success_dir_restore() {
    local dir; dir="$(newdir)"
    local dest="$dir/dest"; mkdir -m 0700 -- "$dest"
    local src="$dir/src"; mkdir -p "$src"
    build_dummy_source_tree "$src"
    local archive checksum
    read -r archive checksum < <(make_dir_backup "$dest" "$src" "dirrestore" "20260101T202020Z")

    local expected_tree="$dir/expected-tree"
    cp -a "$src" "$expected_tree"
    rm -rf "$src"

    local target="$dir/recovery-target"
    local marker="$dir/validator-invoked"
    run_restore "BACKUP_ARCHIVE=$archive" "RECOVERY_TARGET=$target" "RESTORE_LIVE_DATA_PATH=$src" "EXPECTED_TREE=$expected_tree" "VALIDATOR_INVOKED_MARKER=$marker" -- "$DIR_EXACT_MATCH_VALIDATOR"
    assert_restore_rc_eq 0 || return 1

    [[ -d "$target" ]] || { fail_case "recovery target missing"; return 1; }
    [[ ! -e "$target/.restore-control" ]] || { fail_case ".restore-control was not removed"; return 1; }
    [[ -f "$marker" ]] || { fail_case "validator was not invoked"; return 1; }
    [[ "$(stat -c '%a' "$target")" == "700" ]] || { fail_case "recovery target root mode is not 0700"; return 1; }

    local payload="$target/payload/dirrestore-20260101T202020Z/data/src"
    [[ -d "$payload" ]] || { fail_case "payload path missing: $payload"; return 1; }
    diff -r "$expected_tree" "$payload" >"$dir/diffout.txt" 2>&1 || { fail_case "restored tree differs from expected: $(cat "$dir/diffout.txt")"; return 1; }

    local hit
    hit="$(find "$payload" -not -type f -not -type d -print -quit)"
    [[ -z "$hit" ]] || { fail_case "restored tree has an unsupported entry type: $hit"; return 1; }
    hit="$(find "$payload" -type f -links +1 -print -quit)"
    [[ -z "$hit" ]] || { fail_case "restored tree has a hardlinked file: $hit"; return 1; }
}
run_case "successful directory restore: exact content, permissions, viable target" t_success_dir_restore

# --- G. successful db restore -----------------------------------------

t_success_db_restore() {
    local dir; dir="$(newdir)"
    local dest="$dir/dest"; mkdir -m 0700 -- "$dest"
    local live="$dir/live"; mkdir -p "$live"
    local archive checksum
    read -r archive checksum < <(make_db_backup "$dest" "$live" "dbrestore" "20260101T212121Z" "$DB_PRODUCER")

    local expected_dump="$dir/expected-dump.bin"
    printf '%s' "DETERMINISTIC_DUMP_BYTES_FOR_RESTORE_TESTS" >"$expected_dump"

    local target="$dir/recovery-target"
    local marker="$dir/validator-invoked"
    run_restore "BACKUP_ARCHIVE=$archive" "RECOVERY_TARGET=$target" "RESTORE_LIVE_DATA_PATH=$dir/some-other-live" "EXPECTED_DUMP_FILE=$expected_dump" "VALIDATOR_INVOKED_MARKER=$marker" -- "$DB_EXACT_MATCH_VALIDATOR"
    assert_restore_rc_eq 0 || return 1
    [[ -f "$marker" ]] || { fail_case "validator was not invoked"; return 1; }

    local payload="$target/payload/dbrestore-20260101T212121Z/dump/dump.bin"
    [[ -f "$payload" ]] || { fail_case "payload path missing: $payload"; return 1; }
    cmp "$expected_dump" "$payload" || { fail_case "restored dump bytes differ from expected"; return 1; }
    # transport/publication byte-exactness only -- not a claim of PostgreSQL
    # logical restore compatibility.
}
run_case "successful synthetic db restore: exact bytes, transport-only" t_success_db_restore

# --- H. validator failure --------------------------------------------

t_validator_failure() {
    local dir; dir="$(newdir)"
    local dest="$dir/dest"; mkdir -m 0700 -- "$dest"
    local src="$dir/src"; mkdir -p "$src"; : >"$src/f"
    local archive checksum
    read -r archive checksum < <(make_dir_backup "$dest" "$src" "validatorfail" "20260101T222222Z")

    local target="$dir/target"
    run_restore "BACKUP_ARCHIVE=$archive" "RECOVERY_TARGET=$target" "RESTORE_LIVE_DATA_PATH=$dir/nolive" -- "$ALWAYS_FAIL_VALIDATOR"
    assert_restore_rc_nonzero || return 1
    assert_target_absent "$target" || return 1
}
run_case "workload validator failure fails the restore and leaves no viable/leftover target" t_validator_failure

# --- I. ownership-proof mismatch (direct unit exercise) --------------------

t_ownership_mismatch_token() {
    local dir; dir="$(newdir)"
    local target="$dir/target"
    mkdir -m 0700 -- "$target"
    local out rc=0
    out="$(bash -c '
        source "$1"
        RECOVERY_TARGET_CLAIMED="$2"
        RECOVERY_TARGET_DEV_INODE="$(stat_dev_inode "$2")"
        RECOVERY_TARGET_TOKEN="expected-token-value"
        cleanup_recovery_target_if_owned
        echo "STILL_PRESENT=$([[ -d "$2" ]] && echo yes || echo no)"
    ' "restore-ownership-test" "$RESTORE_SH" "$target" 2>&1)" || rc=$?
    [[ -d "$target" ]] || { fail_case "target was deleted despite a token mismatch"; return 1; }
    [[ "$out" == *"could not be reverified"* ]] || { fail_case "expected a refusal diagnostic, got: $out"; return 1; }
    [[ "$out" == *"STILL_PRESENT=yes"* ]] || { fail_case "target presence check failed: $out"; return 1; }
}
run_case "cleanup_recovery_target_if_owned refuses deletion on a control-token mismatch" t_ownership_mismatch_token

t_ownership_mismatch_inode() {
    local dir; dir="$(newdir)"
    local target="$dir/target"
    mkdir -m 0700 -- "$target"
    local out rc=0
    out="$(bash -c '
        source "$1"
        RECOVERY_TARGET_CLAIMED="$2"
        RECOVERY_TARGET_DEV_INODE="0:0"
        RECOVERY_TARGET_TOKEN="whatever"
        cleanup_recovery_target_if_owned
        echo "STILL_PRESENT=$([[ -d "$2" ]] && echo yes || echo no)"
    ' "restore-ownership-test" "$RESTORE_SH" "$target" 2>&1)" || rc=$?
    [[ -d "$target" ]] || { fail_case "target was deleted despite a device/inode mismatch"; return 1; }
    [[ "$out" == *"could not be reverified"* ]] || { fail_case "expected a refusal diagnostic, got: $out"; return 1; }
    [[ "$out" == *"STILL_PRESENT=yes"* ]] || { fail_case "target presence check failed: $out"; return 1; }
}
run_case "cleanup_recovery_target_if_owned refuses deletion on a device/inode mismatch" t_ownership_mismatch_inode

# --- J. interrupted recovery target -----------------------------------

t_interrupted_target_refused() {
    local dir; dir="$(newdir)"
    local dest="$dir/dest"; mkdir -m 0700 -- "$dest"
    local src="$dir/src"; mkdir -p "$src"; : >"$src/f"
    local archive checksum
    read -r archive checksum < <(make_dir_backup "$dest" "$src" "interrupted" "20260101T232323Z")

    local target="$dir/target"
    mkdir -m 0700 -- "$target"
    printf 'leftover-token' >"$target/.restore-control"
    chmod 0600 "$target/.restore-control"

    run_restore "BACKUP_ARCHIVE=$archive" "RECOVERY_TARGET=$target" "RESTORE_LIVE_DATA_PATH=$dir/nolive" -- "$ALWAYS_PASS_VALIDATOR"
    assert_restore_rc_nonzero || return 1
    [[ -d "$target" ]] || { fail_case "pre-existing interrupted target was removed"; return 1; }
    [[ -f "$target/.restore-control" ]] || { fail_case "interrupted target's control marker was removed"; return 1; }
    [[ "$(cat "$target/.restore-control")" == "leftover-token" ]] || { fail_case "interrupted target's control marker content changed"; return 1; }
}
run_case "a pre-existing interrupted target (with .restore-control present) refuses and is left unchanged" t_interrupted_target_refused

# --- K. signal status ---------------------------------------------------
#
# A test-only `cp` shadowed via PATH (the same mechanism as section C) sends
# the requested signal to its parent (the restore.sh process) immediately
# after completing the snapshot copy -- a reliable, early, deterministic
# injection point, well before any Recovery Target mutation. This proves the
# core SIGINT->130 / SIGTERM->143 / no-false-success contract live. The
# separate case of a signal arriving after a Recovery Target has already been
# claimed is covered by construction: cleanup on that path always goes
# through the same cleanup_recovery_target_if_owned function directly
# exercised (and proven ownership-gated) in section I above.

CP_SIGNAL_WRAPPER_DIR="$D/cp-signal-wrapper"
mkdir -p "$CP_SIGNAL_WRAPPER_DIR"
cat >"$CP_SIGNAL_WRAPPER_DIR/cp" <<EOF
#!/usr/bin/env bash
"$REAL_CP_PATH" "\$@"
rc=\$?
if [[ -n "\${TEST_SIGNAL_AFTER_SNAPSHOT:-}" ]]; then
    kill -s "\$TEST_SIGNAL_AFTER_SNAPSHOT" "\$PPID"
fi
exit "\$rc"
EOF
chmod +x "$CP_SIGNAL_WRAPPER_DIR/cp"

run_restore_with_signal_wrapper() {
    local archive="$1" target="$2" live="$3" signal="$4"
    local rc=0
    LAST_OUT="$(env PATH="$CP_SIGNAL_WRAPPER_DIR:$PATH" TEST_SIGNAL_AFTER_SNAPSHOT="$signal" \
        BACKUP_ARCHIVE="$archive" RECOVERY_TARGET="$target" RESTORE_LIVE_DATA_PATH="$live" \
        bash "$RESTORE_SH" -- "$ALWAYS_PASS_VALIDATOR" 2>&1)" || rc=$?
    LAST_RC=$rc
}

t_sigint_early() {
    local dir; dir="$(newdir)"
    local dest="$dir/dest"; mkdir -m 0700 -- "$dest"
    local src="$dir/src"; mkdir -p "$src"; : >"$src/f"
    local archive checksum
    read -r archive checksum < <(make_dir_backup "$dest" "$src" "sigintrestore" "20260101T000001Z")

    local target="$dir/target"
    run_restore_with_signal_wrapper "$archive" "$target" "$dir/nolive" INT
    assert_restore_rc_eq 130 || return 1
    assert_target_absent "$target" || return 1
}
run_case "SIGINT shortly after snapshot creation: exits 130, no false success, target not created" t_sigint_early

t_sigterm_early() {
    local dir; dir="$(newdir)"
    local dest="$dir/dest"; mkdir -m 0700 -- "$dest"
    local src="$dir/src"; mkdir -p "$src"; : >"$src/f"
    local archive checksum
    read -r archive checksum < <(make_dir_backup "$dest" "$src" "sigtermrestore" "20260101T000002Z")

    local target="$dir/target"
    run_restore_with_signal_wrapper "$archive" "$target" "$dir/nolive" TERM
    assert_restore_rc_eq 143 || return 1
    assert_target_absent "$target" || return 1
}
run_case "SIGTERM shortly after snapshot creation: exits 143, no false success, target not created" t_sigterm_early

echo
echo "== summary =="
echo "$PASSED passed, $FAILED failed"
if ((FAILED > 0)); then
    echo "Failed cases:"
    printf '  - %s\n' "${FAILED_NAMES[@]}"
    exit 1
fi

#!/usr/bin/env bash
#
# Tests for backup/tar_metadata_check.py -- the single authoritative
# implementation of the generic archive contract (member path/type safety,
# exact layout, manifest strictness, manifest-vs-payload consistency).
#
# Archives are constructed with a small Python stdlib `tarfile` fixture
# builder (embedded below) rather than the GNU `tar` CLI, since several
# required fixtures (absolute member paths, `..` components, symlink/
# hardlink/FIFO/device members, duplicate or aliased member paths) cannot be
# expressed via ordinary `tar` invocations. Nothing here weakens the
# validator to make a fixture easier to build -- every fixture that should
# be rejected is a genuinely malformed/unsafe archive.
#
# Run with:
#   bash backup/tar_metadata_check.test.sh
#
# Every scratch file lives under one trapped mktemp directory. No sudo, no
# sleep, no repo-tree writes.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATOR="$SCRIPT_DIR/tar_metadata_check.py"

D="$(mktemp -d)"
trap 'rm -rf -- "$D"' EXIT

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
            if len(parts) > 3:
                ti.linkname = parts[3]
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
        elif kind == 'chr':
            ti.type = tarfile.CHRTYPE
            ti.devmajor = 1
            ti.devminor = 5
            tf.addfile(ti)
        else:
            raise SystemExit('build_archive.py: unknown kind: ' + kind)
    tf.close()

main()
PYEOF

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

build_archive() {
    local archive="$1"
    python3 "$BUILDER_PY" "$archive"
}

# Runs the validator, returns its exit code via $?, and leaves stdout in
# $VALIDATOR_STDOUT / stderr+stdout combined in $VALIDATOR_COMBINED.
invoke_validator() {
    local archive="$1" topdir="$2"
    local rc=0
    VALIDATOR_STDOUT="$(python3 "$VALIDATOR" "$archive" "$topdir" 2>"$D/stderr.tmp")" || rc=$?
    VALIDATOR_STDERR="$(cat "$D/stderr.tmp")"
    return "$rc"
}

assert_pass_contains() {
    local needle="$1"
    [[ "$VALIDATOR_STDOUT" == *"$needle"* ]] || { fail_case "expected stdout to contain [$needle], got: $VALIDATOR_STDOUT"; return 1; }
    return 0
}

assert_fail_contains() {
    local needle="$1"
    [[ "$VALIDATOR_STDERR" == *"$needle"* ]] || { fail_case "expected stderr to contain [$needle], got: $VALIDATOR_STDERR"; return 1; }
    [[ -z "$VALIDATOR_STDOUT" ]] || { fail_case "expected no stdout on failure, got: $VALIDATOR_STDOUT"; return 1; }
    return 0
}

TOPDIR="myid-20260101T000000Z"

valid_dir_manifest_file() {
    local f="$D/manifest-dir.txt"
    printf 'BACKUP_ID=myid\nSOURCE_KIND=dir\nCREATED_AT=20260101T000000Z\nFORMAT_VERSION=1\nFILE_COUNT=3\nTOTAL_BYTES=10\n' >"$f"
    printf '%s' "$f"
}

DB_DUMP_CONTENT="FAKE_DUMP_BYTES_12345"
DB_DUMP_SHA256="$(printf '%s' "$DB_DUMP_CONTENT" | sha256sum | cut -d' ' -f1)"
DB_DUMP_SIZE="${#DB_DUMP_CONTENT}"

valid_db_manifest_file() {
    local f="$D/manifest-db.txt"
    printf 'BACKUP_ID=myid\nSOURCE_KIND=db\nCREATED_AT=20260101T000000Z\nFORMAT_VERSION=1\nDUMP_SIZE_BYTES=%s\nDUMP_SHA256=%s\n' \
        "$DB_DUMP_SIZE" "$DB_DUMP_SHA256" >"$f"
    printf '%s' "$f"
}

# ---------------------------------------------------------------------
# SUCCESS CASES
# ---------------------------------------------------------------------

t_success_dir() {
    local archive="$D/success-dir.tar.gz"
    local mf; mf="$(valid_dir_manifest_file)"
    {
        printf 'dir\t%s\n' "$TOPDIR"
        printf 'regfile\t%s/manifest\t%s\n' "$TOPDIR" "$mf"
        printf 'dir\t%s/data\n' "$TOPDIR"
        printf 'dir\t%s/data/mysrc\n' "$TOPDIR"
        printf 'reg\t%s/data/mysrc/file1.txt\thello\n' "$TOPDIR"
        printf 'dir\t%s/data/mysrc/nested\n' "$TOPDIR"
        printf 'reg\t%s/data/mysrc/nested/file2.txt\tworld\n' "$TOPDIR"
        printf 'reg\t%s/data/mysrc/empty.txt\t\n' "$TOPDIR"
    } | build_archive "$archive"
    invoke_validator "$archive" "$TOPDIR" || { fail_case "expected PASS, got rc=$? stderr=$VALIDATOR_STDERR"; return 1; }
    assert_pass_contains "BACKUP_ID=myid" || return 1
    assert_pass_contains "SOURCE_KIND=dir" || return 1
    assert_pass_contains "FILE_COUNT=3" || return 1
    assert_pass_contains "TOTAL_BYTES=10" || return 1
    assert_pass_contains "DATA_BASENAME=mysrc" || return 1
    return 0
}
run_case "valid dir-kind archive passes with correct KEY=value output" t_success_dir

t_success_db() {
    local archive="$D/success-db.tar.gz"
    local mf; mf="$(valid_db_manifest_file)"
    {
        printf 'dir\t%s\n' "$TOPDIR"
        printf 'regfile\t%s/manifest\t%s\n' "$TOPDIR" "$mf"
        printf 'dir\t%s/dump\n' "$TOPDIR"
        printf 'reg\t%s/dump/dump.bin\t%s\n' "$TOPDIR" "$DB_DUMP_CONTENT"
    } | build_archive "$archive"
    invoke_validator "$archive" "$TOPDIR" || { fail_case "expected PASS, got rc=$? stderr=$VALIDATOR_STDERR"; return 1; }
    assert_pass_contains "SOURCE_KIND=db" || return 1
    assert_pass_contains "DUMP_SIZE_BYTES=$DB_DUMP_SIZE" || return 1
    assert_pass_contains "DUMP_SHA256=$DB_DUMP_SHA256" || return 1
    return 0
}
run_case "valid db-kind archive passes with correct size/digest" t_success_db

# ---------------------------------------------------------------------
# PATH / MEMBER SAFETY
# ---------------------------------------------------------------------

simple_fail_case() {
    local desc="$1" expected="$2" spec="$3"
    local archive="$D/fail-$$-$RANDOM.tar.gz"
    printf '%s' "$spec" | build_archive "$archive"
    invoke_validator "$archive" "$TOPDIR" && { fail_case "expected FAIL, got PASS: $VALIDATOR_STDOUT"; return 1; }
    assert_fail_contains "$expected" || return 1
    return 0
}

mf_dir() { valid_dir_manifest_file; }

t_absolute_member() {
    local mf; mf="$(mf_dir)"
    simple_fail_case "abs" "absolute path" "$(printf 'dir\t%s\nregfile\t%s/manifest\t%s\nreg\t/evil\tx\n' "$TOPDIR" "$TOPDIR" "$mf")"
}
run_case "rejects an absolute member path" t_absolute_member

t_dotdot_component() {
    local mf; mf="$(mf_dir)"
    simple_fail_case "dotdot" "unsafe component" "$(printf 'dir\t%s\nregfile\t%s/manifest\t%s\nreg\t%s/../evil\tx\n' "$TOPDIR" "$TOPDIR" "$mf" "$TOPDIR")"
}
run_case "rejects a member with a .. path component" t_dotdot_component

t_dot_component() {
    local mf; mf="$(mf_dir)"
    simple_fail_case "dot" "unsafe component" "$(printf 'dir\t%s\nregfile\t%s/manifest\t%s\nreg\t%s/./evil\tx\n' "$TOPDIR" "$TOPDIR" "$mf" "$TOPDIR")"
}
run_case "rejects a member with a . path component" t_dot_component

t_repeated_separator() {
    local mf; mf="$(mf_dir)"
    simple_fail_case "sep" "unsafe component" "$(printf 'dir\t%s\nregfile\t%s/manifest\t%s\nreg\t%s//evil\tx\n' "$TOPDIR" "$TOPDIR" "$mf" "$TOPDIR")"
}
run_case "rejects a member with a repeated separator (empty component)" t_repeated_separator

t_duplicate_raw_member() {
    local mf; mf="$(mf_dir)"
    simple_fail_case "dup" "duplicate member path" "$(printf 'dir\t%s\nregfile\t%s/manifest\t%s\nreg\t%s/data/mysrc/f.txt\ta\nreg\t%s/data/mysrc/f.txt\tb\n' "$TOPDIR" "$TOPDIR" "$mf" "$TOPDIR" "$TOPDIR")"
}
run_case "rejects a duplicate raw member path" t_duplicate_raw_member

t_normalized_duplicate_alias() {
    local mf; mf="$(mf_dir)"
    simple_fail_case "alias" "duplicate member path" "$(printf 'dir\t%s\nregfile\t%s/manifest\t%s\ndir\t%s/data\ndir\t%s/data/\n' "$TOPDIR" "$TOPDIR" "$mf" "$TOPDIR" "$TOPDIR")"
}
run_case "rejects a normalized duplicate alias (topdir/data vs topdir/data/)" t_normalized_duplicate_alias

t_symlink_member() {
    local mf; mf="$(mf_dir)"
    simple_fail_case "sym" "not a regular file or directory" "$(printf 'dir\t%s\nregfile\t%s/manifest\t%s\nsym\t%s/data/mysrc/evil\t/etc/passwd\n' "$TOPDIR" "$TOPDIR" "$mf" "$TOPDIR")"
}
run_case "rejects a symlink member" t_symlink_member

t_hardlink_member() {
    local mf; mf="$(mf_dir)"
    simple_fail_case "hardlink" "not a regular file or directory" "$(printf 'dir\t%s\nregfile\t%s/manifest\t%s\nhardlink\t%s/data/mysrc/evil\t%s/manifest\n' "$TOPDIR" "$TOPDIR" "$mf" "$TOPDIR" "$TOPDIR")"
}
run_case "rejects a hardlink member" t_hardlink_member

t_fifo_member() {
    local mf; mf="$(mf_dir)"
    simple_fail_case "fifo" "not a regular file or directory" "$(printf 'dir\t%s\nregfile\t%s/manifest\t%s\nfifo\t%s/data/mysrc/evil\n' "$TOPDIR" "$TOPDIR" "$mf" "$TOPDIR")"
}
run_case "rejects a FIFO member" t_fifo_member

t_chr_member() {
    local mf; mf="$(mf_dir)"
    simple_fail_case "chr" "not a regular file or directory" "$(printf 'dir\t%s\nregfile\t%s/manifest\t%s\nchr\t%s/data/mysrc/evil\n' "$TOPDIR" "$TOPDIR" "$mf" "$TOPDIR")"
}
run_case "rejects a character-device member" t_chr_member

t_populated_linkname_on_regular() {
    local mf; mf="$(mf_dir)"
    simple_fail_case "linkname" "populated link target" "$(printf 'dir\t%s\nregfile\t%s/manifest\t%s\nreg\t%s/data/mysrc/evil\tcontent\tsomewhere-else\n' "$TOPDIR" "$TOPDIR" "$mf" "$TOPDIR")"
}
run_case "rejects a regular-file member with a populated link target" t_populated_linkname_on_regular

# ---------------------------------------------------------------------
# LAYOUT
# ---------------------------------------------------------------------

t_two_top_level_dirs() {
    local mf; mf="$(mf_dir)"
    simple_fail_case "twotop" "outside the expected top-level directory" "$(printf 'dir\t%s\nregfile\t%s/manifest\t%s\nreg\tother-20260101T000000Z/stray\tx\n' "$TOPDIR" "$TOPDIR" "$mf")"
}
run_case "rejects an archive with a second top-level directory" t_two_top_level_dirs

t_wrong_topdir_argument() {
    local archive="$D/wrong-topdir.tar.gz"
    local mf; mf="$(mf_dir)"
    {
        printf 'dir\t%s\n' "$TOPDIR"
        printf 'regfile\t%s/manifest\t%s\n' "$TOPDIR" "$mf"
        printf 'dir\t%s/data\n' "$TOPDIR"
        printf 'dir\t%s/data/mysrc\n' "$TOPDIR"
        printf 'reg\t%s/data/mysrc/file1.txt\thello\n' "$TOPDIR"
        printf 'reg\t%s/data/mysrc/f2.txt\tworld\n' "$TOPDIR"
        printf 'reg\t%s/data/mysrc/empty.txt\t\n' "$TOPDIR"
    } | build_archive "$archive"
    invoke_validator "$archive" "other-99999999T999999Z" && { fail_case "expected FAIL, got PASS: $VALIDATOR_STDOUT"; return 1; }
    assert_fail_contains "outside the expected top-level directory" || return 1
    return 0
}
run_case "rejects when invoked with a mismatched expected top-level directory" t_wrong_topdir_argument

t_stray_top_level_file() {
    local mf; mf="$(mf_dir)"
    simple_fail_case "stray" "outside the supported layout" "$(printf 'dir\t%s\nregfile\t%s/manifest\t%s\ndir\t%s/data\ndir\t%s/data/mysrc\nreg\t%s/data/mysrc/file1.txt\thello\nreg\t%s/data/mysrc/f2.txt\tworld\nreg\t%s/randomfile.txt\tx\n' "$TOPDIR" "$TOPDIR" "$mf" "$TOPDIR" "$TOPDIR" "$TOPDIR" "$TOPDIR" "$TOPDIR")"
}
run_case "rejects a stray top-level file alongside a valid data/ payload" t_stray_top_level_file

t_dir_kind_with_dump_content() {
    local mf; mf="$(mf_dir)"
    simple_fail_case "extradump" "dir-kind archive has dump/ content" "$(printf 'dir\t%s\nregfile\t%s/manifest\t%s\ndir\t%s/data\ndir\t%s/data/mysrc\nreg\t%s/data/mysrc/file1.txt\thello\nreg\t%s/data/mysrc/f2.txt\tworld\nreg\t%s/dump/dump.bin\tx\n' "$TOPDIR" "$TOPDIR" "$mf" "$TOPDIR" "$TOPDIR" "$TOPDIR" "$TOPDIR" "$TOPDIR")"
}
run_case "rejects a dir-kind archive with unsupported dump/ content" t_dir_kind_with_dump_content

t_db_kind_extra_file() {
    local mf; mf="$(valid_db_manifest_file)"
    simple_fail_case "extradbfile" "must contain exactly dump/dump.bin" "$(printf 'dir\t%s\nregfile\t%s/manifest\t%s\ndir\t%s/dump\nreg\t%s/dump/dump.bin\t%s\nreg\t%s/dump/extra.txt\ty\n' "$TOPDIR" "$TOPDIR" "$mf" "$TOPDIR" "$TOPDIR" "$DB_DUMP_CONTENT" "$TOPDIR")"
}
run_case "rejects a db-kind archive with an extra file under dump/" t_db_kind_extra_file

t_missing_manifest() {
    simple_fail_case "nomanifest" "archive is missing the manifest" "$(printf 'dir\t%s\ndir\t%s/data\ndir\t%s/data/mysrc\nreg\t%s/data/mysrc/file1.txt\thello\n' "$TOPDIR" "$TOPDIR" "$TOPDIR" "$TOPDIR")"
}
run_case "rejects an archive with no manifest at all" t_missing_manifest

t_duplicate_manifest() {
    local mf; mf="$(mf_dir)"
    simple_fail_case "dupmanifest" "duplicate member path" "$(printf 'dir\t%s\nregfile\t%s/manifest\t%s\nregfile\t%s/manifest\t%s\n' "$TOPDIR" "$TOPDIR" "$mf" "$TOPDIR" "$mf")"
}
run_case "rejects an archive with a duplicate manifest member" t_duplicate_manifest

t_db_missing_dump_bin() {
    local mf; mf="$(valid_db_manifest_file)"
    simple_fail_case "nodump" "must contain exactly dump/dump.bin" "$(printf 'dir\t%s\nregfile\t%s/manifest\t%s\ndir\t%s/dump\n' "$TOPDIR" "$TOPDIR" "$mf" "$TOPDIR")"
}
run_case "rejects a db-kind archive missing dump/dump.bin" t_db_missing_dump_bin

t_dir_missing_data() {
    local mf; mf="$(mf_dir)"
    simple_fail_case "nodata" "no data/ content" "$(printf 'dir\t%s\nregfile\t%s/manifest\t%s\n' "$TOPDIR" "$TOPDIR" "$mf")"
}
run_case "rejects a dir-kind archive missing data/ content" t_dir_missing_data

# ---------------------------------------------------------------------
# MANIFEST
# ---------------------------------------------------------------------

manifest_fail_case() {
    local desc="$1" expected="$2" manifest_content="$3"
    local mf="$D/manifest-$$-$RANDOM.txt"
    # $manifest_content came through a command substitution above, which
    # strips trailing newlines -- restore exactly one so the fixture is a
    # well-formed, newline-terminated manifest (otherwise every case here
    # would fail on that check instead of the one actually being tested).
    printf '%s\n' "$manifest_content" >"$mf"
    local archive="$D/fail-$$-$RANDOM.tar.gz"
    {
        printf 'dir\t%s\n' "$TOPDIR"
        printf 'regfile\t%s/manifest\t%s\n' "$TOPDIR" "$mf"
        printf 'dir\t%s/data\n' "$TOPDIR"
        printf 'dir\t%s/data/mysrc\n' "$TOPDIR"
        printf 'reg\t%s/data/mysrc/file1.txt\thello\n' "$TOPDIR"
        printf 'reg\t%s/data/mysrc/f2.txt\tworld\n' "$TOPDIR"
    } | build_archive "$archive"
    invoke_validator "$archive" "$TOPDIR" && { fail_case "expected FAIL, got PASS: $VALIDATOR_STDOUT"; return 1; }
    assert_fail_contains "$expected" || return 1
    return 0
}

t_manifest_line_no_equals() {
    manifest_fail_case "noeq" "manifest line is not KEY=value" \
        "$(printf 'GARBAGE\nSOURCE_KIND=dir\nCREATED_AT=20260101T000000Z\nFORMAT_VERSION=1\nFILE_COUNT=2\nTOTAL_BYTES=10\n')"
}
run_case "rejects a manifest line without =" t_manifest_line_no_equals

t_manifest_unknown_key() {
    manifest_fail_case "unknown" "manifest has an unknown key" \
        "$(printf 'BACKUP_ID=myid\nSOURCE_KIND=dir\nCREATED_AT=20260101T000000Z\nFORMAT_VERSION=1\nFILE_COUNT=2\nTOTAL_BYTES=10\nFOO=bar\n')"
}
run_case "rejects an unknown manifest key" t_manifest_unknown_key

t_manifest_duplicate_key() {
    manifest_fail_case "dupkey" "manifest has a duplicate key" \
        "$(printf 'BACKUP_ID=myid\nBACKUP_ID=myid\nSOURCE_KIND=dir\nCREATED_AT=20260101T000000Z\nFORMAT_VERSION=1\nFILE_COUNT=2\nTOTAL_BYTES=10\n')"
}
run_case "rejects a duplicate manifest key" t_manifest_duplicate_key

t_manifest_missing_required_key() {
    manifest_fail_case "missingkey" "manifest is missing required key" \
        "$(printf 'BACKUP_ID=myid\nSOURCE_KIND=dir\nCREATED_AT=20260101T000000Z\nFILE_COUNT=2\nTOTAL_BYTES=10\n')"
}
run_case "rejects a manifest missing a required key" t_manifest_missing_required_key

t_manifest_unsupported_format_version() {
    manifest_fail_case "badversion" "malformed value" \
        "$(printf 'BACKUP_ID=myid\nSOURCE_KIND=dir\nCREATED_AT=20260101T000000Z\nFORMAT_VERSION=2\nFILE_COUNT=2\nTOTAL_BYTES=10\n')"
}
run_case "rejects an unsupported FORMAT_VERSION" t_manifest_unsupported_format_version

t_manifest_invalid_backup_id() {
    manifest_fail_case "badid" "malformed value" \
        "$(printf 'BACKUP_ID=my id\nSOURCE_KIND=dir\nCREATED_AT=20260101T000000Z\nFORMAT_VERSION=1\nFILE_COUNT=2\nTOTAL_BYTES=10\n')"
}
run_case "rejects an invalid BACKUP_ID" t_manifest_invalid_backup_id

t_manifest_invalid_created_at() {
    manifest_fail_case "badcreated" "malformed value" \
        "$(printf 'BACKUP_ID=myid\nSOURCE_KIND=dir\nCREATED_AT=2026-01-01\nFORMAT_VERSION=1\nFILE_COUNT=2\nTOTAL_BYTES=10\n')"
}
run_case "rejects an invalid CREATED_AT" t_manifest_invalid_created_at

t_manifest_backup_id_identity_mismatch() {
    manifest_fail_case "idmismatch" "do not match the archive identity" \
        "$(printf 'BACKUP_ID=otherid\nSOURCE_KIND=dir\nCREATED_AT=20260101T000000Z\nFORMAT_VERSION=1\nFILE_COUNT=2\nTOTAL_BYTES=10\n')"
}
run_case "rejects manifest BACKUP_ID not matching the archive identity" t_manifest_backup_id_identity_mismatch

t_manifest_created_at_identity_mismatch() {
    manifest_fail_case "createdmismatch" "do not match the archive identity" \
        "$(printf 'BACKUP_ID=myid\nSOURCE_KIND=dir\nCREATED_AT=20270202T000000Z\nFORMAT_VERSION=1\nFILE_COUNT=2\nTOTAL_BYTES=10\n')"
}
run_case "rejects manifest CREATED_AT not matching the archive identity" t_manifest_created_at_identity_mismatch

t_manifest_wrong_kind_fields() {
    manifest_fail_case "wrongkindfields" "not permitted for dir-kind" \
        "$(printf 'BACKUP_ID=myid\nSOURCE_KIND=dir\nCREATED_AT=20260101T000000Z\nFORMAT_VERSION=1\nFILE_COUNT=2\nTOTAL_BYTES=10\nDUMP_SIZE_BYTES=5\nDUMP_SHA256=%s\n' "$(printf 'a%.0s' $(seq 1 64))")"
}
run_case "rejects dir-kind manifest containing db-only fields" t_manifest_wrong_kind_fields

t_manifest_numeric_malformed() {
    manifest_fail_case "badnum" "malformed value" \
        "$(printf 'BACKUP_ID=myid\nSOURCE_KIND=dir\nCREATED_AT=20260101T000000Z\nFORMAT_VERSION=1\nFILE_COUNT=abc\nTOTAL_BYTES=10\n')"
}
run_case "rejects a malformed numeric field" t_manifest_numeric_malformed

t_manifest_negative_numeric() {
    manifest_fail_case "negnum" "malformed value" \
        "$(printf 'BACKUP_ID=myid\nSOURCE_KIND=dir\nCREATED_AT=20260101T000000Z\nFORMAT_VERSION=1\nFILE_COUNT=-5\nTOTAL_BYTES=10\n')"
}
run_case "rejects a negative-looking numeric field" t_manifest_negative_numeric

t_manifest_nonhex_sha256() {
    manifest_fail_case "nonhex" "malformed value" \
        "$(printf 'BACKUP_ID=myid\nSOURCE_KIND=db\nCREATED_AT=20260101T000000Z\nFORMAT_VERSION=1\nDUMP_SIZE_BYTES=5\nDUMP_SHA256=%s\n' "$(printf 'g%.0s' $(seq 1 64))")"
}
run_case "rejects a non-hex DUMP_SHA256" t_manifest_nonhex_sha256

t_manifest_wrong_length_sha256() {
    manifest_fail_case "wronglen" "malformed value" \
        "$(printf 'BACKUP_ID=myid\nSOURCE_KIND=db\nCREATED_AT=20260101T000000Z\nFORMAT_VERSION=1\nDUMP_SIZE_BYTES=5\nDUMP_SHA256=%s\n' "$(printf 'a%.0s' $(seq 1 63))")"
}
run_case "rejects a wrong-length DUMP_SHA256" t_manifest_wrong_length_sha256

t_manifest_zero_dump_size() {
    manifest_fail_case "zerosize" "greater than zero" \
        "$(printf 'BACKUP_ID=myid\nSOURCE_KIND=db\nCREATED_AT=20260101T000000Z\nFORMAT_VERSION=1\nDUMP_SIZE_BYTES=0\nDUMP_SHA256=%s\n' "$(printf 'a%.0s' $(seq 1 64))")"
}
run_case "rejects DUMP_SIZE_BYTES=0 at the manifest-parse stage" t_manifest_zero_dump_size

# ---------------------------------------------------------------------
# PAYLOAD CONSISTENCY
# ---------------------------------------------------------------------

t_dir_file_count_mismatch() {
    local mf="$D/manifest-fc.txt"
    printf 'BACKUP_ID=myid\nSOURCE_KIND=dir\nCREATED_AT=20260101T000000Z\nFORMAT_VERSION=1\nFILE_COUNT=99\nTOTAL_BYTES=10\n' >"$mf"
    simple_fail_case "fcmismatch" "FILE_COUNT does not match" "$(printf 'dir\t%s\nregfile\t%s/manifest\t%s\ndir\t%s/data\ndir\t%s/data/mysrc\nreg\t%s/data/mysrc/file1.txt\thello\nreg\t%s/data/mysrc/f2.txt\tworld\n' "$TOPDIR" "$TOPDIR" "$mf" "$TOPDIR" "$TOPDIR" "$TOPDIR" "$TOPDIR")"
}
run_case "rejects a dir-kind archive with wrong FILE_COUNT" t_dir_file_count_mismatch

t_dir_total_bytes_mismatch() {
    local mf="$D/manifest-tb.txt"
    printf 'BACKUP_ID=myid\nSOURCE_KIND=dir\nCREATED_AT=20260101T000000Z\nFORMAT_VERSION=1\nFILE_COUNT=2\nTOTAL_BYTES=99999\n' >"$mf"
    simple_fail_case "tbmismatch" "TOTAL_BYTES does not match" "$(printf 'dir\t%s\nregfile\t%s/manifest\t%s\ndir\t%s/data\ndir\t%s/data/mysrc\nreg\t%s/data/mysrc/file1.txt\thello\nreg\t%s/data/mysrc/f2.txt\tworld\n' "$TOPDIR" "$TOPDIR" "$mf" "$TOPDIR" "$TOPDIR" "$TOPDIR" "$TOPDIR")"
}
run_case "rejects a dir-kind archive with wrong TOTAL_BYTES" t_dir_total_bytes_mismatch

t_db_size_mismatch() {
    local mf="$D/manifest-dbsize.txt"
    printf 'BACKUP_ID=myid\nSOURCE_KIND=db\nCREATED_AT=20260101T000000Z\nFORMAT_VERSION=1\nDUMP_SIZE_BYTES=99999\nDUMP_SHA256=%s\n' "$DB_DUMP_SHA256" >"$mf"
    simple_fail_case "dbsize" "DUMP_SIZE_BYTES does not match" "$(printf 'dir\t%s\nregfile\t%s/manifest\t%s\ndir\t%s/dump\nreg\t%s/dump/dump.bin\t%s\n' "$TOPDIR" "$TOPDIR" "$mf" "$TOPDIR" "$TOPDIR" "$DB_DUMP_CONTENT")"
}
run_case "rejects a db-kind archive with wrong DUMP_SIZE_BYTES" t_db_size_mismatch

t_db_digest_mismatch() {
    local mf="$D/manifest-dbdigest.txt"
    printf 'BACKUP_ID=myid\nSOURCE_KIND=db\nCREATED_AT=20260101T000000Z\nFORMAT_VERSION=1\nDUMP_SIZE_BYTES=%s\nDUMP_SHA256=%s\n' "$DB_DUMP_SIZE" "$(printf 'b%.0s' $(seq 1 64))" >"$mf"
    simple_fail_case "dbdigest" "DUMP_SHA256 does not match" "$(printf 'dir\t%s\nregfile\t%s/manifest\t%s\ndir\t%s/dump\nreg\t%s/dump/dump.bin\t%s\n' "$TOPDIR" "$TOPDIR" "$mf" "$TOPDIR" "$TOPDIR" "$DB_DUMP_CONTENT")"
}
run_case "rejects a db-kind archive with wrong DUMP_SHA256" t_db_digest_mismatch

echo
echo "== summary =="
echo "$PASSED passed, $FAILED failed"
if ((FAILED > 0)); then
    echo "Failed cases:"
    printf '  - %s\n' "${FAILED_NAMES[@]}"
    exit 1
fi

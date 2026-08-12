#!/usr/bin/env bash
# Generic backup routine. See docs/backup-runbook.md.
#
# Required:
#   BACKUP_DESTINATION    absolute path, must already exist, mode 0700.
#                          Never created or chmod'd by this script.
#   BACKUP_ID              [A-Za-z0-9-]+
#   BACKUP_SOURCE_KIND      dir | db
#
#   kind=dir:
#     BACKUP_SOURCE_DIR    absolute path, must already exist. Also serves
#                          as the live-data path for the locality guard.
#
#   kind=db:
#     BACKUP_LIVE_DATA_PATH   absolute path, must already exist. Locality
#                              safety gate only against BACKUP_DESTINATION
#                              -- never read, archived, or logged.
#     trailing CLI argv after --: the dump-producer executable and its
#     arguments, executed directly (no eval, no shell string). Its stdout
#     becomes the archived dump. Non-zero exit, or zero-byte stdout, fails
#     the backup before anything is published.
#
# Optional:
#   BACKUP_TIMESTAMP    test-only override. Must match ^[0-9]{8}T[0-9]{6}Z$
#                       -- the production date -u value is held to the
#                       exact same rule.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=backup/lib.sh
source "${SCRIPT_DIR}/lib.sh"

readonly TAR_METADATA_CHECK="${SCRIPT_DIR}/tar_metadata_check.py"

STAGING_DIR=""

# Takes the exit code as an argument rather than reading $?, which for a
# signal-triggered invocation would reflect whatever command happened to
# complete just before the signal arrived, not the signal itself -- see the
# INT/TERM trap registrations below.
cleanup() {
    local rc="$1"
    trap - EXIT INT TERM
    cleanup_pending_checksum_if_owned
    if [[ -n "$STAGING_DIR" && -d "$STAGING_DIR" ]]; then
        rm -rf -- "$STAGING_DIR"
    fi
    exit "$rc"
}

main() {
    if [[ "${1:-}" == "--" ]]; then
        shift
    fi
    local producer_argv=("$@")

    local kind="${BACKUP_SOURCE_KIND:-}"
    local destination="${BACKUP_DESTINATION:-}"
    local backup_id="${BACKUP_ID:-}"
    local source_dir="${BACKUP_SOURCE_DIR:-}"
    local live_data_path="${BACKUP_LIVE_DATA_PATH:-}"
    local timestamp

    # -- input validation; no mutation below this point until staging ----
    local missing=()
    [[ -n "$destination" ]] || missing+=("BACKUP_DESTINATION")
    [[ -n "$backup_id" ]] || missing+=("BACKUP_ID")
    [[ -n "$kind" ]] || missing+=("BACKUP_SOURCE_KIND")
    ((${#missing[@]} == 0)) || die "missing required variable(s): ${missing[*]}"

    case "$kind" in
        dir | db) ;;
        *) die "BACKUP_SOURCE_KIND must be 'dir' or 'db': $kind" ;;
    esac

    validate_backup_id "$backup_id"
    require_absolute_path "BACKUP_DESTINATION" "$destination"

    if [[ "$kind" == "dir" ]]; then
        [[ -n "$source_dir" ]] || die "BACKUP_SOURCE_DIR is required for kind=dir"
        [[ -z "$live_data_path" ]] || die "BACKUP_LIVE_DATA_PATH must not be set for kind=dir"
        ((${#producer_argv[@]} == 0)) || die "a producer argv must not be given for kind=dir"
        require_absolute_path "BACKUP_SOURCE_DIR" "$source_dir"
    else
        [[ -z "$source_dir" ]] || die "BACKUP_SOURCE_DIR must not be set for kind=db"
        [[ -n "$live_data_path" ]] || die "BACKUP_LIVE_DATA_PATH is required for kind=db"
        ((${#producer_argv[@]} > 0)) || die "a dump-producer argv is required for kind=db (pass it after --)"
        require_absolute_path "BACKUP_LIVE_DATA_PATH" "$live_data_path"
    fi

    timestamp="${BACKUP_TIMESTAMP:-$(date -u +%Y%m%dT%H%M%SZ)}"
    validate_timestamp "$timestamp"

    [[ -d "$destination" ]] || die "BACKUP_DESTINATION does not exist or is not a directory: $destination"
    [[ "$(stat -c '%a' -- "$destination")" == "700" ]] || die "BACKUP_DESTINATION is not mode 0700: $destination"

    local canon_destination canon_live
    canon_destination="$(canonicalize_existing "$destination")"
    if [[ "$kind" == "dir" ]]; then
        [[ -d "$source_dir" ]] || die "BACKUP_SOURCE_DIR does not exist or is not a directory: $source_dir"
        canon_live="$(canonicalize_existing "$source_dir")"
    else
        [[ -e "$live_data_path" ]] || die "BACKUP_LIVE_DATA_PATH does not exist: $live_data_path"
        canon_live="$(canonicalize_existing "$live_data_path")"
    fi
    if paths_conflict "$canon_destination" "$canon_live"; then
        die "BACKUP_DESTINATION and the live data path must be disjoint"
    fi

    if [[ "$kind" == "dir" ]]; then
        scan_payload_safety "$source_dir"
    fi

    umask 0077

    STAGING_DIR="$(mktemp -d -- "${destination}/.backup-staging.XXXXXX")" || die "failed to create staging directory"
    chmod 0700 -- "$STAGING_DIR"
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'cleanup "$?"' EXIT

    local topdir="${backup_id}-${timestamp}"
    local build_dir="${STAGING_DIR}/build"
    mkdir -m 0700 -- "$build_dir" "${build_dir}/${topdir}"

    if [[ "$kind" == "dir" ]]; then
        local source_basename file_count total_bytes
        source_basename="$(basename -- "$source_dir")"
        mkdir -m 0700 -- "${build_dir}/${topdir}/data"
        cp -a -- "$source_dir" "${build_dir}/${topdir}/data/${source_basename}"
        file_count="$(find "${build_dir}/${topdir}/data" -type f -printf '.' | wc -c)" \
            || die "failed to count payload files"
        total_bytes="$(find "${build_dir}/${topdir}/data" -type f -printf '%s\n' | awk '{sum += $1} END {print sum + 0}')" \
            || die "failed to sum payload file sizes"
        cat >"${build_dir}/${topdir}/manifest" <<EOF
BACKUP_ID=${backup_id}
SOURCE_KIND=dir
CREATED_AT=${timestamp}
FORMAT_VERSION=1
FILE_COUNT=${file_count}
TOTAL_BYTES=${total_bytes}
EOF
    else
        mkdir -m 0700 -- "${build_dir}/${topdir}/dump"
        local dump_path="${build_dir}/${topdir}/dump/dump.bin"
        "${producer_argv[@]}" >"$dump_path" || die "dump-producer failed"
        local dump_size dump_sha256
        dump_size="$(stat -c '%s' -- "$dump_path")"
        [[ "$dump_size" -gt 0 ]] || die "dump-producer succeeded but produced zero bytes"
        dump_sha256="$(sha256sum -- "$dump_path" | awk '{print $1}')" || die "failed to compute dump checksum"
        cat >"${build_dir}/${topdir}/manifest" <<EOF
BACKUP_ID=${backup_id}
SOURCE_KIND=db
CREATED_AT=${timestamp}
FORMAT_VERSION=1
DUMP_SIZE_BYTES=${dump_size}
DUMP_SHA256=${dump_sha256}
EOF
    fi

    local staged_archive="${STAGING_DIR}/${topdir}.tar.gz"
    tar -C "$build_dir" -czf "$staged_archive" -- "$topdir"

    python3 "$TAR_METADATA_CHECK" "$staged_archive" "$topdir" >/dev/null \
        || die "staged archive failed the archive contract validator"

    local staged_checksum="${STAGING_DIR}/${topdir}.tar.gz.sha256"
    (cd "$STAGING_DIR" && sha256sum -- "$(basename -- "$staged_archive")" >"$(basename -- "$staged_checksum")")

    chmod 0600 -- "$staged_archive" "$staged_checksum"

    local final_archive="${destination}/${topdir}.tar.gz"
    local final_checksum="${destination}/${topdir}.tar.gz.sha256"
    publish_checksum_then_archive "$staged_checksum" "$staged_archive" "$final_checksum" "$final_archive"

    printf 'backup published: %s\n' "$final_archive"
}

if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
    main "$@"
fi

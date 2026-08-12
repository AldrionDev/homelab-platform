#!/usr/bin/env bash
# Generic restore routine. See docs/backup-runbook.md.
#
# Required:
#   BACKUP_ARCHIVE            absolute path to a published .tar.gz, with a
#                              .tar.gz.sha256 sidecar alongside it.
#   RECOVERY_TARGET            absolute path, must not currently exist as
#                              any filesystem object or symlink.
#   RESTORE_LIVE_DATA_PATH     absolute path, safety-gate only. May
#                              currently be absent (the live source may
#                              already have been deleted/corrupted).
#   trailing CLI argv after --: the workload validator executable and its
#     arguments, executed directly (no eval, no shell string) against the
#     restored payload path, which is appended as the final argument.
#     Exit 0 = viable, non-zero = restore fails and the target is not
#     published as viable.
#
# The external BACKUP_ARCHIVE path is read exactly once, into a private
# snapshot. Every subsequent step (checksum, structural validation,
# extraction) operates only on that snapshot -- the external path is never
# reopened, so it cannot be raced or replaced mid-restore.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=backup/lib.sh
source "${SCRIPT_DIR}/lib.sh"

readonly TAR_METADATA_CHECK="${SCRIPT_DIR}/tar_metadata_check.py"

SCRATCH_DIR=""
RECOVERY_TARGET_CLAIMED=""
RECOVERY_TARGET_DEV_INODE=""
RECOVERY_TARGET_TOKEN=""

cleanup_recovery_target_if_owned() {
    local target="$RECOVERY_TARGET_CLAIMED"
    [[ -d "$target" ]] || return 0

    local current_id
    current_id="$(stat_dev_inode "$target" 2>/dev/null || true)"
    if [[ "$current_id" != "$RECOVERY_TARGET_DEV_INODE" ]]; then
        printf 'ERROR: Recovery Target identity could not be reverified, refusing to delete: %s\n' "$target" >&2
        return 0
    fi

    local current_token
    current_token="$(cat -- "${target}/.restore-control" 2>/dev/null || true)"
    if [[ "$current_token" != "$RECOVERY_TARGET_TOKEN" ]]; then
        printf 'ERROR: Recovery Target ownership token could not be reverified, refusing to delete: %s\n' "$target" >&2
        return 0
    fi

    rm -rf -- "$target"
}

# Takes the exit code as an argument rather than reading $?, which for a
# signal-triggered invocation would reflect whatever command happened to
# complete just before the signal arrived, not the signal itself -- see the
# INT/TERM trap registrations below.
cleanup() {
    local rc="$1"
    trap - EXIT INT TERM
    if [[ -n "$SCRATCH_DIR" && -d "$SCRATCH_DIR" ]]; then
        rm -rf -- "$SCRATCH_DIR"
    fi
    if [[ "$rc" != "0" && -n "$RECOVERY_TARGET_CLAIMED" ]]; then
        cleanup_recovery_target_if_owned
    fi
    exit "$rc"
}

main() {
    if [[ "${1:-}" == "--" ]]; then
        shift
    fi
    local validator_argv=("$@")

    local archive="${BACKUP_ARCHIVE:-}"
    local recovery_target="${RECOVERY_TARGET:-}"
    local live_data_path="${RESTORE_LIVE_DATA_PATH:-}"

    local missing=()
    [[ -n "$archive" ]] || missing+=("BACKUP_ARCHIVE")
    [[ -n "$recovery_target" ]] || missing+=("RECOVERY_TARGET")
    [[ -n "$live_data_path" ]] || missing+=("RESTORE_LIVE_DATA_PATH")
    ((${#missing[@]} == 0)) || die "missing required variable(s): ${missing[*]}"
    ((${#validator_argv[@]} > 0)) || die "a workload validator argv is required (pass it after --)"

    require_absolute_path "BACKUP_ARCHIVE" "$archive"
    require_absolute_path "RECOVERY_TARGET" "$recovery_target"
    require_absolute_path "RESTORE_LIVE_DATA_PATH" "$live_data_path"

    local archive_basename
    archive_basename="$(basename -- "$archive")"
    validate_archive_basename "$archive_basename"
    [[ -f "$archive" ]] || die "BACKUP_ARCHIVE does not exist: $archive"
    local topdir="${archive_basename%.tar.gz}"

    local sidecar="${archive}.sha256"
    [[ -f "$sidecar" ]] || die "checksum sidecar does not exist: $sidecar"

    # -- strict sidecar parse; the sidecar's filename field is validated
    # but never used to select what gets hashed -----------------------
    local sidecar_content sidecar_digest sidecar_filename
    sidecar_content="$(cat -- "$sidecar")"
    if [[ "$sidecar_content" == *$'\n'* ]]; then
        die "checksum sidecar has more than one line: $sidecar"
    fi
    if [[ ! "$sidecar_content" =~ ^([0-9a-fA-F]{64})[[:space:]]{2}(.+)$ ]]; then
        die "checksum sidecar is malformed: $sidecar"
    fi
    sidecar_digest="${BASH_REMATCH[1]}"
    sidecar_filename="${BASH_REMATCH[2]}"
    [[ "$sidecar_filename" == "$archive_basename" ]] || die "checksum sidecar filename does not match the archive: $sidecar"

    umask 0077

    # -- snapshot: the only read of the external archive path ----------
    SCRATCH_DIR="$(mktemp -d)" || die "failed to create restore scratch directory"
    chmod 0700 -- "$SCRATCH_DIR"
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'cleanup "$?"' EXIT

    local snapshot="${SCRATCH_DIR}/archive-snapshot.tar.gz"
    cp -- "$archive" "$snapshot" || die "failed to snapshot archive"
    chmod 0600 -- "$snapshot"

    local computed_digest
    computed_digest="$(sha256sum -- "$snapshot" | awk '{print $1}')" || die "failed to compute checksum of snapshot"
    if [[ "${computed_digest,,}" != "${sidecar_digest,,}" ]]; then
        die "checksum mismatch, refusing to proceed"
    fi

    local manifest_output
    manifest_output="$(python3 "$TAR_METADATA_CHECK" "$snapshot" "$topdir")" \
        || die "archive failed the archive contract validator"

    local source_kind="" data_basename=""
    local key value
    while IFS='=' read -r key value; do
        case "$key" in
            SOURCE_KIND) source_kind="$value" ;;
            DATA_BASENAME) data_basename="$value" ;;
        esac
    done <<<"$manifest_output"
    [[ -n "$source_kind" ]] || die "internal error: validator did not report SOURCE_KIND"
    if [[ "$source_kind" == "dir" ]]; then
        [[ -n "$data_basename" && "$data_basename" != "." && "$data_basename" != ".." && "$data_basename" != */* ]] \
            || die "internal error: validator did not report a safe DATA_BASENAME"
    fi

    # -- recovery-target and live-data-path canonicalization -----------
    local canon_target canon_live
    canon_target="$(canonicalize_recovery_target "$recovery_target")"
    canon_live="$(canonicalize_restore_live_data_path "$live_data_path")"
    if paths_conflict "$canon_target" "$canon_live"; then
        die "RECOVERY_TARGET and RESTORE_LIVE_DATA_PATH must be disjoint"
    fi
    [[ ! -e "$recovery_target" && ! -L "$recovery_target" ]] || die "RECOVERY_TARGET already exists: $recovery_target"

    # -- atomic claim + ownership proof ---------------------------------
    mkdir -m 0700 -- "$recovery_target" || die "failed to claim RECOVERY_TARGET (it may already exist): $recovery_target"
    RECOVERY_TARGET_CLAIMED="$recovery_target"
    RECOVERY_TARGET_DEV_INODE="$(stat_dev_inode "$recovery_target")"
    RECOVERY_TARGET_TOKEN="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
    printf '%s' "$RECOVERY_TARGET_TOKEN" >"${recovery_target}/.restore-control"
    chmod 0600 -- "${recovery_target}/.restore-control"

    local payload_root="${recovery_target}/payload"
    mkdir -m 0700 -- "$payload_root"

    tar -xzf "$snapshot" -C "$payload_root" --no-same-owner --no-same-permissions

    scan_payload_safety "$payload_root"

    local payload_path
    if [[ "$source_kind" == "dir" ]]; then
        payload_path="${payload_root}/${topdir}/data/${data_basename}"
    else
        payload_path="${payload_root}/${topdir}/dump/dump.bin"
    fi
    [[ -e "$payload_path" ]] || die "internal error: expected restored payload path does not exist: $payload_path"

    "${validator_argv[@]}" "$payload_path" || die "workload validator rejected the restored data"

    # -- re-verify ownership before declaring success -------------------
    local final_id final_token
    final_id="$(stat_dev_inode "$recovery_target")"
    final_token="$(cat -- "${recovery_target}/.restore-control")"
    [[ "$final_id" == "$RECOVERY_TARGET_DEV_INODE" && "$final_token" == "$RECOVERY_TARGET_TOKEN" ]] \
        || die "Recovery Target ownership could not be reverified before completion: $recovery_target"
    rm -f -- "${recovery_target}/.restore-control"

    printf 'restore complete: %s\n' "$payload_path"
}

if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
    main "$@"
fi

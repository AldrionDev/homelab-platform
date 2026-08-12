#!/usr/bin/env bash
# Shared helpers for backup/backup.sh and backup/restore.sh.
#
# Sourced only. Must not impose shell options (set -e/-u/pipefail) on the
# caller -- each function is written to be safe to call under any caller
# shell-option configuration.

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

require_absolute_path() {
    local name="$1" value="$2"
    [[ "$value" == /* ]] || die "$name must be an absolute path: $value"
}

validate_backup_id() {
    local value="$1"
    [[ "$value" =~ ^[A-Za-z0-9-]+$ ]] || die "BACKUP_ID is malformed: $value"
}

# Whichever timestamp is in use (test-only override or the real date -u
# output) must pass this check before it is used in any path.
validate_timestamp() {
    local value="$1"
    [[ "$value" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || die "timestamp is malformed: $value"
}

readonly ARCHIVE_BASENAME_PATTERN='^[A-Za-z0-9-]+-[0-9]{8}T[0-9]{6}Z\.tar\.gz$'

validate_archive_basename() {
    local value="$1"
    [[ "$value" =~ $ARCHIVE_BASENAME_PATTERN ]] || die "archive filename does not match the expected pattern: $value"
}

stat_dev_inode() {
    stat -c '%d:%i' -- "$1"
}

# Canonicalizes a path that must already exist. Dies with a clear message
# otherwise.
canonicalize_existing() {
    local path="$1"
    realpath -e -- "$path" 2>/dev/null || die "path does not exist or cannot be resolved: $path"
}

# RECOVERY_TARGET canonicalization: the target must not currently exist as
# any object or symlink (including a dangling one); its parent must exist;
# its basename must be a safe single path component.
canonicalize_recovery_target() {
    local target="$1" parent leaf canon_parent
    if [[ -e "$target" || -L "$target" ]]; then
        die "RECOVERY_TARGET already exists: $target"
    fi
    parent="$(dirname -- "$target")"
    leaf="$(basename -- "$target")"
    case "$leaf" in
        '' | '.' | '..')
            die "RECOVERY_TARGET has an unsafe basename: $target"
            ;;
    esac
    canon_parent="$(canonicalize_existing "$parent")" || die "RECOVERY_TARGET parent does not exist: $parent"
    printf '%s/%s\n' "$canon_parent" "$leaf"
}

# RESTORE_LIVE_DATA_PATH canonicalization: three cases.
#   - currently exists (as a real object, or a symlink that resolves):
#     fully resolved via realpath -e, so an existing symlink aliasing the
#     recovery path is caught after resolution.
#   - plainly absent and not a symlink at all: parent+basename
#     canonicalization, tolerant of the leaf itself being gone (the live
#     source may already have been deleted).
#   - a dangling symlink: fails closed as ambiguous rather than guessing.
canonicalize_restore_live_data_path() {
    local path="$1" parent leaf canon_parent
    if [[ -e "$path" ]]; then
        canonicalize_existing "$path"
        return
    fi
    if [[ -L "$path" ]]; then
        die "RESTORE_LIVE_DATA_PATH is a dangling symlink, refusing as ambiguous: $path"
    fi
    parent="$(dirname -- "$path")"
    leaf="$(basename -- "$path")"
    case "$leaf" in
        '' | '.' | '..')
            die "RESTORE_LIVE_DATA_PATH has an unsafe basename: $path"
            ;;
    esac
    canon_parent="$(canonicalize_existing "$parent")" || die "RESTORE_LIVE_DATA_PATH parent does not exist: $parent"
    printf '%s/%s\n' "$canon_parent" "$leaf"
}

# Rejects if two already-canonical absolute paths are equal, or either
# contains the other.
paths_conflict() {
    local a="$1" b="$2"
    [[ "$a" == "$b" ]] && return 0
    [[ "$a" == "$b"/* ]] && return 0
    [[ "$b" == "$a"/* ]] && return 0
    return 1
}

# Refuses a dir-kind source (or an already-extracted restore payload)
# containing anything other than regular files and directories, or any
# hardlinked regular file (nlink > 1).
scan_payload_safety() {
    local root="$1" hit
    hit="$(find "$root" -mindepth 1 -not -type f -not -type d -print -quit)" \
        || die "payload scan failed while checking for unsupported entry types under: $root"
    [[ -z "$hit" ]] || die "payload contains an unsupported entry type: $hit"
    hit="$(find "$root" -mindepth 1 -type f -links +1 -print -quit)" \
        || die "payload scan failed while checking for hardlinked files under: $root"
    [[ -z "$hit" ]] || die "payload contains a hardlinked regular file: $hit"
}

# Publication-ownership state. Armed BEFORE the checksum hardlink is even
# attempted (not after it succeeds) so that a trappable signal arriving at
# ANY point from arming onward -- including the narrow window between the
# hardlink syscall completing and the next shell statement running -- is
# covered by the caller's own trap-driven cleanup. Consulted by
# cleanup_pending_checksum_if_owned. An untrappable interruption (SIGKILL,
# power loss) cannot be covered by any shell-level mechanism -- that
# residual remains intentionally documented elsewhere, not hidden.
PUBLISH_PENDING_CHECKSUM_PATH=""
PUBLISH_PENDING_CHECKSUM_ID=""

# Three cases, matching how far publication actually got:
#   - the pending path does not exist at all: the checksum hardlink was
#     never (yet) created -- silent no-op, nothing to report or remove.
#   - it exists and its device+inode matches the recorded identity: it is
#     exactly the file this invocation published -- remove it.
#   - it exists but does not match: a pre-existing or since-swapped file --
#     refuse to delete, print a diagnostic.
# No-op if nothing is currently armed. Never lets an internal failure (e.g.
# rm) propagate as an uncontrolled error, so this is safe to call from a
# trap under set -e without masking the original exit status.
cleanup_pending_checksum_if_owned() {
    [[ -n "$PUBLISH_PENDING_CHECKSUM_PATH" ]] || return 0
    local path="$PUBLISH_PENDING_CHECKSUM_PATH"
    local expected_id="$PUBLISH_PENDING_CHECKSUM_ID"
    PUBLISH_PENDING_CHECKSUM_PATH=""
    PUBLISH_PENDING_CHECKSUM_ID=""

    if [[ ! -e "$path" ]]; then
        return 0
    fi

    local current_id
    current_id="$(stat_dev_inode "$path" 2>/dev/null || true)"
    if [[ "$current_id" == "$expected_id" ]]; then
        rm -f -- "$path" || printf 'ERROR: failed to remove pending checksum: %s\n' "$path" >&2
    else
        printf 'ERROR: pending checksum identity could not be reverified, refusing to delete: %s\n' "$path" >&2
    fi
    return 0
}

# Publishes checksum first, archive last, using collision-refusing
# hardlinks (ln fails with EEXIST if the target already exists, and is
# atomic on the same filesystem -- both staged files must already be on
# the same filesystem as their final destination).
#
# On archive-path collision, removes only the checksum this invocation
# just published, and only after re-verifying (via device+inode) that it
# is still the exact file this invocation created -- a pre-existing
# archive at that path is never touched.
publish_checksum_then_archive() {
    local staged_checksum="$1" staged_archive="$2" final_checksum="$3" final_archive="$4"

    # Armed before the hardlink attempt, not after -- see the state comment
    # above.
    PUBLISH_PENDING_CHECKSUM_PATH="$final_checksum"
    PUBLISH_PENDING_CHECKSUM_ID="$(stat_dev_inode "$staged_checksum")" || die "failed to stat staged checksum: $staged_checksum"

    if ! ln -- "$staged_checksum" "$final_checksum"; then
        # Our own hardlink never succeeded: there is nothing of ours to
        # clean up, and the pre-existing file at $final_checksum must never
        # be touched. Disarm directly rather than going through the
        # ownership check, so an ordinary, already-diagnosed collision
        # never also prints the generic mismatch diagnostic.
        PUBLISH_PENDING_CHECKSUM_PATH=""
        PUBLISH_PENDING_CHECKSUM_ID=""
        die "checksum already exists at destination, refusing to overwrite: $final_checksum"
    fi

    if ln -- "$staged_archive" "$final_archive"; then
        PUBLISH_PENDING_CHECKSUM_PATH=""
        PUBLISH_PENDING_CHECKSUM_ID=""
        return 0
    fi

    cleanup_pending_checksum_if_owned
    die "archive already exists at destination, refusing to overwrite: $final_archive"
}

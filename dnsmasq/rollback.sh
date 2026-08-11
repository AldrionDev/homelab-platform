#!/usr/bin/env bash
#
# Ownership-aware removal of the home lab's dnsmasq wildcard DNS drop-in.
#
# Takes no configuration: HOST_LAN_IP/HOMELAB_DOMAIN are never required here.
# The durable platform state under /var/lib/homelab-platform/dnsmasq/ already
# holds the exact expected bytes for both managed files, and every live path
# this script touches is fixed — an operator rolling back an installation to
# change HOST_LAN_IP or HOMELAB_DOMAIN must not need to supply the *old*
# values just to remove it. See dnsmasq/install.sh and docs/dnsmasq-runbook.md.
#
# Refuses to act on anything it cannot prove it owns: ownership is a
# byte-exact `cmp` against the platform-recorded expected content, never a
# managed-comment marker in the file (a marker only proves the content looks
# like something the platform would write, not that it's the exact content
# the platform actually wrote — it can't catch a hand-edit that preserves the
# comment). The running dnsmasq process is stopped and the stopped/disabled
# state is verified BEFORE any managed file is removed, since a process
# already running with the old config in memory is unaffected by what happens
# to the files on disk until it's actually restarted or stopped.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=dnsmasq/lib.sh
source "${SCRIPT_DIR}/lib.sh"

is_root() { [[ "$(id -u)" == "0" ]]; }

check_prerequisites() {
  is_root || die "This script must be run as root (sudo)."
  has_command systemctl || die "systemctl is required but was not found in PATH (systemd host required)."
}

do_rollback() {
  local unit="$DNSMASQ_UNIT_NAME"

  [[ -d "$STATE_DIR" && -f "$STATE_HOMELAB_CONF_EXPECTED" && -f "$STATE_DROPIN_EXPECTED" ]] \
    || die "no platform-owned installation state found at $STATE_DIR; nothing to roll back"

  if [[ ! -e "$HOMELAB_CONF_FILE" || ! -e "$SYSTEMD_DROPIN_FILE" ]]; then
    die "platform state exists at $STATE_DIR but a managed live file is already missing ($HOMELAB_CONF_FILE / $SYSTEMD_DROPIN_FILE) — inconsistent prior state, manual recovery required"
  fi

  # Ownership must be proven for BOTH files before anything is mutated — no
  # partial rollback of just the one that happens to match.
  local conf_ok=false dropin_ok=false
  files_match "$HOMELAB_CONF_FILE" "$STATE_HOMELAB_CONF_EXPECTED" && conf_ok=true
  files_match "$SYSTEMD_DROPIN_FILE" "$STATE_DROPIN_EXPECTED" && dropin_ok=true

  if [[ "$conf_ok" != true || "$dropin_ok" != true ]]; then
    printf 'ERROR: ownership could not be proven for one or more managed files:\n' >&2
    [[ "$conf_ok" == true ]] \
      || printf '  %s does not match the platform-recorded expected content\n' "$HOMELAB_CONF_FILE" >&2
    [[ "$dropin_ok" == true ]] \
      || printf '  %s does not match the platform-recorded expected content\n' "$SYSTEMD_DROPIN_FILE" >&2
    die "refusing to roll back: ownership not proven for both managed files. Nothing was removed; manual recovery required."
  fi

  # Both proven. Stop the process before touching any file on disk.
  systemctl disable --now "$unit" \
    || die "systemctl disable --now $unit failed; managed files and platform state left untouched, manual recovery required"

  verify_baseline_disabled_inactive "$unit" \
    || die "$unit did not verify inactive/disabled after disable --now; managed files and platform state left untouched, manual recovery required"

  rm -f -- "$SYSTEMD_DROPIN_FILE" || die "failed to remove $SYSTEMD_DROPIN_FILE; manual recovery required"
  rm -f -- "$HOMELAB_CONF_FILE" || die "failed to remove $HOMELAB_CONF_FILE; manual recovery required"

  systemctl daemon-reload \
    || die "systemctl daemon-reload failed after removing managed files; manual recovery required"

  # Only a directory the manifest explicitly names, and only if now empty. A
  # directory the manifest doesn't name is left in place, full stop — an
  # unnecessary leftover empty directory is preferred over deleting something
  # creation-ownership can't prove.
  local dir
  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    rmdir -- "$dir" 2>/dev/null \
      || printf 'NOTE: %s not removed (not empty, or removal failed); left in place.\n' "$dir" >&2
  done < <(read_created_dirs "$STATE_CREATED_DIRS_LIST")

  # State removed last, only after the live files and daemon-reload above are
  # confirmed successful, so any earlier failure always leaves the one thing
  # that proves ownership intact for a retry or manual recovery.
  rm -f -- "$STATE_HOMELAB_CONF_EXPECTED" "$STATE_DROPIN_EXPECTED" "$STATE_CREATED_DIRS_LIST"
  rmdir -- "$STATE_DIR" 2>/dev/null || true

  printf 'Rollback complete: %s is inactive and disabled; managed files and platform state removed.\n' "$unit"
}

main() {
  check_prerequisites
  do_rollback
}

if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
  main "$@"
fi

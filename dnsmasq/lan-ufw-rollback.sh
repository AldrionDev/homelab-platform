#!/usr/bin/env bash
#
# Ownership-safe removal of the dnsmasq LAN-UFW rules.
#
# Takes no configuration - it reads the durable ownership descriptor at
# /var/lib/homelab-platform/dnsmasq-lan-ufw/state.env (fixed schema, NEVER
# sourced or evaluated) and proves ownership of the live UFW rules before it
# removes anything.
#
#   PHASE=installed    : normal rollback. Requires BOTH exact platform-owned
#                        rules to be present (any missing / changed /
#                        duplicated / foreign state fails closed, nothing
#                        removed). It then atomically transitions the state to
#                        PHASE=rolling_back BEFORE the first firewall mutation.
#   PHASE=rolling_back  : a rollback that has already begun mutating. Supported,
#                        RESUMABLE recovery phase - if a delete or verification
#                        failed, a later invocation re-enters recovery here.
#   PHASE=installing    : recovery mode for an interrupted or failed install.
#
# In PHASE=rolling_back and PHASE=installing (recovery mode) it removes
# whichever of the two owned rules (0, 1 or 2) are provably present, still
# refusing on any foreign, drifted, ambiguous or duplicated rule, and only
# clears component state once every owned rule is proven absent and the
# unrelated-rule fingerprint is unchanged. Any delete/verify failure preserves
# the phase so a later run can safely resume.
#
# Every firewall inspection works from an explicitly captured + validated
# `ufw status` snapshot (exit 0 AND `Status: active`); a failed/inactive read
# aborts, it is never treated as "zero rules".
#
# Rules are deleted by stable spec (`ufw delete allow in on ...`), so the
# second delete is unaffected by the first renumbering. Never removes
# /var/lib/homelab-platform, never calls systemctl, never writes under /etc -
# the dnsmasq service and its configuration are untouched. Serialised against
# lan-ufw-install.sh via a single flock, acquired BEFORE any UFW inspection.
#
# See docs/dnsmasq-runbook.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=dnsmasq/lan-ufw-lib.sh
source "${SCRIPT_DIR}/lan-ufw-lib.sh"

do_rollback() {
  local ip="$ST_HOST_LAN_IP" iface="$ST_LAN_INTERFACE" subnet="$ST_LAN_SUBNET"
  local started="$ST_PHASE"

  # Capture + validate one live snapshot for the branch decision. A failed or
  # inactive `ufw status` here aborts with nothing removed and state untouched
  # - it is never read as "zero owned rules".
  local snap
  snap="$(mktemp)" || die "mktemp failed for UFW snapshot"
  ufw_snapshot "$snap" \
    || { rm -f "$snap"; die "cannot capture a valid live UFW snapshot; nothing was removed and no state was cleared, manual recovery may be required"; }

  local pre_fp udp_n tcp_n foreign
  pre_fp="$(ufw_fingerprint_excluding_owned "$snap" "$ip" "$iface" "$subnet")"
  udp_n="$(owned_rule_count "$snap" udp "$ip" "$iface" "$subnet")"
  tcp_n="$(owned_rule_count "$snap" tcp "$ip" "$iface" "$subnet")"
  foreign="$(list_foreign_dns_rules "$snap" "$ip" "$iface" "$subnet")"
  rm -f "$snap"

  if [[ "$started" == "installed" ]]; then
    # Normal rollback: prove BOTH exact rules present and no foreign state
    # BEFORE the first firewall mutation - not weakened.
    [[ -z "$foreign" ]] \
      || die "refusing to roll back: a foreign or drifted DNS firewall rule is present. Nothing was removed; manual recovery required."
    { ((udp_n == 1)) && ((tcp_n == 1)); } \
      || die "refusing to roll back: expected exactly the two platform-owned DNS rules (udp=$udp_n tcp=$tcp_n). Nothing was removed; manual recovery required."
    # Fix #1: atomically transition installed -> rolling_back BEFORE the first
    # firewall mutation. rolling_back is a supported, resumable recovery phase:
    # if a delete or verification fails below, state stays at rolling_back and
    # a later invocation re-enters this function's recovery branch.
    write_state rolling_back "$ip" "$subnet" "$iface"
    ST_PHASE="rolling_back"
  else
    # PHASE=installing OR PHASE=rolling_back -> recovery mode: 0/1/2 exact
    # owned rules allowed; still refuse foreign / drifted / duplicated.
    [[ -z "$foreign" ]] \
      || die "refusing recovery rollback: a foreign or drifted DNS firewall rule is present. Nothing was removed."
    { ((udp_n <= 1)) && ((tcp_n <= 1)); } \
      || die "refusing recovery rollback: an owned DNS rule tuple is duplicated (udp=$udp_n tcp=$tcp_n). Nothing was removed."
    if ((udp_n == 0 && tcp_n == 0)); then
      remove_component_state
      printf 'Recovery rollback: no platform-owned DNS rule was present; recovery state cleared.\n'
      return 0
    fi
  fi

  recovery_remove_owned_rules "$ip" "$iface" "$subnet" "$pre_fp" \
    || die "MANUAL RECOVERY REQUIRED: rule removal could not be proven safe or complete. Recovery state at $LAN_UFW_STATE_FILE was preserved at PHASE=${ST_PHASE}; re-run 'dnsmasq/lan-ufw-rollback.sh' to resume."

  remove_component_state

  if [[ "$started" == "installed" || "$started" == "rolling_back" ]]; then
    printf 'Rollback complete: the platform-owned dnsmasq LAN-UFW rules were removed; unrelated UFW rules untouched; state cleared.\n'
  else
    printf 'Recovery rollback complete: every provably platform-owned dnsmasq LAN-UFW rule was removed; unrelated UFW rules untouched; recovery state cleared.\n'
  fi
}

main() {
  # root + command availability, BEFORE any UFW state inspection.
  require_root
  require_commands ufw flock mktemp

  # acquire the shared exclusive lifecycle lock, held through completion.
  acquire_lifecycle_lock

  # only now inspect UFW / ownership state.
  ufw_is_active \
    || die "UFW is not active; cannot prove live rule state. If rules were left behind, manual recovery is required."

  [[ -e "$LAN_UFW_STATE_DIR" ]] \
    || die "no platform-owned dnsmasq-lan-ufw state found at $LAN_UFW_STATE_DIR; nothing to roll back"
  read_and_validate_state

  do_rollback
}

if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
  main "$@"
fi

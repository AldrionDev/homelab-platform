#!/usr/bin/env bash
#
# Open LAN-scoped DNS (UDP/53 + TCP/53) to this host's dnsmasq through UFW,
# for exactly one derived LAN subnet -> HOST_LAN_IP on one derived LAN
# interface.
#
# This is a SEPARATE, explicitly-invoked host mutation - not part of
# dnsmasq/install.sh. It never edits /etc, never touches the dnsmasq systemd
# unit or service state, and never introduces an unrestricted `ufw allow 53` /
# "Anywhere" DNS rule. The only effective policy it can ever produce is:
#
#   <LAN_SUBNET> -> <HOST_LAN_IP>:53/udp on <LAN_INTERFACE>
#   <LAN_SUBNET> -> <HOST_LAN_IP>:53/tcp on <LAN_INTERFACE>
#
# Behaviour:
#   * requires HOST_LAN_IP (dotted-quad IPv4), no default;
#   * requires root, `ip`, `ufw` (already active) and `flock`;
#   * serialised against lan-ufw-rollback.sh via a single flock, acquired
#     BEFORE any UFW state inspection;
#   * fail-closed LAN discovery (exact global address on exactly one non-
#     loopback interface, directly-connected subnet, interface on the IPv4
#     default route);
#   * fail-closed classification: install | noop | mismatch;
#   * transactional: a failure after the first rule is auto-rolled-back where
#     provable; otherwise recoverable state is preserved and the run exits
#     with MANUAL RECOVERY REQUIRED.
#
# See docs/dnsmasq-runbook.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=dnsmasq/lan-ufw-lib.sh
source "${SCRIPT_DIR}/lan-ufw-lib.sh"

validate_env() {
  [[ -n "${HOST_LAN_IP:-}" ]] || die "Missing required variable: HOST_LAN_IP"
}

# --- transactional trackers (file scope: the EXIT trap reads them) ---------

STATE_DIR_CREATED=false
STATE_PERSISTED=false
# ATTEMPT, not confirmed success: set true on the line BEFORE the corresponding
# `ufw allow` is invoked. A mutating `ufw allow` can apply its rule and STILL
# return non-zero (a later internal failure), so the exit status must never be
# trusted to prove "no firewall side effect". Cleanup reconciles the live
# firewall whenever a mutation was *attempted*, never gating on a success flag.
UDP_ATTEMPTED=false
TCP_ATTEMPTED=false
PRE_FP=""
DISC_IFACE=""
DISC_SUBNET=""

# Reverses exactly what this invocation did, using the shared, ownership-gated
# removal helper. If a provably-clean result cannot be reached, the recovery
# state (state.env at PHASE=installing) is preserved and the operator is told
# the exact outstanding `ufw delete` command(s).
install_failure_cleanup() {
  local rc="$?"
  trap - EXIT INT TERM

  local ip="${HOST_LAN_IP}" iface="$DISC_IFACE" subnet="$DISC_SUBNET"
  local clean=true

  # Reconcile whenever a UFW mutation may have occurred - i.e. any `ufw allow`
  # was invoked - regardless of its return code. recovery_remove_owned_rules is
  # snapshot-based and ownership-gated: it removes exactly the 0 / 1 / 2 owned
  # rules that are actually live (proving "clean" when the failed command had
  # no side effect), or preserves state and fails closed.
  if [[ "$UDP_ATTEMPTED" == true || "$TCP_ATTEMPTED" == true ]]; then
    recovery_remove_owned_rules "$ip" "$iface" "$subnet" "$PRE_FP" || clean=false
  fi

  if [[ "$clean" == true ]]; then
    if [[ "$STATE_PERSISTED" == true ]]; then
      remove_component_state
    elif [[ "$STATE_DIR_CREATED" == true ]]; then
      rmdir -- "$LAN_UFW_STATE_DIR" 2>/dev/null || true
    fi
    printf 'Install failed and was rolled back; no platform-owned UFW rule remains. See errors above.\n' >&2
    exit "$rc"
  fi

  printf 'MANUAL RECOVERY REQUIRED: automatic cleanup could not be proven complete.\n' >&2
  printf '  Recovery state preserved: %s (PHASE=installing)\n' "$LAN_UFW_STATE_FILE" >&2
  printf '  Supported next step: sudo bash %s/lan-ufw-rollback.sh   (recovery mode)\n' "$SCRIPT_DIR" >&2
  # Print the stable delete command for every ATTEMPTED protocol ("if still
  # present"), never omitting one merely because `ufw allow` returned non-zero
  # after possibly applying it.
  [[ "$UDP_ATTEMPTED" == true ]] \
    && printf '  Outstanding if still present: sudo %s\n' "$(ufw_delete_rule_cmd udp "$ip" "$iface" "$subnet")" >&2
  [[ "$TCP_ATTEMPTED" == true ]] \
    && printf '  Outstanding if still present: sudo %s\n' "$(ufw_delete_rule_cmd tcp "$ip" "$iface" "$subnet")" >&2
  exit "$rc"
}

do_install() {
  local ip="$1" iface="$2" subnet="$3"

  # 1. Capture + validate a live UFW snapshot for PRE_FP, BEFORE creating any
  #    durable state, so a failed/inactive `ufw status` here means truly
  #    nothing was created and no mutation happened.
  local snap
  snap="$(mktemp)" || die "mktemp failed for UFW snapshot"
  ufw_snapshot "$snap" || { rm -f "$snap"; die "cannot capture a valid live UFW snapshot; refusing to install"; }
  PRE_FP="$(ufw_fingerprint_excluding_owned "$snap" "$ip" "$iface" "$subnet")"
  rm -f "$snap"

  # 2. State root + component directory.
  if [[ -e "$PLATFORM_STATE_ROOT" && ! -d "$PLATFORM_STATE_ROOT" ]]; then
    die "$PLATFORM_STATE_ROOT exists but is not a directory; manual recovery required"
  fi
  # Two explicit mkdirs, never `mkdir -p`: a missing shared root is never
  # created implicitly as a side effect of creating the component dir. The
  # shared root is never removed by this component.
  if [[ ! -d "$PLATFORM_STATE_ROOT" ]]; then
    mkdir -m 0755 -- "$PLATFORM_STATE_ROOT" || die "failed to create $PLATFORM_STATE_ROOT"
  fi
  if [[ ! -d "$LAN_UFW_STATE_DIR" ]]; then
    mkdir -m 0700 -- "$LAN_UFW_STATE_DIR" || die "failed to create $LAN_UFW_STATE_DIR"
    STATE_DIR_CREATED=true
  fi

  # 3. Fix #3: arm the cleanup trap BEFORE the first durable state write, so a
  #    failed `write_state` also unwinds (the component dir this invocation
  #    created is removed; no UFW mutation has happened; no malformed state is
  #    left behind wedging future runs).
  trap install_failure_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  # 4. PHASE=installing is persisted BEFORE the first firewall mutation, so an
  #    interrupted run always leaves a descriptor rollback recovery mode uses.
  write_state installing "$ip" "$subnet" "$iface"
  STATE_PERSISTED=true

  # Mark ATTEMPT before the call: if `ufw allow` applies its rule then returns
  # non-zero, the tracker is already set and cleanup will reconcile it.
  UDP_ATTEMPTED=true
  ufw_add_rule udp "$ip" "$iface" "$subnet" || die "failed to add the UDP/53 UFW rule"
  TCP_ATTEMPTED=true
  ufw_add_rule tcp "$ip" "$iface" "$subnet" || die "failed to add the TCP/53 UFW rule"

  # --- post-mutation verification from a FRESH validated snapshot ---------
  local vsnap
  vsnap="$(mktemp)" || die "mktemp failed for UFW snapshot"
  ufw_snapshot "$vsnap" || { rm -f "$vsnap"; die "post-install check failed: cannot capture a valid live UFW snapshot"; }
  local udp_n tcp_n foreign post_fp
  udp_n="$(owned_rule_count "$vsnap" udp "$ip" "$iface" "$subnet")"
  tcp_n="$(owned_rule_count "$vsnap" tcp "$ip" "$iface" "$subnet")"
  foreign="$(list_foreign_dns_rules "$vsnap" "$ip" "$iface" "$subnet")"
  post_fp="$(ufw_fingerprint_excluding_owned "$vsnap" "$ip" "$iface" "$subnet")"
  rm -f "$vsnap"
  ((udp_n == 1)) || die "post-install check failed: expected exactly 1 owned UDP/53 rule, found $udp_n"
  ((tcp_n == 1)) || die "post-install check failed: expected exactly 1 owned TCP/53 rule, found $tcp_n"
  [[ -z "$foreign" ]] || die "post-install check failed: unexpected extra DNS rule(s) present"
  [[ "$post_fp" == "$PRE_FP" ]] || die "post-install check failed: unrelated UFW rules changed"

  # Only now is the install complete: flip the descriptor to PHASE=installed.
  write_state installed "$ip" "$subnet" "$iface"

  trap - EXIT INT TERM
  printf 'dnsmasq LAN-UFW install complete. Effective policy:\n'
  printf '  %s -> %s:53/udp on %s\n' "$subnet" "$ip" "$iface"
  printf '  %s -> %s:53/tcp on %s\n' "$subnet" "$ip" "$iface"
  printf 'Re-running this script against this exact state is a no-op.\n'
}

main() {
  # 1-3: input + root + command availability, BEFORE any UFW state inspection.
  validate_env
  validate_ipv4 "$HOST_LAN_IP"
  require_root
  require_commands ip ufw flock mktemp

  # 4: acquire the shared exclusive lifecycle lock, held through cleanup.
  acquire_lifecycle_lock

  # 5: only now inspect UFW / network / ownership state.
  ufw_is_active || die "UFW is not active; this lifecycle requires UFW to be installed and active"

  local disc iface prefix subnet
  disc="$(discover_lan_interface "$HOST_LAN_IP")"
  read -r iface prefix subnet <<< "$disc"
  DISC_IFACE="$iface"
  DISC_SUBNET="$subnet"

  local decision action reason
  decision="$(classify_state "$HOST_LAN_IP" "$iface" "$subnet")" || exit 1
  action="$(printf '%s\n' "$decision" | sed -n 's/^ACTION=//p')"
  reason="$(printf '%s\n' "$decision" | sed -n 's/^REASON=//p')"

  case "$action" in
    noop)
      printf 'dnsmasq LAN-UFW already matches HOST_LAN_IP=%s (%s on %s) and is fully applied. No changes made.\n' \
        "$HOST_LAN_IP" "$subnet" "$iface"
      exit 0
      ;;
    mismatch)
      printf 'ERROR: %s\n' "$reason" >&2
      printf 'This lifecycle installs only from a clean baseline, or no-ops against an exactly\n' >&2
      printf 'matching applied state. See docs/dnsmasq-runbook.md for recovery.\n' >&2
      exit 1
      ;;
    install)
      do_install "$HOST_LAN_IP" "$iface" "$subnet"
      ;;
    *)
      die "internal error: unrecognized classification '$action'"
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
  main "$@"
fi

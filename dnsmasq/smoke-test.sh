#!/usr/bin/env bash
#
# Read-only verification of the installed dnsmasq wildcard DNS setup.
#
# Requires HOST_LAN_IP and HOMELAB_DOMAIN — the same values dnsmasq/install.sh
# was run with. No root required; makes no changes. Each wildcard query uses a
# fresh unique marker so a cached answer can't produce a false pass.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=dnsmasq/lib.sh
source "${SCRIPT_DIR}/lib.sh"

validate_env() {
  local missing=()
  [[ -n "${HOST_LAN_IP:-}" ]] || missing+=("HOST_LAN_IP")
  [[ -n "${HOMELAB_DOMAIN:-}" ]] || missing+=("HOMELAB_DOMAIN")
  ((${#missing[@]} == 0)) || die "Missing required variable(s): ${missing[*]}"
}

check_prerequisites() {
  has_command dig || die "dig is required but was not found in PATH (install dnsutils/bind-tools)."
  has_command systemctl || die "systemctl is required but was not found in PATH (systemd host required)."
}

main() {
  validate_env
  validate_ipv4 "$HOST_LAN_IP"
  validate_domain "$HOMELAB_DOMAIN"
  check_prerequisites

  local failures=0

  local marker answer
  marker="smoke-$$-${RANDOM}.${HOMELAB_DOMAIN}"
  answer="$(dig +short "@${HOST_LAN_IP}" "$marker" 2>/dev/null || true)"
  if [[ "$answer" == "$HOST_LAN_IP" ]]; then
    printf 'OK: %s -> %s\n' "$marker" "$HOST_LAN_IP"
  else
    printf 'FAIL: dig @%s %s returned %s, expected %s\n' \
      "$HOST_LAN_IP" "$marker" "${answer:-<empty>}" "$HOST_LAN_IP" >&2
    failures=$((failures + 1))
  fi

  local upstream_answer
  upstream_answer="$(dig +short "@${HOST_LAN_IP}" example.com 2>/dev/null || true)"
  if [[ -n "$upstream_answer" ]]; then
    printf 'OK: example.com via dnsmasq -> %s\n' "$upstream_answer"
  else
    printf 'FAIL: dig @%s example.com returned no answer (upstream forwarding broken?)\n' "$HOST_LAN_IP" >&2
    failures=$((failures + 1))
  fi

  if unit_is_active "$DNSMASQ_UNIT_NAME"; then
    printf 'OK: %s is active\n' "$DNSMASQ_UNIT_NAME"
  else
    printf 'FAIL: %s is not active\n' "$DNSMASQ_UNIT_NAME" >&2
    failures=$((failures + 1))
  fi
  if unit_is_enabled "$DNSMASQ_UNIT_NAME"; then
    printf 'OK: %s is enabled\n' "$DNSMASQ_UNIT_NAME"
  else
    printf 'FAIL: %s is not enabled\n' "$DNSMASQ_UNIT_NAME" >&2
    failures=$((failures + 1))
  fi

  # This host's own normal resolver path (never touched by this platform
  # component) — checked independently of dnsmasq to confirm "normal DNS
  # resolution for all other domains continues to work" per issue #5's AC.
  local normal_answer
  normal_answer="$(dig +short example.com 2>/dev/null || true)"
  if [[ -n "$normal_answer" ]]; then
    printf "OK: example.com via this host's normal resolver -> %s\n" "$normal_answer"
  else
    printf 'FAIL: dig example.com (normal resolver path) returned no answer\n' >&2
    failures=$((failures + 1))
  fi

  if ((failures > 0)); then
    printf '%d check(s) failed.\n' "$failures" >&2
    exit 1
  fi
  printf 'All checks passed.\n'
}

if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
  main "$@"
fi

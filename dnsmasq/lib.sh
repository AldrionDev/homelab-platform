#!/usr/bin/env bash
#
# Shared helpers for dnsmasq/install.sh and dnsmasq/rollback.sh.
#
# Sourced only — never an entrypoint. Defines no `main`, runs nothing on
# source, and is safe to source twice (constants are guarded).
#
# Fixed production paths — never overridable via environment variable. Test
# seams are explicit function arguments defaulting to these, exactly like
# k3s/install.sh's K3S_UNIT_NAME/K3S_CONFIG_FILE.

if [[ -n "${HOMELAB_DNSMASQ_LIB_SH_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
readonly HOMELAB_DNSMASQ_LIB_SH_LOADED=1

# Deliberately NOT `readonly`: fixed production values that install.sh and
# rollback.sh never reassign, but the test seam for the higher-level
# orchestration functions in both scripts (which reference these globals
# directly, unlike this file's own pure functions, which take every path as
# an explicit call-time argument) is reassigning them after sourcing this
# file and before invoking the function under test — the same tmpdir-per-case
# isolation k3s/install.test.sh uses, just via reassignment instead of an
# extra argument on every orchestration call. Never attacker-controlled
# input, so immutability here buys no real safety margin.
DNSMASQ_UNIT_NAME="dnsmasq"
MAIN_DNSMASQ_CONF="/etc/dnsmasq.conf"
HOMELAB_CONF_DIR="/etc/dnsmasq.d"
HOMELAB_CONF_FILE="${HOMELAB_CONF_DIR}/homelab.conf"
SYSTEMD_DROPIN_DIR="/etc/systemd/system/dnsmasq.service.d"
SYSTEMD_DROPIN_FILE="${SYSTEMD_DROPIN_DIR}/homelab.conf"
# PLATFORM_STATE_ROOT is shared, persistent platform state — not owned by
# dnsmasq alone, so install.sh only ever creates it if absent and never
# removes it, and rollback.sh never touches it at all. STATE_DIR, beneath it,
# is dnsmasq's own component-private directory: created explicitly (never via
# an implicit mkdir-parent) and freely created/removed by this component.
PLATFORM_STATE_ROOT="/var/lib/homelab-platform"
STATE_DIR="${PLATFORM_STATE_ROOT}/dnsmasq"
STATE_HOMELAB_CONF_EXPECTED="${STATE_DIR}/homelab.conf.expected"
STATE_DROPIN_EXPECTED="${STATE_DIR}/dropin.expected"
STATE_CREATED_DIRS_LIST="${STATE_DIR}/created-dirs.list"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

has_command() { command -v "$1" >/dev/null 2>&1; }

# --- input validation --------------------------------------------------------

# Whole-string anchored before any splitting, same newline-injection defense
# as k3s/install.sh's validate_ipv4: `read` stops at the first newline, so a
# value like $'192.168.1.50\n<payload>' would validate on its first line
# while the untruncated value still reached the generated config.
validate_ipv4() {
  local ip="$1"
  [[ -n "$ip" ]] || die "HOST_LAN_IP is empty"
  [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] \
    || die "HOST_LAN_IP '$ip' is not a dotted-quad IPv4 address"
  local IFS=.
  local -a octets
  read -ra octets <<< "$ip"
  ((${#octets[@]} == 4)) || die "HOST_LAN_IP '$ip' is not a dotted-quad IPv4 address"
  local octet
  for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^(0|[1-9][0-9]{0,2})$ ]] \
      || die "HOST_LAN_IP '$ip' contains a malformed or leading-zero octet: '$octet'"
    ((10#$octet <= 255)) || die "HOST_LAN_IP '$ip' contains an out-of-range octet: $octet"
  done
}

# Whole-string anchored, same newline-injection defense: this value is
# interpolated directly into a generated dnsmasq `address=/.../...` line.
# Requires at least two dot-separated labels (rejects a bare TLD-style
# single label), each label 1-63 chars, alnum with internal hyphens only,
# total length <=253.
validate_domain() {
  local domain="$1"
  [[ -n "$domain" ]] || die "HOMELAB_DOMAIN is empty"
  ((${#domain} <= 253)) || die "HOMELAB_DOMAIN '$domain' exceeds 253 characters"
  [[ "$domain" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] \
    || die "HOMELAB_DOMAIN '$domain' is not a well-formed multi-label DNS domain"
}

# --- systemd inspection (all read-only) --------------------------------------

unit_property() {
  local unit="$1" prop="$2"
  systemctl show "$unit" --property="$prop" --value 2>/dev/null
}

unit_load_state()    { unit_property "${1:-$DNSMASQ_UNIT_NAME}" LoadState; }
unit_active_state()  { unit_property "${1:-$DNSMASQ_UNIT_NAME}" ActiveState; }
unit_fragment_path() { unit_property "${1:-$DNSMASQ_UNIT_NAME}" FragmentPath; }
unit_dropin_paths()  { unit_property "${1:-$DNSMASQ_UNIT_NAME}" DropInPaths; }

unit_is_loaded() { [[ "$(unit_load_state "${1:-$DNSMASQ_UNIT_NAME}")" == "loaded" ]]; }
unit_is_active() { [[ "$(unit_active_state "${1:-$DNSMASQ_UNIT_NAME}")" == "active" ]]; }
unit_is_enabled() { systemctl is-enabled --quiet "${1:-$DNSMASQ_UNIT_NAME}" 2>/dev/null; }

# Emits: none | own | foreign. Any DropInPaths content that isn't exactly the
# platform's own single file is "foreign" — including a set that contains
# ours plus something else.
dropin_state() {
  local unit="${1:-$DNSMASQ_UNIT_NAME}"
  local own_path="${2:-$SYSTEMD_DROPIN_FILE}"
  local paths
  paths="$(unit_dropin_paths "$unit")"
  if [[ -z "$paths" ]]; then
    echo "none"
  elif [[ "$paths" == "$own_path" ]]; then
    echo "own"
  else
    echo "foreign"
  fi
}

# Verifies the unit is both inactive and disabled. Used after a `disable
# --now` to prove the baseline was actually restored, not assumed.
verify_baseline_disabled_inactive() {
  local unit="${1:-$DNSMASQ_UNIT_NAME}"
  if unit_is_active "$unit"; then
    printf 'ERROR: %s is still active\n' "$unit" >&2
    return 1
  fi
  if unit_is_enabled "$unit"; then
    printf 'ERROR: %s is still enabled\n' "$unit" >&2
    return 1
  fi
  return 0
}

# --- base ExecStart derivation (no PCRE) -------------------------------------

# Reads the package's own ExecStart directly from the base unit *file*
# (FragmentPath), never from `systemctl show`'s structured argv[] display —
# that's a plain `Key=Value` line, so plain POSIX grep/sed is sufficient and
# no PCRE dependency is introduced. Fails closed on zero or multiple matches.
extract_base_execstart() {
  local fragment_path="$1"
  local count
  count=$(grep -c '^ExecStart=' -- "$fragment_path") || true
  [[ "$count" == "1" ]] \
    || die "expected exactly one ExecStart= line in $fragment_path, found ${count:-0}"
  sed -n 's/^ExecStart=//p' -- "$fragment_path"
}

# --- atomic writes -------------------------------------------------------------

# Writes $content to $target via a same-directory temp file + rename, never
# a direct truncating write to the final path. $mode is applied before the
# rename so the target is never briefly world-readable/writable.
atomic_write() {
  local target="$1" content="$2" mode="$3"
  local dir tmp
  dir="$(dirname -- "$target")"
  tmp="$(mktemp -- "${dir}/.$(basename -- "$target").XXXXXX")" \
    || die "atomic_write: mktemp failed in $dir"
  printf '%s' "$content" > "$tmp" || { rm -f -- "$tmp"; die "atomic_write: failed writing $tmp"; }
  chmod "$mode" -- "$tmp" || { rm -f -- "$tmp"; die "atomic_write: chmod failed on $tmp"; }
  mv -f -- "$tmp" "$target" || { rm -f -- "$tmp"; die "atomic_write: rename to $target failed"; }
}

# --- ownership proof ----------------------------------------------------------

# True only on an exact byte match. Any diff, or any error (including a
# permission failure, indistinguishable from "differs" from the exit code
# alone), is treated identically by callers: not proven, refuse to act.
files_match() {
  local a="$1" b="$2"
  cmp -s -- "$a" "$b"
}

# --- created-dirs manifest ------------------------------------------------

# Emits one directory per line, or nothing if the manifest is absent/empty.
read_created_dirs() {
  local list_file="$1"
  [[ -f "$list_file" ]] || return 0
  grep -v '^[[:space:]]*$' -- "$list_file" || true
}

# Atomically appends $dir to the manifest (read current content, append,
# write-temp-and-rename the whole file — never a partial append to the live
# path). Only ever called immediately after the corresponding mkdir succeeds.
append_created_dir() {
  local list_file="$1" dir="$2"
  local existing new
  existing="$(read_created_dirs "$list_file")"
  if [[ -n "$existing" ]]; then
    new="${existing}"$'\n'"${dir}"
  else
    new="${dir}"
  fi
  atomic_write "$list_file" "${new}"$'\n' 0600
}

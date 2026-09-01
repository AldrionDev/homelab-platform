#!/usr/bin/env bash
#
# Shared helpers for the dnsmasq LAN-UFW lifecycle:
#   dnsmasq/lan-ufw-install.sh and dnsmasq/lan-ufw-rollback.sh.
#
# This is a SEPARATE lifecycle from dnsmasq/install.sh / dnsmasq/rollback.sh.
# It never sources dnsmasq/lib.sh, never touches the dnsmasq systemd unit or
# service state, and never writes under /etc. It only ever adds or removes
# exactly two narrowly-scoped, platform-commented UFW rules:
#
#   <LAN_SUBNET> -> <HOST_LAN_IP>:53/udp on <LAN_INTERFACE>
#   <LAN_SUBNET> -> <HOST_LAN_IP>:53/tcp on <LAN_INTERFACE>
#
# It never introduces an unrestricted `ufw allow 53` / "Anywhere" DNS rule.
#
# Sourced only - defines no `main`, runs nothing on source, safe to source
# twice (guarded).

if [[ -n "${HOMELAB_DNSMASQ_LAN_UFW_LIB_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
readonly HOMELAB_DNSMASQ_LAN_UFW_LIB_LOADED=1

# All textual parsing of `ufw` / `ip` output in this component must be locale
# deterministic (issue #36). These are single-purpose host lifecycle scripts,
# so forcing the C locale process-wide is the simplest robust guarantee - it
# covers the tool output, `sort` collation and `grep`/`[[ =~ ]]` char classes
# in one place.
export LC_ALL=C
export LANG=C

# --- fixed production values (deliberately NOT readonly: the test seam) ------
#
# install.sh/rollback.sh never reassign these; the test suite reassigns them
# after sourcing and before invoking a function under test, exactly like
# dnsmasq/lib.sh's path globals.

PLATFORM_STATE_ROOT="/var/lib/homelab-platform"
LAN_UFW_STATE_DIR="${PLATFORM_STATE_ROOT}/dnsmasq-lan-ufw"
LAN_UFW_STATE_FILE="${LAN_UFW_STATE_DIR}/state.env"

# /run is tmpfs, always present on a systemd host, root-only writable, cleared
# on reboot - a lifecycle lock needs no persistence. flock is taken on fd 9
# and held for the whole process (including EXIT-trap cleanup).
LOCK_FILE="/run/homelab-platform-dnsmasq-lan-ufw.lock"

# The CODE-defined ownership comments are the SOLE authority for rule
# ownership. The copies persisted in state.env are only cross-checked for
# exact equality on read; their text is never trusted as authority.
LAN_UFW_UDP_COMMENT="homelab-platform:dnsmasq-lan-ufw udp/53"
LAN_UFW_TCP_COMMENT="homelab-platform:dnsmasq-lan-ufw tcp/53"

# Strict root-ownership / permission assertion on the component state dir+file.
# Production keeps this 1; the unit suite sets it to 0 so non-root tmpdir tests
# still exercise the symlink / non-regular-file shape checks. A dedicated test
# forces it back to 1 with a shadowed `stat`.
LAN_UFW_STATE_STRICT_PERMS=1

# --- basics ----------------------------------------------------------------

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

has_command() { command -v "$1" >/dev/null 2>&1; }

is_root() { [[ "$(id -u)" == "0" ]]; }

require_root() { is_root || die "This script must be run as root (sudo)."; }

require_commands() {
  local c
  for c in "$@"; do
    has_command "$c" || die "required command '$c' was not found in PATH"
  done
}

# --- input validation ----------------------------------------------------------

# Kept byte-for-byte in sync with dnsmasq/lib.sh:validate_ipv4 ON PURPOSE:
# this lifecycle is deliberately decoupled from the dnsmasq install lifecycle
# and must not source that (protected) file. If the canonical validator ever
# changes, this copy must be updated to match.
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

# Rejects /31 and /32 (a point-to-point / single-host prefix has no usable
# multi-host LAN subnet). NOTE: no minimum-prefix policy - a /8 is accepted;
# the real LAN-discovery gate is the exact-address + directly-connected-route
# + default-route consistency check in discover_lan_interface.
assert_usable_lan_prefix() {
  local prefix="$1" label="${2:-derived prefix}"
  { [[ "$prefix" =~ ^[0-9]{1,2}$ ]] && ((10#$prefix <= 32)); } \
    || die "$label: prefix '$prefix' is not in 0..32"
  ((10#$prefix <= 30)) \
    || die "$label: /$prefix is a point-to-point / single-host prefix with no usable LAN subnet"
}

validate_ifname() {
  local ifn="$1" label="${2:-LAN_INTERFACE}"
  [[ "$ifn" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,14}$ ]] \
    || die "$label '$ifn' is not a valid network interface name"
}

# --- CIDR math (pure bash, no ipcalc dependency) ---------------------------

# Emits the canonical "<network>/<prefix>" for <ip>/<prefix>. Non-zero (and a
# stderr note) on malformed input.
cidr_network() {
  local ip="$1" prefix="$2"
  { [[ "$prefix" =~ ^[0-9]{1,2}$ ]] && ((10#$prefix <= 32)); } \
    || { printf 'cidr_network: bad prefix %s\n' "$prefix" >&2; return 1; }
  local IFS=.
  local -a o
  read -ra o <<< "$ip"
  ((${#o[@]} == 4)) || { printf 'cidr_network: bad ip %s\n' "$ip" >&2; return 1; }
  local i
  for i in 0 1 2 3; do
    { [[ "${o[$i]}" =~ ^[0-9]{1,3}$ ]] && ((10#${o[$i]} <= 255)); } \
      || { printf 'cidr_network: bad octet %s\n' "${o[$i]}" >&2; return 1; }
  done
  local ip32=$(( (10#${o[0]} << 24) | (10#${o[1]} << 16) | (10#${o[2]} << 8) | 10#${o[3]} ))
  local mask
  if ((10#$prefix == 0)); then
    mask=0
  else
    mask=$(( (0xFFFFFFFF << (32 - 10#$prefix)) & 0xFFFFFFFF ))
  fi
  local net=$(( ip32 & mask ))
  printf '%d.%d.%d.%d/%d\n' \
    $(( (net >> 24) & 255 )) $(( (net >> 16) & 255 )) $(( (net >> 8) & 255 )) $(( net & 255 )) \
    "$((10#$prefix))"
}

# --- atomic write / byte-exact compare (as dnsmasq/lib.sh) ----------------

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

files_match() { cmp -s -- "$1" "$2"; }

# --- UFW inspection (read-only) ------------------------------------------------

# `ufw status` requires root; callers gate on require_root + acquire lock
# first. Never parsed for anything but the fixed English "Status:" line and
# the rule table, always under LC_ALL=C.
#
# Fail-closed rule: EVERY firewall inspection works from an explicitly captured
# and validated snapshot (`ufw_snapshot`). A failed or "inactive" `ufw status`
# is never allowed to silently degrade to "zero rules" - it aborts the caller.
ufw_is_active() {
  local out rc=0
  out="$(LC_ALL=C ufw status 2>/dev/null)" || rc=$?
  ((rc == 0)) || return 1
  [[ "$(printf '%s\n' "$out" | head -n1)" == "Status: active" ]]
}

# Captures a live UFW snapshot into the file $1 and VALIDATES it:
#   * `ufw status` must exit 0;
#   * its first line must be exactly `Status: active`.
# On any failure it writes a diagnostic to stderr and returns non-zero WITHOUT
# creating/overwriting a usable snapshot - callers must treat that as
# fail-closed (abort, never "no rules"). On success the validated raw output
# is in $1 and every rule-parsing helper reads only from that immutable file.
ufw_snapshot() {
  local out_file="$1" raw rc=0
  raw="$(LC_ALL=C ufw status 2>/dev/null)" || rc=$?
  if ((rc != 0)); then
    printf 'ERROR: `ufw status` failed (exit %s); refusing to act on an unreadable firewall\n' "$rc" >&2
    return 1
  fi
  if [[ "$(printf '%s\n' "$raw" | head -n1)" != "Status: active" ]]; then
    printf 'ERROR: captured UFW snapshot does not report `Status: active`; refusing to act\n' >&2
    return 1
  fi
  printf '%s\n' "$raw" > "$out_file" || {
    printf 'ERROR: failed to persist the UFW snapshot to %s\n' "$out_file" >&2
    return 1
  }
  return 0
}

# Emits only rule lines from an already-captured snapshot file $1: drops the
# "Status:" line, the "To ... Action ... From" header, the "-- -- ---"
# underline, and blank lines. Never calls `ufw` itself.
ufw_status_lines_from() {
  LC_ALL=C awk '
    /^Status:/                              { next }
    /^To[[:space:]]+Action[[:space:]]+From/ { next }
    /^-+[[:space:]]+-+[[:space:]]+-+/       { next }
    /^[[:space:]]*$/                        { next }
    { print }' "$1"
}

# tuple = everything before the first " # ", whitespace-squeezed and trimmed.
ufw_rule_tuple() {
  local line="$1" tuple
  tuple="${line%% # *}"
  printf '%s' "$tuple" | tr -s ' \t' ' ' | sed -e 's/^ //' -e 's/ $//'
}

# comment = everything after the first " # " (empty if none).
ufw_rule_comment() {
  local line="$1"
  case "$line" in
    *" # "*) printf '%s' "${line#* # }" ;;
    *)      printf '%s' "" ;;
  esac
}

# True if a UFW numeric port spec (proto suffix already stripped) includes
# destination port 53 - a bare `53`, a comma list (`53,67`), or a range
# (`53:60`, `50:53`). Never matches an unrelated port such as `5353`.
_port_spec_covers_53() {
  local spec="$1" item lo hi
  local IFS=,
  local -a items
  read -ra items <<< "$spec"
  for item in "${items[@]}"; do
    if [[ "$item" == *:* ]]; then
      lo="${item%%:*}"; hi="${item##*:}"
      [[ "$lo" =~ ^[0-9]+$ && "$hi" =~ ^[0-9]+$ ]] || continue
      ((10#$lo <= 53 && 53 <= 10#$hi)) && return 0
    else
      [[ "$item" =~ ^[0-9]+$ ]] || continue
      ((10#$item == 53)) && return 0
    fi
  done
  return 1
}

# True if the rule's destination port covers 53 in any numeric form UFW
# renders: `53`, `53/udp`, `53/tcp`, `53 (v6)`, a range that spans 53
# (`53:60/udp`, `50:53/tcp`), or a comma list that contains 53 (`53,67/udp`).
# A destination-specific rule renders the port as a field after the address
# (`192.0.2.10 53/udp on lan0 ...`), so every whitespace field is checked.
# Unrelated ports (`5353`, `80,443`, `1024:2000`) do not match.
line_is_dns_rule() {
  local tuple field core
  tuple="$(ufw_rule_tuple "$1")"
  for field in $tuple; do
    core="$field"
    case "$core" in
      */udp|*/tcp) core="${core%/*}" ;;
    esac
    [[ "$core" =~ ^[0-9]+([,:][0-9]+)*$ ]] || continue
    _port_spec_covers_53 "$core" && return 0
  done
  return 1
}

owned_comment_for() {
  case "$1" in
    udp) printf '%s' "$LAN_UFW_UDP_COMMENT" ;;
    tcp) printf '%s' "$LAN_UFW_TCP_COMMENT" ;;
    *)   return 1 ;;
  esac
}

# Semantic ownership match against a normalized `ufw status` rule tuple.
#
# The lifecycle deliberately captures PLAIN `ufw status`, whose rule rows on
# the real host (UFW 0.36.2) render the action as bare `ALLOW`:
#
#   192.0.2.10 53/udp on lan0     ALLOW     192.0.2.0/24     # <comment>
#
# `ufw status numbered` instead renders `ALLOW IN`. This matcher accepts
# EITHER representation, while still requiring every ownership field exactly:
#   * destination IP        == <ip>
#   * port/protocol token   == 53/<proto>
#   * on <iface>            == literally `on` then <iface>
#   * action               == `ALLOW` (an optional `IN` token may follow)
#   * source subnet         == <subnet>
#   * NO other tokens (exact field count).
# The ownership COMMENT is checked separately by the callers against the
# code-defined constant.
_tuple_is_owned_rule() {
  local tuple="$1" proto="$2" ip="$3" iface="$4" subnet="$5"
  local -a t
  read -ra t <<< "$tuple" || true
  { ((${#t[@]} == 6)) || ((${#t[@]} == 7)); } || return 1
  [[ "${t[0]}" == "$ip"         ]] || return 1
  [[ "${t[1]}" == "53/$proto"   ]] || return 1
  [[ "${t[2]}" == "on"          ]] || return 1
  [[ "${t[3]}" == "$iface"      ]] || return 1
  [[ "${t[4]}" == "ALLOW"       ]] || return 1
  if ((${#t[@]} == 7)); then
    [[ "${t[5]}" == "IN"      ]] || return 1
    [[ "${t[6]}" == "$subnet" ]] || return 1
  else
    [[ "${t[5]}" == "$subnet" ]] || return 1
  fi
  return 0
}

# True if a status LINE is exactly one of our two owned rules: the semantic
# tuple match above AND the exact code-defined ownership comment.
_line_is_owned_rule() {
  local line="$1" proto="$2" ip="$3" iface="$4" subnet="$5" want_comment
  want_comment="$(owned_comment_for "$proto")" || return 1
  [[ "$(ufw_rule_comment "$line")" == "$want_comment" ]] || return 1
  _tuple_is_owned_rule "$(ufw_rule_tuple "$line")" "$proto" "$ip" "$iface" "$subnet"
}

# Number of rules IN SNAPSHOT $1 that are exactly our owned <proto> rule
# (semantic tuple + exact ownership comment). The caller treats 0 / 1 / >1
# distinctly. Reads only the snapshot.
owned_rule_count() {
  local snap="$1" proto="$2" ip="$3" iface="$4" subnet="$5"
  local n=0 line
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    _line_is_owned_rule "$line" "$proto" "$ip" "$iface" "$subnet" || continue
    n=$((n + 1))
  done < <(ufw_status_lines_from "$snap")
  printf '%d\n' "$n"
}

# DNS-port rule lines IN SNAPSHOT $1 that are NOT one of our two exact owned
# rules. A line carrying one of our ownership comments on a non-matching tuple
# is reported here too (drift / tamper). Reads only the snapshot.
list_foreign_dns_rules() {
  local snap="$1" ip="$2" iface="$3" subnet="$4"
  local line comment
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if _line_is_owned_rule "$line" udp "$ip" "$iface" "$subnet"; then continue; fi
    if _line_is_owned_rule "$line" tcp "$ip" "$iface" "$subnet"; then continue; fi
    comment="$(ufw_rule_comment "$line")"
    if line_is_dns_rule "$line"; then
      printf '%s\n' "$line"
    elif [[ "$comment" == "$LAN_UFW_UDP_COMMENT" || "$comment" == "$LAN_UFW_TCP_COMMENT" ]]; then
      printf '%s\n' "$line"
    fi
  done < <(ufw_status_lines_from "$snap")
}

# Sorted fingerprint of every rule IN SNAPSHOT $1 EXCEPT our two exact owned
# rules - compared before/after a mutation to prove unrelated rules were
# untouched. Reads only the snapshot.
ufw_fingerprint_excluding_owned() {
  local snap="$1" ip="$2" iface="$3" subnet="$4"
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if _line_is_owned_rule "$line" udp "$ip" "$iface" "$subnet"; then continue; fi
    if _line_is_owned_rule "$line" tcp "$ip" "$iface" "$subnet"; then continue; fi
    printf '%s # %s\n' "$(ufw_rule_tuple "$line")" "$(ufw_rule_comment "$line")"
  done < <(ufw_status_lines_from "$snap") | LC_ALL=C sort
}

# (all `ip` / `ufw` reads are pinned to LC_ALL=C for deterministic textual
# parsing regardless of the caller's locale.)

# --- rule spec builders (add / delete / human) ---------------------------

ufw_add_rule() {
  local proto="$1" ip="$2" iface="$3" subnet="$4" comment
  comment="$(owned_comment_for "$proto")" || die "ufw_add_rule: bad proto '$proto'"
  ufw allow in on "$iface" from "$subnet" to "$ip" port 53 proto "$proto" comment "$comment"
}

# Spec-based delete: matches the rule tuple regardless of its current UFW
# number, so a second delete is still correctly addressed after the first.
ufw_delete_rule() {
  local proto="$1" ip="$2" iface="$3" subnet="$4"
  ufw delete allow in on "$iface" from "$subnet" to "$ip" port 53 proto "$proto"
}

ufw_delete_rule_cmd() {
  local proto="$1" ip="$2" iface="$3" subnet="$4"
  printf "ufw delete allow in on %s from %s to %s port 53 proto %s" "$iface" "$subnet" "$ip" "$proto"
}

# --- LAN discovery -------------------------------------------------------------

# Echoes "<iface> <prefix> <scope>" for every interface carrying EXACTLY <ip>
# as an IPv4 address (one line per match).
_addr_iface_prefix_scope() {
  local ip="$1"
  LC_ALL=C ip -o -4 addr show 2>/dev/null | LC_ALL=C awk -v want="$ip" '
    {
      iface=$2; sub(/:$/, "", iface)
      addr=""; pfx=""; scope=""
      for (i = 1; i <= NF; i++) {
        if ($i == "inet")  { split($(i + 1), a, "/"); addr = a[1]; pfx = a[2] }
        if ($i == "scope") { scope = $(i + 1) }
      }
      if (addr == want) print iface, pfx, scope
    }'
}

# Fail-closed LAN discovery for HOST_LAN_IP. Echoes "<iface> <prefix> <subnet>"
# only when ALL of the following hold, otherwise dies:
#   * the exact IPv4 address exists on exactly one interface;
#   * that address has global scope;
#   * the interface is not a loopback interface;
#   * the derived subnet is directly connected (scope link) on that interface;
#   * that interface also carries an IPv4 default route (rules out CNI/Docker
#     bridges that merely have a connected route for the address).
# Nothing is hard-coded - every value is derived from `ip` output.
discover_lan_interface() {
  local ip="$1"
  local -a matches=()
  local m
  while IFS= read -r m; do
    [[ -n "$m" ]] && matches+=("$m")
  done < <(_addr_iface_prefix_scope "$ip")

  ((${#matches[@]} != 0)) \
    || die "HOST_LAN_IP $ip is not present on any interface"
  ((${#matches[@]} == 1)) \
    || die "HOST_LAN_IP $ip is present on multiple interfaces; ambiguous LAN interface discovery"

  local iface prefix scope
  read -r iface prefix scope <<< "${matches[0]}"

  validate_ifname "$iface" "discovered interface"

  [[ "$scope" == "global" ]] \
    || die "HOST_LAN_IP $ip has non-global scope '${scope:-<none>}' on $iface; refusing (not a LAN address)"

  local link_line
  link_line="$(LC_ALL=C ip -o link show dev "$iface" 2>/dev/null)"
  [[ "$link_line" == *"<"*"LOOPBACK"*">"* ]] \
    && die "interface $iface carrying HOST_LAN_IP $ip is a loopback interface; refusing"

  assert_usable_lan_prefix "$prefix" "discovered prefix for $ip"

  local subnet
  subnet="$(cidr_network "$ip" "$prefix")" \
    || die "could not derive the connected subnet for $ip/$prefix"

  local link_route
  link_route="$(LC_ALL=C ip -o -4 route show dev "$iface" scope link 2>/dev/null \
    | LC_ALL=C awk -v s="$subnet" '$1 == s { print; exit }')"
  [[ -n "$link_route" ]] \
    || die "derived LAN subnet $subnet is not a directly-connected route on $iface; inconsistent discovery"

  local default_route
  default_route="$(LC_ALL=C ip -o -4 route show default 2>/dev/null \
    | LC_ALL=C awk -v d="$iface" '{ for (i = 1; i <= NF; i++) if ($i == "dev" && $(i + 1) == d) { print; exit } }')"
  [[ -n "$default_route" ]] \
    || die "interface $iface does not carry an IPv4 default route; refusing (HOST_LAN_IP must sit on the LAN uplink, not a bridge)"

  printf '%s %s %s\n' "$iface" "$prefix" "$subnet"
}

# --- durable ownership state (fixed schema; NEVER sourced / evaluated) ------

ST_PHASE=""
ST_HOST_LAN_IP=""
ST_LAN_SUBNET=""
ST_LAN_INTERFACE=""

# Refuses an unsafe filesystem shape for the component state dir/file. Under
# root (production) also asserts strict root:root 0700 / 0600, unless the
# LAN_UFW_STATE_STRICT_PERMS test seam is 0.
verify_state_fs_shape() {
  local dir="$1" file="$2"
  [[ -e "$dir" ]] || die "no dnsmasq-lan-ufw state directory at $dir"
  { [[ -d "$dir" && ! -L "$dir" ]]; } || die "$dir is a symlink or not a directory; refusing"
  [[ -e "$file" ]] || die "no dnsmasq-lan-ufw state file at $file"
  { [[ -f "$file" && ! -L "$file" ]]; } || die "$file is a symlink or not a regular file; refusing"
  if is_root && [[ "${LAN_UFW_STATE_STRICT_PERMS:-1}" == "1" ]]; then
    local dm fm
    dm="$(stat -c '%U %G %a' -- "$dir" 2>/dev/null)"  || die "cannot stat $dir"
    fm="$(stat -c '%U %G %a' -- "$file" 2>/dev/null)" || die "cannot stat $file"
    [[ "$dm" == "root root 700" ]] \
      || die "$dir has unsafe ownership/permissions '$dm' (want 'root root 700'); refusing"
    [[ "$fm" == "root root 600" ]] \
      || die "$file has unsafe ownership/permissions '$fm' (want 'root root 600'); refusing"
  fi
}

# Parses the fixed six-key schema into ST_* globals. Rejects: unsafe FS shape,
# non KEY=VALUE lines, control chars in a value, unknown key, duplicate key,
# missing key, and any value that fails its own revalidation. The persisted
# ownership comments must EXACTLY equal the code constants. Never executes any
# byte of the file.
read_and_validate_state() {
  local file="${1:-$LAN_UFW_STATE_FILE}"
  local dir
  dir="$(dirname -- "$file")"
  verify_state_fs_shape "$dir" "$file"

  local expected="PHASE HOST_LAN_IP LAN_SUBNET LAN_INTERFACE UDP_COMMENT TCP_COMMENT"
  local -A kv=()
  local line key val lineno=0

  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    ((lineno <= 64)) || die "state file $file has too many lines; refusing"
    [[ -n "$line" ]] || die "state file $file has a blank line ($lineno); refusing"
    [[ "$line" =~ ^([A-Z_]+)=(.*)$ ]] \
      || die "state file $file line $lineno is not KEY=VALUE; refusing"
    key="${BASH_REMATCH[1]}"
    val="${BASH_REMATCH[2]}"
    [[ "$val" =~ [[:cntrl:]] ]] \
      && die "state file $file key $key has a control character in its value; refusing"
    case " $expected " in
      *" $key "*) : ;;
      *) die "state file $file has an unknown key '$key'; refusing" ;;
    esac
    [[ -z "${kv[$key]+set}" ]] || die "state file $file has a duplicate key '$key'; refusing"
    kv[$key]="$val"
  done < "$file"

  local k
  for k in $expected; do
    [[ -n "${kv[$k]+set}" ]] || die "state file $file is missing required key '$k'; refusing"
  done

  validate_ipv4 "${kv[HOST_LAN_IP]}"
  validate_cidr "${kv[LAN_SUBNET]}" "LAN_SUBNET"
  validate_ifname "${kv[LAN_INTERFACE]}" "LAN_INTERFACE"
  case "${kv[PHASE]}" in
    installing|installed|rolling_back) : ;;
    *) die "state file $file has an invalid PHASE '${kv[PHASE]}'; refusing" ;;
  esac

  [[ "${kv[UDP_COMMENT]}" == "$LAN_UFW_UDP_COMMENT" ]] \
    || die "state file $file UDP_COMMENT does not equal the platform ownership constant; refusing"
  [[ "${kv[TCP_COMMENT]}" == "$LAN_UFW_TCP_COMMENT" ]] \
    || die "state file $file TCP_COMMENT does not equal the platform ownership constant; refusing"

  ST_PHASE="${kv[PHASE]}"
  ST_HOST_LAN_IP="${kv[HOST_LAN_IP]}"
  ST_LAN_SUBNET="${kv[LAN_SUBNET]}"
  ST_LAN_INTERFACE="${kv[LAN_INTERFACE]}"
}

# <ipv4>/<prefix>, prefix 0..30, canonical network address (host bits zero).
validate_cidr() {
  local cidr="$1" label="${2:-LAN_SUBNET}"
  [[ -n "$cidr" ]] || die "$label is empty"
  [[ "$cidr" =~ ^([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})/([0-9]{1,2})$ ]] \
    || die "$label '$cidr' is not <ipv4>/<prefix>"
  local addr="${BASH_REMATCH[1]}" prefix="${BASH_REMATCH[2]}"
  ( validate_ipv4 "$addr" ) >/dev/null 2>&1 || die "$label '$cidr' has a malformed IPv4 part"
  { [[ "$prefix" =~ ^[0-9]{1,2}$ ]] && ((10#$prefix <= 32)); } \
    || die "$label '$cidr' prefix is out of range"
  assert_usable_lan_prefix "$prefix" "$label"
  local canon
  canon="$(cidr_network "$addr" "$prefix")" || die "$label '$cidr' failed network derivation"
  [[ "$canon" == "$cidr" ]] \
    || die "$label '$cidr' is not the canonical network address (expected $canon)"
}

write_state() {
  local phase="$1" ip="$2" subnet="$3" iface="$4" content
  printf -v content '%s\n' \
    "PHASE=${phase}" \
    "HOST_LAN_IP=${ip}" \
    "LAN_SUBNET=${subnet}" \
    "LAN_INTERFACE=${iface}" \
    "UDP_COMMENT=${LAN_UFW_UDP_COMMENT}" \
    "TCP_COMMENT=${LAN_UFW_TCP_COMMENT}"
  atomic_write "$LAN_UFW_STATE_FILE" "$content" 0600
}

# Removes ONLY this component's own state; never the shared
# /var/lib/homelab-platform root.
remove_component_state() {
  rm -f -- "$LAN_UFW_STATE_FILE"
  rmdir -- "$LAN_UFW_STATE_DIR" 2>/dev/null || true
}

# --- shared removal helper (install cleanup + rollback recovery) ----------

# Removes whichever of the two owned rules are currently present (0/1/2), by
# stable spec. Every check works from a FRESH validated snapshot: the gate
# snapshot immediately before the first delete, a re-captured snapshot after
# each delete, and a final snapshot for the "both absent + unrelated
# unchanged" verification. Refuses (returns 1) BEFORE any delete on a
# foreign/drifted DNS rule or a duplicated owned tuple, and returns 1 on any
# snapshot failure or verification failure - so a caller that preserves state
# on a non-zero return stays resumable. Returns 0 only when the result is
# provably clean.
recovery_remove_owned_rules() {
  local ip="$1" iface="$2" subnet="$3" pre_fp="$4"
  local snap rc=0
  snap="$(mktemp)" || { printf 'ERROR: mktemp failed for UFW snapshot\n' >&2; return 1; }
  _recovery_remove_owned_rules_impl "$snap" "$ip" "$iface" "$subnet" "$pre_fp" || rc=$?
  rm -f "$snap"
  return "$rc"
}

# All exits are `return N` (never `die`), so the wrapper above always cleans up
# the temp snapshot and the caller can preserve state on any non-zero return.
_recovery_remove_owned_rules_impl() {
  local snap="$1" ip="$2" iface="$3" subnet="$4" pre_fp="$5"

  ufw_snapshot "$snap" || return 1

  local foreign
  foreign="$(list_foreign_dns_rules "$snap" "$ip" "$iface" "$subnet")"
  if [[ -n "$foreign" ]]; then
    printf 'refusing: a foreign or drifted DNS firewall rule is present:\n%s\n' "$foreign" >&2
    return 1
  fi

  local udp_n tcp_n
  udp_n="$(owned_rule_count "$snap" udp "$ip" "$iface" "$subnet")"
  tcp_n="$(owned_rule_count "$snap" tcp "$ip" "$iface" "$subnet")"
  { ((udp_n <= 1)) && ((tcp_n <= 1)); } \
    || { printf 'refusing: an owned DNS rule tuple is duplicated (udp=%s tcp=%s)\n' "$udp_n" "$tcp_n" >&2; return 1; }

  if ((udp_n == 1)); then
    ufw_delete_rule udp "$ip" "$iface" "$subnet" \
      || { printf 'ufw delete (udp/53) failed\n' >&2; return 1; }
    ufw_snapshot "$snap" || return 1
    [[ "$(owned_rule_count "$snap" udp "$ip" "$iface" "$subnet")" == 0 ]] \
      || { printf 'udp/53 rule still present after delete\n' >&2; return 1; }
  fi

  tcp_n="$(owned_rule_count "$snap" tcp "$ip" "$iface" "$subnet")"
  if ((tcp_n == 1)); then
    ufw_delete_rule tcp "$ip" "$iface" "$subnet" \
      || { printf 'ufw delete (tcp/53) failed\n' >&2; return 1; }
    ufw_snapshot "$snap" || return 1
    [[ "$(owned_rule_count "$snap" tcp "$ip" "$iface" "$subnet")" == 0 ]] \
      || { printf 'tcp/53 rule still present after delete\n' >&2; return 1; }
  fi

  ufw_snapshot "$snap" || return 1
  local final_udp final_tcp
  final_udp="$(owned_rule_count "$snap" udp "$ip" "$iface" "$subnet")"
  final_tcp="$(owned_rule_count "$snap" tcp "$ip" "$iface" "$subnet")"
  { ((final_udp == 0)) && ((final_tcp == 0)); } \
    || { printf 'owned DNS rules still present after removal (udp=%s tcp=%s)\n' "$final_udp" "$final_tcp" >&2; return 1; }

  local post_fp
  post_fp="$(ufw_fingerprint_excluding_owned "$snap" "$ip" "$iface" "$subnet")"
  [[ "$post_fp" == "$pre_fp" ]] \
    || { printf 'unrelated UFW rules changed during removal; aborting\n' >&2; return 1; }

  return 0
}

# --- lifecycle lock ---------------------------------------------------------

# Exclusive, non-blocking. fd 9 stays open for the life of the process, so the
# lock is held through the EXIT-trap cleanup. MUST be acquired before any UFW
# state inspection (including ufw_is_active).
acquire_lifecycle_lock() {
  exec 9>"$LOCK_FILE" || die "cannot open lifecycle lock file $LOCK_FILE"
  flock -n 9 \
    || die "another dnsmasq-lan-ufw lifecycle operation is already in progress ($LOCK_FILE); refusing to run concurrently"
}

# --- classification (non-mutating) ---------------------------------------------

emit_decision() {
  printf 'ACTION=%s\n' "$1"
  printf 'REASON=%s\n' "$2"
}

# Prints ACTION=install|noop|mismatch + REASON=... . Performs no mutation.
# Captures its own validated live UFW snapshot; dies (fail closed) if that
# snapshot cannot be captured/validated, or if a present state file cannot be
# parsed and validated - never adopts an unreadable firewall or unparseable
# state, and in particular a failed `ufw status` is never seen as a clean
# baseline.
classify_state() {
  local ip="$1" iface="$2" subnet="$3"
  local snap rc=0
  snap="$(mktemp)" || die "mktemp failed for UFW snapshot"
  _classify_state_impl "$snap" "$ip" "$iface" "$subnet" || rc=$?
  rm -f "$snap"
  ((rc == 0)) || die "could not obtain a valid live UFW snapshot for classification; refusing (a failed 'ufw status' is never treated as a clean baseline)"
  return 0
}

_classify_state_impl() {
  local snap="$1" ip="$2" iface="$3" subnet="$4"
  ufw_snapshot "$snap" || return 2

  if [[ ! -e "$LAN_UFW_STATE_DIR" ]]; then
    local line hit=""
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      if line_is_dns_rule "$line"; then hit=1; break; fi
      case "$(ufw_rule_comment "$line")" in
        "$LAN_UFW_UDP_COMMENT"|"$LAN_UFW_TCP_COMMENT") hit=1; break ;;
      esac
    done < <(ufw_status_lines_from "$snap")
    if [[ -n "$hit" ]]; then
      emit_decision mismatch "a DNS / port-53 firewall rule already exists but this platform holds no ownership state for it; refusing to adopt a foreign or pre-existing rule"
      return 0
    fi
    emit_decision install ""
    return 0
  fi

  read_and_validate_state

  case "$ST_PHASE" in
    installing)
      emit_decision mismatch "an interrupted prior install is recorded (PHASE=installing); run 'dnsmasq/lan-ufw-rollback.sh' (recovery mode) before reinstalling"
      return 0 ;;
    rolling_back)
      emit_decision mismatch "an interrupted rollback is recorded (PHASE=rolling_back); run 'dnsmasq/lan-ufw-rollback.sh' again to finish it before reinstalling"
      return 0 ;;
  esac

  if [[ "$ST_HOST_LAN_IP" != "$ip" || "$ST_LAN_SUBNET" != "$subnet" || "$ST_LAN_INTERFACE" != "$iface" ]]; then
    emit_decision mismatch "recorded owned state ($ST_HOST_LAN_IP on $ST_LAN_INTERFACE, $ST_LAN_SUBNET) differs from freshly-derived ($ip on $iface, $subnet); roll back then reinstall"
    return 0
  fi

  local foreign
  foreign="$(list_foreign_dns_rules "$snap" "$ip" "$iface" "$subnet")"
  if [[ -n "$foreign" ]]; then
    emit_decision mismatch "a foreign or drifted DNS firewall rule is present alongside the platform-owned rules; refusing"
    return 0
  fi

  local udp_n tcp_n
  udp_n="$(owned_rule_count "$snap" udp "$ip" "$iface" "$subnet")"
  tcp_n="$(owned_rule_count "$snap" tcp "$ip" "$iface" "$subnet")"
  if ((udp_n == 1 && tcp_n == 1)); then
    emit_decision noop ""
    return 0
  fi

  emit_decision mismatch "recorded PHASE=installed but the live firewall does not hold exactly the two platform-owned rules (udp=$udp_n tcp=$tcp_n); run 'dnsmasq/lan-ufw-rollback.sh' then reinstall"
  return 0
}

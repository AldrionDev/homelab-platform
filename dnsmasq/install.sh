#!/usr/bin/env bash
#
# Install the home lab's dnsmasq wildcard DNS drop-in as a systemd service.
#
# Requires HOST_LAN_IP (dotted-quad IPv4) and HOMELAB_DOMAIN (multi-label DNS
# domain). Neither has a default: an unset or malformed value is a hard error.
#
# Never edits /etc/dnsmasq.conf and never `conf-dir`s the whole /etc/dnsmasq.d
# directory — only the single platform-owned /etc/dnsmasq.d/homelab.conf file
# is ever written or read, loaded via an explicit two-file --conf-file systemd
# drop-in derived from the actually-installed dnsmasq unit.
#
# Idempotency and fail-closed behavior are enforced by this script: re-running
# inspects the existing installation and either no-ops or refuses, never
# silently overwriting a differing config. The platform only takes ownership
# of dnsmasq's lifecycle from a provably clean baseline (inactive, disabled,
# no prior platform state) — an already active/enabled dnsmasq with no
# platform state is treated as a foreign, pre-existing deployment and refused.
#
# The install transaction is itself fail-closed: any failure after the first
# mutation triggers automatic, ownership-safe cleanup (dnsmasq/lib.sh), never
# leaving a silently half-installed DNS configuration.
#
# See docs/dnsmasq-runbook.md for operations, verification, and the separate
# dnsmasq/rollback.sh procedure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=dnsmasq/lib.sh
source "${SCRIPT_DIR}/lib.sh"

# --- input validation --------------------------------------------------------

validate_env() {
  local missing=()
  [[ -n "${HOST_LAN_IP:-}" ]] || missing+=("HOST_LAN_IP")
  [[ -n "${HOMELAB_DOMAIN:-}" ]] || missing+=("HOMELAB_DOMAIN")
  ((${#missing[@]} == 0)) || die "Missing required variable(s): ${missing[*]}"
}

# --- preflight (read-only) ---------------------------------------------------

is_root() { [[ "$(id -u)" == "0" ]]; }

check_prerequisites() {
  is_root || die "This script must be run as root (sudo)."
  has_command dnsmasq \
    || die "dnsmasq is not installed; install it via your package manager first (out of scope for this script)."
  has_command systemctl \
    || die "systemctl is required but was not found in PATH (systemd host required)."
  has_command dig \
    || die "dig is required for post-install verification; install your distro's dnsutils/bind-tools package first."
  has_command mktemp || die "mktemp is required but was not found in PATH."
}

# --- rendering ----------------------------------------------------------------

render_homelab_conf() {
  local domain="$1" ip="$2"
  cat <<EOF
# Managed by homelab-platform (see docs/dnsmasq-runbook.md).
# Wildcard resolution for the home lab. All other domains continue to
# forward normally through dnsmasq's own default upstream (this host's
# /etc/resolv.conf) — no no-resolv/server= exclusivity is set here.
address=/${domain}/${ip}
listen-address=${ip}
bind-interfaces
EOF
}

# ExecStartPre here is additive: systemd only clears prior ExecStartPre=
# directives on an *empty* assignment, which this drop-in never does, so the
# package's own default-file precheck still runs alongside this one. Only
# ExecStart= is cleared-and-replaced.
render_dropin() {
  local base_execstart="$1"
  cat <<EOF
# Managed by homelab-platform (see docs/dnsmasq-runbook.md).
# Loads the package's own ${MAIN_DNSMASQ_CONF} plus exactly the
# platform-owned ${HOMELAB_CONF_FILE} — never the whole ${HOMELAB_CONF_DIR}
# directory, never an edit to the package-shipped config.
[Service]
ExecStart=
ExecStart=${base_execstart} --conf-file=${MAIN_DNSMASQ_CONF} --conf-file=${HOMELAB_CONF_FILE}
ExecStartPre=/usr/bin/dnsmasq --test --conf-file=${MAIN_DNSMASQ_CONF} --conf-file=${HOMELAB_CONF_FILE}
EOF
}

# True only if $file exists and its content byte-matches $content exactly.
content_matches_file() {
  local content="$1" file="$2"
  [[ -f "$file" ]] || return 1
  local tmp rc=0
  tmp="$(mktemp)"
  printf '%s' "$content" > "$tmp"
  files_match "$tmp" "$file" || rc=1
  rm -f -- "$tmp"
  return "$rc"
}

# --- existing-installation inspection (all read-only) ------------------------

emit_decision() {
  printf 'ACTION=%s\n' "$1"
  printf 'REASON=%s\n' "$2"
}

# Single source of truth for the noop/mismatch/install decision. Performs no
# mutation in any branch, including "install".
inspect_installation() {
  local domain="$1" ip="$2"
  local unit="$DNSMASQ_UNIT_NAME"

  if ! unit_is_loaded "$unit"; then
    emit_decision "mismatch" \
      "dnsmasq systemd unit is not loaded despite the dnsmasq binary being present"
    return 0
  fi

  if [[ -e "$PLATFORM_STATE_ROOT" && ! -d "$PLATFORM_STATE_ROOT" ]]; then
    emit_decision "mismatch" \
      "$PLATFORM_STATE_ROOT exists but is not a directory; this is the shared platform state root, manual recovery required"
    return 0
  fi

  local active=false enabled=false
  unit_is_active "$unit" && active=true
  unit_is_enabled "$unit" && enabled=true

  local state_present=false
  [[ -f "$STATE_HOMELAB_CONF_EXPECTED" && -f "$STATE_DROPIN_EXPECTED" ]] && state_present=true

  local dstate
  dstate="$(dropin_state "$unit")"

  if [[ "$state_present" == false ]]; then
    if [[ "$active" == true || "$enabled" == true ]]; then
      emit_decision "mismatch" \
        "dnsmasq is already active or enabled outside this platform's management (no platform state present); reconciling a foreign/pre-existing dnsmasq deployment is out of scope for this script"
      return 0
    fi
    if [[ "$dstate" != "none" ]]; then
      emit_decision "mismatch" \
        "a systemd drop-in already exists for dnsmasq (state: $dstate) without corresponding platform state; manual recovery required before install"
      return 0
    fi
    if [[ -e "$HOMELAB_CONF_FILE" ]]; then
      emit_decision "mismatch" \
        "$HOMELAB_CONF_FILE already exists without corresponding platform state; manual recovery required before install"
      return 0
    fi
    emit_decision "install" ""
    return 0
  fi

  # state_present == true: this is a re-run, not a fresh baseline.
  if [[ "$dstate" == "foreign" ]]; then
    emit_decision "mismatch" \
      "a foreign systemd drop-in already manages dnsmasq; reconciling it is out of scope for this script"
    return 0
  fi
  if [[ "$dstate" == "none" || ! -e "$HOMELAB_CONF_FILE" ]]; then
    emit_decision "mismatch" \
      "platform state exists at $STATE_DIR but a managed live file is missing; run dnsmasq/rollback.sh or recover manually before reinstalling"
    return 0
  fi

  local fragment_path
  fragment_path="$(unit_fragment_path "$unit")"
  if [[ -z "$fragment_path" ]]; then
    emit_decision "mismatch" "could not determine the dnsmasq unit's FragmentPath"
    return 0
  fi
  local base_execstart proposed_conf proposed_dropin
  base_execstart="$(extract_base_execstart "$fragment_path")"
  proposed_conf="$(render_homelab_conf "$domain" "$ip")"
  proposed_dropin="$(render_dropin "$base_execstart")"

  local conf_ok=false dropin_ok=false
  content_matches_file "$proposed_conf" "$HOMELAB_CONF_FILE" && conf_ok=true
  content_matches_file "$proposed_dropin" "$SYSTEMD_DROPIN_FILE" && dropin_ok=true

  if [[ "$conf_ok" == true && "$dropin_ok" == true && "$active" == true && "$enabled" == true ]]; then
    emit_decision "noop" ""
    return 0
  fi

  emit_decision "mismatch" \
    "installed configuration differs from what this run would render, or the service is not both active and enabled (homelab.conf matches: $conf_ok, drop-in matches: $dropin_ok, active: $active, enabled: $enabled) — this includes HOST_LAN_IP/HOMELAB_DOMAIN having changed, or the package's own ExecStart having changed: run dnsmasq/rollback.sh then reinstall, no in-place update is supported"
}

# --- the transactional install -----------------------------------------------

# Tracked at file scope (not `local`) so install_failure_cleanup, invoked via
# the EXIT trap from within do_install's dynamic scope, can see exactly which
# mutations this invocation actually performed.
STATE_DIR_CREATED=false
STATE_PERSISTED=false
DNSMASQ_D_CREATED=false
HOMELAB_CONF_WRITTEN=false
DROPIN_DIR_CREATED=false
DROPIN_WRITTEN=false
DAEMON_RELOADED=false
LIFECYCLE_TOUCHED=false
ENABLE_SUCCEEDED=false
START_SUCCEEDED=false

# Reverses exactly what this invocation did, using the same cmp-before-delete
# ownership gate as dnsmasq/rollback.sh. Never removes a file that no longer
# matches what this run just wrote. If the fresh-install baseline can't be
# proven restored after a lifecycle mutation, stops immediately and leaves
# every file and all state in place for manual recovery.
install_failure_cleanup() {
  local rc="$?"
  trap - EXIT INT TERM

  if [[ "$LIFECYCLE_TOUCHED" == true ]]; then
    systemctl disable --now "$DNSMASQ_UNIT_NAME" >/dev/null 2>&1 \
      || printf 'WARNING: systemctl disable --now %s failed during cleanup\n' "$DNSMASQ_UNIT_NAME" >&2
    if ! verify_baseline_disabled_inactive "$DNSMASQ_UNIT_NAME"; then
      printf 'ERROR: could not verify %s returned to inactive/disabled during cleanup.\n' "$DNSMASQ_UNIT_NAME" >&2
      printf 'MANUAL RECOVERY REQUIRED: nothing further was removed. Check `systemctl status %s`.\n' "$DNSMASQ_UNIT_NAME" >&2
      exit "$rc"
    fi
  fi

  local homelab_conf_removed=true dropin_removed=true

  if [[ "$HOMELAB_CONF_WRITTEN" == true ]]; then
    if [[ -f "$HOMELAB_CONF_FILE" ]] && files_match "$HOMELAB_CONF_FILE" "$STATE_HOMELAB_CONF_EXPECTED"; then
      rm -f -- "$HOMELAB_CONF_FILE" \
        || { homelab_conf_removed=false; printf 'WARNING: failed to remove %s\n' "$HOMELAB_CONF_FILE" >&2; }
    else
      homelab_conf_removed=false
      printf 'WARNING: %s no longer matches what this run wrote; leaving it in place for manual recovery.\n' "$HOMELAB_CONF_FILE" >&2
    fi
  fi

  if [[ "$DROPIN_WRITTEN" == true ]]; then
    if [[ -f "$SYSTEMD_DROPIN_FILE" ]] && files_match "$SYSTEMD_DROPIN_FILE" "$STATE_DROPIN_EXPECTED"; then
      rm -f -- "$SYSTEMD_DROPIN_FILE" \
        || { dropin_removed=false; printf 'WARNING: failed to remove %s\n' "$SYSTEMD_DROPIN_FILE" >&2; }
    else
      dropin_removed=false
      printf 'WARNING: %s no longer matches what this run wrote; leaving it in place for manual recovery.\n' "$SYSTEMD_DROPIN_FILE" >&2
    fi
  fi

  if [[ "$HOMELAB_CONF_WRITTEN" == true || "$DROPIN_WRITTEN" == true ]]; then
    systemctl daemon-reload 2>/dev/null \
      || printf 'WARNING: systemctl daemon-reload failed during cleanup\n' >&2
  fi

  if [[ "$DROPIN_DIR_CREATED" == true ]]; then
    rmdir -- "$SYSTEMD_DROPIN_DIR" 2>/dev/null \
      || printf 'NOTE: %s was created by this run but is not empty (or removal failed); left in place.\n' "$SYSTEMD_DROPIN_DIR" >&2
  fi
  if [[ "$DNSMASQ_D_CREATED" == true ]]; then
    rmdir -- "$HOMELAB_CONF_DIR" 2>/dev/null \
      || printf 'NOTE: %s was created by this run but is not empty (or removal failed); left in place.\n' "$HOMELAB_CONF_DIR" >&2
  fi

  if [[ "$STATE_PERSISTED" == true ]]; then
    if [[ "$homelab_conf_removed" == true && "$dropin_removed" == true ]]; then
      rm -f -- "$STATE_HOMELAB_CONF_EXPECTED" "$STATE_DROPIN_EXPECTED" "$STATE_CREATED_DIRS_LIST"
      if [[ "$STATE_DIR_CREATED" == true ]]; then
        rmdir -- "$STATE_DIR" 2>/dev/null || true
      fi
    else
      printf 'NOTE: platform state at %s preserved — not all managed files could be safely removed. Use dnsmasq/rollback.sh or recover manually.\n' "$STATE_DIR" >&2
    fi
  fi

  printf 'Install transaction failed and was rolled back where safely provable. See errors above.\n' >&2
  exit "$rc"
}

do_install() {
  local domain="$1" ip="$2"
  local unit="$DNSMASQ_UNIT_NAME"

  local fragment_path
  fragment_path="$(unit_fragment_path "$unit")"
  [[ -n "$fragment_path" ]] || die "could not determine the dnsmasq unit's FragmentPath"
  local base_execstart
  base_execstart="$(extract_base_execstart "$fragment_path")"

  local proposed_conf proposed_dropin
  proposed_conf="$(render_homelab_conf "$domain" "$ip")"
  proposed_dropin="$(render_dropin "$base_execstart")"

  # --- pre-flight: staged syntax validation, nothing under /etc touched ----
  local staged_conf test_output
  staged_conf="$(mktemp)"
  printf '%s' "$proposed_conf" > "$staged_conf"
  if ! test_output="$(dnsmasq --test --conf-file="$MAIN_DNSMASQ_CONF" --conf-file="$staged_conf" 2>&1)"; then
    rm -f -- "$staged_conf"
    die "dnsmasq --test failed against the staged homelab.conf: $test_output"
  fi
  rm -f -- "$staged_conf"

  # --- entering the mutating phase ------------------------------------------
  trap install_failure_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  # PLATFORM_STATE_ROOT is shared platform state, not dnsmasq-owned: created
  # explicitly if absent, accepted as-is if it already exists as a directory,
  # and never removed by this script (including on failure-cleanup) or by
  # dnsmasq/rollback.sh. Two separate explicit mkdir calls, never a single
  # `-p`, so a missing root is never created implicitly as a side effect of
  # creating the dnsmasq-private directory beneath it.
  if [[ -e "$PLATFORM_STATE_ROOT" && ! -d "$PLATFORM_STATE_ROOT" ]]; then
    die "$PLATFORM_STATE_ROOT exists but is not a directory"
  fi
  if [[ ! -d "$PLATFORM_STATE_ROOT" ]]; then
    mkdir -m 0755 -- "$PLATFORM_STATE_ROOT" || die "failed to create $PLATFORM_STATE_ROOT"
  fi
  if [[ ! -d "$STATE_DIR" ]]; then
    mkdir -m 0700 -- "$STATE_DIR" || die "failed to create $STATE_DIR"
    STATE_DIR_CREATED=true
  fi
  atomic_write "$STATE_HOMELAB_CONF_EXPECTED" "$proposed_conf" 0600
  atomic_write "$STATE_DROPIN_EXPECTED" "$proposed_dropin" 0600
  STATE_PERSISTED=true

  if [[ ! -d "$HOMELAB_CONF_DIR" ]]; then
    mkdir -m 0755 -- "$HOMELAB_CONF_DIR" || die "failed to create $HOMELAB_CONF_DIR"
    DNSMASQ_D_CREATED=true
    append_created_dir "$STATE_CREATED_DIRS_LIST" "$HOMELAB_CONF_DIR"
  fi
  atomic_write "$HOMELAB_CONF_FILE" "$proposed_conf" 0644
  HOMELAB_CONF_WRITTEN=true

  if [[ ! -d "$SYSTEMD_DROPIN_DIR" ]]; then
    mkdir -m 0755 -- "$SYSTEMD_DROPIN_DIR" || die "failed to create $SYSTEMD_DROPIN_DIR"
    DROPIN_DIR_CREATED=true
    append_created_dir "$STATE_CREATED_DIRS_LIST" "$SYSTEMD_DROPIN_DIR"
  fi
  atomic_write "$SYSTEMD_DROPIN_FILE" "$proposed_dropin" 0644
  DROPIN_WRITTEN=true

  systemctl daemon-reload || die "systemctl daemon-reload failed"
  DAEMON_RELOADED=true

  # Set before the first lifecycle-mutating command: `systemctl enable` can
  # itself partially mutate state (e.g. partially create the .wants symlink)
  # before returning failure, so cleanup must treat any attempt as needing a
  # restore-to-baseline, not just a confirmed success.
  LIFECYCLE_TOUCHED=true
  systemctl enable "$unit" || die "systemctl enable $unit failed"
  ENABLE_SUCCEEDED=true

  systemctl start "$unit" || die "systemctl start $unit failed"
  START_SUCCEEDED=true

  # --- post-install verification, still inside the transaction -------------
  unit_is_active "$unit" || die "post-install check failed: $unit is not active"
  unit_is_enabled "$unit" || die "post-install check failed: $unit is not enabled"

  local marker answer
  marker="verify-$$-${RANDOM}.${domain}"
  answer="$(dig +short "@${ip}" "$marker" 2>/dev/null || true)"
  [[ "$answer" == "$ip" ]] \
    || die "post-install check failed: dig @${ip} ${marker} returned '${answer:-<empty>}', expected ${ip}"

  trap - EXIT
  printf 'dnsmasq installed and verified: %s active and enabled, *.%s -> %s\n' "$unit" "$domain" "$ip"
  printf 'Run dnsmasq/smoke-test.sh for the fuller repeatable verification.\n'
}

# --- entrypoint ---------------------------------------------------------------

main() {
  validate_env
  validate_ipv4 "$HOST_LAN_IP"
  validate_domain "$HOMELAB_DOMAIN"
  check_prerequisites

  local action="" reason=""
  local key value
  while IFS='=' read -r key value; do
    case "$key" in
      ACTION) action="$value" ;;
      REASON) reason="$value" ;;
    esac
  done < <(inspect_installation "$HOMELAB_DOMAIN" "$HOST_LAN_IP")

  case "$action" in
    noop)
      printf 'dnsmasq already matches HOST_LAN_IP=%s HOMELAB_DOMAIN=%s and is active/enabled. No changes made.\n' \
        "$HOST_LAN_IP" "$HOMELAB_DOMAIN"
      exit 0
      ;;
    mismatch)
      printf 'ERROR: %s\n' "$reason" >&2
      printf 'This script only installs from a clean baseline, or no-ops against an exactly\n' >&2
      printf 'matching existing install. See docs/dnsmasq-runbook.md for recovery.\n' >&2
      exit 1
      ;;
    install)
      do_install "$HOMELAB_DOMAIN" "$HOST_LAN_IP"
      ;;
    *)
      die "internal error: unrecognized action '$action'"
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
  main "$@"
fi

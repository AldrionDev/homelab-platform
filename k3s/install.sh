#!/usr/bin/env bash
#
# Install single-node k3s on this host as a systemd service.
#
# Requires K3S_VERSION (exact release tag) and HOST_LAN_IP (dotted-quad IPv4).
# Neither has a default: an unset or malformed value is a hard error.
#
# Idempotency is enforced by this script, not delegated to the upstream
# installer. Re-running inspects the existing installation and either no-ops or
# refuses; it never regenerates systemd config or restarts a running service.
#
# See docs/k3s-runbook.md for operations, verification, and the separate
# destructive uninstall/reset procedure.

set -euo pipefail

# Fixed production constants — never overridable via environment variable.
# Test seams are explicit function arguments defaulting to these.
readonly KUBECONFIG_PATH="/etc/rancher/k3s/k3s.yaml"
readonly K3S_BINARY_PATH="/usr/local/bin/k3s"
readonly K3S_UNIT_NAME="k3s"
readonly K3S_CONFIG_FILE="/etc/rancher/k3s/config.yaml"
readonly K3S_CONFIG_DIR="/etc/rancher/k3s/config.yaml.d"

die() { echo "ERROR: $*" >&2; exit 1; }

# --- input validation --------------------------------------------------------

# Exact stable k3s release tag: vX.Y.Z+k3sN. Rejects "latest", "stable", and
# partial versions — installing an unpinned version is never acceptable here.
is_well_formed_version() {
  [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+\+k3s[0-9]+$ ]]
}

validate_env() {
  local missing=()
  [[ -n "${K3S_VERSION:-}" ]] || missing+=("K3S_VERSION")
  [[ -n "${HOST_LAN_IP:-}" ]] || missing+=("HOST_LAN_IP")
  ((${#missing[@]} == 0)) || die "Missing required variable(s): ${missing[*]}"
}

validate_version() {
  is_well_formed_version "$1" \
    || die "K3S_VERSION '$1' is not an exact k3s release tag (expected format vX.Y.Z+k3sN)"
}

validate_ipv4() {
  local ip="$1"
  [[ -n "$ip" ]] || die "HOST_LAN_IP is empty"
  # Anchor the whole string BEFORE splitting. `read` stops at the first
  # newline, so without this a value like $'192.168.1.50\n<payload>' would
  # validate on its first line while the untruncated value still reaches the
  # installer — and the generated systemd unit would gain an injected
  # directive. Bash's =~ does not set REG_NEWLINE, so $ anchors at end of
  # string, and [0-9] never matches a newline.
  [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] \
    || die "HOST_LAN_IP '$ip' is not a dotted-quad IPv4 address"
  local IFS=.
  local -a octets
  read -ra octets <<< "$ip"
  ((${#octets[@]} == 4)) || die "HOST_LAN_IP '$ip' is not a dotted-quad IPv4 address"
  local octet
  for octet in "${octets[@]}"; do
    # Exactly "0", or a non-zero leading digit plus up to two more digits. This
    # rejects "", "00", "01", "-5" and any non-digit; the 10# arithmetic below
    # is defense-in-depth for the range.
    [[ "$octet" =~ ^(0|[1-9][0-9]{0,2})$ ]] \
      || die "HOST_LAN_IP '$ip' contains a malformed or leading-zero octet: '$octet'"
    ((10#$octet <= 255)) || die "HOST_LAN_IP '$ip' contains an out-of-range octet: $octet"
  done
}

# --- preflight (read-only) ---------------------------------------------------

is_root()     { [[ "$(id -u)" == "0" ]]; }
has_command() { command -v "$1" >/dev/null 2>&1; }

# parse_exec_start_argv needs PCRE. Without it the inspection would still fail
# closed, but with a misleading "could not be parsed" message instead of a
# clear missing-dependency error.
has_pcre_grep() { echo x | grep -qP x 2>/dev/null; }

systemd_running() {
  local marker="${1:-/run/systemd/system}"
  [[ -d "$marker" ]]
}

check_prerequisites() {
  is_root               || die "This script must be run as root (sudo)."
  has_command curl      || die "curl is required but was not found in PATH."
  has_command systemctl || die "systemctl is required but was not found in PATH (systemd host required)."
  has_pcre_grep         || die "grep with PCRE support (grep -P) is required but is not available."
  systemd_running       || die "systemd does not appear to be running as PID 1."
}

# --- existing-installation inspection (all read-only) ------------------------

get_installed_version() {
  local k3s_binary="${1:-$K3S_BINARY_PATH}"
  [[ -x "$k3s_binary" ]] || { echo ""; return 0; }
  local out
  if ! out=$("$k3s_binary" --version 2>/dev/null) || [[ -z "$out" ]]; then
    echo ""
    return 1
  fi
  awk 'NR==1{print $3}' <<< "$out"
}

unit_loaded() {
  [[ "$(systemctl show "${1:-$K3S_UNIT_NAME}" --property=LoadState --value 2>/dev/null)" == "loaded" ]]
}

unit_active() {
  [[ "$(systemctl show "${1:-$K3S_UNIT_NAME}" --property=ActiveState --value 2>/dev/null)" == "active" ]]
}

unit_enabled() {
  systemctl is-enabled "${1:-$K3S_UNIT_NAME}" >/dev/null 2>&1
}

# Effective, drop-in/override-aware configuration. Deliberately not a grep of
# /etc/systemd/system/k3s.service, which would miss overrides.
get_effective_exec_start() {
  systemctl show "${1:-$K3S_UNIT_NAME}" --property=ExecStart --value 2>/dev/null
}

# Emits the single argv[] token string, or fails if the effective ExecStart does
# not contain exactly one argv[] block — fails closed on any ambiguity.
parse_exec_start_argv() {
  local raw="$1" matches count=0
  matches=$(grep -oP 'argv\[\]=\K[^;]+' <<< "$raw" 2>/dev/null || true)
  [[ -z "$matches" ]] || count=$(grep -c . <<< "$matches")
  ((count == 1)) || return 1
  sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' <<< "$matches"
}

# Diagnostics only — used to describe an existing install in the summary, never
# to make the decision. Matches whole tokens, so --tls-sans or --tls-san2 are
# not picked up. Handles both the separated and the = form.
get_tls_san_values() {
  local argv_str="$1"
  local -a tokens
  read -ra tokens <<< "$argv_str"
  local i token
  for ((i = 0; i < ${#tokens[@]}; i++)); do
    token="${tokens[$i]}"
    if [[ "$token" == "--tls-san" ]]; then
      if ((i + 1 < ${#tokens[@]})); then
        echo "${tokens[$((i + 1))]}"
        # Not ((i++)): that returns status 1 when i is 0, which aborts the
        # function under set -e.
        i=$((i + 1))
      else
        echo ""
      fi
    elif [[ "$token" == --tls-san=* ]]; then
      echo "${token#--tls-san=}"
    fi
  done
}

# The decision function. The effective argv must be exactly the command this
# script itself would produce: same executable, the server subcommand, exactly
# one --tls-san, exactly the requested IP, and nothing else. Agent mode, an
# extra flag, a missing token, a foreign executable, or a different
# representation (including --tls-san=IP, which install_k3s never produces) all
# fail this check.
effective_exec_start_is_managed() {
  local argv_str="$1" requested_ip="$2"
  local k3s_binary="${3:-$K3S_BINARY_PATH}"
  local -a tokens expected
  read -ra tokens <<< "$argv_str"
  expected=("$k3s_binary" "server" "--tls-san" "$requested_ip")
  ((${#tokens[@]} == ${#expected[@]})) || return 1
  local i
  for ((i = 0; i < ${#expected[@]}; i++)); do
    [[ "${tokens[$i]}" == "${expected[$i]}" ]] || return 1
  done
}

# k3s also reads /etc/rancher/k3s/config.yaml and config.yaml.d/*, which can
# change cluster behaviour in ways the version and ExecStart cannot reveal.
# This script does not model them, so it refuses to act when any are present.
has_external_k3s_config() {
  local config_file="${1:-$K3S_CONFIG_FILE}"
  local config_dir="${2:-$K3S_CONFIG_DIR}"
  [[ -e "$config_file" ]] && return 0
  if [[ -d "$config_dir" ]]; then
    local entry
    for entry in "$config_dir"/* "$config_dir"/.[!.]*; do
      [[ -e "$entry" ]] && return 0
    done
  fi
  return 1
}

# Single source of truth for the decision. Emits a fixed key=value block on
# stdout. Performs no mutation in any branch, including "install".
inspect_installation() {
  local requested_version="$1" requested_ip="$2"
  local k3s_binary="${3:-$K3S_BINARY_PATH}"
  local unit="${4:-$K3S_UNIT_NAME}"
  local kubeconfig_path="${5:-$KUBECONFIG_PATH}"
  local config_file="${6:-$K3S_CONFIG_FILE}"
  local config_dir="${7:-$K3S_CONFIG_DIR}"

  local binary_present=false unit_present=false kubeconfig_present=false
  [[ -x "$k3s_binary" ]] && binary_present=true
  unit_loaded "$unit" && unit_present=true
  [[ -f "$kubeconfig_path" ]] && kubeconfig_present=true

  local action="" installed_version="" effective_sans="" reason=""
  local unit_active_flag=false unit_enabled_flag=false

  if has_external_k3s_config "$config_file" "$config_dir"; then
    # Gated before every other branch, including a fresh install: with an
    # external config present, neither the summary nor a no-op could honestly
    # describe the resulting runtime configuration.
    action="mismatch"
    reason="external k3s configuration present ($config_file or $config_dir); custom k3s config is out of scope for this script"

  elif [[ "$binary_present" == false && "$unit_present" == false ]]; then
    # A stale kubeconfig is backed up by main() before installing; it does not
    # gate this branch.
    action="install"

  elif [[ "$binary_present" != "$unit_present" ]]; then
    action="mismatch"
    reason="k3s binary and systemd unit are in an inconsistent state (one present, one missing)"

  else
    installed_version=$(get_installed_version "$k3s_binary") || installed_version=""
    if [[ -z "$installed_version" ]] || ! is_well_formed_version "$installed_version"; then
      action="mismatch"
      reason="installed k3s version is missing or not a well-formed release tag"
    else
      local argv=""
      if ! argv=$(parse_exec_start_argv "$(get_effective_exec_start "$unit")"); then
        action="mismatch"
        reason="effective ExecStart could not be parsed unambiguously (check systemd drop-ins/overrides)"
      else
        local -a sans
        mapfile -t sans < <(get_tls_san_values "$argv")
        effective_sans=$(IFS=,; echo "${sans[*]}")

        unit_active "$unit" && unit_active_flag=true
        unit_enabled "$unit" && unit_enabled_flag=true

        if [[ "$installed_version" != "$requested_version" ]]; then
          action="mismatch"
          reason="installed version differs from requested ($installed_version vs $requested_version)"
        elif ! effective_exec_start_is_managed "$argv" "$requested_ip" "$k3s_binary"; then
          action="mismatch"
          reason="effective ExecStart is not exactly '$k3s_binary server --tls-san $requested_ip'"
        elif [[ "$unit_active_flag" == false || "$unit_enabled_flag" == false ]]; then
          action="mismatch"
          reason="installation matches but the k3s service is not both active and enabled"
        elif [[ "$kubeconfig_present" == false ]]; then
          action="mismatch"
          reason="installation matches but the kubeconfig file is missing"
        else
          action="noop"
        fi
      fi
    fi
  fi

  cat <<EOF
ACTION=$action
INSTALLED_VERSION=$installed_version
EFFECTIVE_SANS=$effective_sans
UNIT_ACTIVE=$unit_active_flag
UNIT_ENABLED=$unit_enabled_flag
KUBECONFIG_PRESENT=$kubeconfig_present
REASON=$reason
EOF
}

# --- reporting ---------------------------------------------------------------

print_summary() {
  local action="$1" installed_version="$2" effective_sans="$3" reason="$4"
  cat <<EOF
k3s install summary
-------------------
Requested version:        $K3S_VERSION
Requested HOST_LAN_IP:    $HOST_LAN_IP
Resulting --tls-san:      $HOST_LAN_IP
Kubeconfig path (fixed):  $KUBECONFIG_PATH
Intended action:          $action
EOF

  if [[ "$action" == "mismatch" ]]; then
    cat <<EOF

Existing installation state:
  installed version:      ${installed_version:-<none/unparseable>}
  effective --tls-san:    ${effective_sans:-<none/unparseable>}
  reason:                 $reason

This script only performs a fresh install, or a no-op against an exactly
equivalent and healthy existing install. A no-op asserts equivalence of the
state this script manages (version, complete effective ExecStart, service
active and enabled, kubeconfig present, no external k3s config) — not of
arbitrary k3s configuration. Upgrading, reconfiguring, or repairing a
differing install is a separate manual procedure: see docs/k3s-runbook.md.
EOF
  fi
}

print_next_steps() {
  cat <<'EOF'

Next steps:
  sudo systemctl status k3s
  sudo journalctl -u k3s -f
  sudo k3s kubectl get nodes
EOF
}

# --- kubeconfig backup (mutates the filesystem) ------------------------------

# Copies an existing kubeconfig to a timestamped sibling. Never modifies or
# removes the original, and never overwrites an existing backup: a collision
# gets a numeric suffix. The path is a required argument, never env-overridable.
backup_kubeconfig() {
  local kubeconfig_path="$1"
  [[ -f "$kubeconfig_path" ]] || return 0
  local timestamp backup suffix=1
  timestamp=$(date -u +%Y%m%dT%H%M%SZ)
  backup="${kubeconfig_path}.backup-${timestamp}"
  while [[ -e "$backup" ]]; do
    backup="${kubeconfig_path}.backup-${timestamp}-${suffix}"
    suffix=$((suffix + 1))
  done
  cp -p "$kubeconfig_path" "$backup"
  echo "Backed up existing kubeconfig to $backup"
}

# --- the host-mutating installer call ----------------------------------------

install_k3s() {
  # Clear the installer's whole configuration namespace before invoking it.
  # Upstream, INSTALL_K3S_COMMIT and INSTALL_K3S_PR are checked *before*
  # INSTALL_K3S_VERSION, INSTALL_K3S_EXEC prepends its own arguments to argv,
  # and INSTALL_K3S_BIN_DIR moves the install target. Any of those inherited
  # from the caller would install something other than what the summary just
  # promised. Clearing the namespace also covers variables upstream adds after
  # this script was written.
  local -a present=() cleared=()
  mapfile -t present < <(compgen -v | grep -E '^(INSTALL_K3S_|K3S_)' || true)
  local var
  for var in "${present[@]}"; do
    cleared+=(-u "$var")
  done

  curl -sfL https://get.k3s.io \
    | env "${cleared[@]}" INSTALL_K3S_VERSION="$K3S_VERSION" \
        sh -s - server --tls-san "$HOST_LAN_IP"
}

# --- entrypoint --------------------------------------------------------------

main() {
  validate_env
  validate_version "$K3S_VERSION"
  validate_ipv4 "$HOST_LAN_IP"
  check_prerequisites

  local action="" installed_version="" effective_sans="" reason=""
  local key value
  while IFS='=' read -r key value; do
    case "$key" in
      ACTION)            action="$value" ;;
      INSTALLED_VERSION) installed_version="$value" ;;
      EFFECTIVE_SANS)    effective_sans="$value" ;;
      REASON)            reason="$value" ;;
    esac
  done < <(inspect_installation "$K3S_VERSION" "$HOST_LAN_IP")

  print_summary "$action" "$installed_version" "$effective_sans" "$reason"

  case "$action" in
    noop)
      echo "No changes made."
      exit 0
      ;;
    mismatch)
      exit 1
      ;;
    install)
      backup_kubeconfig "$KUBECONFIG_PATH"
      install_k3s
      print_next_steps
      ;;
    *)
      die "internal error: unrecognized action '$action'"
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
  main "$@"
fi

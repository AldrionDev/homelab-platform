#!/usr/bin/env bash
#
# End-to-end smoke test for the local Docker registry.
#
# Builds a tiny throwaway image, pushes it to the registry on the host's LAN
# interface, pulls it back by digest, deletes that digest, and confirms it is
# gone. This covers verification steps 2-4 of the registry issue.
#
# Requires HOST_LAN_IP (dotted-quad IPv4, not loopback). There is no default,
# and the port is fixed at 5000: this verifies the registry defined in
# registry/docker-compose.yml, reached the way the rest of the LAN reaches it.
#
# The registry must already be running. This script never starts, stops, or
# reconfigures it, and never touches the Docker daemon configuration.
#
# Ownership model: the registry is unauthenticated, so any LAN client can move
# a tag at any moment. The only artifact this run owns is the digest reported
# by its own `docker push`. That digest — never a later tag lookup — is what
# gets pulled, deleted, and cleaned up. A tag that stops resolving to it means
# someone else interfered, and the script fails instead of touching their
# manifest. Cleanup is best-effort and signal-aware; see
# docs/registry-runbook.md for what it cannot guarantee.
#
# Assumes a GNU/Linux coreutils environment (date, tr, rm, grep, cut).
# Does not require jq.

set -euo pipefail

readonly REPO="homelab-smoke-test"
readonly REGISTRY_PORT="5000"
readonly DIGEST_PATTERN='^sha256:[0-9a-f]{64}$'

# Both Docker and OCI manifest types, single and index/list forms. The registry
# returns Docker-Content-Digest only for a media type it is willing to serve.
readonly MANIFEST_ACCEPT="application/vnd.docker.distribution.manifest.v2+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.oci.image.index.v1+json"

# --- state (drives cleanup; see cleanup()) -----------------------------------

REGISTRY_HOST=""
TAG=""
IMAGE_REF=""
DIGEST_REF=""
HEADERS_FILE=""
PUSH_OUTPUT=""
BUILD_CONTEXT=""
LOCAL_TAG_PRESENT=false
LOCAL_DIGEST_PRESENT=false
PUSH_ATTEMPTED=false
PUSH_SUCCEEDED=false
PUSH_DIGEST=""
REMOTE_DELETE_ATTEMPTED=false
REMOTE_DELETED=false

die()  { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARNING: $*" >&2; }

# --- input validation --------------------------------------------------------

has_command() { command -v "$1" >/dev/null 2>&1; }

validate_dependencies() {
  local missing=() cmd
  for cmd in docker curl od mktemp; do
    has_command "$cmd" || missing+=("$cmd")
  done
  ((${#missing[@]} == 0)) || die "missing required command(s): ${missing[*]}"
}

# Anchors the whole string BEFORE splitting. `read` stops at the first newline,
# so without this a value like $'192.168.0.10\n<payload>' would validate on its
# first line while the untruncated value still reached docker and curl. Bash's
# =~ does not set REG_NEWLINE, so $ anchors at end of string.
validate_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] \
    || die "HOST_LAN_IP '$ip' is not a dotted-quad IPv4 address"
  local IFS=.
  local -a octets
  read -ra octets <<< "$ip"
  ((${#octets[@]} == 4)) || die "HOST_LAN_IP '$ip' is not a dotted-quad IPv4 address"
  local octet
  for octet in "${octets[@]}"; do
    # Exactly "0", or a non-zero leading digit plus up to two more digits.
    # Rejects "", "00", "01", "-5" and any non-digit; the 10# arithmetic below
    # is defense-in-depth for the range.
    [[ "$octet" =~ ^(0|[1-9][0-9]{0,2})$ ]] \
      || die "HOST_LAN_IP '$ip' contains a malformed or leading-zero octet: '$octet'"
    ((10#$octet <= 255)) || die "HOST_LAN_IP '$ip' contains an out-of-range octet: $octet"
  done
  # The compose service binds to the LAN address only, and the point of this
  # test is to verify that interface. A loopback address would either fail to
  # connect or, worse, silently exercise some other registry.
  [[ "${octets[0]}" != "127" ]] \
    || die "HOST_LAN_IP '$ip' is a loopback address; the registry binds to the host's LAN address, so this test needs that address"
}

validate_env() {
  [[ -n "${HOST_LAN_IP:-}" ]] \
    || die "HOST_LAN_IP is required (no default). Usage: HOST_LAN_IP=<lan-ip> bash registry/smoke-test.sh"
  validate_ipv4 "$HOST_LAN_IP"
}

# --- registry HTTP helpers ---------------------------------------------------

manifest_url() {
  printf 'http://%s/v2/%s/manifests/%s\n' "$REGISTRY_HOST" "$REPO" "$1"
}

# Bounded retry: the registry needs a moment after `up -d` or `docker restart`,
# but a persistent failure must still surface, with curl's own last error.
check_registry_reachable() {
  curl \
    --fail \
    --silent \
    --show-error \
    --retry 10 \
    --retry-delay 1 \
    --retry-connrefused \
    --connect-timeout 5 \
    --output /dev/null \
    "http://${REGISTRY_HOST}/v2/" \
    || die "registry at http://${REGISTRY_HOST}/v2/ is not reachable. Start it first — see the 'Starting and stopping' section of docs/registry-runbook.md"
}

# Emits the HTTP status; response headers land in $HEADERS_FILE.
head_manifest() {
  local reference="$1" status
  status="$(
    curl \
      --silent \
      --show-error \
      --connect-timeout 5 \
      --head \
      --header "Accept: ${MANIFEST_ACCEPT}" \
      --output "$HEADERS_FILE" \
      --write-out '%{http_code}' \
      "$(manifest_url "$reference")"
  )" || die "HEAD request for ${REPO}:${reference} failed"
  printf '%s\n' "$status"
}

# Reads Docker-Content-Digest from the last HEAD response. Header names are
# case-insensitive on the wire, so the match is too. Used only to compare
# against $PUSH_DIGEST — never to decide what this run may delete.
read_digest_from_headers() {
  local digest
  digest="$(
    grep -i '^docker-content-digest:' "$HEADERS_FILE" |
      tail -n 1 |
      cut -d: -f2- |
      tr -d ' \r' \
      || true
  )"
  [[ -n "$digest" ]] \
    || die "registry response contained no Docker-Content-Digest header"
  [[ "$digest" =~ $DIGEST_PATTERN ]] \
    || die "registry returned a malformed digest: '$digest'"
  printf '%s\n' "$digest"
}

# The single manifest-delete implementation, shared by the normal path and by
# cleanup. Returns 0 on a confirmed 202, 1 on any other HTTP status, 2 on a
# curl transport failure. Sets the two remote-delete state flags.
delete_manifest_digest() {
  local digest="$1" status
  REMOTE_DELETE_ATTEMPTED=true

  if ! status="$(
    curl \
      --silent \
      --show-error \
      --connect-timeout 5 \
      --request DELETE \
      --output /dev/null \
      --write-out '%{http_code}' \
      "$(manifest_url "$digest")"
  )"; then
    return 2
  fi

  # Only 202 means the registry accepted the deletion. A 404 means it was not
  # there to delete, 405 that the delete API is disabled, 401 that something
  # requires credentials — none of those are a successful delete.
  if [[ "$status" != "202" ]]; then
    printf 'Unexpected DELETE response for %s: HTTP %s\n' "$digest" "$status" >&2
    return 1
  fi

  REMOTE_DELETED=true
  return 0
}

# --- unique artifact ---------------------------------------------------------

# UTC timestamp + PID + 64 bits of randomness. Strongly collision-resistant,
# but not a uniqueness guarantee — the HEAD check below is what decides.
generate_tag() {
  local random_suffix
  random_suffix="$(
    od -An -N8 -tx1 /dev/urandom |
      tr -d ' \n'
  )"
  printf '%s-%s-%s\n' "$(date -u +%Y%m%dT%H%M%SZ)" "$$" "$random_suffix"
}

# Sets TAG and IMAGE_REF to a reference that does not yet exist in the
# registry. Every derived value is regenerated together on a collision.
prepare_unique_tag() {
  local attempt status
  for attempt in 1 2; do
    TAG="$(generate_tag)"
    IMAGE_REF="${REGISTRY_HOST}/${REPO}:${TAG}"
    # Printed before anything is built or pushed, so an interrupted run leaves
    # the operator with the exact reference to inspect or remove by hand.
    printf 'Smoke-test image: %s\n' "$IMAGE_REF"
    status="$(head_manifest "$TAG")"
    case "$status" in
      404) return 0 ;;
      200) warn "tag ${TAG} already exists in the registry; regenerating (attempt ${attempt})" ;;
      *)   die "unexpected HTTP status $status while checking whether ${REPO}:${TAG} is free" ;;
    esac
  done
  die "tag collision persisted after regeneration; aborting without touching the registry"
}

# A unique tag alone does not imply a unique manifest digest: an identical
# build context reproduces an identical manifest, and deletion is by digest.
# Binding the marker's content to this run's reference keeps the DELETE from
# ever reaching an earlier smoke-test artifact.
build_image() {
  BUILD_CONTEXT="$(mktemp -d)"
  printf '%s\n' "$IMAGE_REF" >"$BUILD_CONTEXT/marker"
  cat >"$BUILD_CONTEXT/Dockerfile" <<'EOF'
FROM scratch
COPY marker /marker
EOF
  docker build --quiet --tag "$IMAGE_REF" "$BUILD_CONTEXT" >/dev/null \
    || die "docker build failed for $IMAGE_REF"
  LOCAL_TAG_PRESENT=true
}

# Scans the captured push output for the digest Docker reported. Sets
# PUSH_DIGEST directly rather than echoing it, so a failure here dies in the
# main shell instead of in a command substitution.
parse_push_digest() {
  local line candidate found=""
  while IFS= read -r line; do
    if [[ "$line" =~ digest:[[:space:]]+(sha256:[0-9a-f]{64}) ]]; then
      candidate="${BASH_REMATCH[1]}"
      [[ -z "$found" || "$found" == "$candidate" ]] \
        || die "docker push reported conflicting digests ($found and $candidate); refusing to guess which artifact this run owns"
      found="$candidate"
    fi
  done <"$PUSH_OUTPUT"

  [[ -n "$found" ]] \
    || die "docker push succeeded but reported no digest; refusing to fall back to a tag lookup, which another client could have changed"
  [[ "$found" =~ $DIGEST_PATTERN ]] \
    || die "docker push reported a malformed digest: '$found'"

  PUSH_DIGEST="$found"
}

# Captures the push output in full so both the digest and any error survive,
# and preserves Docker's own exit status.
push_image() {
  local push_rc=0
  PUSH_ATTEMPTED=true

  if docker push "$IMAGE_REF" >"$PUSH_OUTPUT" 2>&1; then
    cat "$PUSH_OUTPUT"
  else
    push_rc=$?
    cat "$PUSH_OUTPUT" >&2
    cat >&2 <<EOF

Push failed. If Docker reports an HTTPS/HTTP mismatch, configure this
registry under insecure-registries as documented in
docs/registry-runbook.md.
EOF
    exit "$push_rc"
  fi

  PUSH_SUCCEEDED=true
  parse_push_digest
}

# --- cleanup -----------------------------------------------------------------

# Best-effort, and the only teardown path — the successful run uses it too.
# Takes the exit code as an argument rather than reading $?, which by then may
# reflect a command inside the trap itself.
cleanup() {
  local rc="$1" delete_rc=0
  # Disarmed first: a signal arriving during cleanup, or the exit below, must
  # not re-enter this function.
  trap - EXIT INT TERM

  if [[ "$PUSH_SUCCEEDED" == true && "$REMOTE_DELETED" == false ]]; then
    if [[ "$REMOTE_DELETE_ATTEMPTED" == true ]]; then
      warn "an earlier manifest DELETE was attempted but never confirmed successful; retrying it once"
    fi
    if [[ "$PUSH_DIGEST" =~ $DIGEST_PATTERN ]]; then
      delete_manifest_digest "$PUSH_DIGEST" || delete_rc=$?
      case "$delete_rc" in
        0) echo "Cleanup removed this run's manifest $PUSH_DIGEST from the registry." ;;
        2) warn "cleanup could not reach the registry to delete $PUSH_DIGEST; remove it manually" ;;
        *) warn "cleanup did not get a 202 when deleting $PUSH_DIGEST; it may still be present" ;;
      esac
    else
      # Deliberately no tag lookup here: the tag is mutable, and deleting
      # whatever it points at now could destroy another client's manifest.
      warn "the push completed but no digest was captured for it; inspect ${REPO}:${TAG} manually"
    fi
  elif [[ "$PUSH_ATTEMPTED" == true && "$PUSH_SUCCEEDED" == false ]]; then
    warn "the push did not complete; partial upload data may remain in the registry (handling it is out of scope for this test)"
  fi

  if [[ "$LOCAL_DIGEST_PRESENT" == true ]]; then
    if ! docker image rm -f "$DIGEST_REF" >/dev/null 2>&1; then
      warn "failed to remove local image $DIGEST_REF"
    fi
  fi

  if [[ "$LOCAL_TAG_PRESENT" == true ]]; then
    if ! docker image rm -f "$IMAGE_REF" >/dev/null 2>&1; then
      warn "failed to remove local image $IMAGE_REF"
    fi
  fi

  if [[ -n "$BUILD_CONTEXT" && -d "$BUILD_CONTEXT" ]]; then
    if ! rm -rf -- "$BUILD_CONTEXT"; then
      warn "failed to remove build context $BUILD_CONTEXT"
    fi
  fi

  local scratch
  for scratch in "$HEADERS_FILE" "$PUSH_OUTPUT"; do
    [[ -n "$scratch" ]] || continue
    if ! rm -f -- "$scratch"; then
      warn "failed to remove $scratch"
    fi
  done

  exit "$rc"
}

# --- entrypoint --------------------------------------------------------------

main() {
  validate_env
  validate_dependencies

  REGISTRY_HOST="${HOST_LAN_IP}:${REGISTRY_PORT}"
  HEADERS_FILE="$(mktemp)"
  PUSH_OUTPUT="$(mktemp)"

  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'cleanup "$?"' EXIT

  echo "Registry:         http://${REGISTRY_HOST}"
  check_registry_reachable
  echo "Registry is reachable (GET /v2/)."

  prepare_unique_tag

  build_image
  echo "Built $IMAGE_REF"

  push_image
  echo "Push digest:      $PUSH_DIGEST"

  DIGEST_REF="${REGISTRY_HOST}/${REPO}@${PUSH_DIGEST}"

  # The tag must still resolve to what this run pushed. If it does not, another
  # client replaced it; that manifest is theirs, so stop rather than pull or
  # delete it.
  local status tag_digest
  status="$(head_manifest "$TAG")"
  [[ "$status" == "200" ]] \
    || die "expected HTTP 200 for the pushed tag ${REPO}:${TAG}, got $status"
  tag_digest="$(read_digest_from_headers)"
  [[ "$tag_digest" == "$PUSH_DIGEST" ]] \
    || die "tag ${REPO}:${TAG} now resolves to $tag_digest, not to this run's push digest $PUSH_DIGEST; another client replaced it, so refusing to pull or delete a foreign manifest"

  docker image rm "$IMAGE_REF" >/dev/null \
    || die "failed to remove the local image before the pull test"
  LOCAL_TAG_PRESENT=false

  # Pull by digest, not by tag: this proves the exact manifest this run pushed
  # came back intact.
  docker pull --quiet "$DIGEST_REF" >/dev/null \
    || die "docker pull failed for $DIGEST_REF"
  LOCAL_DIGEST_PRESENT=true
  echo "Pulled $DIGEST_REF back"

  local delete_rc=0
  delete_manifest_digest "$PUSH_DIGEST" || delete_rc=$?
  case "$delete_rc" in
    0) echo "Deleted manifest $PUSH_DIGEST" ;;
    2) die "the DELETE request for $PUSH_DIGEST could not reach the registry" ;;
    *) die "the registry did not confirm deletion of $PUSH_DIGEST with HTTP 202" ;;
  esac

  status="$(head_manifest "$PUSH_DIGEST")"
  [[ "$status" == "404" ]] \
    || die "expected HTTP 404 for the deleted digest $PUSH_DIGEST, got $status"

  # The tag is inspected, not enforced. If someone else's manifest now sits
  # under it, that is their artifact and this run leaves it alone.
  status="$(head_manifest "$TAG")"
  case "$status" in
    404)
      ;;
    200)
      tag_digest="$(read_digest_from_headers)"
      die "the deleted digest is gone, but tag ${REPO}:${TAG} now resolves to $tag_digest — another client wrote to this tag. Leaving their manifest untouched; remove it yourself if it is unwanted"
      ;;
    *)
      die "unexpected HTTP status $status when re-checking tag ${REPO}:${TAG} after deletion"
      ;;
  esac

  echo
  echo "Smoke test passed: push, pull by digest, and delete all worked against http://${REGISTRY_HOST}"
}

if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
  main "$@"
fi

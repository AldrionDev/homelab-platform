#!/usr/bin/env bash
#
# Proves that k3s/containerd can pull from the local plain-HTTP registry.
#
# Builds a throwaway image with a per-run unique marker, pushes it to the
# registry on the host's LAN interface, runs it as a Pod by tag, waits for
# Running, and confirms the Pod is running exactly the image this run pushed.
#
# Requires HOST_LAN_IP (dotted-quad IPv4, not loopback) and KUBECONFIG. Neither
# has a default. KUBECONFIG must be explicit: an ambient kubectl context is
# rejected, because running this against some other cluster would produce a
# meaningless pass. Every kubectl call passes --kubeconfig explicitly rather
# than relying on exported state.
#
# This script never uses sudo, never touches systemd, never writes
# /etc/rancher/k3s/registries.yaml, and never restarts k3s. Configuring the
# trust and restarting the service are documented host transactions in
# docs/k3s-runbook.md, behind their own approval. That separation is what keeps
# this script repeatable and low-privilege.
#
# The restart-persistence check is orchestrated by the runbook, not here: run
# this script, restart k3s, verify persistence, then run it again. Each run
# builds a fresh marker, so the second run's manifest has never been seen by
# containerd and a cached image cannot produce a false pass.
#
# Assumes a GNU/Linux coreutils environment (date, tr, rm, grep, cut).
# Does not require jq: every cluster query uses kubectl -o jsonpath.

set -euo pipefail

readonly REPO="homelab-k3s-pull-test"
readonly NAMESPACE="default"
readonly REGISTRY_PORT="5000"
readonly DIGEST_PATTERN='^sha256:[0-9a-f]{64}$'

# Pinned to a multi-arch OCI image index digest, not a floating tag and not a
# single-platform manifest. The base image only has to provide a long-lived
# process so the Pod can reach Running; `FROM scratch` cannot, which is why
# this test does not reuse the registry smoke test's image shape.
readonly BASE_IMAGE="busybox@sha256:9db7b59979c38555a39def84a31fb98b5296952f9e3afd4f6f11f05b07adfab0"

# Both Docker and OCI manifest types, single and index/list forms. The registry
# returns Docker-Content-Digest only for a media type it is willing to serve.
readonly MANIFEST_ACCEPT="application/vnd.docker.distribution.manifest.v2+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.oci.image.index.v1+json"

readonly POD_RUNNING_TIMEOUT_SECONDS=120
readonly POD_POLL_INTERVAL_SECONDS=2

# --- state (drives cleanup; see cleanup()) -----------------------------------

REGISTRY_HOST=""
RUN_ID=""
TAG=""
IMAGE_REF=""
POD_NAME=""
HEADERS_FILE=""
PUSH_OUTPUT=""
BUILD_CONTEXT=""
LOCAL_TAG_PRESENT=false
PUSH_ATTEMPTED=false
PUSH_SUCCEEDED=false
PUSH_DIGEST=""
OWN_CONFIG_DIGEST=""
POD_CREATED=false
REMOTE_DELETE_ATTEMPTED=false
REMOTE_DELETED=false

die()  { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARNING: $*" >&2; }

# --- input validation --------------------------------------------------------

has_command() { command -v "$1" >/dev/null 2>&1; }

validate_dependencies() {
  local missing=() cmd
  # `ip` is needed to enumerate this host's own IPv4 addresses, which is how
  # the cluster-identity check proves the kubeconfig points at a k3s node
  # running here rather than at some other reachable single-node k3s cluster.
  for cmd in docker kubectl curl od mktemp ip; do
    has_command "$cmd" || missing+=("$cmd")
  done
  ((${#missing[@]} == 0)) || die "missing required command(s): ${missing[*]}"
}

# Predicates over untrusted addresses read from the cluster and from `ip`.
# Kept separate from validate_ipv4 on purpose: that one validates operator
# input and dies with HOST_LAN_IP-specific, actionable messages, while these
# filter and compare lists and must never die on a single bad entry.
is_valid_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
  local IFS=.
  local -a octets
  read -ra octets <<< "$ip"
  ((${#octets[@]} == 4)) || return 1
  local octet
  for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^(0|[1-9][0-9]{0,2})$ ]] || return 1
    ((10#$octet <= 255)) || return 1
  done
}

is_loopback_ipv4() { [[ "$1" == 127.* ]]; }

# Anchors the whole string BEFORE splitting. `read` stops at the first newline,
# so without this a value like $'192.168.0.10\n<payload>' would validate on its
# first line while the untruncated value still reached docker, curl and kubectl.
# Bash's =~ does not set REG_NEWLINE, so $ anchors at end of string.
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
  # The registry binds to the LAN address only, and the whole point is to prove
  # the cluster can reach that interface. A loopback address would either fail
  # to connect or, worse, silently exercise some other registry.
  [[ "${octets[0]}" != "127" ]] \
    || die "HOST_LAN_IP '$ip' is a loopback address; the registry binds to the host's LAN address, so this test needs that address"
}

validate_env() {
  [[ -n "${HOST_LAN_IP:-}" ]] \
    || die "HOST_LAN_IP is required (no default). Usage: HOST_LAN_IP=<lan-ip> KUBECONFIG=<path> bash k3s/registry-pull-test.sh"
  validate_ipv4 "$HOST_LAN_IP"
}

# An explicit kubeconfig is mandatory. Falling back to ~/.kube/config or to
# whatever context happens to be current would let this test pass against an
# unrelated cluster — minikube, kind, a remote cluster — and report it as proof
# that k3s trusts the local registry.
validate_kubeconfig() {
  [[ -n "${KUBECONFIG:-}" ]] \
    || die "KUBECONFIG is required and must be explicit (no default, no ambient kubectl context). See docs/k3s-runbook.md"
  [[ -e "$KUBECONFIG" ]] \
    || die "KUBECONFIG '$KUBECONFIG' does not exist"
  [[ -f "$KUBECONFIG" ]] \
    || die "KUBECONFIG '$KUBECONFIG' is not a regular file"
  [[ -r "$KUBECONFIG" ]] \
    || die "KUBECONFIG '$KUBECONFIG' is not readable by the current user. The k3s kubeconfig is root-owned 0600 — see docs/k3s-runbook.md for the documented user-owned copy"
}

# --- cluster access ----------------------------------------------------------

# The single kubectl entry point. Always passes --kubeconfig, so no call can
# silently fall back to ambient state.
run_kubectl() {
  kubectl --kubeconfig "$KUBECONFIG" "$@"
}

# One tab-separated record per node: name, kubelet version, container runtime,
# Ready condition status. Emitted as a string so the assertion below stays a
# pure function that the test suite can drive without a cluster.
fetch_node_records() {
  run_kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.nodeInfo.kubeletVersion}{"\t"}{.status.nodeInfo.containerRuntimeVersion}{"\t"}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\n"}{end}'
}

# Fails closed on anything that is not exactly the expected single-node k3s
# cluster, with a distinct message per failed check — "wrong cluster" alone
# would not tell the operator what to fix.
#
# Deliberately does NOT require the node's InternalIP to equal HOST_LAN_IP.
# k3s picks its node IP from the default route, which can legitimately differ
# from the address the registry binds to on a multi-homed host. Cluster
# identity and registry endpoint identity are two separate things.
assert_single_k3s_node() {
  local records="$1"
  [[ -n "${records//[[:space:]]/}" ]] \
    || die "cluster identity check failed: kubectl returned no node records (is the API reachable?)"

  local -a lines=()
  local line
  while IFS= read -r line; do
    [[ -n "${line//[[:space:]]/}" ]] && lines+=("$line")
  done <<< "$records"

  ((${#lines[@]} == 1)) \
    || die "cluster identity check failed: expected exactly 1 node, found ${#lines[@]}. This repository targets a single-node k3s cluster"

  local name kubelet runtime ready
  IFS=$'\t' read -r name kubelet runtime ready <<< "${lines[0]}"

  [[ -n "$name" ]] \
    || die "cluster identity check failed: the node record has no name; kubectl output was not in the expected form"
  [[ "$ready" == "True" ]] \
    || die "cluster identity check failed: node '$name' is not Ready (Ready condition: '${ready:-<missing>}')"
  [[ "$kubelet" == *"+k3s"* ]] \
    || die "cluster identity check failed: node '$name' reports kubeletVersion '${kubelet:-<missing>}', which is not a k3s build. Refusing to run against a non-k3s cluster"
  [[ "$runtime" == containerd://* ]] \
    || die "cluster identity check failed: node '$name' reports containerRuntimeVersion '${runtime:-<missing>}', expected a containerd:// runtime"

  printf 'Cluster:          single-node k3s, node %s (%s, %s)\n' "$name" "$kubelet" "$runtime"
}

fetch_node_internal_ips() {
  run_kubectl get nodes \
    -o jsonpath='{range .items[*]}{range .status.addresses[?(@.type=="InternalIP")]}{.address}{"\n"}{end}{end}'
}

# The kernel's own routing decision for this host, as raw `ip route get` output.
#
# This is a ROUTE LOOKUP, not a connectivity probe: `ip route get` consults the
# routing table and returns immediately. No packet is sent, nothing is dialled,
# and the destination only has to be an off-link address that forces a
# default-route lookup — it is never contacted.
fetch_host_route_source() {
  ip -4 route get 1.1.1.1 2>/dev/null
}

# Pure. Emits every `src <value>` field found in `ip route get` output, one per
# line, without judging them — the caller decides what "none", "one" and "more
# than one" mean, so each gets its own diagnostic.
extract_route_source_ipv4() {
  local route_output="$1" line
  local -a tokens
  local i
  while IFS= read -r line; do
    [[ -n "${line//[[:space:]]/}" ]] || continue
    read -ra tokens <<< "$line"
    for ((i = 0; i + 1 < ${#tokens[@]}; i++)); do
      if [[ "${tokens[$i]}" == "src" ]]; then
        printf '%s\n' "${tokens[$((i + 1))]}"
      fi
    done
  done <<< "$route_output"
}

# The check the previous four conditions cannot make: they are satisfied by ANY
# reachable single-node k3s cluster, so a kubeconfig for someone else's lab
# would sail through them and the registry pull would then prove nothing about
# this host.
#
# Identity is pinned to the source address the kernel selects for a
# default-route lookup — the address this machine actually routes from. That is
# a single, host-specific value. Membership in the host's full address list
# would not do: docker0, cni0, flannel and bridge addresses such as 172.17.0.1
# or 10.42.0.1 exist identically on countless hosts, so a foreign k3s node
# advertising one of them would have passed.
#
# Interface names are never consulted. Blacklisting docker0/cni0/veth*/br-*
# would just be another environment-specific heuristic; asking the kernel which
# address it routes from is the question actually worth answering.
#
# Deliberately NOT compared against HOST_LAN_IP. That value is the registry's
# bind/reference address — a separate concern. Node network identity is derived
# independently from host routing, so a multihomed host whose registry address
# differs from its routing address still verifies correctly.
#
# Scope note: this models the bare-metal single-node k3s installation this
# repository manages, where k3s takes its node IP from the default route. An
# installation deliberately started with a different --node-ip would fail this
# check — correctly so: that is a signal to revisit this model and the runbook,
# not something to wave through.
#
# Pure: both inputs are strings, so the suite can drive every branch without a
# cluster, a network stack, root, or any route mutation.
assert_node_is_this_hosts_node() {
  local node_records="$1" route_output="$2"
  local -a node_ips=() src_ips=()
  local line

  while IFS= read -r line; do
    line="${line//[[:space:]]/}"
    [[ -n "$line" ]] && node_ips+=("$line")
  done <<< "$node_records"

  while IFS= read -r line; do
    line="${line//[[:space:]]/}"
    [[ -n "$line" ]] && src_ips+=("$line")
  done < <(extract_route_source_ipv4 "$route_output")

  # --- the expected local node address, from this host's routing table -------

  ((${#src_ips[@]} != 0)) \
    || die "cluster identity check failed: the IPv4 default-route lookup returned no 'src' field, so this host's expected node address cannot be determined"
  ((${#src_ips[@]} == 1)) \
    || die "cluster identity check failed: the IPv4 default-route lookup returned ${#src_ips[@]} ambiguous 'src' values (${src_ips[*]}); refusing to guess this host's address"

  local expected_ip="${src_ips[0]}"
  is_valid_ipv4 "$expected_ip" \
    || die "cluster identity check failed: the route source address '$expected_ip' is not a dotted-quad IPv4 address"
  if is_loopback_ipv4 "$expected_ip"; then
    die "cluster identity check failed: the route source address is loopback ($expected_ip); this host has no usable routed address to identify its node by"
  fi

  # --- the node's own claim --------------------------------------------------

  ((${#node_ips[@]} != 0)) \
    || die "cluster identity check failed: the node reports no InternalIP, so it cannot be confirmed as this host's node"
  ((${#node_ips[@]} == 1)) \
    || die "cluster identity check failed: the node reports ${#node_ips[@]} InternalIP addresses (${node_ips[*]}); refusing to guess which one identifies it"

  local node_ip="${node_ips[0]}"
  is_valid_ipv4 "$node_ip" \
    || die "cluster identity check failed: the node's InternalIP '$node_ip' is not a dotted-quad IPv4 address"

  # --- they must be the same machine -----------------------------------------

  [[ "$node_ip" == "$expected_ip" ]] \
    || die "cluster identity check failed: this is a valid single-node k3s/containerd cluster, but it is NOT this host's managed local k3s node. Node InternalIP: $node_ip. Expected (this host's default-route source address): $expected_ip"

  printf 'Node InternalIP:  %s (matches this host default-route source address)\n' "$node_ip"
}

check_cluster_identity() {
  local records
  records="$(fetch_node_records)" \
    || die "could not reach the Kubernetes API with KUBECONFIG '$KUBECONFIG'"
  assert_single_k3s_node "$records"

  local node_ips route_output
  node_ips="$(fetch_node_internal_ips)" \
    || die "could not read the node's InternalIP with KUBECONFIG '$KUBECONFIG'"
  route_output="$(fetch_host_route_source)" \
    || die "the IPv4 default-route lookup failed on this host, so the expected local node address cannot be determined"
  assert_node_is_this_hosts_node "$node_ips" "$route_output"
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

# --- unique run identity -----------------------------------------------------

# UTC timestamp + PID + 64 bits of randomness, lowercase throughout so the same
# value is legal as both a Docker tag and an RFC 1123 Kubernetes object name.
# Strongly collision-resistant, but not a uniqueness guarantee — the HEAD check
# below is what decides.
generate_run_id() {
  local random_suffix
  random_suffix="$(
    od -An -N8 -tx1 /dev/urandom |
      tr -d ' \n'
  )"
  printf '%s-%s-%s\n' "$(date -u +%Y%m%dt%H%M%Sz)" "$$" "$random_suffix"
}

# Sets RUN_ID, TAG, IMAGE_REF and POD_NAME to a reference that does not yet
# exist in the registry. Every derived value is regenerated together on a
# collision, so the Pod name can never drift away from the image it runs.
prepare_unique_run() {
  local attempt status
  for attempt in 1 2; do
    RUN_ID="$(generate_run_id)"
    TAG="$RUN_ID"
    IMAGE_REF="${REGISTRY_HOST}/${REPO}:${TAG}"
    POD_NAME="${REPO}-${RUN_ID}"
    # Printed before anything is built or pushed, so an interrupted run leaves
    # the operator with the exact reference and Pod name to inspect or remove.
    printf 'Test image:       %s\n' "$IMAGE_REF"
    printf 'Test Pod:         %s (namespace %s)\n' "$POD_NAME" "$NAMESPACE"
    status="$(head_manifest "$TAG")"
    case "$status" in
      404) return 0 ;;
      200) warn "tag ${TAG} already exists in the registry; regenerating (attempt ${attempt})" ;;
      *)   die "unexpected HTTP status $status while checking whether ${REPO}:${TAG} is free" ;;
    esac
  done
  die "tag collision persisted after regeneration; aborting without touching the registry"
}

# --- image ------------------------------------------------------------------

# The marker binds this run's own image reference into a layer, so both the
# manifest digest and the image config digest are unique to this run. containerd
# keeps its own content store, separate from Docker's, so a unique manifest can
# never be satisfied from a previously cached image — that is what makes a pass
# here real evidence of a registry pull rather than a cache hit.
build_image() {
  BUILD_CONTEXT="$(mktemp -d)"
  printf '%s\n' "$IMAGE_REF" >"$BUILD_CONTEXT/marker"
  cat >"$BUILD_CONTEXT/Dockerfile" <<EOF
FROM ${BASE_IMAGE}
COPY marker /smoke-marker
CMD ["sleep", "3600"]
EOF
  if ! docker build --quiet --tag "$IMAGE_REF" "$BUILD_CONTEXT" >/dev/null; then
    cat >&2 <<EOF

The build failed before anything was pushed. This is a build prerequisite
failure — pulling the pinned base image from Docker Hub, or the Docker daemon
itself. It is NOT evidence about the local registry or about k3s registry
trust; neither has been exercised yet.
EOF
    die "docker build failed for $IMAGE_REF"
  fi
  LOCAL_TAG_PRESENT=true
}

# The image config digest, captured while the local image still exists. This is
# the second identity the Pod's imageID is allowed to resolve to: the CRI
# reports either the manifest digest or the config digest depending on the
# runtime version, and neither choice should fail a correct run.
capture_config_digest() {
  local id
  id="$(docker image inspect --format '{{.Id}}' "$IMAGE_REF")" \
    || die "could not read the image config digest for $IMAGE_REF"
  [[ "$id" =~ $DIGEST_PATTERN ]] \
    || die "docker reported a malformed image config digest: '$id'"
  OWN_CONFIG_DIGEST="$id"
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

The push failed. This is the host Docker daemon talking to the registry, not
k3s: if Docker reports an HTTPS/HTTP mismatch, configure this registry under
insecure-registries as documented in docs/registry-runbook.md. k3s registry
trust has not been exercised yet at this point.
EOF
    exit "$push_rc"
  fi

  PUSH_SUCCEEDED=true
  parse_push_digest
}

# --- Pod --------------------------------------------------------------------

# The Pod pulls by TAG, not by digest: resolving the tag over plain HTTP is
# part of what this test has to prove. imagePullPolicy=Always keeps containerd
# from short-circuiting to anything it might already hold.
create_pod() {
  run_kubectl -n "$NAMESPACE" run "$POD_NAME" \
    --image="$IMAGE_REF" \
    --image-pull-policy=Always \
    --restart=Never \
    >/dev/null \
    || die "failed to create Pod $POD_NAME in namespace $NAMESPACE"
  POD_CREATED=true
}

pod_phase() {
  run_kubectl -n "$NAMESPACE" get pod "$POD_NAME" \
    -o jsonpath='{.status.phase}' 2>/dev/null || true
}

dump_pod_diagnostics() {
  echo "--- kubectl describe pod ${POD_NAME} ---" >&2
  run_kubectl -n "$NAMESPACE" describe pod "$POD_NAME" >&2 2>&1 || true
  echo "--- events for pod ${POD_NAME} ---" >&2
  run_kubectl -n "$NAMESPACE" get events \
    --field-selector "involvedObject.name=${POD_NAME}" >&2 2>&1 || true
}

# Only Running counts. Succeeded/Completed would mean the container exited —
# the acceptance criterion is a Pod that reaches Running, and an image whose
# process ended immediately would not demonstrate that.
wait_for_pod_running() {
  local waited=0 phase=""
  while ((waited < POD_RUNNING_TIMEOUT_SECONDS)); do
    phase="$(pod_phase)"
    case "$phase" in
      Running)
        printf 'Pod %s reached Running after %ss\n' "$POD_NAME" "$waited"
        return 0
        ;;
      Succeeded|Failed)
        dump_pod_diagnostics
        die "Pod $POD_NAME reached terminal phase '$phase' instead of Running"
        ;;
    esac
    sleep "$POD_POLL_INTERVAL_SECONDS"
    waited=$((waited + POD_POLL_INTERVAL_SECONDS))
  done
  dump_pod_diagnostics
  die "Pod $POD_NAME did not reach Running within ${POD_RUNNING_TIMEOUT_SECONDS}s (last phase: '${phase:-<unknown>}'). ImagePullBackOff or ErrImagePull above means the pull from http://${REGISTRY_HOST} failed — check the k3s registry trust per docs/k3s-runbook.md"
}

# Extracts the sha256 digest from a CRI imageID. Known representations:
#   sha256:<hex>
#   containerd://sha256:<hex>
#   docker-pullable://<repo>@sha256:<hex>
#   <repo>@sha256:<hex>
# The remainder is matched anchored, so a truncated, over-long, uppercase or
# otherwise malformed value is rejected rather than partially matched.
extract_image_digest() {
  local raw="$1" candidate
  [[ -n "$raw" ]] || return 1
  candidate="$raw"
  candidate="${candidate#containerd://}"
  candidate="${candidate#docker-pullable://}"
  candidate="${candidate#docker://}"
  candidate="${candidate##*@}"
  [[ "$candidate" =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "$candidate"
}

# Fail-closed against the two digests this run owns. Accepting either keeps the
# check strict without failing a correct run purely because of which digest the
# runtime chose to report.
verify_pod_image() {
  local raw resolved
  raw="$(
    run_kubectl -n "$NAMESPACE" get pod "$POD_NAME" \
      -o jsonpath='{.status.containerStatuses[0].imageID}'
  )" || die "could not read the resolved imageID for Pod $POD_NAME"

  if ! resolved="$(extract_image_digest "$raw")"; then
    dump_pod_diagnostics
    die "the Pod's imageID ('${raw:-<empty>}') did not yield exactly one well-formed sha256 digest; refusing to assume the running image is the one this run pushed"
  fi

  if [[ "$resolved" != "$PUSH_DIGEST" && "$resolved" != "$OWN_CONFIG_DIGEST" ]]; then
    cat >&2 <<EOF
Pod image reference:      $IMAGE_REF
Resolved imageID (raw):   $raw
Resolved digest:          $resolved
Expected manifest digest: $PUSH_DIGEST
Expected config digest:   $OWN_CONFIG_DIGEST
EOF
    die "the running Pod does not resolve to either digest this run owns"
  fi

  # Emitted on success too, not only on failure: this is the evidence that the
  # Pod ran exactly the image this run pushed, and a passing run is precisely
  # when that evidence needs to be preserved. Note that the two accepted
  # digests coincide when Docker uses the containerd image store, where
  # `docker image inspect .Id` reports the manifest digest rather than the
  # classic image config digest.
  local matched
  if [[ "$resolved" == "$PUSH_DIGEST" && "$resolved" == "$OWN_CONFIG_DIGEST" ]]; then
    matched="both (PUSH_DIGEST and OWN_CONFIG_DIGEST are identical on this host)"
  elif [[ "$resolved" == "$PUSH_DIGEST" ]]; then
    matched="PUSH_DIGEST (push manifest digest)"
  else
    matched="OWN_CONFIG_DIGEST (image config digest)"
  fi

  cat <<EOF
Pod image reference:      $IMAGE_REF
Resolved imageID (raw):   $raw
Resolved digest:          $resolved
Expected manifest digest: $PUSH_DIGEST
Expected config digest:   $OWN_CONFIG_DIGEST
Matched:                  $matched
EOF
}

# --- cleanup -----------------------------------------------------------------

# Best-effort, and the only teardown path — the successful run uses it too.
# Takes the exit code as an argument rather than reading $?, which by then may
# reflect a command inside the trap itself.
#
# Every target is named by this run's own generated identity. Nothing is deleted
# by prefix, label selector or any other guess: an orphan left by an earlier
# interrupted run is somebody else's problem to inspect, not this run's to
# silently remove.
cleanup() {
  local rc="$1" delete_rc=0
  # Disarmed first: a signal arriving during cleanup, or the exit below, must
  # not re-enter this function.
  trap - EXIT INT TERM

  if [[ "$POD_CREATED" == true && -n "$POD_NAME" ]]; then
    if ! run_kubectl -n "$NAMESPACE" delete pod "$POD_NAME" \
      --ignore-not-found --wait=false >/dev/null 2>&1; then
      warn "failed to delete Pod $POD_NAME in namespace $NAMESPACE; remove it manually"
    fi
  fi

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

  if [[ "$LOCAL_TAG_PRESENT" == true ]]; then
    # Only this run's tag. The pinned base image is not ours to remove.
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
  validate_kubeconfig
  validate_dependencies

  REGISTRY_HOST="${HOST_LAN_IP}:${REGISTRY_PORT}"
  HEADERS_FILE="$(mktemp)"
  PUSH_OUTPUT="$(mktemp)"

  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'cleanup "$?"' EXIT

  echo "Registry:         http://${REGISTRY_HOST}"
  echo "Kubeconfig:       ${KUBECONFIG}"
  check_cluster_identity

  check_registry_reachable
  echo "Registry is reachable (GET /v2/)."

  prepare_unique_run

  build_image
  echo "Built $IMAGE_REF"

  capture_config_digest
  echo "Config digest:    $OWN_CONFIG_DIGEST"

  push_image
  echo "Push digest:      $PUSH_DIGEST"

  # The tag must still resolve to what this run pushed. If it does not, another
  # client replaced it; running that manifest would prove nothing about this
  # run, so stop rather than start a Pod from it.
  local status tag_digest
  status="$(head_manifest "$TAG")"
  [[ "$status" == "200" ]] \
    || die "expected HTTP 200 for the pushed tag ${REPO}:${TAG}, got $status"
  tag_digest="$(read_digest_from_headers)"
  [[ "$tag_digest" == "$PUSH_DIGEST" ]] \
    || die "tag ${REPO}:${TAG} now resolves to $tag_digest, not to this run's push digest $PUSH_DIGEST; another client replaced it, so refusing to run a foreign manifest"
  echo "Tag resolves to this run's push digest."

  create_pod
  wait_for_pod_running
  verify_pod_image

  echo
  echo "Registry pull test passed: k3s pulled ${REPO}:${TAG} from http://${REGISTRY_HOST} over plain HTTP and ran it as a Pod."
}

if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
  main "$@"
fi

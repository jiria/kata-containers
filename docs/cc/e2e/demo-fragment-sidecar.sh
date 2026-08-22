#!/usr/bin/env bash
#
# Copyright (c) 2026 Microsoft Corporation
#
# SPDX-License-Identifier: Apache-2.0
#
# shellcheck source-path=SCRIPTDIR
# Hand-runnable demo of the sidecar shape: a measured base policy that pins
# one workload, and a separately signed fragment that admits a second container.
# What `pins` a container depends on the image path: dm-verity layer root hashes
# under host-pull, image reference plus argv/env/mounts/user under guest-pull.
#
#   1. a container starts under a policy that contains it
#   2. a sidecar the policy has never seen is refused, and the pod keeps running
#   3. the sidecar's container entry is signed into a fragment and published
#   4. the same sidecar starts, because the delivered fragment now authorizes it
#
# Steps 2 and 4 differ in exactly one thing: whether the pod declares and receives
# the fragment. Nothing about the sidecar itself changes.
#
# This is the interactive twin of stage 07 cases 07l/07m. It is not part of
# run-all.sh, writes no .done marker, and can be re-run at will.
#
# Prerequisites (all produced by the normal stages):
#   * a cluster with the branch guest stack   — 03-deploy-cluster.sh, 04-build-guest-stack.sh
#   * an issuer key and issuer allow-list      — 06-policy-fragment-e2e.sh
#   * a reachable registry (loopback is fine)  — 06-policy-fragment-e2e.sh
#
# Env:
#   DEMO_PAUSE=1   wait for Enter between steps (default: run straight through)
#   E2E_NS         namespace (default coco-e2e)
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Same as demo.sh: remember the current heading so pause() can redraw it after
# clearing the screen, without duplicating lib.sh's heading format.
eval "_lib_step() $(declare -f step | tail -n +2)"
_CUR_STEP=""

# Not `clear`: that also emits ESC[3J here, which discards the scrollback.
_demo_clear() {
  [[ "${DEMO_PAUSE:-0}" = "1" && "${DEMO_CLEAR:-1}" = "1" ]] || return 1
  [[ -n "${TERM:-}" && "${TERM}" != "dumb" ]] || return 1
  printf '\033[H\033[2J'
}

# `|| true` matters: this script runs under `set -e`, and _demo_clear returns
# non-zero whenever clearing is off (piped runs, DEMO_PAUSE=0). Without it the
# whole script exits silently at the first heading.
step() { _CUR_STEP="$*"; _demo_clear || true; _lib_step "$@"; _vo "$*"; }

# A heading that deliberately does not clear: use it when the section reads the
# evidence still on screen. The closing summary refers to the pod that step 4
# just brought up, so wiping it first would leave the summary unsupported.
heading() { _CUR_STEP="$*"; _lib_step "$@"; _vo "$*"; }

# Narration, mirroring demo.sh: prose can be suppressed for a live voice-over
# (DEMO_NARRATE=0) and captured to a plain-text script (DEMO_SCRIPT), while the
# commands and their output are always shown.
_HOST_LABEL="$(whoami)@$(hostname -s 2>/dev/null || echo host)"

_vo() {
  [[ -n "${DEMO_SCRIPT:-}" ]] || return 0
  printf '%s\n' "$*" >> "${DEMO_SCRIPT}"
  return 0
}

# Beat numbers, so a reviewer can point at one. This runs as its own process, so
# it carries its own prefix rather than trying to continue demo.sh's count.
_BEAT_N=0
_BEAT_PREFIX="${DEMO_BEAT_PREFIX:-F}"
_beat() {
  _BEAT_TAG=''
  [[ "${DEMO_STEPS:-1}" = "1" ]] || return 0
  _BEAT_N=$((_BEAT_N + 1))
  _BEAT_TAG=$(printf '[%s%02d]' "${_BEAT_PREFIX}" "${_BEAT_N}")
}

# A real prompt with real output under it, unindented: the evidence should look
# like what an engineer would see running the command themselves.
_prompt() {
  printf '\n%s%s%s:%s%s%s$ %s\n' \
    "${_c_grn}" "${_HOST_LABEL}" "${_c_off}" \
    "${_c_blu}" "${PWD/#${HOME}/\~}" "${_c_off}" "$*"
}

say() {
  local line para="" tag first=1
  _beat; tag="${_BEAT_TAG}"
  while IFS= read -r line; do
    if [[ "${DEMO_NARRATE:-1}" = "1" ]]; then
      if [[ -n "${tag}" && "${first}" = "1" && -z "${line//[[:space:]]/}" ]]; then
        printf '\n  %s\n' "${tag}"
      else
        [[ -n "${tag}" && "${first}" = "1" ]] && printf '\n  %s\n' "${tag}"
        printf '%s\n' "${line}"
      fi
      first=0
    fi
    if [[ -z "${line//[[:space:]]/}" ]]; then
      [[ -n "${para}" ]] && _vo "${para}"
      para=""
    else
      line="${line#"${line%%[![:space:]]*}"}"
      para="${para:+${para} }${line%"${line##*[![:space:]]}"}"
    fi
  done
  [[ -n "${para}" ]] && _vo "${para}"
  return 0
}

# Same contract as demo.sh's: state the claim, then show the command that
# substantiates it. Duplicated rather than shared because each demo script has
# to stand on its own when run directly.
show() {
  local desc="$1"; shift
  local tag; _beat; tag="${_BEAT_TAG}"
  _vo "${desc}"
  if [[ "${DEMO_NARRATE:-1}" = "1" ]]; then
    printf '\n  %s->%s %s%s\n' "${_c_blu}" "${_c_off}" "${tag:+${tag} }" "${desc}"
  elif [[ -n "${tag}" ]]; then
    printf '\n  %s\n' "${tag}"
  fi
  _prompt "$*"
  bash -c "$*" 2>&1
  return 0
}

NS="${E2E_NS:-coco-e2e}"
POD=demo-frag-sidecar
# Quiet, for the same reason as demo.sh: staging chatter would land on screen
# with no command above it. Failures still print the whole log.
_SETUP_LOG=$(mktemp)
ensure_genpolicy_defaults >> "${_SETUP_LOG}" 2>&1 \
  || { cat "${_SETUP_LOG}"; die "could not stage genpolicy inputs"; }
SETTINGS="${GP_SETTINGS}"
RULES_SRC="${GP_RULES}"
FRAG="${HOME}/.coco-e2e/fragments"
ENTRY="${FRAG}/fragment-entry.json"
E2E_REPO_DIR="${E2E_REPO_DIR:-${HOME}/kata-containers}"

# The sidecar is identified in the generated policy by its command, not its name:
# the container entry records the process argv, and two containers of the same
# image are otherwise indistinguishable.
MARK="sleep-601-demo-sidecar"

pause() {
  [[ "${DEMO_PAUSE:-0}" = "1" ]] || return 0
  printf '\n    press Enter to continue '
  read -r _
}

# Same split as demo.sh: `pause` holds while the audience reads something that
# belongs with what is already on screen; `scene` ends one line of argument and
# clears so the next step starts on a screen of its own.
scene() {
  pause
  { _demo_clear && [[ -n "${_CUR_STEP}" ]] && _lib_step "${_CUR_STEP}"; } || true
}

need kubectl; need jq; need python3
[[ -s "${ENTRY}" ]] || die "no fragment fixture at ${ENTRY} — run 06-policy-fragment-e2e.sh first"
[[ -s "${FRAG}/key.txt" ]] || die "no issuer key at ${FRAG}/key.txt — run 06-policy-fragment-e2e.sh first"
[[ -r "${RULES_SRC}" ]] || die "no staged rules.rego at ${RULES_SRC} — run 03-deploy-cluster.sh first"

ISSUER=$(jq -r .issuer "${ENTRY}")
FEED=$(jq -r .feed "${ENTRY}")
SVN=$(jq -r .minimum_svn "${ENTRY}")
PRIV=$(grep '^private_key_hex=' "${FRAG}/key.txt" | cut -d= -f2)
SIDECAR_FEED="${FEED}-sidecar-demo"
SIDECAR_REF="${SIDECAR_FEED}:demo"
# An array, not a string: see 06-policy-fragment-e2e.sh.
PLAIN_HTTP=()
case "${FEED%%/*}" in localhost*|127.0.0.1*) PLAIN_HTTP=(--plain-http) ;; esac

load_toolchain 2>/dev/null || true
# Built by DEMO_PREP=1 (demo.sh), never here: this runs mid-demo.
GENPOLICY="${E2E_REPO_DIR}/target/release/genpolicy"
[[ -x "${GENPOLICY}" ]] || die "genpolicy has not been built — run DEMO_PREP=1 ./demo.sh first"
rm -f "${_SETUP_LOG}"

SIGN()    { ( cd "${E2E_REPO_DIR}" && cargo run -q --example sign-fragment \
              -p kata-security-reference-monitor -- "$@" ); }
FRAGGEN() { ( cd "${E2E_REPO_DIR}" && cargo run -q -p genpolicy-fragmentgen -- "$@" ); }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
kubectl get ns "${NS}" >/dev/null 2>&1 || kubectl create ns "${NS}" >/dev/null

# The issuer allow-list is measured configuration: it travels in initdata, not in
# the policy, so the guest knows which issuers exist before any policy runs.
printf 'version = "0.1.0"\nalgorithm = "sha256"\n\n[data]\n"fragment-issuers.toml" = %s\n%s\n%s\n' \
  "'''" "$(cat "${FRAG}/fragment-issuers.toml")" "'''" > "${WORK}/initdata.toml"

# Two rule files: one declaring no fragment, one declaring this fragment. The
# declaration is part of the measured policy — a fragment cannot be trusted by a
# policy that never named it, which is why steps 2 and 4 need different policies.
cp "${RULES_SRC}" "${WORK}/rules-none.rego"
printf '\npolicy_fragments := []\n' >> "${WORK}/rules-none.rego"
cp "${RULES_SRC}" "${WORK}/rules-sidecar.rego"
printf '\npolicy_fragments := [{"issuer": "%s", "feed": "%s", "minimum_svn": %s}]\n' \
  "${ISSUER}" "${SIDECAR_FEED}" "${SVN}" >> "${WORK}/rules-sidecar.rego"

# $1 = delivery annotation, empty for none.
render_pod() {
  local anno=""
  [[ -n "${1:-}" ]] && anno="
  annotations:
    io.katacontainers.config.agent.policy_fragments: \"$1\""
  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${POD}
  namespace: ${NS}${anno}
spec:
  runtimeClassName: ${E2E_RUNTIMECLASS}
  restartPolicy: Never
  securityContext:
    runAsUser: 0
    runAsGroup: 0
    supplementalGroups: [10]
  containers:
    - name: busybox
      image: quay.io/prometheus/busybox:latest
      command: ["sleep", "600"]
EOF
}

append_sidecar() {
  cat >> "$1" <<EOF
    - name: sidecar
      image: quay.io/prometheus/busybox:latest
      command: ["sh", "-c", "echo ${MARK}; sleep 600"]
EOF
}

ready_of() {
  kubectl get pod "${POD}" -n "${NS}" \
    -o jsonpath="{.status.containerStatuses[?(@.name=='$1')].ready}" 2>/dev/null
}

# wait_for runs its argument as a command, not as a shell string, so the
# predicates have to be functions.
pod_running()     { [[ "$(kubectl get pod "${POD}" -n "${NS}" -o jsonpath='{.status.phase}' 2>/dev/null)" = Running ]]; }
container_ready() { [[ "$(ready_of "$1")" = true ]]; }

wipe_pod() {
  kubectl delete pod "${POD}" -n "${NS}" --ignore-not-found --now >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do
    kubectl get pod "${POD}" -n "${NS}" >/dev/null 2>&1 || return 0
    sleep 2
  done
  kubectl delete pod "${POD}" -n "${NS}" --force --grace-period=0 >/dev/null 2>&1 || true
  sleep 3
}

# ---------------------------------------------------------------------------
step "1 — a container the measured policy contains"
log "generating a policy from a one-container pod, then running that pod"
wipe_pod
render_pod "" > "${WORK}/step1.yaml"
"${GENPOLICY}" -y "${WORK}/step1.yaml" -p "${WORK}/rules-none.rego" -j "${SETTINGS}" \
  --initdata-path="${WORK}/initdata.toml" >/dev/null || die "genpolicy failed"
_prompt "kubectl apply -f ${WORK}/step1.yaml"
kubectl apply -f "${WORK}/step1.yaml"
log "starting pod ${POD} — this boots a fresh SEV-SNP CVM, so it is not instant"
wait_for 300 "pod ${POD} Running" pod_running
ok "busybox is running, authorized by an entry in the measured policy"
kubectl get pod "${POD}" -n "${NS}"
pause

# ---------------------------------------------------------------------------
step "2 — a sidecar the policy has never seen"
log "same policy, plus a container appended to the yaml *after* generation"
log "the policy therefore has no entry for it, and no fragment is declared"
wipe_pod
render_pod "" > "${WORK}/step2.yaml"
"${GENPOLICY}" -y "${WORK}/step2.yaml" -p "${WORK}/rules-none.rego" -j "${SETTINGS}" \
  --initdata-path="${WORK}/initdata.toml" >/dev/null || die "genpolicy failed"
append_sidecar "${WORK}/step2.yaml"
_prompt "kubectl apply -f ${WORK}/step2.yaml"
kubectl apply -f "${WORK}/step2.yaml"
log "starting pod ${POD} again — another fresh CVM boot"
wait_for 300 "busybox ready" container_ready busybox
sleep 20
sc=$(ready_of sidecar)
[[ "${sc}" = "true" ]] && die "the sidecar started without a fragment — the policy is not being enforced"
ok "busybox ready, sidecar refused (ready=${sc:-<none>})"
show "kubernetes sees a partly-running pod: one container up, one never created" \
  "kubectl get pod ${POD} -n ${NS}; kubectl get pod ${POD} -n ${NS} -o jsonpath='{range .status.containerStatuses[*]}{.name}{\"  ready=\"}{.ready}{\"  \"}{.state.waiting.reason}{.state.terminated.reason}{\"\\n\"}{end}'"
show "the refusal is a pod event written by kubelet, relaying the shim's error" \
  "kubectl get events -n ${NS} --field-selector involvedObject.name=${POD} -o jsonpath='{range .items[*]}{.source.component}{\" -> \"}{.message}{\"\\n\"}{end}' 2>/dev/null | grep -m1 'blocked by policy' | cut -c1-240"
show "and this is the sentence the guest itself produced" \
  "kubectl get events -n ${NS} --field-selector involvedObject.name=${POD} -o jsonpath='{range .items[*]}{.message}{\"\\n\"}{end}' 2>/dev/null | grep -o 'blocked by policy[^\\\\]*' | head -1 | cut -c1-200"
say <<'EOF'

  Worth being clear about where that sentence comes from, because it reaches the
  screen through the host and the host is not trusted. The framing -- "<endpoint>
  is blocked by policy: no policy container satisfied: ..." -- is assembled by
  the agent's policy engine inside the guest (agent/policy/src/decision.rs). The
  reasons after the colon are strings from the measured policy document itself:
  "command: no policy container declares this container's argument list" is a
  rule in the generated rules.rego, not prose written by the runtime.

  The chain above is the whole trip: the agent returns PERMISSION_DENIED for
  CreateContainer over ttRPC, the shim wraps it, containerd hands it to kubelet,
  kubelet records the event. Every hop after the guest is untrusted, and none of
  them can turn the denial into an admission -- the container simply never
  starts. The worst a hostile host can do here is garble the explanation.

  Note also the pod is not dead: the sandbox and the authorized container keep
  running. The policy denies the request; it does not kill the pod.
EOF
pause

# ---------------------------------------------------------------------------
step "3 — sign and publish a fragment that authorizes exactly that sidecar"
# The entry is lifted from a policy generated for the pod the sidecar will really
# run in — annotation included, because the runtime stamps pod annotations onto
# every container's OCI spec and the entry has to match the request byte for byte.
log "generating a two-container reference policy to lift the sidecar's real entry from"
render_pod "${SIDECAR_REF}" > "${WORK}/ref.yaml"
append_sidecar "${WORK}/ref.yaml"
"${GENPOLICY}" -y "${WORK}/ref.yaml" -p "${WORK}/rules-none.rego" -j "${SETTINGS}" \
  --initdata-path="${WORK}/initdata.toml" >/dev/null || die "genpolicy failed"

python3 - "${WORK}/ref.yaml" "${MARK}" > "${WORK}/entry.json" <<'PY'
import base64, gzip, json, re, sys
blob = re.search(r'cc_init_data:\s*"?([A-Za-z0-9+/=]+)"?', open(sys.argv[1]).read())
policy = gzip.decompress(base64.b64decode(blob.group(1))).decode("utf-8", "replace")
i = policy.find("policy_data := {")
data, _ = json.JSONDecoder().raw_decode(policy, policy.index("{", i))
hits = [c for c in data["containers"] if sys.argv[2] in json.dumps(c)]
assert len(hits) == 1, f"expected one sidecar entry, found {len(hits)}"
print(json.dumps(hits[0], indent=2))
PY
[[ -s "${WORK}/entry.json" ]] || die "could not lift the sidecar entry"
# What the entry pins depends on how images reach the guest. With dm-verity
# (host-pull) it carries the layer root hash and the image is pinned by content.
# With guest-pull — what this cluster uses — `storages` is empty and the entry
# pins the image *reference* plus argv, env, mounts, user/gid and annotations;
# image integrity is then enforced by the guest's own image-verification policy,
# not by this entry. Either way the fragment authorizes one specific container,
# but it is worth being exact about which property is doing the work.
if grep -q 'root_hash\|verity' "${WORK}/entry.json"; then
  PINNED_BY="its dm-verity layer root hash"
  ok "the entry pins the image by dm-verity root hash"
else
  PINNED_BY="its image reference, argv, env, mounts and user — image integrity is enforced separately by the guest's image-verification policy"
  log "guest-pull: the entry pins the image reference and process shape, not a layer root hash"
fi

# The package is the fragment's own feed, quoted: a feed is an OCI reference and
# not a bare Rego identifier. The agent accepts that form only for the feed the
# SRM verified from the COSE envelope, so no publisher can write another's key.
{
  printf 'package agent_policy.fragments["%s"]\n\n' "${SIDECAR_FEED}"
  printf 'issuer := "%s"\n' "${ISSUER}"
  printf 'svn := %s\n' "${SVN}"
  printf 'containers := [%s]\n' "$(cat "${WORK}/entry.json")"
} > "${WORK}/sidecar.rego"
show "the fragment declares" "head -4 ${WORK}/sidecar.rego"

SIGN sign --issuer "${ISSUER}" --feed "${SIDECAR_FEED}" --svn "${SVN}" \
     --module "${WORK}/sidecar.rego" --key "${PRIV}" > "${WORK}/sign.txt" \
  || { tail -20 "${WORK}/sign.txt"; die "signing failed"; }
grep '^cose_sign1_hex=' "${WORK}/sign.txt" | cut -d= -f2 > "${WORK}/cose.hex"
FRAGGEN --cose "${WORK}/cose.hex" --push "${SIDECAR_REF}" "${PLAIN_HTTP[@]}" > "${WORK}/push.txt" \
  || { tail -20 "${WORK}/push.txt"; die "publishing failed"; }
ok "published ${SIDECAR_REF}, COSE_Sign1-signed by ${ISSUER} at svn ${SVN}"

# The fragment is the one artifact the host fetches and hands in, so decode it
# rather than describe it. The inspector carries its own CBOR reader; the node
# has no cbor2, and a demo should not need a pip install to explain itself.
_INSPECT="$(dirname "${BASH_SOURCE[0]}")/cose-inspect.py"
show "what was actually published — decoded from the envelope, not from what we typed" \
  "python3 ${_INSPECT} ${WORK}/cose.hex"
say <<'EOF'

  Everything the guest decides about this fragment comes from that protected
  header: the issuer it must find on the measured allow-list, the feed it may
  write under, and the SVN it must meet. All three are inside the signature, so
  a host that edits any of them invalidates the envelope it is trying to pass.
EOF
show "and this is the Rego it would add — the same module we signed, read back out of the envelope" \
  "python3 ${_INSPECT} ${WORK}/cose.hex --payload | head -4"
pause

say <<'EOF'

  Signature and SVN say who wrote it and how new it is. They do not say that
  anyone else ever saw it — a compromised issuer can sign a fragment for one
  victim and never publish it. That is what a transparency receipt is for, and
  the reference monitor verifies one cryptographically rather than trusting its
  presence.
EOF
show "a receipt is a ledger's countersignature over the same bytes the issuer signed" \
  "grep -n 'pub receipt:' -A3 ${E2E_REPO_DIR}/src/agent/security-reference-monitor/src/fragments.rs | head -8"
show "and it is checked by recomputing the ledger's Merkle root, not by reading a claim" \
  "grep -n -A9 'pub fn verify_ccf_inclusion' ${E2E_REPO_DIR}/src/agent/security-reference-monitor/src/ccf.rs"
show "a required receipt that is absent is a refusal, with its own error" \
  "grep -n 'MissingReceipt' ${E2E_REPO_DIR}/src/agent/security-reference-monitor/src/fragments.rs | head -4"
say <<'EOF'

  This demo's issuer list does not require a receipt, so what you just saw is
  the machinery rather than a live rejection — the fragment above carries none.
  The requirement is per issuer and feed, and the tests cover both directions,
  including a receipt that verifies against the wrong ledger.
EOF
pause

# ---------------------------------------------------------------------------
step "4 — the same sidecar, now authorized by the delivered fragment"
log "identical workload; the pod now declares the fragment and the host delivers it"
wipe_pod
render_pod "${SIDECAR_REF}" > "${WORK}/step4.yaml"
"${GENPOLICY}" -y "${WORK}/step4.yaml" -p "${WORK}/rules-sidecar.rego" -j "${SETTINGS}" \
  --initdata-path="${WORK}/initdata.toml" >/dev/null || die "genpolicy failed"
append_sidecar "${WORK}/step4.yaml"
_prompt "kubectl apply -f ${WORK}/step4.yaml"
kubectl apply -f "${WORK}/step4.yaml"
log "starting pod ${POD} once more — final fresh CVM boot"
wait_for 300 "sidecar ready" container_ready sidecar
[[ "$(ready_of busybox)" = "true" ]] || die "busybox is not ready"
ok "both containers running — the fragment authorized a container the measured policy never contained"
kubectl get pod "${POD}" -n "${NS}"
kubectl logs "${POD}" -n "${NS}" -c sidecar 2>/dev/null | head -1 || true

heading "what just happened"
say <<EOF
  step 2 and step 4 run the same image, the same command, the same pod.
  The difference is a signed, versioned artifact fetched from a registry by the
  host and verified inside the guest before it can authorize anything:

    * the issuer is on an allow-list measured into initdata, not into the policy
    * the fragment is COSE_Sign1-signed and its feed must match the declaration
    * its SVN must be at or above the floor the policy declares
    * it may only write under its own signed feed's namespace
    * the container it admits is pinned by ${PINNED_BY}

  Withhold the fragment (step 2) and the container simply never runs.
EOF
log "clean up with: kubectl delete pod ${POD} -n ${NS}"

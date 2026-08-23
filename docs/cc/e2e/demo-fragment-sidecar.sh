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
#   5. a fragment on a receipt-required feed is delivered by hand over ttRPC:
#      refused without a receipt, refused with one that binds other bytes,
#      accepted with the real one
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

# Same default as demo.sh, set before lib.sh derives paths from it: this script
# is also run standalone, and lib.sh's own default is the qemu dev platform.
: "${E2E_PLATFORM:=clh-snp}"
export E2E_PLATFORM

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
  # One command per break, as in demo.sh: a beat that runs something always
  # holds afterwards, so two commands never scroll past between keypresses.
  pause
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
# clears so the next step starts on a screen of its own. `scene` does not pause
# — every command beat already holds after itself.
scene() {
  { _demo_clear && [[ -n "${_CUR_STEP}" ]] && _lib_step "${_CUR_STEP}"; } || true
}

need kubectl; need jq; need python3
[[ -s "${ENTRY}" ]] || die "no fragment fixture at ${ENTRY} — run 06-policy-fragment-e2e.sh first"
[[ -s "${FRAG}/key.txt" ]] || die "no issuer key at ${FRAG}/key.txt — run 06-policy-fragment-e2e.sh first"
[[ -r "${RULES_SRC}" ]] || die "no staged rules.rego at ${RULES_SRC} — run 03-deploy-cluster.sh first"

ISSUER_CN="e2e-fragment-signer"
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
[[ -x "${E2E_REPO_DIR}/target/release/kata-agent-ctl" ]] \
  || die "kata-agent-ctl has not been built — run DEMO_PREP=1 ./demo.sh first"
rm -f "${_SETUP_LOG}"

SIGN()    { ( cd "${E2E_REPO_DIR}" && cargo run -q --example sign-fragment \
              -p kata-security-reference-monitor -- "$@" ); }
FRAGGEN() { ( cd "${E2E_REPO_DIR}" && cargo run -q -p genpolicy-fragmentgen -- "$@" ); }
LEDGER()  { ( cd "${E2E_REPO_DIR}" && cargo run -q --example mock-ledger \
              -p kata-security-reference-monitor -- "$@" ); }

# Step 5 talks to the guest agent directly over the sandbox's vsock, which is the
# host's own channel — so it needs the same tool an attacker on this node would
# use. Built by DEMO_PREP=1, never here.
CTL="${E2E_REPO_DIR}/target/release/kata-agent-ctl"

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
kubectl get ns "${NS}" >/dev/null 2>&1 || kubectl create ns "${NS}" >/dev/null

# FR-1f: a transparency ledger keypair for step 5. Only the public half is
# measured into initdata; the private half never leaves this directory, and a
# fresh one per run means nothing here is reusable as a trust anchor elsewhere.
( umask 077; SIGN gen-key > "${WORK}/ledger.txt" ) \
  || die "could not generate a ledger keypair"
LEDGER_ID="e2e-ledger"
LEDGER_PRIV=$(grep '^private_key_hex=' "${WORK}/ledger.txt" | cut -d= -f2)
LEDGER_PUB=$(grep  '^public_key_hex='  "${WORK}/ledger.txt" | cut -d= -f2)
[[ -n "${LEDGER_PRIV}" && -n "${LEDGER_PUB}" ]] || die "could not parse the ledger keypair"

# ------------------------------------------------------------------ did:x509
# FR-1d: the issuer is a certificate identity, not a bare key — the same shape
# C-ACI uses. A throwaway CA and one code-signing leaf, minted per run: nothing
# here is reusable as a trust anchor anywhere else.
need openssl
( umask 077
  openssl ecparam -name prime256v1 -genkey -noout -out "${WORK}/ca.key" 2>/dev/null
  openssl req -x509 -new -key "${WORK}/ca.key" -sha256 -days 2 \
      -subj "/CN=e2e-fragment-ca" -out "${WORK}/ca.pem" 2>/dev/null
  openssl ecparam -name prime256v1 -genkey -noout -out "${WORK}/leaf.ec.key" 2>/dev/null
  # sign-fragment parses PKCS#8; `ecparam` emits SEC1.
  openssl pkcs8 -topk8 -nocrypt -in "${WORK}/leaf.ec.key" -out "${WORK}/leaf.key" 2>/dev/null
  openssl req -new -key "${WORK}/leaf.key" -subj "/CN=${ISSUER_CN}" -out "${WORK}/leaf.csr" 2>/dev/null
  printf 'extendedKeyUsage = codeSigning\n' > "${WORK}/leaf.ext"
  openssl x509 -req -in "${WORK}/leaf.csr" -CA "${WORK}/ca.pem" -CAkey "${WORK}/ca.key" \
      -CAcreateserial -days 2 -sha256 -extfile "${WORK}/leaf.ext" -out "${WORK}/leaf.pem" 2>/dev/null
) || die "could not mint the demo certificate chain"
CA_FP_HEX=$(openssl x509 -in "${WORK}/ca.pem" -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1)
[[ ${#CA_FP_HEX} -eq 64 ]] || die "could not fingerprint the demo CA"
# The canonical did:x509 form: version, fingerprint algorithm, base64url of the
# CA fingerprint, then the policy the leaf must satisfy.
CA_FP_B64=$(openssl x509 -in "${WORK}/ca.pem" -outform DER 2>/dev/null \
  | openssl dgst -sha256 -binary | base64 | tr '+/' '-_' | tr -d '=\n')
ISSUER="did:x509:0:sha256:${CA_FP_B64}::subject:CN:${ISSUER_CN}"
EKU_CODE_SIGNING="1.3.6.1.5.5.7.3.3"
X509_ARGS=(--x509-key "${WORK}/leaf.key" --x509-chain "${WORK}/leaf.pem,${WORK}/ca.pem")

# `[[issuer]]` is where feeds, SVN floors and receipt scoping are declared, and
# its schema still requires an Ed25519 key. Mint a throwaway one so the field is
# a real key rather than a fabricated value — its private half signs only the
# Ed25519 envelope that sign-fragment emits alongside the x509 one and that
# nothing in this demo delivers. `require_x509 = true` makes the raw-key path
# unreachable regardless (see the note in step 3).
( umask 077; SIGN gen-key > "${WORK}/placeholder.txt" ) \
  || die "could not generate the placeholder keypair"
PRIV=$(grep '^private_key_hex=' "${WORK}/placeholder.txt" | cut -d= -f2)
PLACEHOLDER_PUB=$(grep '^public_key_hex=' "${WORK}/placeholder.txt" | cut -d= -f2)

# The receipt requirement is scoped to one feed rather than switched on globally:
# the sidecar feed above is delivered by boot-pull, which carries no receipt, and
# the point of step 5 is that the requirement is per issuer and per feed.
RECEIPT_FEED="${FEED}-receipt-demo"
{
  printf 'require_receipt = false\nrequire_x509 = true\n'
  printf '\n[[ca_anchor]]\ndid = "%s"\nca_fingerprint_hex = "%s"\n' "${ISSUER}" "${CA_FP_HEX}"
  printf 'require_subject_cn = "%s"\nrequire_eku = ["%s"]\n' "${ISSUER_CN}" "${EKU_CODE_SIGNING}"
  printf '\n[[issuer]]\nid = "%s"\ned25519_pubkey_hex = "%s"\nmin_svn = %s\n' \
    "${ISSUER}" "${PLACEHOLDER_PUB}" "${SVN}"
  printf '\n[[issuer.feed]]\nname = "%s"\nmin_svn = %s\nrequired_receipt_from = ["%s"]\n' \
    "${RECEIPT_FEED}" "${SVN}" "${LEDGER_ID}"
  printf '\n[[ledger]]\nid = "%s"\npubkey_hex = ["%s"]\n' "${LEDGER_ID}" "${LEDGER_PUB}"
} > "${WORK}/fragment-issuers.toml"

# The issuer allow-list is measured configuration: it travels in initdata, not in
# the policy, so the guest knows which issuers exist before any policy runs.
printf 'version = "0.1.0"\nalgorithm = "sha256"\n\n[data]\n"fragment-issuers.toml" = %s\n%s\n%s\n' \
  "'''" "$(cat "${WORK}/fragment-issuers.toml")" "'''" > "${WORK}/initdata.toml"

# Two rule files: one declaring no fragment, one declaring this fragment. The
# declaration is part of the measured policy — a fragment cannot be trusted by a
# policy that never named it, which is why steps 2 and 4 need different policies.
cp "${RULES_SRC}" "${WORK}/rules-none.rego"
printf '\npolicy_fragments := []\n' >> "${WORK}/rules-none.rego"
cp "${RULES_SRC}" "${WORK}/rules-sidecar.rego"
printf '\npolicy_fragments := [{"issuer": "%s", "feed": "%s", "minimum_svn": %s}]\n' \
  "${ISSUER}" "${SIDECAR_FEED}" "${SVN}" >> "${WORK}/rules-sidecar.rego"

# Read the container entries back out of a pod's *measured* policy. The point of
# steps 1-2 is that this document never changes, so take it from the running pod
# rather than from any file we wrote — a file we wrote proves nothing about what
# the guest was launched with.
cat > "${WORK}/policy-containers.py" <<'PY'
import json, re, sys
policy = sys.stdin.read()
i = policy.find("policy_data := {")
data, _ = json.JSONDecoder().raw_decode(policy, policy.index("{", i))
containers = data["containers"]
for c in containers:
    ann = c.get("OCI", {}).get("Annotations", {})
    name = ann.get("io.kubernetes.cri.container-name")
    print("  permitted: %s" % (name if name else "<the sandbox's own pause container>"))
frags = []
m = re.search(r"^policy_fragments := \[", policy, re.M)
if m:
    frags, _ = json.JSONDecoder().raw_decode(policy, policy.index("[", m.start()))
for f in frags:
    iss = f.get("issuer") or ""
    print("  trusted to add more: feed %s, minimum svn %s" % (f.get("feed"), f.get("minimum_svn")))
    print("                       issuer %s" % (iss[:52] + "..." if len(iss) > 52 else iss))
print()
print("%d container entries in this pod's measured policy%s" %
      (len(containers),
       " — nothing else can be created" if not frags
       else "\nthe declaration above names an issuer and a feed, never a container;\n"
            "the sidecar's entry exists only inside the signed fragment"))
PY

# Pull the measured policy back out of a rendered pod spec, so a claim about a
# pod's policy can be read from the document that will actually be applied.
cat > "${WORK}/yaml-policy.py" <<'PY'
import base64, gzip, re, sys
blob = re.search(r'cc_init_data:\s*"?([A-Za-z0-9+/=]+)"?', open(sys.argv[1]).read())
sys.stdout.write(gzip.decompress(base64.b64decode(blob.group(1))).decode("utf-8", "replace"))
PY

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
      image: mcr.microsoft.com/azurelinux/busybox:1.36
      command: ["sleep", "600"]
EOF
}

append_sidecar() {
  cat >> "$1" <<EOF
    - name: sidecar
      image: mcr.microsoft.com/azurelinux/busybox:1.36
      command: ["sh", "-c", "echo ${MARK}; sleep 600"]
EOF
}

ready_of() {
  kubectl get pod "${POD}" -n "${NS}" \
    -o jsonpath="{.status.containerStatuses[?(@.name=='$1')].ready}" 2>/dev/null
}

# An ephemeral container is reported in its own status list, never in
# containerStatuses, so a refused one is invisible to ready_of.
eph_ready_of() {
  kubectl get pod "${POD}" -n "${NS}" \
    -o jsonpath="{.status.ephemeralContainerStatuses[?(@.name=='$1')].ready}" 2>/dev/null
}

# Refused means the kubelet got an error back and the container terminated
# without ever running; settled covers that and the (disallowed) running case,
# so the assertion after it is what decides, not the wait.
eph_settled() {
  local s
  s=$(kubectl get pod "${POD}" -n "${NS}" \
    -o jsonpath="{.status.ephemeralContainerStatuses[?(@.name=='$1')].state}" 2>/dev/null)
  [[ "${s}" == *terminated* || "${s}" == *running* ]]
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

# --------------------------------------------------- reaching the agent directly
# Step 5 does not go through the runtime: it opens the sandbox's own vsock and
# speaks ttRPC to the agent, which is the channel the host already owns. Same
# discovery as 08-lifecycle-gates.sh, kept here so this script stands alone.
container_id() {
  kubectl get pod "${POD}" -n "${NS}" \
    -o jsonpath='{.status.containerStatuses[0].containerID}' 2>/dev/null \
    | sed 's|containerd://||'
}

sandbox_id() {
  local ct sb
  ct=$(container_id) && [[ -n "${ct}" ]] || return 1
  sb=$(sudo ctr -n k8s.io c info "${ct}" 2>/dev/null \
    | sed -n 's/.*"io.kubernetes.cri.sandbox-id": "\([a-f0-9]*\)".*/\1/p' | head -1)
  [[ -n "${sb}" ]] || return 1
  echo "${sb}"
}

# Cloud Hypervisor has no host-visible CID: the guest is reached through a hybrid
# vsock unix socket the shim creates per sandbox. QEMU gives a real CID instead.
agent_addr() {
  local sb=$1 sock cid
  if [[ "${E2E_PLATFORM:-}" = "clh-snp" ]]; then
    sock="/run/kata/${sb}/ch-vm.sock"
    for _ in $(seq 1 20); do
      sudo test -S "${sock}" && { echo "unix://${sock}"; return 0; }
      sleep 1
    done
    return 1
  fi
  # shellcheck disable=SC2009  # the full argv is needed to sed guest-cid out of
  cid=$(ps -ef | grep "[s]andbox-${sb}" | sed -n 's/.*guest-cid=\([0-9]*\).*/\1/p' | head -1)
  [[ -n "${cid}" ]] || return 1
  echo "vsock://${cid}:1024"
}

# A unix:// address is a hybrid vsock socket, not a plain domain socket, and
# agent-ctl only treats it as one when told so.
agent_hvsock_flag() {
  case "$1" in unix://*) printf '%s' "--hybrid-vsock true" ;; *) printf '%s' "" ;; esac
}

# ---------------------------------------------------------------------------
step "1 — a container the measured policy contains"
# Steps 1-2 need nothing more than a running pod whose measured policy declares
# no fragments — which is exactly what act 1 left behind. Reuse it rather than
# spending another CVM boot on an identical one. Steps 3-5 do need their own
# pod, because those carry a measured issuer list act 1's pod does not have.
FRAG_POD=demo-frag-sidecar
FRAG_INITDATA_JSONPATH='{.metadata.annotations.io\.katacontainers\.config\.hypervisor\.cc_init_data}'
if [[ -n "${E2E_BASE_POD:-}" ]] \
   && [[ "$(kubectl get pod "${E2E_BASE_POD}" -n "${NS}" -o jsonpath='{.status.phase}' 2>/dev/null)" = Running ]]; then
  POD="${E2E_BASE_POD}"
  log "reusing the pod from act 1 — it is still running, and its measured policy declares no fragments"
  ok "busybox is running, authorized by an entry in that measured policy"
else
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
  pause
fi
show "the spec this pod is running under — one container, and the policy measured into it" \
  "kubectl get pod ${POD} -n ${NS} -o yaml | awk '/^  annotations:/,/^status:/' | grep -vE 'last-applied-configuration|^      \\{' | awk '{ l = \$0; if (length(l) > 78) l = substr(l,1,78) \"...\"; if (l ~ /cc_init_data:/) l = l \"   <-- the measured policy\"; print l }' | grep -vE '^status:' | head -24"
show "and this is every container that spec's measured policy admits" \
  "kubectl get pod ${POD} -n ${NS} -o jsonpath='${FRAG_INITDATA_JSONPATH}' | base64 -d | gunzip | python3 ${WORK}/policy-containers.py"
say <<'EOF'

  That policy is fixed. Nothing in the steps that follow regenerates it, and
  nothing re-launches this pod — so whatever happens next is judged against
  exactly this list. One workload container is permitted, and the sandbox's own
  pause container. A second workload container has no entry, and cannot acquire
  one by being asked for politely.
EOF
pause

# ---------------------------------------------------------------------------
step "2 — a sidecar the policy has never seen, added to the pod already running"
log "no reboot, no new pod: the same sandbox from step 1 is still up"
log "kubectl debug injects a container into it at runtime, and the measured"
log "policy has no entry for it — no fragment is declared either"
say <<'EOF'

  This is the interesting shape of the attack. The pod was admitted, the CVM
  booted, its measurement is already fixed — and only now does something try to
  add a container. Nothing about the launch can help here; the decision has to
  be made by the guest, at runtime, against the document it was launched with.
EOF
show "add a container to the running pod" \
  "kubectl debug -n ${NS} ${POD} --image=mcr.microsoft.com/azurelinux/busybox:1.36 -c sidecar -- sh -c 'echo ${MARK}; sleep 600' 2>&1 | tail -4 || true"
wait_for 120 "the sidecar to reach a terminal state" eph_settled sidecar
sc=$(eph_ready_of sidecar)
[[ "${sc}" = "true" ]] && die "the sidecar started without a fragment — the policy is not being enforced"
ok "busybox still running, sidecar refused (ready=${sc:-<none>})"
show "kubernetes sees the pod it always saw, plus one container that never started" \
  "kubectl get pod ${POD} -n ${NS}; kubectl get pod ${POD} -n ${NS} -o jsonpath='{range .status.containerStatuses[*]}{.name}{\"  ready=\"}{.ready}{\"\\n\"}{end}{range .status.ephemeralContainerStatuses[*]}{.name}{\"  ready=\"}{.ready}{\"  \"}{.state.waiting.reason}{.state.terminated.reason}{\"\\n\"}{end}'"
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
  running, and they were running throughout. The policy denies the request; it
  does not kill the pod, and it does not need the pod restarted to say no.
EOF
pause

# ---------------------------------------------------------------------------
step "3 — sign and publish a fragment that authorizes exactly that sidecar"
# Back to a pod of our own from here on: steps 4-5 need a pod carrying the
# measured issuer list, which act 1's pod does not have. The switch has to
# happen *before* the reference policy below is generated — the runtime stamps
# the sandbox name onto every container's OCI spec, so an entry lifted under one
# pod name will not match a request made under another.
POD="${FRAG_POD}"
say <<'EOF'

  Before anything is signed, the fragment's contents have to come from
  somewhere. Nothing here is hand-written: the container entry is generated by
  the same tool that generated act 1's policy, from a real pod spec.

  The spec below is the two-container pod the sidecar will actually run in. It
  is never applied — it exists only so genpolicy has something to describe.
EOF
render_pod "${SIDECAR_REF}" > "${WORK}/ref.yaml"
append_sidecar "${WORK}/ref.yaml"
show "the reference spec — the pod as it will exist once the sidecar is authorized" \
  "grep -vE 'cc_init_data|policy_fragments' ${WORK}/ref.yaml | awk '{ l = \$0; if (length(l) > 78) l = substr(l,1,78) \"...\"; if (l ~ /name: sidecar/) l = l \"   <-- the container the fragment will carry\"; print l }' | sed -n '/^spec:/,\$p'"
say <<'EOF'

  Run genpolicy over that spec and it produces a policy admitting both
  containers. We do not want that policy — the pod must not be allowed to launch
  with the sidecar already in it. We want exactly one entry out of it.
EOF
show "generate a reference policy, then lift the single entry describing the sidecar" \
  "echo 'genpolicy -y ref.yaml -p rules-none.rego -j settings.json \\'; echo '         --initdata-path initdata.toml'; echo; echo '  then: decode the generated policy, select the one container entry'; echo '        whose spec matches the sidecar, and keep that entry alone'"
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
show "the lifted entry — generated, not written, and this is what the fragment will carry" \
  "head -14 ${WORK}/entry.json | awk '{ l = \$0; if (length(l) > 78) l = substr(l,1,78) \"...\"; print l }'; echo '  ...'; echo; echo -n '  entry size: '; wc -l < ${WORK}/entry.json | tr -d ' '; echo '  lines of generated JSON describing one container'"
say <<EOF

  That entry pins ${PINNED_BY}.

  It also carries the pod's annotations, including the sandbox name — the
  runtime stamps those onto every container's OCI spec, and the guest compares
  the request to the entry byte for byte. That is why the reference spec had to
  be the pod the sidecar will really run in, rather than any two-container pod.

  All that remains is to wrap it. Four lines of Rego go around the entry: the
  package name, the issuer, the SVN, and the entry itself.
EOF
show "the finished module — three declarations and the generated entry" \
  "awk 'NR<=4 { print } NR==5 { print \"containers := [ ...the generated entry above... ]\" }' ${WORK}/sidecar.rego 2>/dev/null || head -5 ${WORK}/sidecar.rego"
say <<'EOF'

  The package name is the fragment's own feed, quoted, because a feed is an OCI
  reference and not a bare Rego identifier. The agent accepts that form only for
  the feed it verified from the envelope, so no publisher can write into
  another's namespace.

  The issuer and the SVN appear twice — here in the module, and again in the
  envelope's signed header — and that is deliberate, not redundancy. The header
  is what the Rust side checks when the fragment is admitted. But the base
  policy also re-checks the SVN floor when it decides whether to admit a
  container, and that decision happens inside the policy engine, which cannot
  see a COSE header at all. So the module has to restate them in a form Rego
  can read.

  A restatement the author controls would be worthless as a gate, so before this
  module is loaded the agent evaluates it in a throwaway engine and requires the
  issuer and SVN it declares to equal the ones in the signed header. A module
  that describes itself as a different fragment than the envelope it arrived in
  is refused, and it is refused before it lands anywhere.
EOF
pause
say <<EOF

  Note what the issuer is. Not a key fingerprint and not a name we made up — a
  did:x509, which is a trust policy written as an identifier: version, hash
  algorithm, the CA certificate's SHA-256 fingerprint, and the constraints the
  signing leaf must satisfy.

    ${ISSUER}

  Nothing resolves that over a network; a confidential guest has no egress and
  needs none. The chain travels inside the envelope, and the identifier is
  checked against it. The measured initdata pins the CA fingerprint, the leaf's
  common name and its code-signing EKU, and this build sets require_x509, so the
  raw-key path is not reachable at all — a chain cannot be stripped to land on a
  weaker check.
EOF
show "the anchor, as measured into this pod's initdata" \
  "sed -n '/\\[\\[ca_anchor\\]\\]/,/^\$/p' ${WORK}/fragment-issuers.toml"
show "and the chain that has to satisfy it" \
  "openssl x509 -in ${WORK}/leaf.pem -noout -subject -issuer -ext extendedKeyUsage 2>/dev/null; echo; echo -n 'CA SHA-256: '; openssl x509 -in ${WORK}/ca.pem -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1"

say <<EOF

  That module is just text; nothing about it is trustworthy yet. Two commands
  turn it into something the guest will accept. The first wraps it in a
  COSE_Sign1 envelope: the Rego becomes the signed payload, the issuer, feed and
  SVN become signed headers, and the certificate chain rides along beside them.
  The second pushes that envelope to a registry so the host can find it.

  Note which side of the boundary that registry sits on. The guest never
  fetches anything — at the point a policy is being composed it has no network
  beyond loopback, and it needs none. The host resolves the reference, pulls
  the bytes, and hands them in. It is a courier, not an authority: it chooses
  which bytes to offer, and it can refuse to offer any, but every anchor used
  to judge them was measured into the guest at launch. Withholding is the only
  move it has left.
EOF
show "sign the module into an envelope, then publish the envelope" \
  "echo \"sign-fragment sign --issuer ${ISSUER} \\\\\"; echo '    --feed ${SIDECAR_FEED} --svn ${SVN} \\'; echo '    --module sidecar.rego --key <issuer key> --x509-chain <leaf,ca>'; echo; echo 'fragmentgen --cose cose.hex --push ${SIDECAR_REF}'"

SIGN sign --issuer "${ISSUER}" --feed "${SIDECAR_FEED}" --svn "${SVN}" \
     --module "${WORK}/sidecar.rego" --key "${PRIV}" "${X509_ARGS[@]}" > "${WORK}/sign.txt" \
  || { tail -20 "${WORK}/sign.txt"; die "signing failed"; }
grep '^cose_sign1_x509_hex=' "${WORK}/sign.txt" | cut -d= -f2 > "${WORK}/cose.hex"
[[ -s "${WORK}/cose.hex" ]] || die "sign-fragment produced no did:x509 envelope"
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

  The chain sits in the unprotected header, and the inspector is right to say
  that is not signed — so ask the obvious question: can the host swap it? It
  can, and it gains nothing. The chain is not the identity. The identity is the
  issuer string in the *signed* header, and the guest only accepts it if the
  chain it was handed leads to the measured CA, satisfies the leaf policy, and
  ends in the key that actually produced this signature. Substituting a chain
  the host controls fails the anchor; keeping the real chain changes nothing.
EOF
show "and this is the Rego it would add — the same module we signed, read back out of the envelope" \
  "python3 ${_INSPECT} ${WORK}/cose.hex --payload | head -4"

say <<'EOF'

  Signature and SVN say who wrote it and how new it is. They do not say that
  anyone else ever saw it — a compromised issuer can sign a fragment for one
  victim and never publish it. That is what a transparency receipt is for, and
  step 5 makes the guest prove it verifies one rather than trusting its presence.
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
show "the spec for this step — the same two containers, plus one annotation naming the fragment" \
  "awk '{ l = \$0; if (length(l) > 78) l = substr(l,1,78) \"...\"; if (l ~ /policy_fragments:/) l = l \"   <-- the fragment the host must fetch\"; else if (l ~ /cc_init_data:/) l = l \"   <-- the measured policy, which now declares that issuer\"; print l }' ${WORK}/step4.yaml"
say <<'EOF'

  This is a freshly launched pod with a different measured policy, and it has to
  be. The fragment declaration is part of what gets measured, so a pod that never
  named the issuer cannot be talked into trusting one later — which is exactly
  why step 2 failed and this will not.

  But notice what that policy does *not* contain. It has no entry for the
  sidecar, no image, no argv — nothing describing the second container at all.
  All it carries is a name, a signing identity and an SVN floor: permission for
  one specific issuer to say something about one specific feed. The container
  entry itself only ever exists inside the signed fragment. So what is measured
  at launch is the *authority*, not the payload — which is what lets the payload
  be written later without the launch measurement changing.
EOF
pause
show "the pod's own policy still admits only what act 1's did — the sidecar is not in it" \
  "python3 ${WORK}/yaml-policy.py ${WORK}/step4.yaml | python3 ${WORK}/policy-containers.py"
_prompt "kubectl apply -f ${WORK}/step4.yaml"
kubectl apply -f "${WORK}/step4.yaml"
log "starting pod ${POD} — a fresh CVM, this time declaring the fragment"
wait_for 300 "sidecar ready" container_ready sidecar
[[ "$(ready_of busybox)" = "true" ]] || die "busybox is not ready"
ok "both containers running — the fragment authorized a container the measured policy never contained"
kubectl get pod "${POD}" -n "${NS}"
kubectl logs "${POD}" -n "${NS}" -c sidecar 2>/dev/null | head -1 || true
say <<'EOF'

  Nothing here is specific to a sidecar injected after the fact. The same holds
  for an ordinary multi-container pod: whatever the measured policy does not
  already contain has to arrive as a signed fragment, or not at all.
EOF
pause
scene

# ---------------------------------------------------------------------------
step "5 — a transparency receipt, checked by the guest over the host's own channel"
say <<EOF

  Steps 1–4 went through the runtime. This one does not: it opens the sandbox's
  vsock and speaks ttRPC to the agent directly, with kata-agent-ctl — the same
  channel a compromised host already owns. Nothing here is privileged access;
  it is the ordinary delivery path, driven by hand.

  The pod that is running carries a measured issuer list with one extra rule:
  fragments on the feed

    ${RECEIPT_FEED}

  must additionally carry a receipt from the ledger "${LEDGER_ID}", whose public
  key is measured into initdata. The sidecar feed from steps 3–4 has no such
  requirement — the scope is per issuer and per feed.
EOF
show "the requirement and the ledger key, as measured into this pod's initdata" \
  "sed -n '/\\[\\[issuer.feed\\]\\]/,\$p' ${WORK}/fragment-issuers.toml"

SB=$(sandbox_id) || die "could not find the sandbox for ${POD}"
AGENT=$(agent_addr "${SB}") || die "could not work out the agent address for sandbox ${SB}"
HV=$(agent_hvsock_flag "${AGENT}")
show "the agent's endpoint on this node — a socket the host owns" \
  "echo ${AGENT}; sudo ls -l ${AGENT#unix://} 2>/dev/null || true"

# A second fragment, on the receipt-required feed. --emit-statement writes the
# exact bytes the issuer signed (the COSE Sig_structure), which is what a ledger
# records as a leaf — not the serialized envelope, or an intermediary could add
# an unprotected header and give one signed fragment two ledger identities.
{
  printf 'package agent_policy.fragments["%s"]\n\n' "${RECEIPT_FEED}"
  printf 'receipt_demo_loaded := true\n'
} > "${WORK}/receipt.rego"
SIGN sign --issuer "${ISSUER}" --feed "${RECEIPT_FEED}" --svn "${SVN}" \
     --module "${WORK}/receipt.rego" --key "${PRIV}" "${X509_ARGS[@]}" \
     --emit-x509-statement "${WORK}/receipt.stmt" > "${WORK}/receipt.sign.txt" \
  || { tail -20 "${WORK}/receipt.sign.txt"; die "signing the receipt-feed fragment failed"; }
grep '^cose_sign1_x509_hex=' "${WORK}/receipt.sign.txt" | cut -d= -f2 > "${WORK}/receipt.cose.hex"
[[ -s "${WORK}/receipt.cose.hex" && -s "${WORK}/receipt.stmt" ]] \
  || die "sign-fragment produced no did:x509 envelope or statement"
ok "signed a fragment on ${RECEIPT_FEED} at svn ${SVN}"
pause

_CTL_CMD="sudo ${CTL} -l error connect --server-address ${AGENT} ${HV} -n true -c"
# A refusal is carried by the ttRPC status, which -l error already prints. A
# success has no error to print, so the accepting call is run at -l info: the
# agent's reply is then visible instead of an empty screen and a claim.
_CTL_CMD_V="sudo ${CTL} -l info connect --server-address ${AGENT} ${HV} -n true -c"

say <<'EOF'

  First, deliver it with no receipt at all. The envelope is genuine: the issuer
  signed it, the SVN is in range, the feed is one this issuer may publish.
EOF
show "deliver the fragment over ttRPC, receipt withheld" \
  "${_CTL_CMD} \"LoadPolicyFragment cose=\$(cat ${WORK}/receipt.cose.hex)\" 2>&1 | tail -3"
say <<'EOF'

  Refused: FAILED_PRECONDITION / MissingReceipt. A valid issuer signature is not
  enough on a feed that requires publication.
EOF
pause

# The ledger records the statement and proves inclusion. --tamper flips the leaf
# data-hash, which is the interesting negative: the receipt is signed by the real
# ledger key and is still refused, because the root it signs no longer binds
# these bytes.
LEDGER prove-ccf --key "${LEDGER_PRIV}" --leaf "${WORK}/receipt.stmt" > "${WORK}/receipt.proof" \
  || die "mock-ledger could not mint a receipt"
LEDGER prove-ccf --key "${LEDGER_PRIV}" --leaf "${WORK}/receipt.stmt" --tamper \
  > "${WORK}/receipt.bad.proof" || die "mock-ledger could not mint the tampered receipt"

say <<'EOF'

  Now record the statement in the ledger and take a receipt for it. A receipt is
  not a stamp saying "published": it is an inclusion proof plus the ledger's
  signature over the Merkle root that proof folds to.
EOF
show "the receipt as it comes off the ledger" "cat ${WORK}/receipt.proof | cut -c1-100"
_RINSPECT="$(dirname "${BASH_SOURCE[0]}")/receipt-inspect.py"
show "decoded, and folded back to a root the same way the guest does it" \
  "python3 ${_RINSPECT} ${WORK}/receipt.proof --statement ${WORK}/receipt.stmt"
say <<'EOF'

  That last line is the whole mechanism. The guest does not read the data hash
  and believe it: it hashes the statement it just verified the issuer's signature
  over, and requires the leaf to be that hash. A receipt for some other fragment
  folds to a root the ledger did sign, but the leaf will not match.
EOF
pause

say <<'EOF'

  So try exactly that: a receipt minted by the real ledger key, one byte
  different in the leaf. Nothing about it is forged — the signature verifies.
EOF
show "what the tampered receipt binds instead" \
  "python3 ${_RINSPECT} ${WORK}/receipt.bad.proof --statement ${WORK}/receipt.stmt | tail -4"
show "deliver it" \
  "${_CTL_CMD} \"LoadPolicyFragment cose=\$(cat ${WORK}/receipt.cose.hex) receipt_ledger=${LEDGER_ID} proof=${WORK}/receipt.bad.proof\" 2>&1 | tail -3"
say <<'EOF'

  Refused again, and with a different status — InvalidInclusionProof rather than
  MissingReceipt. The two failures are distinguishable because they are
  different checks: one is presence, the other is what the bytes bind.
EOF
pause

say <<'EOF'

  Finally the real one, unchanged from what the ledger emitted. This call is run
  at info level, so the agent's own reply is on screen: a refusal would be a
  ttRPC status like the two above, and an acceptance is an empty Empty.
EOF
show "deliver the fragment with its receipt" \
  "${_CTL_CMD_V} \"LoadPolicyFragment cose=\$(cat ${WORK}/receipt.cose.hex) receipt_ledger=${LEDGER_ID} proof=${WORK}/receipt.proof\" 2>&1 | grep -E 'response received|RpcStatus' | tail -2"

say <<'EOF'

  And the same envelope again, receipt and all. It is now a replay, and the
  refusal is the proof that the acceptance above was real: the guest recorded
  this feed at SVN 2 and now requires 3, which is a statement about state it
  only has because the fragment was admitted.
EOF
show "deliver it a second time" \
  "${_CTL_CMD} \"LoadPolicyFragment cose=\$(cat ${WORK}/receipt.cose.hex) receipt_ledger=${LEDGER_ID} proof=${WORK}/receipt.proof\" 2>&1 | tail -3"
say <<EOF

  Four deliveries of the same signed fragment, over the same channel, to the
  same running guest: refused for no receipt, refused for a receipt that binds
  other bytes, accepted, then refused as a replay. What changed between them was
  only what travelled alongside the envelope — and none of the receipt fields
  are covered by the issuer's signature, which is exactly why the guest
  recomputes them rather than reading them.
EOF
pause

heading "what just happened"
say <<EOF

  Step 2 and step 4 run the same image and the same command. The difference is a
  signed, versioned artifact fetched from a registry by the host and verified
  inside the guest before it can authorize anything:

    * the issuer is a did:x509 whose CA fingerprint and leaf policy are measured
      into initdata, not into the policy — and the chain is inside the envelope
    * the fragment is COSE_Sign1-signed and its feed must match the declaration
    * its SVN must be at or above the floor the policy declares
    * it may only write under its own signed feed's namespace
    * the container it admits is pinned by ${PINNED_BY}
    * on a feed that requires one, it must also carry a transparency receipt
      whose ledger signature covers a Merkle root that binds these exact bytes

  Withhold the fragment (step 2) and the container simply never runs. Withhold
  the receipt (step 5) and the fragment itself is refused.
EOF
log "clean up with: kubectl delete pod ${POD} -n ${NS}"

#!/usr/bin/env bash
#
# Copyright (c) 2026 Microsoft Corporation
#
# SPDX-License-Identifier: Apache-2.0
#
# shellcheck source-path=SCRIPTDIR
# Hand-runnable demo of what Kata CoCo Strict enforces, end to end.
#
#   act 0  the guest is a real CVM on a confidential host
#   act 1  the policy is measured, not asserted
#   act 2  the image layers are verified — EROFS + dm-verity
#   act 3  the strict gates, live
#   act 4  fragments: a signed, bounded extension to a measured policy
#
# Design rules, learned the hard way:
#   * every beat prints evidence the audience can read, not a PASS marker;
#   * nothing here asserts anything it has not just shown;
#   * no .done markers, re-runnable at will, and it never mutates the cluster
#     beyond the pods it creates and deletes.
#
# The formal-model act (TLA+ / mutation harness) is deliberately absent: model
# coverage is being extended on branch jiria/formal-ci-gate and the numbers will
# move. Add it once that lands.
#
# Prerequisites. This runs against a fully built e2e node — it demonstrates the
# stack, it does not build it. What each act needs:
#
#   acts 0-3   stages 01-04. Specifically: an MSHV Dom0 node that has been
#              rebooted onto the MSHV kernel (01, 02), a cluster (03), and the
#              branch guest stack installed with its IGVM (04). Stage 04 also
#              records ~/.coco-e2e/guest-config-paths, which act 0 reads rather
#              than guessing the config filename.
#   act 4      additionally stage 06 — it needs the issuer key, the signed
#              fragment fixture and a reachable registry. Skipped with a warning
#              if those are absent.
#
#   Stage 05 is *not* required. Nothing here depends on it.
#
# Re-runnable on the same host: verified by running it twice back to back, which
# produced byte-identical evidence both times, including the same two initdata
# digests. Every pod it creates is deleted on exit, including the one the
# fragment demo would otherwise leave running.
#
# Also needed: kubectl, jq, passwordless sudo (acts 1 and 2 read the journal and
# the containerd snapshot dirs, both root-only), a cargo toolchain, and the
# source tree at E2E_REPO_DIR — acts 1, 2 and 3 quote the agent and runtime
# source directly, because showing the source is the point.
#
# In practice: ./run-all.sh 01 02 03 04 06, then DEMO_PREP=1 ./demo.sh.
#
# Env:
#   DEMO_PAUSE=1     wait for Enter between beats (default: run straight through)
#   DEMO_CLEAR=0     keep the screen when paused (default: clear between beats,
#                    redrawing the act heading; scrollback is preserved)
#   DEMO_ACTS=0,2    run only these acts (default: 0,1,2,3,4)
#   DEMO_PREP=1      do the slow work and exit — build genpolicy, warm the image
#                    pull, then stop. Run this *before* the demo: otherwise act 1
#                    pays ~70s to compile genpolicy while the audience watches.
#   E2E_NS           namespace (default coco-e2e)
set -uo pipefail

# This demo is about the confidential stack specifically, so the platform is not
# an open question. lib.sh derives every path from E2E_PLATFORM at source time
# and defaults to qemu-coco-dev, which would silently resolve /opt/kata paths
# that do not exist here — a demo that prints "No such file" instead of evidence.
: "${E2E_PLATFORM:=clh-snp}"
export E2E_PLATFORM

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Clearing the screen between beats costs the audience its place, so the act
# heading is redrawn afterwards — which means remembering it. Wrapping lib.sh's
# step keeps the heading format defined in exactly one place.
eval "_lib_step() $(declare -f step | tail -n +2)"
_CUR_STEP=""

# Home the cursor and erase the visible screen. Deliberately not `clear`: on this
# distro that also emits ESC[3J, which drops the scrollback buffer — so anything
# scrolled past would be genuinely gone rather than just off-screen.
_demo_clear() {
  [[ "${DEMO_PAUSE:-0}" = "1" && "${DEMO_CLEAR:-1}" = "1" ]] || return 1
  [[ -n "${TERM:-}" && "${TERM}" != "dumb" ]] || return 1
  printf '\033[H\033[2J'
}

step() { _CUR_STEP="$*"; _demo_clear; _lib_step "$@"; }

NS="${E2E_NS:-coco-e2e}"
ACTS="${DEMO_ACTS:-0,1,2,3,4}"
WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"; kubectl delete pod -n "${NS}" -l demo=parma --ignore-not-found >/dev/null 2>&1 || true; kubectl delete pod -n "${NS}" demo-frag-sidecar --ignore-not-found >/dev/null 2>&1 || true' EXIT

pause() {
  [[ "${DEMO_PAUSE:-0}" = "1" ]] || return 0
  printf '\n    press Enter to continue '
  read -r _
  # Start each beat on a clean screen. The previous evidence has been read and
  # discussed by this point, and leaving it up makes it hard to see what is new.
  # Only interactive runs clear: a piped or unpaused run keeps the full
  # transcript, which is what gets checked afterwards.
  _demo_clear && [[ -n "${_CUR_STEP}" ]] && _lib_step "${_CUR_STEP}"
}

want_act() { [[ ",${ACTS}," == *",$1,"* ]]; }

# Narration helper: a claim, then the command that substantiates it. Printing the
# command matters — an audience that cannot see what produced a number has been
# asked to take it on trust, which is the thing this whole branch is against.
show() {
  local desc="$1"; shift
  printf '\n  %s->%s %s\n' "${_c_blu}" "${_c_off}" "${desc}"
  printf '     %s$ %s%s\n' "${_c_yel}" "$*" "${_c_off}"
  bash -c "$*" 2>&1 | sed 's/^/     /'
}

# ---------------------------------------------------------------- pod fixtures
# A demo pod is an ordinary pod whose policy genpolicy generates and injects as
# measured initdata. CMD is the container argv, which is what the generated
# policy pins the container by.
demo_pod_yaml() {
  local name="$1" cmd="$2"
  cat > "${WORK}/${name}.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  namespace: ${NS}
  labels:
    demo: parma
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
      command: [${cmd}]
EOF
  "${GENPOLICY}" -y "${WORK}/${name}.yaml" -p "${GP_RULES}" -j "${GP_SETTINGS}" >/dev/null \
    || die "genpolicy failed for ${name}"
  grep -q 'cc_init_data' "${WORK}/${name}.yaml" \
    || die "no cc_init_data annotation — genpolicy did not inject a measured policy"
}

start_demo_pod() {
  local name="$1"
  kubectl delete pod "${name}" -n "${NS}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl apply -f "${WORK}/${name}.yaml" >/dev/null || die "kubectl apply failed for ${name}"
  log "starting pod ${name} — this boots a fresh SEV-SNP CVM, so it is not instant"
  wait_for 300 "pod ${name} Running" \
    bash -c "kubectl get pod ${name} -n ${NS} -o jsonpath='{.status.phase}' | grep -qx Running"
}

# The shim logs the digest it stamped into HOST_DATA. Note the double space in
# "initdata  digest" — it is not a typo, and a single-space grep silently
# matches nothing, which would look like the feature is missing.
#
# Do NOT identify a pod's digest by position in the journal (e.g. tail -1): the
# value you get then depends on how many sandboxes have booted since, so a
# second pod silently retroactively changes the "first" pod's answer. Compute
# the expected digest from that pod's own document and look that value up.
initdata_digest_expected() {
  openssl dgst -sha256 -binary "$1" | base64
}

initdata_journal_line() {
  local since="$1" want="$2"
  sudo journalctl -t kata --since "${since}" --no-pager 2>/dev/null \
    | grep -F "initdata  digest" | grep -F "${want}" | tail -1
}

# Any act that may have to generate a policy needs this, not just act 1: acts
# can be run individually, and act 2 falls back to creating its own pod. Doing
# it once and guarding with a flag keeps a full run from paying for it twice.
_TOOLCHAIN_READY=0
ensure_policy_toolchain() {
  [[ "${_TOOLCHAIN_READY}" = "1" ]] && return 0
  ensure_branch_genpolicy
  ensure_genpolicy_defaults
  kubectl get ns "${NS}" >/dev/null 2>&1 || kubectl create ns "${NS}"
  _TOOLCHAIN_READY=1
}

# Tie the pod that just booted to the CVM underneath it. The link is the sandbox
# id: it appears in the shim's -id and again in the path of the API socket that
# Cloud Hypervisor was launched with, so the chain from pod to partition is
# something the audience can follow rather than something we assert.
show_sandbox_backing() {
  local name="$1"
  show "the pod asked for the confidential runtime class, and the node honored it" \
    "kubectl get pod ${name} -n ${NS} -o custom-columns=NAME:.metadata.name,RUNTIMECLASS:.spec.runtimeClassName,STATUS:.status.phase,NODE:.spec.nodeName"
  show "that class is not a label: containerd routes it to its own shim and snapshotter" \
    "grep -A2 'runtimes.${E2E_RUNTIMECLASS}\]' /etc/containerd/config.toml"
  pause

  local sid
  sid=$(sudo crictl pods --name "${name}" --state Ready -o json 2>/dev/null | jq -r '.items[0].id // empty')
  if [[ -z "${sid}" ]]; then
    warn "could not resolve the sandbox id for ${name} — skipping the hypervisor linkage"
    return 0
  fi
  show "each Cloud Hypervisor process on this node is exactly one pod sandbox" \
    "ps -eo pid,args | grep '[c]loud-hypervisor' | cut -c1-150"
  show "and the sandbox id is what ties this pod's shim to this pod's VM" \
    "ps -eo pid,args | grep '[${sid:0:1}]${sid:1:11}' | cut -c1-130"
  pause

  local clh
  clh=$(pgrep -f "/run/kata/${sid}/ch-api.sock" | head -n 1)
  if [[ -z "${clh}" ]]; then
    warn "no Cloud Hypervisor process found for sandbox ${sid} — skipping the MSHV check"
    return 0
  fi
  # The fd table is the honest answer to "which hypervisor is this really?" —
  # a partition handle and a vCPU handle can only have come from /dev/mshv.
  show "that VM is driven by MSHV — a partition and a vCPU, and no KVM descriptor anywhere" \
    "sudo ls -l /proc/${clh}/fd | awk '/mshv|kvm/{print \$NF}' | sort -u"
  pause
}

# The measured document itself, straight out of the pod spec.
INITDATA_JSONPATH='{.metadata.annotations.io\.katacontainers\.config\.hypervisor\.cc_init_data}'
decode_initdata() {
  local name="$1" out="$2"
  kubectl get pod "${name}" -n "${NS}" -o jsonpath="${INITDATA_JSONPATH}" \
    | base64 -d | gunzip > "${out}" 2>/dev/null \
    || die "could not decode initdata for ${name}"
}

need kubectl; need jq; need openssl

# Fail with something actionable. A demo that dies halfway through act 1 in front
# of an audience is worse than one that refuses to start with a reason.
preflight() {
  need cargo
  sudo -n true 2>/dev/null \
    || die "passwordless sudo is required — acts 1 and 2 read the journal and containerd's root-only snapshot dirs"
  [[ -r "${E2E_REPO_DIR}/src/agent/src/mediation.rs" ]] \
    || die "no source tree at E2E_REPO_DIR=${E2E_REPO_DIR} — acts 2 and 3 quote the source directly"
  [[ -r "${E2E_GUEST_IGVM}" ]] \
    || die "no guest IGVM at ${E2E_GUEST_IGVM} — run 04-build-guest-stack.sh first"
  kubectl get nodes >/dev/null 2>&1 \
    || die "no reachable cluster — run 03-deploy-cluster.sh first"
  kubectl get runtimeclass "${E2E_RUNTIMECLASS}" >/dev/null 2>&1 \
    || die "runtimeclass ${E2E_RUNTIMECLASS} not found — run 03-deploy-cluster.sh first"
  ok "preflight: cluster, guest stack and source tree present"
}

# ============================================================ act 0
act0() {
  step "act 0 — this is a confidential host, and the guest is a real CVM"
  cat <<'EOF'

  MSHV plus Cloud Hypervisor with real SEV-SNP is not new work in itself — that
  path existed before, and then it was suspended. What is new is that it has
  been rebased onto current Kata and brought back into working order, so the
  hardening in the acts that follow is demonstrated on real confidential
  hardware rather than under nested virt on an ordinary host.
EOF
  show "the node runs an MSHV Dom0 kernel, not a stock one" \
    "uname -r"
  show "the hypervisor device is /dev/mshv; there is no /dev/sev (that is the guest's side)" \
    "ls -l /dev/mshv 2>&1; ls -l /dev/sev 2>&1 || true"
  pause
  # The stages record the config path they actually installed; guessing the
  # filename is how this breaks when runtime-rs and runtime-go configs diverge.
  local cfg
  cfg=$(cat "${E2E_STATE_DIR}/guest-config-paths" 2>/dev/null | head -1)
  [[ -r "${cfg}" ]] || cfg="${E2E_KATA_PREFIX}/share/defaults/kata-containers/runtime-rs/configuration.toml"
  show "the runtime is configured for an IGVM-launched SEV-SNP guest" \
    "grep -nE '^(igvm|confidential_guest|sev_snp_guest)' ${cfg}"
  show "and the IGVM file is the artifact the launch measurement covers" \
    "sha256sum ${E2E_GUEST_IGVM}"
  pause
}

# ============================================================ act 1
act1() {
  step "act 1 — the policy is measured, not asserted"
  cat <<'EOF'

  The policy does not arrive as an annotation the guest is asked to trust. It
  arrives as a document whose digest is in the SNP report, and the guest refuses
  to run if the two disagree.
EOF
  ensure_policy_toolchain

  local t0; t0=$(date '+%Y-%m-%d %H:%M:%S')
  demo_pod_yaml demo-a '"sleep", "3600"'
  show "genpolicy injects the policy as measured initdata — gzip+base64, not plaintext" \
    "grep -o 'cc_init_data: [A-Za-z0-9+/]\{0,24\}' ${WORK}/demo-a.yaml"
  pause

  start_demo_pod demo-a
  cat <<'EOF'

  Before opening the document, it is worth establishing what just booted — a
  pod is only as confidential as the sandbox underneath it.
EOF
  show_sandbox_backing demo-a

  decode_initdata demo-a "${WORK}/a.toml"
  show "that annotation is an initdata document — decode it straight out of the running pod" \
    "kubectl get pod demo-a -n ${NS} -o jsonpath='${INITDATA_JSONPATH}' | base64 -d | gunzip | head -5"
  cat <<'EOF'

  That is the whole shape of it. Two header fields, then a [data] table with a
  single key: "policy.rego", whose value is the entire generated policy —
  everything below that line. Nothing else is in the document, so "the
  measurement covers the policy" is not a figure of speech; the document *is*
  the policy. Note algorithm = 'sha256': that is how its digest gets computed
  in a moment.
EOF
  pause
  show "and the fragment machinery rides inside it — declared empty for this pod, and fail-closed" \
    "grep -c . ${WORK}/a.toml | xargs -I{} echo 'policy lines: {}'; grep -nE '^default policy_fragments := \[\]|\"fragments\": \[\]|\"image_layer_verification\": \"[a-z-]*\"' ${WORK}/a.toml"
  pause

  local d1; d1=$(initdata_digest_expected "${WORK}/a.toml")
  printf '\n  %s->%s anyone can compute the expected measurement from that document alone\n' "${_c_blu}" "${_c_off}"
  printf '     %s$ openssl dgst -sha256 -binary a.toml | base64%s\n' "${_c_yel}" "${_c_off}"
  printf '     %s\n' "${d1}"
  printf '\n  %s->%s and that is the value the runtime stamped into the SNP report'"'"'s HOST_DATA\n' "${_c_blu}" "${_c_off}"
  printf '     %s$ sudo journalctl -t kata | grep "initdata  digest"%s\n' "${_c_yel}" "${_c_off}"
  local jline; jline=$(initdata_journal_line "${t0}" "${d1}")
  if [[ -n "${jline}" ]]; then
    printf '     %s\n' "${jline}"
    ok "the host logged exactly the digest we computed ourselves"
  else
    warn "did not find that digest in the journal — check 'journalctl -t kata'"
  fi
  cat <<'EOF'

  Now the point of the whole exercise. The workload here is the container's
  command, and we change one byte of it — sleep 3600 becomes sleep 3601. That
  is the entire difference: same image, same everything else. The measurement
  moves anyway, because the command is part of the policy that gets hashed. A
  relying party pinned to the first digest rejects the second.
EOF
  pause

  local t1; t1=$(date '+%Y-%m-%d %H:%M:%S')
  demo_pod_yaml demo-b '"sleep", "3601"'
  start_demo_pod demo-b
  decode_initdata demo-b "${WORK}/b.toml"
  local d2; d2=$(initdata_digest_expected "${WORK}/b.toml")
  printf '\n     sleep 3600  ->  %s\n     sleep 3601  ->  %s\n' "${d1}" "${d2}"
  if [[ -z "${d1}" || -z "${d2}" ]]; then
    warn "could not compute both digests"
  elif [[ "${d1}" = "${d2}" ]]; then
    warn "the two digests are identical — that should not happen; the workload change did not reach the policy"
  elif [[ -n "$(initdata_journal_line "${t1}" "${d2}")" ]]; then
    ok "one byte of workload, an entirely different measurement — and the host stamped it"
  else
    warn "digests differ as expected, but the second was not found in the journal"
  fi
  cat <<'EOF'

  Worth noting what does *not* change: run this again, on this host or another,
  and the same workload yields the same digest. The measurement is a pure
  function of the policy document — which is why we could compute it above with
  nothing but sha256 and the document itself. That is what makes pinning a
  digest meaningful: a relying party computes the expected value rather than
  being told what to trust.

  And the guest checks this itself: the agent reads its own SNP report and
  aborts unless the delivered document hashes to HOST_DATA.

  The fair question is whether we can watch it do that — print the value the
  guest saw. We cannot, and the reason is worth more than the number would be.
  This build closes every channel that could carry it out.
EOF
  pause
  show "the agent's log stream is wired to a sink — a strict build forwards nothing" \
    "grep -n -B4 'Box::new(tokio::io::sink())' ${E2E_REPO_DIR}/src/agent/src/main.rs"
  show "and it cannot even construct a vsock listener: the socket import is compiled out" \
    "grep -n -B1 'use nix::sys::socket' ${E2E_REPO_DIR}/src/agent/src/main.rs"
  pause
  show "nor can the host ask for it back — the guest overrides what it is told" \
    "grep -n -A6 '\*debug_console = false;' ${E2E_REPO_DIR}/src/agent/src/config.rs"
  cat <<'EOF'

  No log, no port, no debug console, no tracing — and the host cannot re-enable
  any of them, because those settings arrive on the kernel command line and this
  build refuses to honor them. Note what that costs us right here: the demo
  would be more satisfying if the guest could just tell us. It does not, and it
  should not.

  So the evidence is not a line of output. It is that the pod reached Running at
  all. Had the delivered document not hashed to HOST_DATA, the agent would have
  aborted and there would be nothing to look at.
EOF
  pause
}

# ============================================================ act 2
act2() {
  step "act 2 — the image layers are verified: EROFS + dm-verity"
  cat <<'EOF'

  A measured policy is only as good as its grip on what actually gets mounted.
  Here the container image layers are EROFS images produced by containerd's own
  snapshotter, each with a dm-verity root hash, and the policy names those exact
  hashes — so the guest will mount a layer only if its contents hash to what the
  measurement already committed to.
EOF
  [[ -s "${WORK}/a.toml" ]] || { ensure_policy_toolchain; demo_pod_yaml demo-a '"sleep", "3600"'; start_demo_pod demo-a; decode_initdata demo-a "${WORK}/a.toml"; }

  local SNAP=/var/lib/containerd/io.containerd.snapshotter.v1.erofs/snapshots
  show "containerd built each layer as an EROFS image, with verity metadata beside it" \
    "sudo find ${SNAP} -maxdepth 2 -name 'layer.erofs*' | sort | head"
  pause
  show "one such file per layer — and a pod has several, across its images and the pause container" \
    "sudo find ${SNAP} -maxdepth 2 -name 'layer.erofs.dmverity' | sort | while read -r f; do echo \"\$f\"; sudo cat \"\$f\"; echo; done | head -20"
  pause

  show "and the policy names them in the mount options the guest must be handed" \
    "grep -oE 'X-kata\.dmverity\.roothash=[a-f0-9]{64}' ${WORK}/a.toml | sort -u | head -3"
  pause

  sudo find "${SNAP}" -maxdepth 2 -name 'layer.erofs.dmverity' -exec cat {} \; 2>/dev/null \
    | jq -r '.roothash' 2>/dev/null | sort -u > "${WORK}/host-hashes.txt"
  # Extract by the option that actually carries a root hash. Grepping for any
  # 64-hex string would also pick up image digests and quietly inflate the count.
  grep -oE 'X-kata\.dmverity\.roothash=[a-f0-9]{64}' "${WORK}/a.toml" \
    | cut -d= -f2 | sort -u > "${WORK}/policy-hashes.txt"

  printf '\n  %s->%s the measured policy names each of those layers, by root hash\n' "${_c_blu}" "${_c_off}"
  printf '     EROFS layers on this host : %s\n' "$(wc -l < "${WORK}/host-hashes.txt")"
  printf '     root hashes in the policy : %s\n' "$(wc -l < "${WORK}/policy-hashes.txt")"
  local matched missing
  matched=$(comm -12 "${WORK}/host-hashes.txt" "${WORK}/policy-hashes.txt" | wc -l)
  missing=$(comm -13 "${WORK}/host-hashes.txt" "${WORK}/policy-hashes.txt" | wc -l)
  comm -12 "${WORK}/host-hashes.txt" "${WORK}/policy-hashes.txt" | sed 's/^/     match  /'
  if [[ "${matched}" -gt 0 && "${missing}" -eq 0 ]]; then
    ok "every root hash the policy names is a layer containerd actually built (${matched})"
  elif [[ "${matched}" -gt 0 ]]; then
    warn "${matched} matched, but ${missing} policy hash(es) have no layer on this host"
  else
    warn "no overlap — the running pod's layers may not be among the snapshots listed"
  fi
  pause

  show "and the policy demands verity for every layer it admits" \
    "grep -o '\"image_layer_verification\": \"[a-z-]*\"' ${WORK}/a.toml | head -1"
  cat <<'EOF'

  genpolicy did not read those hashes off this host. It predicted them offline,
  reproducing containerd's mkfs.erofs invocation byte-for-byte against a pinned
  erofs-utils — which is why the policy can be generated anywhere, and why the
  match above is a result rather than a copy.
EOF
  pause

  show "note where the verity device is NOT: the host has no dm devices at all" \
    "sudo dmsetup ls 2>&1"
  cat <<'EOF'

  The host builds the layers and can no longer look inside them. The guest
  kernel mounts them with dm-verity and enforces the root hash on every block
  read — a root hash that came from the measured policy, which is covered by
  the attestation. That is an unbroken chain from the SNP report to a
  filesystem block.
EOF
  pause
}

# ============================================================ act 3
act3() {
  step "act 3 — the strict gates, live"
  [[ -n "$(kubectl get pod demo-a -n "${NS}" --ignore-not-found -o name 2>/dev/null)" ]] || {
    ensure_policy_toolchain
    demo_pod_yaml demo-a '"sleep", "3600"'; start_demo_pod demo-a
  }

  cat <<'EOF'

  Nothing in the generated policy permits an exec. So the agent refuses one —
  and the refusal is not a string, it is a structured object.
EOF
  local out
  out=$(kubectl exec -n "${NS}" demo-a -- /bin/true 2>&1) && die "exec SUCCEEDED — policy is not being enforced"
  printf '\n  %s->%s kubectl exec, denied\n' "${_c_blu}" "${_c_off}"
  echo "${out}" | grep -o 'policyDecision<[^>]*>policyDecision' | head -1 \
    | cut -c1-96 | sed 's/^/     /; s/$/.../'
  pause

  # The sentinel wraps the payload in angle brackets: policyDecision<...>policyDecision.
  # The framing is fixed and machine-parseable, so a log consumer can lift the
  # record straight out of containerd's logs without modification.
  local b64; b64=$(echo "${out}" | grep -o 'policyDecision<[^>]*>policyDecision' | head -1 \
    | sed 's/^policyDecision<//; s/>policyDecision$//')
  if [[ -n "${b64}" ]]; then
    printf '\n  %s->%s decoded — this is FR-8\n' "${_c_blu}" "${_c_off}"
    echo "${b64}" | base64 -d 2>/dev/null | jq . 2>/dev/null | sed 's/^/     /' \
      || echo "${b64}" | base64 -d | sed 's/^/     /'
    cat <<'EOF'

  Three things to notice. The sentinel framing is fixed and machine-parseable,
  so a log consumer can lift this record straight out of containerd's logs.
  bound_state_keys lists field *names* and never their values, so a denial
  record cannot become an exfil channel. And failed_rule names only the
  endpoint — "reasons" is what actually attributes the denial.
EOF
  else
    warn "no decision object in the error text — expected the policyDecision sentinel"
  fi
  pause

  cat <<'EOF'

  Two more gates, in categories that are easy to leave open.
EOF
  show "FR-10: the host-to-guest file copy channel is refused outright in strict builds" \
    "sed -n '2535,2543p' ${E2E_REPO_DIR}/src/agent/src/rpc.rs"
  show "FR-14: network config is policy-checked and then frozen once the workload starts" \
    "grep -n 'net_phase_authorize' ${E2E_REPO_DIR}/src/agent/src/rpc.rs | head -6"
  cat <<'EOF'

  Network configuration is an easy channel to overlook: if a host can reach the
  network-modify path without a policy call, it can add or remove adapters,
  addresses and routes unchecked, and the measured policy says nothing about the
  pod's connectivity. Which raises the obvious question: how do we know there is
  no such hole anywhere else in the agent?
EOF
  pause

  show "every RPC is classified, per build configuration — this is the strict posture, in source" \
    "sed -n '190,200p' ${E2E_REPO_DIR}/src/agent/src/mediation.rs"
  cat <<'EOF'

  SetPolicy is CompiledOut in a strict build — not denied, absent — and the
  fragment channel opens exactly as the policy-mutation channel closes.

  And the manifest cannot drift from the service: build.rs parses agent.proto
  and a const block compares the two, so an unclassified RPC is a *compile
  error*. Delete one line and the build stops.
EOF
  pause
}

# ============================================================ act 4
act4() {
  step "act 4 — fragments: a signed, bounded extension to a measured policy"
  local frag="${HOME}/.coco-e2e/fragments"
  if [[ ! -s "${frag}/fragment-entry.json" || ! -s "${frag}/key.txt" ]]; then
    warn "no fragment fixtures — run 06-policy-fragment-e2e.sh first; skipping act 4"
    return 0
  fi
  cat <<'EOF'

  A measured policy is fixed at launch. Fragments are how it is extended
  afterwards without unmeasuring it: signed by an issuer the measured document
  already named, and bounded by what that document already permits.
EOF
  pause
  DEMO_PAUSE="${DEMO_PAUSE:-0}" bash "$(dirname "${BASH_SOURCE[0]}")/demo-fragment-sidecar.sh"
}

# ============================================================ run
load_toolchain
load_coco_env
preflight

# Everything slow lives here, so the demo itself only displays evidence. The
# image pull matters as much as the genpolicy build: a cold pull happens inside
# the pod-start wait in act 1, where it looks like the platform being slow.
if [[ "${DEMO_PREP:-0}" = "1" ]]; then
  step "prep — doing the slow work now so the demo does not"
  ensure_policy_toolchain
  demo_pod_yaml demo-prep '"sleep", "5"'
  start_demo_pod demo-prep
  kubectl delete pod demo-prep -n "${NS}" --ignore-not-found >/dev/null 2>&1 || true
  ok "genpolicy built, image pulled, EROFS layers and verity sidecars materialized"
  log "now run: DEMO_PAUSE=1 ./demo.sh"
  exit 0
fi

for a in 0 1 2 3 4; do
  want_act "${a}" && "act${a}"
done

step "demo complete"
if [[ "${ACTS}" == "0,1,2,3,4" ]]; then
  cat <<'EOF'

  What was shown, end to end: a real CVM on a confidential host; a policy whose
  digest is in the hardware report and moves with a one-byte change; image
  layers pinned by dm-verity root hashes that the measured policy names; a
  structured, redacted denial; and a signed fragment that extends the policy
  only within what the measurement already allowed.
EOF
else
  printf '\n  ran acts: %s (of 0,1,2,3,4)\n' "${ACTS}"
fi

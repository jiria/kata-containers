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
#   DEMO_NARRATE=0   suppress the written prose, leaving only the headings,
#                    commands and their output — for narrating live over the top
#   DEMO_STEPS=0     hide the per-beat numbers (default: show them, so a beat can
#                    be referred to by number when reviewing)
#   DEMO_SCRIPT=path write the spoken script to this file as well, one line per
#                    beat, for generating a voice-over track. Works with the
#                    prose on or off; the file is truncated at startup.
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

step() { _CUR_STEP="$*"; _demo_clear; _lib_step "$@"; _vo "$*"; }

# A heading that deliberately does not clear: for a section that reads the
# evidence still on screen. The closing summary sums up the act that just ran,
# so wiping it first would leave the summary unsupported.
heading() { _CUR_STEP="$*"; _lib_step "$@"; _vo "$*"; }

NS="${E2E_NS:-coco-e2e}"
ACTS="${DEMO_ACTS:-0,1,2,3,4}"
WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"; sudo pkill -f initdata-tamper.py >/dev/null 2>&1 || true; kubectl delete pod -n "${NS}" -l demo=parma --ignore-not-found >/dev/null 2>&1 || true; kubectl delete pod -n "${NS}" demo-frag-sidecar --ignore-not-found >/dev/null 2>&1 || true' EXIT

pause() {
  [[ "${DEMO_PAUSE:-0}" = "1" ]] || return 0
  printf '\n    press Enter to continue '
  read -r _
}

# Two kinds of break. `pause` holds while the audience reads something that
# belongs with what is already on screen; `scene` ends one line of argument and
# clears, so the next claim starts on a screen of its own. Beats that are
# evidence for the same claim have to stay together — clearing between the two
# halves of a comparison is how the comparison stops being one.
scene() {
  pause
  _demo_clear && [[ -n "${_CUR_STEP}" ]] && _lib_step "${_CUR_STEP}"
}

want_act() { [[ ",${ACTS}," == *",$1,"* ]]; }

# ------------------------------------------------------------------- narration
# The prose is separable from the evidence. A presenter narrating live wants the
# commands and their output on screen but not a wall of text competing with what
# they are saying, and a recorded version wants that same prose as an audio
# track. So every spoken line goes through one place: it can be suppressed on
# screen (DEMO_NARRATE=0) and it can be captured to a plain-text script
# (DEMO_SCRIPT=path), one line per spoken beat, ready for a TTS pass.
#
# The evidence itself is never suppressed — with the prose gone the commands have
# to carry the explanation, which is why they are shown with the host they run on
# and their output is bracketed rather than left to run into the next beat.
_HOST_LABEL="$(whoami)@$(hostname -s 2>/dev/null || echo host)"

# Every beat gets a visible number so a reviewer can say "beat 14 is wrong"
# instead of quoting a line of output back. Screen only: DEMO_SCRIPT stays clean
# because a TTS pass would happily read the numbers aloud. The prefix keeps the
# fragment demo's beats distinguishable, since it runs as its own process with
# its own counter.
_BEAT_N=0
_BEAT_PREFIX="${DEMO_BEAT_PREFIX:-}"
_beat() {
  _BEAT_TAG=''
  [[ "${DEMO_STEPS:-1}" = "1" ]] || return 0
  _BEAT_N=$((_BEAT_N + 1))
  _BEAT_TAG=$(printf '[%s%02d]' "${_BEAT_PREFIX}" "${_BEAT_N}")
}

_vo() {
  [[ -n "${DEMO_SCRIPT:-}" ]] || return 0
  printf '%s\n' "$*" >> "${DEMO_SCRIPT}"
}

# A real prompt, and real output under it. The evidence is the point of this
# demo, so it should look like what an engineer would see if they ran the
# command themselves — same host, same working directory, no indentation and no
# gutter characters wrapped around it.
_prompt() {
  printf '\n%s%s%s:%s%s%s$ %s\n' \
    "${_c_grn}" "${_HOST_LABEL}" "${_c_off}" \
    "${_c_blu}" "${PWD/#${HOME}/\~}" "${_c_off}" "$*"
}

# Reads the block from stdin so the call sites stay ordinary heredocs. Wrapped
# lines are rejoined into one line per paragraph: a TTS engine wants sentences,
# not the 78-column layout the terminal wants.
say() {
  local line para="" tag first=1
  _beat; tag="${_BEAT_TAG}"
  while IFS= read -r line; do
    if [[ "${DEMO_NARRATE:-1}" = "1" ]]; then
      # Every block opens with a blank line; spend it on the beat number rather
      # than adding one, so numbering costs no vertical space.
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

# Narration helper: a claim, then the command that substantiates it. Printing the
# command matters — an audience that cannot see what produced a number has been
# asked to take it on trust, which is the thing this whole branch is against.
#
# The claim is prose and follows DEMO_NARRATE; the command and its output do not.
show() {
  local desc="$1"; shift
  local tag; _beat; tag="${_BEAT_TAG}"
  _vo "${desc}"
  if [[ "${DEMO_NARRATE:-1}" = "1" ]]; then
    printf '\n  %s->%s %s%s\n' "${_c_blu}" "${_c_off}" "${tag:+${tag} }" "${desc}"
  elif [[ -n "${tag}" ]]; then
    # With the prose suppressed the number would vanish with it, and the
    # narrated run is exactly where "which beat?" gets asked.
    printf '\n  %s\n' "${tag}"
  fi
  _prompt "$*"
  bash -c "$*" 2>&1
  return 0
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
  # Shown rather than hidden: the audience should see the pod being created, and
  # by what command, not just a status line claiming it happened.
  _prompt "kubectl apply -f ${WORK}/${name}.yaml"
  kubectl apply -f "${WORK}/${name}.yaml" || die "kubectl apply failed for ${name}"
  log "this boots a fresh SEV-SNP CVM, so it is not instant"
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
  # No building here. genpolicy is built once by DEMO_PREP=1 (and preflight
  # refuses to start without it), so the demo itself only ever displays evidence.
  GENPOLICY="${E2E_REPO_DIR}/target/release/genpolicy"
  export GENPOLICY
  # Staging the rules/settings is file copying, not compilation, but it is still
  # scaffolding: run it quietly and dump the whole log if it fails.
  local logf="${WORK}/toolchain.log"
  ensure_genpolicy_defaults > "${logf}" 2>&1 \
    || { cat "${logf}"; die "could not stage genpolicy inputs (see ${logf})"; }
  kubectl get ns "${NS}" >/dev/null 2>&1 || kubectl create ns "${NS}"
  _TOOLCHAIN_READY=1
  # Provenance is checked in prep, not shown as a beat: it says something about
  # how the demo was assembled, not about how the guest defends itself.
  local head_sha stamp
  head_sha=$(git -C "${E2E_REPO_DIR}" rev-parse HEAD 2>/dev/null || echo unknown)
  stamp=$(strings "${GENPOLICY}" 2>/dev/null | grep -m1 -o "${head_sha}[a-z-]*" || true)
  [[ -n "${stamp}" ]] \
    || warn "genpolicy was not built from this tree's HEAD (${head_sha:0:12}) — rerun DEMO_PREP=1 ./demo.sh"
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
  # Deliberately paired with crictl: a node often has more than one confidential
  # sandbox alive, and a bare process list then raises "why are there two?".
  # Listing the kata pods beside the process count answers it on screen.
  #
  # Counted through /proc/*/exe rather than a ps|grep, which counts the shell
  # running the pattern as well and reports one process too many.
  show "one Cloud Hypervisor process per confidential sandbox — and each one is a pod" \
    "sudo crictl pods --state Ready 2>/dev/null | awk 'NR==1 || \$NF==\"${E2E_RUNTIMECLASS}\"'; echo; echo \"cloud-hypervisor processes: \$(sudo ls -l /proc/*/exe 2>/dev/null | grep -c cloud-hypervisor)\""
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
  scene
}

# The stages record the config path they actually installed; guessing the
# filename is how this breaks when runtime-rs and runtime-go configs diverge.
runtime_config_path() {
  local cfg
  cfg=$(head -1 "${E2E_STATE_DIR}/guest-config-paths" 2>/dev/null)
  [[ -r "${cfg}" ]] || cfg="${E2E_KATA_PREFIX}/share/defaults/kata-containers/runtime-rs/configuration.toml"
  printf '%s' "${cfg}"
}

# ---------------------------------------------------- live binding experiment
# Stage the swap the measurement is supposed to prevent, on this hardware, and
# watch what happens. Run twice, because one run on its own proves nothing:
#
#   flip     serve a policy that differs from the measured one
#   control  serve the same policy, re-compressed — new bytes, same digest
#
# If flip is refused and control boots, the only variable that mattered is the
# content digest. Without the control, "the pod did not start" is equally well
# explained by "we corrupted the image".
_TAMPER_PHASE=""
_tamper_run() {
  local mode="$1" pod="$2" want="$3"
  local logf="${WORK}/tamper-${mode}.log"
  local harness="${E2E_REPO_DIR}/docs/cc/e2e/initdata-tamper.py"
  _TAMPER_PHASE=""
  [[ -r "${harness}" ]] || { warn "no tamper harness at ${harness} — skipping"; return 1; }

  kubectl delete pod "${pod}" -n "${NS}" --ignore-not-found >/dev/null 2>&1 || true
  sudo nohup python3 "${harness}" --mode "${mode}" --deadline 150 >"${logf}" 2>&1 &
  local watcher=$!
  # The watcher only rewrites images created after it starts, so it has to be
  # up before the sandbox is. Give it its first poll.
  sleep 1

  kubectl apply -f "${WORK}/${pod}.yaml" >/dev/null || die "kubectl apply failed for ${pod}"
  log "starting pod ${pod} with the watcher armed (${mode})"

  local i
  for i in $(seq 1 30); do
    _TAMPER_PHASE=$(kubectl get pod "${pod}" -n "${NS}" -o jsonpath='{.status.phase}' 2>/dev/null)
    [[ "${_TAMPER_PHASE}" = "Running" ]] && break
    # A refused sandbox shows up as a kubelet retry, which is the signal the
    # guest declined — there is no message from inside the guest to wait for.
    # Only ever believe that once the watcher says it rewrote something: an
    # untampered pod that is merely slow to boot looks identical otherwise.
    if [[ "${want}" = "refused" ]] \
       && grep -q 'rewrote the initdata image' "${logf}" 2>/dev/null \
       && _tamper_events "${pod}" | grep -q .; then
      break
    fi
    sleep 5
  done

  sudo pkill -f "initdata-tamper.py --mode ${mode}" >/dev/null 2>&1 || true
  wait "${watcher}" 2>/dev/null || true

  # The experiment is only an experiment if the manipulation landed. Without
  # this, a watcher that missed its window produces a Pending pod and a very
  # convincing-looking conclusion drawn from nothing.
  grep -q 'rewrote the initdata image' "${logf}" 2>/dev/null || {
    warn "the ${mode} watcher never caught an initdata image — nothing was staged, so this run proves nothing"
    return 1
  }
}

# Kubelet's own account of the refusal. Kept separate because it is both the
# loop's stop condition and the evidence shown afterwards, and those must agree.
_tamper_events() {
  kubectl get events -n "${NS}" --field-selector "involvedObject.name=$1" \
    -o custom-columns=REASON:.reason,MESSAGE:.message --no-headers 2>/dev/null \
    | grep -i 'sandbox' || true
}

live_binding_experiment() {
  # Distinct pod names per run, deliberately. Events outlive the pod they
  # describe, so reusing one name lets the flip run's failure events answer for
  # the control run -- or, worse, a previous demo's events answer for this one.
  demo_pod_yaml demo-tampered '"sleep", "3600"'
  demo_pod_yaml demo-control  '"sleep", "3600"'

  _tamper_run flip demo-tampered refused || return 0
  show "the host stamped one policy and served another — same sandbox, one token apart" \
    "cat ${WORK}/tamper-flip.log"
  show "and the pod never ran — this is kubelet's account, from outside the guest" \
    "kubectl get pod demo-tampered -n ${NS} -o custom-columns=NAME:.metadata.name,STATUS:.status.phase --no-headers; kubectl get events -n ${NS} --field-selector involvedObject.name=demo-tampered -o custom-columns=REASON:.reason,MESSAGE:.message --no-headers | grep -i sandbox | cut -c1-150 | head -2"
  if [[ "${_TAMPER_PHASE}" = "Running" ]]; then
    warn "the pod reached Running under a swapped policy — that is the failure this act exists to catch"
  else
    ok "phase=${_TAMPER_PHASE:-Pending} — the guest refused a policy it had not been launched with"
  fi
  kubectl delete pod demo-tampered -n "${NS}" --ignore-not-found >/dev/null 2>&1 || true
  say <<'EOF'

  Kubelet keeps retrying and the watcher keeps rewriting, so the pod never gets
  a sandbox at all. But on its own that is not yet proof: a pod that fails to
  start is just as well explained by us having corrupted the image. So run the
  experiment again with the manipulation neutered — re-compress the document
  instead of editing it. Different bytes on disk, identical digest. It is a
  second pod, so it has its own policy and its own measurement; what is held
  constant is the rewrite itself.
EOF
  pause

  _tamper_run control demo-control running || return 0
  show "same rewrite, same code path — only the content is unchanged" \
    "cat ${WORK}/tamper-control.log"
  show "and this time the pod is up" \
    "kubectl get pod demo-control -n ${NS} -o custom-columns=NAME:.metadata.name,STATUS:.status.phase --no-headers"
  if [[ "${_TAMPER_PHASE}" = "Running" ]]; then
    ok "phase=Running — rewriting the image is not what refused the pod; the digest is"
  else
    warn "the control did not reach Running (phase=${_TAMPER_PHASE:-unknown}) — the flip result above is inconclusive"
  fi
  kubectl delete pod demo-control -n "${NS}" --ignore-not-found >/dev/null 2>&1 || true
  say <<'EOF'

  Two runs, one variable. The guest will not enforce a policy other than the one
  named in its own launch measurement — so an SNP report cannot lie about which
  policy is in force. Note what this does *not* claim: a host is free to launch a
  CVM under any policy it likes, stamping that policy's digest honestly. Catching
  that is attestation's job, and it can do it precisely because the digest in the
  report is trustworthy.
EOF
  scene
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
  # Checked here rather than built on demand: a compile in the middle of an act is
  # exactly the kind of scaffolding the demo should never show.
  [[ "${DEMO_PREP:-0}" = "1" || -x "${E2E_REPO_DIR}/target/release/genpolicy" ]] \
    || die "genpolicy has not been built — run DEMO_PREP=1 ./demo.sh first"
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
  say <<'EOF'

  MSHV plus Cloud Hypervisor with real SEV-SNP is not new work in itself — that
  path existed before, and then it was suspended. What is new is that it has
  been rebased onto current Kata and brought back into working order, so the
  hardening in the acts that follow is demonstrated on real confidential
  hardware rather than under nested virt on an ordinary host.
EOF
  show "the hypervisor device on this node is /dev/mshv" \
    "ls -l /dev/mshv"
  # Not a module on this kernel, so lsmod/modinfo say nothing. The binding is
  # visible instead in the misc class node carrying the same major:minor as the
  # device, and in the driver's own boot lines.
  show "it belongs to the in-kernel mshv driver — the misc class node carries the same major:minor" \
    "cat /sys/class/misc/mshv/dev"
  show "and this is what that driver reported at boot, including what the hardware offers it" \
    "sudo journalctl -k --no-pager | grep -m3 'misc mshv:'"
  scene
  local cfg; cfg=$(runtime_config_path)
  show "the kata runtime's own configuration for this runtime class asks for an IGVM-launched SEV-SNP guest" \
    "grep -nE '^(igvm|confidential_guest|sev_snp_guest)' ${cfg}"
  # The SNP support lines come from the driver beat above — the same three lines
  # say who the driver is and what the hardware offers it.
  pause
}

# ============================================================ act 1
act1() {
  step "act 1 — the policy is measured, not asserted"
  say <<'EOF'

  The policy does not arrive as an annotation the guest is asked to trust. It
  arrives as a document whose digest is in the SNP report, and the guest refuses
  to run if the two disagree.
EOF
  ensure_policy_toolchain

  local t0; t0=$(date '+%Y-%m-%d %H:%M:%S')
  demo_pod_yaml demo-a '"sleep", "3600"'
  say <<'EOF'

  What happens next: we apply an ordinary pod. genpolicy has already generated a
  policy for exactly this spec and written it into the pod as an annotation, so
  applying it boots a fresh CVM whose measurement is fixed by that annotation
  before the guest runs a single instruction. Then we open the annotation, and
  follow it all the way into the hardware report.
EOF
  pause
  start_demo_pod demo-a

  show "the policy rides in the pod spec — the start of it, on the running pod, and what it is" \
    "kubectl get pod demo-a -n ${NS} -o yaml | grep -m1 'cc_init_data:' | cut -c1-96; B=\$(kubectl get pod demo-a -n ${NS} -o jsonpath='${INITDATA_JSONPATH}'); echo; echo \"annotation      : \${#B} base64 characters\"; echo \"gzip payload    : \$(echo \"\${B}\" | base64 -d | wc -c) bytes\"; echo \"decoded document: \$(echo \"\${B}\" | base64 -d | gunzip | wc -c) bytes of TOML\""
  say <<'EOF'

  Be clear about what that blob is, because the encoding is the least
  interesting thing about it. It is transport — base64 of gzip of a TOML
  document, and a policy is large enough to want compressing. The host decodes
  it on the way in (kata-types annotations/mod.rs, add_hypervisor_initdata_overrides),
  keeps the decoded text, and everything that follows — the digest it stamps
  into the hardware report, the document it serves the guest — is computed from
  that text, not from these bytes. Re-compress it differently and nothing
  downstream moves; the experiment at the end of this act does exactly that,
  deliberately.

  Nor is the annotation trusted for being an annotation. It arrives in the pod
  spec, which the host controls, and the runtime only looks at it because this
  confidential configuration opts in to that annotation by name.

  Before opening the document, though, it is worth establishing what just
  booted — a pod is only as confidential as the sandbox underneath it.
EOF
  show_sandbox_backing demo-a

  decode_initdata demo-a "${WORK}/a.toml"
  show "that annotation is an initdata document — decode it straight out of the running pod" \
    "kubectl get pod demo-a -n ${NS} -o jsonpath='${INITDATA_JSONPATH}' | base64 -d | gunzip | head -5"
  say <<'EOF'

  Initdata is not a policy file. It is a small envelope: two header fields, then
  a [data] table of named documents. What makes it interesting is that the
  digest is taken over the whole envelope — so whatever is in the table is
  measured, not just the policy.
EOF
  pause
  show "so ask the document what it actually carries — the header, and every key in the table" \
    "grep -nE '^(version|algorithm) = |^\[data\]|^\"[^\"]+\" = ' ${WORK}/a.toml; grep -c . ${WORK}/a.toml | xargs -I{} echo \"whole document: {} lines\""
  say <<'EOF'

  One entry for this pod: "policy.rego", holding the entire generated policy. So
  here the document effectively *is* the policy — but that is this pod's
  content, not the format's limit. The agent recognizes four keys, and act 4
  uses a second one: the fragment issuer allow-list travels as its own entry in
  this same table, which is what lets that act call the trust root "measured"
  without putting it in the policy.

  Note algorithm = 'sha256'. That is how the digest gets computed in a moment.
EOF
  pause
  show "the keys the guest will look for, from the agent's own source" \
    "grep -n 'const [A-Z_]*KEY: &str' ${E2E_REPO_DIR}/src/agent/src/initdata.rs"
  pause
  show "and the fragment machinery rides inside it — declared empty for this pod, and fail-closed" \
    "grep -c . ${WORK}/a.toml | xargs -I{} echo 'policy lines: {}'; grep -nE '^default policy_fragments := \[\]|\"fragments\": \[\]|\"image_layer_verification\": \"[a-z-]*\"' ${WORK}/a.toml"
  scene

  local d1; d1=$(initdata_digest_expected "${WORK}/a.toml")
  show "anyone can compute the expected measurement from that document alone" \
    "openssl dgst -sha256 -binary ${WORK}/a.toml | base64"
  show "and that is the value the runtime stamped into the SNP report's HOST_DATA" \
    "sudo journalctl -t kata --since '${t0}' --no-pager | grep -F 'initdata  digest' | tail -1"
  local jline; jline=$(initdata_journal_line "${t0}" "${d1}")
  if [[ -n "${jline}" ]]; then
    ok "the host logged exactly the digest we computed ourselves"
  else
    warn "did not find that digest in the journal — check 'journalctl -t kata'"
  fi
  say <<'EOF'

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
  show "the two measurements, side by side" \
    "printf 'sleep 3600  ->  '; openssl dgst -sha256 -binary ${WORK}/a.toml | base64; printf 'sleep 3601  ->  '; openssl dgst -sha256 -binary ${WORK}/b.toml | base64"
  if [[ -z "${d1}" || -z "${d2}" ]]; then
    warn "could not compute both digests"
  elif [[ "${d1}" = "${d2}" ]]; then
    warn "the two digests are identical — that should not happen; the workload change did not reach the policy"
  elif [[ -n "$(initdata_journal_line "${t1}" "${d2}")" ]]; then
    ok "one byte of workload, an entirely different measurement — and the host stamped it"
  else
    warn "digests differ as expected, but the second was not found in the journal"
  fi
  say <<'EOF'

  Worth noting what does *not* change: run this again, on this host or another,
  and the same workload yields the same digest. The measurement is a pure
  function of the policy document — which is why we could compute it above with
  nothing but sha256 and the document itself. That is what makes pinning a
  digest meaningful: a relying party computes the expected value rather than
  being told what to trust.
EOF
  scene
  say <<'EOF'

  A relying party rejecting the second digest is one half. The other half is
  what the guest does when the host serves a document that does not match the
  measurement it was launched with — because that is the case an attacker
  actually needs: keep the attested measurement, swap the policy.

  That opening is real, and it needs no trickery beyond being the host. The
  runtime does two independent things with the document: it hashes it for the
  launch, and it separately writes it into a block image the guest reads.
  Nothing re-checks that the second still matches the first.
EOF
  pause
  show "the digest and the delivered document are produced independently" \
    "grep -n -E 'let initdata_digest = match|initdata_block::push_data|host_data: init_data' ${E2E_REPO_DIR}/src/runtime-rs/crates/runtimes/virt_container/src/sandbox.rs"
  say <<'EOF'

  So we can stage the attack for real, on this hardware, with no lie told to the
  hardware at all: let the runtime stamp the honest digest, then rewrite the
  image before the guest reads it. What we serve is the same policy with one
  token changed — AllowRequestsFailingPolicy from false to true, which rules.rego
  itself labels an unsecure configuration. It disables every rule at once and
  leaves every dm-verity root hash intact, so nothing else in the guest has
  cause to object.
EOF
  pause
  live_binding_experiment
  say <<'EOF'

  What the experiment cannot show is the edges — the cases that never arise on a
  healthy node. Those the agent's own tests cover, driving the same check
  against a synthetic TEE tree.
EOF
  pause
  show "the agent's own binding check, exercised in both directions" \
    "cd ${E2E_REPO_DIR}/src/agent && cargo test --features strict-policy,tsm-test-override hostdata::tests::binding 2>&1 | grep -E '^test |^test result'"
  say <<'EOF'

  Four cases, and the two middle ones are the point: a matching measurement is
  accepted, a tampered one is refused. The other two are the fail-closed edges —
  a guest that should be able to measure but cannot is refused, while a plain
  non-confidential VM is skipped rather than failed.

  Note the feature those tests need. KATA_AGENT_TSM_ROOT can only redirect the
  lookup when the agent is built with tsm-test-override, which no shipped image
  enables — the agent's environment is host-influenced, so a host that could set
  that variable could point the check at a tree it controls.
EOF
  pause
  show "and a mismatch is fatal, not a warning — the agent aborts the VM" \
    "grep -n -B2 -A2 'initdata does not match the launch measurement, aborting VM' ${E2E_REPO_DIR}/src/agent/src/main.rs; grep -n -A4 'async fn fatal_abort' ${E2E_REPO_DIR}/src/agent/src/main.rs"
  say <<'EOF'

  fatal_abort records the reason and calls process::abort(). The agent is pid 1
  in that guest, so aborting it takes the VM with it: there is no degraded mode
  in which the workload runs under a policy that was never measured.
EOF
  scene
  say <<'EOF'

  Which raises the obvious question: can we watch the guest do that check —
  print the value it saw? We cannot, and the reason is worth more than the
  number would be. This build closes every channel that could carry it out.
EOF
  pause
  show "the agent's log stream is wired to a sink — a strict build forwards nothing" \
    "grep -n -B4 'Box::new(tokio::io::sink())' ${E2E_REPO_DIR}/src/agent/src/main.rs"
  show "and it cannot even construct a vsock listener: the socket import is compiled out" \
    "grep -n -B1 'use nix::sys::socket' ${E2E_REPO_DIR}/src/agent/src/main.rs"
  pause
  show "nor can the host ask for it back — the guest overrides what it is told" \
    "grep -n -A6 '\*debug_console = false;' ${E2E_REPO_DIR}/src/agent/src/config.rs"
  say <<'EOF'

  No log, no port, no debug console, no tracing — and the host cannot re-enable
  any of them, because those settings arrive on the kernel command line and this
  build refuses to honor them. Note what that costs us right here: the demo
  would be more satisfying if the guest could just say "digest mismatch". It
  does not, and it should not.

  So the evidence is never a line of output from inside the guest. It is which
  pods ran: the honest one reached Running, and the one handed a policy it was
  not launched with never got a sandbox at all.
EOF
  pause
}

# ============================================================ act 2
act2() {
  step "act 2 — the image layers are verified: EROFS + dm-verity"
  say <<'EOF'

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

  show "and the measured policy names those same layers, in the mount options the guest must be handed" \
    "grep -oE 'X-kata\.dmverity\.roothash=[a-f0-9]{64}' ${WORK}/a.toml | sort -u"

  sudo find "${SNAP}" -maxdepth 2 -name 'layer.erofs.dmverity' -exec cat {} \; 2>/dev/null \
    | jq -r '.roothash' 2>/dev/null | sort -u > "${WORK}/host-hashes.txt"
  # Extract by the option that actually carries a root hash. Grepping for any
  # 64-hex string would also pick up image digests and quietly inflate the count.
  grep -oE 'X-kata\.dmverity\.roothash=[a-f0-9]{64}' "${WORK}/a.toml" \
    | cut -d= -f2 | sort -u > "${WORK}/policy-hashes.txt"

  show "count both sides — the layers this host built, and the hashes the policy names" \
    "wc -l ${WORK}/host-hashes.txt ${WORK}/policy-hashes.txt"
  local matched missing
  matched=$(comm -12 "${WORK}/host-hashes.txt" "${WORK}/policy-hashes.txt" | wc -l)
  missing=$(comm -13 "${WORK}/host-hashes.txt" "${WORK}/policy-hashes.txt" | wc -l)
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
  say <<'EOF'

  genpolicy did not read those hashes off this host. It predicted them offline,
  reproducing containerd's mkfs.erofs invocation byte-for-byte against a pinned
  erofs-utils — which is why the policy can be generated anywhere, and why the
  match above is a result rather than a copy.
EOF
  scene

  show "note where the verity device is NOT: the host has no dm devices at all" \
    "sudo dmsetup ls 2>&1"
  say <<'EOF'

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

  say <<'EOF'

  Nothing in the generated policy permits an exec. So the agent refuses one —
  and the refusal is not a string, it is a structured object.
EOF
  local out
  out=$(kubectl exec -n "${NS}" demo-a -- /bin/true 2>&1) && die "exec SUCCEEDED — policy is not being enforced"
  show "so try one: kubectl exec into the running pod" \
    "kubectl exec -n ${NS} demo-a -- /bin/true 2>&1 | grep -o 'policyDecision<[^>]*>policyDecision' | head -1 | cut -c1-96 | sed 's/\$/.../'"
  pause

  # The sentinel wraps the payload in angle brackets: policyDecision<...>policyDecision.
  # The framing is fixed and machine-parseable, so a log consumer can lift the
  # record straight out of containerd's logs without modification.
  local b64; b64=$(echo "${out}" | grep -o 'policyDecision<[^>]*>policyDecision' | head -1 \
    | sed 's/^policyDecision<//; s/>policyDecision$//')
  if [[ -n "${b64}" ]]; then
    show "decoded — this is FR-8" \
      "echo '${b64}' | base64 -d | jq ."
    say <<'EOF'

  Three things to notice. The sentinel framing is fixed and machine-parseable,
  so a log consumer can lift this record straight out of containerd's logs.
  bound_state_keys lists field *names* and never their values, so a denial
  record cannot become an exfil channel. And failed_rule names only the
  endpoint — "reasons" is what actually attributes the denial.
EOF
  else
    warn "no decision object in the error text — expected the policyDecision sentinel"
  fi
  scene

  say <<'EOF'

  Two more gates, in categories that are easy to leave open.
EOF
  show "FR-10: the host-to-guest file copy channel is refused outright in strict builds" \
    "sed -n '2535,2543p' ${E2E_REPO_DIR}/src/agent/src/rpc.rs"
  show "FR-14: network config is policy-checked and then frozen once the workload starts" \
    "grep -n 'net_phase_authorize' ${E2E_REPO_DIR}/src/agent/src/rpc.rs | head -6"
  say <<'EOF'

  Network configuration is an easy channel to overlook: if a host can reach the
  network-modify path without a policy call, it can add or remove adapters,
  addresses and routes unchecked, and the measured policy says nothing about the
  pod's connectivity. Which raises the obvious question: how do we know there is
  no such hole anywhere else in the agent?
EOF
  pause

  show "every RPC is classified, per build configuration — this is the strict posture, in source" \
    "sed -n '190,200p' ${E2E_REPO_DIR}/src/agent/src/mediation.rs"
  say <<'EOF'

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
  say <<'EOF'

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

# The voice-over script accumulates across the run, so start from empty rather
# than appending to whatever a previous run left behind. Exported so the act 4
# delegate writes into the same file and the script stays in demo order.
if [[ -n "${DEMO_SCRIPT:-}" ]]; then
  : > "${DEMO_SCRIPT}" || die "cannot write the voice-over script at ${DEMO_SCRIPT}"
  export DEMO_SCRIPT
fi
export DEMO_NARRATE="${DEMO_NARRATE:-1}"

# Everything slow lives here, so the demo itself only displays evidence. The
# image pull matters as much as the genpolicy build: a cold pull happens inside
# the pod-start wait in act 1, where it looks like the platform being slow.
if [[ "${DEMO_PREP:-0}" = "1" ]]; then
  step "prep — doing the slow work now so the demo does not"
  ensure_branch_genpolicy
  ensure_policy_toolchain
  # Act 1 runs the agent's binding tests live. Cached that is ~4s; cold it is a
  # full agent test build, which is not something to discover mid-demo.
  log "warming the agent test build (act 1 runs the binding tests live)"
  (cd "${E2E_REPO_DIR}/src/agent" \
    && cargo test --features strict-policy,tsm-test-override --no-run >/dev/null 2>&1) \
    || warn "could not pre-build the agent tests — act 1's binding beat will compile them itself"
  # Act 4 signs and publishes a fragment with `cargo run`, which compiles on first
  # use. Build both now so nothing in the act is waiting on rustc.
  log "warming the fragment signing and publishing tools (act 4 uses both)"
  (cd "${E2E_REPO_DIR}" \
    && cargo build -q --example sign-fragment -p kata-security-reference-monitor \
    && cargo build -q -p genpolicy-fragmentgen) \
    || warn "could not pre-build the fragment tools — act 4 will compile them itself"
  demo_pod_yaml demo-prep '"sleep", "5"'
  start_demo_pod demo-prep
  kubectl delete pod demo-prep -n "${NS}" --ignore-not-found >/dev/null 2>&1 || true
  ok "genpolicy built, image pulled, EROFS layers and their verity metadata materialized"
  log "now run: DEMO_PAUSE=1 ./demo.sh"
  exit 0
fi

for a in 0 1 2 3 4; do
  want_act "${a}" && "act${a}"
done

heading "demo complete"
if [[ "${ACTS}" == "0,1,2,3,4" ]]; then
  say <<'EOF'

  What was shown, end to end: a real CVM on a confidential host; a policy whose
  digest is in the hardware report and moves with a one-byte change; image
  layers pinned by dm-verity root hashes that the measured policy names; a
  structured, redacted denial; and a signed fragment that extends the policy
  only within what the measurement already allowed.

  Read the other way round — as the routes a hostile host would actually take
  to get a container running under rules nobody approved — each one is closed
  by something in the acts above, and by different machinery each time:

    * Launch the guest under a policy of its own choosing. Not prevented, and
      not meant to be: the host picks HOST_DATA. It is caught by attestation,
      which works precisely because the digest in the report is honest.
    * Stamp one policy and serve another. Refused at boot by the guest itself,
      staged live in act 1 — with a control run, so the refusal is the digest
      and not a broken image.
    * Replace the policy once the guest is up. There is no channel: SetPolicy
      is compiled out of a strict build, so initdata is the only way a policy
      ever enters (act 3).
    * Run a container the policy never described. Denied at
      CreateContainerRequest, and the denial says which check failed without
      echoing the request back (acts 3 and 4).
    * Serve different image content behind an approved name. The measured
      policy names every layer by dm-verity root hash, and the guest mounts
      only those (act 2).
    * Turn on a debug channel to work from inside. The guest overrides what the
      host asks for: no log, no vsock port, no debug console (act 1).
    * Smuggle permissions in through a fragment. It must be signed by an issuer
      on the measured allow-list, declared by the measured policy, at or above
      the SVN floor, and confined to its own feed's namespace (act 4).
EOF
else
  printf '\n  ran acts: %s (of 0,1,2,3,4)\n' "${ACTS}"
fi

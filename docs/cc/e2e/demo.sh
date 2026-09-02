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
#   DEMO_SETTLE=1    seconds to hold before each command, so consecutive outputs
#                    read as separate beats on a recording (default: 1 under a
#                    conductor-driven take, 0 otherwise; set 0 to disable)
#   DEMO_CLEAR=0     keep the screen when paused (default: clear between beats,
#                    redrawing the act heading; scrollback is preserved)
#   DEMO_ACTS=0,2    run only these acts (default: 0,1,2,3,4)
#   DEMO_NARRATE=0   suppress the written prose, the [e2e] commentary and the
#                    [ ok] verdict lines, leaving the commands and their output
#                    — for narrating live over the top, or for a voice-over cut.
#                    warn/die are never suppressed
#   DEMO_HEADINGS=0  drop the act banners too (default: show them). Set alongside
#                    DEMO_NARRATE=0 when the spoken track already says where we
#                    are; the screen still clears between beats
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
: "${E2E_PLATFORM:=openvmm-snp}"
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

# Headings are structure for someone watching the script run. Under a voice-over
# cut they are neither: the spoken track already says where we are, and an act
# banner on screen is a second, competing title. DEMO_HEADINGS=0 drops the
# banners while leaving the clear between beats, which is layout, not commentary.
_heading_on() { [[ "${DEMO_HEADINGS:-1}" = "1" ]]; }

# lib.sh's log() carries commentary, not evidence — failures go through warn/die
# and results come from the commands themselves. So it follows the prose switch:
# under a voice-over cut these lines say aloud what the narration is already
# saying, on top of the footage it is spoken over.
#
# ok() goes with it, for a narrower reason. Every ok() in this script is drawn
# from state the beat has just put on screen — the pod table, the events, the
# two digests side by side — or from state track B is showing live. So on a
# narrated take it is a second voice reading out a result the viewer can see,
# and the raw output stays either way. warn() and die() do not follow it: those
# report that the demo did not do what it claims, which has to be visible.
eval "_lib_log() $(declare -f log | tail -n +2)"
log() { [[ "${DEMO_NARRATE:-1}" = "1" ]] || return 0; _lib_log "$@"; }
eval "_lib_ok() $(declare -f ok | tail -n +2)"
ok()  { [[ "${DEMO_NARRATE:-1}" = "1" ]] || return 0; _lib_ok "$@"; }

step() { _CUR_STEP="$*"; _demo_clear; _heading_on && _lib_step "$@"; _vo "$*"; return 0; }

# A heading that deliberately does not clear: for a section that reads the
# evidence still on screen. The closing summary sums up the act that just ran,
# so wiping it first would leave the summary unsupported.
heading() { _CUR_STEP="$*"; _heading_on && _lib_step "$@"; _vo "$*"; return 0; }

NS="${E2E_NS:-coco-e2e}"
ACTS="${DEMO_ACTS:-0,1,2,3,4}"
WORK=$(mktemp -d)
# Kubernetes events outlive the pod they describe (an hour, by default), and
# they are looked up by object name. A fixed pod name therefore lets a previous
# run's refusal answer for this one -- both as evidence on screen and, worse, as
# the stop condition act 1's experiment waits on. Tag the names per run.
RUN_TAG=$(date -u +%H%M%S)
trap '_verity_restore; rm -rf "${WORK}"; sudo pkill -f initdata-tamper.py >/dev/null 2>&1 || true; kubectl delete pod -n "${NS}" -l demo=parma --ignore-not-found >/dev/null 2>&1 || true; kubectl delete pod -n "${NS}" demo-frag-sidecar --ignore-not-found >/dev/null 2>&1 || true' EXIT

# Act 2 substitutes the root hash the host presents. That edits a file belonging
# to containerd's snapshotter, so it has to be put back even if the demo dies
# between the edit and the restore — hence a global, and a call from the trap.
SNAP=/var/lib/containerd/io.containerd.snapshotter.v1.erofs/snapshots
_VERITY_TARGET=""
_verity_restore() {
  [[ -n "${_VERITY_TARGET}" ]] || return 0
  sudo cp "${_VERITY_TARGET}.demobak" "${_VERITY_TARGET}" >/dev/null 2>&1 || true
  sudo rm -f "${_VERITY_TARGET}.demobak" >/dev/null 2>&1 || true
  _VERITY_TARGET=""
}

# The trap covers everything except SIGKILL and a hard reset — and if the restore
# never runs, the substituted hash stays on disk, where it breaks every later pod
# that mounts that layer, this demo's own included. The backup is enough to undo
# it, so undo it before anything else runs rather than debugging a mystery.
_verity_recover_stray() {
  local bak
  while read -r bak; do
    [[ -n "${bak}" ]] || continue
    sudo cp "${bak}" "${bak%.demobak}" >/dev/null 2>&1 || true
    sudo rm -f "${bak}" >/dev/null 2>&1 || true
    warn "put back a dm-verity root hash a previous run left substituted: ${bak%.demobak}"
  done < <(sudo find "${SNAP}" -maxdepth 2 -name 'layer.erofs.dmverity.demobak' 2>/dev/null)
}

# Two ways to hold after a beat. Interactively the keypress is the hold; on a
# hands-free take the hold before the next command does the same job, and lives
# in `_prompt` so it applies to every command rather than only the ones that
# reach here.
pause() {
  if [[ "${DEMO_PAUSE:-0}" = "1" ]]; then
    printf '\n    press Enter to continue '
    read -r _
    return 0
  fi
  # A shot-list take (demo-shots.sh) needs every command to stand alone in the
  # capture, because the cut is assembled shot by shot against a narration line.
  # So: hold the output long enough to be read, wipe the screen, and leave a
  # blank gap. The gap is the thing — an editor looking for the boundary between
  # two shots should find a run of identical blank frames, not a guess about
  # where one output stopped scrolling and the next started.
  [[ -n "${DEMO_HOLD:-}" ]] || return 0
  sleep "${DEMO_HOLD}"
  # Some shots argue one point together and have to be read as one screen — the
  # sandbox linkage is three commands, and splitting them turns a chain of
  # evidence into three unrelated outputs. DEMO_KEEP keeps the break (the next
  # command still types a second later) but not the wipe, so they accumulate.
  if [[ "${DEMO_KEEP:-0}" = "1" ]]; then
    sleep "${DEMO_GAP:-1}"
    return 0
  fi
  printf '\033[H\033[2J'
  sleep "${DEMO_GAP:-1}"
}

# Two kinds of break. `pause` holds while the audience reads something that
# belongs with what is already on screen; `scene` ends one line of argument and
# clears, so the next claim starts on a screen of its own. Beats that are
# evidence for the same claim have to stay together — clearing between the two
# halves of a comparison is how the comparison stops being one.
#
# `scene` does not pause: every command beat already holds after itself (see
# `show`), so pausing here too would ask for two keypresses at one break.
scene() {
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
# One highlighter for both acts and for the conductor's own segments, so the
# palette cannot drift between them — or from track B's inset, which follows
# the same rule: colour carries the verdict.
_HL="$(dirname "${BASH_SOURCE[0]}")/demo-hl.sh"

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
# One second before every command, on a conductor-driven take. Not in `pause`:
# that only covers beats that end by pausing, and a beat reached some other way
# (the first of an act, a launch that runs its own wait loop) then starts with
# the previous output still settling into frame — two commands read as one.
# Putting it here makes the break a property of running a command at all.
#
# Interactive runs already have the keypress; a hand-run act stays at full
# speed. DEMO_SETTLE overrides either way, and 0 disables it.
_settle() {
  [[ "${DEMO_PAUSE:-0}" != "1" ]] || return 0
  local s="${DEMO_SETTLE:-${DEMO_CUE_DIR:+1}}"
  if [[ -n "${s}" && "${s}" != "0" ]]; then sleep "${s}"; fi
}

_prompt() {
  _settle
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
  # Output goes through the highlighter so the word that decides the beat is
  # findable in the second the camera gives it. It is a no-op when stdout is not
  # a terminal, so captured runs stay plain.
  bash -c "$*" 2>&1 | bash "${_HL}"
  # One command per break. A beat that runs something always holds afterwards,
  # so two commands never scroll past between keypresses — the audience gets to
  # read every output before the next one replaces it as the thing on screen.
  pause
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
      image: ${E2E_BUSYBOX_IMAGE}
      command: [${cmd}]
EOF
  # Generating a policy takes a few seconds and prints nothing. Off screen that
  # is dead air in the middle of the narration; act 1 therefore shows it as a
  # beat of its own (see gen_policy_shown) rather than hiding it here.
  [[ "${3:-}" = "--defer" ]] && return 0
  gen_policy_for "${name}"
}

# Run genpolicy over a pod yaml, in place. It rewrites the file, adding the
# measured policy as an annotation.
gen_policy_for() {
  local name="$1"
  "${GENPOLICY}" -y "${WORK}/${name}.yaml" -p "${GP_RULES}" -j "${GP_SETTINGS}" >/dev/null \
    || die "genpolicy failed for ${name}"
  grep -q 'cc_init_data' "${WORK}/${name}.yaml" \
    || die "no cc_init_data annotation — genpolicy did not inject a measured policy"
}

# Same, but on screen: the spec that goes in, the command that produces the
# policy, and the annotation it leaves behind. The claim in the narration is that
# the policy is generated for this exact spec, so both ends of that are worth
# watching rather than asserting — the input especially, since it is otherwise
# written off screen and the audience has only our word for what was in it.
gen_policy_shown() {
  local name="$1" cue_gen="${2:-}"
  show "the input is an ordinary pod spec — no policy, no annotations, nothing measured yet" \
    "awk '{ l = \$0; if (l ~ /runtimeClassName:/) l = l \"        <-- act 0'\"'\"'s runtime class\"; print l }' ${WORK}/${name}.yaml"
  # Under a paced take the spec and the generated annotation are two different
  # sentences of narration, so they must not land on screen together.
  cue "${cue_gen}"
  show "generate the policy for this exact pod spec — genpolicy rewrites that file in place" \
    "${GENPOLICY} -y ${WORK}/${name}.yaml -p ${GP_RULES} -j ${GP_SETTINGS} && grep -c . ${WORK}/${name}.yaml | xargs -I{} echo \"${name}.yaml is now {} lines\""
  grep -q 'cc_init_data' "${WORK}/${name}.yaml" \
    || die "no cc_init_data annotation — genpolicy did not inject a measured policy"
  show "and this is what it added: the same spec, now carrying one new annotation" \
    "awk '{ l = \$0; if (length(l) > 78) l = substr(l,1,78) \"...\"; if (l ~ /cc_init_data:/) l = l \"   <-- the measured policy\"; print l }' ${WORK}/${name}.yaml"
}

start_demo_pod() {
  local name="$1"
  kubectl delete pod "${name}" -n "${NS}" --ignore-not-found >/dev/null 2>&1 || true
  # Shown rather than hidden: the audience should see the pod being created, and
  # by what command, not just a status line claiming it happened.
  _prompt "kubectl apply -f ${WORK}/${name}.yaml"
  kubectl apply -f "${WORK}/${name}.yaml" 2>&1 | bash "${_HL}" \
    || die "kubectl apply failed for ${name}"
  log "this boots a fresh SEV-SNP CVM, so it is not instant"
  wait_for 300 "pod ${name} Running" \
    bash -c "kubectl get pod ${name} -n ${NS} -o jsonpath='{.status.phase}' | grep -qx Running"
  # Same one-command-per-break rule as `show`: this ran a command of its own, so
  # it holds before the next one is typed.
  pause
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
# id: it appears in the shim's -id and again in the per-sandbox run directory the
# VMM was launched against, so the chain from pod to partition is something the
# audience can follow rather than something we assert.
# The VMM is whatever the recorded runtime config points at, so derive it rather
# than naming one. This demo has now run on both cloud-hypervisor and OpenVMM,
# and a hard-coded name does not fail loudly on the other — it counts zero
# processes and finds no pid, which reads on screen as "there is no VM here".
vmm_binary_name() {
  local p
  p=$(awk -F'"' '/^path = /{print $2; exit}' "$(runtime_config_path)" 2>/dev/null)
  [[ -n "${p}" ]] || return 1
  basename "${p}"
}

# The VMM process for one sandbox: every VMM keeps its per-sandbox state under
# /run/kata/<sid>/, but the socket's name is VMM-specific (ch-api.sock,
# openvmm.sock), so match the directory and confirm the process by its exe.
vmm_pid_for_sandbox() {
  local sid="$1" name="$2" p
  for p in $(pgrep -f "/run/kata/${sid}/" 2>/dev/null); do
    [[ "$(sudo readlink -f "/proc/${p}/exe" 2>/dev/null)" == *"/${name}" ]] && { printf '%s' "${p}"; return 0; }
  done
  return 1
}

show_sandbox_backing() {
  local name="$1"

  local sid
  sid=$(sudo crictl pods --name "${name}" --state Ready -o json 2>/dev/null | jq -r '.items[0].id // empty')
  if [[ -z "${sid}" ]]; then
    warn "could not resolve the sandbox id for ${name} — skipping the hypervisor linkage"
    return 0
  fi

  local vmm
  vmm=$(vmm_binary_name) || { warn "no VMM path in $(runtime_config_path) — skipping the hypervisor linkage"; return 0; }

  # Deliberately paired with crictl: a node often has more than one confidential
  # sandbox alive, and a bare process list then raises "why are there two?".
  # Listing the kata pods beside the process count answers it on screen.
  #
  # Counted through /proc/*/exe rather than a ps|grep, which counts the shell
  # running the pattern as well and reports one process too many.
  show "one ${vmm} process per confidential sandbox — and each one is a pod" \
    "sudo crictl pods --state Ready 2>/dev/null | awk 'NR==1 || \$NF==\"${E2E_RUNTIMECLASS}\"'; echo; echo \"${vmm} processes: \$(sudo ls -l /proc/*/exe 2>/dev/null | grep -c '/${vmm}\$')\""
  show "and the sandbox id is what ties this pod's shim to this pod's VM" \
    "ps -eo pid,args | grep '[${sid:0:1}]${sid:1:11}' | cut -c1-130"

  local vmmpid
  if ! vmmpid=$(vmm_pid_for_sandbox "${sid}" "${vmm}"); then
    warn "no ${vmm} process found for sandbox ${sid} — skipping the MSHV check"
    return 0
  fi
  # The fd table is the honest answer to "which hypervisor is this really?" —
  # a partition handle and a vCPU handle can only have come from /dev/mshv.
  show "that VM is driven by MSHV — a partition and a vCPU, and no KVM descriptor anywhere" \
    "sudo ls -l /proc/${vmmpid}/fd | awk '/mshv|kvm/{print \$NF}' | sort -u"
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

  # The launch is evidence, not setup. The substituted image is already staged
  # by the time this runs, so this apply *is* the experiment being performed —
  # and applying it silently left the screen empty for the whole boot, with the
  # narration describing a pod launch nobody could see happen.
  _prompt "kubectl apply -f ${WORK}/${pod}.yaml"
  kubectl apply -f "${WORK}/${pod}.yaml" 2>&1 | bash "${_HL}" \
    || die "kubectl apply failed for ${pod}"
  log "starting pod ${pod} with the watcher armed (${mode})"

  # The boot takes a minute or so, and nothing was on screen for any of it —
  # the narration described a substitution while the capture showed a finished
  # command and a cursor. The watcher writes what it did as it does it, so
  # follow that log through the wait: the rewrite, and the two digests that no
  # longer agree, appear while the sandbox is still coming up.
  #
  # The poll runs in the background so the follow can hold the screen; tail
  # exits on its own when the watcher does, and the watcher is killed as soon as
  # the verdict is in. `--pid` rather than a kill from here: a tail left writing
  # to the terminal after the shot has moved on corrupts the next one.
  (
    tries=0
    while (( tries < 30 )); do
      tries=$((tries + 1))
      [[ "$(kubectl get pod "${pod}" -n "${NS}" -o jsonpath='{.status.phase}' 2>/dev/null)" = Running ]] && break
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
  ) &
  local poller=$!

  _prompt "tail -f ${logf}"
  tail -f --pid="${watcher}" "${logf}" 2>/dev/null | bash "${_HL}"
  wait "${poller}" 2>/dev/null || true
  # Read back in this shell: the poll ran in a subshell and its copy of the
  # phase went with it.
  _TAMPER_PHASE=$(kubectl get pod "${pod}" -n "${NS}" -o jsonpath='{.status.phase}' 2>/dev/null)
  pause

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
  # Distinct pod names per run and per arm, deliberately: reusing one name lets
  # the flip run's failure events answer for the control run, or a previous
  # demo's events answer for this one. See RUN_TAG.
  local tpod="demo-tampered-${RUN_TAG}" cpod="demo-control-${RUN_TAG}"
  demo_pod_yaml "${tpod}" '"sleep", "3600"'
  demo_pod_yaml "${cpod}" '"sleep", "3600"'

  _tamper_run flip "${tpod}" refused || return 0
  # The boot and the rewrite ran under the hold; the evidence for them is the
  # next thing said, so it waits for it.
  cue S12
  # The watcher's log is no longer shown here: it is followed live through the
  # boot (see _tamper_run), so by this point the audience has already watched
  # the rewrite happen and the two digests diverge. Repeating it as a static
  # screen would be the same evidence twice.
  show "and the pod never ran — this is kubelet's account, from outside the guest" \
    "kubectl get pod ${tpod} -n ${NS} -o custom-columns=NAME:.metadata.name,STATUS:.status.phase --no-headers; kubectl get events -n ${NS} --field-selector involvedObject.name=${tpod} -o custom-columns=REASON:.reason,MESSAGE:.message --no-headers | grep -i sandbox | cut -c1-150"
  if [[ "${_TAMPER_PHASE}" = "Running" ]]; then
    warn "the pod reached Running under a swapped policy — that is the failure this act exists to catch"
  else
    ok "phase=${_TAMPER_PHASE:-Pending} — the guest refused a policy it had not been launched with"
  fi
  kubectl delete pod "${tpod}" -n "${NS}" --ignore-not-found >/dev/null 2>&1 || true
  say <<'EOF'

  Kubelet keeps retrying and the watcher keeps rewriting, so the pod never gets
  a sandbox at all — and the refusal is fatal rather than a warning. On a
  mismatch the agent records the reason and aborts; it is pid 1 in that guest,
  so aborting takes the VM with it. There is no degraded mode in which the
  workload runs under a policy that was never measured.

  Note what none of this claims: a host is free to launch a CVM under any policy
  it likes, stamping that policy's digest honestly. Catching that is
  attestation's job, and it can do it precisely because the digest in the report
  is trustworthy.
EOF
  pause
  if [[ "${DEMO_TAMPER_CONTROL:-0}" = "1" ]]; then
    _tamper_run control "${cpod}" running || return 0
    if [[ "${_TAMPER_PHASE}" = "Running" ]]; then
      ok "phase=Running — rewriting the image is not what refused the pod; the digest is"
    else
      warn "the control did not reach Running (phase=${_TAMPER_PHASE:-unknown}) — the flip result above is inconclusive"
    fi
    kubectl delete pod "${cpod}" -n "${NS}" --ignore-not-found >/dev/null 2>&1 || true
    pause
  fi
  scene
}

# ---------------------------------------------------------------- act 2
# Substitute the dm-verity root hash the *host* presents, leaving the measured
# policy alone, and let the guest answer. The runtime reads that hash out of a
# per-layer file in containerd's snapshotter, which the host owns outright — so
# staging this needs no exploit, only an edit.
#
# Writes ${WORK}/verity-denial.py, which lifts the guest's sentence back out of
# the kubelet event. That message embeds an escaped Rust string inside JSON, so
# it is unpicked in Python rather than in a pipeline of seds.
verity_substitution_experiment() {
  local pod=demo-verity
  local target_hash="" target_file="" best=0 f h sz

  # The layer to swap is the workload's: a hash the policy names, on the largest
  # image this host built. The pause container's layer would prove the same
  # thing about a less interesting image.
  while read -r f; do
    [[ -n "${f}" ]] || continue
    h=$(sudo jq -r '.roothash' "${f}" 2>/dev/null) || continue
    grep -qx "${h}" "${WORK}/policy-hashes.txt" 2>/dev/null || continue
    sz=$(sudo stat -c %s "$(dirname "${f}")/layer.erofs" 2>/dev/null || echo 0)
    if [[ "${sz}" -gt "${best}" ]]; then best="${sz}"; target_hash="${h}"; target_file="${f}"; fi
  done < <(sudo find "${SNAP}" -maxdepth 2 -name 'layer.erofs.dmverity' 2>/dev/null)

  if [[ -z "${target_file}" ]]; then
    warn "no layer on this host carries a root hash the policy names — skipping the substitution"
    return 0
  fi

  cat > "${WORK}/verity-denial.py" <<'PY'
import json, re, subprocess, sys

ns, pod = sys.argv[1], sys.argv[2]
out = subprocess.run(
    ["kubectl", "get", "events", "-n", ns,
     "--field-selector", "involvedObject.name=" + pod, "-o", "json"],
    capture_output=True, text=True).stdout
msgs = [i["message"] for i in json.loads(out).get("items", [])
        if "blocked by policy" in i.get("message", "")]
if not msgs:
    print("no policy denial recorded for this pod")
    raise SystemExit(1)

s = msgs[-1]
s = s[s.index("blocked by policy:"):].split("policyDecision<")[0]
s = s.replace('\\\\\\"', '"').replace('\\"', '"').replace('\\\\', '\\')

# The pod object carries no terminated.message for this failure, so the one-line
# reason has to come out of the same event as the detail below it.
if "--headline" in sys.argv:
    print("  " + s.split(" request presents")[0].rstrip(": "))
    raise SystemExit(0)

def short(t):
    return re.sub(r"([0-9a-f]{16})[0-9a-f]{48}", r"\1...", t)

groups = re.findall(r"(request presents|policy declares) \{(.*?)\}", s)
print("the guest refused CreateContainerRequest, and this is why:\n")
if groups:
    for label, body in groups:
        print("  %s" % label)
        for entry in re.findall(r'"([^"]+)"', body):
            print("    %s" % short(entry.rstrip("\\ ")))
        print()
    print("  (partition numbers restart at 1 for each container, and 'policy declares'")
    print("   covers every container in the policy — so a second partition 1 is the")
    print("   pause container's layer, not a duplicate)")
else:
    print("  " + short(s.strip()))
PY

  say <<EOF

  So try that. The policy stays exactly as it is — untouched, still measured,
  still the document whose digest is in the report. The only thing that changes
  is the number the host hands over at mount time.
EOF
  pause
  # The substitution itself is its own sentence of narration: hold here until it
  # is being spoken, or the flip lands on screen under the beat before it.
  cue S05
  show "the hash the runtime presents is read out of this file, which belongs to the host" \
    "sudo cat ${target_file}"


  sudo cp "${target_file}" "${target_file}.demobak" >/dev/null 2>&1 \
    || { warn "could not back the file up — skipping the substitution"; return 0; }
  _VERITY_TARGET="${target_file}"

  local first="${target_hash:0:1}" new tampered
  if [[ "${first}" = "0" ]]; then new=1; else new=0; fi
  tampered="${new}${target_hash:1}"

  show "flip one hex digit of it — the layer on disk is untouched, only the claim about it changes" \
    "sudo python3 -c \"import json,sys; p=sys.argv[1]; d=json.load(open(p)); d['roothash']=sys.argv[2]; open(p,'w').write(json.dumps(d)); print('presented root hash is now', sys.argv[2])\" ${target_file} ${tampered}"

  say <<EOF

  The policy still declares ${target_hash:0:16}...
  The host will now present  ${tampered:0:16}...

  Nothing else differs. The image is the one the policy was generated for, the
  command is the same, and every other layer still matches.
EOF
  pause

  demo_pod_yaml "${pod}" '"sleep", "300"'
  kubectl delete pod "${pod}" -n "${NS}" --ignore-not-found >/dev/null 2>&1 || true
  # The verdict and the reason for it are the last sentence of this act's
  # narration; the launch that produces them starts when that sentence does.
  cue S06
  _prompt "kubectl apply -f ${WORK}/${pod}.yaml"
  kubectl apply -f "${WORK}/${pod}.yaml" 2>&1 | bash "${_HL}" \
    || die "kubectl apply failed for ${pod}"
  log "the sandbox still boots — it is the container that has to be judged"
  wait_for_soft 180 "${pod} to reach a terminal state" \
    bash -c "kubectl get pod ${pod} -n ${NS} -o jsonpath='{.status.containerStatuses[0].state.terminated.reason}{.status.phase}' 2>/dev/null | grep -qE 'StartError|Failed'" \
    || true
  pause

  show "the pod's own account of what happened to that container, and why" \
    "kubectl get pod ${pod} -n ${NS} -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,CONTAINER:.status.containerStatuses[0].name,STATE:.status.containerStatuses[0].state.terminated.reason,EXIT:.status.containerStatuses[0].state.terminated.exitCode'; echo; python3 ${WORK}/verity-denial.py ${NS} ${pod} --headline"
  show "and the guest's answer in full" "python3 ${WORK}/verity-denial.py ${NS} ${pod}"
  show "where that sentence came from: the frame from the agent, the reason from the measured document itself" \
    "grep -n 'is blocked by policy: no policy container satisfied' ${E2E_REPO_DIR}/src/agent/policy/src/decision.rs; grep -o 'dm-verity layers: request presents.*' ${WORK}/a.toml | fold -s -w 100 | sed 's/^/  /'"
  say <<'EOF'

  The host did not compose that refusal, it relayed it. The sentence frame is
  written by the agent inside the guest, and the reason in it comes from the
  policy that was measured at launch — the second grep is act 1's decoded
  document, not a copy in the source tree. So the explanation for the refusal
  is covered by the same digest as the rule that produced it.
EOF
  pause

  local phase
  phase=$(kubectl get pod "${pod}" -n "${NS}" -o jsonpath='{.status.containerStatuses[0].state.terminated.reason}' 2>/dev/null)
  if [[ "${phase}" = "StartError" ]]; then
    ok "the container never started — one hex digit is the whole difference"
  else
    warn "expected StartError, got '${phase:-unknown}' — read the event above before believing this beat"
  fi

  _verity_restore
  kubectl delete pod "${pod}" -n "${NS}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  pause
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

# Best-effort variant for acts that can run standalone: act 4 shows act 1's
# document when it is there, and simply skips those beats when it is not. The
# strict version dies, and a `|| true` around it would not help — `die` exits.
decode_initdata_if_running() {
  local name="$1" out="$2"
  [[ "$(kubectl get pod "${name}" -n "${NS}" -o jsonpath='{.status.phase}' 2>/dev/null)" = Running ]] || return 0
  kubectl get pod "${name}" -n "${NS}" -o jsonpath="${INITDATA_JSONPATH}" \
    | base64 -d | gunzip > "${out}" 2>/dev/null || rm -f "${out}"
  return 0
}

# Same, but from a generated yaml rather than a running pod: act 1 opens the
# document before it applies anything, so that nothing about the format has to
# be taken on trust from a pod that has already booted.
decode_initdata_yaml() {
  local yaml="$1" out="$2"
  sed -n 's/^[[:space:]]*io\.katacontainers\.config\.hypervisor\.cc_init_data: //p' "${yaml}" \
    | base64 -d | gunzip > "${out}" 2>/dev/null \
    || die "could not decode initdata from ${yaml}"
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
  _verity_recover_stray
  ok "preflight: cluster, guest stack and source tree present"
}

# ============================================================ act 0
act0() {
  step "act 0 — this is a confidential host, and the guest is a real CVM"
  say <<'EOF'

  The stack underneath is OpenVMM on MSHV. That path is not new work in
  itself — it existed, and had been suspended; rebasing it onto current Kata and
  getting it running again is what this branch did. It is the reason everything
  that follows happens on a confidential machine rather than under nested virt.
EOF
  show "there is no KVM on this node — no device node, and no kvm module loaded" \
    "ls -l /dev/kvm 2>&1; lsmod | grep -E '^kvm' || echo '(no kvm module loaded)'"
  # mshv is not a module on this kernel, so lsmod/modinfo say nothing about it
  # either. The binding shows instead in the misc class node carrying the same
  # major:minor as the device, and in the driver's own boot lines.
  show "the hypervisor here is /dev/mshv, and it belongs to the in-kernel mshv driver — same major:minor" \
    "ls -l /dev/mshv; cat /sys/class/misc/mshv/dev"
  show "and this is what that driver reported at boot, including what the hardware offers it" \
    "sudo journalctl -k --no-pager | grep -m3 'misc mshv:'"
  scene
  local cfg; cfg=$(runtime_config_path)
  say <<'EOF'

  On top of that hardware this node runs an ordinary Kubernetes with containerd.
  The control plane is stock, and nothing in it treats confidential computing as
  a default: every pod so far is an ordinary pod on an ordinary runtime.

  What has been added to this node is a shim and a VMM sitting beside the
  default ones, plus a name that selects them. Nothing reaches them unless a pod
  asks, so up to this point nothing says which pods get any of this.

  That is what a runtime class is: a name a pod asks for, which containerd
  resolves to a shim of its own rather than the default one.
EOF
  show "workloads opt into this stack by name — the runtime class the rest of this demo uses" \
    "kubectl get runtimeclass ${E2E_RUNTIMECLASS}"
  show "containerd resolves that handler to a shim of its own, and to one config file" \
    "grep -n -A12 'runtimes.${E2E_RUNTIMECLASS}\]' /etc/containerd/config.toml | grep -E 'runtimes\.${E2E_RUNTIMECLASS}\]|runtime_type|snapshotter|ConfigPath'"
  show "that is this file — and the VMM it tells that shim to drive" \
    "grep -nE '^\[hypervisor\.|^path = ' ${cfg} | head -2"
  show "and the same config asks that VMM for an IGVM-launched SEV-SNP guest" \
    "grep -nE '^(igvm|confidential_guest|sev_snp_guest)' ${cfg}"
  # The SNP support lines come from the driver beat above — the same three lines
  # say who the driver is and what the hardware offers it.
  say <<'EOF'

  One thing left to place before any of the rest can be read: where enforcement
  actually happens.

  Inside that guest, pid 1 is the kata agent. It is what the shim talks to —
  over a vsock, in ttRPC — and every request to create a container, mount a
  layer, exec a process or configure the network arrives there as a call. The
  agent carries a policy engine, and each of those calls is answered against a
  policy document before it is served.

  So there are two sides to keep apart for the rest of this demo. Everything
  left of the boundary below is host-controlled and untrusted — it is what the
  hardware is protecting the guest from. Every gate that follows is enforced on
  the right, by the guest, on requests the host is making.

    outside the guest — untrusted     ║      inside the guest — trusted
                                      ║
      kubelet                         ║        kata-agent (pid 1)
         │                            ║             │
      containerd                      ║        policy engine
         │                            ║             │
      kata shim ── ttRPC over vsock ──╫──▶   allow / deny
         │                            ║             ▲
      OpenVMM on MSHV                 ║             │
         └─ launches the CVM;         ║        the measured policy
            cannot see inside it      ║
EOF
  pause
}

# ============================================================ act 1
act1() {
  step "act 1 — the policy is measured, not asserted"
  ensure_policy_toolchain

  say <<'EOF'

  How a policy is built and measured is existing mechanism, and the first half
  of this act simply follows it: genpolicy turns a pod spec into a policy,
  initdata carries that policy into the guest, and the runtime stamps its digest
  into the hardware report at launch. genpolicy is Kata's; initdata comes from
  the wider Confidential Containers project — a small TOML document of named
  entries plus the hash algorithm to digest them with, which Kata fills in.

  The second half goes where that mechanism stops — to the question of whether
  the document the guest is handed has to be the document that digest was taken
  over.
EOF
  pause

  local t0; t0=$(date '+%Y-%m-%d %H:%M:%S')
  demo_pod_yaml demo-a '"sleep", "3600"' --defer
  gen_policy_shown demo-a S08

  # Opened from the file, before anything is applied: the format is worth
  # understanding on its own, and a running pod would only add the question of
  # whether what we are reading is what the pod got.
  decode_initdata_yaml "${WORK}/demo-a.yaml" "${WORK}/a-pre.toml"
  show "that annotation is a document in transport form — base64 of gzip" \
    "B=\$(sed -n 's/^[[:space:]]*io\.katacontainers\.config\.hypervisor\.cc_init_data: //p' ${WORK}/demo-a.yaml); echo \"annotation      : \${#B} base64 characters\"; echo \"gzip payload    : \$(echo \"\${B}\" | base64 -d | wc -c) bytes\"; echo \"decoded document: \$(echo \"\${B}\" | base64 -d | gunzip | wc -c) bytes\""
  say <<'EOF'

  The encoding is transport, and that is all. The host decodes it on the way in,
  and everything downstream — the digest it stamps into the hardware report, the
  document it serves the guest — is computed from that decoded text, not from
  these bytes. Re-compress the same document differently and the digest does not
  move.

  Nor is it trusted for being an annotation. It arrives in the pod spec, which
  the host controls, and the runtime looks at it only because this confidential
  configuration opts in to that annotation by name.
EOF
  pause
  show "so decode it — those 150 kilobytes are TOML, and the format has a name: initdata" \
    "head -5 ${WORK}/a-pre.toml"
  say <<'EOF'

  Initdata is not a policy file. It is a small envelope: two header fields, then
  a [data] table of named documents. What makes it interesting is that the
  digest is taken over the whole envelope — so whatever is in the table is
  measured, not just the policy.
EOF
  show "so ask the document what it actually carries — the header, and every key in the table" \
    "grep -nE '^(version|algorithm) = |^\[data\]|^\"[^\"]+\" = ' ${WORK}/a-pre.toml; grep -c . ${WORK}/a-pre.toml | xargs -I{} echo \"whole document: {} lines\""
  say <<'EOF'

  One entry for this pod: "policy.rego", holding the entire generated policy. So
  here the document effectively *is* the policy — but that is this pod's
  content, not the format's limit. The agent recognizes four keys, and act 4
  uses a second one: the fragment issuer allow-list travels as its own entry in
  this same table, which is what lets that act call the trust root "measured"
  without putting it in the policy.

  Note algorithm = 'sha256'. That is how the digest gets computed later in this
  act.
EOF
  show "and that one entry, policy.rego, has a shape of its own — one rule per request the agent can be asked to serve" \
    "grep -E '^default [A-Za-z]+Request' ${WORK}/a-pre.toml | head -12; echo; grep -cE '^default ' ${WORK}/a-pre.toml | xargs -I{} echo \"{} default rules in all — the guest's whole API surface, each answered before it is asked\""
  say <<'EOF'

  That is the shape of the thing being measured: not a list of permissions, but
  a decision for every request the agent can receive, defaulting to refusal. The
  entries generated for this pod then turn specific ones on — for this image,
  this command, these mounts.

  So the policy is not a document the pod author wrote and the guest is asked to
  trust. It is derived from this exact spec, and it rides back in the spec.

  What happens next: applying that pod spec, with its initdata annotation, boots
  a fresh CVM whose measurement is fixed by that annotation before the guest
  runs a single instruction. Then we follow it all the way into the hardware
  report — where a disagreement is refused, not reported.
EOF
  pause
  start_demo_pod demo-a

  decode_initdata demo-a "${WORK}/a.toml"
  scene

  # The digest comes before the sandbox it was stamped for. Both orders make
  # sense read as a script, but only this one matches the narration: the words
  # follow the document into the hardware report first, and only then ask what
  # is running underneath.
  cue S09
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
  # The exec cut has no narration for this comparison — moment 3 goes from the
  # digest in the report straight to what is running underneath — so in that cut
  # it plays as a pod launch and a digest pair with nothing said about either.
  # It stays in the full demo, where the prose on both sides of it is spoken.
  if [[ "${DEMO_EXEC:-0}" != "1" ]]; then
  say <<'EOF'

  Now the point of the whole exercise. The workload here is the command the pod
  starts its container with, and we change one byte of it — the container's
  startup command goes from sleep 3600 to sleep 3601. That is the entire
  difference: same image, same everything else. The measurement moves anyway,
  because that command is part of the policy that gets hashed. A relying party
  pinned to the first digest rejects the second.
EOF
  pause

  local t1; t1=$(date '+%Y-%m-%d %H:%M:%S')
  demo_pod_yaml demo-b '"sleep", "3601"'
  start_demo_pod demo-b
  decode_initdata demo-b "${WORK}/b.toml"
  local d2; d2=$(initdata_digest_expected "${WORK}/b.toml")
  show "the two measurements, side by side" \
    "printf 'demo-a  sleep 3600  ->  '; openssl dgst -sha256 -binary ${WORK}/a.toml | base64; printf 'demo-b  sleep 3601  ->  '; openssl dgst -sha256 -binary ${WORK}/b.toml | base64"
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
  pause
  fi   # end of the workload-change comparison, full demo only
  scene

  # Moved here from just after demo-a booted. A pod is only as confidential as
  # the sandbox underneath it, and this is where the narration asks what that
  # is — after the document has been followed all the way into the report.
  cue S10
  say <<'EOF'

  So much for the document. What is actually running under it: the layers this
  pod's measured policy admits, with the root hashes it names for them, and the
  OpenVMM process serving the VM they are mounted in.
EOF
  show "the layers demo-a's measured policy admits, by the root hash it names for each" \
    "grep -oE 'X-kata\\.dmverity\\.roothash=[a-f0-9]{64}' ${WORK}/a.toml | cut -d= -f2 | sort -u | nl -w4 -s '  layer  ' | sed 's/\\([0-9a-f]\\{16\\}\\)[0-9a-f]*/\\1.../'"
  show_sandbox_backing demo-a

  say <<'EOF'

  A relying party rejecting the second digest is one half. The other half is
  what the guest does when the host serves a document that does not match the
  measurement it was launched with — because that is the case an attacker
  actually needs: keep the attested measurement, swap the policy.

  That opening is real, and it needs no trickery beyond being the host. The
  runtime does two independent things with the document: it hashes it for the
  launch, and it separately writes it into a block image the guest reads. Both
  happen on the host, and nothing on that side re-checks that the second still
  matches the first.

  So the guest has to. This branch makes the agent recompute the digest of the
  initdata it was actually served and compare it against the launch measurement
  the host stamped it into — on this hardware, HOST_DATA, read back out of an
  SNP report the PSP produced rather than anything the host can write. That
  comparison runs before any consumer of the document, and it is what the rest
  of this act puts on trial.
EOF
  pause
  say <<'EOF'

  So we can stage the attack for real, on this hardware, with no lie told to the
  hardware at all: let the runtime stamp the honest digest, then rewrite that
  block image — the one carrying the policy — before the guest reads it. What we
  serve is the same policy with one character changed, inside a comment — no
  rule touched, no check disabled,
  every dm-verity root hash intact, so nothing in the guest has any cause to
  object to it except the binding itself.

  A nastier edit would prove nothing extra. The guest aborts before the document
  it was served is ever evaluated, so what a swapped policy *says* never gets a
  chance to matter. What is on trial here is whether the served bytes have to be
  the measured bytes.

  What follows is a real pod launch: a fresh SEV-SNP CVM boots under the
  rewritten image, so expect a wait with nothing on screen.
EOF
  pause
  # The tamper needs a fresh CVM to boot before it can be refused, and that wait
  # is silent — so it starts under S11, the hold, and S12 releases the verdict
  # once the words about it begin. Starting it at S12 instead would run the
  # whole boot inside a seven-second line of narration.
  cue S11
  live_binding_experiment
}

# ============================================================ act 2
act2() {
  step "act 2 — the image layers are verified: EROFS + dm-verity"
  say <<'EOF'

  A measured policy is only as good as its grip on what actually gets mounted.

  Kata already mounts read-only image layers through dm-verity: containerd's
  snapshotter builds each layer as an EROFS image with a root hash, and the
  guest kernel checks every block read against it. What that proves is that a
  layer's contents match the hash it was mounted with — content against digest,
  and nothing more.

  What it does not say is where that hash came from. The host supplies it, and
  a host serving its own layer can supply the matching hash to go with it: verity
  passes, and an attacker's filesystem is mounted read-only and perfectly intact.
  The kernel was never asked the question that matters, which is whether the
  digest is one the tenant approved.

  That question is what this branch adds. The measured policy names the root
  hashes the pod is allowed to mount, and a layer arriving under any other hash
  is refused before it is mounted. The rest of this act shows the naming, and
  then breaks it.
EOF
  [[ -s "${WORK}/a.toml" ]] || { ensure_policy_toolchain; demo_pod_yaml demo-a '"sleep", "3600"'; start_demo_pod demo-a; decode_initdata demo-a "${WORK}/a.toml"; }

  show "containerd built each layer as an EROFS image in its snapshotter store, with verity metadata beside it" \
    "sudo find ${SNAP} -maxdepth 2 \\( -name 'layer.erofs' -o -name 'layer.erofs.dmverity' \\) | sort"
  # Print every layer, not a head-truncated sample: the next beat lists the hashes
  # the policy names, and a cut-off list makes one of them look absent from the host.
  show "and this is the root hash of every layer on this host — not just this pod's" \
    "sudo find ${SNAP} -maxdepth 2 -name 'layer.erofs.dmverity' | sort | while read -r f; do printf '  snapshot %-5s %s...\\n' \"\$(basename \$(dirname \$f))\" \"\$(sudo jq -r .roothash \$f | cut -c1-16)\"; done"

  # Partition numbers are per container, so two containers each have a partition 1.
  # Printing the hashes flat makes the agent's denial message (which unions them into
  # one set) look like it is contradicting itself.
  cat > "${WORK}/policy-layers.py" <<'PYEOF'
import json, sys
t = open(sys.argv[1]).read()
j = t.index("{", t.index("policy_data := {"))
d = 0
for k in range(j, len(t)):
    if t[k] == "{":
        d += 1
    elif t[k] == "}":
        d -= 1
        if d == 0:
            end = k + 1
            break
for n, c in enumerate(json.loads(t[j:end])["containers"], 1):
    img = c.get("OCI", {}).get("Annotations", {}).get("io.kubernetes.cri.image-name") \
        or "the pause container (sandbox infrastructure)"
    if "@sha256:" in img:
        repo, dig = img.split("@sha256:", 1)
        img = "%s@sha256:%s..." % (repo, dig[:12])
    print("  container %d - %s" % (n, img))
    for s in c.get("storages", []):
        if s.get("driver") != "erofs-verity-layer":
            continue
        o = dict(x.split("=", 1) for x in s.get("options", []) if "=" in x)
        print("      partition %s = %s..." % (o.get("X-kata.partition-number", "?"),
                                              o.get("X-kata.dmverity.roothash", "?")[:16]))
PYEOF
  show "and the measured policy — demo-a's initdata, decoded — names only the ones this pod may mount" \
    "python3 ${WORK}/policy-layers.py ${WORK}/a.toml"

  sudo find "${SNAP}" -maxdepth 2 -name 'layer.erofs.dmverity' -exec cat {} \; 2>/dev/null \
    | jq -r '.roothash' 2>/dev/null | sort -u > "${WORK}/host-hashes.txt"
  # Extract by the option that actually carries a root hash. Grepping for any
  # 64-hex string would also pick up image digests and quietly inflate the count.
  grep -oE 'X-kata\.dmverity\.roothash=[a-f0-9]{64}' "${WORK}/a.toml" \
    | cut -d= -f2 | sort -u > "${WORK}/policy-hashes.txt"

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

  say <<'EOF'

  genpolicy did not read those hashes off this host. It predicted them offline,
  reproducing containerd's mkfs.erofs invocation byte-for-byte against a pinned
  erofs-utils — which is why the policy can be generated anywhere, and why the
  match above is a result rather than a copy.

  It also means the policy and the host arrive at those hashes independently.
  So the interesting question is what happens when they disagree.
EOF
  pause
  scene

  verity_substitution_experiment

  say <<'EOF'

  The host built these layers, so it has the bytes and could read them at any
  time — that is not what dm-verity is for. It hands them to the guest, and the
  guest kernel mounts them with dm-verity and enforces the root hash on every
  block read, so the host cannot change what it handed over without the guest
  noticing. And the hash the guest enforces has to be one the measured policy
  named, or the container is refused before any mount happens.

  Those are two different checks doing two different jobs. The kernel proves
  contents against digest. The policy proves that digest was approved. Kata
  brought the first; the second is what closes the gap, and it is covered by
  the attestation because it lives in the measured document.
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
  [[ -s "${WORK}/a.toml" ]] || decode_initdata demo-a "${WORK}/a.toml"

  say <<'EOF'

  Back to act 1's default rules: every request the agent can serve starts at
  false, and genpolicy only turns on the ones this pod's spec justifies.

  That posture is worth saying plainly, because it is not what the stock guest
  does. The default policy shipped in the upstream rootfs is allow-all — a guest
  that boots without a policy of its own serves whatever it is asked. This build
  compiles the closed door into the agent binary instead, so it does not depend
  on which policy file a host chose to point it at, and the escape hatch that
  let requests through when the policy failed to answer is compiled out too.

  Nobody asked to exec into this pod, so ExecProcessRequest was never turned on.
EOF
  show "the rule that decides it, in this pod's own measured policy" \
    "grep -nE '^default ExecProcessRequest' ${WORK}/a.toml; grep -cE '^ExecProcessRequest' ${WORK}/a.toml | xargs -I{} echo '{} conditional rules could turn it on — this exec matched none of them'"
  say <<'EOF'

  So the agent refuses — and the refusal is not a string, it is a structured
  object.
EOF
  local out
  out=$(kubectl exec -n "${NS}" demo-a -- /bin/true 2>&1) && die "exec SUCCEEDED — policy is not being enforced"
  show "so try one: kubectl exec into the running pod" \
    "kubectl exec -n ${NS} demo-a -- /bin/true 2>&1 | grep -o 'policyDecision<[^>]*>policyDecision' | head -1 | cut -c1-96 | sed 's/\$/.../'"

  # The sentinel wraps the payload in angle brackets: policyDecision<...>policyDecision.
  # The framing is fixed and machine-parseable, so a log consumer can lift the
  # record straight out of containerd's logs without modification.
  local b64; b64=$(echo "${out}" | grep -o 'policyDecision<[^>]*>policyDecision' | head -1 \
    | sed 's/^policyDecision<//; s/>policyDecision$//')
  if [[ -n "${b64}" ]]; then
    show "decoded — the denial the guest produced, as a structured record" \
      "echo '${b64}' | base64 -d | jq ."
    say <<'EOF'

  Three things to notice. The framing is fixed and machine-parseable, so a log
  consumer can lift this record straight out of containerd's logs.
  bound_state_keys lists field *names* and never their values, so a denial
  record cannot become an exfil channel. And failed_rule names only the
  endpoint — "reasons" is what attributes the denial.
EOF
    pause
  else
    warn "no decision object in the error text — expected the policyDecision sentinel"
  fi
  scene

  say <<'EOF'

  Three more gates, in categories that are easy to leave open.
EOF
  show "the host-to-guest file copy channel is refused outright in strict builds" \
    "sed -n '2535,2543p' ${E2E_REPO_DIR}/src/agent/src/rpc.rs"
  show "network config is policy-checked, then frozen once the workload starts" \
    "grep -n 'net_phase_authorize' ${E2E_REPO_DIR}/src/agent/src/rpc.rs | head -6"
  show "and the settings a host could use to open a way in are fixed by the guest, whatever it asked for" \
    "grep -nE '^\\s+\\*(debug_console|debug_console_vport|dev_mode|log_level|log_vport|tracing|secure_storage_integrity) = ' ${E2E_REPO_DIR}/src/agent/src/config.rs"
  say <<'EOF'

  The host chooses every one of those — on the kernel command line, in a config
  file, or in the agent's environment. A debug console is a shell into the guest
  that no policy sees, and tracing ships request payloads back out. So a strict
  guest sets them itself rather than accepting what it was handed.

  And it has to say something about each one: the code names every setting
  individually, so a new one will not compile until someone decides whether a
  confidential guest may honour it.
EOF
  pause
  say <<'EOF'

  Network configuration is easy to overlook: a host that can reach the
  network-modify path without a policy call can add or remove adapters,
  addresses and routes unchecked, and the measured policy says nothing about the
  pod's connectivity. Which raises the obvious question — how do we know there
  is no such hole anywhere else in the agent?
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

  A measured policy is fixed at launch. That is the point of it, and it is also
  its limit: anything the pod turns out to need later has no way in. Upstream
  the answer was SetPolicy, a host-facing call that replaced the policy wholesale
  — which act 3 just showed compiled out of this build.

  Fragments are what replaces it, and they are new here. A fragment extends a
  measured policy without invalidating the measurement: the launch digest never
  moves, and the extension is signed by an issuer the measured document already
  named and bounded by what that document already permits. Add-only, and only
  within limits fixed before the guest booted.

  Which means the machinery has to live in the measured document itself. It
  already does — act 1's pod carries it, declared empty.
EOF
  [[ -s "${WORK}/a.toml" ]] || decode_initdata_if_running demo-a "${WORK}/a.toml"
  if [[ -s "${WORK}/a.toml" ]]; then
    show "the keys the guest will look for in that document, from the agent's own source" \
      "grep -n 'const [A-Z_]*KEY: &str' ${E2E_REPO_DIR}/src/agent/src/initdata.rs"
    show "and act 1's pod declared no fragments at all — which is a decision, not a gap" \
      "grep -nE '^default policy_fragments := \[\]|\"fragments\": \[\]' ${WORK}/a.toml"
    say <<'EOF'

  aa.toml and cdh.toml carry attestation configuration, policy.rego is the
  policy itself, and fragment-issuers.toml is the allow-list this act turns on.
  Whoever signs a fragment, an empty list is an empty list — so act 1's pod
  could not have had anything added to it at runtime. What follows is a pod
  that names an issuer.
EOF
  fi
  pause
  # Steps 1-2 only need a running pod whose measured policy declares no
  # fragments; act 1 already left one. Handing it over saves a CVM boot and
  # makes the continuity explicit.
  DEMO_PAUSE="${DEMO_PAUSE:-0}" E2E_BASE_POD=demo-a \
    bash "$(dirname "${BASH_SOURCE[0]}")/demo-fragment-sidecar.sh"
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
    && cargo build -q --example mock-ledger -p kata-security-reference-monitor \
    && cargo build -q -p genpolicy-fragmentgen) \
    || warn "could not pre-build the fragment tools — act 4 will compile them itself"
  # Act 4 step 5 delivers a fragment over the sandbox's own vsock. agent-ctl is a
  # cold build of several minutes, so it never happens during an act.
  log "building kata-agent-ctl (act 4 delivers a fragment over ttRPC by hand)"
  (cd "${E2E_REPO_DIR}/src/tools/agent-ctl" && cargo build --release >/dev/null 2>&1) \
    || warn "could not build kata-agent-ctl — act 4's receipt step will refuse to start"
  demo_pod_yaml demo-prep '"sleep", "5"'
  start_demo_pod demo-prep
  kubectl delete pod demo-prep -n "${NS}" --ignore-not-found >/dev/null 2>&1 || true
  ok "genpolicy built, image pulled, EROFS layers and their verity metadata materialized"
  log "now run: DEMO_PAUSE=1 ./demo.sh"
  exit 0
fi

if [[ "${ACTS}" == "0,1,2,3,4" ]]; then
  step "what this demo is testing"
  say <<'EOF'

  Confidential containers exist for one reason: to run a workload on a machine
  whose operator you do not trust. The hardware encrypts the guest's memory and
  attests what it booted, so the host cannot read the workload as it runs.

  But the host is still the thing that starts that workload, supplies its
  images, and answers it at runtime. Encrypted memory says nothing about *what*
  was started. A host that can decide what runs inside the guest does not need
  to read anything — it can simply run something of its own choosing and be
  handed the secrets by the workload itself.

  So the question here is narrower than "is the VM confidential". It is whether
  what runs inside has been fixed in advance, and tied to something the hardware
  will vouch for.

  The answer takes the form of a policy: a document generated from the pod spec,
  measured into the launch, and enforced inside the guest on every request the
  host makes. Kata already has that shape. Whether it holds against a host that
  is actively hostile, rather than merely uninvolved, is what follows — one
  route at a time, on real SEV-SNP hardware, in five acts. Each act is
  introduced as it begins.
EOF
  pause
fi

for a in 0 1 2 3 4; do
  want_act "${a}" && "act${a}"
done

pause
heading "demo complete"
if [[ "${ACTS}" == "0,1,2,3,4" ]]; then
  say <<'EOF'

  What was shown, end to end: a real CVM on a confidential host; a policy whose
  digest is in the hardware report and moves with a one-byte change; image
  layers pinned by dm-verity root hashes that the measured policy names, and a
  substituted hash refused; a structured, redacted denial; and a signed fragment
  that extends the policy only within what the measurement already allowed.

  The shape of most of this was already there: the runtime class, genpolicy,
  dm-verity layers and a policy engine in the agent from Kata, and initdata and
  its digest from the wider Confidential Containers project. What this
  branch adds is the part that makes each one hold against a host that is
  actively hostile rather than merely uninvolved — the guest checking what it
  was served against what was measured, the approved-digest test on every layer,
  a closed door compiled into the binary with the mutation channel removed, and
  a signed, versioned, bounded way to extend a policy that is already fixed.

  Read the other way round — as the routes a hostile host would actually take
  to get a container running under rules nobody approved — each one is closed
  by something in the acts above, and by different machinery each time:

    * Launch the guest under a policy of its own choosing. Not prevented, and
      not meant to be: the host picks HOST_DATA. It is caught by attestation,
      which works precisely because the digest in the report is honest.
    * Stamp one policy and serve another. Refused at boot by the guest itself,
      staged live in act 1.
    * Replace the policy once the guest is up. There is no channel: SetPolicy
      is compiled out of a strict build, so initdata is the only way a policy
      ever enters (act 3).
    * Run a container the policy never described. Denied at
      CreateContainerRequest, and the denial says which check failed without
      echoing the request back (acts 3 and 4).
    * Serve different image content behind an approved name. The measured
      policy names every layer by dm-verity root hash, and a layer presented
      under any other hash is refused — staged live in act 2, by changing one
      hex digit of what the host hands over.
    * Turn on a debug channel to work from inside. The guest overrides what the
      host asks for: no debug console, no log listener, no tracing exporter
      (act 3).
    * Smuggle permissions in through a fragment. It must be signed by an issuer
      on the measured allow-list, declared by the measured policy, at or above
      the SVN floor, and confined to its own feed's namespace (act 4).
EOF
else
  # A note to whoever ran a subset, and so commentary: it follows DEMO_NARRATE
  # like the rest of the prose, because on a voice-over take it would land on
  # the last shot. Written as an if, not `[[ ]] &&`: this is the last statement
  # in the script, so a false test would become the script's exit status and a
  # perfectly good take would report failure.
  if [[ "${DEMO_NARRATE:-1}" = "1" ]]; then
    printf '\n  ran acts: %s (of 0,1,2,3,4)\n' "${ACTS}"
  fi
fi

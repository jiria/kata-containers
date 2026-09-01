#!/usr/bin/env bash
#
# Copyright (c) 2026 Microsoft Corporation
#
# SPDX-License-Identifier: Apache-2.0
#
# shellcheck source-path=SCRIPTDIR
# The executive cut, as a shot list: one terminal shot per narration segment.
#
# WHY THIS EXISTS, GIVEN demo-exec.sh ALREADY DOES
#
# demo-exec.sh conducts a take *paced by the narration*: it holds each segment
# on screen for the length of its synthesized line, so a single capture comes
# out already aligned to the audio. That is the right shape when the narration
# is settled and the cut is assembled in one pass.
#
# It is the wrong shape while the narration is still moving. Re-pacing a take
# every time a line changes means re-recording the whole thing, and pacing a
# recording to audio is something an editor does far better than a sleep(1)
# does. So this script drops the pacing entirely and optimizes for the one
# thing an editor cannot recover afterwards: clean, complete, separable shots.
#
# The contract with the edit is therefore narrow:
#
#   * one command per shot, its whole output on screen, nothing scrolled past
#   * a blank screen for at least a second between any two shots, so the cut
#     point is a run of identical frames rather than a judgement call
#   * shots in narration order, and named for the segment they serve
#   * each pod deleted as soon as its last shot is done — track B, the live
#     kubectl inset, is in frame for the whole take, and a pod that has finished
#     being evidence is clutter in it for every shot that follows
#
# One exception to the first two, and it is deliberate: where several commands
# make a single argument, they accumulate on one screen and only the wipe is
# dropped — the pause between them stays, so the editor can still shorten the
# typing without losing the fact that the outputs belong together. Two cases:
#
#   S09  the pod, the Cloud Hypervisor process serving its VM, and that
#        process's handles on the hypervisor. A chain, threaded by the sandbox
#        id — three screens make it three unrelated facts.
#   S10  the digest computed from the document, and the digest the host stamped
#        into the report. A comparison, and only one screen can hold it.
#
# The two groups stay separate from each other: they are different sentences.
#
# Timing is not this script's business. Neither are the title cards or the
# architecture diagrams (stack-*.svg) — those are injected in the edit.
#
# WHERE THE SHOTS COME FROM
#
# Almost nothing here is new. The commands, the experiments and the fixtures
# are demo.sh's, and this script sources it purely to get at them: DEMO_ACTS is
# set to a value that matches no act, so sourcing defines every helper and runs
# none of the walkthrough. That matters more than it looks — the moment this
# script grows its own copy of, say, the dm-verity substitution, the demo starts
# being able to claim something the engineering walkthrough no longer proves.
#
# Moment 3 (the fragment flow) is a child process rather than a sourced helper,
# because demo-fragment-sidecar.sh is a whole demo of its own with its own
# fixtures and its own cleanup.
#
# THE SHOT / SEGMENT MAP
#
# Segment ids are narration.md's. Segments not listed here have no terminal at
# all — they are title cards or diagram cards, and the editor injects them:
#
#   S01 S02   title card, stack-simple.svg
#   S05       stack-before.svg
#   S12       stack-enforce.svg
#   S17 S18   stack-fragment.svg
#   S30 S31   stack-exec.svg + closing title card
#
# Usage:
#   ./demo-shots.sh                 every moment, in order (~15 min)
#   ./demo-shots.sh 1 2             only those moments
#   DEMO_HOLD=4 ./demo-shots.sh     linger longer on each output
#   FRAG_FROM=3 ./demo-shots.sh 3   re-record the fragment moment from S22 only
#
# Env:
#   DEMO_HOLD=3     seconds an output stays up before the screen is wiped
#   DEMO_GAP=1.5    seconds of blank screen between shots (the cut point)
#   FRAG_FROM=1     1 for all of moment 3, or 3 to start at the fragment build
#                   (S22) and keep the S19-S21 footage you already have
#   SHOT_LIST=path  where to write the shot list (default ${WORK}/shots.tsv)
set -uo pipefail

# Held on screen long enough to be read at recording time, so that a shot is
# usable even if the editor takes it as-is. Both are exported: moment 3 is a
# child process and has to keep the same rhythm, or the fragment shots become
# the only ones in the cut without a gap in front of them.
export DEMO_HOLD="${DEMO_HOLD:-3}"
export DEMO_GAP="${DEMO_GAP:-1.5}"

# The acts settle for a second before each prompt when they are being cued.
# Here the gap already sits between every pair of shots, and a second settle
# would put a second, shorter pause *inside* one.
export DEMO_SETTLE=0

# Off by default: every shot gets its own screen unless a group of them is
# making a single argument (see S09).
export DEMO_KEEP=0

# Voice-over take: the spoken track says where we are, so nothing on screen
# should say it too. What is left is commands and their output, which is the
# evidence and the only reason to record a terminal at all.
export DEMO_NARRATE=0 DEMO_STEPS=0 DEMO_HEADINGS=0 DEMO_PAUSE=0

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# No act matches this, so sourcing demo.sh defines its helpers and runs none of
# its walkthrough. Deliberately not "none" as a magic value — want_act does a
# substring match against a comma-joined list, and anything not in 0..4 does.
export DEMO_ACTS=shots
# shellcheck source=demo.sh
. "${HERE}/demo.sh"

SHOT_LIST="${SHOT_LIST:-${WORK}/shots.tsv}"

# The editor cuts against the clock, not against the shot list, so the list has
# to carry one. Offsets are from the first frame of the take rather than wall
# clock: the recorder is started by hand a moment before the script, and only
# the offset survives that.
_TAKE_T0="${EPOCHREALTIME/,/.}"
{
  printf '# take started %s\n' "$(date --iso-8601=seconds)"
  printf 'segment\tshot\tstart\tend\twhat is on screen\n'
} > "${SHOT_LIST}"

_SHOT_N=0
_SEG=""

_elapsed() { awk -v a="${EPOCHREALTIME/,/.}" -v b="${_TAKE_T0}" 'BEGIN{printf "%.1f", a-b}'; }

# Open a shot: claim the number and stamp the clock. The row is not written
# until _shot_end, because its duration is the thing being recorded.
_shot_begin() {
  _SHOT_N=$((_SHOT_N + 1))
  _SHOT_WHAT="$1"
  _SHOT_START="$(_elapsed)"
}

_shot_end() {
  printf '%s\t%02d\t%s\t%s\t%s\n' \
    "${_SEG}" "${_SHOT_N}" "${_SHOT_START}" "$(_elapsed)" "${_SHOT_WHAT}" >> "${SHOT_LIST}"
}

# Name the segment the following shots belong to. Recorded rather than printed:
# a segment banner would be on the footage the narration is spoken over.
seg() { _SEG="$1"; }

# A shot the editor can cut: the command, its output, and then a gap. The
# rhythm is `pause`'s, so this stays identical to what the sourced helpers
# produce -- a shot from show() and a shot from here must be indistinguishable
# in the capture, or the cut has two grammars in it.
shot() {
  local what="$1"; shift
  _shot_begin "${what}"
  _prompt "$*"
  bash -c "$*" 2>&1 | bash "${_HL}"
  pause
  _shot_end
}

# The sourced helpers call show() directly, which does not know about segments.
# Wrapping it here keeps the shot list complete without touching demo.sh.
eval "_shots_show() $(declare -f show | tail -n +2)"
show() {
  _shot_begin "$1"
  _shots_show "$@"
  _shot_end
}

# start_demo_pod runs a command and holds on it like any other shot, but it does
# it with _prompt rather than show, so it never reached the shot list -- the
# apply was on screen with nothing in the record to cut against. Wrapped for the
# same reason as show: the list has to be what the take actually filmed.
eval "_shots_start_demo_pod() $(declare -f start_demo_pod | tail -n +2)"
start_demo_pod() {
  _shot_begin "apply the pod spec and wait for the CVM to boot ($1)"
  _shots_start_demo_pod "$@"
  _shot_end
}

want_moment() { [[ -z "${MOMENTS}" || ",${MOMENTS}," == *",$1,"* ]]; }

MOMENTS="$(printf '%s' "${*:-}" | tr ' ' ',')"

# A take opens on whatever the last one left behind unless something clears it,
# and a stale Killing event on the first frame reads as part of the demo.
kubectl delete pod -n "${NS}" -l demo=parma --ignore-not-found >/dev/null 2>&1 || true
kubectl delete pod -n "${NS}" demo-frag-sidecar --ignore-not-found >/dev/null 2>&1 || true
kubectl delete events -n "${NS}" --all >/dev/null 2>&1 || true
printf '\033[H\033[2J'
sleep "${DEMO_GAP}"

# ---------------------------------------------------------------- moment 1
# S03, S04 — what the workload runs in.
#
# Static by necessity: no cloud-hypervisor process exists until a pod creates a
# UVM, so this moment shows the platform and moment 2 shows the running VM.
if want_moment 1; then
  seg S03
  shot "the hypervisor device, and the in-kernel driver behind it" \
    "ls -l /dev/mshv; cat /sys/class/misc/mshv/dev"

  seg S04
  shot "the runtime config: Cloud Hypervisor as the VMM, IGVM-launched SEV-SNP guest" \
    "grep -nE '^\[hypervisor\.clh\]|^path = ' $(runtime_config_path) | head -2; grep -nE '^(igvm|confidential_guest|sev_snp_guest)' $(runtime_config_path)"
fi

# ---------------------------------------------------------------- moment 2
# S06 - S16 — the policy: generated, measured, enforced.
if want_moment 2; then
  ensure_policy_toolchain
  # --defer keeps genpolicy out of this call: S06 is the shot of it running, and
  # a policy generated quietly here would leave that shot with nothing to show.
  demo_pod_yaml demo-a '"sleep", "3600"' --defer

  # gen_policy_shown is three shots in a row, and they are three segments:
  # the spec that goes in, genpolicy running, the annotation it leaves behind.
  # The seg calls sit between them, so the shot list stays honest.
  seg S06
  show "the input is an ordinary pod spec — no policy, no annotations, nothing measured yet" \
    "awk '{ l = \$0; if (l ~ /runtimeClassName:/) l = l \"        <-- the confidential runtime class\"; print l }' ${WORK}/demo-a.yaml"
  show "generate the policy for this exact pod spec — genpolicy rewrites that file in place" \
    "${GENPOLICY} -y ${WORK}/demo-a.yaml -p ${GP_RULES} -j ${GP_SETTINGS} && grep -c . ${WORK}/demo-a.yaml | xargs -I{} echo \"demo-a.yaml is now {} lines\""
  grep -q 'cc_init_data' "${WORK}/demo-a.yaml" \
    || die "no cc_init_data annotation — genpolicy did not inject a measured policy"

  seg S07
  show "and this is what it added: the same spec, now carrying one new annotation" \
    "awk '{ l = \$0; if (length(l) > 78) l = substr(l,1,78) \"...\"; if (l ~ /cc_init_data:/) l = l \"   <-- the measured policy\"; print l }' ${WORK}/demo-a.yaml"

  # The journal is read back from here, so the mark has to be taken before the
  # pod boots -- not after, or the digest line is already behind it.
  T0="$(date '+%Y-%m-%d %H:%M:%S')"

  seg S08
  start_demo_pod demo-a

  # S09 is three commands making one argument — the pod, the process serving its
  # VM, and that process's handle on the hypervisor — so they belong on one
  # screen. The break between them stays; only the wipe goes.
  seg S09
  DEMO_KEEP=1
  show_sandbox_backing demo-a
  DEMO_KEEP=0
  printf '\033[H\033[2J'
  sleep "${DEMO_GAP}"

  # S10 is a comparison: the digest anyone can compute from the document, and
  # the digest the host stamped into the report. On two screens it is two
  # base64 strings; on one it is the claim.
  seg S10
  decode_initdata demo-a "${WORK}/a.toml"
  D1="$(initdata_digest_expected "${WORK}/a.toml")"
  DEMO_KEEP=1
  show "anyone can compute the expected measurement from that document alone" \
    "openssl dgst -sha256 -binary ${WORK}/a.toml | base64"
  show "and that is the value the runtime stamped into the SNP report's HOST_DATA" \
    "sudo journalctl -t kata --since '${T0}' --no-pager | grep -F 'initdata  digest' | tail -1"
  DEMO_KEEP=0
  printf '\033[H\033[2J'
  sleep "${DEMO_GAP}"
  [[ -n "$(initdata_journal_line "${T0}" "${D1}")" ]] \
    || warn "did not find the computed digest in the journal — check 'journalctl -t kata'"

  # demo-a's last shot for now. It is needed again at S16, which execs into it,
  # but nothing between here and there touches it: S13 and S14 read the decoded
  # policy under ${WORK}, and S11 and S15 each bring a pod of their own. Leaving
  # it up means the live pod inset shows demo-a beside demo-tampered and again
  # beside demo-verity, which reads as two unrelated pods in a story about one.
  # So it goes now and comes back below.
  kubectl delete pod demo-a -n "${NS}" --ignore-not-found --wait=false >/dev/null 2>&1 || true

  # S11 — the swap the measurement is supposed to prevent, staged on this
  # hardware. Uses its own per-run pod names, so demo-a survives it and the
  # later shots still have something running.
  seg S11
  live_binding_experiment

  seg S13
  show "the policy's shape: one rule per request the agent can be asked to serve, and every one of them starts denied" \
    "grep -E '^default [A-Za-z]+Request' ${WORK}/a.toml | head -12; echo; grep -cE '^default ' ${WORK}/a.toml | xargs -I{} echo \"{} default rules in all — the guest's whole API surface, each answered before it is asked\""

  seg S14
  show "containerd built each layer as an EROFS image in its snapshotter store, with verity metadata beside it" \
    "sudo find ${SNAP} -maxdepth 2 \\( -name 'layer.erofs' -o -name 'layer.erofs.dmverity' \\) | sort"
  # policy-layers.py is act 2's, and is written by it rather than kept as a file
  # on disk. Reproduced here by calling act 2's own writer would mean running
  # act 2; the alternative is this, which is a copy and is marked as one.
  # KEEP IN SYNC with demo.sh act2().
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
  show "and the measured policy names the root hash of every layer this pod may mount" \
    "python3 ${WORK}/policy-layers.py ${WORK}/a.toml"

  # The substitution experiment picks its target from the hashes the policy
  # names, so it needs this file. Act 2 writes it as a side effect of a beat we
  # are not recording here.
  grep -oE 'X-kata\.dmverity\.roothash=[a-f0-9]{64}' "${WORK}/a.toml" \
    | cut -d= -f2 | sort -u > "${WORK}/policy-hashes.txt"

  seg S15
  verity_substitution_experiment

  # demo-a, back for the exec shot. Silent and off-camera: S08 already showed
  # the pod being created, and showing it a second time would say something
  # happened here that did not. Recreated from the same file genpolicy rewrote
  # in S06, so it carries the same measured policy the earlier shots proved.
  #
  # After the verity experiment rather than before it: that experiment deletes
  # its own pod when it finishes, so starting here is the one point where the
  # inset holds exactly one pod. Measured on this node, Pending -> Running is
  # about five seconds, which the gap before S16 covers.
  kubectl apply -f "${WORK}/demo-a.yaml" >/dev/null 2>&1 \
    || die "could not recreate demo-a for the exec shot"
  wait_for 300 "pod demo-a Running" \
    bash -c "kubectl get pod demo-a -n ${NS} -o jsonpath='{.status.phase}' | grep -qx Running" \
    >/dev/null 2>&1 \
    || die "demo-a did not come back up — S16 has nothing to exec into"

  # S16 — exec into demo-a, which was recreated just above.
  seg S16
  show "nobody asked to exec into this pod, so the rule that decides it was never turned on" \
    "grep -nE '^default ExecProcessRequest' ${WORK}/a.toml; grep -cE '^ExecProcessRequest' ${WORK}/a.toml | xargs -I{} echo '{} conditional rules could turn it on — this exec matches none of them'"
  EXEC_OUT="$(kubectl exec -n "${NS}" demo-a -- /bin/true 2>&1)" \
    && die "exec SUCCEEDED — policy is not being enforced"
  show "so try one: kubectl exec into the running pod" \
    "kubectl exec -n ${NS} demo-a -- /bin/true 2>&1 | grep -o 'policyDecision<[^>]*>policyDecision' | head -1 | cut -c1-96 | sed 's/\$/.../'"
  EXEC_B64="$(printf '%s' "${EXEC_OUT}" | grep -o 'policyDecision<[^>]*>policyDecision' | head -1 \
    | sed 's/^policyDecision<//; s/>policyDecision$//')"
  if [[ -n "${EXEC_B64}" ]]; then
    show "decoded — the denial the guest produced, as a structured record" \
      "echo '${EXEC_B64}' | base64 -d | jq ."
  else
    warn "no decision object in the error text — expected the policyDecision sentinel"
  fi

  # demo-a's last shot. It is deleted here rather than by the exit trap because
  # track B — the live kubectl inset in the corner — is in frame for the whole
  # recording, and a pod that has finished being evidence is just clutter in it
  # for the rest of the take. Silent and unwaited: this is stagehand work, not a
  # shot, and the gap after S16 absorbs it.
  kubectl delete pod demo-a -n "${NS}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------- moment 3
# S19 - S29 — fragments. A child process, not a sourced helper: this is a whole
# demo with its own fixtures and its own cleanup, and it has to be able to fail
# without taking the moments already recorded down with it.
if want_moment 3; then
  # FRAG_FROM=3 skips steps 1-2, so the take starts at the fragment build. The
  # label follows, because it is what the editor cuts against.
  FRAG_SEG=S19-S29
  [[ "${FRAG_FROM:-1}" = 3 ]] && FRAG_SEG=S22-S29
  seg "${FRAG_SEG}"
  _FRAG_T0="$(_elapsed)"
  printf '\033[H\033[2J'
  sleep "${DEMO_GAP}"
  # A child process, so its shots cannot be counted here. It keeps the rhythm
  # because DEMO_HOLD and DEMO_GAP are exported, which is the part that matters.
  #
  # DEMO_RECEIPT_TAMPER=0 drops the tampered-receipt refusal. S25-S27 narrate
  # three beats — refused without a receipt, accepted with one, refused as a
  # replay — and the fourth delivery only reads as a distinct failure if the
  # decoded leaf is on screen beside it, which is more explaining than the take
  # can afford. The walkthrough still runs all four.
  DEMO_BEAT_PREFIX=F DEMO_RECEIPT_TAMPER=0 FRAG_FROM="${FRAG_FROM:-1}" bash "${HERE}/demo-fragment-sidecar.sh" || \
    warn "the fragment moment did not finish — the moments already recorded are unaffected"
  # The child cannot count its own shots into this list, but it can be bounded:
  # one row spanning the whole moment, written once it returns.
  printf '%s\t--\t%s\t%s\tfragments: every beat of demo-fragment-sidecar.sh, one shot each\n' \
    "${FRAG_SEG}" "${_FRAG_T0}" "$(_elapsed)" >> "${SHOT_LIST}"
  # Same reason as demo-a: the fragment pod has stopped being evidence, and the
  # inset is still in frame. demo-fragment-sidecar.sh leaves it deliberately —
  # run by hand, the pod is the thing you want to poke at afterwards — so the
  # cleanup belongs here, where the take is what matters.
  kubectl delete pod demo-frag-sidecar -n "${NS}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
fi

printf '\033[H\033[2J'
printf '%d shots recorded here%s. shot list: %s\n' "${_SHOT_N}" \
  "$(want_moment 3 && printf ', plus moment 3 in its own process')" "${SHOT_LIST}"
cp "${SHOT_LIST}" "${HOME}/demo-shots.tsv" 2>/dev/null || true

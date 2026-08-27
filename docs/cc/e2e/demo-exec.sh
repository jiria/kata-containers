#!/usr/bin/env bash
#
# Copyright (c) 2026 Microsoft Corporation
#
# SPDX-License-Identifier: Apache-2.0
#
# shellcheck source-path=SCRIPTDIR
# The four-minute executive cut, as a shot list and a voice-over script.
#
# This is not demo.sh. demo.sh is the engineering walkthrough — 108 beats, 40+
# minutes, and about a third of it is grep of Rust and Rego source. This script
# drives the executive version: four moments, eighteen segments, ~4:00, and no
# source code on screen.
#
# WHAT THIS PRODUCES
#
# The demo is delivered as two tracks that are cut together afterwards:
#
#   track A   the terminal recording — this script's segments, with every wait
#             removed in the edit. Real output, real hashes, real denials.
#   track B   a live `kubectl` inset in the corner, running throughout. That is
#             genuinely live in the room; see --inset for the command.
#
# and one audio track, narrated over both. The whole point of the split is that
# runtime is bounded by the narration, not by how long a CVM takes to boot.
#
# So the artefacts are:
#
#   voiceover.txt    one narration block per line, in segment order. Line N is
#                    segment N. Feed it to a TTS pass, or read it aloud.
#   voiceover.tsv    the same lines with id, word count and estimated duration.
#   voiceover.srt    subtitle timings. Estimated before a run; MEASURED after
#                    one, so it drops straight into an editor already aligned.
#   shotlist.md      per segment: what is on screen, which command produced it,
#                    and the line spoken over it. This is the editor's map.
#   recording-plan.md the same segments grouped by take, in capture order, with
#                    the command for each. This is the operator's map — the shot
#                    list read the other way round.
#   segments.tsv     measured start/end/duration per segment (after --run).
#   chapters.txt     ffmpeg-style chapter marks.
#   tts/S01.txt ...  one file per line, for per-segment audio synthesis.
#
# FOR KDENLIVE specifically:
#
#   kdenlive-markers.txt   Timeline Markers ▸ Import. One range marker per
#                          segment, so each segment shows up as a *labelled
#                          region* on the timeline ruler rather than a bare
#                          point. Frame-rate independent — use this one.
#   kdenlive-markers.json  the same markers in Kdenlive's JSON form, where
#                          positions are frame numbers. Needs DEMO_EXEC_FPS to
#                          match the project profile; the .txt does not.
#   voiceover.srt          Project ▸ Subtitles ▸ Import Subtitle File.
#   demo-exec.kdenlive     a project you can open directly: every narration clip
#                          already laid out on an audio track at its segment's
#                          start time. Written only when --tts has produced the
#                          audio. Open it, then drag the screen recording onto
#                          the video track above and slide it into place.
#                          It is MLT XML — which is what a Kdenlive project is —
#                          but it has to carry the .kdenlive extension: the open
#                          dialog filters on it, so a .mlt is invisible there.
#
# Both marker formats and the SRT are read straight out of Kdenlive's importers
# (markerlistmodel.cpp: importFromTxt takes `<timecode> <comment> [seconds]`,
# importFromJson takes {"pos": frames, "comment", "type", "duration": frames}).
#
# HOW TO USE IT
#
#   ./demo-exec.sh                  write the artefacts, touch nothing. Do this
#                                   first — the shot list is the plan.
#   ./demo-exec.sh --run            conduct a recording: start your screen
#                                   capture, then walk the segments. Cheap
#                                   segments run their own commands; the three
#                                   stateful experiments prompt you to run the
#                                   corresponding act of demo.sh and record it.
#                                   Timings are stamped either way.
#   ./demo-exec.sh --run --auto     smoke-test the conductor: no prompts, so it
#                                   runs straight through in seconds. Not a
#                                   recording — it stamps no timings, because a
#                                   run nobody was recording did not measure
#                                   anything.
#   ./demo-exec.sh --tts            synthesize the narration with Azure Speech.
#   ./demo-exec.sh --inset          print the track B command and exit.
#   ./demo-exec.sh --reset          clear the demo's pods and events, and exit.
#                                   Run before each take: the inset shows the
#                                   last few events, so a take otherwise opens
#                                   on the previous one's.
#
# NARRATION AUDIO
#
# --tts talks to the `jiriatts` Speech resource (eastus, S0). It has local auth
# disabled, so there is no key: authentication is your Entra token, and `az
# login` is the only setup. Because keys are off, the regional TTS endpoint
# rejects the request outright — the custom-domain endpoint is the one that
# accepts a bearer token, and it is the default here for that reason.
#
# Each line becomes tts/S<nn>.mp3. Where ffprobe is available the real duration
# is measured and compared against the segment's budget, because a line that
# runs long is the failure mode that turns a four-minute cut into a five-minute
# one, and it is far cheaper to find here than in the edit.
#
# WHY THE HEAVY SEGMENTS DELEGATE
#
# Three of the four moments need machinery that already exists and is already
# verified: the dm-verity substitution (act 2), the policy substitution and
# genpolicy injection (act 1), and the fragment flow (act 4, via
# demo-fragment-sidecar.sh). Reimplementing them here would duplicate several
# hundred lines of carefully-debugged code and let the two drift apart, which is
# how a demo starts claiming something the product no longer does. So this
# script conducts; demo.sh still performs. Each such segment names the act that
# produces its footage, and the editor pulls that shot from that recording.
#
# Env:
#   DEMO_EXEC_OUT=dir   where to write (default /tmp/demo-exec-<timestamp>)
#   DEMO_EXEC_WPM=144   speaking rate used for duration estimates
#   DEMO_EXEC_FPS=30    project frame rate, for the JSON markers and the project
#   E2E_REPO_DIR        source tree, for the config-path lookup in moment 1
#   SPEECH_ENDPOINT     default https://jiriatts.cognitiveservices.azure.com
#   SPEECH_SUB          subscription holding that resource
#   SPEECH_VOICE        default en-US-AndrewMultilingualNeural
#   SPEECH_RATE         prosody rate, e.g. "+6%" to claw back a long line

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${E2E_REPO_DIR:=$(cd "${HERE}/../../.." && pwd)}"
# 170, not the 144 a script-planning rule of thumb would suggest: measured
# against en-US-AndrewMultilingualNeural reading these exact lines, delivery
# came out at ~172 wpm. Estimating low is not the safe direction here — it hides
# how much room the cut actually has, and makes every line look on-budget.
: "${DEMO_EXEC_WPM:=170}"
: "${DEMO_EXEC_FPS:=30}"
: "${DEMO_EXEC_OUT:=/tmp/demo-exec-$(date -u +%Y%m%d-%H%M%S)}"
# The breath between spoken blocks. Used both for the estimated timeline and for
# the silence spliced into narration-full.mp3, so the full track and the markers
# cannot disagree about how long the cut is.
SEG_GAP_MS=600
SEG_GAP_S="$(awk -v m="${SEG_GAP_MS}" 'BEGIN{printf "%.3f", m/1000}')"

RUN=0
AUTO=0
TTS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --run)   RUN=1 ;;
    --auto)  AUTO=1 ;;
    --tts)   TTS=1 ;;
    --out)   shift; DEMO_EXEC_OUT="$1" ;;
    --voice) shift; SPEECH_VOICE="$1"; TTS=1 ;;
    --rate)  shift; SPEECH_RATE="$1";  TTS=1 ;;
    --inset) INSET_ONLY=1 ;;
    --reset) RESET_ONLY=1 ;;
    # Print the header block itself, so help cannot drift out of step with the
    # documentation the way a hard-coded line range does.
    -h|--help)
      awk 'NR>7 && /^#/ { sub(/^# ?/, ""); print; next } NR>7 { exit }' "${BASH_SOURCE[0]}"
      exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

c_off=$'\033[0m'; c_bld=$'\033[1m'; c_blu=$'\033[34m'
c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_dim=$'\033[2m'
[[ -t 1 ]] || { c_off=; c_bld=; c_blu=; c_grn=; c_ylw=; c_dim=; }

# ---------------------------------------------------------------- track B
# The inset is the credibility anchor: track A is a real run with the waiting
# cut out, but track B is unmistakably a live cluster reacting in real time. It
# wants its own terminal, small, in a corner, running for the whole take.
inset_command() {
  cat <<'EOF'
watch -n1 --color -t '
  kubectl get pods -n coco-e2e -o custom-columns=\
NAME:.metadata.name,PHASE:.status.phase,READY:.status.containerStatuses[*].ready \
    --no-headers 2>/dev/null | head -6
  echo
  kubectl get events -n coco-e2e --sort-by=.lastTimestamp \
    -o custom-columns=REASON:.reason,OBJECT:.involvedObject.name --no-headers 2>/dev/null \
    | tail -4'
EOF
}

if [[ "${INSET_ONLY:-0}" = "1" ]]; then
  printf '%s# track B — run this in a second terminal, keep it in shot%s\n\n' "${c_dim}" "${c_off}"
  inset_command
  exit 0
fi

# ------------------------------------------------------------- stage reset
# Track B shows the last few events in the namespace, and Kubernetes keeps
# events for an hour by default. So the inset opens on whatever ran last —
# typically `Killing demo-prep` from the warm-up — and an audience has no way to
# know that is not part of the demo. Clearing the namespace before a take makes
# the first thing they see belong to the take.
#
# Scoped to the demo's own pods and its own namespace: this runs on a cluster
# someone may be using for something else, and a recording aid has no business
# deleting anything it did not create.
NS="${E2E_NS:-coco-e2e}"

reset_stage() {
  kubectl get ns "${NS}" >/dev/null 2>&1 || return 0
  kubectl delete pod -n "${NS}" -l demo=parma --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete pod -n "${NS}" demo-frag-sidecar demo-prep \
    --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete events -n "${NS}" --all >/dev/null 2>&1 || true
  printf '%sstage reset: %s has no demo pods and no events%s\n' "${c_dim}" "${NS}" "${c_off}"
}

if [[ "${RESET_ONLY:-0}" = "1" ]]; then
  reset_stage
  exit 0
fi

# ------------------------------------------------------------- config lookup
# Stage 04 records the config path it actually installed. Guessing the filename
# is how this breaks when the runtime-rs and runtime-go configs diverge.
runtime_config_path() {
  local rec="${HOME}/.coco-e2e/guest-config-paths"
  if [[ -r "${rec}" ]]; then
    awk 'NF{print $NF; exit}' "${rec}" && return 0
  fi
  printf '/opt/kata/share/defaults/kata-containers/configuration-clh-snp.toml'
}
CFG="$(runtime_config_path)"

# ------------------------------------------------------------------ segments
#
# One segment == one line of narration == one clip in the edit. Keeping that
# strictly 1:1 is what makes the artefacts synchronisable: line N of
# voiceover.txt is spoken over segment N, and nothing has to be re-derived by
# hand at 2am the night before.
#
# Fields: id | moment | shot (what is on screen) | source | command
#   source  ''            this script runs the command itself
#           'act:N'       footage comes from demo.sh act N — record it there
#           'act:frag'    footage comes from demo-fragment-sidecar.sh
#           'none'        no terminal; a title card or a held frame

SEG_ID=(); SEG_MOMENT=(); SEG_SHOT=(); SEG_SRC=(); SEG_CMD=(); SEG_VO=()

segment() {
  SEG_ID+=("$1"); SEG_MOMENT+=("$2"); SEG_SHOT+=("$3"); SEG_SRC+=("$4"); SEG_CMD+=("$5")
  local vo; vo="$(cat)"
  # Rejoin the wrapped heredoc into one line: TTS wants a sentence, not a
  # 78-column layout, and one line per segment is the contract with the editor.
  vo="$(printf '%s' "${vo}" | tr '\n' ' ' | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//')"
  SEG_VO+=("${vo}")
}

# ---- open -------------------------------------------------------------------
segment S01 "open" "title card — no terminal" none '' <<'VO'
We've enhanced the upstream Kata Confidential Containers stack to make it ready for Manifold's
scenarios. A workload runs in its own hardware-isolated VM, governed by one
document: a policy measured into the hardware report at launch. Every layer, every
mount, every container has to match what that document declared, for the whole life of
the workload.
VO

# ---- moment 1: what the workload actually runs in ---------------------------
# Static by necessity: no cloud-hypervisor process exists until a pod creates a
# UVM, so this moment shows the platform and moment 3 shows the running VM.
segment S02 "m1" "the hypervisor device and the in-kernel driver behind it" '' \
  "ls -l /dev/mshv; cat /sys/class/misc/mshv/dev" <<'VO'
Here's what builds that VM. Cloud Hypervisor, through slash dev slash m-s-h-v —
the kernel's interface to the Microsoft hypervisor running beneath this host.
VO

segment S03 "m1" "the runtime config: CLH as the VMM, IGVM-launched SEV-SNP guest" '' \
  "grep -nE '^\[hypervisor\.clh\]|^path = ' ${CFG} | head -2; grep -nE '^(igvm|confidential_guest|sev_snp_guest)' ${CFG}" <<'VO'
And it asks for an IGVM-launched SEV-SNP guest, so the memory boundary is
enforced by the silicon rather than by a setting.
VO

# ---- moment 2: down to the bytes of the image -------------------------------
segment S04 "m2" "the layer's dm-verity root hash, as named in the measured policy" act:2 '' <<'VO'
That boundary protects the memory, not what runs inside it. That's the policy's
job — and here's one thing it declares. Every layer is an EROFS image: a
mainline Linux filesystem, and a proposed OCI layer format. The kernel proves
each layer against its dm-verity root hash, and that hash is in the policy — so
the host can only present what was declared.
VO

segment S05 "m2" "one hex digit of one hash changed" act:2 '' <<'VO'
Watch: we change one hex digit of one hash. Not the data. One digit.
VO

segment S06 "m2" "pod verdict — StartError, exit 128 — then the full layer list beside the policy" act:2 '' <<'VO'
The container never starts, and the refusal is written inside the boundary — the
host is only relaying it. And it holds for the set, not just the one: the right
hashes in the wrong order is still a refusal.
VO

# ---- moment 3: the rules are generated, measured, and enforced --------------
segment S07 "m3" "the pod spec, before anything is done to it" act:1 '' <<'VO'
So who writes that document, and when?
VO

segment S08 "m3" "genpolicy rewriting the spec — the cc_init_data annotation appears" act:1 '' <<'VO'
The customer does, before deploying. The Genpolicy tool derives a Rego policy
from this exact pod spec and writes it back as one annotation. That's the
measured document the guest enforces: what may run, what may be mounted, who may
get a shell.
VO

segment S09 "m3" "the same digest in the hardware report at launch" act:1 '' <<'VO'
Its digest is stamped into the hardware report at launch. The guest refuses to
run unless its rules match that stamp, and attestation checks it's the one you
approved.
VO

segment S10 "m3" "the pod Running: its EROFS layers with their hashes, and the CLH process" act:1 '' <<'VO'
And here's the pod running under them: those layers, those hashes, and the
Cloud Hypervisor process for its VM.
VO

segment S11 "m3" "hold on the running pod — no new terminal output" none '' <<'VO'
Every check inside the guest asks one question: does what you presented match
exactly what was declared? Not just whether some rule allows it — a one-for-one
match: nothing reordered, duplicated or slipped in alongside. And it's fixed at
boot: no code path accepts a new one, compiled out rather than switched off.
VO

segment S12 "m3" "a substituted policy staged, and the guest's refusal" act:1 '' <<'VO'
So here we substitute the policy the way an attacker would. Refused, before a
single line of customer code runs.
VO

# ---- moment 4: how a running workload safely changes ------------------------
segment S13 "m4" "the sidecar attempt, refused — no entry in the attested policy" act:frag '' <<'VO'
Now something that pod's policy never named: a sidecar. It doesn't matter that
it's a legitimate container, or who asks — it has no entry, so it doesn't start.
VO

segment S14 "m4" "the policy_fragments annotation being attached to the pod spec" act:frag '' <<'VO'
Normally, changing that means redeploying and re-attesting. Instead, the policy
names the issuers it will accept new rules from. Here's a signed rule being
attached to the pod spec — one more annotation, next to the measured policy.
VO

segment S15 "m4" "hold on the annotation, then the measured issuer list beside it" act:frag '' <<'VO'
It's called a fragment, and it can come from the customer or from Azure — a
managed sidecar is the same mechanism. Notice it arrives through the host. What
gets it accepted is the signature, never the delivery.
VO

segment S16 "m4" "the guest verifying the fragment's signature and its version floor" act:frag '' <<'VO'
It's signed by an issuer the attested policy
named before launch, at a version at or above the floor that policy set. An old
rule replayed fails that same test.
VO

segment S17 "m4" "the sidecar Running beside the original container; then the receipt-required feed" act:frag '' <<'VO'
It passes, and the sidecar starts — no redeploy, no re-attestation. And what's
measured at launch can ask for more: that a feed's rules also carry a
transparency-ledger receipt, proving they were published in the open.
VO

# ---- close ------------------------------------------------------------------
segment S18 "close" "title card — no terminal" none '' <<'VO'
Hardware isolation, images verified block by block, rules that hold for the
workload's whole life, and a safe way to evolve them — all running today. Ready
for Manifold to build on now, while we upstream them into Kata Confidential
Containers.
VO

N=${#SEG_ID[@]}

# ------------------------------------------------------------------ estimates
words_of() { printf '%s' "$1" | wc -w | tr -d ' '; }

# Speech duration from word count. Deliberately crude: it is a planning number,
# and once --run has happened the measured timings replace it everywhere.
est_seconds() {
  awk -v w="$1" -v wpm="${DEMO_EXEC_WPM}" 'BEGIN{ s = w / (wpm/60); if (s < 1.5) s = 1.5; printf "%.1f", s }'
}

hms() { awk -v t="$1" 'BEGIN{ printf "%02d:%02d:%06.3f", int(t/3600), int((t%3600)/60), t%60 }'; }
srt_ts() { hms "$1" | sed 's/\./,/'; }
mmss() { awk -v t="$1" 'BEGIN{ printf "%d:%02d", int(t/60), int(t%60) }'; }

# ------------------------------------------------------------------- conduct
STARTS=(); ENDS=()

slate() {
  local i="$1"
  printf '\n\n%s%s  %s  %s%s\n' "${c_bld}${c_blu}" "$(printf '%.0s─' {1..72})" "${SEG_ID[i]}" \
    "${SEG_MOMENT[i]}" "${c_off}"
  printf '  %s%s%s\n' "${c_dim}" "${SEG_SHOT[i]}" "${c_off}"
  printf '%s%s%s\n' "${c_bld}${c_blu}" "$(printf '%.0s─' {1..72})" "${c_off}"
}

conduct() {
  local t0 i prev_src=""
  reset_stage
  # What this is, said once, because the shape of it surprises people: the cut
  # interleaves segments that come from the same run of demo.sh — S04, S05 and
  # S06 are all act 2 — so the acts cannot be driven from here. Running act 2
  # three times would produce three different runs of the same experiment. The
  # acts are separate takes, recorded once each; this walks the cut in order so
  # the live segments get captured and the rest get called.
  printf '%sthis conducts the cut; it does not run the three stateful acts.%s\n' \
    "${c_bld}" "${c_off}"
  printf '%sthose are separate takes — see recording-plan.md.%s\n\n' "${c_dim}" "${c_off}"
  if [[ "${AUTO}" = "1" ]]; then
    printf '%s--auto: smoke test, no prompts, no timings stamped. Not a recording.%s\n' \
      "${c_ylw}" "${c_off}"
  fi
  printf '%s\n' "${c_ylw}start your screen recording now, and keep the track B inset in shot.${c_off}"
  printf '%s\n' "${c_ylw}(./demo-exec.sh --inset prints the inset command)${c_off}"
  # The narration is deliberately not shown here. It is voice-over, added in
  # post, and anything on this screen is inside the capture — printing it puts
  # the words on the footage they are meant to be spoken over. Read it in
  # shotlist.md or voiceover.txt, on a second screen, outside the frame.
  printf '%s\n' "${c_dim}(narration is not printed — it is in shotlist.md, off-camera)${c_off}"
  [[ "${AUTO}" = "1" ]] || read -r -p "press Enter when recording ..." _
  t0="$(date +%s.%N)"

  for ((i = 0; i < N; i++)); do
    # An --auto pass is not a conducted run: nothing was recorded and nobody
    # waited, so the wall clock measures the speed of a for-loop. Leaving STARTS
    # empty keeps emit() on a basis that means something.
    [[ "${AUTO}" = "1" ]] || \
      STARTS+=("$(awk -v a="$(date +%s.%N)" -v b="${t0}" 'BEGIN{printf "%.3f", a-b}')")
    slate "${i}"
    case "${SEG_SRC[i]}" in
      none) : ;;
      act:*)
        # Only announce the act when it changes. Five consecutive segments out
        # of act 1 are five shots in one recording, and repeating the command
        # under each one reads as an instruction to run it again.
        if [[ "${SEG_SRC[i]}" = "${prev_src}" ]]; then
          printf '  %sstill in that recording — keep it rolling%s\n' "${c_dim}" "${c_off}"
        else
          printf '  %sfootage source: %s — run and record that act, then continue%s\n' \
            "${c_ylw}" "${SEG_SRC[i]#act:}" "${c_off}"
          case "${SEG_SRC[i]}" in
            act:frag) printf '  %s%s%s\n' "${c_dim}" "DEMO_PAUSE=0 bash ${HERE}/demo-fragment-sidecar.sh" "${c_off}" ;;
            *)        printf '  %s%s%s\n' "${c_dim}" "DEMO_PAUSE=0 DEMO_ACTS=${SEG_SRC[i]#act:} bash ${HERE}/demo.sh" "${c_off}" ;;
          esac
        fi
        prev_src="${SEG_SRC[i]}"
        ;;
      *)
        # Clear first: everything above this point — the slate, the previous
        # segment's output, the prompt — is for the operator, and all of it is
        # inside the capture. A segment the editor can cut cleanly is one whose
        # footage starts at the top of an empty screen.
        [[ "${AUTO}" = "1" ]] || read -r -p "  press Enter to run ${SEG_ID[i]} ..." _
        clear
        printf '%s%s@%s%s:%s%s%s$ %s\n' "${c_grn}" "$(whoami)" "$(hostname -s 2>/dev/null || echo host)" \
          "${c_off}" "${c_blu}" "${PWD/#${HOME}/\~}" "${c_off}" "${SEG_CMD[i]}"
        bash -c "${SEG_CMD[i]}" 2>&1 || true
        prev_src="self"
        ;;
    esac
    [[ "${AUTO}" = "1" ]] || read -r -p "  press Enter for the next segment ..." _
    [[ "${AUTO}" = "1" ]] || \
      ENDS+=("$(awk -v a="$(date +%s.%N)" -v b="${t0}" 'BEGIN{printf "%.3f", a-b}')")
  done
}

# ------------------------------------------------------------------- artefacts
emit() {
  local i w e out="${DEMO_EXEC_OUT}"
  mkdir -p "${out}/tts"

  : > "${out}/voiceover.txt"
  : > "${out}/voiceover.tsv"
  printf 'id\twords\test_seconds\tnarration\n' >> "${out}/voiceover.tsv"

  for ((i = 0; i < N; i++)); do
    printf '%s\n' "${SEG_VO[i]}" >> "${out}/voiceover.txt"
    w="$(words_of "${SEG_VO[i]}")"; e="$(est_seconds "${w}")"
    printf '%s\t%s\t%s\t%s\n' "${SEG_ID[i]}" "${w}" "${e}" "${SEG_VO[i]}" >> "${out}/voiceover.tsv"
    printf '%s\n' "${SEG_VO[i]}" > "${out}/tts/${SEG_ID[i]}.txt"
  done

  # Timings, best source first:
  #   1. synthesized audio — real spoken time. The narration is the master
  #                         clock: narration-full.mp3 is always concatenated at
  #                         a fixed gap, so markers and subtitles measured from
  #                         anything else disagree with the track the editor
  #                         lays under them.
  #   2. a conducted run  — real on-screen time. Tells you how long the machine
  #                         took, which is worth knowing, but it is not the
  #                         timeline: it includes the operator, and with a
  #                         press-Enter-to-run prompt it includes them reading.
  #                         Used only when no audio exists.
  #   3. word count       — the plan, before either exists.
  local -a st en
  local cur=0 have_audio=1
  TIMING_BASIS="estimated from word counts"
  for ((i = 0; i < N; i++)); do
    [[ -s "${out}/tts/${SEG_ID[i]}.mp3" ]] || { have_audio=0; break; }
  done

  # The gap the markers assume has to be the gap the full track actually
  # contains, or the two disagree by a second across eighteen segments. The
  # service returns a slightly longer clip than the break asks for, so measure
  # it rather than trusting the nominal value.
  [[ -s "${out}/tts/_gap.mp3" ]] && SEG_GAP_S="$(mp3_seconds "${out}/tts/_gap.mp3")"

  # A conducted run that measured nothing — every segment stamped at t=0 — is a
  # run that was not really conducted. Fall through rather than emit a 0:00
  # timeline.
  if [[ ${#STARTS[@]} -eq ${N} && "${have_audio}" != "1" \
        && "$(awk -v x="${ENDS[$((N - 1))]:-0}" 'BEGIN{print (x > 1) ? 1 : 0}')" = "1" ]]; then
    TIMING_BASIS="measured from a conducted run"; st=("${STARTS[@]}"); en=("${ENDS[@]}")
  else
    for ((i = 0; i < N; i++)); do
      if [[ "${have_audio}" = "1" ]]; then
        e="$(mp3_seconds "${out}/tts/${SEG_ID[i]}.mp3")"
      else
        w="$(words_of "${SEG_VO[i]}")"; e="$(est_seconds "${w}")"
      fi
      st+=("${cur}")
      cur="$(awk -v a="${cur}" -v b="${e}" 'BEGIN{printf "%.3f", a+b}')"
      en+=("${cur}")
      cur="$(awk -v a="${cur}" -v g="${SEG_GAP_S}" 'BEGIN{printf "%.3f", a+g}')"   # breath between blocks
    done
    [[ "${have_audio}" = "1" ]] && TIMING_BASIS="measured from the synthesized narration"
  fi

  : > "${out}/voiceover.srt"
  : > "${out}/segments.tsv"
  printf 'id\tmoment\tstart_s\tend_s\tduration_s\tsource\tshot\n' >> "${out}/segments.tsv"
  : > "${out}/chapters.txt"

  for ((i = 0; i < N; i++)); do
    printf '%d\n%s --> %s\n%s\n\n' "$((i + 1))" \
      "$(srt_ts "${st[i]}")" "$(srt_ts "${en[i]}")" "${SEG_VO[i]}" >> "${out}/voiceover.srt"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${SEG_ID[i]}" "${SEG_MOMENT[i]}" "${st[i]}" "${en[i]}" \
      "$(awk -v a="${en[i]}" -v b="${st[i]}" 'BEGIN{printf "%.3f", a-b}')" \
      "${SEG_SRC[i]:-self}" "${SEG_SHOT[i]}" >> "${out}/segments.tsv"
    printf '%s %s — %s\n' "$(mmss "${st[i]}")" "${SEG_ID[i]}" "${SEG_SHOT[i]}" >> "${out}/chapters.txt"
  done

  {
    printf '# Executive cut — shot list\n\n'
    printf 'Generated %s by `demo-exec.sh`. Timings are **%s**.\n\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${TIMING_BASIS}"
    printf 'Track A is this terminal recording, cut to the narration. Track B is a live\n'
    printf '`kubectl` inset kept in shot throughout — see `--inset`.\n\n'
    printf '| # | id | moment | at | on screen | footage from | narration |\n'
    printf '|---|----|--------|----|-----------|--------------|-----------|\n'
    for ((i = 0; i < N; i++)); do
      printf '| %d | %s | %s | %s | %s | %s | %s |\n' "$((i + 1))" "${SEG_ID[i]}" "${SEG_MOMENT[i]}" \
        "$(mmss "${st[i]}")" "${SEG_SHOT[i]}" \
        "$( [[ -z "${SEG_SRC[i]}" ]] && echo 'this script' || echo "\`${SEG_SRC[i]}\`" )" \
        "${SEG_VO[i]}"
    done
    printf '\n**Total narration:** %s words over %s (%s wpm delivered).\n' \
      "$(wc -w < "${out}/voiceover.txt" | tr -d ' ')" \
      "$(mmss "${en[$((N - 1))]}")" \
      "$(awk -v w="$(wc -w < "${out}/voiceover.txt" | tr -d ' ')" -v t="${en[$((N - 1))]}" \
         'BEGIN{ printf "%d", (t > 0 ? w / (t / 60) : 0) }')"
  } > "${out}/shotlist.md"

  printf '%s\n' "$(inset_command)" > "${out}/track-b-inset.sh"
  chmod +x "${out}/track-b-inset.sh"

  emit_recording_plan st[@] en[@]
  emit_kdenlive st[@] en[@]
}

# ----------------------------------------------------------- recording plan
# The shot list is the *editor's* map: it is ordered by narration, and three of
# its moments are delegated to acts that each produce one continuous recording.
# That ordering is exactly wrong for the person holding the camera — S04, S05
# and S06 all come out of a single act 2 run, and recording act 2 three times to
# match the script would be absurd. So this is the other view of the same table:
# grouped by take, in the order the takes should be captured, with the command
# for each and the segments it feeds. Without it the operator has to invert the
# shot list by hand, which is how a take gets missed.
emit_recording_plan() {
  local -a st=("${!1}") en=("${!2}")
  local out="${DEMO_EXEC_OUT}" i j src n=0 found
  local -a srcs=()

  # Distinct sources, in order of first appearance.
  for ((i = 0; i < N; i++)); do
    src="${SEG_SRC[i]:-self}"
    found=0
    for ((j = 0; j < n; j++)); do [[ "${srcs[j]}" = "${src}" ]] && found=1 && break; done
    [[ "${found}" = "0" ]] && srcs+=("${src}") && n=$((n + 1))
  done

  {
    printf '# Executive cut — recording plan\n\n'
    printf 'Generated %s by `demo-exec.sh`. Companion to `shotlist.md`: same segments,\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'grouped by **take** instead of by narration order.\n\n'
    printf 'This script does not capture video. It conducts: `--run` slates each segment and\n'
    printf 'runs the live ones. Screen capture is yours to start and stop.\n\n'
    printf '## Before you record\n\n'
    printf '1. `DEMO_PREP=1 bash %s/demo.sh` — builds genpolicy and warms the image pull.\n' "${HERE}"
    printf '   Skip this and act 1 spends ~70s compiling while the audience watches.\n'
    printf '2. `./demo-exec.sh --tts` — narration audio, if it is not current.\n'
    printf '3. Start the track B inset and keep it in shot: `./demo-exec.sh --inset`.\n'
    printf '4. Set the terminal to the capture size you will keep for every take. Takes\n'
    printf '   recorded at different sizes cannot be intercut cleanly.\n\n'
    printf '## Between takes\n\n'
    printf 'Run `./demo-exec.sh --reset` before each one. The inset shows the last few\n'
    printf 'events in the namespace and Kubernetes keeps them for an hour, so a take that\n'
    printf 'starts without it opens on the previous take'"'"'s events — or on `Killing\n'
    printf 'demo-prep` from the warm-up. `--run` does this for you; takes 3 to 5 do not.\n\n'
    printf '## Takes\n\n'
    printf 'Takes are numbered in the order their first shot appears in the cut, not in a\n'
    printf 'required order — each is an independent recording, so capture them in whatever\n'
    printf 'order suits the cluster.\n\n'
    for ((j = 0; j < n; j++)); do
      src="${srcs[j]}"
      printf '### Take %d — %s\n\n' "$((j + 1))" \
        "$(case "${src}" in
             self)     echo 'live, from this script' ;;
             none)     echo 'no terminal' ;;
             act:frag) echo '`demo-fragment-sidecar.sh`' ;;
             act:*)    echo "\`demo.sh\` act ${src#act:}" ;;
           esac)"
      case "${src}" in
        self) printf 'Run `./demo-exec.sh --run` and record the segments below as they are slated.\n\n' ;;
        none) printf 'Nothing to capture. These are title cards, or a hold on the previous shot —\n'
              printf 'the narration runs over what is already on screen.\n\n' ;;
        act:frag) printf '```\nDEMO_PAUSE=0 bash %s/demo-fragment-sidecar.sh\n```\n\n' "${HERE}"
                  printf 'One continuous recording. The editor pulls the shots below out of it.\n\n' ;;
        act:*) printf '```\nDEMO_PAUSE=0 DEMO_ACTS=%s bash %s/demo.sh\n```\n\n' "${src#act:}" "${HERE}"
               printf 'One continuous recording. The editor pulls the shots below out of it.\n\n' ;;
      esac
      printf '| id | at | length | on screen |\n|----|----|--------|-----------|\n'
      for ((i = 0; i < N; i++)); do
        [[ "${SEG_SRC[i]:-self}" = "${src}" ]] || continue
        printf '| %s | %s | %ss | %s |\n' "${SEG_ID[i]}" "$(mmss "${st[i]}")" \
          "$(awk -v a="${en[i]}" -v b="${st[i]}" 'BEGIN{printf "%.1f", a-b}')" "${SEG_SHOT[i]}"
      done
      printf '\n'
    done
    printf '## After\n\n'
    printf 'Open `demo-exec.kdenlive` (narration already laid out), then import `kdenlive-markers.txt`\n'
    printf 'as timeline markers. Each marker is a **range**, so a segment cut to its marker is\n'
    printf 'cut to length. `voiceover.srt` drops in as subtitles, already aligned.\n'
  } > "${out}/recording-plan.md"
}

# ------------------------------------------------------------------ kdenlive
# Two marker files and a project file. The formats are taken from Kdenlive's own
# importers rather than guessed:
#
#   importFromTxt   "<timecode> <comment>", timecode as SS / MM:SS / HH:MM:SS
#                   with a decimal seconds field, and a trailing "[seconds]"
#                   turning the marker into a range. No frame rate anywhere,
#                   which is why this is the one to use.
#   importFromJson  [{"pos": <frames>, "comment": ..., "type": <0-8>,
#                   "duration": <frames>}]. `pos` is frames, so it is only
#                   correct if DEMO_EXEC_FPS matches the project profile.
#
# Range markers matter here: a segment is an interval, not an instant, and an
# editor that can see where a segment *ends* can cut to length without counting.
emit_kdenlive() {
  local -a st=("${!1}") en=("${!2}")
  local out="${DEMO_EXEC_OUT}" i dur type

  : > "${out}/kdenlive-markers.txt"
  : > "${out}/kdenlive-markers.json"
  printf '[\n' >> "${out}/kdenlive-markers.json"

  for ((i = 0; i < N; i++)); do
    dur="$(awk -v a="${en[i]}" -v b="${st[i]}" 'BEGIN{printf "%.3f", a-b}')"
    # Colour the moments differently so the timeline reads at a glance.
    case "${SEG_MOMENT[i]}" in
      open|close) type=0 ;;
      m1) type=1 ;; m2) type=2 ;; m3) type=3 ;; m4) type=4 ;;
      *) type=0 ;;
    esac

    printf '%s %s — %s [%s]\n' "$(hms "${st[i]}")" "${SEG_ID[i]}" "${SEG_SHOT[i]}" "${dur}" \
      >> "${out}/kdenlive-markers.txt"

    printf '  {"pos": %s, "comment": "%s — %s", "type": %s, "duration": %s}%s\n' \
      "$(awk -v t="${st[i]}" -v f="${DEMO_EXEC_FPS}" 'BEGIN{printf "%d", t*f + 0.5}')" \
      "${SEG_ID[i]}" "$(printf '%s' "${SEG_SHOT[i]}" | sed 's/"/\\"/g')" \
      "${type}" \
      "$(awk -v t="${dur}" -v f="${DEMO_EXEC_FPS}" 'BEGIN{printf "%d", t*f + 0.5}')" \
      "$( [[ $((i + 1)) -lt ${N} ]] && printf ',' )" \
      >> "${out}/kdenlive-markers.json"
  done
  printf ']\n' >> "${out}/kdenlive-markers.json"

  emit_mlt st[@]
}

# A project file with the narration already laid out. Only meaningful once the
# audio exists, so it is skipped otherwise rather than emitting a project full
# of missing clips — a broken project is worse than no project.
emit_mlt() {
  local -a st=("${!1}")
  local out="${DEMO_EXEC_OUT}" i have=0 alen prev=0 gap
  for ((i = 0; i < N; i++)); do
    [[ -s "${out}/tts/${SEG_ID[i]}.mp3" ]] && have=1
  done
  [[ "${have}" = "1" ]] || return 0

  # Clip length is the audio's own duration — that is what actually has to fit.
  # mp3_seconds is exact here even without ffmpeg installed, because the stream
  # is constant bitrate by request.
  # Path portability: this script may run under Git Bash while Kdenlive runs as
  # a native Windows app, and "/c/Users/..." means nothing to the latter. So
  # resources are relative to the document and the root is converted to a native
  # form where a converter exists. On Linux both are already correct.
  local root="${out}"
  command -v cygpath >/dev/null 2>&1 && root="$(cygpath -m "${out}" 2>/dev/null || printf '%s' "${out}")"

  # Timeline length, needed up front because the background track has to span it.
  local total=0
  for ((i = 0; i < N; i++)); do
    [[ -s "${out}/tts/${SEG_ID[i]}.mp3" ]] || continue
    alen="$(mp3_seconds "${out}/tts/${SEG_ID[i]}.mp3")"
    total="$(awk -v a="${st[i]}" -v l="${alen}" -v t="${total}" \
      'BEGIN{e=a+l; printf "%.3f", (e>t ? e : t)}')"
  done

  {
    printf '<?xml version="1.0" encoding="utf-8"?>\n'
    # No profile="..." attribute: that names a profile *file* for MLT to look up
    # in its share/profiles directory, and "demo_exec" is not one of them, so it
    # fails to open. The inline <profile> element below is the definition.
    printf '<mlt LC_NUMERIC="C" version="7.0.0" producer="main_bin" root="%s">\n' "${root}"
    printf '  <profile description="demo-exec" width="1920" height="1080" progressive="1"'
    printf ' sample_aspect_num="1" sample_aspect_den="1" display_aspect_num="16"'
    printf ' display_aspect_den="9" frame_rate_num="%s" frame_rate_den="1" colorspace="709"/>\n' \
      "${DEMO_EXEC_FPS}"

    # Kdenlive puts a black background under every timeline and assumes track 0
    # is it. Without one the document loads, but the video tracks sit on nothing.
    printf '  <producer id="black_track" in="00:00:00.000" out="%s">\n' "$(hms "${total}")"
    printf '    <property name="length">%s</property>\n' "$(hms "${total}")"
    printf '    <property name="eof">continue</property>\n'
    printf '    <property name="resource">black</property>\n'
    printf '    <property name="aspect_ratio">1</property>\n'
    printf '    <property name="mlt_service">color</property>\n'
    printf '    <property name="mlt_image_format">rgba</property>\n'
    printf '    <property name="set.test_audio">0</property>\n'
    printf '  </producer>\n'

    for ((i = 0; i < N; i++)); do
      [[ -s "${out}/tts/${SEG_ID[i]}.mp3" ]] || continue
      alen="$(mp3_seconds "${out}/tts/${SEG_ID[i]}.mp3")"
      printf '  <producer id="vo%02d" in="00:00:00.000" out="%s">\n' "${i}" "$(hms "${alen}")"
      printf '    <property name="length">%s</property>\n' "$(hms "${alen}")"
      printf '    <property name="eof">pause</property>\n'
      # Absolute, native-form path. Relative-plus-root is the tidier MLT idiom,
      # but Kdenlive only honours it when the project was saved with relative
      # paths turned on, and otherwise looks the clip up as given and reports it
      # missing. Kdenlive's own default is absolute, so match it. The trade is
      # that moving this directory breaks the links — but the directory is a
      # fixed, durable output location, and a project that opens beats one that
      # relocates.
      printf '    <property name="resource">%s/tts/%s.mp3</property>\n' "${root}" "${SEG_ID[i]}"
      printf '    <property name="mlt_service">avformat</property>\n'
      printf '    <property name="kdenlive:clipname">%s</property>\n' "${SEG_ID[i]}"
      # Bin ids have to be unique and are 1-based with 1 reserved, so start at 2.
      printf '    <property name="kdenlive:id">%d</property>\n' "$((i + 2))"
      printf '  </producer>\n'
    done

    # The project bin. This is also where Kdenlive keeps the document version it
    # complains about not being able to read when it is missing.
    printf '  <playlist id="main_bin">\n'
    printf '    <property name="kdenlive:docproperties.version">1.1</property>\n'
    printf '    <property name="kdenlive:docproperties.profile">demo-exec</property>\n'
    printf '    <property name="kdenlive:docproperties.decimalPoint">.</property>\n'
    printf '    <property name="xml_retain">1</property>\n'
    for ((i = 0; i < N; i++)); do
      [[ -s "${out}/tts/${SEG_ID[i]}.mp3" ]] || continue
      alen="$(mp3_seconds "${out}/tts/${SEG_ID[i]}.mp3")"
      printf '    <entry producer="vo%02d" in="00:00:00.000" out="%s"/>\n' "${i}" "$(hms "${alen}")"
    done
    printf '  </playlist>\n'

    printf '  <playlist id="playlist_vo">\n'
    prev=0
    for ((i = 0; i < N; i++)); do
      [[ -s "${out}/tts/${SEG_ID[i]}.mp3" ]] || continue
      gap="$(awk -v a="${st[i]}" -v b="${prev}" 'BEGIN{d=a-b; if (d < 0.001) d=0; printf "%.3f", d}')"
      awk -v g="${gap}" 'BEGIN{ exit !(g > 0.001) }' \
        && printf '    <blank length="%s"/>\n' "$(hms "${gap}")"
      alen="$(mp3_seconds "${out}/tts/${SEG_ID[i]}.mp3")"
      printf '    <entry producer="vo%02d" in="00:00:00.000" out="%s"/>\n' "${i}" "$(hms "${alen}")"
      prev="$(awk -v a="${st[i]}" -v l="${alen}" 'BEGIN{printf "%.3f", a+l}')"
    done
    printf '  </playlist>\n'
    # Second playlist of the pair: a Kdenlive track is a tractor over two
    # playlists, so that a clip can cross-fade with its own neighbour.
    printf '  <playlist id="playlist_vo_b"/>\n'

    printf '  <tractor id="tractor_vo" in="00:00:00.000" out="%s">\n' "$(hms "${total}")"
    printf '    <property name="kdenlive:audio_track">1</property>\n'
    printf '    <property name="kdenlive:trackName">narration</property>\n'
    printf '    <track hide="video" producer="playlist_vo"/>\n'
    printf '    <track hide="video" producer="playlist_vo_b"/>\n'
    printf '  </tractor>\n'

    printf '  <tractor id="maintractor" in="00:00:00.000" out="%s">\n' "$(hms "${total}")"
    printf '    <property name="kdenlive:projectTractor">1</property>\n'
    printf '    <track producer="black_track"/>\n'
    printf '    <track producer="tractor_vo"/>\n'
    printf '  </tractor>\n'
    printf '</mlt>\n'
  } > "${out}/demo-exec.kdenlive"
}

# --------------------------------------------------------------------- TTS
# Azure Speech, via the `jiriatts` resource. Two things about it decide the shape
# of this function, and both were established by trying them rather than by
# reading a doc page:
#
#   * the resource has `disableLocalAuth: true`, so there is no key to fetch —
#     `az cognitiveservices account keys list` fails outright. Auth is Entra.
#   * with Entra, the *regional* endpoint
#     (https://<region>.tts.speech.microsoft.com/...) returns 401. The custom
#     subdomain endpoint accepts the same bearer token and returns audio. So the
#     custom domain is not a preference here, it is the only thing that works.
#
# One file per line, named for its segment, so a rewritten line is re-synthesized
# alone instead of re-cutting the whole track.
: "${SPEECH_ENDPOINT:=https://jiriatts.cognitiveservices.azure.com}"
: "${SPEECH_SUB:=b99b2264-54e6-408e-812b-2ec280c0ce7a}"
: "${SPEECH_VOICE:=en-US-AndrewMultilingualNeural}"
: "${SPEECH_RATE:=default}"

speech_token() {
  command -v az >/dev/null 2>&1 || { printf ''; return 1; }
  az account get-access-token \
    --resource https://cognitiveservices.azure.com \
    ${SPEECH_SUB:+--subscription "${SPEECH_SUB}"} \
    --query accessToken -o tsv 2>/dev/null
}

# Duration of one narration file, in seconds.
#
# ffprobe when it exists. When it does not, size still gives the exact answer:
# we ask for audio-24khz-96kbitrate-mono-mp3, and 96 kbit/s constant is 12000
# bytes per second. That matters more than it looks — without it, a machine
# without ffmpeg silently loses both the overrun check and the clip lengths in
# the project file, which are the two things this whole pass is for.
mp3_seconds() {
  local f="$1" d=''
  [[ -s "${f}" ]] || { printf '0'; return; }
  if command -v ffprobe >/dev/null 2>&1; then
    d="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "${f}" 2>/dev/null || true)"
  fi
  if [[ -z "${d}" || "${d}" == "N/A" ]]; then
    d="$(awk -v b="$(wc -c < "${f}" | tr -d ' ')" 'BEGIN{ printf "%.3f", b / 12000 }')"
  fi
  printf '%s' "${d}"
}

# Turn a narration line into the SSML body that is actually spoken.
#
# SSML is XML: an unescaped ampersand or angle bracket is a 400, not a warning.
# So escape first, then insert markup — do it the other way round and the tags
# get escaped into literal text and read aloud.
#
# Pauses: this narration uses em dashes the way speech uses a beat before a
# qualifier, but the voice runs straight through them, which turns "written
# inside the boundary — the host is only relaying it" into one breathless
# clause.
#
# Pronunciation: neural voices guess at unfamiliar identifiers, and this voice
# reads "EROFS" as a word rather than spelling it. Capitalisation alone does not
# help — measured against this voice, "an erofs image" and "an EROFS image" come
# back the same length, so the case is ignored. Hyphenating it in the narration
# would spell it, but then the shot list and the subtitles carry "E-R-O-F-S",
# which is not how anyone writes it. So the text keeps the real spelling and the
# alias does the spelling out. A <sub> alias rather than <phoneme>: this voice
# rejects phoneme outright, HTTP 400 with an empty body, with or without the
# SSML namespace. Add terms here as they turn up.
#
# In both cases only the SSML is touched. The text files keep the ordinary
# spelling and punctuation, because a shot list and a subtitle should read
# normally.
ssml_body() {
  printf '%s' "$1" \
    | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
    | sed -e 's| — | <break time="320ms"/> |g' \
          -e 's| – | <break time="240ms"/> |g' \
          -e 's|: |: <break time="200ms"/> |g' \
    | sed -e 's|[eE][rR][oO][fF][sS]|<sub alias="E-R-O-F-S">EROFS</sub>|g'
}

synthesize() {
  local out="${DEMO_EXEC_OUT}" i txt tok code dur planned w spoken over=0 total=0 made=0 kept=0
  mkdir -p "${out}/tts"

  tok="$(speech_token || true)"
  if [[ -z "${tok}" ]]; then
    printf '%sno Entra token — run `az login` (subscription %s).%s\n' "${c_ylw}" "${SPEECH_SUB}" "${c_off}"
    printf '%sthe per-line text in %s/tts/ is still there to synthesize elsewhere.%s\n' \
      "${c_dim}" "${out}" "${c_off}"
    return 0
  fi

  printf '\n%ssynthesizing %d lines — %s%s\n' "${c_bld}" "${N}" "${SPEECH_VOICE}" "${c_off}"
  for ((i = 0; i < N; i++)); do
    # The SSML, not the plain line, is what determines the audio — so it is what
    # the cache has to compare. Keying on the spoken text would mean a change to
    # pronunciation or pausing silently kept the old take, which is the same
    # trap as keying on the file merely existing.
    txt="$(ssml_body "${SEG_VO[i]}")"
    spoken="${out}/tts/${SEG_ID[i]}.spoken"
    if [[ -s "${out}/tts/${SEG_ID[i]}.mp3" && "${SPEECH_FORCE:-0}" != "1" ]] \
       && [[ -f "${spoken}" ]] && [[ "$(cat "${spoken}")" == "${txt}" ]]; then
      kept=$((kept + 1))
    else
      code="$(curl -sS -o "${out}/tts/${SEG_ID[i]}.mp3" -w '%{http_code}' \
        -X POST "${SPEECH_ENDPOINT%/}/tts/cognitiveservices/v1" \
        -H "Authorization: Bearer ${tok}" \
        -H "Content-Type: application/ssml+xml" \
        -H "X-Microsoft-OutputFormat: audio-24khz-96kbitrate-mono-mp3" \
        -d "<speak version='1.0' xml:lang='en-US'><voice name='${SPEECH_VOICE}'><prosody rate='${SPEECH_RATE}'>${txt}</prosody></voice></speak>" \
        2>/dev/null || echo 000)"
      if [[ "${code}" != "200" ]]; then
        printf '  %s%s  HTTP %s%s\n' "${c_ylw}" "${SEG_ID[i]}" "${code}" "${c_off}"
        rm -f "${out}/tts/${SEG_ID[i]}.mp3"
        continue
      fi
      made=$((made + 1))
      printf '%s' "${txt}" > "${spoken}"
    fi

    # A line that overruns its segment is the one thing that breaks a
    # four-minute cut, and it is cheap to catch now rather than in the edit.
    dur="$(mp3_seconds "${out}/tts/${SEG_ID[i]}.mp3")"
    w="$(words_of "${SEG_VO[i]}")"; planned="$(est_seconds "${w}")"
    total="$(awk -v a="${total}" -v b="${dur}" 'BEGIN{printf "%.3f", a+b}')"
    if awk -v d="${dur}" -v p="${planned}" 'BEGIN{ exit !(d > p * 1.15) }'; then
      printf '  %s%s  %5.1fs   budget %ss — long%s\n' "${c_ylw}" "${SEG_ID[i]}" "${dur}" "${planned}" "${c_off}"
      over=$((over + 1))
    else
      printf '  %s  %5.1fs   budget %ss\n' "${SEG_ID[i]}" "${dur}" "${planned}"
    fi
  done

  printf '\n  %s%d synthesized, %d reused%s\n' "${c_dim}" "${made}" "${kept}" "${c_off}"
  printf '  %sspoken audio end to end: %s%s%s' "${c_bld}" "$(mmss "${total}")" "${c_off}" "${c_off}"
  awk -v t="${total}" 'BEGIN{ if (t > 240) printf "   <- over four minutes\n"; else printf "\n" }'
  [[ "${over}" -gt 0 ]] && printf '  %s%d line(s) over budget — shorten them, or raise SPEECH_RATE%s\n' \
    "${c_ylw}" "${over}" "${c_off}"

  concat_narration "${tok}"
  return 0
}

# One file of the whole cut, for listening to it end to end before any footage
# exists. This used to be made by hand, which meant every rewrite left a stale
# full track sitting next to freshly-voiced segments with nothing to say so —
# the same trap as keying the segment cache on the file merely existing. It is
# built here so it cannot drift.
#
# Byte concatenation is legitimate for these files: every segment comes back
# from the same endpoint in the same CBR format, so the frames are compatible
# and no re-encode is needed (there is no ffmpeg on the authoring machine). The
# gaps are real audio for the same reason — a silent clip synthesized once from
# a break-only SSML, spliced between segments, so the full track runs to the
# same length as the timeline instead of ~10s short.
concat_narration() {
  local tok="$1" out="${DEMO_EXEC_OUT}" gap="${out}/tts/_gap.mp3" i code full="${out}/narration-full.mp3"
  local -a parts=()

  for ((i = 0; i < N; i++)); do
    [[ -s "${out}/tts/${SEG_ID[i]}.mp3" ]] || {
      printf '  %snarration-full.mp3 not written — %s is missing%s\n' \
        "${c_ylw}" "${SEG_ID[i]}" "${c_off}"
      return 0
    }
  done

  if [[ ! -s "${gap}" ]]; then
    code="$(curl -sS -o "${gap}" -w '%{http_code}' \
      -X POST "${SPEECH_ENDPOINT%/}/tts/cognitiveservices/v1" \
      -H "Authorization: Bearer ${tok}" \
      -H "Content-Type: application/ssml+xml" \
      -H "X-Microsoft-OutputFormat: audio-24khz-96kbitrate-mono-mp3" \
      -d "<speak version='1.0' xml:lang='en-US'><voice name='${SPEECH_VOICE}'><break time='${SEG_GAP_MS}ms'/></voice></speak>" \
      2>/dev/null || echo 000)"
    [[ "${code}" = "200" ]] || { rm -f "${gap}"; }
  fi

  for ((i = 0; i < N; i++)); do
    [[ "${i}" -gt 0 && -s "${gap}" ]] && parts+=("${gap}")
    parts+=("${out}/tts/${SEG_ID[i]}.mp3")
  done

  cat "${parts[@]}" > "${full}"
  if [[ -s "${gap}" ]]; then
    printf '  %sfull track: %s (%s, with %sms between lines)%s\n' \
      "${c_dim}" "narration-full.mp3" "$(mmss "$(mp3_seconds "${full}")")" "${SEG_GAP_MS}" "${c_off}"
  else
    printf '  %sfull track: narration-full.mp3 (%s) — no gap clip, lines run together%s\n' \
      "${c_ylw}" "$(mmss "$(mp3_seconds "${full}")")" "${c_off}"
  fi
}

# -------------------------------------------------------------------- main
# Order matters: synthesis has to happen before emit, because the project file
# is built around the audio that exists and is skipped when none does.
[[ "${RUN}" = "1" ]] && conduct
[[ "${TTS}" = "1" ]] && synthesize
emit

printf '\n%swrote %s%s\n' "${c_bld}" "${DEMO_EXEC_OUT}" "${c_off}"
printf '  %-22s %s\n' voiceover.txt "one narration block per line, line N = segment N"
printf '  %-22s %s\n' voiceover.srt "${TIMING_BASIS} — Project > Subtitles > Import"
printf '  %-22s %s\n' kdenlive-markers.txt "Timeline Markers > Import — one labelled range per segment"
printf '  %-22s %s\n' kdenlive-markers.json "same markers, frame-based (needs fps ${DEMO_EXEC_FPS})"
if [[ -s "${DEMO_EXEC_OUT}/demo-exec.kdenlive" ]]; then
  printf '  %-22s %s\n' demo-exec.kdenlive "open directly — narration already laid out on an audio track"
else
  printf '  %-22s %s\n' demo-exec.kdenlive "(not written — run --tts first to produce the audio)"
fi
printf '  %-22s %s\n' shotlist.md "what is on screen per segment, and where the footage comes from"
printf '  %-22s %s\n' recording-plan.md "the same segments grouped by take — record in this order"
printf '  %-22s %s\n' segments.tsv "machine-readable timings"
printf '  %-22s %s\n' track-b-inset.sh "the live inset to keep in shot"
printf '\n  %s%s words of narration, timeline runs %s — %s%s\n' "${c_dim}" \
  "$(wc -w < "${DEMO_EXEC_OUT}/voiceover.txt" | tr -d ' ')" \
  "$(mmss "$(awk -F'\t' 'END{print $4+0}' "${DEMO_EXEC_OUT}/segments.tsv")")" \
  "${TIMING_BASIS}" "${c_off}"
awk -F'\t' -v c="${c_ylw}" -v o="${c_off}" 'END{ if ($4+0 > 240) printf "  %sover four minutes — trim a line%s\n", c, o }' \
  "${DEMO_EXEC_OUT}/segments.tsv"

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
#   kdenlive-vo.mlt        a project you can open directly: every narration clip
#                          already laid out on an audio track at its segment's
#                          start time. Written only when --tts has produced the
#                          audio. Open it, then drag the screen recording onto
#                          the video track above and slide it into place.
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
#   ./demo-exec.sh --run --auto     same without waiting for Enter.
#   ./demo-exec.sh --tts            synthesize the narration with Azure Speech.
#   ./demo-exec.sh --inset          print the track B command and exit.
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
#   DEMO_EXEC_FPS=30    project frame rate, for the JSON markers and the .mlt
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
job — and here's one thing it declares. Every layer is an erofs image: a
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
The customer does, before deploying. Genpolicy derives it from this exact pod
spec and writes it back as one annotation, so the rules are settled before the
workload is ever submitted. That's the measured document the guest enforces:
what may run, what may be mounted, who may get a shell.
VO

segment S09 "m3" "the same digest in the hardware report at launch" act:1 '' <<'VO'
Its digest goes into the hardware report at launch, so the guest can tell
whether it got the rules that were approved.
VO

segment S10 "m3" "the pod Running: its erofs layers with their hashes, and the CLH process" act:1 '' <<'VO'
And here's the pod running under them. Its image layers are erofs, each with a
dm-verity hash the policy names, and this is the Cloud Hypervisor process for
its VM.
VO

segment S11 "m3" "hold on the running pod — no new terminal output" none '' <<'VO'
Every check inside the guest asks one question: does what you presented match
exactly what was declared? Not just whether some rule allows it — a one-for-one
match, so nothing can be reordered, duplicated or slipped in alongside. And that
document is fixed at boot: no code path accepts a new one, compiled out rather
than switched off.
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
managed sidecar is the same mechanism. Notice it arrives through the host —
which only carries it. What gets it accepted is the signature, never the
delivery.
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
  printf '  %s“%s”%s\n' "${c_grn}" "${SEG_VO[i]}" "${c_off}"
  printf '%s%s%s\n' "${c_bld}${c_blu}" "$(printf '%.0s─' {1..72})" "${c_off}"
}

conduct() {
  local t0 i
  printf '%s\n' "${c_ylw}start your screen recording now, and keep the track B inset in shot.${c_off}"
  printf '%s\n' "${c_ylw}(./demo-exec.sh --inset prints the inset command)${c_off}"
  [[ "${AUTO}" = "1" ]] || read -r -p "press Enter when recording ..." _
  t0="$(date +%s.%N)"

  for ((i = 0; i < N; i++)); do
    STARTS+=("$(awk -v a="$(date +%s.%N)" -v b="${t0}" 'BEGIN{printf "%.3f", a-b}')")
    slate "${i}"
    case "${SEG_SRC[i]}" in
      none) : ;;
      act:*)
        printf '  %sfootage source: %s — run and record that act, then continue%s\n' \
          "${c_ylw}" "${SEG_SRC[i]#act:}" "${c_off}"
        case "${SEG_SRC[i]}" in
          act:frag) printf '  %s%s%s\n' "${c_dim}" "DEMO_PAUSE=0 bash ${HERE}/demo-fragment-sidecar.sh" "${c_off}" ;;
          *)        printf '  %s%s%s\n' "${c_dim}" "DEMO_PAUSE=0 DEMO_ACTS=${SEG_SRC[i]#act:} bash ${HERE}/demo.sh" "${c_off}" ;;
        esac
        ;;
      *)
        printf '\n%s%s@%s%s:%s%s%s$ %s\n' "${c_grn}" "$(whoami)" "$(hostname -s 2>/dev/null || echo host)" \
          "${c_off}" "${c_blu}" "${PWD/#${HOME}/\~}" "${c_off}" "${SEG_CMD[i]}"
        bash -c "${SEG_CMD[i]}" 2>&1 || true
        ;;
    esac
    [[ "${AUTO}" = "1" ]] || read -r -p "  press Enter for the next segment ..." _
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
  #   1. a conducted run  — real on-screen time, the only thing that reflects
  #                         how long the machine actually took.
  #   2. synthesized audio — real spoken time. Once the mp3s exist, the word
  #                         count is a worse estimate of its own narration than
  #                         the narration is, so never prefer it over the audio.
  #   3. word count       — the plan, before either exists.
  local -a st en
  local cur=0 have_audio=1
  TIMING_BASIS="estimated from word counts"
  for ((i = 0; i < N; i++)); do
    [[ -s "${out}/tts/${SEG_ID[i]}.mp3" ]] || { have_audio=0; break; }
  done

  if [[ ${#STARTS[@]} -eq ${N} ]]; then
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
      cur="$(awk -v a="${cur}" 'BEGIN{printf "%.3f", a+0.6}')"   # breath between blocks
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

  emit_kdenlive st[@] en[@]
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

  {
    printf '<?xml version="1.0" encoding="utf-8"?>\n'
    printf '<mlt LC_NUMERIC="C" version="7.0.0" producer="main_bin" profile="demo_exec" root="%s">\n' "${root}"
    printf '  <profile description="demo-exec" width="1920" height="1080" progressive="1"'
    printf ' sample_aspect_num="1" sample_aspect_den="1" display_aspect_num="16"'
    printf ' display_aspect_den="9" frame_rate_num="%s" frame_rate_den="1" colorspace="709"/>\n' \
      "${DEMO_EXEC_FPS}"

    for ((i = 0; i < N; i++)); do
      [[ -s "${out}/tts/${SEG_ID[i]}.mp3" ]] || continue
      alen="$(mp3_seconds "${out}/tts/${SEG_ID[i]}.mp3")"
      printf '  <producer id="vo%02d" in="00:00:00.000" out="%s">\n' "${i}" "$(hms "${alen}")"
      printf '    <property name="resource">tts/%s.mp3</property>\n' "${SEG_ID[i]}"
      printf '    <property name="mlt_service">avformat</property>\n'
      printf '    <property name="kdenlive:clipname">%s</property>\n' "${SEG_ID[i]}"
      printf '  </producer>\n'
    done

    printf '  <playlist id="playlist_vo">\n'
    printf '    <property name="kdenlive:audio_track">1</property>\n'
    printf '    <property name="kdenlive:track_name">narration</property>\n'
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

    printf '  <tractor id="tractor_main" title="demo-exec narration">\n'
    printf '    <track producer="playlist_vo"/>\n'
    printf '  </tractor>\n'
    printf '</mlt>\n'
  } > "${out}/kdenlive-vo.mlt"
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
    # Re-synthesizing an unchanged line costs time and money and returns the
    # same audio, so keep what is already there. But "already there" has to mean
    # "and it says the same thing": keying the cache on the file merely existing
    # meant every rewrite silently kept the old take, and the only way to find
    # out was to listen to the whole cut. The spoken text is stored beside the
    # audio and compared. SPEECH_FORCE=1 still overrides.
    spoken="${out}/tts/${SEG_ID[i]}.spoken"
    if [[ -s "${out}/tts/${SEG_ID[i]}.mp3" && "${SPEECH_FORCE:-0}" != "1" ]] \
       && [[ -f "${spoken}" ]] && [[ "$(cat "${spoken}")" == "${SEG_VO[i]}" ]]; then
      kept=$((kept + 1))
    else
      # SSML is XML: an unescaped ampersand or angle bracket is a 400, not a
      # warning. Escape first, then insert breaks — do it the other way round
      # and the break tags get escaped into literal text.
      #
      # The dashes need the breaks. This narration uses em dashes the way speech
      # uses a beat before a qualifier, but the voice runs straight through them,
      # which turns "written inside the boundary — the host is only relaying it"
      # into one breathless clause. The text files keep the dash, because a shot
      # list and a subtitle should read normally; only the SSML gets the pause.
      txt="$(printf '%s' "${SEG_VO[i]}" \
        | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
        | sed -e 's/ — / <break time="320ms"\/> /g' \
              -e 's/ – / <break time="240ms"\/> /g' \
              -e 's/: /: <break time="200ms"\/> /g')"
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
      printf '%s' "${SEG_VO[i]}" > "${spoken}"
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
  return 0
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
if [[ -s "${DEMO_EXEC_OUT}/kdenlive-vo.mlt" ]]; then
  printf '  %-22s %s\n' kdenlive-vo.mlt "open directly — narration already laid out on an audio track"
else
  printf '  %-22s %s\n' kdenlive-vo.mlt "(not written — run --tts first to produce the audio)"
fi
printf '  %-22s %s\n' shotlist.md "what is on screen per segment, and where the footage comes from"
printf '  %-22s %s\n' segments.tsv "machine-readable timings"
printf '  %-22s %s\n' track-b-inset.sh "the live inset to keep in shot"
printf '\n  %s%s words of narration, timeline runs %s — %s%s\n' "${c_dim}" \
  "$(wc -w < "${DEMO_EXEC_OUT}/voiceover.txt" | tr -d ' ')" \
  "$(mmss "$(awk -F'\t' 'END{print $4+0}' "${DEMO_EXEC_OUT}/segments.tsv")")" \
  "${TIMING_BASIS}" "${c_off}"
awk -F'\t' -v c="${c_ylw}" -v o="${c_off}" 'END{ if ($4+0 > 240) printf "  %sover four minutes — trim a line%s\n", c, o }' \
  "${DEMO_EXEC_OUT}/segments.tsv"

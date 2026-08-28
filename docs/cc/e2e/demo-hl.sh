#!/usr/bin/env bash
#
# Colour filter for the demo's command output — "track A" in the recording.
#
# kubectl, journalctl and grep emit no colour of their own, so a beat's output
# arrives as a wall of even grey in which the one word that decides the beat
# (Running, denied, StartError) looks exactly like the twenty words around it.
# On a recording that is a real cost: the viewer has a few seconds per shot and
# no way to search.
#
# One principle, the same one track B's inset uses, so the two halves of the
# screen agree: COLOUR CARRIES THE VERDICT.
#
#   green    it worked / it was allowed / it is running
#   red      it was refused, and by whom — this is the demo's punchline. The
#            bare words `true` and `false` are in these two lists for the same
#            reason: in a Rego policy they *are* the verdict, and the shot of
#            the default rules is a screen of nothing else.
#   yellow   still happening; nothing has been decided yet
#   bold     the identifiers the whole argument is about: digests, dm-verity
#            root hashes, the measured-policy keys
#
# Everything else is left alone deliberately. Colouring more would make the
# colour mean "text" again.
#
# Read stdin, write stdout. Passes through untouched when stdout is not a
# terminal, so captured logs, DEMO_SCRIPT and anything piped into grep stay
# plain — escapes in a captured log are a trap for whoever reads it later.
#
# The config-key rule tolerates a leading "N:" because most of these files reach
# the screen through grep -n, and the line number is the reason a viewer can go
# and check the file for themselves.
#
# Usage:  some-command 2>&1 | demo-hl.sh
#
set -uo pipefail

# Not a terminal: hand the bytes straight through. cat, not a sed no-op, so
# there is no chance of a substitution rule touching captured text.
[[ -t 1 ]] || exec cat

e=$(printf '\033')
R="${e}[0m"; B="${e}[1m"
G="${e}[32m"; RD="${e}[31m"; Y="${e}[33m"; C="${e}[36m"

# -u keeps this live: a beat that waits on a pod prints while it waits, and a
# block-buffered filter would hold that output back until the command exits,
# turning a live wait into a silent screen followed by a burst.
#
# Ordering matters. The refusal rules run before the generic word rules so that
# "denied" inside a longer sentence is not recoloured by something later, and
# the identifier rules run last: by then the words they might have matched are
# already wrapped in escapes, which no longer match a word-boundary rule.
exec sed -u -E \
  -e "s/(is blocked by policy[^,]*|CreateContainerRequest is blocked[^ ]*)/${B}${RD}\1${R}/g" \
  -e "s/\b(denied|Denied|DENIED|refused|Refused|rejected|Rejected|StartError|CrashLoopBackOff|ImagePullBackOff|CreateContainerError|Unhealthy|mismatch|MISMATCH|FailedCreatePodSandBox|Failed|Error|error|false|DIFFERENT)\b/${RD}\1${R}/g" \
  -e "s/\b(Running|Completed|Succeeded|allowed|Allowed|verified|Verified|match|matches|matched|true)\b/${G}\1${R}/g" \
  -e "s/\b(Pending|ContainerCreating|PodInitializing|Terminating|Waiting|Pulling|creating|starting)\b/${Y}\1${R}/g" \
  -e "s/\b([0-9a-f]{32,})\b/${B}\1${R}/g" \
  -e "s@\b(io\.katacontainers\.[A-Za-z0-9_.]*|cc_init_data|policy_fragments|HOST_DATA|dm-verity|initdata)@${B}${Y}\1${R}@g" \
  -e "s/\b(sha256:[0-9a-f]{8,})/${B}\1${R}/g" \
  -e "s@^([[:space:]]*([0-9]+:)?)([A-Za-z0-9_.-]+)( *= *)@\1${C}\3${R}\4@"

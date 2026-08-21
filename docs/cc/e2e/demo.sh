#!/usr/bin/env bash
#
# Copyright (c) 2026 Microsoft Corporation
#
# SPDX-License-Identifier: Apache-2.0
#
# shellcheck source-path=SCRIPTDIR
# Hand-runnable demo of what Kata CoCo Strict adds over the C-ACI / hcsshim stack.
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
# Prerequisites (all produced by the normal stages):
#   * cluster with the branch guest stack   — 03-deploy-cluster.sh, 04-build-guest-stack.sh
#   * for act 4 only: issuer key + registry — 06-policy-fragment-e2e.sh
#
# Env:
#   DEMO_PAUSE=1     wait for Enter between beats (default: run straight through)
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

NS="${E2E_NS:-coco-e2e}"
ACTS="${DEMO_ACTS:-0,1,2,3,4}"
WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"; kubectl delete pod -n "${NS}" -l demo=parma --ignore-not-found >/dev/null 2>&1 || true' EXIT

pause() {
  [[ "${DEMO_PAUSE:-0}" = "1" ]] || return 0
  printf '\n    press Enter to continue '
  read -r _
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
  wait_for 300 "pod ${name} Running" \
    bash -c "kubectl get pod ${name} -n ${NS} -o jsonpath='{.status.phase}' | grep -qx Running"
}

# The shim logs the digest it stamped into HOST_DATA. Note the double space in
# "initdata  digest" — it is not a typo, and a single-space grep silently
# matches nothing, which would look like the feature is missing.
initdata_digest_since() {
  local since="$1"
  sudo journalctl -t kata --since "${since}" --no-pager 2>/dev/null \
    | grep -o 'initdata  digest [^ ]*' | tail -1 | awk '{print $3}' | tr -d '"'
}

# The measured document itself, straight out of the pod spec.
decode_initdata() {
  local name="$1" out="$2"
  kubectl get pod "${name}" -n "${NS}" \
    -o jsonpath='{.metadata.annotations.io\.katacontainers\.config\.hypervisor\.cc_init_data}' \
    | base64 -d | gunzip > "${out}" 2>/dev/null \
    || die "could not decode initdata for ${name}"
}

need kubectl; need jq

# ============================================================ act 0
act0() {
  step "act 0 — this is a confidential host, and the guest is a real CVM"
  cat <<'EOF'

  C-ACI runs its UVM on a confidential host. Until this branch, the Kata CoCo
  e2e ran under nested virt on an ordinary host: the policy work was real, the
  hardware root of trust was not. That is no longer true.
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
  show "and the IGVM file is the artefact the launch measurement covers" \
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
  ensure_branch_genpolicy
  ensure_genpolicy_defaults
  kubectl get ns "${NS}" >/dev/null 2>&1 || kubectl create ns "${NS}"

  local t0; t0=$(date '+%Y-%m-%d %H:%M:%S')
  demo_pod_yaml demo-a '"sleep", "3600"'
  show "genpolicy injects the policy as measured initdata — gzip+base64, not plaintext" \
    "grep -o 'cc_init_data: [A-Za-z0-9+/]\{0,24\}' ${WORK}/demo-a.yaml"
  pause

  start_demo_pod demo-a
  decode_initdata demo-a "${WORK}/a.toml"
  show "decoded, it is one TOML document — and it carries the fragment trust roots too" \
    "head -4 ${WORK}/a.toml; echo '   ...'; grep -c . ${WORK}/a.toml | xargs -I{} echo '   ({} lines total)'; grep -oE '^\[data\..*|\"image_layer_verification\": \"[a-z-]*\"' ${WORK}/a.toml | sort -u | head"
  pause

  local d1; d1=$(initdata_digest_since "${t0}")
  printf '\n  %s->%s the runtime hashed that document into the SNP report'"'"'s HOST_DATA field\n' "${_c_blu}" "${_c_off}"
  printf '     %s$ sudo journalctl -t kata | grep "initdata  digest"%s\n' "${_c_yel}" "${_c_off}"
  printf '     %s\n' "${d1}"
  cat <<'EOF'

  Now the point of the whole exercise. Change one byte of the workload — sleep
  3600 becomes sleep 3601 — and the measurement moves. A relying party pinned to
  the first digest rejects the second.
EOF
  pause

  local t1; t1=$(date '+%Y-%m-%d %H:%M:%S')
  demo_pod_yaml demo-b '"sleep", "3601"'
  start_demo_pod demo-b
  local d2; d2=$(initdata_digest_since "${t1}")
  printf '\n     sleep 3600  ->  %s\n     sleep 3601  ->  %s\n' "${d1}" "${d2}"
  if [[ -n "${d1}" && -n "${d2}" && "${d1}" != "${d2}" ]]; then
    ok "one byte of workload, an entirely different measurement"
  else
    warn "could not read both digests from the journal — check 'journalctl -t kata'"
  fi
  cat <<'EOF'

  And the guest checks this itself: the agent reads its own SNP report and
  aborts unless the delivered document hashes to HOST_DATA. So a pod that
  reached Running is itself the evidence that the binding held.
EOF
  pause
}

# ============================================================ act 2
act2() {
  step "act 2 — the image layers are verified: EROFS + dm-verity"
  cat <<'EOF'

  hcsshim converts OCI layers to ext4 with a filesystem writer maintained inside
  its own repository. We consume EROFS layers produced by containerd's own
  snapshotter — the upstream-standard format. The integrity guarantee is
  equivalent; the difference is adoption, and it is a migration argument.
EOF
  [[ -s "${WORK}/a.toml" ]] || { demo_pod_yaml demo-a '"sleep", "3600"'; start_demo_pod demo-a; decode_initdata demo-a "${WORK}/a.toml"; }

  local SNAP=/var/lib/containerd/io.containerd.snapshotter.v1.erofs/snapshots
  show "containerd built each layer as an EROFS image, with verity metadata beside it" \
    "sudo find ${SNAP} -maxdepth 2 -name 'layer.erofs*' | sort | head"
  pause
  show "each sidecar carries the dm-verity root hash of its layer" \
    "sudo find ${SNAP} -maxdepth 2 -name 'layer.erofs.dmverity' | sort | while read -r f; do echo \"\$f\"; sudo cat \"\$f\"; echo; done | head -20"
  pause

  sudo find "${SNAP}" -maxdepth 2 -name 'layer.erofs.dmverity' -exec cat {} \; 2>/dev/null \
    | jq -r '.roothash' 2>/dev/null | sort -u > "${WORK}/host-hashes.txt"
  grep -oE '[a-f0-9]{64}' "${WORK}/a.toml" | sort -u > "${WORK}/policy-hashes.txt"

  printf '\n  %s->%s the measured policy names those layers, by root hash\n' "${_c_blu}" "${_c_off}"
  printf '     host sidecars : %s\n' "$(wc -l < "${WORK}/host-hashes.txt")"
  printf '     in the policy : %s\n' "$(wc -l < "${WORK}/policy-hashes.txt")"
  local matched; matched=$(comm -12 "${WORK}/host-hashes.txt" "${WORK}/policy-hashes.txt" | wc -l)
  comm -12 "${WORK}/host-hashes.txt" "${WORK}/policy-hashes.txt" | sed 's/^/     match  /'
  if [[ "${matched}" -gt 0 ]]; then
    ok "${matched} layer root hash(es) present in both — the policy pins these exact layers"
  else
    warn "no overlap — the running pod's layers may not be among the snapshots listed"
  fi
  pause

  show "and the policy demands verity for every layer it admits" \
    "grep -o '\"image_layer_verification\": \"[a-z-]*\"' ${WORK}/a.toml | head -1"
  cat <<'EOF'

  genpolicy did not read those hashes off this host. It predicted them offline,
  reproducing containerd's mkfs.erofs invocation byte-for-byte against a
  matching erofs-utils, so the policy can be generated anywhere.
EOF
  show "which is why the erofs-utils version is pinned" \
    "mkfs.erofs --version 2>&1 | head -1; grep -A3 -i '^  erofs-utils:' ${E2E_REPO_DIR}/versions.yaml | grep -iE 'version' | head -2"
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
    ensure_branch_genpolicy; ensure_genpolicy_defaults
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
  # It is deliberately byte-identical to the one C-ACI emits, so existing
  # containerd-log consumers parse this record without modification.
  local b64; b64=$(echo "${out}" | grep -o 'policyDecision<[^>]*>policyDecision' | head -1 \
    | sed 's/^policyDecision<//; s/>policyDecision$//')
  if [[ -n "${b64}" ]]; then
    printf '\n  %s->%s decoded — this is FR-8\n' "${_c_blu}" "${_c_off}"
    echo "${b64}" | base64 -d 2>/dev/null | jq . 2>/dev/null | sed 's/^/     /' \
      || echo "${b64}" | base64 -d | sed 's/^/     /'
    cat <<'EOF'

  Three things to notice. The sentinel is deliberately the same one C-ACI uses,
  so existing log consumers parse this unchanged. bound_state_keys lists field
  *names* and never their values, so a denial record cannot become an exfil
  channel. And failed_rule names only the endpoint — "reasons" is what actually
  attributes the denial.
EOF
  else
    warn "no decision object in the error text — expected the policyDecision sentinel"
  fi
  pause

  cat <<'EOF'

  Two more gates, both categories C-ACI leaves open.
EOF
  show "FR-10: the host-to-guest file copy channel is refused outright in strict builds" \
    "sed -n '2535,2543p' ${E2E_REPO_DIR}/src/agent/src/rpc.rs"
  show "FR-14: network config is policy-checked and then frozen once the workload starts" \
    "grep -n 'net_phase_authorize' ${E2E_REPO_DIR}/src/agent/src/rpc.rs | head -6"
  cat <<'EOF'

  hcsshim reaches modifyNetwork with no policy call anywhere on the path, so a
  host there can add or remove adapters, addresses and routes unchecked. Which
  raises the obvious question: how do we know *we* have no such hole?
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

# Everything slow lives here, so the demo itself only displays evidence. The
# image pull matters as much as the genpolicy build: a cold pull happens inside
# the pod-start wait in act 1, where it looks like the platform being slow.
if [[ "${DEMO_PREP:-0}" = "1" ]]; then
  step "prep — doing the slow work now so the demo does not"
  ensure_branch_genpolicy
  ensure_genpolicy_defaults
  kubectl get ns "${NS}" >/dev/null 2>&1 || kubectl create ns "${NS}"
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

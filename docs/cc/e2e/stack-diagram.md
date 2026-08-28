# The stack diagram

`stack-diagram.py` generates two renderings of the same description:

| file | for |
| --- | --- |
| `stack-simple.svg` | the high-level card — names and boxes only: the host stack, the guest, the boundary, and the one call that crosses it |
| `stack-exec.svg` | the executive cut's opening — few boxes, large type, readable in the seconds a title card gets |
| `stack-detail.svg` | the same structure as the exec card with the identifiers, for the doc and for engineers who ask |

Regenerate rather than editing the SVG:

```sh
python stack-diagram.py --out .
```

The palette is the demo's terminal palette on purpose, so the card cuts against
the footage instead of flashing white in the middle of it: red is the host and
untrusted, green is measured and inside the boundary, blue is the measured
document, amber is its digest.

## Why the shape is what it is

The diagram makes one argument, and only one: **the host builds and serves all
of it, and the only place the served bytes are ever compared against the
measurement is inside the guest.** That is why the two curves in the middle
channel start on the host side and converge on a single box on the guest side.
Everything else on the card is there to make those two curves mean something.

It follows the framing rule the demo follows: it describes how the system works
and never names another product.

## Every box, and where it comes from

Nothing on the card is asserted from memory. Each claim below was read out of
the `manifold-cc` branch or observed on the demo node.

### Before deployment

| on the card | source |
| --- | --- |
| genpolicy derives the rules from the pod spec | `src/tools/genpolicy` |
| the measured document: `policy.rego`, `fragment-issuers.toml`, `aa.toml`, `cdh.toml` | initdata TOML, `[data]` section |
| `algorithm = "sha256"` | initdata TOML has `version` / `algorithm` / `[data]` |
| gzip + base64, carried as one annotation | `io.katacontainers.config.hypervisor.cc_init_data`, `annotations.go:270` |

### The host

| on the card | source |
| --- | --- |
| containerd 2.3 + erofs snapshotter | observed on the demo node |
| `containerd-shim-kata-cc-v2` (runtime-rs) | observed on the demo node |
| cloud-hypervisor `--features mshv,sev_snp` on `/dev/mshv` | observed on the demo node; `/dev/sev` does **not** appear on the host — MSHV owns the PSP |
| the host computes and presents every root hash | `layer.erofs.dmverity` JSON sidecars, passed as `X-kata.dmverity.roothash=` |
| the initdata digest is computed host-side | `kata-types/src/initdata.rs:183` |

### Inside the CVM

| on the card | source |
| --- | --- |
| kata-agent is pid 1 | `src/agent/src/main.rs:455` |
| hashes the initdata it was served, reads `HOST_DATA` back out of the SNP report, compares | `src/agent/src/hostdata.rs`; `HOST_DATA` at offset `0xC0`, 32 bytes |
| Regorus evaluates `policy.rego` for each request | the policy engine is Regorus, a Rust-native Rego evaluator — not OPA |
| declared vs presented dm-verity root hashes | `rules.rego:3155-3197` |
| SRM: two-phase commit, fragment store, SVN floor | `src/agent/security-reference-monitor/` |
| COSE_Sign1, did:x509 issuer, svn >= the measured floor | `application/cose-x509+rego`; x5chain in COSE header 33; `RolledBackSvn { issuer, presented, min_required }` at `fragments.rs:597` |
| every container request — ttRPC over vsock | `CreateContainerRequest`, `ExecProcessRequest`, … |

### Provable from outside

The last clause of the subtitle, and the closing line, say the customer can
check the same measurement remotely. That rests on three things already cited
above: the digest is stamped into `HOST_DATA` at launch, `HOST_DATA` comes back
inside an SNP attestation report signed by the platform, and the initdata the
guest is given carries `aa.toml` and `cdh.toml` — the attestation agent and the
confidential data hub — in the same measured `[data]` section as the policy.

The card deliberately stops at "a signed hardware report they can check from
outside the machine". It does not claim anything about what a relying party
then releases, because the demo does not show that.

### Deliberately not on the card

The guest-side dm-verity device is created by the agent when it is built with
`USE_DEVMAPPER=yes`, but the call site was not found, so the card says only that
root hashes are checked — which is proven — and does not draw the device.

## Consistency with the demo

`demo.sh` prints an ASCII trust-boundary diagram of the same three zones
(around line 855). The card and that block should agree; if one changes, change
the other.

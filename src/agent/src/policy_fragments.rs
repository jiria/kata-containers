// Copyright (c) 2026 Microsoft Corporation
//
// SPDX-License-Identifier: Apache-2.0
//

//! Runtime pull + verify + inject of signed policy fragments during agent boot.
//!
//! The measured base policy (set via init-data before this runs) may declare
//! `policy_data.fragments[]` entries — each naming an `issuer` (`did:x509`),
//! a `feed` (OCI reference), and a `minimum_svn`. For each such entry this
//! module:
//!   1. pulls the COSE_Sign1 fragment OCI artifact for the feed,
//!   2. hands the bytes to the policy crate to cryptographically verify against
//!      the (attested) spec, and
//!   3. injects the verified Rego module into the running engine.
//!
//! Everything is fail-closed: if any declared fragment cannot be fetched,
//! verified, or injected, the whole operation returns `Err` and the caller
//! aborts the boot rather than proceeding with a partially-composed policy.

use anyhow::{anyhow, bail, Context, Result};
use oci_client::client::{ClientConfig, ClientProtocol};
use oci_client::secrets::RegistryAuth;
use oci_client::{Client, Reference};
use slog::info;

use crate::AGENT_POLICY;

/// OCI layer media type carrying the COSE_Sign1(rego) fragment envelope.
const COSE_LAYER_MEDIA_TYPE: &str = "application/cose-x509+rego";
/// Expected OCI artifactType for a kata policy fragment.
const FRAGMENT_ARTIFACT_TYPE: &str = "application/x-ms-ccepolicy-frag";

macro_rules! sl {
    () => {
        slog_scope::logger()
    };
}

/// Fetch, verify, and inject every fragment the measured base policy declares.
///
/// Returns the number of fragments injected (0 when none are declared). Any
/// failure is fatal and propagated so the boot path can fail closed.
pub async fn load_declared_fragments() -> Result<usize> {
    // Snapshot the specs under the lock, then release it so the network pull
    // does not hold the global policy mutex.
    let specs = {
        let mut policy = AGENT_POLICY.lock().await;
        policy
            .fragment_specs()
            .context("reading policy_data.fragments from the base policy")?
    };

    if specs.is_empty() {
        info!(sl!(), "policy-fragments: base policy declares no fragments");
        return Ok(0);
    }

    info!(
        sl!(),
        "policy-fragments: base policy declares {} fragment(s)",
        specs.len()
    );

    let mut injected = 0usize;
    for spec in &specs {
        let cose = fetch_fragment(&spec.feed)
            .await
            .with_context(|| format!("fetching fragment for feed {}", spec.feed))?;

        // Verify + inject under the lock (verification is CPU-only, no I/O).
        let mut policy = AGENT_POLICY.lock().await;
        policy
            .load_verified_fragment(&cose, spec)
            .with_context(|| format!("verifying/injecting fragment for feed {}", spec.feed))?;
        injected += 1;
    }

    info!(
        sl!(),
        "policy-fragments: injected {}/{} verified fragment(s)",
        injected,
        specs.len()
    );
    Ok(injected)
}

/// Pull the raw COSE_Sign1 bytes for a fragment feed from its OCI registry.
///
/// `feed` is an OCI reference (e.g. `contoso.azurecr.io/frag/infra:1`). The
/// manifest is resolved, the COSE layer selected by media type, and its blob
/// downloaded. No verification happens here — the returned bytes are untrusted
/// until [`FragmentPolicy`]-checked by the policy crate.
async fn fetch_fragment(feed: &str) -> Result<Vec<u8>> {
    let reference: Reference = feed
        .parse()
        .with_context(|| format!("invalid OCI reference for feed: {feed}"))?;

    // Registries are HTTPS by default; only fall back to plain HTTP for an
    // explicit localhost dev registry.
    let protocol = if is_plain_http_registry(&reference) {
        ClientProtocol::Http
    } else {
        ClientProtocol::Https
    };
    let client = Client::new(ClientConfig {
        protocol,
        ..Default::default()
    });

    // Fragments are public artifacts pinned by digest/tag; anonymous pull.
    let auth = RegistryAuth::Anonymous;

    let (manifest, _digest) = client
        .pull_image_manifest(&reference, &auth)
        .await
        .with_context(|| format!("failed to pull manifest for {reference}"))?;

    if let Some(at) = &manifest.artifact_type {
        if at != FRAGMENT_ARTIFACT_TYPE {
            info!(
                sl!(),
                "policy-fragments: unexpected artifactType {at} (want {FRAGMENT_ARTIFACT_TYPE}) for {reference} — continuing"
            );
        }
    }

    let layer = manifest
        .layers
        .iter()
        .find(|l| l.media_type == COSE_LAYER_MEDIA_TYPE)
        .ok_or_else(|| {
            anyhow!(
                "no {COSE_LAYER_MEDIA_TYPE} layer in manifest for {reference} (have: {})",
                manifest
                    .layers
                    .iter()
                    .map(|l| l.media_type.clone())
                    .collect::<Vec<_>>()
                    .join(", ")
            )
        })?;

    let mut buf: Vec<u8> = Vec::with_capacity(layer.size.max(0) as usize);
    client
        .pull_blob(&reference, layer, &mut buf)
        .await
        .with_context(|| format!("failed to download fragment layer {}", layer.digest))?;

    if buf.is_empty() {
        bail!("downloaded fragment layer is empty for {reference}");
    }
    Ok(buf)
}

/// Only treat an explicit localhost/loopback registry as plain-HTTP; all other
/// registries must use TLS.
fn is_plain_http_registry(reference: &Reference) -> bool {
    let registry = reference.registry();
    registry.starts_with("localhost")
        || registry.starts_with("127.0.0.1")
        || registry.starts_with("[::1]")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plain_http_only_for_localhost() {
        let local: Reference = "localhost:5001/frag/infra:1".parse().unwrap();
        assert!(is_plain_http_registry(&local));

        let loopback: Reference = "127.0.0.1:5001/frag/infra:1".parse().unwrap();
        assert!(is_plain_http_registry(&loopback));

        let remote: Reference = "contoso.azurecr.io/frag/infra:1".parse().unwrap();
        assert!(!is_plain_http_registry(&remote));
    }

    // ---------------------------------------------------------------------
    // Live wire-path tests against a local dev registry (`localhost:5001`).
    //
    // These exercise the *real* `fetch_fragment` OCI pull followed by the
    // real `verify_fragment` crypto/format check on the pulled bytes — the
    // exact code the guest runs, minus the VM boundary (on the host,
    // `localhost:5001` genuinely reaches the registry so the plain-HTTP dev
    // path is taken with no hacks).
    //
    // They are `#[ignore]`d because they need a registry pre-loaded by
    // `genpolicy-fragmentgen` with these tags:
    //   frag/infra:1        GOOD   (svn 2, issuer == DID_GOOD)
    //   frag/infra:badsvn   svn 0, issuer == DID_GOOD
    //   frag/infra:wrongiss svn 2, issuer != DID_GOOD (different chain)
    //
    // Run with:
    //   cargo test -p kata-agent --features agent-policy --release \
    //     policy_fragments::tests::wire_ -- --ignored --nocapture
    // ---------------------------------------------------------------------
    use kata_agent_policy::fragment_verify::{verify_fragment, FragmentPolicy};

    const DID_GOOD: &str =
        "did:x509:0:sha256:JPwQMhqN3j-KAO6S0Ba8zBnK172iBSKZZKi5B8Qo_6k::CN:contoso-fragment-signer";

    #[tokio::test]
    #[ignore]
    async fn wire_good_fetch_verify_ok() {
        let feed = "localhost:5001/frag/infra:1";
        let cose = fetch_fragment(feed).await.expect("fetch GOOD fragment");
        let vf = verify_fragment(
            &cose,
            &FragmentPolicy {
                issuer: DID_GOOD.to_string(),
                feed: feed.to_string(),
                minimum_svn: 1,
            },
        )
        .expect("GOOD fragment must verify");
        assert_eq!(vf.feed, feed);
        assert_eq!(vf.issuer, DID_GOOD);
        assert_eq!(vf.svn, 2);
        assert!(
            vf.namespace.starts_with("agent_fragments"),
            "unexpected namespace: {}",
            vf.namespace
        );
        assert!(vf.rego.contains("svn := 2"));
    }

    #[tokio::test]
    #[ignore]
    async fn wire_bad_svn_rejected() {
        let feed = "localhost:5001/frag/infra:badsvn";
        let cose = fetch_fragment(feed).await.expect("fetch badsvn fragment");
        let err = verify_fragment(
            &cose,
            &FragmentPolicy {
                issuer: DID_GOOD.to_string(),
                feed: feed.to_string(),
                minimum_svn: 1,
            },
        )
        .expect_err("svn 0 < minimum_svn 1 must be rejected");
        let msg = format!("{err:#}").to_lowercase();
        assert!(msg.contains("svn"), "expected an svn error, got: {}", msg);
    }

    #[tokio::test]
    #[ignore]
    async fn wire_wrong_issuer_rejected() {
        let feed = "localhost:5001/frag/infra:wrongiss";
        let cose = fetch_fragment(feed).await.expect("fetch wrongiss fragment");
        let err = verify_fragment(
            &cose,
            &FragmentPolicy {
                issuer: DID_GOOD.to_string(),
                feed: feed.to_string(),
                minimum_svn: 1,
            },
        )
        .expect_err("issuer mismatch must be rejected");
        let msg = format!("{err:#}").to_lowercase();
        assert!(
            msg.contains("issuer") || msg.contains("did"),
            "expected an issuer error, got: {}",
            msg
        );
    }
}

// Copyright (c) 2026 Microsoft Corporation
//
// SPDX-License-Identifier: Apache-2.0
//

//! Guest-side verification of a policy fragment delivered as a COSE_Sign1
//! envelope.
//!
//! This mirrors the Azure Container Instances confidential-container signed
//! fragment format (ES384 / x5chain in protected-header label 33 /
//! `did:x509`), documented in `wiki/raw/aci-cose-fragment-format.md`. It is
//! the security-critical step that MUST succeed before
//! [`crate::policy::AgentPolicy::add_fragment`] injects a module into the
//! regorus engine.
//!
//! The signing key is NOT resolved over the network: the DER certificate chain
//! travels inside the envelope (`x5chain`) and is trust-anchored by the root
//! certificate SHA-256 hash pinned in the measured base policy's `issuer`
//! (`did:x509`) field. This keeps verification self-contained inside the TEE
//! guest with no runtime network dependency to resolve the key.

use anyhow::{anyhow, bail, Context, Result};
use base64::Engine as _;
use coset::{
    cbor::value::Value, iana, CoseSign1, Label, TaggedCborSerializable,
};
use p384::ecdsa::{signature::Verifier, DerSignature, Signature as P384Signature, VerifyingKey};
use sha2::{Digest, Sha256};
use x509_cert::der::{Decode, Encode};
use x509_cert::Certificate;

/// COSE algorithm identifier for ECDSA w/ SHA-384 (P-384).
const ES384: iana::Algorithm = iana::Algorithm::ES384;
/// Expected COSE content type for the raw-Rego payload.
const CTY_REGO: &str = "application/unknown+rego";
/// COSE protected-header label carrying the DER certificate chain.
const X5CHAIN_LABEL: i64 = 33;
/// OID for X.520 Common Name (2.5.4.3).
const OID_COMMON_NAME: &str = "2.5.4.3";

/// The base-policy rule a fragment must satisfy: which issuer / feed is
/// accepted and the minimum acceptable software version number. These values
/// come from the *measured* base policy's `policy_data.fragments[]` entry, so
/// they are attested; the fragment content is trusted only by matching them.
///
/// The field layout matches the JSON object genpolicy emits into
/// `policy_data.fragments[]`, so it deserializes directly from an engine query.
#[derive(Debug, Clone, serde::Deserialize)]
pub struct FragmentPolicy {
    /// Expected `did:x509` issuer (trust anchor: pinned root-cert hash + CN).
    pub issuer: String,
    /// Expected feed (registry reference the fragment was pulled by).
    pub feed: String,
    /// Minimum acceptable `svn` embedded in the fragment payload.
    pub minimum_svn: i64,
}

/// A fragment whose COSE_Sign1 signature, certificate chain, `did:x509` claim,
/// feed, and SVN have all been verified against a [`FragmentPolicy`].
#[derive(Debug, Clone)]
pub struct VerifiedFragment {
    /// The feed carried in the envelope (== the expected feed).
    pub feed: String,
    /// The `did:x509` recomputed from the real chain (== the expected issuer).
    pub issuer: String,
    /// The software version number parsed from the payload.
    pub svn: i64,
    /// The Rego `package` name declared on the first `package` line of the
    /// payload (e.g. `agent_fragments.infra`).
    pub namespace: String,
    /// The raw UTF-8 Rego module text (the COSE payload).
    pub rego: String,
}

/// Verify a COSE_Sign1 fragment envelope against an expected base-policy rule.
///
/// On success the signature is valid, the certificate chain is internally
/// consistent (each cert signed by the next; the last is a self-signed root),
/// the `did:x509` recomputed from the real chain equals `expected.issuer`, the
/// feed matches, and the payload `svn` is `>= expected.minimum_svn`. Any
/// failure returns `Err` — the caller MUST treat that as a hard reject and NOT
/// inject the module (fail-closed).
pub fn verify_fragment(cose: &[u8], expected: &FragmentPolicy) -> Result<VerifiedFragment> {
    // 1. Unwrap CBOR tag 18 -> COSE_Sign1.
    let sign1 = CoseSign1::from_tagged_slice(cose)
        .map_err(|e| anyhow!("not a valid COSE_Sign1 envelope: {e:?}"))?;

    // 2. alg == ES384 and cty == application/unknown+rego.
    match &sign1.protected.header.alg {
        Some(coset::Algorithm::Assigned(a)) if *a == ES384 => {}
        other => bail!("unexpected/absent COSE alg (want ES384): {other:?}"),
    }
    match &sign1.protected.header.content_type {
        Some(coset::ContentType::Text(t)) if t == CTY_REGO => {}
        other => bail!("unexpected/absent COSE cty (want {CTY_REGO}): {other:?}"),
    }

    // 3. Extract x5chain (label 33), iss, feed from the protected header.
    let chain_der = extract_x5chain(&sign1)?;
    if chain_der.is_empty() {
        bail!("x5chain is empty");
    }
    let iss_claim = extract_text_header(&sign1, "iss")
        .context("COSE envelope missing string-keyed `iss` header")?;
    let feed_claim = extract_text_header(&sign1, "feed")
        .context("COSE envelope missing string-keyed `feed` header")?;

    // 4. Parse the DER chain into certificates [leaf .. root].
    let certs: Vec<Certificate> = chain_der
        .iter()
        .map(|der| Certificate::from_der(der).map_err(|e| anyhow!("bad DER cert in x5chain: {e}")))
        .collect::<Result<_>>()?;
    let leaf = &certs[0];
    let root = certs
        .last()
        .expect("chain non-empty (checked above)");

    // 5. Verify the X.509 path leaf -> .. -> root (root is the trust anchor).
    //    Each certificate must be signed by the next one up; the root must be
    //    self-signed. We verify signatures only (path/name constraints are out
    //    of scope for the prototype — the root hash pin below is the anchor).
    for i in 0..certs.len() {
        let issuer_cert = if i + 1 < certs.len() {
            &certs[i + 1]
        } else {
            root // top of chain: expect self-signed
        };
        verify_cert_signature(&certs[i], issuer_cert)
            .with_context(|| format!("X.509 chain link {i} signature invalid"))?;
    }

    // 6. Verify the COSE_Sign1 signature with the leaf public key (ES384).
    let leaf_key = cert_verifying_key(leaf).context("leaf public key")?;
    sign1
        .verify_signature(b"", |sig, data| verify_es384_cose(&leaf_key, sig, data))
        .map_err(|e| anyhow!("COSE_Sign1 signature verification failed: {e}"))?;

    // 7. did:x509 claim check: recompute from the real chain and match both the
    //    envelope's `iss` and the expected (measured) issuer.
    let did = recompute_did_x509(root, leaf)?;
    if did != iss_claim {
        bail!("did:x509 recomputed from chain ({did}) != envelope iss ({iss_claim})");
    }
    if did != expected.issuer {
        bail!(
            "fragment issuer ({did}) does not match the accepted base-policy issuer ({})",
            expected.issuer
        );
    }

    // 8. Payload -> Rego text; parse `package` namespace and `svn := N`.
    let payload = sign1
        .payload
        .as_ref()
        .context("COSE_Sign1 has no payload")?;
    let rego = String::from_utf8(payload.clone()).context("payload is not valid UTF-8 Rego")?;
    let namespace = parse_package(&rego).context("payload has no `package` declaration")?;
    let svn = parse_svn(&rego).context("payload has no parseable `svn := N`")?;

    // 9. Enforce the base-policy rule: feed match + SVN floor.
    if feed_claim != expected.feed {
        bail!(
            "fragment feed ({feed_claim}) does not match the expected feed ({})",
            expected.feed
        );
    }
    if svn < expected.minimum_svn {
        bail!(
            "fragment svn {svn} is below the accepted minimum_svn {}",
            expected.minimum_svn
        );
    }

    Ok(VerifiedFragment {
        feed: feed_claim,
        issuer: did,
        svn,
        namespace,
        rego,
    })
}

/// Pull the DER certificate chain out of protected-header label 33. The value
/// is either an array of byte strings (usual) or a single byte string (one
/// cert).
fn extract_x5chain(sign1: &CoseSign1) -> Result<Vec<Vec<u8>>> {
    for (label, value) in &sign1.protected.header.rest {
        if *label == Label::Int(X5CHAIN_LABEL) {
            return match value {
                Value::Array(items) => items
                    .iter()
                    .map(|v| {
                        v.as_bytes()
                            .cloned()
                            .ok_or_else(|| anyhow!("x5chain array entry is not a byte string"))
                    })
                    .collect(),
                Value::Bytes(b) => Ok(vec![b.clone()]),
                other => bail!("x5chain has unexpected CBOR type: {other:?}"),
            };
        }
    }
    bail!("COSE protected header has no x5chain (label 33)")
}

/// Read a string-keyed text header (e.g. `iss`, `feed`) from the protected
/// header.
fn extract_text_header(sign1: &CoseSign1, key: &str) -> Option<String> {
    sign1.protected.header.rest.iter().find_map(|(label, value)| {
        match (label, value) {
            (Label::Text(k), Value::Text(v)) if k == key => Some(v.clone()),
            _ => None,
        }
    })
}

/// Build a P-384 verifying key from a certificate's SubjectPublicKeyInfo.
fn cert_verifying_key(cert: &Certificate) -> Result<VerifyingKey> {
    let spki = &cert.tbs_certificate.subject_public_key_info;
    let point = spki
        .subject_public_key
        .as_bytes()
        .ok_or_else(|| anyhow!("SubjectPublicKey BIT STRING is not byte-aligned"))?;
    VerifyingKey::from_sec1_bytes(point).map_err(|e| anyhow!("invalid P-384 public key: {e}"))
}

/// Verify that `cert` was signed by `issuer` (ECDSA/P-384/SHA-384). The X.509
/// signature is a DER-encoded ECDSA-Sig-Value over the DER of the TBSCertificate.
fn verify_cert_signature(cert: &Certificate, issuer: &Certificate) -> Result<()> {
    let issuer_key = cert_verifying_key(issuer)?;
    let tbs = cert
        .tbs_certificate
        .to_der()
        .context("re-encode TBSCertificate")?;
    let sig_bytes = cert
        .signature
        .as_bytes()
        .ok_or_else(|| anyhow!("certificate signature BIT STRING is not byte-aligned"))?;
    let sig = DerSignature::from_bytes(sig_bytes)
        .map_err(|e| anyhow!("certificate signature is not a valid DER ECDSA-Sig-Value: {e}"))?;
    issuer_key
        .verify(&tbs, &sig)
        .map_err(|e| anyhow!("certificate signature does not verify: {e}"))
}

/// Verify a COSE_Sign1 signature: `sig` is the raw fixed-width r||s (96 bytes
/// for P-384), `data` is the Sig_Structure ToBeSigned bytes coset builds.
fn verify_es384_cose(key: &VerifyingKey, sig: &[u8], data: &[u8]) -> Result<()> {
    let signature = P384Signature::from_slice(sig)
        .map_err(|e| anyhow!("COSE signature is not a valid P-384 r||s value: {e}"))?;
    key.verify(data, &signature)
        .map_err(|e| anyhow!("ES384 signature mismatch: {e}"))
}

/// Recompute the `did:x509` identifier from the real chain and leaf CN:
/// `did:x509:0:sha256:<b64url(sha256(root_DER))>::CN:<leaf_CN>`.
fn recompute_did_x509(root: &Certificate, leaf: &Certificate) -> Result<String> {
    let root_der = root.to_der().context("re-encode root certificate")?;
    let hash = Sha256::digest(&root_der);
    let b64 = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(hash);
    let cn = subject_common_name(leaf).context("leaf certificate has no Common Name")?;
    Ok(format!("did:x509:0:sha256:{b64}::CN:{cn}"))
}

/// Extract the first Common Name (OID 2.5.4.3) from a certificate subject.
fn subject_common_name(cert: &Certificate) -> Result<String> {
    let cn_oid = const_oid::ObjectIdentifier::new(OID_COMMON_NAME)
        .map_err(|e| anyhow!("bad CN OID constant: {e}"))?;
    for rdn in cert.tbs_certificate.subject.0.iter() {
        for atv in rdn.0.iter() {
            if atv.oid == cn_oid {
                // The value is a DirectoryString (Utf8String or PrintableString).
                if let Ok(s) = atv.value.decode_as::<x509_cert::der::asn1::Utf8StringRef>() {
                    return Ok(s.as_str().to_string());
                }
                if let Ok(s) = atv.value.decode_as::<x509_cert::der::asn1::PrintableStringRef>() {
                    return Ok(s.as_str().to_string());
                }
            }
        }
    }
    bail!("no Common Name RDN found in subject")
}

/// Return the first `package <name>` declared in a Rego module.
fn parse_package(rego: &str) -> Option<String> {
    for line in rego.lines() {
        let l = line.trim();
        if let Some(rest) = l.strip_prefix("package") {
            let name = rest.trim();
            if !name.is_empty() && rest.starts_with(char::is_whitespace) {
                return Some(name.to_string());
            }
        }
    }
    None
}

/// Parse `svn := <N>` (or `svn := "<N>"`) from a Rego module, taking the
/// leading integer.
fn parse_svn(rego: &str) -> Option<i64> {
    for line in rego.lines() {
        let l = line.trim();
        let rest = match l.strip_prefix("svn") {
            Some(r) => r.trim_start(),
            None => continue,
        };
        let rest = match rest.strip_prefix(":=") {
            Some(r) => r.trim(),
            None => continue,
        };
        let val = rest.trim_matches('"').trim();
        let digits: String = val.chars().take_while(|c| c.is_ascii_digit()).collect();
        if let Ok(n) = digits.parse::<i64>() {
            return Some(n);
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use coset::{CoseSign1Builder, HeaderBuilder};
    use p384::ecdsa::{signature::Signer, Signature, SigningKey};
    use p384::pkcs8::DecodePrivateKey;

    /// A generated P-384 root+leaf chain plus the leaf signing key.
    struct TestChain {
        root_der: Vec<u8>,
        leaf_der: Vec<u8>,
        leaf_sk: SigningKey,
        leaf_cn: String,
    }

    fn gen_chain(leaf_cn: &str) -> TestChain {
        let alg = &rcgen::PKCS_ECDSA_P384_SHA384;

        let root_kp = rcgen::KeyPair::generate_for(alg).unwrap();
        let mut root_params = rcgen::CertificateParams::new(vec![]).unwrap();
        root_params
            .distinguished_name
            .push(rcgen::DnType::CommonName, "frag-root");
        root_params.is_ca = rcgen::IsCa::Ca(rcgen::BasicConstraints::Unconstrained);
        let root = root_params.self_signed(&root_kp).unwrap();

        let leaf_kp = rcgen::KeyPair::generate_for(alg).unwrap();
        let mut leaf_params = rcgen::CertificateParams::new(vec![]).unwrap();
        leaf_params
            .distinguished_name
            .push(rcgen::DnType::CommonName, leaf_cn);
        let leaf = leaf_params.signed_by(&leaf_kp, &root, &root_kp).unwrap();

        let leaf_sk = SigningKey::from_pkcs8_der(leaf_kp.serialized_der()).unwrap();

        TestChain {
            root_der: root.der().to_vec(),
            leaf_der: leaf.der().to_vec(),
            leaf_sk,
            leaf_cn: leaf_cn.to_string(),
        }
    }

    /// Compute the did:x509 the given root+leaf would produce.
    fn did_for(chain: &TestChain) -> String {
        let hash = Sha256::digest(&chain.root_der);
        let b64 = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(hash);
        format!("did:x509:0:sha256:{b64}::CN:{}", chain.leaf_cn)
    }

    /// Build a COSE_Sign1 fragment envelope signed by the chain's leaf key.
    fn build_cose(chain: &TestChain, rego: &str, iss: &str, feed: &str) -> Vec<u8> {
        let protected = HeaderBuilder::new()
            .algorithm(iana::Algorithm::ES384)
            .content_type(CTY_REGO.to_string())
            .text_value("iss".to_string(), Value::Text(iss.to_string()))
            .text_value("feed".to_string(), Value::Text(feed.to_string()))
            .value(
                X5CHAIN_LABEL,
                Value::Array(vec![
                    Value::Bytes(chain.leaf_der.clone()),
                    Value::Bytes(chain.root_der.clone()),
                ]),
            )
            .build();

        CoseSign1Builder::new()
            .protected(protected)
            .payload(rego.as_bytes().to_vec())
            .create_signature(b"", |tbs| {
                let sig: Signature = chain.leaf_sk.sign(tbs);
                sig.to_bytes().to_vec()
            })
            .build()
            .to_tagged_vec()
            .unwrap()
    }

    const FRAG_REGO: &str = r#"package agent_fragments.infra
issuer := "did:web:contoso.example"
svn := "2"
containers := [{"OCI": {"Annotations": {"name": "infra-sidecar"}}}]
"#;

    #[test]
    fn good_fragment_accepts() {
        let chain = gen_chain("contoso-fragment-signer");
        let did = did_for(&chain);
        let feed = "infra";
        let cose = build_cose(&chain, FRAG_REGO, &did, feed);

        let expected = FragmentPolicy {
            issuer: did.clone(),
            feed: feed.to_string(),
            minimum_svn: 1,
        };
        let vf = verify_fragment(&cose, &expected).expect("valid fragment should verify");
        assert_eq!(vf.feed, "infra");
        assert_eq!(vf.svn, 2);
        assert_eq!(vf.namespace, "agent_fragments.infra");
        assert_eq!(vf.issuer, did);
    }

    #[test]
    fn tampered_payload_rejects() {
        let chain = gen_chain("contoso-fragment-signer");
        let did = did_for(&chain);
        let mut cose = build_cose(&chain, FRAG_REGO, &did, "infra");

        // Flip a byte somewhere in the middle (the payload region) so the
        // ECDSA signature — not merely CBOR parsing — rejects it.
        let mid = cose.len() / 2;
        cose[mid] ^= 0x01;

        let expected = FragmentPolicy {
            issuer: did,
            feed: "infra".to_string(),
            minimum_svn: 1,
        };
        assert!(
            verify_fragment(&cose, &expected).is_err(),
            "tampered envelope must be rejected"
        );
    }

    #[test]
    fn wrong_issuer_rejects() {
        let chain = gen_chain("contoso-fragment-signer");
        let real_did = did_for(&chain);
        let cose = build_cose(&chain, FRAG_REGO, &real_did, "infra");

        // The base policy pins a *different* issuer than the one that signed.
        let expected = FragmentPolicy {
            issuer: "did:x509:0:sha256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA::CN:someone-else"
                .to_string(),
            feed: "infra".to_string(),
            minimum_svn: 1,
        };
        assert!(
            verify_fragment(&cose, &expected).is_err(),
            "issuer mismatch must be rejected"
        );
    }

    #[test]
    fn low_svn_rejects() {
        let chain = gen_chain("contoso-fragment-signer");
        let did = did_for(&chain);
        let cose = build_cose(&chain, FRAG_REGO, &did, "infra");

        // Payload svn is 2; require a minimum of 5.
        let expected = FragmentPolicy {
            issuer: did,
            feed: "infra".to_string(),
            minimum_svn: 5,
        };
        assert!(
            verify_fragment(&cose, &expected).is_err(),
            "under-versioned fragment must be rejected"
        );
    }

    #[test]
    fn wrong_feed_rejects() {
        let chain = gen_chain("contoso-fragment-signer");
        let did = did_for(&chain);
        // Envelope feed is "infra"; policy expects "other".
        let cose = build_cose(&chain, FRAG_REGO, &did, "infra");
        let expected = FragmentPolicy {
            issuer: did,
            feed: "other".to_string(),
            minimum_svn: 1,
        };
        assert!(
            verify_fragment(&cose, &expected).is_err(),
            "feed mismatch must be rejected"
        );
    }
}

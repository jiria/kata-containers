// Copyright (c) 2024 Edgeless Systems GmbH
//
// SPDX-License-Identifier: Apache-2.0
//

//! Fragment *generation* (signing) — the producer side of the COSE_Sign1
//! policy-fragment format verified by [`crate::fragment_verify`].
//!
//! This module is feature-gated (`fragment-gen`) and is **not** compiled into
//! the shipped guest agent: only the offline `genpolicy-fragmentgen` tool
//! enables it. It deliberately shares the exact format constants
//! (`CTY_REGO`, `X5CHAIN_LABEL`, ES384) with the verifier so the producer and
//! consumer can never drift apart.

use anyhow::{anyhow, bail, Context, Result};
use base64::Engine as _;
use coset::{
    cbor::value::Value, iana, CoseSign1Builder, HeaderBuilder, TaggedCborSerializable,
};
use p384::ecdsa::{signature::Signer, Signature, SigningKey};
use sha2::{Digest, Sha256};
use x509_cert::der::Decode;
use x509_cert::Certificate;

use crate::fragment_verify::{subject_common_name, CTY_REGO, X5CHAIN_LABEL};

/// Sign a Rego fragment into a COSE_Sign1 envelope in the exact format
/// [`crate::fragment_verify::verify_fragment`] accepts: a protected header
/// carrying ES384, the `application/unknown+rego` content type, string-keyed
/// `iss` and `feed` claims, and the DER `x5chain` (leaf-first) at label 33.
///
/// `chain_der` must be leaf-first (`[leaf, intermediates.., root]`) and
/// `leaf_sk` must be the private key for `chain_der[0]`.
pub fn sign_fragment(
    leaf_sk: &SigningKey,
    chain_der: &[Vec<u8>],
    rego: &str,
    iss: &str,
    feed: &str,
) -> Result<Vec<u8>> {
    if chain_der.is_empty() {
        bail!("certificate chain is empty (need at least a leaf certificate)");
    }
    let x5chain = Value::Array(chain_der.iter().cloned().map(Value::Bytes).collect());

    let protected = HeaderBuilder::new()
        .algorithm(iana::Algorithm::ES384)
        .content_type(CTY_REGO.to_string())
        .text_value("iss".to_string(), Value::Text(iss.to_string()))
        .text_value("feed".to_string(), Value::Text(feed.to_string()))
        .value(X5CHAIN_LABEL, x5chain)
        .build();

    let cose = CoseSign1Builder::new()
        .protected(protected)
        .payload(rego.as_bytes().to_vec())
        .create_signature(b"", |tbs| {
            let sig: Signature = leaf_sk.sign(tbs);
            sig.to_bytes().to_vec()
        })
        .build();

    cose.to_tagged_vec()
        .map_err(|e| anyhow!("failed to serialize COSE_Sign1 envelope: {e:?}"))
}

/// Compute the `did:x509` identifier a given root DER + leaf CN produce — the
/// value that must be pinned as `issuer` in the measured base policy:
/// `did:x509:0:sha256:<b64url_nopad(sha256(root_DER))>::CN:<leaf_CN>`.
pub fn did_x509_for(root_der: &[u8], leaf_cn: &str) -> String {
    let hash = Sha256::digest(root_der);
    let b64 = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(hash);
    format!("did:x509:0:sha256:{b64}::CN:{leaf_cn}")
}

/// Extract the leaf certificate's Common Name from its DER encoding.
pub fn leaf_common_name(leaf_der: &[u8]) -> Result<String> {
    let cert = Certificate::from_der(leaf_der).context("parse leaf certificate DER")?;
    subject_common_name(&cert).context("leaf certificate has no Common Name")
}

/// A freshly generated P-384 root + leaf chain, for development and end-to-end
/// testing when no real signing PKI is available.
#[cfg(feature = "fragment-gen")]
pub struct DevChain {
    /// DER encoding of the self-signed root CA certificate.
    pub root_der: Vec<u8>,
    /// DER encoding of the leaf (signing) certificate.
    pub leaf_der: Vec<u8>,
    /// PKCS#8 DER encoding of the leaf private key.
    pub leaf_key_pkcs8_der: Vec<u8>,
    /// The leaf certificate's Common Name (part of the `did:x509`).
    pub leaf_cn: String,
}

/// Generate a self-signed P-384 root and a leaf certificate signed by it,
/// using ECDSA/P-384/SHA-384 (matching the verifier's ES384 expectation).
#[cfg(feature = "fragment-gen")]
pub fn gen_dev_chain(root_cn: &str, leaf_cn: &str) -> Result<DevChain> {
    let alg = &rcgen::PKCS_ECDSA_P384_SHA384;

    let root_kp = rcgen::KeyPair::generate_for(alg).context("generate root key pair")?;
    let mut root_params =
        rcgen::CertificateParams::new(vec![]).context("build root certificate params")?;
    root_params
        .distinguished_name
        .push(rcgen::DnType::CommonName, root_cn);
    root_params.is_ca = rcgen::IsCa::Ca(rcgen::BasicConstraints::Unconstrained);
    let root = root_params
        .self_signed(&root_kp)
        .context("self-sign root certificate")?;

    let leaf_kp = rcgen::KeyPair::generate_for(alg).context("generate leaf key pair")?;
    let mut leaf_params =
        rcgen::CertificateParams::new(vec![]).context("build leaf certificate params")?;
    leaf_params
        .distinguished_name
        .push(rcgen::DnType::CommonName, leaf_cn);
    let leaf = leaf_params
        .signed_by(&leaf_kp, &root, &root_kp)
        .context("sign leaf certificate with root")?;

    Ok(DevChain {
        root_der: root.der().to_vec(),
        leaf_der: leaf.der().to_vec(),
        leaf_key_pkcs8_der: leaf_kp.serialized_der().to_vec(),
        leaf_cn: leaf_cn.to_string(),
    })
}

#[cfg(all(test, feature = "fragment-gen"))]
mod tests {
    use super::*;
    use crate::fragment_verify::{verify_fragment, FragmentPolicy};
    use p384::pkcs8::DecodePrivateKey;

    const FRAG_REGO: &str = r#"package agent_fragments.infra
issuer := "did:web:contoso.example"
svn := "3"
containers := [{"OCI": {"Annotations": {"name": "infra-sidecar"}}}]
"#;

    #[test]
    fn generated_fragment_round_trips_through_verifier() {
        let chain = gen_dev_chain("frag-root", "contoso-fragment-signer").unwrap();
        let did = did_x509_for(&chain.root_der, &chain.leaf_cn);

        // The did computed from the DER helper must match the leaf CN parsed
        // back out of the certificate.
        assert_eq!(leaf_common_name(&chain.leaf_der).unwrap(), chain.leaf_cn);

        let leaf_sk = SigningKey::from_pkcs8_der(&chain.leaf_key_pkcs8_der).unwrap();
        let cose = sign_fragment(
            &leaf_sk,
            &[chain.leaf_der.clone(), chain.root_der.clone()],
            FRAG_REGO,
            &did,
            "infra",
        )
        .unwrap();

        let vf = verify_fragment(
            &cose,
            &FragmentPolicy {
                issuer: did.clone(),
                feed: "infra".to_string(),
                minimum_svn: i64::MIN,
            },
        )
        .expect("generated fragment must verify");
        assert_eq!(vf.svn, 3);
        assert_eq!(vf.feed, "infra");
        assert_eq!(vf.issuer, did);
        assert_eq!(vf.namespace, "agent_fragments.infra");

        // SVN gate boundary: accepts at the exact floor, rejects one above.
        assert!(verify_fragment(
            &cose,
            &FragmentPolicy {
                issuer: did.clone(),
                feed: "infra".to_string(),
                minimum_svn: vf.svn,
            },
        )
        .is_ok());
        assert!(verify_fragment(
            &cose,
            &FragmentPolicy {
                issuer: did,
                feed: "infra".to_string(),
                minimum_svn: vf.svn + 1,
            },
        )
        .is_err());
    }
}

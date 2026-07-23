// Copyright (c) 2024 Kata Containers contributors
//
// SPDX-License-Identifier: Apache-2.0
//

//! `genpolicy-fragmentgen` — sign a Rego policy fragment into the COSE_Sign1
//! envelope the kata guest verifies, and optionally push it as an OCI artifact.
//!
//! The envelope format and the round-trip verifier are shared with the
//! `kata-agent-policy` crate (`fragment_gen` / `fragment_verify`), so a
//! fragment produced here is guaranteed to be accepted by the in-guest
//! verifier — the tool proves this on every run unless `--no-verify` is given.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use anyhow::{bail, Context, Result};
use clap::Parser;
use kata_agent_policy::fragment_gen::{
    did_x509_for, gen_dev_chain, leaf_common_name, sign_fragment,
};
use kata_agent_policy::fragment_verify::{verify_fragment, FragmentPolicy};
use oci_client::client::{Client, ClientConfig, ClientProtocol, Config, ImageLayer};
use oci_client::manifest::OciImageManifest;
use oci_client::secrets::RegistryAuth;
use oci_client::Reference;
use p384::ecdsa::SigningKey;
use p384::pkcs8::DecodePrivateKey;
use x509_cert::der::{Decode, DecodePem, Encode};
use x509_cert::Certificate;

/// OCI artifactType for a kata policy fragment (matches the guest fetcher).
const FRAGMENT_ARTIFACT_TYPE: &str = "application/x-ms-ccepolicy-frag";
/// Media type of the COSE_Sign1 fragment layer (matches the guest fetcher).
const COSE_LAYER_MEDIA_TYPE: &str = "application/cose-x509+rego";
/// Empty-config media type for an OCI artifact manifest.
const EMPTY_CONFIG_MEDIA_TYPE: &str = "application/vnd.oci.empty.v1+json";

#[derive(Parser, Debug)]
#[command(
    name = "genpolicy-fragmentgen",
    about = "Sign a Rego policy fragment into a COSE_Sign1 OCI artifact for kata confidential containers",
    version
)]
struct Cli {
    /// Path to the Rego fragment module (must declare `package <ns>` and `svn := N`).
    #[arg(long)]
    rego: PathBuf,

    /// Feed name embedded in the envelope and enforced by the base policy.
    #[arg(long)]
    feed: String,

    /// Output path for the COSE_Sign1 envelope.
    #[arg(long, default_value = "fragment.cose")]
    out: PathBuf,

    /// Generate a self-signed P-384 dev root+leaf chain instead of supplying one.
    #[arg(long, conflicts_with_all = ["leaf_cert", "root_cert", "key"])]
    gen_dev_chain: bool,

    /// (dev chain) Common Name for the generated root CA.
    #[arg(long, default_value = "frag-root")]
    root_cn: String,

    /// (dev chain) Common Name for the generated leaf signer (part of the did:x509).
    #[arg(long, default_value = "contoso-fragment-signer")]
    signer_cn: String,

    /// (dev chain) Where to write the generated root certificate (DER).
    #[arg(long)]
    root_out: Option<PathBuf>,

    /// (dev chain) Where to write the generated leaf certificate (DER).
    #[arg(long)]
    leaf_out: Option<PathBuf>,

    /// (dev chain) Where to write the generated leaf private key (PKCS#8 DER).
    #[arg(long)]
    key_out: Option<PathBuf>,

    /// Leaf (signing) certificate, PEM or DER.
    #[arg(long, requires_all = ["root_cert", "key"])]
    leaf_cert: Option<PathBuf>,

    /// Root CA certificate (trust anchor), PEM or DER.
    #[arg(long)]
    root_cert: Option<PathBuf>,

    /// Leaf private key (PKCS#8), PEM or DER.
    #[arg(long)]
    key: Option<PathBuf>,

    /// Skip the built-in round-trip verification of the produced envelope.
    #[arg(long)]
    no_verify: bool,

    /// Push the produced artifact to this OCI reference (e.g. localhost:5001/frag/infra:1).
    #[arg(long)]
    push: Option<String>,

    /// Allow plain-HTTP push (only for localhost/loopback dev registries).
    #[arg(long)]
    plain_http: bool,
}

/// The resolved signing material: leaf-first DER chain + leaf key + leaf CN.
struct Signer {
    chain_der: Vec<Vec<u8>>,
    leaf_sk: SigningKey,
    root_der: Vec<u8>,
    leaf_cn: String,
}

/// Read a PEM-or-DER X.509 certificate and return its canonical DER encoding.
fn read_cert_der(path: &Path) -> Result<Vec<u8>> {
    let bytes = std::fs::read(path).with_context(|| format!("read certificate {path:?}"))?;
    let cert = if bytes.starts_with(b"-----BEGIN") {
        let text = std::str::from_utf8(&bytes).context("PEM certificate is not UTF-8")?;
        Certificate::from_pem(text).with_context(|| format!("parse PEM certificate {path:?}"))?
    } else {
        Certificate::from_der(&bytes).with_context(|| format!("parse DER certificate {path:?}"))?
    };
    cert.to_der().context("re-encode certificate to DER")
}

/// Read a PEM-or-DER PKCS#8 P-384 private key.
fn read_signing_key(path: &Path) -> Result<SigningKey> {
    let bytes = std::fs::read(path).with_context(|| format!("read private key {path:?}"))?;
    if bytes.starts_with(b"-----BEGIN") {
        let text = std::str::from_utf8(&bytes).context("PEM key is not UTF-8")?;
        SigningKey::from_pkcs8_pem(text).with_context(|| format!("parse PEM PKCS#8 key {path:?}"))
    } else {
        SigningKey::from_pkcs8_der(&bytes)
            .with_context(|| format!("parse DER PKCS#8 key {path:?}"))
    }
}

fn resolve_signer(cli: &Cli) -> Result<Signer> {
    if cli.gen_dev_chain {
        let chain = gen_dev_chain(&cli.root_cn, &cli.signer_cn)?;
        if let Some(p) = &cli.root_out {
            std::fs::write(p, &chain.root_der).with_context(|| format!("write root {p:?}"))?;
        }
        if let Some(p) = &cli.leaf_out {
            std::fs::write(p, &chain.leaf_der).with_context(|| format!("write leaf {p:?}"))?;
        }
        if let Some(p) = &cli.key_out {
            std::fs::write(p, &chain.leaf_key_pkcs8_der)
                .with_context(|| format!("write key {p:?}"))?;
        }
        let leaf_sk = SigningKey::from_pkcs8_der(&chain.leaf_key_pkcs8_der)
            .context("load generated leaf key")?;
        return Ok(Signer {
            chain_der: vec![chain.leaf_der, chain.root_der.clone()],
            leaf_sk,
            root_der: chain.root_der,
            leaf_cn: chain.leaf_cn,
        });
    }

    let leaf_path = cli
        .leaf_cert
        .as_ref()
        .context("supply --leaf-cert/--root-cert/--key or use --gen-dev-chain")?;
    let root_path = cli.root_cert.as_ref().context("--root-cert is required")?;
    let key_path = cli.key.as_ref().context("--key is required")?;

    let leaf_der = read_cert_der(leaf_path)?;
    let root_der = read_cert_der(root_path)?;
    let leaf_sk = read_signing_key(key_path)?;
    let leaf_cn = leaf_common_name(&leaf_der)?;

    Ok(Signer {
        chain_der: vec![leaf_der, root_der.clone()],
        leaf_sk,
        root_der,
        leaf_cn,
    })
}

async fn push_artifact(reference: &str, plain_http: bool, cose: &[u8]) -> Result<()> {
    let reference: Reference = reference
        .parse()
        .with_context(|| format!("invalid OCI reference {reference:?}"))?;

    let registry = reference.registry();
    let is_local = registry.starts_with("localhost")
        || registry.starts_with("127.0.0.1")
        || registry.starts_with("[::1]");
    if plain_http && !is_local {
        bail!("--plain-http is only allowed for localhost/loopback registries (got {registry})");
    }
    let protocol = if plain_http && is_local {
        ClientProtocol::Http
    } else {
        ClientProtocol::Https
    };

    let client = Client::new(ClientConfig {
        protocol,
        ..Default::default()
    });

    let layer = ImageLayer::new(cose.to_vec(), COSE_LAYER_MEDIA_TYPE.to_string(), None);
    let config = Config::new(b"{}".to_vec(), EMPTY_CONFIG_MEDIA_TYPE.to_string(), None);

    let mut manifest = OciImageManifest::build(std::slice::from_ref(&layer), &config, None);
    manifest.artifact_type = Some(FRAGMENT_ARTIFACT_TYPE.to_string());
    let mut annotations = BTreeMap::new();
    annotations.insert(
        "org.opencontainers.image.title".to_string(),
        "kata-policy-fragment".to_string(),
    );
    manifest.annotations = Some(annotations);

    client
        .push(
            &reference,
            std::slice::from_ref(&layer),
            config,
            &RegistryAuth::Anonymous,
            Some(manifest),
        )
        .await
        .with_context(|| format!("push fragment artifact to {reference}"))?;
    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();

    let rego = std::fs::read_to_string(&cli.rego)
        .with_context(|| format!("read fragment rego {:?}", cli.rego))?;

    let signer = resolve_signer(&cli)?;
    let issuer = did_x509_for(&signer.root_der, &signer.leaf_cn);

    let cose = sign_fragment(&signer.leaf_sk, &signer.chain_der, &rego, &issuer, &cli.feed)
        .context("sign fragment into COSE_Sign1")?;

    std::fs::write(&cli.out, &cose).with_context(|| format!("write envelope {:?}", cli.out))?;

    // Round-trip through the real in-guest verifier unless suppressed.
    let mut verified_svn = None;
    if !cli.no_verify {
        let vf = verify_fragment(
            &cose,
            &FragmentPolicy {
                issuer: issuer.clone(),
                feed: cli.feed.clone(),
                minimum_svn: i64::MIN,
            },
        )
        .context("produced envelope failed round-trip verification")?;
        verified_svn = Some(vf.svn);
    }

    println!("Wrote {} ({} bytes)", cli.out.display(), cose.len());
    println!("issuer (pin as `issuer` in the measured base policy):");
    println!("  {issuer}");
    println!("feed: {}", cli.feed);
    if let Some(svn) = verified_svn {
        println!("svn:  {svn}  (round-trip verification: OK)");
        println!();
        println!("genpolicy-settings.json fragments[] entry:");
        println!("  {{");
        println!("    \"issuer\": \"{issuer}\",");
        println!("    \"feed\": \"{}\",", cli.feed);
        println!("    \"minimum_svn\": {svn}");
        println!("  }}");
    } else {
        println!("round-trip verification: SKIPPED (--no-verify)");
    }

    if let Some(reference) = &cli.push {
        push_artifact(reference, cli.plain_http, &cose).await?;
        println!("Pushed artifact to {reference}");
    }

    Ok(())
}

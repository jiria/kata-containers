#!/usr/bin/env python3
"""Rewrite a sandbox's initdata image between the launch and the guest reading it.

This exists to answer one question with an experiment rather than an argument:
if a host stamps one policy's digest into the SNP report and then hands the
guest a *different* policy, does the guest notice?

The opening is real and needs no privileged trickery beyond being the host. The
runtime does two independent things with the initdata document
(virt_container/src/sandbox.rs):

  * hashes it and passes the digest as SevSnpConfig.host_data, which the
    hardware binds into the launch measurement, and
  * writes it into a block image the guest mounts and reads.

Nothing re-checks that the second still matches the first. So a host can stamp
document A and serve document B, and the report will still say A -- which is
precisely the lie an attacker needs. The guest's own boot-time binding check is
what closes it.

Two modes, and the second is what makes the first mean anything:

  flip     Serve a document that differs from the measured one, minimally and
           harmlessly: one character inside a comment in the policy's copyright
           header. Deliberately inert -- it changes no rule, disables no check,
           and leaves every dm-verity root hash intact, so nothing in the guest
           has any cause to object to it except the binding itself. If the pod
           still refuses to start, the binding check is the only thing that
           could have refused it.

           A meaner edit would be no more convincing: the guest aborts before
           the served document is ever evaluated, so what the swapped policy
           *says* never gets a chance to matter.

  control  Re-compress the *same* document. The bytes on disk change, the
           digest does not. If this boots normally, then rewriting the image is
           not itself what breaks the pod -- the content digest is -- and the
           flip result is not an artifact of a corrupted image.

Run it before starting the pod; it polls for a new image and rewrites it.
inotify is not available on the node image, hence the busy poll.

  sudo ./initdata-tamper.py --mode flip --deadline 120

Every rewrite is announced on stdout with the digest before and after, so the
run is auditable rather than something the reader has to take on faith.
"""

import argparse
import base64
import glob
import gzip
import hashlib
import os
import struct
import sys
import time

BASE = "/run/kata-containers/shared/initdata"

# initdata.rs: 8-byte magic, 8-byte little-endian payload length, gzip payload,
# then zero padding out to a sector boundary.
MAGIC = b"initdata"
HEADER = 16

# A single character, inside a comment, same length in and out: the smallest
# edit that is unambiguously not an attempt to weaken anything. Same length
# matters -- the image is sector-padded, and keeping the size fixed keeps the
# rewrite to exactly the bytes under test.
FLIP_FROM = b"# Copyright (c) 2023 Microsoft Corporation"
FLIP_TO = b"# copyright (c) 2023 Microsoft Corporation"


def digest(toml: bytes) -> str:
    """The value the runtime puts in HOST_DATA: sha256 of the document text."""
    return base64.b64encode(hashlib.sha256(toml).digest()).decode()


def read_image(path: str):
    with open(path, "rb") as fh:
        blob = fh.read()
    if len(blob) < HEADER or blob[:8] != MAGIC:
        return None, None
    length = struct.unpack("<Q", blob[8:HEADER])[0]
    if length <= 0 or HEADER + length > len(blob):
        return None, None
    return blob, gzip.decompress(blob[HEADER : HEADER + length])


def write_image(path: str, original: bytes, toml: bytes) -> bool:
    """Rewrite in place, keeping the image exactly as long as it was.

    Same length matters: the block device was sized for the original, and a
    short write would leave the tail of the previous payload behind.
    """
    payload = gzip.compress(toml, 9)
    new = MAGIC + struct.pack("<Q", len(payload)) + payload
    if len(new) > len(original):
        print("[tamper] rewritten payload is larger than the image; skipping", flush=True)
        return False
    new += b"\x00" * (len(original) - len(new))
    if new == original:
        print("[tamper] rewrite produced identical bytes; nothing was staged", flush=True)
        return False
    fd = os.open(path, os.O_WRONLY)
    try:
        os.write(fd, new)
        # Without this the guest can read the pre-write contents and the run
        # silently proves nothing.
        os.fsync(fd)
    finally:
        os.close(fd)
    return True


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--mode", choices=("flip", "control"), default="flip")
    ap.add_argument("--deadline", type=float, default=120.0,
                    help="stop after this many seconds (default: 120)")
    ap.add_argument("--once", action="store_true",
                    help="stop after the first rewrite instead of catching retries")
    args = ap.parse_args()

    if os.geteuid() != 0:
        print("[tamper] must run as root to write under " + BASE, flush=True)
        return 2

    start = time.time()
    print("[tamper] mode=%s watching %s" % (args.mode, BASE), flush=True)
    if args.mode == "flip":
        print("[tamper] will serve a policy edited by one character, inside a comment", flush=True)
    else:
        print("[tamper] will re-compress the same policy: new bytes, same digest", flush=True)

    seen = set()
    rewrites = 0
    while time.time() - start < args.deadline:
        for path in glob.glob(BASE + "/*/initdata.image"):
            sandbox = os.path.basename(os.path.dirname(path))
            # Only images this run is responsible for. Kubelet retries a failed
            # sandbox, and each retry gets a fresh one -- catching every retry is
            # the difference between a pod that is refused and a pod that is
            # refused once and then quietly starts on attempt two.
            if sandbox in seen:
                continue
            try:
                if os.path.getmtime(path) < start:
                    continue
                original, toml = read_image(path)
            except (OSError, EOFError, gzip.BadGzipFile):
                continue
            if original is None:
                continue

            before = digest(toml)
            if args.mode == "flip":
                if FLIP_FROM not in toml:
                    print("[tamper] %s: no copyright comment to edit" % sandbox[:12],
                          flush=True)
                    continue
                staged = toml.replace(FLIP_FROM, FLIP_TO)
            else:
                staged = toml

            if not write_image(path, original, staged):
                continue

            seen.add(sandbox)
            rewrites += 1
            after = digest(staged)
            print("[tamper] rewrote the initdata image for sandbox %s" % sandbox[:12], flush=True)
            print("[tamper]   digest the host stamped into HOST_DATA : %s" % before, flush=True)
            print("[tamper]   digest of the document now being served: %s%s"
                  % (after, "  (unchanged)" if after == before else "  (DIFFERENT)"), flush=True)
            if args.once:
                return 0
        time.sleep(0.002)

    print("[tamper] done: %d image(s) rewritten" % rewrites, flush=True)
    return 0 if rewrites else 3


if __name__ == "__main__":
    sys.exit(main())

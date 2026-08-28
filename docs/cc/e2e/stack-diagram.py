"""Architecture diagram for the exec demo.

Every box and label here corresponds to something verified in the source of the
manifold-cc branch; the citations live in stack-diagram.md next to it. Two
renderings from one description:

  exec    few boxes, large type, meant to be read in the seconds an opening
          title card gets on video
  detail  the same structure with the identifiers -- file names, annotation
          keys, struct fields -- for the doc and for engineers who ask

Regenerate rather than editing the SVG.
"""
import argparse

W, H = 1920, 1080

# Terminal-ish palette, so the card cuts against the demo footage rather than
# flashing white in the middle of it.
BG        = "#0d1117"
INK       = "#e6edf3"
DIM       = "#8b949e"
LINE      = "#30363d"
UNTRUSTED = "#f85149"   # the demo's red: the host, which is the adversary here
TRUSTED   = "#3fb950"   # the demo's green: measured, inside the boundary
DOC       = "#58a6ff"   # the demo's blue: the measured document and its digest
WARM      = "#d29922"


def esc(s):
    return (s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


class Svg:
    def __init__(self):
        self.p = []

    def add(self, s):
        self.p.append(s)

    def text(self, x, y, s, size=22, fill=INK, anchor="start", mono=False,
             weight="normal", opacity=1.0, spacing=0):
        fam = ("ui-monospace, 'Cascadia Mono', Consolas, monospace" if mono
               else "'Segoe UI', 'Helvetica Neue', Arial, sans-serif")
        ls = ' letter-spacing="%s"' % spacing if spacing else ""
        self.add('<text x="%s" y="%s" font-family="%s" font-size="%s" fill="%s" '
                 'text-anchor="%s" font-weight="%s" opacity="%s"%s>%s</text>'
                 % (x, y, fam, size, fill, anchor, weight, opacity, ls, esc(s)))

    def box(self, x, y, w, h, stroke=LINE, fill="none", rx=8, dash=None, width=2,
            opacity=1.0):
        d = ' stroke-dasharray="%s"' % dash if dash else ""
        self.add('<rect x="%s" y="%s" width="%s" height="%s" rx="%s" fill="%s" '
                 'stroke="%s" stroke-width="%s" opacity="%s"%s/>'
                 % (x, y, w, h, rx, fill, stroke, width, opacity, d))

    def line(self, x1, y1, x2, y2, stroke=LINE, width=2, dash=None, marker=None,
             opacity=1.0):
        d = ' stroke-dasharray="%s"' % dash if dash else ""
        m = ' marker-end="url(#%s)"' % marker if marker else ""
        self.add('<line x1="%s" y1="%s" x2="%s" y2="%s" stroke="%s" '
                 'stroke-width="%s" opacity="%s"%s%s/>'
                 % (x1, y1, x2, y2, stroke, width, opacity, d, m))

    def path(self, d, stroke=LINE, width=2, dash=None, marker=None, fill="none"):
        da = ' stroke-dasharray="%s"' % dash if dash else ""
        m = ' marker-end="url(#%s)"' % marker if marker else ""
        self.add('<path d="%s" fill="%s" stroke="%s" stroke-width="%s"%s%s/>'
                 % (d, fill, stroke, width, da, m))

    def render(self):
        heads = "".join(
            '<marker id="a-%s" viewBox="0 0 10 10" refX="9" refY="5" '
            'markerWidth="6" markerHeight="6" orient="auto-start-reverse">'
            '<path d="M 0 0 L 10 5 L 0 10 z" fill="%s"/></marker>' % (n, c)
            for n, c in (("dim", DIM), ("doc", DOC), ("ok", TRUSTED),
                         ("bad", UNTRUSTED), ("warm", WARM)))
        return ('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" '
                'viewBox="0 0 %d %d"><defs>%s</defs>'
                '<rect width="%d" height="%d" fill="%s"/>%s</svg>'
                % (W, H, W, H, heads, W, H, BG, "".join(self.p)))


def unit(s, x, y, w, title, lines, accent=LINE, mono_from=99, h=None,
         title_size=25, line_size=19, fill=None):
    """A labelled box. `lines` after index `mono_from` are set in monospace,
    which is how identifiers are distinguished from prose throughout."""
    h = h or (54 + 26 * len(lines))
    s.box(x, y, w, h, stroke=accent, fill=fill or "none", opacity=1 if fill else 0.9)
    s.text(x + 18, y + 34, title, size=title_size, fill=INK, weight="600")
    for i, ln in enumerate(lines):
        s.text(x + 18, y + 62 + 26 * i, ln, size=line_size,
               fill=DIM, mono=(i >= mono_from))
    return y + h


def build(detail):
    s = Svg()
    d = detail

    s.text(64, 58, "A pod's policy", size=34, weight="600")
    s.text(64, 94,
           "generated before deployment · measured into the hardware at launch · "
           "enforced inside the guest",
           size=22, fill=DIM)

    # Three zones, with a wide channel between the host and the guest: the two
    # paths the document takes have to be readable, and they are the argument.
    # The zone hugs its own content, which is taller in detail mode; the block
    # is then placed so the top and bottom margins roughly balance.
    ZY, ZH = (170, 700) if d else (300, 520)
    ZB = ZY + ZH
    AX, AW = 64, 372
    BX, BW = 470, 452
    CX, CW = 1148, 708
    BOUND = 1044

    for x, w, name, sub, col in (
            (AX, AW, "BEFORE DEPLOYMENT", "the customer's machine", DOC),
            (BX, BW, "THE HOST", "controls delivery — trusted with nothing", UNTRUSTED),
            (CX, CW, "INSIDE THE CVM", "measured at launch — decides everything", TRUSTED)):
        s.box(x, ZY, w, ZH, stroke=col, dash="6 8", width=2, rx=14, opacity=0.45)
        s.text(x + 18, ZY - 40, name, size=18, fill=col, weight="700", spacing=2)
        s.text(x + 18, ZY - 16, sub, size=18, fill=DIM)

    # The strongest line on the page. Everything left of it is the adversary.
    # The label sits on the guest side, in the gutter before column C, where
    # neither of the two curves crosses it.
    s.line(BOUND, ZY - 62, BOUND, ZB + 74, stroke=TRUSTED, width=3, opacity=0.6)
    s.add('<text x="%d" y="%d" transform="rotate(-90 %d %d)" font-family="'
          "'Segoe UI', Arial, sans-serif\" font-size=\"17\" fill=\"%s\" "
          'text-anchor="middle" letter-spacing="3" opacity="0.75">%s</text>'
          % (BOUND + 22, ZB - 110, BOUND + 22, ZB - 110, TRUSTED, "HARDWARE BOUNDARY"))

    # ---- column A: where the document comes from -----------------------------
    x, w = AX + 28, AW - 56
    y = ZY + 34
    y = unit(s, x, y, w, "pod spec",
             ["the workload as written:", "image, command, mounts"] if not d else
             ["the workload as written:", "image, command, mounts",
              "runtimeClassName: kata-cc"],
             mono_from=2, accent=LINE)
    s.line(x + 60, y, x + 60, y + 36, stroke=DOC, marker="a-doc")
    y = unit(s, x, y + 36, w, "genpolicy",
             ["derives the rules from", "this exact spec"] if not d else
             ["derives the rules from this exact",
              "spec — nothing is hand-written", "src/tools/genpolicy"],
             mono_from=2, accent=DOC)
    s.line(x + 60, y, x + 60, y + 36, stroke=DOC, marker="a-doc")
    y = unit(s, x, y + 36, w, "the measured document",
             (["policy.rego", "fragment-issuers.toml"] if not d else
              ['algorithm = "sha256"', "policy.rego", "fragment-issuers.toml",
               "aa.toml · cdh.toml"]),
             mono_from=0, accent=DOC, fill="#0d2136")
    s.text(x, y + 34, "every rule the guest will enforce,", size=18, fill=DIM)
    s.text(x, y + 58, "in one document", size=18, fill=DIM)
    if d:
        s.text(x, y + 92, "gzip + base64, carried as one", size=17, fill=DIM)
        s.text(x, y + 114, "annotation on the pod spec:", size=17, fill=DIM)
        s.text(x, y + 140, "…hypervisor.cc_init_data", size=16, fill=DOC, mono=True)

    # the document handed to the host
    s.path("M %d %d C %d %d %d %d %d %d"
           % (AX + AW, ZY + 137, AX + AW + 16, ZY + 137,
              BX - 16, ZY + 137, BX, ZY + 137),
           stroke=DOC, width=3, marker="a-doc")

    # ---- column B: the host --------------------------------------------------
    x, w = BX + 26, BW - 52
    y = ZY + 34
    stack = (["kubelet", "containerd + erofs snapshotter",
              "kata shim (runtime-rs)", "cloud-hypervisor on /dev/mshv"]
             if not d else
             ["kubelet", "containerd 2.3 + erofs snapshotter",
              "containerd-shim-kata-cc-v2", "cloud-hypervisor --features mshv,sev_snp"])
    bh = 46 + 40 * len(stack)
    s.box(x, y, w, bh, stroke=UNTRUSTED, rx=8, opacity=0.9)
    s.text(x + 18, y + 34, "the delivery path", size=25, weight="600")
    for i, ln in enumerate(stack):
        s.text(x + 18, y + 68 + 40 * i, ln, size=18 if not d else 16,
               fill=DIM, mono=d)
    y += bh + 28

    y = unit(s, x, y, w, "the image layers",
             (["each layer an EROFS image —", "the host presents its root hash"]
              if not d else
              ["layer.erofs + layer.erofs.dmverity",
               "the host computes and presents", "every root hash"]),
             mono_from=0 if d else 99, accent=UNTRUSTED)

    s.text(x, y + 38, "the host builds and serves", size=19, fill=UNTRUSTED)
    s.text(x, y + 62, "all of it — and nothing on", size=19, fill=UNTRUSTED)
    s.text(x, y + 86, "this side re-checks itself.", size=19, fill=UNTRUSTED)

    # ---- the two paths, in the channel ---------------------------------------
    # One document, two independent things done with it. Both arrive at the same
    # box, because the only place they are ever brought together is inside the
    # guest — which is the whole of moment 3.
    CM = CX - 8
    LX = BX + BW + 6
    s.path("M %d %d C %d %d %d %d %d %d"
           % (BX + BW, ZY + 124, BX + BW + 90, ZY + 124,
              CM - 110, ZY + 160, CM, ZY + 160),
           stroke=DOC, width=3, marker="a-doc")
    s.text(LX, ZY + 96, "the document", size=17, fill=DOC)
    s.text(LX, ZY + 118, "byte for byte", size=17, fill=DOC)

    s.path("M %d %d C %d %d %d %d %d %d"
           % (BX + BW, ZY + 464, BX + BW + 90, ZY + 464,
              CM - 110, ZY + 210, CM, ZY + 210),
           stroke=WARM, width=3, marker="a-warm")
    s.text(LX, ZY + 490, "its sha256,", size=17, fill=WARM)
    s.text(LX, ZY + 512, "stamped into", size=17, fill=WARM)
    s.text(LX, ZY + 534, "the hardware", size=17, fill=WARM)
    if d:
        s.text(LX, ZY + 558, "HOST_DATA", size=15, fill=WARM, mono=True)

    # ---- column C: the guest -------------------------------------------------
    x, w = CX + 26, CW - 52
    y = ZY + 26
    y = unit(s, x, y, w, "kata-agent — pid 1 in the guest",
             (["the init process, so a refusal takes the VM with it"]
              if not d else
              ["the init process (getpid() == 1), so an abort takes the VM",
               "src/agent/src/main.rs"]),
             mono_from=1, accent=TRUSTED)

    y = unit(s, x, y + 20, w, "does the served document match the measurement?",
             (["it hashes what it was actually served, reads what the",
               "hardware was told, and stops if the two differ"]
              if not d else
              ["hashes the initdata it was served, reads HOST_DATA back",
               "out of the SNP report via /dev/sev-guest, compares",
               "src/agent/src/hostdata.rs"]),
             mono_from=2, accent=TRUSTED, fill="#0d2a17", title_size=23)

    y = unit(s, x, y + 20, w, "then every request is answered against it",
             (["what may run, what may be mounted, who gets a shell",
               "every layer's root hash checked against the declared one"]
              if not d else
              ["Regorus evaluates policy.rego for each request",
               "declared vs presented dm-verity root hashes",
               "SRM: two-phase commit, fragment store, SVN floor"]),
             mono_from=99, accent=TRUSTED)

    unit(s, x, y + 20, w, "and it can be extended without redeploying",
         (["a signed rule, from an issuer the measured policy already",
           "named, at or above the version floor it set"]
          if not d else
          ["COSE_Sign1, did:x509 issuer, svn >= the measured floor",
           "host-delivered, trusted only on its signature",
           "security-reference-monitor/src/fragments.rs"]),
         mono_from=99 if not d else 2, accent=TRUSTED)

    # ---- the request path across the boundary --------------------------------
    ry = ZB + (72 if d else 52)
    s.line(BX + 40, ry, BOUND, ry, stroke=DIM, dash="5 6")
    s.line(BOUND, ry, CX + 24, ry, stroke=TRUSTED, width=3, marker="a-ok")
    if d:
        s.text(BX + 44, ry - 40,
               "CreateContainerRequest, ExecProcessRequest, …",
               size=17, fill=DIM, mono=True)
    s.text(BX + 44, ry - 16, "every container request — ttRPC over vsock",
           size=19, fill=DIM)
    s.text(CX + 44, ry + 8, "allow / deny", size=22, fill=TRUSTED, weight="600")

    s.text(64, H - 44,
           "The host decides what to deliver. The guest decides what to accept — "
           "against a document the hardware already measured.",
           size=22, fill=DIM)
    return s.render()


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=r"C:\Users\jiria\demo-exec")
    a = ap.parse_args()
    for name, det in (("stack-exec", False), ("stack-detail", True)):
        p = "%s\\%s.svg" % (a.out, name)
        open(p, "w", encoding="utf-8", newline="\n").write(build(det))
        print("wrote", p)

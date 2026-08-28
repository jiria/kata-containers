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

    def text_parts(self, x, y, parts, size=22, anchor="start", weight="normal"):
        """One text element, differently coloured runs — so allow and deny do
        not have to share a colour."""
        spans = "".join('<tspan fill="%s">%s</tspan>' % (c, esc(t))
                        for t, c in parts)
        self.add('<text x="%s" y="%s" font-family="%s" font-size="%s" '
                 'text-anchor="%s" font-weight="%s">%s</text>'
                 % (x, y, "'Segoe UI', 'Helvetica Neue', Arial, sans-serif",
                    size, anchor, weight, spans))

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
                         ("bad", UNTRUSTED), ("warm", WARM), ("ink", INK)))
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
           "enforced inside the guest · provable from outside",
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
    s.text(LX, ZY + 60, "the base document", size=17, fill=DOC)
    s.text(LX, ZY + 82, "byte for byte", size=17, fill=DOC)
    s.text(LX, ZY + 104, "and, later, fragments", size=17, fill=DOC)

    s.path("M %d %d C %d %d %d %d %d %d"
           % (BX + BW, ZY + 464, BX + BW + 90, ZY + 464,
              CM - 110, ZY + 210, CM, ZY + 210),
           stroke=WARM, width=3, marker="a-warm")
    # The caption sits above the curve's run through the channel; below it is
    # where the request line now lives.
    s.text(LX, ZY + 220, "its sha256,", size=17, fill=WARM)
    s.text(LX, ZY + 242, "stamped into", size=17, fill=WARM)
    s.text(LX, ZY + 264, "the hardware", size=17, fill=WARM)
    if d:
        s.text(LX, ZY + 286, "HOST_DATA", size=15, fill=WARM, mono=True)

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

    y4 = y + 20
    unit(s, x, y4, w, "and it can be extended without redeploying",
         (["a signed rule, from an issuer the measured policy already",
           "named, at or above the version floor it set"]
          if not d else
          ["COSE_Sign1, did:x509 issuer, svn >= the measured floor",
           "host-delivered, trusted only on its signature",
           "security-reference-monitor/src/fragments.rs"]),
         mono_from=99 if not d else 2, accent=TRUSTED)

    # The host delivers fragments too, and that was not on the page: both curves
    # above are launch-time, so the diagram read as though the host hands over
    # one document and is then done with it. It leaves from the same point as the
    # base document -- same untrusted path -- but dashed and landing on the last
    # card, because it arrives later, with the pod already running.
    FY = ZY + 124
    FT = y4 + 48
    s.path("M %d %d C %d %d, %d %d, %d %d C %d %d, %d %d, %d %d"
           % (BX + BW, FY,
              1040, FY, 1100, FY + 40, 1100, (FY + FT) / 2,
              1100, FT - 30, 1105, FT, CM, FT),
           stroke=DOC, width=3, dash="7 6", marker="a-doc")

    # ---- the request path across the boundary --------------------------------
    # This line is the one the audience must not skim: every request the
    # workload makes is answered on the far side of the boundary.
    ry = ZB + (72 if d else 52)
    s.line(BX + 40, ry, BOUND, ry, stroke=INK, dash="5 6", width=3, opacity=0.85)
    s.line(BOUND, ry, CX + 24, ry, stroke=INK, width=4, marker="a-ink")
    if d:
        s.text(BX + 44, ry - 44,
               "CreateContainerRequest, ExecProcessRequest, …",
               size=17, fill=DIM, mono=True)
    s.text(BX + 44, ry - 18, "every container request — ttRPC over vsock",
           size=23, fill=INK, weight="600")
    s.text_parts(CX + 44, ry + 8,
                 [("allow", TRUSTED), (" / ", DIM), ("deny", UNTRUSTED)],
                 size=24, weight="700")

    s.text(64, H - 76,
           "The host decides what to deliver. The guest decides what to accept — "
           "against a document the hardware already measured.",
           size=22, fill=DIM)
    s.text(64, H - 40,
           "And the customer decides whether to trust any of it: the same "
           "measurement, carried in a signed hardware report they can check "
           "from outside the machine.",
           size=22, fill=WARM)
    return s.render()


def build_simple():
    """The high-level card: the two sides, the boundary between them, and the
    one thing that happens at it. Names and boxes only."""
    s = Svg()

    s.text(64, 62, "Where the boundary is", size=38, weight="600")
    s.text(64, 102,
           "every call into the guest is answered against the measured document",
           size=24, fill=DIM)

    BOUND = 960
    PY, PH = 190, 700
    HX, HW = 90, 700
    GX, GW = 1130, 700

    s.box(HX, PY, HW, PH, stroke=UNTRUSTED, dash="6 8", rx=16, opacity=0.45)
    s.text(HX + 20, PY - 42, "THE HOST", size=22, fill=UNTRUSTED, weight="700",
           spacing=2)
    s.text(HX + 20, PY - 14, "outside the boundary", size=20, fill=DIM)

    s.box(GX, PY, GW, PH, stroke=TRUSTED, dash="6 8", rx=16, opacity=0.45)
    s.text(GX + 20, PY - 42, "THE CVM", size=22, fill=TRUSTED, weight="700",
           spacing=2)
    s.text(GX + 20, PY - 14, "measured at launch", size=20, fill=DIM)

    s.line(BOUND, PY - 66, BOUND, PY + PH + 40, stroke=TRUSTED, width=4,
           opacity=0.6)
    s.add('<text x="%d" y="%d" transform="rotate(-90 %d %d)" font-family="'
          "'Segoe UI', Arial, sans-serif\" font-size=\"19\" fill=\"%s\" "
          'text-anchor="middle" letter-spacing="4" opacity="0.8">%s</text>'
          % (BOUND - 26, PY + 620, BOUND - 26, PY + 620, TRUSTED,
             "HARDWARE BOUNDARY"))

    def plain(x, y, w, h, title, sub, accent, fill=None, ts=32):
        s.box(x, y, w, h, stroke=accent, fill=fill or "none", rx=10,
              opacity=1 if fill else 0.9)
        s.text(x + 26, y + (h / 2 + 10 if not sub else h / 2 - 4), title,
               size=ts, weight="600")
        if sub:
            s.text(x + 26, y + h / 2 + 30, sub, size=21, fill=DIM)

    x, w = HX + 40, HW - 80
    for i, (t, sub) in enumerate((
            ("kubelet", ""),
            ("containerd", ""),
            ("kata shim", ""),
            ("cloud-hypervisor", "MSHV · SEV-SNP"))):
        plain(x, PY + 46 + i * 158, w, 128, t, sub, UNTRUSTED)

    x, w = GX + 40, GW - 80
    plain(x, PY + 46, w, 128, "kata-agent", "pid 1 in the guest", TRUSTED)
    plain(x, PY + 204, w, 128, "the measured document", "policy.rego", DOC,
          fill="#0d2136", ts=30)
    plain(x, PY + 520, w, 128, "the workload's containers", "", TRUSTED, ts=30)

    # the agent answers against the document
    s.line(x + 90, PY + 174, x + 90, PY + 204, stroke=DOC, marker="a-doc",
           width=3)
    s.line(x + 90, PY + 332, x + 90, PY + 520, stroke=TRUSTED, marker="a-ok",
           width=3)
    s.text(x + 116, PY + 420, "only what the document allows", size=21,
           fill=TRUSTED)

    # the one thing that crosses, and the answer that comes back
    mid = (HX + HW + GX) / 2

    def label(y, txt, size, fill, weight="normal", pad=18, parts=None):
        w = size * 0.56 * len(txt) + pad * 2
        s.box(mid - w / 2, y - size - 6, w, size + 16, stroke=BG, fill=BG, rx=4,
              width=1)
        if parts:
            s.text_parts(mid, y, parts, size=size, anchor="middle",
                         weight=weight)
        else:
            s.text(mid, y, txt, size=size, fill=fill, weight=weight,
                   anchor="middle")

    ay = PY + 330
    s.line(HX + HW, ay, GX, ay, stroke=INK, width=4, marker="a-ink", dash="6 7")
    label(ay - 22, "every container request", 24, INK, "600")
    label(ay + 34, "ttRPC over vsock", 21, DIM)

    by = PY + 440
    s.line(GX, by, HX + HW, by, stroke=INK, width=4, marker="a-ink")
    label(by - 20, "allow / deny", 24, TRUSTED, "700",
          parts=[("allow", TRUSTED), (" / ", DIM), ("deny", UNTRUSTED)])

    s.text(64, H - 44,
           "The host asks. The guest answers — against a document it was "
           "measured with, and the host cannot change.",
           size=24, fill=DIM)
    return s.render()


def build_before():
    """Before deployment, on its own. Everything the guest will enforce is
    decided here, on the customer's machine, before the host sees the pod."""
    s = Svg()

    s.text(64, 62, "Before deployment", size=38, weight="600")
    s.text(64, 102,
           "the rules are derived from the pod spec — nothing is written by hand",
           size=24, fill=DIM)

    ZX, ZY, ZW, ZH = 70, 300, 1780, 420
    s.box(ZX, ZY, ZW, ZH, stroke=DOC, dash="6 8", rx=16, opacity=0.4)
    s.text(ZX + 24, ZY - 42, "THE CUSTOMER'S MACHINE", size=22, fill=DOC,
           weight="700", spacing=2)
    s.text(ZX + 24, ZY - 14, "before the host has seen anything", size=20,
           fill=DIM)

    BY, BH, BW = ZY + 60, 300, 380
    xs = [110, 550, 990, 1430]

    def card(x, title, lines, accent, fill=None, mono_from=99, mono_to=99,
             ts=29):
        s.box(x, BY, BW, BH, stroke=accent, fill=fill or "none", rx=10,
              opacity=1 if fill else 0.9)
        s.text(x + 26, BY + 56, title, size=ts, weight="600")
        for i, ln in enumerate(lines):
            s.text(x + 26, BY + 108 + 34 * i, ln, size=21, fill=DIM,
                   mono=(mono_from <= i <= mono_to))

    card(xs[0], "the pod spec",
         ["the workload as written",
          "image · command · mounts",
          "",
          "runtimeClassName: kata-cc"],
         LINE, mono_from=3, mono_to=3)

    card(xs[1], "genpolicy",
         ["reads that exact spec",
          "and derives the rules",
          "",
          "no hand-written policy"],
         DOC)

    card(xs[2], "the measured document",
         ["policy.rego",
          "fragment-issuers.toml",
          "aa.toml · cdh.toml",
          "",
          "one annotation on the pod"],
         DOC, fill="#0d2136", mono_from=0, mono_to=2, ts=27)

    card(xs[3], "its sha256",
         ["the digest of that document,",
          "stamped into the hardware",
          "when the guest launches",
          "",
          "nothing else is trusted"],
         WARM)
    # the digest is the only thing that leaves this stage as a fact
    s.text(xs[3] + 26, BY + 108 + 34 * 4, "", size=21)

    for i in range(3):
        x1 = xs[i] + BW
        s.line(x1 + 12, BY + BH / 2, xs[i + 1] - 12, BY + BH / 2,
               stroke=DOC if i < 2 else WARM, width=3,
               marker="a-doc" if i < 2 else "a-warm")

    s.text(64, H - 76,
           "Every rule the guest will enforce is decided here — and every request "
           "starts denied, so the generated rules turn on only what this pod needs.",
           size=23, fill=DIM)
    s.text(64, H - 40,
           "The host never contributes to this document. It only carries it.",
           size=23, fill=WARM)
    return s.render()


def build_launch():
    """How the document reaches the hardware, and how the guest re-derives it."""
    s = Svg()

    s.text(64, 62, "Into the hardware", size=38, weight="600")
    s.text(64, 102,
           "the digest is stamped in at launch — and the guest re-derives it "
           "from what it was actually served",
           size=24, fill=DIM)

    ZY, ZH = 300, 420
    BOUND = 960
    s.box(70, ZY, 860, ZH, stroke=UNTRUSTED, dash="6 8", rx=16, opacity=0.4)
    s.text(94, ZY - 42, "OUTSIDE THE GUEST", size=22, fill=UNTRUSTED,
           weight="700", spacing=2)
    s.text(94, ZY - 14, "the host carries the document", size=20, fill=DIM)

    s.box(990, ZY, 860, ZH, stroke=TRUSTED, dash="6 8", rx=16, opacity=0.4)
    s.text(1014, ZY - 42, "INSIDE THE CVM", size=22, fill=TRUSTED, weight="700",
           spacing=2)
    s.text(1014, ZY - 14, "and cannot reach past this line", size=20, fill=DIM)

    # The label goes below the line, on its axis: the gutter between the two
    # zones is too narrow to hold rotated text without touching a border.
    s.line(BOUND, ZY - 66, BOUND, ZY + ZH + 30, stroke=TRUSTED, width=4,
           opacity=0.6)
    s.add('<text x="%d" y="%d" transform="rotate(-90 %d %d)" font-family="'
          "'Segoe UI', Arial, sans-serif\" font-size=\"16\" fill=\"%s\" "
          'text-anchor="middle" letter-spacing="2" opacity="0.8">%s</text>'
          % (BOUND + 6, ZY + ZH + 140, BOUND + 6, ZY + ZH + 140, TRUSTED,
             "HARDWARE BOUNDARY"))

    BY, BH, BW = ZY + 60, 300, 380
    xs = [100, 545, 1010, 1455]

    def card(x, title, lines, accent, fill=None, mono=(), ts=27):
        s.box(x, BY, BW, BH, stroke=accent, fill=fill or "none", rx=10,
              opacity=1 if fill else 0.9)
        s.text(x + 26, BY + 56, title, size=ts, weight="600")
        for i, ln in enumerate(lines):
            s.text(x + 26, BY + 106 + 32 * i, ln, size=20, fill=DIM,
                   mono=(i in mono))

    card(xs[0], "the document",
         ["policy.rego and the rest,",
          "gzip + base64 as one TOML,",
          "carried on the pod spec",
          "",
          "…hypervisor.cc_init_data"],
         DOC, fill="#0d2136", mono={4})

    card(xs[1], "its digest",
         ["sha256 over that document,",
          "computed before the VM starts",
          "",
          "one 32-byte value — the only",
          "thing the hardware is told"],
         WARM)

    card(xs[2], "measured at launch",
         ["the digest goes in as HOST_DATA",
          "and is sealed into the report",
          "the platform signs",
          "",
          "nothing can change it after boot"],
         TRUSTED)

    card(xs[3], "checked in the guest",
         ["the agent hashes the initdata it",
          "was actually served, reads",
          "HOST_DATA back, and compares",
          "",
          "if they differ, it stops"],
         TRUSTED, fill="#0d2a17")

    for i, col in ((0, DOC), (1, WARM), (2, TRUSTED)):
        s.line(xs[i] + BW + 12, BY + BH / 2, xs[i + 1] - 12, BY + BH / 2,
               stroke=col, width=3,
               marker={DOC: "a-doc", WARM: "a-warm", TRUSTED: "a-ok"}[col])

    s.text(64, H - 76,
           "The host computes the digest and carries the document — but it "
           "cannot choose what the hardware records, and cannot change it after.",
           size=23, fill=DIM)
    s.text(64, H - 40,
           "The guest hashes what it was actually served. If the two ever "
           "differ it stops — and because the agent is pid 1, that takes the VM "
           "with it.",
           size=23, fill=WARM)
    return s.render()


def build_enforce():
    """Inside the guest: what happens to a request between arriving and being
    answered."""
    s = Svg()

    s.text(64, 62, "Inside the guest", size=38, weight="600")
    s.text(64, 102,
           "every request is answered against the measured document — there is "
           "no path around it",
           size=24, fill=DIM)

    ZY, ZH = 300, 420
    BOUND = 515
    s.text(94, ZY - 42, "FROM THE HOST", size=22, fill=UNTRUSTED, weight="700",
           spacing=2)
    s.text(94, ZY - 14, "it chooses what to ask for", size=20, fill=DIM)

    s.box(540, ZY, 1310, ZH, stroke=TRUSTED, dash="6 8", rx=16, opacity=0.4)
    s.text(564, ZY - 42, "INSIDE THE CVM", size=22, fill=TRUSTED, weight="700",
           spacing=2)
    s.text(564, ZY - 14, "where the answer is decided", size=20, fill=DIM)

    s.line(BOUND, ZY - 66, BOUND, ZY + ZH + 180, stroke=TRUSTED, width=4,
           opacity=0.6)
    s.add('<text x="%d" y="%d" transform="rotate(-90 %d %d)" font-family="'
          "'Segoe UI', Arial, sans-serif\" font-size=\"18\" fill=\"%s\" "
          'text-anchor="middle" letter-spacing="4" opacity="0.8">%s</text>'
          % (BOUND - 24, ZY + ZH + 100, BOUND - 24, ZY + ZH + 100, TRUSTED,
             "HARDWARE BOUNDARY"))

    BY, BH, BW = ZY + 60, 300, 380
    xs = [100, 570, 1015, 1460]

    def card(x, title, lines, accent, fill=None, mono=(), ts=27, parts=None):
        s.box(x, BY, BW, BH, stroke=accent, fill=fill or "none", rx=10,
              opacity=1 if fill else 0.9)
        if parts:
            s.text_parts(x + 26, BY + 56, parts, size=ts, weight="600")
        else:
            s.text(x + 26, BY + 56, title, size=ts, weight="600")
        for i, ln in enumerate(lines):
            s.text(x + 26, BY + 106 + 32 * i, ln, size=20, fill=DIM,
                   mono=(i in mono))

    card(xs[0], "the request",
         ["the host asks for something:",
          "start a container, run a process,",
          "mount a volume, open a shell",
          "",
          "ttRPC over vsock"],
         INK)

    card(xs[1], "the agent",
         ["pid 1 in the guest — every",
          "request arrives here, and there",
          "is no other way in",
          "",
          "it never asks the host anything"],
         TRUSTED)

    card(xs[2], "the document",
         ["the policy the hardware",
          "measured, evaluated per request",
          "",
          "every request starts denied",
          "layer hashes: declared vs served"],
         DOC, fill="#0d2136")

    card(xs[3], None,
         ["only what the document names",
          "is allowed to happen",
          "",
          "a refusal is the whole answer —",
          "nothing half-applied is left"],
         TRUSTED,
         parts=[("allow", TRUSTED), (" / ", DIM), ("deny", UNTRUSTED)], ts=29)

    for i, col in ((0, INK), (1, TRUSTED), (2, TRUSTED)):
        s.line(xs[i] + BW + 12, BY + BH / 2, xs[i + 1] - 12, BY + BH / 2,
               stroke=col, width=3,
               marker="a-ink" if col is INK else "a-ok")

    s.text(64, H - 76,
           "The host decides what to ask for. It does not get to decide what "
           "the answer is.",
           size=23, fill=DIM)
    s.text(64, H - 40,
           "And the document it is answered against is the one the hardware "
           "measured — the host cannot substitute another.",
           size=23, fill=WARM)
    return s.render()


def build_fragment():
    """Extending the measured policy at runtime, without redeploying."""
    s = Svg()

    s.text(64, 62, "Extending the policy", size=38, weight="600")
    s.text(64, 102,
           "a signed rule, from an issuer the measured document already named, "
           "at or above the version floor it set",
           size=24, fill=DIM)

    ZY, ZH = 300, 420
    BOUND = 515
    s.text(94, ZY - 42, "FROM THE HOST", size=22, fill=UNTRUSTED, weight="700",
           spacing=2)
    s.text(94, ZY - 14, "it delivers, and that is all", size=20, fill=DIM)

    s.box(540, ZY, 1310, ZH, stroke=TRUSTED, dash="6 8", rx=16, opacity=0.4)
    s.text(564, ZY - 42, "INSIDE THE CVM", size=22, fill=TRUSTED, weight="700",
           spacing=2)
    s.text(564, ZY - 14, "where it is accepted, or is not", size=20, fill=DIM)

    s.line(BOUND, ZY - 66, BOUND, ZY + ZH + 30, stroke=TRUSTED, width=4,
           opacity=0.6)
    s.add('<text x="%d" y="%d" transform="rotate(-90 %d %d)" font-family="'
          "'Segoe UI', Arial, sans-serif\" font-size=\"16\" fill=\"%s\" "
          'text-anchor="middle" letter-spacing="2" opacity="0.8">%s</text>'
          % (BOUND + 6, ZY + ZH + 140, BOUND + 6, ZY + ZH + 140, TRUSTED,
             "HARDWARE BOUNDARY"))

    BY, BH, BW = ZY + 60, 300, 380
    xs = [100, 570, 1015, 1460]

    def card(x, title, lines, accent, fill=None, mono=(), ts=27):
        s.box(x, BY, BW, BH, stroke=accent, fill=fill or "none", rx=10,
              opacity=1 if fill else 0.9)
        s.text(x + 26, BY + 56, title, size=ts, weight="600")
        for i, ln in enumerate(lines):
            s.text(x + 26, BY + 106 + 32 * i, ln, size=20, fill=DIM,
                   mono=(i in mono))

    card(xs[0], "the fragment",
         ["a signed Rego rule, handed in",
          "while the pod is running",
          "",
          "COSE_Sign1",
          "application/cose-x509+rego"],
         INK, mono={3, 4})

    card(xs[1], "whose rule is it",
         ["a did:x509 identity, derived",
          "from the certificate chain",
          "carried in the signature",
          "",
          "must be one the document named"],
         DOC, fill="#0d2136")

    card(xs[2], "is it new enough",
         ["every fragment carries an SVN,",
          "and the measured policy set",
          "the floor it must clear",
          "",
          "below the floor → refused"],
         WARM)

    card(xs[3], "then it applies",
         ["added in two phases, so a",
          "refusal leaves nothing behind",
          "",
          "the pod was never restarted,",
          "and the measurement is unchanged"],
         TRUSTED, fill="#0d2a17")

    for i, col in ((0, INK), (1, DOC), (2, WARM)):
        s.line(xs[i] + BW + 12, BY + BH / 2, xs[i + 1] - 12, BY + BH / 2,
               stroke=col, width=3,
               marker={INK: "a-ink", DOC: "a-doc", WARM: "a-warm"}[col])

    s.text(64, H - 76,
           "The host can deliver a fragment. It cannot make the guest accept "
           "one.",
           size=23, fill=DIM)
    s.text(64, H - 40,
           "Nothing about a fragment is trusted except its signature — and the "
           "measured document decides whose signature counts.",
           size=23, fill=WARM)
    return s.render()


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=r"C:\Users\jiria\demo-exec")
    a = ap.parse_args()
    for name, det in (("stack-exec", False), ("stack-detail", True)):
        p = "%s\\%s.svg" % (a.out, name)
        open(p, "w", encoding="utf-8", newline="\n").write(build(det))
        print("wrote", p)
    p = "%s\\stack-simple.svg" % a.out
    open(p, "w", encoding="utf-8", newline="\n").write(build_simple())
    print("wrote", p)
    p = "%s\\stack-before.svg" % a.out
    open(p, "w", encoding="utf-8", newline="\n").write(build_before())
    print("wrote", p)
    p = "%s\\stack-launch.svg" % a.out
    open(p, "w", encoding="utf-8", newline="\n").write(build_launch())
    print("wrote", p)
    p = "%s\\stack-enforce.svg" % a.out
    open(p, "w", encoding="utf-8", newline="\n").write(build_enforce())
    print("wrote", p)
    p = "%s\\stack-fragment.svg" % a.out
    open(p, "w", encoding="utf-8", newline="\n").write(build_fragment())
    print("wrote", p)

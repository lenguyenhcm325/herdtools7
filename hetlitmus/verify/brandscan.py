#!/usr/bin/env python3
"""brandscan -- does this harness NAME a machine its pair is not entitled to?

litmus/hetMachine.ml says which machine a (CPU ISA x GPU dialect) pair may name.
A render built for the wrong pair compiles, runs and reports like one built for
the right pair, so what the directory SAYS is all that separates them.

SCANNED: every string literal of a C/CUDA/HIP source, comments stripped and
adjacent literals joined the way the compiler joins them (a phrase split across
two chunks or two lines is still seen), plus README.md / comp.sh / Makefile in
full.  NOT the comments: a payload explains its lane by naming the part it was
derived for, and cites Fusco et al. by naming the part they measured -- and
de-branding a citation falsifies it.

Keyed on ENTITLEMENT, never a global ban: the (AArch64, cuda) lane prints "the
Grace half" because its row says GH200.  --entitled names the row whose words
are allowed; every other row's words are a finding.

  brandscan.py --entitled gh200|mi300a|none PATH...   # exit 1 on any hit
  brandscan.py --rows                                 # the vocabularies
"""

import argparse
import os
import re
import sys

# THE ROWS' VOCABULARIES.  One entry per machine row of litmus/hetMachine.ml,
# and every word that row's silicon goes by in this tree -- not the defines it
# stamps, because a sentence can name a part without using any define at all.
# "the x86 half" is in the AMD row for the same reason its HET_HOST_HALF is: an
# x86 host is HALF of that row's package, and no other row may call anything
# that.  (The bare word "x86" is not: the corpus, the ISA and the frontend are
# all named for it.)
ROWS = {
    "gh200": r"Grace|Hopper|GH200|NVLink|C2C",
    "mi300a": r"MI300A|MI300X|Infinity\s+Fabric|the\s+x86\s+half",
}
# The lanes, by the row each may name.  `none' is a pair with no machine row:
# registered-but-nameless (X86_64, cuda) or a pair in no row at all.
ENTITLEMENTS = sorted(ROWS) + ["none"]

SRC_EXT = (".c", ".h", ".cu", ".cuh", ".hip", ".inc", ".cpp")
WHOLE_FILE = ("README.md", "comp.sh", "Makefile")


def literals(text):
    """[(line, text)] for every run of adjacent C string literals, comments and
    character constants removed.  Adjacent literals are JOINED, because that is
    what the compiler does and what the reader sees."""
    out, i, n, line, cur = [], 0, len(text), 1, None
    while i < n:
        c = text[i]
        if c == "\n":
            line += 1
            i += 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            j = text.find("\n", i)
            i = n if j < 0 else j
            cur = None
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            line += text.count("\n", i, j)
            i = j
            cur = None
            continue
        if c == "'":                      # a character constant, never prose
            i += 1
            while i < n and text[i] != "'":
                i += 2 if text[i] == "\\" else 1
            i += 1
            continue
        if c == '"':
            start, i, buf = line, i + 1, []
            while i < n and text[i] != '"':
                if text[i] == "\\":
                    buf.append(text[i:i + 2])
                    i += 2
                    continue
                if text[i] == "\n":
                    line += 1
                buf.append(text[i])
                i += 1
            i += 1
            if cur is None:
                cur = [start, []]
                out.append(cur)
            cur[1].append("".join(buf))
            j = i
            while j < n and text[j] in " \t\n\r":
                j += 1
            if j >= n or text[j] != '"':
                cur = None
            continue
        if c not in " \t\r":
            cur = None
        i += 1
    return [(ln, "".join(parts)) for ln, parts in out]


def scan_file(path, forbidden):
    """[(path, line, row, word, excerpt)] for one file."""
    base = os.path.basename(path)
    if base not in WHOLE_FILE and not path.endswith(SRC_EXT):
        return []
    try:
        text = open(path, errors="replace").read()
    except OSError as e:
        return [(path, 0, "?", "?", "unreadable: %s" % e)]
    if base in WHOLE_FILE:
        chunks = [(k, l) for k, l in enumerate(text.splitlines(), 1)]
    else:
        chunks = literals(text)
    hits = []
    for ln, chunk in chunks:
        for row, rx in forbidden:
            m = rx.search(chunk)
            if m:
                hits.append((path, ln, row, m.group(0),
                             chunk.replace("\\n", " ").strip()[:150]))
    return hits


def scan(paths, entitled):
    forbidden = [(row, re.compile(rx))
                 for row, rx in sorted(ROWS.items()) if row != entitled]
    hits = []
    for p in paths:
        if os.path.isdir(p):
            for root, _dirs, files in os.walk(p):
                for f in sorted(files):
                    hits += scan_file(os.path.join(root, f), forbidden)
        else:
            hits += scan_file(p, forbidden)
    return hits


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--entitled", choices=ENTITLEMENTS,
                    help="the machine row whose words this lane may name")
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("--rows", action="store_true",
                    help="print the row vocabularies and exit")
    ap.add_argument("paths", nargs="*")
    a = ap.parse_args()
    if a.rows:
        for row, rx in sorted(ROWS.items()):
            print("%-8s %s" % (row, rx))
        return 0
    if a.entitled is None or not a.paths:
        ap.error("--entitled and at least one path are required")
    hits = scan(a.paths, a.entitled)
    for path, ln, row, word, excerpt in hits:
        print("%s:%d: names %r (the %s row's word; this lane is entitled to %s): %s"
              % (path, ln, word, row, a.entitled, excerpt), file=sys.stderr)
    if hits:
        print("FAIL: %d machine word(s) in a lane entitled to %s -- a harness that "
              "names the wrong machine runs and reports like one that names the "
              "right one" % (len(hits), a.entitled), file=sys.stderr)
        return 1
    if not a.quiet:
        print("brandscan: %d path(s), no machine word outside the %s row"
              % (len(a.paths), a.entitled))
    return 0


if __name__ == "__main__":
    sys.exit(main())

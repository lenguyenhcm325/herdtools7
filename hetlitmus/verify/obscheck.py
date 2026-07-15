#!/usr/bin/env python3
"""
obscheck.py -- DR1-A3 -- the OBSERVER-LIVENESS gate (guards F1).

WHY THIS GATE EXISTS.  statscheck.py feeds the verdict a *synthetic*
observer_unique_count; NO gate ever compiled the REAL emitted CPU observer loop.
So F1 -- the -O2 hoist that lifted the observer's `*a->x' read out of the perpetual
loop, broadcast one value N times, pinned observer_unique_count<=1, and rendered the
22 store-only (2+2W) tests' ONLY recovery channel inert -- was INVISIBLE to CI.  A
green gate is not evidence the mechanism runs; this is the FIFTH inert-mechanism bug
this project shipped green (P-fix _cond, B3 _weak, B4 stress, B4 spin, now F1).

WHAT IT DOES.  It EMITS a store-only het test through the real litmus7, EXTRACTS the
actual `*cpu_obs_args' struct and observer for-loop from the emitted `.cu' (extracted
from the artifact, NOT hand-copied, so emission drift is visible), wraps them in a
host translation unit, and compiles at `clang -O2' for BOTH x86-64 and the
GH200's aarch64 (cross).  It asserts -- scoped to the LOOP BODY, per the B5 gate rule
(do not count any load anywhere) -- that a per-iteration load survives inside EVERY
loop the compiler emits.  The `volatile const' fix guarantees a single straight loop
whose body reloads the observed pointer each iteration; the plain-`uint64_t*' hoist
instead emits an alias-versioned fast loop that broadcasts one hoisted value and whose
body has NO load (aarch64 `ld1r'; x86 `pshufd' splat).  "Every loop body has a load"
is therefore TRUE clean and FALSE once hoisted.

IT BITES BOTH WAYS (`--bite').  It strips `volatile' from the extracted TU (cmp-
verified to have actually changed it -- a sed that matches nothing "passes" for free,
which has happened here), recompiles, and the very same assertion must now FAIL.  A
gate never seen to fail is not evidence.
"""
import argparse
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
HET_DIR = os.path.join(ROOT, "hetlitmus", "tests", "het")

# A store-only (2+2W) shape: the observer is its ONLY channel, so it is exactly the
# family F1 killed and the one this gate must keep alive.
STORE_ONLY_TEST = "2+2W-cg-sys-fence.litmus"

# clang -O2 for the host, for both target ISAs the campaign runs on.  aarch64 is the
# GH200 CPU (where F1 was proven); x86-64 is the MI300A host and the dev box.
TARGETS = [
    ("x86-64",  ["clang", "-O2", "-S"]),
    ("aarch64", ["clang", "--target=aarch64-linux-gnu", "-O2", "-S"]),
]


def _env():
    env = dict(os.environ)
    env["PATH"] = (os.path.join(ROOT, "_build", "install", "default", "bin")
                   + os.pathsep + env["PATH"])
    return env


def emit_store_only(tmp):
    """Emit the real harness for a store-only test; return the path to its .cu."""
    out = os.path.join(tmp, "emit")
    os.makedirs(out, exist_ok=True)
    test = os.path.join(HET_DIR, STORE_ONLY_TEST)
    subprocess.run(["litmus7", "-set-libdir", os.path.join(ROOT, "litmus", "libdir"),
                    "-o", out, test],
                   cwd=ROOT, env=_env(), check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    base = os.path.splitext(STORE_ONLY_TEST)[0]
    cu = os.path.join(out, base, base + ".cu")
    if not os.path.exists(cu):
        raise SystemExit("obscheck: litmus7 did not emit %s" % cu)
    return cu


def extract_probe(cu):
    """Pull the REAL cpu_obs_args struct + observer loop from the emitted .cu and
       wrap them in a host TU.  Only the wrapper (signature + stubs) is the gate's;
       the struct and the loop are the artifact's, so a regression in either is
       visible here."""
    src = open(cu).read()
    ms = re.search(r'struct (\w*cpu_obs_args) \{.*?\n\};', src, re.S)
    if not ms:
        raise SystemExit("obscheck: could not find cpu_obs_args struct in the artifact")
    struct, sname = ms.group(0), ms.group(1)
    mt = re.search(r'static void\* \w*cpu_obs_thread\(void\* _a\) \{(.*?)\n\}', src, re.S)
    if not mt:
        raise SystemExit("obscheck: could not find cpu_obs_thread in the artifact")
    ml = re.search(r'(for \(int _n=0; _n<SIZE_OF_TEST; \+\+_n\) \{.*?\n  \})',
                   mt.group(1), re.S)
    if not ml:
        raise SystemExit("obscheck: could not find the observer loop in the artifact")
    loop = ml.group(1)
    if "volatile" not in struct:
        # Not a compile problem -- a SCIENCE problem: the emitter regressed F1.
        raise SystemExit("obscheck: the emitted cpu_obs_args struct has NO `volatile' "
                         "-- the F1 fix has regressed; the observer will hoist.\n"
                         + struct)
    tu = (
        "#include <stdint.h>\n"
        "#ifndef SIZE_OF_TEST\n#define SIZE_OF_TEST 64\n#endif\n"
        "typedef struct { int _d; } het_cpu_tally;\n"
        + struct + "\n"
        "void obs_probe(struct " + sname + "* a) {\n"
        "  " + loop + "\n"
        "}\n"
    )
    return tu, sname


# --- assembly analysis -----------------------------------------------------------
def _fn_lines(asm):
    out, on = [], False
    for line in asm.splitlines():
        if re.match(r'^obs_probe:', line):
            on = True
        if on:
            out.append(line)
        if on and re.match(r'^\s*\.size\s+obs_probe', line):
            break
    return out


def _is_load(line, isa):
    s = line.strip()
    if not s or s.startswith((".", "//", "#")):
        return False
    m = re.match(r'^([A-Za-z][\w.]*)\s+(.*)$', s)
    if not m:
        return False
    mn, ops = m.group(1), m.group(2)
    if isa == "aarch64":
        # every aarch64 load mnemonic starts `ld' (ldr/ldp/ld1r/ldur/ldar/...);
        # stores start `st'.  Scope: the mnemonic, not a substring anywhere.
        return mn.startswith("ld")
    # x86 AT&T: `<mov...> source, dest'.  A LOAD has a memory *source*, i.e. the
    # first operand contains `(...)'.  A store's memory operand is the *dest* (after
    # the comma), and `lea' computes an address without loading -- both excluded.
    if not mn.startswith("mov"):
        return False
    src = ops.split(",", 1)[0]
    return "(" in src


def _loops(fn):
    """Return [(header_idx, backedge_idx)] for every loop: a branch to a label that
       was defined at an EARLIER line is a loop back-edge."""
    label_idx = {}
    for i, l in enumerate(fn):
        m = re.match(r'^(\.[\w$.]+):', l.strip())
        if m:
            label_idx[m.group(1)] = i
    loops = []
    for j, l in enumerate(fn):
        m = re.match(r'^(b|b\.[a-z]+|cbn?z|tbn?z|j[a-z]+)\s+(\.[\w$.]+)', l.strip())
        if not m:
            continue
        i = label_idx.get(m.group(2))
        if i is not None and i < j:
            loops.append((i, j))
    return loops


def every_loop_has_load(asm, isa):
    """The gate's criterion: every loop body carries >=1 load (the observed-pointer
       reload).  Returns (ok, details)."""
    fn = _fn_lines(asm)
    loops = _loops(fn)
    if not loops:
        return False, "NO LOOP found in obs_probe -- cannot have proven per-iteration reload"
    details, ok = [], True
    for (i, j) in loops:
        nloads = sum(1 for k in range(i + 1, j + 1) if _is_load(fn[k], isa))
        details.append((fn[i].strip().rstrip(":"), nloads))
        if nloads == 0:
            ok = False
    return ok, details


def _compile_asm(cc, tu):
    with tempfile.NamedTemporaryFile("w", suffix=".c", delete=False) as f:
        f.write(tu)
        src = f.name
    try:
        r = subprocess.run(cc + [src, "-o", "-"], capture_output=True, text=True)
        if r.returncode != 0:
            raise SystemExit("obscheck: clang failed:\n" + r.stderr)
        return r.stdout
    finally:
        os.unlink(src)


def analyse(tu, quiet):
    """Compile `tu' for both ISAs; return True iff EVERY loop on EVERY ISA has a
       per-iteration load in its body."""
    ok_all = True
    for isa, cc in TARGETS:
        asm = _compile_asm(cc, tu)
        ok, det = every_loop_has_load(asm, isa)
        ok_all &= ok
        if isinstance(det, str):
            print("  [%-7s] %s" % (isa, det))
        elif not quiet or not ok:
            for (hdr, n) in det:
                mark = "load in body" if n else "*** NO LOAD IN BODY (hoisted)"
                print("  [%-7s] loop %-14s : %d load(s)  %s"
                      % (isa, hdr, n, mark))
    return ok_all


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-q", "--quiet", action="store_true")
    ap.add_argument("--bite", action="store_true",
                    help="prove this gate FAILS when `volatile' is stripped (the hoist)")
    a = ap.parse_args()

    tmp = tempfile.mkdtemp(prefix="obscheck.")
    try:
        cu = emit_store_only(tmp)
        tu, sname = extract_probe(cu)

        if a.bite:
            print("===== OBSCHECK BITE: strip `volatile' -> the observer must HOIST =====")
            bitten = re.sub(r'\bvolatile\b\s*', '', tu)
            if bitten == tu:
                print("  *** VACUOUS BITE: stripping `volatile' changed nothing")
                return 1
            ok = analyse(bitten, a.quiet)
            if ok:
                print("\n  *** DID NOT BITE: the hoisted observer still passed the gate")
                return 1
            print("\nOBSCHECK BITE OK (a hoisted observer FAILS the gate, as it must)")
            return 0

        print("===== OBSCHECK: does the REAL emitted observer reload per iteration? =====")
        print("  test   : %s   (store-only: the observer is its ONLY channel)" % STORE_ONLY_TEST)
        print("  struct : %s   (extracted from the emitted .cu)" % sname)
        ok = analyse(tu, a.quiet)
        print("\n" + "=" * 70)
        if ok:
            print("OBSCHECK: PASS  (per-iteration observed-pointer load survives -O2 on "
                  "x86-64 AND aarch64)")
            return 0
        print("OBSCHECK: FAIL  (the observer's read is HOISTED -- F1 has regressed; the "
              "store-only recovery channel is inert)")
        return 1
    finally:
        import shutil
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())

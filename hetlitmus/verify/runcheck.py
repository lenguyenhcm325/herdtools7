#!/usr/bin/env python3
"""runcheck.py -- the device-session wrapper (hetlitmus/hetlitmus-run.sh), driven
end to end on a box with no device.

The wrapper is the one command a hardware session runs, so the things it decides
-- which oracle pair the corpus and the flag select, which architecture the
binaries are built for, whether the campaign adjudicates or characterizes -- are
decided once, on a machine nobody is watching, and are visible afterwards only in
what it wrote down.  This gate drives the whole chain with the compiler and the
probe replaced by stand-ins (the wrapper's documented seams), so every one of
those decisions is checked here rather than on rented hardware.

  PHASE 1  --dry-run prints the plan and does NOT act: no results dir at all.
  PHASE 2  the chain end to end, twice: the NO-ORACLE pair (x86_64, cuda), which
           must take the characterization path by itself, and the populated pair
           (x86_64, hip), which must take the control map the table names.  Also
           --reuse-emitted.  Needs an x86_64 host: the committed fixture corpus
           is the x86 lane, and the emitted link targets refuse a foreign host.
  PHASE 3  the refusals, each by its own reason (mandatory flag, unknown target,
           no device for --arch auto, host-ISA mismatch, missing toolchain,
           unregistered pair).
  PHASE 4  campaign.py --characterization: the same runner that produces an
           adjudicating stop under a control map must produce none under it, and
           the two switches must be mutually exclusive in both directions.

`--bite' plants one defect per phase in a COPY of the script under test (never in
the tree) and requires the phase to redden.  `--hw' is the same wrapper on the
real device, which is the -nvcc lane's half of this gate.
"""
import argparse
import os
import platform
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
HETL = os.path.join(ROOT, "hetlitmus")
WRAPPER = os.path.join(HETL, "hetlitmus-run.sh")
CAMPAIGN = os.path.join(HETL, "campaign.py")
# The committed (x86_64, *) fixture: three tests, cut verbatim from a
# generate-x86.sh run and kept that way by hetlitmus-x86fixture.  Using it rather
# than generating the 411-test x86 corpus costs the gate nothing in fidelity.
X86_DIR = os.path.join(HETL, "tests", "het-x86")
AARCH64_DIR = os.path.join(HETL, "tests", "het")
X86_TESTS = ["MP-cg-sys-acqrel-2s-x86_64", "MP-cg-sys-relaxed-x86_64",
             "S-cg-sys-fence-x86_64"]

# One HetStats machine line, the whole interface between a harness and
# campaign.py.  A null with a measured dispersion, so a bound is reachable and
# nothing fires: what the scheduler does with it is the phase's subject.
STUB_STATS = ("HetStats %s oracle=NO-ORACLE obs=Never k=0 k_eff=0 k_runs=0 "
              "tier=none mu_upper=2.9957 tau_w=1.28 N_eff=100 tau_need=1 "
              "R_eff=100 p_bound=0.029957 P_rep=-1 R=10 usable=10 degen=0 "
              "ctrl=none win_n=1280 nwin=128 F_win=1.05 F_cell=1.02 r_hat=inf "
              "acf1=0.01 ks=pass ks_D=0.1 ks_Dcrit=0.2 ks_split=-1 N=100000 "
              "frames=100000 flags=0x0")

# The stand-in compiler: `-c' writes the object, a link writes an executable that
# prints the line above.  It is what lets the chain reach the campaign on a box
# with no device -- and the wrapper records that it was used.
STUB_CC = r'''#!/bin/sh
set -eu
out="" ; compile=0
while [ $# -gt 0 ]; do
  case "$1" in
    -c) compile=1 ;;
    -o) out="${2:-}" ; shift ;;
  esac
  shift
done
[ -n "$out" ] || { echo "stub-cc: no -o" >&2 ; exit 2 ; }
if [ "$compile" -eq 1 ]; then : > "$out" ; exit 0 ; fi
cat > "$out" <<'HARNESS'
#!/bin/sh
printf 'HetLitmus: shared-mem mode=stub\n'
printf '@@STATS@@\n' "$(basename "$0")"
HARNESS
chmod +x "$out"
'''

STUB_PROBE = r'''#!/bin/sh
# Stand-in for probe.sh / probe-hip.sh: the shape of a probe record, none of the
# facts.  The wrapper records that a stand-in was used.
set -eu
mkdir -p "$RESULTS"
{
  echo "probe_date=$(date -Is 2>/dev/null || date)"
  echo "host_uname_m=$(uname -m)"
  echo "probe_status=STUB"
} > "$RESULTS/probe.txt"
echo "stub-probe: wrote $RESULTS/probe.txt"
'''

# A runner whose one line WOULD be an adjudication under a control map: k_eff>=1
# stops an Allowed row OBSERVED, and k_runs>=3 corroborates a Disallowed row into
# CONFIRMED.  Under --characterization neither stop may be reachable.
MATCHY_RUNNER = r'''#!/usr/bin/env python3
import os, sys
d = sys.argv[1]
print("HetStats %s oracle=Disallowed obs=Sometimes k=1 k_eff=1 k_runs=3 "
      "tier=MATCH-would-be mu_upper=0 tau_w=1.28 N_eff=100 tau_need=1 R_eff=0 "
      "p_bound=-1 P_rep=0.632 R=10 usable=10 degen=0 ctrl=canary win_n=1280 "
      "nwin=128 F_win=1.05 F_cell=1.02 r_hat=inf acf1=0.01 ks=pass ks_D=0.1 "
      "ks_Dcrit=0.2 ks_split=-1 N=100000 frames=100000 flags=0x0"
      % os.path.basename(d))
'''

PATHS_SHIM = ('HETL="%s"\nREPO="%s"\nBIN="%s"\nLITMUS7="%s"\nLIBDIR="%s"\n'
              'HERDLIB="%s"\n')


def sh(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def write_exec(path, text):
    with open(path, "w") as fh:
        fh.write(text)
    os.chmod(path, 0o755)
    return path


def make_stubs(tmp):
    """The stand-in compiler and probe, in `tmp'.  Returns (cc, probe)."""
    cc = os.path.join(tmp, "stub-cc")
    write_exec(cc, STUB_CC.replace("@@STATS@@", STUB_STATS % "%s"))
    probe = os.path.join(tmp, "stub-probe.sh")
    write_exec(probe, STUB_PROBE)
    return cc, probe


def wrapper_env(cc, probe, extra=None):
    env = dict(os.environ)
    env["NVCC"] = cc
    env["HIPCC"] = cc
    env["HET_PROBE_SH"] = probe
    if extra:
        env.update(extra)
    return env


def run_wrapper(wrapper, args, env=None):
    return sh(["bash", wrapper] + args, env=env)


def state_rows(path):
    """(test, class, stop, runs) per row of a campaign state file."""
    rows = []
    with open(path) as fh:
        for i, line in enumerate(fh):
            f = line.rstrip("\n").split(",")
            if i == 0 or len(f) < 5:
                continue
            rows.append((f[0], f[1], f[2], int(f[4])))
    return rows


# ---------------------------------------------------------------------------
# PHASE 1 -- --dry-run says what it would do, and does none of it.
# ---------------------------------------------------------------------------
PLAN_FRAGMENTS = [
    "step 1  preflight", "step 2  probe", "step 3  emit", "step 4  compile",
    "step 5  smoke rungs", "step 6  campaign", "step 7  collect",
    "(X86_64, cuda)", "characterization", "sm_86",
]


def phase1_dryrun(wrapper, quiet=False):
    bad = []
    tmp = tempfile.mkdtemp(prefix="runcheck1.")
    try:
        out = os.path.join(tmp, "never-created")
        r = run_wrapper(wrapper, ["--gpu-target", "cuda", "--corpus", X86_DIR,
                                  "--arch", "sm_86", "--out", out, "--dry-run"])
        if r.returncode != 0:
            bad.append("--dry-run exited %d: %s" % (r.returncode,
                                                    r.stderr.strip()[-200:]))
        for frag in PLAN_FRAGMENTS:
            if frag not in r.stdout:
                bad.append("the plan never mentions %r -- a plan that omits a step "
                           "or a resolved value is not the plan that would run"
                           % frag)
        if os.path.exists(out):
            bad.append("--dry-run CREATED %s -- it must write nothing at all" % out)
        for junk in ("emit", "campaign-state.csv", "probe.txt"):
            if os.path.exists(os.path.join(out, junk)):
                bad.append("--dry-run produced %s" % junk)
        if not quiet and not bad:
            print("      the plan names all 7 steps, the pair, the mode and the "
                  "arch; nothing was written")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return bad


# ---------------------------------------------------------------------------
# PHASE 2 -- the chain end to end, on both pairs the x86 fixture can reach.
# ---------------------------------------------------------------------------
def _e2e(wrapper, tmp, target, arch, want_mode, want_classes, quiet):
    """One full chain.  Returns (failures, results dir)."""
    bad = []
    cc, probe = make_stubs(tmp)
    out = os.path.join(tmp, "out-" + target)
    r = run_wrapper(wrapper,
                    ["--gpu-target", target, "--corpus", X86_DIR, "--arch", arch,
                     "--budget-runs", "10", "--out", out],
                    env=wrapper_env(cc, probe))
    if r.returncode != 0:
        bad.append("%s chain exited %d:\n%s\n%s"
                   % (target, r.returncode, r.stdout[-1200:], r.stderr[-600:]))
        return bad, out
    # THE RESULTS DIR IS THE DELIVERABLE: a session that ran but recorded nothing
    # cannot be read afterwards.
    for f in ("run-record.txt", "probe.txt", "build-failures.txt", "summary.txt",
              "campaign-state.csv", "campaign.log", "emit.log"):
        if not os.path.exists(os.path.join(out, f)):
            bad.append("%s: the results dir has no %s" % (target, f))
    if os.path.getsize(os.path.join(out, "build-failures.txt")) != 0:
        bad.append("%s: the build failure table is not empty on a chain that "
                   "reported success" % target)
    for t in X86_TESTS:
        for f in (os.path.join("build", t + ".log"),
                  os.path.join("emit", t, t + "." + ("cu" if target == "cuda"
                                                     else "hip")),
                  os.path.join("emit", t, t)):
            if not os.path.exists(os.path.join(out, f)):
                bad.append("%s: %s missing from the results dir" % (target, f))
    # The HetStats line is what every row was scored from, and campaign.py keeps
    # none of it: the session's own copy is the only place it survives.
    for t in X86_TESTS:
        log = os.path.join(out, "hetstats", t + ".log")
        if not os.path.exists(log):
            bad.append("%s: no harness transcript for %s in hetstats/" % (target, t))
        elif "HetStats %s " % t not in open(log).read():
            bad.append("%s: the transcript of %s carries no HetStats line"
                       % (target, t))
    summary = open(os.path.join(out, "summary.txt")).read()
    if want_mode not in summary:
        bad.append("%s: the summary does not say %r -- it says:\n%s"
                   % (target, want_mode, summary))
    record = open(os.path.join(out, "run-record.txt")).read()
    for frag in ("arch=" + arch, "mode=" + want_mode, "seam_probe=STUB",
                 "seam_compiler=OVERRIDDEN"):
        if frag not in record:
            bad.append("%s: run-record.txt does not carry %r -- the value the "
                       "session turned on is not a recorded fact" % (target, frag))
    rows = state_rows(os.path.join(out, "campaign-state.csv"))
    got = sorted((t, c) for t, c, _, _ in rows)
    if got != sorted(want_classes.items()):
        bad.append("%s: campaign state classes %s, want %s"
                   % (target, got, sorted(want_classes.items())))
    if not quiet and not bad:
        print("      %-4s -> %-16s %d row(s) %s"
              % (target, want_mode, len(rows),
                 ", ".join("%s=%s" % (t, c) for t, c, _, _ in rows)))
    return bad, out


def phase2_e2e(wrapper, quiet=False):
    if platform.machine() != "x86_64":
        print("      NOT RUN on %s: the fixture corpus carries an x86_64 CPU "
              "column and the emitted link targets refuse a foreign host, so "
              "this phase has no chain to drive here (the refusal itself is "
              "asserted in phase 3)." % platform.machine())
        return []
    bad = []
    tmp = tempfile.mkdtemp(prefix="runcheck2.")
    try:
        # (X86_64, cuda) is registered WITHOUT an oracle, so the wrapper must
        # select the characterization path from the emission, unprompted.
        b, out = _e2e(wrapper, tmp, "cuda", "sm_86", "characterization",
                      dict.fromkeys(X86_TESTS, "NO-ORACLE"), quiet)
        bad += b
        # (X86_64, hip) IS populated, so the same corpus must take the control map
        # the table names -- classes read out of it, not defaulted.
        bad += _e2e(wrapper, tmp, "hip", "gfx942", "oracle",
                    {"MP-cg-sys-relaxed-x86_64": "Allowed",
                     "MP-cg-sys-acqrel-2s-x86_64": "NO-ORACLE",
                     "S-cg-sys-fence-x86_64": "NO-ORACLE"}, quiet)[0]
        # --reuse-emitted: the same results dir, no emission, same answers.
        cc, probe = make_stubs(tmp)
        before = open(os.path.join(out, "emit.log")).read()
        r = run_wrapper(wrapper,
                        ["--gpu-target", "cuda", "--corpus", X86_DIR, "--arch",
                         "sm_86", "--budget-runs", "10", "--out", out,
                         "--reuse-emitted"],
                        env=wrapper_env(cc, probe))
        if r.returncode != 0:
            bad.append("--reuse-emitted exited %d:\n%s"
                       % (r.returncode, (r.stdout + r.stderr)[-800:]))
        elif open(os.path.join(out, "emit.log")).read() != before:
            bad.append("--reuse-emitted re-emitted the corpus (emit.log changed)")
        elif "reused 3 harness dir(s)" not in r.stdout:
            bad.append("--reuse-emitted did not say it reused the emission")
        elif not quiet:
            print("      --reuse-emitted verified the 3 dirs and emitted nothing")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return bad


# ---------------------------------------------------------------------------
# PHASE 3 -- the refusals.  Each is checked by its OWN reason: a wrapper that
# refused everything with one message would pass a bare exit-code check.
# ---------------------------------------------------------------------------
def phase3_refusals(wrapper, quiet=False):
    bad = []
    tmp = tempfile.mkdtemp(prefix="runcheck3.")
    try:
        cc, probe = make_stubs(tmp)
        # A PATH with neither device-listing tool, to make --arch auto see nothing.
        nogpu = os.path.join(tmp, "nogpu-bin")
        os.makedirs(nogpu)
        for tool in ("nvidia-smi", "nvptx-arch", "amdgpu-arch", "rocminfo"):
            write_exec(os.path.join(nogpu, tool), "#!/bin/sh\nexit 0\n")
        # The corpus whose CPU lane is NOT this host's, for the mismatch refusal.
        foreign = AARCH64_DIR if platform.machine() == "x86_64" else X86_DIR
        cases = [
            ("no --gpu-target",
             ["--corpus", X86_DIR], {}, "--gpu-target is mandatory"),
            ("unknown --gpu-target",
             ["--gpu-target", "sycl", "--corpus", X86_DIR], {},
             "is not a GPU dialect"),
            ("--arch auto with no device visible",
             ["--gpu-target", "cuda", "--corpus", X86_DIR, "--arch", "auto"],
             {"PATH": nogpu + os.pathsep + os.environ["PATH"]},
             "found no cuda device on this box"),
            ("host-ISA mismatch",
             ["--gpu-target", "cuda", "--corpus", foreign, "--arch", "sm_86"], {},
             "uname -m is"),
            ("toolchain missing",
             ["--gpu-target", "cuda", "--corpus", X86_DIR, "--arch", "sm_86"],
             {"NVCC": os.path.join(tmp, "no-such-nvcc")}, "is not on PATH"),
            ("unregistered pair",
             ["--gpu-target", "hip", "--corpus", AARCH64_DIR, "--arch", "gfx942"],
             {}, "is not in litmus/hetOracle.ml"),
        ]
        for name, args, extra, frag in cases:
            env = wrapper_env(cc, probe, extra)
            r = run_wrapper(wrapper, args + ["--dry-run"], env=env)
            if r.returncode != 2:
                bad.append("[%s] exited %d, want 2 (fail closed): %s"
                           % (name, r.returncode,
                              (r.stdout + r.stderr).strip()[-300:]))
            elif frag not in r.stderr:
                bad.append("[%s] refused for the wrong reason -- %r is not in: %s"
                           % (name, frag, r.stderr.strip()[-300:]))
            elif not quiet:
                print("      %-34s rc=2, names it" % name)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return bad


# ---------------------------------------------------------------------------
# PHASE 4 -- campaign.py --characterization.
# ---------------------------------------------------------------------------
CHAR_TESTS = ["CH-one", "CH-two"]


def _campaign(campaign, corpus, runner, state, extra):
    return sh([sys.executable, campaign, "--corpus", corpus, "--runner",
               "%s %s {dir}" % (sys.executable, runner), "--state", state,
               "--budget-runs", "30", "--allowed-budget-runs", "10"] + extra)


def phase4_characterization(campaign, quiet=False):
    bad = []
    tmp = tempfile.mkdtemp(prefix="runcheck4.")
    try:
        corpus = os.path.join(tmp, "corpus")
        for t in CHAR_TESTS:
            os.makedirs(os.path.join(corpus, t))
        runner = write_exec(os.path.join(tmp, "matchy.py"), MATCHY_RUNNER)
        cmap = os.path.join(tmp, "control-map.csv")
        with open(cmap, "w") as fh:
            fh.write("Test,Expected,Mu,Canary\n"
                     "CH-one,Allowed,-,CH-two\nCH-two,Disallowed,mu,CH-two\n")

        # EXACTLY ONE of the two switches, both ways.
        for name, extra, frag in (
                ("neither switch", [], "one of the arguments"),
                ("both switches", ["--control-map", cmap, "--characterization"],
                 "not allowed with argument")):
            r = _campaign(campaign, corpus, runner,
                          os.path.join(tmp, "s0.csv"), extra)
            if r.returncode != 2 or frag not in r.stderr:
                bad.append("[%s] exited %d without %r: %s"
                           % (name, r.returncode, frag, r.stderr.strip()[-200:]))
            elif not quiet:
                print("      %-16s refused (rc=2)" % name)

        # THE RUNNER IS ADJUDICATING-CAPABLE: under a control map its one line
        # stops an Allowed row OBSERVED and corroborates a Disallowed row into
        # CONFIRMED.  Without this the phase below would prove nothing -- a runner
        # that can produce neither would "pass" it for free.
        st_map = os.path.join(tmp, "mapped.csv")
        r = _campaign(campaign, corpus, runner, st_map, ["--control-map", cmap])
        stops = {t: s for t, _, s, _ in state_rows(st_map)}
        if stops != {"CH-one": "OBSERVED", "CH-two": "CONFIRMED"}:
            bad.append("the control-map run gave %s, want CH-one OBSERVED and "
                       "CH-two CONFIRMED -- the runner is not adjudicating-capable "
                       "and the characterization run below proves nothing" % stops)
        elif not quiet:
            print("      the same runner adjudicates under a map: OBSERVED + "
                  "CONFIRMED (rc=%d)" % r.returncode)

        # ... AND UNDER --characterization IT CANNOT.
        st_ch = os.path.join(tmp, "char.csv")
        r = _campaign(campaign, corpus, runner, st_ch, ["--characterization"])
        if r.returncode != 0:
            bad.append("--characterization exited %d: %s"
                       % (r.returncode, (r.stdout + r.stderr)[-400:]))
        rows = state_rows(st_ch)
        for t, cls, stop, runs in rows:
            if cls != "NO-ORACLE":
                bad.append("%s is classed %s under --characterization" % (t, cls))
            if stop not in ("BOUND-MET", "BUDGET"):
                bad.append("%s stopped %s under --characterization -- only a bound "
                           "or a spent budget is reachable here" % (t, stop))
            # The bound-row budget (30), not the Allowed sweep's (10): a row
            # scheduled as Allowed would have stopped three invocations earlier.
            if stop == "BUDGET" and runs != 30:
                bad.append("%s ran %d runs, want the bound-row budget 30 -- an "
                           "Allowed sweep was scheduled after all" % (t, runs))
        if len(rows) != len(CHAR_TESTS):
            bad.append("--characterization scheduled %d row(s) of %d: every test "
                       "must run" % (len(rows), len(CHAR_TESTS)))
        for word in ("OBSERVED", "CONFIRMED", "MISMATCH", "MATCH"):
            if word in open(st_ch).read():
                bad.append("the characterization state carries %r -- a pair with no "
                           "oracle has no prediction to agree or disagree with"
                           % word)
            if word in r.stdout:
                bad.append("the characterization summary carries %r" % word)
        # THE ONE PATH BY WHICH AN ADJUDICATION COULD STILL REACH A
        # CHARACTERIZATION RUN: a state file carries terminal stops, and a
        # resumed row inherits them.  Handing the run above's OWN state (CH-one
        # OBSERVED, CH-two CONFIRMED) to --characterization must fail closed.
        r = _campaign(campaign, corpus, runner, st_map, ["--characterization"])
        if r.returncode != 2:
            bad.append("resuming an ORACLE state under --characterization exited "
                       "%d, want 2: the row would have inherited the OBSERVED or "
                       "CONFIRMED an oracle campaign banked" % r.returncode)
        elif "classes its rows differently" not in r.stderr:
            bad.append("the cross-class resume was refused for another reason: %s"
                       % r.stderr.strip()[-200:])
        elif not quiet:
            print("      an oracle state cannot be resumed by a characterization "
                  "run (rc=2)")
        # D-MV5's banned artefact: nothing may have written a map to stand in for
        # the one this pair does not have.
        made = [f for f in os.listdir(tmp) if "control-map" in f and f != "control-map.csv"]
        if made:
            bad.append("a stand-in control map was created: %s" % made)
        if not quiet and not bad:
            print("      --characterization: %d NO-ORACLE row(s), each to its bound "
                  "or its full budget, none adjudicating" % len(rows))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return bad


# ---------------------------------------------------------------------------
# THE BITES.  One planted defect per phase, in a copy of the script under test.
# ---------------------------------------------------------------------------
def copy_wrapper(tmp, mutate):
    """A mutated hetlitmus-run.sh in its own dir, beside a paths.sh that points
    back at the real tree.  The tree itself is never written to."""
    d = tempfile.mkdtemp(dir=tmp)
    src = open(WRAPPER).read()
    new = mutate(src)
    if new == src:
        return None
    with open(os.path.join(d, "paths.sh"), "w") as fh:
        fh.write(PATHS_SHIM % (HETL, ROOT,
                               os.path.join(ROOT, "_build", "install", "default",
                                            "bin"),
                               os.path.join(ROOT, "_build", "install", "default",
                                            "bin", "litmus7"),
                               os.path.join(ROOT, "litmus", "libdir"),
                               os.path.join(ROOT, "herd", "libdir")))
    return write_exec(os.path.join(d, "hetlitmus-run.sh"), new)


def copy_campaign(tmp, mutate):
    d = tempfile.mkdtemp(dir=tmp)
    src = open(CAMPAIGN).read()
    new = mutate(src)
    if new == src:
        return None
    return write_exec(os.path.join(d, "campaign.py"), new)


INJECTIONS = [
    ("1", "wrapper", "--dry-run creates the results dir anyway",
     lambda s: s.replace('if [ "$DRYRUN" -eq 1 ]; then\n  echo\n',
                         'mkdir -p "$OUT"\nif [ "$DRYRUN" -eq 1 ]; then\n  echo\n', 1),
     phase1_dryrun),
    ("2", "wrapper", "the mode is assumed to be `oracle' instead of read off the pair",
     lambda s: s.replace(
         'if [ "$PAIR_STATE" = POPULATED ]; then\n  MODE="oracle"',
         'if true; then\n  MODE="oracle" ; PAIR_ORACLE="expected-amd.csv" ; '
         'PAIR_MAP="control-map-amd.csv"', 1),
     phase2_e2e),
    ("2", "wrapper", "the harness transcripts are not kept",
     lambda s: s.replace('export HET_RUN_LOG_DIR="$OUT/hetstats"',
                         'HET_RUN_LOG_DIR=""', 1),
     phase2_e2e),
    ("3", "wrapper", "--gpu-target quietly defaults to cuda",
     lambda s: s.replace('[ -n "$GPU_TARGET" ] || die "--gpu-target is mandatory',
                         'GPU_TARGET="${GPU_TARGET:-cuda}"\n'
                         '[ -n "$GPU_TARGET" ] || die "--gpu-target is mandatory', 1),
     phase3_refusals),
    ("3", "wrapper", "the host-ISA check is dropped",
     lambda s: s.replace('[ "$CPU_ISA" = "$HOST_ISA" ] || die',
                         '[ 1 = 1 ] || die', 1),
     phase3_refusals),
    ("4", "campaign", "--characterization classes its rows Disallowed",
     lambda s: s.replace('return dict.fromkeys(tests, "NO-ORACLE")',
                         'return dict.fromkeys(tests, "Disallowed")', 1),
     phase4_characterization),
    ("4", "campaign", "the two switches stop being mutually exclusive",
     lambda s: s.replace("klass = ap.add_mutually_exclusive_group(required=True)",
                         "klass = ap.add_argument_group('oracle class')", 1),
     phase4_characterization),
    ("4", "campaign", "a row is resumed across oracle classes",
     lambda s: s.replace(
         'if t in prior and prior[t].get("class") not in (None, "", st.oclass):',
         'if False:', 1),
     phase4_characterization),
]


def bite():
    print("===== BITE: does each phase read what it claims to? =====")
    tmp = tempfile.mkdtemp(prefix="runcheck-bite.")
    bad = 0
    try:
        for tag, which, what, mutate, phase in INJECTIONS:
            target = (copy_wrapper(tmp, mutate) if which == "wrapper"
                      else copy_campaign(tmp, mutate))
            if target is None:
                print("  *** [phase %s] %s: the injection changed NOTHING -- this "
                      "bite proves nothing" % (tag, what))
                bad += 1
                continue
            failures = phase(target, quiet=True)
            if not failures:
                print("  *** [phase %s] %s: the phase stayed GREEN" % (tag, what))
                bad += 1
            else:
                print("      [phase %s] RED on %s" % (tag, what))
                print("          %s" % failures[0].splitlines()[0][:150])
        print("-- and the untouched scripts must be green, or `red' meant nothing")
        clean = (phase1_dryrun(WRAPPER, quiet=True)
                 + phase2_e2e(WRAPPER, quiet=True)
                 + phase3_refusals(WRAPPER, quiet=True)
                 + phase4_characterization(CAMPAIGN, quiet=True))
        if clean:
            print("  *** the UNTOUCHED wrapper/campaign is RED (%s) -- the "
                  "injections above prove nothing" % clean[0].splitlines()[0][:150])
            bad += 1
        else:
            print("      the untouched wrapper and campaign: GREEN")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    if bad:
        print("\nBITE FAILED: %d injection(s) went unnoticed." % bad)
        return 1
    print("\nBITE OK (%d injections, each RED; restored GREEN)" % len(INJECTIONS))
    return 0


# ---------------------------------------------------------------------------
# --hw -- the same wrapper, on the device.  No stand-ins: the real probe, the
# real compiler, the real harness.  The pair it reaches here is registered
# WITHOUT an oracle, which is precisely the new-hardware session the wrapper
# exists for, so what is asserted is that it characterizes and says so.
# ---------------------------------------------------------------------------
# A harness that loses a barrier increment stalls until the runner's timeout
# kills it (campaign.py then records `runner rc=124').  On a device whose pinned
# read-modify-write is not system-atomic against the host -- which the probe
# measures, and which this box is -- that is a property of the box and not of the
# session, so it is retried and only an all-stall is reported.
STALL_TRIES = 3
RUN_TIMEOUT = "90"


def _stalled(out):
    p = os.path.join(out, "campaign-state.csv")
    return os.path.exists(p) and "rc=124" in open(p).read()


def _session(wrapper, tmp, env, quiet):
    """One wrapper session on the device, retried past a rendezvous stall.
    Returns (completed process or None if every attempt stalled, results dir)."""
    out = None
    for i in range(1, STALL_TRIES + 1):
        out = os.path.join(tmp, "out-%d" % i)
        r = run_wrapper(wrapper, ["--gpu-target", "cuda", "--corpus", X86_DIR,
                                  "--arch", "auto", "--budget-runs", "10",
                                  "--out", out], env=env)
        if r.returncode == 0 or not _stalled(out):
            return r, out
        if not quiet:
            print("      attempt %d: a harness STALLED at the rendezvous (the "
                  "runner timed out); retrying" % i)
    return None, out


def hardware(wrapper=WRAPPER, quiet=False):
    if platform.machine() != "x86_64":
        raise SystemExit("runcheck --hw: this host is %s and the fixture corpus "
                         "carries an x86_64 CPU column" % platform.machine())
    env = dict(os.environ)
    env.setdefault("HET_ALLOC", "pinned")
    env.setdefault("HET_RUN_TIMEOUT", RUN_TIMEOUT)
    tmp = tempfile.mkdtemp(prefix="runcheck-hw.")
    try:
        if not quiet:
            print("runcheck --hw: (X86_64, cuda) over %d test(s), arch auto, "
                  "HET_ALLOC=%s" % (len(X86_TESTS), env["HET_ALLOC"]))
        r, out = _session(wrapper, tmp, env, quiet)
        bad = []
        if r is None:
            bad.append("every one of %d sessions stalled at the rendezvous.  "
                       "HET_ALLOC=%s cannot make a system-scope atomic barrier on "
                       "this device; re-run with an allocator that can."
                       % (STALL_TRIES, env["HET_ALLOC"]))
        elif r.returncode != 0:
            if not quiet:
                print(r.stdout[-2500:])
            bad.append("the session exited %d:\n%s" % (r.returncode,
                                                       r.stderr[-800:]))
        else:
            if not quiet:
                print(r.stdout[-2500:])
            summary = open(os.path.join(out, "summary.txt")).read()
            record = open(os.path.join(out, "run-record.txt")).read()
            if "characterization" not in summary:
                bad.append("the summary does not say characterization:\n" + summary)
            if "mode=characterization" not in record:
                bad.append("run-record.txt does not record the characterization mode")
            for frag in ("seam_probe", "seam_compiler", "seam_litmus7"):
                if frag in record:
                    bad.append("run-record.txt carries %s -- a hardware session "
                               "must run no stand-in" % frag)
            if "arch_source=auto" not in record:
                bad.append("the arch was not resolved on this box")
            rows = state_rows(os.path.join(out, "campaign-state.csv"))
            if len(rows) != len(X86_TESTS) or any(c != "NO-ORACLE"
                                                  for _, c, _, _ in rows):
                bad.append("campaign state rows %s" % rows)
            if "probe_status=OK" not in open(os.path.join(out, "probe.txt")).read():
                bad.append("the device probe did not report OK")
            for t in X86_TESTS:
                log = os.path.join(out, "hetstats", t + ".log")
                if not os.path.exists(log) or "HetStats %s " % t not in open(log).read():
                    bad.append("no HetStats transcript for %s -- the line every row "
                               "was scored from survives nowhere else" % t)
        if bad:
            if not quiet:
                print("\nRUNCHECK --hw FAILED: %d problem(s)." % len(bad))
                for m in bad:
                    print("  %s" % m)
            return 1, bad
        if not quiet:
            print("\nRUNCHECK --hw: PASS (the chain ran on the device, the pair "
                  "with no oracle characterized, and the session recorded what it "
                  "did)")
        return 0, []
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# The device lane's own bite: the assertions above read a REAL session, so they
# are proved to bite against a real session too, not only against the stubbed
# chain of phase 2.
def hardware_bite():
    print("===== BITE: does the device lane read the session it ran? =====")
    tmp = tempfile.mkdtemp(prefix="runcheck-hwbite.")
    bad = 0
    try:
        tag, _, what, mutate, _ = INJECTIONS[1]
        target = copy_wrapper(tmp, mutate)
        if target is None:
            print("  *** the injection changed NOTHING -- this bite proves nothing")
            return 1
        rc, why = hardware(target, quiet=True)
        if rc == 0:
            print("  *** the device lane stayed GREEN on: %s" % what)
            bad += 1
        elif not any("characterization" in m for m in why):
            # RED FOR THE RIGHT REASON: a stalled session is red too, and would
            # make this bite pass without the assertion ever having read anything.
            print("  *** the device lane went red on something else: %s"
                  % why[0].splitlines()[0][:200])
            bad += 1
        else:
            print("      RED on %s" % what)
        if hardware(WRAPPER, quiet=True)[0] != 0:
            print("  *** the UNTOUCHED wrapper is RED on the device -- the "
                  "injection above proves nothing")
            bad += 1
        else:
            print("      the untouched wrapper on the device: GREEN")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    if bad:
        print("\nBITE FAILED: %d unnoticed." % bad)
        return 1
    print("\nBITE OK (the planted mode is caught on the device too; restored GREEN)")
    return 0


PHASES = [
    ("1: --dry-run acts on nothing", lambda q: phase1_dryrun(WRAPPER, q)),
    ("2: the chain end to end (stub compiler + stub probe)",
     lambda q: phase2_e2e(WRAPPER, q)),
    ("3: the refusals, each by its own reason",
     lambda q: phase3_refusals(WRAPPER, q)),
    ("4: campaign.py --characterization",
     lambda q: phase4_characterization(CAMPAIGN, q)),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bite", action="store_true",
                    help="prove each phase reddens on a planted defect")
    ap.add_argument("--hw", action="store_true",
                    help="run the wrapper on the real device (-nvcc lane)")
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args()

    if not os.access(os.path.join(ROOT, "_build", "install", "default", "bin",
                                  "litmus7"), os.X_OK):
        raise SystemExit("runcheck: litmus7 not built (run 'make all')")
    if a.hw:
        return hardware_bite() if a.bite else hardware()[0]
    if a.bite:
        return bite()

    rc = 0
    for name, phase in PHASES:
        print("\n===== PHASE %s =====" % name)
        failures = phase(a.quiet)
        for m in failures:
            print("  *** %s" % m)
        rc |= 1 if failures else 0
    if rc:
        print("\nRUNCHECK FAILED.")
        return 1
    print("\nRUNCHECK OK (the plan is a plan; the chain records what it did; the "
          "pair decides the mode; a pair with no oracle adjudicates nothing)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

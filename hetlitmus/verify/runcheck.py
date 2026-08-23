#!/usr/bin/env python3
"""runcheck.py -- the device-session wrapper (hetlitmus/hetlitmus-run.sh), driven
end to end on a box with no device.

The wrapper is the one command a hardware session runs, so what it decides -- the
pair and the architecture the binaries are built for -- is decided on a machine
nobody is watching and is visible afterwards only in what it wrote down.  Every
phase below drives it with the compiler and the probe replaced by the wrapper's
documented stand-ins.  The chain phases need a corpus whose CPU column is this
host's, so `fixture()' picks the committed x86 fixture on an x86_64 box and a cut
of the committed AArch64 corpus on an aarch64 one, and the pairs each phase
expects follow that choice: nothing here is x86-only.

  PHASE 1  --dry-run prints the plan and does NOT act: no results dir at all.
  PHASE 2  the chain end to end on each dialect this host reaches.
  PHASE 3  the refusals, each by its own reason.
  PHASE 4  campaign.py's stop rule, and the states it may not resume.
  PHASE 6  the fail-closed handlers, each under its own induced condition.
  PHASE 7  a second session into a results dir that already holds one.
  PHASE 8  probe-hip.sh's exit paths.

`--bite' plants one defect per assertion in a copy of the script under test (never
in the tree) and requires the phase to redden for the right reason.  One device
mode needs a GPU and is the toolchain lane's half of this gate: `--characterize-hw'
builds a harness and reads what it prints, which is the only artefact a result is
ever read off.
"""
import argparse
import atexit
import csv
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
HETL = os.path.join(ROOT, "hetlitmus")
WRAPPER = os.path.join(HETL, "hetlitmus-run.sh")
CAMPAIGN = os.path.join(HETL, "campaign.py")
RUNONE = os.path.join(HETL, "spotcheck", "run-one.sh")
PROBE_HIP = os.path.join(HETL, "spotcheck", "probe-hip.sh")
BIN = os.path.join(ROOT, "_build", "install", "default", "bin")

# The committed (x86_64, *) fixture, cut verbatim from a generate-x86.sh run and
# kept that way by hetlitmus-x86fixture.
X86_DIR = os.path.join(HETL, "tests", "het-x86")
X86_TESTS = ["CoRR-cg-sys-fence-2s-x86_64", "MP-cg-sys-acqrel-2s-x86_64",
             "MP-cg-sys-relaxed-x86_64", "S-cg-sys-fence-x86_64"]
# The (AArch64, *) lane is the committed het corpus, and a session over all of it
# is not a gate.  The cut below is copied out of it verbatim at run time, so it
# is not a second fixture that could go stale; it is the corpus, minus rows.
AARCH64_DIR = os.path.join(HETL, "tests", "het")
AARCH64_TESTS = ["MP-cg-sys-acqrel-2s", "MP-cg-sys-acquire", "MP-cg-sys-relaxed",
                 "S-cg-sys-fence", "S-cg-sys-relaxed"]

# One HetStats machine line, the whole interface between a harness and
# campaign.py, in the field order and field set het_stats_line prints -- a stub
# that speaks a shape the runtime cannot produce is testing a protocol nobody
# implements.  A null on a live run, so the row is reportable and nothing
# fires: what the scheduler does with it is the phase's subject.
STUB_STATS = ("HetStats %s cpu_only=0 obs=Never R=10 usable=10 k=0 k_eff=0 "
              "k_runs=0 degen=0 first_sight=0 sighting=none N=100000 "
              "scored=100000 discarded=0 flags=0x0")

# The stand-in compiler: `-c' writes the object, a link writes an executable whose
# body is @@BODY@@.  It is what lets the chain reach the campaign on a box with no
# device -- and the wrapper records that it was used.
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
@@BODY@@
HARNESS
chmod +x "$out"
'''

OK_HARNESS = ("#!/bin/sh\n"
              "printf 'HetLitmus: shared-mem mode=stub\\n'\n"
              "printf '@@STATS@@\\n' \"$(basename \"$0\")\"\n")
# A harness that dies with a message on STDERR.  campaign.py builds an errored
# row's note from the runner's stderr, so this is also what proves run-one.sh
# keeps the two streams apart.
HARNESS_STDERR = "harness: the rendezvous never closed"
ERR_HARNESS = ("#!/bin/sh\n"
               "printf 'HetLitmus: shared-mem mode=stub\\n'\n"
               "echo '%s' >&2\n"
               "exit 7\n" % HARNESS_STDERR)

BAD_CC = "#!/bin/sh\necho 'stub-cc: this compiler always fails' >&2\nexit 1\n"

STUB_PROBE = r'''#!/bin/sh
# Stand-in for probe-cuda.sh / probe-hip.sh: the shape of a probe record, none
# of the facts.  The wrapper records that a stand-in was used.
set -eu
mkdir -p "$RESULTS"
{
  echo "probe_date=$(date -Is 2>/dev/null || date)"
  echo "host_uname_m=$(uname -m)"
  echo "probe_status=STUB"
} > "$RESULTS/probe.txt"
echo "stub-probe: wrote $RESULTS/probe.txt"
'''

BAD_PROBE = "#!/bin/sh\necho 'stub-probe: the device vanished' >&2\nexit 9\n"

# A runner that CORROBORATES on its first invocation: k_eff>=1 in k_runs >=
# HET_CORROB_RUNS distinct clean runs is the one stop that means "nothing further is
# bought by running this row".  The line is the shape het_stats_line prints, and
# campaign.py's parser keeps every key=value it does not read, so a drifted field
# here would go unnoticed.
MATCHY_RUNNER = r'''#!/usr/bin/env python3
import os, sys
d = sys.argv[1]
print("HetStats %s cpu_only=0 obs=Sometimes R=10 usable=10 k=1 k_eff=1 k_runs=3 "
      "degen=0 first_sight=1 sighting=CORROBORATED N=100000 scored=100000 "
      "discarded=0 flags=0x0" % os.path.basename(d))
'''

# ... and one that fires ONCE and then goes quiet: the row it drives is held open by
# the confirmation window alone and ends UNCONFIRMED-SIGHTING when the window closes.
LONE_RUNNER = r'''#!/usr/bin/env python3
import os, sys
d = sys.argv[1]
cf = os.path.join(d, "inv.count")
inv = (int(open(cf).read()) + 1) if os.path.exists(cf) else 1
open(cf, "w").write(str(inv))
fired = (inv == 1)
# The harness runs at most HET_RUNS_MAX runs, so this stand-in does too: the last
# invocation of a row held open past its budget is entitled to a FRACTION of a full
# one, and a stub ignoring the cap would land on run counts no harness produces.
R = min(10, int(os.environ.get("HET_RUNS_MAX") or "10"))
print("HetStats %s cpu_only=0 obs=%s R=%d usable=%d k=%d k_eff=%d k_runs=%d "
      "degen=0 first_sight=%d sighting=%s N=100000 scored=100000 discarded=0 "
      "flags=0x0"
      % (os.path.basename(d), "Sometimes" if fired else "Never", R, R,
         fired, fired, fired, 1 if fired else 0,
         "UNCONFIRMED" if fired else "none"))
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


def make_stubs(tmp, harness=None, tag=""):
    """The stand-in compiler and probe, in `tmp'.  Returns (cc, probe)."""
    body = (harness or OK_HARNESS).replace("@@STATS@@", STUB_STATS % "%s")
    cc = write_exec(os.path.join(tmp, "stub-cc" + tag),
                    STUB_CC.replace("@@BODY@@", body.rstrip("\n")))
    probe = write_exec(os.path.join(tmp, "stub-probe%s.sh" % tag), STUB_PROBE)
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
    """(test, stop, runs) per row of a campaign state file: columns test, stop,
    invocations, runs, ..."""
    rows = []
    with open(path) as fh:
        for i, line in enumerate(fh):
            f = line.rstrip("\n").split(",")
            if i == 0 or len(f) < 4:
                continue
            rows.append((f[0], f[1], int(f[3])))
    return rows


# campaign.py's terminal stops, mirrored here so a session's own state file can be
# read: a row that ended on anything else was written by another stop rule.
TERMINAL = ("CORROBORATED", "UNCONFIRMED-SIGHTING", "BUDGET", "ERROR")


def state_is_terminal(pfx, rows, tests):
    """Every test ran and every row ended on a stop this policy can write."""
    bad = []
    if sorted(t for t, _, _ in rows) != sorted(tests):
        bad.append("%scampaign state covers %s, want %s"
                   % (pfx, sorted(t for t, _, _ in rows), sorted(tests)))
    for t, stop, _ in rows:
        if stop not in TERMINAL:
            bad.append("%s%s ended %r, which is not one of this stop rule's outcomes "
                       "%s" % (pfx, t, stop, list(TERMINAL)))
    return bad


def state_notes(path):
    """test -> the note column, which is where an errored row's reason lands."""
    with open(path) as fh:
        return {r["test"]: (r.get("note") or "") for r in csv.DictReader(fh)}


# ---------------------------------------------------------------------------
# The fixture this host can drive, and the device arch each of its two dialects
# is built for.  The emitted link targets refuse a foreign host, so a corpus whose
# CPU column is not this box's has no chain to drive here.  Every row of every
# campaign takes the same stop rule whatever the pair: no harness carries a
# prediction.
# ---------------------------------------------------------------------------
_CUT = None


def aarch64_corpus():
    """The AArch64 cut, copied verbatim out of the committed corpus on demand."""
    global _CUT
    if _CUT is None:
        d = tempfile.mkdtemp(prefix="runcheck-aarch64.")
        atexit.register(shutil.rmtree, d, True)
        for t in AARCH64_TESTS:
            shutil.copy(os.path.join(AARCH64_DIR, t + ".litmus"), d)
        _CUT = d
    return _CUT


def fixture():
    """{isa, key, dir, tests, cuda: arm, hip: arm} for this host, or None."""
    m = platform.machine()
    if m == "x86_64":
        fx = {
            "isa": "x86_64", "key": "X86_64", "dir": X86_DIR, "tests": X86_TESTS,
            "cuda": {"arch": "sm_86"},
            "hip": {"arch": "gfx942"},
        }
    elif m in ("aarch64", "arm64"):
        fx = {
            "isa": "aarch64", "key": "AArch64", "dir": aarch64_corpus(),
            "tests": AARCH64_TESTS,
            "cuda": {"arch": "sm_90"},
            "hip": {"arch": "gfx942"},
        }
    else:
        return None
    return fx


def no_fixture(phase, quiet):
    """The NAMED skip: a host with no committed corpus of its own CPU lane."""
    if not quiet:
        print("      NOT RUN on %s: no committed corpus carries a %s CPU column, "
              "so phase %s has no chain to drive here."
              % (platform.machine(), platform.machine(), phase))
    return []


def foreign_case():
    """(corpus, target) whose CPU lane is NOT this host's, so the session reaches
    the host-ISA refusal and not an earlier one."""
    if platform.machine() == "x86_64":
        return aarch64_corpus(), "cuda"
    return X86_DIR, "hip"


# ---------------------------------------------------------------------------
# PHASE 1 -- --dry-run says what it would do, and does none of it.
# ---------------------------------------------------------------------------
PLAN_STEPS = ["step 1  preflight", "step 2  probe", "step 3  emit",
              "step 4  compile", "step 5  smoke rungs", "step 6  campaign",
              "step 7  collect"]


def phase1_dryrun(wrapper, quiet=False):
    fx = fixture()
    if fx is None:
        return no_fixture("1", quiet)
    arm = fx["cuda"]
    bad = []
    tmp = tempfile.mkdtemp(prefix="runcheck1.")
    try:
        cc, probe = make_stubs(tmp)
        out = os.path.join(tmp, "never-created")
        r = run_wrapper(wrapper, ["--gpu-target", "cuda", "--corpus", fx["dir"],
                                  "--arch", arm["arch"], "--out", out, "--dry-run"],
                        env=wrapper_env(cc, probe))
        if r.returncode != 0:
            bad.append("--dry-run exited %d: %s" % (r.returncode,
                                                    r.stderr.strip()[-200:]))
        for frag in PLAN_STEPS + ["(%s, cuda)" % fx["key"], arm["arch"],
                                  "characterization"]:
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
            print("      the plan names all 7 steps, the pair, the arch and what "
                  "the campaign does; nothing was written")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return bad


# ---------------------------------------------------------------------------
# PHASE 2 -- the chain end to end, on each dialect this host's fixture reaches.
# ---------------------------------------------------------------------------
def _e2e(wrapper, tmp, fx, target, arm, quiet):
    """One full chain.  Returns (failures, results dir)."""
    bad = []
    cc, probe = make_stubs(tmp)
    out = os.path.join(tmp, "out-" + target)
    r = run_wrapper(wrapper,
                    ["--gpu-target", target, "--corpus", fx["dir"], "--arch",
                     arm["arch"], "--budget-runs", "10", "--out", out],
                    env=wrapper_env(cc, probe))
    if r.returncode != 0:
        bad.append("%s chain exited %d:\n%s\n%s"
                   % (target, r.returncode, r.stdout[-1200:], r.stderr[-600:]))
        return bad, out
    # The results dir is the deliverable: a session that ran but recorded nothing
    # cannot be read afterwards.
    for f in ("run-record.txt", "probe.txt", "build-failures.txt", "summary.txt",
              "campaign-state.csv", "campaign.log", "emit.log"):
        if not os.path.exists(os.path.join(out, f)):
            bad.append("%s: the results dir has no %s" % (target, f))
    if os.path.getsize(os.path.join(out, "build-failures.txt")) != 0:
        bad.append("%s: the build failure table is not empty on a chain that "
                   "reported success" % target)
    ext = "cu" if target == "cuda" else "hip"
    for t in fx["tests"]:
        for f in (os.path.join("build", t + ".log"),
                  os.path.join("emit", t, t + "." + ext),
                  os.path.join("emit", t, t)):
            if not os.path.exists(os.path.join(out, f)):
                bad.append("%s: %s missing from the results dir" % (target, f))
    # The HetStats line is what every row was scored from, and campaign.py keeps
    # none of it: the session's own copy is the only place it survives.
    for t in fx["tests"]:
        log = os.path.join(out, "hetstats", t + ".log")
        if not os.path.exists(log):
            bad.append("%s: no harness transcript for %s in hetstats/" % (target, t))
        elif "HetStats %s " % t not in open(log).read():
            bad.append("%s: the transcript of %s carries no HetStats line"
                       % (target, t))
    summary = open(os.path.join(out, "summary.txt")).read()
    if "CHARACTERIZATION" not in summary:
        bad.append("%s: the summary does not say what the rows are -- it says:\n%s"
                   % (target, summary))
    record = open(os.path.join(out, "run-record.txt")).read()
    for frag in ("arch=" + arm["arch"], "seam_probe=STUB",
                 "seam_compiler=OVERRIDDEN", "session_status=COMPLETE"):
        if frag not in record:
            bad.append("%s: run-record.txt does not carry %r -- the value the "
                       "session turned on is not a recorded fact" % (target, frag))
    rows = state_rows(os.path.join(out, "campaign-state.csv"))
    bad += state_is_terminal("%s: " % target, rows, fx["tests"])
    if not quiet and not bad:
        print("      %-4s -> arch %-8s %d row(s)"
              % (target, arm["arch"], len(rows)))
    return bad, out


def phase2_e2e(wrapper, quiet=False):
    fx = fixture()
    if fx is None:
        return no_fixture("2", quiet)
    bad = []
    tmp = tempfile.mkdtemp(prefix="runcheck2.")
    try:
        chained = None
        for target in ("cuda", "hip"):
            arm = fx[target]
            b, out = _e2e(wrapper, tmp, fx, target, arm, quiet)
            bad += b
            if chained is None and not b:
                chained = (out, target)
        if chained is None:
            return bad
        # --reuse-emitted: the same results dir, no emission, same answers.  The
        # first session's campaign state is moved aside, which is the remedy the
        # second-session refusal names (phase 7 asserts that refusal).
        out, target = chained
        cc, probe = make_stubs(tmp)
        before = open(os.path.join(out, "emit.log")).read()
        os.rename(os.path.join(out, "campaign-state.csv"),
                  os.path.join(out, "campaign-state-1.csv"))
        r = run_wrapper(wrapper,
                        ["--gpu-target", target, "--corpus", fx["dir"], "--arch",
                         fx[target]["arch"], "--budget-runs", "10", "--out", out,
                         "--reuse-emitted"],
                        env=wrapper_env(cc, probe))
        if r.returncode != 0:
            bad.append("--reuse-emitted exited %d:\n%s"
                       % (r.returncode, (r.stdout + r.stderr)[-800:]))
        elif open(os.path.join(out, "emit.log")).read() != before:
            bad.append("--reuse-emitted re-emitted the corpus (emit.log changed)")
        elif "reused %d harness dir(s)" % len(fx["tests"]) not in r.stdout:
            bad.append("--reuse-emitted did not say it reused the emission")
        elif not quiet:
            print("      --reuse-emitted verified the %d dirs and emitted nothing"
                  % len(fx["tests"]))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return bad


# ---------------------------------------------------------------------------
# PHASE 3 -- the refusals.  Each is checked by its OWN reason: a wrapper that
# refused everything with one message would pass a bare exit-code check.
# ---------------------------------------------------------------------------
def mixed_corpus(tmp):
    """A corpus carrying both CPU lanes.  The preflight has to read EVERY test's
    lane: a preflight reading only the first passes this corpus and lets emission
    die on the CPU column instead."""
    d = os.path.join(tmp, "mixed")
    os.makedirs(d, exist_ok=True)
    for f in os.listdir(X86_DIR):
        if f.endswith(".litmus"):
            shutil.copy(os.path.join(X86_DIR, f), d)
    shutil.copy(os.path.join(AARCH64_DIR, AARCH64_TESTS[0] + ".litmus"), d)
    return d


def phase3_refusals(wrapper, quiet=False):
    fx = fixture()
    if fx is None:
        return no_fixture("3", quiet)
    bad = []
    tmp = tempfile.mkdtemp(prefix="runcheck3.")
    try:
        cc, probe = make_stubs(tmp)
        # A PATH with neither device-listing tool, so --arch auto sees nothing.
        nogpu = os.path.join(tmp, "nogpu-bin")
        os.makedirs(nogpu)
        for tool in ("nvidia-smi", "nvptx-arch", "amdgpu-arch", "rocminfo"):
            write_exec(os.path.join(nogpu, tool), "#!/bin/sh\nexit 0\n")
        home = fx["dir"]
        foreign, ftarget = foreign_case()
        cases = [
            ("no --gpu-target",
             ["--corpus", home], {}, "--gpu-target is mandatory"),
            ("unknown --gpu-target",
             ["--gpu-target", "sycl", "--corpus", home], {},
             "is not a GPU dialect"),
            ("a valued flag with no value",
             ["--gpu-target", "cuda", "--corpus"], {}, "--corpus needs a value"),
            ("--arch auto with no device visible",
             ["--gpu-target", "cuda", "--corpus", home, "--arch", "auto"],
             {"PATH": nogpu + os.pathsep + os.environ["PATH"]},
             "found no cuda device on this box"),
            ("host-ISA mismatch",
             ["--gpu-target", ftarget, "--corpus", foreign, "--arch",
              fx[ftarget]["arch"]], {}, "uname -m is"),
            ("toolchain missing",
             ["--gpu-target", "cuda", "--corpus", home, "--arch",
              fx["cuda"]["arch"]],
             {"NVCC": os.path.join(tmp, "no-such-nvcc")}, "is not on PATH"),
            ("mixed-ISA corpus",
             ["--gpu-target", "cuda", "--corpus", mixed_corpus(tmp), "--arch",
              fx["cuda"]["arch"]], {}, "mixes CPU lanes"),
        ]
        for name, args, extra, frag in cases:
            env = wrapper_env(cc, probe, extra)
            # --dry-run leads, so that a case whose LAST argument is a valued flag
            # is still a flag with nothing after it.
            r = run_wrapper(wrapper, ["--dry-run"] + args, env=env)
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
# PHASE 4 -- campaign.py's stop rule, and the states it may not resume.
# ---------------------------------------------------------------------------
CHAR_TESTS = ["CH-one", "CH-two"]
STATE_COLS = ["test", "stop", "invocations", "runs", "usable", "k", "k_eff",
              "k_runs", "first_sight", "cpu_only", "note"]
# The window is set BELOW the budget so the two are told apart by the run count
# alone: a row ending at 31 runs or so was ended by the window (LONE_RUNNER fires in
# run 1 and the window closes confirm_runs runs after that), one ending at 60 by the
# budget.  The stop is decided BETWEEN invocations, so a row whose capacity is the
# 60-run budget ends in the first 10-run invocation to carry it past 31 -- run 40 --
# while one capped by a 10-run budget is handed the single run it is still entitled
# to and ends at 31 exactly.
CHAR_BUDGET, CHAR_CONFIRM, CHAR_R = 60, 30, 10
CHAR_WINDOW_END = CHAR_CONFIRM + 1
CHAR_LONE_RUNS = -(-CHAR_WINDOW_END // CHAR_R) * CHAR_R


def _campaign(campaign, corpus, runner, state, extra, budget=CHAR_BUDGET):
    return sh([sys.executable, campaign, "--corpus", corpus, "--runner",
               "%s %s {dir}" % (sys.executable, runner), "--state", state,
               "--budget-runs", str(budget),
               "--confirm-runs", str(CHAR_CONFIRM)] + extra)


def _fresh_corpus(tmp, name):
    """A corpus of its own: LONE_RUNNER counts its invocations inside the harness
    dir, so a second lone run over the same dirs would start already quiet."""
    corpus = os.path.join(tmp, name)
    for t in CHAR_TESTS:
        os.makedirs(os.path.join(corpus, t))
    return corpus


def phase4_stoprule(campaign, quiet=False):
    bad = []
    tmp = tempfile.mkdtemp(prefix="runcheck4.")
    try:
        corpus = os.path.join(tmp, "corpus")
        for t in CHAR_TESTS:
            os.makedirs(os.path.join(corpus, t))
        runner = write_exec(os.path.join(tmp, "matchy.py"), MATCHY_RUNNER)
        lone = write_exec(os.path.join(tmp, "lone.py"), LONE_RUNNER)

        # The stop that ends a row early: a sighting reproduced across distinct
        # clean runs.  Without it the phase below proves nothing -- a runner whose
        # rows can only run to budget would "pass" every assertion for free.
        st_c = os.path.join(tmp, "corrob.csv")
        r = _campaign(campaign, corpus, runner, st_c, [])
        rows = {t: (stop, runs) for t, stop, runs in state_rows(st_c)}
        if {t: rows.get(t, ("?", 0))[0] for t in CHAR_TESTS} != \
                dict.fromkeys(CHAR_TESTS, "CORROBORATED"):
            bad.append("the corroborating runner gave %s, want every row "
                       "CORROBORATED -- this runner cannot stop a row early and the "
                       "assertions below prove nothing" % rows)
        elif r.returncode != 0:
            bad.append("a campaign whose rows all CORROBORATED exited %d, want 0: a "
                       "reproduced observation is the result, not an alarm"
                       % r.returncode)
        elif not quiet:
            print("      a reproduced sighting stops the row CORROBORATED (rc=0)")

        # The flagged stop, and the precedence that produces it: one sighting, then
        # nulls.  The row is held open by the confirmation window and ended by it
        # CHAR_CONFIRM runs after the run it fired in -- not carried to the 60-run
        # budget, and not banked at the first sighting either.  It exits 1: a sighting
        # that did not reproduce is not a row to be read unattended.
        st_l = os.path.join(tmp, "lone.csv")
        r = _campaign(campaign, _fresh_corpus(tmp, "lone"), lone, st_l, [])
        for t, stop, runs in state_rows(st_l):
            if (stop, runs) != ("UNCONFIRMED-SIGHTING", CHAR_LONE_RUNS):
                bad.append("%s ended %s after %d run(s), want UNCONFIRMED-SIGHTING "
                           "after %d (its window closes at run %d): the confirmation "
                           "window ends a lone sighting %d runs after it fired -- not "
                           "the budget, not the sighting itself, and not a window "
                           "that opened before it"
                           % (t, stop, runs, CHAR_LONE_RUNS, CHAR_WINDOW_END,
                              CHAR_CONFIRM))
        if r.returncode != 1:
            bad.append("a campaign with an UNCONFIRMED-SIGHTING row exited %d, want "
                       "1: a sighting that would not reproduce demands a human"
                       % r.returncode)
        elif not quiet:
            print("      a lone sighting ends UNCONFIRMED-SIGHTING at the window "
                  "(fired in run 1, window closes at %d, ends at %d, budget %d), rc=1"
                  % (CHAR_WINDOW_END, CHAR_LONE_RUNS, CHAR_BUDGET))

        # The precedence, in hardware hours: the same row under a budget smaller than
        # the window.  It must OVERSHOOT the budget and end at the window, to the run
        # -- a row ended at BUDGET here would have banked "seen once, stopped
        # looking", and one curtailed to the budget could never reach the window at
        # all (its last invocation is the single run the window still owes it).
        st_p = os.path.join(tmp, "prec.csv")
        _campaign(campaign, _fresh_corpus(tmp, "prec"), lone, st_p, [], budget=10)
        for t, stop, runs in state_rows(st_p):
            if (stop, runs) != ("UNCONFIRMED-SIGHTING", CHAR_WINDOW_END):
                bad.append("%s ended %s after %d run(s) under a 10-run budget, want "
                           "UNCONFIRMED-SIGHTING after %d: an open sighting outranks "
                           "the budget stop" % (t, stop, runs, CHAR_WINDOW_END))
        if not quiet and not bad:
            print("      ... and outruns a 10-run budget to get there (the window "
                  "outranks the budget stop)")

        # --rate: the SAME corroborating runner must now reach the budget instead.
        st_r = os.path.join(tmp, "rate.csv")
        r = _campaign(campaign, corpus, runner, st_r, ["--rate"])
        for t, stop, runs in state_rows(st_r):
            if (stop, runs) != ("BUDGET", CHAR_BUDGET):
                bad.append("%s ended %s after %d run(s) under --rate, want BUDGET "
                           "after %d: rate mode turns the sighting stop off"
                           % (t, stop, runs, CHAR_BUDGET))
        if not quiet and not bad:
            print("      --rate: the same rows run to BUDGET (%d runs)" % CHAR_BUDGET)

        # A state file carries terminal stops and a resumed row inherits them, so a
        # row banked under a stop name this rule cannot write (OBSERVED, CONFIRMED)
        # must fail closed rather than be inherited: nothing else stands between a
        # stop written by another rule and a session that reports it as its own.
        legacy = os.path.join(tmp, "legacy.csv")
        with open(legacy, "w", newline="") as fh:
            w = csv.writer(fh)
            w.writerow(STATE_COLS)
            for t, stop in (("CH-one", "OBSERVED"), ("CH-two", "CONFIRMED")):
                w.writerow([t, stop, 1, 10, 10, 1, 1, 3, 1, 0,
                            "banked by another rule"])
        r = _campaign(campaign, corpus, runner, legacy, [])
        if r.returncode != 2:
            bad.append("resuming a state banked by another stop rule exited %d, want "
                       "2: the row would have inherited an OBSERVED or CONFIRMED no "
                       "harness here can produce" % r.returncode)
        elif "cannot write" not in r.stderr:
            bad.append("the legacy state was refused for another reason: %s"
                       % r.stderr.strip()[-200:])
        elif not quiet:
            print("      a state banked by another stop rule is not resumable (rc=2)")

        # ... and a row this rule DID write is resumed rather than re-run.
        r = _campaign(campaign, corpus, runner, st_c, [])
        if "skip  " not in r.stdout:
            bad.append("a terminal row of this rule's own state was not resumed: %s"
                       % r.stdout[-300:])
        elif not quiet:
            print("      a terminal row of its own state is resumed, not re-run")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return bad


# ---------------------------------------------------------------------------
# PHASE 6 -- the fail-closed handlers, each under the condition it exists for.
# Every one of them is a `die' the chain reaches only when something is wrong, so
# a chain that only ever runs clean executes none of them.
# ---------------------------------------------------------------------------
P6_CASES = ["build", "probe", "ambiguity", "campaign-rc", "emitted-isa", "stamp",
            "reuse-missing", "reuse-partial", "stray-render"]
DOCTORED = ("emitted-isa", "stamp", "reuse-partial", "stray-render")


def _twocap_path(tmp):
    """A PATH whose nvidia-smi reports two distinct compute capabilities."""
    d = os.path.join(tmp, "twogpu-bin")
    os.makedirs(d, exist_ok=True)
    write_exec(os.path.join(d, "nvidia-smi"), "#!/bin/sh\nprintf '8.6\\n9.0\\n'\n")
    write_exec(os.path.join(d, "nvptx-arch"), "#!/bin/sh\nexit 0\n")
    return d + os.pathsep + os.environ["PATH"]


def phase6_failclosed(wrapper, quiet=False, only=None):
    fx = fixture()
    if fx is None:
        return no_fixture("6", quiet)
    arm = fx["cuda"]
    cases = [only] if only else P6_CASES
    bad = []
    tmp = tempfile.mkdtemp(prefix="runcheck6.")
    try:
        base = ["--gpu-target", "cuda", "--corpus", fx["dir"], "--arch",
                arm["arch"], "--budget-runs", "10"]
        cc, probe = make_stubs(tmp)
        emit0 = None
        if any(c in DOCTORED for c in cases):
            # ONE clean chain, whose emission every doctoring case starts from.
            b, out0 = _e2e(wrapper, tmp, fx, "cuda", arm, True)
            if b:
                return ["phase 6 could not build its base emission: %s" % b[0]]
            emit0 = os.path.join(out0, "emit")

        def doctored_out(name, break_it):
            """A results dir holding a COPY of the clean emission, then broken."""
            out = os.path.join(tmp, "out-" + name)
            shutil.copytree(emit0, os.path.join(out, "emit"))
            break_it(os.path.join(out, "emit"))
            return out

        def expect(name, args, env, rc, frag):
            r = run_wrapper(wrapper, args, env=env)
            if r.returncode != rc:
                bad.append("[%s] exited %d, want %d: %s"
                           % (name, r.returncode, rc,
                              (r.stdout + r.stderr).strip()[-400:]))
                return None
            if frag not in r.stderr + r.stdout:
                bad.append("[%s] stopped for the wrong reason -- %r is in neither "
                           "stream: %s" % (name, frag, r.stderr.strip()[-400:]))
                return None
            if not quiet:
                print("      %-14s rc=%d, names it" % (name, rc))
            return r

        def break_isa(e):
            p = os.path.join(e, fx["tests"][-1], "Makefile")
            s = open(p).read()
            with open(p, "w") as fh:
                fh.write(re.sub(r"HET_HOST_ISA \?= \S+", "HET_HOST_ISA ?= vax", s, 1))

        def break_stamp(e):
            t = fx["tests"][0]
            p = os.path.join(e, t, t + ".cu")
            s = open(p).read()
            with open(p, "w") as fh:
                fh.write(s.replace('#define HET_PAIR_NAME "',
                                   '#define HET_PAIR_NAME "zz', 1))

        def drop_render(e):
            t = fx["tests"][0]
            os.remove(os.path.join(e, t, t + ".cu"))

        def plant_hip(e):
            t = fx["tests"][0]
            shutil.copy(os.path.join(e, t, t + ".cu"),
                        os.path.join(e, t, t + ".hip"))

        for case in cases:
            if case == "build":
                bad_cc = write_exec(os.path.join(tmp, "bad-cc"), BAD_CC)
                expect("build", base + ["--out", os.path.join(tmp, "o-build")],
                       wrapper_env(bad_cc, probe), 2, "failed to build")
            elif case == "probe":
                bp = write_exec(os.path.join(tmp, "bad-probe.sh"), BAD_PROBE)
                expect("probe", base + ["--out", os.path.join(tmp, "o-probe")],
                       wrapper_env(cc, bp), 2, "the probe did not complete")
            elif case == "ambiguity":
                expect("ambiguity",
                       ["--gpu-target", "cuda", "--corpus", fx["dir"], "--arch",
                        "auto", "--dry-run"],
                       wrapper_env(cc, probe, {"PATH": _twocap_path(tmp)}),
                       2, "--arch auto is AMBIGUOUS")
            elif case == "campaign-rc":
                # A campaign that errored a row exits 1, and so must the session.
                err_cc, _ = make_stubs(tmp, ERR_HARNESS, tag="-err")
                out = os.path.join(tmp, "o-camprc")
                r = expect("campaign-rc", base + ["--out", out],
                           wrapper_env(err_cc, probe), 1,
                           "the campaign reported an errored row")
                if r is not None:
                    notes = state_notes(os.path.join(out, "campaign-state.csv"))
                    blank = sorted(t for t, n in notes.items()
                                   if HARNESS_STDERR not in n)
                    if blank:
                        bad.append("[campaign-rc] the errored row(s) %s carry a note "
                                   "without the harness's own message %r (%s) -- the "
                                   "runner merged stderr into stdout"
                                   % (blank, HARNESS_STDERR,
                                      [notes[t] for t in blank]))
            elif case == "emitted-isa":
                expect("emitted-isa",
                       base + ["--out", doctored_out("isa", break_isa),
                               "--reuse-emitted"],
                       wrapper_env(cc, probe), 2, "against the wrong lane")
            elif case == "stamp":
                expect("stamp",
                       base + ["--out", doctored_out("stamp", break_stamp),
                               "--reuse-emitted"],
                       wrapper_env(cc, probe), 2, "the emitted pair name of")
            elif case == "reuse-missing":
                expect("reuse-missing",
                       base + ["--out", os.path.join(tmp, "o-noemit"),
                               "--reuse-emitted"],
                       wrapper_env(cc, probe), 2, "there is no")
            elif case == "reuse-partial":
                expect("reuse-partial",
                       base + ["--out", doctored_out("partial", drop_render),
                               "--reuse-emitted"],
                       wrapper_env(cc, probe), 2, "no .cu render for")
            elif case == "stray-render":
                expect("stray-render",
                       base + ["--out", doctored_out("stray", plant_hip),
                               "--reuse-emitted"],
                       wrapper_env(cc, probe), 2, "is not filtering")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return bad


# ---------------------------------------------------------------------------
# PHASE 7 -- a second session into a results dir that already holds one.
# campaign.py resumes every terminal row it is handed, so without an explicit
# --resume a repeat session measures nothing and still reads as complete.
# ---------------------------------------------------------------------------
def _invocations(out, fx):
    """Harness invocations recorded in the session's transcripts."""
    n = 0
    for t in fx["tests"]:
        p = os.path.join(out, "hetstats", t + ".log")
        if os.path.exists(p):
            n += sum(1 for l in open(p) if l.startswith("### " + t + " rc="))
    return n


def phase7_second_session(wrapper, quiet=False):
    fx = fixture()
    if fx is None:
        return no_fixture("7", quiet)
    arm = fx["cuda"]
    bad = []
    tmp = tempfile.mkdtemp(prefix="runcheck7.")
    try:
        b, out = _e2e(wrapper, tmp, fx, "cuda", arm, True)
        if b:
            return ["phase 7 could not run its first session: %s" % b[0]]
        cc, probe = make_stubs(tmp)
        env = wrapper_env(cc, probe)
        base = ["--gpu-target", "cuda", "--corpus", fx["dir"], "--arch",
                arm["arch"], "--out", out, "--reuse-emitted"]
        invocations = _invocations(out, fx)

        r = run_wrapper(wrapper, base + ["--budget-runs", "10"], env=env)
        if r.returncode != 2:
            bad.append("a second session without --resume exited %d, want 2: it "
                       "would have inherited every terminal row and reported a "
                       "complete session having invoked no harness" % r.returncode)
        elif "already carries" not in r.stderr:
            bad.append("the second session was refused for another reason: %s"
                       % r.stderr.strip()[-300:])
        elif not quiet:
            print("      a second session into the same dir is refused (rc=2)")

        r = run_wrapper(wrapper, base + ["--budget-runs", "500", "--resume"],
                        env=env)
        if r.returncode != 2:
            bad.append("--resume with a budget above what the resumed rows spent "
                       "exited %d, want 2: those rows are never re-run, so the "
                       "raised budget would go silently unspent" % r.returncode)
        elif "is above what these row(s) spent" not in r.stderr:
            bad.append("the raised-budget resume was refused for another reason: %s"
                       % r.stderr.strip()[-300:])
        elif not quiet:
            print("      --resume with a raised budget is refused (rc=2)")

        r = run_wrapper(wrapper, base + ["--budget-runs", "10", "--resume"],
                        env=env)
        note = "row(s) (not measured in this session)"
        if r.returncode != 0:
            bad.append("--resume exited %d: %s"
                       % (r.returncode, (r.stdout + r.stderr)[-400:]))
        else:
            for f in ("summary.txt", "run-record.txt"):
                if note not in open(os.path.join(out, f)).read():
                    bad.append("%s does not disclose the resumed rows (%r) -- a "
                               "session that measured nothing must say so"
                               % (f, note))
            after = _invocations(out, fx)
            if after != invocations:
                bad.append("--resume re-invoked a harness: the transcripts grew "
                           "from %d to %d" % (invocations, after))
            elif not quiet:
                print("      --resume runs no harness and discloses the inherited "
                      "row(s)")

        # A refused session must NOT leave the previous one's summary beside its own
        # record: one dir would then describe two different sessions.
        os.remove(os.path.join(out, "campaign-state.csv"))
        bp = write_exec(os.path.join(tmp, "bad-probe.sh"), BAD_PROBE)
        r = run_wrapper(wrapper, base + ["--budget-runs", "10"],
                        env=wrapper_env(cc, bp))
        record = open(os.path.join(out, "run-record.txt")).read()
        if r.returncode != 2:
            bad.append("the refused session exited %d, want 2" % r.returncode)
        elif "session_status=REFUSED@step2" not in record:
            bad.append("a session refused at the probe does not record it: %s"
                       % [l for l in record.splitlines() if "status" in l])
        elif os.path.exists(os.path.join(out, "summary.txt")):
            bad.append("the refused session left a stale summary.txt in place -- "
                       "it is the PREVIOUS session's, beside this session's record")
        elif not quiet:
            print("      a refused session records REFUSED@step2 and leaves no "
                  "stale summary")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return bad


# ---------------------------------------------------------------------------
# PHASE 8 -- probe-hip.sh, under stand-in vendor tools.  No AMD device is
# reachable from this tree, so its device answers are checked here or nowhere.
# ---------------------------------------------------------------------------
def _hip_tools(tmp, gfx):
    d = os.path.join(tmp, "hipbin-" + ("-".join(gfx) or "none"))
    os.makedirs(d, exist_ok=True)
    write_exec(os.path.join(d, "hipcc"), "#!/bin/sh\necho 'HIP version: 6.0.0'\n")
    write_exec(os.path.join(d, "amdgpu-arch"),
               "#!/bin/sh\n" + "".join("echo %s\n" % g for g in gfx))
    write_exec(os.path.join(d, "rocminfo"),
               "#!/bin/sh\n" + "".join("echo '  Name:  %s'\n" % g for g in gfx))
    return d


def phase8_probe_hip(probe, quiet=False):
    bad = []
    tmp = tempfile.mkdtemp(prefix="runcheck8.")
    try:
        cases = [("no hipcc", None, "NO_TOOLCHAIN", 2),
                 ("no gfx agent", [], "NO_DEVICE", 2),
                 ("one gfx agent", ["gfx942"], "HOST_ONLY", 0),
                 ("two gfx agents", ["gfx942", "gfx90a"], "AMBIGUOUS_DEVICE", 2)]
        for name, gfx, want, rc in cases:
            res = os.path.join(tmp, "res-" + name.replace(" ", "_"))
            env = dict(os.environ)
            env["RESULTS"] = res
            if gfx is None:
                env["HIPCC"] = os.path.join(tmp, "no-such-hipcc")
            else:
                bindir = _hip_tools(tmp, gfx)
                env["PATH"] = bindir + os.pathsep + os.environ["PATH"]
                env["HIPCC"] = os.path.join(bindir, "hipcc")
            r = sh(["sh", probe], env=env)
            txt = os.path.join(res, "probe.txt")
            got = ""
            if os.path.exists(txt):
                got = "".join(l for l in open(txt) if l.startswith("probe_status="))
            if r.returncode != rc:
                bad.append("[%s] probe-hip exited %d, want %d: %s"
                           % (name, r.returncode, rc, r.stderr.strip()[-200:]))
            elif want not in got:
                bad.append("[%s] probe.txt says %r, want probe_status=%s"
                           % (name, got.strip(), want))
            elif not quiet:
                print("      %-14s rc=%d  probe_status=%s" % (name, rc, want))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return bad


# ---------------------------------------------------------------------------
# The bites.  One planted defect per assertion, in a copy of the script under
# test.  Each names the failure it must produce: a phase that reddens for some
# other reason has not been shown to read what the injection broke.
# ---------------------------------------------------------------------------
def copy_wrapper(tmp, mutate=None, runone_mutate=None):
    """A hetlitmus-run.sh in its own dir, beside a paths.sh that points back at
    the real tree.  `runone_mutate' additionally shadows HETL, so the wrapper
    picks up a mutated spotcheck/run-one.sh.  The tree is never written to."""
    d = tempfile.mkdtemp(dir=tmp)
    src = open(WRAPPER).read()
    new = mutate(src) if mutate else src
    if mutate and new == src:
        return None
    hetl = HETL
    if runone_mutate:
        hetl = os.path.join(d, "hetlitmus")
        os.makedirs(os.path.join(hetl, "spotcheck"))
        os.symlink(CAMPAIGN, os.path.join(hetl, "campaign.py"))
        rsrc = open(RUNONE).read()
        rnew = runone_mutate(rsrc)
        if rnew == rsrc:
            return None
        write_exec(os.path.join(hetl, "spotcheck", "run-one.sh"), rnew)
    with open(os.path.join(d, "paths.sh"), "w") as fh:
        fh.write(PATHS_SHIM % (hetl, ROOT, BIN, os.path.join(BIN, "litmus7"),
                               os.path.join(ROOT, "litmus", "libdir"),
                               os.path.join(ROOT, "herd", "libdir")))
    return write_exec(os.path.join(d, "hetlitmus-run.sh"), new)


def copy_file(tmp, path, mutate):
    d = tempfile.mkdtemp(dir=tmp)
    src = open(path).read()
    new = mutate(src)
    if new == src:
        return None
    return write_exec(os.path.join(d, os.path.basename(path)), new)


def _p6(case):
    return lambda w, quiet=False: phase6_failclosed(w, quiet, only=case)


INJECTIONS = [
    ("1", "wrapper", "--dry-run creates the results dir anyway",
     lambda s: s.replace('if [ "$DRYRUN" -eq 1 ]; then\n  echo\n',
                         'mkdir -p "$OUT"\nif [ "$DRYRUN" -eq 1 ]; then\n  echo\n', 1),
     phase1_dryrun, "must write nothing"),
    ("2", "wrapper", "the harness transcripts are not kept",
     lambda s: s.replace('export HET_RUN_LOG_DIR="$OUT/hetstats"',
                         'HET_RUN_LOG_DIR=""', 1),
     phase2_e2e, "transcript"),
    ("3", "wrapper", "--gpu-target quietly defaults to cuda",
     lambda s: s.replace('[ -n "$GPU_TARGET" ] || die "--gpu-target is mandatory',
                         'GPU_TARGET="${GPU_TARGET:-cuda}"\n'
                         '[ -n "$GPU_TARGET" ] || die "--gpu-target is mandatory', 1),
     phase3_refusals, "no --gpu-target"),
    ("3", "wrapper", "the host-ISA check is dropped",
     lambda s: s.replace('[ "$CPU_ISA" = "$HOST_ISA" ] || die',
                         '[ 1 = 1 ] || die', 1),
     phase3_refusals, "host-ISA mismatch"),
    ("3", "wrapper", "a valued flag with no value shifts off the end",
     lambda s: s.replace('--corpus)        need_val "$1" $# ; CORPUS="$2" ; shift 2 ;;',
                         '--corpus)        CORPUS="${2:-}" ; shift 2 ;;', 1),
     phase3_refusals, "a valued flag with no value"),
    ("3", "wrapper", "only the first test's CPU lane is read",
     lambda s: s.replace('done < <(corpus_cpu_lanes "${CORPUS_PATHS[@]}")',
                         'done < <(corpus_cpu_lanes "${CORPUS_PATHS[0]}")', 1),
     phase3_refusals, "mixed-ISA corpus"),
    ("4", "campaign", "a LONE sighting is banked as if it had reproduced",
     lambda s: s.replace("            if self.k_runs >= CORROB_RUNS:",
                         "            if self.k_eff >= 1:", 1),
     phase4_stoprule, "UNCONFIRMED-SIGHTING"),
    ("4", "campaign", "the budget ends a lone sighting before the window does",
     lambda s: s.replace("            return self.stop            # outranks the "
                         "budget stop below", "            pass", 1),
     phase4_stoprule, "outranks the budget stop"),
    ("4", "campaign", "the confirmation window is measured from run 0",
     lambda s: s.replace(
         "            elif self.runs - self.runs_at_first_sight >= confirm_runs:",
         "            elif self.runs >= confirm_runs:", 1),
     phase4_stoprule, "a window that opened before it"),
    ("4", "campaign", "--rate is read but never applied",
     lambda s: s.replace("        if self.k_eff > 0 and not rate_mode:",
                         "        if self.k_eff > 0:", 1),
     phase4_stoprule, "rate mode turns the sighting stop off"),
    ("4", "campaign", "a row banked by another stop rule is resumed anyway",
     lambda s: s.replace("            if pstop and pstop not in TERMINAL:",
                         "            if False:", 1),
     phase4_stoprule, "banked by another stop rule"),
    # Four of the phase-6 handlers are subsumed downstream: with the handler
    # removed the session still stops, elsewhere and saying something else, so
    # each of those four names the substitute the phase reaches instead -- the
    # campaign's errored-row exit (1, not 2) for `build', the emitted harness's
    # own host-ISA guard for `emitted-isa', the per-render check for
    # `reuse-missing', the pair stamp for `reuse-partial'.  What their injections
    # prove is that the phase notices its handler is gone, NOT that nothing else
    # would have stopped the session.
    ("6", "wrapper", "a harness that did not build does not stop the session",
     lambda s: s.replace('if [ "$nfail" -ne 0 ]; then', 'if false; then', 1),
     _p6("build"), "[build] exited 1, want 2"),
    ("6", "wrapper", "a probe that did not complete does not stop the session",
     lambda s: s.replace('if [ "$probe_rc" -ne 0 ]; then', 'if false; then', 1),
     _p6("probe"), "probe"),
    ("6", "wrapper", "--arch auto picks one of two devices",
     lambda s: s.replace('elif [ "${#FOUND[@]}" -gt 1 ]; then', 'elif false; then', 1),
     _p6("ambiguity"), "ambiguity"),
    ("6", "wrapper", "the campaign's exit code is not the session's",
     lambda s: s.replace('exit "$camp_rc"', 'exit 0', 1),
     _p6("campaign-rc"), "campaign-rc"),
    ("6", "runone", "the harness's stderr is merged into its stdout",
     lambda s: s.replace('"./$2" > "$o" 2> "$e" || rc=$?',
                         '"./$2" > "$o" 2>&1 || rc=$?', 1),
     _p6("campaign-rc"), "merged stderr into stdout"),
    ("6", "wrapper", "the emitted CPU lane is not mirrored against the corpus",
     lambda s: s.replace('[ "$EMITTED_ISA" = "$CPU_ISA" ] || die',
                         '[ 1 = 1 ] || die', 1),
     _p6("emitted-isa"), "harness(es) did not build"),
    ("6", "wrapper", "the emitted pair name is not cross-checked",
     lambda s: s.replace('grep -qF "#define HET_PAIR_NAME \\"$PAIR\\"" "$f" || {',
                         'true || {', 1),
     _p6("stamp"), "stamp"),
    ("6", "wrapper", "--reuse-emitted accepts a missing emission",
     lambda s: s.replace('[ -d "$EMIT" ] || die "--reuse-emitted, but there is no',
                         '[ 1 = 1 ] || die "--reuse-emitted, but there is no', 1),
     _p6("reuse-missing"), "REFUSING -- no .cu render for"),
    ("6", "wrapper", "a missing render is not noticed on reuse",
     lambda s: s.replace('[ -s "$f" ] || die "no .$RENDER_EXT render for $t under $EMIT"',
                         ': || die "no .$RENDER_EXT render for $t under $EMIT"', 1),
     _p6("reuse-partial"), "REFUSING -- the emitted pair name of"),
    ("6", "wrapper", "an other-vendor render beside the render is not noticed",
     lambda s: s.replace('[ ! -e "$EMIT/$t/$t.$OTHER_EXT" ] \\\n    || die',
                         '[ 1 = 1 ] \\\n    || die', 1),
     _p6("stray-render"), "stray-render"),
    ("7", "wrapper", "a second session silently resumes every terminal row",
     lambda s: s.replace('if [ "$RESUMABLE" -gt 0 ] && [ "$RESUME" -eq 0 ]; then',
                         'if false; then', 1),
     phase7_second_session, "without --resume"),
    ("7", "wrapper", "a raised budget is swallowed by the resumed rows",
     lambda s: s.replace('if [ "$RESUME" -eq 1 ] && [ -n "$RESUMABLE_SHORT" ]; then',
                         'if false; then', 1),
     phase7_second_session, "budget above what the resumed rows spent"),
    ("7", "wrapper", "a refused session leaves the previous summary in place",
     lambda s: s.replace('[ ! -e "$SUMMARY" ] || mv -f "$SUMMARY" '
                         '"$OUT/summary-superseded-$STAMP.txt"', ':', 1),
     phase7_second_session, "stale summary"),
    ("8", "probehip", "the two-device answer is dropped",
     lambda s: s.replace('if [ "$n" -gt 1 ]; then', 'if false; then', 1),
     phase8_probe_hip, "two gfx agents"),
]


def _target_for(tmp, which, mutate):
    if which == "wrapper":
        return copy_wrapper(tmp, mutate)
    if which == "runone":
        return copy_wrapper(tmp, runone_mutate=mutate)
    if which == "campaign":
        return copy_file(tmp, CAMPAIGN, mutate)
    return copy_file(tmp, PROBE_HIP, mutate)


def bite():
    """Each injection runs a phase against a COPY of one script, made in a scratch
    dir, and is judged on a failure carrying its own reason string -- so a green
    arm is the gate's own run (`runcheck.py' with no flag), not a re-run here."""
    print("===== BITE: does each assertion read what it claims to? =====")
    tmp = tempfile.mkdtemp(prefix="runcheck-bite.")
    bad = 0
    try:
        for tag, which, what, mutate, phase, expect in INJECTIONS:
            target = _target_for(tmp, which, mutate)
            if target is None:
                print("  *** [phase %s] %s: the injection changed NOTHING -- this "
                      "bite proves nothing" % (tag, what))
                bad += 1
                continue
            failures = phase(target, quiet=True)
            joined = "\n".join(failures)
            if not failures:
                print("  *** [phase %s] %s: the phase stayed GREEN" % (tag, what))
                bad += 1
            elif expect and expect not in joined:
                print("  *** [phase %s] %s: RED, but for another reason (%r is in "
                      "no failure): %s"
                      % (tag, what, expect, failures[0].splitlines()[0][:150]))
                bad += 1
            else:
                print("      [phase %s] RED on %s" % (tag, what))
                print("          %s" % failures[0].splitlines()[0][:150])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    if bad:
        print("\nBITE FAILED: %d injection(s) went unnoticed." % bad)
        return 1
    print("\nBITE OK (%d injections, each RED naming its own reason)"
          % len(INJECTIONS))
    return 0


# ---------------------------------------------------------------------------
# --characterize-hw -- what a harness actually prints, on the device.  Every
# other gate on the verdict/statistics stack drives it from synthetic records or
# from emitted text; this one builds a harness, runs it on the GPU and reads the
# printout, which is the only artefact a result is ever read off.
#
# EVERY reading is a reading, so all three PASS: the outcome is stochastic, the
# run is re-seeded while it does not fire because a sighting carries strictly
# more sentences to assert, and a stream of nulls -- or a DISCARDED run, which is
# what a box whose rendezvous cannot complete legitimately produces -- is read as
# what it is rather than as a failure of this gate.  What no reading may carry is
# a sentence saying something certifies the harness.
#
# Then a SECOND run of the same binary under caps of one poll, where the
# rendezvous cannot complete by construction: that run must be discarded and must
# name the rendezvous.  It is the disqualifier's bite, and it is here rather than
# under --bite because it needs no injection at all -- a run-time knob produces
# the condition the rule exists to catch.
# ---------------------------------------------------------------------------
CH_TEST = "MP-cg-sys-relaxed-x86_64"
CH_PAIR = "(X86_64, cuda)"
CH_SEED_TRIES = 12
# Every iteration now waits for the other device, so a run costs what N
# rendezvous cost rather than what N free-running iterations did.  The gate reads
# the PRINTOUT, and the printout's shape does not depend on how many runs stand
# behind it, so the runs are curtailed here and the timeout is what a curtailed
# run may take before it is called stalled.
CH_RUNS = "2"
CH_RUN_TIMEOUT = 600
# The host rendezvous cap the run takes.  A discarded iteration costs its cap,
# so on a box whose two sides do meet it never binds, while on one that loses
# arrivals (mapped pinned memory with no host-native atomics) every iteration
# pays it.  The printout's shape does not depend on the outcome, so the host wait
# is shortened here to keep a run inside its timeout, and the value travels in
# the record where a reader sees what the run waited under.  The device cap is
# left alone: shortening it too makes a clean run rare enough that a sighting
# stops reproducing.
CH_CAP_CPU = "4096"


def _ch_env():
    env = dict(os.environ)
    env["PATH"] = BIN + os.pathsep + env["PATH"]
    return env


def ch_arch():
    """sm_XY of the device this will actually run on, NEVER a hardcoded sm_90: a
    cubin built for another architecture does not load."""
    if os.environ.get("CUDA_ARCH"):
        return os.environ["CUDA_ARCH"]
    r = sh(["nvidia-smi", "--query-gpu=compute_cap", "--format=csv,noheader"])
    caps = [l.strip() for l in r.stdout.splitlines() if l.strip()]
    if r.returncode != 0 or not caps:
        return None
    return "sm_" + caps[0].replace(".", "")


def ch_emit(tmp):
    """Emit CH_TEST and return its harness dir."""
    out = tempfile.mkdtemp(dir=tmp)
    r = sh(["litmus7", "-gpu-target", "cuda", "-set-libdir",
            os.path.join(ROOT, "litmus", "libdir"), "-o", out,
            os.path.join(X86_DIR, CH_TEST + ".litmus")], cwd=ROOT, env=_ch_env())
    d = os.path.join(out, CH_TEST)
    if r.returncode != 0 or not os.path.exists(os.path.join(d, CH_TEST + ".cu")):
        raise SystemExit("runcheck --characterize-hw: litmus7 emitted no "
                         "harness:\n%s" % r.stderr)
    return d


def ch_build(d, arch):
    env = dict(os.environ)
    env["CUDA_ARCH"] = arch
    r = sh(["sh", "comp.sh", "cuda-link"], cwd=d, env=env)
    if r.returncode != 0:
        raise SystemExit("runcheck --characterize-hw: comp.sh cuda-link failed:\n"
                         + (r.stdout + r.stderr)[-2000:])


def ch_env(**kw):
    env = dict(os.environ)
    env["HET_ALLOC"] = env.get("HET_ALLOC", "pinned")
    env["HET_RUNS_MAX"] = env.get("HET_RUNS_MAX", CH_RUNS)
    env["HET_CAP_CPU"] = env.get("HET_CAP_CPU", CH_CAP_CPU)
    env.update(kw)
    return env


def ch_run_until_sighting(d, quiet=False):
    """Run with fresh seeds until the outcome fires once, or until the seeds run
    out -- the last run either way.  Returns (text, k, R, obs, tries); text is
    stdout+stderr, the whole printout a reader sees.

    A DISCARDED run ends the loop on the spot: a fresh seed draws a fresh phase,
    not a partner that arrives, so re-seeding a box whose rendezvous cannot
    complete only spends its runs."""
    env = ch_env()
    last = None
    hangs = 0
    for i in range(1, CH_SEED_TRIES + 1):
        env["HET_SEED"] = str(1000 + i)
        try:
            r = subprocess.run([os.path.join(d, CH_TEST)], cwd=d, env=env,
                               capture_output=True, text=True,
                               timeout=CH_RUN_TIMEOUT)
        except subprocess.TimeoutExpired:
            # HET_ALLOC=pinned on a device without host-native atomics can lose
            # barrier increments and stall -- the harness's own banner says so.
            # A stalled run is a property of THIS box, not of the printout, so it
            # is retried; only an all-stall is reported, and never as a pass.
            hangs += 1
            if not quiet:
                print("      seed %d: STALLED at the rendezvous after %ds, retrying"
                      % (1000 + i, CH_RUN_TIMEOUT))
            if hangs >= CH_SEED_TRIES:
                raise SystemExit(
                    "runcheck --characterize-hw: every one of %d runs stalled at "
                    "the rendezvous.  HET_ALLOC=%s cannot make a system-scope "
                    "atomic barrier on this device; re-run with an allocator that "
                    "can." % (hangs, env["HET_ALLOC"]))
            continue
        text = r.stdout + "\n" + r.stderr
        m = re.search(r"^HetStats \S+ cpu_only=\d+ obs=(\S+) R=(\d+) usable=(\d+) "
                      r"k=(\d+) ", r.stdout, re.M)
        if not m:
            raise SystemExit("runcheck --characterize-hw: the run printed no "
                             "HetStats line (rc=%d)\n%s" % (r.returncode,
                                                            text[-2000:]))
        obs, R, usable, k = (m.group(1), int(m.group(2)), int(m.group(3)),
                             int(m.group(4)))
        last = (text, k, R, obs, usable, i)
        if k > 0:
            return last
        if "COLD-INVALID" in text:
            if not quiet:
                print("      seed %d: the run was DISCARDED, which no fresh seed "
                      "undoes -- read as the arm this box printed" % (1000 + i))
            return last
        if not quiet:
            print("      seed %d: k=0, retrying (a sighting carries the report "
                  "sentence and the denominator reading as well)" % (1000 + i))
    return last


# What a run that SAW the outcome must print, and what a run that did not must
# print instead.  The arms are exclusive and one of them always applies, so a
# device that fires, one that does not and one whose rendezvous never completes
# are all read.
CH_OBSERVED = [": OBSERVED",
               "Report it as what %s exhibited" % CH_PAIR]
CH_NULL = ["NOT OBSERVED under this effort",
           "NO RATE AND NO PROBABILITY IS ATTACHED TO THIS NULL",
           "CHARACTERIZATION, NEVER VALIDATION",
           "effort:",
           # The effort a null is entitled to report is the iterations it read
           # back, so the number has to be on the line beside the sentence.
           "scored="]
# ... and what a run every cell of which was DISCARDED must print instead.  A box
# whose rendezvous cannot complete produces this arm legitimately -- mapped
# pinned memory with no host-native atomics loses increments -- so it is read as
# the arm it is, and what it may NOT do is read as reach.
CH_COLD = ["DISCARD this null -- the harness was not demonstrably hot",
           "the weak outcome was NOT observed",
           "VOID -- not one of",
           "scored="]
# The second run: caps of one poll, where the rendezvous cannot complete.  No
# injection produces this -- a run-time knob does -- so the disqualifier's own
# bite is a run rather than a mutation.
CH_CAP1 = ["COLD-INVALID",
           "DISCARD this null -- the harness was not demonstrably hot",
           "A timed-out rendezvous is a DEAD PARTNER"]
# What NEITHER arm may carry: a voucher named, a constant standing in for the pair,
# a build fault reported as a result.  Every entry is planted by an injection
# below, so this list holds only wording a run can be made to carry; a sentence no
# code produces would be looked for here forever and catch nothing.  These tuples
# are reached only through --characterize-hw, which refuses to run without a CUDA
# device: on a box with no GPU they go unchecked.
CH_NEVER_SAYS = [
    ("vouched for by",
     "nothing here certifies this run, and the printout may not say that "
     "anything does"),
    ("the target this harness was tagged for",
     "a constant standing in for the pair names an object no stamp makes right"),
    ("BUILD BUG",
     "the harness is reporting a build fault, which is not a result to read"),
]


def ch_class(k, R, obs, usable):
    """Judge the observation class against the counts it was read off.  Returns
    (failure, note) with exactly one of the two set.

    VOID is a READING, not a failure: a run whose every cell was discarded --
    which a box whose rendezvous cannot complete legitimately produces -- has
    measured nothing, and VOID is the class that says so.  What is refused is a
    class that contradicts the counts beside it, in either direction.

    Below that, the denominator is R, the runs executed, so het_verdict.h reads
    obs=Always off k >= R and obs=Never off k == 0.  obs=Always under k<R would
    mean the denominator had collapsed onto the usable count instead, and
    obs=Never with a sighting in it, or anything else with none, is a class that
    contradicts the counts beside it.

    The bite's shape table is what drives every branch, including the ones a
    given device never lands in."""
    if usable == 0:
        if obs == "VOID":
            return (None, "[F] obs=VOID on 0 usable cell(s) of R=%d (every run "
                          "was discarded, and that is the class which says so)" % R)
        return ("[F] obs=%s on 0 usable cell(s) of R=%d: nothing was measured "
                "and the class does not say so" % (obs, R), None)
    if obs == "VOID":
        return ("[F] obs=VOID on %d usable cell(s) of R=%d: a pool with a usable "
                "cell measured something" % (usable, R), None)
    if k == 0:
        if obs == "Never":
            return (None, "[F] obs=Never on k=0 of R=%d (nothing fired, and that "
                          "is the class which says so)" % R)
        return ("[F] obs=%s on k=0 of R=%d: nothing fired and the class does not "
                "say so" % (obs, R), None)
    if k < R and obs == "Always":
        return ("[F] obs=Always on k=%d of R=%d: the denominator collapsed "
                "onto the runs that fired" % (k, R), None)
    if k < R:
        return (None, "[F] obs=%s on k=%d of R=%d (denominator is R, not the "
                      "usable count)" % (obs, k, R))
    if obs == "Always":
        return (None, "[F] obs=Always on k=%d of R=%d (every run fired, and "
                      "that is the class which says so)" % (k, R))
    return ("[F] obs=%s on k=%d of R=%d: every run fired and the class does "
            "not say so" % (obs, k, R), None)


def ch_check(text, k, R, obs, usable, quiet=False):
    """Every assertion is on the PRINTOUT.  Returns a list of failures."""
    bad = []
    say = (lambda *_: None) if quiet else print

    def must(tag, frag):
        if frag not in text:
            bad.append("[%s] the printout never says %r" % (tag, frag))
        else:
            say("      [%s] %s" % (tag, frag[:88]))

    def never(tag, frag, why):
        if frag in text:
            bad.append("[%s] the printout says %r -- %s" % (tag, frag, why))

    must("A", "HetVerdict %s run=" % CH_TEST)

    # Which arm this box printed.  A sighting outranks everything; otherwise a
    # printout whose every run was discarded is the COLD arm and one with a
    # usable run is the null arm.
    classes = set(re.findall(r"^HetVerdict \S+(?: CPU-ONLY)? run=\d+: (\S+)$",
                             text, re.M))
    if k > 0:
        arm, frags = "OBSERVED", CH_OBSERVED
    elif classes == {"COLD-INVALID"}:
        arm, frags = "COLD-INVALID", CH_COLD
    else:
        arm, frags = "NOT-OBSERVED", CH_NULL
    say("      [D] the %s arm (%s)" % (arm, ", ".join(sorted(classes)) or "none"))
    for frag in frags:
        must("D", frag)
    for frag, why in CH_NEVER_SAYS:
        never("B/C", frag, why)

    why, note = ch_class(k, R, obs, usable)
    if why is not None:
        bad.append(why)
    else:
        say("      %s" % note)
    return bad


def ch_run_once(d, quiet=False):
    got = ch_run_until_sighting(d, quiet=quiet)
    if got is None:
        return 1, ["the harness produced no run at all"]
    text, k, R, obs, usable, tries = got
    if k == 0 and not quiet:
        print("      the outcome never fired in %d x %d runs, so a non-sighting "
              "arm is what this device printed and what is read here"
              % (tries, R))
    bad = ch_check(text, k, R, obs, usable, quiet=quiet)
    return (1 if bad else 0), bad


def ch_cap_run(d, quiet=False):
    """The rendezvous disqualifier, driven by a knob instead of an injection.

    Under caps of ONE poll a participant that does not find its partner already
    arrived gives up at once, so nearly every iteration is discarded and the run
    must be thrown away NAMING the rendezvous.  A box on which most iterations
    still complete inside a single poll would be a box where the two devices need
    no rendezvous at all, which is worth knowing and is not this arm passing."""
    say = (lambda *_: None) if quiet else print
    env = ch_env(HET_CAP_CPU="1", HET_CAP_GPU="1", HET_RUNS_MAX="1",
                 HET_SEED="1")
    try:
        r = subprocess.run([os.path.join(d, CH_TEST)], cwd=d, env=env,
                           capture_output=True, text=True, timeout=CH_RUN_TIMEOUT)
    except subprocess.TimeoutExpired:
        return ["[R] the caps=1 run STALLED after %ds -- a one-poll cap is the "
                "one wait that cannot stall" % CH_RUN_TIMEOUT]
    text = r.stdout + "\n" + r.stderr
    bad = []
    for frag in CH_CAP1:
        if frag not in text:
            bad.append("[R] under HET_CAP_CPU=1 HET_CAP_GPU=1 the printout never "
                       "says %r -- a rendezvous that cannot complete must be "
                       "discarded, and must say which mechanism was dead" % frag)
        else:
            say("      [R] %s" % frag[:88])
    if "NOT OBSERVED under this effort" in text:
        bad.append("[R] under HET_CAP_CPU=1 HET_CAP_GPU=1 the printout reports "
                   "reach: a run whose two sides never met is not a "
                   "non-observation")
    return bad


def ch_probe(tmp, arch, quiet=False):
    d = ch_emit(tmp)
    ch_build(d, arch)
    rc, bad = ch_run_once(d, quiet=quiet)
    if not quiet:
        print("===== the same binary under caps of one poll =====")
    bad = bad + ch_cap_run(d, quiet=quiet)
    return (1 if bad else 0), bad


def _subst(s, pairs):
    """Apply (find, replace) pairs, failing loudly if any `find' matched nothing.

    characterize_hw_bite checks only that the file changed OVERALL, which a
    two-fragment injection satisfies with one fragment matched and the other
    silently dropped -- half an injection that still reports RED for its own
    reason.  One `find' per site, replaced once."""
    for a, b in pairs:
        if a not in s:
            raise SystemExit("runcheck --characterize-hw bite: injection fragment "
                             "not found in the emitted harness -- the file moved "
                             "under the bite: %r" % a[:70])
        s = s.replace(a, b, 1)
    return s


# Each injection rewrites one file of the emitted harness (never the source tree)
# and names both that file -- the two halves of the printout come from two places,
# the verdict/statistics prose from het_verdict.h and the driver's own warnings
# from the render itself -- and the failure it must produce, which is the
# assertion that catches the sentence it planted rather than the one that merely
# notices a sentence went missing.
# Each injection lands on a line EVERY run prints, whichever arm it took, so a
# device that fires and a device that does not both exercise it.  Between them
# they plant every entry of CH_NEVER_SAYS.
CH_INJECTIONS = [
    ("B/C", "het_verdict.h",
     "the verdict banner says something vouched for the run",
     lambda s: _subst(s, [
         ('  fprintf(_ch, "HetVerdict %s%s run=%d: %s\\n",',
          '  fprintf(_ch, "HetVerdict %s%s run=%d: %s'
          '  (vouched for by mu(T))\\n",')]),
     "the printout says 'vouched for by'"),
    # The two pair-naming sentences belong to the sighting and null frames, and a
    # DISCARDED run prints neither -- so the constant is planted on the verdict
    # banner as well, which every arm prints.  That the two frames name the pair
    # is verdictcheck's, over synthetic records where no box can withhold an arm.
    ("A/D", "het_verdict.h",
     "the pair-naming sentences name a constant instead of the pair",
     lambda s: _subst(s, [
         ("      HET_PAIR_NAME, HET_LINK_NAME);",
          '      "the target this harness was tagged for", HET_LINK_NAME);'),
         ("    HET_PAIR_NAME);",
          '    "the target this harness was tagged for");'),
         ('  fprintf(_ch, "HetVerdict %s%s run=%d: %s\\n",',
          '  fprintf(_ch, "HetVerdict %s%s run=%d: %s'
          '  (the target this harness was tagged for)\\n",')]),
     "the printout says 'the target this harness was tagged for'"),
    # The record stamp is what gates every field het_verdict() would read, so a
    # harness that ships without one prints a build fault where a result belongs
    # -- on every run, whichever arm it took.
    ("B/C", CH_TEST + ".cu",
     "the emitted driver ships an UNSTAMPED record",
     lambda s: _subst(s, [
         ("    _rec.rec_magic = HET_REC_MAGIC;\n", "")]),
     "the printout says 'BUILD BUG'"),
]


# The (k, usable, obs) shapes ch_class must tell apart.  Which one a run lands in
# is the device's to decide and not this gate's, so the classifier and the
# ch_check call that turns its verdict into a failure are driven directly:
# (k, R, usable, obs, must the class READ, the fragment its own sentence owes).
CH_SHAPES = [
    (0, 10, 0, "VOID", True, "every run was discarded"),
    (0, 10, 0, "Never", False, "nothing was measured and the class does not say so"),
    (0, 10, 10, "VOID", False, "a pool with a usable cell measured something"),
    (0, 10, 10, "Sometimes", False, "nothing fired and the class does not say so"),
    (0, 10, 10, "Never", True, "nothing fired"),
    (4, 10, 10, "Always", False, "the denominator collapsed"),
    (4, 10, 10, "Sometimes", True, "denominator is R"),
    (10, 10, 10, "Always", True, "every run fired"),
]


def characterize_hw_bite(tmp, arch):
    """Every injection is judged on a failure carrying its own reason string, so
    the green arm is the gate's own run -- `--characterize-hw' with no flag,
    which the Makefile runs first -- and not a re-run here.  A box on which the
    outcome stopped firing reddens every injection with the no-sighting sentence,
    which is no injection's reason, and is reported as the box rather than banked
    as bites."""
    print("===== BITE: does this gate read the PRINTOUT? =====")
    bad = 0
    for k, R, usable, obs, want_read, frag in CH_SHAPES:
        why, note = ch_class(k, R, obs, usable)
        got = note if why is None else why
        # A class only counts once ch_check has carried it into the failures a
        # run is judged on: a refusal must arrive there and a reading must leave
        # nothing behind.  The printout handed over is empty, because ch_check's
        # assertions on a printout are what the injections below drive, on the
        # device; the class is the one verdict it reaches without one.
        carried = [m for m in ch_check("", k, R, obs, usable, quiet=True)
                   if m.startswith("[F]")]
        if (why is None) != want_read:
            print("  *** [F] k=%d of R=%d (usable=%d) obs=%s: the class is %s and "
                  "must be %s -- %s"
                  % (k, R, usable, obs, "read" if why is None else "refused",
                     "read" if want_read else "refused", got))
            bad += 1
        elif frag not in got:
            print("  *** [F] k=%d of R=%d (usable=%d) obs=%s: judged, but not by "
                  "its own sentence (%r is not in it) -- %s"
                  % (k, R, usable, obs, frag, got))
            bad += 1
        elif carried != ([] if want_read else [why]):
            print("  *** [F] k=%d of R=%d (usable=%d) obs=%s: the class is %s, and "
                  "ch_check returns %s -- a run is judged on that list, so it "
                  "carries the refusal or it carries nothing"
                  % (k, R, usable, obs, "read" if want_read else "refused",
                     ", ".join(carried) or "no class failure at all"))
            bad += 1
        else:
            print("      %s" % got)
    for tag, fname, what, mutate, expect in CH_INJECTIONS:
        d = ch_emit(tmp)
        hdr = os.path.join(d, fname)
        src = open(hdr).read()
        new = mutate(src)
        if new == src:
            print("  *** [%s] %s: the injection changed NOTHING -- this bite "
                  "proves nothing" % (tag, what))
            bad += 1
            continue
        open(hdr, "w").write(new)
        ch_build(d, arch)
        rc, why = ch_run_once(d, quiet=True)
        hit = [m for m in why if expect in m]
        if rc == 0:
            print("  *** [%s] %s: the gate stayed GREEN" % (tag, what))
            bad += 1
        elif not hit:
            # A run that never fired the outcome reddens too, and says so; it is
            # the box that failed, not the injection that was seen.
            print("  *** [%s] %s: RED, but for another reason (%r is in no "
                  "failure): %s" % (tag, what, expect, why[0][:150]))
            bad += 1
        else:
            print("      [%s] RED on %s" % (tag, what))
            print("          %s" % hit[0][:150])
    if bad:
        print("\nBITE FAILED: %d injection(s) went unnoticed." % bad)
        return 1
    print("\nBITE OK (%d injections, each RED for its own reason; %d observation "
          "classes told apart)" % (len(CH_INJECTIONS), len(CH_SHAPES)))
    return 0


def characterize_hw(want_bite=False):
    arch = ch_arch()
    if arch is None:
        # NOT a skip.  This mode BUILDS AND RUNS a harness on the device;
        # skipping it quietly is how a check stops checking.
        raise SystemExit(
            "runcheck --characterize-hw: no CUDA device is visible (nvidia-smi "
            "reported none).\n  There is nothing it can assert without one, so it "
            "fails rather than passing vacuously.")
    print("runcheck --characterize-hw: %s, %s, HET_ALLOC=%s"
          % (CH_PAIR, arch, os.environ.get("HET_ALLOC", "pinned")))
    tmp = tempfile.mkdtemp(prefix="runcheck-chhw.")
    try:
        if want_bite:
            return characterize_hw_bite(tmp, arch)
        print("===== the printout of a run =====")
        bad = ch_probe(tmp, arch)[1]
        if bad:
            print("\nCHARACTERIZE-HW FAILED: %d problem(s)." % len(bad))
            for m in bad:
                print("  %s" % m)
            return 1
        print("\nCHARACTERIZE-HW: PASS (the printout names the test, reads as "
              "the arm the run took, claims no machine and names no voucher; and "
              "a rendezvous that cannot complete is DISCARDED naming itself)")
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


PHASES = [
    ("1: --dry-run acts on nothing", lambda q: phase1_dryrun(WRAPPER, q)),
    ("2: the chain end to end (stub compiler + stub probe)",
     lambda q: phase2_e2e(WRAPPER, q)),
    ("3: the refusals by their own reasons",
     lambda q: phase3_refusals(WRAPPER, q)),
    ("4: campaign.py's stop rule and the states it may not resume",
     lambda q: phase4_stoprule(CAMPAIGN, q)),
    ("6: the fail-closed handlers, under their own conditions",
     lambda q: phase6_failclosed(WRAPPER, q)),
    ("7: a second session into the same results dir",
     lambda q: phase7_second_session(WRAPPER, q)),
    ("8: probe-hip.sh's exit paths", lambda q: phase8_probe_hip(PROBE_HIP, q)),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bite", action="store_true",
                    help="prove each phase reddens on a planted defect")
    ap.add_argument("--characterize-hw", action="store_true",
                    help="build two harnesses and read what they PRINT "
                         "(toolchain lane)")
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args()

    if not os.access(os.path.join(BIN, "litmus7"), os.X_OK):
        raise SystemExit("runcheck: litmus7 not built (run 'make all')")
    if a.characterize_hw:
        return characterize_hw(want_bite=a.bite)
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
    print("\nRUNCHECK OK (the plan is a plan; the chain records what it did; "
          "every refusal named its own reason; every fail-closed handler was seen "
          "to fire)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

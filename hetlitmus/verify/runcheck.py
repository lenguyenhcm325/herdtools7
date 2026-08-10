#!/usr/bin/env python3
"""runcheck.py -- the device-session wrapper (hetlitmus/hetlitmus-run.sh), driven
end to end on a box with no device.

The wrapper is the one command a hardware session runs, so what it decides -- the
pair, the machine that pair may name, the architecture the binaries are built for
-- is decided on a machine nobody is watching and is visible afterwards only in
what it wrote down.  Every phase below drives it with the compiler and the probe
replaced by the wrapper's documented stand-ins, so those decisions are checked
here rather than on rented hardware.

HOST-ADAPTIVE.  The chain phases need a corpus whose CPU column is this host's:
`fixture()' picks the committed x86 fixture on an x86_64 box and a cut of the
committed AArch64 corpus on an aarch64 one, and the pairs each phase expects
follow that choice.  Nothing here is x86-only, so the GH200 runs the same gate.

  PHASE 1  --dry-run prints the plan and does NOT act: no results dir at all.
  PHASE 2  the chain end to end on each dialect this host reaches.
  PHASE 3  the refusals, each by its own reason -- and the unregistered pair,
           which is a WARNING and emits.
  PHASE 4  campaign.py's stop rule, and the states it may not resume.
  PHASE 5  the machine-table reader, bounded to the table literal.
  PHASE 6  the fail-closed handlers, each under its own induced condition.
  PHASE 7  a second session into a results dir that already holds one.
  PHASE 8  probe-hip.sh's exit paths.

`--bite' plants one defect per assertion in a COPY of the script under test (never
in the tree) and requires the phase to redden for the right reason.  Two device
modes need a GPU and are the -nvcc lane's half of this gate: `--hw' runs the same
wrapper on the real device, and `--characterize-hw' builds two harnesses and reads
what they PRINT (the only artefact a result is ever read off).
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
MACHINE_ML = os.path.join(ROOT, "litmus", "hetMachine.ml")
BIN = os.path.join(ROOT, "_build", "install", "default", "bin")

sys.path.insert(0, HERE)
import brandscan          # noqa: E402  (the tree's own module, next to this one)

# The committed (x86_64, *) fixture, cut verbatim from a generate-x86.sh run and
# kept that way by hetlitmus-x86fixture.  It is CLOSED UNDER THE CONTROL MAP:
# S-cg-sys-relaxed-x86_64 is here because the S row names it as mu(T) and
# emission refuses a control it cannot build.
X86_DIR = os.path.join(HETL, "tests", "het-x86")
X86_TESTS = ["MP-cg-sys-acqrel-2s-x86_64", "MP-cg-sys-relaxed-x86_64",
             "S-cg-sys-fence-x86_64", "S-cg-sys-relaxed-x86_64"]
# The (AArch64, *) lane is the committed 411-test corpus, and a session over all
# of it is not a gate.  The cut below is copied out of it VERBATIM at run time --
# tests plus the two files the emitter resolves beside them -- so it is not a
# second fixture that could go stale; it is the corpus, minus rows.  Closed under
# the control map: every row here names its lattice-floor sibling as mu(T) and
# MP-cg-sys-relaxed as its canary, and emission refuses a control it cannot build.
AARCH64_DIR = os.path.join(HETL, "tests", "het")
AARCH64_TESTS = ["MP-cg-sys-acqrel-2s", "MP-cg-sys-acquire", "MP-cg-sys-relaxed",
                 "S-cg-sys-fence", "S-cg-sys-relaxed"]
AARCH64_SIDE = ["control-map.csv"]

# One HetStats machine line, the whole interface between a harness and
# campaign.py, in the field order and field set het_stats_line prints -- a stub
# that speaks a shape the runtime cannot produce is testing a protocol nobody
# implements.  A null with a measured dispersion, so a bound is reachable and
# nothing fires: what the scheduler does with it is the phase's subject.
STUB_STATS = ("HetStats %s cpu_only=0 obs=Never R=10 usable=10 k=0 k_eff=0 "
              "k_runs=0 degen=0 first_sight=0 ctrl=canary mu_total=0 "
              "can_total=5000 win_n=1280 nwin=128 F_win=1.05 F_cell=1.02 "
              "r_hat=inf mu_upper=2.9957 tau_w=1.28 N_eff=100 tau_need=1 "
              "R_eff=100 p_bound=0.029957 P_rep=-1 acf1=0.01 ks=pass ks_D=0.1 "
              "ks_Dcrit=0.2 ks_split=-1 sighting=none N=100000 frames=100000 "
              "flags=0x0")

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
      "degen=0 first_sight=1 ctrl=canary mu_total=0 can_total=5000 win_n=1280 "
      "nwin=128 F_win=1.05 F_cell=1.02 r_hat=inf mu_upper=0 tau_w=1.28 N_eff=100 "
      "tau_need=1 R_eff=0 p_bound=-1 P_rep=0.632 acf1=0.01 ks=pass ks_D=0.1 "
      "ks_Dcrit=0.2 ks_split=-1 sighting=CORROBORATED N=100000 frames=100000 "
      "flags=0x0" % os.path.basename(d))
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
      "degen=0 first_sight=%d ctrl=canary mu_total=0 can_total=5000 win_n=1280 "
      "nwin=128 F_win=1.05 F_cell=1.02 r_hat=inf mu_upper=0 tau_w=1.28 N_eff=100 "
      "tau_need=1 R_eff=0 p_bound=-1 P_rep=-1 acf1=0.01 ks=pass ks_D=0.1 "
      "ks_Dcrit=0.2 ks_split=-1 sighting=%s N=100000 frames=100000 flags=0x0"
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
TERMINAL = ("CORROBORATED", "UNCONFIRMED-SIGHTING", "BOUND-MET", "BUDGET", "ERROR")


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
# THE FIXTURE THIS HOST CAN DRIVE, and what litmus/hetMachine.ml says about its
# two dialects.  The emitted link targets refuse a foreign host, so a corpus
# whose CPU column is not this box's has no chain to drive here.  Every row of
# every campaign takes the same stop rule whatever the pair: no harness carries a
# prediction, so the pair changes what a render may CLAIM and nothing about what
# it does.
# ---------------------------------------------------------------------------
_CUT = None


def aarch64_corpus():
    """The AArch64 cut, copied verbatim out of the committed corpus on demand."""
    global _CUT
    if _CUT is None:
        d = tempfile.mkdtemp(prefix="runcheck-aarch64.")
        atexit.register(shutil.rmtree, d, True)
        for f in [t + ".litmus" for t in AARCH64_TESTS] + AARCH64_SIDE:
            shutil.copy(os.path.join(AARCH64_DIR, f), d)
        _CUT = d
    return _CUT


def fixture():
    """{isa, key, dir, tests, map, cuda: arm, hip: arm} for this host, or None."""
    m = platform.machine()
    if m == "x86_64":
        fx = {
            "isa": "x86_64", "key": "X86_64", "dir": X86_DIR, "tests": X86_TESTS,
            "map": "control-map-amd.csv",
            "cuda": {"state": "NO-MACHINE", "machine": "NONE", "arch": "sm_86"},
            "hip": {"state": "MACHINE", "machine": "mi300a_machine",
                    "arch": "gfx942"},
        }
    elif m in ("aarch64", "arm64"):
        fx = {
            "isa": "aarch64", "key": "AArch64", "dir": aarch64_corpus(),
            "tests": AARCH64_TESTS, "map": "control-map.csv",
            "cuda": {"state": "MACHINE", "machine": "gh200_machine",
                     "arch": "sm_90"},
            "hip": {"state": "ABSENT", "machine": "NONE", "arch": "gfx942"},
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
    """(corpus, target) whose CPU lane is NOT this host's, and whose pair IS
    registered -- so the session reaches the host-ISA refusal, not an earlier one."""
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
        out = os.path.join(tmp, "never-created")
        r = run_wrapper(wrapper, ["--gpu-target", "cuda", "--corpus", fx["dir"],
                                  "--arch", arm["arch"], "--out", out, "--dry-run"])
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
    # THE RESULTS DIR IS THE DELIVERABLE: a session that ran but recorded nothing
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
    for frag in ("arch=" + arm["arch"], "pair_state=" + arm["state"],
                 "pair_machine=" + arm["machine"], "control_map=" + fx["map"],
                 "seam_probe=STUB",
                 "seam_compiler=OVERRIDDEN", "session_status=COMPLETE"):
        if frag not in record:
            bad.append("%s: run-record.txt does not carry %r -- the value the "
                       "session turned on is not a recorded fact" % (target, frag))
    rows = state_rows(os.path.join(out, "campaign-state.csv"))
    bad += state_is_terminal("%s: " % target, rows, fx["tests"])
    # An unregistered pair is WARNED about, not refused: the session runs, and
    # the one thing it loses is the machine its renders may name.
    if arm["state"] == "ABSENT" and "is in no row of litmus/hetMachine.ml" \
            not in r.stderr:
        bad.append("%s: the pair is in no row of the machine table and the session "
                   "never said so -- it said: %s" % (target, r.stderr[-300:]))
    if not quiet and not bad:
        print("      %-4s -> %-14s %-16s %d row(s)"
              % (target, arm["state"], arm["machine"], len(rows)))
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
    """A corpus carrying both CPU lanes.  Only the first test used to be read, so
    this passed the preflight and died at emission blaming the pair table."""
    d = os.path.join(tmp, "mixed")
    os.makedirs(d, exist_ok=True)
    for f in os.listdir(X86_DIR):
        if f.endswith((".litmus", ".csv")):
            shutil.copy(os.path.join(X86_DIR, f), d)
    shutil.copy(os.path.join(AARCH64_DIR, AARCH64_TESTS[0] + ".litmus"), d)
    return d


# The (AArch64, hip) pair is in no row of the machine table, and a corpus with an
# AArch64 CPU column is committed, so this is the unregistered case every host can
# drive THROUGH LITMUS7 -- emission does not care which box it runs on.
UNREG_PAIR = "(AArch64, hip)"
UNREG_TEST = "MP-cg-sys-relaxed"
UNREG_WARN = "is in no row of litmus/hetMachine.ml"
MACHINE_DEFINE_RE = re.compile(
    r"^#define HET_(LINK_NAME|HOST_HALF|DEV_HALF|LLC_MB|ALGLAVE_ZERO_MEASURED)\b",
    re.M)


def unregistered_emits(quiet=False):
    """An unregistered pair EMITS: exit 0, one warning, and a render that names
    no machine.  Driven straight through litmus7, so it runs on every host."""
    bad = []
    tmp = tempfile.mkdtemp(prefix="runcheck3-unreg.")
    try:
        r = sh([os.path.join(BIN, "litmus7"), "-gpu-target", "hip", "-o", tmp,
                UNREG_TEST + ".litmus"], cwd=AARCH64_DIR)
        if r.returncode != 0:
            bad.append("litmus7 exited %d on the unregistered pair %s -- warn, "
                       "never refuse: %s"
                       % (r.returncode, UNREG_PAIR, r.stderr.strip()[-300:]))
            return bad
        warns = set(l for l in r.stderr.splitlines() if UNREG_WARN in l)
        if len(warns) != 1:
            bad.append("emitting %s printed %d distinct warning(s) about the pair, "
                       "want exactly 1: %s" % (UNREG_PAIR, len(warns), sorted(warns)))
        elif UNREG_PAIR not in warns.pop():
            bad.append("the warning does not name %s" % UNREG_PAIR)
        render = os.path.join(tmp, UNREG_TEST, UNREG_TEST + ".hip")
        if not os.path.exists(render):
            bad.append("no .hip render for the unregistered pair")
            return bad
        text = open(render).read()
        if '#define HET_PAIR_NAME "%s"' % UNREG_PAIR not in text:
            bad.append("the render does not stamp HET_PAIR_NAME %r" % UNREG_PAIR)
        stamped = MACHINE_DEFINE_RE.findall(text)
        if stamped:
            bad.append("the render of an unregistered pair stamps machine "
                       "define(s) %s -- it is entitled to none" % stamped)
        # ...and it must not SAY one either, which is the half no define can
        # decide: the whole harness dir, over the literals its driver prints and
        # the README and build files a reader opens (brandscan.py).
        named = brandscan.scan([os.path.join(tmp, UNREG_TEST)], "none")
        for path, ln, row, w, excerpt in named[:6]:
            bad.append("the harness of an unregistered pair names %r (the %s row) "
                       "in %s:%d -- %s"
                       % (w, row, os.path.basename(path), ln, excerpt[:100]))
        if len(named) > 6:
            bad.append("...and %d more machine word(s) in that harness"
                       % (len(named) - 6))
        if not quiet and not bad:
            print("      %-34s emits (rc=0), 1 warning, 0 machine defines, "
                  "0 machine words" % UNREG_PAIR)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return bad


def unregistered_session(wrapper, fx, quiet=False):
    """...and the WRAPPER does not refuse one either.  On a host whose own CPU
    lane makes the unregistered pair the session runs; elsewhere the aarch64
    corpus reaches the warning and then dies of the FOREIGN HOST, not of the
    pair."""
    bad = []
    if fx["hip"]["state"] == "ABSENT":
        args = ["--gpu-target", "hip", "--corpus", fx["dir"], "--arch",
                fx["hip"]["arch"], "--dry-run"]
        want_rc, want_frag = 0, UNREG_WARN
    else:
        args = ["--gpu-target", "hip", "--corpus", aarch64_corpus(), "--arch",
                "gfx942", "--dry-run"]
        want_rc, want_frag = 2, "uname -m is"
    r = run_wrapper(wrapper, args)
    if r.returncode != want_rc:
        bad.append("the wrapper exited %d on the unregistered pair, want %d -- an "
                   "unregistered pair is warned about, not refused: %s"
                   % (r.returncode, want_rc, (r.stdout + r.stderr).strip()[-300:]))
    elif UNREG_WARN not in r.stderr:
        bad.append("the wrapper says nothing about the unregistered pair; its "
                   "stderr was: %s" % (r.stderr.strip()[-300:] or "(empty)"))
    elif want_frag not in r.stderr + r.stdout:
        bad.append("the session did not reach %r; it said: %s"
                   % (want_frag, (r.stdout + r.stderr).strip()[-300:]))
    elif not quiet:
        print("      %-34s warned about, session rc=%d" % ("the wrapper on " +
                                                          UNREG_PAIR, want_rc))
    return bad


def mapless_corpus(tmp):
    """This host's fixture, minus the control map the lane reads.  Emission would
    build no control at all, so the session's nulls would be uninterpretable."""
    d = os.path.join(tmp, "mapless")
    os.makedirs(d, exist_ok=True)
    fx = fixture()
    for t in fx["tests"]:
        shutil.copy(os.path.join(fx["dir"], t + ".litmus"), d)
    return d


def phase3_refusals(wrapper, quiet=False):
    fx = fixture()
    if fx is None:
        return no_fixture("3", quiet)
    bad = []
    tmp = tempfile.mkdtemp(prefix="runcheck3.")
    try:
        cc, probe = make_stubs(tmp)
        # A PATH with neither device-listing tool, to make --arch auto see nothing.
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
            ("corpus with no control map",
             ["--gpu-target", "cuda", "--corpus", mapless_corpus(tmp), "--arch",
              fx["cuda"]["arch"]], {}, "not readable beside the corpus"),
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
        # ...AND THE ONE THING THAT IS NO LONGER A REFUSAL.
        bad += unregistered_emits(quiet)
        bad += unregistered_session(wrapper, fx, quiet)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return bad


# ---------------------------------------------------------------------------
# PHASE 4 -- campaign.py's stop rule, and the states it may not resume.
# ---------------------------------------------------------------------------
CHAR_TESTS = ["CH-one", "CH-two"]
STATE_COLS = ["test", "stop", "invocations", "runs", "usable", "k", "k_eff",
              "k_runs", "first_sight", "R_eff", "mu_upper_max", "pooled_bound",
              "nwin", "tau_w", "N_eff", "tau_unresolved", "tau_need", "cpu_only",
              "note"]
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

        # THE STOP THAT ENDS A ROW EARLY: a sighting reproduced across distinct clean
        # runs.  Without it the phase below would prove nothing -- a runner whose
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

        # THE FLAGGED STOP, and the precedence that produces it: one sighting, then
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

        # THE PRECEDENCE, IN HARDWARE HOURS: the same row under a budget SMALLER than
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

        # No row of any of these campaigns may carry the retired vocabulary: no
        # harness carries a prediction, so nothing here agrees or disagrees with one.
        for st in (st_c, st_l, st_r):
            body = open(st).read()
            for word in ("Disallowed", "NO-ORACLE", "Allowed", "MISMATCH", "MATCH",
                         "OBSERVED"):
                if word in body:
                    bad.append("%s carries %r -- a campaign that predicts nothing "
                               "cannot record agreement with a prediction"
                               % (os.path.basename(st), word))

        # THE ONE PATH BY WHICH AN ADJUDICATION COULD STILL REACH A RUN: a state file
        # carries terminal stops and a resumed row inherits them.  A row banked by
        # the oracle-era rule (OBSERVED / CONFIRMED) names a stop this rule cannot
        # write, so resuming it must fail closed rather than inherit it.
        legacy = os.path.join(tmp, "legacy.csv")
        with open(legacy, "w", newline="") as fh:
            w = csv.writer(fh)
            w.writerow(STATE_COLS)
            for t, stop in (("CH-one", "OBSERVED"), ("CH-two", "CONFIRMED")):
                w.writerow([t, stop, 1, 10, 10, 1, 1, 3, 1, "0", "0", "-1", 128,
                            "1.28", "100", 0, 1, 0, "banked by another rule"])
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

        # D-MV5's banned artefact: nothing may have written a control map to stand in
        # for one this scheduler no longer reads at all.
        made = [f for f in os.listdir(tmp) if "control-map" in f]
        if made:
            bad.append("a stand-in control map was created: %s" % made)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return bad


# ---------------------------------------------------------------------------
# PHASE 5 -- the machine-table reader.  A row is a row only INSIDE the table
# literal: a reader that ran past the closing bracket reads a row-shaped line out
# of a comment or a doc example as if it were a registered pair.  The doctored
# copies below are what make that visible -- the committed file happens to survive
# an unbounded parse, and a file with a row-shaped line after the table does not.
# ---------------------------------------------------------------------------
READER_WANT = {("AArch64", "cuda"): "MACHINE gh200_machine",
               ("X86_64", "hip"): "MACHINE mi300a_machine",
               ("X86_64", "cuda"): "NO-MACHINE",
               ("AArch64", "hip"): "ABSENT"}
LAST_ROW = '\n    ("X86_64", "sycl"), Some generic_machine ;\n'
TRAILING_DOC = ('\n(* Adding a machine is adding a row:\n'
                '    ("AArch64", "hip"), Some gh200_machine ;\n'
                '   and nothing else in the emitter changes. *)\n')


def _mkrepo(tmp, name, text):
    d = os.path.join(tmp, name)
    os.makedirs(os.path.join(d, "litmus"), exist_ok=True)
    with open(os.path.join(d, "litmus", "hetMachine.ml"), "w") as fh:
        fh.write(text)
    return d


def phase5_reader(wrapper, quiet=False):
    bad = []
    tmp = tempfile.mkdtemp(prefix="runcheck5.")
    try:
        m = re.search(r"^machine_pair\(\) \{.*?^\}", open(wrapper).read(),
                      re.S | re.M)
        if m is None:
            return ["the wrapper has no machine_pair(): the machine table is read "
                    "by something this phase cannot find, so it checks nothing"]
        drv = write_exec(os.path.join(tmp, "reader.sh"),
                         '#!/usr/bin/env bash\nset -euo pipefail\nREPO="$3"\n'
                         + m.group(0) + '\nmachine_pair "$1" "$2"\n')
        real = open(MACHINE_ML).read()
        i = real.find("let table = [")
        j = real.find("\n  ]\n", i if i >= 0 else 0)
        if i < 0 or j < 0:
            return ["litmus/hetMachine.ml has no `let table = [' ... `]' literal: "
                    "this phase, and the reader it checks, are written for that shape"]
        want_last = dict(READER_WANT)
        want_last[("X86_64", "sycl")] = "MACHINE generic_machine"
        variants = [("the committed table", real, READER_WANT),
                    ("a machine row placed LAST", real[:j] + LAST_ROW + real[j:],
                     want_last),
                    ("a row-shaped line AFTER the table", real + TRAILING_DOC,
                     READER_WANT)]
        for n, (what, text, want) in enumerate(variants):
            if n and text == real:
                bad.append("%r is byte-identical to the committed table -- this "
                           "phase proves nothing about it" % what)
                continue
            repo = _mkrepo(tmp, "repo%d" % n, text)
            hits = 0
            for (isa, tgt), w in sorted(want.items()):
                got = sh(["bash", drv, isa, tgt, repo]).stdout.strip()
                if got != w:
                    bad.append("[%s] (%s, %s) reads %r, want %r -- the reader is "
                               "not bounded to the table literal"
                               % (what, isa, tgt, got, w))
                else:
                    hits += 1
            if not quiet and hits == len(want):
                print("      %-30s %d pair(s) read correctly" % (what, hits))
        # A file whose table literal moved must fail closed, not report every pair
        # absent -- which the wrapper would turn into "register the pair first".
        repo = _mkrepo(tmp, "repo-notable",
                       real.replace("let table = [", "let t = [", 1))
        got = sh(["bash", drv, "AArch64", "cuda", repo]).stdout.strip()
        if got != "NO-TABLE":
            bad.append("a hetMachine.ml with no `let table = [' reads %r, want "
                       "NO-TABLE" % got)
        elif not quiet:
            print("      a table literal that moved reads NO-TABLE, not ABSENT")
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
        elif "is above what these bound row(s) spent" not in r.stderr:
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

        # A REFUSED SESSION MUST NOT LEAVE THE PREVIOUS ONE'S SUMMARY BESIDE ITS
        # OWN RECORD: one dir would then describe two different sessions.
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
# PHASE 8 -- probe-hip.sh, under stand-in vendor tools.  It runs on no box the
# project owns, so its device answers are reachable here and nowhere else.
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
# THE BITES.  One planted defect per assertion, in a copy of the script under
# test.  Each names the failure it must produce: a phase that reddens for some
# other reason has not been shown to read what the injection broke.  A `None'
# there means any failure will do, and is for the one injection whose own failure
# text is a property of the host's fixture rather than of the defect.
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
    ("2", "wrapper", "the machine table is not read: every pair is the GH200 row",
     lambda s: s.replace(
         'read -r PAIR_STATE PAIR_MACHINE <<<"$(machine_pair "$ISA_KEY" "$GPU_TARGET")"',
         'PAIR_STATE=MACHINE ; PAIR_MACHINE=gh200_machine', 1),
     phase2_e2e, "pair_machine"),
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
    ("3", "wrapper", "the lane's control map is not required beside the corpus",
     lambda s: s.replace('[ -r "$CORPUS/$PAIR_MAP" ] || die',
                         '[ 1 = 1 ] || die', 1),
     phase3_refusals, "corpus with no control map"),
    ("3", "wrapper", "an unregistered pair passes without a word",
     lambda s: s.replace('    echo "hetlitmus-run: WARNING -- the pair $PAIR is in no row of \\',
                         '    echo "hetlitmus-run: (nothing to report) \\', 1),
     phase3_refusals, "says nothing about the unregistered pair"),
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
    ("5", "wrapper", "the machine-table reader runs past the table literal",
     lambda s: s.replace("/^[ \\t]*\\][ \\t]*$/ { intab = 0 ; next }",
                         "/^[ \\t]*\\][ \\t]*$/ { next }", 1),
     phase5_reader, "not bounded to the table literal"),
    ("6", "wrapper", "a harness that did not build does not stop the session",
     lambda s: s.replace('if [ "$nfail" -ne 0 ]; then', 'if false; then', 1),
     _p6("build"), "build"),
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
     _p6("emitted-isa"), "emitted-isa"),
    ("6", "wrapper", "the emitted pair name is not cross-checked",
     lambda s: s.replace('grep -qF "#define HET_PAIR_NAME \\"$PAIR\\"" "$f" || {',
                         'true || {', 1),
     _p6("stamp"), "stamp"),
    ("6", "wrapper", "--reuse-emitted accepts a missing emission",
     lambda s: s.replace('[ -d "$EMIT" ] || die "--reuse-emitted, but there is no',
                         '[ 1 = 1 ] || die "--reuse-emitted, but there is no', 1),
     _p6("reuse-missing"), "reuse-missing"),
    ("6", "wrapper", "a missing render is not noticed on reuse",
     lambda s: s.replace('[ -s "$f" ] || die "no .$RENDER_EXT render for $t under $EMIT"',
                         ': || die "no .$RENDER_EXT render for $t under $EMIT"', 1),
     _p6("reuse-partial"), "reuse-partial"),
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
        print("-- and the untouched scripts must be green, or `red' meant nothing")
        clean = []
        for _, phase in PHASES:
            clean += phase(True)
        if clean:
            print("  *** the UNTOUCHED wrapper/campaign/probe is RED (%s) -- the "
                  "injections above prove nothing" % clean[0].splitlines()[0][:150])
            bad += 1
        else:
            print("      the untouched wrapper, campaign and probe: GREEN")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    if bad:
        print("\nBITE FAILED: %d injection(s) went unnoticed." % bad)
        return 1
    print("\nBITE OK (%d injections, each RED for its own reason; restored GREEN)"
          % len(INJECTIONS))
    return 0


# ---------------------------------------------------------------------------
# --hw -- the same wrapper, on the device.  No stand-ins: the real probe, the
# real compiler, the real harness.  The pair it reaches is whichever one this
# host's fixture names, and what is asserted is that the session recorded the
# machine that pair's table row entitles it to and nothing more.
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


def _session(wrapper, tmp, fx, env, quiet):
    """One wrapper session on the device, retried past a rendezvous stall.
    Returns (completed process or None if every attempt stalled, results dir)."""
    out = None
    for i in range(1, STALL_TRIES + 1):
        out = os.path.join(tmp, "out-%d" % i)
        r = run_wrapper(wrapper, ["--gpu-target", "cuda", "--corpus", fx["dir"],
                                  "--arch", "auto", "--budget-runs", "10",
                                  "--out", out], env=env)
        if r.returncode == 0 or not _stalled(out):
            return r, out
        if not quiet:
            print("      attempt %d: a harness STALLED at the rendezvous (the "
                  "runner timed out); retrying" % i)
    return None, out


def hardware(wrapper=WRAPPER, quiet=False):
    fx = fixture()
    if fx is None:
        raise SystemExit("runcheck --hw: no committed corpus carries a %s CPU "
                         "column" % platform.machine())
    arm = fx["cuda"]
    env = dict(os.environ)
    env.setdefault("HET_ALLOC", "pinned")
    env.setdefault("HET_RUN_TIMEOUT", RUN_TIMEOUT)
    tmp = tempfile.mkdtemp(prefix="runcheck-hw.")
    try:
        if not quiet:
            print("runcheck --hw: (%s, cuda) over %d test(s), arch auto, "
                  "HET_ALLOC=%s" % (fx["key"], len(fx["tests"]), env["HET_ALLOC"]))
        r, out = _session(wrapper, tmp, fx, env, quiet)
        bad = []
        if r is None:
            bad.append("every one of %d sessions stalled at the rendezvous.  "
                       "HET_ALLOC=%s cannot make a system-scope atomic barrier on "
                       "this device; re-run with an allocator that can."
                       % (STALL_TRIES, env["HET_ALLOC"]))
        elif r.returncode != 0:
            if not quiet:
                print(r.stdout[-2500:])
            # The campaign's own log too: the session's stderr says only that it
            # exited, and a bite has to be able to tell WHICH failure it caused.
            log = os.path.join(out, "campaign.log")
            tail = open(log).read()[-800:] if os.path.exists(log) else ""
            bad.append("the session exited %d:\n%s\n%s"
                       % (r.returncode, r.stderr[-800:], tail))
        else:
            if not quiet:
                print(r.stdout[-2500:])
            summary = open(os.path.join(out, "summary.txt")).read()
            record = open(os.path.join(out, "run-record.txt")).read()
            if "CHARACTERIZATION" not in summary:
                bad.append("the summary does not say what the rows are:\n%s"
                           % summary)
            for frag in ("pair_state=" + arm["state"],
                         "pair_machine=" + arm["machine"]):
                if frag not in record:
                    bad.append("run-record.txt does not carry %r -- the machine this "
                               "session was entitled to name is not a recorded fact"
                               % frag)
            if "session_status=COMPLETE" not in record:
                bad.append("run-record.txt does not record a completed session")
            for frag in ("seam_probe", "seam_compiler", "seam_litmus7"):
                if frag in record:
                    bad.append("run-record.txt carries %s -- a hardware session "
                               "must run no stand-in" % frag)
            if "arch_source=auto" not in record:
                bad.append("the arch was not resolved on this box")
            rows = state_rows(os.path.join(out, "campaign-state.csv"))
            bad += state_is_terminal("", rows, fx["tests"])
            if "probe_status=OK" not in open(os.path.join(out, "probe.txt")).read():
                bad.append("the device probe did not report OK")
            for t in fx["tests"]:
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
            print("\nRUNCHECK --hw: PASS (the chain ran on the device, the "
                  "session named the machine its table row entitles it to, and "
                  "recorded what it did)")
        return 0, []
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# The device lane's own bite: the assertions above read a REAL session, so they
# are proved to bite against a real session too, not only against the stubbed
# chain of phase 2.
def hardware_bite():
    print("===== BITE: does the device lane read the session it ran? =====")
    fx = fixture()
    tmp = tempfile.mkdtemp(prefix="runcheck-hwbite.")
    bad = 0
    try:
        _, _, what, mutate, _, _ = INJECTIONS[1]
        target = copy_wrapper(tmp, mutate)
        if target is None:
            print("  *** the injection changed NOTHING -- this bite proves nothing")
            return 1
        rc, why = hardware(target, quiet=True)
        # RED FOR THE RIGHT REASON: a stalled session is red too, and would make
        # this bite pass without the assertion having read anything.  The injection
        # substitutes the pair's whole machine row, so its name settles it.
        named = ["pair_machine", "pair_state"]
        if rc == 0:
            print("  *** the device lane stayed GREEN on: %s" % what)
            bad += 1
        elif not any(n in m for m in why for n in named):
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


# ---------------------------------------------------------------------------
# --characterize-hw -- what a harness actually PRINTS, on the device.  Every
# other gate on the verdict/statistics stack drives it from synthetic records or
# from emitted text; this one builds a harness, runs it on the GPU and reads the
# printout, which is the only artefact a result is ever read off.
#
# TWO ARMS, because the two sentences a reader must never see swapped are chosen
# by whether a positive-control map was read at all, and the emitter looks for one
# beside every test:
#   map    the committed x86 fixture, whose map names this row its OWN canary --
#          "it IS the Layer-B canary", and its missing bound IS a construction;
#   nomap  the same test copied away from the map -- no map was read, nothing
#          marks this row a canary, and its missing bound is an OMISSION, of the
#          map FILE beside the test and of nothing else.
# The pair is (X86_64, cuda), which has no machine row, so neither arm may print
# a word of either row's machine vocabulary either.
#
# The outcome is stochastic, so each arm is re-seeded until it fires; a pair that
# cannot fire the most observable het shape in that many runs is itself the
# finding, and this says so rather than passing vacuously.
# ---------------------------------------------------------------------------
CH_TEST = "MP-cg-sys-relaxed-x86_64"
CH_PAIR = "(X86_64, cuda)"
CH_SEED_TRIES = 12
CH_RUN_TIMEOUT = 90          # a healthy run is ~3 s; past this it is stalled
# Both rows' vocabularies, from the one place that spells them (brandscan.py).
# The pair here is entitled to neither, so any of them in a PRINTOUT is a finding.
CH_VENDOR_RE = re.compile("|".join(brandscan.ROWS.values()), re.I)
CH_ARMS = ("map", "nomap")


def _ch_env():
    env = dict(os.environ)
    env["PATH"] = BIN + os.pathsep + env["PATH"]
    return env


def ch_arch():
    """sm_XY of the device this will actually run on -- never a hardcoded GH200
    sm_90, which does not load here."""
    if os.environ.get("CUDA_ARCH"):
        return os.environ["CUDA_ARCH"]
    r = sh(["nvidia-smi", "--query-gpu=compute_cap", "--format=csv,noheader"])
    caps = [l.strip() for l in r.stdout.splitlines() if l.strip()]
    if r.returncode != 0 or not caps:
        return None
    return "sm_" + caps[0].replace(".", "")


def ch_emit(tmp, arm):
    """Emit CH_TEST for one arm and return its harness dir.  The `nomap' arm is
    emitted from a copy of the test WITHOUT the lane's map beside it."""
    src = X86_DIR
    if arm == "nomap":
        src = tempfile.mkdtemp(dir=tmp)
        shutil.copy(os.path.join(X86_DIR, CH_TEST + ".litmus"), src)
    out = tempfile.mkdtemp(dir=tmp)
    r = sh(["litmus7", "-gpu-target", "cuda", "-set-libdir",
            os.path.join(ROOT, "litmus", "libdir"), "-o", out,
            os.path.join(src, CH_TEST + ".litmus")], cwd=ROOT, env=_ch_env())
    d = os.path.join(out, CH_TEST)
    if r.returncode != 0 or not os.path.exists(os.path.join(d, CH_TEST + ".cu")):
        raise SystemExit("runcheck --characterize-hw: litmus7 emitted no %s "
                         "harness:\n%s" % (arm, r.stderr))
    stamped = "#define HET_NO_CONTROL_MAP 1" in open(
        os.path.join(d, CH_TEST + ".cu")).read()
    if stamped != (arm == "nomap"):
        raise SystemExit("runcheck --characterize-hw: the %s arm stamps "
                         "HET_NO_CONTROL_MAP=%d -- the arm does not set up the "
                         "state it exists to read" % (arm, stamped))
    return d


def ch_build(d, arch):
    env = dict(os.environ)
    env["CUDA_ARCH"] = arch
    r = sh(["sh", "comp.sh", "cuda-link"], cwd=d, env=env)
    if r.returncode != 0:
        raise SystemExit("runcheck --characterize-hw: comp.sh cuda-link failed:\n"
                         + (r.stdout + r.stderr)[-2000:])


def ch_run_until_sighting(d, quiet=False):
    """Run with fresh seeds until the outcome fires once.  Returns (text, k, R,
    obs, tries); text is stdout+stderr, the whole printout a reader sees."""
    env = dict(os.environ)
    env["HET_ALLOC"] = env.get("HET_ALLOC", "pinned")
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
        m = re.search(r"^HetStats \S+ cpu_only=\d+ obs=(\S+) R=(\d+) usable=\d+ "
                      r"k=(\d+) ", r.stdout, re.M)
        if not m:
            raise SystemExit("runcheck --characterize-hw: the run printed no "
                             "HetStats line (rc=%d)\n%s" % (r.returncode,
                                                            text[-2000:]))
        obs, R, k = m.group(1), int(m.group(2)), int(m.group(3))
        last = (text, k, R, obs, i)
        if k > 0:
            return last
        if not quiet:
            print("      seed %d: k=0, retrying (the control sentence, the "
                  "observation and the denominator all need one sighting)"
                  % (1000 + i))
    return last


# The two control sentences, and the arm each belongs to.  Neither may appear in
# the other arm's printout: a bound that is missing BY CONSTRUCTION and one that
# is missing because nobody built the instrumentation read alike to everyone
# except the person who emitted it.
CH_SELF = ["IS the Layer-B canary", "NO BOUND -- by construction, not by omission"]
CH_NOMAP = ["NO POSITIVE-CONTROL MAP WAS READ for %s" % CH_PAIR,
            "the map is looked for BESIDE THE TEST",
            "control-map-amd.csv for x86_64), and it was not there",
            "It gets NO BOUND, and that is an OMISSION, not a construction",
            "what was omitted is the map FILE beside this test"]
# The map is loaded for EVERY lane, so HET_NO_CONTROL_MAP says the FILE was not
# beside the test.  These are the sentences that said something else -- that no
# map was registered for the pair and none could be borrowed -- and a printout
# that still explains the flag that way is explaining a mechanism this tool no
# longer has, in EITHER arm.
CH_RETIRED = ["no map is registered for that pair",
              "there is none to borrow",
              "the bootstrap control map for an unregistered pair does not exist yet"]


def ch_check(arm, text, k, R, obs, quiet=False):
    """Every assertion is on the PRINTOUT.  Returns a list of failures."""
    bad = []
    say = (lambda *_: None) if quiet else print

    def must(tag, frag):
        if frag not in text:
            bad.append("[%s/%s] the printout never says %r" % (arm, tag, frag))
        else:
            say("      [%s/%s] %s" % (arm, tag, frag[:88]))

    def never(tag, frag, why):
        if frag in text:
            bad.append("[%s/%s] the printout says %r -- %s" % (arm, tag, frag, why))

    must("A", "HetVerdict %s [" % CH_TEST)
    must("A", "Report it as what %s exhibited" % CH_PAIR)

    mine, theirs = (CH_SELF, CH_NOMAP) if arm == "map" else (CH_NOMAP, CH_SELF)
    for frag in mine:
        must("B/C", frag)
    for frag in theirs:
        never("B/C", frag, "that is the OTHER arm's control state")
    for frag in CH_RETIRED:
        never("B/C", frag, "the flag means the map FILE was not beside the test, "
                           "not that a registry has no row for the pair")

    must("D", ": OBSERVED")
    never("D", "the target this harness was tagged for",
          "that sentence once substituted a disclosure blob for the pair name")

    for w in ("MISMATCH", "MATCH", "ORACLE_", "Disallowed", "REFUT"):
        if w in text:
            bad.append("[%s/E] the printout contains %r -- this harness carries no "
                       "prediction to agree or disagree with" % (arm, w))
    say("      [%s/E] no MATCH / MISMATCH / retired verdict word anywhere" % arm)

    hits = sorted(set(m.group(0) for m in CH_VENDOR_RE.finditer(text)))
    if hits:
        bad.append("[%s/F] the printout names %s -- this pair has no machine row "
                   "and this run was on neither part" % (arm, ", ".join(hits)))
    else:
        say("      [%s/F] no Grace / Hopper / NVLink / C2C / GH200 in stdout or "
            "stderr" % arm)

    if 0 < k < R and obs == "Always":
        bad.append("[%s/G] obs=Always on k=%d of R=%d: the denominator collapsed "
                   "onto the runs that fired, which is every usable cell here"
                   % (arm, k, R))
    elif 0 < k < R:
        say("      [%s/G] obs=%s on k=%d of R=%d (denominator is R, not the usable "
            "count)" % (arm, obs, k, R))
    else:
        bad.append("[%s/G] k=%d of R=%d -- no sighting, so the class carries no "
                   "information about the denominator" % (arm, k, R))
    return bad


def ch_run_once(arm, d, quiet=False):
    got = ch_run_until_sighting(d, quiet=quiet)
    if got is None:
        return 1, ["the %s harness produced no run at all" % arm]
    text, k, R, obs, tries = got
    if k == 0:
        return 1, ["the %s outcome never fired in %d x %d runs -- the sighting "
                   "assertions cannot be read, and a pair that cannot fire the "
                   "most observable het shape is itself the finding"
                   % (arm, tries, R)]
    bad = ch_check(arm, text, k, R, obs, quiet=quiet)
    return (1 if bad else 0), bad


def ch_arm(arm, tmp, arch, quiet=False):
    d = ch_emit(tmp, arm)
    ch_build(d, arch)
    return ch_run_once(arm, d, quiet=quiet)


# Each injection rewrites ONE file of the emitted harness (never the source tree)
# and names the file, because the two halves of the printout come from two places:
# the verdict/statistics prose from het_verdict.h, and the driver's own WARNINGS
# from the render itself.
CH_INJECTIONS = [
    ("B/C", "nomap", "het_verdict.h",
     "the no-control-map note reverted to the self-canary sentence",
     lambda s: s.replace(
         "  NOTE: this row CO-RUNS NO CONTROL because NO POSITIVE-CONTROL MAP WAS ",
         "  NOTE: this row CO-RUNS NO CONTROL -- it IS the Layer-B canary.  WAS ", 1)),
    ("C", "nomap", "het_verdict.h", "the bound called structural again",
     lambda s: s.replace("It gets NO BOUND, and that is an OMISSION, not a "
                         "construction",
                         "It gets NO BOUND -- by construction, not by omission", 1)),
    ("B/C", "nomap", "het_verdict.h",
     "the flag explained as a pair no registry has a map for",
     lambda s: s.replace("the map is looked for BESIDE THE TEST, under the name this ",
                         "no map is registered for that pair, and there is none to "
                         "borrow, so this ", 1)),
    ("A/D", "map", "het_verdict.h",
     "the report sentence names a constant instead of the pair",
     lambda s: s.replace(
         "      HET_PAIR_NAME, HET_LINK_NAME);",
         '      "the target this harness was tagged for", HET_LINK_NAME);', 1)),
    ("F", "map", CH_TEST + ".cu",
     "the driver's noise warning names the GH200 halves again",
     lambda s: s.replace("the host half of the host-device interconnect noise",
                         "the Grace half of the NVLink-C2C noise")),
]


def characterize_hw_bite(tmp, arch):
    print("===== BITE: does this gate read the PRINTOUT? =====")
    bad = 0
    for tag, arm, fname, what, mutate in CH_INJECTIONS:
        d = ch_emit(tmp, arm)
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
        rc, why = ch_run_once(arm, d, quiet=True)
        if rc == 0:
            print("  *** [%s] %s: the gate stayed GREEN" % (tag, what))
            bad += 1
        else:
            print("      [%s] RED on %s" % (tag, what))
            print("          %s" % why[0][:150])
    # ... and the untouched arms must be green, or "red" meant nothing.
    for arm in CH_ARMS:
        rc, why = ch_arm(arm, tmp, arch, quiet=True)
        if rc != 0:
            print("  *** the UNTOUCHED %s arm is RED (%s) -- the injections above "
                  "prove nothing" % (arm, why[0][:150] if why else "?"))
            bad += 1
        else:
            print("      the untouched %s arm: GREEN" % arm)
    if bad:
        print("\nBITE FAILED: %d injection(s) went unnoticed." % bad)
        return 1
    print("\nBITE OK (%d injections, each RED; restored GREEN)" % len(CH_INJECTIONS))
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
        bad = []
        for arm in CH_ARMS:
            print("===== the printout of a %s run =====" % arm)
            bad += ch_arm(arm, tmp, arch)[1]
        if bad:
            print("\nCHARACTERIZE-HW FAILED: %d problem(s)." % len(bad))
            for m in bad:
                print("  %s" % m)
            return 1
        print("\nCHARACTERIZE-HW: PASS (both arms name themselves, say which "
              "control state they are in, claim no machine, and adjudicate "
              "nothing)")
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


PHASES = [
    ("1: --dry-run acts on nothing", lambda q: phase1_dryrun(WRAPPER, q)),
    ("2: the chain end to end (stub compiler + stub probe)",
     lambda q: phase2_e2e(WRAPPER, q)),
    ("3: the refusals by their own reasons; the unregistered pair by its warning",
     lambda q: phase3_refusals(WRAPPER, q)),
    ("4: campaign.py's stop rule and the states it may not resume",
     lambda q: phase4_stoprule(CAMPAIGN, q)),
    ("5: the machine-table reader is bounded to the table",
     lambda q: phase5_reader(WRAPPER, q)),
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
    ap.add_argument("--hw", action="store_true",
                    help="run the wrapper on the real device (-nvcc lane)")
    ap.add_argument("--characterize-hw", action="store_true",
                    help="build two harnesses and read what they PRINT (-nvcc lane)")
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args()

    if not os.access(os.path.join(BIN, "litmus7"), os.X_OK):
        raise SystemExit("runcheck: litmus7 not built (run 'make all')")
    if a.characterize_hw:
        return characterize_hw(want_bite=a.bite)
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
          "pair decides which machine may be named and nothing else; an "
          "unregistered pair is warned about and emits; every fail-closed handler "
          "was seen to fire)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

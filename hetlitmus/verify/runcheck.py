#!/usr/bin/env python3
"""runcheck.py -- hetlitmus/hetlitmus-run.sh, the device session, driven end to
end with the compiler and the probe replaced by the wrapper's stand-ins.  A miss
means the pair, the architecture or a refusal was decided on an unwatched
machine with nothing recording it.

  PHASE 1  --dry-run prints the plan and writes nothing.
  PHASE 2  the chain end to end, on each dialect this host's fixture reaches.
  PHASE 3  the refusals, each by its own reason.
  PHASE 4  the fail-closed handlers, each under its own condition.
  PHASE 5  a second session into a results dir that already holds one.
  PHASE 6  probe-hip.sh's exit paths.
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
RUNONE = os.path.join(HETL, "spotcheck", "run-one.sh")
PROBE_HIP = os.path.join(HETL, "spotcheck", "probe-hip.sh")
BIN = os.path.join(ROOT, "_build", "install", "default", "bin")

# The committed (x86_64, *) fixture: a generate-x86.sh run, cut verbatim and
# kept that way by corpus-gate.sh's het-x86 label.
X86_DIR = os.path.join(HETL, "tests", "het-x86")
X86_TESTS = ["CoRR-cg-sys-fence-2s-x86_64", "MP-cg-sys-acqrel-2s-x86_64",
             "MP-cg-sys-relaxed-x86_64", "S-cg-sys-fence-x86_64"]
# The (AArch64, *) lane is the committed het corpus, and the cut below is copied
# out of it at run time: it is the corpus minus rows, not a second fixture.
AARCH64_DIR = os.path.join(HETL, "tests", "het")
AARCH64_TESTS = ["MP-cg-sys-acqrel-2s", "MP-cg-sys-acquire", "MP-cg-sys-relaxed",
                 "S-cg-sys-fence", "S-cg-sys-relaxed"]

# The HetStats machine line in the field order het_stats_line prints: a null on
# a live run, so the row is reportable and nothing fires.
STUB_STATS = ("HetStats %s cpu_only=0 obs=Never R=10 usable=10 k=0 k_eff=0 "
              "k_runs=0 degen=0 first_sight=0 sighting=none N=100000 "
              "scored=100000 discarded=0 flags=0x0")

# The stand-in compiler: `-c' writes the object, a link writes an executable
# whose body is @@BODY@@.
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
# A harness that dies with a message on STDERR: campaign.py builds an errored
# row's note from the runner's stderr.
HARNESS_STDERR = "harness: the rendezvous never closed"
ERR_HARNESS = ("#!/bin/sh\n"
               "printf 'HetLitmus: shared-mem mode=stub\\n'\n"
               "echo '%s' >&2\n"
               "exit 7\n" % HARNESS_STDERR)

BAD_CC = "#!/bin/sh\necho 'stub-cc: this compiler always fails' >&2\nexit 1\n"

STUB_PROBE = r'''#!/bin/sh
# Stand-in for probe-cuda.sh / probe-hip.sh: the shape of a probe record, none
# of the facts.
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


# campaign.py's terminal stops, mirrored here so a session's own state file can
# be read: a row that ended on anything else was written by another stop rule.
TERMINAL = ("CORROBORATED", "UNCONFIRMED-SIGHTING", "BUDGET", "ERROR")


def state_is_terminal(pfx, rows, tests):
    """Every test ran and every row ended on a stop this policy can write."""
    bad = []
    if sorted(t for t, _, _ in rows) != sorted(tests):
        bad.append("%scampaign state covers %s, want %s"
                   % (pfx, sorted(t for t, _, _ in rows), sorted(tests)))
    for t, stop, _ in rows:
        if stop not in TERMINAL:
            bad.append("%s%s ended %r, not one of %s"
                       % (pfx, t, stop, list(TERMINAL)))
    return bad


def state_notes(path):
    """test -> the note column, which is where an errored row's reason lands."""
    with open(path) as fh:
        return {r["test"]: (r.get("note") or "") for r in csv.DictReader(fh)}


# ---------------------------------------------------------------------------
# The fixture this host can drive: the emitted link target refuses a foreign
# host, so a corpus whose CPU column is not this box's drives nothing here.
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


def host_fixture():
    """The fixture, or a fail-closed exit: a host with no corpus of its own CPU
    lane drives nothing here, and a pass over nothing is the failure mode."""
    fx = fixture()
    if fx is None:
        raise SystemExit("runcheck: no committed corpus carries a %s CPU column,"
                         " so there is no chain to drive on this host."
                         % platform.machine())
    return fx


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
    fx = host_fixture()
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
                bad.append("the plan never mentions %r -- a plan missing a step "
                           "or a resolved value is not the plan that would run"
                           % frag)
        if os.path.exists(out):
            bad.append("--dry-run CREATED %s -- it must write nothing" % out)
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
    # The results dir is the deliverable: a session that ran but recorded
    # nothing cannot be read afterwards.
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
        bad.append("%s: the summary does not say what the rows are:\n%s"
                   % (target, summary))
    record = open(os.path.join(out, "run-record.txt")).read()
    for frag in ("arch=" + arm["arch"], "seam_probe=STUB",
                 "seam_compiler=OVERRIDDEN", "session_status=COMPLETE"):
        if frag not in record:
            bad.append("%s: run-record.txt does not carry %r" % (target, frag))
    rows = state_rows(os.path.join(out, "campaign-state.csv"))
    bad += state_is_terminal("%s: " % target, rows, fx["tests"])
    if not quiet and not bad:
        print("      %-4s -> arch %-8s %d row(s)"
              % (target, arm["arch"], len(rows)))
    return bad, out


def _runone_nolog(tmp, quiet=False):
    """run-one.sh with HET_RUN_LOG_DIR unset -- the branch ladder.sh takes: the
    two streams stay apart and the harness's own status is the exit code."""
    d = os.path.join(tmp, "runone-nolog")
    os.makedirs(d, exist_ok=True)
    write_exec(os.path.join(d, "h"), ERR_HARNESS)
    env = {k: v for k, v in os.environ.items() if k != "HET_RUN_LOG_DIR"}
    r = sh(["sh", RUNONE, d, "h"], env=env)
    if (r.returncode != 7 or "mode=stub" not in r.stdout
            or HARNESS_STDERR not in r.stderr):
        return ["run-one.sh with no HET_RUN_LOG_DIR exited %d, stdout %r, stderr "
                "%r: want the harness's own 7 and each stream forwarded on the "
                "stream it arrived on" % (r.returncode, r.stdout[-120:],
                                          r.stderr[-120:])]
    if not quiet:
        print("      run-one.sh with no log dir: rc=7, the two streams apart")
    return []


def phase2_e2e(wrapper, quiet=False):
    fx = host_fixture()
    bad = []
    tmp = tempfile.mkdtemp(prefix="runcheck2.")
    try:
        bad += _runone_nolog(tmp, quiet)
        chained = None
        for target in ("cuda", "hip"):
            arm = fx[target]
            b, out = _e2e(wrapper, tmp, fx, target, arm, quiet)
            bad += b
            if chained is None and not b:
                chained = (out, target)
        if chained is None:
            return bad
        # --reuse-emitted: the same results dir, no emission, same answers, with
        # the first session's campaign state moved aside.
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
    """A corpus carrying both CPU lanes: the preflight has to read EVERY test's
    lane, not only the first."""
    d = os.path.join(tmp, "mixed")
    os.makedirs(d, exist_ok=True)
    for f in os.listdir(X86_DIR):
        if f.endswith(".litmus"):
            shutil.copy(os.path.join(X86_DIR, f), d)
    shutil.copy(os.path.join(AARCH64_DIR, AARCH64_TESTS[0] + ".litmus"), d)
    return d


def phase3_refusals(wrapper, quiet=False):
    fx = host_fixture()
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
            # --dry-run leads, so that a case whose LAST argument is a valued
            # flag is still a flag with nothing after it.
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
# PHASE 4 -- the fail-closed handlers, each under the condition it exists for.
# Every one is a `die' a clean chain never reaches.
# ---------------------------------------------------------------------------
P4_CASES = ["build", "probe", "ambiguity", "campaign-rc", "stamp"]


def _twocap_path(tmp):
    """A PATH whose nvidia-smi reports two distinct compute capabilities."""
    d = os.path.join(tmp, "twogpu-bin")
    os.makedirs(d, exist_ok=True)
    write_exec(os.path.join(d, "nvidia-smi"), "#!/bin/sh\nprintf '8.6\\n9.0\\n'\n")
    write_exec(os.path.join(d, "nvptx-arch"), "#!/bin/sh\nexit 0\n")
    return d + os.pathsep + os.environ["PATH"]


def phase4_failclosed(wrapper, quiet=False):
    fx = host_fixture()
    arm = fx["cuda"]
    bad = []
    tmp = tempfile.mkdtemp(prefix="runcheck4.")
    try:
        base = ["--gpu-target", "cuda", "--corpus", fx["dir"], "--arch",
                arm["arch"], "--budget-runs", "10"]
        cc, probe = make_stubs(tmp)
        # ONE clean chain, whose emission every doctoring case starts from.
        b, out0 = _e2e(wrapper, tmp, fx, "cuda", arm, True)
        if b:
            return ["phase 4 could not build its base emission: %s" % b[0]]
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

        def break_stamp(e):
            t = fx["tests"][0]
            p = os.path.join(e, t, t + ".cu")
            s = open(p).read()
            with open(p, "w") as fh:
                fh.write(s.replace('#define HET_PAIR_NAME "',
                                   '#define HET_PAIR_NAME "zz', 1))

        for case in P4_CASES:
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
                        bad.append("[campaign-rc] the errored row(s) %s carry a "
                                   "note without the harness's own message %r "
                                   "(%s) -- the runner merged stderr into stdout"
                                   % (blank, HARNESS_STDERR,
                                      [notes[t] for t in blank]))
            elif case == "stamp":
                expect("stamp",
                       base + ["--out", doctored_out("stamp", break_stamp),
                               "--reuse-emitted"],
                       wrapper_env(cc, probe), 2, "the emitted pair name of")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return bad


# ---------------------------------------------------------------------------
# PHASE 5 -- a second session into a results dir that already holds one: the
# campaign refuses the state file the first session left.
# ---------------------------------------------------------------------------
def _invocations(out, fx):
    """Harness invocations recorded in the session's transcripts."""
    n = 0
    for t in fx["tests"]:
        p = os.path.join(out, "hetstats", t + ".log")
        if os.path.exists(p):
            n += sum(1 for l in open(p) if l.startswith("### " + t + " rc="))
    return n


def phase5_second_session(wrapper, quiet=False):
    fx = host_fixture()
    arm = fx["cuda"]
    bad = []
    tmp = tempfile.mkdtemp(prefix="runcheck5.")
    try:
        b, out = _e2e(wrapper, tmp, fx, "cuda", arm, True)
        if b:
            return ["phase 5 could not run its first session: %s" % b[0]]
        cc, probe = make_stubs(tmp)
        env = wrapper_env(cc, probe)
        base = ["--gpu-target", "cuda", "--corpus", fx["dir"], "--arch",
                arm["arch"], "--out", out, "--reuse-emitted"]
        invocations = _invocations(out, fx)
        state = os.path.join(out, "campaign-state.csv")
        with open(state, "rb") as fh:
            held = fh.read()

        # The refusal is campaign.py's and lands in campaign.log, NEVER on the
        # wrapper's own stderr, which is empty on this path.
        r = run_wrapper(wrapper, base + ["--budget-runs", "10"], env=env)
        said = r.stdout + open(os.path.join(out, "campaign.log")).read()
        record = open(os.path.join(out, "run-record.txt")).read()
        if r.returncode != 2:
            bad.append("a second session over an existing campaign state exited "
                       "%d, want 2: it would have written its own numbers over "
                       "the rows that state holds" % r.returncode)
        elif "already exists and a campaign is never resumed" not in said:
            bad.append("the second session stopped for another reason -- neither "
                       "stdout nor campaign.log carries the refusal: %s"
                       % said.strip()[-300:])
        elif "session_status=COMPLETE" not in record:
            bad.append("the second session ran its chain to the end and does not "
                       "record COMPLETE: %s"
                       % [l for l in record.splitlines() if "status" in l])
        elif "the campaign refused (exit 2)" not in \
                open(os.path.join(out, "summary.txt")).read():
            bad.append("this session's summary does not carry the campaign's "
                       "refusal, so the dir reads as one that measured "
                       "something: %s"
                       % open(os.path.join(out, "summary.txt")).read()[-300:])
        elif open(state, "rb").read() != held:
            bad.append("the second session CHANGED the campaign state it refused "
                       "to run over")
        elif _invocations(out, fx) != invocations:
            bad.append("the second session invoked a harness before the refusal: "
                       "the transcripts grew from %d to %d"
                       % (invocations, _invocations(out, fx)))
        elif not quiet:
            print("      a second session into the same dir is refused by the "
                  "campaign (rc=2), state untouched, no harness invoked")

        # A refused session must leave NO summary beside its own record: one dir
        # would then describe two different sessions.
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
            bad.append("the refused session left the previous session's "
                       "summary.txt in place, beside its own record")
        elif not quiet:
            print("      a refused session records REFUSED@step2 and leaves no "
                  "stale summary")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return bad


# ---------------------------------------------------------------------------
# PHASE 6 -- probe-hip.sh, under stand-in vendor tools.  No AMD device is
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


def phase6_probe_hip(probe, quiet=False):
    bad = []
    tmp = tempfile.mkdtemp(prefix="runcheck6.")
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
# --characterize-hw -- a harness built, run on the GPU and read off its
# printout: a sighting, a null and a discarded run are each an arm.
# ---------------------------------------------------------------------------

# The relaxed MP row of this host's fixture: a harness whose CPU column is
# foreign does not link here.
CH_STEM = "MP-cg-sys-relaxed"
CH_SEED_TRIES = 12
# The printout's shape does not depend on how many runs stand behind it, so the
# runs are curtailed and the timeout is what a curtailed run may take.
CH_RUNS = "2"
CH_RUN_TIMEOUT = 600
# The host rendezvous cap this run takes, shortened to keep a run inside its
# timeout.  The device cap is left alone: shortening it makes a clean run rare.
CH_CAP_CPU = "4096"


def _ch_env():
    env = dict(os.environ)
    env["PATH"] = BIN + os.pathsep + env["PATH"]
    return env


def ch_pick():
    """(test, corpus dir, pair) for this host, off the same fixture the phases
    drive: the emitted link target refuses a foreign CPU lane."""
    fx = host_fixture()
    for t in fx["tests"]:
        if t == CH_STEM or t.startswith(CH_STEM + "-"):
            return t, fx["dir"], "(%s, cuda)" % fx["key"]
    raise SystemExit("runcheck --characterize-hw: the %s fixture carries no %s "
                     "row to build" % (fx["isa"], CH_STEM))


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


def ch_emit(tmp, test, cdir):
    """Emit `test' out of `cdir' and return its harness dir."""
    out = tempfile.mkdtemp(dir=tmp)
    r = sh(["litmus7", "-gpu-target", "cuda", "-set-libdir",
            os.path.join(ROOT, "litmus", "libdir"), "-o", out,
            os.path.join(cdir, test + ".litmus")], cwd=ROOT, env=_ch_env())
    d = os.path.join(out, test)
    if r.returncode != 0 or not os.path.exists(os.path.join(d, test + ".cu")):
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


def ch_run_until_sighting(d, test, quiet=False):
    """Run with fresh seeds until the outcome fires once, or the seeds run out --
    the last run either way; returns (text, k, R, obs, tries)."""
    env = ch_env()
    last = None
    for i in range(1, CH_SEED_TRIES + 1):
        env["HET_SEED"] = str(1000 + i)
        try:
            r = subprocess.run([os.path.join(d, test)], cwd=d, env=env,
                               capture_output=True, text=True,
                               timeout=CH_RUN_TIMEOUT)
        except subprocess.TimeoutExpired:
            # Every rendezvous wait is capped in polls, so a run that does not
            # finish is a launch or driver fault, not a slow box.
            raise SystemExit("runcheck --characterize-hw: the run did not "
                             "finish in %ds under HET_ALLOC=%s."
                             % (CH_RUN_TIMEOUT, env["HET_ALLOC"]))
        text = r.stdout + "\n" + r.stderr
        m = re.search(r"^HetStats \S+ cpu_only=\d+ obs=(\S+) R=(\d+) usable=(\d+) "
                      r"k=(\d+) ", r.stdout, re.M)
        if not m:
            raise SystemExit("runcheck --characterize-hw: the run printed no "
                             "HetStats line (rc=%d)\n%s" % (r.returncode,
                                                            text[-2000:]))
        obs, R, k = m.group(1), int(m.group(2)), int(m.group(4))
        last = (text, k, R, obs, i)
        if k > 0:
            return last
        if "COLD-INVALID" in text:
            if not quiet:
                print("      seed %d: the run was DISCARDED, which no fresh seed "
                      "undoes -- read as the arm this box printed" % (1000 + i))
            return last
        if not quiet:
            print("      seed %d: k=0, retrying (a sighting carries more "
                  "sentences to read)" % (1000 + i))
    return last


# What a run that saw the outcome must print, and what a run that did not must
# print instead.  The arms are exclusive and one of them always applies.
def ch_observed(pair):
    return [": OBSERVED", "Report it as what %s exhibited" % pair]


CH_NULL = ["NOT OBSERVED under this effort",
           "NO RATE AND NO PROBABILITY IS ATTACHED TO THIS NULL",
           "CHARACTERIZATION, NEVER VALIDATION",
           "effort:",
           # The effort a null reports is the iterations it read back, so the
           # number is on the line beside the sentence.
           "scored="]
# What a run every cell of which was DISCARDED must print instead: it is read as
# the arm it is, and what it may NOT do is read as reach.
CH_COLD = ["DISCARD this null -- the harness was not demonstrably hot",
           "the weak outcome was NOT observed",
           "VOID -- not one of",
           "scored="]
# The second run: caps of one poll, where the rendezvous cannot complete.
CH_CAP1 = ["COLD-INVALID",
           "DISCARD this null -- the harness was not demonstrably hot",
           "A timed-out rendezvous is a DEAD PARTNER"]
# What NEITHER arm may carry: a build fault reported as a result.
CH_NEVER_SAYS = [
    ("BUILD BUG",
     "the harness is reporting a build fault, which is not a result to read"),
]
CH_CLASSES = ("Never", "Sometimes", "Always", "VOID")


def ch_check(text, k, obs, test, pair, quiet=False):
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

    must("A", "HetVerdict %s run=" % test)

    # Which arm this box printed.  A sighting outranks everything; otherwise a
    # printout whose every run was discarded is the COLD arm.
    classes = set(re.findall(r"^HetVerdict \S+(?: CPU-ONLY)? run=\d+: (\S+)$",
                             text, re.M))
    if k > 0:
        arm, frags = "OBSERVED", ch_observed(pair)
    elif classes == {"COLD-INVALID"}:
        arm, frags = "COLD-INVALID", CH_COLD
    else:
        arm, frags = "NOT-OBSERVED", CH_NULL
    say("      [D] the %s arm (%s)" % (arm, ", ".join(sorted(classes)) or "none"))
    for frag in frags:
        must("D", frag)
    for frag, why in CH_NEVER_SAYS:
        never("B/C", frag, why)

    if obs not in CH_CLASSES:
        bad.append("[F] obs=%s is not one of %s" % (obs, list(CH_CLASSES)))
    else:
        say("      [F] obs=%s on k=%d" % (obs, k))
    return bad


def ch_run_once(d, test, pair, quiet=False):
    got = ch_run_until_sighting(d, test, quiet=quiet)
    if got is None:
        return 1, ["the harness produced no run at all"]
    text, k, R, obs, tries = got
    if k == 0 and not quiet:
        print("      the outcome never fired in %d x %d runs, so a non-sighting "
              "arm is what this device printed" % (tries, R))
    bad = ch_check(text, k, obs, test, pair, quiet=quiet)
    return (1 if bad else 0), bad


def ch_cap_run(d, test, quiet=False):
    """The rendezvous disqualifier, driven by a run-time knob: under caps of ONE
    poll nearly every iteration is discarded and the run must be thrown away."""
    say = (lambda *_: None) if quiet else print
    env = ch_env(HET_CAP_CPU="1", HET_CAP_GPU="1", HET_RUNS_MAX="1",
                 HET_SEED="1")
    try:
        r = subprocess.run([os.path.join(d, test)], cwd=d, env=env,
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
                       "discarded naming the dead mechanism" % frag)
        else:
            say("      [R] %s" % frag[:88])
    if "NOT OBSERVED under this effort" in text:
        bad.append("[R] under HET_CAP_CPU=1 HET_CAP_GPU=1 the printout reports "
                   "reach: a run whose two sides never met is not a "
                   "non-observation")
    return bad


def ch_probe(tmp, test, cdir, pair, arch, quiet=False):
    d = ch_emit(tmp, test, cdir)
    ch_build(d, arch)
    rc, bad = ch_run_once(d, test, pair, quiet=quiet)
    if not quiet:
        print("===== the same binary under caps of one poll =====")
    bad = bad + ch_cap_run(d, test, quiet=quiet)
    return (1 if bad else 0), bad


def characterize_hw():
    test, cdir, pair = ch_pick()
    arch = ch_arch()
    if arch is None:
        # NOT a skip: this mode builds and runs a harness on the device, and
        # skipping it quietly is how a check stops checking.
        raise SystemExit(
            "runcheck --characterize-hw: no CUDA device is visible (nvidia-smi "
            "reported none), so there is nothing it can assert.")
    print("runcheck --characterize-hw: %s, %s, %s, HET_ALLOC=%s"
          % (test, pair, arch, os.environ.get("HET_ALLOC", "pinned")))
    tmp = tempfile.mkdtemp(prefix="runcheck-chhw.")
    try:
        print("===== the printout of a run =====")
        bad = ch_probe(tmp, test, cdir, pair, arch)[1]
        if bad:
            print("\nCHARACTERIZE-HW FAILED: %d problem(s)." % len(bad))
            for m in bad:
                print("  %s" % m)
            return 1
        print("\nCHARACTERIZE-HW: PASS (the printout names the test, reads as "
              "the arm the run took and names no voucher; a rendezvous that "
              "cannot complete is DISCARDED naming itself)")
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


PHASES = [
    ("1: --dry-run acts on nothing", lambda q: phase1_dryrun(WRAPPER, q)),
    ("2: the chain end to end (stub compiler + stub probe)",
     lambda q: phase2_e2e(WRAPPER, q)),
    ("3: the refusals by their own reasons",
     lambda q: phase3_refusals(WRAPPER, q)),
    ("4: the fail-closed handlers, under their own conditions",
     lambda q: phase4_failclosed(WRAPPER, q)),
    ("5: a second session into the same results dir",
     lambda q: phase5_second_session(WRAPPER, q)),
    ("6: probe-hip.sh's exit paths", lambda q: phase6_probe_hip(PROBE_HIP, q)),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--characterize-hw", action="store_true",
                    help="build a harness and read what it PRINTS "
                         "(toolchain lane)")
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args()

    if not os.access(os.path.join(BIN, "litmus7"), os.X_OK):
        raise SystemExit("runcheck: litmus7 not built (run 'make all')")
    host_fixture()
    if a.characterize_hw:
        return characterize_hw()

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
    print("\nRUNCHECK OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())

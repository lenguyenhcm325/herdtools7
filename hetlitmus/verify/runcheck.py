#!/usr/bin/env python3
"""runcheck.py -- the device-session wrapper (hetlitmus/hetlitmus-run.sh), driven
end to end on a box with no device.

The wrapper is the one command a hardware session runs, so what it decides -- the
oracle pair, the architecture the binaries are built for, whether the campaign
adjudicates or characterizes -- is decided on a machine nobody is watching and is
visible afterwards only in what it wrote down.  Every phase below drives it with
the compiler and the probe replaced by the wrapper's documented stand-ins, so
those decisions are checked here rather than on rented hardware.

HOST-ADAPTIVE.  The chain phases need a corpus whose CPU column is this host's:
`fixture()' picks the committed x86 fixture on an x86_64 box and a cut of the
committed AArch64 corpus on an aarch64 one, and the pairs each phase expects
follow that choice.  Nothing here is x86-only, so the GH200 runs the same gate.

  PHASE 1  --dry-run prints the plan and does NOT act: no results dir at all.
  PHASE 2  the chain end to end on each dialect this host's pair table reaches.
  PHASE 3  the refusals, each by its own reason.
  PHASE 4  campaign.py --characterization, and the states it may not resume.
  PHASE 5  the pair-table reader, bounded to the table literal.
  PHASE 6  the fail-closed handlers, each under its own induced condition.
  PHASE 7  a second session into a results dir that already holds one.
  PHASE 8  probe-hip.sh's exit paths.

`--bite' plants one defect per assertion in a COPY of the script under test (never
in the tree) and requires the phase to redden for the right reason.  `--hw' is the
same wrapper on the real device, which is the -nvcc lane's half of this gate.
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
ORACLE_ML = os.path.join(ROOT, "litmus", "hetOracle.ml")
BIN = os.path.join(ROOT, "_build", "install", "default", "bin")

# The committed (x86_64, *) fixture: three tests, cut verbatim from a
# generate-x86.sh run and kept that way by hetlitmus-x86fixture.
X86_DIR = os.path.join(HETL, "tests", "het-x86")
X86_TESTS = ["MP-cg-sys-acqrel-2s-x86_64", "MP-cg-sys-relaxed-x86_64",
             "S-cg-sys-fence-x86_64"]
# The (AArch64, *) lane is the committed 411-test corpus, and a session over all
# of it is not a gate.  The cut below is copied out of it VERBATIM at run time --
# tests plus the two files the emitter resolves beside them -- so it is not a
# second fixture that could go stale; it is the corpus, minus rows.  Closed under
# the control map: MP-cg-sys-acqrel-2s names MP-cg-sys-acquire as its mutant and
# MP-cg-sys-relaxed as its canary, and emission refuses a control it cannot build.
AARCH64_DIR = os.path.join(HETL, "tests", "het")
AARCH64_TESTS = ["MP-cg-sys-acqrel-2s", "MP-cg-sys-acquire", "MP-cg-sys-relaxed",
                 "S-cg-sys-fence"]
AARCH64_SIDE = ["control-map.csv", "expected-nvidia.csv"]

# One HetStats machine line, the whole interface between a harness and
# campaign.py.  A null with a measured dispersion, so a bound is reachable and
# nothing fires: what the scheduler does with it is the phase's subject.
STUB_STATS = ("HetStats %s oracle=NO-ORACLE obs=Never k=0 k_eff=0 k_runs=0 "
              "tier=none mu_upper=2.9957 tau_w=1.28 N_eff=100 tau_need=1 "
              "R_eff=100 p_bound=0.029957 P_rep=-1 R=10 usable=10 degen=0 "
              "ctrl=none win_n=1280 nwin=128 F_win=1.05 F_cell=1.02 r_hat=inf "
              "acf1=0.01 ks=pass ks_D=0.1 ks_Dcrit=0.2 ks_split=-1 N=100000 "
              "frames=100000 flags=0x0")

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
    """(test, class, stop, runs) per row of a campaign state file."""
    rows = []
    with open(path) as fh:
        for i, line in enumerate(fh):
            f = line.rstrip("\n").split(",")
            if i == 0 or len(f) < 5:
                continue
            rows.append((f[0], f[1], f[2], int(f[4])))
    return rows


def state_notes(path):
    """test -> the note column, which is where an errored row's reason lands."""
    with open(path) as fh:
        return {r["test"]: (r.get("note") or "") for r in csv.DictReader(fh)}


# ---------------------------------------------------------------------------
# THE FIXTURE THIS HOST CAN DRIVE, and what litmus/hetOracle.ml says about its
# two dialects.  The emitted link targets refuse a foreign host, so a corpus
# whose CPU column is not this box's has no chain to drive here.
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
    """{isa, key, dir, tests, cuda: arm, hip: arm} for this host, or None."""
    m = platform.machine()
    if m == "x86_64":
        return {
            "isa": "x86_64", "key": "X86_64", "dir": X86_DIR, "tests": X86_TESTS,
            "cuda": {"state": "NO-ORACLE", "mode": "characterization",
                     "arch": "sm_86",
                     "classes": dict.fromkeys(X86_TESTS, "NO-ORACLE")},
            "hip": {"state": "POPULATED", "mode": "oracle", "arch": "gfx942",
                    "classes": {"MP-cg-sys-relaxed-x86_64": "Allowed",
                                "MP-cg-sys-acqrel-2s-x86_64": "NO-ORACLE",
                                "S-cg-sys-fence-x86_64": "NO-ORACLE"}},
        }
    if m in ("aarch64", "arm64"):
        return {
            "isa": "aarch64", "key": "AArch64", "dir": aarch64_corpus(),
            "tests": AARCH64_TESTS,
            "cuda": {"state": "POPULATED", "mode": "oracle", "arch": "sm_90",
                     "classes": {"MP-cg-sys-relaxed": "Allowed",
                                 "MP-cg-sys-acquire": "Allowed",
                                 "MP-cg-sys-acqrel-2s": "Disallowed",
                                 "S-cg-sys-fence": "Allowed"}},
            "hip": {"state": "ABSENT", "arch": "gfx942"},
        }
    return None


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
        for frag in PLAN_STEPS + ["(%s, cuda)" % fx["key"], arm["mode"],
                                  arm["arch"]]:
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
    if arm["mode"] not in summary:
        bad.append("%s: the summary does not say %r -- it says:\n%s"
                   % (target, arm["mode"], summary))
    record = open(os.path.join(out, "run-record.txt")).read()
    for frag in ("arch=" + arm["arch"], "mode=" + arm["mode"], "seam_probe=STUB",
                 "seam_compiler=OVERRIDDEN", "session_status=COMPLETE"):
        if frag not in record:
            bad.append("%s: run-record.txt does not carry %r -- the value the "
                       "session turned on is not a recorded fact" % (target, frag))
    rows = state_rows(os.path.join(out, "campaign-state.csv"))
    got = sorted((t, c) for t, c, _, _ in rows)
    if got != sorted(arm["classes"].items()):
        bad.append("%s: campaign state classes %s, want %s"
                   % (target, got, sorted(arm["classes"].items())))
    if not quiet and not bad:
        print("      %-4s -> %-16s %d row(s) %s"
              % (target, arm["mode"], len(rows),
                 ", ".join("%s=%s" % (t, c) for t, c, _, _ in rows)))
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
            # A dialect the pair table does not register has no chain to drive:
            # what it must do is refuse, and name the table it is missing from.
            if arm["state"] == "ABSENT":
                r = run_wrapper(wrapper, ["--gpu-target", target, "--corpus",
                                          fx["dir"], "--arch", arm["arch"],
                                          "--dry-run"])
                if r.returncode != 2:
                    bad.append("(%s, %s) is absent from the pair table but the "
                               "session exited %d, want 2"
                               % (fx["key"], target, r.returncode))
                elif "is not in litmus/hetOracle.ml" not in r.stderr:
                    bad.append("(%s, %s) was refused for another reason: %s"
                               % (fx["key"], target, r.stderr.strip()[-200:]))
                elif not quiet:
                    print("      %-4s -> ABSENT from the pair table, refused (rc=2)"
                          % target)
                continue
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
            ("unregistered pair",
             ["--gpu-target", "hip", "--corpus", aarch64_corpus(), "--arch",
              "gfx942"], {}, "is not in litmus/hetOracle.ml"),
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
# PHASE 4 -- campaign.py --characterization.
# ---------------------------------------------------------------------------
CHAR_TESTS = ["CH-one", "CH-two"]
STATE_COLS = ["test", "class", "stop", "invocations", "runs", "usable", "k",
              "k_eff", "k_runs", "R_eff", "mu_upper_max", "pooled_bound", "nwin",
              "tau_w", "N_eff", "tau_unresolved", "tau_need", "note"]


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
        # CHARACTERIZATION RUN: a state file carries terminal stops, and a resumed
        # row inherits them.  Handing the run above's OWN state (CH-one OBSERVED,
        # CH-two CONFIRMED) to --characterization must fail closed -- and so must a
        # state whose class cell is blank, which names no stop rule at all and
        # would otherwise be resumable by every campaign.
        blank = os.path.join(tmp, "blank.csv")
        with open(blank, "w", newline="") as fh:
            w = csv.writer(fh)
            w.writerow(STATE_COLS)
            for t, stop in (("CH-one", "OBSERVED"), ("CH-two", "CONFIRMED")):
                w.writerow([t, "", stop, 1, 10, 10, 1, 1, 3, "0", "0", "-1", 128,
                            "1.28", "100", 0, 1, "banked by something"])
        for name, state, frag in (
                ("an oracle state", st_map, "classes its rows differently"),
                ("a state with no class", blank, "no readable oracle class")):
            r = _campaign(campaign, corpus, runner, state, ["--characterization"])
            if r.returncode != 2:
                bad.append("resuming %s under --characterization exited %d, want 2: "
                           "the row would have inherited the OBSERVED or CONFIRMED "
                           "an oracle campaign banked" % (name, r.returncode))
            elif frag not in r.stderr:
                bad.append("[%s] was refused for another reason: %s"
                           % (name, r.stderr.strip()[-200:]))
            elif not quiet:
                print("      %-22s cannot be resumed by a characterization run "
                      "(rc=2)" % name)
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
# PHASE 5 -- the pair-table reader.  `Populated' and `Registered_none' are also
# constructor names in litmus/hetOracle.ml's match arms, so a reader that ran past
# the table literal reads the LAST row's state off unrelated code.  The doctored
# copies below are what make that visible: the committed table happens to survive
# an unbounded parse, and a table with one more row does not.
# ---------------------------------------------------------------------------
READER_WANT = {("AArch64", "cuda"): "POPULATED expected-nvidia.csv control-map.csv",
               ("X86_64", "hip"): "POPULATED expected-amd.csv control-map-amd.csv",
               ("X86_64", "cuda"): "NO-ORACLE",
               ("AArch64", "hip"): "ABSENT"}
LAST_ROW = ('\n    ("X86_64", "sycl"),\n'
            '    Populated { op_oracle_csv = "expected-zz.csv" ;\n'
            '                op_oracle_model = "ZZ" ;\n'
            '                op_control_map_csv = "control-map-zz.csv" ;\n'
            '                op_machine = generic_machine } ;\n')
ARMS_OLD = ("  | Some (Populated p) -> Oracle p\n"
            "  | Some (Registered_none why) -> Characterize why\n")
ARMS_NEW = ("  | Some (Registered_none why) -> Characterize why\n"
            "  | Some (Populated p) -> Oracle p\n")


def _mkrepo(tmp, name, text):
    d = os.path.join(tmp, name)
    os.makedirs(os.path.join(d, "litmus"), exist_ok=True)
    with open(os.path.join(d, "litmus", "hetOracle.ml"), "w") as fh:
        fh.write(text)
    return d


def phase5_reader(wrapper, quiet=False):
    bad = []
    tmp = tempfile.mkdtemp(prefix="runcheck5.")
    try:
        m = re.search(r"^oracle_pair\(\) \{.*?^\}", open(wrapper).read(),
                      re.S | re.M)
        if m is None:
            return ["the wrapper has no oracle_pair(): the pair table is read by "
                    "something this phase cannot find, so it checks nothing"]
        drv = write_exec(os.path.join(tmp, "reader.sh"),
                         '#!/usr/bin/env bash\nset -euo pipefail\nREPO="$3"\n'
                         + m.group(0) + '\noracle_pair "$1" "$2"\n')
        real = open(ORACLE_ML).read()
        i = real.find("let table = [")
        j = real.find("\n  ]\n", i if i >= 0 else 0)
        if i < 0 or j < 0:
            return ["litmus/hetOracle.ml has no `let table = [' ... `]' literal: "
                    "this phase, and the reader it checks, are written for that shape"]
        want_last = dict(READER_WANT)
        want_last[("X86_64", "sycl")] = "POPULATED expected-zz.csv control-map-zz.csv"
        variants = [("the committed table", real, READER_WANT),
                    ("a populated pair placed LAST", real[:j] + LAST_ROW + real[j:],
                     want_last),
                    ("the match arms reordered", real.replace(ARMS_OLD, ARMS_NEW, 1),
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
            bad.append("a hetOracle.ml with no `let table = [' reads %r, want "
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
    ("2", "wrapper", "the mode is assumed to be `oracle' instead of read off the pair",
     lambda s: s.replace(
         'if [ "$PAIR_STATE" = POPULATED ]; then\n  MODE="oracle"',
         'if true; then\n  MODE="oracle" ; PAIR_ORACLE="expected-amd.csv" ; '
         'PAIR_MAP="control-map-amd.csv"', 1),
     phase2_e2e, None),
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
    ("4", "campaign", "--characterization classes its rows Disallowed",
     lambda s: s.replace('return dict.fromkeys(tests, "NO-ORACLE")',
                         'return dict.fromkeys(tests, "Disallowed")', 1),
     phase4_characterization, "classed Disallowed"),
    ("4", "campaign", "the two switches stop being mutually exclusive",
     lambda s: s.replace("klass = ap.add_mutually_exclusive_group(required=True)",
                         "klass = ap.add_argument_group('oracle class')", 1),
     phase4_characterization, "neither switch"),
    ("4", "campaign", "a row is resumed across oracle classes",
     lambda s: s.replace("            if pclass != st.oclass:",
                         "            if False:", 1),
     phase4_characterization, "an oracle state"),
    ("4", "campaign", "a blank class cell counts as a matching class",
     lambda s: s.replace("            if not pclass:", "            if False:", 1)
                .replace("            if pclass != st.oclass:",
                         '            if pclass not in ("", st.oclass):', 1),
     phase4_characterization, "a state with no class"),
    ("5", "wrapper", "the pair-table reader runs past the table literal",
     lambda s: s.replace("{ intab = 0 ; inb = 0 ; next }", "{ next }", 1),
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
# host's fixture names, and what is asserted is that the session took the mode
# that pair's table row entitles it to and said so.
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
            if arm["mode"] not in summary:
                bad.append("the summary does not say %s:\n%s"
                           % (arm["mode"], summary))
            if "mode=" + arm["mode"] not in record:
                bad.append("run-record.txt does not record the %s mode" % arm["mode"])
            if "session_status=COMPLETE" not in record:
                bad.append("run-record.txt does not record a completed session")
            for frag in ("seam_probe", "seam_compiler", "seam_litmus7"):
                if frag in record:
                    bad.append("run-record.txt carries %s -- a hardware session "
                               "must run no stand-in" % frag)
            if "arch_source=auto" not in record:
                bad.append("the arch was not resolved on this box")
            rows = state_rows(os.path.join(out, "campaign-state.csv"))
            got = sorted((t, c) for t, c, _, _ in rows)
            if got != sorted(arm["classes"].items()):
                bad.append("campaign state classes %s, want %s"
                           % (got, sorted(arm["classes"].items())))
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
            print("\nRUNCHECK --hw: PASS (the chain ran on the device, the pair "
                  "took the mode its table row names, and the session recorded "
                  "what it did)")
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
        # substitutes both the mode and the map, so either name settles it.
        named = [fx["cuda"]["mode"], "control-map-amd.csv"]
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


PHASES = [
    ("1: --dry-run acts on nothing", lambda q: phase1_dryrun(WRAPPER, q)),
    ("2: the chain end to end (stub compiler + stub probe)",
     lambda q: phase2_e2e(WRAPPER, q)),
    ("3: the refusals, each by its own reason",
     lambda q: phase3_refusals(WRAPPER, q)),
    ("4: campaign.py --characterization",
     lambda q: phase4_characterization(CAMPAIGN, q)),
    ("5: the pair-table reader is bounded to the table",
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
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args()

    if not os.access(os.path.join(BIN, "litmus7"), os.X_OK):
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
          "pair decides the mode; a pair with no oracle adjudicates nothing; every "
          "fail-closed handler was seen to fire)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

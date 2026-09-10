#!/usr/bin/env python3
"""What one het harness prints on this box's GPU: emitted, built through
hetlitmus/build.sh, run on fresh seeds until the outcome fires or a run is
discarded, then run again under rendezvous caps of zero polls.  Pinned: the
HetVerdict and HetStats lines, the sentence of the arm the run took, and that
the cap-0 run scores nothing, is COLD-INVALID naming the dead partner, and
claims no reach.  A miss means a printed arm was decided with nothing
recording it.  Needs litmus7, nvcc and a CUDA device.
"""

import argparse
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import census
import ptxcheck as ptx

BUILD_SH = os.path.join(ptx.REPO, "hetlitmus", "build.sh")
# The relaxed MP row whose CPU column is this host's: the emitted link target
# refuses a foreign one.
HOST = {"x86_64": ("X86_64", census.X86_DIR, "MP-cg-sys-plain.rlx-x86_64"),
        "aarch64": ("AArch64", census.HET_DIR, "MP-cg-sys-plain.rlx"),
        "arm64": ("AArch64", census.HET_DIR, "MP-cg-sys-plain.rlx")}
SEED_TRIES = 12
RUN_TIMEOUT = 600
# Curtailed runs and a short host cap keep a run inside the timeout; the device
# cap stays, since a short one makes a clean run rare.  The environment wins.
RUN_ENV = {"HET_ALLOC": "pinned", "HET_RUNS_MAX": "2", "HET_CAP_CPU": "4096"}

STATS = re.compile(r"^HetStats \S+ obs=\S+ R=\d+ usable=\d+ k=(\d+) ", re.M)
VERDICT = re.compile(r"^HetVerdict \S+ run=\d+: (\S+)$", re.M)
RDV = re.compile(r"^HetLitmus rendezvous: scored=(\d+) discarded=(\d+)", re.M)
NULL_ARM = "NOT OBSERVED under this effort"
COLD_ARM = "DISCARD this null"
DEAD_PARTNER = "A timed-out rendezvous is a DEAD PARTNER"


def arch():
    """sm_XY of the device this runs on, never a hardcoded one."""
    if os.environ.get("CUDA_ARCH"):
        return os.environ["CUDA_ARCH"]
    r = subprocess.run(["nvidia-smi", "--query-gpu=compute_cap",
                        "--format=csv,noheader"], capture_output=True, text=True)
    caps = r.stdout.split()
    return "sm_" + caps[0].replace(".", "") if r.returncode == 0 and caps else None


def build(tmp, litmus, sm):
    """The harness binary hetlitmus/build.sh produces from the emission."""
    emit = os.path.join(tmp, "emit")
    os.makedirs(emit)
    cu, _ = ptx.emit_harness(litmus, emit)
    d = os.path.dirname(cu)
    r = subprocess.run(["bash", BUILD_SH, emit, "--arch", sm], capture_output=True,
                       text=True,
                       env=dict(os.environ, RESULTS=os.path.join(tmp, "build-results")))
    exe = os.path.join(d, os.path.basename(d))
    if r.returncode != 0 or not os.access(exe, os.X_OK):
        raise SystemExit("runcheck: build.sh --arch %s failed (rc=%d):\n%s"
                         % (sm, r.returncode, (r.stdout + r.stderr)[-2000:]))
    return exe


def run(exe, **knobs):
    """The printout of one invocation."""
    env = dict(RUN_ENV, **os.environ)
    env.update(knobs)
    try:
        r = subprocess.run([exe], cwd=os.path.dirname(exe), env=env,
                           capture_output=True, text=True, timeout=RUN_TIMEOUT)
    except subprocess.TimeoutExpired:
        # Every rendezvous wait is capped in polls, so a run that does not
        # finish is a launch or driver fault, not a slow box.
        raise SystemExit("runcheck: the run did not finish in %ds under %s" % (
            RUN_TIMEOUT, " ".join("%s=%s" % kv for kv in knobs.items())))
    return r.stdout + "\n" + r.stderr


def run_until_sighting(exe):
    """(printout, k) of the last run: fresh seeds until the outcome fires, a
    run is discarded, or the seeds run out."""
    for i in range(1, SEED_TRIES + 1):
        text = run(exe, HET_SEED=str(1000 + i))
        m = STATS.search(text)
        if not m:
            raise SystemExit("runcheck: no HetStats line:\n%s" % text[-2000:])
        k = int(m.group(1))
        if k > 0 or "COLD-INVALID" in text:
            return text, k
        print("  seed %d: k=0" % (1000 + i))
    return text, 0


def check_arm(text, k, test, pair):
    bad = []
    if "HetVerdict %s run=" % test not in text:
        bad.append("no HetVerdict line names %s" % test)
    classes = set(VERDICT.findall(text))
    if k > 0:
        arm, frag = "OBSERVED", "the weak outcome was OBSERVED on %s" % pair
    elif classes == {"COLD-INVALID"}:
        arm, frag = "COLD-INVALID", COLD_ARM
    else:
        arm, frag = "NOT-OBSERVED", NULL_ARM
    print("  arm: %s (verdict lines: %s)" % (arm, ", ".join(sorted(classes)) or "none"))
    if frag not in text:
        bad.append("the %s arm never says %r" % (arm, frag))
    return bad


def check_cap0(text):
    """Under caps of zero polls the earlier arriver of every iteration times
    out: nothing scored, COLD-INVALID naming the partner, no reach claimed."""
    bad = []
    m = RDV.search(text)
    if not m:
        bad.append("cap 0: no rendezvous count line")
    elif m.group(1) != "0":
        bad.append("cap 0: scored %s iteration(s), discarded %s" % m.groups())
    else:
        print("  cap 0: scored=0 discarded=%s" % m.group(2))
    classes = set(VERDICT.findall(text))
    if classes != {"COLD-INVALID"}:
        bad.append("cap 0: the verdict line reads %s, not COLD-INVALID"
                   % (", ".join(sorted(classes)) or "nothing"))
    bad += ["cap 0: the printout never says %r" % frag
            for frag in (COLD_ARM, DEAD_PARTNER) if frag not in text]
    if NULL_ARM in text:
        bad.append("cap 0: the printout claims reach")
    return bad


def main():
    argparse.ArgumentParser(description=__doc__.splitlines()[0]).parse_args()
    if not os.access(ptx.LITMUS7, os.X_OK):
        raise SystemExit("runcheck: litmus7 not built (run 'make all')")
    if platform.machine() not in HOST:
        raise SystemExit("runcheck: no built corpus carries a %s CPU column"
                         % platform.machine())
    key, cdir, test = HOST[platform.machine()]
    pair = "(%s, cuda)" % key
    sm = arch()
    if sm is None:
        raise SystemExit("runcheck: no CUDA device is visible (nvidia-smi "
                         "reported none), so there is nothing to assert")
    print("runcheck: %s, %s, %s, HET_ALLOC=%s"
          % (test, pair, sm, os.environ.get("HET_ALLOC", RUN_ENV["HET_ALLOC"])))
    tmp = tempfile.mkdtemp(prefix="runcheck.")
    try:
        exe = build(tmp, os.path.join(cdir, test + ".litmus"), sm)
        text, k = run_until_sighting(exe)
        bad = check_arm(text, k, test, pair)
        bad += check_cap0(run(exe, HET_CAP_CPU="0", HET_CAP_GPU="0",
                              HET_RUNS_MAX="1", HET_SEED="1"))
    except RuntimeError as e:
        raise SystemExit("runcheck: %s" % e)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    for b in bad:
        print("  FAIL: " + b)
    print("RUNCHECK: %s" % ("FAIL (%d)" % len(bad) if bad else "PASS"))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())

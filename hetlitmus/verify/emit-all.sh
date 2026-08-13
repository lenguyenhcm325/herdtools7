#!/usr/bin/env bash
# HetLitmus emission snapshot: emit the FULL corpus over every (CPU ISA x GPU
# dialect) pair into OUTDIR -- 411 het harness dirs per het lane and 137
# gpu-only kernels per gpu-only lane.
#
# Purpose: the refactor golden.  The Layer-2 gate (corpus-gate.sh) byte-pins
# only the committed gpu-only samples; every other emitted artifact is covered
# by PROPERTY gates (cram greps, ptxcheck, verdictcheck/statscheck corpus
# phases), which by design pass a range of outputs.  A behaviour-preserving
# refactor of the emitter should instead prove BYTE-IDENTICAL output: emit
# before, emit after, `diff -r`.  Emission is deterministic (corpus-gate.sh
# already relies on this for its samples).
#
#   ./emit-all.sh SNAP_BEFORE     # at the pre-refactor commit
#   ...refactor...
#   ./emit-all.sh SNAP_AFTER
#   diff -r SNAP_BEFORE SNAP_AFTER && echo BYTE-IDENTICAL
#
# THE LANES ARE PAIRS, not vendors.  A compound harness is a CPU ISA and a GPU
# dialect, and litmus/hetMachine.ml's table says which of those pairs may NAME a
# machine.  Every pair emits; the table decides what the render is entitled to
# claim, so the emission surface is one lane per (corpus x dialect) combination,
# listed in HET_LANES / GPU_LANES below and nowhere else:
#
#   het-cuda      aarch64 corpus x cuda   GH200 machine words stamped
#   het-x86-hip   x86     corpus x hip    MI300A machine words stamped
#   het-x86-cuda  x86     corpus x cuda   registered, no machine row: no stamps
#   het-hip       aarch64 corpus x hip    unregistered: no stamps, warned
#   gpu-cuda / gpu-hip                    the GPU-only (scoped LISA) arm, which
#                                         has no CPU column and so no pair
#
# The two lanes that stamp NOTHING are the LANDMINE SURFACE, asserted per lane
# below: a render that names a machine its pair has no row for is the one defect
# no reader of a results tree could catch afterwards.
#
# The x86 corpus is NOT committed (tests/het/generate-x86.sh says why); it is
# generated into a scratch dir OUTSIDE OUTDIR, so `diff -r' of two snapshots
# still compares emitted bytes only.  The het corpora are emitted from INSIDE
# their own directory so emission finds the pair's control map + the co-run
# sibling .litmus (a harness embeds its mu(T) and its canary, both resolved
# relative to the source dir).  gpu-only reuses emit-gpu.sh.
#
# FAIL-CLOSED (P2b).  This loop used to be
#     "$LITMUS7" -o "$OUTDIR/het" "$t" >/dev/null
# and litmus7 itself EXITED 0 on a refusal: its batch driver caught the emission
# exception, printed it on the discarded stream and returned success
# (dumpRun.ml:266-281 -> litmus.ml:383-385).  Measured, by replaying the
# pre-P2b script against stand-in litmus7 binaries:
#   * a wholly MISSING harness directory WAS caught, but only by the aggregate
#     census at the bottom -- `emitted: 410 ...' / `FAIL: census mismatch',
#     exit 1, naming no test and no reason (and the count is not even
#     proportionate: one broken test also breaks every harness that co-runs it
#     as mu(T)/canary);
#   * an INCOMPLETE harness -- directory present, <t>_cpu.c gone -- was NOT
#     caught: `emitted: 411 het harness dirs', exit 0.  A snapshot with a whole
#     CPU thread missing reported success.
# Inert while every committed test emitted; live the moment the x86 CPU lane was
# wired.  Three INDEPENDENT detectors now stand between a refusal and a green run:
#   (a) CORRUPTION -- litmus7 exits 3 and prints "HetLitmus REFUSED" (see
#       HetArch.refused); this script checks the status AND greps the marker,
#       so neither one alone is load-bearing;
#   (b) OMISSION   -- the harness directory the test must produce is checked
#       for existence and for its <t>_cpu.c and its OWN render, which fires even
#       if litmus7 were to exit 0 with nothing written.  The lane's render is
#       also required to be the ONLY one: a dir carrying the other vendor's
#       file too would mean -gpu-target stopped filtering.
#   (c) MIS-TAGGING -- every harness of a lane must carry that PAIR's name and
#       that pair's machine defines, and the lane as a whole must SAY no other
#       row's machine words (brandscan.py, over the printed literals and the
#       README / build files).  A harness built for the wrong pair compiles,
#       runs and reports; the stamps and the sentences are what say which
#       machine it was measuring, and a sentence needs no define to name one.
# Each names the test it failed on and pastes litmus7's own output.
#
# Usage:  hetlitmus/verify/emit-all.sh OUTDIR
#         HET_LANES_ONLY / HET_TESTS_ONLY restrict what is emitted (see below).
# Exit:   0 = every selected lane complete; non-zero otherwise (fail-fast).
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../paths.sh"
# Bite seam: point this at a stand-in litmus7 to prove the detectors below
# actually fire.  A detector that has never been seen to fail is not evidence.
LITMUS7="${HET_LITMUS7:-$LITMUS7}"
[ -x "$LITMUS7" ] || { echo "error: $LITMUS7 not built (run 'make all')" >&2; exit 2; }

# Subset seams, empty = everything.  A stand-in litmus7 corrupts one artefact of
# one lane, so the detector that owns it needs that lane and that test and no
# others.  HET_LANES below is NOT narrowed by either: the -gpu-target filter-leak
# loop and the run.sh cleanup range over every lane whatever is selected here, so
# a leak into a lane this run did not emit is still caught.  A run with either
# seam set emits a subset and says so -- see the snapshot guard below.
LANES_ONLY="${HET_LANES_ONLY:-}"        # OUTDIR subdirs to emit
TESTS_ONLY="${HET_TESTS_ONLY:-}"        # test basenames, per het lane's corpus
lane_selected() {               # <OUTDIR subdir> -> 0 when this run emits it
  if [ -z "$LANES_ONLY" ]; then return 0; fi
  for s in $LANES_ONLY; do
    if [ "$s" = "$1" ]; then return 0; fi
  done
  return 1
}

# THE EMISSION LANES, "<corpus>:<gpu-target>:<render extension>:<OUTDIR subdir>".
HET_LANES="aarch64:cuda:cu:het-cuda x86:hip:hip:het-x86-hip x86:cuda:cu:het-x86-cuda \
aarch64:hip:hip:het-hip"
# The OTHER VENDOR'S words a lane must NOT contain anywhere in its harness dirs
# -- the landmine: an x86 host with an NVIDIA GPU is neither published part, and
# "Infinity Fabric" is what the (X86_64, hip) lane stamps one line away from
# here.  (`MI300A' alone is not a landmine: the CPU stress payload's comments
# compare the two hosts by name -- see cram machine-pairs.t (f).)
forbidden_of_lane() {           # <corpus>:<target> -> egrep pattern, or ""
  case "$1" in
    x86:cuda) echo 'Infinity Fabric' ;;
    *)        echo '' ;;
  esac
}
# WHOSE WORDS EACH LANE MAY PRINT, for brandscan.py -- which reads the string
# literals a driver prints and the README / build files a reader opens, and
# leaves the comparative COMMENTS alone (a payload explains its lane by naming
# the part it was derived for, and de-branding a citation falsifies it).  The
# defines above say what a render stamps; this says what it SAYS, and the two are
# not the same check: the Grace half a harness names in a warning is a claim
# about the box it ran on whether or not any define produced the word.
entitled_of_lane() {            # <corpus>:<target> -> the row it may name
  case "$1" in
    aarch64:cuda) echo gh200 ;;
    x86:hip)      echo mi300a ;;
    *)            echo none ;;
  esac
}
# THE PAIR NAME each lane's renders must stamp, and the MACHINE DEFINE BLOCK each
# is entitled to -- verbatim, in emission order, empty where the pair has no
# machine row (litmus/hetMachine.ml).  Checked as a whole block rather than by
# count: a lane that stamped another row's words in the right number would pass a
# count.
pair_of_lane() {                # <corpus>:<target> -> the HET_PAIR_NAME value
  case "$1" in
    aarch64:*) echo "(AArch64, ${1#*:})" ;;
    x86:*)     echo "(X86_64, ${1#*:})" ;;
    *) echo "emit-all.sh: unknown lane $1" >&2 ; return 1 ;;
  esac
}
machine_of_lane() {             # <corpus>:<target> -> the #define block, or ""
  case "$1" in
    aarch64:cuda)
      printf '%s\n' '#define HET_LINK_NAME "NVLink-C2C"' \
                    '#define HET_HOST_HALF "the Grace half"' \
                    '#define HET_DEV_HALF "the Hopper half"' \
                    '#define HET_LLC_MB 114' \
                    '#define HET_ALGLAVE_ZERO_MEASURED 1' ;;
    x86:hip)
      printf '%s\n' '#define HET_LINK_NAME "Infinity Fabric"' \
                    '#define HET_HOST_HALF "the x86 half"' \
                    '#define HET_DEV_HALF "the MI300A device half"' \
                    '#define HET_LLC_MB 256' ;;
    *) : ;;
  esac
}
# ...and, where no machine is stamped, WHICH of the two reasons the render gives
# for it: a REGISTERED pair is deliberately nameless, an unregistered one was
# never considered.  Only litmus/hetMachine.ml's registered bit tells them apart,
# and this line is the only place that bit reaches a reader.
nomachine_note_of_lane() {      # <corpus>:<target> -> the sentence, or ""
  case "$1" in
    aarch64:cuda|x86:hip) : ;;
    aarch64:hip) echo 'is in no' ;;
    *)           echo 'no machine row backs this' ;;
  esac
}
MACHINE_DEFINE_RE='^#define HET_(LINK_NAME|HOST_HALF|DEV_HALF|LLC_MB|ALGLAVE_ZERO_MEASURED)'
GPU_LANES="cuda:cu:gpu-cuda hip:hip:gpu-hip"
EXPECT_HET=411          # harness dirs per het lane
EXPECT_GPU=137          # kernels per gpu-only lane

OUTDIR="${1:?usage: emit-all.sh OUTDIR}"
mkdir -p "$OUTDIR"
OUTDIR="$(cd "$OUTDIR" && pwd)"

# THE SNAPSHOT GUARD.  A seam-restricted run emits a subset, so `diff -r' against
# a full snapshot would report the missing lanes and tests as emitter changes.
# The marker is a dotfile, and `diff -r' compares dotfiles, so the instrument that
# reads snapshots cannot take a subset for one.  It carries a per-run nonce as
# well as the selection, because two subsets taken at two revisions with the
# same seams would otherwise diff clean and read as "byte-identical" over
# whatever fraction of the corpus they hold.  pack-bundle.sh refuses on the
# seams themselves, before it creates anything.
SNAP_MARKER="$OUTDIR/.het-partial-snapshot"
EXPECT_SEL="$EXPECT_HET"        # harness dirs a het lane owes THIS run
if [ -n "$LANES_ONLY$TESTS_ONLY" ]; then
  if [ -n "$TESTS_ONLY" ]; then EXPECT_SEL="$(echo $TESTS_ONLY | wc -w)"; fi
  echo "PARTIAL SNAPSHOT: lanes='${LANES_ONLY:-<all>}' tests='${TESTS_ONLY:-<all>}'"
  echo "        a subset, not a snapshot: not comparable with diff -r, not packable"
  printf 'lanes=%s\ntests=%s\nrun=%s\n' "${LANES_ONLY:-<all>}" \
    "${TESTS_ONLY:-<all>}" "$$-$RANDOM$RANDOM" > "$SNAP_MARKER"
else
  rm -f "$SNAP_MARKER"
fi

# OUTSIDE OUTDIR: a snapshot is byte-diffed with `diff -r', which compares
# dotfiles too, so no scratch file may land in it.
LOG="$(mktemp)"
SCRATCH="$(mktemp -d)"
trap 'rm -f "$LOG"; rm -rf "$SCRATCH"' EXIT

# The x86 corpus, generated on demand (it is deliberately not committed).
X86_CORPUS="$SCRATCH/x86"
gen_x86_once() {
  [ -d "$X86_CORPUS" ] && return 0
  echo "        generating the x86 corpus (not committed; tests/het/generate-x86.sh)"
  PATH="$BIN:$PATH" bash "$HETL/tests/het/generate-x86.sh" "$X86_CORPUS" >"$LOG" 2>&1 || {
    echo "FAIL: generate-x86.sh failed; its output:" >&2 ; cat "$LOG" >&2 ; exit 1 ; }
}
corpus_dir() {                  # <corpus> -> the directory to emit from
  case "$1" in
    aarch64) echo "$HETL/tests/het" ;;
    x86)     gen_x86_once >&2 ; echo "$X86_CORPUS" ;;
    *) echo "emit-all.sh: unknown corpus $1" >&2 ; return 1 ;;
  esac
}

i=0
nlanes=0
nhetlanes=0
ngpulanes=0
for lane in $HET_LANES $GPU_LANES; do
  if lane_selected "${lane##*:}"; then nlanes=$((nlanes+1)); fi
done

for lane in $HET_LANES; do
  corpus="${lane%%:*}"; rest="${lane#*:}"
  target="${rest%%:*}"; rest="${rest#*:}"
  ext="${rest%%:*}"; sub="${rest#*:}"
  lane_selected "$sub" || continue
  nhetlanes=$((nhetlanes+1))
  forbidden="$(forbidden_of_lane "$corpus:$target")"
  want_pair="$(pair_of_lane "$corpus:$target")"
  want_machine="$(machine_of_lane "$corpus:$target")"
  want_note="$(nomachine_note_of_lane "$corpus:$target")"
  want_entitled="$(entitled_of_lane "$corpus:$target")"
  i=$((i+1))
  echo "[$i/$nlanes] $corpus corpus, -gpu-target $target -> $OUTDIR/$sub"
  cdir="$(corpus_dir "$corpus")"
  mkdir -p "$OUTDIR/$sub"
  ( cd "$cdir"
    if [ -n "$TESTS_ONLY" ]; then
      set --
      for n in $TESTS_ONLY; do set -- "$@" "$n.litmus"; done
    else
      set -- *.litmus
    fi
    for t in "$@"; do
      n="${t%.litmus}"
      st=0
      "$LITMUS7" -gpu-target "$target" -o "$OUTDIR/$sub" "$t" >"$LOG" 2>&1 || st=$?
      if [ "$st" -ne 0 ]; then
        echo "FAIL: litmus7 -gpu-target $target exited $st on $t (no harness emitted); its output:" >&2
        cat "$LOG" >&2
        exit 1
      fi
      if grep -q 'HetLitmus REFUSED' "$LOG"; then
        echo "FAIL: litmus7 -gpu-target $target REFUSED $t; its output:" >&2
        cat "$LOG" >&2
        exit 1
      fi
      for f in "$n/${n}_cpu.c" "$n/$n.$ext"; do
        if [ ! -s "$OUTDIR/$sub/$f" ]; then
          echo "FAIL: $t emitted no $f in the $corpus/$target lane (harness missing or empty); litmus7 said:" >&2
          cat "$LOG" >&2
          exit 1
        fi
      done
      for other in $HET_LANES; do
        oext="${other#*:}"; oext="${oext#*:}"; oext="${oext%%:*}"
        if [ "$oext" != "$ext" ] && [ -e "$OUTDIR/$sub/$n/$n.$oext" ]; then
          echo "FAIL: the $corpus/$target lane emitted $n/$n.$oext as well -- -gpu-target is not filtering" >&2
          exit 1
        fi
      done
      # (c) THE RECORD STAMP.  het_verdict() reads no field of a record without
      # HET_REC_MAGIC, so a render that lost the stamp discards every run it
      # will ever make.
      if [ "$(grep -c '_rec.rec_magic = HET_REC_MAGIC;' "$OUTDIR/$sub/$n/$n.$ext")" != 1 ]; then
        echo "FAIL: $t in the $corpus/$target lane does not stamp _rec.rec_magic exactly once" >&2
        exit 1
      fi
      # THE CONTROL MAP WAS THERE.  Every het lane emits from beside its own map,
      # so this define can only appear if the lane lost it -- and a harness that
      # names no control still emits, still runs and still prints, with every
      # null it produces uninterpretable.  Nothing else in this script would see
      # that: the stamps, the pair name and the census are all unaffected.
      if grep -q '^#define HET_NO_CONTROL_MAP 1' "$OUTDIR/$sub/$n/$n.$ext"; then
        echo "FAIL: $t in the $corpus/$target lane stamps HET_NO_CONTROL_MAP 1 -- no control map was found beside the test, so it co-runs nothing" >&2
        exit 1
      fi
      # THE PAIR, and the machine words that pair is entitled to.
      if [ "$(grep -cF "#define HET_PAIR_NAME \"$want_pair\"" "$OUTDIR/$sub/$n/$n.$ext")" != 1 ]; then
        echo "FAIL: $t in the $corpus/$target lane does not stamp HET_PAIR_NAME \"$want_pair\" exactly once; it stamps:" >&2
        grep -F '#define HET_PAIR_NAME' "$OUTDIR/$sub/$n/$n.$ext" >&2 \
          || echo "  (no HET_PAIR_NAME at all)" >&2
        exit 1
      fi
      got_machine="$(grep -E "$MACHINE_DEFINE_RE" "$OUTDIR/$sub/$n/$n.$ext" || true)"
      if [ "$got_machine" != "$want_machine" ]; then
        echo "FAIL: $t in the $corpus/$target lane stamps the wrong machine.  It stamps:" >&2
        printf '%s\n' "${got_machine:-  (nothing)}" | sed 's/^/  /' >&2
        echo "  and this pair is entitled to:" >&2
        printf '%s\n' "${want_machine:-  (nothing)}" | sed 's/^/  /' >&2
        exit 1
      fi
      if [ -n "$want_note" ]; then
        if ! grep -qF "$want_note" "$OUTDIR/$sub/$n/$n.$ext"; then
          echo "FAIL: $t in the $corpus/$target lane names no machine and does not say WHY (\"$want_note\") -- a registered pair with no machine row and a pair in no row at all read alike" >&2
          exit 1
        fi
      fi
      if [ -n "$forbidden" ] \
         && grep -rqE "$forbidden" "$OUTDIR/$sub/$n"; then
        echo "FAIL: $t in the $corpus/$target lane names a machine its pair has no row for ($forbidden):" >&2
        grep -rlE "$forbidden" "$OUTDIR/$sub/$n" >&2
        exit 1
      fi
    done )
  # WHAT THE LANE SAYS, over the lane at once: 411 harness dirs are one scan, and
  # brandscan.py names the file, the line and the row whose word it found.
  if ! python3 "$HETL/verify/brandscan.py" --entitled "$want_entitled" --quiet \
       "$OUTDIR/$sub"; then
    echo "FAIL: the $corpus/$target lane names a machine its pair is not entitled to (above)" >&2
    exit 1
  fi
  nhet="$(find "$OUTDIR/$sub" -mindepth 1 -maxdepth 1 -type d | wc -l)"
  echo "        $nhet het harness dirs (expect $EXPECT_SEL), each stamping its record and $want_pair once, none naming another pair's machine"
  if [ "$nhet" -ne "$EXPECT_SEL" ]; then
    echo "FAIL: census mismatch in $sub (want $EXPECT_SEL)" >&2
    exit 1
  fi
done

for lane in $GPU_LANES; do
  target="${lane%%:*}"; rest="${lane#*:}"; ext="${rest%%:*}"; sub="${rest#*:}"
  lane_selected "$sub" || continue
  ngpulanes=$((ngpulanes+1))
  i=$((i+1))
  echo "[$i/$nlanes] gpu-only corpus, -gpu-target $target -> $OUTDIR/$sub"
  st=0
  "$HETL/emit-gpu.sh" "$target" "$OUTDIR/$sub" >"$LOG" 2>&1 || st=$?
  if [ "$st" -ne 0 ] || grep -q 'HetLitmus REFUSED' "$LOG"; then
    echo "FAIL: emit-gpu.sh $target exited $st / refused; its output:" >&2
    cat "$LOG" >&2
    exit 1
  fi
  n="$(ls "$OUTDIR/$sub"/*."$ext" 2>/dev/null | wc -l)"
  echo "        $n gpu-only .$ext (expect $EXPECT_GPU)"
  if [ "$n" -ne "$EXPECT_GPU" ]; then
    echo "FAIL: census mismatch in $sub (want $EXPECT_GPU .$ext)" >&2
    exit 1
  fi
  for other in $GPU_LANES; do
    oext="${other#*:}"; oext="${oext%%:*}"
    if [ "$oext" != "$ext" ] && ls "$OUTDIR/$sub"/*."$oext" >/dev/null 2>&1; then
      echo "FAIL: the gpu-only $target lane emitted .$oext files -- -gpu-target is not filtering" >&2
      exit 1
    fi
  done
done

# The per-outdir run.sh embeds the ABSOLUTE OUTDIR path + the git revision
# (upstream litmus7 boilerplate, overwritten by every emission so it names only
# the last test).  It is the ONLY emitted file that does (verified: grep for
# the revision/outdir over a full snapshot hits nothing else), so drop it here
# and a plain `diff -r` of two snapshots is byte-exact across dirs AND commits.
for lane in $HET_LANES $GPU_LANES; do
  rm -f "$OUTDIR/${lane##*:}/run.sh"
done

echo "emitted: $nhetlanes x $EXPECT_SEL het harness dirs, \
$ngpulanes x $EXPECT_GPU gpu-only kernels"

#!/usr/bin/env bash
# D10 -- the CPU-ONLY POSITIVE CONTROL, generated into OUTDIR (never the repo).
#
#   usage:  ./generate-d10.sh OUTDIR
#
# WHAT THIS IS FOR: env-research/PORT2-R2-amd-oracle.md sect 7, row D10, and
# PORT2-PHASE2-plan.md:71, which calls it "a first-class campaign item".
#
# D10 is a TABLE ROW, so what follows is a summary of it and NOT a quotation --
# its sentences live in two different cells and stitching them into one block
# quote would misattribute a splice.  Read the row itself for the wording.
#   * run the four artifact CPU-Only shapes as pure x86 tests on the MI300A host,
#     on the ACTUAL SHARED ALLOCATION  (cell 2);
#   * SB and R must be observed -- the store buffer is live -- which doubles as
#     the WB probe of sect 8 P1, since an SB observation rules out UC; MP, LB,
#     2+2W and IRIW must never be observed  (cell 4);
#   * wire the disambiguation into verdict reporting BEFORE the first run: an
#     observed CPU-only Disallowed shape is a finding about x86-TSO not
#     describing this implementation -- [CACM] sect 7's own invited
#     counterexample -- and NOT a refutation of the CMCM.  Without it, a Zen-4
#     conformance failure is mis-reported as a compound-model refutation
#     (cell 4).
#
# It is generated as a HET test with every proc tagged `cpu' -- NOT as an
# upstream X86_64 litmus test -- and that is the whole point.  A plain litmus7
# X86 run would allocate x and y with litmus7's own allocator; D10 requires the
# SHARED allocation, because the question is whether THAT allocation is WB.  The
# het harness reaches it through gd_alloc_shared (HET_ALLOC / hipMallocManaged),
# runs the same stress, and prints the same verdict machinery.
#
# The emitter classifies procs by their device tag and sets `_rec.cpu_only = 1'
# when every one of them is a CPU proc; het_verdict.h keys the D10 sentences off
# that flag, so nothing here depends on the FILE NAME saying "cpuonly".
#
# THE ORACLE.  Every verdict below was machine-checked against herd7 +
# herd/libdir/x86tso.cat on the SAME cycle rendered with `diyone7 -arch X86'.
# Measured 2026-08-03:
#     MP    Never 0 3      LB    Never 0 3      2+2W  Never 0 3
#     IRIW  Never 0 15     SB    Sometimes 1 3  R     Sometimes 1 3
# which reproduces D10's prose (SB/R observable, MP/LB/2+2W/IRIW not) and, on
# the four shapes it covers, the PLDI'23 artifact's own expected.csv:
#     CPU-Only,MP-sys,Disallowed   CPU-Only,LB-sys,Disallowed
#     CPU-Only,SB-sys,Allowed      CPU-Only,IRIW-sys,Disallowed
# OPEN, AND IT AFFECTS EXACTLY ONE ROW OF THIS SET -- read before using 2+2W.
# MEASURED 2026-08-03 on the dev box (12th Gen Intel i5-12500H + RTX 3060,
# HET_ALLOC=pinned): SB and R fired (the WB probe passed, so the allocation is
# not UC), MP / LB / IRIW were not observed in 10 runs each -- exactly what
# x86-TSO predicts -- and 2+2W-cpuonly reported MISMATCH-CONFIRMED, 10 runs of
# 10, with the co edge recovered by the x86-side observer (obs_ws_via_cpu=1).
#
# That is NOT reported here as an x86-TSO violation, and it must not be, because
# 2+2W is the only STORE-ONLY shape in this set: it has no reader, so its cycle
# is reconstructed from an observer rather than from a load, and the emitted
# reconstruction has a known blind spot.  In the emitted scan the per-store tag
# is K*(_n+1)+mu, and the ws test reads `_t % T_K_TAG' -- the store id -- and
# NEVER `_t / T_K_TAG', the iteration (verified over the emitted .cu: four
# occurrences of `% T_K_TAG' inside the four t__ws_* scans, zero of
# `/ T_K_TAG'; the quotient is used only by the observer-uniqueness blocks).
# Under the perpetual loop the observer therefore matches "mu_a seen before
# mu_b" ACROSS iterations, where the coherence order it is meant to witness is
# only defined WITHIN one.  D10 is the first time this detector has been aimed
# at a cycle whose oracle FORBIDS it -- in the het corpus every 2+2W row is
# Allowed, so over-reporting there looks like success -- so the sighting is
# equally consistent with the detector over-reporting and with a real property
# of the pinned allocation.
#
# It does not touch the four ARTIFACT shapes (MP, LB, SB, IRIW): each has a real
# x86 reader, so its cycle closes through a load and none of this applies.  Use
# those four; treat the 2+2W row as UNRESOLVED until the store-only detector is
# re-examined (B3 / DR1 territory, not this script's).
set -e
# OUTDIR IS RESOLVED FIRST, AGAINST THE CALLER'S CWD, BECAUSE THE `cd' BELOW
# MOVES US.  MEASURED 2026-08-03: with the resolution after the cd, `make
# hetlitmus-d10' -- whose $(HETD10OUT) is the RELATIVE `hetlitmus/tests/het/
# d10-out' -- created hetlitmus/tests/het/hetlitmus/tests/het/d10-out/ inside
# the committed corpus and then died with "cd: can't cd to
# hetlitmus/tests/het/d10-out", RC=2, leaving the tree dirty.  A relative
# OUTDIR is the normal case for a Makefile caller, so it is the one that has
# to work.
OUT="${1:?usage: generate-d10.sh OUTDIR}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

cd "$(dirname "$0")"
HETDIR="$(pwd)"
# shellcheck source=../../paths.sh
source ../../paths.sh
COMMON="-set-libdir $HERDLIB -bell $HETL/bells/ptx.bell"

[ "$OUT" != "$HETDIR" ] || { echo "refusing to write into the committed corpus" >&2; exit 2; }

# shape | nprocs | cycle | oracle verdict
#
# WHERE EACH VERDICT COMES FROM (recorded in the Source column of the CSV this
# script writes, and in the notes above):
#  * MP/LB/SB/IRIW are the artifact's own CPU-Only rows -- the same shape,
#    CPU-only, in PLDI23_Compound_Simulation's expected.csv -- AND herd7 on
#    x86tso.cat decides each of them independently.
#  * 2+2W has no artifact CPU-Only row, so its Disallowed verdict rests on
#    x86-TSO alone (and see the store-only-detector caveat above).
#  * R is decided by herd7 on x86tso.cat in the sound direction: Sometimes =>
#    Allowed (memo sect 9.4 G8).
#
# None of this can turn a D10 mismatch into a CMCM refutation whatever the row
# rests on: the CPU-only branch of het_verdict.h outranks the ordinary sentence,
# because on an all-CPU cycle the compound model is not under test.
D10_ROWS="
MP:2:PodWW Rfe PodRR Fre:Disallowed
LB:2:PodRW Rfe PodRW Rfe:Disallowed
SB:2:PodWR Fre PodWR Fre:Allowed
2+2W:2:PodWW Coe PodWW Coe:Disallowed
R:2:PodWW Coe PodWR Fre:Allowed
IRIW:4:Rfe PodRR Fre Rfe PodRR Fre:Disallowed
"

# The Layer-B canary for this set is SB-cpuonly, and it is the RIGHT one rather
# than the het MP canary the main corpus uses: the question a D10 null has to
# answer is "was the SHARED ALLOCATION's store buffer live", and only a CPU-only
# Allowed shape on that allocation answers it.  Importing MP-cg-sys-relaxed
# would vouch for the C2C path -- a path these tests do not use.
CANARY="SB-cpuonly-x86_64"

CM="$OUT/control-map-amd.csv"
EX="$OUT/expected-amd.csv"
cat > "$CM" <<EOF
# HetLitmus D10 CPU-ONLY positive control -- control map.  GENERATED by
# generate-d10.sh; do not hand-edit.  See that script for the derivation.
# Mu is \`none' on every Disallowed row and that is a DERIVED absence, not a
# gap: an x86 rendering of these cycles carries plain MOVs and no fence, so it
# is already at the bottom of the x86 strength lattice and has no weakening
# left.  Every D10 null is therefore a WEAK-NULL by construction, vouched for
# by the Layer-B canary ($CANARY) alone.
Test,Expected,Mu,MuExpected,MuRule,MuAlt,MuRelaxed,Canary
EOF
cat > "$EX" <<'EOF'
# HetLitmus D10 CPU-ONLY positive control -- oracle.  GENERATED by
# generate-d10.sh; do not hand-edit.
#
# Model is AMD-CDNA3-x86 because that names the MACHINE these tests run on and
# the allocator they run against, and it is the lane whose oracle file name the
# emitter records.  It does NOT claim the CDNA3 half is exercised -- it is not:
# every proc is a CPU proc, `_rec.cpu_only' is 1, and het_verdict.h says in so
# many words that the compound model is not under test here.
#
# Verdicts are x86-TSO, machine-checked against herd7 + herd/libdir/x86tso.cat
# and, on four of the six shapes, against the PLDI'23 artifact's own CPU-Only
# rows.  No line of this file is a hardware observation.
Litmus,Expected,Model,Source
EOF

n=0
printf '%s\n' "$D10_ROWS" | while IFS=: read -r shape nprocs cycle verdict; do
  [ -n "$shape" ] || continue
  name="$shape-cpuonly-x86_64"
  devs="cpu"; i=1
  while [ "$i" -lt "$nprocs" ]; do devs="$devs,cpu"; i=$((i+1)); done
  # -gpu is a required option of hetgen7 and is UNUSED here: no proc carries the
  # gpu tag, so no LISA column is rendered.  It is fed the same cycle so the two
  # arguments cannot drift apart into a cycle mismatch.
  "$BIN/hetgen7" $COMMON -cpu-arch x86_64 -devices "$devs" -name "$name" \
    -cpu "$cycle" -gpu "$cycle" > "$OUT/$name.litmus"
  # Sanity: every proc really is tagged x86_64 and none is a gpu column.  Cheap,
  # and it is the property the whole D10 reading rests on.
  if grep -qE 'P[0-9]+:gpu' "$OUT/$name.litmus"; then
    echo "FAIL: $name has a gpu column -- it is not a CPU-only test" >&2; exit 1
  fi
  if [ "$name" = "$CANARY" ]; then can="self"; else can="$CANARY"; fi
  echo "$name,$verdict,none,-,NO Layer-A mutant CAN exist: an x86 rendering of this cycle is already at the lattice minimum (plain MOV; no fence to drop),-,none,$can" >> "$CM"
  echo "$name,$verdict,AMD-CDNA3-x86,D10 CPU-only positive control: x86-TSO on the shared allocation. Machine-checked against herd7 + x86tso.cat on the same cycle. Doubles as the memo sect 8 P1 WB probe -- an observed SB/R rules out a UC mapping." >> "$EX"
done

n="$(ls "$OUT"/*.litmus | wc -l)"
echo "generate-d10: $n CPU-only tests + control-map-amd.csv + expected-amd.csv in $OUT"
[ "$n" -eq 6 ] || { echo "FAIL: expected 6 D10 tests, found $n" >&2; exit 1; }
# Both maps must key the set exactly, in both directions -- the same check
# generate-x86.sh makes, and for the same reason: a test with no row emits
# ORACLE_UNSET, silently, in C.
ls "$OUT"/*.litmus | sed 's|.*/||; s|\.litmus$||' | sort > "$OUT/.keys.tests"
for m in control-map-amd.csv expected-amd.csv; do
  awk -F, '!/^#/ && NF>1 && $1 != "Test" && $1 != "Litmus" { print $1 }' \
    "$OUT/$m" | sort > "$OUT/.keys.$m"
  diff -q "$OUT/.keys.$m" "$OUT/.keys.tests" >/dev/null || {
    echo "FAIL: $m does not key the D10 set exactly:" >&2
    diff "$OUT/.keys.tests" "$OUT/.keys.$m" >&2; exit 1; }
  rm -f "$OUT/.keys.$m"
done
rm -f "$OUT/.keys.tests"

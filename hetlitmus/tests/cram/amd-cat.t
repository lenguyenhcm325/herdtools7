Layer-1 gate for hetlitmus/cats/amd-gcn3.cat -- the three repairs required by
PORT2-R2 register item D14 (env-research/PORT2-R2-amd-oracle.md sec 7.D14), and
above all their DISCRIMINATING POWER.  D14 exists because the file's only
validation was "8/8 against the artifact", and that contract is blind to every
defect it names: measured at the bottom of this file, ALL EIGHT ablations below
still score 8/8 on the anchor set.  The 137-test GPU-only corpus is the next
instrument up and it is blind to the coherence half -- A0, A1 and A01 move 0 of
its 137 rows (the other five move 4 to 6).  So the probes in ../../cats/probes/
are not decoration: for axiom (0) and for `irreflexive (hb;co)` they are the ONLY
instrument in the tree that sees the repair at all.

herd7's libdir cannot be a declared dune dep (herd/dune excludes herd/libdir from
the source scan, so source_tree/glob_files on it resolve to nothing -- silently).
It is located by walking up from cwd instead, which works from _build and from a
dune sandbox alike; see the comment in ./dune.

  $ LIB=$(d=.; while [ ! -f "$d/herd/libdir/stdlib.cat" ] && [ "$(cd "$d" && pwd)" != / ]; do d=$d/..; done; echo "$d/herd/libdir")
  $ test -f "$LIB/cos.cat" && echo libdir-found
  libdir-found
  $ BELL=../../bells/ptx.bell
  $ CAT=../../cats/amd-gcn3.cat
  $ PR=../../cats/probes
  $ GO=../gpu-only
  $ v () { herd7 -set-libdir "$LIB" -bell "$BELL" -cat "$1" "$2" 2>&1 | sed -n 's/^Observation [^ ]* \(Never\|Sometimes\|Always\).*/\1/p'; }

--------------------------------------------------------------------------
D14(a) -- the coherence axioms.  `coh-probe` is the memo's own probe:
W1 -rf-> R -po-> W2 -co-> W1, which every published model forbids and which
this file used to report Sometimes.

  $ v $CAT $PR/coh-probe.litmus
  Never
  $ v $CAT $PR/coh-probe-relaxed.litmus
  Never
  $ v $CAT $PR/S-probe-relacq.litmus
  Never

Two axioms, not one, and each has its own probe because neither subsumes the
other.  `acyclic po-loc | com` ([HSA] Fig. 2-8) is the one that survives
de-annotation -- coh-probe-relaxed carries no release/acquire anywhere, so `hb`
degenerates to `po` and the hb-based axiom cannot see it.  `irreflexive (hb;co)`
is the one that catches a cycle whose po edges cross LOCATIONS, which po-loc by
construction never sees -- that is S-probe-relacq.

--------------------------------------------------------------------------
D14(b) -- the `'sc` set and the fence-ordering axioms.  Also two mechanisms:
axiom (2)'s [HSA] Fig. 3-15 fence clauses (which need an rf edge to route
through) and axiom (4)'s [SCATOM] Def. 27 sc-order (which does not, and is the
only one that can decide a pure-`co` cycle).

  $ v $CAT $PR/MP-probe-2fence.litmus
  Never
  $ v $CAT $GO/2+2W-sys-fence.litmus
  Never
  $ v $CAT $PR/MP-probe-scacc.litmus
  Never

The extension is deliberately NOT total, and the boundary is asserted, not left
implicit: release/acquire fences carry no SC order, so an SB shape fenced on
both procs stays Allowed.  [SCATOM] Def. 27 gives the SC order to `sc` events
only, and G3's A-D5 is why -- HIP release/acquire have no HSAIL screl/scacq
counterpart, and reading them as sequentially consistent would over-strengthen
by a full SC order.

  $ v $CAT $PR/SB-probe-2fence.litmus
  Sometimes

--------------------------------------------------------------------------
D14(c) -- the `tag2events` seam.  `tag2events('release)` returns FENCE events
too, and axiom (2)'s fence clauses are built on that.  seam-probe.cat states no
axiom, so its flags are computed over every execution.

  $ herd7 -set-libdir "$LIB" -bell "$BELL" -cat $PR/seam-probe.cat $PR/MP-probe-2fence.litmus 2>&1 | grep '^Flag'
  Flag ACQUIRE-TAG-INCLUDES-FENCES
  Flag RELEASE-TAG-INCLUDES-FENCES
  Flag STRONG-INCLUDES-FENCES
  $ herd7 -set-libdir "$LIB" -bell "$BELL" -cat $PR/seam-probe.cat $GO/2+2W-sys-fence.litmus 2>&1 | grep '^Flag'
  Flag ACQUIRE-TAG-INCLUDES-FENCES
  Flag RELEASE-TAG-INCLUDES-FENCES
  Flag SC-TAG-INCLUDES-FENCES
  Flag STRONG-INCLUDES-FENCES

Liveness the other way, so an unconditional flag would be caught: on a test with
no fence at all NOTHING fires.  (`0` plus grep's no-match exit `[1]`; both halves
are part of the expectation.)

  $ herd7 -set-libdir "$LIB" -bell "$BELL" -cat $PR/seam-probe.cat $GO/MP-sys.litmus 2>&1 | grep -c '^Flag'
  0
  [1]

seam-probe.cat duplicates amd-gcn3.cat's set definitions (it must, to observe
them unfiltered by the axioms).  The duplicate is pinned against the original
here, so it cannot drift:

  $ grep -c "^let SCT    = tag2events('sc)$" $CAT $PR/seam-probe.cat
  ../../cats/amd-gcn3.cat:1
  ../../cats/probes/seam-probe.cat:1
  $ grep -c "^let REL = tag2events('release) | ACQREL | SCT$" $CAT $PR/seam-probe.cat
  ../../cats/amd-gcn3.cat:1
  ../../cats/probes/seam-probe.cat:1
  $ grep -c "^let ACQ = tag2events('acquire) | ACQREL | SCT$" $CAT $PR/seam-probe.cat
  ../../cats/amd-gcn3.cat:1
  ../../cats/probes/seam-probe.cat:1

--------------------------------------------------------------------------
THE BITES.  Eight one-line ablations of the real file, each targeting one
mechanism.  A gate never seen to fail is not evidence, so the flipped verdicts
are part of the frozen expectation: if an axiom ever stops being load-bearing,
its line below changes and this test reddens.

  $ sed '/^acyclic po-loc | com as SCperLoc$/d' $CAT > A0.cat
  $ sed '/^irreflexive (hb ; co) as coherence-co$/d' $CAT > A1.cat
  $ sed -e '/^acyclic po-loc | com as SCperLoc$/d' -e '/^irreflexive (hb ; co) as coherence-co$/d' $CAT > A01.cat
  $ sed -e '/^  | (((F & REL) \* ACQ)/d' -e '/^  | ((REL \* (F & ACQ))/d' $CAT > A2.cat
  $ sed '/^acyclic (scpairs & (Fsb? ; (hb | fr | co) ; sbF?)) as sc-order$/d' $CAT > A3.cat
  $ sed -e "s/^let REL = tag2events('release) | ACQREL | SCT\$/let REL = (tag2events('release) | ACQREL | SCT) \& M/" -e "s/^let ACQ = tag2events('acquire) | ACQREL | SCT\$/let ACQ = (tag2events('acquire) | ACQREL | SCT) \& M/" $CAT > A4.cat
  $ sed -e "s/^let REL = tag2events('release) | ACQREL | SCT\$/let REL = tag2events('release) | ACQREL/" -e "s/^let ACQ = tag2events('acquire) | ACQREL | SCT\$/let ACQ = tag2events('acquire) | ACQREL/" $CAT > A5.cat
  $ sed "s/^let strong-po = \[strong\] ; po ; \[strong\]\$/let strong-po = ([strong] ; po ; [strong]) | fencerel(strong \& F)/" $CAT > A6.cat

Every ablation must actually EDIT the file -- a sed that silently matched
nothing would make the bite vacuous, which is how a gate dies quietly.

  $ for a in A0 A1 A01 A2 A3 A4 A5 A6; do printf '%s %s\n' $a "$(diff $CAT $a.cat | grep -c '^[<>]')"; done
  A0 1
  A1 1
  A01 2
  A2 2
  A3 1
  A4 4
  A5 4
  A6 2

A0 removes `acyclic po-loc | com`: the relaxed coherence probe goes weak, the
annotated one does not (the hb-based axiom still holds it).

  $ v A0.cat $PR/coh-probe-relaxed.litmus
  Sometimes
  $ v A0.cat $PR/coh-probe.litmus
  Never

A1 removes `irreflexive (hb;co)`: the cross-location coherence cycle goes weak.

  $ v A1.cat $PR/S-probe-relacq.litmus
  Sometimes

A01 removes both, which is what it takes to break D14's own `coh-probe`.

  $ v A01.cat $PR/coh-probe.litmus
  Sometimes

A2 deletes axiom (2)'s two [HSA] Fig. 3-15 fence clauses: the release/acquire
fence pair stops synchronising.  `2+2W-sys-fence` does NOT move -- axiom (4)
decides that one, and the two mechanisms are genuinely independent.

  $ v A2.cat $PR/MP-probe-2fence.litmus
  Sometimes
  $ v A2.cat $GO/2+2W-sys-fence.litmus
  Never

A3 deletes axiom (4): the pure-`co` cycle goes weak, and the rf-routed one does
not.

  $ v A3.cat $GO/2+2W-sys-fence.litmus
  Sometimes
  $ v A3.cat $PR/MP-probe-2fence.litmus
  Never

A4 is the seam bite: REL/ACQ restricted to `M` (accesses only), which is what
they would silently become if `tag2events` ever stopped returning fences.  The
model still parses, still scores 8/8, and quietly loses the fence clauses.

  $ v A4.cat $PR/MP-probe-2fence.litmus
  Sometimes

A5 drops `'sc` from REL/ACQ -- D14 defect (ii), the one that made a system sc
fence read as strictly weaker than a system release store.

  $ v A5.cat $PR/MP-probe-scacc.litmus
  Sometimes

A6 goes the other way and STRENGTHENS: it lets a fence in `strong` order its
neighbours (`fencerel`).  This is the ablation that proves the SB-probe-2fence
`Sometimes` above is a real reading of the model and not a constant.

  $ v A6.cat $PR/SB-probe-2fence.litmus
  Never

--------------------------------------------------------------------------
THE 8/8 CONTRACT, re-established after the repair -- and shown to be blind.
The eight PLDI'23-anchored rows (tests/gpu-only/expected-amd-gcn3.csv): Never
for MP-sys-F, LB-sys, SB-sys-F, IRIW-sys-F, Sometimes for the other four.

  $ for t in MP-sys MP-sys-F MP-cta-F LB-sys SB-sys SB-sys-F IRIW-sys IRIW-sys-F; do printf '%-11s %s\n' $t "$(v $CAT $GO/$t.litmus)"; done
  MP-sys      Sometimes
  MP-sys-F    Never
  MP-cta-F    Sometimes
  LB-sys      Never
  SB-sys      Sometimes
  SB-sys-F    Never
  IRIW-sys    Sometimes
  IRIW-sys-F  Never

And the blindness, measured rather than asserted: every one of the eight
ablations above reproduces the identical anchor verdicts.  This is why D14
says the extension is unanchored -- there is no fence and no `sc` operation
anywhere in the PLDI'23 artifact, so the anchor set cannot test one line of
axiom (4), of axiom (2)'s fence clauses, or of the `'sc` set.

  $ for a in A0 A1 A01 A2 A3 A4 A5 A6; do s=""; for t in MP-sys MP-sys-F MP-cta-F LB-sys SB-sys SB-sys-F IRIW-sys IRIW-sys-F; do s="$s$(v $a.cat $GO/$t.litmus)|"; done; printf '%s %s\n' $a "$s"; done
  A0 Sometimes|Never|Sometimes|Never|Sometimes|Never|Sometimes|Never|
  A1 Sometimes|Never|Sometimes|Never|Sometimes|Never|Sometimes|Never|
  A01 Sometimes|Never|Sometimes|Never|Sometimes|Never|Sometimes|Never|
  A2 Sometimes|Never|Sometimes|Never|Sometimes|Never|Sometimes|Never|
  A3 Sometimes|Never|Sometimes|Never|Sometimes|Never|Sometimes|Never|
  A4 Sometimes|Never|Sometimes|Never|Sometimes|Never|Sometimes|Never|
  A5 Sometimes|Never|Sometimes|Never|Sometimes|Never|Sometimes|Never|
  A6 Sometimes|Never|Sometimes|Never|Sometimes|Never|Sometimes|Never|

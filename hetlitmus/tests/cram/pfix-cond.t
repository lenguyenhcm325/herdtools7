Condition-compiler guard: the emitted condition must NEVER silently drop or
vacuously satisfy a [x]=N (Location_global) atom -- a dropped half decides the
test on the register half alone, and a constant-true one decides it on nothing.
The compiler decides such an atom by the per-frame read-buffer scan plus, for a
coherence-final [ell]=v atom, a per-run observer ws witness: the register pass
marks the atom `1 /* [ell] via observer _loc */` and the location is tracked by
the _loc cycle over the _ws_<ell>_<c|g> observer scans.  We emit the four
representative shapes and assert every location atom keeps its [ ] label and is
tracked by an observer cycle.

(Every het test co-runs at least the Layer-B canary, so the test under study
carries the instance prefix `t_' -- `_loc' is `_t_loc' and `_ws_y_c' is
`t__ws_y_c'.  The patterns below are pinned to the exact cycle structure,
because a check loosened to `_loc' would pass on any observer cycle at all --
including one for the wrong instance.)

2+2W -- pure-location [x]=2 /\ [y]=2: both halves are labelled [x]/[y] and both
are tracked by the same-observer-thread _loc cycle over _ws_x/_ws_y.
  $ litmus7 -gpu-target cuda -o . ../het/2+2W-cg-sys-fence.litmus >/dev/null 2>&1
  $ grep -hE 'static const char\* _labels' 2+2W-cg-sys-fence/2+2W-cg-sys-fence.cu
  static const char* _labels[2] = { "[x]", "[y]" };
  $ grep -c 'int _t_loc = ((t__ws_x_c && t__ws_y_c) || (t__ws_x_g && t__ws_y_g))' 2+2W-cg-sys-fence/2+2W-cg-sys-fence.cu
  1

R -- mixed 1:r0=0 /\ [y]=2: register half decodes through its buffer, the [y]
half is tracked by the _loc observer cycle.
  $ litmus7 -gpu-target cuda -o . ../het/R-cg-sys-fence.litmus >/dev/null 2>&1
  $ grep -hE 'static const char\* _labels' R-cg-sys-fence/R-cg-sys-fence.cu
  static const char* _labels[2] = { "1:r0", "[y]" };
  $ grep -c 'int _t_loc = (t__ws_y_c || t__ws_y_g)' R-cg-sys-fence/R-cg-sys-fence.cu
  1

S -- mixed 1:r0=1 /\ [x]=2: mirror of R, [x] tracked by _loc, register half
decodes rf through its tag buffer.
  $ litmus7 -gpu-target cuda -o . ../het/S-cg-sys-fence.litmus >/dev/null 2>&1
  $ grep -hE 'static const char\* _labels' S-cg-sys-fence/S-cg-sys-fence.cu
  static const char* _labels[2] = { "1:r0", "[x]" };
  $ grep -c 'int _t_loc = (t__ws_x_c || t__ws_x_g)' S-cg-sys-fence/S-cg-sys-fence.cu
  1

MP -- pure-register control: no Location_global atom, so no [ ] label, no
observer _loc cycle; the recovery decodes both reads (rf + fr).  The negative
matches BOTH spellings, prefixed and bare: pinned to a bare `_loc' alone it would
report 0 for free, since the emitted name is `_t_loc' -- a guard that has stopped
guarding.
  $ litmus7 -gpu-target cuda -o . ../het/MP-cg-sys-acqrel-2s.litmus >/dev/null 2>&1
  $ grep -hE 'static const char\* _labels' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  static const char* _labels[2] = { "1:r0", "1:r1" };
  $ grep -cE 'int _(t_|mu_|can_)?loc =' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu || true
  0

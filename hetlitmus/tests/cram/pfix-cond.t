Task P (7a/7b) regression guard, updated for B3: the Tier-2 condition compiler
must never silently drop or vacuously satisfy a [x]=N (Location_global) atom.
Before the P-fix, 2+2W's condition was the constant-true `(1 && 1)` and R/S
dropped their location half.  B3 replaced the post-join `_cond(o)` with the
per-frame read-buffer recovery scan (`int _weak = ...`); a location atom is now a
compile-visible HET_PENDING marker (a real, non-vacuous placeholder the observer
commit decodes), a register atom decodes through its tag buffer.  We emit the four
representative shapes and assert: (i) the [ ] labels are still produced (P-fix), and
(ii) every location atom is a HET_PENDING marker -- never constant-true, never the
old HET_UNCONVERTIBLE.

2+2W -- pure-location [x]=2 /\ [y]=2: both halves are HET_PENDING markers (2),
labelled [x] and [y]; the recovery _weak is present (not constant-true).
  $ litmus7 -o . ../het/2+2W-cg-sys-fence.litmus >/dev/null 2>&1
  $ grep -hE 'static const char\* _labels' 2+2W-cg-sys-fence/2+2W-cg-sys-fence.cu
  static const char* _labels[2] = { "[x]", "[y]" };
  $ grep -c 'int _weak =' 2+2W-cg-sys-fence/2+2W-cg-sys-fence.cu
  1
  $ grep -o 'HET_PENDING /\* \[' 2+2W-cg-sys-fence/2+2W-cg-sys-fence.cu | wc -l
  2

R -- mixed 1:r0=0 /\ [y]=2: register half decodes through its buffer, the [y]
half is one HET_PENDING marker (was silently dropped pre-fix), labelled [y].
  $ litmus7 -o . ../het/R-cg-sys-fence.litmus >/dev/null 2>&1
  $ grep -hE 'static const char\* _labels' R-cg-sys-fence/R-cg-sys-fence.cu
  static const char* _labels[2] = { "1:r0", "[y]" };
  $ grep -c 'HET_PENDING /\* \[' R-cg-sys-fence/R-cg-sys-fence.cu
  1

S -- mixed 1:r0=1 /\ [x]=2: mirror of R, [x] half is one HET_PENDING marker,
the register half decodes rf through its tag buffer.
  $ litmus7 -o . ../het/S-cg-sys-fence.litmus >/dev/null 2>&1
  $ grep -hE 'static const char\* _labels' S-cg-sys-fence/S-cg-sys-fence.cu
  static const char* _labels[2] = { "1:r0", "[x]" };
  $ grep -c 'HET_PENDING /\* \[' S-cg-sys-fence/S-cg-sys-fence.cu
  1

MP -- pure-register control: no Location_global atom, so no [ ] label and no
HET_PENDING location marker appear; the recovery decodes both reads (rf + fr).
  $ litmus7 -o . ../het/MP-cg-sys-acqrel-2s.litmus >/dev/null 2>&1
  $ grep -hE 'static const char\* _labels' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  static const char* _labels[2] = { "1:r0", "1:r1" };
  $ grep -c 'HET_PENDING /\* \[' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu || true
  0

No emitted recovery is ever the old constant-true `_cond`, and no location atom
degrades to the old HET_UNCONVERTIBLE marker, across the corpus path above.
  $ grep -rlE 'static int _cond|HET_UNCONVERTIBLE|unsupported atom' */*.cu
  [1]

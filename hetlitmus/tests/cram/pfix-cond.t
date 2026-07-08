Task P (7a/7b) regression guard: the Tier-2 condition compiler must never
silently drop or vacuously satisfy a [x]=N (Location_global) atom.  We emit the
four representative shapes through litmus7 (het emission needs no -set-libdir)
and read the generated _labels / _cond.  Before the fix, 2+2W's _cond was the
constant-true `(1 && 1)` and R/S dropped their location half.

2+2W -- pure-location condition [x]=2 /\ [y]=2: BOTH halves are real final-memory
reads o[0]/o[1] (never the old constant-true), labelled [x] and [y].
  $ litmus7 -o . ../het/2+2W-cg-sys-fence.litmus >/dev/null 2>&1
  $ grep -hE 'static const char\* _labels|static int _cond' 2+2W-cg-sys-fence/2+2W-cg-sys-fence.cu
  static const char* _labels[2] = { "[x]", "[y]" };
  static int _cond(intmax_t* o){ (void)o; return ((o[0] == 2) && (o[1] == 2)); }

R -- mixed 1:r0=0 /\ [y]=2: the register half stays o[0], the [y] half is now a
real read o[1] (was silently dropped), labelled [y].
  $ litmus7 -o . ../het/R-cg-sys-fence.litmus >/dev/null 2>&1
  $ grep -hE 'static const char\* _labels|static int _cond' R-cg-sys-fence/R-cg-sys-fence.cu
  static const char* _labels[2] = { "1:r0", "[y]" };
  static int _cond(intmax_t* o){ (void)o; return ((o[0] == 0) && (o[1] == 2)); }

S -- mixed 1:r0=1 /\ [x]=2: mirror of R, [x] half recovered as o[1].
  $ litmus7 -o . ../het/S-cg-sys-fence.litmus >/dev/null 2>&1
  $ grep -hE 'static const char\* _labels|static int _cond' S-cg-sys-fence/S-cg-sys-fence.cu
  static const char* _labels[2] = { "1:r0", "[x]" };
  static int _cond(intmax_t* o){ (void)o; return ((o[0] == 1) && (o[1] == 2)); }

MP -- pure-register control: no Location_global atom, so no [ ] label and no
final-memory read appear; byte-identical to pre-fix output.
  $ litmus7 -o . ../het/MP-cg-sys-acqrel-2s.litmus >/dev/null 2>&1
  $ grep -hE 'static const char\* _labels|static int _cond' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  static const char* _labels[2] = { "1:r0", "1:r1" };
  static int _cond(intmax_t* o){ (void)o; return ((o[0] == 1) && (o[1] == 0)); }

No emitted _cond is ever constant-true or contains an unsupported/unconvertible
location marker across the whole corpus path exercised above.
  $ grep -rl 'HET_UNCONVERTIBLE\|unsupported atom' */*.cu
  [1]

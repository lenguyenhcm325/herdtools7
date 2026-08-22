Condition-compiler guard: the emitted condition must NEVER silently drop or
vacuously satisfy a [x]=N (Location_global) atom -- a dropped half decides the
test on the register half alone, and a constant-true one decides it on nothing.
Every atom of the condition is one outcome column: a register's is its read
buffer at _n, a location's is that location's own slot n, and the detector reads
the same vector the histogram is fed.  We emit the four representative shapes and
assert every location atom keeps its [ ] label and is read out of its slot.

(The patterns below are pinned to the exact column index, because a check
loosened to `_o[' alone would pass on any outcome column at all.)

2+2W -- pure-location [x]=2 /\ [y]=2: both halves are labelled [x]/[y], both are
read out of their own slot, and both are compared in the detector.
  $ litmus7 -gpu-target cuda -o . ../het/2+2W-cg-sys-fence.litmus >/dev/null 2>&1
  $ grep -hE 'static const char\* _labels' 2+2W-cg-sys-fence/2+2W-cg-sys-fence.cu
  static const char* _labels[2] = { "[x]", "[y]" };
  $ grep -c '_o\[0\] = (intmax_t)x\[(size_t)_n\*HET_SLOT_STRIDE_WORDS\];' 2+2W-cg-sys-fence/2+2W-cg-sys-fence.cu
  1
  $ grep -c '_o\[1\] = (intmax_t)y\[(size_t)_n\*HET_SLOT_STRIDE_WORDS\];' 2+2W-cg-sys-fence/2+2W-cg-sys-fence.cu
  1
  $ grep -c 'int _weak = ((_o\[0\] == 2) && (_o\[1\] == 2));' 2+2W-cg-sys-fence/2+2W-cg-sys-fence.cu
  1

R -- mixed 1:r0=0 /\ [y]=2: the register half is its read buffer at _n, the [y]
half is y's own slot n, and both are in the detector.
  $ litmus7 -gpu-target cuda -o . ../het/R-cg-sys-fence.litmus >/dev/null 2>&1
  $ grep -hE 'static const char\* _labels' R-cg-sys-fence/R-cg-sys-fence.cu
  static const char* _labels[2] = { "1:r0", "[y]" };
  $ grep -c '_o\[0\] = (intmax_t)bufP1_0_h\[_n\];' R-cg-sys-fence/R-cg-sys-fence.cu
  1
  $ grep -c '_o\[1\] = (intmax_t)y\[(size_t)_n\*HET_SLOT_STRIDE_WORDS\];' R-cg-sys-fence/R-cg-sys-fence.cu
  1
  $ grep -c 'int _weak = ((_o\[0\] == 0) && (_o\[1\] == 2));' R-cg-sys-fence/R-cg-sys-fence.cu
  1

S -- mixed 1:r0=1 /\ [x]=2: the mirror of R, on x.
  $ litmus7 -gpu-target cuda -o . ../het/S-cg-sys-fence.litmus >/dev/null 2>&1
  $ grep -hE 'static const char\* _labels' S-cg-sys-fence/S-cg-sys-fence.cu
  static const char* _labels[2] = { "1:r0", "[x]" };
  $ grep -c '_o\[1\] = (intmax_t)x\[(size_t)_n\*HET_SLOT_STRIDE_WORDS\];' S-cg-sys-fence/S-cg-sys-fence.cu
  1
  $ grep -c 'int _weak = ((_o\[0\] == 1) && (_o\[1\] == 2));' S-cg-sys-fence/S-cg-sys-fence.cu
  1

MP -- pure-register control: no Location_global atom, so no [ ] label and no slot
read among the outcome columns; both halves come from read buffers.  The three
shapes above emit the slot read this negative looks for, so a 0 here is a real
absence rather than a pattern that matches nothing anywhere.
  $ litmus7 -gpu-target cuda -o . ../het/MP-cg-sys-acqrel-2s.litmus >/dev/null 2>&1
  $ grep -hE 'static const char\* _labels' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  static const char* _labels[2] = { "1:r0", "1:r1" };
  $ grep -c 'HET_SLOT_STRIDE_WORDS\];' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu || true
  0

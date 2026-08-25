Condition-compiler guard (hetlitmus/docs/het-emission.md).

The emitted condition must NEVER silently drop or vacuously satisfy a [x]=N
(Location_global) atom; each pattern is pinned to its exact column index.

2+2W -- pure-location [x]=2 /\ [y]=2: both halves keep their label, are read out
of their own slot, and are compared in the detector.
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

MP -- pure-register control: no Location_global atom, so no [ ] label and no
slot read; the two shapes above emit that read when it is owed.
  $ litmus7 -gpu-target cuda -o . ../het/MP-cg-sys-acqrel-2s.litmus >/dev/null 2>&1
  $ grep -hE 'static const char\* _labels' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
  static const char* _labels[2] = { "1:r0", "1:r1" };
  $ grep -c 'HET_SLOT_STRIDE_WORDS\];' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu || true
  0

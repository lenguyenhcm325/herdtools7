Condition-compiler guard.

2+2W: both [x]=2 and [y]=2 are read from their slots and compared.
  $ litmus7 -gpu-target cuda -o . ../het/2+2W-cg-sys-plain.fsc.litmus >/dev/null 2>&1
  $ grep -hE 'static const char\* _labels' 2+2W-cg-sys-plain.fsc/2+2W-cg-sys-plain.fsc.cu
  static const char* _labels[2] = { "[x]", "[y]" };
  $ grep -c '_o\[0\] = (intmax_t)x\[(size_t)_n\*HET_SLOT_STRIDE_WORDS\];' 2+2W-cg-sys-plain.fsc/2+2W-cg-sys-plain.fsc.cu
  1
  $ grep -c '_o\[1\] = (intmax_t)y\[(size_t)_n\*HET_SLOT_STRIDE_WORDS\];' 2+2W-cg-sys-plain.fsc/2+2W-cg-sys-plain.fsc.cu
  1
  $ grep -c 'int _weak = ((_o\[0\] == 2) && (_o\[1\] == 2));' 2+2W-cg-sys-plain.fsc/2+2W-cg-sys-plain.fsc.cu
  1

R: a register atom reads its buffer, a location atom its slot.
  $ litmus7 -gpu-target cuda -o . ../het/R-cg-sys-plain.fsc.litmus >/dev/null 2>&1
  $ grep -hE 'static const char\* _labels' R-cg-sys-plain.fsc/R-cg-sys-plain.fsc.cu
  static const char* _labels[2] = { "1:r0", "[y]" };
  $ grep -c '_o\[0\] = (intmax_t)bufP1_0_h\[_n\];' R-cg-sys-plain.fsc/R-cg-sys-plain.fsc.cu
  1
  $ grep -c '_o\[1\] = (intmax_t)y\[(size_t)_n\*HET_SLOT_STRIDE_WORDS\];' R-cg-sys-plain.fsc/R-cg-sys-plain.fsc.cu
  1
  $ grep -c 'int _weak = ((_o\[0\] == 0) && (_o\[1\] == 2));' R-cg-sys-plain.fsc/R-cg-sys-plain.fsc.cu
  1

MP: no location atom, so no slot read.
  $ litmus7 -gpu-target cuda -o . ../het/MP-cg-sys-ra.acq.litmus >/dev/null 2>&1
  $ grep -hE 'static const char\* _labels' MP-cg-sys-ra.acq/MP-cg-sys-ra.acq.cu
  static const char* _labels[2] = { "1:r0", "1:r1" };
  $ grep -c 'HET_SLOT_STRIDE_WORDS\];' MP-cg-sys-ra.acq/MP-cg-sys-ra.acq.cu || true
  0

Slot + readout guard.  Every shared location of a het harness is SIZE_OF_TEST
slots wide, iteration _n touches slot _n alone, and the readout reads iteration
_n's outcome back out of slot _n -- one pass, no search.  The standalone GPU-only
path is unchanged: one word per location, no slots and no record.

The slot layout ships with the harness and is what every address is offset by.
  $ litmus7 -gpu-target cuda -o . ../het/MP-cg-sys-relaxed.litmus >/dev/null 2>&1
  $ grep -c '#define HET_SLOT_STRIDE_WORDS 16' MP-cg-sys-relaxed/het_rdv.h
  1
  $ grep -c '#include "het_rdv.h"' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  1
  $ grep -c 'int \*x; gd_alloc_shared((void\*\*)&x, sizeof(int)\*SIZE_OF_TEST\*HET_SLOT_STRIDE_WORDS);' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  1

The per-run reset clears every slot, which is also what first-touches the pages
the run is about to race on; clearing the first word alone would leave iteration
1 onwards reading whatever the last run left.
  $ grep -c 'memset(x, 0, sizeof(int)\*SIZE_OF_TEST\*HET_SLOT_STRIDE_WORDS);' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  1

NPART counts the participants and nothing else: this test's 2 procs, one GPU
lane and one CPU thread.  Pin the total and the two lane counts beside it, so a
wrong participant count cannot hide inside a plausible number.
  $ grep -c '#define NPART 2' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  1
  $ grep -E '^#define HET_(TEST_BLOCKS|GPU_LANES)' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  #define HET_TEST_BLOCKS 1
  #define HET_GPU_LANES 1
  $ grep -cE '^static void\* cpu_[A-Za-z_0-9]+\(void\* _a\)' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  1

The GPU lane addresses iteration _n's own slot; the CPU body is litmus7's own and
addresses a bare pointer, so its CALLER does the addressing.
  $ grep -c 'cuda::atomic_ref<int, cuda::thread_scope_system> ref(\*(y + (_n)\*HET_SLOT_STRIDE_WORDS));' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  1
  $ grep -c 'size_t _slot = (size_t)_n \* HET_SLOT_STRIDE_WORDS;' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  1
  $ grep -c 'het_run_P0(a->x + _slot,a->y + _slot);' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  1
  $ grep -c '#START _litmus_P0' MP-cg-sys-relaxed/MP-cg-sys-relaxed_cpu.c
  1

The readout: one pass over the slots, every iteration scored, the outcome vector
read from slot _n and fed to the histogram exactly once.  A second
add_outcome_outs call site would count one observation twice.
  $ grep -c '_rec.iters_scored++;' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  1
  $ grep -c 'add_outcome_outs(' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  1
  $ sed -n '/for (int _n=0; _n<SIZE_OF_TEST; ++_n) {/,/^    }$/p' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu | grep -c 'add_outcome_outs('
  1

EVERY outcome column prints a NUMBER, in ONE loop over all of them: a location's
value is read out of its slot like any register's, so the printer has one arm and
no column it prints a placeholder for.  The whole callback is pinned, on the
shape whose every column is a location.
  $ litmus7 -gpu-target cuda -o . ../het/2+2W-cg-sys-fence.litmus >/dev/null 2>&1
  $ grep -hE 'static const char\* _labels' 2+2W-cg-sys-fence/2+2W-cg-sys-fence.cu
  static const char* _labels[2] = { "[x]", "[y]" };
  $ sed -n '/^static void _dump_one/,/^}$/p' 2+2W-cg-sys-fence/2+2W-cg-sys-fence.cu
  static void _dump_one(FILE* _ch, intmax_t* o, count_t c, int show){
    fprintf(_ch, "%-8" PRIu64 "%c> ", c, show ? '*' : ' ');
    for (int i=0;i<2;i++) fprintf(_ch, "%s=%" PRIdMAX "; ", _labels[i], o[i]);
    fprintf(_ch, "\n");
  }
  $ grep -c '_o\[0\] = (intmax_t)x\[(size_t)_n\*HET_SLOT_STRIDE_WORDS\];' 2+2W-cg-sys-fence/2+2W-cg-sys-fence.cu
  1

A register column is its read buffer at _n, and the buffer carries the value the
load returned -- no decoding, so a condition value is compared as the .litmus
writes it.
  $ grep -c 'int _weak = ((_o\[0\] == 1) && (_o\[1\] == 0));' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  1
  $ grep -c '_o\[0\] = (intmax_t)bufP1_0_h\[_n\];' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  1

The one-outcome evidence the degeneracy guard reads is written by the readout
itself: without it every cell would look like a constant read.
  $ grep -c '_rec.outcomes_vary = 1;' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  1

The same readout on the shapes that used to need a frame search: SB (two reads,
neither an rf anchor) and R (an fr-against-init read plus a location).  One pass
each, and one histogram call each.
  $ litmus7 -gpu-target cuda -o . ../het/SB-cg-sys-acqrel-2s.litmus >/dev/null 2>&1
  $ grep -c 'add_outcome_outs(' SB-cg-sys-acqrel-2s/SB-cg-sys-acqrel-2s.cu
  1
  $ grep -c 'for (int _n=0; _n<SIZE_OF_TEST; ++_n) {' SB-cg-sys-acqrel-2s/SB-cg-sys-acqrel-2s.cu
  3
  $ litmus7 -gpu-target cuda -o . ../het/R-cg-sys-fence.litmus >/dev/null 2>&1
  $ grep -hE 'static const char\* _labels' R-cg-sys-fence/R-cg-sys-fence.cu
  static const char* _labels[2] = { "1:r0", "[y]" };
  $ grep -c 'add_outcome_outs(' R-cg-sys-fence/R-cg-sys-fence.cu
  1

LDAPR is RCpc (ARMv8.3), and litmus7 lowers a two-sided test's acquire read to
it.  Neither native gcc on the host nor `clang --target=aarch64-linux-gnu'
accepts one at the default architecture, so the emitted build files carry the
flag on EVERY compilation of <t>_cpu.c or every -2s test fails to ASSEMBLE.
  $ litmus7 -gpu-target cuda -o . ../het/CoRR-cg-sys-acqrel-2s.litmus >/dev/null 2>&1
  $ grep -c 'ldapr ' CoRR-cg-sys-acqrel-2s/CoRR-cg-sys-acqrel-2s_cpu.c
  2
  $ grep -c 'HET_CPU_CFLAGS="${HET_CPU_CFLAGS:--march=armv8.3-a}"' CoRR-cg-sys-acqrel-2s/comp.sh
  1
  $ grep -c 'clang --target=aarch64-linux-gnu -std=gnu11 $HET_CPU_CFLAGS -c' CoRR-cg-sys-acqrel-2s/comp.sh
  1
  $ grep -c 'HET_CPU_CFLAGS ?= -march=armv8.3-a' CoRR-cg-sys-acqrel-2s/Makefile
  1
  $ grep -c '$(CC) $(HET_HOST_CFLAGS) -c $< -o $@' CoRR-cg-sys-acqrel-2s/Makefile
  1

...and the HOST object takes them only on a native host: elsewhere gcc compiles
the portable shim, and another ISA's flags are not its to take -- a compile-only
build of an AArch64 harness has to succeed on an x86_64 box.
  $ grep -c 'if \[ "$(uname -m)" = "$HET_HOST_ISA" \]; then HET_HOST_CFLAGS="$HET_CPU_CFLAGS"; fi' CoRR-cg-sys-acqrel-2s/comp.sh
  1
  $ grep -c 'HET_HOST_CFLAGS := $(if $(filter $(HET_HOST_ISA),$(shell uname -m)),$(HET_CPU_CFLAGS))' CoRR-cg-sys-acqrel-2s/Makefile
  1

The x86_64 pair owes no extension flag, and the variable is still there: an empty
default is a flag list, not a missing one.
  $ litmus7 -gpu-target hip -o . ../het-x86/MP-cg-sys-relaxed-x86_64.litmus >/dev/null 2>&1
  $ grep -c 'HET_CPU_CFLAGS="${HET_CPU_CFLAGS:-}"' MP-cg-sys-relaxed-x86_64/comp.sh
  1

REFUSAL: the emitted weak-behaviour detector may never be a constant.  A
constant-true one reports the weak behaviour on every run and a constant-false
one reports "Never" on every run, so the emitter refuses rather than emit one --
exit 3, with nothing written.
  $ cat > const-detector.litmus <<'EOF'
  > Het CONST-DETECTOR
  > "a condition no proc can decide"
  > {
  > 0:X1=x;
  > }
  >  P0:cpu       | P1:gpu             ;
  >  MOV W0,#1    | w[relaxed,sys] x 1 ;
  >  STR W0,[X1]  |                    ;
  > scopes: (sys (gpu (cta P1)))
  > exists ([q]=1)
  > EOF
  $ litmus7 -gpu-target cuda -o . const-detector.litmus 2>&1 | grep -c 'HetLitmus REFUSED'
  1
  $ litmus7 -gpu-target cuda -o . const-detector.litmus >/dev/null 2>&1
  [3]
  $ test -d CONST-DETECTOR && echo "a refusal left a harness behind" || echo "nothing written"
  nothing written

The standalone GPU-only path is untouched by any of it: plain int atomic_ref on
one word per location, no slots, no record, no readout.
  $ litmus7 -gpu-target cuda -o . ../gpu-only/MP-sys-acquire.litmus >/dev/null 2>&1
  $ grep -q 'atomic_ref<int' MP-sys-acquire.cu && echo "gpu-only uses plain int"
  gpu-only uses plain int
  $ grep -cE 'HET_SLOT_STRIDE_WORDS|het_obs_record|iters_scored' MP-sys-acquire.cu || true
  0

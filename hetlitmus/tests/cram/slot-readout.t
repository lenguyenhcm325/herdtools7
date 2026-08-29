Slot + readout guard (hetlitmus/docs/00-environment-design.md sec 3.3;
hetlitmus/docs/het-emission.md).

The slot layout ships with the harness and is what every address is offset by:
one 128 B line per slot, so two iterations share neither a word nor a line.
  $ litmus7 -gpu-target cuda -o . ../het/MP-cg-sys-relaxed.litmus >/dev/null 2>&1
  $ grep -c '#define HET_SLOT_STRIDE_WORDS 32' MP-cg-sys-relaxed/het_rdv.h
  1
  $ grep -c '#include "het_rdv.h"' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  1
  $ grep -c 'int \*x; gd_alloc_shared((void\*\*)&x, sizeof(int)\*SIZE_OF_TEST\*HET_SLOT_STRIDE_WORDS);' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  1

The per-run reset clears every slot, which is also what first-touches the pages
the run is about to race on.
  $ grep -c 'memset(x, 0, sizeof(int)\*SIZE_OF_TEST\*HET_SLOT_STRIDE_WORDS);' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  1

NPART counts the participants and nothing else, so the total is pinned beside
the two lane counts a wrong participant count could hide inside.
  $ grep -c '#define NPART 2' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  1
  $ grep -E '^#define HET_(TEST_BLOCKS|GPU_LANES)' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  #define HET_TEST_BLOCKS 1
  #define HET_GPU_LANES 1
  $ grep -cE '^static void\* cpu_[A-Za-z_0-9]+\(void\* _a\)' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  1

The GPU lane addresses iteration _n's own slot; the CPU body is litmus7's own
and addresses a bare pointer, so its CALLER does the addressing.
  $ grep -c 'cuda::atomic_ref<int, cuda::thread_scope_system> ref(\*(y + (_n)\*HET_SLOT_STRIDE_WORDS));' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  1
  $ grep -c 'size_t _slot = (size_t)_n \* HET_SLOT_STRIDE_WORDS;' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  1
  $ grep -c 'het_run_P0(a->x + _slot,a->y + _slot);' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  1
  $ grep -c '#START _litmus_P0' MP-cg-sys-relaxed/MP-cg-sys-relaxed_cpu.c
  1

The readout is one pass over the slots: every iteration scored, the outcome
vector read from slot _n and fed to the histogram exactly once.
  $ grep -c '_rec.iters_scored++;' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  1
  $ grep -c 'add_outcome_outs(' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  1
  $ sed -n '/for (int _n=0; _n<SIZE_OF_TEST; ++_n) {/,/^    }$/p' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu | grep -c 'add_outcome_outs('
  1

Every outcome column prints a NUMBER, in one loop over all of them, pinned here
on the shape whose every column is a location.
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

A register column is its read buffer at _n, carrying the value the load
returned, so a condition value is compared as the .litmus writes it.
  $ grep -c 'int _weak = ((_o\[0\] == 1) && (_o\[1\] == 0));' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  1
  $ grep -c '_o\[0\] = (intmax_t)bufP1_0_h\[_n\];' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  1

The one-outcome evidence the degeneracy guard reads is written by the readout
itself.
  $ grep -c '_rec.outcomes_vary = 1;' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  1

One flag buffer per participant, one byte per iteration, each written by the
side that owns it and the GPU's mirrored back for the readout.
  $ grep -c 'uint8_t \*_rdvG_P1; gd_alloc_dev((void\*\*)&_rdvG_P1, sizeof(uint8_t)\*SIZE_OF_TEST, "_rdvG_P1");' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  1
  $ grep -c 'uint8_t \*_rdvC_P0 = (uint8_t\*)malloc_check(sizeof(uint8_t)\*SIZE_OF_TEST);' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  1
  $ grep -c 'cudaMemcpy(_rdvG_P1_h, _rdvG_P1, sizeof(uint8_t)\*SIZE_OF_TEST, cudaMemcpyDeviceToHost);' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  1

The readout ANDs the flags before it reads a single slot: an iteration only one
side started is DISCARDED, and rdv_valid says the readout ran at all.
  $ sed -n '/for (int _n=0; _n<SIZE_OF_TEST; ++_n) {/,/^    }$/p' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu | sed -n '/int _ok = 1;/,/_rec.iters_scored++;/p'
        int _ok = 1;
        if (!_rdvC_P0[_n]) { _ok = 0; _rec.rdv_cap_cpu++; }
        if (!_rdvG_P1_h[_n]) { _ok = 0; _rec.rdv_cap_gpu++; }
        if (!_ok) { _rec.iters_discarded++; continue; }
        _rec.iters_scored++;
  $ grep -c '_rec.rdv_valid = 1;' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  1

...and the run says on stderr what the rendezvous cost it, beside the caps it
waited under and whether those caps are a measurement at all.
  $ grep -c 'HetLitmus rendezvous: scored=%llu discarded=%llu (cap_cpu=%llu cap_gpu=%llu) caps=%lu/%u jitter=%d discard_max=%d%% %s' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  1
  $ grep -c 'HET_CAP_CALIBRATED ? "caps calibrated" : "caps UNCALIBRATED"' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  1

Both caps are read from the environment at run time, so a box is re-capped
without a rebuild.
  $ grep -c 'het_env_long("HET_CAP_CPU", (long)HET_CAP_CPU)' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  1
  $ grep -c 'het_env_long("HET_CAP_GPU", (long)HET_CAP_GPU)' MP-cg-sys-relaxed/MP-cg-sys-relaxed.cu
  1

A label column names a register and a location in the same vector.
  $ litmus7 -gpu-target cuda -o . ../het/R-cg-sys-fence.litmus >/dev/null 2>&1
  $ grep -hE 'static const char\* _labels' R-cg-sys-fence/R-cg-sys-fence.cu
  static const char* _labels[2] = { "1:r0", "[y]" };

LDAPR is RCpc (ARMv8.3), so the emitted build files carry the flag on every
compilation of <t>_cpu.c or every -2s test fails to ASSEMBLE.
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

The Makefile hands those flags to the host object only where `uname -m` is this
render's own ISA.
  $ grep -c 'HET_HOST_CFLAGS := $(if $(filter aarch64,$(shell uname -m)),$(HET_CPU_CFLAGS))' CoRR-cg-sys-acqrel-2s/Makefile
  1

Each render's CPU file compiles for its own ISA only: the #else branch is an
#error naming that ISA, and off its host comp.sh cross-assembles the file.
  $ grep -c '#error "CoRR-cg-sys-acqrel-2s_cpu.c carries AArch64 asm and compiles only where uname -m is aarch64; cross-assemble it elsewhere with clang --target=aarch64-linux-gnu"' CoRR-cg-sys-acqrel-2s/CoRR-cg-sys-acqrel-2s_cpu.c
  1

The x86_64 pair owes no extension flag, and the variable is still there: an
empty default is a flag list, not a missing one.
  $ litmus7 -gpu-target hip -o . ../het-x86/MP-cg-sys-relaxed-x86_64.litmus >/dev/null 2>&1
  $ grep -c 'HET_CPU_CFLAGS="${HET_CPU_CFLAGS:-}"' MP-cg-sys-relaxed-x86_64/comp.sh
  1
  $ grep -c '#error "MP-cg-sys-relaxed-x86_64_cpu.c carries X86_64 asm and compiles only where uname -m is x86_64; cross-assemble it elsewhere with clang --target=x86_64-linux-gnu"' MP-cg-sys-relaxed-x86_64/MP-cg-sys-relaxed-x86_64_cpu.c
  1
  $ grep -c 'clang --target=x86_64-linux-gnu -std=gnu11 $HET_CPU_CFLAGS -c' MP-cg-sys-relaxed-x86_64/comp.sh
  1

REFUSAL (a): an atom no outcome column backs has no slot to read, so the
emitter refuses -- exit 3, with nothing written.
  $ cat > unbacked-loc.litmus <<'EOF'
  > Het UNBACKED-LOC
  > "a condition naming a location no proc touches"
  > {
  > 0:X1=x;
  > }
  >  P0:cpu       | P1:gpu             ;
  >  MOV W0,#1    | w[relaxed,sys] x 1 ;
  >  STR W0,[X1]  |                    ;
  > scopes: (sys (gpu (cta P1)))
  > exists ([q]=1)
  > EOF
  $ litmus7 -gpu-target cuda -o . unbacked-loc.litmus 2>&1 | grep -c 'but no proc of this test touches that location (no slot backs it)'
  1
  $ litmus7 -gpu-target cuda -o . unbacked-loc.litmus >/dev/null 2>&1
  [3]
  $ test -d UNBACKED-LOC && echo "a refusal left a harness behind" || echo "nothing written"
  nothing written

REFUSAL (b): a constant weak-behaviour detector reports the same verdict on
every run, so the emitter refuses that too, matched on the words only it prints.
  $ cat > const-true.litmus <<'EOF'
  > Het CONST-TRUE
  > "a condition that decides nothing, always true"
  > {
  > 0:X1=x;
  > }
  >  P0:cpu       | P1:gpu             ;
  >  MOV W0,#1    | w[relaxed,sys] x 1 ;
  >  STR W0,[X1]  |                    ;
  > scopes: (sys (gpu (cta P1)))
  > exists (true)
  > EOF
  $ litmus7 -gpu-target cuda -o . const-true.litmus 2>&1 | grep -c 'would emit a CONSTANT weak-behaviour detector (_weak = 1)'
  1
  $ litmus7 -gpu-target cuda -o . const-true.litmus >/dev/null 2>&1
  [3]
  $ cat > const-false.litmus <<'EOF'
  > Het CONST-FALSE
  > "a condition that decides nothing, always false"
  > {
  > 0:X1=x;
  > }
  >  P0:cpu       | P1:gpu             ;
  >  MOV W0,#1    | w[relaxed,sys] x 1 ;
  >  STR W0,[X1]  |                    ;
  > scopes: (sys (gpu (cta P1)))
  > exists (false)
  > EOF
  $ litmus7 -gpu-target cuda -o . const-false.litmus 2>&1 | grep -c 'would emit a CONSTANT weak-behaviour detector (_weak = 0)'
  1
  $ litmus7 -gpu-target cuda -o . const-false.litmus >/dev/null 2>&1
  [3]

The fold runs under `not' and `=>' as well, so a constant reached through either
is refused with the same two values.
  $ sed 's/CONST-TRUE/NOT-TRUE/; s/exists (true)/exists (not (true))/' const-true.litmus > not-true.litmus
  $ litmus7 -gpu-target cuda -o . not-true.litmus 2>&1 | grep -c 'would emit a CONSTANT weak-behaviour detector (_weak = 0)'
  1
  $ litmus7 -gpu-target cuda -o . not-true.litmus >/dev/null 2>&1
  [3]
  $ sed 's/CONST-FALSE/NOT-FALSE/; s/exists (false)/exists (not (false))/' const-false.litmus > not-false.litmus
  $ litmus7 -gpu-target cuda -o . not-false.litmus 2>&1 | grep -c 'would emit a CONSTANT weak-behaviour detector (_weak = 1)'
  1
  $ litmus7 -gpu-target cuda -o . not-false.litmus >/dev/null 2>&1
  [3]
  $ sed 's/CONST-TRUE/IMPL-CONST/; s/exists (true)/exists (true => false)/' const-true.litmus > impl-const.litmus
  $ litmus7 -gpu-target cuda -o . impl-const.litmus 2>&1 | grep -c 'would emit a CONSTANT weak-behaviour detector (_weak = 0)'
  1
  $ litmus7 -gpu-target cuda -o . impl-const.litmus >/dev/null 2>&1
  [3]
  $ ls -d CONST-TRUE CONST-FALSE NOT-TRUE NOT-FALSE IMPL-CONST 2>/dev/null | wc -l
  0

The standalone GPU-only path is untouched by any of it: plain int atomic_ref on
one word per location, no slots, no record, no readout.
  $ litmus7 -gpu-target cuda -o . ../gpu-only/MP-sys-acquire.litmus >/dev/null 2>&1
  $ grep -q 'atomic_ref<int' MP-sys-acquire.cu && echo "gpu-only uses plain int"
  gpu-only uses plain int
  $ grep -cE 'HET_SLOT_STRIDE_WORDS|het_obs_record|iters_scored' MP-sys-acquire.cu || true
  0

Slot + readout guard.

One 128 B line per slot.
  $ litmus7 -gpu-target cuda -o . ../het/MP-cg-sys-plain.rlx.litmus >/dev/null 2>&1
  $ grep -c '#define HET_SLOT_STRIDE_WORDS 32' MP-cg-sys-plain.rlx/het_rdv.h
  1
  $ grep -c '#include "het_rdv.h"' MP-cg-sys-plain.rlx/MP-cg-sys-plain.rlx.cu
  1
  $ grep -c 'int \*x; gd_alloc_shared((void\*\*)&x, sizeof(int)\*SIZE_OF_TEST\*HET_SLOT_STRIDE_WORDS);' MP-cg-sys-plain.rlx/MP-cg-sys-plain.rlx.cu
  1

The per-run reset clears every slot.
  $ grep -c 'memset(x, 0, sizeof(int)\*SIZE_OF_TEST\*HET_SLOT_STRIDE_WORDS);' MP-cg-sys-plain.rlx/MP-cg-sys-plain.rlx.cu
  1

The GPU lane addresses slot _n; the CPU body's caller does the addressing.
  $ grep -c 'cuda::atomic_ref<int, cuda::thread_scope_system> ref(\*(y + (_n)\*HET_SLOT_STRIDE_WORDS));' MP-cg-sys-plain.rlx/MP-cg-sys-plain.rlx.cu
  1
  $ grep -c 'size_t _slot = (size_t)_n \* HET_SLOT_STRIDE_WORDS;' MP-cg-sys-plain.rlx/MP-cg-sys-plain.rlx.cu
  1
  $ grep -c 'het_run_P0(a->x + _slot,a->y + _slot);' MP-cg-sys-plain.rlx/MP-cg-sys-plain.rlx.cu
  1
  $ grep -c '#START _litmus_P0' MP-cg-sys-plain.rlx/MP-cg-sys-plain.rlx_cpu.c
  1

A GPU lane carries its ops in column order, with order and scope.
  $ litmus7 -gpu-target cuda -o . ../het/R-cg-sys-plain.fsc.litmus >/dev/null 2>&1
  $ sed -n '/{ \/\/ w\[relaxed,sys\] y 2$/,/bufP1_0\[_n\] = r0;/p' R-cg-sys-plain.fsc/R-cg-sys-plain.fsc.cu
        { // w[relaxed,sys] y 2
          cuda::atomic_ref<int, cuda::thread_scope_system> ref(*(y + (_n)*HET_SLOT_STRIDE_WORDS));
          ref.store(2, cuda::memory_order_relaxed);
        }
        asm volatile("fence.sc.sys;" ::: "memory"); // sm_70+
        { // r[relaxed,sys] r0 x
          cuda::atomic_ref<int, cuda::thread_scope_system> ref(*(x + (_n)*HET_SLOT_STRIDE_WORDS));
          r0 = ref.load(cuda::memory_order_relaxed);
        }
        bufP1_0[_n] = r0;

Every outcome column prints a number.
  $ litmus7 -gpu-target cuda -o . ../het/2+2W-cg-sys-plain.fsc.litmus >/dev/null 2>&1
  $ sed -n '/^static void _dump_one/,/^}$/p' 2+2W-cg-sys-plain.fsc/2+2W-cg-sys-plain.fsc.cu
  static void _dump_one(FILE* _ch, intmax_t* o, count_t c, int show){
    fprintf(_ch, "%-8" PRIu64 "%c> ", c, show ? '*' : ' ');
    for (int i=0;i<2;i++) fprintf(_ch, "%s=%" PRIdMAX "; ", _labels[i], o[i]);
    fprintf(_ch, "\n");
  }

A register column is its read buffer at _n.
  $ grep -c 'int _weak = ((_o\[0\] == 1) && (_o\[1\] == 0));' MP-cg-sys-plain.rlx/MP-cg-sys-plain.rlx.cu
  1
  $ grep -c '_o\[0\] = (intmax_t)bufP1_0_h\[_n\];' MP-cg-sys-plain.rlx/MP-cg-sys-plain.rlx.cu
  1

Each thread records, per iteration, whether it reached the rendezvous before its cap.
  $ grep -c 'uint8_t \*_rdvG_P1; gd_alloc_dev((void\*\*)&_rdvG_P1, sizeof(uint8_t)\*SIZE_OF_TEST, "_rdvG_P1");' MP-cg-sys-plain.rlx/MP-cg-sys-plain.rlx.cu
  1
  $ grep -c 'uint8_t \*_rdvC_P0 = (uint8_t\*)malloc_check(sizeof(uint8_t)\*SIZE_OF_TEST);' MP-cg-sys-plain.rlx/MP-cg-sys-plain.rlx.cu
  1
  $ grep -c 'cudaMemcpy(_rdvG_P1_h, _rdvG_P1, sizeof(uint8_t)\*SIZE_OF_TEST, cudaMemcpyDeviceToHost);' MP-cg-sys-plain.rlx/MP-cg-sys-plain.rlx.cu
  1

The readout checks every flag before reading a slot.
  $ sed -n '/for (int _n=0; _n<SIZE_OF_TEST; ++_n) {/,/^    }$/p' MP-cg-sys-plain.rlx/MP-cg-sys-plain.rlx.cu | sed -n '/int _ok = 1;/,/_rec.iters_scored++;/p'
        int _ok = 1;
        if (!_rdvC_P0[_n]) { _ok = 0; _rec.rdv_cap_cpu++; }
        if (!_rdvG_P1_h[_n]) { _ok = 0; _rec.rdv_cap_gpu++; }
        if (!_ok) { _rec.iters_discarded++; continue; }
        _rec.iters_scored++;
  $ grep -c '_rec.rdv_valid = 1;' MP-cg-sys-plain.rlx/MP-cg-sys-plain.rlx.cu
  1

The run reports the rendezvous cost and its caps on stderr.
  $ grep -c 'HetLitmus rendezvous: scored=%llu discarded=%llu (cap_cpu=%llu cap_gpu=%llu) caps=%lu/%u jitter=%d discard_max=%d%% %s' MP-cg-sys-plain.rlx/MP-cg-sys-plain.rlx.cu
  1
  $ grep -c 'HET_CAP_CALIBRATED ? "caps calibrated" : "caps UNCALIBRATED"' MP-cg-sys-plain.rlx/MP-cg-sys-plain.rlx.cu
  1

Both caps are read from the environment at run time.
  $ grep -c 'het_env_long("HET_CAP_CPU", (long)HET_CAP_CPU)' MP-cg-sys-plain.rlx/MP-cg-sys-plain.rlx.cu
  1
  $ grep -c 'het_env_long("HET_CAP_GPU", (long)HET_CAP_GPU)' MP-cg-sys-plain.rlx/MP-cg-sys-plain.rlx.cu
  1

Every compilation of <t>_cpu.c carries the LDAPR flag.
  $ litmus7 -gpu-target cuda -o . ../het/CoRR-cg-sys-ra.rel.litmus >/dev/null 2>&1
  $ grep -c 'ldapr ' CoRR-cg-sys-ra.rel/CoRR-cg-sys-ra.rel_cpu.c
  2
  $ grep -c 'HET_CPU_CFLAGS="${HET_CPU_CFLAGS:--march=armv8.3-a}"' CoRR-cg-sys-ra.rel/comp.sh
  1
  $ grep -c 'clang --target=aarch64-linux-gnu -std=gnu11 $HET_CPU_CFLAGS -c' CoRR-cg-sys-ra.rel/comp.sh
  1
  $ grep -c 'HET_CPU_CFLAGS ?= -march=armv8.3-a' CoRR-cg-sys-ra.rel/Makefile
  1
  $ grep -c '$(CC) $(HET_HOST_CFLAGS) -c $< -o $@' CoRR-cg-sys-ra.rel/Makefile
  1

The Makefile passes those flags only on this render's own ISA.
  $ grep -c 'HET_HOST_CFLAGS := $(if $(filter aarch64,$(shell uname -m)),$(HET_CPU_CFLAGS))' CoRR-cg-sys-ra.rel/Makefile
  1

Each render's CPU file compiles for its own ISA only.
  $ grep -c '#error "CoRR-cg-sys-ra.rel_cpu.c carries AArch64 asm and compiles only where uname -m is aarch64; cross-assemble it elsewhere with clang --target=aarch64-linux-gnu"' CoRR-cg-sys-ra.rel/CoRR-cg-sys-ra.rel_cpu.c
  1

The x86_64 pair has an empty CPU flag default.
  $ litmus7 -gpu-target hip -o . ../het-x86_64/MP-cg-sys-plain.rlx-x86_64.litmus >/dev/null 2>&1
  $ grep -c 'HET_CPU_CFLAGS="${HET_CPU_CFLAGS:-}"' MP-cg-sys-plain.rlx-x86_64/comp.sh
  1
  $ grep -c '#error "MP-cg-sys-plain.rlx-x86_64_cpu.c carries X86_64 asm and compiles only where uname -m is x86_64; cross-assemble it elsewhere with clang --target=x86_64-linux-gnu"' MP-cg-sys-plain.rlx-x86_64/MP-cg-sys-plain.rlx-x86_64_cpu.c
  1
  $ grep -c 'clang --target=x86_64-linux-gnu -std=gnu11 $HET_CPU_CFLAGS -c' MP-cg-sys-plain.rlx-x86_64/comp.sh
  1

REFUSAL (a): an atom no outcome column backs is refused, exit 3.
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

REFUSAL (b): a constant weak-outcome detector is refused.
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

The constant fold also runs under `not' and `=>'.
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

The GPU-only path has no slots, record or readout.
  $ litmus7 -gpu-target cuda -o . ../gpu-only/MP-sys-acq.litmus >/dev/null 2>&1
  $ grep -q 'atomic_ref<int' MP-sys-acq.cu && echo "gpu-only uses plain int"
  gpu-only uses plain int
  $ grep -cE 'HET_SLOT_STRIDE_WORDS|het_obs_record|iters_scored' MP-sys-acq.cu || true
  0

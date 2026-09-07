Generated tests, verbatim: a change in hetgen7, diyone7, the diy backends or
grid.py's renderers shows here as a diff (hetlitmus/docs/corpus-grid.md).

A gpu-only LISA cell.
  $ cat ../gpu-only/MP-sys-rlx.litmus
  LISA MP-sys-rlx
  Generator=diyone7 (version 7.58+1)
  Scopes=(sys (gpu (cta 0) (cta 1)))
  Prefetch=0:x=F,0:y=W,1:y=F,1:x=T
  Com=Rf Fr
  Orig=PodWWRelaxedSysRelaxedSys RfeRelaxedSysRelaxedSys PodRRRelaxedSysRelaxedSys FreRelaxedSysRelaxedSys
  "PodWWRelaxedSysRelaxedSys RfeRelaxedSysRelaxedSys PodRRRelaxedSysRelaxedSys FreRelaxedSysRelaxedSys"
  {
  }
   P0                 | P1                  ;
   w[relaxed,sys] x 1 | r[relaxed,sys] r0 y ;
   w[relaxed,sys] y 1 | r[relaxed,sys] r1 x ;
  
  scopes: (sys (gpu (cta 0) (cta 1)))
  exists (1:r0=1 /\ 1:r1=0)

An AArch64 barrier against a GPU sc fence.
  $ cat ../het/MP-cg-sys-sy.fsc.litmus
  Het MP-cg-sys-sy.fsc
  "Heterogeneous MP-cg-sys-sy.fsc: per-proc device assignment cpu,gpu (cpu=AArch64, gpu=LISA)"
  {
  0:X1=x;
  0:X3=y;
  }
   P0:cpu      | P1:gpu              ;
   MOV W0,#1   | r[relaxed,sys] r0 y ;
   STR W0,[X1] | f[sc,sys]           ;
   DMB SY      | r[relaxed,sys] r1 x ;
   MOV W2,#1   |                     ;
   STR W2,[X3] |                     ;
  scopes: (sys (gpu (cta P1)))
  exists (1:r0=1 /\ 1:r1=0)

The same-location x86_64 MFence, spelled with the location letter s.
  $ cat ../het-x86_64/CoRR-cg-sys-mf.rlx-x86_64.litmus
  Het CoRR-cg-sys-mf.rlx-x86_64
  "Heterogeneous CoRR-cg-sys-mf.rlx-x86_64: per-proc device assignment cpu,gpu (cpu=x86_64, gpu=LISA)"
  {
  }
   P0:x86_64     | P1:gpu             ;
   movl (x),%eax | w[relaxed,sys] x 1 ;
   mfence        |                    ;
   movl (x),%ebx |                    ;
  scopes: (sys (gpu (cta P1)))
  exists (0:rax=1 /\ 0:rbx=0)

IRIW with two GPU procs, one writer and one reader, both sides annotated.
  $ cat ../het/IRIW-cggc-sys-ra.ra.litmus
  Het IRIW-cggc-sys-ra.ra
  "Heterogeneous IRIW-cggc-sys-ra.ra: per-proc device assignment cpu,gpu,gpu,cpu (cpu=AArch64, gpu=LISA)"
  {
  0:X0=x;
  0:X2=y;
  3:X0=x;
  }
   P0:cpu        | P1:gpu             | P2:gpu              | P3:cpu       ;
   LDAPR W1,[X0] | w[release,sys] y 1 | r[acquire,sys] r0 y | MOV W1,#1    ;
   LDAPR W3,[X2] |                    | r[acquire,sys] r1 x | STLR W1,[X0] ;
  scopes: (sys (gpu (cta P1) (cta P2)))
  exists (0:X1=1 /\ 0:X3=0 /\ 2:r0=1 /\ 2:r1=0)

An sc access on the GPU side.
  $ cat ../het/MP-cg-sys-plain.sc.litmus
  Het MP-cg-sys-plain.sc
  "Heterogeneous MP-cg-sys-plain.sc: per-proc device assignment cpu,gpu (cpu=AArch64, gpu=LISA)"
  {
  0:X1=x;
  0:X3=y;
  }
   P0:cpu      | P1:gpu         ;
   MOV W0,#1   | r[sc,sys] r0 y ;
   STR W0,[X1] | r[sc,sys] r1 x ;
   MOV W2,#1   |                ;
   STR W2,[X3] |                ;
  scopes: (sys (gpu (cta P1)))
  exists (1:r0=1 /\ 1:r1=0)

A three-proc cycle whose coherence atom pairs a CPU write with a GPU write.
  $ cat ../het/Z6.3-cgc-sys-plain.rlx.litmus
  Het Z6.3-cgc-sys-plain.rlx
  "Heterogeneous Z6.3-cgc-sys-plain.rlx: per-proc device assignment cpu,gpu,cpu (cpu=AArch64, gpu=LISA)"
  {
  0:X1=x;
  0:X3=y;
  2:X1=x;
  2:X4=z;
  }
   P0:cpu      | P1:gpu             | P2:cpu      ;
   MOV W0,#1   | w[relaxed,sys] y 2 | LDR W0,[X4] ;
   STR W0,[X1] | w[relaxed,sys] z 1 | LDR W2,[X1] ;
   MOV W2,#1   |                    |             ;
   STR W2,[X3] |                    |             ;
  scopes: (sys (gpu (cta P1)))
  exists (2:X0=1 /\ 2:X2=0 /\ [y]=2)

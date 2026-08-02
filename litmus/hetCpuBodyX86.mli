(****************************************************************************)
(*                           the diy toolsuite                              *)
(*                                                                          *)
(* HetLitmus: the tagged CPU thread body for x86-64 (P2b), the twin of      *)
(* hetCpuBody.  Same contract, same emitted C shape, same B3 store-tagging; *)
(* matcher over the fixed het vocabulary {MOV $imm,(g) | MOV (g),%r |       *)
(* MOV %r,(g) | MFENCE|SFENCE|LFENCE}.  Never touches Skel.ml / ASMLang.ml  *)
(* / the shared arch backends.  Consumed by top_litmus's HetEmit through    *)
(* HetCpuFront.X86_64's het_analyze / het_emit_body hooks.                  *)
(****************************************************************************)

(* Peel labels/nops off a pseudo list into its straight-line instructions. *)
val instrs_of_code :
  X86_64Base.pseudo list -> X86_64Base.instruction list

(* Resolve one proc's stores/loads into the SHARED plan type the generic
   emitter consumes.  [reg_env] maps an address register name to the global C
   name; the het corpus addresses its globals absolutely (`(x)'), so reg_env is
   consulted only for a zero-offset register deref. *)
val analyze :
  reg_env:(string -> string) -> X86_64Base.instruction list ->
  HetCpuBody.cpu_plan

(* Emit the tagged het_run_<prefix>P<proc>.  Argument contract is
   HetCpuBody.emit_body's, verbatim (see hetCpuBody.mli for what each label
   means and why [prefix] is load-bearing).  Operands are widened to 64 bits
   (`movq'): the shared globals are uint64_t and the K*iter+mu tag must not be
   truncated (B3-decision.md, Decision 3). *)
val emit_body :
  out_channel -> prefix:string -> proc:int -> k:int -> store_mu:(int -> int) ->
  load_buf:(int -> string) -> reg_env:(string -> string) -> iter:string ->
  addr_params:(string * string) list -> buf_params:(string * string) list ->
  X86_64Base.instruction list -> unit

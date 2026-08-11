(****************************************************************************)
(*                           the diy toolsuite                              *)
(*                                                                          *)
(* HetLitmus: the tagged CPU thread body for AArch64 (env-research/         *)
(* decisions/B3-decision.md, Decision 1).  One matcher over the fixed het   *)
(* vocabulary {MOV|MOVZ #imm, STR|STLR|LDR|LDAR|LDAPR at a bare [Xn],       *)
(* DMB SY|ST|LD}; anything else is refused at classification, before a      *)
(* harness directory exists.  Never touches Skel.ml / ASMLang.ml / the      *)
(* shared arch backends.  Consumed by top_litmus's HetEmit through          *)
(* HetCpuFront.AArch64's het_analyze / het_emit_body hooks; the node type,  *)
(* the plan and the C frame are hetCpuPlan's, shared with the x86_64 twin   *)
(* hetCpuBodyX86.                                                           *)
(****************************************************************************)

(* Peel labels/nops off a pseudo list into its straight-line instructions. *)
val instrs_of_code : AArch64Base.pseudo list -> AArch64Base.instruction list

(* Resolve one proc's stores/loads into the shared plan.  [reg_env] maps an
   address register name (e.g. "X1", as it appears in the test init) to the
   global C name. *)
val analyze :
  reg_env:(string -> string) -> AArch64Base.instruction list ->
  HetCpuPlan.cpu_plan

(* Emit the tagged het_run_<prefix>P<proc> -- see hetCpuPlan.emit_frame for
   what each label means.  Each store's value is rebound to the tag operand
   (uint64_t)K*iter + store_mu(store-index) and each load recorded into
   load_buf(load-index)[_n]; the tested mnemonics and fences are reproduced
   verbatim as one asm block, widened to `%x'. *)
val emit_body :
  out_channel -> prefix:string -> proc:int -> k:int -> store_mu:(int -> int) ->
  load_buf:(int -> string) -> reg_env:(string -> string) -> iter:string ->
  addr_params:(string * string) list -> buf_params:(string * string) list ->
  AArch64Base.instruction list -> unit

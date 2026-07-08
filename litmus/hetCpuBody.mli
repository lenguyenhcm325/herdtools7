(****************************************************************************)
(*                           the diy toolsuite                              *)
(*                                                                          *)
(* HetLitmus (B3, decisions/B3-decision.md Decision 1): the bespoke tagged  *)
(* CPU thread body.  AArch64-specific matcher over the fixed het vocabulary *)
(* {MOV #imm + STR|STLR, LDR|LDAR|LDAPR, DMB SY}.  Never touches Skel.ml /   *)
(* ASMLang.ml / the shared arch backends -- that isolation is the whole      *)
(* reason Decision 1 chose option (b).  Consumed by top_litmus's HetEmit via *)
(* the CpuF.het_analyze / CpuF.het_emit_body hooks (the x86_64 arm wires the  *)
(* compile-only [emit_stub] instead).                                        *)
(****************************************************************************)

(* One CPU proc's store/load structure in program order, addresses resolved
   to their global C name; device-agnostic so the generic emitter can build the
   mu map, the read-buffer plan and the (loc,value)->mu recovery map. *)
type cpu_plan = {
    stores : (string * int option) list ;  (* (global, orig `mov #imm' value)  *)
    loads : string list ;                   (* global each recorded load reads  *)
  }

val empty_plan : cpu_plan

(* Peel labels/nops off a pseudo list into its straight-line instructions. *)
val instrs_of_code : AArch64Base.pseudo list -> AArch64Base.instruction list

(* Resolve one proc's stores/loads.  [reg_env] maps an address register name
   (e.g. "X1", as it appears in the test init) to the global C name. *)
val analyze :
  reg_env:(string -> string) -> AArch64Base.instruction list -> cpu_plan

(* Emit the tagged het_run_P<proc>.  Each store's value is rebound to the
   register operand (uint64_t)K*iter + store_mu(store-index) (the `mov #imm' is
   dropped); each load is recorded into load_buf(load-index)[_n]; the tested
   mnemonic and DMB SY are reproduced verbatim as one asm block, widened to %x.
   [iter] is the C tag-index expression (the caller passes "(_n + 1)").
   [addr_params]/[buf_params] are (decl,name) pairs -- the SAME lists
   top_litmus uses for the extern decl, the arg struct and the driver call. *)
val emit_body :
  out_channel -> proc:int -> k:int -> store_mu:(int -> int) ->
  load_buf:(int -> string) -> reg_env:(string -> string) -> iter:string ->
  addr_params:(string * string) list -> buf_params:(string * string) list ->
  AArch64Base.instruction list -> unit

(* x86_64 twin: a compile-only no-op body with the matching signature (MI300A
   de-prioritised; never executed as a result). *)
val emit_stub :
  out_channel -> proc:int -> addr_params:(string * string) list ->
  buf_params:(string * string) list -> unit

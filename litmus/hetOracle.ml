(****************************************************************************)
(*                           the diy toolsuite                              *)
(*                                                                          *)
(* HetLitmus extension (TUM thesis, Nguyen / DSE chair).                    *)
(*                                                                          *)
(* hetOracle: the ORACLE PAIR TABLE.  A compound harness is a CPU ISA and a *)
(* GPU dialect running one test, and the model prediction it carries        *)
(* belongs to THE PAIR: expected-nvidia.csv is derived for Grace(AArch64)+  *)
(* Hopper and expected-amd.csv for Zen-4(x86-64)+CDNA3, so an AArch64 CPU   *)
(* column rendered against HIP is a machine neither file speaks for.  Three *)
(* states -- populated, registered without an oracle, absent (refuse) --    *)
(* and an empty cell is never defaulted to a neighbouring row (D-MV3;       *)
(* hetlitmus/docs/het-emission.md).                                         *)
(*                                                                          *)
(* This software is governed by the CeCILL-B license under French law.      *)
(****************************************************************************)

(* THE MACHINE A HARNESS IS ENTITLED TO NAME.  Every word here is printed by the
   emitted driver and by het_verdict.h as a claim about silicon, so it hangs off
   the pair row and never off the GPU dialect alone: the host half is a property
   of the pair, so a dialect-keyed "Grace half" would land on the (x86_64, cuda)
   emission, which has no Grace in it (hetlitmus/docs/het-emission.md). *)
type machine = {
    mc_link_name : string ;   (* no leading article: use sites supply their own *)
    mc_host_half : string ;
    mc_dev_half : string ;
    (* Alglave ASPLOS'15 4.3.1's "zero without stress" is an NVIDIA measurement
       (B4).  True only where it was measured; everywhere else the gap is stated
       instead of the number being borrowed. *)
    mc_alglave_zero : bool ;
    (* The last-level cache a noise buffer must EXCEED to cross anything on this
       part, in MB, and the parenthetical printed after that warning.  [None]
       means no figure is published for the target: the warning then names the
       mechanism and discloses that its threshold is a fallback measured
       elsewhere, rather than passing another part's capacity off as this one's. *)
    mc_llc_mb : int option ;
    mc_llc_note : string ;
  }

(* THE FALLBACK, and it claims least: it names the MECHANISM, never a brand.  A
   pair with no oracle gets this and stamps no machine defines at all, so
   het_verdict.h's #ifndef defaults -- which are these same words -- stand. *)
let generic_machine = {
    mc_link_name = "host-device interconnect" ;
    mc_host_half = "the host half" ;
    mc_dev_half = "the device half" ;
    mc_alglave_zero = false ;
    mc_llc_mb = None ;
    mc_llc_note =
      " (the local-cache argument is target-independent; no measured \
       last-level-cache behaviour is claimed for this target)" ;
  }

(* GH200: Grace (AArch64) + Hopper over NVLink-C2C.  The Fusco note is that
   Hopper's L2 caches HBM whether the line is local or peer. *)
let gh200_machine = {
    mc_link_name = "NVLink-C2C" ;
    mc_host_half = "the Grace half" ;
    mc_dev_half = "the Hopper half" ;
    mc_alglave_zero = true ;
    (* max(Grace L3 114 MB, Hopper L2 51 MB) -- Bagchi ISMM'26 Table 1. *)
    mc_llc_mb = Some 114 ;
    mc_llc_note = " (Fusco: Hopper L2 caches HBM, local and peer)" ;
  }

(* MI300A: Zen-4 x86-64 CCDs + CDNA3 XCDs on one package over Infinity Fabric.
   That is the machine expected-amd.csv is derived FOR, verbatim from the memo
   that derives it (env-research/PORT2-R2-amd-oracle.md sec 1), so naming it here
   claims exactly what the oracle already claims and nothing more.  Alglave's
   "zero without stress" stays withheld: no equivalent figure is published for
   this part.  The LLC figure is not withheld, because one IS published for it --
   256 MB, and the Grace 114 MB it replaces UNDER-fires here, so the target's own
   figure is both the grounded and the conservative reading. *)
let mi300a_machine = {
    mc_link_name = "Infinity Fabric" ;
    mc_host_half = "the x86 half" ;
    mc_dev_half = "the MI300A device half" ;
    mc_alglave_zero = false ;
    (* The MALL / AMD Infinity Cache on the IOD is this part's last level, above
       both the per-XCD 4 MB L2 and the per-CCD Zen-4 L3, and all HBM traffic
       passes through it: Tee et al., "The MALL is Open", SC Workshops '25,
       Table 1 p.1111 (MI300A: sL1 16 KB, L2 4 MB/XCD, MALL 256 MB). *)
    mc_llc_mb = Some 256 ;
    mc_llc_note =
      " (the MALL / AMD Infinity Cache, 256 MB -- Tee et al., The MALL is \
       Open, SC-W'25 Table 1)" ;
  }

type populated = {
    (* NAMES, not contents: nothing is read out of the oracle CSV at emission.
       The pair (file, Model) is what the harness records as [oracle_source], so
       a run log says which oracle the tag came from and a reader knows which
       file to re-derive a mismatch from. *)
    op_oracle_csv : string ;
    op_oracle_model : string ;
    (* The positive-control map IS read: it carries mu(T), the canary and the
       oracle class.  It is per PAIR for the same reason the oracle is -- the
       x86 strength lattice loses the AArch64 lattice's middle rung, so a mu(T)
       chosen on one is not a weakening on the other (memo 7.D11). *)
    op_control_map_csv : string ;
    op_machine : machine ;
  }

type state =
  | Populated of populated
  | Registered_none of string       (* why this pair carries no prediction *)

(* THE TABLE.  Adding a machine is adding a row here; nothing else in the
   emitter knows a pair exists. *)
let table = [
    ("AArch64", "cuda"),
    Populated { op_oracle_csv = "expected-nvidia.csv" ;
                op_oracle_model = "NVIDIA-PTX-AArch64" ;
                op_control_map_csv = "control-map.csv" ;
                op_machine = gh200_machine } ;

    ("X86_64", "hip"),
    Populated { op_oracle_csv = "expected-amd.csv" ;
                op_oracle_model = "AMD-CDNA3-x86" ;
                op_control_map_csv = "control-map-amd.csv" ;
                op_machine = mi300a_machine } ;

    (* Registered NO-ORACLE: the dev box is an x86-64 host with an NVIDIA GPU, so
       this pair is what the runtime bites (PORT1 spotcheck, the stress and
       allocator gates) actually execute.  No compound model has been instantiated
       for it -- CMCM sec 5-6 is x86TSO+PTX on paper, but its oracle here would be
       an untested transfer -- so its harnesses characterize and never adjudicate. *)
    ("X86_64", "cuda"),
    Registered_none
      "dev-tier machinery only: no compound oracle has been derived for an \
       x86-64 host with an NVIDIA device" ;
  ]

(* `-allow-no-oracle' (D-MV4).  Legitimate only for an UNREGISTERED pair on new
   hardware, where refusing would mean the machine cannot be measured at all.
   The use is disclosed in the stamp every run prints, and no committed script
   passes it (hetlitmus/verify/allow-no-oracle-gate.sh enforces that over the
   tree, and is bitten). *)
let allow_no_oracle = ref false
let set_allow_no_oracle b = allow_no_oracle := b

let pair_name ~cpu_isa ~target = Printf.sprintf "(%s, %s)" cpu_isa target

let registered_doc () =
  String.concat ", "
    (List.map (fun ((c,t),_) -> pair_name ~cpu_isa:c ~target:t) table)

type resolution =
  | Oracle of populated
  | Characterize of string          (* REGISTERED NO-ORACLE, with its reason *)
  | Override                        (* ABSENT pair, emitted under the flag *)

(* Fails closed on an absent pair: the caller's deliverable is a harness that
   says what the model predicts, and there is no honest way to write one here.
   The emission arms turn the error into a refusal (HetArch.refused: exit 3,
   never a silent 0), so nothing is written. *)
let resolve ~cpu_isa ~target =
  match List.assoc_opt (cpu_isa,target) table with
  | Some (Populated p) -> Oracle p
  | Some (Registered_none why) -> Characterize why
  | None ->
     if !allow_no_oracle then Override
     else
       Warn.user_error
         "no oracle is registered for the CPU-ISA x GPU-dialect pair %s.  The \
          model prediction a harness carries belongs to the PAIR, so tagging \
          this one from a neighbouring row would stamp it with a prediction \
          derived for another machine.  Registered pairs: %s.  Add the pair to \
          litmus/hetOracle.ml, or pass -allow-no-oracle to emit it as a \
          characterization-only harness (new hardware only; the stamp discloses \
          the override)."
         (pair_name ~cpu_isa ~target) (registered_doc ())

(* The machine a resolution is entitled to name.  Only a populated pair has one;
   everything else gets the mechanism-naming fallback. *)
let machine_of = function
  | Oracle p -> Some p.op_machine
  | Characterize _ | Override -> None

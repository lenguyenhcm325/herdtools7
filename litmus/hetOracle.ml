(****************************************************************************)
(*                           the diy toolsuite                              *)
(*                                                                          *)
(* HetLitmus extension (TUM thesis, Nguyen / DSE chair).                    *)
(*                                                                          *)
(* hetOracle: the ORACLE PAIR TABLE.  A compound harness is a CPU ISA and   *)
(* a GPU dialect running one test, and the model prediction it carries      *)
(* belongs to THE PAIR, not to either half: expected-nvidia.csv is derived  *)
(* for Grace(AArch64)+Hopper and expected-amd.csv for Zen-4(x86-64)+CDNA3,  *)
(* so an AArch64 CPU column rendered against HIP is a machine neither file  *)
(* speaks for.  Keying the oracle on the CPU ISA alone -- what this table   *)
(* replaces -- tagged such a harness with the nearer file's prediction and  *)
(* stood ready to report a sighting as a refutation of a model that never   *)
(* addressed that machine.                                                  *)
(*                                                                          *)
(* Three states, and the third is the point (D-MV3):                        *)
(*   POPULATED           the pair has an oracle; its name and Model string  *)
(*                       are stamped into the harness, and its positive-    *)
(*                       control map names mu(T) and the canary.            *)
(*   REGISTERED NO-ORACLE  a committed row saying WHY this pair carries no  *)
(*                       prediction.  Every test is stamped ORACLE_NONE     *)
(*                       directly (D-MV5): no CSV is read and no blank file *)
(*                       exists anywhere, so the class cannot be mistaken   *)
(*                       for a lookup that silently missed.                 *)
(*   ABSENT              refuse at emission, naming the pair.  An empty     *)
(*                       cell is NEVER defaulted to a neighbouring row: a   *)
(*                       wrong-CPU oracle is the false-refutation class     *)
(*                       D26 purged from the AMD oracle.                    *)
(*                                                                          *)
(* This software is governed by the CeCILL-B license under French law.      *)
(****************************************************************************)

(* THE MACHINE A HARNESS IS ENTITLED TO NAME.  These words are printed by the
   emitted driver and by het_verdict.h, and each one is a claim about silicon:
   calling the two halves of the interconnect noise "Grace" and "Hopper" on an
   AMD-tagged run is a false statement about the machine (MEASURED 2026-08-03 on
   a real run of 2+2W-cpuonly-x86_64, whose first two lines were "the Hopper half
   of the C2C noise is DISABLED" and "the Grace half ... is DISABLED").

   They hang off the PAIR ROW rather than off the GPU dialect, because the host
   half is a property of the pair: keyed on the dialect alone, the dev-tier
   (x86_64, cuda) emission would stamp "the Grace half" on a machine that has no
   Grace in it, which is the same defect one table over. *)
type machine = {
    mc_link_name : string ;   (* no leading article: use sites supply their own *)
    mc_host_half : string ;
    mc_dev_half : string ;
    (* Alglave ASPLOS'15 4.3.1's "zero without stress" is an NVIDIA measurement
       (B4).  True only where it was measured; everywhere else the gap is stated
       instead of the number being borrowed. *)
    mc_alglave_zero : bool ;
    (* The parenthetical after the "noise buffer fits in cache" warning.  Same
       rule: a measured last-level-cache behaviour is cited only for the part it
       was measured on. *)
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
    mc_llc_note = " (Fusco: Hopper L2 caches HBM, local and peer)" ;
  }

(* MI300A: Zen-4 x86-64 CCDs + CDNA3 XCDs on one package over Infinity Fabric.
   That is the machine expected-amd.csv is derived FOR, verbatim from the memo
   that derives it (env-research/PORT2-R2-amd-oracle.md sec 1), so naming it here
   claims exactly what the oracle already claims and nothing more.  The two
   measured NVIDIA notes above stay withheld: no equivalent figure is published
   for this part, and the honest form says so rather than borrowing one. *)
let mi300a_machine = {
    mc_link_name = "Infinity Fabric" ;
    mc_host_half = "the x86 half" ;
    mc_dev_half = "the MI300A device half" ;
    mc_alglave_zero = false ;
    mc_llc_note = generic_machine.mc_llc_note ;
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

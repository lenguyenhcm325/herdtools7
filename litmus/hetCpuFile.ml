(****************************************************************************)
(*                           the diy toolsuite                              *)
(*                                                                          *)
(* Jade Alglave, University College London, UK.                             *)
(* Luc Maranget, INRIA Paris-Rocquencourt, France.                          *)
(*                                                                          *)
(* Copyright 2013-present Institut National de Recherche en Informatique et *)
(* en Automatique and the authors. All rights reserved.                     *)
(*                                                                          *)
(* This software is governed by the CeCILL-B license under French law and   *)
(* abiding by the rules of distribution of free software. You can use,      *)
(* modify and/ or redistribute the software under the terms of the CeCILL-B *)
(* license as circulated by CEA, CNRS and INRIA at the following URL        *)
(* "http://www.cecill.info". We also give a copy in LICENSE.txt.            *)
(****************************************************************************)

(* HetLitmus: the <t>_cpu.c render -- the harness's CPU threads, whose bodies
   litmus7's own asm printer writes, and the non-static entry points the GPU
   driver calls.  Design: hetlitmus/docs/het-emission.md. *)

open HetCpuFront

open HetHarness

let dump h ch =
  let s = output_string ch in
  let tname = h.h_name and it = h.h_shape and tc = h.h_toolchain in
            s (Printf.sprintf
                 "/* HetLitmus: the CPU threads of %s (%s).\n   \
                  Bodies compiled and printed by litmus7 itself\n   \
                  (Compile.Make -> ASMLang.dump_fun); het_run_P<n> is the\n   \
                  non-static entry point its caller hands iteration n's slot\n   \
                  address for every location.  DO NOT EDIT. */\n"
                 tname tc.isa_name) ;

            (* _GNU_SOURCE before EVERY libc header: glibc hides the cpu_set_t
               and sched_setaffinity that het_cpu_stress.h needs. *)
            s "#define _GNU_SOURCE\n" ;
            s "#include <stdint.h>\n\n" ;
            (* HET_CPU_STRESS_IMPL: the CPU stress bodies land in this file. *)
            s "#define HET_CPU_STRESS_IMPL\n" ;
            s "#include \"het_cpu_stress.h\"\n\n" ;
            s (Printf.sprintf "#if defined(%s)\n" tc.host_macro) ;
            List.iter (fun cp -> cp.cp_dump ch) it.i_cpus ;
            s "#else\n" ;
            s (Printf.sprintf
                 "/* Stub for a non-%s host; the tested body is the asm above. */\n"
                 tc.isa_name) ;
            List.iter
              (fun cp ->
                s (Printf.sprintf "static void code%d(%s) {\n"
                     cp.cp_proc (cpu_sig cp)) ;
                List.iter (fun (_,n) -> s (Printf.sprintf "  (void)%s;\n" n))
                  cp.cp_addrs ;
                List.iter (fun (_,n) -> s (Printf.sprintf "  *%s = 0;\n" n))
                  cp.cp_outs ;
                s "}\n")
              it.i_cpus ;
            s "#endif\n\n" ;

            (* The non-static entry points the GPU-side driver calls. *)
            List.iter
              (fun cp ->
                let args =
                  String.concat "," (List.map snd (cp.cp_addrs @ cp.cp_outs)) in
                s (Printf.sprintf "void het_run_P%d(%s) { code%d(%s); }\n"
                     cp.cp_proc (cpu_sig cp) cp.cp_proc args))
              it.i_cpus

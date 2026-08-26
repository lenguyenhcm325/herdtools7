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

(* HetLitmus: the harness directory's build files -- comp.sh, the Makefile and
   the README -- rendered from one harness record.  Every per-vendor line folds
   over the selected dialects (litmus/hetDialect.ml).
   Design: hetlitmus/docs/het-emission.md. *)

open HetCpuFront

open HetDialect

open HetHarness

(* The build files' per-vendor vocabulary, folded over the harness's selected
   dialects; each render defaults to [d0], the head of that list. *)
let targets h = List.map (fun d -> d.gd_target) h.h_dialects
let comp_args h =
  let targets = targets h in
  String.concat "|" (targets @ List.map (fun t -> t ^ "-link") targets)
let plural h sing plur = if List.length h.h_dialects = 1 then sing else plur
let enum l = match List.rev l with
  | [] -> ""
  | [x] -> x
  | x :: rest -> String.concat ", " (List.rev rest) ^ " and " ^ x
let count_word = function
  | 1 -> "The one" | 2 -> "Both" | 3 -> "All three" | 4 -> "All four"
  | k -> Printf.sprintf "All %d" k

let dump_comp h ch =
  let s = output_string ch in
  let tname = h.h_name and tc = h.h_toolchain in
  let host_uname = tc.host_uname in
  let dialects = h.h_dialects in
  let d0 = List.hd dialects in
  let targets = targets h and comp_args = comp_args h in
            s "#!/bin/sh\n" ;
            s (Printf.sprintf
                 "# Compile-only check for HetLitmus harness '%s' (%s render).\n"
                 tname (enum (List.map (fun d -> d.gd_name) dialects))) ;
            s (Printf.sprintf
                 "# COMPILE-ONLY by default (-c, no link, no GPU run); %s links ./%s too.\n"
                 (String.concat " / "
                    (List.map (fun t -> Printf.sprintf "`%s-link'" t) targets))
                 tname) ;
            s (Printf.sprintf "# Usage: sh comp.sh [%s]   (default %s)\n"
                 comp_args d0.gd_target) ;
            s (Printf.sprintf
                 "# Why the link is guarded, why every render writes ./%s, and the build\n"
                 tname) ;
            s "# knobs: hetlitmus/docs/het-emission.md\n" ;
            s "set -e\n" ;
            s (Printf.sprintf "TARGET=\"${1:-%s}\"\n" d0.gd_target) ;

            (* one `compiler ; arch' line per dialect *)
            let var_line d =
              Printf.sprintf "%s=\"${%s:-%s}\" ; %s=\"${%s:-%s}\""
                d.gd_compiler_var d.gd_compiler_var d.gd_compiler
                d.gd_arch_var d.gd_arch_var d.gd_arch_default in
            let var_w =
              List.fold_left
                (fun w d -> max w (String.length (var_line d))) 0 dialects in
            List.iter
              (fun d ->
                let v = var_line d in
                s (Printf.sprintf "%s%s # %s\n"
                     v (String.make (var_w - String.length v) ' ')
                     ("default arch " ^ d.gd_arch_default)))
              dialects ;
            s (Printf.sprintf
                 "HET_HOST_ISA=\"%s\"   # uname -m of this test's CPU ISA (%s)\n"
                 host_uname tc.isa_name) ;

            (* The ISA flags litmus7's lowering needs (e.g. rcpc): the cross
               line always, the host line only when the host IS this ISA. *)
            s (Printf.sprintf
                 "HET_CPU_CFLAGS=\"${HET_CPU_CFLAGS:-%s}\"\n" tc.cpu_cflags) ;
            s "HET_HOST_CFLAGS=\"\"\n" ;
            s "if [ \"$(uname -m)\" = \"$HET_HOST_ISA\" ]; then HET_HOST_CFLAGS=\"$HET_CPU_CFLAGS\"; fi\n" ;
            s "echo \"+ gcc -c outs.c\"\ngcc -c outs.c -o outs.o\n" ;
            s (Printf.sprintf
                 "echo \"+ gcc $HET_HOST_CFLAGS -c %s_cpu.c  (host build; %s asm under #if defined(%s))\"\n"
                 tname tc.isa_name tc.host_macro) ;
            s (Printf.sprintf "gcc $HET_HOST_CFLAGS -c %s_cpu.c -o %s_cpu_host.o\n"
                 tname tname) ;
            (match tc.cross with
             | Some (triple,std) ->
                s "if command -v clang >/dev/null 2>&1; then\n" ;
                s (Printf.sprintf
                     "  echo \"+ clang --target=%s $HET_CPU_CFLAGS -c %s_cpu.c  (real %s asm)\"\n"
                     triple tname tc.isa_name) ;
                s (Printf.sprintf
                     "  clang --target=%s -std=%s $HET_CPU_CFLAGS -c %s_cpu.c -o %s_cpu.o\n"
                     triple std tname tname) ;
                s (Printf.sprintf
                     "else\n  echo \"(no clang: skipped %s cross-assembly of %s_cpu.c)\"\nfi\n"
                     tc.isa_name tname)
             | None ->
                s (Printf.sprintf
                     "# (%s host == build host: the gcc -c above already assembled the real %s asm)\n"
                     tc.isa_name tc.isa_name)) ;
            s "case \"$TARGET\" in\n" ;
            List.iter
              (fun d ->
                let cc = "$" ^ d.gd_compiler_var
                and arch = "$" ^ d.gd_arch_var
                and obj = gpu_obj d tname in
                s (Printf.sprintf "  %s|%s-link)\n" d.gd_target d.gd_target) ;
                s (Printf.sprintf
                     "    if [ \"$TARGET\" = %s-link ] && [ \"$(uname -m)\" != \"$HET_HOST_ISA\" ]; then\n"
                     d.gd_target) ;
                s (Printf.sprintf
                     "      echo \"error: comp.sh %s-link refuses on $(uname -m): %s_cpu_host.o here is the PORTABLE SHIM, not %s asm, so the binary would test nothing -- link on a $HET_HOST_ISA host\" >&2\n"
                     d.gd_target tname tc.isa_name) ;
                s "      exit 3\n" ;
                s "    fi\n" ;
                s (Printf.sprintf
                     "    command -v \"%s\" >/dev/null 2>&1 || { echo \"error: %s not found (%s toolchain absent)\" >&2 ; exit 1 ; }\n"
                     cc cc d.gd_toolchain) ;
                s (Printf.sprintf "    echo \"+ %s %s -c %s.%s\"\n"
                     cc (gpu_cflags d arch) tname d.gd_ext) ;
                s (Printf.sprintf "    %s %s -c %s.%s -o %s\n"
                     cc (gpu_cflags d arch) tname d.gd_ext obj) ;
                s (Printf.sprintf "    if [ \"$TARGET\" = %s-link ]; then\n"
                     d.gd_target) ;
                s (Printf.sprintf
                     "      echo \"+ %s %s%s %s outs.o %s_cpu_host.o -o %s -lpthread -lm\"\n"
                     cc d.gd_arch_flag arch obj tname tname) ;
                s (Printf.sprintf
                     "      %s %s%s %s outs.o %s_cpu_host.o -o %s -lpthread -lm\n"
                     cc d.gd_arch_flag arch obj tname tname) ;
                s "    fi ;;\n")
              dialects ;
 
            s (Printf.sprintf
                 "  *) echo \"comp.sh: unknown target \\\"$TARGET\\\" -- this directory is %s-only (accepted: %s)\" >&2 ; exit 2 ;;\n"
                 (String.concat "/" targets) comp_args) ;
            s "esac\n" ;
            s (Printf.sprintf "if %s; then\n"
                 (String.concat " || "
                    (List.map
                       (fun t -> Printf.sprintf "[ \"$TARGET\" = %s-link ]" t)
                       targets))) ;
            s (Printf.sprintf "  echo \"HetLitmus: link OK -> ./%s\"\n" tname) ;
            s "else\n" ;
            s "  echo 'HetLitmus: compile OK'\n" ;
            s "fi\n"

let dump_makefile h ch =
  let s = output_string ch in
  let tname = h.h_name and tc = h.h_toolchain in
  let host_uname = tc.host_uname in
  let dialects = h.h_dialects in
  let d0 = List.hd dialects in
  let targets = targets h and plural = plural h in
            s (Printf.sprintf
                 "# HetLitmus harness '%s' -- objects by default (`make %s');\n"
                 tname d0.gd_target) ;
            s (Printf.sprintf
                 "# %s %s ./%s, guarded by uname -m.\n"
                 (String.concat " / "
                    (List.map (fun t -> Printf.sprintf "`make %s-bin'" t)
                       targets))
                 (plural "links" "link") tname) ;
            List.iter
              (fun d ->
                s (Printf.sprintf "%s ?= %s\n%s ?= %s\n"
                     d.gd_compiler_var d.gd_compiler
                     d.gd_arch_var d.gd_arch_default))
              dialects ;
            s "CC ?= gcc\n" ;
            s (Printf.sprintf "HET_CPU_CFLAGS ?= %s\n" tc.cpu_cflags) ;
            s (Printf.sprintf
                 "# uname -m of this test's CPU ISA (%s); the %s-bin guard compares it.\n"
                 tc.isa_name d0.gd_target) ;
            s (Printf.sprintf "HET_HOST_ISA ?= %s\n" host_uname) ;
            (* Keyed on the literal uname word, not on HET_HOST_ISA: overriding
               that to link on a foreign host must not hand its gcc this -march. *)
            s (Printf.sprintf
                 "HET_HOST_CFLAGS := $(if $(filter %s,$(shell uname -m)),$(HET_CPU_CFLAGS))\n\n"
                 host_uname) ;
            s (Printf.sprintf "all: %s\n\n" d0.gd_target) ;
            List.iter
              (fun d ->
                s (Printf.sprintf "%s: %s outs.o %s_cpu_host.o\n"
                     d.gd_target (gpu_obj d tname) tname))
              dialects ;
            s "\n" ;
            List.iter
              (fun d ->
                s (Printf.sprintf "%s: %s.%s\n\t$(%s) %s -c $< -o $@\n\n"
                     (gpu_obj d tname) tname d.gd_ext d.gd_compiler_var
                     (gpu_cflags d (Printf.sprintf "$(%s)" d.gd_arch_var))))
              dialects ;
            s "outs.o: outs.c\n\t$(CC) -c $< -o $@\n\n" ;
            s (Printf.sprintf
                 "%s_cpu_host.o: %s_cpu.c\n\t$(CC) $(HET_HOST_CFLAGS) -c $< -o $@\n\n"
                 tname tname) ;
            List.iter
              (fun d ->
                s (Printf.sprintf "%s-bin: %s outs.o %s_cpu_host.o\n"
                     d.gd_target (gpu_obj d tname) tname) ;
                s (Printf.sprintf
                     "\t@ test \"$$(uname -m)\" = \"$(HET_HOST_ISA)\" || { echo \"error: %s-bin refuses on $$(uname -m): %s_cpu_host.o here is the PORTABLE SHIM, not %s asm, so the binary would test nothing -- link on a $(HET_HOST_ISA) host\" >&2 ; exit 3 ; }\n"
                     d.gd_target tname tc.isa_name) ;
                s (Printf.sprintf "\t$(%s) %s$(%s) $^ -o %s -lpthread -lm\n\n"
                     d.gd_compiler_var d.gd_arch_flag d.gd_arch_var tname))
              dialects ;
            s ".SUFFIXES:\n\n" ;
            s (Printf.sprintf "%s:\n" tname) ;
            s (Printf.sprintf
                 "\t@ echo \"error: \\`make %s' is not a build target: it would bypass the uname -m guard.  Link it with %s, %s uname -m first.\" >&2 ; exit 3\n\n"
                 tname
                 (String.concat " or "
                    (List.map
                       (fun d -> Printf.sprintf "\\`make %s-bin' (%s)"
                                   d.gd_target d.gd_vendor)
                       dialects))
                 (plural "which checks" "which all check")) ;
            s (Printf.sprintf
                 ".PHONY: all %s clean %s\nclean:\n\trm -f *.o %s\n"
                 (String.concat " "
                    (List.map (fun t -> Printf.sprintf "%s %s-bin" t t)
                       targets))
                 tname tname)

let dump_readme h ch =
  let s = output_string ch in
  let tname = h.h_name and tc = h.h_toolchain in
  let host_uname = tc.host_uname and pair_label = h.h_pair_label in
  let dialects = h.h_dialects in
  let n_d = List.length dialects in
  let d0 = List.hd dialects in
  let targets = targets h and plural = plural h in
            s (Printf.sprintf "# HetLitmus heterogeneous harness: %s\n\n" tname) ;
            s (Printf.sprintf "CPU ISA: %s.  GPU dialect%s: %s.\n\n"
                 tc.isa_name (plural "" "s")
                 (String.concat " + "
                    (List.map
                       (fun d -> Printf.sprintf "%s (`.%s`)" d.gd_name d.gd_ext)
                       dialects))) ;
            s "Files:\n" ;
            let ext_w =
              List.fold_left
                (fun w d -> max w (String.length d.gd_ext)) 0 dialects + 4 in
            List.iter
              (fun d ->
                s (Printf.sprintf "- `%s.%s`%s%s" tname d.gd_ext
                     (String.make (ext_w - String.length d.gd_ext) ' ')
                     d.gd_readme_files))
              dialects ;
            s (Printf.sprintf
                 "- `%s_cpu.c`  CPU thread(s): litmus7's own %s inline asm (ASMLang).\n"
                 tname tc.isa_name) ;
            s "- `outs.c/.h` litmus7's outcome histogram (verbatim from litmus/libdir).\n" ;
            s (Printf.sprintf
                 "- `comp.sh` / `Makefile`  compile-only build, plus %s guarded link target%s.\n\n"
                 (plural "the" "the two") (plural "" "s")) ;
            s (Printf.sprintf
                 "Build (compile-only, no GPU): `sh comp.sh [%s]` (default %s), or %s.\n"
                 (String.concat "|" targets) d0.gd_target
                 (String.concat " / "
                    (List.map (fun t -> Printf.sprintf "`make %s`" t)
                       targets))) ;
            List.iter
              (fun d ->
                s (Printf.sprintf
                     "Link: `sh comp.sh %s-link` or `make %s-bin` writes `./%s` from `%s`\n"
                     d.gd_target d.gd_target tname (gpu_obj d tname)) ;
                s (Printf.sprintf "  (%s: `$%s %s$%s`, %s).\n"
                     d.gd_vendor d.gd_compiler_var d.gd_arch_flag d.gd_arch_var
                     ("default " ^ d.gd_arch_default)))
              dialects ;
            s (Printf.sprintf
                 "%s link paths REFUSE unless `uname -m` is `%s`: elsewhere\n"
                 (count_word (2 * n_d)) host_uname) ;
            s (Printf.sprintf
                 "`%s_cpu_host.o` is the portable shim, not the %s asm, and the binary\n"
                 tname tc.isa_name) ;
            s "would test nothing.\n\n" ;
            s (Printf.sprintf
                 "The build knobs and why `make %s` refuses:\n" tname) ;
            s "`hetlitmus/docs/het-emission.md`.\n\n" ;
            s (Printf.sprintf "Target%s: %s.\n" (plural "" "s")
                 (enum
                    (List.map
                       (fun d -> Printf.sprintf "%s %s" d.gd_vendor d.gd_name)
                       dialects))) ;
            s (Printf.sprintf
                 "Pair: `%s` -- the CPU ISA and GPU dialect this harness was built\n"
                 pair_label) ;
            s "for, stamped as HET_PAIR_NAME; results are filed under it, and it names\n" ;
            s "no machine.\n"

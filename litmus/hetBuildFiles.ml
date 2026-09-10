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
   the README -- rendered from one harness record.
   Design: hetlitmus/docs/het-emission.md. *)

open HetCpuFront

open HetDialect

open HetHarness

let dump_comp h ch =
  let s = output_string ch in
  let tname = h.h_identity.id_name and tc = h.h_toolchain in
  let host_uname = tc.host_uname in
  let d = h.h_dialect in
  let target = d.gd_target in
  s "#!/bin/sh\n" ;
  s (Printf.sprintf
       "# Compile-only check for HetLitmus harness '%s' (%s render).\n"
       tname d.gd_name) ;
  s (Printf.sprintf
       "# COMPILE-ONLY by default (-c, no link, no GPU run); `%s-link' links ./%s too.\n"
       target tname) ;
  s (Printf.sprintf "# Usage: sh comp.sh [%s|%s-link]   (default %s)\n"
       target target target) ;
  s (Printf.sprintf
       "# Why every render writes ./%s, and the build\n"
       tname) ;
  s "# knobs: hetlitmus/docs/het-emission.md\n" ;
  s "set -e\n" ;
  s (Printf.sprintf "TARGET=\"${1:-%s}\"\n" target) ;
  s (Printf.sprintf "%s=\"${%s:-%s}\" ; %s=\"${%s:-%s}\" # default arch %s\n"
       d.gd_compiler_var d.gd_compiler_var d.gd_compiler
       d.gd_arch_var d.gd_arch_var d.gd_arch_default d.gd_arch_default) ;
  s (Printf.sprintf
       "HET_CPU_CFLAGS=\"${HET_CPU_CFLAGS:-%s}\"\n" tc.cpu_cflags) ;
  s {|echo "+ gcc -c outs.c"
gcc -c outs.c -o outs.o
|} ;
  (* ONLY the native branch writes the object a link path names
     (hetlitmus/docs/het-emission.md, "The CPU object"). *)
  let triple,std = tc.cross in
  s (Printf.sprintf "if [ \"$(uname -m)\" = \"%s\" ]; then\n" host_uname) ;
  s (Printf.sprintf
       "  echo \"+ gcc $HET_CPU_CFLAGS -c %s_cpu.c  (%s asm, native)\"\n"
       tname tc.isa_name) ;
  s (Printf.sprintf "  gcc $HET_CPU_CFLAGS -c %s_cpu.c -o %s_cpu_host.o\n"
       tname tname) ;
  s "else\n" ;
  s (Printf.sprintf
       "  command -v clang >/dev/null 2>&1 || { echo \"error: clang not found: \
        %s_cpu.c carries %s asm, which this $(uname -m) host can only \
        cross-assemble\" >&2 ; exit 1 ; }\n"
       tname tc.isa_name) ;
  s (Printf.sprintf
       "  echo \"+ clang --target=%s $HET_CPU_CFLAGS -c %s_cpu.c  (%s asm, \
        cross-assembled)\"\n"
       triple tname tc.isa_name) ;
  s (Printf.sprintf
       "  clang --target=%s -std=%s $HET_CPU_CFLAGS -c %s_cpu.c -o %s_cpu.o\n"
       triple std tname tname) ;
  s "fi\n" ;
  s "case \"$TARGET\" in\n" ;
  let cc = "$" ^ d.gd_compiler_var
  and arch = "$" ^ d.gd_arch_var
  and obj = gpu_obj d tname in
  s (Printf.sprintf "  %s|%s-link)\n" target target) ;
  s (Printf.sprintf
       "    command -v \"%s\" >/dev/null 2>&1 || { echo \"error: %s not found (%s toolchain absent)\" >&2 ; exit 1 ; }\n"
       cc cc d.gd_toolchain) ;
  s (Printf.sprintf "    echo \"+ %s %s -c %s.%s\"\n"
       cc (gpu_cflags d arch) tname d.gd_ext) ;
  s (Printf.sprintf "    %s %s -c %s.%s -o %s\n"
       cc (gpu_cflags d arch) tname d.gd_ext obj) ;
  s (Printf.sprintf "    if [ \"$TARGET\" = %s-link ]; then\n" target) ;
  s (Printf.sprintf
       "      echo \"+ %s %s%s %s outs.o %s_cpu_host.o -o %s -lpthread\"\n"
       cc d.gd_arch_flag arch obj tname tname) ;
  s (Printf.sprintf
       "      %s %s%s %s outs.o %s_cpu_host.o -o %s -lpthread\n"
       cc d.gd_arch_flag arch obj tname tname) ;
  s "    fi ;;\n" ;
  s (Printf.sprintf
       "  *) echo \"comp.sh: unknown target \\\"$TARGET\\\" -- this directory is %s-only (accepted: %s|%s-link)\" >&2 ; exit 2 ;;\n"
       target target target) ;
  s "esac\n" ;
  s (Printf.sprintf "if [ \"$TARGET\" = %s-link ]; then\n" target) ;
  s (Printf.sprintf "  echo \"HetLitmus: link OK -> ./%s\"\n" tname) ;
  s {|else
  echo 'HetLitmus: compile OK'
fi
|}

let dump_makefile h ch =
  let s = output_string ch in
  let tname = h.h_identity.id_name and tc = h.h_toolchain in
  let host_uname = tc.host_uname in
  let d = h.h_dialect in
  let target = d.gd_target and obj = gpu_obj d tname in
  s (Printf.sprintf
       "# HetLitmus harness '%s' -- objects by default (`make %s');\n"
       tname target) ;
  s (Printf.sprintf "# `make %s-bin' links ./%s.\n" target tname) ;
  s (Printf.sprintf "%s ?= %s\n%s ?= %s\n"
       d.gd_compiler_var d.gd_compiler d.gd_arch_var d.gd_arch_default) ;
  s "CC ?= gcc\n" ;
  s (Printf.sprintf "HET_CPU_CFLAGS ?= %s\n" tc.cpu_cflags) ;
  (* A gcc of another ISA rejects a foreign -march before preprocessing. *)
  s (Printf.sprintf
       "HET_HOST_CFLAGS := $(if $(filter %s,$(shell uname -m)),$(HET_CPU_CFLAGS))\n\n"
       host_uname) ;
  s (Printf.sprintf "all: %s\n\n" target) ;
  s (Printf.sprintf "%s: %s outs.o %s_cpu_host.o\n" target obj tname) ;
  s "\n" ;
  s (Printf.sprintf "%s: %s.%s\n\t$(%s) %s -c $< -o $@\n\n"
       obj tname d.gd_ext d.gd_compiler_var
       (gpu_cflags d (Printf.sprintf "$(%s)" d.gd_arch_var))) ;
  s {|outs.o: outs.c
	$(CC) -c $< -o $@

|} ;
  s (Printf.sprintf
       "%s_cpu_host.o: %s_cpu.c\n\t$(CC) $(HET_HOST_CFLAGS) -c $< -o $@\n\n"
       tname tname) ;
  s (Printf.sprintf "%s-bin: %s outs.o %s_cpu_host.o\n" target obj tname) ;
  s (Printf.sprintf "\t$(%s) %s$(%s) $^ -o %s -lpthread\n\n"
       d.gd_compiler_var d.gd_arch_flag d.gd_arch_var tname) ;
  s ".SUFFIXES:\n\n" ;
  s (Printf.sprintf "%s:\n" tname) ;
  s (Printf.sprintf
       "\t@ echo \"error: \\`make %s' is not a build target: it would hand back a stale ./%s.  Link it with \\`make %s-bin' (%s).\" >&2 ; exit 3\n\n"
       tname tname target d.gd_vendor) ;
  s (Printf.sprintf
       ".PHONY: all %s %s-bin clean %s\nclean:\n\trm -f *.o %s\n"
       target target tname tname)

let dump_readme h ch =
  let s = output_string ch in
  let tname = h.h_identity.id_name and tc = h.h_toolchain in
  let host_uname = tc.host_uname in
  let pair_label = h.h_identity.id_pair_label in
  let d = h.h_dialect in
  let target = d.gd_target in
  s (Printf.sprintf "# HetLitmus heterogeneous harness: %s\n\n" tname) ;
  s (Printf.sprintf "CPU ISA: %s.  GPU dialect: %s (`.%s`).\n\n"
       tc.isa_name d.gd_name d.gd_ext) ;
  s "Files:\n" ;
  s (Printf.sprintf "- `%s.%s`    %s" tname d.gd_ext d.gd_readme_files) ;
  s (Printf.sprintf
       "- `%s_cpu.c`  CPU thread(s): litmus7's own %s inline asm (ASMLang).\n"
       tname tc.isa_name) ;
  s "- `outs.c/.h` litmus7's outcome histogram (verbatim from litmus/libdir).\n" ;
  s "- `comp.sh` / `Makefile`  compile-only build, plus the link target.\n\n" ;
  s (Printf.sprintf
       "Build (compile-only, no GPU): `sh comp.sh [%s]` (default %s), or `make %s`.\n"
       target target target) ;
  s (Printf.sprintf
       "Link: `sh comp.sh %s-link` or `make %s-bin` writes `./%s` from `%s`\n"
       target target tname (gpu_obj d tname)) ;
  s (Printf.sprintf "  (%s: `$%s %s$%s`, default %s).\n"
       d.gd_vendor d.gd_compiler_var d.gd_arch_flag d.gd_arch_var
       d.gd_arch_default) ;
  s (Printf.sprintf
       "`%s_cpu.c` compiles only where `uname -m` is `%s` -- its `#else` is\n"
       tname host_uname) ;
  s (Printf.sprintf
       "an `#error` -- so elsewhere `comp.sh` cross-assembles it with\n\
        `clang --target=%s` and no link path can write `./%s`.\n\n"
       (fst tc.cross) tname) ;
  s (Printf.sprintf
       "The build knobs and why `make %s` refuses:\n" tname) ;
  s "`hetlitmus/docs/het-emission.md`.\n\n" ;
  s (Printf.sprintf "Target: %s %s.\n" d.gd_vendor d.gd_name) ;
  s (Printf.sprintf
       "Pair: `%s` -- the CPU ISA and GPU dialect this harness was built\n"
       pair_label) ;
  s "for, stamped as HET_PAIR_NAME; results are filed under it, and it names\n" ;
  s "no machine.\n"

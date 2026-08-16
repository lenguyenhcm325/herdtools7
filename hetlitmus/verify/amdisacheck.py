#!/usr/bin/env python3
"""
amdisacheck.py -- the ISA read-back gate: the AMD GPU instructions hipcc
generates for an emitted harness carry exactly the ordering effects its
.litmus annotates.

    .litmus annotation --(litmus/HipLang.ml)--> .hip --(hipcc -S)--> gfx ISA
        --(a per-generation lowering profile)--> abstract token stream
        == the token stream the annotation's memory-model row prescribes ?

What it proves.  Every access and cache operation the compiler emitted inside
the kernel's own symbol is read back and mapped, through the profile, to an
abstract token (kind, width class, scope, returns-value).  The basic blocks
carrying tokens are then the multiset of sequences the harness prescribes --
one per proc (gpu-only) or per barrier-joining lane (het), each in emitted
order, holding exactly the tokens the AMDGPU memory-model code sequence for
that (kind, order, scope) asks for: the access with its scope's cache bits, the
writeback ahead of a release, the invalidate behind an acquire, and the wait
the row requires between an acquire access and its invalidate.  The het
scaffolding -- rendezvous arrive and spin, window-opener spin, observer snoop
-- is the block population the lane plan predicts, and a whole-kernel token
census is a second, independent net over the counts the block match cannot see.

What it does not prove.  Nothing is launched; no device is needed.  Three
gaps are structural, not incidental:

  * At workgroup scope the generated code witnesses NO order.  Those rows ask
    for no cache operation at all, only a counter wait, and a wait is a token
    here only immediately before an invalidate: a relaxed and a release store
    carry the same tokens, so do a relaxed and an acquire load, and a seq_cst
    workgroup fence carries none.  Those annotations rest on the HIP source
    gate (hipsrccheck.py) alone.
  * At agent and system scope order is witnessed as the presence and relative
    position of the ordering effect, never as its attribution: an acquire load
    and a relaxed load followed by an acquire fence are the same instructions,
    as are a release store and a release fence followed by a relaxed store.
    Which annotation produced an effect is again the source gate's to say.
  * That match is a multiset equality over every expected sequence, so any
    permutation of them across procs, lanes or co-running instances reads as no
    change -- an ordering effect moved out of the test instance's lane and into
    its mu(T) control's lane included, and not merely a swap of two symmetric
    procs.  The source gate carries that attribution, comparing each lane's ops
    in order and binding each instance's aliases; a permutation here could only
    come from one there, a compiler having no way to move code across mutually
    exclusive blockIdx/threadIdx guards.  What is established here is that the
    multiset of per-lane lowerings is the expected one and that nothing else
    bit-carrying exists.

Also unmodelled by construction: an access carrying no cache bits (the result
buffers, the scratch counters, a discarded agent-scope RMW) is dropped with the
plain accesses, since at ISA level it names no scope; an unmatched basic block
may hold loads (the interconnect-noise reader lives in one); and one compile
under the shipped flags is read, with -S bounded against the shipped object by
the disassembly cross-check --reps and --all both run.  Two census figures are
how many copies this toolchain makes of a loop-carried scaffolding read, so a
toolchain bump can redden them; that is a profile re-derivation, logged, not a
loosened check.

Why reading -S is sound.  Spatially, every token is attributed to the kernel's
own mangled symbol, and a second function symbol in the output is refused
rather than skipped.  For membership, every bit-carrying access and cache
operation inside that symbol is either matched to an expected token or sits in
an unmatched block that holds loads only.  For order, the token order inside a
block is the emitted order, and a reorder of two model ops is
machine-scheduler-excluded (an ordered memory operand makes the instruction the
scheduler's barrier chain, [LLVMSched]), IR-optimizer-unverified (nothing here
bounds a mid-level pass) and probe-unobserved.

Exit 0 = PASS, 1 = FAIL, 2 = completeness hard-fail, 3 = error.

Extending to another GPU generation: fetch that generation's "Memory Model
GFX<NNN>" section of [AMDGPUUsage], derive its code-sequence rows, its
assembler-directive preconditions, its scaffolding signatures and its bite
mutations into a new LoweringProfile, then run `--arch gfxNNN --reps` on that
toolchain.  A generation's target name is spelled inside its profile and
nowhere else; the target-name prefix and the vendor's offload triple, which
every generation shares, are machinery.

ptxcheck.py is the NVIDIA read-back twin and hipsrccheck.py the HIP source
gate; both are imported, never modified.  Their .litmus parsers, control-map
loader, lane plan and emit recipe are the expected side here too.

Usage:
  amdisacheck.py TEST.litmus [--arch gfxNNN] [--asm F] [-q]
  amdisacheck.py --all [--gpu-dir D] [--x86-dir D] [--jobs N] [--arch gfxNNN]
  amdisacheck.py --reps [--arch gfxNNN]
  amdisacheck.py --bite [--arch gfxNNN]
  amdisacheck.py --guard
"""

import argparse
import collections
import concurrent.futures
import contextlib
import importlib.util
import io
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))            # hetlitmus/verify
PTXCHECK = os.path.join(HERE, "ptxcheck.py")
HIPSRCCHECK = os.path.join(HERE, "hipsrccheck.py")

# hipcc is resolved the way hetlitmus/compile-hip.sh resolves it; the two LLVM
# tools the disassembly cross-check needs are not on PATH in every ROCm
# install, so each falls back to the toolchain's own bin directory.
HIPCC = shutil.which("hipcc") or "/opt/rocm/bin/hipcc"
OBJDUMP = shutil.which("llvm-objdump") or "/opt/rocm/llvm/bin/llvm-objdump"
BUNDLER = (shutil.which("clang-offload-bundler")
           or "/opt/rocm/llvm/bin/clang-offload-bundler")


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


ptx = _load("ptxcheck", PTXCHECK)
hip = _load("hipsrccheck", HIPSRCCHECK)
CompletenessError = ptx.CompletenessError
GateError = hip.GateError


# ===========================================================================
# 1. The abstract token -- generation-independent
# ===========================================================================

# kind: LD / ST / ATOMIC access the address space; WBL2 writes the cache back
# and INV invalidates it; WAIT is the profile-required wait a row places before
# an invalidate.  width is the access width class, which is emitter-owned: a
# model location is one C object per path (litmus/gpuLang.ml declares them int*,
# litmus/hetEmit.ml uint64_t*) and an atomic is never vectorized or split, so
# the width the compiler picks is the one the source names.  scope is the
# .litmus scope the profile decodes the access's cache annotation to, or None
# when it carries none.  ret is set on an RMW whose result is used.
Token = collections.namedtuple("Token", "kind width scope ret")

LD, ST, ATOMIC, WBL2, INV, WAIT = "LD", "ST", "ATOMIC", "WBL2", "INV", "WAIT"
ACCESS_KINDS = (LD, ST, ATOMIC)
CACHE_KINDS = (WBL2, INV)
WAIT_TOKEN = Token(WAIT, None, None, False)

# The width class of one model location, per emitter.  A gpu-only kernel takes
# int* globals (litmus/gpuLang.ml dump_test), a het kernel uint64_t* ones so a
# store can carry its writer tag (litmus/hetEmit.ml).
MODEL_WIDTH_GPU_ONLY = 32
MODEL_WIDTH_HET = 64


def fmt(t):
    if t.kind == WAIT:
        return "wait"
    if t.kind in CACHE_KINDS:
        return "%s(%s)" % (t.kind.lower(), t.scope)
    return "%s%s(%s%s)" % (t.kind.lower(), t.width or "?", t.scope or "-",
                           ",ret" if t.ret else "")


def fmt_seq(seq):
    return "[%s]" % " ".join(fmt(t) for t in seq)


# ===========================================================================
# 2. THE LOWERING PROFILE -- everything one GPU generation spells for itself
# ===========================================================================

# One text mutation a profile owns, so the bite driver stays generic.  `needs'
# names what a carrier render must hold -- a (kind, order, scope) row, `het'
# for any het render, `het-obs' for one whose lane plan has an observer lane.
# `apply' rewrites the -S text and refuses an absent anchor: an injection that
# changed nothing would report a pass for a corruption never presented.
Mutation = collections.namedtuple("Mutation", "label needs rc want apply")


def _sub_first(text, pattern, repl, what):
    new, n = re.subn(pattern, repl, text, count=1, flags=re.M)
    if n != 1:
        raise GateError("mutation anchor %s is absent from the assembly" % what)
    return new


def _sub_all(text, pattern, repl, what):
    """The same, over every occurrence: a directive the profile asserts is not
    promised to be written once, and leaving a second copy behind would leave
    the assertion holding."""
    new, n = re.subn(pattern, repl, text, flags=re.M)
    if not n:
        raise GateError("mutation anchor %s is absent from the assembly" % what)
    return new


class LoweringProfile(object):
    """How one GPU generation spells the memory model, and nothing else.

    A profile answers four questions and owns its own mutations:
    which assembler directives must hold before its rows mean anything
    (`preconditions'); which instructions are memory operations and what
    abstract token each one is (`classify'); what token sequence a
    (kind, order, scope) annotation lowers to (`row'); and which text
    injections must redden the gate (`mutations').  The machinery holds no
    mnemonic, no cache bit and no directive of its own."""

    name = arch = section = None
    preconditions = ()
    mutations = ()

    def classify(self, mnemonic, operands, where):
        raise NotImplementedError

    def row(self, kind, order, scope, width, ret=False):
        raise NotImplementedError


class Gfx942(LoweringProfile):
    """CDNA3 (MI300 family).

    Rows are read off the "AMDHSA Memory Model Code Sequences GFX942" table of
    [AMDGPUUsage], each keyed below by its line in that section's source.  A
    cache bit set is a scope -- sc0 workgroup, sc1 agent, both system, none no
    scope at all -- with the atomic as the exception: it spends sc0 on
    "returns the original value" and keeps only sc1 for scope (:11154), so a
    discarded agent-scope RMW is bit-less and workgroup and agent are
    indistinguishable on an RMW.  At workgroup scope the ordering rows ask for
    no cache operation and differ only by a counter wait, which the table
    places in both TgSplit branches and which is glue here; the acquire load's
    invalidate is the branch `.amdhsa_tg_split 0' excludes."""

    name = "gfx942"
    arch = "gfx942"
    section = "AMDHSA Memory Model Code Sequences GFX942"

    # The rows are the non-TgSplit branch of the table, and the directive says
    # which branch the compiler took; it is emitted only for targets carrying
    # the tgsplit-support feature ([AMDGPUUsage "LLVM IR Attributes"], the
    # "amdgpu-tg-split" row), which is why the list is a profile datum and not
    # a machinery constant.
    preconditions = (
        (".amdgcn_target", '"amdgcn-amd-amdhsa--gfx942"',
         "the assembly was generated for another target"),
        (".amdhsa_code_object_version", "6",
         "the kernel descriptor has another layout"),
        (".amdhsa_tg_split", "0",
         "TgSplit execution mode selects the OTHER branch of the workgroup "
         "rows, which gives the acquire load a wait and an invalidate this "
         "profile does not carry"),
    )

    # Every memory, wait and barrier instruction family this generation
    # spells, vector, scalar and LDS alike.  A mnemonic matching this that the
    # tables below cannot classify is refused: it would be a memory operation
    # the gate has no token for.  DROPPED is the one family that carries no
    # token on purpose -- the scalar loads read the kernarg segment, and no
    # atomic is ever lowered to one.
    FAMILY = re.compile(r'^(global|flat|buffer|scratch|ds|tbuffer|image)_'
                        r'|^s_(load|store|buffer|atomic|dcache|atc|mem)'
                        r'|^s_wait|^s_barrier')
    DROPPED = ("s_load",)

    # mnemonic head -> access kind, and the data-width suffix of an access.
    ACCESS = {"global_load": LD, "flat_load": LD, "buffer_load": LD,
              "global_store": ST, "flat_store": ST, "buffer_store": ST,
              "global_atomic": ATOMIC, "flat_atomic": ATOMIC,
              "buffer_atomic": ATOMIC}
    WIDTH = {"dword": 32, "dwordx2": 64}
    # An RMW spells its width in the operation suffix: bare is 32-bit, _x2 64.
    ATOMIC_X2 = "_x2"
    CACHE = {"buffer_wbl2": WBL2, "buffer_inv": INV}
    WAITS = ("s_waitcnt",)

    # The cache annotation vocabulary, and the scope each bit set names on a
    # non-atomic access or a cache operation.  A set outside this map is
    # refused rather than compared -- `nt' is a real bit of this generation
    # whose effect no row here models.
    BITS = ("sc0", "sc1", "nt")
    SCOPE_OF_BITS = {frozenset(("sc0",)): "cta",
                     frozenset(("sc1",)): "gpu",
                     frozenset(("sc0", "sc1")): "sys",
                     frozenset(): None}
    BITS_OF_SCOPE = {"cta": ("sc0",), "gpu": ("sc1",), "sys": ("sc0", "sc1")}
    # sc0 on an RMW means the original value is returned, not workgroup scope.
    ATOMIC_RETURNS = "sc0"
    ATOMIC_SYSTEM = "sc1"

    # Anything else in an operand list is a modifier this profile has no model
    # for, so the operand shapes it does know are enumerated.
    OPERAND = re.compile(
        r'^([vsa](\[\d+:\d+\]|\d+)|off|null|vcc|exec|-?\d+|0x[0-9a-f]+'
        r'|offset:-?\d+)$')

    def classify(self, mnemonic, operands, where):
        """(token, is_memory) for one instruction line.

        is_memory says the mnemonic belongs to this generation's memory
        instruction family, so a caller can refuse an unclassifiable one."""
        if any(mnemonic.startswith(pre) for pre in self.DROPPED):
            return None, False
        fam = bool(self.FAMILY.match(mnemonic))
        if mnemonic in self.WAITS:
            return WAIT_TOKEN, True                 # masks are never compared
        if mnemonic in self.CACHE:
            return (Token(self.CACHE[mnemonic], None,
                          self._scope(mnemonic, operands, where), False), True)
        head, width = self._split(mnemonic)
        if head is None:
            return None, fam
        kind = self.ACCESS[head]
        bits = self._bits(mnemonic, operands, where)
        if kind is ATOMIC:
            ret = self.ATOMIC_RETURNS in bits
            scope = "sys" if self.ATOMIC_SYSTEM in bits else ("gpu" if ret else None)
            unknown = bits - set((self.ATOMIC_RETURNS, self.ATOMIC_SYSTEM))
            if unknown:
                raise CompletenessError(
                    "%s: %r carries the cache bit(s) %s, which no atomic row of "
                    "%s models" % (where, mnemonic, " ".join(sorted(unknown)),
                                   self.section))
            return Token(ATOMIC, width, scope, ret), True
        return Token(kind, width, self._scope(mnemonic, operands, where, bits),
                     False), True

    def _split(self, mnemonic):
        """(access family, width class) of an access mnemonic, or (None, None)."""
        for head, _kind in self.ACCESS.items():
            if not mnemonic.startswith(head):
                continue
            suffix = mnemonic[len(head):].lstrip("_")
            if self.ACCESS[head] is ATOMIC:
                return head, (64 if suffix.endswith(self.ATOMIC_X2) else 32)
            if suffix in self.WIDTH:
                return head, self.WIDTH[suffix]
            raise CompletenessError(
                "unknown access width suffix %r on %r -- %s maps only %s"
                % (suffix, mnemonic, self.section,
                   ", ".join(sorted(self.WIDTH))))
        return None, None

    def _bits(self, mnemonic, operands, where):
        got, unknown = set(), []
        for tok in operands.replace(",", " ").split():
            if tok in self.BITS:
                got.add(tok)
            elif not self.OPERAND.match(tok):
                unknown.append(tok)
        if unknown:
            raise CompletenessError(
                "%s: %r carries the operand token(s) %s, which are neither an "
                "operand shape nor a cache bit this profile models"
                % (where, mnemonic, " ".join(unknown)))
        return got

    def _scope(self, mnemonic, operands, where, bits=None):
        b = frozenset(self._bits(mnemonic, operands, where)
                      if bits is None else bits)
        if b not in self.SCOPE_OF_BITS:
            raise CompletenessError(
                "%s: %r carries the cache bit set {%s}, which names no scope in "
                "%s" % (where, mnemonic, " ".join(sorted(b)), self.section))
        return self.SCOPE_OF_BITS[b]

    # --- the rows ---------------------------------------------------------
    #
    # [AMDGPUUsage "AMDHSA Memory Model Code Sequences GFX942"], each row keyed
    # by its line in that section's source.  A row that requires a wait before
    # its invalidate carries the wait token; every other wait the compiler
    # emits is glue whose mask and position it decides.  The table spells a
    # seq_cst RMW as the acq_rel RMW of the same scope (:13452) and a seq_cst
    # fence as the acq_rel fence (:13457), while a seq_cst load is the acquire
    # load of the same scope behind a leading wait (:13354) that the filter
    # below drops with the other glue.
    def row(self, kind, order, scope, width, ret=False):
        acc = lambda k, s: Token(k, width, s, False)
        wbl2 = lambda s: Token(WBL2, None, s, False)
        inv = lambda s: Token(INV, None, s, False)
        key = (kind, order, scope)
        table = {
            ("ld", "relaxed", "cta"): [acc(LD, "cta")],              # :11321
            ("ld", "relaxed", "gpu"): [acc(LD, "gpu")],              # :11328
            ("ld", "relaxed", "sys"): [acc(LD, "sys")],              # :11330
            ("ld", "acquire", "cta"): [acc(LD, "cta")],              # :11361
            ("ld", "acquire", "gpu"): [acc(LD, "gpu"), WAIT_TOKEN,
                                       inv("gpu")],                  # :11436
            ("ld", "acquire", "sys"): [acc(LD, "sys"), WAIT_TOKEN,
                                       inv("sys")],                  # :11460
            ("st", "relaxed", "cta"): [acc(ST, "cta")],              # :11334
            ("st", "relaxed", "gpu"): [acc(ST, "gpu")],              # :11336
            ("st", "relaxed", "sys"): [acc(ST, "sys")],              # :11338
            ("st", "release", "cta"): [acc(ST, "cta")],              # :11969
            ("st", "release", "gpu"): [wbl2("gpu"), acc(ST, "gpu")],  # :12008
            ("st", "release", "sys"): [wbl2("sys"), acc(ST, "sys")],  # :12064
            ("fence", "sc", "cta"): [],                              # :12934
            ("fence", "sc", "gpu"): [wbl2("gpu"), WAIT_TOKEN,
                                     inv("gpu")],                    # :13044
            ("fence", "sc", "sys"): [wbl2("sys"), WAIT_TOKEN,
                                     inv("sys")],                    # :13148
            ("fence", "acquire", "sys"): [WAIT_TOKEN, inv("sys")],   # :11886
            ("fence", "release", "sys"): [wbl2("sys")],              # :12392
            # Scaffolding orders, which no .litmus column names.
            ("ld", "sc", "sys"): [acc(LD, "sys"), WAIT_TOKEN,
                                  inv("sys")],                       # :13354
            ("rmw", "relaxed", "gpu"): [Token(ATOMIC, width,
                                              "gpu" if ret else None,
                                              ret)],                 # :11345
            ("rmw", "sc", "sys"): [wbl2("sys"),
                                   Token(ATOMIC, width, "sys", ret),
                                   WAIT_TOKEN, inv("sys")],          # :12690
            # A volatile non-atomic access is system-coherent by the table.
            ("vld", "-", "sys"): [acc(LD, "sys")],                   # :11254
        }
        if key not in table:
            raise CompletenessError(
                "%s has no row for %s[%s,%s] -- derive it from %s before the "
                "gate can compare it" % (self.name, kind, order, scope,
                                         self.section))
        return table[key]

    # --- the mutations this profile owes the bite driver -------------------
    mutations = (
        Mutation("the buffer_inv behind an acquire load DELETED",
                 ("ld", "acquire", "sys"), 1, "no basic block carries",
                 lambda t: _sub_first(t, r'^\tbuffer_inv sc0 sc1\n', '',
                                      "a system-scope buffer_inv")),
        Mutation("the buffer_wbl2 ahead of a release store DELETED",
                 ("st", "release", "sys"), 1, "no basic block carries",
                 lambda t: _sub_first(t, r'^\tbuffer_wbl2 sc0 sc1\n', '',
                                      "a system-scope buffer_wbl2")),
        Mutation("a system-scope access NARROWED to agent scope",
                 ("st", "relaxed", "sys"), 1, "no basic block carries",
                 lambda t: _sub_first(t, r'^(\tglobal_(?:load|store)_dword.*) '
                                         r'sc0 sc1$', r'\1 sc1',
                                      "a system-scope model access")),
        Mutation("the row-required wait between an acquire load and its "
                 "buffer_inv DELETED",
                 ("ld", "acquire", "sys"), 1, "no basic block carries",
                 lambda t: _sub_first(t, r'^\ts_waitcnt [^\n]*\n(\tbuffer_inv)',
                                      r'\1',
                                      "a wait ahead of a buffer_inv")),
        Mutation("an ordering effect no lane asks for INSERTED after a "
                 "system-scope load",
                 ("ld", "relaxed", "sys"), 1, "no lane accounts for",
                 lambda t: _sub_first(t, r'^(\tglobal_load_dword.* sc0 sc1)$',
                                      r'\1\n\ts_waitcnt vmcnt(0)\n'
                                      r'\tbuffer_inv sc0 sc1',
                                      "a system-scope model load")),
        Mutation("a non-temporal bit APPENDED to a model access",
                 ("st", "relaxed", "sys"), 2, "names no scope in",
                 lambda t: _sub_first(t, r'^(\tglobal_store_dword.* sc0 sc1)$',
                                      r'\1 nt', "a system-scope model store")),
        Mutation("the window-opener's RMW WIDENED to system scope",
                 "het", 1, "window-opener-arrive",
                 lambda t: _sub_first(t, r'^(\tglobal_atomic_add [^\n]*) sc0$',
                                      r'\1 sc0 sc1',
                                      "an agent-scope returning RMW")),
        Mutation("a scoped store PLANTED in a block no lane accounts for",
                 "het", 1, "no lane accounts for",
                 lambda t: _sub_first(t, r'^(\tflat_load_dwordx2 [^\n]*)$',
                                      r'\1\n\tglobal_store_dwordx2 v0, v[0:1], '
                                      r's[0:1] sc0 sc1',
                                      "the interconnect-noise reader")),
        Mutation("an observer lane's snoop DELETED",
                 "het-obs", 1, ":obs [",
                 lambda t: _sub_first(t, r'^\tglobal_load_dwordx2 [^\n]* '
                                         r'sc0 sc1\n', '',
                                      "a system-scope 64-bit model load")),
        Mutation("an observer lane's snoop NARROWED to agent scope",
                 "het-obs", 1, ":obs [",
                 lambda t: _sub_first(t, r'^(\tglobal_load_dwordx2 [^\n]*) '
                                         r'sc0 sc1$', r'\1 sc1',
                                      "a system-scope 64-bit model load")),
        Mutation("the whole seq_cst fence lowering STRIPPED",
                 ("fence", "sc", "sys"), 1, "no basic block carries",
                 lambda t: _sub_first(t, r'^\tbuffer_wbl2 sc0 sc1\n'
                                         r'\ts_waitcnt [^\n]*\n'
                                         r'\tbuffer_inv sc0 sc1\n', '',
                                      "a system-scope fence lowering")),
        Mutation("only the invalidate of a seq_cst fence DELETED, its "
                 "writeback and wait left in place",
                 ("fence", "sc", "sys"), 1, "no basic block carries",
                 lambda t: _sub_first(t, r'^(\tbuffer_wbl2 sc0 sc1\n'
                                         r'\ts_waitcnt [^\n]*\n)'
                                         r'\tbuffer_inv sc0 sc1\n', r'\1',
                                      "a system-scope fence lowering")),
        Mutation("a model store DELETED",
                 ("st", "relaxed", "sys"), 1, "no basic block carries",
                 lambda t: _sub_first(t, r'^\tglobal_store_dword[^\n]* sc0 sc1\n',
                                      '', "a system-scope store")),
        Mutation("a bit-less store PLANTED between a row-required wait and the "
                 "invalidate it guards",
                 ("ld", "acquire", "sys"), 1, "no basic block carries",
                 lambda t: _sub_first(t, r'^(\ts_waitcnt [^\n]*\n)'
                                         r'(\tbuffer_inv sc0 sc1\n)',
                                      r'\1\tglobal_store_dword v0, v1, s[6:7]\n\2',
                                      "a wait ahead of a buffer_inv")),
        Mutation("the rendezvous invalidate NARROWED to agent scope",
                 "het", 1, "rendezvous-arrive",
                 lambda t: _sub_first(t, r'^(\tglobal_atomic_add [^\n]* sc1\n'
                                         r'\ts_waitcnt [^\n]*\n'
                                         r'\tbuffer_inv) sc0 sc1$', r'\1 sc1',
                                      "the rendezvous arrival")),
        Mutation("the rendezvous spin's load DELETED",
                 "het", 1, "rendezvous-spin",
                 lambda t: _sub_first(t, r'^\tglobal_load_dword [^\n]* sc0 sc1\n',
                                      '', "the rendezvous spin")),
        Mutation("the window-opener's arrival DELETED",
                 "het", 1, "window-opener-arrive",
                 lambda t: _sub_first(t, r'^\tglobal_atomic_add [^\n]* sc0\n', '',
                                      "an agent-scope returning RMW")),
        # The poll shares its lowering with the folded counter reads, which
        # sit in load-only blocks the tail policy admits, so the block match
        # matches one of those in its place and the census is what sees it gone.
        Mutation("the window-opener's poll DELETED",
                 "het", 1, "ld32(gpu), the lane plan accounts for",
                 lambda t: _sub_first(t, r'^\tglobal_load_dword '
                                         r'(?![^\n]*sc0)[^\n]* sc1\n', '',
                                      "an agent-scope scaffolding load")),
        Mutation("one co-run instance's two-load model block DELETED",
                 "het", 1, ":P1 [ld64(sys) ld64(sys)]",
                 lambda t: _sub_first(t, r'^\tglobal_load_dwordx2 [^\n]* sc0 sc1\n'
                                         r'\tglobal_load_dwordx2 [^\n]* sc0 sc1\n',
                                      '',
                                      "two adjacent 64-bit system-scope loads")),
        Mutation("a cache invalidate PLANTED in a block no lane accounts for",
                 "het", 1, "no lane accounts for",
                 lambda t: _sub_first(t, r'^(\tflat_load_dwordx2 [^\n]*)$',
                                      r'\1\n\tbuffer_inv sc0 sc1',
                                      "the interconnect-noise reader")),
        # A bit-less access names no scope, so the block match filters it out
        # and the census exempts it; the multiple-of-copies law is the ONLY net
        # left under it.
        Mutation("one access of the inlined stress body DELETED",
                 "het", 1, "ld32(-), which is not a positive multiple",
                 lambda t: _sub_first(t, r'^\tglobal_load_dword '
                                         r'(?![^\n]*sc[01])[^\n]*\n', '',
                                      "a bit-less 32-bit load")),
    )


PROFILES = {p.arch: p() for p in (Gfx942,)}
# What the emitted comp.sh compiles for by default (litmus/hetDialect.ml).
DEFAULT_ARCH = Gfx942.arch


def generation_of(arch):
    """The generation one target's [AMDGPUUsage] memory-model section is titled
    after: the target-name prefix every AMD generation shares, dropped."""
    return re.sub(r'^gfx', '', arch).upper()


def profile_for(arch):
    """The lowering profile for one target, or a refusal naming the section of
    [AMDGPUUsage] a new one is derived from."""
    if arch in PROFILES:
        return PROFILES[arch]
    gen = generation_of(arch)
    raise CompletenessError(
        "no lowering profile for %s -- derive one from the \"Memory Model "
        "GFX%s\" section of the AMDGPU backend user guide (known: %s)"
        % (arch, gen, ", ".join(sorted(PROFILES))))


# ===========================================================================
# 3. EMIT and COMPILE
# ===========================================================================

# The flags the harness itself compiles with -- the emitted comp.sh runs
# `$HIPCC --offload-arch=$HIP_ARCH -std=c++17 -c <test>.hip', and
# hetlitmus/compile-hip.sh the same without -c.  Reading a different flag set
# than the one that ships would leave the gate checking another program.
# --offload-device-only -S turns that compile into readable device text, and
# -I the render's own directory keeps its includes resolvable when it is
# compiled from elsewhere; nothing else is added.  --offload-device-only makes
# --hip-link unused, which is the one diagnostic the compile is expected to
# print.
COMPILE_FLAGS = ("-std=c++17", "--offload-device-only", "-S")
BENIGN_DIAGNOSTIC = ("clang++: warning: argument unused during compilation: "
                     "'--hip-link'")


def _run(cmd):
    return subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          text=True)


def require_tool(path, what):
    if not (os.path.isabs(path) and os.path.exists(path)) and not shutil.which(path):
        raise GateError(
            "%s is not resolvable at %s -- the gate reads generated code, so an "
            "absent toolchain is a refusal, never a skipped check" % (what, path))
    return path


def diagnostics(out):
    """Compiler output with the one expected diagnostic removed, so the rest is
    surfaced instead of being lost in an ignored stream."""
    return [l for l in out.splitlines()
            if l.strip() and BENIGN_DIAGNOSTIC not in l]


def compile_asm(hip_path, arch, out_s):
    """The device assembly of one render, under the shipped flags."""
    require_tool(HIPCC, "hipcc")
    cmd = [HIPCC, "--offload-arch=" + arch] + list(COMPILE_FLAGS) \
        + ["-I", os.path.dirname(os.path.abspath(hip_path)), hip_path, "-o", out_s]
    r = _run(cmd)
    if r.returncode != 0 or not os.path.exists(out_s):
        raise GateError("hipcc failed for %s (--offload-arch=%s):\n%s"
                        % (hip_path, arch, r.stdout))
    return diagnostics(r.stdout)


# ===========================================================================
# 4. READING THE ASSEMBLY -- symbol, region, basic blocks, tokens
# ===========================================================================

FUNC_SYMBOL = re.compile(r'^\s*\.type\s+([\w.$]+)\s*,\s*@function\s*$')
MANGLED = re.compile(r'^_Z(\d+)(\w+)')
BLOCK_LABEL = re.compile(r'^(\.LBB\d+_\d+):')
BLOCK_MARKER = re.compile(r'^;\s*(%bb\.\d+):')
SECTION = re.compile(r'^\s*\.section\b')
INSTRUCTION = re.compile(r'^\s+([a-z][\w.]*)\b(.*)$')


def c_ident(name):
    """The C identifier litmus7 makes of a test name for its kernel symbol."""
    return re.sub(r'[^A-Za-z0-9_]', '_', name)


def kernel_lines(text, tname, path):
    """The kernel's own instruction lines, and its symbol.

    Exactly one function symbol may exist: a second one is a device helper the
    compiler did not inline, whose instructions belong to no lane and would be
    attributed to whichever block they landed in.  That is a refusal, not a
    silent skip."""
    lines = text.splitlines()
    syms = [m.group(1) for m in (FUNC_SYMBOL.match(l) for l in lines) if m]
    if len(syms) != 1:
        raise GateError(
            "%s carries %d @function symbol(s) (%s); the gate attributes every "
            "token to the kernel's own symbol, so a second one is unreadable"
            % (path, len(syms), ", ".join(syms) or "none"))
    sym = syms[0]
    want = "litmus_" + c_ident(tname)
    m = MANGLED.match(sym)
    if not m or not m.group(2).startswith(want) or int(m.group(1)) != len(want):
        raise GateError(
            "%s: the function symbol %r is not the mangled kernel of %s "
            "(expected _Z%d%s...)" % (path, sym, tname, len(want), want))
    start = next((i for i, l in enumerate(lines)
                  if l.startswith(sym + ":")), None)
    if start is None:
        raise GateError("%s: no label for %s" % (path, sym))
    end = len(lines)
    for j in range(start + 1, len(lines)):
        # The kernel descriptor follows the last instruction as its own
        # section; it is data, not code, and it is what ends the region.
        if SECTION.match(lines[j]):
            end = j
            break
    return sym, lines[start + 1:end]


def split_blocks(klines):
    """The kernel's basic blocks, in text order, as (label, [lines]).

    Block order is not proc order -- the compiler is free to lay a lane's block
    anywhere, and does -- so blocks are matched by their contents, never by
    position."""
    blocks = [("entry", [])]
    for l in klines:
        m = BLOCK_LABEL.match(l) or BLOCK_MARKER.match(l)
        if m:
            blocks.append((m.group(1), []))
            continue
        blocks[-1][1].append(l)
    return blocks


def strip_comment(line):
    for mark in (";", "//"):
        i = line.find(mark)
        if i >= 0:
            line = line[:i]
    return line


def classify_lines(profile, lines, where):
    """The abstract tokens of a run of instruction lines, in emitted order.

    A mnemonic in the profile's memory family that it cannot classify is a
    memory operation with no token, and is refused."""
    out = []
    for raw in lines:
        l = strip_comment(raw)
        if not l.strip() or l.lstrip().startswith("."):
            continue
        m = INSTRUCTION.match(l)
        if not m:
            continue
        tok, is_mem = profile.classify(m.group(1), m.group(2), where)
        if tok is None:
            if is_mem:
                raise CompletenessError(
                    "%s: %r is a memory instruction of %s that the profile maps "
                    "to no token" % (where, m.group(1), profile.name))
            continue
        out.append(tok)
    return out


def filter_tokens(tokens):
    """The compared stream: scoped accesses and cache operations, plus the wait
    a row requires ahead of an invalidate with no memory operation between.

    That wait is read off the unfiltered stream, so traffic the scope filter
    drops still separates it from the invalidate.  An access carrying no cache
    bits names no scope at ISA level, so it is dropped with the plain
    result-buffer and counter traffic the census below accounts for, and every
    other wait is glue whose mask and position the compiler decides."""
    out = []
    for i, t in enumerate(tokens):
        if t.kind == WAIT:
            nxt = tokens[i + 1] if i + 1 < len(tokens) else None
            if nxt is None or nxt.kind != INV:
                continue
        elif t.kind in ACCESS_KINDS and t.scope is None:
            continue
        out.append(t)
    return out


def read_assembly(profile, text, tname, path):
    """(per-block filtered token sequences, whole-kernel census, symbol).

    The census counts every classified token, the dropped ones included, so the
    count laws can see traffic the block match drops."""
    sym, klines = kernel_lines(text, tname, path)
    blocks, census = [], collections.Counter()
    for label, lines in split_blocks(klines):
        toks = classify_lines(profile, lines, "%s %s" % (path, label))
        census.update(t for t in toks if t.kind != WAIT)
        toks = filter_tokens(toks)
        if toks:
            blocks.append((label, toks))
    return blocks, census, sym


def kernel_token_stream(profile, text, tname, path):
    """One token stream for the whole kernel, block structure ignored.

    The disassembly cross-check has no block structure to read, so both routes
    are compared this way."""
    _sym, klines = kernel_lines(text, tname, path)
    return filter_tokens(classify_lines(profile, klines, path))


# ===========================================================================
# 5. THE EXPECTED SIDE
# ===========================================================================

# What a het lane runs around its model ops, as the (kind, order, scope,
# returns) the runtime source asks for; the profile turns each into tokens.
# The rendezvous joins both devices once per lane (litmus/hetDialect.ml gd_bar),
# the window-opener aligns one instance's GPU lanes inside the iteration loop
# and the observer snoops one location per iteration (gd_sys_load_u64).
SCAFFOLD_WIDTH = 32
RENDEZVOUS_ARRIVE = ("rmw", "sc", "sys", False)
RENDEZVOUS_SPIN = ("ld", "sc", "sys", False)
WINDOW_ARRIVE = ("rmw", "relaxed", "gpu", True)
WINDOW_POLL = ("ld", "relaxed", "gpu", False)
OBSERVER_LOAD = ("ld", "relaxed", "sys", False)
# Counter traffic the block match drops but the census pins
# (litmus/het-runtime/het_stress.h).  het_scratch_bump lands once per
# barrier-joining lane, once per test lane inside the window-opener and twice
# across the stress and noise regions; het_scratch_max once per inlined stress
# copy and once in the noise region.  The abstract token does not name the
# operation an RMW performs, so the two are counted as one sum.
DISCARDED_RMW = ("rmw", "relaxed", "gpu", False)
# Two reads the compiler copies out of the loops they are the condition or the
# body of: het_scratch_read, which guards both stress-round loops, and the
# interconnect-noise reader's one volatile access.  Each count is what this
# toolchain lays down, and a toolchain that rotates those loops differently
# reddens the census rather than passing quietly.
SCRATCH_READ = ("ld", "relaxed", "gpu", False)
SCRATCH_READ_COPIES = 3
NOISE_READ = ("vld", "-", "sys", False)
NOISE_READ_COPIES = 2


def _seq(profile, spec, width):
    kind, order, scope, ret = spec
    return profile.row(kind, order, scope, width, ret=ret)


def _one(profile, spec, width):
    s = _seq(profile, spec, width)
    if len(s) != 1:
        raise GateError("%s lowers %s to %d tokens, not one"
                        % (profile.name, spec[:3], len(s)))
    return s[0]


def model_tokens(profile, ops, width):
    out = []
    for kind, order, scope in ops:
        out.extend(profile.row(kind, order, scope, width))
    return out


def expected_gpu_only(profile, inst):
    """One block per proc, holding that column's model ops in column order."""
    return [("P%d" % pidx, model_tokens(profile, ops, MODEL_WIDTH_GPU_ONLY))
            for pidx, ops in inst['gpu']]


def read_registers(cells):
    """The distinct destinations of a column's loads, in column order: one
    result store each (litmus/hetEmit.ml)."""
    regs = []
    for kind, _o, _s, dst, _v in cells:
        if kind == 'r' and dst not in regs:
            regs.append(dst)
    return regs


def expected_het(profile, insts):
    """The blocks a het kernel owes, and the lane figures the census needs.

    Every barrier-joining lane opens with the rendezvous arrival and its spin,
    each in its own block; every test lane also carries the window-opener's
    arrival and its poll, again one block each; a test lane's model ops sit in
    one block and an observer lane's snoops in one."""
    plan = ptx.het_lane_plan([dict(gpu=i['gpu'], obs=i['obs'], name=i['label'])
                              for i in insts])
    cells_of = dict((i['label'], i['cells']) for i in insts)
    arrive = _seq(profile, RENDEZVOUS_ARRIVE, SCAFFOLD_WIDTH)
    spin = _seq(profile, RENDEZVOUS_SPIN, SCAFFOLD_WIDTH)
    w_arrive = _seq(profile, WINDOW_ARRIVE, SCAFFOLD_WIDTH)
    w_poll = _seq(profile, WINDOW_POLL, SCAFFOLD_WIDTH)
    obs_load = _one(profile, OBSERVER_LOAD, MODEL_WIDTH_HET)
    blocks, lanes, ntest, nregs, obsloc = [], [], 0, 0, 0
    for kind, pidx, payload, iname in plan:
        who = "%s:%s" % (iname, "P%d" % pidx if kind == 'test' else "obs")
        lanes.append(who)
        blocks.append(("%s rendezvous-arrive" % who, arrive))
        blocks.append(("%s rendezvous-spin" % who, spin))
        if kind == 'obs':
            blocks.append((who, [obs_load] * len(payload)))
            obsloc += len(payload)
            continue
        ntest += 1
        nregs += len(read_registers(cells_of[iname][pidx]))
        blocks.append(("%s window-opener-arrive" % who, w_arrive))
        blocks.append(("%s window-opener-poll" % who, w_poll))
        blocks.append((who, model_tokens(profile, payload, MODEL_WIDTH_HET)))
    return blocks, dict(lanes=len(plan), test=ntest, regs=nregs, obs=obsloc,
                        names=", ".join(lanes))


def het_census(profile, blocks, f):
    """The whole-kernel token census a het kernel owes: the blocks above, plus
    the traffic they drop."""
    c = collections.Counter()
    for _l, toks in blocks:
        c.update(t for t in toks if t.kind != WAIT)
    t, n = f['test'], f['lanes']
    bumps = n + t + 2
    maxes = (t + 1) + 1
    c[_one(profile, NOISE_READ, MODEL_WIDTH_HET)] += NOISE_READ_COPIES
    c[_one(profile, SCRATCH_READ, SCAFFOLD_WIDTH)] += SCRATCH_READ_COPIES
    c[_one(profile, DISCARDED_RMW, SCAFFOLD_WIDTH)] += bumps + maxes
    # One result store per read register of a test lane and per location an
    # observer lane snoops (litmus/hetEmit.ml).
    c[Token(ST, MODEL_WIDTH_HET, None, False)] += f['regs'] + f['obs']
    return c


# het_do_stress is inlined once per test lane and once in the stress region, so
# its plain traffic is a multiple of that many copies.  How many accesses one
# copy holds is a compiler and stress-body figure, not a memory-model one, so
# only the multiple is pinned -- pinning the figure would redden the gate on a
# toolchain bump for a reason that is not faithfulness.
INLINED_STRESS = (Token(LD, 32, None, False), Token(ST, 32, None, False))


# ===========================================================================
# 6. THE CHECKS
# ===========================================================================

class Result:
    def __init__(self):
        self.ok = True
        self.lines = []

    def fail(self, msg):
        self.ok = False
        self.lines.append("FAIL: " + msg)

    def note(self, msg):
        self.lines.append(msg)


def check_preconditions(profile, text, path):
    """Every directive the profile declares must be present and hold.

    A violated one means the rows were read for another machine or another
    execution mode, so the comparison below would be against the wrong table --
    a refusal, not a mismatch."""
    for directive, value, why in profile.preconditions:
        got = [l.split(None, 1)[1].strip() if len(l.split(None, 1)) > 1 else ""
               for l in text.splitlines() if l.split()[:1] == [directive]]
        if not got:
            raise CompletenessError(
                "%s: %s declares the precondition `%s %s', which %s does not "
                "carry at all -- %s" % (path, profile.name, directive, value,
                                        path, why))
        bad = [g for g in got if g != value]
        if bad:
            raise CompletenessError(
                "%s: %s is `%s', not `%s' -- %s"
                % (path, directive, bad[0], value, why))


def match_blocks(result, expected, actual, tail_allowed):
    """Match every expected block to a basic block by its ordered tokens.

    The compiler lays blocks in an order of its own, so the match is on
    contents, which makes it a multiset equality: any permutation of the
    expected sequences across procs, lanes or instances passes, and attributing
    an op to a lane is the source gate's job (hipsrccheck.py).  With
    tail_allowed an unmatched block may hold loads -- the interconnect-noise
    reader and the folded counter reads live in those -- and nothing else."""
    want = collections.defaultdict(list)
    empty = [lab for lab, toks in expected if not toks]
    for lab, toks in expected:
        if toks:
            want[tuple(toks)].append(lab)
    unmatched = []
    for lab, toks in actual:
        key = tuple(toks)
        if want.get(key):
            want[key].pop()
        else:
            unmatched.append((lab, toks))
    missing = [(lab, key) for key, labs in sorted(want.items())
               for lab in labs]
    for lab in empty:
        result.note("  %s lowers to no instruction at all, so no block carries "
                    "it" % lab)
    bad = len(missing)
    for lab, key in missing:
        result.fail("no basic block carries %s %s" % (lab, fmt_seq(key)))
    for lab, toks in unmatched:
        stray = [t for t in toks if t.kind not in (LD, WAIT)]
        if stray or not tail_allowed:
            bad += 1
            result.fail("basic block %s carries %s, which no lane accounts for"
                        % (lab, fmt_seq(toks)))
    if not bad:
        result.note("  %d expected block(s) matched, %d unmatched block(s) hold "
                    "loads only" % (len(expected) - len(empty), len(unmatched)))
    return not bad


def check_census(result, expected, census, exempt=()):
    """The whole-kernel token counts, as a second net over what the block match
    cannot see: an unmatched block's loads, and every access the scope filter
    drops."""
    bad = 0
    for tok in sorted(set(expected) | set(census), key=fmt):
        if tok in exempt:
            continue
        if expected.get(tok, 0) != census.get(tok, 0):
            bad += 1
            result.fail("the kernel holds %d %s, the lane plan accounts for %d"
                        % (census.get(tok, 0), fmt(tok), expected.get(tok, 0)))
    if not bad:
        result.note("  token census OK (%d kind(s), %d token(s))"
                    % (len(census), sum(census.values())))


def check_inlined_stress(result, census, copies):
    """The inlined stress body: present, and the same in every copy.

    Its size is a compiler and stress-body figure, so only "more than none, and
    a whole number of copies" is asked of it."""
    for tok in INLINED_STRESS:
        n = census.get(tok, 0)
        if n == 0 or n % copies:
            result.fail("the kernel holds %d %s, which is not a positive "
                        "multiple of the %d inlined stress copies"
                        % (n, fmt(tok), copies))
        else:
            result.note("  inlined stress OK (%d %s = %d x %d copies)"
                        % (n, fmt(tok), n // copies, copies))


# ===========================================================================
# 7. ONE TEST
# ===========================================================================

def check_test(litmus_path, arch, asm_override=None, verbose=True):
    profile = profile_for(arch)
    inst = hip.instance_of(litmus_path)
    kind, name = inst['kind'], inst['name']
    corpus = "x86_64 het" if kind == 'Het' else "gpu-only"
    result = Result()
    result.note("=== %s [%s, %s corpus, profile %s] ==="
                % (name, kind, corpus, profile.name))
    # The whole expected side is built first, so a control map the gate cannot
    # read and an annotation the profile has no row for are each a refusal on
    # every path, including the one where no compile runs.
    insts = f = None
    if kind == 'Het':
        insts = hip.het_instances(litmus_path)
        expected, f = expected_het(profile, insts)
    else:
        expected = expected_gpu_only(profile, inst)

    tmp = tempfile.mkdtemp(prefix="amdisacheck_")
    try:
        if asm_override is not None:
            asm_path = asm_override
        else:
            hip_path, _cpu = hip.emit_harness(litmus_path, tmp)
            asm_path = os.path.join(tmp, name + ".s")
            for d in compile_asm(hip_path, arch, asm_path):
                result.note("  compiler said: %s" % d)
        result.note("  assembly %s" % asm_path)
        text = open(asm_path).read()
        check_preconditions(profile, text, asm_path)
        blocks, census, sym = read_assembly(profile, text, name, asm_path)
        result.note("  kernel %s, %d block(s) carrying tokens"
                    % (sym, len(blocks)))

        if kind == 'Het':
            if len(insts) > 1:
                result.note("  CO-RUN harness: %s"
                            % " + ".join("%s (%s)" % (i['name'], i['role'])
                                         for i in insts))
            result.note("  lane plan (x86_64 het): %d lane(s) -- %s"
                        % (f['lanes'], f['names']))
            match_blocks(result, expected, blocks, tail_allowed=True)
            check_census(result, het_census(profile, expected, f), census,
                         exempt=INLINED_STRESS)
            check_inlined_stress(result, census, f['test'] + 1)
        else:
            match_blocks(result, expected, blocks, tail_allowed=False)
            # A gpu-only kernel runs no scaffolding at all, so the only traffic
            # the scope filter drops is its result buffer, whose stores the
            # compiler is free to merge; a load or an RMW there is unaccounted.
            want = collections.Counter()
            for _l, toks in expected:
                want.update(t for t in toks if t.kind != WAIT)
            check_census(result, want, census,
                         exempt=(Token(ST, 32, None, False),
                                 Token(ST, 64, None, False)))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    if verbose:
        for ln in result.lines:
            print(ln)
    return result.ok


# ===========================================================================
# 8. THE REP SET  (--reps)
# ===========================================================================

# Each fixed het shape a rep must exist for, and the property that decides it.
# They are the shapes a lane-plan implementation gets wrong on its own: a
# co-running trio with an observer, a test whose GPU side is more than one
# lane, the system-fence carrier, and the degenerate test that IS its own
# canary and runs a single lane.
SHAPES = (
    ("co-run trio with an observer lane",
     lambda i, ins: len(ins) == 3 and any(x['obs'] for x in ins)),
    ("an IRIW with more than one GPU proc",
     lambda i, ins: i['name'].startswith("IRIW") and len(i['gpu']) >= 2),
    ("carries a system-scope seq_cst fence",
     lambda i, ins: ("fence", "sc", "sys") in
                    set(o for _p, ops in i['gpu'] for o in ops)),
    ("one instance, one lane",
     lambda i, ins: len(ins) == 1 and len(ptx.het_lane_plan(ins)) == 1),
)


def rows_of(inst):
    return set(o for _p, ops in inst['gpu'] for o in ops)


def fmt_row(row):
    return "%s[%s,%s]" % ({'st': 'w', 'ld': 'r', 'fence': 'f'}[row[0]],
                          row[1], row[2])


def corpus(tmp):
    """(gpu-only paths, x86_64 het paths), each sorted by test name.

    The het half is generated on demand -- it is not committed -- so a run can
    never read a stale one, and its census is asserted before it is used."""
    gpu = hip.corpus_files(hip.GPU_ONLY_DIR, "gpu-only", hip.GPU_ONLY_N)
    d = hip.regen_x86(os.path.join(tmp, "x86"))
    het = hip.corpus_files(d, "x86_64 het", hip.X86_HET_N)
    return gpu, het


def select_reps(gpu, het):
    """The rep set, derived from the corpus every run rather than pinned.

    Per row the first carrier by test name, a gpu-only test preferred, then one
    test per fixed het shape.  "First by name" is not stable under arbitrary
    corpus growth, which is why the coverage tripwire below reads the rows back
    off the files instead of trusting the bookkeeping here."""
    carriers, insts = {}, {}
    for path in gpu + het:
        inst = hip.instance_of(path)
        insts[path] = inst
        for row in rows_of(inst):
            carriers.setdefault(row, path)
    reps = collections.OrderedDict()
    for row, path in sorted(carriers.items()):
        reps.setdefault(path, []).append("row " + fmt_row(row))
    shapes, plans = {}, {}
    for label, holds in SHAPES:
        for path in het:
            ins = plans.setdefault(path, hip.het_instances(path))
            if holds(insts[path], ins):
                shapes[label] = path
                reps.setdefault(path, []).append("shape " + label)
                break
        else:
            raise CompletenessError(
                "no test in the x86_64 het corpus satisfies the rep shape %r -- "
                "the shape the rep stood for is no longer in the corpus" % label)
    return reps, shapes


def coverage_tripwire(profile, rep_paths, corpus_paths, shapes):
    """Recomputed every run, off the files rather than off the rep builder's
    bookkeeping: every annotation row the corpus carries is carried by a rep
    and lowered by the profile, and every fixed shape holds of its rep.

    Reading the rows again here is what makes this an audit of select_reps
    rather than a restatement of it -- a row it leaves without a carrier, a rep
    it drops and a shape it files under the wrong test are each drift the rep
    set cannot survive, and NONE of them shows in a list it built itself."""
    want, covered = set(), set()
    for path in corpus_paths:
        want |= rows_of(hip.instance_of(path))
    for path in rep_paths:
        covered |= rows_of(hip.instance_of(path))
    missing = sorted(want - covered)
    if missing:
        raise CompletenessError(
            "the rep set covers %d of %d corpus row(s); uncovered: %s"
            % (len(want & covered), len(want),
               ", ".join(fmt_row(r) for r in missing)))
    # A row the corpus carries and the profile does not lower is refused here,
    # before a compile runs, rather than on whichever rep first reaches it.
    for kind, order, scope in sorted(want):
        profile.row(kind, order, scope, MODEL_WIDTH_GPU_ONLY)
    for label, path in sorted(shapes.items()):
        holds = dict(SHAPES)[label]
        if not holds(hip.instance_of(path), hip.het_instances(path)):
            raise CompletenessError(
                "the rep %s no longer satisfies the shape %r it is in the set "
                "for" % (os.path.basename(path), label))
    return want


def mutation_carrier(mutation, rep_paths, het_paths):
    """The rep one profile mutation can be injected into, or None.

    A mutation names what a carrier must hold -- an annotation row, any het
    render, or a het render with an observer lane -- and a name the rep set
    cannot answer is a mutation whose carrier left the corpus."""
    need, het = mutation.needs, set(het_paths)
    for path in rep_paths:
        if need in ("het", "het-obs"):
            if path in het and (need == "het"
                                or any(i['obs'] for i in hip.het_instances(path))):
                return path
        elif need in rows_of(hip.instance_of(path)):
            return path
    return None


# ===========================================================================
# 9. THE DISASSEMBLY CROSS-CHECK
# ===========================================================================

# The object route: --genco is what packs a device bundle under this code
# object version (-c does not).  The bundle entry is the HIP offload triple,
# which every AMD generation shares, so it is parameterized by the target rather
# than held in a profile.
GENCO_FLAGS = ("-std=c++17", "--genco")
BUNDLE_TARGET = "hipv4-amdgcn-amd-amdhsa--%s"
DISASM_SYMBOL = re.compile(r'^[0-9a-f]+\s+<([^>]+)>:\s*$')


def disasm_lines(text, tname, path):
    """The kernel's instruction lines in a disassembly.

    A disassembly carries neither block labels nor assembler directives, so it
    can bound nothing the profile's preconditions rest on; it exists only to
    say that the assembly text is what the assembler encodes."""
    lines = text.splitlines()
    heads = [(i, m.group(1)) for i, l in enumerate(lines)
             for m in [DISASM_SYMBOL.match(l)] if m]
    if len(heads) != 1:
        raise GateError("%s carries %d symbol(s) in .text, expected the kernel "
                        "alone" % (path, len(heads)))
    i, sym = heads[0]
    want = "litmus_" + c_ident(tname)
    m = MANGLED.match(sym)
    if not m or not m.group(2).startswith(want):
        raise GateError("%s disassembles the symbol %r, not the kernel of %s"
                        % (path, sym, tname))
    return lines[i + 1:]


def crosscheck(profile, litmus_path, arch, work, doctor=None):
    """The -S token stream against the disassembly of the shipped object.

    Block structure is lost in a disassembly, so both routes are read flat.
    `doctor' rewrites the -S text after the compiler wrote it, which is the
    divergence this comparison exists to catch; the text it injects is the
    profile's, since nothing here names an instruction."""
    require_tool(BUNDLER, "clang-offload-bundler")
    require_tool(OBJDUMP, "llvm-objdump")
    name = ptx.litmus_name(ptx.read_litmus(litmus_path))
    d = os.path.join(work, "cross-" + name)
    os.makedirs(d)
    hip_path, _cpu = hip.emit_harness(litmus_path, d)
    s_path = os.path.join(d, name + ".s")
    compile_asm(hip_path, arch, s_path)
    if doctor is not None:
        text = open(s_path).read()
        open(s_path, "w").write(doctor(text))
    co = os.path.join(d, name + ".co")
    r = _run([HIPCC, "--offload-arch=" + arch] + list(GENCO_FLAGS)
             + ["-I", os.path.dirname(os.path.abspath(hip_path)), hip_path,
                "-o", co])
    if r.returncode != 0 or not os.path.exists(co):
        raise GateError("hipcc --genco failed for %s:\n%s" % (hip_path, r.stdout))
    elf = os.path.join(d, name + ".elf")
    r = _run([BUNDLER, "--unbundle", "--type=o", "--input", co,
              "--targets=" + BUNDLE_TARGET % arch, "--output", elf])
    if r.returncode != 0 or not os.path.exists(elf):
        raise GateError("clang-offload-bundler found no %s bundle in %s:\n%s"
                        % (BUNDLE_TARGET % arch, co, r.stdout))
    r = _run([OBJDUMP, "-d", "--mcpu=" + arch, elf])
    if r.returncode != 0:
        raise GateError("llvm-objdump failed on %s:\n%s" % (elf, r.stdout))
    a = kernel_token_stream(profile, open(s_path).read(), name, s_path)
    b = filter_tokens(classify_lines(profile, disasm_lines(r.stdout, name, elf),
                                     elf))
    return a, b


def crosscheck_report(profile, litmus_path, arch, work, doctor=None):
    """One cross-check, printed.  True when the two routes agree."""
    a, b = crosscheck(profile, litmus_path, arch, work, doctor=doctor)
    name = os.path.basename(litmus_path)[:-len(".litmus")]
    if a == b:
        print("  %-42s OK (%d token(s) identical)" % (name, len(a)))
        return True
    print("  %-42s DIFFERS" % name)
    print("     assembly     %s" % fmt_seq(a))
    print("     disassembly  %s" % fmt_seq(b))
    return False


def crosscheck_pair(rep, gpu_paths, het_paths):
    """The smallest and the largest shape the rep set holds: its first gpu-only
    rep, and its het rep with the most lanes."""
    gpu, het = set(gpu_paths), set(het_paths)
    hets = [p for p in rep if p in het]
    return [next(p for p in rep if p in gpu),
            max(hets, key=lambda p: (lane_count(p), os.path.basename(p)))]


# ===========================================================================
# 10. --reps
# ===========================================================================

def toolchain_banner():
    r = _run([HIPCC, "--version"])
    return (r.stdout.splitlines() or ["<no output>"])[0].strip()


def lane_count(path):
    return len(ptx.het_lane_plan(hip.het_instances(path)))


def reps(arch, verbose=True):
    profile = profile_for(arch)
    require_tool(HIPCC, "hipcc")
    print("===== ISA READ-BACK GATE (rep set): %s =====" % profile.name)
    print("  %s" % toolchain_banner())
    print("  profile %s, derived from \"%s\"" % (profile.name, profile.section))
    tmp = tempfile.mkdtemp(prefix="amdisacheck-reps.")
    t0 = time.time()
    try:
        gpu, het = corpus(tmp)
        print("  corpus: %d gpu-only + %d x86_64 het (the x86_64 rendering of "
              "the het corpus, not the AArch64 one)" % (len(gpu), len(het)))
        rep, shapes = select_reps(gpu, het)
        covered = coverage_tripwire(profile, list(rep), gpu + het, shapes)
        print("  %d row(s) in the corpus, all carried by %d rep(s)"
              % (len(covered), len(rep)))
        print("\n%-42s | %s" % ("rep", "stands for"))
        print("-" * 43 + "+" + "-" * 34)
        for path, why in rep.items():
            print("%-42s | %s" % (os.path.basename(path)[:-len(".litmus")],
                                  "; ".join(why)))
        npass = 0
        print()
        for path in rep:
            ok = check_test(path, arch, verbose=verbose)
            print("RESULT: %s" % ("PASS" if ok else "FAIL"))
            npass += 1 if ok else 0
        pair = crosscheck_pair(rep, gpu, het)
        print("\n-- the assembly against the disassembly of the shipped object --")
        nx = sum(1 for path in pair
                 if crosscheck_report(profile, path, arch, tmp))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    ok = npass == len(rep) and nx == len(pair)
    print("\nISA READ-BACK GATE (rep set): %s -- %d/%d rep(s), %d/%d "
          "cross-check(s), %d row(s) covered, %.1f s"
          % ("PASS" if ok else "FAILED", npass, len(rep), nx, len(pair),
             len(covered), time.time() - t0))
    return 0 if ok else 1


# ===========================================================================
# 11. THE CORPUS SWEEP  (--all)
# ===========================================================================

def run_check(litmus_path, arch, asm=None, verbose=True):
    """(exit code, printed output) of one check.

    Returning the exit code rather than raising is what lets the sweep and an
    injection under --bite read the same verdict the command line prints."""
    buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf):
            ok = check_test(litmus_path, arch, asm_override=asm, verbose=verbose)
            print("RESULT:", "PASS" if ok else "FAIL")
        rc = 0 if ok else 1
    except CompletenessError as e:
        buf.write("COMPLETENESS HARD-FAIL: %s\n" % e)
        rc = 2
    except GateError as e:
        buf.write("ERROR: %s\n" % e)
        rc = 3
    except Exception as e:
        buf.write("ERROR: %s: %s\n" % (type(e).__name__, e))
        rc = 3
    return rc, buf.getvalue()


def capture(fn, **override):
    """(exit code, printed output) of an in-process call, with module globals
    temporarily replaced.

    The sweep resolves its worker and its toolchain through those globals, so a
    worker that dies and an unresolvable hipcc are injections like any other."""
    g = globals()
    saved = {k: g[k] for k in override}
    g.update(override)
    buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf):
            rc = fn()
    except CompletenessError as e:
        buf.write("COMPLETENESS HARD-FAIL: %s\n" % e)
        rc = 2
    except GateError as e:
        buf.write("ERROR: %s\n" % e)
        rc = 3
    except Exception as e:
        buf.write("ERROR: %s: %s\n" % (type(e).__name__, e))
        rc = 3
    finally:
        g.update(saved)
    return rc, buf.getvalue()


def _sweep_one(job):
    """One test, as (verdict, name, output).

    A worker that raises is reported as that test's error verdict, so nothing
    here can turn an exception into a pass."""
    litmus_path, arch = job
    name = os.path.basename(litmus_path)[:-len(".litmus")]
    try:
        rc, out = run_check(litmus_path, arch)
    except Exception as e:
        return "ERROR", name, "ERROR: %s: %s\n" % (type(e).__name__, e)
    return {0: "PASS", 1: "FAIL", 2: "GUARD-FAIL"}.get(rc, "ERROR"), name, out


def sweep_dir(files, label, arch, jobs, diffs):
    """Check one corpus in a worker pool; print its table and TALLY line.

    Returns (pass, total).  Every non-PASS test's own output is written into
    [diffs] and echoed, so a failure is never reduced to a count."""
    print("\n===== lowering faithfulness: %s =====" % label)
    print("%-42s | %s" % ("test", "verdict"))
    print("-" * 43 + "+---------")
    rows = []
    try:
        with concurrent.futures.ProcessPoolExecutor(max_workers=jobs) as pool:
            for verdict, name, out in pool.map(_sweep_one,
                                               [(f, arch) for f in files]):
                rows.append((name, verdict, out))
    except concurrent.futures.BrokenExecutor as e:
        # A worker killed outright never reaches _sweep_one's own handler, and
        # the tests it held come back with no verdict at all, so the corpus is
        # refused here rather than tallied short.
        raise GateError("a sweep worker died without raising, breaking the pool "
                        "after %d of %d %s test(s): %s"
                        % (len(rows), len(files), label, e))
    rows.sort()
    for name, verdict, _out in rows:
        print("%-42s | %s" % (name, verdict))
    print("-" * 43 + "+---------")
    n = {v: sum(1 for _, w, _ in rows if w == v)
         for v in ("PASS", "FAIL", "GUARD-FAIL", "ERROR")}
    print("TALLY %s: %d/%d PASS  (FAIL=%d  GUARD-FAIL=%d  ERROR=%d)"
          % (label, n["PASS"], len(rows), n["FAIL"], n["GUARD-FAIL"], n["ERROR"]))
    if n["PASS"] != len(rows):
        print("\n--- output for every non-PASS %s test (saved in %s) ---"
              % (label, diffs))
        for name, verdict, out in rows:
            if verdict == "PASS":
                continue
            with open(os.path.join(diffs, "diff." + name), "w") as fh:
                fh.write(out)
            print(">>> %s %s" % (verdict, name))
            print(out.rstrip())
    return n["PASS"], len(rows)


def sweep(gpu_dir, x86_dir, arch, jobs):
    """Both corpora, each against its pinned census, with the rep-set tripwire
    and the cross-check reading the same generated corpus the sweep does.

    The het half is the x86_64 rendering this lane emits, NOT the AArch64 one
    ptxcheck.py reads -- the same shapes under a different CPU column -- so
    every count printed here says which corpus it counts."""
    profile = profile_for(arch)
    require_tool(HIPCC, "hipcc")
    tmp = tempfile.mkdtemp(prefix="amdisacheck-all.")
    diffs = None
    t0 = time.time()
    try:
        # Both censuses are asserted before a single render compiles: a corpus
        # that is not there cannot be reported as a corpus that passed.
        gpu_files = hip.corpus_files(gpu_dir, "gpu-only", hip.GPU_ONLY_N)
        generated = x86_dir is None
        if generated:
            x86_dir = hip.regen_x86(os.path.join(tmp, "corpus"))
        x86_files = hip.corpus_files(x86_dir, "x86_64 het", hip.X86_HET_N)
        if not os.path.exists(os.path.join(x86_dir, hip.CONTROL_MAP)):
            raise GateError(
                "no %s in the x86_64 het corpus %s -- without it every lane plan "
                "collapses to a single instance" % (hip.CONTROL_MAP, x86_dir))
        print("===== ISA READ-BACK GATE: %d gpu-only + %d x86_64 het renders ====="
              % (hip.GPU_ONLY_N, hip.X86_HET_N))
        print("  %s" % toolchain_banner())
        print("  profile     %s, derived from \"%s\""
              % (profile.name, profile.section))
        print("  gpu-only    %s" % gpu_dir)
        print("  x86_64 het  %s%s" % (x86_dir, " (generated)" if generated else ""))
        print("  workers     %d" % jobs)
        rep, shapes = select_reps(gpu_files, x86_files)
        covered = coverage_tripwire(profile, list(rep), gpu_files + x86_files,
                                    shapes)
        print("  rep set     %d rep(s) carrying all %d corpus row(s), each row "
              "lowered by the profile" % (len(rep), len(covered)))
        diffs = tempfile.mkdtemp(prefix="amdisacheck-diffs.")
        gp, gt = sweep_dir(gpu_files, "gpu-only", arch, jobs, diffs)
        xp, xt = sweep_dir(x86_files, "x86_64 het", arch, jobs, diffs)
        print("\n-- the assembly against the disassembly of the shipped object --")
        pair = crosscheck_pair(rep, gpu_files, x86_files)
        nx = sum(1 for path in pair
                 if crosscheck_report(profile, path, arch, tmp))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
        # A refused corpus raises before a verdict is written, so the directory
        # goes with the rest of the scratch unless it holds output to read.
        if diffs is not None and os.path.isdir(diffs) and not os.listdir(diffs):
            os.rmdir(diffs)
    ok = ((gp, gt) == (hip.GPU_ONLY_N, hip.GPU_ONLY_N)
          and (xp, xt) == (hip.X86_HET_N, hip.X86_HET_N) and nx == len(pair))
    print("\nISA READ-BACK GATE: %s -- gpu-only %d/%d, x86_64 het %d/%d (the "
          "x86_64 rendering of the het corpus, not the AArch64 one), %d/%d "
          "cross-check(s), %d row(s) covered, %.1f s"
          % ("PASS" if ok else "FAILED", gp, gt, xp, xt, nx, len(pair),
             len(covered), time.time() - t0))
    print("  each kernel's blocks are the multiset its lanes prescribe; which "
          "lane runs an op, and the order of a workgroup-scope one, are the HIP "
          "source gate's to say")
    return 0 if ok else 1


# ===========================================================================
# 12. BITE  (every check reddened on a fresh artifact)
# ===========================================================================

# A synthetic carrier for an annotation the corpus does not hold and this
# profile lowers no row for, so the refusal that a row is missing cannot rot
# unbitten; hipsrccheck.py owns the .litmus body, the annotation and its name.
BITE_SYNTH = "F-acqrel-sys"
# A second function symbol, whose instructions would belong to no lane.
BITE_SECOND_SYMBOL = "device_helper_the_compiler_did_not_inline"


def _unknown_arch():
    """A target no lowering profile is written for, which the registry must
    refuse by naming the section of [AMDGPUUsage] the next one is derived from.

    It is walked off a known target rather than written down, so the driver
    spells no generation of its own and a profile added later cannot leave the
    injection pointing at a target that is no longer unknown."""
    known = sorted(PROFILES)[0]
    for c in "0123456789abcdef":
        cand = known[:-1] + c
        if cand not in PROFILES:
            return cand
    raise GateError("--bite: every neighbour of %s carries a profile, so no "
                    "target is left for the registry to refuse" % known)


def _worker_dies(_job):
    """A sweep worker that dies without raising, which --bite puts in the pool:
    _sweep_one's handler never sees it, and the pool breaks instead."""
    os._exit(1)


def _rotated_preconditions(profile):
    """Each declared precondition paired with a value the profile declares for
    another of them, so an injection is always a value this target never
    carries and the driver still names no directive of its own."""
    values = [v for _d, v, _w in profile.preconditions]
    return [(d, v, values[(i + 1) % len(values)])
            for i, (d, v, _w) in enumerate(profile.preconditions)]


def _uncovering_rep(rep_paths, corpus_paths):
    """The rep whose loss leaves a corpus row with no carrier at all.

    The tripwire exists for exactly that drift, so the injection is computed
    from the corpus rather than pinned to a test name."""
    want = set()
    for path in corpus_paths:
        want |= rows_of(hip.instance_of(path))
    for drop in rep_paths:
        kept = set()
        for path in rep_paths:
            if path != drop:
                kept |= rows_of(hip.instance_of(path))
        if want - kept:
            return drop, [p for p in rep_paths if p != drop]
    raise GateError("--bite: no rep is the sole carrier of a row, so dropping "
                    "one cannot uncover any")


def _misfiled_shape(shapes, het_paths):
    """One fixed shape re-filed under a test that does not satisfy it."""
    for label in sorted(shapes):
        holds = dict(SHAPES)[label]
        for other in het_paths:
            if not holds(hip.instance_of(other), hip.het_instances(other)):
                bad = dict(shapes)
                bad[label] = other
                return label, other, bad
    raise GateError("--bite: every het test satisfies every fixed shape, so no "
                    "rep can be misfiled")


def bite(arch, tmp):
    """Every check on a fresh artifact, on the corruption it exists to catch.

    Exit codes are the contract, so each injection names the code it owes as
    well as the assertion: 1 is generated code that differs from what its
    .litmus prescribes, 2 a construct the profile has no model for and must
    refuse rather than compare, 3 a gate that cannot run at all."""
    profile = profile_for(arch)
    require_tool(HIPCC, "hipcc")
    b = hip.Bites()
    b.work = os.path.join(tmp, "bites")
    os.makedirs(b.work)
    srcs = os.path.join(tmp, "src")
    os.makedirs(srcs)
    corpus = hip.regen_x86(os.path.join(tmp, "x86"))
    gpu_files = hip.corpus_files(hip.GPU_ONLY_DIR, "gpu-only", hip.GPU_ONLY_N)
    het_files = hip.corpus_files(corpus, "x86_64 het", hip.X86_HET_N)
    rep, shapes = select_reps(gpu_files, het_files)

    cache = {}

    def run_printing(litmus_path, target):
        """One check whose output reaches the caller's stdout, so an injection
        made through capture() sees the message the command line would."""
        rc, out = run_check(litmus_path, target)
        print(out, end="")
        return rc

    def asm_of(litmus_path):
        """The compiled assembly of one carrier, once per run."""
        if litmus_path not in cache:
            d = os.path.join(srcs, "src%02d" % len(cache))
            os.makedirs(d)
            hip_path, _cpu = hip.emit_harness(litmus_path, d)
            out = os.path.join(d, ptx.litmus_name(ptx.read_litmus(litmus_path))
                               + ".s")
            compile_asm(hip_path, arch, out)
            cache[litmus_path] = out
        return cache[litmus_path]

    def inject(tag, label, litmus_path, rc, want, apply_to):
        """One injection into a pristine copy of a carrier's assembly."""
        src = asm_of(litmus_path)
        w = b.fresh(tag, src)
        text = open(w).read()
        open(w, "w").write(apply_to(text))
        return b.record(label, rc, want, *run_check(litmus_path, arch, asm=w),
                        orig=src, cur=w)

    print("===== ISA READ-BACK GATE BITE: the clean controls, then every check =====")
    print("  profile %s, derived from \"%s\"" % (profile.name, profile.section))
    print("  corpus  %d gpu-only + %d x86_64 het (generated)"
          % (len(gpu_files), len(het_files)))

    print("\n-- clean controls (an injection is evidence only against a green "
          "base) --")
    controls = [mutation_carrier(m, list(rep), het_files)
                for m in profile.mutations]
    for path in sorted(set(p for p in controls if p is not None)):
        name = os.path.basename(path)[:-len(".litmus")]
        b.record("%s (unmodified assembly)" % name, 0, "RESULT: PASS",
                 *run_check(path, arch, asm=asm_of(path)))

    print("\n-- the lowering profile's own mutations, on the carriers --guard "
          "resolves --")
    for i, m in enumerate(profile.mutations):
        who = controls[i]
        if who is None:
            print("  *** NO CARRIER IN THE REP SET    [%s]" % m.label)
            b.n += 1
            b.bad += 1
            continue
        inject("mut%02d" % i, m.label, who, m.rc, m.want, m.apply)

    # The refusals below are about the file rather than about a lane, so they
    # all read one already compiled gpu-only carrier.
    plain = sorted(p for p in cache if p in set(gpu_files))[0]

    print("\n-- the assembler directives the profile's rows rest on --")
    for directive, value, other in _rotated_preconditions(profile):
        inject("pre-%s" % directive.strip("."),
               "the precondition `%s %s' CARRYING ANOTHER DECLARED VALUE"
               % (directive, value), plain, 2, "%s is" % directive,
               lambda t, d=directive, o=other: _sub_all(
                   t, r'^(\s*%s\s+)\S.*$' % re.escape(d),
                   lambda mm, o=o: mm.group(1) + o, "the directive %s" % d))
        inject("pre-gone-%s" % directive.strip("."),
               "the precondition `%s %s' DELETED" % (directive, value),
               plain, 2, "does not carry at all",
               lambda t, d=directive: _sub_all(
                   t, r'^\s*%s\b[^\n]*\n' % re.escape(d), '',
                   "the directive %s" % d))

    print("\n-- the symbol every token is attributed to --")
    inject("second-symbol", "a SECOND @function symbol in the output",
           plain, 3, "@function symbol(s)",
           lambda t: _sub_first(
               t, r'^(\s*\.type\s+[\w.$]+\s*,\s*@function\s*)$',
               lambda mm: "%s\n\t.type\t%s,@function"
                          % (mm.group(1), BITE_SECOND_SYMBOL),
               "the kernel's own function symbol"))

    print("\n-- the tables, the tools and the rep set the gate runs through --")
    unknown = _unknown_arch()
    b.record("a target no lowering profile is written for (--arch %s)"
             % unknown, 2, "Memory Model GFX%s" % generation_of(unknown),
             *run_check(plain, unknown))

    sdir = os.path.join(b.work, "synth")
    os.makedirs(sdir)
    synth = hip.synth_carrier(sdir, BITE_SYNTH)
    b.record("an annotation this profile lowers no row for (%s)"
             % hip.SYNTH[BITE_SYNTH], 2, "has no row for",
             *run_check(synth, arch))

    b.record("hipcc UNRESOLVABLE (the gate reads generated code, so a missing "
             "toolchain is a refusal)", 3, "is not resolvable at",
             *capture(lambda: run_printing(plain, arch),
                      HIPCC=os.path.join(tmp, "no", "such", "hipcc")))

    dropped, kept = _uncovering_rep(list(rep), gpu_files + het_files)
    b.record("the SOLE carrier of a corpus row dropped from the rep set (%s)"
             % os.path.basename(dropped)[:-len(".litmus")], 2, "uncovered:",
             *capture(lambda: coverage_tripwire(profile, kept,
                                                gpu_files + het_files, shapes)))

    label, other, misfiled = _misfiled_shape(shapes, het_files)
    b.record("the shape %r re-filed under a test that does not satisfy it (%s)"
             % (label, os.path.basename(other)[:-len(".litmus")]), 2,
             "no longer satisfies the shape",
             *capture(lambda: coverage_tripwire(profile, list(rep),
                                                gpu_files + het_files, misfiled)))

    print("\n-- the cross-check that bounds -S against the shipped object --")
    doctor = next(m for m in profile.mutations
                  if m.rc == 1 and mutation_carrier(m, list(rep), het_files)
                  in set(gpu_files))
    victim = mutation_carrier(doctor, list(rep), het_files)
    clean = os.path.join(b.work, "cross-clean")
    os.makedirs(clean)
    b.record("%s cross-checked UNDOCTORED (control)"
             % os.path.basename(victim)[:-len(".litmus")], 0, "OK (",
             *capture(lambda: 0 if crosscheck_report(profile, victim, arch, clean)
                      else 1))
    doctored = os.path.join(b.work, "cross-doctored")
    os.makedirs(doctored)
    b.record("the assembly DOCTORED under the cross-check (%s)" % doctor.label,
             1, "DIFFERS",
             *capture(lambda: 0 if crosscheck_report(profile, victim, arch,
                                                     doctored,
                                                     doctor=doctor.apply)
                      else 1))

    print("\n-- the census the sweep asserts before it compiles a single render --")
    empty = os.path.join(b.work, "empty")
    os.makedirs(empty)
    b.record("an EMPTY gpu-only directory swept as if it were the corpus", 3,
             "holds 0 .litmus, expected %d" % hip.GPU_ONLY_N,
             *capture(lambda: sweep(empty, corpus, arch, 2)))

    few = [os.path.basename(p)[:-len(".litmus")] for p in het_files[:3]]
    short = hip.corpus_slice(corpus, os.path.join(b.work, "short"), few)
    b.record("an x86_64 het corpus SHORT of its census", 3,
             "holds %d .litmus, expected %d" % (len(few), hip.X86_HET_N),
             *capture(lambda: sweep(hip.GPU_ONLY_DIR, short, arch, 2)))

    names = [os.path.basename(p)[:-len(".litmus")] for p in het_files]
    nomap = hip.corpus_slice(corpus, os.path.join(b.work, "nomap"), names,
                             drop_map=True)
    b.record("a FULL-SIZE x86_64 het corpus carrying no control map", 3,
             "without it every lane plan",
             *capture(lambda: sweep(hip.GPU_ONLY_DIR, nomap, arch, 2)))

    b.record("a sweep worker KILLED, which breaks the pool without raising", 3,
             "a sweep worker died without raising",
             *capture(lambda: sweep(hip.GPU_ONLY_DIR, corpus, arch, 2),
                      _sweep_one=_worker_dies))

    print()
    if b.n == 0:
        print("ISA READ-BACK GATE BITE FAILED: no injection ran")
        return 1
    if b.bad:
        print("ISA READ-BACK GATE BITE FAILED: %d of %d assertion(s) did not "
              "hold (%d reddened for the wrong reason)" % (b.bad, b.n, b.wrong))
        return 1
    print("ISA READ-BACK GATE BITE OK: %d injections, each reddening its own "
          "assertion, 0 for a wrong reason; %d clean control(s) green"
          % (b.red, b.green))
    return 0


# ===========================================================================
# 13. --guard
# ===========================================================================

def guard_report(arch):
    """The tables this gate compares through and the tools it resolves.  An
    empty table or an unresolvable tool is itself a failure: a guard that
    reports nothing vouches for nothing."""
    bad = 0
    profile = profile_for(arch)
    print("===== ISA READ-BACK GATE: tables, tools and reps =====")
    print("\n-- tools --")
    for what, p in (("hipcc", HIPCC), ("llvm-objdump", OBJDUMP),
                    ("clang-offload-bundler", BUNDLER),
                    ("ptxcheck.py (imported, not modified)", PTXCHECK),
                    ("hipsrccheck.py (imported, not modified)", HIPSRCCHECK)):
        try:
            require_tool(p, what)
            print("  %-38s %s" % (what, p))
        except GateError:
            print("  %-38s %s  *** MISSING ***" % (what, p))
            bad += 1
    print("  %-38s %s" % ("compile", " ".join(("hipcc", "--offload-arch=" + arch)
                                              + COMPILE_FLAGS + ("-I <render dir>",
                                                                 "<t>.hip", "-o <t>.s"))))
    print("\n-- lowering profiles --")
    print("  known: %s; selected: %s (\"%s\")"
          % (", ".join(sorted(PROFILES)), profile.name, profile.section))
    if not PROFILES:
        bad += 1
    print("\n-- preconditions this profile asserts on every render --")
    if not profile.preconditions:
        print("  *** empty table ***")
        bad += 1
    for directive, value, _why in profile.preconditions:
        print("  %-32s %s" % (directive, value))
    print("\n-- mnemonic classes --")
    for label, table in (("access", profile.ACCESS), ("cache", profile.CACHE),
                         ("width suffix", profile.WIDTH)):
        if not table:
            print("  %-14s *** empty table ***" % label)
            bad += 1
        for k in sorted(table):
            v = table[k]
            print("  %-14s %-18s -> %s" % (label, k, v))
    print("  %-14s %s" % ("wait", ", ".join(profile.WAITS)))
    print("  %-14s %s" % ("memory family", profile.FAMILY.pattern))
    print("  %-14s %s (no token, and no refusal)"
          % ("dropped", ", ".join(pre + "*" for pre in profile.DROPPED)))
    print("\n-- cache annotation -> scope --")
    if not profile.BITS_OF_SCOPE:
        bad += 1
    for scope in ("cta", "gpu", "sys"):
        print("  %-6s %s" % (scope, " ".join(profile.BITS_OF_SCOPE[scope])))
    print("  an access carrying none names no scope and is dropped")
    print("  on an RMW %s means the value is returned and %s means system scope"
          % (profile.ATOMIC_RETURNS, profile.ATOMIC_SYSTEM))
    print("\n-- rows: annotation -> token sequence, at the gpu-only "
          "model width; the het path takes the same rows at %d --"
          % MODEL_WIDTH_HET)
    nrow = 0
    for kind, order, scope in sorted(_all_rows(profile)):
        for w in (MODEL_WIDTH_GPU_ONLY,):
            print("  %-16s %s" % (fmt_row((kind, order, scope))
                                  if kind in ('st', 'ld', 'fence')
                                  else "%s[%s,%s]" % (kind, order, scope),
                                  fmt_seq(profile.row(kind, order, scope, w))))
            nrow += 1
    if not nrow:
        bad += 1
    print("\n-- het scaffolding, as the runtime's own (kind, order, scope) --")
    for label, spec in (("rendezvous arrive", RENDEZVOUS_ARRIVE),
                        ("rendezvous spin", RENDEZVOUS_SPIN),
                        ("window-opener arrive", WINDOW_ARRIVE),
                        ("window-opener poll", WINDOW_POLL),
                        ("observer snoop", OBSERVER_LOAD),
                        ("folded counter read", SCRATCH_READ),
                        ("discarded counter RMW", DISCARDED_RMW),
                        ("interconnect-noise read", NOISE_READ)):
        w = MODEL_WIDTH_HET if spec in (OBSERVER_LOAD, NOISE_READ) else SCAFFOLD_WIDTH
        print("  %-24s %-22s %s" % (label, "%s[%s,%s]" % spec[:3],
                                    fmt_seq(_seq(profile, spec, w))))
    print("\n-- the rep set, derived from the corpus --")
    tmp = tempfile.mkdtemp(prefix="amdisacheck-guard.")
    try:
        gpu, het = corpus(tmp)
        rep, shapes = select_reps(gpu, het)
        covered = coverage_tripwire(profile, list(rep), gpu + het, shapes)
        for path, why in rep.items():
            print("  %-42s %s" % (os.path.basename(path)[:-len(".litmus")],
                                  "; ".join(why)))
        print("  %d rep(s) covering all %d corpus row(s)" % (len(rep), len(covered)))
        if not rep:
            bad += 1
        print("\n-- bite mutations this profile owns, each resolved to the "
              "carrier it names --")
        if not profile.mutations:
            bad += 1
        for m in profile.mutations:
            who = mutation_carrier(m, list(rep), het)
            if who is None:
                bad += 1
            print("  exit %d  %-56s %s"
                  % (m.rc, m.label,
                     os.path.basename(who)[:-len(".litmus")] if who
                     else "*** NO CARRIER IN THE REP SET (%s) ***"
                          % (m.needs if isinstance(m.needs, str)
                             else fmt_row(m.needs))))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("\n-- exit contract --")
    print("  0 PASS   1 FAIL   2 completeness hard-fail   3 error")
    if bad:
        print("\nGUARD FAILED: %d unresolved tool(s), carrier(s) or empty "
              "table(s)" % bad)
    return 1 if bad else 0


def _all_rows(profile):
    """The keys of the profile's row table, read back through the one entry
    point that owns it."""
    out = []
    for kind in ("ld", "st", "fence", "rmw", "vld"):
        for order in ("relaxed", "acquire", "release", "sc", "-"):
            for scope in ("cta", "gpu", "sys"):
                try:
                    profile.row(kind, order, scope, 32)
                except CompletenessError:
                    continue
                out.append((kind, order, scope))
    return out


# ===========================================================================
# 14. DRIVER
# ===========================================================================

def main():
    ap = argparse.ArgumentParser(
        description="HetLitmus ISA read-back gate: .litmus annotation vs the "
                    "AMD GPU code hipcc generates")
    ap.add_argument("litmus", nargs="?", help=".litmus test path")
    ap.add_argument("--arch", default=DEFAULT_ARCH,
                    help="offload target, selecting the lowering profile "
                         "(default %s, what the emitted comp.sh compiles for)"
                         % DEFAULT_ARCH)
    ap.add_argument("--asm", help="read this .s instead of emitting and compiling")
    ap.add_argument("--all", action="store_true",
                    help="sweep both corpora (%d gpu-only + %d x86_64 het)"
                         % (hip.GPU_ONLY_N, hip.X86_HET_N))
    ap.add_argument("--gpu-dir", default=hip.GPU_ONLY_DIR,
                    help="the gpu-only corpus to sweep")
    ap.add_argument("--x86-dir",
                    help="an x86_64 het corpus to sweep (default: regenerate one)")
    ap.add_argument("--jobs", type=int, default=hip.default_jobs(),
                    help="sweep workers (default: CPUs, capped at %d)"
                         % hip.JOBS_CAP)
    ap.add_argument("--reps", action="store_true",
                    help="check the rep set derived from the corpus, then "
                         "cross-check two of them against the shipped object")
    ap.add_argument("--bite", action="store_true",
                    help="prove every check FAILS on the corruption it is for")
    ap.add_argument("--guard", action="store_true",
                    help="print the tables, the tools and the rep set, then exit")
    ap.add_argument("-q", "--quiet", action="store_true")
    args = ap.parse_args()
    try:
        if args.guard:
            sys.exit(guard_report(args.arch))
        if args.bite:
            tmp = tempfile.mkdtemp(prefix="amdisacheck-bite.")
            try:
                sys.exit(bite(args.arch, tmp))
            finally:
                shutil.rmtree(tmp, ignore_errors=True)
        if args.all:
            sys.exit(sweep(args.gpu_dir, args.x86_dir, args.arch,
                           max(1, args.jobs)))
        if args.reps:
            sys.exit(reps(args.arch, verbose=not args.quiet))
        if not args.litmus:
            print("ERROR: no .litmus given (and none of --all/--reps/--bite/"
                  "--guard asked for)")
            sys.exit(3)
        ok = check_test(args.litmus, args.arch, asm_override=args.asm,
                        verbose=not args.quiet)
    except CompletenessError as e:
        print("COMPLETENESS HARD-FAIL: %s" % e)
        sys.exit(2)
    except GateError as e:
        print("ERROR: %s" % e)
        sys.exit(3)
    except Exception as e:
        print("ERROR: %s: %s" % (type(e).__name__, e))
        sys.exit(3)
    print("RESULT:", "PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()

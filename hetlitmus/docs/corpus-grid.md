# HetLitmus corpus grid

Home of the rule that generates the het corpus and its all-GPU cut, the
gpu-only corpus, of the reasons for its shape and that corpus's vendor boundary.

## The shape catalogue

The `Co` names and edge order are diy's: a `Pos` edge's far end must agree in
direction with the external edge after it. An all-`Pos` cycle touches one
location, refused without `-oneloc`. Each `Coe` edge puts one location in the
condition, so a cycle with no `Coe` names none. A diy edge token admits no
underscore, so the fence tag is `acqrel`, not PTX's `acq_rel`.

## The five axes

Each proc sits in its own CTA, as the artifact places its threads, so a `cta`
annotation cannot cross threads; strength is read from the tree. A fence
order's fence turns the `Po` edge into a diy fence edge, which diy supports as
it stands. A mixed pair, an acquire read against an `sc` write, is not a cell.
A non-`plain` CPU order pairs with `sys` only: CPU ops are scope-free and the
pair they close is the cross-device one. An order whose annotation has no
access of its kind to land on renders a weaker order's body, so those cells are
duplicates.

## Device cuts

All-CPU is litmus7's own path and all-GPU the gpu-only corpus; every other proc
assignment is a raw cut. A rotation of the segment list that fixes the edge
list renames procs and locations, so one cut per orbit survives, no two
survivors are one experiment up to proc permutation and location renaming, and
none is lost. SB, LB, 2+2W, 3.2W, 3.SB and 3.LB are invariant under rotation by
one proc, IRIW by two, every other shape under none.

## The CPU ISA of a rendering

Under x86-TSO [Sewell10 §3.1] the store/load pair is the only reordering and
MFENCE removes it, so no release store, acquire load or one-sided barrier has
an image distinct from the plain cycle or MFENCE. The x86_64 profile thus has
two CPU orders by construction, and its rendering is a smaller cell set than
the AArch64 one, not a renaming.

## Vendor scope

The artifact runs on gem5's GCN3 GPU fused with an x86 CPU, so its observations
are one simulated AMD machine's, and this project ships and derives none. The
`.litmus` vocabulary is PTX-named because it maps 1:1 onto the levels the
corpus uses, and the vendor difference lives in the emitters
(`gpu-emitters.md`), never in the `.litmus` layer.

## Kernels as grid cells

A per-access placement of an order is not an axis, so the artifact's flag-only
release/acquire kernels are not cells; the corpus carries the `rlx` and `ra`
cell either side of each, the residual between artifact and corpus. Its
workgroup-scope kernel is a gem5 build variant, and every kernel launches one
thread per block, so that scope is too narrow -- the same residual as the
corpus's own-CTA placement.

### Release/acquire without fences

No `RelAcq` kernel contains a fence, and release/acquire alone does not forbid
SB or IRIW, whose forbidden outcome has every acquire read the initial value.
The artifact records both as disallowed: on the gem5 GCN3 model a release or
acquire behaves as an SC fence ([Goens23] §7.2, fn. 10). That is that machine's
property; neither reading transfers.

## The vocabulary the frontend must express

The vocabulary is anchored on the [Goens23] artifact's GPU litmus tests: the
artifact motivates it, not membership. Those sources use `__ATOMIC_ACQUIRE` and
`__ATOMIC_RELEASE` only, at system and, by build variant, workgroup scope. The
frontend therefore needs scoped loads and stores, no RMW, and the intermediate
scope `gpu` the artifact does not use; beyond the artifact the bell declares
`sc` and the standalone fences the grid's orders use, over the idioms of
`herd/libdir/c11.bell` and `catalogue/tutorial/bells/jaguar.bell`.

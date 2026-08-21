Reporting-tier guard.  Every het harness stamps two tiers into its record: the
MECHANISM tier, which says what the shape's own decode channels are, and the
REPORTING tier, which is the label a human reads off the printout.  They are not
the same rule (litmus/hetCond.mli), and collapsing them relabels a whole class of
rows.  This file pins both fields on four shapes and pins which of them the
printed [...] label is.

THE REPORTING TIER IS NOT THE MECHANISM TIER.  R and S are both mechanically
ADVISORY (one ws-location + a register), but S's read is an rf read -- a real
synchrony anchor -- while R has zero rf edges: its only read is the
fr-against-init, which in the weak case returns init, tag 0, so it decodes no
writer and no synchrony.  R borrows both its synchrony point and its ws edge from
the fragile observer, exactly like 2+2W, and is demoted for REPORTING only.

  $ litmus7 -gpu-target cuda -o . ../het/R-cg-sys-fence.litmus >/dev/null 2>&1
  $ grep -E '_rec\.(confidence|reporting) =' R-cg-sys-fence/R-cg-sys-fence.cu
      _rec.confidence = CONF_ADVISORY;
      _rec.reporting = CONF_EXPLORATORY;

  $ litmus7 -gpu-target cuda -o . ../het/S-cg-sys-fence.litmus >/dev/null 2>&1
  $ grep -E '_rec\.(confidence|reporting) =' S-cg-sys-fence/S-cg-sys-fence.cu
      _rec.confidence = CONF_ADVISORY;
      _rec.reporting = CONF_ADVISORY;

The other two tiers, and which of the two fields the printed [...] label is.  The
pair above pins only the tier where the two fields DIFFER; the floor (2+2W, both
EXPLORATORY) and the ceiling (a pure-register shape, both ROBUST) would otherwise
be untested, so a rule collapsed to a constant would still pass.  R reports at
the 2+2W floor rather than at S's tier, for the reason litmus/hetCond.mli gives.
  $ litmus7 -gpu-target cuda -o . ../het/2+2W-cg-sys-fence.litmus >/dev/null 2>&1
  $ grep -E '_rec\.(confidence|reporting) =' 2+2W-cg-sys-fence/2+2W-cg-sys-fence.cu
      _rec.confidence = CONF_EXPLORATORY;
      _rec.reporting = CONF_EXPLORATORY;

  $ litmus7 -gpu-target cuda -o . ../het/MP-cg-sys-acqrel-2s.litmus >/dev/null 2>&1
  $ grep -E '_rec\.(confidence|reporting) =' MP-cg-sys-acqrel-2s/MP-cg-sys-acqrel-2s.cu
      _rec.confidence = CONF_ROBUST;
      _rec.reporting = CONF_ROBUST;

And the label the human reads is the REPORTING tier.  Printing `confidence' there
instead would relabel every R row [ADVISORY] -- claiming a null from a shape
that borrows both its synchrony point and its ws edge from the observer is as
good as one recovered from read buffers.  Pinned on the emitted header, not the
source copy.
  $ grep -c 'het_conf_name(_r->reporting)' MP-cg-sys-acqrel-2s/het_verdict.h
  1
  $ grep -c 'het_conf_name(_r->confidence)' MP-cg-sys-acqrel-2s/het_verdict.h
  0
  [1]

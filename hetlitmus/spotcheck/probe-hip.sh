#!/bin/sh
# =========================================================================
# HetLitmus device probe, AMD side -- the sibling of probe.sh (NVIDIA).
#
#   sh probe-hip.sh                 # results-devtier-<date>-<host>/probe.txt
#   RESULTS=... sh probe-hip.sh     # somewhere else
#
# NO DEVICE-ATTRIBUTE KERNEL.  probe.sh compiles and runs probe.cu, which asks
# the driver what the device offers (managed memory, host page tables, system
# atomics).  Its HIP twin has to ask different questions of a different runtime
# and cannot be written blind: there is no AMD GPU on the dev box, so not one of
# its answers could be observed here (spotcheck/README.md).  This script
# therefore records what the VENDOR TOOLS report and stamps probe_status so the
# results dir says which probe it got -- it does not stand in for the kernel.
#
# The host-half keys are spelled exactly as probe.sh spells them, so a probe.txt
# from either vendor diffs against one from the other.
#
# Everything is key=value, one per line.  Nothing here is a litmus result.
# =========================================================================
set -eu

HIPCC="${HIPCC:-hipcc}"
RESULTS="${RESULTS:-$(cd "$(dirname "$0")" && pwd)/results-devtier-$(date +%Y%m%d)-$( (hostname -s 2>/dev/null || hostname 2>/dev/null || echo host) | tr -c 'A-Za-z0-9_.-' '_' )}"

mkdir -p "$RESULTS"
OUT="$RESULTS/probe.txt"
: > "$OUT"

emit() { printf '%s\n' "$1" >> "$OUT"; }

emit "probe_date=$(date -Is 2>/dev/null || date)"
emit "host_uname_m=$(uname -m)"
emit "host_uname_r=$(uname -r)"
emit "host_uname_s=$(uname -s)"
emit "host_nproc=$( (nproc 2>/dev/null || echo -1) )"

if [ -r /proc/cpuinfo ]; then
  feats="$(grep -m1 -E '^(Features|flags)' /proc/cpuinfo 2>/dev/null | cut -d: -f2- || true)"
else
  feats=""
fi
emit "cpu_features_raw=${feats# }"
for f in lrcpc lrcpc2 atomics asimd sve; do
  case " $feats " in
    *" $f "*) emit "cpu_has_$f=1" ;;
    *)        emit "cpu_has_$f=0" ;;
  esac
done
emit "cpu_model=$(grep -m1 -E '^(model name|CPU part|Model)' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^ *//' || echo unknown)"

if command -v "$HIPCC" >/dev/null 2>&1; then
  emit "hipcc=$($HIPCC --version 2>/dev/null | grep -m1 -E 'HIP version|clang version' || echo unknown)"
else
  emit "hipcc=ABSENT"
  emit "probe_status=NO_TOOLCHAIN"
  echo "probe-hip: $HIPCC not found -- wrote $OUT" >&2
  exit 2
fi
emit "rocm_path=${ROCM_PATH:-$(dirname "$(dirname "$(command -v "$HIPCC")")")}"

# The gfx architectures visible to this host, one per line from amdgpu-arch and
# from rocminfo's agent list.  Both are consulted because either can be absent
# from a given ROCm install, and a disagreement between them is a fact about the
# box that the operator should see rather than a tie this script breaks.
archs=""
if command -v amdgpu-arch >/dev/null 2>&1; then
  archs="$(amdgpu-arch 2>/dev/null | tr -d ' \r' | grep -c . || true)"
  emit "amdgpu_arch_agents=${archs:-0}"
  emit "amdgpu_arch_list=$(amdgpu-arch 2>/dev/null | tr -d ' \r' | tr '\n' ' ')"
else
  emit "amdgpu_arch_agents=TOOL_ABSENT"
fi
if command -v rocminfo >/dev/null 2>&1; then
  emit "rocminfo_gfx_list=$(rocminfo 2>/dev/null | sed -n 's/.*Name: *\(gfx[0-9a-f]*\).*/\1/p' | tr '\n' ' ')"
else
  emit "rocminfo_gfx_list=TOOL_ABSENT"
fi

# The suggested arch is the single distinct gfx name the tools agree on.  Two
# distinct names is not a probe failure -- it is a machine this harness cannot be
# built for without the operator naming which device is under test.
uniq_archs="$( { amdgpu-arch 2>/dev/null || true ; \
                 rocminfo 2>/dev/null | sed -n 's/.*Name: *\(gfx[0-9a-f]*\).*/\1/p' || true ; } \
               | tr -d ' \r' | grep -E '^gfx[0-9a-f]+$' | sort -u )"
n="$(printf '%s' "$uniq_archs" | grep -c . || true)"
if [ "$n" -eq 0 ]; then
  emit "suggested_hip_arch=NONE"
  emit "probe_status=NO_DEVICE"
  echo "probe-hip: no gfx agent is visible (amdgpu-arch and rocminfo report none) -- wrote $OUT" >&2
  exit 2
fi
if [ "$n" -gt 1 ]; then
  emit "suggested_hip_arch=AMBIGUOUS($(printf '%s' "$uniq_archs" | tr '\n' ' '))"
  emit "probe_status=AMBIGUOUS_DEVICE"
  echo "probe-hip: $n distinct gfx architectures visible -- wrote $OUT" >&2
  exit 2
fi
emit "suggested_hip_arch=$uniq_archs"
emit "device_count=$n"
emit "probe_status=HOST_ONLY (vendor-tool facts only; no device-attribute kernel exists for HIP -- see the header)"

echo "probe-hip: wrote $OUT"
grep -E '^(hipcc|amdgpu_arch_agents|rocminfo_gfx_list|suggested_hip_arch|device_count|probe_status)=' "$OUT" || true

#!/bin/sh
# The AMD probe, sibling of probe-cuda.sh: it records what the vendor tools
# report and stamps probe_status, and it runs NO device-attribute kernel -- a
# HIP twin of probe.cu asks a different runtime different questions and there is
# no AMD device here to write it against.
#
#   sh probe-hip.sh                 # run-out/<date>-<host>/probe.txt
#   RESULTS=... sh probe-hip.sh     # somewhere else
#
# The host-half keys are spelled as probe-cuda.sh spells them, so the two
# probe.txt files diff.  Everything is key=value; none of it is a litmus result.
set -eu

HIPCC="${HIPCC:-hipcc}"
RESULTS="${RESULTS:-$(cd "$(dirname "$0")" && pwd)/run-out/$(date +%Y%m%d)-$( (hostname -s 2>/dev/null || hostname 2>/dev/null || echo host) | tr -c 'A-Za-z0-9_.-' '_' )}"

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

# The gfx architectures visible here, from amdgpu-arch and from rocminfo's agent
# list: either tool can be absent, and a disagreement is the operator's to read.
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
# names is a box the operator must choose a device on, not a probe failure.
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
emit "probe_status=HOST_ONLY (vendor-tool facts only; no device-attribute kernel for HIP)"

echo "probe-hip: wrote $OUT"
grep -E '^(hipcc|amdgpu_arch_agents|rocminfo_gfx_list|suggested_hip_arch|device_count|probe_status)=' "$OUT" || true

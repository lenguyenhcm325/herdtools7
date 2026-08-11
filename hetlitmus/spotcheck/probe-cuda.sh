#!/bin/sh
# =========================================================================
# HetLitmus dev-tier probe driver.  Compiles + runs probe.cu and adds the
# host-side facts it cannot see from CUDA, into <results>/probe.txt.
#
#   sh probe-cuda.sh                 # results-devtier-<date>-<host>/probe.txt
#   RESULTS=... sh probe-cuda.sh     # somewhere else
#
# PTX-ONLY BUILD.  probe.cu is compiled to compute_75 PTX and JIT-ed at load, so
# one command works on sm_75 (T4G), sm_90 (GH200) and sm_121 (GB10) without
# knowing the arch first -- which is the point, since the arch is one of the
# things being probed.  It is deliberately NOT `-arch=native': that flag only
# exists from CUDA 11.5 update 1, and the whole job here is to work on a box
# whose toolkit version has not been established yet.
# compute_75, not compute_60: CUDA 13 REMOVED pre-Turing targets, so compute_60
# is `nvcc fatal: Unsupported gpu architecture' there (hit on the first real
# box, GB10 + CUDA 13.2, 2026-07-31).  compute_75 needs only CUDA 10, and every
# device CUDA 13 can still target is sm_75+ -- so it excludes nothing anywhere.
#
# Everything is key=value, one per line.  Nothing here is a litmus result.
# =========================================================================
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
NVCC="${NVCC:-nvcc}"
PROBE_GENCODE="${PROBE_GENCODE:--gencode arch=compute_75,code=compute_75}"
RESULTS="${RESULTS:-$HERE/results-devtier-$(date +%Y%m%d)-$( (hostname -s 2>/dev/null || hostname 2>/dev/null || echo host) | tr -c 'A-Za-z0-9_.-' '_' )}"

mkdir -p "$RESULTS"
OUT="$RESULTS/probe.txt"
: > "$OUT"

emit() { printf '%s\n' "$1" >> "$OUT"; }

emit "probe_date=$(date -Is 2>/dev/null || date)"
emit "host_uname_m=$(uname -m)"
emit "host_uname_r=$(uname -r)"
emit "host_uname_s=$(uname -s)"
emit "host_nproc=$( (nproc 2>/dev/null || echo -1) )"

# AArch64 feature flags that decide whether the CPU side can carry the tested
# ops at all: `lrcpc' is LDAPR (the RCpc acquire the -2s CPU cycles use) and
# `atomics' is LSE.  Absent lrcpc, the CPU half of a -2s test cannot issue the
# acquire its .litmus names.  x86 hosts have no such line; the
# key is emitted as `n/a' rather than omitted, so a diff across boxes lines up.
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

if command -v "$NVCC" >/dev/null 2>&1; then
  emit "nvcc=$($NVCC --version | grep -o 'release [0-9.]*' | head -1)"
else
  emit "nvcc=ABSENT"
  emit "probe_status=NO_TOOLCHAIN"
  echo "probe: $NVCC not found -- wrote $OUT" >&2
  exit 2
fi
if command -v nvidia-smi >/dev/null 2>&1; then
  emit "nvidia_smi_driver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || echo unknown)"
else
  emit "nvidia_smi_driver=ABSENT"
fi

# shellcheck disable=SC2086
"$NVCC" -std=c++17 $PROBE_GENCODE "$HERE/probe.cu" -o "$RESULTS/probe" \
  >> "$OUT" 2>&1 || { emit "probe_status=COMPILE_FAIL"; echo "probe: compile failed, see $OUT" >&2; exit 2; }

rc=0
"$RESULTS/probe" >> "$OUT" 2>&1 || rc=$?
emit "probe_exit=$rc"

echo "probe: wrote $OUT"
grep -E '^(device_name|compute_capability|suggested_cuda_arch|pageableMemoryAccess|usesHostPageTables|concurrentManagedAccess|hostNativeAtomicSupported|cooperativeLaunch|coherence_mechanism|het_alloc_auto_would_pick|harness_can_run|mode_|sysatomic_[a-z]*=|probe_status)' "$OUT" || true
exit "$rc"

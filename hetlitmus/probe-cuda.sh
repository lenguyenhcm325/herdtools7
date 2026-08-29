#!/bin/sh
# The CUDA probe driver: run probe.cu, add the host facts CUDA cannot see, and
# write <results>/probe.txt as key=value lines.  None of it is a litmus result.
#
#   sh probe-cuda.sh                 # run-out/<date>-<host>/probe.txt
#   RESULTS=... sh probe-cuda.sh     # somewhere else
#
# Builds compute_75 PTX and JITs at load, so one command works before the arch
# is known; NEVER `-arch=native' (hetlitmus/docs/het-emission.md, the CUDA_ARCH
# paragraph).
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
NVCC="${NVCC:-nvcc}"
PROBE_GENCODE="${PROBE_GENCODE:--gencode arch=compute_75,code=compute_75}"
RESULTS="${RESULTS:-$HERE/run-out/$(date +%Y%m%d)-$( (hostname -s 2>/dev/null || hostname 2>/dev/null || echo host) | tr -c 'A-Za-z0-9_.-' '_' )}"

mkdir -p "$RESULTS"
OUT="$RESULTS/probe.txt"
: > "$OUT"

emit() { printf '%s\n' "$1" >> "$OUT"; }

emit "probe_date=$(date -Is 2>/dev/null || date)"
emit "host_uname_m=$(uname -m)"
emit "host_uname_r=$(uname -r)"
emit "host_uname_s=$(uname -s)"
emit "host_nproc=$( (nproc 2>/dev/null || echo -1) )"

# AArch64 flags the CPU side needs: `lrcpc' is LDAPR and `atomics' is LSE.  An
# x86 host has no such line, so the keys read 0 and either box's probe.txt diffs.
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

# command -v alone resolves a builtin or function, which is no toolchain.
if [ -x "$(command -v "$NVCC" 2>/dev/null || true)" ]; then
  emit "nvcc=$($NVCC --version | grep -o 'release [0-9.]*' | head -1)"
else
  emit "nvcc=ABSENT"
  emit "probe_status=NO_TOOLCHAIN"
  echo "probe: $NVCC does not resolve to an executable -- wrote $OUT" >&2
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

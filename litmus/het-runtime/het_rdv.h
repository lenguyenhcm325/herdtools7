/****************************************************************************/
/*                           the diy toolsuite                              */
/*                                                                          */
/* Jade Alglave, University College London, UK.                             */
/* Luc Maranget, INRIA Paris-Rocquencourt, France.                          */
/*                                                                          */
/* Copyright 2013-present Institut National de Recherche en Informatique et */
/* en Automatique and the authors. All rights reserved.                     */
/*                                                                          */
/* This software is governed by the CeCILL-B license under French law and   */
/* abiding by the rules of distribution of free software. You can use,      */
/* modify and/ or redistribute the software under the terms of the CeCILL-B */
/* license as circulated by CEA, CNRS and INRIA at the following URL        */
/* "http://www.cecill.info". We also give a copy in LICENSE.txt.            */
/****************************************************************************/

#ifndef HET_RDV_H
#define HET_RDV_H

#include "het_stress.h"

/* In ints: 32 = 128 B, so two iterations never share a cache line. */
#ifndef HET_SLOT_STRIDE_WORDS
#define HET_SLOT_STRIDE_WORDS 32
#endif

#ifndef HET_CAP_GPU
#define HET_CAP_GPU 16384
#endif
#ifndef HET_CAP_CPU
#define HET_CAP_CPU 524288
#endif
#ifndef HET_CAP_CALIBRATED
#define HET_CAP_CALIBRATED 0
#endif

#ifndef HET_RELEASE_JITTER_SPINS
#define HET_RELEASE_JITTER_SPINS 64
#endif

/* A host spin that never enters the runtime can starve the grid it waits for.
   https://docs.nvidia.com/cuda/archive/13.4.2/cuda-programming-guide/05-appendices/cuda-cpp-execution-model.html#cuda-c-execution-model */
typedef void (*het_poke_fn)(void);

#ifndef HET_RDV_POKE_EVERY
#define HET_RDV_POKE_EVERY 1024
#endif
#if (HET_RDV_POKE_EVERY & (HET_RDV_POKE_EVERY - 1)) != 0
#error "HET_RDV_POKE_EVERY must be a power of two"
#endif

/* Relaxed on purpose: on Hopper an acquire appears to self-invalidate the L1
   [Bagchi26]. */
#if defined(__HIP_PLATFORM_AMD__) || defined(__HIP_DEVICE_COMPILE__)
__device__ static inline int het_rdv_device(uint64_t *_ctr, uint64_t _target,
                                            uint32_t _cap) {
  uint64_t _v = __hip_atomic_fetch_add(_ctr, 1ull, __ATOMIC_RELAXED,
                                       __HIP_MEMORY_SCOPE_SYSTEM) + 1ull;
  uint32_t _i = 0;
  while (_v < _target && _i < _cap) {
    _i++;
    /* Adapted from __gpu_thread_suspend, which sleeps 2; benefit unmeasured.
       https://github.com/llvm/llvm-project/blob/ea4d814a136bbc30c09c631cb00cdddcd4a58326/clang/lib/Headers/amdgpuintrin.h#L155-L157 */
    __builtin_amdgcn_s_sleep(1);
    _v = __hip_atomic_load(_ctr, __ATOMIC_RELAXED, __HIP_MEMORY_SCOPE_SYSTEM);
  }
  return _v >= _target;
}
#else
__device__ static inline int het_rdv_device(uint64_t *_ctr, uint64_t _target,
                                            uint32_t _cap) {
  cuda::atomic_ref<uint64_t, cuda::thread_scope_system> _a(*_ctr);
  uint64_t _v = _a.fetch_add(1ull, cuda::memory_order_relaxed) + 1ull;
  uint32_t _i = 0;
  while (_v < _target && _i < _cap) {
    _i++;
    _v = _a.load(cuda::memory_order_relaxed);
  }
  return _v >= _target;
}
#endif

static inline int het_rdv_host(uint64_t *_ctr, uint64_t _target, long _cap,
                               het_poke_fn _poke) {
  uint64_t _v = __atomic_fetch_add(_ctr, 1ull, __ATOMIC_RELAXED) + 1ull;
  long _i = 0;
  while (_v < _target && _i < _cap) {
    _i++;
    if (_poke != NULL && (_i & (HET_RDV_POKE_EVERY - 1)) == 0) _poke();
    _v = __atomic_load_n(_ctr, __ATOMIC_RELAXED);
  }
  return _v >= _target;
}

/* Empty asm on purpose: a spin that touched memory would add traffic to the
   window the delay sweeps. */
__device__ __host__ static inline void het_rdv_jitter(uint32_t _draw,
                                                      uint32_t _max) {
  uint32_t _k = (_max > 0u) ? (_draw % (_max + 1u)) : 0u;
  while (_k > 0u) { _k--; __asm__ __volatile__("" ::: "memory"); }
}

#endif /* HET_RDV_H */

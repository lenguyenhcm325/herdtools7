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

/* HetLitmus: the cross-device rendezvous, and the per-iteration slot layout it
 * pairs.  Iteration n of the persistent loop begins when every participant has
 * arrived at a shared counter, and then touches slot n ALONE on both sides, so
 * the outcome of iteration n is read back from slot n with no search and no
 * decoding.  An iteration whose rendezvous timed out is discarded, never scored.
 *
 * This header travels to GPU boxes inside a harness directory, so it stands on
 * its own.  Design: hetlitmus/docs/00-environment-design.md. */

#ifndef HET_RDV_H
#define HET_RDV_H

#include "het_stress.h"   /* het_rng_t: the jitter draws from the lane's RNG */

/* Distance between one iteration's slot and the next, in elements of the shared
   arrays (int).  32 ints = 128 B, one cache line per slot, so two iterations
   share neither a word nor a line, and a location costs SIZE_OF_TEST * 128 B. */
#ifndef HET_SLOT_STRIDE_WORDS
#define HET_SLOT_STRIDE_WORDS 32
#endif

/* How long a participant waits for the others, in polls, before it gives up on
   this iteration.  Both are placeholders: no target has been measured, so a run
   prints them with HET_CAP_CALIBRATED and every null they produce says
   uncalibrated.  Both are overridden at run time by HET_CAP_GPU / HET_CAP_CPU. */
#ifndef HET_CAP_GPU
#define HET_CAP_GPU 4096
#endif
#ifndef HET_CAP_CPU
#define HET_CAP_CPU 262144
#endif
/* 1 once the two caps above have been measured on the target this harness is
   built for; the placeholders are not that measurement. */
#ifndef HET_CAP_CALIBRATED
#define HET_CAP_CALIBRATED 0
#endif

/* The post-release delay, in spins.  Each participant leaves the rendezvous
   after 0..HET_RELEASE_JITTER spins of its own, so the iterations sweep the
   relative phase of the two devices instead of repeating one alignment. */
#ifndef HET_RELEASE_JITTER
#define HET_RELEASE_JITTER 64
#endif

/* What the host rendezvous calls while it waits, or NULL.  A CUDA host thread
   that spins without entering the runtime can starve the grid it is waiting for
   [CudaGuide "CUDA C++ Execution model"], so the CUDA render hands this a
   runtime call; the HIP render hands it NULL. */
typedef void (*het_poke_fn)(void);

/* Arrive, then poll: relaxed, with NO fence anywhere.  An acquire poll
   self-invalidates the GPU L1 [Bagchi26 sec 5.3] / emits buffer_inv on gfx942,
   which destroys the very cache state the tested iteration is about to race on,
   so the rendezvous orders nothing and is not part of the program under test:
   it only decides when both sides start.  The counter is monotone and each
   participant adds 1 per iteration, so the target of iteration n is
   NPART*(n+1) and the last arriver reads it off its own fetch_add.
   Returns 1 iff this participant saw the target -- 0 means the cap expired and
   the caller's iteration is discarded. */
#if defined(__HIP_PLATFORM_AMD__) || defined(__HIP_DEVICE_COMPILE__)
__device__ static inline int het_rdv_device(uint64_t *_ctr, uint64_t _target,
                                            uint32_t _cap) {
  uint64_t _v = __hip_atomic_fetch_add(_ctr, 1ull, __ATOMIC_RELAXED,
                                       __HIP_MEMORY_SCOPE_SYSTEM) + 1ull;
  uint32_t _i = 0;
  while (_v < _target && _i < _cap) {
    _i++;
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

/* The host half.  [_poke] is called once per poll, and the emitter passes it on
   iteration 0 alone: past that the grid is resident, and a vendor runtime call
   inside the tested loop is traffic the tested window does not need. */
static inline int het_rdv_host(uint64_t *_ctr, uint64_t _target, long _cap,
                               het_poke_fn _poke) {
  uint64_t _v = __atomic_fetch_add(_ctr, 1ull, __ATOMIC_RELAXED) + 1ull;
  long _i = 0;
  while (_v < _target && _i < _cap) {
    _i++;
    if (_poke != NULL) _poke();
    _v = __atomic_load_n(_ctr, __ATOMIC_RELAXED);
  }
  return _v >= _target;
}

/* The release delay, drawn per participant per iteration.  An empty volatile asm
   is the body because it costs no memory operation: a spin that touched memory
   would add traffic to the window the delay exists to sweep. */
__device__ __host__ static inline void het_rdv_jitter(het_rng_t *_rng,
                                                      uint32_t _max) {
  uint32_t _k = (_max > 0u) ? (het_rng_next(_rng) % (_max + 1u)) : 0u;
  while (_k > 0u) { _k--; __asm__ __volatile__("" ::: "memory"); }
}

#endif /* HET_RDV_H */

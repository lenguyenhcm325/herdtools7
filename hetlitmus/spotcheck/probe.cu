/* =========================================================================
 * HetLitmus dev-tier PROBE -- what does this machine actually offer?
 * =========================================================================
 * Run FIRST on any rented instance, before building a single harness.  The
 * het harness makes four hard demands, and each of them is a runtime property
 * of the box, not of the code:
 *
 *   1. cooperative launch.  The driver returns 2 immediately without it
 *      (`cooperative launch unsupported on this device'), so a box that lacks
 *      it runs NOTHING and there is no point building anything.
 *   2. a shared-memory mode whose system-scope atomics are actually atomic.
 *      The CUDA C++ Memory Model gives one condition per mode: system-allocated
 *      memory needs pageableMemoryAccess=1, managed memory needs
 *      concurrentManagedAccess=1, mapped memory needs
 *      hostNativeAtomicSupported=1 (plus the separate allowance for plain
 *      naturally-aligned loads/stores of 1/2/4/8/16 bytes on mapped memory).
 *      HET_ALLOC picks the mode; this probe says which ones are legal here.
 *   3. usesHostPageTables, to know WHICH machine this is.  The guide defines
 *      that attribute as the mechanism of CPU/GPU coherence: 1 is hardware
 *      (ATS -- GH200, DGX Spark), 0 is software (HMM).  An x86 or PCIe box on a
 *      recent driver can report pageableMemoryAccess=1 through HMM and take the
 *      very same malloc branch as GH200 while being a different experiment.
 *   4. a GPU that can be launched on at all, at this compute capability.
 *
 * Everything is printed as key=value, one per line, so probe.txt is greppable
 * and diffable across boxes.  Compile with PTX only (see probe.sh) -- this file
 * must load on sm_60 through sm_121+ without knowing the arch in advance.
 *
 * SCOPE: this is a machine probe.  It makes no memory-model claim and its
 * output is never a litmus result.
 * ========================================================================= */
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cuda_runtime.h>

__global__ void probe_write(unsigned long long *p, unsigned long long v) {
  if (threadIdx.x == 0 && blockIdx.x == 0) *p = v;
}

/* One thread, `iters' system-scope increments.  The host does the same count
   concurrently; a short total is decisive evidence that a system-scope RMW is
   not atomic against the CPU in this mode.  (A matching total is only WEAK
   evidence the other way -- see the note printed with the result.) */
__global__ void probe_sysadd(unsigned long long *p, int iters) {
  if (threadIdx.x == 0 && blockIdx.x == 0)
    for (int i = 0; i < iters; i++) atomicAdd_system(p, 1ull);
}

static int iattr(cudaDeviceAttr a) {
  int v = -1;
  if (cudaDeviceGetAttribute(&v, a, 0) != cudaSuccess) return -1;
  return v;
}

#define SYS_ITERS 200000

/* Exercise one HET_ALLOC mode: allocate, have the device write through the
   pointer, read it back on the host, then race a system-scope fetch_add against
   the host.
   NEVER EXERCISE A MODE THE DEVICE CANNOT REACH.  An illegal access does not
   just fail -- cudaErrorIllegalAddress is STICKY and poisons the whole context,
   so every later probe returns the same error and the report reads as if the
   machine offered nothing.  (Measured: probing malloc on a
   pageableMemoryAccess=0 box turned managed and pinned into ALLOC_FAIL too.)
   `reachable' gates the whole mode; `concurrent_ok' gates only the race, because
   at concurrentManagedAccess=0 managed memory is perfectly usable in the
   launch-sync-read pattern and only CONCURRENT CPU access faults. */
static int poisoned = 0;

static void exercise(const char *mode, int reachable, const char *why_not,
                     int concurrent_ok, int rmw_atomic) {
  unsigned long long *p = NULL;
  cudaError_t e = cudaSuccess;
  if (poisoned) { printf("mode_%s=NOT_PROBED(context poisoned earlier)\n", mode); return; }
  if (!reachable) {
    printf("mode_%s=skipped(%s)\n", mode, why_not);
    printf("sysatomic_%s=skipped(%s)\n", mode, why_not);
    return;
  }
  if (mode[0] == 'm' && mode[2] == 'l') {                            /* malloc  */
    p = (unsigned long long *)malloc(sizeof(unsigned long long));
    if (p == NULL) e = cudaErrorMemoryAllocation;
  } else if (mode[0] == 'm') {                                       /* managed */
    e = cudaMallocManaged((void **)&p, sizeof(unsigned long long));
  } else {                                                           /* pinned  */
    e = cudaHostAlloc((void **)&p, sizeof(unsigned long long),
                      cudaHostAllocMapped | cudaHostAllocPortable);
  }
  if (e != cudaSuccess || p == NULL) {
    printf("mode_%s=ALLOC_FAIL(%s)\n", mode, cudaGetErrorString(e));
    return;
  }
  *p = 0ull;
  probe_write<<<1, 1>>>(p, 0x5eedull);
  e = cudaDeviceSynchronize();
  if (e != cudaSuccess) {
    printf("mode_%s=DEVICE_WRITE_FAIL(%s)\n", mode, cudaGetErrorString(e));
    if (e == cudaErrorIllegalAddress) { poisoned = 1; return; }
  } else if (*p != 0x5eedull) {
    printf("mode_%s=INCOHERENT(read 0x%llx)\n", mode, (unsigned long long)*p);
  } else {
    printf("mode_%s=ok rmw_atomic_per_model=%d\n", mode, rmw_atomic);
  }

  if (!concurrent_ok) {
    printf("sysatomic_%s=skipped(concurrentManagedAccess=0: a concurrent host "
           "access would fault)\n", mode);
  } else {
    *p = 0ull;
    probe_sysadd<<<1, 1>>>(p, SYS_ITERS);
    for (int i = 0; i < SYS_ITERS; i++)
      __atomic_fetch_add(p, 1ull, __ATOMIC_SEQ_CST);
    e = cudaDeviceSynchronize();
    if (e != cudaSuccess) {
      printf("sysatomic_%s=LAUNCH_FAIL(%s)\n", mode, cudaGetErrorString(e));
      if (e == cudaErrorIllegalAddress) { poisoned = 1; return; }
    } else {
      printf("sysatomic_%s=%llu/%d\n", mode, (unsigned long long)*p, 2 * SYS_ITERS);
    }
  }

  if (mode[0] == 'm' && mode[2] == 'l') free(p);
  else if (mode[0] == 'm') cudaFree(p);
  else cudaFreeHost(p);
}

int main(void) {
  int n = 0, drv = 0, rt = 0;
  cudaError_t e = cudaGetDeviceCount(&n);
  printf("probe_version=PORT1\n");
  printf("device_count=%d\n", n);
  if (e != cudaSuccess || n < 1) {
    printf("probe_status=NO_DEVICE(%s)\n", cudaGetErrorString(e));
    return 2;
  }
  (void)cudaDriverGetVersion(&drv);
  (void)cudaRuntimeGetVersion(&rt);
  printf("driver_version=%d\n", drv);
  printf("runtime_version=%d\n", rt);

  cudaDeviceProp prop;
  if (cudaGetDeviceProperties(&prop, 0) != cudaSuccess) {
    printf("probe_status=NO_PROPS\n");
    return 2;
  }
  printf("device_name=%s\n", prop.name);
  printf("compute_capability=%d.%d\n", prop.major, prop.minor);
  printf("suggested_cuda_arch=sm_%d%d\n", prop.major, prop.minor);
  printf("sm_count=%d\n", prop.multiProcessorCount);
  printf("l2_cache_bytes=%d\n", prop.l2CacheSize);
  printf("global_mem_mb=%llu\n",
         (unsigned long long)(prop.totalGlobalMem / (1024ull * 1024ull)));

  /* The four attributes the shared allocator turns on, plus the two the driver
     and the barrier turn on. */
  int pg   = iattr(cudaDevAttrPageableMemoryAccess);
  int ht   = iattr(cudaDevAttrPageableMemoryAccessUsesHostPageTables);
  int cma  = iattr(cudaDevAttrConcurrentManagedAccess);
  int hna  = iattr(cudaDevAttrHostNativeAtomicSupported);
  int coop = iattr(cudaDevAttrCooperativeLaunch);
  printf("pageableMemoryAccess=%d\n", pg);
  printf("usesHostPageTables=%d\n", ht);
  printf("concurrentManagedAccess=%d\n", cma);
  printf("hostNativeAtomicSupported=%d\n", hna);
  printf("cooperativeLaunch=%d\n", coop);
  printf("managedMemory=%d\n", iattr(cudaDevAttrManagedMemory));
  printf("unifiedAddressing=%d\n", iattr(cudaDevAttrUnifiedAddressing));
  printf("directManagedMemAccessFromHost=%d\n",
         iattr(cudaDevAttrDirectManagedMemAccessFromHost));

  printf("coherence_mechanism=%s\n",
         pg <= 0 ? "none" : (ht == 1 ? "hardware-ATS" : "software-HMM"));
  printf("het_alloc_auto_would_pick=%s\n", pg == 1 ? "malloc" : "managed");
  printf("harness_can_run=%s\n", coop == 1 ? "yes" : "NO-cooperative-launch");

  int mm  = iattr(cudaDevAttrManagedMemory);
  int map = iattr(cudaDevAttrCanMapHostMemory);
  exercise("malloc",  pg == 1,  "pageableMemoryAccess=0: the device cannot address system malloc",
           pg == 1,  pg == 1);
  exercise("managed", mm == 1,  "managedMemory=0: no managed allocator here",
           cma == 1, cma == 1);
  exercise("pinned",  map == 1, "canMapHostMemory=0: no mapped host memory here",
           1,        hna == 1);
  printf("sysatomic_note=a SHORT total is decisive (that mode's read-modify-write "
         "is not system-atomic against the CPU); a matching total is WEAK evidence "
         "-- the kernel may simply have finished before the host loop started\n");
  printf("probe_status=%s\n", poisoned ? "POISONED-partial" : "OK");
  return poisoned ? 1 : 0;
}

/* The machine probe: what this box offers, printed as key=value lines for
 * probe.txt.  Run it FIRST on a rented instance -- cooperative launch, which
 * shared-memory modes are legal, and the coherence mechanism behind them are
 * runtime properties of the box that the harness demands and the code cannot
 * settle.  Which key decides what: README.md beside this file.  Compile to PTX
 * only (probe-cuda.sh): this file must load without knowing the arch first.  It
 * makes no memory-model claim and its output is never a litmus result. */
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cuda_runtime.h>

__global__ void probe_write(unsigned long long *p, unsigned long long v) {
  if (threadIdx.x == 0 && blockIdx.x == 0) *p = v;
}

/* One thread, `iters' system-scope increments, raced against the same count on
   the host: a short total is decisive that this mode's read-modify-write is not
   atomic against the CPU, a matching one only weak evidence the other way. */
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

/* Exercise one HET_ALLOC mode: allocate, write through the pointer on the
   device, read it back on the host, then race a system-scope fetch_add.
   NEVER exercise a mode the device cannot reach: cudaErrorIllegalAddress is
   sticky and poisons the context.  `reachable' gates the whole mode;
   `concurrent_ok' gates only the race. */
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

  /* The attributes the shared allocator, the driver and the barrier turn on. */
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

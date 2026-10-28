static int gd_alloc_noise(void** _pp, size_t _bytes){
  *_pp = NULL;
  if (hipMallocManaged(_pp, _bytes) != hipSuccess || *_pp == NULL) return -1;
  het_cpu_first_touch(*_pp, _bytes);   /* untouched pages all map to one zero page */
  return 0;
}
static void gd_free_noise(void* _p){
  if (_p != NULL) (void)hipFree(_p);
}

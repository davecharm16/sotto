#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdatomic.h>
typedef void (malloc_logger_t)(uint32_t type, uintptr_t a1, uintptr_t a2, uintptr_t a3, uintptr_t result, uint32_t skip);
extern malloc_logger_t *malloc_logger;
static _Atomic(uintptr_t) rt_threads[4];
static _Atomic long rt_allocs, rt_frees;
static void logger(uint32_t type, uintptr_t a1, uintptr_t a2, uintptr_t a3, uintptr_t result, uint32_t skip) {
    uintptr_t self = (uintptr_t)pthread_self();
    for (int i = 0; i < 4; i++) if (atomic_load_explicit(&rt_threads[i], memory_order_relaxed) == self) {
        if (type & 2) atomic_fetch_add(&rt_allocs, 1);
        if (type & 4) atomic_fetch_add(&rt_frees, 1);
        return; }
}
void rtguard_install(void) { malloc_logger = logger; }
void rtguard_mark(int slot) { atomic_store_explicit(&rt_threads[slot], (uintptr_t)pthread_self(), memory_order_relaxed); }
void rtguard_unmark(int slot) { atomic_store(&rt_threads[slot], 0); }
long rtguard_allocs(void) { return atomic_load(&rt_allocs); }
long rtguard_frees(void) { return atomic_load(&rt_frees); }
long rtguard_selftest(void) { rtguard_mark(3); long b = rtguard_allocs(); void *p = malloc(64); free(p); long d = rtguard_allocs() - b; rtguard_unmark(3); return d; }

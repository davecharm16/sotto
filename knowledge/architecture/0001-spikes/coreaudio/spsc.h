// C11/clang atomics shim: what a bridging-header include would give the app on macOS 13 without SPM deps.
#include <stdint.h>
static inline int64_t sp_load_acq(const int64_t *p) { return __atomic_load_n(p, __ATOMIC_ACQUIRE); }
static inline int64_t sp_load_relaxed(const int64_t *p) { return __atomic_load_n(p, __ATOMIC_RELAXED); }
static inline void sp_store_rel(int64_t *p, int64_t v) { __atomic_store_n(p, v, __ATOMIC_RELEASE); }
static inline void sp_add_relaxed(int64_t *p, int64_t v) { __atomic_fetch_add(p, v, __ATOMIC_RELAXED); }
static inline void sp_max_relaxed(int64_t *p, int64_t v) { int64_t c = __atomic_load_n(p, __ATOMIC_RELAXED); while (v > c && !__atomic_compare_exchange_n(p, &c, v, 1, __ATOMIC_RELAXED, __ATOMIC_RELAXED)) {} }
static inline void sp_min_relaxed(int64_t *p, int64_t v) { int64_t c = __atomic_load_n(p, __ATOMIC_RELAXED); while (v < c && !__atomic_compare_exchange_n(p, &c, v, 1, __ATOMIC_RELAXED, __ATOMIC_RELAXED)) {} }
void rtguard_install(void); void rtguard_mark(int slot); void rtguard_unmark(int slot);
long rtguard_allocs(void); long rtguard_frees(void); long rtguard_selftest(void);

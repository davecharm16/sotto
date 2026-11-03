#ifndef SottoAtomics_h
#define SottoAtomics_h

#include <stdatomic.h>
#include <stdint.h>

// Lock-free primitives for the audio rings and flags. The stdlib `Synchronization.Atomic` needs macOS 15 and the
// deployment target is 13, so Swift goes through these inlines. Callers pass naturally aligned UInt64 storage that
// they own for the lifetime of the atomic (clang accepts the _Atomic cast on such storage). Included from
// DeepFilter-Bridging-Header.h.

static inline uint64_t sotto_load_acquire(const uint64_t *p) {
    return atomic_load_explicit((const _Atomic uint64_t *)p, memory_order_acquire);
}
static inline uint64_t sotto_load_relaxed(const uint64_t *p) {
    return atomic_load_explicit((const _Atomic uint64_t *)p, memory_order_relaxed);
}
static inline void sotto_store_release(uint64_t *p, uint64_t v) {
    atomic_store_explicit((_Atomic uint64_t *)p, v, memory_order_release);
}
static inline void sotto_store_relaxed(uint64_t *p, uint64_t v) {
    atomic_store_explicit((_Atomic uint64_t *)p, v, memory_order_relaxed);
}

#endif

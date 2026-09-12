// Test-only process allocator instrumentation, never linked into Mojo products.
#include "probe.h"
#include <stdatomic.h>
#include <stddef.h>
#include <stdlib.h>

static _Atomic int enabled;
static _Atomic uint64_t allocations;

void swift_mojo_probe_begin(void) {
    atomic_store_explicit(&allocations, 0, memory_order_relaxed);
    atomic_store_explicit(&enabled, 1, memory_order_relaxed);
}

uint64_t swift_mojo_probe_end(void) {
    atomic_store_explicit(&enabled, 0, memory_order_relaxed);
    return atomic_load_explicit(&allocations, memory_order_relaxed);
}

static void record(void) {
    if (atomic_load_explicit(&enabled, memory_order_relaxed))
        atomic_fetch_add_explicit(&allocations, 1, memory_order_relaxed);
}

#if defined(__APPLE__)
#include <malloc/malloc.h>
static void *probe_zone_malloc(malloc_zone_t *zone, size_t size) { record(); return malloc_zone_malloc(zone, size); }
static void *probe_zone_calloc(malloc_zone_t *zone, size_t count, size_t size) { record(); return malloc_zone_calloc(zone, count, size); }
static void *probe_zone_memalign(malloc_zone_t *zone, size_t alignment, size_t size) { record(); return malloc_zone_memalign(zone, alignment, size); }
static int probe_posix_memalign(void **pointer, size_t alignment, size_t size) { record(); return posix_memalign(pointer, alignment, size); }
static void *probe_malloc(size_t size) { record(); return malloc(size); }
static void *probe_calloc(size_t count, size_t size) { record(); return calloc(count, size); }
static void *probe_realloc(void *pointer, size_t size) { record(); return realloc(pointer, size); }
#define INTERPOSE(replacement, original) \
    __attribute__((used, section("__DATA,__interpose"))) \
    static const struct { const void *new_function; const void *old_function; } \
    pair_##original = { (const void *)&replacement, (const void *)&original }
INTERPOSE(probe_zone_malloc, malloc_zone_malloc);
INTERPOSE(probe_zone_calloc, malloc_zone_calloc);
INTERPOSE(probe_zone_memalign, malloc_zone_memalign);
INTERPOSE(probe_posix_memalign, posix_memalign);
INTERPOSE(probe_malloc, malloc);
INTERPOSE(probe_calloc, calloc);
INTERPOSE(probe_realloc, realloc);
#elif defined(__GLIBC__)
#include <dlfcn.h>
#include <pthread.h>
static pthread_once_t aligned_once = PTHREAD_ONCE_INIT;
static int (*original_posix_memalign)(void **, size_t, size_t);
static void resolve_aligned_allocator(void) {
    original_posix_memalign = dlsym(RTLD_NEXT, "posix_memalign");
    if (!original_posix_memalign) abort();
}
int posix_memalign(void **pointer, size_t alignment, size_t size) {
    pthread_once(&aligned_once, resolve_aligned_allocator);
    record();
    return original_posix_memalign(pointer, alignment, size);
}
extern void *__libc_malloc(size_t);
extern void *__libc_calloc(size_t, size_t);
extern void *__libc_realloc(void *, size_t);
void *malloc(size_t size) { record(); return __libc_malloc(size); }
void *calloc(size_t count, size_t size) { record(); return __libc_calloc(count, size); }
void *realloc(void *pointer, size_t size) { record(); return __libc_realloc(pointer, size); }
#else
#error This test probe requires Darwin or glibc allocator entry points.
#endif

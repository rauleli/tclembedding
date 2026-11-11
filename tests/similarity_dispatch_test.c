/* Exercise both implementations and concurrent stateless dispatch. */
#include "../src/similarity.h"
#include <pthread.h>
#include <math.h>
#include <stdio.h>
#include <stdint.h>
#include <stdatomic.h>

int similarity_scalar_cosine(const unsigned char *, const unsigned char *, size_t, size_t,
                             double *);
int similarity_sse2_cosine(const unsigned char *, const unsigned char *, size_t, size_t, double *);
int __real_similarity_sse2_cosine(const unsigned char *, const unsigned char *, size_t, size_t,
                                  double *);
static _Atomic unsigned long sse2_calls;
int __wrap_similarity_sse2_cosine(const unsigned char *a, const unsigned char *b, size_t na,
                                  size_t nb, double *out) {
    atomic_fetch_add_explicit(&sse2_calls, 1, memory_order_relaxed);
    return __real_similarity_sse2_cosine(a, b, na, nb, out);
}
static void *worker(void *unused) {
    (void)unused;
    const unsigned char a[] = {0, 0, 128, 63, 0, 0, 0, 64}, b[] = {0, 0, 0, 64, 0, 0, 128, 63};
    for (int i = 0; i < 10000; i++) {
        double x = 0, y = 0, z = 0;
        if (!similarity_scalar_cosine(a, b, 8, 8, &x) || !similarity_sse2_cosine(a, b, 8, 8, &y) ||
            !similarity_cosine_f32le(a, b, 8, 8, &z) || fabs(x - y) > 1e-12 || fabs(y - z) > 1e-12)
            return (void *)(uintptr_t)1;
        z = 19;
        if (similarity_cosine_f32le(a, b, 8, 4, &z) || z != 19)
            return (void *)(uintptr_t)1;
    }
    return NULL;
}
int main(void) {
    pthread_t threads[8];
    for (int i = 0; i < 8; i++)
        if (pthread_create(&threads[i], NULL, worker, NULL))
            return 1;
    for (int i = 0; i < 8; i++) {
        void *result;
        if (pthread_join(threads[i], &result) || result)
            return 1;
    }
    /* Each iteration makes one direct call and two dispatched calls. */
    if (atomic_load_explicit(&sse2_calls, memory_order_relaxed) != 240000)
        return 1;
    puts("scalar, SSE2 and concurrent dispatch passed");
    return 0;
}

#define _POSIX_C_SOURCE 200809L
#define COSINE_STANDALONE 1
#include "../src/similarity.c"
#define cosine_le similarity_cosine_f32le
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static void put32(unsigned char *p, float f) {
    uint32_t bits;
    memcpy(&bits, &f, 4);
    for (int i = 0; i < 4; i++)
        p[i] = (unsigned char)(bits >> (8 * i));
}
static void check(int condition, const char *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message);
        exit(1);
    }
}
static long double reference(const float *a, const float *b, size_t n) {
    long double dot = 0, aa = 0, bb = 0;
    for (size_t i = 0; i < n; i++) {
        long double x = a[i], y = b[i];
        dot += x * y;
        aa += x * x;
        bb += y * y;
    }
    return (dot / sqrtl(aa)) / sqrtl(bb);
}
static double seconds(void) {
    struct timespec t;
    check(clock_gettime(CLOCK_MONOTONIC, &t) == 0, "clock");
    return (double)t.tv_sec + (double)t.tv_nsec / 1e9;
}
int main(void) {
    unsigned char abuf[4 * 768 + 1], bbuf[4 * 768 + 1];
    unsigned char *a = abuf + 1, *b = bbuf + 1; /* Deliberately unaligned. */
    float av[768], bv[768];
    double actual;
    put32(a, 1.0f);
    put32(a + 4, 0.0f);
    put32(b, 0.0f);
    put32(b + 4, 1.0f);
    check(cosine_le(a, a, 8, 8, &actual) && fabs(actual - 1) < 1e-12, "identical");
    check(cosine_le(a, b, 8, 8, &actual) && fabs(actual) < 1e-12, "orthogonal");
    put32(b, -1.0f);
    put32(b + 4, 0.0f);
    check(cosine_le(a, b, 8, 8, &actual) && fabs(actual + 1) < 1e-12, "opposite");
    put32(a, -2.0f);
    put32(a + 4, 3.0f);
    put32(b, 4.0f);
    put32(b + 4, -5.0f);
    check(similarity_dot_f32le(a, b, 8, 8, &actual) && actual == -23.0, "dot product");
    check(!similarity_dot_f32le(a, b, 8, 4, &actual), "dot length mismatch");
    av[0] = -2;
    av[1] = 3;
    bv[0] = 4;
    bv[1] = -5;
    check(cosine_le(a, b, 8, 8, &actual) && fabsl(actual - reference(av, bv, 2)) < 1e-12L,
          "negative values");
    check(!cosine_le(a, b, 8, 4, &actual), "different dimensions");
    check(!cosine_le(a, b, 3, 3, &actual), "mis-sized blob");
    check(!cosine_le(a, b, 0, 0, &actual), "empty blobs");
    check(!cosine_le(NULL, b, 4, 4, &actual), "null pointer");
    put32(a, 0.0f);
    put32(a + 4, 0.0f);
    check(similarity_dot_f32le(a, a, 8, 8, &actual) && actual == 0.0, "zero dot product");
    check(!cosine_le(a, a, 8, 8, &actual), "same zero pointer");
    const unsigned char nan32[] = {0, 0, 0xc0, 0x7f}, inf32[] = {0, 0, 0x80, 0x7f};
    actual = 123.0;
    check(!similarity_dot_f32le(nan32, nan32, 4, 4, &actual) && actual == 123.0,
          "dot rejects NaN without changing output");
    check(!similarity_dot_f32le(inf32, inf32, 4, 4, &actual), "dot rejects infinity");
    check(!similarity_dot_f32le(inf32, inf32, 4, 4, NULL), "dot rejects null output");
    check(!cosine_le(nan32, nan32, 4, 4, &actual), "same NaN pointer");
    check(!cosine_le(inf32, inf32, 4, 4, &actual), "infinity");
    const unsigned char one[] = {0, 0, 0x80, 0x3f};
    check(read_float32_le(one) == 1.0f, "little-endian byte order");
    put32(a, FLT_MAX);
    put32(a + 4, FLT_MAX);
    put32(b, FLT_MAX);
    put32(b + 4, -FLT_MAX);
    check(cosine_le(a, b, 8, 8, &actual) && fabs(actual) < 1e-12, "large finite values");
    const unsigned char tiny[] = {1, 0, 0, 0};
    check(cosine_le(tiny, tiny, 4, 4, &actual) && fabs(actual - 1) < 1e-12, "smallest subnormal");
    uint32_t state = 123456789;
    for (size_t n = 1; n <= 768; n++) {
        for (size_t i = 0; i < n; i++) {
            state = 1664525u * state + 1013904223u;
            av[i] = (float)((int)(state % 20001) - 10000) / 10000.0f;
            state = 1664525u * state + 1013904223u;
            bv[i] = (float)((int)(state % 20001) - 10000) / 10000.0f;
            put32(a + 4 * i, av[i]);
            put32(b + 4 * i, bv[i]);
        }
        check(cosine_le(a, b, 4 * n, 4 * n, &actual), "random vector valid");
        check(fabsl(actual - reference(av, bv, n)) < 1e-12L, "reference tolerance");
    }
    volatile double sink = 0.0;
    double start = seconds();
    for (int k = 0; k < 10000; k++) {
        check(cosine_le(a, b, 4 * 768, 4 * 768, &actual), "benchmark");
        sink += actual;
    }
    double elapsed = seconds() - start;
    printf("implementation=%s reference_cases=768 tolerance=1e-12 benchmark_calls=10000 "
           "dimension=768 elapsed_ms=%.3f sink=%.6f\n",
           COSINE_SSE2 ? "sse2" : "scalar", elapsed * 1000.0, (double)sink);
    return 0;
}

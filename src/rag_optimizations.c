/*
 * rag_optimizations.c - MySQL UDF for SIMD-optimized Cosine Similarity
 * High-performance vector similarity calculation for RAG applications
 *
 * Features:
 * - AVX2 acceleration with FMA (Fused Multiply-Add) for modern CPUs
 * - SSE4.1 fallback for older x86_64 systems
 * - Scalar fallback for maximum portability
 * - Efficient horizontal SIMD reductions
 * - Flexible vector dimension handling
 *
 * COMPILATION:
 * gcc -O3 -march=native -ffast-math -fno-math-errno -flto \
 *     -shared -fPIC \
 *     -o udf_cosine_similarity.so rag_optimizations.c \
 *     -I/usr/include/mysql -lm
 *
 * INSTALLATION:
 * sudo cp udf_cosine_similarity.so /usr/lib/mysql/plugin/
 *
 * MYSQL REGISTRATION:
 * CREATE FUNCTION cosine_similarity RETURNS REAL SONAME 'udf_cosine_similarity.so';
 *
 * USAGE:
 * SELECT cosine_similarity(embedding1, embedding2) FROM vectors;
 *
 * Copyright (c) 2024
 * License: MIT
 */

#include <mysql.h>
#include <string.h>
#include <math.h>
#include <float.h>
#include <immintrin.h>

/* MySQL 8.0 compatibility - my_bool was removed */
#ifndef my_bool
typedef char my_bool;
#endif

/* =========================
   Horizontal SIMD Reductions
   ========================= */

static inline float hsum_sse(__m128 v) {
    __m128 shuf = _mm_movehdup_ps(v);
    __m128 sums = _mm_add_ps(v, shuf);
    shuf = _mm_movehl_ps(shuf, sums);
    sums = _mm_add_ss(sums, shuf);
    return _mm_cvtss_f32(sums);
}

#ifdef __AVX2__
static inline float hsum_avx(__m256 v) {
    __m128 vlow  = _mm256_castps256_ps128(v);
    __m128 vhigh = _mm256_extractf128_ps(v, 1);
    vlow = _mm_add_ps(vlow, vhigh);
    return hsum_sse(vlow);
}
#endif

/* =========================
   SIMD Implementations
   ========================= */

#ifdef __AVX2__
static float cosine_sim_avx(const float *a, const float *b, int n) {
    __m256 dot_v = _mm256_setzero_ps();
    __m256 ma2_v = _mm256_setzero_ps();
    __m256 mb2_v = _mm256_setzero_ps();

    int i = 0;
    for (; i <= n - 8; i += 8) {
        __m256 av = _mm256_loadu_ps(a + i);
        __m256 bv = _mm256_loadu_ps(b + i);
        dot_v = _mm256_fmadd_ps(av, bv, dot_v);
        ma2_v = _mm256_fmadd_ps(av, av, ma2_v);
        mb2_v = _mm256_fmadd_ps(bv, bv, mb2_v);
    }

    float dot = hsum_avx(dot_v);
    float ma2 = hsum_avx(ma2_v);
    float mb2 = hsum_avx(mb2_v);

    for (; i < n; i++) {
        dot += a[i] * b[i];
        ma2 += a[i] * a[i];
        mb2 += b[i] * b[i];
    }

    if (ma2 <= FLT_MIN || mb2 <= FLT_MIN)
        return 0.0f;

    return dot / (sqrtf(ma2) * sqrtf(mb2));
}
#endif

#ifdef __SSE4_1__
static float cosine_sim_sse(const float *a, const float *b, int n) {
    __m128 dot_v = _mm_setzero_ps();
    __m128 ma2_v = _mm_setzero_ps();
    __m128 mb2_v = _mm_setzero_ps();

    int i = 0;
    for (; i <= n - 4; i += 4) {
        __m128 av = _mm_loadu_ps(a + i);
        __m128 bv = _mm_loadu_ps(b + i);
        dot_v = _mm_add_ps(dot_v, _mm_mul_ps(av, bv));
        ma2_v = _mm_add_ps(ma2_v, _mm_mul_ps(av, av));
        mb2_v = _mm_add_ps(mb2_v, _mm_mul_ps(bv, bv));
    }

    float dot = hsum_sse(dot_v);
    float ma2 = hsum_sse(ma2_v);
    float mb2 = hsum_sse(mb2_v);

    for (; i < n; i++) {
        dot += a[i] * b[i];
        ma2 += a[i] * a[i];
        mb2 += b[i] * b[i];
    }

    if (ma2 <= FLT_MIN || mb2 <= FLT_MIN)
        return 0.0f;

    return dot / (sqrtf(ma2) * sqrtf(mb2));
}
#endif

/* =========================
   Main Selector
   ========================= */

static inline float calculate_cosine(const float *a, const float *b, int n) {
    if (a == b)
        return 1.0f;

#ifdef __AVX2__
    return cosine_sim_avx(a, b, n);
#elif defined(__SSE4_1__)
    return cosine_sim_sse(a, b, n);
#else
    float dot = 0.0f, ma2 = 0.0f, mb2 = 0.0f;
    for (int i = 0; i < n; i++) {
        dot += a[i] * b[i];
        ma2 += a[i] * a[i];
        mb2 += b[i] * b[i];
    }
    if (ma2 <= FLT_MIN || mb2 <= FLT_MIN)
        return 0.0f;
    return dot / (sqrtf(ma2) * sqrtf(mb2));
#endif
}

/* =========================
   MySQL UDF Interface
   ========================= */

my_bool cosine_similarity_init(UDF_INIT *initid, UDF_ARGS *args, char *message) {
    if (args->arg_count != 2 ||
        args->arg_type[0] != STRING_RESULT ||
        args->arg_type[1] != STRING_RESULT) {
        strcpy(message, "cosine_similarity() requires two float32 blobs");
        return 1;
    }

    initid->maybe_null = 1;
    return 0;
}

double cosine_similarity(UDF_INIT *initid, UDF_ARGS *args,
                          char *is_null, char *error) {
    if (!args->args[0] || !args->args[1]) {
        *is_null = 1;
        return 0.0;
    }

    /* Strict logical alignment validation */
    if ((args->lengths[0] % sizeof(float)) != 0 ||
        (args->lengths[1] % sizeof(float)) != 0) {
        *error = 1;
        return 0.0;
    }

    int n1 = args->lengths[0] / sizeof(float);
    int n2 = args->lengths[1] / sizeof(float);
    int n  = (n1 < n2) ? n1 : n2;

    if (n <= 0) {
        *is_null = 1;
        return 0.0;
    }

    return (double)calculate_cosine(
        (const float *)args->args[0],
        (const float *)args->args[1],
        n
    );
}

void cosine_similarity_deinit(UDF_INIT *initid) {}

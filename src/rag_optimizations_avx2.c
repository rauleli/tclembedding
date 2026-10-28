/*
 * rag_optimizations_avx2.c - UDF MySQL con AVX2 para embeddings de 384 dimensiones
 * Optimizado específicamente para modelos E5-small y similares (384 floats)
 * 
 * COMPILACIÓN:
 * gcc -shared -fPIC -mavx2 -mfma -O3 -o mysql_cosine_similarity_avx2.so rag_optimizations_avx2.c -I/usr/include/mysql
 */

#include <mysql.h>
#include <string.h>
#include <math.h>
#include <immintrin.h>  // AVX2

#ifdef __cplusplus
extern "C" {
#endif

#if !defined(MARIADB_BASE_VERSION) && MYSQL_VERSION_ID >= 80000
typedef bool my_bool;
#endif

/* Función helper para suma horizontal de __m256 */
static inline float horizontal_sum_avx(__m256 v) {
    __m128 vlow = _mm256_castps256_ps128(v);
    __m128 vhigh = _mm256_extractf128_ps(v, 1);
    vlow = _mm_add_ps(vlow, vhigh);
    __m128 shuf = _mm_movehdup_ps(vlow);
    __m128 sums = _mm_add_ps(vlow, shuf);
    shuf = _mm_movehl_ps(shuf, sums);
    sums = _mm_add_ss(sums, shuf);
    return _mm_cvtss_f32(sums);
}

/* Versión optimizada para 384 dimensiones (múltiplo de 16) */
my_bool cosine_similarity_384d_init(UDF_INIT *initid, UDF_ARGS *args, char *message) {
    if (args->arg_count != 2) {
        strcpy(message, "cosine_similarity_384d() requires exactly 2 arguments");
        return 1;
    }
    
    if (args->arg_type[0] != STRING_RESULT || args->arg_type[1] != STRING_RESULT) {
        strcpy(message, "cosine_similarity_384d() requires 2 BLOB arguments (384 floats each)");
        return 1;
    }
    
    initid->ptr = NULL;
    initid->maybe_null = 1;
    initid->const_item = 0;
    
    return 0;
}

double cosine_similarity_384d(UDF_INIT *initid, UDF_ARGS *args, char *is_null, char *error) {
    if (args->args[0] == NULL || args->args[1] == NULL) {
        *is_null = 1;
        return 0.0;
    }
    
    unsigned long len1 = args->lengths[0];
    unsigned long len2 = args->lengths[1];
    
    // 384 floats * 4 bytes = 1536 bytes
    if (len1 != 1536 || len2 != 1536) {
        *error = 1;
        return 0.0;
    }
    
    float *vec1 = (float *)args->args[0];
    float *vec2 = (float *)args->args[1];
    
    // Usar AVX2 si está disponible (384 floats = 12 batches de 32 floats)
    __m256 dot_sum = _mm256_setzero_ps();
    __m256 norm1_sum = _mm256_setzero_ps();
    __m256 norm2_sum = _mm256_setzero_ps();
    
    // Procesar 8 floats a la vez (AVX2 tiene registros de 256 bits = 8 floats)
    for (int i = 0; i < 384; i += 8) {
        __m256 v1 = _mm256_loadu_ps(&vec1[i]);
        __m256 v2 = _mm256_loadu_ps(&vec2[i]);
        
        // dot product: v1 * v2
        __m256 mul = _mm256_mul_ps(v1, v2);
        dot_sum = _mm256_add_ps(dot_sum, mul);
        
        // norms: v1 * v1, v2 * v2
        norm1_sum = _mm256_fmadd_ps(v1, v1, norm1_sum);  // FMA: fused multiply-add
        norm2_sum = _mm256_fmadd_ps(v2, v2, norm2_sum);
    }
    
    // Reducir a escalares
    float dot = horizontal_sum_avx(dot_sum);
    float norm1 = sqrtf(horizontal_sum_avx(norm1_sum));
    float norm2 = sqrtf(horizontal_sum_avx(norm2_sum));
    
    if (norm1 == 0.0f || norm2 == 0.0f) {
        return 0.0;
    }
    
    return (double)(dot / (norm1 * norm2));
}

/* Versión genérica con detección automática de AVX2 */
double cosine_similarity_optimized(UDF_INIT *initid, UDF_ARGS *args, char *is_null, char *error) {
    if (args->args[0] == NULL || args->args[1] == NULL) {
        *is_null = 1;
        return 0.0;
    }
    
    unsigned long len1 = args->lengths[0];
    unsigned long len2 = args->lengths[1];
    
    if (len1 != len2 || len1 % 4 != 0) {
        *error = 1;
        return 0.0;
    }
    
    int num_floats = len1 / 4;
    float *vec1 = (float *)args->args[0];
    float *vec2 = (float *)args->args[1];
    
    // Detectar y usar AVX2 si está disponible
    #ifdef __AVX2__
    if (num_floats >= 32 && (num_floats % 8 == 0)) {
        // Usar implementación AVX2
        __m256 dot_sum = _mm256_setzero_ps();
        __m256 norm1_sum = _mm256_setzero_ps();
        __m256 norm2_sum = _mm256_setzero_ps();
        
        for (int i = 0; i < num_floats; i += 8) {
            __m256 v1 = _mm256_loadu_ps(&vec1[i]);
            __m256 v2 = _mm256_loadu_ps(&vec2[i]);
            
            __m256 mul = _mm256_mul_ps(v1, v2);
            dot_sum = _mm256_add_ps(dot_sum, mul);
            
            norm1_sum = _mm256_fmadd_ps(v1, v1, norm1_sum);
            norm2_sum = _mm256_fmadd_ps(v2, v2, norm2_sum);
        }
        
        float dot = horizontal_sum_avx(dot_sum);
        float norm1 = sqrtf(horizontal_sum_avx(norm1_sum));
        float norm2 = sqrtf(horizontal_sum_avx(norm2_sum));
        
        if (norm1 == 0.0f || norm2 == 0.0f) return 0.0;
        return (double)(dot / (norm1 * norm2));
    }
    #endif
    
    // Fallback a implementación scalar
    double dot_product = 0.0;
    double magnitude1 = 0.0;
    double magnitude2 = 0.0;
    
    for (int i = 0; i < num_floats; i++) {
        float v1 = vec1[i];
        float v2 = vec2[i];
        
        dot_product += v1 * v2;
        magnitude1 += v1 * v1;
        magnitude2 += v2 * v2;
    }
    
    if (magnitude1 == 0.0 || magnitude2 == 0.0) {
        return 0.0;
    }
    
    magnitude1 = sqrt(magnitude1);
    magnitude2 = sqrt(magnitude2);
    
    return dot_product / (magnitude1 * magnitude2);
}

void cosine_similarity_deinit(UDF_INIT *initid) {
    if (initid->ptr != NULL) {
        free(initid->ptr);
    }
}

#ifdef __cplusplus
}
#endif

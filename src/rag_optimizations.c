/*
 * rag_optimizations.c - Funciones UDF para MySQL
 * Extensión C para cálculo rápido de similitud coseno
 * 
 * COMPILACIÓN:
 * gcc -shared -fPIC -march=native -O3 -msse3 -msse4a -o mysql_cosine_similarity.so rag_optimizations.c $(mysql_config --include) -lm
 * 
 * INSTALACIÓN EN MYSQL:
 * sudo cp mysql_cosine_similarity.so /usr/lib/mysql/plugin/
 * 
 * REGISTRO EN MYSQL:
 * CREATE FUNCTION cosine_similarity RETURNS REAL SONAME 'mysql_cosine_similarity.so';
 */
#include <mysql.h>
#include <immintrin.h>
#include <math.h>
#include <string.h>
#ifndef my_bool
typedef char my_bool;
#endif

// Función interna de producto punto acelerada
static inline float dot_product(const float* a, const float* b, int n) {
    float result = 0.0f;
    int i = 0;

    #if defined(__AVX__)
        // Versión AVX para máquinas modernas (8 floats)
        __m256 sum8 = _mm256_setzero_ps();
        for (; i <= n - 8; i += 8) {
            sum8 = _mm256_add_ps(sum8, _mm256_mul_ps(_mm256_loadu_ps(&a[i]), _mm256_loadu_ps(&b[i])));
        }
        float temp8[8];
        _mm256_storeu_ps(temp8, sum8);
        for (int j = 0; j < 8; j++) result += temp8[j];
    #elif defined(__SSE__)
        // Versión óptima para Phenom II (4 floats)
        __m128 sum4 = _mm_setzero_ps();
        for (; i <= n - 4; i += 4) {
            sum4 = _mm_add_ps(sum4, _mm_mul_ps(_mm_loadu_ps(&a[i]), _mm_loadu_ps(&b[i])));
        }
        float temp4[4];
        _mm_storeu_ps(temp4, sum4);
        result = temp4[0] + temp4[1] + temp4[2] + temp4[3];
    #endif

    // Limpieza/Fallback para el resto
    for (; i < n; i++) {
        result += a[i] * b[i];
    }
    return result;
}

// Inicialización del UDF
my_bool cosine_similarity_init(UDF_INIT* initid, UDF_ARGS* args, char* message) {
    if (args->arg_count != 2 || args->arg_type[0] != STRING_RESULT || args->arg_type[1] != STRING_RESULT) {
        strcpy(message, "cosine_similarity requiere dos argumentos BLOB");
        return 1;
    }
    return 0;
}

// Función principal
double cosine_similarity(UDF_INIT* initid, UDF_ARGS* args, char* is_null, char* error) {
    if (!args->args[0] || !args->args[1]) {
        *is_null = 1;
        return 0.0;
    }

    if (args->lengths[0] != args->lengths[1] || (args->lengths[0] % 4) != 0) {
        *error = 1;
        return 0.0;
    }

    int n = args->lengths[0] / sizeof(float);
    const float* a = (const float*)args->args[0];
    const float* b = (const float*)args->args[1];

    // Similitud de coseno = (A·B) / (||A|| * ||B||)
    float dot = dot_product(a, b, n);
    float magA = sqrtf(dot_product(a, a, n));
    float magB = sqrtf(dot_product(b, b, n));

    if (magA == 0.0f || magB == 0.0f) return 0.0;
    
    return (double)(dot / (magA * magB));
}

void cosine_similarity_deinit(UDF_INIT* initid) {}

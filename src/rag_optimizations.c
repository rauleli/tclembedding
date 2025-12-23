/*
 * rag_optimizations.c - Funciones UDF para MySQL
 * Extensión C para cálculo rápido de similitud coseno
 * 
 * COMPILACIÓN:
 * gcc -shared -fPIC -o mysql_cosine_similarity.so rag_optimizations.c -I/usr/include/mysql
 * 
 * INSTALACIÓN EN MYSQL:
 * sudo cp mysql_cosine_similarity.so /usr/lib/mysql/plugin/
 * 
 * REGISTRO EN MYSQL:
 * CREATE FUNCTION cosine_similarity RETURNS REAL SONAME 'mysql_cosine_similarity.so';
 */

#include <mysql.h>
#include <string.h>
#include <math.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Compatibilidad con MySQL 8.0+ */
#if !defined(MARIADB_BASE_VERSION) && MYSQL_VERSION_ID >= 80000
typedef bool my_bool;
#endif

/* Inicialización de la función UDF */
my_bool cosine_similarity_init(UDF_INIT *initid, UDF_ARGS *args, char *message) {
    if (args->arg_count != 2) {
        strcpy(message, "cosine_similarity() requires exactly 2 arguments");
        return 1;
    }
    
    if (args->arg_type[0] != STRING_RESULT || args->arg_type[1] != STRING_RESULT) {
        strcpy(message, "cosine_similarity() requires 2 BLOB arguments");
        return 1;
    }
    
    // Asignar memoria para cálculos intermedios
    initid->ptr = NULL;
    initid->maybe_null = 1;
    initid->const_item = 0;
    
    return 0;
}

/* Cálculo de similitud coseno */
double cosine_similarity(UDF_INIT *initid, UDF_ARGS *args, char *is_null, char *error) {
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

/* Limpieza */
void cosine_similarity_deinit(UDF_INIT *initid) {
    if (initid->ptr != NULL) {
        free(initid->ptr);
    }
}

#ifdef __cplusplus
}
#endif

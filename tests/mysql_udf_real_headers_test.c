/* Direct ABI/type checks with actual MySQL headers; this is not an SQL test. */
#include "../src/similarity.c"
#include "../src/rag_optimizations.c"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>

/* Compile-time checks against the function-pointer types in MySQL 8 headers. */
static Udf_func_init compile_init = cosine_similarity_init;
static Udf_func_double compile_run = cosine_similarity;
static Udf_func_deinit compile_free = cosine_similarity_deinit;
static void check(int ok, const char *message) {
    if (!ok) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}
int main(int argc, char **argv) {
    check(argc == 2 && compile_init && compile_run && compile_free, "arguments and header function types");
    void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    check(library != NULL, "load library");
    Udf_func_init init; Udf_func_double run; Udf_func_deinit finish; void *symbol;
    symbol = dlsym(library, "cosine_similarity_v2_init"); memcpy(&init, &symbol, sizeof(init));
    symbol = dlsym(library, "cosine_similarity_v2"); memcpy(&run, &symbol, sizeof(run));
    symbol = dlsym(library, "cosine_similarity_v2_deinit"); memcpy(&finish, &symbol, sizeof(finish));
    check(init && run && finish, "exported symbols");
    UDF_INIT state = {0}; UDF_ARGS args = {0};
    enum Item_result types[] = {STRING_RESULT, STRING_RESULT};
    unsigned char one[] = {0,0,0x80,0x3f}, zero[] = {0,0,0,0}, nan[] = {0,0,0xc0,0x7f};
    char *values[] = {(char *)one, (char *)one}; unsigned long lengths[] = {4,4};
    args.arg_count=2; args.arg_type=types; args.args=values; args.lengths=lengths;
    char message[256] = {0}; unsigned char is_null=0, error=0;
    check(!init(&state,&args,message) && state.maybe_null && state.decimals==31, "init");
    check(run(&state,&args,&is_null,&error)==1.0 && !is_null && !error, "identical");
    values[0]=NULL; is_null=error=0; run(&state,&args,&is_null,&error); check(is_null && !error, "null");
    values[0]=values[1]=(char *)zero; is_null=error=0; run(&state,&args,&is_null,&error); check(is_null && !error, "zero");
    values[0]=values[1]=(char *)nan; is_null=error=0; run(&state,&args,&is_null,&error); check(is_null && !error, "NaN");
    values[0]=values[1]=(char *)one; lengths[1]=8; is_null=error=0; run(&state,&args,&is_null,&error); check(is_null && !error, "different dimensions");
    lengths[1]=4; run(&state,&args,&is_null,&error); check(!is_null && !error, "valid row after invalid");
    finish(&state); check(dlclose(library)==0, "unload library");
    puts("MySQL header type checks and direct shared-library calls passed; no SQL server tested");
    return 0;
}

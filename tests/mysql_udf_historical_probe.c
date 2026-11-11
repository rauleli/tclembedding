/* Probe a historical library in a separate process; does not register it. */
#include <mysql.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
int main(int argc, char **argv) {
    if (argc != 3)
        return 2;
    void *lib = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!lib) {
        fprintf(stderr, "dlopen failed\n");
        return 2;
    }
    Udf_func_init init = NULL;
    Udf_func_double run = NULL;
    Udf_func_deinit end = NULL;
    void *p = dlsym(lib, "cosine_similarity_init");
    memcpy(&init, &p, sizeof init);
    p = dlsym(lib, "cosine_similarity");
    memcpy(&run, &p, sizeof run);
    p = dlsym(lib, "cosine_similarity_deinit");
    memcpy(&end, &p, sizeof end);
    if (!init || !run || !end)
        return 2;
    UDF_INIT state = {0};
    UDF_ARGS args = {0};
    enum Item_result types[] = {STRING_RESULT, STRING_RESULT};
    unsigned char a[] = {0, 0, 0, 0xc0, 0, 0, 0x40, 0x40};
    unsigned char b[] = {0, 0, 0x80, 0x40, 0, 0, 0xa0, 0xc0};
    char *values[] = {(char *)a, (char *)b};
    unsigned long lengths[] = {8, 8};
    args.arg_count = 2;
    args.arg_type = types;
    args.args = values;
    args.lengths = lengths;
    if (!strcmp(argv[2], "zero")) {
        memset(a, 0, sizeof a);
        memset(b, 0, sizeof b);
    } else if (!strcmp(argv[2], "nan")) {
        a[0] = 0;
        a[1] = 0;
        a[2] = 0xc0;
        a[3] = 0x7f;
    } else if (!strcmp(argv[2], "unequal")) {
        lengths[1] = 4;
    } else if (!strcmp(argv[2], "truncated")) {
        lengths[0] = lengths[1] = 3;
    } else if (!strcmp(argv[2], "null")) {
        values[0] = NULL;
    } else if (strcmp(argv[2], "signed"))
        return 2;
    char message[256] = {0};
    unsigned char is_null = 0, error = 0;
    if (init(&state, &args, message)) {
        fprintf(stderr, "initialization failed\n");
        return 1;
    }
    double out = run(&state, &args, &is_null, &error);
    printf("historical_case=%s result=%.17g null=%u error=%u decimals=%u\n", argv[2], out, is_null,
           error, state.decimals);
    end(&state);
    dlclose(lib);
    return 0;
}

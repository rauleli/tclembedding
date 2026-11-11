/* Independent batch ONNX experiment. Synthetic IDs on stdin: one row per line,
 * semicolon-separated sequences, each sequence space-separated. */
#include <onnxruntime_c_api.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

static const OrtApi *api;
static void check(OrtStatus *s) {
    if (s) {
        fprintf(stderr, "%s\n", api->GetErrorMessage(s));
        api->ReleaseStatus(s);
        exit(1);
    }
}
int main(int argc, char **argv) {
    if (argc != 6) {
        fprintf(stderr, "usage: client model pad dimension mean|cls input_count\n");
        return 2;
    }
    int64_t pad = strtoll(argv[2], NULL, 10);
    int dim = atoi(argv[3]), cls = strcmp(argv[4], "cls") == 0, ninputs = atoi(argv[5]);
    if (pad < 0 || dim <= 0 || dim > 8192 || (strcmp(argv[4], "mean") && !cls) ||
        (ninputs != 2 && ninputs != 3))
        return 2;
    api = OrtGetApiBase()->GetApi(ORT_API_VERSION);
    if (!api)
        return 1;
    OrtEnv *env = NULL;
    OrtSessionOptions *opt = NULL;
    OrtSession *session = NULL;
    OrtMemoryInfo *memory = NULL;
    check(api->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "batch-reference", &env));
    check(api->CreateSessionOptions(&opt));
    check(api->SetIntraOpNumThreads(opt, 1));
    check(api->SetSessionExecutionMode(opt, ORT_SEQUENTIAL));
    check(api->CreateSession(env, argv[1], opt, &session));
    check(api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &memory));
    char line[131072];
    while (fgets(line, sizeof(line), stdin)) {
        int64_t tokens[32][2048];
        int sizes[32] = {0}, batch = 0, maxlen = 0;
        char *save1 = NULL, *sequence = strtok_r(line, ";\r\n", &save1);
        while (sequence) {
            if (batch == 32)
                return 2;
            char *save2 = NULL, *p = strtok_r(sequence, " \t", &save2);
            while (p) {
                if (sizes[batch] == 2048)
                    return 2;
                tokens[batch][sizes[batch]++] = strtoll(p, NULL, 10);
                p = strtok_r(NULL, " \t", &save2);
            }
            if (!sizes[batch])
                return 2;
            if (sizes[batch] > maxlen)
                maxlen = sizes[batch];
            batch++;
            sequence = strtok_r(NULL, ";\r\n", &save1);
        }
        if (!batch)
            return 2;
        size_t count = (size_t)batch * (size_t)maxlen;
        int64_t *ids = calloc(count, sizeof(*ids)), *mask = calloc(count, sizeof(*mask)),
                *types = calloc(count, sizeof(*types));
        if (!ids || !mask || !types)
            return 1;
        for (int b = 0; b < batch; b++)
            for (int t = 0; t < maxlen; t++) {
                size_t j = (size_t)b * maxlen + t;
                ids[j] = t < sizes[b] ? tokens[b][t] : pad;
                mask[j] = t < sizes[b];
            }
        int64_t dims[2] = {batch, maxlen};
        OrtValue *v[3] = {NULL, NULL, NULL}, *out = NULL;
        check(api->CreateTensorWithDataAsOrtValue(memory, ids, count * sizeof(*ids), dims, 2,
                                                  ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &v[0]));
        check(api->CreateTensorWithDataAsOrtValue(memory, mask, count * sizeof(*mask), dims, 2,
                                                  ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &v[1]));
        if (ninputs == 3)
            check(api->CreateTensorWithDataAsOrtValue(memory, types, count * sizeof(*types), dims,
                                                      2, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64,
                                                      &v[2]));
        const char *names[] = {"input_ids", "attention_mask", "token_type_ids"},
                   *outputs[] = {"last_hidden_state"};
        check(
            api->Run(session, NULL, names, (const OrtValue *const *)v, ninputs, outputs, 1, &out));
        OrtTensorTypeAndShapeInfo *shape = NULL;
        size_t rank, elements;
        int64_t d[3];
        ONNXTensorElementDataType typ;
        check(api->GetTensorTypeAndShape(out, &shape));
        check(api->GetDimensionsCount(shape, &rank));
        if (rank != 3)
            return 1;
        check(api->GetDimensions(shape, d, 3));
        check(api->GetTensorElementType(shape, &typ));
        check(api->GetTensorShapeElementCount(shape, &elements));
        if (d[0] != batch || d[1] != maxlen || d[2] != dim ||
            typ != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT || elements != count * (size_t)dim)
            return 1;
        float *data = NULL;
        check(api->GetTensorMutableData(out, (void **)&data));
        double *vec = calloc((size_t)dim, sizeof(*vec));
        if (!vec)
            return 1;
        for (int b = 0; b < batch; b++) {
            memset(vec, 0, (size_t)dim * sizeof(*vec));
            for (int t = 0; t < sizes[b] && (!cls || t == 0); t++)
                for (int i = 0; i < dim; i++)
                    vec[i] += data[((size_t)b * maxlen + t) * (size_t)dim + i];
            double norm = 0;
            for (int i = 0; i < dim; i++) {
                vec[i] /= cls ? 1 : sizes[b];
                norm += vec[i] * vec[i];
            }
            norm = sqrt(norm);
            if (!isfinite(norm) || norm == 0)
                return 1;
            if (norm < 1e-9)
                norm = 1e-9;
            for (int i = 0; i < dim; i++)
                printf("%s%.17g", i ? "," : "", vec[i] / norm);
            putchar('\n');
        }
        putchar('\n');
        free(vec);
        api->ReleaseTensorTypeAndShapeInfo(shape);
        api->ReleaseValue(out);
        for (int i = 0; i < ninputs; i++)
            api->ReleaseValue(v[i]);
        free(ids);
        free(mask);
        free(types);
    }
    api->ReleaseMemoryInfo(memory);
    api->ReleaseSession(session);
    api->ReleaseSessionOptions(opt);
    api->ReleaseEnv(env);
    return 0;
}

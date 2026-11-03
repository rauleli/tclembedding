/* Laboratory-only ONNX reference: input IDs on stdin, one space-separated case per line. */
#include <onnxruntime_c_api.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

static const OrtApi *api;
static void check(OrtStatus *s) {
    if (s) { fprintf(stderr, "%s\n", api->GetErrorMessage(s)); api->ReleaseStatus(s); exit(1); }
}
static void signature(OrtSession *session, int output) {
    size_t count;
    OrtAllocator *allocator;
    check(api->GetAllocatorWithDefaultOptions(&allocator));
    check(output ? api->SessionGetOutputCount(session, &count) : api->SessionGetInputCount(session, &count));
    for (size_t i = 0; i < count; i++) {
        char *name = NULL;
        OrtTypeInfo *type = NULL;
        const OrtTensorTypeAndShapeInfo *shape = NULL;
        ONNXTensorElementDataType element;
        size_t nd;
        int64_t dims[8];
        check(output ? api->SessionGetOutputName(session, i, allocator, &name) : api->SessionGetInputName(session, i, allocator, &name));
        check(output ? api->SessionGetOutputTypeInfo(session, i, &type) : api->SessionGetInputTypeInfo(session, i, &type));
        check(api->CastTypeInfoToTensorInfo(type, &shape));
        check(api->GetTensorElementType(shape, &element));
        check(api->GetDimensionsCount(shape, &nd));
        if (nd > 8) { fprintf(stderr, "too many dimensions\n"); exit(1); }
        check(api->GetDimensions(shape, dims, nd));
        fprintf(stderr, "%s %s type=%d shape=", output ? "output" : "input", name, element);
        for (size_t j = 0; j < nd; j++) fprintf(stderr, "%s%lld", j ? "," : "", (long long)dims[j]);
        fputc('\n', stderr);
        check(api->AllocatorFree(allocator, name));
        api->ReleaseTypeInfo(type);
    }
}
int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "usage: onnx_reference model.onnx\n"); return 2; }
    api = OrtGetApiBase()->GetApi(ORT_API_VERSION);
    if (!api) return 1;
    OrtEnv *env = NULL; OrtSessionOptions *options = NULL; OrtSession *session = NULL; OrtMemoryInfo *memory = NULL;
    check(api->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "reference", &env));
    check(api->CreateSessionOptions(&options));
    check(api->SetIntraOpNumThreads(options, 1));
    check(api->SetSessionExecutionMode(options, ORT_SEQUENTIAL));
    check(api->CreateSession(env, argv[1], options, &session));
    signature(session, 0); signature(session, 1);
    check(api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &memory));
    char line[65536];
    while (fgets(line, sizeof(line), stdin)) {
        int64_t ids[1024], mask[1024], types[1024]; size_t n = 0;
        char *p = strtok(line, " \t\r\n");
        while (p) { if (n == 1024) return 2; ids[n] = strtoll(p, NULL, 10); mask[n] = 1; types[n++] = 0; p = strtok(NULL, " \t\r\n"); }
        if (!n) return 2;
        int64_t dims[] = {1, (int64_t)n};
        OrtValue *v[3] = {NULL, NULL, NULL}, *out = NULL;
        check(api->CreateTensorWithDataAsOrtValue(memory, ids, n*sizeof(*ids), dims, 2, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &v[0]));
        check(api->CreateTensorWithDataAsOrtValue(memory, mask, n*sizeof(*mask), dims, 2, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &v[1]));
        check(api->CreateTensorWithDataAsOrtValue(memory, types, n*sizeof(*types), dims, 2, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &v[2]));
        const char *names[] = {"input_ids", "attention_mask", "token_type_ids"}, *outs[] = {"last_hidden_state"};
        check(api->Run(session, NULL, names, (const OrtValue *const *)v, 3, outs, 1, &out));
        OrtTensorTypeAndShapeInfo *shape = NULL; size_t nd; int64_t actual[3]; ONNXTensorElementDataType element;
        check(api->GetTensorTypeAndShape(out, &shape)); check(api->GetDimensionsCount(shape, &nd));
        if (nd != 3) { fprintf(stderr, "unexpected output rank\n"); return 1; }
        check(api->GetDimensions(shape, actual, 3)); check(api->GetTensorElementType(shape, &element));
        api->ReleaseTensorTypeAndShapeInfo(shape);
        if (actual[0] != 1 || actual[1] != (int64_t)n || actual[2] != 384 || element != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT) { fprintf(stderr, "unexpected output shape/type\n"); return 1; }
        float *data; check(api->GetTensorMutableData(out, (void **)&data));
        double mean[384] = {0}, norm = 0;
        for (size_t t = 0; t < n; t++) for (size_t d = 0; d < 384; d++) mean[d] += data[t*384+d];
        for (size_t d = 0; d < 384; d++) { mean[d] /= n; norm += mean[d]*mean[d]; }
        norm = sqrt(norm);
        printf("%.17g", norm);
        for (size_t d = 0; d < 384; d++) printf(" %.17g", mean[d]);
        for (size_t d = 0; d < 384; d++) printf(" %.17g", mean[d] / (norm < 1e-9 ? 1e-9 : norm));
        putchar('\n'); fflush(stdout);
        api->ReleaseValue(out); for (size_t i = 0; i < 3; i++) api->ReleaseValue(v[i]);
    }
    api->ReleaseMemoryInfo(memory); api->ReleaseSession(session); api->ReleaseSessionOptions(options); api->ReleaseEnv(env);
    return 0;
}

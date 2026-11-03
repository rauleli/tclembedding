/*
 * tclembedding.c - Versión Final "Zero Warnings"
 * - Mean Pooling
 * - L2 Normalization
 * - Verificación exhaustiva de TODOS los retornos de ONNX
 */

#ifdef __cplusplus
extern "C" {
#endif

#include <tcl.h>
#include <tclTomMathDecls.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <limits.h>
#include <stdatomic.h>
#include <string.h>
#include "onnxruntime_c_api.h"

// Estructura de estado
typedef struct {
    OrtSession* session;
    OrtSessionOptions* options;
    OrtEnv* env;
    int has_type_ids;
    int64_t fixed_sequence;
    Tcl_Interp *interp;
    Tcl_Command command;
} EmbeddingState;

static const OrtApi* g_ort = NULL;
static atomic_ullong next_handle = 1;

static void EmbeddingStateDelete(ClientData data) {
    EmbeddingState *state = (EmbeddingState *)data;
    if (state->session) g_ort->ReleaseSession(state->session);
    if (state->options) g_ort->ReleaseSessionOptions(state->options);
    if (state->env) g_ort->ReleaseEnv(state->env);
    ckfree((char *)state);
}

static int EmbeddingHandleCmd(ClientData data, Tcl_Interp *interp, int objc,
                              Tcl_Obj *const objv[]) {
    (void)data; (void)objc; (void)objv;
    Tcl_SetObjResult(interp, Tcl_NewStringObj("embedding handle is not directly callable", -1));
    return TCL_ERROR;
}

static EmbeddingState *GetEmbeddingState(Tcl_Interp *interp, Tcl_Obj *name) {
    Tcl_Command command = Tcl_GetCommandFromObj(interp, name);
    Tcl_CmdInfo info;
    if (command && Tcl_GetCommandInfoFromToken(command, &info) &&
        info.objProc == EmbeddingHandleCmd && info.deleteProc == EmbeddingStateDelete) {
        EmbeddingState *state = (EmbeddingState *)info.objClientData;
        if (state && state->interp == interp && state->command == command) return state;
    }
    Tcl_SetObjResult(interp, Tcl_NewStringObj("invalid embedding handle", -1));
    return NULL;
}

#define CHECK_STATUS_INIT(expr) do { \
    OrtStatus* status = (expr); \
    if (status != NULL) { \
        const char* msg = g_ort->GetErrorMessage(status); \
        Tcl_SetObjResult(interp, Tcl_NewStringObj(msg, -1)); \
        g_ort->ReleaseStatus(status); \
        EmbeddingStateDelete(state); \
        return TCL_ERROR; \
    } \
} while(0)

/* Validate the encoder inputs once, before publishing a Tcl handle. */
static int ValidateInputs(Tcl_Interp *interp, EmbeddingState *state) {
    OrtStatus *st = NULL;
    OrtAllocator *allocator = NULL;
    OrtTypeInfo *type = NULL;
    char *name = NULL;
    size_t count = 0;
    int seen = 0, result = TCL_ERROR;
    int64_t fixed = 0;
#define INPUT_CALL(expr) do { st = (expr); if (st) { \
    Tcl_SetObjResult(interp, Tcl_NewStringObj(g_ort->GetErrorMessage(st), -1)); \
    g_ort->ReleaseStatus(st); goto done; } } while (0)
    INPUT_CALL(g_ort->GetAllocatorWithDefaultOptions(&allocator));
    INPUT_CALL(g_ort->SessionGetInputCount(state->session, &count));
    if (count != 2 && count != 3) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj("ONNX model must have two or three supported inputs", -1)); goto done;
    }
    for (size_t i = 0; i < count; i++) {
        const OrtTensorTypeAndShapeInfo *shape = NULL;
        ONNXType kind;
        ONNXTensorElementDataType element;
        size_t rank = 0;
        int64_t dims[2];
        int bit;
        INPUT_CALL(g_ort->SessionGetInputName(state->session, i, allocator, &name));
        if (!name) { Tcl_SetObjResult(interp, Tcl_NewStringObj("ONNX input has no name", -1)); goto done; }
        if (strcmp(name, "input_ids") == 0) bit = 1;
        else if (strcmp(name, "attention_mask") == 0) bit = 2;
        else if (strcmp(name, "token_type_ids") == 0) bit = 4;
        else { Tcl_SetObjResult(interp, Tcl_ObjPrintf("unsupported ONNX input: %s", name)); goto done; }
        if (seen & bit) { Tcl_SetObjResult(interp, Tcl_NewStringObj("duplicate ONNX input", -1)); goto done; }
        seen |= bit;
        INPUT_CALL(g_ort->SessionGetInputTypeInfo(state->session, i, &type));
        INPUT_CALL(g_ort->GetOnnxTypeFromTypeInfo(type, &kind));
        if (kind != ONNX_TYPE_TENSOR) { Tcl_SetObjResult(interp, Tcl_NewStringObj("ONNX input must be a tensor", -1)); goto done; }
        INPUT_CALL(g_ort->CastTypeInfoToTensorInfo(type, &shape));
        if (!shape) { Tcl_SetObjResult(interp, Tcl_NewStringObj("ONNX input tensor metadata unavailable", -1)); goto done; }
        INPUT_CALL(g_ort->GetTensorElementType(shape, &element));
        INPUT_CALL(g_ort->GetDimensionsCount(shape, &rank));
        if (element != ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64 || rank != 2) {
            Tcl_SetObjResult(interp, Tcl_NewStringObj("ONNX inputs must be rank-2 int64 tensors", -1)); goto done;
        }
        INPUT_CALL(g_ort->GetDimensions(shape, dims, 2));
        if ((dims[0] != 1 && dims[0] != -1) || dims[1] == 0 || dims[1] < -1 ||
            (dims[1] > 0 && fixed && fixed != dims[1])) {
            Tcl_SetObjResult(interp, Tcl_NewStringObj("incompatible ONNX input shape", -1)); goto done;
        }
        if (dims[1] > 0) fixed = dims[1];
        g_ort->ReleaseTypeInfo(type); type = NULL;
        allocator->Free(allocator, name); name = NULL;
    }
    if ((seen & 3) != 3) { Tcl_SetObjResult(interp, Tcl_NewStringObj("ONNX model is missing required inputs", -1)); goto done; }
    state->has_type_ids = (seen & 4) != 0;
    state->fixed_sequence = fixed;
    result = TCL_OK;
done:
    if (type) g_ort->ReleaseTypeInfo(type);
    if (name && allocator) allocator->Free(allocator, name);
#undef INPUT_CALL
    return result;
}

// --- INIT ---
static int TclEmbedding_Init_Cmd(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    (void)cd;
    if (objc != 2) {
        Tcl_WrongNumArgs(interp, 1, objv, "model_path");
        return TCL_ERROR;
    }
    if (g_ort == NULL) g_ort = OrtGetApiBase()->GetApi(ORT_API_VERSION);
    if (g_ort == NULL) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj("ONNX Runtime API version unavailable", -1));
        return TCL_ERROR;
    }

    const char *model_path = Tcl_GetString(objv[1]);
    EmbeddingState *state = (EmbeddingState *) ckalloc(sizeof(EmbeddingState));
    *state = (EmbeddingState){0};
    state->interp = interp;
    
    // Inicialización paso a paso
    CHECK_STATUS_INIT(g_ort->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "tclembedding", &state->env));
    CHECK_STATUS_INIT(g_ort->CreateSessionOptions(&state->options));
    CHECK_STATUS_INIT(g_ort->SetIntraOpNumThreads(state->options, 1));
    CHECK_STATUS_INIT(g_ort->SetSessionExecutionMode(state->options, ORT_SEQUENTIAL));

    CHECK_STATUS_INIT(g_ort->CreateSession(state->env, model_path, state->options, &state->session));

    if (ValidateInputs(interp, state) != TCL_OK) {
        EmbeddingStateDelete(state);
        return TCL_ERROR;
    }

    char handle[64];
    do {
        unsigned long long id = atomic_load(&next_handle);
        do {
            if (id == ULLONG_MAX) {
                Tcl_SetObjResult(interp, Tcl_NewStringObj("embedding handle IDs exhausted", -1));
                EmbeddingStateDelete(state);
                return TCL_ERROR;
            }
        } while (!atomic_compare_exchange_weak(&next_handle, &id, id + 1));
        snprintf(handle, sizeof(handle), "::embedding%llu", id);
    } while (Tcl_FindCommand(interp, handle, NULL, TCL_GLOBAL_ONLY) != NULL);
    state->command = Tcl_CreateObjCommand(interp, handle, EmbeddingHandleCmd, state, EmbeddingStateDelete);
    if (!state->command) {
        EmbeddingStateDelete(state);
        return TCL_ERROR;
    }
    Tcl_SetObjResult(interp, Tcl_NewStringObj(handle, -1));
    return TCL_OK;
}

// --- COMPUTE ---
static int TclEmbedding_Compute_Cmd(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    (void)cd;
    if (objc != 3 && objc != 5) {
        Tcl_WrongNumArgs(interp, 1, objv, "handle token_id_list ?-pooling mean|cls?");
        return TCL_ERROR;
    }

    EmbeddingState *state = GetEmbeddingState(interp, objv[1]);
    if (!state) return TCL_ERROR;
    int cls = 0;
    if (objc == 5) {
        const char *option = Tcl_GetString(objv[3]);
        const char *pooling = Tcl_GetString(objv[4]);
        if (strcmp(option, "-pooling") != 0 || (strcmp(pooling, "mean") != 0 && strcmp(pooling, "cls") != 0)) {
            Tcl_SetObjResult(interp, Tcl_NewStringObj("expected -pooling mean or cls", -1));
            return TCL_ERROR;
        }
        cls = strcmp(pooling, "cls") == 0;
    }

    // 1. TCL List -> C Array
    int token_count;
    Tcl_Obj **obj_tokens;
    if (Tcl_ListObjGetElements(interp, objv[2], &token_count, &obj_tokens) != TCL_OK) return TCL_ERROR;

    if (token_count == 0) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj("token ID list must not be empty", -1));
        return TCL_ERROR;
    }

    if (state->fixed_sequence && state->fixed_sequence != token_count) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj("token count does not match fixed ONNX input sequence", -1));
        return TCL_ERROR;
    }
    size_t count = (size_t)token_count;
    if (count > SIZE_MAX / sizeof(int64_t) ||
        count > UINT_MAX / sizeof(int64_t)) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj("token ID list is too large", -1));
        return TCL_ERROR;
    }
    size_t input_bytes = count * sizeof(int64_t);
    int64_t* input_ids = (int64_t*)ckalloc((unsigned int)input_bytes);
    int64_t* attention = (int64_t*)ckalloc((unsigned int)input_bytes);
    int64_t* type_ids  = (int64_t*)ckalloc((unsigned int)input_bytes);

    for (int i = 0; i < token_count; i++) {
        mp_int exact;
        if (Tcl_GetBignumFromObj(interp, obj_tokens[i], &exact) != TCL_OK) {
            ckfree((char*)input_ids); ckfree((char*)attention); ckfree((char*)type_ids);
            return TCL_ERROR;
        }
        int invalid = mp_isneg(&exact) || mp_count_bits(&exact) > 63;
        mp_clear(&exact);
        if (invalid) {
            Tcl_SetObjResult(interp, Tcl_NewStringObj("token IDs must be nonnegative signed 64-bit integers", -1));
            ckfree((char*)input_ids); ckfree((char*)attention); ckfree((char*)type_ids);
            return TCL_ERROR;
        }
        Tcl_WideInt val;
        if (Tcl_GetWideIntFromObj(interp, obj_tokens[i], &val) != TCL_OK) {
            ckfree((char*)input_ids); ckfree((char*)attention); ckfree((char*)type_ids);
            return TCL_ERROR;
        }
        if (val < 0 || val > (Tcl_WideInt)INT64_MAX) {
            Tcl_SetObjResult(interp, Tcl_NewStringObj("token IDs must be nonnegative signed 64-bit integers", -1));
            ckfree((char*)input_ids); ckfree((char*)attention); ckfree((char*)type_ids);
            return TCL_ERROR;
        }
        input_ids[i] = (int64_t)val;
        attention[i] = 1; 
        type_ids[i] = 0;
    }

    // Variables para ONNX y limpieza
    OrtMemoryInfo* memory_info = NULL;
    OrtStatus* st = NULL;
    OrtValue *t1 = NULL, *t2 = NULL, *t3 = NULL, *t_out = NULL;
    OrtTensorTypeAndShapeInfo *output_shape = NULL;
    double* sum_vec = NULL;
    int result = TCL_OK;

    // 2. Preparar Memoria y Tensores
    st = g_ort->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &memory_info);
    if (st) { Tcl_SetObjResult(interp, Tcl_NewStringObj(g_ort->GetErrorMessage(st), -1)); g_ort->ReleaseStatus(st); result = TCL_ERROR; goto cleanup; }
    
    int64_t input_shape[] = {1, token_count};
    
    st = g_ort->CreateTensorWithDataAsOrtValue(memory_info, input_ids, input_bytes, input_shape, 2, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &t1);
    if (st) { Tcl_SetObjResult(interp, Tcl_NewStringObj(g_ort->GetErrorMessage(st), -1)); g_ort->ReleaseStatus(st); result = TCL_ERROR; goto cleanup; }

    st = g_ort->CreateTensorWithDataAsOrtValue(memory_info, attention, input_bytes, input_shape, 2, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &t2);
    if (st) { Tcl_SetObjResult(interp, Tcl_NewStringObj(g_ort->GetErrorMessage(st), -1)); g_ort->ReleaseStatus(st); result = TCL_ERROR; goto cleanup; }

    if (state->has_type_ids) {
        st = g_ort->CreateTensorWithDataAsOrtValue(memory_info, type_ids, input_bytes, input_shape, 2, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &t3);
        if (st) { Tcl_SetObjResult(interp, Tcl_NewStringObj(g_ort->GetErrorMessage(st), -1)); g_ort->ReleaseStatus(st); result = TCL_ERROR; goto cleanup; }
    }

    const char* input_names[] = {"input_ids", "attention_mask", "token_type_ids"};
    const char* output_names[] = {"last_hidden_state"};
    const OrtValue* inputs[] = {t1, t2, t3};

    // 3. Ejecutar Inferencia
    st = g_ort->Run(state->session, NULL, input_names, inputs, state->has_type_ids ? 3 : 2, output_names, 1, &t_out);
    if (st) {
        const char* msg = g_ort->GetErrorMessage(st);
        Tcl_SetObjResult(interp, Tcl_NewStringObj(msg, -1));
        g_ort->ReleaseStatus(st);
        result = TCL_ERROR;
        goto cleanup;
    }

    // Validate the output before interpreting its memory.
    if (!t_out) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj("ONNX returned no output", -1));
        result = TCL_ERROR; goto cleanup;
    }
    int is_tensor = 0;
    st = g_ort->IsTensor(t_out, &is_tensor);
    if (st) { Tcl_SetObjResult(interp, Tcl_NewStringObj(g_ort->GetErrorMessage(st), -1)); g_ort->ReleaseStatus(st); result = TCL_ERROR; goto cleanup; }
    if (!is_tensor) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj("ONNX output is not a tensor", -1));
        result = TCL_ERROR; goto cleanup;
    }
    st = g_ort->GetTensorTypeAndShape(t_out, &output_shape);
    if (st) { Tcl_SetObjResult(interp, Tcl_NewStringObj(g_ort->GetErrorMessage(st), -1)); g_ort->ReleaseStatus(st); result = TCL_ERROR; goto cleanup; }
    ONNXTensorElementDataType element_type;
    size_t rank = 0, elements = 0;
    int64_t dimensions[3];
    st = g_ort->GetTensorElementType(output_shape, &element_type);
    if (st) { Tcl_SetObjResult(interp, Tcl_NewStringObj(g_ort->GetErrorMessage(st), -1)); g_ort->ReleaseStatus(st); result = TCL_ERROR; goto cleanup; }
    if (element_type != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj("ONNX output tensor must have float32 elements", -1));
        result = TCL_ERROR; goto cleanup;
    }
    st = g_ort->GetDimensionsCount(output_shape, &rank);
    if (st) { Tcl_SetObjResult(interp, Tcl_NewStringObj(g_ort->GetErrorMessage(st), -1)); g_ort->ReleaseStatus(st); result = TCL_ERROR; goto cleanup; }
    if (rank != 3) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj("ONNX output tensor must have rank 3", -1));
        result = TCL_ERROR; goto cleanup;
    }
    st = g_ort->GetDimensions(output_shape, dimensions, 3);
    if (st) { Tcl_SetObjResult(interp, Tcl_NewStringObj(g_ort->GetErrorMessage(st), -1)); g_ort->ReleaseStatus(st); result = TCL_ERROR; goto cleanup; }
    if (dimensions[0] != 1 || dimensions[1] != (int64_t)token_count || dimensions[2] <= 0 || dimensions[2] > INT_MAX ||
        (uint64_t)dimensions[2] > SIZE_MAX / sizeof(double) ||
        (uint64_t)dimensions[2] > SIZE_MAX / count ||
        count * (size_t)dimensions[2] > SIZE_MAX / sizeof(float)) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj("ONNX output tensor must have a safe shape [1, token_count, hidden_dimension]", -1));
        result = TCL_ERROR; goto cleanup;
    }
    st = g_ort->GetTensorShapeElementCount(output_shape, &elements);
    if (st) { Tcl_SetObjResult(interp, Tcl_NewStringObj(g_ort->GetErrorMessage(st), -1)); g_ort->ReleaseStatus(st); result = TCL_ERROR; goto cleanup; }
    size_t embedding_dim = (size_t)dimensions[2];
    if (elements != count * embedding_dim) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj("ONNX output tensor element count is inconsistent", -1));
        result = TCL_ERROR; goto cleanup;
    }

    // 4. Mean Pooling + L2 Normalization
    float* floats;
    // --- EL FIX DEL WARNING ESTÁ AQUÍ ---
    st = g_ort->GetTensorMutableData(t_out, (void**)&floats);
    if (st) {
        const char* msg = g_ort->GetErrorMessage(st);
        Tcl_SetObjResult(interp, Tcl_NewStringObj(msg, -1));
        g_ort->ReleaseStatus(st);
        result = TCL_ERROR;
        goto cleanup;
    }
    if (!floats) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj("ONNX output tensor has no data", -1));
        result = TCL_ERROR; goto cleanup;
    }
    // ------------------------------------
    
    sum_vec = (double*)calloc(embedding_dim, sizeof(double));
    if (!sum_vec) { Tcl_SetObjResult(interp, Tcl_NewStringObj("unable to allocate embedding", -1)); result = TCL_ERROR; goto cleanup; }

    // A. Sumar
    for (int t = 0; t < (cls ? 1 : token_count); t++) {
        for (size_t i = 0; i < embedding_dim; i++) {
            sum_vec[i] += floats[(size_t)t * embedding_dim + i];
        }
    }
    
    // B. Promediar y Calcular Norma
    double norm = 0.0;
    for (size_t i = 0; i < embedding_dim; i++) {
        sum_vec[i] /= cls ? 1 : token_count;
        if (!isfinite(sum_vec[i])) {
            Tcl_SetObjResult(interp, Tcl_NewStringObj("ONNX output produced non-finite mean values", -1));
            result = TCL_ERROR; goto cleanup;
        }
        norm += sum_vec[i] * sum_vec[i];
    }
    norm = sqrt(norm);
    if (!isfinite(norm) || norm == 0.0) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj("embedding norm is zero or non-finite", -1));
        result = TCL_ERROR; goto cleanup;
    }
    if (norm < 1e-9) norm = 1e-9;

    // C. Generar lista TCL normalizada
    Tcl_Obj *result_list = Tcl_NewListObj(0, NULL);
    for (size_t i = 0; i < embedding_dim; i++) {
        Tcl_ListObjAppendElement(interp, result_list, Tcl_NewDoubleObj(sum_vec[i] / norm));
    }
    Tcl_SetObjResult(interp, result_list);

cleanup:
    if (output_shape) g_ort->ReleaseTensorTypeAndShapeInfo(output_shape);
    if (sum_vec) free(sum_vec);
    if (t1) g_ort->ReleaseValue(t1);
    if (t2) g_ort->ReleaseValue(t2);
    if (t3) g_ort->ReleaseValue(t3);
    if (t_out) g_ort->ReleaseValue(t_out);
    if (memory_info) g_ort->ReleaseMemoryInfo(memory_info);

    ckfree((char*)input_ids);
    ckfree((char*)attention);
    ckfree((char*)type_ids);

    return result;
}

static int TclEmbedding_Free_Cmd(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    (void)cd;
    if (objc != 2) {
        Tcl_WrongNumArgs(interp, 1, objv, "handle");
        return TCL_ERROR;
    }
    EmbeddingState *state = GetEmbeddingState(interp, objv[1]);
    if (!state) return TCL_ERROR;
    if (Tcl_DeleteCommandFromToken(interp, state->command) != 0) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj("could not delete embedding handle", -1));
        return TCL_ERROR;
    }
    return TCL_OK;
}

int Tclembedding_Init(Tcl_Interp *interp) {
    if (Tcl_InitStubs(interp, "8.6", 0) == NULL) return TCL_ERROR;
    Tcl_CreateObjCommand(interp, "embedding::init_raw", TclEmbedding_Init_Cmd, NULL, NULL);
    Tcl_CreateObjCommand(interp, "embedding::compute", TclEmbedding_Compute_Cmd, NULL, NULL);
    Tcl_CreateObjCommand(interp, "embedding::free", TclEmbedding_Free_Cmd, NULL, NULL);
    return Tcl_PkgProvide(interp, "tclembedding", "1.0");
}

#ifdef __cplusplus
}
#endif

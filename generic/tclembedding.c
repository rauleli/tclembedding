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
#include <sys/stat.h>
#include "onnxruntime_c_api.h"

// Estructura de estado
typedef struct {
    OrtSession *session;
    OrtSessionOptions *options;
    OrtEnv *env;
    int profiling;
    int has_type_ids;
    int64_t fixed_sequence;
    int64_t fixed_batch;
    Tcl_Interp *interp;
    Tcl_Command command;
} EmbeddingState;

static const OrtApi *g_ort = NULL;
static atomic_ullong next_handle = 1;

/* Finish a requested profile once. The caller owns the returned status. */
static OrtStatus *EmbeddingEndProfile(EmbeddingState *state) {
    OrtAllocator *allocator = NULL;
    char *path = NULL;
    OrtStatus *status;
    if (!state->session || !state->profiling)
        return NULL;
    state->profiling = 0;
    status = g_ort->GetAllocatorWithDefaultOptions(&allocator);
    if (!status)
        status = g_ort->SessionEndProfiling(state->session, allocator, &path);
    if (!status && !path)
        status = g_ort->CreateStatus(ORT_FAIL, "profile output filename was not returned");
    if (!status && path) {
        Tcl_Obj *result_path = Tcl_NewStringObj(path, -1);
        Tcl_IncrRefCount(result_path);
        if (Tcl_FSAccess(result_path, 0) != 0)
            status = g_ort->CreateStatus(ORT_FAIL, "profile output file was not created");
        Tcl_DecrRefCount(result_path);
    }
    if (path && allocator)
        allocator->Free(allocator, path);
    return status;
}

static void EmbeddingStateDelete(ClientData data) {
    EmbeddingState *state = (EmbeddingState *)data;
    OrtStatus *status = EmbeddingEndProfile(state);
    if (status)
        g_ort->ReleaseStatus(status);
    if (state->session)
        g_ort->ReleaseSession(state->session);
    if (state->options)
        g_ort->ReleaseSessionOptions(state->options);
    if (state->env)
        g_ort->ReleaseEnv(state->env);
    ckfree((char *)state);
}

static int EmbeddingHandleCmd(ClientData data, Tcl_Interp *interp, int objc,
                              Tcl_Obj *const objv[]) {
    (void)data;
    (void)objc;
    (void)objv;
    Tcl_SetObjResult(interp, Tcl_NewStringObj("embedding handle is not directly callable", -1));
    return TCL_ERROR;
}

static EmbeddingState *GetEmbeddingState(Tcl_Interp *interp, Tcl_Obj *name) {
    Tcl_Command command = Tcl_GetCommandFromObj(interp, name);
    Tcl_CmdInfo info;
    if (command && Tcl_GetCommandInfoFromToken(command, &info) &&
        info.objProc == EmbeddingHandleCmd && info.deleteProc == EmbeddingStateDelete) {
        EmbeddingState *state = (EmbeddingState *)info.objClientData;
        if (state && state->interp == interp && state->command == command)
            return state;
    }
    Tcl_SetObjResult(interp, Tcl_NewStringObj("invalid embedding handle", -1));
    return NULL;
}

#define CHECK_STATUS_INIT(expr)                                                                    \
    do {                                                                                           \
        OrtStatus *status = (expr);                                                                \
        if (status != NULL) {                                                                      \
            const char *msg = g_ort->GetErrorMessage(status);                                      \
            Tcl_SetObjResult(interp, Tcl_NewStringObj(msg, -1));                                   \
            g_ort->ReleaseStatus(status);                                                          \
            EmbeddingStateDelete(state);                                                           \
            return TCL_ERROR;                                                                      \
        }                                                                                          \
    } while (0)

/* Validate the encoder inputs once, before publishing a Tcl handle. */
static int ValidateInputs(Tcl_Interp *interp, EmbeddingState *state) {
    OrtStatus *st = NULL;
    OrtAllocator *allocator = NULL;
    OrtTypeInfo *type = NULL;
    char *name = NULL;
    size_t count = 0;
    int seen = 0, result = TCL_ERROR;
    int64_t fixed = 0, fixed_batch = 0;
#define INPUT_CALL(expr)                                                                           \
    do {                                                                                           \
        st = (expr);                                                                               \
        if (st) {                                                                                  \
            Tcl_SetObjResult(interp, Tcl_NewStringObj(g_ort->GetErrorMessage(st), -1));            \
            g_ort->ReleaseStatus(st);                                                              \
            goto done;                                                                             \
        }                                                                                          \
    } while (0)
    INPUT_CALL(g_ort->GetAllocatorWithDefaultOptions(&allocator));
    INPUT_CALL(g_ort->SessionGetInputCount(state->session, &count));
    if (count != 2 && count != 3) {
        Tcl_SetObjResult(
            interp, Tcl_NewStringObj("ONNX model must have two or three supported inputs", -1));
        goto done;
    }
    for (size_t i = 0; i < count; i++) {
        const OrtTensorTypeAndShapeInfo *shape = NULL;
        ONNXType kind;
        ONNXTensorElementDataType element;
        size_t rank = 0;
        int64_t dims[2];
        int bit;
        INPUT_CALL(g_ort->SessionGetInputName(state->session, i, allocator, &name));
        if (!name) {
            Tcl_SetObjResult(interp, Tcl_NewStringObj("ONNX input has no name", -1));
            goto done;
        }
        if (strcmp(name, "input_ids") == 0)
            bit = 1;
        else if (strcmp(name, "attention_mask") == 0)
            bit = 2;
        else if (strcmp(name, "token_type_ids") == 0)
            bit = 4;
        else {
            Tcl_SetObjResult(interp, Tcl_ObjPrintf("unsupported ONNX input: %s", name));
            goto done;
        }
        if (seen & bit) {
            Tcl_SetObjResult(interp, Tcl_NewStringObj("duplicate ONNX input", -1));
            goto done;
        }
        seen |= bit;
        INPUT_CALL(g_ort->SessionGetInputTypeInfo(state->session, i, &type));
        INPUT_CALL(g_ort->GetOnnxTypeFromTypeInfo(type, &kind));
        if (kind != ONNX_TYPE_TENSOR) {
            Tcl_SetObjResult(interp, Tcl_NewStringObj("ONNX input must be a tensor", -1));
            goto done;
        }
        INPUT_CALL(g_ort->CastTypeInfoToTensorInfo(type, &shape));
        if (!shape) {
            Tcl_SetObjResult(interp,
                             Tcl_NewStringObj("ONNX input tensor metadata unavailable", -1));
            goto done;
        }
        INPUT_CALL(g_ort->GetTensorElementType(shape, &element));
        INPUT_CALL(g_ort->GetDimensionsCount(shape, &rank));
        if (element != ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64 || rank != 2) {
            Tcl_SetObjResult(interp,
                             Tcl_NewStringObj("ONNX inputs must be rank-2 int64 tensors", -1));
            goto done;
        }
        INPUT_CALL(g_ort->GetDimensions(shape, dims, 2));
        if ((dims[0] != 1 && dims[0] != -1) || dims[1] == 0 || dims[1] < -1 ||
            (dims[1] > 0 && fixed && fixed != dims[1])) {
            Tcl_SetObjResult(interp, Tcl_NewStringObj("incompatible ONNX input shape", -1));
            goto done;
        }
        if (dims[1] > 0)
            fixed = dims[1];
        if (dims[0] == 1)
            fixed_batch = 1;
        g_ort->ReleaseTypeInfo(type);
        type = NULL;
        allocator->Free(allocator, name);
        name = NULL;
    }
    if ((seen & 3) != 3) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj("ONNX model is missing required inputs", -1));
        goto done;
    }
    state->has_type_ids = (seen & 4) != 0;
    state->fixed_sequence = fixed;
    state->fixed_batch = fixed_batch;
    result = TCL_OK;
done:
    if (type)
        g_ort->ReleaseTypeInfo(type);
    if (name && allocator)
        allocator->Free(allocator, name);
#undef INPUT_CALL
    return result;
}

/* Reject embedded NUL even when Tcl represents it as modified UTF-8. */
static int ContainsNull(Tcl_Obj *value) {
    int count;
    const Tcl_UniChar *chars = Tcl_GetUnicodeFromObj(value, &count);
    for (int i = 0; i < count; i++)
        if (chars[i] == 0)
            return 1;
    return 0;
}

// --- INIT ---
static int TclEmbedding_Init_Cmd(ClientData cd, Tcl_Interp *interp, int objc,
                                 Tcl_Obj *const objv[]) {
    (void)cd;
    int cuda = 0, device = 0, provider_seen = 0, device_seen = 0, profile_seen = 0;
    const char *profile = NULL;
    if (objc < 2 || objc % 2 != 0) {
        Tcl_WrongNumArgs(interp, 1, objv,
                         "model_path ?-provider cpu|cuda? ?-device index? ?-profile prefix?");
        return TCL_ERROR;
    }
    for (int i = 2; i < objc; i += 2) {
        int option_length, length;
        const char *option = Tcl_GetStringFromObj(objv[i], &option_length);
        const char *value = Tcl_GetStringFromObj(objv[i + 1], &length);
        if ((size_t)option_length != strlen(option) || (size_t)length != strlen(value) ||
            ContainsNull(objv[i]) || ContainsNull(objv[i + 1])) {
            Tcl_SetObjResult(interp, Tcl_NewStringObj("option value contains NUL", -1));
            return TCL_ERROR;
        }
        if (!strcmp(option, "-provider") && !provider_seen) {
            provider_seen = 1;
            if (!strcmp(value, "cuda"))
                cuda = 1;
            else if (strcmp(value, "cpu")) {
                Tcl_SetObjResult(interp, Tcl_NewStringObj("provider must be cpu or cuda", -1));
                return TCL_ERROR;
            }
        } else if (!strcmp(option, "-device") && !device_seen) {
            device_seen = 1;
            if (!length) {
                Tcl_SetObjResult(interp, Tcl_NewStringObj("device must be a decimal index", -1));
                return TCL_ERROR;
            }
            for (int j = 0; j < length; j++) {
                if (value[j] < '0' || value[j] > '9' ||
                    device > (INT_MAX - (value[j] - '0')) / 10) {
                    Tcl_SetObjResult(interp, Tcl_NewStringObj("invalid CUDA device index", -1));
                    return TCL_ERROR;
                }
                device = device * 10 + value[j] - '0';
            }
        } else if (!strcmp(option, "-profile") && !profile_seen) {
            profile_seen = 1;
            if (!length || value[length - 1] == '/') {
                Tcl_SetObjResult(interp, Tcl_NewStringObj("invalid profile prefix", -1));
                return TCL_ERROR;
            }
            int components = 0;
            Tcl_Obj *parts = Tcl_FSSplitPath(objv[i + 1], &components);
            Tcl_IncrRefCount(parts);
            Tcl_Obj *parent = components > 1 ? Tcl_FSJoinPath(parts, components - 1)
                                             : Tcl_NewStringObj(".", -1);
            Tcl_IncrRefCount(parent);
            Tcl_StatBuf parent_info;
            int accessible = Tcl_FSStat(parent, &parent_info) == 0 &&
                             S_ISDIR(parent_info.st_mode) && Tcl_FSAccess(parent, 2) == 0;
            Tcl_DecrRefCount(parent);
            Tcl_DecrRefCount(parts);
            if (!accessible) {
                Tcl_SetObjResult(interp, Tcl_NewStringObj("profile directory is not writable", -1));
                return TCL_ERROR;
            }
            profile = value;
        } else {
            Tcl_SetObjResult(interp, Tcl_ObjPrintf("unknown or duplicate option: %s", option));
            return TCL_ERROR;
        }
    }
    if (device_seen && !cuda) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj("-device requires -provider cuda", -1));
        return TCL_ERROR;
    }
    if (g_ort == NULL)
        g_ort = OrtGetApiBase()->GetApi(ORT_API_VERSION);
    if (g_ort == NULL) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj("ONNX Runtime API version unavailable", -1));
        return TCL_ERROR;
    }

    const char *model_path = Tcl_GetString(objv[1]);
    EmbeddingState *state = (EmbeddingState *)ckalloc(sizeof(EmbeddingState));
    *state = (EmbeddingState){0};
    state->interp = interp;

    // Inicialización paso a paso
    CHECK_STATUS_INIT(g_ort->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "tclembedding", &state->env));
    CHECK_STATUS_INIT(g_ort->CreateSessionOptions(&state->options));
    CHECK_STATUS_INIT(g_ort->SetIntraOpNumThreads(state->options, 1));
    CHECK_STATUS_INIT(g_ort->SetSessionExecutionMode(state->options, ORT_SEQUENTIAL));
    if (profile)
        CHECK_STATUS_INIT(g_ort->EnableProfiling(state->options, profile));
    if (cuda) {
        char **providers = NULL;
        int count = 0, found = 0;
        OrtStatus *status = g_ort->GetAvailableProviders(&providers, &count);
        if (!status) {
            for (int i = 0; i < count; i++)
                if (!strcmp(providers[i], "CUDAExecutionProvider"))
                    found = 1;
            status = g_ort->ReleaseAvailableProviders(providers, count);
        }
        if (status) {
            Tcl_SetObjResult(interp, Tcl_ObjPrintf("cannot enumerate providers: %s",
                                                  g_ort->GetErrorMessage(status)));
            g_ort->ReleaseStatus(status);
            EmbeddingStateDelete(state);
            return TCL_ERROR;
        }
        if (!found) {
            Tcl_SetObjResult(interp, Tcl_NewStringObj("CUDAExecutionProvider unavailable", -1));
            EmbeddingStateDelete(state);
            return TCL_ERROR;
        }
        OrtCUDAProviderOptionsV2 *cuda_options = NULL;
        char device_text[32];
        snprintf(device_text, sizeof(device_text), "%d", device);
        const char *keys[] = {"device_id"};
        const char *values[] = {device_text};
        status = g_ort->CreateCUDAProviderOptions(&cuda_options);
        if (!status)
            status = g_ort->UpdateCUDAProviderOptions(cuda_options, keys, values, 1);
        if (!status)
            status = g_ort->SessionOptionsAppendExecutionProvider_CUDA_V2(state->options,
                                                                          cuda_options);
        if (cuda_options)
            g_ort->ReleaseCUDAProviderOptions(cuda_options);
        if (status) {
            Tcl_SetObjResult(interp, Tcl_ObjPrintf("CUDAExecutionProvider setup failed: %s",
                                                  g_ort->GetErrorMessage(status)));
            g_ort->ReleaseStatus(status);
            EmbeddingStateDelete(state);
            return TCL_ERROR;
        }
    }

    OrtStatus *session_status =
        g_ort->CreateSession(state->env, model_path, state->options, &state->session);
    if (session_status) {
        const char *message = g_ort->GetErrorMessage(session_status);
        Tcl_SetObjResult(interp, cuda ? Tcl_ObjPrintf("CUDA session initialization failed: %s", message)
                                      : Tcl_NewStringObj(message, -1));
        g_ort->ReleaseStatus(session_status);
        EmbeddingStateDelete(state);
        return TCL_ERROR;
    }
    state->profiling = profile != NULL;

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
    state->command =
        Tcl_CreateObjCommand(interp, handle, EmbeddingHandleCmd, state, EmbeddingStateDelete);
    if (!state->command) {
        EmbeddingStateDelete(state);
        return TCL_ERROR;
    }
    Tcl_SetObjResult(interp, Tcl_NewStringObj(handle, -1));
    return TCL_OK;
}

// --- COMPUTE ---
static int TclEmbedding_Compute_Cmd(ClientData cd, Tcl_Interp *interp, int objc,
                                    Tcl_Obj *const objv[]) {
    (void)cd;
    if (objc != 3 && objc != 5) {
        Tcl_WrongNumArgs(interp, 1, objv, "handle token_id_list ?-pooling mean|cls?");
        return TCL_ERROR;
    }

    EmbeddingState *state = GetEmbeddingState(interp, objv[1]);
    if (!state)
        return TCL_ERROR;
    int cls = 0;
    if (objc == 5) {
        const char *option = Tcl_GetString(objv[3]);
        const char *pooling = Tcl_GetString(objv[4]);
        if (strcmp(option, "-pooling") != 0 ||
            (strcmp(pooling, "mean") != 0 && strcmp(pooling, "cls") != 0)) {
            Tcl_SetObjResult(interp, Tcl_NewStringObj("expected -pooling mean or cls", -1));
            return TCL_ERROR;
        }
        cls = strcmp(pooling, "cls") == 0;
    }

    // 1. TCL List -> C Array
    int token_count;
    Tcl_Obj **obj_tokens;
    if (Tcl_ListObjGetElements(interp, objv[2], &token_count, &obj_tokens) != TCL_OK)
        return TCL_ERROR;

    if (token_count == 0) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj("token ID list must not be empty", -1));
        return TCL_ERROR;
    }

    if (state->fixed_sequence && state->fixed_sequence != token_count) {
        Tcl_SetObjResult(
            interp, Tcl_NewStringObj("token count does not match fixed ONNX input sequence", -1));
        return TCL_ERROR;
    }
    size_t count = (size_t)token_count;
    if (count > SIZE_MAX / sizeof(int64_t) || count > UINT_MAX / sizeof(int64_t)) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj("token ID list is too large", -1));
        return TCL_ERROR;
    }
    size_t input_bytes = count * sizeof(int64_t);
    int64_t *input_ids = (int64_t *)ckalloc((unsigned int)input_bytes);
    int64_t *attention = (int64_t *)ckalloc((unsigned int)input_bytes);
    int64_t *type_ids = (int64_t *)ckalloc((unsigned int)input_bytes);

    for (int i = 0; i < token_count; i++) {
        mp_int exact;
        if (Tcl_GetBignumFromObj(interp, obj_tokens[i], &exact) != TCL_OK) {
            ckfree((char *)input_ids);
            ckfree((char *)attention);
            ckfree((char *)type_ids);
            return TCL_ERROR;
        }
        int invalid = mp_isneg(&exact) || mp_count_bits(&exact) > 63;
        mp_clear(&exact);
        if (invalid) {
            Tcl_SetObjResult(
                interp,
                Tcl_NewStringObj("token IDs must be nonnegative signed 64-bit integers", -1));
            ckfree((char *)input_ids);
            ckfree((char *)attention);
            ckfree((char *)type_ids);
            return TCL_ERROR;
        }
        Tcl_WideInt val;
        if (Tcl_GetWideIntFromObj(interp, obj_tokens[i], &val) != TCL_OK) {
            ckfree((char *)input_ids);
            ckfree((char *)attention);
            ckfree((char *)type_ids);
            return TCL_ERROR;
        }
        if (val < 0 || val > (Tcl_WideInt)INT64_MAX) {
            Tcl_SetObjResult(
                interp,
                Tcl_NewStringObj("token IDs must be nonnegative signed 64-bit integers", -1));
            ckfree((char *)input_ids);
            ckfree((char *)attention);
            ckfree((char *)type_ids);
            return TCL_ERROR;
        }
        input_ids[i] = (int64_t)val;
        attention[i] = 1;
        type_ids[i] = 0;
    }

    // Variables para ONNX y limpieza
    OrtMemoryInfo *memory_info = NULL;
    OrtStatus *st = NULL;
    OrtValue *t1 = NULL, *t2 = NULL, *t3 = NULL, *t_out = NULL;
    OrtTensorTypeAndShapeInfo *output_shape = NULL;
    double *sum_vec = NULL;
    int result = TCL_OK;

    // 2. Preparar Memoria y Tensores
    st = g_ort->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &memory_info);
    if (st) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj(g_ort->GetErrorMessage(st), -1));
        g_ort->ReleaseStatus(st);
        result = TCL_ERROR;
        goto cleanup;
    }

    int64_t input_shape[] = {1, token_count};

    st = g_ort->CreateTensorWithDataAsOrtValue(memory_info, input_ids, input_bytes, input_shape, 2,
                                               ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &t1);
    if (st) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj(g_ort->GetErrorMessage(st), -1));
        g_ort->ReleaseStatus(st);
        result = TCL_ERROR;
        goto cleanup;
    }

    st = g_ort->CreateTensorWithDataAsOrtValue(memory_info, attention, input_bytes, input_shape, 2,
                                               ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &t2);
    if (st) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj(g_ort->GetErrorMessage(st), -1));
        g_ort->ReleaseStatus(st);
        result = TCL_ERROR;
        goto cleanup;
    }

    if (state->has_type_ids) {
        st = g_ort->CreateTensorWithDataAsOrtValue(memory_info, type_ids, input_bytes, input_shape,
                                                   2, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &t3);
        if (st) {
            Tcl_SetObjResult(interp, Tcl_NewStringObj(g_ort->GetErrorMessage(st), -1));
            g_ort->ReleaseStatus(st);
            result = TCL_ERROR;
            goto cleanup;
        }
    }

    const char *input_names[] = {"input_ids", "attention_mask", "token_type_ids"};
    const char *output_names[] = {"last_hidden_state"};
    const OrtValue *inputs[] = {t1, t2, t3};

    // 3. Ejecutar Inferencia
    st = g_ort->Run(state->session, NULL, input_names, inputs, state->has_type_ids ? 3 : 2,
                    output_names, 1, &t_out);
    if (st) {
        const char *msg = g_ort->GetErrorMessage(st);
        Tcl_SetObjResult(interp, Tcl_NewStringObj(msg, -1));
        g_ort->ReleaseStatus(st);
        result = TCL_ERROR;
        goto cleanup;
    }

    // Validate the output before interpreting its memory.
    if (!t_out) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj("ONNX returned no output", -1));
        result = TCL_ERROR;
        goto cleanup;
    }
    int is_tensor = 0;
    st = g_ort->IsTensor(t_out, &is_tensor);
    if (st) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj(g_ort->GetErrorMessage(st), -1));
        g_ort->ReleaseStatus(st);
        result = TCL_ERROR;
        goto cleanup;
    }
    if (!is_tensor) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj("ONNX output is not a tensor", -1));
        result = TCL_ERROR;
        goto cleanup;
    }
    st = g_ort->GetTensorTypeAndShape(t_out, &output_shape);
    if (st) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj(g_ort->GetErrorMessage(st), -1));
        g_ort->ReleaseStatus(st);
        result = TCL_ERROR;
        goto cleanup;
    }
    ONNXTensorElementDataType element_type;
    size_t rank = 0, elements = 0;
    int64_t dimensions[3];
    st = g_ort->GetTensorElementType(output_shape, &element_type);
    if (st) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj(g_ort->GetErrorMessage(st), -1));
        g_ort->ReleaseStatus(st);
        result = TCL_ERROR;
        goto cleanup;
    }
    if (element_type != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT) {
        Tcl_SetObjResult(interp,
                         Tcl_NewStringObj("ONNX output tensor must have float32 elements", -1));
        result = TCL_ERROR;
        goto cleanup;
    }
    st = g_ort->GetDimensionsCount(output_shape, &rank);
    if (st) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj(g_ort->GetErrorMessage(st), -1));
        g_ort->ReleaseStatus(st);
        result = TCL_ERROR;
        goto cleanup;
    }
    if (rank != 3) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj("ONNX output tensor must have rank 3", -1));
        result = TCL_ERROR;
        goto cleanup;
    }
    st = g_ort->GetDimensions(output_shape, dimensions, 3);
    if (st) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj(g_ort->GetErrorMessage(st), -1));
        g_ort->ReleaseStatus(st);
        result = TCL_ERROR;
        goto cleanup;
    }
    if (dimensions[0] != 1 || dimensions[1] != (int64_t)token_count || dimensions[2] <= 0 ||
        dimensions[2] > INT_MAX || (uint64_t)dimensions[2] > SIZE_MAX / sizeof(double) ||
        (uint64_t)dimensions[2] > SIZE_MAX / count ||
        count * (size_t)dimensions[2] > SIZE_MAX / sizeof(float)) {
        Tcl_SetObjResult(
            interp,
            Tcl_NewStringObj(
                "ONNX output tensor must have a safe shape [1, token_count, hidden_dimension]",
                -1));
        result = TCL_ERROR;
        goto cleanup;
    }
    st = g_ort->GetTensorShapeElementCount(output_shape, &elements);
    if (st) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj(g_ort->GetErrorMessage(st), -1));
        g_ort->ReleaseStatus(st);
        result = TCL_ERROR;
        goto cleanup;
    }
    size_t embedding_dim = (size_t)dimensions[2];
    if (elements != count * embedding_dim) {
        Tcl_SetObjResult(interp,
                         Tcl_NewStringObj("ONNX output tensor element count is inconsistent", -1));
        result = TCL_ERROR;
        goto cleanup;
    }

    // 4. Mean Pooling + L2 Normalization
    float *floats;
    // --- EL FIX DEL WARNING ESTÁ AQUÍ ---
    st = g_ort->GetTensorMutableData(t_out, (void **)&floats);
    if (st) {
        const char *msg = g_ort->GetErrorMessage(st);
        Tcl_SetObjResult(interp, Tcl_NewStringObj(msg, -1));
        g_ort->ReleaseStatus(st);
        result = TCL_ERROR;
        goto cleanup;
    }
    if (!floats) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj("ONNX output tensor has no data", -1));
        result = TCL_ERROR;
        goto cleanup;
    }
    // ------------------------------------

    sum_vec = (double *)calloc(embedding_dim, sizeof(double));
    if (!sum_vec) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj("unable to allocate embedding", -1));
        result = TCL_ERROR;
        goto cleanup;
    }

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
            Tcl_SetObjResult(interp,
                             Tcl_NewStringObj("ONNX output produced non-finite mean values", -1));
            result = TCL_ERROR;
            goto cleanup;
        }
        norm += sum_vec[i] * sum_vec[i];
    }
    norm = sqrt(norm);
    if (!isfinite(norm) || norm == 0.0) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj("embedding norm is zero or non-finite", -1));
        result = TCL_ERROR;
        goto cleanup;
    }
    if (norm < 1e-9)
        norm = 1e-9;

    // C. Generar lista TCL normalizada
    Tcl_Obj *result_list = Tcl_NewListObj(0, NULL);
    for (size_t i = 0; i < embedding_dim; i++) {
        Tcl_ListObjAppendElement(interp, result_list, Tcl_NewDoubleObj(sum_vec[i] / norm));
    }
    Tcl_SetObjResult(interp, result_list);

cleanup:
    if (output_shape)
        g_ort->ReleaseTensorTypeAndShapeInfo(output_shape);
    if (sum_vec)
        free(sum_vec);
    if (t1)
        g_ort->ReleaseValue(t1);
    if (t2)
        g_ort->ReleaseValue(t2);
    if (t3)
        g_ort->ReleaseValue(t3);
    if (t_out)
        g_ort->ReleaseValue(t_out);
    if (memory_info)
        g_ort->ReleaseMemoryInfo(memory_info);

    ckfree((char *)input_ids);
    ckfree((char *)attention);
    ckfree((char *)type_ids);

    return result;
}

/* Batch size and padded tensor elements are deliberately bounded before allocation. */
#define EMBEDDING_BATCH_MAX 256
#define EMBEDDING_BATCH_ELEMENTS_MAX 4096
#define EMBEDDING_BATCH_SEQUENCE_MAX 512
#define EMBEDDING_BATCH_OUTPUT_MAX 16777216

static int BatchId(Tcl_Interp *interp, Tcl_Obj *obj, int64_t *out) {
    mp_int exact;
    if (Tcl_GetBignumFromObj(interp, obj, &exact) != TCL_OK)
        return TCL_ERROR;
    int invalid = mp_isneg(&exact) || mp_count_bits(&exact) > 63;
    mp_clear(&exact);
    Tcl_WideInt value;
    if (invalid) {
        Tcl_SetObjResult(interp,
                         Tcl_NewStringObj("IDs must be nonnegative signed 64-bit integers", -1));
        return TCL_ERROR;
    }
    if (Tcl_GetWideIntFromObj(interp, obj, &value) != TCL_OK)
        return TCL_ERROR;
    if (value < 0 || value > (Tcl_WideInt)INT64_MAX) {
        Tcl_SetObjResult(interp,
                         Tcl_NewStringObj("IDs must be nonnegative signed 64-bit integers", -1));
        return TCL_ERROR;
    }
    *out = (int64_t)value;
    return TCL_OK;
}

/* Bound the output tensor from its declared hidden size before running ONNX. */
static int BatchOutputBound(Tcl_Interp *interp, EmbeddingState *state, size_t count, int batch,
                            int length, int64_t *declared_hidden) {
    OrtStatus *st = NULL;
    OrtAllocator *allocator = NULL;
    OrtTypeInfo *type = NULL;
    char *name = NULL;
    size_t n = 0;
    int result = TCL_ERROR;
#define OUTPUT_CALL(expr)                                                                          \
    do {                                                                                           \
        st = (expr);                                                                               \
        if (st) {                                                                                  \
            Tcl_SetObjResult(interp, Tcl_NewStringObj(g_ort->GetErrorMessage(st), -1));            \
            g_ort->ReleaseStatus(st);                                                              \
            goto output_done;                                                                      \
        }                                                                                          \
    } while (0)
    OUTPUT_CALL(g_ort->GetAllocatorWithDefaultOptions(&allocator));
    OUTPUT_CALL(g_ort->SessionGetOutputCount(state->session, &n));
    for (size_t i = 0; i < n; i++) {
        OUTPUT_CALL(g_ort->SessionGetOutputName(state->session, i, allocator, &name));
        if (name && strcmp(name, "last_hidden_state") == 0) {
            const OrtTensorTypeAndShapeInfo *shape = NULL;
            ONNXType kind;
            ONNXTensorElementDataType element;
            size_t rank;
            int64_t dims[3];
            OUTPUT_CALL(g_ort->SessionGetOutputTypeInfo(state->session, i, &type));
            OUTPUT_CALL(g_ort->GetOnnxTypeFromTypeInfo(type, &kind));
            if (kind != ONNX_TYPE_TENSOR)
                break;
            OUTPUT_CALL(g_ort->CastTypeInfoToTensorInfo(type, &shape));
            if (!shape)
                break;
            OUTPUT_CALL(g_ort->GetTensorElementType(shape, &element));
            OUTPUT_CALL(g_ort->GetDimensionsCount(shape, &rank));
            if (element != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT || rank != 3)
                break;
            OUTPUT_CALL(g_ort->GetDimensions(shape, dims, 3));
            if ((dims[0] != -1 && dims[0] != batch) || (dims[1] != -1 && dims[1] != length) ||
                dims[2] <= 0 || dims[2] > 8192 ||
                (uint64_t)dims[2] > EMBEDDING_BATCH_OUTPUT_MAX / count)
                break;
            *declared_hidden = dims[2];
            result = TCL_OK;
            break;
        }
        if (name) {
            allocator->Free(allocator, name);
            name = NULL;
        }
    }
    if (result != TCL_OK)
        Tcl_SetObjResult(
            interp,
            Tcl_NewStringObj("ONNX batch output metadata is incompatible or exceeds limits", -1));
output_done:
    if (type)
        g_ort->ReleaseTypeInfo(type);
    if (name && allocator)
        allocator->Free(allocator, name);
#undef OUTPUT_CALL
    return result;
}

static int TclEmbedding_ComputeBatch_Cmd(ClientData cd, Tcl_Interp *interp, int objc,
                                         Tcl_Obj *const objv[]) {
    (void)cd;
    if (objc != 5 && objc != 7) {
        Tcl_WrongNumArgs(interp, 1, objv,
                         "handle token_id_lists -pad-id integer ?-pooling mean|cls?");
        return TCL_ERROR;
    }
    EmbeddingState *state = GetEmbeddingState(interp, objv[1]);
    if (!state)
        return TCL_ERROR;
    if (strcmp(Tcl_GetString(objv[3]), "-pad-id") != 0) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj("expected -pad-id integer", -1));
        return TCL_ERROR;
    }
    int64_t pad;
    if (BatchId(interp, objv[4], &pad) != TCL_OK)
        return TCL_ERROR;
    int cls = 0;
    if (objc == 7) {
        const char *mode = Tcl_GetString(objv[6]);
        if (strcmp(Tcl_GetString(objv[5]), "-pooling") != 0 ||
            (strcmp(mode, "mean") != 0 && strcmp(mode, "cls") != 0)) {
            Tcl_SetObjResult(interp, Tcl_NewStringObj("expected -pooling mean or cls", -1));
            return TCL_ERROR;
        }
        cls = strcmp(mode, "cls") == 0;
    }
    int batch_count;
    Tcl_Obj **sequences;
    if (Tcl_ListObjGetElements(interp, objv[2], &batch_count, &sequences) != TCL_OK)
        return TCL_ERROR;
    if (batch_count <= 0 || batch_count > EMBEDDING_BATCH_MAX) {
        Tcl_SetObjResult(interp,
                         Tcl_NewStringObj("batch must contain between 1 and 256 sequences", -1));
        return TCL_ERROR;
    }
    if (state->fixed_batch && state->fixed_batch != batch_count) {
        Tcl_SetObjResult(interp,
                         Tcl_NewStringObj("batch size does not match fixed ONNX input batch", -1));
        return TCL_ERROR;
    }
    int max_len = 0;
    for (int b = 0; b < batch_count; b++) {
        int length;
        Tcl_Obj **items;
        if (Tcl_ListObjGetElements(interp, sequences[b], &length, &items) != TCL_OK)
            return TCL_ERROR;
        if (!length) {
            Tcl_SetObjResult(interp, Tcl_NewStringObj("token ID sequences must not be empty", -1));
            return TCL_ERROR;
        }
        if (length > EMBEDDING_BATCH_SEQUENCE_MAX) {
            Tcl_SetObjResult(
                interp,
                Tcl_NewStringObj("sequence exceeds the batch input limit of 512 tokens", -1));
            return TCL_ERROR;
        }
        if (length > max_len)
            max_len = length;
        if ((size_t)max_len > EMBEDDING_BATCH_ELEMENTS_MAX / (size_t)batch_count) {
            Tcl_SetObjResult(interp,
                             Tcl_NewStringObj("padded batch exceeds the input element limit", -1));
            return TCL_ERROR;
        }
        for (int t = 0; t < length; t++) {
            int64_t ignored;
            if (BatchId(interp, items[t], &ignored) != TCL_OK)
                return TCL_ERROR;
        }
    }
    if (state->fixed_sequence && state->fixed_sequence != max_len) {
        Tcl_SetObjResult(
            interp, Tcl_NewStringObj("padded length does not match fixed ONNX input sequence", -1));
        return TCL_ERROR;
    }
    size_t count = (size_t)batch_count * (size_t)max_len;
    if (count > SIZE_MAX / sizeof(int64_t)) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj("padded batch size overflow", -1));
        return TCL_ERROR;
    }
    int64_t declared_hidden = 0;
    if (BatchOutputBound(interp, state, count, batch_count, max_len, &declared_hidden) != TCL_OK)
        return TCL_ERROR;
    size_t bytes = count * sizeof(int64_t);
    int64_t *ids = calloc(count, sizeof(*ids)), *mask = calloc(count, sizeof(*mask));
    int64_t *types = state->has_type_ids ? calloc(count, sizeof(*types)) : NULL;
    OrtMemoryInfo *memory = NULL;
    OrtValue *input[3] = {NULL, NULL, NULL}, *output = NULL;
    OrtTensorTypeAndShapeInfo *shape = NULL;
    Tcl_Obj *result_list = NULL;
    double *pooled = NULL;
    int result = TCL_ERROR;
    OrtStatus *st;
#define BATCH_CALL(expr)                                                                           \
    do {                                                                                           \
        st = (expr);                                                                               \
        if (st) {                                                                                  \
            Tcl_SetObjResult(interp, Tcl_NewStringObj(g_ort->GetErrorMessage(st), -1));            \
            g_ort->ReleaseStatus(st);                                                              \
            goto batch_cleanup;                                                                    \
        }                                                                                          \
    } while (0)
    if (!ids || !mask || (state->has_type_ids && !types)) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj("unable to allocate batch inputs", -1));
        goto batch_cleanup;
    }
    for (int b = 0; b < batch_count; b++) {
        int length;
        Tcl_Obj **items;
        if (Tcl_ListObjGetElements(interp, sequences[b], &length, &items) != TCL_OK)
            goto batch_cleanup;
        for (int t = 0; t < max_len; t++) {
            size_t offset = (size_t)b * (size_t)max_len + (size_t)t;
            if (t < length) {
                if (BatchId(interp, items[t], &ids[offset]) != TCL_OK)
                    goto batch_cleanup;
                mask[offset] = 1;
            } else
                ids[offset] = pad;
        }
    }
    int64_t input_dims[2] = {batch_count, max_len};
    BATCH_CALL(g_ort->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &memory));
    BATCH_CALL(g_ort->CreateTensorWithDataAsOrtValue(
        memory, ids, bytes, input_dims, 2, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &input[0]));
    BATCH_CALL(g_ort->CreateTensorWithDataAsOrtValue(
        memory, mask, bytes, input_dims, 2, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &input[1]));
    if (state->has_type_ids)
        BATCH_CALL(g_ort->CreateTensorWithDataAsOrtValue(
            memory, types, bytes, input_dims, 2, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &input[2]));
    const char *input_names[] = {"input_ids", "attention_mask", "token_type_ids"};
    const char *output_names[] = {"last_hidden_state"};
    BATCH_CALL(g_ort->Run(state->session, NULL, input_names, (const OrtValue *const *)input,
                          state->has_type_ids ? 3 : 2, output_names, 1, &output));
    if (!output) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj("ONNX returned no output", -1));
        goto batch_cleanup;
    }
    int is_tensor = 0;
    BATCH_CALL(g_ort->IsTensor(output, &is_tensor));
    if (!is_tensor) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj("ONNX output is not a tensor", -1));
        goto batch_cleanup;
    }
    BATCH_CALL(g_ort->GetTensorTypeAndShape(output, &shape));
    ONNXTensorElementDataType element;
    size_t rank, elements;
    int64_t dims[3];
    BATCH_CALL(g_ort->GetTensorElementType(shape, &element));
    BATCH_CALL(g_ort->GetDimensionsCount(shape, &rank));
    if (element != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT || rank != 3) {
        Tcl_SetObjResult(interp,
                         Tcl_NewStringObj("ONNX output must be a rank-3 float32 tensor", -1));
        goto batch_cleanup;
    }
    BATCH_CALL(g_ort->GetDimensions(shape, dims, 3));
    if (dims[0] != batch_count || dims[1] != max_len || dims[2] != declared_hidden ||
        dims[2] <= 0 || dims[2] > 8192 || (uint64_t)dims[2] > EMBEDDING_BATCH_OUTPUT_MAX / count ||
        (uint64_t)dims[2] > SIZE_MAX / sizeof(double) || (uint64_t)dims[2] > SIZE_MAX / count ||
        count * (size_t)dims[2] > SIZE_MAX / sizeof(float)) {
        Tcl_SetObjResult(
            interp,
            Tcl_NewStringObj("ONNX output must have a safe shape [batch, sequence, hidden]", -1));
        goto batch_cleanup;
    }
    size_t dim = (size_t)dims[2];
    BATCH_CALL(g_ort->GetTensorShapeElementCount(shape, &elements));
    if (elements != count * dim) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj("ONNX output element count is inconsistent", -1));
        goto batch_cleanup;
    }
    float *data = NULL;
    BATCH_CALL(g_ort->GetTensorMutableData(output, (void **)&data));
    if (!data) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj("ONNX output tensor has no data", -1));
        goto batch_cleanup;
    }
    pooled = calloc(dim, sizeof(*pooled));
    if (!pooled) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj("unable to allocate pooled vector", -1));
        goto batch_cleanup;
    }
    result_list = Tcl_NewListObj(0, NULL);
    Tcl_IncrRefCount(result_list);
    for (int b = 0; b < batch_count; b++) {
        memset(pooled, 0, dim * sizeof(*pooled));
        size_t valid = 0;
        for (int t = 0; t < max_len; t++) {
            size_t offset = (size_t)b * (size_t)max_len + (size_t)t;
            if (mask[offset])
                valid++;
            for (size_t i = 0; i < dim; i++) {
                float value = data[offset * dim + i];
                if (!isfinite(value)) {
                    Tcl_SetObjResult(
                        interp, Tcl_NewStringObj("ONNX output contains non-finite values", -1));
                    goto batch_cleanup;
                }
                if (mask[offset] && (!cls || t == 0))
                    pooled[i] += value;
            }
        }
        double norm = 0.0;
        for (size_t i = 0; i < dim; i++) {
            pooled[i] /= cls ? 1 : valid;
            norm += pooled[i] * pooled[i];
        }
        norm = sqrt(norm);
        if (!isfinite(norm) || norm == 0.0) {
            Tcl_SetObjResult(interp, Tcl_NewStringObj("embedding norm is zero or non-finite", -1));
            goto batch_cleanup;
        }
        if (norm < 1e-9)
            norm = 1e-9;
        Tcl_Obj *vec = Tcl_NewListObj(0, NULL);
        Tcl_IncrRefCount(vec);
        for (size_t i = 0; i < dim; i++) {
            if (Tcl_ListObjAppendElement(interp, vec, Tcl_NewDoubleObj(pooled[i] / norm)) !=
                TCL_OK) {
                Tcl_DecrRefCount(vec);
                goto batch_cleanup;
            }
        }
        if (Tcl_ListObjAppendElement(interp, result_list, vec) != TCL_OK) {
            Tcl_DecrRefCount(vec);
            goto batch_cleanup;
        }
        Tcl_DecrRefCount(vec);
    }
    Tcl_SetObjResult(interp, result_list);
    result = TCL_OK;
batch_cleanup:
    if (result_list)
        Tcl_DecrRefCount(result_list);
    free(pooled);
    if (shape)
        g_ort->ReleaseTensorTypeAndShapeInfo(shape);
    if (output)
        g_ort->ReleaseValue(output);
    for (int i = 0; i < 3; i++)
        if (input[i])
            g_ort->ReleaseValue(input[i]);
    if (memory)
        g_ort->ReleaseMemoryInfo(memory);
    free(ids);
    free(mask);
    free(types);
#undef BATCH_CALL
    return result;
}

static int TclEmbedding_Free_Cmd(ClientData cd, Tcl_Interp *interp, int objc,
                                 Tcl_Obj *const objv[]) {
    (void)cd;
    if (objc != 2) {
        Tcl_WrongNumArgs(interp, 1, objv, "handle");
        return TCL_ERROR;
    }
    EmbeddingState *state = GetEmbeddingState(interp, objv[1]);
    if (!state)
        return TCL_ERROR;
    OrtStatus *profile_status = EmbeddingEndProfile(state);
    if (profile_status) {
        Tcl_SetObjResult(interp, Tcl_ObjPrintf("ONNX profiling finalization failed: %s",
                                              g_ort->GetErrorMessage(profile_status)));
        g_ort->ReleaseStatus(profile_status);
        Tcl_DeleteCommandFromToken(interp, state->command);
        return TCL_ERROR;
    }
    if (Tcl_DeleteCommandFromToken(interp, state->command) != 0) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj("could not delete embedding handle", -1));
        return TCL_ERROR;
    }
    return TCL_OK;
}

int Tclembedding_Init(Tcl_Interp *interp) {
    if (Tcl_InitStubs(interp, "8.6", 0) == NULL)
        return TCL_ERROR;
    Tcl_CreateObjCommand(interp, "embedding::init_raw", TclEmbedding_Init_Cmd, NULL, NULL);
    Tcl_CreateObjCommand(interp, "embedding::compute", TclEmbedding_Compute_Cmd, NULL, NULL);
    Tcl_CreateObjCommand(interp, "embedding::compute_batch", TclEmbedding_ComputeBatch_Cmd, NULL,
                         NULL);
    Tcl_CreateObjCommand(interp, "embedding::free", TclEmbedding_Free_Cmd, NULL, NULL);
    return Tcl_PkgProvide(interp, "tclembedding", "1.0");
}

#ifdef __cplusplus
}
#endif

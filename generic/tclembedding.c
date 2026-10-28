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
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include "onnxruntime_c_api.h"

// Estructura de estado
typedef struct {
    OrtSession* session;
    OrtSessionOptions* options;
    OrtEnv* env;
    int embedding_dim;
} EmbeddingState;

static const OrtApi* g_ort = NULL;

// Macro para verificar errores de ONNX en Init (donde no hay cleanup complejo)
#define CHECK_STATUS_INIT(expr) do { \
    OrtStatus* status = (expr); \
    if (status != NULL) { \
        const char* msg = g_ort->GetErrorMessage(status); \
        Tcl_SetObjResult(interp, Tcl_NewStringObj(msg, -1)); \
        g_ort->ReleaseStatus(status); \
        return TCL_ERROR; \
    } \
} while(0)

// --- INIT ---
static int TclEmbedding_Init_Cmd(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    if (g_ort == NULL) g_ort = OrtGetApiBase()->GetApi(ORT_API_VERSION);
    
    if (objc != 2) {
        Tcl_WrongNumArgs(interp, 1, objv, "model_path");
        return TCL_ERROR;
    }

    const char *model_path = Tcl_GetString(objv[1]);
    EmbeddingState *state = (EmbeddingState *) ckalloc(sizeof(EmbeddingState));
    
    // Inicialización paso a paso
    CHECK_STATUS_INIT(g_ort->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "tclembedding", &state->env));
    CHECK_STATUS_INIT(g_ort->CreateSessionOptions(&state->options));
    CHECK_STATUS_INIT(g_ort->SetIntraOpNumThreads(state->options, 1));
    CHECK_STATUS_INIT(g_ort->SetSessionExecutionMode(state->options, ORT_SEQUENTIAL));

    OrtStatus* status = g_ort->CreateSession(state->env, model_path, state->options, &state->session);
    if (status != NULL) {
        const char* msg = g_ort->GetErrorMessage(status);
        Tcl_SetObjResult(interp, Tcl_NewStringObj(msg, -1));
        g_ort->ReleaseStatus(status);
        ckfree((char *)state);
        return TCL_ERROR;
    }

    state->embedding_dim = 384; // MiniLM-L12

    char handle[64];
    snprintf(handle, sizeof(handle), "embedding%p", (void *)state);
    Tcl_CreateObjCommand(interp, handle, NULL, state, NULL);
    Tcl_SetObjResult(interp, Tcl_NewStringObj(handle, -1));
    return TCL_OK;
}

// --- COMPUTE ---
static int TclEmbedding_Compute_Cmd(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    if (objc != 3) {
        Tcl_WrongNumArgs(interp, 1, objv, "handle token_id_list");
        return TCL_ERROR;
    }

    const char *handle = Tcl_GetString(objv[1]);
    Tcl_CmdInfo info;
    if (!Tcl_GetCommandInfo(interp, handle, &info)) return TCL_ERROR;
    EmbeddingState *state = (EmbeddingState *) info.objClientData;

    // 1. TCL List -> C Array
    int token_count;
    Tcl_Obj **obj_tokens;
    if (Tcl_ListObjGetElements(interp, objv[2], &token_count, &obj_tokens) != TCL_OK) return TCL_ERROR;

    if (token_count == 0) {
        Tcl_SetObjResult(interp, Tcl_NewListObj(0, NULL));
        return TCL_OK;
    }

    int64_t* input_ids = (int64_t*)ckalloc(token_count * sizeof(int64_t));
    int64_t* attention = (int64_t*)ckalloc(token_count * sizeof(int64_t));
    int64_t* type_ids  = (int64_t*)ckalloc(token_count * sizeof(int64_t));

    for (int i = 0; i < token_count; i++) {
        long val;
        Tcl_GetLongFromObj(interp, obj_tokens[i], &val);
        input_ids[i] = (int64_t)val;
        attention[i] = 1; 
        type_ids[i] = 0;
    }

    // Variables para ONNX y limpieza
    OrtMemoryInfo* memory_info = NULL;
    OrtStatus* st = NULL;
    OrtValue *t1 = NULL, *t2 = NULL, *t3 = NULL, *t_out = NULL;
    double* sum_vec = NULL;
    int result = TCL_OK;

    // 2. Preparar Memoria y Tensores
    st = g_ort->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &memory_info);
    if (st) { g_ort->ReleaseStatus(st); result = TCL_ERROR; goto cleanup_early; }
    
    int64_t input_shape[] = {1, token_count};
    
    st = g_ort->CreateTensorWithDataAsOrtValue(memory_info, input_ids, token_count*8, input_shape, 2, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &t1);
    if (st) { g_ort->ReleaseStatus(st); result = TCL_ERROR; goto cleanup; }

    st = g_ort->CreateTensorWithDataAsOrtValue(memory_info, attention, token_count*8, input_shape, 2, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &t2);
    if (st) { g_ort->ReleaseStatus(st); result = TCL_ERROR; goto cleanup; }

    st = g_ort->CreateTensorWithDataAsOrtValue(memory_info, type_ids, token_count*8, input_shape, 2, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, &t3);
    if (st) { g_ort->ReleaseStatus(st); result = TCL_ERROR; goto cleanup; }

    const char* input_names[] = {"input_ids", "attention_mask", "token_type_ids"};
    const char* output_names[] = {"last_hidden_state"};
    const OrtValue* inputs[] = {t1, t2, t3};

    // 3. Ejecutar Inferencia
    st = g_ort->Run(state->session, NULL, input_names, inputs, 3, output_names, 1, &t_out);
    if (st) {
        const char* msg = g_ort->GetErrorMessage(st);
        Tcl_SetObjResult(interp, Tcl_NewStringObj(msg, -1));
        g_ort->ReleaseStatus(st);
        result = TCL_ERROR;
        goto cleanup;
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
    // ------------------------------------
    
    sum_vec = (double*)calloc(state->embedding_dim, sizeof(double));
    if (!sum_vec) { result = TCL_ERROR; goto cleanup; }

    // A. Sumar
    for (int t = 0; t < token_count; t++) {
        for (int i = 0; i < state->embedding_dim; i++) {
            sum_vec[i] += floats[t * state->embedding_dim + i];
        }
    }
    
    // B. Promediar y Calcular Norma
    double norm = 0.0;
    for (int i = 0; i < state->embedding_dim; i++) {
        sum_vec[i] /= token_count;
        norm += sum_vec[i] * sum_vec[i];
    }
    norm = sqrt(norm);
    if (norm < 1e-9) norm = 1e-9;

    // C. Generar lista TCL normalizada
    Tcl_Obj *result_list = Tcl_NewListObj(0, NULL);
    for (int i = 0; i < state->embedding_dim; i++) {
        Tcl_ListObjAppendElement(interp, result_list, Tcl_NewDoubleObj(sum_vec[i] / norm));
    }
    Tcl_SetObjResult(interp, result_list);

cleanup:
    if (sum_vec) free(sum_vec);
    if (t1) g_ort->ReleaseValue(t1);
    if (t2) g_ort->ReleaseValue(t2);
    if (t3) g_ort->ReleaseValue(t3);
    if (t_out) g_ort->ReleaseValue(t_out);
    if (memory_info) g_ort->ReleaseMemoryInfo(memory_info);

cleanup_early:
    ckfree((char*)input_ids);
    ckfree((char*)attention);
    ckfree((char*)type_ids);

    return result;
}

static int TclEmbedding_Free_Cmd(ClientData cd, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
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

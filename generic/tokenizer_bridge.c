#include <tcl.h>
#include <tclTomMathDecls.h>
#include <stdint.h>
#include <limits.h>
#include <string.h>
#include "../tokenizer-native/hf_tokenizer.h"

typedef struct {
    hf_tokenizer *handle;
} TokenizerState;

static void StateDelete(ClientData data, Tcl_Interp *interp) {
    TokenizerState *state = (TokenizerState *)data;
    (void)interp;
    if (state->handle)
        hf_tokenizer_free(state->handle);
    ckfree((char *)state);
}

static int BackendError(Tcl_Interp *interp, char *error) {
    Tcl_SetObjResult(interp, Tcl_NewStringObj(error ? error : "tokenizer backend error", -1));
    if (error)
        hf_error_free(error);
    Tcl_SetErrorCode(interp, "TOKENIZER", "BACKEND", NULL);
    return TCL_ERROR;
}

static int LoadCmd(ClientData data, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    TokenizerState *state = (TokenizerState *)data;
    hf_tokenizer *next = NULL;
    Tcl_DString path;
    Tcl_Encoding utf8;
    int length;
    char *error = NULL;
    const char *str;
    if (objc != 2) {
        Tcl_WrongNumArgs(interp, 1, objv, "tokenizer_json");
        return TCL_ERROR;
    }
    str = Tcl_GetStringFromObj(objv[1], &length);
    utf8 = Tcl_GetEncoding(interp, "utf-8");
    if (!utf8)
        return TCL_ERROR;
    Tcl_UtfToExternalDString(utf8, str, length, &path);
    Tcl_FreeEncoding(utf8);
    if (memchr(Tcl_DStringValue(&path), 0, (size_t)Tcl_DStringLength(&path))) {
        Tcl_DStringFree(&path);
        Tcl_SetObjResult(interp, Tcl_NewStringObj("tokenizer path contains NUL", -1));
        return TCL_ERROR;
    }
    if (hf_load(Tcl_DStringValue(&path), &next, &error)) {
        Tcl_DStringFree(&path);
        return BackendError(interp, error);
    }
    Tcl_DStringFree(&path);
    if (state->handle)
        hf_tokenizer_free(state->handle);
    state->handle = next;
    return TCL_OK;
}

static int EncodeCommon(ClientData data, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[],
                        int details_mode) {
    TokenizerState *state = (TokenizerState *)data;
    Tcl_WideInt limit = 0;
    Tcl_DString bytes;
    Tcl_Encoding utf8;
    int length;
    const char *text;
    uint32_t *ids = NULL;
    hf_token_detail *details = NULL;
    size_t count = 0;
    char *error = NULL;
    if (objc != 2 && objc != 4) {
        Tcl_WrongNumArgs(interp, 1, objv, "text ?-max-length count?");
        return TCL_ERROR;
    }
    if (objc == 4) {
        if (strcmp(Tcl_GetString(objv[2]), "-max-length") != 0) {
            Tcl_SetObjResult(interp, Tcl_NewStringObj("expected -max-length", -1));
            return TCL_ERROR;
        }
        mp_int exact;
        if (Tcl_GetBignumFromObj(interp, objv[3], &exact) != TCL_OK)
            return TCL_ERROR;
        int negative = mp_isneg(&exact);
        int too_large = mp_count_bits(&exact) > 63;
        mp_clear(&exact);
        if (negative) {
            Tcl_SetObjResult(interp, Tcl_NewStringObj("max-length must be positive", -1));
            return TCL_ERROR;
        }
        if (too_large) {
            Tcl_SetObjResult(interp, Tcl_NewStringObj("integer value too large to represent", -1));
            return TCL_ERROR;
        }
        if (Tcl_GetWideIntFromObj(interp, objv[3], &limit) != TCL_OK)
            return TCL_ERROR;
        if (limit < 1 || (uint64_t)limit > SIZE_MAX) {
            Tcl_SetObjResult(interp, Tcl_NewStringObj("max-length must be positive", -1));
            return TCL_ERROR;
        }
    }
    if (!state->handle) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj("no tokenizer loaded", -1));
        return TCL_ERROR;
    }
    text = Tcl_GetStringFromObj(objv[1], &length);
    utf8 = Tcl_GetEncoding(interp, "utf-8");
    if (!utf8)
        return TCL_ERROR;
    Tcl_UtfToExternalDString(utf8, text, length, &bytes);
    Tcl_FreeEncoding(utf8);
    int status =
        details_mode
            ? hf_encode_details(state->handle, (const uint8_t *)Tcl_DStringValue(&bytes),
                                (size_t)Tcl_DStringLength(&bytes), (size_t)limit, &details, &count,
                                &error)
            : hf_encode(state->handle, (const uint8_t *)Tcl_DStringValue(&bytes),
                        (size_t)Tcl_DStringLength(&bytes), (size_t)limit, &ids, &count, &error);
    if (status) {
        Tcl_DStringFree(&bytes);
        return BackendError(interp, error);
    }
    Tcl_DStringFree(&bytes);
    if (count > INT_MAX) {
        if (details_mode)
            hf_details_free(&details, &count);
        else
            hf_ids_free(ids, count);
        Tcl_SetObjResult(interp, Tcl_NewStringObj("too many token IDs", -1));
        return TCL_ERROR;
    }
    Tcl_Obj *result = Tcl_NewListObj(0, NULL);
    Tcl_IncrRefCount(result);
    for (size_t i = 0; i < count; i++) {
        Tcl_Obj *item;
        if (details_mode) {
            if (details[i].byte_start > INT64_MAX || details[i].byte_end > INT64_MAX) {
                hf_details_free(&details, &count);
                Tcl_DecrRefCount(result);
                Tcl_SetObjResult(interp, Tcl_NewStringObj("token offset too large", -1));
                return TCL_ERROR;
            }
            Tcl_Obj *fields[6] = {Tcl_NewWideIntObj(details[i].id),
                                  Tcl_NewWideIntObj((Tcl_WideInt)details[i].byte_start),
                                  Tcl_NewWideIntObj((Tcl_WideInt)details[i].byte_end),
                                  Tcl_NewWideIntObj(details[i].special_mask),
                                  Tcl_NewWideIntObj(details[i].attention_mask),
                                  Tcl_NewWideIntObj(details[i].type_id)};
            item = Tcl_NewListObj(6, fields);
        } else
            item = Tcl_NewWideIntObj((Tcl_WideInt)ids[i]);
        if (Tcl_ListObjAppendElement(interp, result, item) != TCL_OK) {
            if (details_mode)
                hf_details_free(&details, &count);
            else
                hf_ids_free(ids, count);
            Tcl_DecrRefCount(result);
            return TCL_ERROR;
        }
    }
    if (details_mode)
        hf_details_free(&details, &count);
    else
        hf_ids_free(ids, count);
    Tcl_SetObjResult(interp, result);
    Tcl_DecrRefCount(result);
    return TCL_OK;
}

static int EncodeCmd(ClientData data, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    return EncodeCommon(data, interp, objc, objv, 0);
}
static int EncodeDetailsCmd(ClientData data, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    return EncodeCommon(data, interp, objc, objv, 1);
}

static int FreeCmd(ClientData data, Tcl_Interp *interp, int objc, Tcl_Obj *const objv[]) {
    TokenizerState *state = (TokenizerState *)data;
    if (objc != 1) {
        Tcl_WrongNumArgs(interp, 1, objv, "");
        return TCL_ERROR;
    }
    if (!state->handle) {
        Tcl_SetObjResult(interp, Tcl_NewStringObj("no tokenizer loaded", -1));
        return TCL_ERROR;
    }
    hf_tokenizer_free(state->handle);
    state->handle = NULL;
    return TCL_OK;
}

int Tcltokenizer_Init(Tcl_Interp *interp) {
    if (!Tcl_InitStubs(interp, "8.6", 0))
        return TCL_ERROR;
    if (!Tcl_FindNamespace(interp, "::tokenizer", NULL, TCL_GLOBAL_ONLY) &&
        !Tcl_CreateNamespace(interp, "::tokenizer", NULL, NULL))
        return TCL_ERROR;
    TokenizerState *state = (TokenizerState *)ckalloc(sizeof(*state));
    state->handle = NULL;
    Tcl_SetAssocData(interp, "tclembedding.tokenizer", StateDelete, state);
    Tcl_CreateObjCommand(interp, "::tokenizer::load_vocab", LoadCmd, state, NULL);
    Tcl_CreateObjCommand(interp, "::tokenizer::tokenize", EncodeCmd, state, NULL);
    Tcl_CreateObjCommand(interp, "::tokenizer::encode_details", EncodeDetailsCmd, state, NULL);
    Tcl_CreateObjCommand(interp, "::tokenizer::free", FreeCmd, state, NULL);
    if (Tcl_PkgProvide(interp, "tclembedding::tokenizer", "1.0.0") != TCL_OK)
        return TCL_ERROR;
    return Tcl_PkgProvide(interp, "tokenizer", "1.0.0");
}

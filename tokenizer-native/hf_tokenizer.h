#ifndef HF_TOKENIZER_H
#define HF_TOKENIZER_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct hf_tokenizer hf_tokenizer;
/* Byte offsets refer to the exact UTF-8 input, with an exclusive end. */
typedef struct {
    uint64_t byte_start, byte_end;
    uint32_t id, special_mask, attention_mask, type_id;
} hf_token_detail;
/* Valid output parameters are reset on failure. When error is non-NULL,
 * *error is set to NULL or a message owned by the caller. Output parameters
 * must be writable and must not overlap. Input pointers must remain valid. */
int hf_load(const char *path, hf_tokenizer **out, char **error);
/* max_length=0 disables truncation; otherwise truncates with special tokens.
 * utf8 must be non-NULL even when length is zero. Free the returned buffer
 * once, with its original count, using hf_ids_free. */
int hf_encode(const hf_tokenizer *, const uint8_t *utf8, size_t length, size_t max_length,
              uint32_t **ids, size_t *count, char **error);
/* The caller owns the returned array. Release it through the same writable,
 * non-overlapping output slots and original count; release resets them and may
 * safely be repeated on those slots. Do not free copied aliases or stale slots.
 * An active handle must not be freed concurrently with an encoding call. */
int hf_encode_details(const hf_tokenizer *, const uint8_t *utf8, size_t length, size_t max_length,
                      hf_token_detail **details, size_t *count, char **error);
void hf_details_free(hf_token_detail **details, size_t *count);
void hf_ids_free(uint32_t *ids, size_t count);
void hf_error_free(char *error);
void hf_tokenizer_free(hf_tokenizer *tokenizer);
#ifdef __cplusplus
}
#endif
#endif

#ifndef HF_TOKENIZER_H
#define HF_TOKENIZER_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct hf_tokenizer hf_tokenizer;
/* Valid output parameters are reset on failure. When error is non-NULL,
 * *error is set to NULL or a message owned by the caller. Output parameters
 * must be writable and must not overlap. Input pointers must remain valid. */
int hf_load(const char *path, hf_tokenizer **out, char **error);
/* max_length=0 disables truncation; otherwise truncates with special tokens.
 * utf8 must be non-NULL even when length is zero. Free the returned buffer
 * once, with its original count, using hf_ids_free. */
int hf_encode(const hf_tokenizer *, const uint8_t *utf8, size_t length,
              size_t max_length, uint32_t **ids, size_t *count, char **error);
void hf_ids_free(uint32_t *ids, size_t count);
void hf_error_free(char *error);
void hf_tokenizer_free(hf_tokenizer *tokenizer);
#ifdef __cplusplus
}
#endif
#endif

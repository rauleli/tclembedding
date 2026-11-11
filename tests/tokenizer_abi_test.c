#include "../tokenizer-native/hf_tokenizer.h"
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define CHECK(expr)                                                                                \
    do {                                                                                           \
        if (!(expr)) {                                                                             \
            fprintf(stderr, "failed at line %d: %s\n", __LINE__, #expr);                           \
            return 1;                                                                              \
        }                                                                                          \
    } while (0)

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: tokenizer_abi_test tokenizer.json\n");
        return 2;
    }
    CHECK(hf_load(NULL, NULL, NULL) != 0);
    CHECK(hf_encode(NULL, NULL, 0, 0, NULL, NULL, NULL) != 0);
    hf_tokenizer *h = (hf_tokenizer *)(uintptr_t)1;
    char *err = NULL;
    CHECK(hf_load(NULL, &h, &err) != 0);
    CHECK(h == NULL && err != NULL);
    hf_error_free(err);
    err = NULL;
    CHECK(hf_load(argv[1], NULL, &err) != 0 && err != NULL);
    hf_error_free(err);
    err = NULL;
    const char bad_path[] = {(char)0xff, 0};
    h = (hf_tokenizer *)(uintptr_t)1;
    CHECK(hf_load(bad_path, &h, &err) != 0 && h == NULL && err != NULL);
    hf_error_free(err);
    err = NULL;
    uint32_t *ids = (uint32_t *)(uintptr_t)1;
    size_t count = 999;
    CHECK(hf_encode(NULL, (const uint8_t *)"", 0, 0, &ids, &count, &err) != 0);
    CHECK(ids == NULL && count == 0 && err != NULL);
    hf_error_free(err);
    err = NULL;
    CHECK(hf_load(argv[1], &h, &err) == 0 && h != NULL && err == NULL);
    ids = (uint32_t *)(uintptr_t)1;
    count = 999;
    CHECK(hf_encode(h, (const uint8_t *)"x", SIZE_MAX, 0, &ids, &count, &err) != 0);
    CHECK(ids == NULL && count == 0 && err != NULL);
    hf_error_free(err);
    err = NULL;
    ids = (uint32_t *)(uintptr_t)1;
    count = 999;
    CHECK(hf_encode(h, NULL, 0, 0, &ids, &count, &err) != 0);
    CHECK(ids == NULL && count == 0 && err != NULL);
    hf_error_free(err);
    err = NULL;
    count = 999;
    CHECK(hf_encode(h, (const uint8_t *)"", 0, 0, NULL, &count, &err) != 0);
    CHECK(count == 0 && err != NULL);
    hf_error_free(err);
    err = NULL;
    const uint8_t bad[] = {0xff};
    CHECK(hf_encode(h, bad, sizeof(bad), 0, &ids, &count, &err) != 0);
    CHECK(ids == NULL && count == 0 && err != NULL);
    hf_error_free(err);
    err = NULL;
    const uint8_t nul_text[] = {'a', 0, 'b'};
    const uint32_t expected[] = {0, 10, 3, 275, 2};
    CHECK(hf_encode(h, nul_text, sizeof(nul_text), 0, &ids, &count, &err) == 0);
    CHECK(count == sizeof(expected) / sizeof(expected[0]) &&
          memcmp(ids, expected, sizeof(expected)) == 0);
    hf_ids_free(ids, count);
    hf_token_detail *details = NULL;
    size_t detail_count = 0;
    CHECK(sizeof(hf_token_detail) == 32);
    CHECK(hf_encode_details(NULL, nul_text, sizeof(nul_text), 0, &details, &detail_count, &err) !=
          0);
    CHECK(details == NULL && detail_count == 0 && err != NULL);
    hf_error_free(err);
    err = NULL;
    CHECK(hf_encode_details(h, nul_text, sizeof(nul_text), 0, NULL, &detail_count, &err) != 0);
    CHECK(detail_count == 0 && err != NULL);
    hf_error_free(err);
    err = NULL;
    CHECK(hf_encode_details(h, nul_text, sizeof(nul_text), 0, &details, &detail_count, &err) == 0);
    CHECK(detail_count == sizeof(expected) / sizeof(expected[0]));
    for (size_t i = 0; i < detail_count; i++) {
        CHECK(details[i].id == expected[i]);
        CHECK(details[i].byte_start <= details[i].byte_end &&
              details[i].byte_end <= sizeof(nul_text));
        CHECK(details[i].attention_mask == 1 && details[i].type_id == 0);
    }
    CHECK(details[0].special_mask == 1 && details[0].byte_start == 0 && details[0].byte_end == 0);
    hf_details_free(&details, &detail_count);
    CHECK(details == NULL && detail_count == 0);
    hf_details_free(&details, &detail_count);
    CHECK(hf_encode_details(h, bad, sizeof(bad), 0, &details, &detail_count, &err) != 0);
    CHECK(details == NULL && detail_count == 0 && err != NULL);
    hf_error_free(err);
    err = NULL;
    CHECK(hf_encode_details(h, (const uint8_t *)"hola", 4, 1, &details, &detail_count, &err) != 0);
    CHECK(details == NULL && detail_count == 0 && err != NULL);
    hf_error_free(err);
    err = NULL;
    CHECK(hf_encode_details(h, (const uint8_t *)"hola", 4, 3, &details, &detail_count, &err) == 0);
    CHECK(detail_count == 3 && details[2].special_mask == 1);
    hf_details_free(&details, &detail_count);
    const char *texts[] = {"", "\xf0\x9f\xa6\x84", "cafe\xcc\x81"};
    const uint32_t expected_ids[][4] = {{0, 2, 0, 0}, {0, 6, 247874, 2}, {0, 26216, 2, 0}};
    const size_t expected_sizes[] = {2, 4, 3};
    for (size_t i = 0; i < 3; ++i) {
        CHECK(hf_encode(h, (const uint8_t *)texts[i], strlen(texts[i]), 0, &ids, &count, &err) ==
              0);
        CHECK(count == expected_sizes[i] &&
              memcmp(ids, expected_ids[i], count * sizeof(*ids)) == 0);
        hf_ids_free(ids, count);
    }
    hf_tokenizer *other = NULL;
    CHECK(hf_load(argv[1], &other, &err) == 0 && other != NULL && err == NULL);
    const uint32_t short_ids[] = {0, 739, 2};
    const uint32_t full_ids[] = {0, 739, 143, 2};
    CHECK(hf_encode(h, (const uint8_t *)"hola", 4, 3, &ids, &count, &err) == 0);
    CHECK(count == 3 && memcmp(ids, short_ids, sizeof(short_ids)) == 0);
    hf_ids_free(ids, count);
    CHECK(hf_encode(other, (const uint8_t *)"hola", 4, 0, &ids, &count, &err) == 0);
    CHECK(count == 4 && memcmp(ids, full_ids, sizeof(full_ids)) == 0);
    hf_ids_free(ids, count);
    hf_tokenizer_free(h);
    CHECK(hf_encode(other, (const uint8_t *)"hola", 4, 0, &ids, &count, &err) == 0);
    CHECK(count == 4 && memcmp(ids, full_ids, sizeof(full_ids)) == 0);
    hf_ids_free(ids, count);
    hf_tokenizer_free(other);
    hf_tokenizer_free(NULL);
    hf_ids_free(NULL, 0);
    hf_error_free(NULL);
    puts("tokenizer C ABI: null, error, UTF-8 and ownership checks passed");
    return 0;
}

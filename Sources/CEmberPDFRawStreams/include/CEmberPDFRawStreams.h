// SPDX-License-Identifier: MPL-2.0
#ifndef CEMBERPDFRAWSTREAMS_H
#define CEMBERPDFRAWSTREAMS_H

#include <stddef.h>
#include <stdint.h>
#include "CEmberPDFTagReadAuxiliary.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct EmberRawPDFContext *EmberRawPDFRef;
typedef uint64_t EmberRawPDFObject;
typedef int32_t (*EmberRawPDFCancelCallback)(void *user_data);

enum EmberRawPDFStatus {
    EMBER_RAW_PDF_OK = 0,
    EMBER_RAW_PDF_ARGUMENT = 1,
    EMBER_RAW_PDF_PARSE = 2,
    EMBER_RAW_PDF_UNSUPPORTED = 3,
    EMBER_RAW_PDF_LIMIT = 4,
    EMBER_RAW_PDF_CANCELLED = 5,
    EMBER_RAW_PDF_INTERNAL = 6
};

enum EmberRawPDFKind {
    EMBER_RAW_PDF_NULL = 0,
    EMBER_RAW_PDF_BOOLEAN = 1,
    EMBER_RAW_PDF_INTEGER = 2,
    EMBER_RAW_PDF_REAL = 3,
    EMBER_RAW_PDF_NAME = 4,
    EMBER_RAW_PDF_STRING = 5,
    EMBER_RAW_PDF_ARRAY = 6,
    EMBER_RAW_PDF_DICTIONARY = 7,
    EMBER_RAW_PDF_STREAM = 8
};

// Copies at most max_input_bytes and owns that immutable copy until destroy.
// Rejects encrypted input and parser recovery/warnings. No file is opened.
// One context must be externally serialized; different contexts may run in parallel.
// Handle zero is invalid. Nonzero handles are canonical within this context,
// including repeated indirect references and repeated direct containers.
EmberRawPDFRef ember_raw_pdf_create(const uint8_t *bytes, size_t count,
                                  size_t max_input_bytes, uint32_t max_objects,
                                  int32_t *out_status);
// Borrows an immutable, unlinked, private read-only snapshot descriptor during
// construction. A successful context owns a CLOEXEC duplicate until destroy;
// the caller always closes its own descriptor. No pathname is opened and no
// whole-file buffer is allocated. The caller must have frozen/version-checked
// the source; this API does not grant native-object provenance.
EmberRawPDFRef ember_raw_pdf_create_snapshot(int32_t snapshot_fd, size_t expected_bytes,
                                           size_t max_file_bytes, uint32_t max_objects,
                                           EmberRawPDFCancelCallback cancel, void *user_data,
                                           int32_t *out_status);
void ember_raw_pdf_destroy(EmberRawPDFRef context);
// Copies only this context's proven immutable memory input. File-backed
// contexts explicitly refuse whole-input copies. No file/parser
// is opened. Cancellation is checked per64KiB; failure returns NULL/0.
// max_bytes must not exceed the existing256MiB source ceiling.
int32_t ember_raw_pdf_input_copy(EmberRawPDFRef context, size_t max_bytes,
                                EmberRawPDFCancelCallback cancel, void *user_data,
                                uint8_t **out_bytes, size_t *out_count);
// The returned string is owned by context, valid only until its next call.
const char *ember_raw_pdf_last_error(EmberRawPDFRef context);

int32_t ember_raw_pdf_page_count(EmberRawPDFRef context, uint32_t *out_count);
int32_t ember_raw_pdf_page(EmberRawPDFRef context, uint32_t index,
                          EmberRawPDFObject *out_object);
int32_t ember_raw_pdf_catalog(EmberRawPDFRef context,
                             EmberRawPDFObject *out_object);
int32_t ember_raw_pdf_kind(EmberRawPDFRef context, EmberRawPDFObject object,
                          int32_t *out_kind);
int32_t ember_raw_pdf_boolean(EmberRawPDFRef context, EmberRawPDFObject object,
                             int32_t *out_value);
int32_t ember_raw_pdf_integer(EmberRawPDFRef context, EmberRawPDFObject object,
                             int64_t *out_value);
int32_t ember_raw_pdf_real(EmberRawPDFRef context, EmberRawPDFObject object,
                          double *out_value);

// Copies exact bytes, without UTF-8 conversion. Names and keys start with '/'
// and have PDF name escaping resolved. Strings may contain embedded NULs.
// Empty values may return a null buffer and count zero. Free every returned
// nonnull buffer exactly once with ember_raw_pdf_free.
int32_t ember_raw_pdf_name_copy(EmberRawPDFRef context, EmberRawPDFObject object,
                               uint8_t **out_bytes, size_t *out_count);
// Bounded caller buffers for signature appearance graph proofs. QPDF may
// allocate internally while obtaining a value; the owned returned buffer is
// allocated only after the explicit size ceiling succeeds.
int32_t ember_raw_pdf_bounded_scalar_copy(EmberRawPDFRef context, EmberRawPDFObject object,
                                        size_t max_bytes, uint8_t **out_bytes, size_t *out_count);
int32_t ember_raw_pdf_bounded_key_copy(EmberRawPDFRef context, EmberRawPDFObject dictionary,
                                     uint32_t index, size_t max_bytes, uint8_t **out_bytes, size_t *out_count);
// Exact typed stored numeric spelling. Reals use QPDF's retained decimal
// token, never a conversion through double; result is <=128 validated bytes.
int32_t ember_raw_pdf_number_token_copy(EmberRawPDFRef context, EmberRawPDFObject object,
                                       uint8_t **out_bytes, size_t *out_count);
// Fixed scalar proofs. A PDF empty name is exactly "/" after name escaping;
// an embedded NUL is a different byte sequence. No caller-owned name buffer
// is copied. Non-name/nonmatching values return OK/false; invalid handles use
// the ordinary error contract. Library/parser internal allocations may remain.
int32_t ember_raw_pdf_name_is_empty(EmberRawPDFRef context, EmberRawPDFObject object,
                                    int32_t *out_matches);
// Exactly two keys: /S /GoTo and /D / . Extra fields (including /Next) refuse.
int32_t ember_raw_pdf_exact_empty_goto_action(EmberRawPDFRef context,
                                             EmberRawPDFObject object,
                                             int32_t *out_matches);
int32_t ember_raw_pdf_string_copy(EmberRawPDFRef context, EmberRawPDFObject object,
                                 uint8_t **out_bytes, size_t *out_count);
// Exact inert outline-parent candidate only. Requires a direct four-member
// array whose members are literal direct null, integer0, integer0, integer1.
// Indirect arrays/null aliases, reals and all other values return false.
// Output starts false, including invalid context/handle or parser warnings.
int32_t ember_raw_pdf_exact_inert_outline_destination(EmberRawPDFRef context,
                                                     EmberRawPDFObject object,
                                                     int32_t *out_matches);
int32_t ember_raw_pdf_array_count(EmberRawPDFRef context, EmberRawPDFObject object,
                                 uint32_t *out_count);
int32_t ember_raw_pdf_array_item(EmberRawPDFRef context, EmberRawPDFObject object,
                                uint32_t index, EmberRawPDFObject *out_item);
// Validates EVERY array slot as null or Dictionary (never Stream), then copies
// the original nonnull indices in increasing order. No slot is interned, so
// null-heavy arrays consume no additional object handles. max_slots must be
// <=100000; zero permits only an empty array. Cancellation is checked before,
// after, and every256 slots. Any error returns NULL/0 and no partial indices.
// Caller must separately prove immutable source/native-array correspondence
// and retain the existing native owner/forward identity checks at these slots.
int32_t ember_raw_pdf_sparse_parent_members(EmberRawPDFRef context,
                                          EmberRawPDFObject array_object,
                                          uint32_t max_slots,
                                          EmberRawPDFCancelCallback cancel,
                                          void *user_data,
                                          uint32_t **out_indices,
                                          size_t *out_count);
void ember_raw_pdf_indices_free(uint32_t *indices);
// Enumerates explicit null entries too. Missing dictionary keys return a valid
// null object; use key enumeration when presence, not just value, matters.
int32_t ember_raw_pdf_dictionary_count(EmberRawPDFRef context, EmberRawPDFObject object,
                                      uint32_t *out_count);
int32_t ember_raw_pdf_dictionary_key_copy(EmberRawPDFRef context, EmberRawPDFObject object,
                                         uint32_t index, uint8_t **out_bytes,
                                         size_t *out_count);
int32_t ember_raw_pdf_dictionary_get(EmberRawPDFRef context, EmberRawPDFObject object,
                                    const uint8_t *key, size_t key_count,
                                    EmberRawPDFObject *out_value);
int32_t ember_raw_pdf_stream_dictionary(EmberRawPDFRef context, EmberRawPDFObject object,
                                       EmberRawPDFObject *out_dictionary);

// No decoding or re-encoding. Pipeline stops before accepting bytes beyond
// max_bytes, and cancellation is checked before/after and on every chunk.
// A nonzero callback result cancels. Failure returns no partial output.
int32_t ember_raw_pdf_stream_copy(EmberRawPDFRef context, EmberRawPDFObject object,
                                 size_t max_bytes,
                                 EmberRawPDFCancelCallback cancel,
                                 void *user_data, uint8_t **out_bytes,
                                 size_t *out_count);

// Dedicated blank-content proof only. Requires one /FlateDecode name and
// absent/null DecodeParms/F/FFilter/FDecodeParms. Both encoded and accepted
// decoded lengths must be <= max_bytes <=4096. Uses strict zlib EOF/checksum
// and rejects trailing/truncated data, warnings and cancellation. No stream
// or dictionary is changed. Caller must still apply the closed q/Q grammar.
// All output counts/pointer are0/NULL on failure. encoded_count charges the
// original bytes; aggregate proof cost is sum(max(encoded_count,decoded_count)).
int32_t ember_raw_pdf_blank_flate_copy(EmberRawPDFRef context, EmberRawPDFObject object,
                                      size_t max_bytes, EmberRawPDFCancelCallback cancel,
                                      void *user_data, uint8_t **out_bytes,
                                      size_t *out_count, size_t *out_encoded_count);
void ember_raw_pdf_free(uint8_t *bytes);

#ifdef __cplusplus
}
#endif
#endif

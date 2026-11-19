// SPDX-License-Identifier: MPL-2.0
#ifndef CEMBERPDFTAGREADAUXILIARY_H
#define CEMBERPDFTAGREADAUXILIARY_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// Disposable worker only. Does not mutate or borrow any live RawContext.
// Caller retains both descriptors, owns/removes the output, and must enforce
// process RSS/time bounds: QPDF parsing cannot poll inside every library call.
// Limits may only LOWER the fixed 128MiB/192MiB/250000 ceilings.
struct EmberTagReadAuxiliaryLimits {
    uint64_t max_input_bytes;
    uint64_t max_output_bytes;
    uint32_t max_objects;
};
struct EmberTagReadAuxiliaryReceipt {
    uint64_t input_bytes;
    uint64_t output_bytes;
    uint32_t object_count;
    uint32_t page_count;
    uint32_t tag_nodes;
    uint8_t raw_tag_graph_equivalent;
    uint8_t input_sha256[32];
    uint8_t output_sha256[32];
};
typedef int32_t (*EmberTagReadAuxiliaryCancel)(void *user_data);
enum EmberTagReadAuxiliaryStatus {
    EMBER_TAG_AUX_OK = 0,
    EMBER_TAG_AUX_ARGUMENT = 1,
    EMBER_TAG_AUX_IO = 2,
    EMBER_TAG_AUX_LIMIT = 3,
    EMBER_TAG_AUX_CANCELLED = 4,
    EMBER_TAG_AUX_PARSE_OR_WARNING = 5,
    EMBER_TAG_AUX_INPUT_CHANGED = 6,
    EMBER_TAG_AUX_UNSUPPORTED = 7,
    EMBER_TAG_AUX_INTERNAL = 8
};
// input: caller-opened read-only regular PDF descriptor, never a path.
// output: distinct, empty, caller-owned regular O_RDWR descriptor, mode0600,
// nlink1. SHA/stat are checked before/after. Failure zeroes receipt and, only
// after validating ownership, truncates partial output. Cancellation or hard
// process termination still requires caller cleanup. Receipt grants no tag,
// painting, catalog, current-state, or native-object mapping authority.
int32_t ember_tag_read_auxiliary(
    int32_t input_fd, int32_t output_fd, const uint8_t expected_input_sha256[32],
    struct EmberTagReadAuxiliaryLimits limits,
    EmberTagReadAuxiliaryCancel cancel, void *user_data,
    struct EmberTagReadAuxiliaryReceipt *out_receipt);
// Read-only process information bridge. Caller must independently establish
// and retain ownership of this exact child pid/start tuple/ppid before acting.
// Every output is zeroed and failure returns0; no signal is ever sent here.
// Self-only Mach RSS read for the helper's independent watchdog. No pid input.
int32_t ember_pdf_current_worker_resident_bytes(uint64_t *resident_bytes);
int32_t ember_pdf_read_worker_process_info(int32_t pid, uint64_t *start_sec,
    uint64_t *start_usec, int32_t *parent_pid, uint64_t *resident_bytes);
#ifdef __cplusplus
}
#endif
#endif

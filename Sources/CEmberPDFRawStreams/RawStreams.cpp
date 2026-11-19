// SPDX-License-Identifier: MPL-2.0
#include "CEmberPDFRawStreams.h"

#include <qpdf/Pipeline.hh>
#include <qpdf/QPDF.hh>
#include <qpdf/QPDFExc.hh>
#include <qpdf/QPDFObjectHandle.hh>

#include <algorithm>
#include <array>
#include <cstddef>
#include <zlib.h>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <map>
#include <memory>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace {
struct Failure : std::runtime_error {
    int32_t status;
    Failure(int32_t status, const char *message) : std::runtime_error(message), status(status) {}
};

void require(bool condition, const char *message) {
    if (!condition) throw Failure(EMBER_RAW_PDF_ARGUMENT, message);
}

class CappedPipeline final : public Pipeline {
  public:
    std::vector<uint8_t> bytes;
    int32_t failure = EMBER_RAW_PDF_OK;
    CappedPipeline(size_t limit, EmberRawPDFCancelCallback cancel, void *user)
        : Pipeline("EmberPDF bounded raw stream", nullptr), limit(limit), cancel(cancel), user(user) {}
    void check() {
        if (cancel && cancel(user)) {
            failure = EMBER_RAW_PDF_CANCELLED;
            throw Failure(failure, "Raw stream read cancelled");
        }
    }
    void write(const unsigned char *data, size_t count) override {
        check();
        if (count > limit - bytes.size()) {
            failure = EMBER_RAW_PDF_LIMIT;
            throw Failure(failure, "Raw stream exceeds byte limit");
        }
        if (count) {
            const size_t needed = bytes.size() + count;
            if (needed > bytes.capacity()) {
                const size_t doubled = bytes.capacity() > limit / 2 ? limit : bytes.capacity() * 2;
                bytes.reserve(std::max(needed, doubled));
            }
            bytes.insert(bytes.end(), data, data + count);
        }
    }
    void finish() override { check(); }
  private:
    size_t limit;
    EmberRawPDFCancelCallback cancel;
    void *user;
};

// Only the small blank-content proof uses this decoder. Never mutate qpdf's
// global Pl_Flate memory limit or its permissive general filter behaviour.
struct BlankFlateAllocationBudget {
    static constexpr size_t maximum = 128U * 1024U;
    struct alignas(std::max_align_t) Header { size_t charged; };
    size_t live = 0;
    static voidpf allocate(voidpf opaque, uInt items, uInt size) noexcept {
        auto &budget = *static_cast<BlankFlateAllocationBudget *>(opaque);
        if (size && items > (maximum - sizeof(Header)) / size) return nullptr;
        const size_t bytes = static_cast<size_t>(items) * size;
        const size_t charged = sizeof(Header) + std::max(size_t(1), bytes);
        if (charged > maximum - budget.live) return nullptr;
        auto header = static_cast<Header *>(std::malloc(charged));
        if (!header) return nullptr;
        header->charged = charged;
        budget.live += charged;
        return header + 1;
    }
    static void release(voidpf opaque, voidpf pointer) noexcept {
        if (!pointer) return;
        auto &budget = *static_cast<BlankFlateAllocationBudget *>(opaque);
        auto header = static_cast<Header *>(pointer) - 1;
        budget.live -= header->charged;
        std::free(header);
    }
};
struct BlankFlateEnd {
    z_stream &stream;
    bool active = true;
    ~BlankFlateEnd() { if (active) inflateEnd(&stream); }
};
}

struct EmberRawPDFContext {
    // QPDF's memory input borrows storage. Member order destroys QPDF first.
    std::vector<char> input;
    struct FileCloser { void operator()(FILE *file) const noexcept { if (file) std::fclose(file); } };
    std::unique_ptr<FILE, FileCloser> snapshot;
    QPDF pdf;
    uint32_t maxObjects;
    std::vector<QPDFObjectHandle> objects;
    std::map<std::pair<int, int>, EmberRawPDFObject> indirect;
    std::vector<EmberRawPDFObject> directContainers;
    std::map<EmberRawPDFObject, std::vector<std::string>> dictionaryKeys;
    char error[384] = {};
    bool rejected = false;

    EmberRawPDFContext(const uint8_t *bytes, size_t count, uint32_t maxObjects)
        : input(reinterpret_cast<const char *>(bytes), reinterpret_cast<const char *>(bytes) + count),
          maxObjects(maxObjects) {}
    explicit EmberRawPDFContext(uint32_t maxObjects) : maxObjects(maxObjects) {}

    void setError(const char *message) noexcept {
        std::snprintf(error, sizeof(error), "%s", message ? message : "Unknown native error");
    }
    void warnings() {
        if (rejected || !pdf.getWarnings().empty()) {
            rejected = true;
            throw Failure(EMBER_RAW_PDF_PARSE, "PDF parser warning; raw reuse refused");
        }
    }
    QPDFObjectHandle &object(EmberRawPDFObject handle) {
        require(handle > 0 && handle <= objects.size(), "Invalid object handle");
        return objects[static_cast<size_t>(handle - 1)];
    }
    EmberRawPDFObject intern(QPDFObjectHandle value) {
        const auto id = value.getObjGen();
        if (id.getObj() != 0) {
            auto found = indirect.find({id.getObj(), id.getGen()});
            if (found != indirect.end()) return found->second;
        } else if (value.isArray() || value.isDictionary() || value.isStream()) {
            for (auto candidate : directContainers) {
                if (object(candidate).isSameObjectAs(value)) return candidate;
            }
        }
        if (objects.size() >= maxObjects) throw Failure(EMBER_RAW_PDF_LIMIT, "Object handle limit reached");
        objects.push_back(value);
        auto handle = static_cast<EmberRawPDFObject>(objects.size());
        if (id.getObj() != 0) indirect.emplace(std::make_pair(id.getObj(), id.getGen()), handle);
        else if (value.isArray() || value.isDictionary() || value.isStream()) directContainers.push_back(handle);
        return handle;
    }
    const std::vector<std::string> &keys(EmberRawPDFObject handle) {
        auto &value = object(handle);
        require(value.isDictionary(), "Expected dictionary");
        auto found = dictionaryKeys.find(handle);
        if (found != dictionaryKeys.end()) return found->second;
        // getKeys() omits explicit null entries, which would weaken pairing.
        auto dictionary = value.getDictAsMap();
        if (dictionary.size() > maxObjects) throw Failure(EMBER_RAW_PDF_LIMIT, "Dictionary entry limit reached");
        std::vector<std::string> result;
        result.reserve(dictionary.size());
        for (const auto &entry : dictionary) result.push_back(entry.first);
        return dictionaryKeys.emplace(handle, std::move(result)).first->second;
    }
};

namespace {
template <typename Operation> int32_t call(EmberRawPDFRef context, Operation operation) noexcept {
    if (!context) return EMBER_RAW_PDF_ARGUMENT;
    context->error[0] = 0;
    try {
        context->warnings();
        operation();
        context->warnings();
        return EMBER_RAW_PDF_OK;
    } catch (const Failure &e) {
        context->setError(e.what());
        return e.status;
    } catch (const QPDFExc &e) {
        context->rejected = true;
        context->setError(e.what());
        return EMBER_RAW_PDF_PARSE;
    } catch (const std::bad_alloc &) {
        context->setError("Native allocation failed");
        return EMBER_RAW_PDF_LIMIT;
    } catch (const std::exception &e) {
        context->setError(e.what());
        return EMBER_RAW_PDF_INTERNAL;
    } catch (...) {
        context->setError("Unknown native exception");
        return EMBER_RAW_PDF_INTERNAL;
    }
}

void copyBytes(const uint8_t *bytes, size_t count, uint8_t **out, size_t *outCount) {
    require(out && outCount, "Missing output pointer");
    if (count) {
        auto result = static_cast<uint8_t *>(std::malloc(count));
        if (!result) throw std::bad_alloc();
        std::memcpy(result, bytes, count);
        *out = result;
    }
    *outCount = count;
}

template <typename Operation> int32_t bufferCall(EmberRawPDFRef c, uint8_t **out, size_t *count,
                                               Operation operation) noexcept {
    if (out) *out = nullptr;
    if (count) *count = 0;
    auto status = call(c, operation);
    if (status != EMBER_RAW_PDF_OK) {
        if (out) { std::free(*out); *out = nullptr; }
        if (count) *count = 0;
    }
    return status;
}

int32_t kind(QPDFObjectHandle value) {
    if (value.isNull()) return EMBER_RAW_PDF_NULL;
    if (value.isBool()) return EMBER_RAW_PDF_BOOLEAN;
    if (value.isInteger()) return EMBER_RAW_PDF_INTEGER;
    if (value.isReal()) return EMBER_RAW_PDF_REAL;
    if (value.isName()) return EMBER_RAW_PDF_NAME;
    if (value.isString()) return EMBER_RAW_PDF_STRING;
    if (value.isArray()) return EMBER_RAW_PDF_ARRAY;
    if (value.isDictionary()) return EMBER_RAW_PDF_DICTIONARY;
    if (value.isStream()) return EMBER_RAW_PDF_STREAM;
    throw Failure(EMBER_RAW_PDF_UNSUPPORTED, "Unsupported PDF object type");
}
}

extern "C" {
EmberRawPDFRef ember_raw_pdf_create(const uint8_t *bytes, size_t count, size_t maxInputBytes,
                                  uint32_t maxObjects, int32_t *outStatus) {
    if (outStatus) *outStatus = EMBER_RAW_PDF_ARGUMENT;
    if (!bytes || !count || !maxObjects || !outStatus) return nullptr;
    if (count > maxInputBytes) { *outStatus = EMBER_RAW_PDF_LIMIT; return nullptr; }
    try {
        auto context = std::make_unique<EmberRawPDFContext>(bytes, count, maxObjects);
        context->pdf.setAttemptRecovery(false);
        context->pdf.setSuppressWarnings(true);
        context->pdf.setMaxWarnings(1);
        context->pdf.processMemoryFile("EmberPDF immutable source", context->input.data(), context->input.size());
        if (context->pdf.isEncrypted()) {
            *outStatus = EMBER_RAW_PDF_UNSUPPORTED;
            return nullptr;
        }
        context->warnings();
        *outStatus = EMBER_RAW_PDF_OK;
        return context.release();
    } catch (const Failure &e) { *outStatus = e.status; }
      catch (const std::bad_alloc &) { *outStatus = EMBER_RAW_PDF_LIMIT; }
      catch (const QPDFExc &) { *outStatus = EMBER_RAW_PDF_PARSE; }
      catch (...) { *outStatus = EMBER_RAW_PDF_INTERNAL; }
    return nullptr;
}
EmberRawPDFRef ember_raw_pdf_create_snapshot(int32_t fd, size_t expectedBytes,
        size_t maximum, uint32_t maxObjects, EmberRawPDFCancelCallback cancel,
        void *user, int32_t *outStatus) {
    if (outStatus) *outStatus = EMBER_RAW_PDF_ARGUMENT;
    if (!outStatus || fd < 0 || !expectedBytes || !maxObjects || !maximum
        || maximum > size_t(1024) * 1024 * 1024) return nullptr;
    try {
        if (expectedBytes > maximum) throw Failure(EMBER_RAW_PDF_LIMIT, "File input exceeds limit");
        if (cancel && cancel(user)) throw Failure(EMBER_RAW_PDF_CANCELLED, "File input cancelled");
        struct stat identity{};
        int flags = fcntl(fd, F_GETFL);
        require(flags >= 0 && (flags & O_ACCMODE) == O_RDONLY && fstat(fd, &identity) == 0,
                "Read-only snapshot required");
        require(S_ISREG(identity.st_mode) && identity.st_uid == geteuid()
                && (identity.st_mode & 07777) == 0600 && identity.st_nlink == 0
                && identity.st_size > 0 && static_cast<uint64_t>(identity.st_size) == expectedBytes,
                "Private unlinked snapshot required");
        auto context = std::make_unique<EmberRawPDFContext>(maxObjects);
        int duplicate = fcntl(fd, F_DUPFD_CLOEXEC, 0);
        if (duplicate < 0) throw Failure(EMBER_RAW_PDF_INTERNAL, "Snapshot descriptor unavailable");
        FILE *file = fdopen(duplicate, "rb");
        if (!file) { close(duplicate); throw Failure(EMBER_RAW_PDF_INTERNAL, "Snapshot stream unavailable"); }
        context->snapshot.reset(file);
        context->pdf.setAttemptRecovery(false);
        context->pdf.setSuppressWarnings(true);
        context->pdf.setMaxWarnings(1);
        context->pdf.processFile("EmberPDF immutable file snapshot", file, false);
        if (cancel && cancel(user)) throw Failure(EMBER_RAW_PDF_CANCELLED, "File input cancelled");
        if (context->pdf.isEncrypted()) throw Failure(EMBER_RAW_PDF_UNSUPPORTED, "Encrypted input refused");
        context->warnings();
        if (context->pdf.getXRefTable().size() > maxObjects)
            throw Failure(EMBER_RAW_PDF_LIMIT, "File object limit reached");
        context->warnings();
        *outStatus = EMBER_RAW_PDF_OK;
        return context.release();
    } catch (const Failure &e) { *outStatus = e.status; }
      catch (const std::bad_alloc &) { *outStatus = EMBER_RAW_PDF_LIMIT; }
      catch (const QPDFExc &) { *outStatus = EMBER_RAW_PDF_PARSE; }
      catch (...) { *outStatus = EMBER_RAW_PDF_INTERNAL; }
    return nullptr;
}
void ember_raw_pdf_destroy(EmberRawPDFRef context) { delete context; }
int32_t ember_raw_pdf_input_copy(EmberRawPDFRef c, size_t maximum,
                                EmberRawPDFCancelCallback cancel, void *user,
                                uint8_t **out, size_t *count) {
    return bufferCall(c, out, count, [&] {
        require(out && count && maximum <= 256U * 1024U * 1024U, "Invalid input copy limit");
        if (c->snapshot) throw Failure(EMBER_RAW_PDF_LIMIT, "File input does not permit whole-input copies");
        if (c->input.size() > maximum) throw Failure(EMBER_RAW_PDF_LIMIT, "Input copy exceeds limit");
        if (cancel && cancel(user)) throw Failure(EMBER_RAW_PDF_CANCELLED, "Input copy cancelled");
        auto result = static_cast<uint8_t *>(std::malloc(c->input.size()));
        if (!result) throw std::bad_alloc();
        *out = result;
        for (size_t offset = 0; offset < c->input.size(); offset += 65536) {
            if (cancel && cancel(user)) throw Failure(EMBER_RAW_PDF_CANCELLED, "Input copy cancelled");
            const size_t length = std::min(size_t(65536), c->input.size() - offset);
            std::memcpy(result + offset, c->input.data() + offset, length);
        }
        if (cancel && cancel(user)) throw Failure(EMBER_RAW_PDF_CANCELLED, "Input copy cancelled");
        *count = c->input.size();
    });
}
const char *ember_raw_pdf_last_error(EmberRawPDFRef context) {
    return context ? context->error : "Invalid context";
}
void ember_raw_pdf_free(uint8_t *bytes) { std::free(bytes); }
void ember_raw_pdf_indices_free(uint32_t *indices) { std::free(indices); }

int32_t ember_raw_pdf_page_count(EmberRawPDFRef c, uint32_t *out) {
    if (out) *out = 0;
    return call(c, [&] {
        require(out, "Missing page count");
        const auto &pages = c->pdf.getAllPages();
        if (pages.size() > c->maxObjects) throw Failure(EMBER_RAW_PDF_LIMIT, "Page limit reached");
        *out = static_cast<uint32_t>(pages.size());
    });
}
int32_t ember_raw_pdf_page(EmberRawPDFRef c, uint32_t index, EmberRawPDFObject *out) {
    if (out) *out = 0;
    return call(c, [&] {
        require(out, "Missing page handle");
        const auto &pages = c->pdf.getAllPages();
        require(index < pages.size(), "Page index out of range");
        *out = c->intern(pages[index]);
    });
}
int32_t ember_raw_pdf_catalog(EmberRawPDFRef c, EmberRawPDFObject *out) {
    if (out) *out = 0;
    return call(c, [&] {
        require(out, "Missing catalog handle");
        auto root = c->pdf.getRoot();
        if (!root.isDictionary()) throw Failure(EMBER_RAW_PDF_PARSE, "Invalid catalog");
        *out = c->intern(root);
    });
}
int32_t ember_raw_pdf_kind(EmberRawPDFRef c, EmberRawPDFObject object, int32_t *out) {
    if (out) *out = EMBER_RAW_PDF_NULL;
    return call(c, [&] { require(out, "Missing kind"); *out = kind(c->object(object)); });
}
int32_t ember_raw_pdf_boolean(EmberRawPDFRef c, EmberRawPDFObject object, int32_t *out) {
    if (out) *out = 0;
    return call(c, [&] {
        require(out, "Missing boolean"); auto value = c->object(object);
        require(value.isBool(), "Expected boolean"); *out = value.getBoolValue() ? 1 : 0;
    });
}
int32_t ember_raw_pdf_integer(EmberRawPDFRef c, EmberRawPDFObject object, int64_t *out) {
    if (out) *out = 0;
    return call(c, [&] {
        require(out, "Missing integer"); auto value = c->object(object);
        require(value.isInteger(), "Expected integer"); *out = value.getIntValue();
    });
}
int32_t ember_raw_pdf_real(EmberRawPDFRef c, EmberRawPDFObject object, double *out) {
    if (out) *out = 0;
    return call(c, [&] {
        require(out, "Missing real"); auto value = c->object(object);
        require(value.isReal(), "Expected real");
        double number = value.getNumericValue();
        if (!std::isfinite(number)) throw Failure(EMBER_RAW_PDF_UNSUPPORTED, "Non-finite real");
        *out = number;
    });
}
int32_t ember_raw_pdf_name_copy(EmberRawPDFRef c, EmberRawPDFObject object, uint8_t **out, size_t *count) {
    return bufferCall(c, out, count, [&] {
        auto value = c->object(object); require(value.isName(), "Expected name");
        auto bytes = value.getName(); copyBytes(reinterpret_cast<const uint8_t *>(bytes.data()), bytes.size(), out, count);
    });
}
int32_t ember_raw_pdf_bounded_scalar_copy(EmberRawPDFRef c, EmberRawPDFObject object,
                                        size_t maximum, uint8_t **out, size_t *count) {
    return bufferCall(c, out, count, [&] {
        require(maximum <= 65536, "Invalid scalar copy ceiling");
        auto value = c->object(object);
        require(value.isName() || value.isString(), "Expected name or string");
        auto bytes = value.isName() ? value.getName() : value.getStringValue();
        if (bytes.size() > maximum) throw Failure(EMBER_RAW_PDF_LIMIT, "Scalar exceeds copy ceiling");
        copyBytes(reinterpret_cast<const uint8_t *>(bytes.data()), bytes.size(), out, count);
    });
}
int32_t ember_raw_pdf_bounded_key_copy(EmberRawPDFRef c, EmberRawPDFObject object,
                                     uint32_t index, size_t maximum, uint8_t **out, size_t *count) {
    return bufferCall(c, out, count, [&] {
        require(maximum <= 4096, "Invalid key copy ceiling");
        const auto &keys = c->keys(object);
        require(index < keys.size(), "Invalid key index");
        const auto &bytes = keys[index];
        if (bytes.size() > maximum) throw Failure(EMBER_RAW_PDF_LIMIT, "Key exceeds copy ceiling");
        copyBytes(reinterpret_cast<const uint8_t *>(bytes.data()), bytes.size(), out, count);
    });
}
int32_t ember_raw_pdf_number_token_copy(EmberRawPDFRef c, EmberRawPDFObject object,
                                       uint8_t **out, size_t *count) {
    return bufferCall(c, out, count, [&] {
        auto value = c->object(object);
        require(value.isInteger() || value.isReal(), "Expected stored number");
        std::string token;
        if (value.isInteger()) {
            long long integer = 0;
            require(value.getValueAsInt(integer), "Stored integer exceeds exact range");
            token = std::to_string(integer);
        } else token = value.getRealValue();
        if (token.empty() || token.size() > 128) throw Failure(EMBER_RAW_PDF_LIMIT, "Number token exceeds ceiling");
        bool digit = false, dot = false;
        for (size_t i = 0; i < token.size(); ++i) {
            const char ch = token[i];
            if (ch >= '0' && ch <= '9') digit = true;
            else if (ch == '.' && !dot && value.isReal()) dot = true;
            else if ((ch == '+' || ch == '-') && i == 0) {}
            else throw Failure(EMBER_RAW_PDF_UNSUPPORTED, "Invalid stored number spelling");
        }
        require(digit && (value.isInteger() || dot), "Invalid stored decimal token");
        copyBytes(reinterpret_cast<const uint8_t *>(token.data()), token.size(), out, count);
    });
}
int32_t ember_raw_pdf_name_is_empty(EmberRawPDFRef c, EmberRawPDFObject object, int32_t *out) {
    if (out) *out = 0;
    return call(c, [&] {
        require(out, "Missing empty-name result");
        *out = c->object(object).isNameAndEquals("/") ? 1 : 0;
    });
}
int32_t ember_raw_pdf_exact_empty_goto_action(EmberRawPDFRef c, EmberRawPDFObject object, int32_t *out) {
    if (out) *out = 0;
    return call(c, [&] {
        require(out, "Missing empty-action result");
        auto action = c->object(object);
        if (action.isDictionary() && c->keys(object).size() == 2 &&
            action.getKey("/S").isNameAndEquals("/GoTo") &&
            action.getKey("/D").isNameAndEquals("/")) {
            *out = 1;
        }
    });
}
int32_t ember_raw_pdf_string_copy(EmberRawPDFRef c, EmberRawPDFObject object, uint8_t **out, size_t *count) {
    return bufferCall(c, out, count, [&] {
        auto value = c->object(object); require(value.isString(), "Expected string");
        auto bytes = value.getStringValue(); copyBytes(reinterpret_cast<const uint8_t *>(bytes.data()), bytes.size(), out, count);
    });
}
int32_t ember_raw_pdf_exact_inert_outline_destination(EmberRawPDFRef c, EmberRawPDFObject object, int32_t *out) {
    if (out) *out = 0;
    auto status = call(c, [&] {
        require(out, "Missing output pointer");
        auto &value = c->object(object);
        if (value.isIndirect() || !value.isArray() || value.getArrayNItems() != 4) return;
        auto head = value.getArrayItem(0);
        if (head.isIndirect() || !head.isNull()) return;
        for (int i = 1; i < 4; ++i) {
            auto item = value.getArrayItem(i);
            if (item.isIndirect() || !item.isInteger() || item.getIntValue() != (i == 3 ? 1 : 0)) return;
        }
        *out = 1;
    });
    if (status != EMBER_RAW_PDF_OK && out) *out = 0;
    return status;
}

int32_t ember_raw_pdf_array_count(EmberRawPDFRef c, EmberRawPDFObject object, uint32_t *out) {
    if (out) *out = 0;
    return call(c, [&] {
        require(out, "Missing array count"); auto value = c->object(object);
        require(value.isArray(), "Expected array");
        auto count = value.getArrayNItems();
        if (count < 0 || static_cast<uint64_t>(count) > c->maxObjects)
            throw Failure(EMBER_RAW_PDF_LIMIT, "Array item limit reached");
        *out = static_cast<uint32_t>(count);
    });
}
int32_t ember_raw_pdf_array_item(EmberRawPDFRef c, EmberRawPDFObject object, uint32_t index, EmberRawPDFObject *out) {
    if (out) *out = 0;
    return call(c, [&] {
        require(out, "Missing array item"); auto value = c->object(object);
        require(value.isArray() && index < static_cast<uint64_t>(value.getArrayNItems()), "Invalid array index");
        *out = c->intern(value.getArrayItem(static_cast<int>(index)));
    });
}
int32_t ember_raw_pdf_sparse_parent_members(EmberRawPDFRef c, EmberRawPDFObject object,
                                          uint32_t maxSlots, EmberRawPDFCancelCallback cancel,
                                          void *user, uint32_t **out, size_t *outCount) {
    if (out) *out = nullptr;
    if (outCount) *outCount = 0;
    auto status = call(c, [&] {
        require(out && outCount, "Missing parent member output");
        require(maxSlots <= 100000, "Parent slot limit exceeds supported maximum");
        auto checkpoint = [&] {
            if (cancel && cancel(user)) throw Failure(EMBER_RAW_PDF_CANCELLED, "Parent scan cancelled");
            c->warnings();
        };
        checkpoint();
        auto array = c->object(object);
        require(array.isArray(), "Expected parent array");
        auto count = array.getArrayNItems();
        if (count < 0 || static_cast<uint64_t>(count) > maxSlots)
            throw Failure(EMBER_RAW_PDF_LIMIT, "Parent array exceeds slot limit");
        if (static_cast<uint64_t>(count) > std::numeric_limits<size_t>::max() / sizeof(QPDFObjectHandle))
            throw Failure(EMBER_RAW_PDF_LIMIT, "Parent slot vector exceeds byte limit");
        // qpdf's public vector copy is bounded by100000 slots. It reuses its
        // existing null handles; getArrayItem may allocate a fresh null handle
        // for every sparse hole. This exposes no private parser structures.
        const auto slots = array.getArrayAsVector();
        if (slots.size() != static_cast<size_t>(count))
            throw Failure(EMBER_RAW_PDF_PARSE, "Parent slot vector length mismatch");
        checkpoint();
        std::vector<uint32_t> indices;
        for (int index = 0; index < count; ++index) {
            if ((index & 255) == 0) checkpoint();
            // Inspect every slot; skipping null runs could hide malformed data.
            // Never intern an item, including nulls or dictionary owners.
            const auto &item = slots[static_cast<size_t>(index)];
            if (item.isNull()) continue;
            if (item.isStream() || !item.isDictionary())
                throw Failure(EMBER_RAW_PDF_UNSUPPORTED, "Parent array contains a non-dictionary slot");
            if (indices.size() == indices.capacity()) {
                const auto grown = std::max<size_t>(16, indices.capacity() * 2);
                indices.reserve(std::min<size_t>(static_cast<size_t>(count), grown));
            }
            indices.push_back(static_cast<uint32_t>(index));
        }
        checkpoint();
        if (!indices.empty()) {
            if (indices.size() > maxSlots || indices.size() > std::numeric_limits<size_t>::max() / sizeof(uint32_t))
                throw Failure(EMBER_RAW_PDF_LIMIT, "Parent index output exceeds byte limit");
            const size_t bytes = indices.size() * sizeof(uint32_t);
            auto result = static_cast<uint32_t *>(std::malloc(bytes));
            if (!result) throw std::bad_alloc();
            std::memcpy(result, indices.data(), bytes);
            *out = result;
        }
        *outCount = indices.size();
        checkpoint();
    });
    if (status != EMBER_RAW_PDF_OK) {
        if (out) { std::free(*out); *out = nullptr; }
        if (outCount) *outCount = 0;
    }
    return status;
}
int32_t ember_raw_pdf_dictionary_count(EmberRawPDFRef c, EmberRawPDFObject object, uint32_t *out) {
    if (out) *out = 0;
    return call(c, [&] { require(out, "Missing dictionary count"); *out = static_cast<uint32_t>(c->keys(object).size()); });
}
int32_t ember_raw_pdf_dictionary_key_copy(EmberRawPDFRef c, EmberRawPDFObject object, uint32_t index,
                                         uint8_t **out, size_t *count) {
    return bufferCall(c, out, count, [&] {
        const auto &keys = c->keys(object); require(index < keys.size(), "Invalid dictionary index");
        const auto &bytes = keys[index]; copyBytes(reinterpret_cast<const uint8_t *>(bytes.data()), bytes.size(), out, count);
    });
}
int32_t ember_raw_pdf_dictionary_get(EmberRawPDFRef c, EmberRawPDFObject object, const uint8_t *key,
                                    size_t keyCount, EmberRawPDFObject *out) {
    if (out) *out = 0;
    return call(c, [&] {
        require(out && key && keyCount > 0 && key[0] == '/', "Invalid dictionary key");
        auto value = c->object(object); require(value.isDictionary(), "Expected dictionary");
        *out = c->intern(value.getKey(std::string(reinterpret_cast<const char *>(key), keyCount)));
    });
}
int32_t ember_raw_pdf_stream_dictionary(EmberRawPDFRef c, EmberRawPDFObject object, EmberRawPDFObject *out) {
    if (out) *out = 0;
    return call(c, [&] {
        require(out, "Missing stream dictionary"); auto value = c->object(object);
        require(value.isStream(), "Expected stream"); *out = c->intern(value.getDict());
    });
}
int32_t ember_raw_pdf_stream_copy(EmberRawPDFRef c, EmberRawPDFObject object, size_t maxBytes,
                                 EmberRawPDFCancelCallback cancel, void *user, uint8_t **out, size_t *count) {
    return bufferCall(c, out, count, [&] {
        require(out && count, "Missing stream output"); auto value = c->object(object);
        require(value.isStream(), "Expected stream");
        // qpdf 12.4.1's memory input reads the full declared stream before
        // calling Pipeline::write. Reject its resolved length before that read;
        // the Pipeline cap alone would bound output but not this allocation.
        auto length = value.getDict().getKey("/Length");
        if (!length.isInteger() || length.getIntValue() < 0)
            throw Failure(EMBER_RAW_PDF_UNSUPPORTED, "Invalid raw stream length");
        if (static_cast<uint64_t>(length.getIntValue()) > maxBytes)
            throw Failure(EMBER_RAW_PDF_LIMIT, "Raw stream exceeds byte limit");
        c->warnings();
        CappedPipeline pipeline(maxBytes, cancel, user);
        pipeline.check();
        bool filteringAttempted = false;
        // Per-call suppression skips recording warnings too. Suppress only
        // stderr at the QPDF context level, so every read warning rejects reuse.
        bool success = false;
        try {
            success = value.pipeStreamData(&pipeline, &filteringAttempted, 0, qpdf_dl_none, false, false);
        } catch (...) {
            if (pipeline.failure != EMBER_RAW_PDF_OK)
                throw Failure(pipeline.failure, "Bounded raw stream read interrupted");
            throw;
        }
        if (pipeline.failure != EMBER_RAW_PDF_OK) throw Failure(pipeline.failure, "Bounded raw stream read interrupted");
        pipeline.check();
        // qpdf reports an empty stream as filterable even at qpdf_dl_none.
        // Accept that flag only when the actual bounded read proved zero
        // bytes and no filter, parameters or external-file control is present.
        bool emptyUnfiltered = length.getIntValue() == 0 && pipeline.bytes.empty();
        for (const char *key : {"/Filter", "/DecodeParms", "/F", "/FFilter", "/FDecodeParms"})
            emptyUnfiltered = emptyUnfiltered && value.getDict().getKey(key).isNull();
        if (!success || (filteringAttempted && !emptyUnfiltered) ||
            pipeline.bytes.size() != static_cast<uint64_t>(length.getIntValue()))
            throw Failure(EMBER_RAW_PDF_PARSE, "Raw stream read failed");
        c->warnings();
        copyBytes(pipeline.bytes.data(), pipeline.bytes.size(), out, count);
    });
}

int32_t ember_raw_pdf_blank_flate_copy(EmberRawPDFRef c, EmberRawPDFObject object,
                                      size_t maximum, EmberRawPDFCancelCallback cancel,
                                      void *user, uint8_t **out, size_t *count,
                                      size_t *encodedCount) {
    if (encodedCount) *encodedCount = 0;
    const auto status = bufferCall(c, out, count, [&] {
        require(out && count && encodedCount && maximum <= 4096,
                "Invalid blank Flate proof limit");
        auto value = c->object(object);
        require(value.isStream(), "Expected blank proof stream");
        auto dictionary = value.getDict();
        if (!dictionary.getKey("/Filter").isNameAndEquals("/FlateDecode"))
            throw Failure(EMBER_RAW_PDF_UNSUPPORTED, "Blank proof requires one FlateDecode filter");
        for (const char *key : {"/DecodeParms", "/F", "/FFilter", "/FDecodeParms"})
            if (!dictionary.getKey(key).isNull())
                throw Failure(EMBER_RAW_PDF_UNSUPPORTED, "Blank proof parameters/external file refused");
        if (cancel && cancel(user)) throw Failure(EMBER_RAW_PDF_CANCELLED, "Blank proof cancelled");

        // Keep the general API byte-exact. Its qpdf_dl_none read checks the
        // resolved Length before allocation, actual encoded byte count,
        // warnings and cancellation through the existing CappedPipeline.
        uint8_t *raw = nullptr;
        size_t rawCount = 0;
        const int32_t rawStatus = ember_raw_pdf_stream_copy(c, object, maximum, cancel, user,
                                                          &raw, &rawCount);
        std::unique_ptr<uint8_t, decltype(&std::free)> encoded(raw, &std::free);
        if (rawStatus != EMBER_RAW_PDF_OK)
            throw Failure(rawStatus, "Bounded encoded blank proof read refused");
        if (rawCount > maximum || !rawCount || !raw)
            throw Failure(EMBER_RAW_PDF_PARSE, "Invalid encoded blank proof bytes");
        if (cancel && cancel(user)) throw Failure(EMBER_RAW_PDF_CANCELLED, "Blank proof cancelled");

        // qpdf12.4.1 Pl_Flate deliberately accepts an incorrect Adler checksum.
        // A local zlib stream instead requires a complete valid zlib member,
        // with no trailing member/bytes or repair. One fixed extra output byte
        // detects overflow; at most4096 decoded bytes can ever be published.
        std::array<uint8_t, 4097> decoded{};
        BlankFlateAllocationBudget memory;
        z_stream stream{};
        stream.zalloc = BlankFlateAllocationBudget::allocate;
        stream.zfree = BlankFlateAllocationBudget::release;
        stream.opaque = &memory;
        const int initialized = inflateInit(&stream);
        if (initialized != Z_OK)
            throw Failure(initialized == Z_MEM_ERROR ? EMBER_RAW_PDF_LIMIT : EMBER_RAW_PDF_PARSE,
                          "Blank proof inflate initialization refused");
        BlankFlateEnd cleanup{stream};
        stream.next_in = encoded.get();
        stream.avail_in = static_cast<uInt>(rawCount);
        stream.next_out = decoded.data();
        stream.avail_out = static_cast<uInt>(maximum + 1);
        const int inflated = inflate(&stream, Z_FINISH);
        if (cancel && cancel(user)) throw Failure(EMBER_RAW_PDF_CANCELLED, "Blank proof cancelled");
        if (stream.total_out > maximum)
            throw Failure(EMBER_RAW_PDF_LIMIT, "Decoded blank proof exceeds limit");
        if (inflated != Z_STREAM_END || stream.total_in != rawCount || stream.avail_in != 0)
            throw Failure(inflated == Z_MEM_ERROR ? EMBER_RAW_PDF_LIMIT : EMBER_RAW_PDF_PARSE,
                          "Invalid, truncated or trailing blank proof Flate data");
        const size_t decodedCount = static_cast<size_t>(stream.total_out);
        const int ended = inflateEnd(&stream);
        cleanup.active = false;
        if (ended != Z_OK || memory.live != 0)
            throw Failure(EMBER_RAW_PDF_PARSE, "Blank proof inflate cleanup refused");
        if (cancel && cancel(user)) throw Failure(EMBER_RAW_PDF_CANCELLED, "Blank proof cancelled");
        c->warnings();
        copyBytes(decoded.data(), decodedCount, out, count);
        *encodedCount = rawCount;
    });
    if (status != EMBER_RAW_PDF_OK && encodedCount) *encodedCount = 0;
    return status;
}
}

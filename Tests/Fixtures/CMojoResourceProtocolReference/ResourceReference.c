#include "ResourceReference.h"
#include <stdint.h>

static uint64_t little(const uint8_t *p, unsigned width) {
    uint64_t v = 0;
    for (unsigned i = width; i > 0; --i) v = (v << 8) | p[i - 1];
    return v;
}

/* Independent test oracle. It reads canonical bytes directly and never uses
 * Swift descriptor construction or its derived extent. No pointer escapes. */
int swmo_reference_buffer_end(
    const uint8_t *b, size_t n, uint16_t maximum_rank,
    uint64_t maximum_region_bytes, int allows_empty, uint64_t *end
) {
    static const unsigned widths[] = {0,1,1,2,2,4,4,8,8,2,4,8};
    if (!b || !end || n < 40) return 0;
    unsigned storage = (unsigned)little(b, 2);
    unsigned type = (unsigned)little(b + 2, 2);
    unsigned rank = (unsigned)little(b + 4, 2);
    if (storage < 1 || storage > 3 || type < 1 || type > 11 ||
        rank > maximum_rank || n < 40 + (size_t)rank * 16 ||
        little(b + 6, 2) || little(b + 12, 4)) return 0;
    uint64_t ordinal = little(b + 8, 4);
    uint64_t region = little(b + 16, 8);
    uint64_t offset = little(b + 24, 8);
    uint64_t payload = little(b + 32, 8);
    unsigned width = widths[type];
    if (region > maximum_region_bytes || offset > region || offset % width) return 0;
    if (storage == 1) {
        if (ordinal != UINT32_MAX || payload % width) return 0;
    } else if (ordinal == UINT32_MAX || payload != 0) return 0;
    int empty = 0;
    for (unsigned i = 0; i < rank; ++i)
        if (little(b + 40 + i * 16, 8) == 0) empty = 1;
    if (empty) {
        if (!allows_empty) return 0;
        *end = offset;
        return 1;
    }
    uint64_t extent = offset;
    for (unsigned i = 0; i < rank; ++i) {
        uint64_t dimension = little(b + 40 + i * 16, 8);
        uint64_t stride = little(b + 48 + i * 16, 8);
        if (!stride || (dimension > 1 && stride % width)) return 0;
        uint64_t steps = dimension - 1;
        if (steps && stride > UINT64_MAX / steps) return 0;
        uint64_t distance = steps * stride;
        if (distance > UINT64_MAX - extent) return 0;
        extent += distance;
    }
    if (width > UINT64_MAX - extent) return 0;
    extent += width;
    if (extent > region) return 0;
    *end = extent;
    return 1;
}

int swmo_reference_invocation(const uint8_t *b, size_t n,
                              uint64_t *copied, uint64_t *mapped) {
    static const unsigned widths[] = {0,1,1,2,2,4,4,8,8,2,4,8};
    if (!b || !copied || !mapped || n < 48 || n > 1024 || !little(b, 8)) return 0;
    uint64_t args = little(b + 40, 4);
    unsigned inputs = (unsigned)little(b + 44, 2);
    unsigned outputs = (unsigned)little(b + 46, 2);
    if (inputs > 4 || outputs > 4 || args > 64) return 0;
    uint64_t regions[4] = {0};
    unsigned kinds[4] = {0};
    uint64_t copied_end = 0, mapped_bytes = 0;
    size_t offset = 48;
    for (unsigned i = 0; i < inputs; ++i) {
        uint64_t view_end;
        if (!swmo_reference_buffer_end(b + offset, n - offset, 4, 8000000, 1, &view_end)) return 0;
        const uint8_t *d = b + offset;
        unsigned kind = (unsigned)little(d, 2);
        unsigned ordinal = (unsigned)little(d + 8, 4);
        uint64_t region = little(d + 16, 8);
        if (kind == 1) {
            uint64_t payload = little(d + 32, 8);
            if (payload > UINT64_MAX - region) return 0;
            if (copied_end < payload + region) copied_end = payload + region;
        } else {
            if (ordinal >= inputs) return 0;
            if (kinds[ordinal]) {
                if (kinds[ordinal] != kind || regions[ordinal] != region) return 0;
            } else {
                kinds[ordinal] = kind;
                regions[ordinal] = region;
                mapped_bytes += region;
            }
        }
        offset += 40 + (size_t)little(d + 4, 2) * 16;
    }
    unsigned handle_count = 0;
    for (unsigned i = 0; i < inputs; ++i) if (kinds[i]) ++handle_count;
    for (unsigned i = 0; i < handle_count; ++i) if (!kinds[i]) return 0;
    uint64_t result_bytes = 0;
    for (unsigned i = 0; i < outputs; ++i) {
        if (n - offset < 12) return 0;
        unsigned type = (unsigned)little(b + offset, 2);
        uint64_t count = little(b + offset + 4, 8);
        if (type < 1 || type > 11 || little(b + offset + 2, 2)) return 0;
        if (count > 1024 / widths[type]) return 0;
        result_bytes += count * widths[type];
        offset += 12;
    }
    if (n - offset != args || copied_end > 8000000 || mapped_bytes > 8000000 || result_bytes + 44 + outputs * 8 + 64 > 1024) return 0;
    *copied = copied_end;
    *mapped = mapped_bytes;
    return 1;
}

int swmo_reference_result(const uint8_t *b, size_t n, uint64_t *body) {
    if (!b || !body || n < 44 || n > 1024) return 0;
    for (unsigned i = 0; i < 32; ++i) if (b[4 + i] != i) return 0;
    uint64_t status = little(b, 4);
    uint64_t values = little(b + 36, 4);
    unsigned outputs = (unsigned)little(b + 40, 2);
    if (little(b + 42, 2) || values > 64 || outputs > 4 ||
        n != 44 + outputs * 8 + values) return 0;
    if (status) {
        if (values || outputs) return 0;
        *body = 0;
        return 1;
    }
    if (outputs != 1) return 0;
    uint64_t count = little(b + 44, 8);
    if (count > 10 || n + count * 8 > 1024) return 0;
    *body = count * 8;
    return 1;
}

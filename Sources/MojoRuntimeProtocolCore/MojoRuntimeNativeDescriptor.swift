/// C-side descriptor admission emitted into the worker from the wire owner.
package enum MojoRuntimeNativeDescriptor {
    package static let source = #"""
    #include <stddef.h>
    #include <stdint.h>

    typedef struct {
        uint16_t storage, element, rank;
        uint32_t ordinal;
        uint64_t region, offset, payload_offset, addressed_end;
        int empty;
    } swmo_buffer_view;

    static uint64_t swmo_descriptor_integer(const uint8_t *p, size_t width) {
        uint64_t value = 0;
        for (size_t i = 0; i < width; ++i) value |= (uint64_t)p[i] << (8u * i);
        return value;
    }

    /* Caller owns view and layout arrays with verified_rank entries. No pointer
     * escapes. Output is usable only on zero status; no mapping occurs here. */
    static int swmo_descriptor(
        const uint8_t *wire, size_t count, uint16_t verified_element,
        uint16_t verified_rank, uint64_t maximum_region, int allows_empty,
        swmo_buffer_view *view, uint64_t *dimensions, uint64_t *strides,
        size_t *consumed
    ) {
        if (!wire || !view || !consumed || (verified_rank && (!dimensions || !strides))) return -1;
        if (count < 40u || count - 40u < (size_t)verified_rank * 16u) return -1;
        uint16_t storage = (uint16_t)swmo_descriptor_integer(wire, 2);
        uint16_t element = (uint16_t)swmo_descriptor_integer(wire + 2u, 2);
        uint16_t rank = (uint16_t)swmo_descriptor_integer(wire + 4u, 2);
        if (rank != verified_rank || element != verified_element) return -1;
        if (swmo_descriptor_integer(wire + 6u, 2) || swmo_descriptor_integer(wire + 12u, 4)) return -1;
        uint64_t width;
        switch (element) {
        case 1: case 2: width = 1; break;
        case 3: case 4: case 9: width = 2; break;
        case 5: case 6: case 10: width = 4; break;
        case 7: case 8: case 11: width = 8; break;
        default: return -1;
        }
        uint32_t ordinal = (uint32_t)swmo_descriptor_integer(wire + 8u, 4);
        uint64_t region = swmo_descriptor_integer(wire + 16u, 8);
        uint64_t offset = swmo_descriptor_integer(wire + 24u, 8);
        uint64_t payload = swmo_descriptor_integer(wire + 32u, 8);
        if (region > maximum_region || offset > region || offset % width) return -1;
        switch (storage) {
        case 1:
            if (ordinal != UINT32_MAX || payload % width) return -1;
            break;
        case 2: case 3:
            if (ordinal == UINT32_MAX || payload) return -1;
            break;
        default: return -1;
        }
        int empty = 0;
        for (size_t i = 0; i < rank; ++i) {
            dimensions[i] = swmo_descriptor_integer(wire + 40u + 16u * i, 8);
            strides[i] = swmo_descriptor_integer(wire + 48u + 16u * i, 8);
            if (!dimensions[i]) empty = 1;
        }
        if (empty && !allows_empty) return -1;
        uint64_t end = offset;
        if (!empty) {
            for (size_t i = 0; i < rank; ++i) {
                uint64_t distance = dimensions[i] - 1u, stride = strides[i];
                if (!stride || (dimensions[i] > 1u && stride % width)) return -1;
                if (distance > UINT64_MAX / stride) return -1;
                distance *= stride;
                if (distance > UINT64_MAX - end) return -1;
                end += distance;
            }
            if (width > UINT64_MAX - end) return -1;
            end += width;
            if (end > region) return -1;
        }
        *view = (swmo_buffer_view){storage, element, rank, ordinal, region, offset, payload, end, empty};
        *consumed = 40u + (size_t)rank * 16u;
        return 0;
    }
    """#
}

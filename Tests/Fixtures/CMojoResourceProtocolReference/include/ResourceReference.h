#ifndef SWMO_RESOURCE_REFERENCE_H
#define SWMO_RESOURCE_REFERENCE_H
#include <stddef.h>
#include <stdint.h>
int swmo_reference_buffer_end(
    const uint8_t *bytes, size_t count, uint16_t maximum_rank,
    uint64_t maximum_region_bytes, int allows_empty, uint64_t *end
);
/* Fixed fixture limits: rank/inputs/outputs 4, args 64, control/result 1024,
 * copied/mapped/region bytes 8000000. */
int swmo_reference_invocation(const uint8_t *bytes, size_t count,
                              uint64_t *copied, uint64_t *mapped);
/* One Float64 output, capacity ten, schema bytes 0...31. */
int swmo_reference_result(const uint8_t *bytes, size_t count, uint64_t *body);
#endif

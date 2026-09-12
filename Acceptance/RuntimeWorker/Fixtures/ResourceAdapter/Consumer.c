#include "bridge.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

int main(void) {
    void *session = NULL;
    uint32_t schema = 0, device = 99, ordinal = 99;
    uint64_t capabilities = 0;
    assert(CREATE(FACTORY, 1, 0, 0, 0, &session, &schema, &device, &ordinal, &capabilities) == 0);
    assert(session && schema == 1 && device == 0 && ordinal == 0);
    // Packed signed extrema, unsigned extrema, NaNs and negative zero.
    uint8_t arguments[] = {
        0x80,0, 0,0x80, 0xff,0xff, 0,0,0,0x80, 0xff,0xff,0xff,0xff,
        0,0,0,0,0,0,0,0x80, 0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,
        0x01,0x7e, 0,0,0,0x80, 0x42,0,0,0,0,0,0xf8,0x7f
    };
    uint8_t storage[sizeof(arguments)+2], expected[sizeof(storage)];
    uint8_t *results = storage + 1; // Deliberately unaligned packed results.
    uint16_t input[] = {1,2,99,3,4};
    uint64_t dimensions[] = {2,2}, strides[] = {6,2}, count = 99;
    float output = -1;
    memset(storage, 0xa5, sizeof(storage));
    assert(INVOKE(session, arguments, sizeof(arguments), results, sizeof(arguments),
                  input, dimensions, strides, &output, 1, &count) == 0);
    assert(output == 10 && count == 1);
    assert(memcmp(arguments, results, sizeof(arguments)) == 0);
    assert(storage[0] == 0xa5 && storage[sizeof(storage)-1] == 0xa5);
    for (int mode = 1; mode <= 4; ++mode) {
        memset(storage, 0xa5, sizeof(storage));
        memcpy(expected, storage, sizeof(storage));
        arguments[1] = mode < 3 ? mode : 0;
        int32_t status = INVOKE(session, arguments, sizeof(arguments)-(mode == 3),
            results, sizeof(arguments)-(mode == 4), input, dimensions, strides,
            &output, 1, &count);
        assert(status == (mode == 1 ? 7 : -1));
        assert(memcmp(expected, storage, sizeof(storage)) == 0);
    }
    DESTROY(FACTORY, session);
    puts("resource native adapter: packed scalars, strided input, failure and extent guards passed");
}

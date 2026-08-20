#ifndef SWIFTMOJO_MOJOBUILDPLUGININTEGRATIONFIXTURE_ABI_H
#define SWIFTMOJO_MOJOBUILDPLUGININTEGRATIONFIXTURE_ABI_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

uint32_t swift_mojo_0d3826565dae9a79e3476cad158d11cf6bd3198ccb12185d0bcb1e4f9c3c4de6_static_abi_version(void);
uint64_t swift_mojo_0d3826565dae9a79e3476cad158d11cf6bd3198ccb12185d0bcb1e4f9c3c4de6_input_graph_identifier(void);
uint32_t swift_mojo_0d3826565dae9a79e3476cad158d11cf6bd3198ccb12185d0bcb1e4f9c3c4de6_has_binding(uint64_t binding_id);
int32_t swift_mojo_0d3826565dae9a79e3476cad158d11cf6bd3198ccb12185d0bcb1e4f9c3c4de6_call_i32_i32_i32(
    uint64_t binding_id,
    int32_t lhs,
    int32_t rhs
);

#ifdef __cplusplus
}
#endif

#endif

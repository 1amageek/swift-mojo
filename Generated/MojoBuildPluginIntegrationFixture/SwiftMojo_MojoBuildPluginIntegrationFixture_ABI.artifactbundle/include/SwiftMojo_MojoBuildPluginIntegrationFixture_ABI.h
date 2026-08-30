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
int32_t swift_mojo_0d3826565dae9a79e3476cad158d11cf6bd3198ccb12185d0bcb1e4f9c3c4de6_create_session_v1(
    uint64_t binding_id,
    uint32_t request_schema,
    uint32_t requested_device,
    uint32_t requested_ordinal,
    uint64_t required_capabilities,
    void **session_out,
    uint32_t *response_schema_out,
    uint32_t *actual_device_out,
    uint32_t *actual_ordinal_out,
    uint64_t *available_capabilities_out
);
void swift_mojo_0d3826565dae9a79e3476cad158d11cf6bd3198ccb12185d0bcb1e4f9c3c4de6_shutdown_session_v1(
    uint64_t binding_id,
    void *session
);
int32_t swift_mojo_0d3826565dae9a79e3476cad158d11cf6bd3198ccb12185d0bcb1e4f9c3c4de6_call_session_f32_buffer_f32_buffer_i32_v1(
    uint64_t binding_id,
    void *session,
    const float *input,
    uint64_t input_count,
    float *output,
    uint64_t output_count
);

#ifdef __cplusplus
}
#endif

#endif

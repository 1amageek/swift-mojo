#ifndef GENERATED_MOJO_ABI_H
#define GENERATED_MOJO_ABI_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

uint32_t swift_mojo_static_abi_version(void);
uint64_t swift_mojo_source_graph_identifier(void);
uint32_t swift_mojo_has_binding(uint64_t binding_id);
int32_t swift_mojo_call_i32_i32_i32(
    uint64_t binding_id,
    int32_t lhs,
    int32_t rhs
);

#ifdef __cplusplus
}
#endif

#endif

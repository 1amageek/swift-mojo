#ifndef CMOJO_STATIC_PREFLIGHT_FIXTURE_H
#define CMOJO_STATIC_PREFLIGHT_FIXTURE_H

#include <stdint.h>

enum {
    SWIFT_MOJO_PREFLIGHT_SUCCESS = 0,
    SWIFT_MOJO_PREFLIGHT_ABI_MISMATCH = 1,
    SWIFT_MOJO_PREFLIGHT_GRAPH_MISMATCH = 2,
    SWIFT_MOJO_PREFLIGHT_BINDING_MISSING = 3,
};

void swift_mojo_preflight_fixture_reset(
    uint32_t scenario,
    uint64_t missing_binding_id
);
uint32_t swift_mojo_preflight_fixture_abi_version(void);
uint64_t swift_mojo_preflight_fixture_input_graph(void);
int32_t swift_mojo_preflight_fixture_has_binding(uint64_t binding_id);
int32_t swift_mojo_preflight_fixture_create_session(void);
uint32_t swift_mojo_preflight_fixture_abi_call_count(void);
uint32_t swift_mojo_preflight_fixture_graph_call_count(void);
uint32_t swift_mojo_preflight_fixture_binding_call_count(void);
uint64_t swift_mojo_preflight_fixture_binding_call(uint32_t index);
uint32_t swift_mojo_preflight_fixture_session_call_count(void);

#endif

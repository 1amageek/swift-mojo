#include "CMojoStaticPreflightFixture.h"

static uint32_t fixture_scenario;
static uint64_t fixture_missing_binding_id;
static uint32_t fixture_abi_calls;
static uint32_t fixture_graph_calls;
static uint32_t fixture_binding_calls;
static uint64_t fixture_binding_call_ids[8];
static uint32_t fixture_session_calls;

void swift_mojo_preflight_fixture_reset(
    uint32_t scenario,
    uint64_t missing_binding_id
) {
    fixture_scenario = scenario;
    fixture_missing_binding_id = missing_binding_id;
    fixture_abi_calls = 0;
    fixture_graph_calls = 0;
    fixture_binding_calls = 0;
    fixture_session_calls = 0;
    for (uint32_t index = 0; index < 8; index += 1) {
        fixture_binding_call_ids[index] = 0;
    }
}

uint32_t swift_mojo_preflight_fixture_abi_version(void) {
    fixture_abi_calls += 1;
    return fixture_scenario == SWIFT_MOJO_PREFLIGHT_ABI_MISMATCH ? 2 : 1;
}

uint64_t swift_mojo_preflight_fixture_input_graph(void) {
    fixture_graph_calls += 1;
    return fixture_scenario == SWIFT_MOJO_PREFLIGHT_GRAPH_MISMATCH ? 202 : 101;
}

int32_t swift_mojo_preflight_fixture_has_binding(uint64_t binding_id) {
    if (fixture_binding_calls < 8) {
        fixture_binding_call_ids[fixture_binding_calls] = binding_id;
    }
    fixture_binding_calls += 1;
    if (fixture_scenario == SWIFT_MOJO_PREFLIGHT_BINDING_MISSING
        && binding_id == fixture_missing_binding_id) {
        return 0;
    }
    return 1;
}

int32_t swift_mojo_preflight_fixture_create_session(void) {
    fixture_session_calls += 1;
    return 0;
}

uint32_t swift_mojo_preflight_fixture_abi_call_count(void) {
    return fixture_abi_calls;
}

uint32_t swift_mojo_preflight_fixture_graph_call_count(void) {
    return fixture_graph_calls;
}

uint32_t swift_mojo_preflight_fixture_binding_call_count(void) {
    return fixture_binding_calls;
}

uint64_t swift_mojo_preflight_fixture_binding_call(uint32_t index) {
    return index < fixture_binding_calls && index < 8
        ? fixture_binding_call_ids[index]
        : 0;
}

uint32_t swift_mojo_preflight_fixture_session_call_count(void) {
    return fixture_session_calls;
}

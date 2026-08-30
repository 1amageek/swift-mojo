from std.memory import OpaquePointer, Pointer
from SessionModel import create_session as __swift_mojo_session_create_4078450316648511580
from SessionModel import shutdown_session as __swift_mojo_session_shutdown_4078450316648511580
from SessionModel import scale as __swift_mojo_external_5660857492218414691


@export("swift_mojo_0d3826565dae9a79e3476cad158d11cf6bd3198ccb12185d0bcb1e4f9c3c4de6_static_abi_version")
def swift_mojo_0d3826565dae9a79e3476cad158d11cf6bd3198ccb12185d0bcb1e4f9c3c4de6_static_abi_version() abi("C") -> UInt32:
    return 1


@export("swift_mojo_0d3826565dae9a79e3476cad158d11cf6bd3198ccb12185d0bcb1e4f9c3c4de6_input_graph_identifier")
def swift_mojo_0d3826565dae9a79e3476cad158d11cf6bd3198ccb12185d0bcb1e4f9c3c4de6_input_graph_identifier() abi("C") -> UInt64:
    return 6676104244661572363


@export("swift_mojo_0d3826565dae9a79e3476cad158d11cf6bd3198ccb12185d0bcb1e4f9c3c4de6_has_binding")
def swift_mojo_0d3826565dae9a79e3476cad158d11cf6bd3198ccb12185d0bcb1e4f9c3c4de6_has_binding(binding_id: UInt64) abi("C") -> UInt32:
    if binding_id == 4078450316648511580:
        return 1
    if binding_id == 4309807554310999824:
        return 1
    if binding_id == 5660857492218414691:
        return 1
    return 0


# The Swift bridge validates ABI, input graph, and membership before dispatch.
@export("swift_mojo_0d3826565dae9a79e3476cad158d11cf6bd3198ccb12185d0bcb1e4f9c3c4de6_call_i32_i32_i32")
def swift_mojo_0d3826565dae9a79e3476cad158d11cf6bd3198ccb12185d0bcb1e4f9c3c4de6_call_i32_i32_i32(binding_id: UInt64, lhs: Int32, rhs: Int32) abi("C") -> Int32:
    if binding_id == 4309807554310999824:
        return lhs + rhs
    return 0


# Session creation transfers one opaque owned handle to Swift on status zero.
@export("swift_mojo_0d3826565dae9a79e3476cad158d11cf6bd3198ccb12185d0bcb1e4f9c3c4de6_create_session_v1")
def swift_mojo_0d3826565dae9a79e3476cad158d11cf6bd3198ccb12185d0bcb1e4f9c3c4de6_create_session_v1(
    binding_id: UInt64,
    request_schema: UInt32,
    requested_device: UInt32,
    requested_ordinal: UInt32,
    required_capabilities: UInt64,
    session_out: Pointer[OpaquePointer[MutUntrackedOrigin], MutUntrackedOrigin],
    response_schema_out: Pointer[UInt32, MutUntrackedOrigin],
    actual_device_out: Pointer[UInt32, MutUntrackedOrigin],
    actual_ordinal_out: Pointer[UInt32, MutUntrackedOrigin],
    available_capabilities_out: Pointer[UInt64, MutUntrackedOrigin],
) abi("C") -> Int32:
    if binding_id == 4078450316648511580:
        return __swift_mojo_session_create_4078450316648511580(request_schema, requested_device, requested_ordinal, required_capabilities, session_out, response_schema_out, actual_device_out, actual_ordinal_out, available_capabilities_out)
    return -1


# The paired destroy operation is total for every valid created handle.
@export("swift_mojo_0d3826565dae9a79e3476cad158d11cf6bd3198ccb12185d0bcb1e4f9c3c4de6_shutdown_session_v1")
def swift_mojo_0d3826565dae9a79e3476cad158d11cf6bd3198ccb12185d0bcb1e4f9c3c4de6_shutdown_session_v1(
    binding_id: UInt64,
    session: OpaquePointer[MutUntrackedOrigin],
) abi("C"):
    if binding_id == 4078450316648511580:
        __swift_mojo_session_shutdown_4078450316648511580(session)
        return


# The session and buffers are borrowed only for this synchronous call.
@export("swift_mojo_0d3826565dae9a79e3476cad158d11cf6bd3198ccb12185d0bcb1e4f9c3c4de6_call_session_f32_buffer_f32_buffer_i32_v1")
def swift_mojo_0d3826565dae9a79e3476cad158d11cf6bd3198ccb12185d0bcb1e4f9c3c4de6_call_session_f32_buffer_f32_buffer_i32_v1(
    binding_id: UInt64,
    session: OpaquePointer[MutUntrackedOrigin],
    input: Pointer[Float32, ImmUntrackedOrigin],
    input_count: UInt64,
    output: Pointer[Float32, MutUntrackedOrigin],
    output_count: UInt64,
) abi("C") -> Int32:
    if binding_id == 5660857492218414691:
        return __swift_mojo_external_5660857492218414691(session, input, input_count, output, output_count)
    return -1

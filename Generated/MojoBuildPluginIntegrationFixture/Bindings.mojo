from std.memory import OpaquePointer, Pointer
from SessionModel import scale as __swift_mojo_external_2867618991011413709
from SessionModel import scale_double as __swift_mojo_external_3641678818880782478
from SessionModel import create_session as __swift_mojo_session_create_4078450316648511580
from SessionModel import shutdown_session as __swift_mojo_session_shutdown_4078450316648511580
from SessionModel import sum_values as __swift_mojo_external_8022657782034030130


@export("swift_mojo_0d3826565dae9a79e3476cad158d11cf6bd3198ccb12185d0bcb1e4f9c3c4de6_static_abi_version")
def swift_mojo_0d3826565dae9a79e3476cad158d11cf6bd3198ccb12185d0bcb1e4f9c3c4de6_static_abi_version() abi("C") -> UInt32:
    return 1


@export("swift_mojo_0d3826565dae9a79e3476cad158d11cf6bd3198ccb12185d0bcb1e4f9c3c4de6_input_graph_identifier")
def swift_mojo_0d3826565dae9a79e3476cad158d11cf6bd3198ccb12185d0bcb1e4f9c3c4de6_input_graph_identifier() abi("C") -> UInt64:
    return 2724223800370590252


@export("swift_mojo_0d3826565dae9a79e3476cad158d11cf6bd3198ccb12185d0bcb1e4f9c3c4de6_has_binding")
def swift_mojo_0d3826565dae9a79e3476cad158d11cf6bd3198ccb12185d0bcb1e4f9c3c4de6_has_binding(binding_id: UInt64) abi("C") -> UInt32:
    if binding_id == 962412470839809362:
        return 1
    if binding_id == 2867618991011413709:
        return 1
    if binding_id == 3538556927784445112:
        return 1
    if binding_id == 3641678818880782478:
        return 1
    if binding_id == 4078450316648511580:
        return 1
    if binding_id == 4309807554310999824:
        return 1
    if binding_id == 4985786232365396030:
        return 1
    if binding_id == 6062013772035942840:
        return 1
    if binding_id == 6202277106033142579:
        return 1
    if binding_id == 6634603960240158218:
        return 1
    if binding_id == 8022657782034030130:
        return 1
    return 0


# The Swift bridge validates ABI, input graph, and membership before dispatch.
@export("swift_mojo_0d3826565dae9a79e3476cad158d11cf6bd3198ccb12185d0bcb1e4f9c3c4de6_call_i32_i32_i32")
def swift_mojo_0d3826565dae9a79e3476cad158d11cf6bd3198ccb12185d0bcb1e4f9c3c4de6_call_i32_i32_i32(binding_id: UInt64, lhs: Int32, rhs: Int32) abi("C") -> Int32:
    if binding_id == 4309807554310999824:
        return lhs + rhs
    return 0


# The borrowed pointer is valid only for the synchronous Swift call scope.
@export("swift_mojo_0d3826565dae9a79e3476cad158d11cf6bd3198ccb12185d0bcb1e4f9c3c4de6_call_f32_buffer_f32")
def swift_mojo_0d3826565dae9a79e3476cad158d11cf6bd3198ccb12185d0bcb1e4f9c3c4de6_call_f32_buffer_f32(
    binding_id: UInt64,
    values: Pointer[Float32, ImmUntrackedOrigin],
    count: UInt64,
) abi("C") -> Float32:
    if binding_id == 8022657782034030130:
        return __swift_mojo_external_8022657782034030130(values, count)
    return Float32(0)


# Both Float64 pointers are valid only for the synchronous Swift call scope.
@export("swift_mojo_0d3826565dae9a79e3476cad158d11cf6bd3198ccb12185d0bcb1e4f9c3c4de6_call_f64_buffer_f64_buffer_i32")
def swift_mojo_0d3826565dae9a79e3476cad158d11cf6bd3198ccb12185d0bcb1e4f9c3c4de6_call_f64_buffer_f64_buffer_i32(
    binding_id: UInt64,
    input: Pointer[Float64, ImmUntrackedOrigin],
    input_count: UInt64,
    output: Pointer[Float64, MutUntrackedOrigin],
    output_count: UInt64,
) abi("C") -> Int32:
    if binding_id == 3641678818880782478:
        return __swift_mojo_external_3641678818880782478(input, input_count, output, output_count)
    return -1


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
    if binding_id == 2867618991011413709:
        return __swift_mojo_external_2867618991011413709(session, input, input_count, output, output_count)
    return -1

from SessionModel import check_resources as __opaque_call_962412470839809362
from SessionModel import synchronize_resources as __opaque_sync_962412470839809362

@export("swift_mojo_0d3826565dae9a79e3476cad158d11cf6bd3198ccb12185d0bcb1e4f9c3c4de6_resources_call_962412470839809362")
def swift_mojo_0d3826565dae9a79e3476cad158d11cf6bd3198ccb12185d0bcb1e4f9c3c4de6_resources_call_962412470839809362(session: OpaquePointer[MutUntrackedOrigin], resources: Pointer[OpaquePointer[MutUntrackedOrigin], ImmUntrackedOrigin], count: UInt64) abi("C") -> Int32:
    status = __opaque_call_962412470839809362(session, resources, count)
    completion = __opaque_sync_962412470839809362(session)
    if status != 0:
        return status
    return completion

from SessionModel import create_resource as __opaque_create_3538556927784445112
from SessionModel import destroy_resource as __opaque_destroy_3538556927784445112
from SessionModel import synchronize_resources as __opaque_sync_3538556927784445112

@export("swift_mojo_0d3826565dae9a79e3476cad158d11cf6bd3198ccb12185d0bcb1e4f9c3c4de6_resource_create_3538556927784445112")
def swift_mojo_0d3826565dae9a79e3476cad158d11cf6bd3198ccb12185d0bcb1e4f9c3c4de6_resource_create_3538556927784445112(session: OpaquePointer[MutUntrackedOrigin], config: Pointer[UInt8, ImmUntrackedOrigin], count: UInt64, result: Pointer[OpaquePointer[MutUntrackedOrigin], MutUntrackedOrigin]) abi("C") -> Int32:
    status = __opaque_create_3538556927784445112(session, config, count, result)
    completion = __opaque_sync_3538556927784445112(session)
    if status != 0:
        return status
    return completion

@export("swift_mojo_0d3826565dae9a79e3476cad158d11cf6bd3198ccb12185d0bcb1e4f9c3c4de6_resource_destroy_3538556927784445112")
def swift_mojo_0d3826565dae9a79e3476cad158d11cf6bd3198ccb12185d0bcb1e4f9c3c4de6_resource_destroy_3538556927784445112(session: OpaquePointer[MutUntrackedOrigin], resource: OpaquePointer[MutUntrackedOrigin]) abi("C"):
    __opaque_destroy_3538556927784445112(session, resource)

from SessionModel import check_resource_count as __opaque_call_4985786232365396030
from SessionModel import synchronize_resources as __opaque_sync_4985786232365396030

@export("swift_mojo_0d3826565dae9a79e3476cad158d11cf6bd3198ccb12185d0bcb1e4f9c3c4de6_resources_call_4985786232365396030")
def swift_mojo_0d3826565dae9a79e3476cad158d11cf6bd3198ccb12185d0bcb1e4f9c3c4de6_resources_call_4985786232365396030(session: OpaquePointer[MutUntrackedOrigin], resources: Pointer[OpaquePointer[MutUntrackedOrigin], ImmUntrackedOrigin], count: UInt64) abi("C") -> Int32:
    status = __opaque_call_4985786232365396030(session, resources, count)
    completion = __opaque_sync_4985786232365396030(session)
    if status != 0:
        return status
    return completion

from SessionModel import sum_resources as __opaque_call_6062013772035942840
from SessionModel import synchronize_resources as __opaque_sync_6062013772035942840

@export("swift_mojo_0d3826565dae9a79e3476cad158d11cf6bd3198ccb12185d0bcb1e4f9c3c4de6_resources_call_6062013772035942840")
def swift_mojo_0d3826565dae9a79e3476cad158d11cf6bd3198ccb12185d0bcb1e4f9c3c4de6_resources_call_6062013772035942840(session: OpaquePointer[MutUntrackedOrigin], resources: Pointer[OpaquePointer[MutUntrackedOrigin], ImmUntrackedOrigin], count: UInt64) abi("C") -> Int32:
    status = __opaque_call_6062013772035942840(session, resources, count)
    completion = __opaque_sync_6062013772035942840(session)
    if status != 0:
        return status
    return completion

from SessionModel import fail_resources as __opaque_call_6202277106033142579
from SessionModel import synchronize_resources as __opaque_sync_6202277106033142579

@export("swift_mojo_0d3826565dae9a79e3476cad158d11cf6bd3198ccb12185d0bcb1e4f9c3c4de6_resources_call_6202277106033142579")
def swift_mojo_0d3826565dae9a79e3476cad158d11cf6bd3198ccb12185d0bcb1e4f9c3c4de6_resources_call_6202277106033142579(session: OpaquePointer[MutUntrackedOrigin], resources: Pointer[OpaquePointer[MutUntrackedOrigin], ImmUntrackedOrigin], count: UInt64) abi("C") -> Int32:
    status = __opaque_call_6202277106033142579(session, resources, count)
    completion = __opaque_sync_6202277106033142579(session)
    if status != 0:
        return status
    return completion

from SessionModel import create_resource as __opaque_create_6634603960240158218
from SessionModel import destroy_resource as __opaque_destroy_6634603960240158218
from SessionModel import synchronize_resources as __opaque_sync_6634603960240158218

@export("swift_mojo_0d3826565dae9a79e3476cad158d11cf6bd3198ccb12185d0bcb1e4f9c3c4de6_resource_create_6634603960240158218")
def swift_mojo_0d3826565dae9a79e3476cad158d11cf6bd3198ccb12185d0bcb1e4f9c3c4de6_resource_create_6634603960240158218(session: OpaquePointer[MutUntrackedOrigin], config: Pointer[UInt8, ImmUntrackedOrigin], count: UInt64, result: Pointer[OpaquePointer[MutUntrackedOrigin], MutUntrackedOrigin]) abi("C") -> Int32:
    status = __opaque_create_6634603960240158218(session, config, count, result)
    completion = __opaque_sync_6634603960240158218(session)
    if status != 0:
        return status
    return completion

@export("swift_mojo_0d3826565dae9a79e3476cad158d11cf6bd3198ccb12185d0bcb1e4f9c3c4de6_resource_destroy_6634603960240158218")
def swift_mojo_0d3826565dae9a79e3476cad158d11cf6bd3198ccb12185d0bcb1e4f9c3c4de6_resource_destroy_6634603960240158218(session: OpaquePointer[MutUntrackedOrigin], resource: OpaquePointer[MutUntrackedOrigin]) abi("C"):
    __opaque_destroy_6634603960240158218(session, resource)

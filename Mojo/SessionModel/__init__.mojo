from std.ffi import external_call
from std.memory import OpaquePointer, Pointer
from std.sys import size_of


struct Session:
    var factor: Float32
    var pending: Int32
    var resource_count: Int64

    def __init__(out self, factor: Float32):
        self.factor = factor
        self.pending = 0
        self.resource_count = 0


def create_session(
    request_schema: UInt32,
    requested_device: UInt32,
    requested_ordinal: UInt32,
    required_capabilities: UInt64,
    session_out: Pointer[OpaquePointer[MutUntrackedOrigin], MutUntrackedOrigin],
    response_schema_out: Pointer[UInt32, MutUntrackedOrigin],
    actual_device_out: Pointer[UInt32, MutUntrackedOrigin],
    actual_ordinal_out: Pointer[UInt32, MutUntrackedOrigin],
    available_capabilities_out: Pointer[UInt64, MutUntrackedOrigin],
) -> Int32:
    if request_schema != 1 or requested_device != 0 or requested_ordinal != 0:
        return 1
    var supported_capabilities = UInt64(19)
    if (
        required_capabilities & supported_capabilities
    ) != required_capabilities:
        return 2
    var address = external_call["malloc", UInt](UInt(size_of[Session]()))
    if address == 0:
        return 3
    var session = Pointer[Session, MutUntrackedOrigin](
        unsafe_from_address=Int(address)
    )
    session.unsafe_write(Session(2.0))
    session_out[] = session.unsafe_bitcast[NoneType]()
    response_schema_out[] = 1
    actual_device_out[] = 0
    actual_ordinal_out[] = 0
    available_capabilities_out[] = supported_capabilities
    return 0


def shutdown_session(handle: OpaquePointer[MutUntrackedOrigin]):
    var session = handle.unsafe_bitcast[Session]()
    session.unsafe_deinit_pointee()
    external_call["free", NoneType](handle)


def scale(
    handle: OpaquePointer[MutUntrackedOrigin],
    input: Pointer[Float32, ImmUntrackedOrigin],
    input_count: UInt64,
    output: Pointer[Float32, MutUntrackedOrigin],
    output_count: UInt64,
) -> Int32:
    if output_count < input_count:
        return 4
    var session = handle.unsafe_bitcast[Session]()
    for index in range(Int(input_count)):
        output[unsafe_offset=index] = (
            input[unsafe_offset=index] * session[].factor
        )
    return 0


def sum_values(
    input: Pointer[Float32, ImmUntrackedOrigin],
    count: UInt64,
) -> Float32:
    var result = Float32(0)
    for index in range(Int(count)):
        result += input[unsafe_offset=index]
    return result


def scale_double(
    input: Pointer[Float64, ImmUntrackedOrigin],
    input_count: UInt64,
    output: Pointer[Float64, MutUntrackedOrigin],
    output_count: UInt64,
) -> Int32:
    if output_count < input_count:
        return 4
    for index in range(Int(input_count)):
        output[unsafe_offset=index] = input[unsafe_offset=index] * 2
    return 0


# Resources deliberately contain Int64 values, not Float32 host buffers.
# Allocation belongs to create_resource and exactly one destroy_resource call.
def create_resource(
    handle: OpaquePointer[MutUntrackedOrigin],
    config: Pointer[UInt8, ImmUntrackedOrigin], count: UInt64,
    result: Pointer[OpaquePointer[MutUntrackedOrigin], MutUntrackedOrigin],
) -> Int32:
    session = handle.unsafe_bitcast[Session]()
    if session[].pending != 0:
        return 40
    if count != 1:
        return 45
    session[].pending = 1
    if config[] == 254:
        return 0
    address = external_call["malloc", UInt](UInt(size_of[Int64]()))
    if address == 0:
        return 3
    value = Pointer[Int64, MutUntrackedOrigin](unsafe_from_address=Int(address))
    value.unsafe_write(Int64(config[]))
    result[] = value.unsafe_bitcast[NoneType]()
    session[].resource_count += 1
    if config[] == 255:
        session[].pending = 42
        return 41
    return 0


def destroy_resource(handle: OpaquePointer[MutUntrackedOrigin], resource: OpaquePointer[MutUntrackedOrigin]):
    handle.unsafe_bitcast[Session]()[].resource_count -= 1
    external_call["free", NoneType](resource)


def synchronize_resources(handle: OpaquePointer[MutUntrackedOrigin]) -> Int32:
    session = handle.unsafe_bitcast[Session]()
    pending = session[].pending
    session[].pending = 0
    if pending == 42:
        return 44
    return 0


def sum_resources(handle: OpaquePointer[MutUntrackedOrigin], resources: Pointer[OpaquePointer[MutUntrackedOrigin], ImmUntrackedOrigin], count: UInt64) -> Int32:
    session = handle.unsafe_bitcast[Session]()
    if session[].pending != 0:
        return 40
    if count < 2:
        return 46
    session[].pending = 1
    var total = Int64(0)
    for index in range(Int(count) - 1):
        total += resources[unsafe_offset=index].unsafe_bitcast[Int64]()[]
    resources[unsafe_offset=Int(count) - 1].unsafe_bitcast[Int64]()[] = total
    return 0


def check_resources(handle: OpaquePointer[MutUntrackedOrigin], resources: Pointer[OpaquePointer[MutUntrackedOrigin], ImmUntrackedOrigin], count: UInt64) -> Int32:
    if count < 2:
        return 46
    var expected = Int64(0)
    for index in range(Int(count) - 1):
        expected += 7
    if resources[unsafe_offset=Int(count) - 1].unsafe_bitcast[Int64]()[] != expected:
        return 47
    return 0


def fail_resources(handle: OpaquePointer[MutUntrackedOrigin], resources: Pointer[OpaquePointer[MutUntrackedOrigin], ImmUntrackedOrigin], count: UInt64) -> Int32:
    handle.unsafe_bitcast[Session]()[].pending = 42
    return 43


def check_resource_count(handle: OpaquePointer[MutUntrackedOrigin], resources: Pointer[OpaquePointer[MutUntrackedOrigin], ImmUntrackedOrigin], count: UInt64) -> Int32:
    if handle.unsafe_bitcast[Session]()[].resource_count != Int64(count):
        return 48
    return 0

from std.memory import OpaquePointer, Pointer, alloc


struct Session:
    var factor: Float32

    def __init__(out self, factor: Float32):
        self.factor = factor


def create_session(
    request_schema: UInt32,
    requested_device: UInt32,
    requested_ordinal: UInt32,
    required_capabilities: UInt64,
    session_out: Pointer[
        OpaquePointer[MutUntrackedOrigin], MutUntrackedOrigin
    ],
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
    var session = alloc[Session](1)
    session.unsafe_write(Session(2.0))
    session_out[] = session.unsafe_bitcast[NoneType]()
    response_schema_out[] = 1
    actual_device_out[] = 0
    actual_ordinal_out[] = 0
    available_capabilities_out[] = supported_capabilities
    return 0


def shutdown_session(
    handle: OpaquePointer[MutUntrackedOrigin],
):
    var session = handle.unsafe_bitcast[Session]()
    session.unsafe_deinit_pointee()
    session.unsafe_free()


def scale(
    handle: OpaquePointer[MutUntrackedOrigin],
    input: Pointer[Float32, ImmUntrackedOrigin],
    input_count: UInt64,
    output: Pointer[Float32, MutUntrackedOrigin],
    output_count: UInt64,
) -> Int32:
    if output_count < input_count:
        return 7
    var session = handle.unsafe_bitcast[Session]()
    for index in range(Int(input_count)):
        output[unsafe_offset=index] = (
            input[unsafe_offset=index] * session[].factor
        )
    return 0


def stall(
    handle: OpaquePointer[MutUntrackedOrigin],
    input: Pointer[Float32, ImmUntrackedOrigin],
    input_count: UInt64,
    output: Pointer[Float32, MutUntrackedOrigin],
    output_count: UInt64,
) -> Int32:
    while True:
        pass

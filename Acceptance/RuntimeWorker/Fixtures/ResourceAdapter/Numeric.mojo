from std.memory import OpaquePointer, Pointer
from RuntimeWorkerAcceptanceModel import create_session as create, shutdown_session as destroy


def compute(
    session: OpaquePointer[MutUntrackedOrigin],
    a0: Int8, a1: UInt8, a2: Int16, a3: UInt16,
    a4: Int32, a5: UInt32, a6: Int64, a7: UInt64,
    a8: Float16, a9: Float32, a10: Float64,
    input: Pointer[UInt16, ImmUntrackedOrigin],
    dimensions: Pointer[UInt64, ImmUntrackedOrigin],
    strides: Pointer[UInt64, ImmUntrackedOrigin],
    r0: Pointer[Int8, MutUntrackedOrigin], r1: Pointer[UInt8, MutUntrackedOrigin],
    r2: Pointer[Int16, MutUntrackedOrigin], r3: Pointer[UInt16, MutUntrackedOrigin],
    r4: Pointer[Int32, MutUntrackedOrigin], r5: Pointer[UInt32, MutUntrackedOrigin],
    r6: Pointer[Int64, MutUntrackedOrigin], r7: Pointer[UInt64, MutUntrackedOrigin],
    r8: Pointer[Float16, MutUntrackedOrigin], r9: Pointer[Float32, MutUntrackedOrigin],
    r10: Pointer[Float64, MutUntrackedOrigin],
    output: Pointer[Float32, MutUntrackedOrigin], capacity: UInt64,
    count: Pointer[UInt64, MutUntrackedOrigin],
) -> Int32:
    if a1 == 1:
        return 7
    if a1 == 2:
        count[] = capacity + 1
        return 0
    if capacity < 1:
        return 8
    var total = UInt64(0)
    for row in range(Int(dimensions[unsafe_offset=0])):
        for column in range(Int(dimensions[unsafe_offset=1])):
            var offset = (UInt64(row) * strides[unsafe_offset=0] + UInt64(column) * strides[unsafe_offset=1]) // 2
            total += UInt64(input[unsafe_offset=Int(offset)])
    output[] = Float32(total)
    count[] = 1
    r0[] = a0
    r1[] = a1
    r2[] = a2
    r3[] = a3
    r4[] = a4
    r5[] = a5
    r6[] = a6
    r7[] = a7
    r8[] = a8
    r9[] = a9
    r10[] = a10
    return 0

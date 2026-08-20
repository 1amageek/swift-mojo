@export("swift_mojo_static_abi_version")
def swift_mojo_static_abi_version() abi("C") -> UInt32:
    return 1


@export("swift_mojo_source_graph_identifier")
def swift_mojo_source_graph_identifier() abi("C") -> UInt64:
    return 2856165373393807928


@export("swift_mojo_has_binding")
def swift_mojo_has_binding(binding_id: UInt64) abi("C") -> UInt32:
    if binding_id == 788870723690667806:
        return 1
    return 0


# The Swift bridge validates ABI, source graph, and membership before dispatch.
@export("swift_mojo_call_i32_i32_i32")
def swift_mojo_call_i32_i32_i32(binding_id: UInt64, lhs: Int32, rhs: Int32) abi("C") -> Int32:
    if binding_id == 788870723690667806:
        return lhs + rhs
    return 0

@export("swift_mojo_0d3826565dae9a79e3476cad158d11cf6bd3198ccb12185d0bcb1e4f9c3c4de6_static_abi_version")
def swift_mojo_0d3826565dae9a79e3476cad158d11cf6bd3198ccb12185d0bcb1e4f9c3c4de6_static_abi_version() abi("C") -> UInt32:
    return 1


@export("swift_mojo_0d3826565dae9a79e3476cad158d11cf6bd3198ccb12185d0bcb1e4f9c3c4de6_input_graph_identifier")
def swift_mojo_0d3826565dae9a79e3476cad158d11cf6bd3198ccb12185d0bcb1e4f9c3c4de6_input_graph_identifier() abi("C") -> UInt64:
    return 7450898839080874269


@export("swift_mojo_0d3826565dae9a79e3476cad158d11cf6bd3198ccb12185d0bcb1e4f9c3c4de6_has_binding")
def swift_mojo_0d3826565dae9a79e3476cad158d11cf6bd3198ccb12185d0bcb1e4f9c3c4de6_has_binding(binding_id: UInt64) abi("C") -> UInt32:
    if binding_id == 4309807554310999824:
        return 1
    return 0


# The Swift bridge validates ABI, input graph, and membership before dispatch.
@export("swift_mojo_0d3826565dae9a79e3476cad158d11cf6bd3198ccb12185d0bcb1e4f9c3c4de6_call_i32_i32_i32")
def swift_mojo_0d3826565dae9a79e3476cad158d11cf6bd3198ccb12185d0bcb1e4f9c3c4de6_call_i32_i32_i32(binding_id: UInt64, lhs: Int32, rhs: Int32) abi("C") -> Int32:
    if binding_id == 4309807554310999824:
        return lhs + rhs
    return 0

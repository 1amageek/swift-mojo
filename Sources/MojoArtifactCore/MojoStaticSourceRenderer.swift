import MojoBindingCore

package struct MojoStaticSourceRenderer: Sendable {
    package static let generationVersion = 2
    package static let borrowedFloat32BufferGenerationVersion = 2
    package static let borrowedMutableFloat32BuffersGenerationVersion = 1
    package static let borrowedMutableFloat64BuffersGenerationVersion = 1
    package static let runtimeSessionGenerationVersion = 1
    package static let sessionResourceGenerationVersion = 3

    package init() {}

    package func mojoSource(for graph: MojoSourceGraph) -> String {
        render(
            inputGraph: MojoInputGraph(bindingGraph: graph),
            identity: .legacy
        ).source
            .replacingOccurrences(
                of: "swift_mojo_input_graph_identifier",
                with: "swift_mojo_source_graph_identifier"
            )
            .replacingOccurrences(
                of: "return \(MojoInputGraph(bindingGraph: graph).digestIdentifier)",
                with: "return \(graph.digestIdentifier)"
            )
    }

    package var header: String {
        header(identity: .legacy).replacingOccurrences(
            of: "swift_mojo_input_graph_identifier",
            with: "swift_mojo_source_graph_identifier"
        )
    }

    package var moduleMap: String {
        moduleMap(identity: .legacy)
    }

    package func render(
        inputGraph: MojoInputGraph,
        identity: MojoArtifactIdentity
    ) -> MojoRenderedSource {
        let graph = inputGraph.bindingGraph
        let scalarBindings = graph.bindings.filter {
            $0.signature == .int32Binary
        }
        let bufferBindings = graph.bindings.filter {
            $0.signature == .borrowedFloat32Buffer
        }
        let mutationBindings = graph.bindings.filter {
            $0.signature == .borrowedMutableFloat32Buffers
        }
        let doubleMutationBindings = graph.bindings.filter {
            $0.signature == .borrowedMutableFloat64Buffers
        }
        let sessionFactories = graph.bindings.filter {
            $0.signature == .runtimeSessionFactory
        }
        let bufferFactories = graph.bindings.filter {
            $0.signature == .sessionFloat32BufferFactory
        }
        let sessionMutations = graph.bindings.filter {
            $0.signature == .sessionBorrowedMutableFloat32Buffers
        }
        var lines: [String] = []
        var entries: [MojoSourceMap.Entry] = []

        if !sessionFactories.isEmpty || !bufferFactories.isEmpty
            || !sessionMutations.isEmpty {
            lines.append("from std.memory import OpaquePointer, Pointer")
        } else if !bufferBindings.isEmpty || !mutationBindings.isEmpty
            || !doubleMutationBindings.isEmpty {
            lines.append("from std.memory import Pointer")
        }
        for binding in graph.bindings {
            switch binding.implementation {
            case .inline:
                continue
            case .external(let package, let function):
                lines.append(
                    "from \(package) import \(function) as __swift_mojo_external_\(binding.bindingID)"
                )
            case .session(let package, let create, let shutdown):
                lines.append(
                    "from \(package) import \(create) as __swift_mojo_session_create_\(binding.bindingID)"
                )
                lines.append(
                    "from \(package) import \(shutdown) as __swift_mojo_session_shutdown_\(binding.bindingID)"
                )
            case .sessionExternal(let package, let function, _):
                lines.append(
                    "from \(package) import \(function) as __swift_mojo_external_\(binding.bindingID)"
                )
            case .sessionResource(
                let package,
                let create,
                let shutdown,
                let copyFromHost,
                let copyToHost,
                let synchronize,
                _
            ):
                lines.append(
                    "from \(package) import \(create) as __swift_mojo_resource_create_\(binding.bindingID)"
                )
                lines.append(
                    "from \(package) import \(shutdown) as __swift_mojo_resource_shutdown_\(binding.bindingID)"
                )
                lines.append(
                    "from \(package) import \(copyFromHost) as __swift_mojo_resource_copy_from_host_\(binding.bindingID)"
                )
                lines.append(
                    "from \(package) import \(copyToHost) as __swift_mojo_resource_copy_to_host_\(binding.bindingID)"
                )
                lines.append(
                    "from \(package) import \(synchronize) as __swift_mojo_resource_synchronize_\(binding.bindingID)"
                )
            }
            if let source = binding.sourceReference {
                entries.append(
                    MojoSourceMap.Entry(
                        generatedLine: lines.count,
                        bindingID: binding.bindingID,
                        source: source
                    )
                )
            }
        }
        if !lines.isEmpty {
            lines.append("")
            lines.append("")
        }

        lines.append("@export(\"\(identity.symbolPrefix)_static_abi_version\")")
        lines.append("def \(identity.symbolPrefix)_static_abi_version() abi(\"C\") -> UInt32:")
        lines.append("    return \(MojoStaticABI.version)")
        lines.append("")
        lines.append("")
        lines.append("@export(\"\(identity.symbolPrefix)_input_graph_identifier\")")
        lines.append("def \(identity.symbolPrefix)_input_graph_identifier() abi(\"C\") -> UInt64:")
        lines.append("    return \(inputGraph.digestIdentifier)")
        lines.append("")
        lines.append("")
        lines.append("@export(\"\(identity.symbolPrefix)_has_binding\")")
        lines.append("def \(identity.symbolPrefix)_has_binding(binding_id: UInt64) abi(\"C\") -> UInt32:")
        for binding in graph.bindings {
            lines.append("    if binding_id == \(binding.bindingID):")
            lines.append("        return 1")
        }
        lines.append("    return 0")
        if !scalarBindings.isEmpty {
            lines.append("")
            lines.append("")
            lines.append("# The Swift bridge validates ABI, input graph, and membership before dispatch.")
            lines.append("@export(\"\(identity.symbolPrefix)_call_i32_i32_i32\")")
            lines.append("def \(identity.symbolPrefix)_call_i32_i32_i32(binding_id: UInt64, lhs: Int32, rhs: Int32) abi(\"C\") -> Int32:")
            for binding in scalarBindings {
                lines.append("    if binding_id == \(binding.bindingID):")
                let expression: String
                switch binding.implementation {
                case .inline(let operation):
                    expression = operation.mojoExpression(lhs: "lhs", rhs: "rhs")
                case .external:
                    expression = "__swift_mojo_external_\(binding.bindingID)(lhs, rhs)"
                case .session:
                    preconditionFailure(
                        "Scalar bindings cannot use a session factory implementation"
                    )
                case .sessionExternal:
                    preconditionFailure(
                        "Scalar bindings cannot use a session-bound implementation"
                    )
                case .sessionResource:
                    preconditionFailure(
                        "Scalar bindings cannot use a session resource implementation"
                    )
                }
                lines.append("        return \(expression)")
                if let source = binding.sourceReference {
                    entries.append(
                        MojoSourceMap.Entry(
                            generatedLine: lines.count,
                            bindingID: binding.bindingID,
                            source: source
                        )
                    )
                }
            }
            lines.append("    return 0")
        }

        if !bufferBindings.isEmpty {
            lines.append("")
            lines.append("")
            lines.append("# The borrowed pointer is valid only for the synchronous Swift call scope.")
            lines.append("@export(\"\(identity.symbolPrefix)_call_f32_buffer_f32\")")
            lines.append("def \(identity.symbolPrefix)_call_f32_buffer_f32(")
            lines.append("    binding_id: UInt64,")
            lines.append("    values: Pointer[Float32, ImmUntrackedOrigin],")
            lines.append("    count: UInt64,")
            lines.append(") abi(\"C\") -> Float32:")
            for binding in bufferBindings {
                lines.append("    if binding_id == \(binding.bindingID):")
                guard case .external = binding.implementation else {
                    preconditionFailure(
                        "Borrowed buffer bindings require external implementations"
                    )
                }
                lines.append(
                    "        return __swift_mojo_external_\(binding.bindingID)(values, count)"
                )
                if let source = binding.sourceReference {
                    entries.append(
                        MojoSourceMap.Entry(
                            generatedLine: lines.count,
                            bindingID: binding.bindingID,
                            source: source
                        )
                    )
                }
            }
            lines.append("    return Float32(0)")
        }

        if !mutationBindings.isEmpty {
            lines.append("")
            lines.append("")
            lines.append("# Both pointers are valid only for the synchronous Swift call scope.")
            lines.append("@export(\"\(identity.symbolPrefix)_call_f32_buffer_f32_buffer_i32\")")
            lines.append("def \(identity.symbolPrefix)_call_f32_buffer_f32_buffer_i32(")
            lines.append("    binding_id: UInt64,")
            lines.append("    input: Pointer[Float32, ImmUntrackedOrigin],")
            lines.append("    input_count: UInt64,")
            lines.append("    output: Pointer[Float32, MutUntrackedOrigin],")
            lines.append("    output_count: UInt64,")
            lines.append(") abi(\"C\") -> Int32:")
            for binding in mutationBindings {
                lines.append("    if binding_id == \(binding.bindingID):")
                guard case .external = binding.implementation else {
                    preconditionFailure(
                        "Mutable buffer bindings require external implementations"
                    )
                }
                lines.append(
                    "        return __swift_mojo_external_\(binding.bindingID)(input, input_count, output, output_count)"
                )
                if let source = binding.sourceReference {
                    entries.append(
                        MojoSourceMap.Entry(
                            generatedLine: lines.count,
                            bindingID: binding.bindingID,
                            source: source
                        )
                    )
                }
            }
            lines.append("    return -1")
        }

        if !doubleMutationBindings.isEmpty {
            lines.append("")
            lines.append("")
            lines.append("# Both Float64 pointers are valid only for the synchronous Swift call scope.")
            lines.append("@export(\"\(identity.symbolPrefix)_call_f64_buffer_f64_buffer_i32\")")
            lines.append("def \(identity.symbolPrefix)_call_f64_buffer_f64_buffer_i32(")
            lines.append("    binding_id: UInt64,")
            lines.append("    input: Pointer[Float64, ImmUntrackedOrigin],")
            lines.append("    input_count: UInt64,")
            lines.append("    output: Pointer[Float64, MutUntrackedOrigin],")
            lines.append("    output_count: UInt64,")
            lines.append(") abi(\"C\") -> Int32:")
            for binding in doubleMutationBindings {
                lines.append("    if binding_id == \(binding.bindingID):")
                guard case .external = binding.implementation else {
                    preconditionFailure(
                        "Mutable Float64 buffer bindings require external implementations"
                    )
                }
                lines.append(
                    "        return __swift_mojo_external_\(binding.bindingID)(input, input_count, output, output_count)"
                )
                if let source = binding.sourceReference {
                    entries.append(
                        MojoSourceMap.Entry(
                            generatedLine: lines.count,
                            bindingID: binding.bindingID,
                            source: source
                        )
                    )
                }
            }
            lines.append("    return -1")
        }

        if !sessionFactories.isEmpty {
            lines.append("")
            lines.append("")
            lines.append("# Session creation transfers one opaque owned handle to Swift on status zero.")
            lines.append("@export(\"\(identity.symbolPrefix)_create_session_v1\")")
            lines.append("def \(identity.symbolPrefix)_create_session_v1(")
            lines.append("    binding_id: UInt64,")
            lines.append("    request_schema: UInt32,")
            lines.append("    requested_device: UInt32,")
            lines.append("    requested_ordinal: UInt32,")
            lines.append("    required_capabilities: UInt64,")
            lines.append("    session_out: Pointer[OpaquePointer[MutUntrackedOrigin], MutUntrackedOrigin],")
            lines.append("    response_schema_out: Pointer[UInt32, MutUntrackedOrigin],")
            lines.append("    actual_device_out: Pointer[UInt32, MutUntrackedOrigin],")
            lines.append("    actual_ordinal_out: Pointer[UInt32, MutUntrackedOrigin],")
            lines.append("    available_capabilities_out: Pointer[UInt64, MutUntrackedOrigin],")
            lines.append(") abi(\"C\") -> Int32:")
            for binding in sessionFactories {
                lines.append("    if binding_id == \(binding.bindingID):")
                guard case .session = binding.implementation else {
                    preconditionFailure(
                        "Session factory bindings require paired create and shutdown implementations"
                    )
                }
                lines.append(
                    "        return __swift_mojo_session_create_\(binding.bindingID)(request_schema, requested_device, requested_ordinal, required_capabilities, session_out, response_schema_out, actual_device_out, actual_ordinal_out, available_capabilities_out)"
                )
                if let source = binding.sourceReference {
                    entries.append(
                        MojoSourceMap.Entry(
                            generatedLine: lines.count,
                            bindingID: binding.bindingID,
                            source: source
                        )
                    )
                }
            }
            lines.append("    return -1")
            lines.append("")
            lines.append("")
            lines.append("# The paired destroy operation is total for every valid created handle.")
            lines.append("@export(\"\(identity.symbolPrefix)_shutdown_session_v1\")")
            lines.append("def \(identity.symbolPrefix)_shutdown_session_v1(")
            lines.append("    binding_id: UInt64,")
            lines.append("    session: OpaquePointer[MutUntrackedOrigin],")
            lines.append(") abi(\"C\"):")
            for binding in sessionFactories {
                lines.append("    if binding_id == \(binding.bindingID):")
                lines.append(
                    "        __swift_mojo_session_shutdown_\(binding.bindingID)(session)"
                )
                lines.append("        return")
            }
        }

        if !bufferFactories.isEmpty {
            lines.append("")
            lines.append("")
            lines.append("# Buffer creation transfers one session-owned opaque handle on status zero.")
            lines.append("@export(\"\(identity.symbolPrefix)_create_f32_buffer_v1\")")
            lines.append("def \(identity.symbolPrefix)_create_f32_buffer_v1(")
            lines.append("    binding_id: UInt64,")
            lines.append("    session: OpaquePointer[MutUntrackedOrigin],")
            lines.append("    element_count: UInt64,")
            lines.append("    memory_kind: UInt32,")
            lines.append("    buffer_out: Pointer[OpaquePointer[MutUntrackedOrigin], MutUntrackedOrigin],")
            lines.append(") abi(\"C\") -> Int32:")
            for binding in bufferFactories {
                lines.append("    if binding_id == \(binding.bindingID):")
                guard case .sessionResource = binding.implementation else {
                    preconditionFailure(
                        "Buffer factory bindings require paired create and shutdown implementations"
                    )
                }
                lines.append(
                    "        return __swift_mojo_resource_create_\(binding.bindingID)(session, element_count, memory_kind, buffer_out)"
                )
                if let source = binding.sourceReference {
                    entries.append(
                        MojoSourceMap.Entry(
                            generatedLine: lines.count,
                            bindingID: binding.bindingID,
                            source: source
                        )
                    )
                }
            }
            lines.append("    return -1")
            lines.append("")
            lines.append("")
            lines.append("# Buffer destruction runs while the parent session lease is active.")
            lines.append("@export(\"\(identity.symbolPrefix)_shutdown_f32_buffer_v1\")")
            lines.append("def \(identity.symbolPrefix)_shutdown_f32_buffer_v1(")
            lines.append("    binding_id: UInt64,")
            lines.append("    session: OpaquePointer[MutUntrackedOrigin],")
            lines.append("    buffer: OpaquePointer[MutUntrackedOrigin],")
            lines.append(") abi(\"C\"):")
            for binding in bufferFactories {
                lines.append("    if binding_id == \(binding.bindingID):")
                lines.append(
                    "        __swift_mojo_resource_shutdown_\(binding.bindingID)(session, buffer)"
                )
                lines.append("        return")
            }
            lines.append("")
            lines.append("")
            lines.append("# Host input remains borrowed until the synchronous transfer returns.")
            lines.append("@export(\"\(identity.symbolPrefix)_copy_host_to_f32_buffer_v1\")")
            lines.append("def \(identity.symbolPrefix)_copy_host_to_f32_buffer_v1(")
            lines.append("    binding_id: UInt64,")
            lines.append("    session: OpaquePointer[MutUntrackedOrigin],")
            lines.append("    buffer: OpaquePointer[MutUntrackedOrigin],")
            lines.append("    source: Pointer[Float32, ImmUntrackedOrigin],")
            lines.append("    element_count: UInt64,")
            lines.append(") abi(\"C\") -> Int32:")
            for binding in bufferFactories {
                lines.append("    if binding_id == \(binding.bindingID):")
                lines.append(
                    "        var status = __swift_mojo_resource_copy_from_host_\(binding.bindingID)(session, buffer, source, element_count)"
                )
                lines.append("        if status != 0:")
                lines.append("            return status")
                lines.append(
                    "        return __swift_mojo_resource_synchronize_\(binding.bindingID)(session)"
                )
            }
            lines.append("    return -1")
            lines.append("")
            lines.append("")
            lines.append("# Host output remains borrowed until the synchronous transfer returns.")
            lines.append("@export(\"\(identity.symbolPrefix)_copy_f32_buffer_to_host_v1\")")
            lines.append("def \(identity.symbolPrefix)_copy_f32_buffer_to_host_v1(")
            lines.append("    binding_id: UInt64,")
            lines.append("    session: OpaquePointer[MutUntrackedOrigin],")
            lines.append("    buffer: OpaquePointer[MutUntrackedOrigin],")
            lines.append("    destination: Pointer[Float32, MutUntrackedOrigin],")
            lines.append("    element_count: UInt64,")
            lines.append(") abi(\"C\") -> Int32:")
            for binding in bufferFactories {
                lines.append("    if binding_id == \(binding.bindingID):")
                lines.append(
                    "        var status = __swift_mojo_resource_copy_to_host_\(binding.bindingID)(session, buffer, destination, element_count)"
                )
                lines.append("        if status != 0:")
                lines.append("            return status")
                lines.append(
                    "        return __swift_mojo_resource_synchronize_\(binding.bindingID)(session)"
                )
            }
            lines.append("    return -1")
        }

        if !sessionMutations.isEmpty {
            lines.append("")
            lines.append("")
            lines.append("# The session and buffers are borrowed only for this synchronous call.")
            lines.append("@export(\"\(identity.symbolPrefix)_call_session_f32_buffer_f32_buffer_i32_v1\")")
            lines.append("def \(identity.symbolPrefix)_call_session_f32_buffer_f32_buffer_i32_v1(")
            lines.append("    binding_id: UInt64,")
            lines.append("    session: OpaquePointer[MutUntrackedOrigin],")
            lines.append("    input: Pointer[Float32, ImmUntrackedOrigin],")
            lines.append("    input_count: UInt64,")
            lines.append("    output: Pointer[Float32, MutUntrackedOrigin],")
            lines.append("    output_count: UInt64,")
            lines.append(") abi(\"C\") -> Int32:")
            for binding in sessionMutations {
                lines.append("    if binding_id == \(binding.bindingID):")
                guard case .sessionExternal = binding.implementation else {
                    preconditionFailure(
                        "Session mutation bindings require external implementations"
                    )
                }
                lines.append(
                    "        return __swift_mojo_external_\(binding.bindingID)(session, input, input_count, output, output_count)"
                )
                if let source = binding.sourceReference {
                    entries.append(
                        MojoSourceMap.Entry(
                            generatedLine: lines.count,
                            bindingID: binding.bindingID,
                            source: source
                        )
                    )
                }
            }
            lines.append("    return -1")
        }

        return MojoRenderedSource(
            source: lines.joined(separator: "\n") + "\n",
            sourceMap: MojoSourceMap(
                inputGraphDigest: inputGraph.digest,
                entries: entries
            )
        )
    }

    package func header(identity: MojoArtifactIdentity) -> String {
        header(identity: identity, signatures: [.int32Binary])
    }

    package func header(
        identity: MojoArtifactIdentity,
        inputGraph: MojoInputGraph
    ) -> String {
        header(
            identity: identity,
            signatures: Set(inputGraph.bindingGraph.bindings.map(\.signature))
        )
    }

    private func header(
        identity: MojoArtifactIdentity,
        signatures: Set<MojoBinding.Signature>
    ) -> String {
        let prefix = identity.symbolPrefix
        var lines = [
            "#ifndef \(identity.moduleName.uppercased())_H",
            "#define \(identity.moduleName.uppercased())_H",
            "",
            "#include <stdint.h>",
            "",
            "#ifdef __cplusplus",
            "extern \"C\" {",
            "#endif",
            "",
            "uint32_t \(prefix)_static_abi_version(void);",
            "uint64_t \(prefix)_input_graph_identifier(void);",
            "uint32_t \(prefix)_has_binding(uint64_t binding_id);",
        ]
        if signatures.contains(.int32Binary) {
            lines.append(contentsOf: [
                "int32_t \(prefix)_call_i32_i32_i32(",
                "    uint64_t binding_id,",
                "    int32_t lhs,",
                "    int32_t rhs",
                ");",
            ])
        }
        if signatures.contains(.borrowedFloat32Buffer) {
            lines.append(contentsOf: [
                "float \(prefix)_call_f32_buffer_f32(",
                "    uint64_t binding_id,",
                "    const float *values,",
                "    uint64_t count",
                ");",
            ])
        }
        if signatures.contains(.borrowedMutableFloat32Buffers) {
            lines.append(contentsOf: [
                "int32_t \(prefix)_call_f32_buffer_f32_buffer_i32(",
                "    uint64_t binding_id,",
                "    const float *input,",
                "    uint64_t input_count,",
                "    float *output,",
                "    uint64_t output_count",
                ");",
            ])
        }
        if signatures.contains(.borrowedMutableFloat64Buffers) {
            lines.append(contentsOf: [
                "int32_t \(prefix)_call_f64_buffer_f64_buffer_i32(",
                "    uint64_t binding_id,",
                "    const double *input,",
                "    uint64_t input_count,",
                "    double *output,",
                "    uint64_t output_count",
                ");",
            ])
        }
        if signatures.contains(.runtimeSessionFactory) {
            lines.append(contentsOf: [
                "int32_t \(prefix)_create_session_v1(",
                "    uint64_t binding_id,",
                "    uint32_t request_schema,",
                "    uint32_t requested_device,",
                "    uint32_t requested_ordinal,",
                "    uint64_t required_capabilities,",
                "    void **session_out,",
                "    uint32_t *response_schema_out,",
                "    uint32_t *actual_device_out,",
                "    uint32_t *actual_ordinal_out,",
                "    uint64_t *available_capabilities_out",
                ");",
                "void \(prefix)_shutdown_session_v1(",
                "    uint64_t binding_id,",
                "    void *session",
                ");",
            ])
        }
        if signatures.contains(.sessionFloat32BufferFactory) {
            lines.append(contentsOf: [
                "int32_t \(prefix)_create_f32_buffer_v1(",
                "    uint64_t binding_id,",
                "    void *session,",
                "    uint64_t element_count,",
                "    uint32_t memory_kind,",
                "    void **buffer_out",
                ");",
                "void \(prefix)_shutdown_f32_buffer_v1(",
                "    uint64_t binding_id,",
                "    void *session,",
                "    void *buffer",
                ");",
                "int32_t \(prefix)_copy_host_to_f32_buffer_v1(",
                "    uint64_t binding_id,",
                "    void *session,",
                "    void *buffer,",
                "    const float *source,",
                "    uint64_t element_count",
                ");",
                "int32_t \(prefix)_copy_f32_buffer_to_host_v1(",
                "    uint64_t binding_id,",
                "    void *session,",
                "    void *buffer,",
                "    float *destination,",
                "    uint64_t element_count",
                ");",
            ])
        }
        if signatures.contains(.sessionBorrowedMutableFloat32Buffers) {
            lines.append(contentsOf: [
                "int32_t \(prefix)_call_session_f32_buffer_f32_buffer_i32_v1(",
                "    uint64_t binding_id,",
                "    void *session,",
                "    const float *input,",
                "    uint64_t input_count,",
                "    float *output,",
                "    uint64_t output_count",
                ");",
            ])
        }
        lines.append(contentsOf: [
            "",
            "#ifdef __cplusplus",
            "}",
            "#endif",
            "",
            "#endif",
        ])
        return lines.joined(separator: "\n") + "\n"
    }

    package func moduleMap(identity: MojoArtifactIdentity) -> String {
        """
        module \(identity.moduleName) {
            header "\(identity.moduleName).h"
            export *
        }
        """ + "\n"
    }

    package func frameworkModuleMap(identity: MojoArtifactIdentity) -> String {
        """
        framework module \(identity.moduleName) {
            umbrella header "\(identity.moduleName).h"
            export *
        }
        """ + "\n"
    }

}

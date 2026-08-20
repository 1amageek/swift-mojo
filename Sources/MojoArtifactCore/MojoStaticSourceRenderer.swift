import MojoBindingCore

package struct MojoStaticSourceRenderer: Sendable {
    package static let generationVersion = 2
    package static let borrowedFloat32BufferGenerationVersion = 1

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
        var lines: [String] = []
        var entries: [MojoSourceMap.Entry] = []

        if !bufferBindings.isEmpty {
            lines.append("from memory import UnsafePointer")
        }
        for binding in graph.bindings {
            guard case .external(let package, let function) = binding.implementation else {
                continue
            }
            lines.append(
                "from \(package) import \(function) as __swift_mojo_external_\(binding.bindingID)"
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
            lines.append("    values: UnsafePointer[Float32, ImmutExternalOrigin],")
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
}

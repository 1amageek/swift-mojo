import MojoBindingCore

package struct MojoStaticSourceRenderer: Sendable {
    package static let generationVersion = 1

    package init() {}

    package func mojoSource(for graph: MojoSourceGraph) -> String {
        let membership = graph.bindings.map { binding in
            """
                if binding_id == \(binding.bindingID):
                    return 1
            """
        }.joined(separator: "\n")
        let dispatch = graph.bindings.map { binding in
            """
                if binding_id == \(binding.bindingID):
                    return \(binding.mojoExpression)
            """
        }.joined(separator: "\n")

        return """
        @export("swift_mojo_static_abi_version")
        def swift_mojo_static_abi_version() abi("C") -> UInt32:
            return \(MojoStaticABI.version)


        @export("swift_mojo_source_graph_identifier")
        def swift_mojo_source_graph_identifier() abi("C") -> UInt64:
            return \(graph.digestIdentifier)


        @export("swift_mojo_has_binding")
        def swift_mojo_has_binding(binding_id: UInt64) abi("C") -> UInt32:
        \(membership)
            return 0


        # The Swift bridge validates ABI, source graph, and membership before dispatch.
        @export("swift_mojo_call_i32_i32_i32")
        def swift_mojo_call_i32_i32_i32(binding_id: UInt64, lhs: Int32, rhs: Int32) abi("C") -> Int32:
        \(dispatch)
            return 0
        """ + "\n"
    }

    package var header: String {
        """
        #ifndef GENERATED_MOJO_ABI_H
        #define GENERATED_MOJO_ABI_H

        #include <stdint.h>

        #ifdef __cplusplus
        extern "C" {
        #endif

        uint32_t swift_mojo_static_abi_version(void);
        uint64_t swift_mojo_source_graph_identifier(void);
        uint32_t swift_mojo_has_binding(uint64_t binding_id);
        int32_t swift_mojo_call_i32_i32_i32(
            uint64_t binding_id,
            int32_t lhs,
            int32_t rhs
        );

        #ifdef __cplusplus
        }
        #endif

        #endif
        """ + "\n"
    }

    package var moduleMap: String {
        """
        module GeneratedMojoABI {
            header "GeneratedMojoABI.h"
            export *
        }
        """ + "\n"
    }
}

import Foundation
import MojoBindingCore

// Opaque resources retain their authored representation across direct calls.
package enum MojoOpaqueResourceRendering {
    package static func symbols(_ binding: MojoBinding, prefix: String) -> [String] {
        switch binding.signature {
        case .opaqueResourceFactory:
            ["\(prefix)_resource_create_\(binding.bindingID)", "\(prefix)_resource_destroy_\(binding.bindingID)"]
        case .opaqueResourceOperation:
            ["\(prefix)_resources_call_\(binding.bindingID)"]
        default: []
        }
    }

    package static func source(_ binding: MojoBinding, prefix: String) -> [String] {
        let id = binding.bindingID
        let session = "session: OpaquePointer[MutUntrackedOrigin]"
        switch binding.implementation {
        case .opaqueResource(let package, let create, let shutdown, let synchronize, _):
            return """

            from \(package) import \(create) as __opaque_create_\(id)
            from \(package) import \(shutdown) as __opaque_destroy_\(id)
            from \(package) import \(synchronize) as __opaque_sync_\(id)

            @export("\(prefix)_resource_create_\(id)")
            def \(prefix)_resource_create_\(id)(\(session), config: Pointer[UInt8, ImmUntrackedOrigin], count: UInt64, result: Pointer[OpaquePointer[MutUntrackedOrigin], MutUntrackedOrigin]) abi("C") -> Int32:
                status = __opaque_create_\(id)(session, config, count, result)
                completion = __opaque_sync_\(id)(session)
                if status != 0:
                    return status
                return completion

            @export("\(prefix)_resource_destroy_\(id)")
            def \(prefix)_resource_destroy_\(id)(\(session), resource: OpaquePointer[MutUntrackedOrigin]) abi("C"):
                __opaque_destroy_\(id)(session, resource)
            """.components(separatedBy: "\n")
        case .opaqueResourceExternal(let package, let function, let synchronize, _, _):
            return """

            from \(package) import \(function) as __opaque_call_\(id)
            from \(package) import \(synchronize) as __opaque_sync_\(id)

            @export("\(prefix)_resources_call_\(id)")
            def \(prefix)_resources_call_\(id)(\(session), resources: Pointer[OpaquePointer[MutUntrackedOrigin], ImmUntrackedOrigin], count: UInt64) abi("C") -> Int32:
                status = __opaque_call_\(id)(session, resources, count)
                completion = __opaque_sync_\(id)(session)
                if status != 0:
                    return status
                return completion
            """.components(separatedBy: "\n")
        default: return []
        }
    }

    package static func header(_ binding: MojoBinding, prefix: String) -> [String] {
        let id = binding.bindingID
        switch binding.signature {
        case .opaqueResourceFactory:
            return [
                "int32_t \(prefix)_resource_create_\(id)(void *session, const uint8_t *config, uint64_t count, void **result);",
                "void \(prefix)_resource_destroy_\(id)(void *session, void *resource);",
            ]
        case .opaqueResourceOperation:
            return ["int32_t \(prefix)_resources_call_\(id)(void *session, void *const *resources, uint64_t count);"]
        default: return []
        }
    }

    package static func registry(
        inputGraph: MojoInputGraph, identity: MojoArtifactIdentity,
        domain: (UInt64) -> UInt64
    ) -> [String] {
        let bindings = inputGraph.bindingGraph.bindings
        let prefix = identity.symbolPrefix
        var factories: [String] = []
        var operations: [String] = []
        for binding in bindings {
            let id = binding.bindingID
            switch binding.implementation {
            case .opaqueResource(_, _, _, _, let sessionFactory):
                let factory = bindings.first { $0.functionName == sessionFactory && $0.signature == .runtimeSessionFactory }!
                factories.append("""
                        case \(id):
                            return try values.withUnsafeBufferPointer { config in
                                try session.createResource(
                                    expectedSessionDomainID: \(domain(factory.bindingID)),
                                    factoryBindingID: \(id),
                                    create: { handle in
                                        var result: UnsafeMutableRawPointer?
                                        let status = \(prefix)_resource_create_\(id)(handle, config.baseAddress, UInt64(config.count), &result)
                                        guard status == 0 else {
                                            if let result { \(prefix)_resource_destroy_\(id)(handle, result) }
                                            throw MojoInvocationError.invocationFailed(bindingID: bindingID, status: status)
                                        }
                                        guard let result else {
                                            throw MojoInvocationError.resourceCreationReturnedNoHandle(bindingID: bindingID)
                                        }
                                        return result
                                    },
                                    destroy: { \(prefix)_resource_destroy_\(id)($0, $1) }
                                )
                            }
                """)
            case .opaqueResourceExternal(_, _, _, let sessionFactory, let resourceFactory):
                let factory = bindings.first { $0.functionName == sessionFactory && $0.signature == .runtimeSessionFactory }!
                let resource = bindings.first { $0.functionName == resourceFactory && $0.signature == .opaqueResourceFactory }!
                operations.append("""
                        case \(id):
                            try session.withResourceHandles(
                                resources: values,
                                expectedSessionDomainID: \(domain(factory.bindingID)),
                                expectedFactoryBindingID: \(resource.bindingID)
                            ) { handle, resources in
                                let status = \(prefix)_resources_call_\(id)(handle, resources.baseAddress, UInt64(resources.count))
                                guard status == 0 else {
                                    throw MojoInvocationError.invocationFailed(bindingID: bindingID, status: status)
                                }
                            }
                """)
            default: break
            }
        }
        var methods: [String] = []
        if !factories.isEmpty {
            methods.append("""
                static func makeOpaqueResource(bindingID: UInt64, session: MojoSessionOwner, values: borrowing Span<UInt8>) throws -> MojoSessionResourceOwner {
                    try artifactPreflight.requireValid()
                    switch bindingID {
                \(factories.joined(separator: "\n"))
                    default: throw MojoInvocationError.bindingUnavailable(bindingID: bindingID)
                    }
                }
            """)
        }
        if !operations.isEmpty {
            methods.append("""
                static func invokeOpaqueResources(bindingID: UInt64, session: MojoSessionOwner, values: borrowing Span<MojoSessionResourceOwner>) throws {
                    try artifactPreflight.requireValid()
                    switch bindingID {
                \(operations.joined(separator: "\n"))
                    default: throw MojoInvocationError.bindingUnavailable(bindingID: bindingID)
                    }
                }
            """)
        }
        return methods
    }
}

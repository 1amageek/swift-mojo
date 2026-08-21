import MojoBindingCore

package struct MojoStaticRegistryWriter: Sendable {
    package static let generationVersion = 3
    package static let borrowedFloat32BufferGenerationVersion = 1
    package static let borrowedMutableFloat32BuffersGenerationVersion = 1
    package static let runtimeSessionGenerationVersion = 1
    package static let sessionResourceGenerationVersion = 2

    package init() {}

    package func source(
        manifest: MojoArtifactManifest,
        inputGraph: MojoInputGraph
    ) -> String {
        let signatures = Set(
            inputGraph.bindingGraph.bindings.map(\.signature)
        )
        let bindingIDs = inputGraph.bindingGraph.bindings
            .map { String($0.bindingID) }
            .joined(separator: ", ")
        let scalarBindingCases = inputGraph.bindingGraph.bindings
            .filter { $0.signature == .int32Binary }
            .map { String($0.bindingID) }
            .joined(separator: ", ")
        let bufferBindingCases = inputGraph.bindingGraph.bindings
            .filter { $0.signature == .borrowedFloat32Buffer }
            .map { String($0.bindingID) }
            .joined(separator: ", ")
        let mutationBindingCases = inputGraph.bindingGraph.bindings
            .filter { $0.signature == .borrowedMutableFloat32Buffers }
            .map { String($0.bindingID) }
            .joined(separator: ", ")
        let sessionFactories = inputGraph.bindingGraph.bindings.filter {
            $0.signature == .runtimeSessionFactory
        }
        let sessionFactoryCases = sessionFactories
            .map { String($0.bindingID) }
            .joined(separator: ", ")
        let sessionMutations = inputGraph.bindingGraph.bindings.filter {
            $0.signature == .sessionBorrowedMutableFloat32Buffers
        }
        let bufferFactories = inputGraph.bindingGraph.bindings.filter {
            $0.signature == .sessionFloat32BufferFactory
        }
        let bufferFactoryCases = bufferFactories
            .map { String($0.bindingID) }
            .joined(separator: ", ")
        let sessionMutationCases = sessionMutations
            .map { String($0.bindingID) }
            .joined(separator: ", ")
        let identity = manifest.effectiveIdentity
        let prefix = identity.symbolPrefix
        let conditions = Set(
            manifest.effectiveSlices.compactMap {
                Self.swiftCondition(for: $0.target.triple)
            }
        ).sorted().joined(separator: " || ")
        let platformGuard = conditions.isEmpty
            ? "#error(\"The prepared Mojo artifact has no Swift-compatible native slice\")"
            : "#if \(conditions)\n#else\n#error(\"The prepared Mojo artifact does not support this Swift destination\")\n#endif"
        let expectedInputGraph = manifest.inputGraphIdentifier
            ?? manifest.sourceGraphIdentifier
        let graphFunction = manifest.schemaVersion
            == MojoArtifactManifest.legacySchemaVersion
            ? "\(prefix)_source_graph_identifier"
            : "\(prefix)_input_graph_identifier"
        let preparedBindingStorage =
            "private static let preparedBindingIDs: [UInt64] = [\(bindingIDs)]"
        let validationCache = """
        private static let artifactValidationError: MojoInvocationError? = {
            let actualABIVersion = \(prefix)_static_abi_version()
            guard actualABIVersion == expectedABIVersion else {
                return .incompatibleStaticABI(
                    expected: expectedABIVersion,
                    actual: actualABIVersion
                )
            }
            let actualInputGraph = \(graphFunction)()
            guard actualInputGraph == expectedInputGraph else {
                return .inputGraphMismatch(
                    expected: expectedInputGraph,
                    actual: actualInputGraph
                )
            }
            for bindingID in preparedBindingIDs
            where \(prefix)_has_binding(bindingID) != 1 {
                return .bindingUnavailable(bindingID: bindingID)
            }
            return nil
        }()
        """
        var methods: [String] = []
        if signatures.contains(.int32Binary) {
            methods.append(
                """
                    @inline(__always)
                    static func invokeInt32Binary(
                        bindingID: UInt64,
                        lhs: Int32,
                        rhs: Int32
                    ) -> Int32 {
                        if let error = artifactValidationError {
                            fatalError(error.description)
                        }
                        switch bindingID {
                        case \(scalarBindingCases):
                            break
                        default:
                            fatalError("The linked Mojo artifact does not contain the requested binding")
                        }
                        return \(prefix)_call_i32_i32_i32(bindingID, lhs, rhs)
                    }
                """
            )
        }
        if signatures.contains(.borrowedFloat32Buffer) {
            methods.append(
                """
                    @inline(__always)
                    static func invokeFloatBuffer(
                        bindingID: UInt64,
                        values: borrowing [Float]
                    ) throws -> Float {
                        if let error = artifactValidationError {
                            throw error
                        }
                        switch bindingID {
                        case \(bufferBindingCases):
                            break
                        default:
                            throw MojoInvocationError.bindingUnavailable(
                                bindingID: bindingID
                            )
                        }
                        return try values.withUnsafeBufferPointer { buffer in
                            guard let baseAddress = buffer.baseAddress,
                                  !buffer.isEmpty else {
                                throw MojoInvocationError.emptyBorrowedBuffer
                            }
                            return \(prefix)_call_f32_buffer_f32(
                                bindingID,
                                baseAddress,
                                UInt64(buffer.count)
                            )
                        }
                    }
                """
            )
        }
        if signatures.contains(.borrowedMutableFloat32Buffers) {
            methods.append(
                """
                    @inline(__always)
                    static func invokeFloatBufferMutation(
                        bindingID: UInt64,
                        input: borrowing [Float],
                        output: inout [Float]
                    ) throws {
                        if let error = artifactValidationError {
                            throw error
                        }
                        switch bindingID {
                        case \(mutationBindingCases):
                            break
                        default:
                            throw MojoInvocationError.bindingUnavailable(
                                bindingID: bindingID
                            )
                        }
                        try input.withUnsafeBufferPointer { inputBuffer in
                            guard let inputBaseAddress = inputBuffer.baseAddress,
                                  !inputBuffer.isEmpty else {
                                throw MojoInvocationError.emptyBorrowedBuffer
                            }
                            try output.withUnsafeMutableBufferPointer { outputBuffer in
                                guard let outputBaseAddress = outputBuffer.baseAddress,
                                      !outputBuffer.isEmpty else {
                                    throw MojoInvocationError.emptyMutableBuffer
                                }
                                let status = \(prefix)_call_f32_buffer_f32_buffer_i32(
                                    bindingID,
                                    inputBaseAddress,
                                    UInt64(inputBuffer.count),
                                    outputBaseAddress,
                                    UInt64(outputBuffer.count)
                                )
                                guard status == 0 else {
                                    throw MojoInvocationError.invocationFailed(
                                        bindingID: bindingID,
                                        status: status
                                    )
                                }
                            }
                        }
                    }
                """
            )
        }
        if signatures.contains(.runtimeSessionFactory) {
            let factoryDomains = sessionFactories.map { binding in
                "case \(binding.bindingID): sessionDomainID = \(Self.sessionDomainID(identity: identity, inputGraph: inputGraph, factoryBindingID: binding.bindingID))"
            }.joined(separator: "\n            ")
            methods.append(
                """
                    @inline(__always)
                    static func makeSession(
                        bindingID: UInt64,
                        requirements: MojoSessionRequirements
                    ) throws -> MojoSessionOwner {
                        if let error = artifactValidationError {
                            throw error
                        }
                        switch bindingID {
                        case \(sessionFactoryCases):
                            break
                        default:
                            throw MojoInvocationError.bindingUnavailable(
                                bindingID: bindingID
                            )
                        }
                        let sessionDomainID: UInt64
                        switch bindingID {
                        \(factoryDomains)
                        default:
                            throw MojoInvocationError.bindingUnavailable(
                                bindingID: bindingID
                            )
                        }
                        var handle: UnsafeMutableRawPointer?
                        var responseSchema: UInt32 = 0
                        var actualDeviceRawValue: UInt32 = 0
                        var actualOrdinal: UInt32 = 0
                        var availableCapabilityBits: UInt64 = 0
                        let status = \(prefix)_create_session_v1(
                            bindingID,
                            MojoSessionRequirements.currentSchemaVersion,
                            requirements.device.rawValue,
                            requirements.ordinal,
                            requirements.requiredCapabilities.rawValue,
                            &handle,
                            &responseSchema,
                            &actualDeviceRawValue,
                            &actualOrdinal,
                            &availableCapabilityBits
                        )
                        guard status == 0 else {
                            if let handle {
                                \(prefix)_shutdown_session_v1(bindingID, handle)
                            }
                            throw MojoInvocationError.invocationFailed(
                                bindingID: bindingID,
                                status: status
                            )
                        }
                        guard let handle else {
                            throw MojoInvocationError.sessionCreationReturnedNoHandle(
                                bindingID: bindingID
                            )
                        }
                        guard responseSchema
                                == MojoSessionRequirements.currentSchemaVersion else {
                            \(prefix)_shutdown_session_v1(bindingID, handle)
                            throw MojoInvocationError.invalidSessionResponseSchema(
                                bindingID: bindingID,
                                expected: MojoSessionRequirements.currentSchemaVersion,
                                actual: responseSchema
                            )
                        }
                        guard let actualDevice = MojoDeviceKind(
                            rawValue: actualDeviceRawValue
                        ) else {
                            \(prefix)_shutdown_session_v1(bindingID, handle)
                            throw MojoInvocationError.invalidSessionDeviceKind(
                                bindingID: bindingID,
                                rawValue: actualDeviceRawValue
                            )
                        }
                        let capabilities = MojoSessionCapabilities(
                            device: actualDevice,
                            ordinal: actualOrdinal,
                            availableCapabilities: MojoSessionCapability(
                                rawValue: availableCapabilityBits
                            )
                        )
                        guard capabilities.satisfies(requirements) else {
                            \(prefix)_shutdown_session_v1(bindingID, handle)
                            throw MojoInvocationError.sessionRequirementsUnsatisfied(
                                bindingID: bindingID,
                                requirements: requirements,
                                actual: capabilities
                            )
                        }
                        return MojoSessionOwner(
                            handle: handle,
                            sessionDomainID: sessionDomainID,
                            capabilities: capabilities,
                            destroy: { handle in
                                \(prefix)_shutdown_session_v1(bindingID, handle)
                            }
                        )
                    }
                """
            )
        }
        if signatures.contains(.sessionFloat32BufferFactory) {
            let factoryByName = Dictionary(
                uniqueKeysWithValues: sessionFactories.map {
                    ($0.functionName, $0)
                }
            )
            let resourceDomains = bufferFactories.map { binding -> String in
                guard case .sessionResource(
                    _,
                    _,
                    _,
                    _,
                    _,
                    _,
                    let sessionFactory
                ) = binding.implementation,
                let factory = factoryByName[sessionFactory] else {
                    preconditionFailure(
                        "The source graph must resolve every buffer factory"
                    )
                }
                let domainID = Self.sessionDomainID(
                    identity: identity,
                    inputGraph: inputGraph,
                    factoryBindingID: factory.bindingID
                )
                return "case \(binding.bindingID): sessionDomainID = \(domainID)"
            }.joined(separator: "\n            ")
            methods.append(
                """
                    @inline(__always)
                    static func makeFloat32Buffer(
                        bindingID: UInt64,
                        session: MojoSessionOwner,
                        elementCount: UInt64,
                        memoryKind: MojoBufferMemoryKind
                    ) throws -> MojoFloat32BufferOwner {
                        if let error = artifactValidationError {
                            throw error
                        }
                        switch bindingID {
                        case \(bufferFactoryCases):
                            break
                        default:
                            throw MojoInvocationError.bindingUnavailable(
                                bindingID: bindingID
                            )
                        }
                        let sessionDomainID: UInt64
                        switch bindingID {
                        \(resourceDomains)
                        default:
                            throw MojoInvocationError.bindingUnavailable(
                                bindingID: bindingID
                            )
                        }
                        return try MojoFloat32BufferOwner.create(
                            session: session,
                            expectedSessionDomainID: sessionDomainID,
                            elementCount: elementCount,
                            memoryKind: memoryKind,
                            create: { sessionHandle, count in
                                var buffer: UnsafeMutableRawPointer?
                                let status = \(prefix)_create_f32_buffer_v1(
                                    bindingID,
                                    sessionHandle,
                                    count,
                                    memoryKind.rawValue,
                                    &buffer
                                )
                                guard status == 0 else {
                                    if let buffer {
                                        \(prefix)_shutdown_f32_buffer_v1(
                                            bindingID,
                                            sessionHandle,
                                            buffer
                                        )
                                    }
                                    throw MojoInvocationError.invocationFailed(
                                        bindingID: bindingID,
                                        status: status
                                    )
                                }
                                guard let buffer else {
                                    throw MojoInvocationError.resourceCreationReturnedNoHandle(
                                        bindingID: bindingID
                                    )
                                }
                                return buffer
                            },
                            destroy: { sessionHandle, buffer in
                                \(prefix)_shutdown_f32_buffer_v1(
                                    bindingID,
                                    sessionHandle,
                                    buffer
                                )
                            },
                            copyFromHost: {
                                sessionHandle,
                                buffer,
                                source,
                                count in
                                let status = \(prefix)_copy_host_to_f32_buffer_v1(
                                    bindingID,
                                    sessionHandle,
                                    buffer,
                                    source,
                                    count
                                )
                                guard status == 0 else {
                                    throw MojoInvocationError.invocationFailed(
                                        bindingID: bindingID,
                                        status: status
                                    )
                                }
                            },
                            copyToHost: {
                                sessionHandle,
                                buffer,
                                destination,
                                count in
                                let status = \(prefix)_copy_f32_buffer_to_host_v1(
                                    bindingID,
                                    sessionHandle,
                                    buffer,
                                    destination,
                                    count
                                )
                                guard status == 0 else {
                                    throw MojoInvocationError.invocationFailed(
                                        bindingID: bindingID,
                                        status: status
                                    )
                                }
                            }
                        )
                    }
                """
            )
        }
        if signatures.contains(.sessionBorrowedMutableFloat32Buffers) {
            let factoryByName = Dictionary(
                uniqueKeysWithValues: sessionFactories.map {
                    ($0.functionName, $0)
                }
            )
            let mutationDomains = sessionMutations.map { binding -> String in
                guard case .sessionExternal(
                    _,
                    _,
                    let sessionFactory
                ) = binding.implementation,
                let factory = factoryByName[sessionFactory] else {
                    preconditionFailure(
                        "The source graph must resolve every session-bound binding"
                    )
                }
                let domainID = Self.sessionDomainID(
                    identity: identity,
                    inputGraph: inputGraph,
                    factoryBindingID: factory.bindingID
                )
                return "case \(binding.bindingID): sessionDomainID = \(domainID)"
            }.joined(separator: "\n            ")
            methods.append(
                """
                    @inline(__always)
                    static func invokeSessionFloatBufferMutation(
                        bindingID: UInt64,
                        session: MojoSessionOwner,
                        input: borrowing [Float],
                        output: inout [Float]
                    ) throws {
                        if let error = artifactValidationError {
                            throw error
                        }
                        switch bindingID {
                        case \(sessionMutationCases):
                            break
                        default:
                            throw MojoInvocationError.bindingUnavailable(
                                bindingID: bindingID
                            )
                        }
                        let sessionDomainID: UInt64
                        switch bindingID {
                        \(mutationDomains)
                        default:
                            throw MojoInvocationError.bindingUnavailable(
                                bindingID: bindingID
                            )
                        }
                        try session.withOpaqueHandle(
                            expectedSessionDomainID: sessionDomainID
                        ) { handle in
                            try input.withUnsafeBufferPointer { inputBuffer in
                                guard let inputBaseAddress = inputBuffer.baseAddress,
                                      !inputBuffer.isEmpty else {
                                    throw MojoInvocationError.emptyBorrowedBuffer
                                }
                                try output.withUnsafeMutableBufferPointer { outputBuffer in
                                    guard let outputBaseAddress = outputBuffer.baseAddress,
                                          !outputBuffer.isEmpty else {
                                        throw MojoInvocationError.emptyMutableBuffer
                                    }
                                    let status = \(prefix)_call_session_f32_buffer_f32_buffer_i32_v1(
                                        bindingID,
                                        handle,
                                        inputBaseAddress,
                                        UInt64(inputBuffer.count),
                                        outputBaseAddress,
                                        UInt64(outputBuffer.count)
                                    )
                                    guard status == 0 else {
                                        throw MojoInvocationError.invocationFailed(
                                            bindingID: bindingID,
                                            status: status
                                        )
                                    }
                                }
                            }
                        }
                    }
                """
            )
        }
        let mojoImport = signatures.contains(.runtimeSessionFactory)
            || signatures.contains(.sessionFloat32BufferFactory)
            || signatures.contains(.sessionBorrowedMutableFloat32Buffers)
            ? "@_spi(SwiftMojoGenerated) import Mojo"
            : "import Mojo"
        return """
        // Generated by swift-mojo. Do not edit.
        // Artifact SHA-256: \(manifest.artifactDigest)
        // Generation pipeline SHA-256: \(manifest.generationPipelineDigest)
        \(mojoImport)
        import \(identity.moduleName)

        \(platformGuard)

        enum __SwiftMojoGeneratedBindings {
            private static let expectedABIVersion: UInt32 = \(manifest.abiVersion)
            private static let expectedInputGraph: UInt64 = \(expectedInputGraph)
            \(preparedBindingStorage)
        \(validationCache)

        \(methods.joined(separator: "\n\n"))
        }
        """ + "\n"
    }

    private static func sessionDomainID(
        identity: MojoArtifactIdentity,
        inputGraph: MojoInputGraph,
        factoryBindingID: UInt64
    ) -> UInt64 {
        MojoCanonicalDigest.identifier(
            [
                "swift-mojo-session-domain-v1",
                identity.targetName,
                inputGraph.digest,
                String(factoryBindingID),
            ].joined(separator: "|")
        )
    }

    private static func swiftCondition(for triple: String) -> String? {
        let normalized = triple.lowercased()
        let architecture: String
        if normalized.hasPrefix("arm64-") || normalized.hasPrefix("aarch64-") {
            architecture = "arm64"
        } else if normalized.hasPrefix("x86_64-") {
            architecture = "x86_64"
        } else {
            return nil
        }

        let operatingSystem: String
        if normalized.contains("-apple-macos") {
            operatingSystem = "macOS"
        } else if normalized.contains("-apple-ios") {
            operatingSystem = "iOS"
        } else if normalized.contains("-linux-") {
            operatingSystem = "Linux"
        } else {
            return nil
        }
        return "(arch(\(architecture)) && os(\(operatingSystem)))"
    }
}

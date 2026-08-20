import MojoBindingCore

package struct MojoStaticRegistryWriter: Sendable {
    package static let generationVersion = 2
    package static let borrowedFloat32BufferGenerationVersion = 1

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
        let identity = manifest.effectiveIdentity
        let prefix = identity.symbolPrefix
        let conditions = Set(
            manifest.effectiveSlices.compactMap {
                Self.swiftCondition(for: $0.target.triple)
            }
        ).sorted().joined(separator: " || ")
        let platformGuard = conditions.isEmpty
            ? "#error(\"The prepared Mojo artifact has no Swift-compatible Apple slice\")"
            : "#if \(conditions)\n#else\n#error(\"The prepared Mojo artifact does not support this Swift destination\")\n#endif"
        let expectedInputGraph = manifest.inputGraphIdentifier
            ?? manifest.sourceGraphIdentifier
        let graphFunction = manifest.schemaVersion
            == MojoArtifactManifest.legacySchemaVersion
            ? "\(prefix)_source_graph_identifier"
            : "\(prefix)_input_graph_identifier"
        let mojoImport = signatures.contains(.borrowedFloat32Buffer)
            ? "\nimport Mojo"
            : ""
        let usesBorrowedBuffer = signatures.contains(.borrowedFloat32Buffer)
        let preparedBindingStorage = usesBorrowedBuffer
            ? "private static let preparedBindingIDs: [UInt64] = [\(bindingIDs)]"
            : "private static let preparedBindingIDs: Set<UInt64> = [\(bindingIDs)]"
        let validationCache = usesBorrowedBuffer
            ? """
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
            : ""
        var methods: [String] = []
        if signatures.contains(.int32Binary) {
            let validation: String
            if usesBorrowedBuffer {
                validation = """
                    if let error = artifactValidationError {
                        fatalError(error.description)
                    }
                    switch bindingID {
                    case \(scalarBindingCases):
                        break
                    default:
                        fatalError("The linked Mojo artifact does not contain the requested binding")
                    }
                """
            } else {
                validation = """
                    guard \(prefix)_static_abi_version() == expectedABIVersion else {
                        fatalError("The linked Mojo artifact has an incompatible static ABI")
                    }
                    guard \(graphFunction)() == expectedInputGraph else {
                        fatalError("The linked Mojo artifact does not match the prepared input graph")
                    }
                    guard preparedBindingIDs.contains(bindingID),
                          \(prefix)_has_binding(bindingID) == 1 else {
                        fatalError("The linked Mojo artifact does not contain the requested binding")
                    }
                """
            }
            methods.append(
                """
                    @inline(__always)
                    static func invokeInt32Binary(
                        bindingID: UInt64,
                        lhs: Int32,
                        rhs: Int32
                    ) -> Int32 {
                \(validation)
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
        return """
        // Generated by swift-mojo. Do not edit.
        // Artifact SHA-256: \(manifest.artifactDigest)
        // Generation pipeline SHA-256: \(manifest.generationPipelineDigest)
        import \(identity.moduleName)\(mojoImport)

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
        } else {
            return nil
        }
        return "(arch(\(architecture)) && os(\(operatingSystem)))"
    }
}

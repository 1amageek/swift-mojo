import MojoRuntime

enum RuntimeWorkerAcceptanceProjectionOracle {
    static let expectedOutputBitPatterns: [UInt32] = [
        Float(2).bitPattern,
        Float(4).bitPattern,
        Float(6).bitPattern,
    ]

    static func verify(
        projection: MojoRuntimeWorkerBundleVerification,
        artifact: RuntimeWorkerAcceptanceContract.Artifact,
        protocolRecord: RuntimeWorkerAcceptanceContract.ProtocolRecord
    ) throws -> Int {
        var fieldCount = 0

        try equal(
            projection.schemaVersion,
            artifact.schemaVersion,
            "artifact.schemaVersion",
            count: &fieldCount
        )
        try equal(
            projection.bundleDigest,
            artifact.bundleDigest,
            "artifact.bundleDigest",
            count: &fieldCount
        )
        try equal(
            projection.executionContractDigest,
            artifact.executionContractDigest,
            "artifact.executionContractDigest",
            count: &fieldCount
        )

        let semantic = artifact.semanticIdentity
        try equal(
            projection.workerABIVersion,
            semantic.workerABIVersion,
            "artifact.semanticIdentity.workerABIVersion",
            count: &fieldCount
        )
        try equal(
            projection.protocolVersion,
            semantic.protocolVersion,
            "artifact.semanticIdentity.protocolVersion",
            count: &fieldCount
        )
        try equal(
            projection.sourceGraphDigest,
            semantic.sourceGraphDigest,
            "artifact.semanticIdentity.sourceGraphDigest",
            count: &fieldCount
        )
        try equal(
            projection.sourceGraphIdentifier,
            semantic.sourceGraphIdentifier,
            "artifact.semanticIdentity.sourceGraphIdentifier",
            count: &fieldCount
        )
        try equal(
            projection.inputGraphDigest,
            semantic.inputGraphDigest,
            "artifact.semanticIdentity.inputGraphDigest",
            count: &fieldCount
        )
        try equal(
            projection.inputGraphIdentifier,
            semantic.inputGraphIdentifier,
            "artifact.semanticIdentity.inputGraphIdentifier",
            count: &fieldCount
        )
        try equal(
            projection.generationPipelineDigest,
            semantic.generationPipelineDigest,
            "artifact.semanticIdentity.generationPipelineDigest",
            count: &fieldCount
        )
        try equal(
            projection.bindingTableDigest,
            semantic.bindingTableDigest,
            "artifact.semanticIdentity.bindingTableDigest",
            count: &fieldCount
        )
        try equal(
            projection.bindings.count,
            semantic.bindings.count,
            "artifact.semanticIdentity.bindings.count",
            count: &fieldCount
        )
        for (index, pair) in zip(projection.bindings, semantic.bindings)
            .enumerated()
        {
            try equal(
                pair.0.bindingID,
                pair.1.bindingID,
                "artifact.semanticIdentity.bindings[\(index)].bindingID",
                count: &fieldCount
            )
            try equal(
                pair.0.functionName,
                pair.1.functionName,
                "artifact.semanticIdentity.bindings[\(index)].functionName",
                count: &fieldCount
            )
            try equal(
                pair.0.signature.rawValue,
                pair.1.signature.rawValue,
                "artifact.semanticIdentity.bindings[\(index)].signature",
                count: &fieldCount
            )
            try equal(
                pair.0.sessionFactoryFunctionName,
                pair.1.sessionFactoryFunctionName,
                "artifact.semanticIdentity.bindings[\(index)].sessionFactoryFunctionName",
                count: &fieldCount
            )
        }

        let generated = artifact.generatedInputs
        try equal(
            projection.generatedMojoSourceDigest,
            generated.generatedMojoSourceDigest,
            "artifact.generatedInputs.generatedMojoSourceDigest",
            count: &fieldCount
        )
        try equal(
            projection.generatedCWorkerSourceDigest,
            generated.generatedCWorkerSourceDigest,
            "artifact.generatedInputs.generatedCWorkerSourceDigest",
            count: &fieldCount
        )
        try equal(
            projection.sourceMapDigest,
            generated.sourceMapDigest,
            "artifact.generatedInputs.sourceMapDigest",
            count: &fieldCount
        )
        try equal(
            projection.generatedMojoObjectDigest,
            generated.generatedMojoObjectDigest,
            "artifact.generatedInputs.generatedMojoObjectDigest",
            count: &fieldCount
        )
        try equal(
            projection.generatedCWorkerObjectDigest,
            generated.generatedCWorkerObjectDigest,
            "artifact.generatedInputs.generatedCWorkerObjectDigest",
            count: &fieldCount
        )
        try equal(
            projection.compilerVersion,
            generated.compilerVersion,
            "artifact.generatedInputs.compilerVersion",
            count: &fieldCount
        )

        let runtime = artifact.runtimeBundle
        try equal(
            projection.runtimeBundleManifestDigest,
            runtime.manifestDigest,
            "artifact.runtimeBundle.manifestDigest",
            count: &fieldCount
        )
        try equal(
            projection.runtimeReceiptDigest,
            runtime.receiptDigest,
            "artifact.runtimeBundle.receiptDigest",
            count: &fieldCount
        )
        try equal(
            projection.executable.relativePath,
            runtime.executable.relativePath,
            "artifact.runtimeBundle.executable.relativePath",
            count: &fieldCount
        )
        try equal(
            projection.executable.sha256Digest,
            runtime.executable.sha256Digest,
            "artifact.runtimeBundle.executable.sha256Digest",
            count: &fieldCount
        )
        try equal(
            projection.libraries.count,
            runtime.libraries.count,
            "artifact.runtimeBundle.libraries.count",
            count: &fieldCount
        )
        for (index, pair) in zip(projection.libraries, runtime.libraries)
            .enumerated()
        {
            try equal(
                pair.0.relativePath,
                pair.1.relativePath,
                "artifact.runtimeBundle.libraries[\(index)].relativePath",
                count: &fieldCount
            )
            try equal(
                pair.0.sha256Digest,
                pair.1.sha256Digest,
                "artifact.runtimeBundle.libraries[\(index)].sha256Digest",
                count: &fieldCount
            )
        }
        try equal(
            projection.loaderSearchPath,
            runtime.loaderSearchPath,
            "artifact.runtimeBundle.loaderSearchPath",
            count: &fieldCount
        )
        try equal(
            projection.systemDependencies,
            runtime.systemDependencies,
            "artifact.runtimeBundle.systemDependencies",
            count: &fieldCount
        )
        try equal(
            projection.programInterpreter,
            runtime.programInterpreter,
            "artifact.runtimeBundle.programInterpreter",
            count: &fieldCount
        )

        let target = artifact.targetClosure
        try equal(
            projection.target.triple,
            target.targetTriple,
            "artifact.targetClosure.targetTriple",
            count: &fieldCount
        )
        try equal(
            projection.target.cpu,
            target.targetCPU,
            "artifact.targetClosure.targetCPU",
            count: &fieldCount
        )
        try equal(
            projection.target.accelerator,
            target.targetAccelerator,
            "artifact.targetClosure.targetAccelerator",
            count: &fieldCount
        )
        try equal(
            projection.artifactIdentity.targetName,
            target.artifactIdentity.targetName,
            "artifact.targetClosure.artifactIdentity.targetName",
            count: &fieldCount
        )
        try equal(
            projection.artifactIdentity.moduleName,
            target.artifactIdentity.moduleName,
            "artifact.targetClosure.artifactIdentity.moduleName",
            count: &fieldCount
        )
        try equal(
            projection.artifactIdentity.artifactName,
            target.artifactIdentity.artifactName,
            "artifact.targetClosure.artifactIdentity.artifactName",
            count: &fieldCount
        )
        try equal(
            projection.artifactIdentity.libraryName,
            target.artifactIdentity.libraryName,
            "artifact.targetClosure.artifactIdentity.libraryName",
            count: &fieldCount
        )
        try equal(
            projection.artifactIdentity.symbolPrefix,
            target.artifactIdentity.symbolPrefix,
            "artifact.targetClosure.artifactIdentity.symbolPrefix",
            count: &fieldCount
        )
        try equal(
            projection.targetClosureDigest,
            target.targetClosureDigest,
            "artifact.targetClosure.targetClosureDigest",
            count: &fieldCount
        )

        try equal(
            projection.protocolVersion,
            protocolRecord.version,
            "protocol.version",
            count: &fieldCount
        )
        try equal(
            projection.protocolDescriptor,
            protocolRecord.descriptor,
            "protocol.descriptor",
            count: &fieldCount
        )
        try equal(
            projection.protocolHeaderByteCount,
            protocolRecord.headerByteCount,
            "protocol.headerByteCount",
            count: &fieldCount
        )
        try equal(
            projection.protocolByteOrder,
            protocolRecord.byteOrder,
            "protocol.byteOrder",
            count: &fieldCount
        )
        try equal(
            projection.maximumFramePayloadBytes,
            protocolRecord.maximumFramePayloadBytes,
            "protocol.maximumFramePayloadBytes",
            count: &fieldCount
        )
        try equal(
            projection.maximumInFlightRequests,
            protocolRecord.maximumInFlightRequests,
            "protocol.maximumInFlightRequests",
            count: &fieldCount
        )
        try equal(
            projection.protocolMessageKinds.count,
            protocolRecord.messageKinds.count,
            "protocol.messageKinds.count",
            count: &fieldCount
        )
        for (index, pair) in zip(
            projection.protocolMessageKinds,
            protocolRecord.messageKinds
        ).enumerated() {
            try equal(
                pair.0.rawValue,
                pair.1.rawValue,
                "protocol.messageKinds[\(index)].rawValue",
                count: &fieldCount
            )
            try equal(
                pair.0.name,
                pair.1.name,
                "protocol.messageKinds[\(index)].name",
                count: &fieldCount
            )
        }

        return fieldCount
    }

    private static func equal<Value: Equatable>(
        _ actual: Value,
        _ expected: Value,
        _ field: String,
        count: inout Int
    ) throws {
        guard actual == expected else {
            throw RuntimeWorkerAcceptanceRunnerError.projectionMismatch(field)
        }
        count += 1
    }
}

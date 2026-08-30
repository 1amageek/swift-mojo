import Foundation
import MojoBindingCore
import MojoCompilerCore
import MojoRuntimeProtocolCore

package struct MojoRuntimeWorkerRuntimeLibrary: Codable, Equatable, Sendable {
    package let fileName: String
    package let digest: String
    package let architecture: String
    package let installName: String
    package let dynamicDependencies: [String]
    package let providedSymbols: [String]

    package init(_ library: MojoRuntimeDependencyReceipt.Library) {
        self.init(
            fileName: library.fileName,
            digest: library.digest,
            architecture: library.architecture,
            installName: library.installName,
            dynamicDependencies: library.dynamicDependencies,
            providedSymbols: library.providedSymbols
        )
    }

    package init(
        fileName: String,
        digest: String,
        architecture: String,
        installName: String,
        dynamicDependencies: [String],
        providedSymbols: [String]
    ) {
        self.fileName = fileName
        self.digest = digest
        self.architecture = architecture
        self.installName = installName
        self.dynamicDependencies = dynamicDependencies.sorted()
        self.providedSymbols = providedSymbols.sorted()
    }

    package var canonicalRecords: [String] {
        [
            "file=\(fileName)",
            "digest=\(digest)",
            "architecture=\(architecture)",
            "install-name=\(installName)",
        ] + dynamicDependencies.map { "dependency=\($0)" }
            + providedSymbols.map { "provided=\($0)" }
    }
}

package struct MojoRuntimeWorkerReceiptClosure: Codable, Equatable, Sendable {
    package let schemaVersion: Int
    package let linkagePolicyVersion: Int
    package let target: MojoTargetConfiguration
    package let receiptDigest: String
    package let objectDigest: String
    package let requiredSymbols: [String]
    package let systemDependencies: [String]
    package let libraries: [MojoRuntimeWorkerRuntimeLibrary]

    package init(_ receipt: MojoRuntimeDependencyReceipt) {
        self.schemaVersion = receipt.schemaVersion
        self.linkagePolicyVersion = receipt.linkagePolicyVersion
        self.target = receipt.target
        self.receiptDigest = receipt.digest
        self.objectDigest = receipt.objectDigest
        self.requiredSymbols = receipt.requiredSymbols.sorted()
        self.systemDependencies = receipt.systemDependencies.sorted()
        self.libraries = receipt.libraries
            .map(MojoRuntimeWorkerRuntimeLibrary.init)
            .sorted { $0.fileName < $1.fileName }
    }

    package init(
        schemaVersion: Int = MojoRuntimeDependencyReceipt.currentSchemaVersion,
        linkagePolicyVersion: Int = MojoObjectLinkageInspector.policyVersion,
        target: MojoTargetConfiguration,
        receiptDigest: String,
        objectDigest: String,
        requiredSymbols: [String],
        systemDependencies: [String],
        libraries: [MojoRuntimeWorkerRuntimeLibrary]
    ) {
        self.schemaVersion = schemaVersion
        self.linkagePolicyVersion = linkagePolicyVersion
        self.target = target
        self.receiptDigest = receiptDigest
        self.objectDigest = objectDigest
        self.requiredSymbols = requiredSymbols.sorted()
        self.systemDependencies = systemDependencies.sorted()
        self.libraries = libraries.sorted { $0.fileName < $1.fileName }
    }

    package var receipt: MojoRuntimeDependencyReceipt {
        MojoRuntimeDependencyReceipt(
            target: target,
            objectDigest: objectDigest,
            requiredSymbols: requiredSymbols,
            systemDependencies: systemDependencies,
            libraries: libraries.map {
                MojoRuntimeDependencyReceipt.Library(
                    fileName: $0.fileName,
                    digest: $0.digest,
                    architecture: $0.architecture,
                    installName: $0.installName,
                    dynamicDependencies: $0.dynamicDependencies,
                    providedSymbols: $0.providedSymbols
                )
            }
        )
    }

    package var canonicalRecords: [String] {
        var records = [
            "schema=\(schemaVersion)",
            "policy=\(linkagePolicyVersion)",
            "target=\(target.identity)",
            "receipt=\(receiptDigest)",
            "object=\(objectDigest)",
        ]
        records.append(contentsOf: requiredSymbols.map { "required=\($0)" })
        records.append(contentsOf: systemDependencies.map { "system=\($0)" })
        for library in libraries {
            records.append(contentsOf: library.canonicalRecords)
        }
        return records
    }
}

package struct MojoRuntimeWorkerExecutionContract: Equatable, Sendable {
    package let protocolSchemaDigest: String
    package let workerABIVersion: UInt32
    package let inputGraphDigest: String
    package let inputGraphIdentifier: UInt64
    package let bindingTable: MojoRuntimeWorkerBindingTable
    package let target: MojoTargetConfiguration
    package let generationPipelineDigest: String
    package let compilerIdentity: String
    package let sourceMapDigest: String
    package let generatedMojoSourceDigest: String
    package let generatedMojoObjectDigest: String
    package let maximumFramePayloadBytes: UInt64
    package let receiptClosure: MojoRuntimeWorkerReceiptClosure
    package let digest: String

    package init(
        protocolSchemaDigest: String = MojoRuntimeProtocol.schemaDigest,
        workerABIVersion: UInt32,
        inputGraphDigest: String,
        inputGraphIdentifier: UInt64,
        bindingTable: MojoRuntimeWorkerBindingTable,
        target: MojoTargetConfiguration,
        generationPipelineDigest: String,
        compilerIdentity: String,
        sourceMapDigest: String,
        generatedMojoSourceDigest: String,
        generatedMojoObjectDigest: String,
        maximumFramePayloadBytes: UInt64,
        receiptClosure: MojoRuntimeWorkerReceiptClosure
    ) throws {
        guard protocolSchemaDigest == MojoRuntimeProtocol.schemaDigest else {
            throw MojoRuntimeProtocolError.invalidDigest(protocolSchemaDigest)
        }
        for digest in [
            inputGraphDigest,
            generationPipelineDigest,
            sourceMapDigest,
            generatedMojoSourceDigest,
            generatedMojoObjectDigest,
            receiptClosure.receiptDigest,
            receiptClosure.objectDigest,
        ] {
            guard Self.isDigest(digest) else {
                throw MojoRuntimeProtocolError.invalidDigest(digest)
            }
        }
        guard !compilerIdentity.isEmpty else {
            throw MojoRuntimeProtocolError.invalidPayload(
                kind: .ready,
                reason: "compiler identity must not be empty"
            )
        }
        let limits = try MojoRuntimeProtocolLimits(
            maximumFramePayloadBytes: maximumFramePayloadBytes
        )
        guard receiptClosure.target == target else {
            throw MojoRuntimeProtocolError.invalidPayload(
                kind: .ready,
                reason: "runtime receipt target does not match execution target"
            )
        }
        guard receiptClosure.schemaVersion
                == MojoRuntimeDependencyReceipt.currentSchemaVersion,
              receiptClosure.linkagePolicyVersion
                == MojoObjectLinkageInspector.policyVersion else {
            throw MojoRuntimeProtocolError.invalidPayload(
                kind: .ready,
                reason: "runtime receipt policy is unsupported"
            )
        }
        // MojoRuntimeDependencyReceipt owns receipt canonicalization. The
        // closure is admitted only when its supplied digest exactly matches it.
        guard receiptClosure.receiptDigest == receiptClosure.receipt.digest else {
            throw MojoRuntimeProtocolError.invalidPayload(
                kind: .ready,
                reason: "runtime receipt closure digest is inconsistent"
            )
        }
        guard receiptClosure.objectDigest == generatedMojoObjectDigest else {
            throw MojoRuntimeProtocolError.invalidPayload(
                kind: .ready,
                reason: "generated Mojo object digest is missing from receipt closure"
            )
        }

        self.protocolSchemaDigest = protocolSchemaDigest
        self.workerABIVersion = workerABIVersion
        self.inputGraphDigest = inputGraphDigest
        self.inputGraphIdentifier = inputGraphIdentifier
        self.bindingTable = bindingTable
        self.target = target
        self.generationPipelineDigest = generationPipelineDigest
        self.compilerIdentity = compilerIdentity
        self.sourceMapDigest = sourceMapDigest
        self.generatedMojoSourceDigest = generatedMojoSourceDigest
        self.generatedMojoObjectDigest = generatedMojoObjectDigest
        self.maximumFramePayloadBytes = limits.maximumFramePayloadBytes
        self.receiptClosure = receiptClosure
        self.digest = Self.digest(
            canonicalRecords: Self.canonicalRecords(
                protocolSchemaDigest: protocolSchemaDigest,
                workerABIVersion: workerABIVersion,
                inputGraphDigest: inputGraphDigest,
                inputGraphIdentifier: inputGraphIdentifier,
                bindingTable: bindingTable,
                target: target,
                generationPipelineDigest: generationPipelineDigest,
                compilerIdentity: compilerIdentity,
                sourceMapDigest: sourceMapDigest,
                generatedMojoSourceDigest: generatedMojoSourceDigest,
                generatedMojoObjectDigest: generatedMojoObjectDigest,
                maximumFramePayloadBytes: limits.maximumFramePayloadBytes,
                receiptClosure: receiptClosure
            )
        )
    }

    package var canonicalRecords: [String] {
        Self.canonicalRecords(
            protocolSchemaDigest: protocolSchemaDigest,
            workerABIVersion: workerABIVersion,
            inputGraphDigest: inputGraphDigest,
            inputGraphIdentifier: inputGraphIdentifier,
            bindingTable: bindingTable,
            target: target,
            generationPipelineDigest: generationPipelineDigest,
            compilerIdentity: compilerIdentity,
            sourceMapDigest: sourceMapDigest,
            generatedMojoSourceDigest: generatedMojoSourceDigest,
            generatedMojoObjectDigest: generatedMojoObjectDigest,
            maximumFramePayloadBytes: maximumFramePayloadBytes,
            receiptClosure: receiptClosure
        )
    }

    private static func canonicalRecords(
        protocolSchemaDigest: String,
        workerABIVersion: UInt32,
        inputGraphDigest: String,
        inputGraphIdentifier: UInt64,
        bindingTable: MojoRuntimeWorkerBindingTable,
        target: MojoTargetConfiguration,
        generationPipelineDigest: String,
        compilerIdentity: String,
        sourceMapDigest: String,
        generatedMojoSourceDigest: String,
        generatedMojoObjectDigest: String,
        maximumFramePayloadBytes: UInt64,
        receiptClosure: MojoRuntimeWorkerReceiptClosure
    ) -> [String] {
        var records = [
            "protocol=\(protocolSchemaDigest)",
            "worker-abi=\(workerABIVersion)",
            "input-graph=\(inputGraphDigest)",
            "input-graph-identifier=\(inputGraphIdentifier)",
            "binding-table=\(bindingTable.digest)",
            "target-triple=\(target.triple)",
            "target-cpu=\(target.cpu)",
            "target-accelerator=\(target.accelerator ?? "none")",
            "generation-pipeline=\(generationPipelineDigest)",
            "compiler=\(compilerIdentity)",
            "source-map=\(sourceMapDigest)",
            "mojo-source=\(generatedMojoSourceDigest)",
            "mojo-object=\(generatedMojoObjectDigest)",
            "maximum-payload=\(maximumFramePayloadBytes)",
        ]
        records.append(contentsOf: bindingTable.bindings.map {
            "binding=\($0.canonicalRecord)"
        })
        records.append(contentsOf: receiptClosure.canonicalRecords)
        return records
    }

    private static func digest(canonicalRecords: [String]) -> String {
        var data = Data()
        for record in canonicalRecords {
            var byteCount = UInt64(record.utf8.count).littleEndian
            withUnsafeBytes(of: &byteCount) { data.append(contentsOf: $0) }
            data.append(contentsOf: record.utf8)
        }
        return MojoCanonicalDigest.hex(data)
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }
}

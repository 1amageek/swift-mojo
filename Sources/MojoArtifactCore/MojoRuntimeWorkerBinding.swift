import Foundation
import MojoBindingCore

package struct MojoRuntimeWorkerBinding: Codable, Equatable, Sendable {
    package let bindingID: UInt64
    package let functionName: String
    package let signature: MojoBinding.Signature
    package let sessionFactoryFunctionName: String?

    package init(_ binding: MojoBinding) {
        self.bindingID = binding.bindingID
        self.functionName = binding.functionName
        self.signature = binding.signature
        switch binding.implementation {
        case .sessionExternal(_, _, let factory),
             .sessionResource(_, _, _, _, _, _, let factory):
            self.sessionFactoryFunctionName = factory
        case .inline, .external, .session:
            self.sessionFactoryFunctionName = nil
        }
    }

    package init(
        bindingID: UInt64,
        functionName: String,
        signature: MojoBinding.Signature,
        sessionFactoryFunctionName: String? = nil
    ) {
        self.bindingID = bindingID
        self.functionName = functionName
        self.signature = signature
        self.sessionFactoryFunctionName = sessionFactoryFunctionName
    }

    package var canonicalRecord: String {
        [
            String(bindingID),
            functionName,
            signature.rawValue,
            sessionFactoryFunctionName ?? "-",
        ].map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }
}

package struct MojoRuntimeWorkerBindingTable: Equatable, Sendable {
    package enum ValidationError: Error, Equatable, Sendable,
        CustomStringConvertible
    {
        case empty
        case duplicateID(UInt64)
        case duplicateFunction(String)
        case invalidFunction(String)
        case invalidSessionFactory(binding: String, factory: String)
        case missingSessionFactory(String)
        case sessionFactoryHasRelationship(String)
        case graphMismatch(UInt64)

        package var description: String {
            switch self {
            case .empty:
                "worker binding table must not be empty"
            case .duplicateID(let id):
                "worker binding ID \(id) is duplicated"
            case .duplicateFunction(let name):
                "worker binding function '\(name)' is duplicated"
            case .invalidFunction(let name):
                "worker binding function '\(name)' is not portable"
            case .invalidSessionFactory(let binding, let factory):
                "worker binding '\(binding)' references invalid session factory '\(factory)'"
            case .missingSessionFactory(let name):
                "worker binding references missing session factory '\(name)'"
            case .sessionFactoryHasRelationship(let name):
                "session factory '\(name)' cannot reference another factory"
            case .graphMismatch(let id):
                "worker binding table does not match graph binding \(id)"
            }
        }
    }

    package let bindings: [MojoRuntimeWorkerBinding]
    package let digest: String
    package let digestIdentifier: UInt64

    package init(bindings: [MojoRuntimeWorkerBinding]) throws {
        guard !bindings.isEmpty else {
            throw ValidationError.empty
        }
        let sorted = bindings.sorted {
            if $0.bindingID == $1.bindingID {
                return $0.functionName < $1.functionName
            }
            return $0.bindingID < $1.bindingID
        }
        var ids = Set<UInt64>()
        var functionSignatures = Set<String>()
        for binding in sorted {
            guard ids.insert(binding.bindingID).inserted else {
                throw ValidationError.duplicateID(binding.bindingID)
            }
            let functionSignature = "\(binding.functionName)|\(binding.signature.rawValue)"
            guard functionSignatures.insert(functionSignature).inserted else {
                throw ValidationError.duplicateFunction(binding.functionName)
            }
            guard MojoRuntimeLoaderPolicy.isPortableCSymbol(binding.functionName) else {
                throw ValidationError.invalidFunction(binding.functionName)
            }
            switch binding.signature {
            case .runtimeSessionFactory:
                guard binding.sessionFactoryFunctionName == nil else {
                    throw ValidationError.sessionFactoryHasRelationship(
                        binding.functionName
                    )
                }
            case .sessionFloat32BufferFactory,
                 .sessionBorrowedMutableFloat32Buffers:
                guard let factory = binding.sessionFactoryFunctionName,
                      MojoRuntimeLoaderPolicy.isPortableCSymbol(factory) else {
                    throw ValidationError.invalidSessionFactory(
                        binding: binding.functionName,
                        factory: binding.sessionFactoryFunctionName ?? ""
                    )
                }
            case .int32Binary, .borrowedFloat32Buffer,
                 .borrowedMutableFloat32Buffers,
                 .borrowedMutableFloat64Buffers:
                guard binding.sessionFactoryFunctionName == nil else {
                    throw ValidationError.sessionFactoryHasRelationship(
                        binding.functionName
                    )
                }
            }
        }
        let factories = Set(
            sorted.compactMap { binding -> String? in
                binding.signature == .runtimeSessionFactory
                    ? binding.functionName
                    : nil
            }
        )
        for binding in sorted {
            guard let factory = binding.sessionFactoryFunctionName else {
                continue
            }
            guard factories.contains(factory) else {
                throw ValidationError.missingSessionFactory(factory)
            }
        }
        let canonical = sorted.map(\.canonicalRecord).joined(separator: "\n")
        var canonicalData = Data()
        for record in sorted.map(\.canonicalRecord) {
            var length = UInt64(record.utf8.count).littleEndian
            withUnsafeBytes(of: &length) {
                canonicalData.append(contentsOf: $0)
            }
            canonicalData.append(contentsOf: record.utf8)
        }
        self.bindings = sorted
        self.digest = MojoCanonicalDigest.hex(canonicalData)
        self.digestIdentifier = MojoCanonicalDigest.identifier(canonical)
    }

    package init(inputGraph: MojoInputGraph) throws {
        try self.init(
            bindings: inputGraph.bindingGraph.bindings.map(
                MojoRuntimeWorkerBinding.init
            )
        )
    }

    package func binding(bindingID: UInt64) -> MojoRuntimeWorkerBinding? {
        bindings.first { $0.bindingID == bindingID }
    }

    package func validateMembership(
        in inputGraph: MojoInputGraph
    ) throws {
        let graphBindings = inputGraph.bindingGraph.bindings.map(
            MojoRuntimeWorkerBinding.init
        )
        let graphTable = try Self.init(bindings: graphBindings)
        guard graphTable.bindings == bindings else {
            let id = graphTable.bindings.first {
                self.binding(bindingID: $0.bindingID) != $0
            }?.bindingID ?? 0
            throw ValidationError.graphMismatch(id)
        }
    }

}

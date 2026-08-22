import MojoBindingCore

package enum MojoRuntimeLibraryBindingTable {
    package struct ValidationError: Error, Equatable, Sendable,
        CustomStringConvertible
    {
        package let description: String

        package init(_ description: String) {
            self.description = description
        }
    }

    package static func validated(
        _ bindings: [MojoRuntimeLibraryBundleManifest.Binding]
    ) throws -> [MojoRuntimeLibraryBundleManifest.Binding] {
        guard !bindings.isEmpty else {
            throw ValidationError(
                "runtime library binding table must not be empty"
            )
        }
        let sorted = bindings.sorted(
            by: MojoRuntimeLibraryBundleManifest.bindingPrecedes
        )
        var bindingIDs: Set<UInt64> = []
        var functionSignatures: Set<String> = []
        var sessionFactories: Set<String> = []

        for binding in sorted {
            guard bindingIDs.insert(binding.bindingID).inserted else {
                throw ValidationError(
                    "runtime library binding ID \(binding.bindingID) is duplicated"
                )
            }
            guard MojoRuntimeLoaderPolicy.isPortableCSymbol(
                binding.functionName
            ) else {
                throw ValidationError(
                    "runtime library binding function '\(binding.functionName)' is not portable"
                )
            }
            guard let signature = MojoBinding.Signature(
                rawValue: binding.signature
            ) else {
                throw ValidationError(
                    "runtime library binding '\(binding.functionName)' has unsupported signature '\(binding.signature)'"
                )
            }
            let signatureKey = "\(binding.functionName)|\(binding.signature)"
            guard functionSignatures.insert(signatureKey).inserted else {
                throw ValidationError(
                    "runtime library binding '\(binding.functionName)' has a duplicated signature"
                )
            }

            switch signature {
            case .sessionFloat32BufferFactory,
                 .sessionBorrowedMutableFloat32Buffers:
                guard let factory = binding.sessionFactoryFunctionName,
                      MojoRuntimeLoaderPolicy.isPortableCSymbol(factory) else {
                    throw ValidationError(
                        "runtime library binding '\(binding.functionName)' requires a portable session factory function"
                    )
                }
            case .int32Binary,
                 .borrowedFloat32Buffer,
                 .borrowedMutableFloat32Buffers,
                 .borrowedMutableFloat64Buffers,
                 .runtimeSessionFactory:
                guard binding.sessionFactoryFunctionName == nil else {
                    throw ValidationError(
                        "runtime library binding '\(binding.functionName)' cannot declare a session factory"
                    )
                }
            }

            if signature == .runtimeSessionFactory {
                guard sessionFactories.insert(binding.functionName).inserted else {
                    throw ValidationError(
                        "runtime library session factory '\(binding.functionName)' is ambiguous"
                    )
                }
            }
        }

        for binding in sorted {
            guard let factory = binding.sessionFactoryFunctionName else {
                continue
            }
            guard sessionFactories.contains(factory) else {
                throw ValidationError(
                    "runtime library binding '\(binding.functionName)' references missing session factory '\(factory)'"
                )
            }
        }
        return sorted
    }
}

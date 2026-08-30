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

        let genericBindings: [MojoRuntimeWorkerBinding]
        do {
            genericBindings = try bindings.map { binding in
                guard let signature = MojoBinding.Signature(
                    rawValue: binding.signature
                ) else {
                    throw ValidationError(
                        "runtime library binding '\(binding.functionName)' has unsupported signature '\(binding.signature)'"
                    )
                }
                return MojoRuntimeWorkerBinding(
                    bindingID: binding.bindingID,
                    functionName: binding.functionName,
                    signature: signature,
                    sessionFactoryFunctionName:
                        binding.sessionFactoryFunctionName
                )
            }
        } catch let error as ValidationError {
            throw error
        } catch let error as MojoRuntimeWorkerBindingTable.ValidationError {
            throw ValidationError(error.description)
        }

        do {
            let table = try MojoRuntimeWorkerBindingTable(
                bindings: genericBindings
            )
            return table.bindings.map {
                MojoRuntimeLibraryBundleManifest.Binding(
                    bindingID: $0.bindingID,
                    functionName: $0.functionName,
                    signature: $0.signature.rawValue,
                    sessionFactoryFunctionName:
                        $0.sessionFactoryFunctionName
                )
            }
        } catch let error as MojoRuntimeWorkerBindingTable.ValidationError {
            throw ValidationError(error.description)
        }
    }
}

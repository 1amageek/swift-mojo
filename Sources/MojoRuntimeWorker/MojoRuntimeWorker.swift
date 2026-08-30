public import MojoRuntime

public struct MojoRuntimeWorker: Sendable {
    package let verification: MojoRuntimeWorkerBundleVerification

    public init(
        verification: MojoRuntimeWorkerBundleVerification
    ) throws {
        self.verification = verification
    }

    public func sessionFactory(
        for binding: MojoRuntimeWorkerBinding
    ) throws -> MojoRuntimeWorkerSessionFactory {
        try validatedMembership(of: binding)
        guard binding.signature == .runtimeSessionFactory else {
            throw MojoRuntimeWorkerError.unsupportedBindingSignature(
                expected: [.runtimeSessionFactory],
                actual: binding.signature
            )
        }
        guard binding.sessionFactoryFunctionName == nil else {
            throw MojoRuntimeWorkerError
                .unexpectedSessionFactoryRelationship
        }
        return MojoRuntimeWorkerSessionFactory(
            bundleDigest: verification.bundleDigest,
            binding: binding
        )
    }

    public func float32Operation(
        for binding: MojoRuntimeWorkerBinding
    ) throws -> MojoRuntimeWorkerFloat32Operation {
        try validatedMembership(of: binding)

        switch binding.signature {
        case .borrowedFloat32Buffer, .borrowedMutableFloat32Buffers:
            guard binding.sessionFactoryFunctionName == nil else {
                throw MojoRuntimeWorkerError
                    .unexpectedSessionFactoryRelationship
            }
        case .sessionBorrowedMutableFloat32Buffers:
            guard let factoryName = binding.sessionFactoryFunctionName else {
                throw MojoRuntimeWorkerError
                    .missingSessionFactoryRelationship
            }
            guard verification.bindings.contains(where: {
                $0.functionName == factoryName
                    && $0.signature == .runtimeSessionFactory
                    && $0.sessionFactoryFunctionName == nil
            }) else {
                throw MojoRuntimeWorkerError
                    .unresolvedSessionFactoryRelationship
            }
        case .int32Binary, .borrowedMutableFloat64Buffers,
                .runtimeSessionFactory, .sessionFloat32BufferFactory:
            throw MojoRuntimeWorkerError.unsupportedBindingSignature(
                expected: [
                    .borrowedFloat32Buffer,
                    .borrowedMutableFloat32Buffers,
                    .sessionBorrowedMutableFloat32Buffers,
                ],
                actual: binding.signature
            )
        }

        return MojoRuntimeWorkerFloat32Operation(
            bundleDigest: verification.bundleDigest,
            binding: binding
        )
    }

    package func validatedBinding(
        for sessionFactory: MojoRuntimeWorkerSessionFactory
    ) throws -> MojoRuntimeWorkerBinding {
        guard sessionFactory.bundleDigest == verification.bundleDigest else {
            throw MojoRuntimeWorkerError.workerProjectionMismatch
        }
        _ = try self.sessionFactory(for: sessionFactory.binding)
        return sessionFactory.binding
    }

    package func validatedBinding(
        for operation: MojoRuntimeWorkerFloat32Operation
    ) throws -> MojoRuntimeWorkerBinding {
        guard operation.bundleDigest == verification.bundleDigest else {
            throw MojoRuntimeWorkerError.workerProjectionMismatch
        }
        _ = try float32Operation(for: operation.binding)
        return operation.binding
    }

    private func validatedMembership(
        of binding: MojoRuntimeWorkerBinding
    ) throws {
        guard verification.bindings.contains(binding) else {
            throw MojoRuntimeWorkerError.bindingNotInVerification
        }
    }
}

import Foundation

package struct MojoRuntimeReceiptVerifier: Sendable {
    private let preparer: MojoRuntimeReceiptPreparer

    package init(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.preparer = MojoRuntimeReceiptPreparer(environment: environment)
    }

    package init(preparer: MojoRuntimeReceiptPreparer) {
        self.preparer = preparer
    }

    @discardableResult
    package func verify(
        receipt: MojoRuntimeDependencyReceipt,
        options: MojoRuntimeReceiptOptions
    ) throws -> MojoRuntimeDependencyReceipt {
        guard receipt.schemaVersion
                == MojoRuntimeDependencyReceipt.currentSchemaVersion,
              receipt.linkagePolicyVersion
                == MojoObjectLinkageInspector.policyVersion else {
            throw MojoArtifactError.invalidRuntimeReceipt(
                "schema or linkage policy version is unsupported"
            )
        }
        let current = try preparer.prepare(options: options)
        guard current == receipt else {
            throw MojoArtifactError.runtimeReceiptMismatch(
                expected: receipt.digest,
                actual: current.digest
            )
        }
        return current
    }
}

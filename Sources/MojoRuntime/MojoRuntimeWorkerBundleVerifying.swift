import Foundation

public protocol MojoRuntimeWorkerBundleVerifying: Sendable {
    func verifyWorkerBundle(
        at bundleURL: URL
    ) throws -> MojoRuntimeWorkerBundleVerification
}

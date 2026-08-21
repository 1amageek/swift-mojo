import Foundation

public protocol MojoRuntimeBundleVerifying: Sendable {
    func verifyBundle(
        at bundleURL: URL
    ) throws -> MojoRuntimeBundleVerification
}

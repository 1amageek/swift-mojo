import Foundation

public protocol MojoRuntimeLibraryBundleVerifying: Sendable {
    func verifyLibraryBundle(
        at bundleURL: URL
    ) throws -> MojoRuntimeLibraryBundleVerification
}

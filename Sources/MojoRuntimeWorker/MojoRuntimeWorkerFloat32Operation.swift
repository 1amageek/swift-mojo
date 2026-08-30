import MojoRuntime

public struct MojoRuntimeWorkerFloat32Operation: Sendable {
    package let bundleDigest: String
    package let binding: MojoRuntimeWorkerBinding

    package init(
        bundleDigest: String,
        binding: MojoRuntimeWorkerBinding
    ) {
        self.bundleDigest = bundleDigest
        self.binding = binding
    }
}

import MojoBindingCore

package struct MojoInputGraph: Equatable, Sendable {
    package let bindingGraph: MojoSourceGraph
    package let externalPackages: [MojoExternalPackage]
    package let digest: String
    package let digestIdentifier: UInt64

    package init(
        bindingGraph: MojoSourceGraph,
        externalPackages: [MojoExternalPackage]
    ) throws {
        let sortedPackages = externalPackages.sorted { $0.name < $1.name }
        guard Set(sortedPackages.map(\.name)).count == sortedPackages.count else {
            throw MojoArtifactError.invalidExternalPackage(
                "External Mojo package names must be unique"
            )
        }
        let available = Set(sortedPackages.map(\.name))
        for binding in bindingGraph.bindings {
            let package: String
            switch binding.implementation {
            case .inline:
                continue
            case .external(let externalPackage, _):
                package = externalPackage
            case .session(let sessionPackage, _, _):
                package = sessionPackage
            case .sessionExternal(let sessionPackage, _, _):
                package = sessionPackage
            case .sessionResource(let sessionPackage, _, _, _, _, _, _):
                package = sessionPackage
            }
            guard available.contains(package) else {
                throw MojoArtifactError.externalPackageNotDeclared(package)
            }
        }
        let canonical = (["bindings|\(bindingGraph.digest)"] + sortedPackages.map {
            "package|\($0.name)|\($0.digest)"
        }).joined(separator: "\n")
        self.bindingGraph = bindingGraph
        self.externalPackages = sortedPackages
        self.digest = MojoCanonicalDigest.hex(canonical)
        self.digestIdentifier = MojoCanonicalDigest.identifier(canonical)
    }

    package init(bindingGraph: MojoSourceGraph) {
        let canonical = "bindings|\(bindingGraph.digest)"
        self.bindingGraph = bindingGraph
        self.externalPackages = []
        self.digest = MojoCanonicalDigest.hex(canonical)
        self.digestIdentifier = MojoCanonicalDigest.identifier(canonical)
    }
}

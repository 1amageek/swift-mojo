import Foundation
import MojoBindingCore

package struct MojoArtifactInspector: Sendable {
    private let renderer: MojoStaticSourceRenderer

    package init(
        renderer: MojoStaticSourceRenderer = MojoStaticSourceRenderer()
    ) {
        self.renderer = renderer
    }

    package func inspect(
        layout: MojoPackageLayout,
        configuration: SwiftMojoConfiguration?
    ) throws -> MojoInspectionReport {
        let packageNames = try configuration?
            .target(named: layout.targetName).mojoPackages ?? []
        let inputGraph = try MojoInputGraph(
            bindingGraph: MojoSourceGraph(
                sourceURLs: layout.sourceURLs(),
                sourceRootURL: layout.packageRootURL
            ),
            externalPackages: layout.externalPackages(names: packageNames)
        )
        let rendered = renderer.render(
            inputGraph: inputGraph,
            identity: layout.identity
        )
        let manifestURL = layout.outputDirectoryURL.appendingPathComponent(
            MojoStaticABI.manifestName
        )
        let manifest: MojoArtifactManifest?
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            do {
                manifest = try JSONDecoder().decode(
                    MojoArtifactManifest.self,
                    from: Data(contentsOf: manifestURL)
                )
            } catch {
                throw MojoArtifactError.invalidManifest(
                    String(describing: error)
                )
            }
        } else {
            manifest = nil
        }
        return MojoInspectionReport(
            targetName: layout.targetName,
            identity: layout.identity,
            inputGraph: inputGraph,
            generatedMojo: rendered.source,
            preparedManifest: manifest
        )
    }
}

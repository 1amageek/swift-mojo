import Foundation
import MojoBindingCore
import MojoCompilerCore

package struct MojoRuntimeWorkerBundleOptions: Equatable, Sendable {
    package let outputDirectoryURL: URL
    package let executableName: String
    package let identity: MojoArtifactIdentity
    package let inputGraph: MojoInputGraph
    package let renderedSources: MojoRuntimeWorkerRenderedSources
    package let mojoSourceURL: URL
    package let mojoObjectURL: URL
    package let workerSourceURL: URL
    package let workerObjectURL: URL
    package let mojoSourceDigest: String
    package let mojoObjectDigest: String
    package let workerSourceDigest: String
    package let workerObjectDigest: String
    package let runtimeBundleOptions: MojoRuntimeBundleOptions

    package var libraryURLs: [URL] {
        runtimeBundleOptions.libraryURLs
    }

    package var target: MojoTargetConfiguration {
        runtimeBundleOptions.target
    }

    package init(
        outputDirectoryURL: URL,
        executableName: String,
        identity: MojoArtifactIdentity,
        inputGraph: MojoInputGraph,
        renderedSources: MojoRuntimeWorkerRenderedSources,
        mojoSourceURL: URL,
        mojoObjectURL: URL,
        workerSourceURL: URL,
        workerObjectURL: URL,
        runtimeLibraryURLs: [URL],
        target: MojoTargetConfiguration,
        allowedSystemDependencies: Set<String> = []
    ) throws {
        guard target.accelerator != nil else {
            throw MojoArtifactError.invalidArguments(
                "A runtime worker bundle requires an explicit accelerator target"
            )
        }
        let normalizedMojoSource = mojoSourceURL.standardizedFileURL
        let normalizedMojoObject = mojoObjectURL.standardizedFileURL
        let normalizedWorkerSource = workerSourceURL.standardizedFileURL
        let normalizedWorkerObject = workerObjectURL.standardizedFileURL
        let inputs = [
            normalizedMojoSource,
            normalizedMojoObject,
            normalizedWorkerSource,
            normalizedWorkerObject,
        ]
        guard Set(inputs.map(\.path)).count == inputs.count else {
            throw MojoArtifactError.invalidArguments(
                "Runtime worker generated source and object paths must be unique"
            )
        }
        for input in inputs {
            try MojoRegularFile.validate(at: input)
        }

        let contract = renderedSources.executionContract
        guard contract.inputGraphDigest == inputGraph.digest,
              contract.inputGraphIdentifier == inputGraph.digestIdentifier else {
            throw MojoArtifactError.inputGraphMismatch(
                expected: inputGraph.digest,
                actual: contract.inputGraphDigest
            )
        }
        try renderedSources.bindingTable.validateMembership(in: inputGraph)
        guard contract.bindingTable == renderedSources.bindingTable else {
            throw MojoArtifactError.invalidRuntimeBundle(
                "worker execution contract binding table differs from the rendered binding table"
            )
        }
        guard contract.target == target else {
            throw MojoArtifactError.targetMismatch(
                expectedTriple: target.triple,
                expectedCPU: target.cpu,
                actualTriple: contract.target.triple,
                actualCPU: contract.target.cpu
            )
        }

        let actualMojoSourceDigest = try MojoCanonicalDigest.file(
            at: normalizedMojoSource
        )
        let actualMojoObjectDigest = try MojoCanonicalDigest.file(
            at: normalizedMojoObject
        )
        let actualWorkerSourceDigest = try MojoCanonicalDigest.file(
            at: normalizedWorkerSource
        )
        let actualWorkerObjectDigest = try MojoCanonicalDigest.file(
            at: normalizedWorkerObject
        )
        guard actualMojoSourceDigest
                == MojoCanonicalDigest.hex(Data(renderedSources.mojo.source.utf8)),
              actualMojoSourceDigest == contract.generatedMojoSourceDigest else {
            throw MojoArtifactError.inputsChangedDuringOperation(
                "runtime worker Mojo source admission"
            )
        }
        guard actualMojoObjectDigest == contract.generatedMojoObjectDigest else {
            throw MojoArtifactError.inputsChangedDuringOperation(
                "runtime worker Mojo object admission"
            )
        }
        guard actualWorkerSourceDigest == renderedSources.workerSourceDigest,
              actualWorkerSourceDigest
                == MojoCanonicalDigest.hex(Data(renderedSources.workerSource.utf8)) else {
            throw MojoArtifactError.inputsChangedDuringOperation(
                "runtime worker C source admission"
            )
        }

        let output = outputDirectoryURL.standardizedFileURL
        let outputPrefix = output.path.hasSuffix("/")
            ? output.path
            : output.path + "/"
        guard !inputs.contains(where: {
            $0.path == output.path || $0.path.hasPrefix(outputPrefix)
        }) else {
            throw MojoArtifactError.invalidArguments(
                "The runtime worker bundle output must not contain generated build inputs"
            )
        }
        let runtimeOptions = try MojoRuntimeBundleOptions(
            outputDirectoryURL: output,
            executableName: executableName,
            objectURL: normalizedMojoObject,
            libraryURLs: runtimeLibraryURLs,
            target: target,
            allowedSystemDependencies: allowedSystemDependencies
        )

        self.outputDirectoryURL = output
        self.executableName = executableName
        self.identity = identity
        self.inputGraph = inputGraph
        self.renderedSources = renderedSources
        self.mojoSourceURL = normalizedMojoSource
        self.mojoObjectURL = normalizedMojoObject
        self.workerSourceURL = normalizedWorkerSource
        self.workerObjectURL = normalizedWorkerObject
        self.mojoSourceDigest = actualMojoSourceDigest
        self.mojoObjectDigest = actualMojoObjectDigest
        self.workerSourceDigest = actualWorkerSourceDigest
        self.workerObjectDigest = actualWorkerObjectDigest
        self.runtimeBundleOptions = runtimeOptions
    }

    package func validateGeneratedInputs() throws {
        let expected = [
            (mojoSourceURL, mojoSourceDigest),
            (mojoObjectURL, mojoObjectDigest),
            (workerSourceURL, workerSourceDigest),
            (workerObjectURL, workerObjectDigest),
        ]
        for (url, digest) in expected {
            try MojoRegularFile.validate(at: url)
            guard try MojoCanonicalDigest.file(at: url) == digest else {
                throw MojoArtifactError.inputsChangedDuringOperation(
                    "runtime worker bundle preparation"
                )
            }
        }
    }
}

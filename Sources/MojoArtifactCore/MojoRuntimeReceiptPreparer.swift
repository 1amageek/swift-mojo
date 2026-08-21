import Foundation
import MojoBindingCore
import MojoCompilerCore

package struct MojoRuntimeReceiptPreparer: Sendable {
    private struct InspectedLibrary {
        let url: URL
        let digest: String
        let inspection: MojoRuntimeBinaryInspection
    }

    private let binaryInspector: any MojoRuntimeBinaryInspecting
    private let linkageInspector: MojoObjectLinkageInspector

    package init(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let runner = FoundationMojoProcessRunner(environment: environment)
        self.init(
            binaryInspector: MojoRuntimeBinaryInspector(
                processRunner: runner,
                environment: environment
            ),
            processRunner: runner
        )
    }

    package init(
        binaryInspector: any MojoRuntimeBinaryInspecting,
        processRunner: any MojoProcessRunning
    ) {
        self.binaryInspector = binaryInspector
        self.linkageInspector = MojoObjectLinkageInspector(
            processRunner: processRunner
        )
    }

    package func prepare(
        options: MojoRuntimeReceiptOptions
    ) throws -> MojoRuntimeDependencyReceipt {
        try MojoRegularFile.validate(at: options.objectURL)
        try options.libraryURLs.forEach(MojoRegularFile.validate)
        try binaryInspector.validateObject(
            objectURL: options.objectURL,
            target: options.target
        )
        let objectDigest = try MojoCanonicalDigest.file(at: options.objectURL)
        let undefinedSymbols = try linkageInspector.undefinedSymbols(
            objectURL: options.objectURL,
            target: options.target
        )
        let knownRuntimeSymbols = Set(
            undefinedSymbols.filter(MojoObjectLinkageInspector.isRuntimeSymbol)
        )
        let inspected = try options.libraryURLs.map { url in
            InspectedLibrary(
                url: url,
                digest: try MojoCanonicalDigest.file(at: url),
                inspection: try binaryInspector.inspect(
                    libraryURL: url,
                    target: options.target
                )
            )
        }
        let undefined = Set(undefinedSymbols)
        var providers: [String: [Int]] = [:]
        for (index, library) in inspected.enumerated() {
            for symbol in undefined.intersection(
                library.inspection.exportedSymbols
            ) {
                providers[symbol, default: []].append(index)
            }
        }
        let requiredSymbols = knownRuntimeSymbols.union(providers.keys)
        guard !requiredSymbols.isEmpty else {
            throw MojoArtifactError.runtimeReceiptHasNoRuntimeSymbols(
                options.target.identity
            )
        }
        let missing = requiredSymbols.filter {
            providers[$0, default: []].isEmpty
        }.sorted()
        guard missing.isEmpty else {
            throw MojoArtifactError.runtimeSymbolsUnresolved(
                target: options.target.identity,
                symbols: missing
            )
        }
        for symbol in requiredSymbols.sorted() {
            let symbolProviders = providers[symbol, default: []]
            guard symbolProviders.count == 1 else {
                throw MojoArtifactError.runtimeSymbolProviderConflict(
                    symbol: symbol,
                    libraries: symbolProviders.map {
                        inspected[$0].url.lastPathComponent
                    }.sorted()
                )
            }
        }

        let aliases = try Self.aliases(for: inspected)
        var reachable = Set(
            requiredSymbols.flatMap { providers[$0, default: []] }
        )
        var queue = reachable.sorted()
        var observedSystemDependencies = Set<String>()
        while let index = queue.first {
            queue.removeFirst()
            for dependency in inspected[index].inspection.dynamicDependencies {
                if Self.isSystemDependency(
                    dependency,
                    target: options.target,
                    explicitlyAllowed: options.allowedSystemDependencies
                ) {
                    observedSystemDependencies.insert(dependency)
                    continue
                }
                let key = Self.dependencyKey(dependency)
                guard let dependencyIndex = aliases[key] else {
                    throw MojoArtifactError.runtimeDependencyUnresolved(
                        library: inspected[index].url.lastPathComponent,
                        dependency: dependency
                    )
                }
                if reachable.insert(dependencyIndex).inserted {
                    queue.append(dependencyIndex)
                    queue.sort()
                }
            }
        }
        let unreachable = inspected.indices.filter { !reachable.contains($0) }
            .map { inspected[$0].url.lastPathComponent }.sorted()
        guard unreachable.isEmpty else {
            throw MojoArtifactError.runtimeLibrariesUnreachable(unreachable)
        }

        let libraries = inspected.enumerated().map { index, library in
            MojoRuntimeDependencyReceipt.Library(
                fileName: library.url.lastPathComponent,
                digest: library.digest,
                architecture: library.inspection.architecture,
                installName: library.inspection.installName,
                dynamicDependencies: library.inspection.dynamicDependencies,
                providedSymbols: requiredSymbols.filter {
                    providers[$0] == [index]
                }
            )
        }
        let receipt = MojoRuntimeDependencyReceipt(
            target: options.target,
            objectDigest: objectDigest,
            requiredSymbols: Array(requiredSymbols),
            systemDependencies: Array(observedSystemDependencies),
            libraries: libraries
        )
        guard try MojoCanonicalDigest.file(at: options.objectURL)
                == objectDigest,
              try zip(options.libraryURLs, inspected).allSatisfy({ pair in
                  try MojoCanonicalDigest.file(at: pair.0) == pair.1.digest
              }) else {
            throw MojoArtifactError.inputsChangedDuringOperation(
                "runtime receipt preparation"
            )
        }
        return receipt
    }

    private static func aliases(
        for libraries: [InspectedLibrary]
    ) throws -> [String: Int] {
        var result: [String: Int] = [:]
        for (index, library) in libraries.enumerated() {
            let aliases = Set([
                library.url.lastPathComponent,
                library.inspection.installName,
                dependencyKey(library.inspection.installName),
            ])
            for alias in aliases {
                if let existing = result.updateValue(index, forKey: alias),
                   existing != index {
                    throw MojoArtifactError.invalidRuntimeLibrary(
                        library: library.url.lastPathComponent,
                        detail: "runtime install-name alias '\(alias)' is duplicated"
                    )
                }
            }
        }
        return result
    }

    private static func dependencyKey(_ dependency: String) -> String {
        URL(fileURLWithPath: dependency).lastPathComponent
    }

    private static func isSystemDependency(
        _ dependency: String,
        target: MojoTargetConfiguration,
        explicitlyAllowed: Set<String>
    ) -> Bool {
        let key = dependencyKey(dependency)
        let triple = target.triple.lowercased()
        if triple.contains("-apple-") {
            guard dependency.hasPrefix("/"),
                  URL(fileURLWithPath: dependency).standardizedFileURL.path
                    == dependency else {
                return false
            }
            return dependency.hasPrefix("/usr/lib/")
                || dependency.hasPrefix("/System/Library/")
                || dependency.hasPrefix("/System/iOSSupport/")
        }
        if triple.contains("-linux-") {
            guard dependency == key else {
                return false
            }
            if explicitlyAllowed.contains(key) {
                return true
            }
            return [
                "ld-linux-aarch64.so.1",
                "ld-linux-x86-64.so.2",
                "libc.so.6",
                "libdl.so.2",
                "libgcc_s.so.1",
                "libm.so.6",
                "libpthread.so.0",
                "librt.so.1",
                "libstdc++.so.6",
            ].contains(key)
        }
        return false
    }
}

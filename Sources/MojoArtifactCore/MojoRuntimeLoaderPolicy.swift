import Foundation
import MojoCompilerCore

package enum MojoRuntimeLoaderPolicy {
    package static func expectedSearchPath(
        target: MojoTargetConfiguration
    ) throws -> String {
        let triple = target.triple.lowercased()
        if triple.contains("-apple-") {
            return "@executable_path/../lib"
        }
        if triple.contains("-linux-") {
            return "$ORIGIN/../lib"
        }
        throw MojoArtifactError.unsupportedTarget(target.triple)
    }

    package static func expectedLibrarySearchPath(
        target: MojoTargetConfiguration
    ) throws -> String {
        let triple = target.triple.lowercased()
        if triple.contains("-apple-") {
            return "@loader_path"
        }
        if triple.contains("-linux-") {
            return "$ORIGIN"
        }
        throw MojoArtifactError.unsupportedTarget(target.triple)
    }

    package static func expectedLibraryInstallName(
        libraryName: String,
        target: MojoTargetConfiguration
    ) throws -> String {
        let triple = target.triple.lowercased()
        if triple.contains("-apple-") {
            return "@rpath/\(libraryName)"
        }
        if triple.contains("-linux-") {
            return libraryName
        }
        throw MojoArtifactError.unsupportedTarget(target.triple)
    }

    package static func isPortableCSymbol(_ value: String) -> Bool {
        guard let first = value.utf8.first,
              first == 95
                || (first >= 65 && first <= 90)
                || (first >= 97 && first <= 122) else {
            return false
        }
        return value.utf8.dropFirst().allSatisfy { codeUnit in
            codeUnit == 95
                || (codeUnit >= 48 && codeUnit <= 57)
                || (codeUnit >= 65 && codeUnit <= 90)
                || (codeUnit >= 97 && codeUnit <= 122)
        }
    }

    package static func expectedProgramInterpreter(
        target: MojoTargetConfiguration
    ) throws -> String? {
        let triple = target.triple.lowercased()
        if triple.contains("-apple-") {
            return nil
        }
        guard triple.contains("-linux-") else {
            throw MojoArtifactError.unsupportedTarget(target.triple)
        }
        switch triple.split(separator: "-").first {
        case "arm64", "aarch64":
            return "/lib/ld-linux-aarch64.so.1"
        case "x86_64":
            return "/lib64/ld-linux-x86-64.so.2"
        default:
            throw MojoArtifactError.unsupportedTarget(target.triple)
        }
    }

    package static func validate(
        receipt: MojoRuntimeDependencyReceipt
    ) throws {
        let triple = receipt.target.triple.lowercased()
        var librariesByName: [String: MojoRuntimeDependencyReceipt.Library] = [:]
        for library in receipt.libraries {
            guard !library.fileName.isEmpty,
                  library.fileName != ".",
                  library.fileName != "..",
                  !library.fileName.contains("\\"),
                  URL(fileURLWithPath: library.fileName).lastPathComponent
                    == library.fileName else {
                throw MojoArtifactError.invalidRuntimeBundle(
                    "runtime receipt library filename is not a safe path "
                        + "component: '\(library.fileName)'"
                )
            }
            guard librariesByName.updateValue(
                library,
                forKey: library.fileName
            ) == nil else {
                throw MojoArtifactError.invalidRuntimeBundle(
                    "runtime receipt contains duplicate library filename "
                        + "'\(library.fileName)'"
                )
            }
        }
        for library in receipt.libraries {
            let expectedInstallName: String
            if triple.contains("-apple-") {
                expectedInstallName = "@rpath/\(library.fileName)"
            } else if triple.contains("-linux-") {
                expectedInstallName = library.fileName
            } else {
                throw MojoArtifactError.unsupportedTarget(
                    receipt.target.triple
                )
            }
            guard library.installName == expectedInstallName else {
                throw MojoArtifactError.invalidRuntimeBundle(
                    "library '\(library.fileName)' has loader identity "
                        + "'\(library.installName)', expected "
                        + "'\(expectedInstallName)'"
                )
            }
            for dependency in library.dynamicDependencies {
                let fileName = URL(fileURLWithPath: dependency)
                    .lastPathComponent
                if let declared = librariesByName[fileName] {
                    guard dependency == declared.installName else {
                        throw MojoArtifactError.invalidRuntimeBundle(
                            "library '\(library.fileName)' references declared "
                                + "library '\(fileName)' through non-bundle "
                                + "loader name '\(dependency)'"
                        )
                    }
                } else if !receipt.systemDependencies.contains(dependency) {
                    throw MojoArtifactError.invalidRuntimeBundle(
                        "library '\(library.fileName)' has dependency "
                            + "'\(dependency)' outside the receipt closure"
                    )
                }
            }
        }
    }

    package static func validate(
        executable: MojoRuntimeExecutableInspection,
        receipt: MojoRuntimeDependencyReceipt
    ) throws {
        let expectedSearchPath = try expectedSearchPath(target: receipt.target)
        guard executable.runtimeSearchPaths == [expectedSearchPath] else {
            throw MojoArtifactError.invalidRuntimeBundle(
                "executable runtime search paths are "
                    + "[\(executable.runtimeSearchPaths.joined(separator: ", "))], "
                    + "expected [\(expectedSearchPath)]"
            )
        }
        let expectedInterpreter = try expectedProgramInterpreter(
            target: receipt.target
        )
        guard executable.programInterpreter == expectedInterpreter else {
            throw MojoArtifactError.invalidRuntimeBundle(
                "executable program interpreter is "
                    + "'\(executable.programInterpreter ?? "none")', expected "
                    + "'\(expectedInterpreter ?? "none")'"
            )
        }
        let expectedRuntimeDependencies = Set(
            receipt.libraries.map(\.installName)
        )
        let actualRuntimeDependencies = Set(
            executable.dynamicDependencies.filter {
                expectedRuntimeDependencies.contains($0)
            }
        )
        guard actualRuntimeDependencies == expectedRuntimeDependencies else {
            throw MojoArtifactError.invalidRuntimeBundle(
                "executable runtime dependencies are "
                    + "[\(actualRuntimeDependencies.sorted().joined(separator: ", "))], "
                    + "expected [\(expectedRuntimeDependencies.sorted().joined(separator: ", "))]"
            )
        }
        let otherDependencies = executable.dynamicDependencies.filter {
            !expectedRuntimeDependencies.contains($0)
        }
        let unexpected = otherDependencies.filter { dependency in
            !receipt.systemDependencies.contains(dependency)
                && !MojoRuntimeReceiptPreparer.isDefaultSystemDependency(
                    dependency,
                    target: receipt.target
                )
        }
        guard unexpected.isEmpty else {
            throw MojoArtifactError.invalidRuntimeBundle(
                "executable has undeclared dynamic dependencies: "
                    + unexpected.sorted().joined(separator: ", ")
            )
        }
    }

    package static func validate(
        linkedLibrary: MojoRuntimeBinaryInspection,
        receipt: MojoRuntimeDependencyReceipt,
        libraryName: String,
        exportedSymbols: Set<String>
    ) throws {
        guard !libraryName.isEmpty,
              libraryName != ".",
              libraryName != "..",
              !libraryName.contains("\\"),
              URL(fileURLWithPath: libraryName).lastPathComponent
                == libraryName,
              !exportedSymbols.isEmpty,
              exportedSymbols.allSatisfy(isPortableCSymbol) else {
            throw MojoArtifactError.invalidRuntimeBundle(
                "linked library filename or exported C symbols are invalid"
            )
        }
        let expectedInstallName = try expectedLibraryInstallName(
            libraryName: libraryName,
            target: receipt.target
        )
        guard linkedLibrary.installName == expectedInstallName else {
            throw MojoArtifactError.invalidRuntimeBundle(
                "linked library install name is '\(linkedLibrary.installName)', expected '\(expectedInstallName)'"
            )
        }
        let expectedSearchPath = try expectedLibrarySearchPath(
            target: receipt.target
        )
        guard linkedLibrary.runtimeSearchPaths == [expectedSearchPath] else {
            throw MojoArtifactError.invalidRuntimeBundle(
                "linked library runtime search paths are [\(linkedLibrary.runtimeSearchPaths.joined(separator: ", "))], expected [\(expectedSearchPath)]"
            )
        }
        guard linkedLibrary.exportedSymbols == exportedSymbols else {
            throw MojoArtifactError.invalidRuntimeBundle(
                "linked library exported symbols do not match the declared ABI"
            )
        }
        let expectedRuntimeDependencies = Set(
            receipt.libraries.map(\.installName)
        )
        let actualRuntimeDependencies = Set(
            linkedLibrary.dynamicDependencies.filter {
                expectedRuntimeDependencies.contains($0)
            }
        )
        guard actualRuntimeDependencies == expectedRuntimeDependencies else {
            throw MojoArtifactError.invalidRuntimeBundle(
                "linked library runtime dependencies are [\(actualRuntimeDependencies.sorted().joined(separator: ", "))], expected [\(expectedRuntimeDependencies.sorted().joined(separator: ", "))]"
            )
        }
        let unexpected = linkedLibrary.dynamicDependencies.filter {
            !expectedRuntimeDependencies.contains($0)
                && !receipt.systemDependencies.contains($0)
                && !MojoRuntimeReceiptPreparer.isDefaultSystemDependency(
                    $0,
                    target: receipt.target
                )
        }
        guard unexpected.isEmpty else {
            throw MojoArtifactError.invalidRuntimeBundle(
                "linked library has undeclared dynamic dependencies: \(unexpected.sorted().joined(separator: ", "))"
            )
        }
    }
}

import Foundation

package enum MojoExternalPackageImportRoot {
    package static func create(
        in directoryURL: URL,
        externalPackages: [MojoExternalPackage]
    ) throws -> URL? {
        guard !externalPackages.isEmpty else {
            return nil
        }
        let importRootURL = directoryURL.appendingPathComponent(
            ".imports",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: importRootURL,
            withIntermediateDirectories: false
        )
        for package in externalPackages {
            try FileManager.default.createSymbolicLink(
                at: importRootURL.appendingPathComponent(
                    package.name,
                    isDirectory: true
                ),
                withDestinationURL: package.rootURL
            )
        }
        return importRootURL
    }
}

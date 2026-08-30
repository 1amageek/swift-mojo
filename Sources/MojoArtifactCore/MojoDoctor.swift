import Foundation
import MojoCompilerCore

package struct MojoDoctor: Sendable {
    private let environment: [String: String]
    private let processRunner: any MojoProcessRunning

    package init(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.environment = environment
        self.processRunner = FoundationMojoProcessRunner(
            environment: environment
        )
    }

    package init(
        environment: [String: String],
        processRunner: any MojoProcessRunning
    ) {
        self.environment = environment
        self.processRunner = processRunner
    }

    package func diagnose(
        layout: MojoPackageLayout? = nil
    ) -> MojoDoctorReport {
        var checks: [MojoDoctorReport.Check] = []
#if os(macOS)
        checks.append(
            commandCheck(
                name: "Swift toolchain",
                executablePath: "/usr/bin/xcrun",
                arguments: ["swift", "--version"]
            )
        )
        checks.append(
            commandCheck(
                name: "Xcode toolchain",
                executablePath: "/usr/bin/xcrun",
                arguments: ["xcodebuild", "-version"]
            )
        )
#else
        checks.append(
            commandCheck(
                name: "Swift toolchain",
                executablePath: "/usr/bin/env",
                arguments: ["swift", "--version"]
            )
        )
        checks.append(
            MojoDoctorReport.Check(
                name: "Static artifact authoring host",
                status: .failed,
                detail: "Static Mojo artifact authoring requires macOS; this host can consume prepared artifacts"
            )
        )
#endif
        checks.append(mojoCheck())
        if let layout {
            checks.append(packageCheck(layout: layout))
        }
        return MojoDoctorReport(checks: checks)
    }

    private func mojoCheck() -> MojoDoctorReport.Check {
        do {
            let executable = try EnvironmentMojoExecutableLocator(
                environment: environment
            ).locate()
            return commandCheck(
                name: "Mojo compiler",
                executablePath: executable,
                arguments: ["--version"]
            )
        } catch {
            return MojoDoctorReport.Check(
                name: "Mojo compiler",
                status: .failed,
                detail: String(describing: error)
            )
        }
    }

    private func packageCheck(
        layout: MojoPackageLayout
    ) -> MojoDoctorReport.Check {
        do {
            try layout.validatePackageTarget()
            let configuration = try SwiftMojoConfiguration.load(
                packageRootURL: layout.packageRootURL
            )
            let target = try configuration.target(named: layout.targetName)
            _ = try layout.externalPackages(names: target.mojoPackages)
            let executable = try EnvironmentMojoExecutableLocator(
                environment: environment
            ).locate()
            let versionResult = try processRunner.capture(
                executablePath: executable,
                arguments: ["--version"]
            )
            let version = versionResult.output
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard versionResult.status == 0,
                  version == target.compilerVersion else {
                return MojoDoctorReport.Check(
                    name: "Swift Mojo package",
                    status: .failed,
                    detail: "Pinned Mojo compiler is '\(target.compilerVersion)', active compiler is '\(version)'"
                )
            }
            return MojoDoctorReport.Check(
                name: "Swift Mojo package",
                status: .passed,
                detail: "\(layout.targetName): \(target.slices.count) slice(s), \(target.mojoPackages.count) external package(s)"
            )
        } catch {
            return MojoDoctorReport.Check(
                name: "Swift Mojo package",
                status: .failed,
                detail: String(describing: error)
            )
        }
    }

    private func commandCheck(
        name: String,
        executablePath: String,
        arguments: [String]
    ) -> MojoDoctorReport.Check {
        do {
            let result = try processRunner.capture(
                executablePath: executablePath,
                arguments: arguments
            )
            let detail = result.output
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard result.status == 0 else {
                return MojoDoctorReport.Check(
                    name: name,
                    status: .failed,
                    detail: "exit \(result.status): \(detail)"
                )
            }
            return MojoDoctorReport.Check(
                name: name,
                status: .passed,
                detail: detail
            )
        } catch {
            return MojoDoctorReport.Check(
                name: name,
                status: .failed,
                detail: String(describing: error)
            )
        }
    }
}

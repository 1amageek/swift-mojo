import Darwin
import Foundation
import MojoCommandCore

@main
enum SwiftMojoCommand {
    static func main() {
        let result = MojoCommandRunner().run(
            arguments: Array(CommandLine.arguments.dropFirst())
        )
        if !result.standardOutput.isEmpty {
            FileHandle.standardOutput.write(Data(result.standardOutput.utf8))
        }
        if !result.standardError.isEmpty {
            FileHandle.standardError.write(Data(result.standardError.utf8))
        }
        if result.exitCode != 0 {
            exit(result.exitCode)
        }
    }
}

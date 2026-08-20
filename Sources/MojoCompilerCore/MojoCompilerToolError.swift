package enum MojoCompilerToolError: Error, Equatable, CustomStringConvertible {
    case invalidTargetValue(option: String, value: String)
    case executablePathMustBeAbsolute(String)
    case executableNotFound
    case processLaunchFailed(command: String, message: String)
    case processControlFailed(command: String, diagnostic: String)
    case processTimedOut(command: String, seconds: Int, diagnostic: String)
    case commandFailed(
        command: String,
        status: Int32,
        diagnostic: String
    )
    case compilerOutputWasNotUTF8(command: String)
    case artifactNotProduced(String)

    package var description: String {
        switch self {
        case .invalidTargetValue(let option, let value):
            "Invalid value '\(value)' for \(option)"
        case .executablePathMustBeAbsolute(let path):
            "SWIFT_MOJO_EXECUTABLE must be an absolute path; received '\(path)'"
        case .executableNotFound:
            "Mojo executable not found. Set SWIFT_MOJO_EXECUTABLE or add mojo to PATH."
        case .processLaunchFailed(let command, let message):
            "Failed to launch '\(command)': \(message)"
        case .processControlFailed(let command, let diagnostic):
            "Failed to control '\(command)': \(diagnostic)"
        case .processTimedOut(let command, let seconds, let diagnostic):
            "Command '\(command)' exceeded \(seconds) seconds\(diagnostic.isEmpty ? "" : ":\n\(diagnostic)")"
        case .commandFailed(let command, let status, let diagnostic):
            if diagnostic.isEmpty {
                "Command '\(command)' failed with exit status \(status)"
            } else {
                "Command '\(command)' failed with exit status \(status):\n\(diagnostic)"
            }
        case .compilerOutputWasNotUTF8(let command):
            "Command '\(command)' produced output that was not UTF-8"
        case .artifactNotProduced(let path):
            "Mojo compiler reported success but did not produce '\(path)'"
        }
    }
}

import MojoArtifactCore

public enum MojoRuntimeBundleVerificationError:
    Error, Equatable, Sendable, CustomStringConvertible
{
    case invalidBundle(String)
    case inspectionFailed(String)
    case unsupportedTarget(String)

    public var description: String {
        switch self {
        case .invalidBundle(let detail):
            "Mojo runtime bundle verification failed: \(detail)"
        case .inspectionFailed(let detail):
            "Mojo runtime bundle inspection failed: \(detail)"
        case .unsupportedTarget(let target):
            "Mojo runtime bundle target is unsupported: \(target)"
        }
    }
}

extension MojoRuntimeBundleVerificationError {
    package static func fromArtifactError(
        _ error: MojoArtifactError
    ) -> Self {
        switch error {
        case .unsupportedTarget(let target):
            .unsupportedTarget(target)
        case .commandFailed:
            .inspectionFailed(error.description)
        default:
            .invalidBundle(error.description)
        }
    }
}

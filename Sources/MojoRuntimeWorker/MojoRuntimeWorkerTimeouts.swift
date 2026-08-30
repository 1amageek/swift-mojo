import Foundation

public struct MojoRuntimeWorkerTimeouts: Equatable, Sendable {
    public let startup: Duration
    public let sessionCreation: Duration
    public let gracefulShutdown: Duration
    public let terminationGracePeriod: Duration
    public let forcedCleanup: Duration

    public init(
        startup: Duration,
        sessionCreation: Duration,
        gracefulShutdown: Duration,
        terminationGracePeriod: Duration,
        forcedCleanup: Duration
    ) throws {
        try Self.requirePositive(startup, field: .startup)
        try Self.requirePositive(
            sessionCreation,
            field: .sessionCreation
        )
        try Self.requirePositive(
            gracefulShutdown,
            field: .gracefulShutdown
        )
        try Self.requirePositive(
            terminationGracePeriod,
            field: .terminationGracePeriod
        )
        try Self.requirePositive(forcedCleanup, field: .forcedCleanup)
        self.startup = startup
        self.sessionCreation = sessionCreation
        self.gracefulShutdown = gracefulShutdown
        self.terminationGracePeriod = terminationGracePeriod
        self.forcedCleanup = forcedCleanup
    }

    package static func validateInvocation(_ value: Duration) throws {
        try requirePositive(value, field: .invocation)
    }

    private static func requirePositive(
        _ value: Duration,
        field: MojoRuntimeWorkerTimeoutField
    ) throws {
        let components = value.components
        guard value > .zero,
              components.seconds >= 0,
              components.attoseconds >= 0,
              Self.isPOSIXRepresentable(
                  seconds: components.seconds,
                  attoseconds: components.attoseconds
              ) else {
            throw MojoRuntimeWorkerError.invalidTimeout(field: field)
        }
    }

    private static func isPOSIXRepresentable(
        seconds: Int64,
        attoseconds: Int64
    ) -> Bool {
        let millisecondsPerSecond: Int64 = 1_000
        let attosecondsPerMillisecond: Int64 = 1_000_000_000_000_000
        let maximumMilliseconds = Int64(Int32.max)
        guard seconds <= maximumMilliseconds / millisecondsPerSecond
        else { return false }
        let fractionalMilliseconds = attoseconds == 0
            ? 0
            : (attoseconds + attosecondsPerMillisecond - 1)
                / attosecondsPerMillisecond
        let wholeMilliseconds = seconds * millisecondsPerSecond
        return wholeMilliseconds
            <= maximumMilliseconds - fractionalMilliseconds
    }
}

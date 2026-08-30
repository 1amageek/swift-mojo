import Foundation

package enum MojoRuntimeProtocolRole: Sendable {
    case worker
    case consumer
}

package enum MojoRuntimeProtocolDirection: Sendable {
    case incoming
    case outgoing
}

package struct MojoRuntimeProtocolSequenceValidator: Sendable {
    private enum Phase: Sendable {
        case waitingForReady
        case idle
        case waitingForResponse(
            requestID: UInt64,
            requestKind: MojoRuntimeFrameKind
        )
        case terminal
    }

    private let role: MojoRuntimeProtocolRole
    private var phase: Phase = .waitingForReady
    private var lastRequestID: UInt64 = 0
    private var sessionCreated = false
    private var sessionShutdown = false

    package init(role: MojoRuntimeProtocolRole) {
        self.role = role
    }

    package var isTerminal: Bool {
        if case .terminal = phase { return true }
        return false
    }

    package var pendingRequestID: UInt64? {
        if case .waitingForResponse(let requestID, _) = phase {
            return requestID
        }
        return nil
    }

    package mutating func accept(
        _ frame: MojoRuntimeFrame,
        direction: MojoRuntimeProtocolDirection
    ) throws {
        guard !isTerminal else {
            throw MojoRuntimeProtocolError.sequenceViolation(
                "a terminal protocol cannot accept another frame"
            )
        }
        let localSender: MojoRuntimeProtocolRole = switch direction {
        case .incoming:
            role == .worker ? .consumer : .worker
        case .outgoing:
            role
        }

        switch phase {
        case .waitingForReady:
            guard localSender == .worker,
                  frame.header.requestID == 0,
                  frame.header.kind == .ready
                    || frame.header.kind == .failure else {
                throw MojoRuntimeProtocolError.unexpectedFrame(
                    expected: .ready,
                    actual: frame.header.kind
                )
            }
            if frame.header.kind == .failure {
                try acceptFailure(frame, localSender: localSender)
            } else {
                phase = .idle
            }
        case .idle:
            if frame.header.kind == .failure {
                throw MojoRuntimeProtocolError.sequenceViolation(
                    "a failure without an in-flight request is not a startup failure"
                )
            }
            if frame.header.kind == .ready {
                throw MojoRuntimeProtocolError.sequenceViolation(
                    "ready may be sent only once"
                )
            }
            if frame.header.kind.isRequest {
                guard localSender == .consumer else {
                    throw MojoRuntimeProtocolError.sequenceViolation(
                        "worker cannot originate a consumer request"
                    )
                }
                try acceptRequest(frame)
            } else {
                guard localSender == .worker else {
                    throw MojoRuntimeProtocolError.sequenceViolation(
                        "consumer cannot originate a worker response"
                    )
                }
                throw MojoRuntimeProtocolError.sequenceViolation(
                    "response has no in-flight request"
                )
            }
        case .waitingForResponse(let requestID, let requestKind):
            if frame.header.kind.isRequest {
                guard localSender == .consumer else {
                    throw MojoRuntimeProtocolError.sequenceViolation(
                        "worker cannot originate a second request"
                    )
                }
                throw MojoRuntimeProtocolError.secondInFlight
            }
            guard localSender == .worker else {
                throw MojoRuntimeProtocolError.sequenceViolation(
                    "consumer cannot originate a response"
                )
            }
            if frame.header.kind == .failure {
                try acceptFailure(frame, localSender: localSender)
                return
            }
            guard let expected = requestKind.expectedResponse else {
                throw MojoRuntimeProtocolError.sequenceViolation(
                    "request kind has no response"
                )
            }
            guard frame.header.requestID == requestID else {
                throw MojoRuntimeProtocolError.responseIdentifierMismatch(
                    expected: requestID,
                    actual: frame.header.requestID
                )
            }
            guard frame.header.kind == expected else {
                throw MojoRuntimeProtocolError.responseKindMismatch(
                    expected: expected,
                    actual: frame.header.kind
                )
            }
            try acceptResponseState(requestKind: requestKind)
        case .terminal:
            throw MojoRuntimeProtocolError.sequenceViolation(
                "terminal protocol state"
            )
        }
    }

    private mutating func acceptRequest(_ frame: MojoRuntimeFrame) throws {
        let requestID = frame.header.requestID
        guard requestID > lastRequestID else {
            throw MojoRuntimeProtocolError.sequenceViolation(
                "request identifiers must increase strictly"
            )
        }
        guard let response = frame.header.kind.expectedResponse else {
            throw MojoRuntimeProtocolError.sequenceViolation(
                "request kind has no paired response"
            )
        }
        _ = response
        switch frame.header.kind {
        case .createSession:
            guard !sessionCreated, !sessionShutdown else {
                throw MojoRuntimeProtocolError.sequenceViolation(
                    "session creation is only valid once"
                )
            }
        case .invokeFloat32:
            guard sessionCreated, !sessionShutdown else {
                throw MojoRuntimeProtocolError.sequenceViolation(
                    "invocation requires a live session"
                )
            }
        case .shutdownSession:
            guard sessionCreated, !sessionShutdown else {
                throw MojoRuntimeProtocolError.sequenceViolation(
                    "session shutdown requires a live session"
                )
            }
        case .shutdownWorker:
            guard sessionShutdown else {
                throw MojoRuntimeProtocolError.sequenceViolation(
                    "worker shutdown requires session shutdown"
                )
            }
        case .ready, .sessionCreated, .invocationResult, .sessionShutdown,
             .workerShutdown, .failure:
            throw MojoRuntimeProtocolError.sequenceViolation(
                "unexpected request kind"
            )
        }
        lastRequestID = requestID
        phase = .waitingForResponse(
            requestID: requestID,
            requestKind: frame.header.kind
        )
    }

    private mutating func acceptResponseState(
        requestKind: MojoRuntimeFrameKind
    ) throws {
        switch requestKind {
        case .createSession:
            sessionCreated = true
        case .invokeFloat32:
            break
        case .shutdownSession:
            guard sessionCreated else {
                throw MojoRuntimeProtocolError.sequenceViolation(
                    "session shutdown response without a session"
                )
            }
            sessionShutdown = true
        case .shutdownWorker:
            guard sessionShutdown else {
                throw MojoRuntimeProtocolError.sequenceViolation(
                    "worker shutdown response before session shutdown"
                )
            }
            phase = .terminal
            return
        case .ready, .sessionCreated, .invocationResult, .sessionShutdown,
             .workerShutdown, .failure:
            throw MojoRuntimeProtocolError.sequenceViolation(
                "response kind cannot complete a request"
            )
        }
        phase = .idle
    }

    private mutating func acceptFailure(
        _ frame: MojoRuntimeFrame,
        localSender: MojoRuntimeProtocolRole
    ) throws {
        guard case .failure = frame.payload else {
            throw MojoRuntimeProtocolError.invalidPayload(
                kind: .failure,
                reason: "failure header has a non-failure payload"
            )
        }
        switch phase {
        case .waitingForReady:
            guard localSender == .worker, frame.header.requestID == 0 else {
                throw MojoRuntimeProtocolError.invalidRequestIdentifier(
                    kind: frame.header.kind.rawValue,
                    requestID: frame.header.requestID
                )
            }
        case .idle:
            guard localSender == .worker,
                  frame.header.requestID == 0 else {
                throw MojoRuntimeProtocolError.sequenceViolation(
                    "idle failure must be a worker startup failure"
                )
            }
        case .waitingForResponse(let requestID, _):
            guard localSender == .worker,
                  frame.header.requestID == requestID else {
                throw MojoRuntimeProtocolError.responseIdentifierMismatch(
                    expected: requestID,
                    actual: frame.header.requestID
                )
            }
        case .terminal:
            throw MojoRuntimeProtocolError.sequenceViolation(
                "terminal protocol state"
            )
        }
        phase = .terminal
    }
}

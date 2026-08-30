import Foundation
import MojoPOSIXSupport
import MojoRuntimeProtocolCore

package struct MojoRuntimeWorkerExchangeCommand: Sendable {
    package let process: MojoPOSIXWorkerProcess
    package let protocolLimits: MojoRuntimeProtocolLimits
    package let gate: MojoRuntimeWorkerCancellationGate
    package let lease: MojoRuntimeWorkerCancellationGate.Lease
    package let prefixData: Data
    package let input: [Float]?
    package let deadline: ContinuousClock.Instant

    package init(
        process: MojoPOSIXWorkerProcess,
        protocolLimits: MojoRuntimeProtocolLimits,
        gate: MojoRuntimeWorkerCancellationGate,
        lease: MojoRuntimeWorkerCancellationGate.Lease,
        prefixData: Data,
        input: [Float]?,
        deadline: ContinuousClock.Instant
    ) {
        self.process = process
        self.protocolLimits = protocolLimits
        self.gate = gate
        self.lease = lease
        self.prefixData = prefixData
        self.input = input
        self.deadline = deadline
    }
}

package struct MojoRuntimeWorkerExchangeResponse: Sendable {
    package let frame: MojoRuntimeFrame
    package let output: [Float]

    package init(frame: MojoRuntimeFrame, output: [Float] = []) {
        self.frame = frame
        self.output = output
    }
}

package enum MojoRuntimeWorkerTransport {
    package static func detached(
        _ command: MojoRuntimeWorkerExchangeCommand
    ) -> Task<MojoRuntimeWorkerExchangeResponse, Error> {
        Task.detached {
            try execute(command)
        }
    }

    private static func execute(
        _ command: MojoRuntimeWorkerExchangeCommand
    ) throws -> MojoRuntimeWorkerExchangeResponse {
        let clock = ContinuousClock()
        try write(
            data: command.prefixData,
            process: command.process,
            gate: command.gate,
            lease: command.lease,
            deadline: command.deadline,
            clock: clock
        )
        if let input = command.input, !input.isEmpty {
            try input.withUnsafeBufferPointer { inputBuffer in
                let raw = UnsafeRawBufferPointer(inputBuffer)
                try write(
                    rawBuffer: raw,
                    process: command.process,
                    gate: command.gate,
                    lease: command.lease,
                    deadline: command.deadline,
                    clock: clock
                )
            }
        }

        let headerData = try readData(
            byteCount: MojoRuntimeProtocol.headerByteCount,
            process: command.process,
            gate: command.gate,
            lease: command.lease,
            deadline: command.deadline,
            clock: clock
        )
        let header = try MojoRuntimeFrameHeader.decode(
            headerData,
            limits: command.protocolLimits
        )
        let payloadLength = try checkedInt(
            header.payloadByteCount,
            failure: .protocolFailure
        )
        let prefixByteCount = try MojoRuntimeFrame.payloadPrefixByteCount(
            for: header.kind,
            payloadLength: payloadLength
        )
        if header.kind == .failure {
            let maximumFailurePayload = 8
                + MojoRuntimeFailurePayload.maximumDiagnosticByteCount
            guard payloadLength <= maximumFailurePayload else {
                throw MojoRuntimeWorkerError.payloadLimitExceeded
            }
        }
        let prefixData = try readData(
            byteCount: prefixByteCount,
            process: command.process,
            gate: command.gate,
            lease: command.lease,
            deadline: command.deadline,
            clock: clock
        )
        let prefix = try MojoRuntimeFrame.decodePrefix(
            headerData: headerData,
            payloadPrefixData: prefixData,
            limits: command.protocolLimits
        )

        var output: [Float] = []
        if case .invocationResult(let result) = prefix.payload,
           result.status == 0,
           result.resultElementCount > 0 {
            let count = try checkedInt(
                result.resultElementCount,
                failure: .protocolFailure
            )
            output = [Float](repeating: 0, count: count)
            try output.withUnsafeMutableBytes { bytes in
                try read(
                    into: bytes,
                    process: command.process,
                    gate: command.gate,
                    lease: command.lease,
                    deadline: command.deadline,
                    clock: clock
                )
            }
        } else if prefix.bodyByteCount > 0 {
            throw MojoRuntimeWorkerError.protocolFailure
        }

        // The gate is deliberately not checked here. The actor performs the
        // final response commit after sequence and deadline validation, which
        // gives a complete response precedence over a later cancellation.
        guard clock.now < command.deadline else {
            throw MojoRuntimeWorkerError.invocationTimedOut
        }
        let frame = try MojoRuntimeFrame(
            requestID: header.requestID,
            payload: prefix.payload,
            limits: command.protocolLimits
        )
        return MojoRuntimeWorkerExchangeResponse(frame: frame, output: output)
    }

    private static func write(
        data: Data,
        process: MojoPOSIXWorkerProcess,
        gate: MojoRuntimeWorkerCancellationGate,
        lease: MojoRuntimeWorkerCancellationGate.Lease,
        deadline: ContinuousClock.Instant,
        clock: ContinuousClock
    ) throws {
        try data.withUnsafeBytes { bytes in
            try write(
                rawBuffer: bytes,
                process: process,
                gate: gate,
                lease: lease,
                deadline: deadline,
                clock: clock
            )
        }
    }

    private static func write(
        rawBuffer: UnsafeRawBufferPointer,
        process: MojoPOSIXWorkerProcess,
        gate: MojoRuntimeWorkerCancellationGate,
        lease: MojoRuntimeWorkerCancellationGate.Lease,
        deadline: ContinuousClock.Instant,
        clock: ContinuousClock
    ) throws {
        guard rawBuffer.count > 0 else { return }
        var offset = 0
        while offset < rawBuffer.count {
            try requireLive(
                gate: gate,
                lease: lease,
                deadline: deadline,
                clock: clock
            )
            let events = try wait(
                interest: .write,
                process: process,
                gate: gate,
                lease: lease,
                deadline: deadline,
                clock: clock
            )
            guard events.contains(.protocolWritable) else {
                continue
            }
            let result = try rawBuffer.withMemoryRebound(
                to: UInt8.self
            ) { bytes in
                guard let baseAddress = bytes.baseAddress else {
                    throw MojoRuntimeWorkerError.protocolFailure
                }
                let remaining = UnsafeRawBufferPointer(
                    start: baseAddress.advanced(by: offset),
                    count: bytes.count - offset
                )
                return try MojoPOSIXWorkerSupport.write(
                    descriptor: process.protocolDescriptor,
                    from: remaining
                )
            }
            switch result {
            case .bytes(let count):
                offset += count
            case .interrupted, .wouldBlock:
                continue
            case .eof:
                throw MojoRuntimeWorkerError.workerExited
            }
        }
    }

    private static func readData(
        byteCount: Int,
        process: MojoPOSIXWorkerProcess,
        gate: MojoRuntimeWorkerCancellationGate,
        lease: MojoRuntimeWorkerCancellationGate.Lease,
        deadline: ContinuousClock.Instant,
        clock: ContinuousClock
    ) throws -> Data {
        guard byteCount >= 0 else {
            throw MojoRuntimeWorkerError.protocolFailure
        }
        var data = Data(count: byteCount)
        try data.withUnsafeMutableBytes { bytes in
            try read(
                into: bytes,
                process: process,
                gate: gate,
                lease: lease,
                deadline: deadline,
                clock: clock
            )
        }
        return data
    }

    private static func read(
        into buffer: UnsafeMutableRawBufferPointer,
        process: MojoPOSIXWorkerProcess,
        gate: MojoRuntimeWorkerCancellationGate,
        lease: MojoRuntimeWorkerCancellationGate.Lease,
        deadline: ContinuousClock.Instant,
        clock: ContinuousClock
    ) throws {
        guard buffer.count >= 0 else {
            throw MojoRuntimeWorkerError.protocolFailure
        }
        var offset = 0
        while offset < buffer.count {
            try requireLive(
                gate: gate,
                lease: lease,
                deadline: deadline,
                clock: clock
            )
            let events = try wait(
                interest: .read,
                process: process,
                gate: gate,
                lease: lease,
                deadline: deadline,
                clock: clock
            )
            guard events.contains(.protocolReadable)
                    || events.contains(.protocolHangup) else {
                continue
            }
            let result = try buffer.withMemoryRebound(
                to: UInt8.self
            ) { bytes in
                guard let baseAddress = bytes.baseAddress else {
                    throw MojoRuntimeWorkerError.protocolFailure
                }
                let remaining = UnsafeMutableRawBufferPointer(
                    start: baseAddress.advanced(by: offset),
                    count: bytes.count - offset
                )
                return try MojoPOSIXWorkerSupport.read(
                    descriptor: process.protocolDescriptor,
                    into: remaining
                )
            }
            switch result {
            case .bytes(let count):
                offset += count
            case .interrupted, .wouldBlock:
                continue
            case .eof:
                throw MojoRuntimeWorkerError.workerExited
            }
        }
    }

    private static func wait(
        interest: MojoPOSIXWorkerPollInterest,
        process: MojoPOSIXWorkerProcess,
        gate: MojoRuntimeWorkerCancellationGate,
        lease: MojoRuntimeWorkerCancellationGate.Lease,
        deadline: ContinuousClock.Instant,
        clock: ContinuousClock
    ) throws -> MojoPOSIXWorkerPollEvents {
        while true {
            try requireLive(
                gate: gate,
                lease: lease,
                deadline: deadline,
                clock: clock
            )
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else {
                throw MojoRuntimeWorkerError.invocationTimedOut
            }
            let result = try MojoPOSIXWorkerSupport.poll(
                protocolDescriptor: process.protocolDescriptor,
                diagnosticDescriptor: process.diagnosticDescriptor,
                wakeupDescriptor: gate.wakeupDescriptor,
                interests: interest,
                timeout: remaining
            )
            switch result {
            case .timedOut:
                throw MojoRuntimeWorkerError.invocationTimedOut
            case .interrupted:
                continue
            case .ready(let events):
                // Protocol readiness is handled first when multiple fds are
                // handled after a bounded diagnostic drain. A cancellation
                // wakeup is classified on the next iteration unless no
                // protocol progress is available.
                let protocolReady = interest.contains(.read)
                    ? events.contains(.protocolReadable)
                        || events.contains(.protocolHangup)
                        || events.contains(.protocolError)
                    : events.contains(.protocolWritable)
                let diagnosticFailed = events.contains(.diagnosticError)
                if events.contains(.diagnosticReadable)
                    || events.contains(.diagnosticHangup) {
                    try drainDiagnostics(
                        descriptor: process.diagnosticDescriptor,
                        deadline: deadline,
                        clock: clock
                    )
                }
                if protocolReady {
                    if events.contains(.protocolError) {
                        throw MojoRuntimeWorkerError.protocolFailure
                    }
                    return events
                }
                if diagnosticFailed {
                    throw MojoRuntimeWorkerError.protocolFailure
                }
                if events.contains(.wakeupReadable)
                    || events.contains(.wakeupHangup)
                    || events.contains(.wakeupError) {
                    _ = try gate.drainWakeup()
                    throw MojoRuntimeWorkerError.cancellationRequested
                }
            }
        }
    }

    private static func drainDiagnostics(
        descriptor: Int32,
        deadline: ContinuousClock.Instant,
        clock: ContinuousClock
    ) throws {
        var storage = [UInt8](repeating: 0, count: 4_096)
        for _ in 0..<16 {
            guard clock.now < deadline else {
                throw MojoRuntimeWorkerError.invocationTimedOut
            }
            let result = try storage.withUnsafeMutableBytes { bytes in
                try MojoPOSIXWorkerSupport.read(
                    descriptor: descriptor,
                    into: bytes
                )
            }
            switch result {
            case .bytes:
                continue
            case .interrupted:
                continue
            case .wouldBlock, .eof:
                return
            }
        }
    }

    private static func requireLive(
        gate: MojoRuntimeWorkerCancellationGate,
        lease: MojoRuntimeWorkerCancellationGate.Lease,
        deadline: ContinuousClock.Instant,
        clock: ContinuousClock
    ) throws {
        if gate.isCancellationRequested(for: lease) {
            throw MojoRuntimeWorkerError.cancellationRequested
        }
        guard clock.now < deadline else {
            throw MojoRuntimeWorkerError.invocationTimedOut
        }
    }

    private static func checkedInt(
        _ value: UInt64,
        failure: MojoRuntimeWorkerError
    ) throws -> Int {
        guard value <= UInt64(Int.max) else { throw failure }
        return Int(value)
    }
}

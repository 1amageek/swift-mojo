import Foundation
import MojoPOSIXSupport
import MojoRuntime
import MojoRuntimeProtocolCore

package struct MojoRuntimeWorkerStartupResult: Sendable {
    package let sequence: MojoRuntimeProtocolSequenceValidator
    package let diagnostics: Data
}

package enum MojoRuntimeWorkerStartupReader {
    private static let maximumDiagnosticByteCount = 65_536
    private static let maximumDiagnosticReadsPerPoll = 16

    package static func readReady(
        from process: MojoPOSIXWorkerProcess,
        verification: MojoRuntimeWorkerBundleVerification,
        timeout: Duration
    ) throws -> MojoRuntimeWorkerStartupResult {
        do {
            let limits = try MojoRuntimeProtocolLimits(
                maximumFramePayloadBytes:
                    verification.maximumFramePayloadBytes
            )
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            var diagnostics = Data()
            var sawProtocolHangup = false
            let headerData = try readExactly(
                byteCount: MojoRuntimeProtocol.headerByteCount,
                process: process,
                deadline: deadline,
                clock: clock,
                diagnostics: &diagnostics,
                sawProtocolHangup: &sawProtocolHangup
            )
            let header = try MojoRuntimeFrameHeader.decode(
                headerData,
                limits: limits
            )
            let payloadByteCount = try payloadCount(header.payloadByteCount)
            let payloadData = try readExactly(
                byteCount: payloadByteCount,
                process: process,
                deadline: deadline,
                clock: clock,
                diagnostics: &diagnostics,
                sawProtocolHangup: &sawProtocolHangup
            )
            var frameData = Data()
            frameData.reserveCapacity(
                MojoRuntimeProtocol.headerByteCount + payloadByteCount
            )
            frameData.append(headerData)
            frameData.append(payloadData)
            let frame = try MojoRuntimeFrame.decode(frameData, limits: limits)
            var sequence = MojoRuntimeProtocolSequenceValidator(role: .consumer)
            try sequence.accept(frame, direction: .incoming)

            switch frame.payload {
            case .ready(let ready):
                guard !sawProtocolHangup else {
                    throw MojoRuntimeWorkerError.startupProtocolFailed
                }
                try MojoRuntimeWorkerReadyAdmission.validate(
                    ready,
                    against: verification
                )
                return MojoRuntimeWorkerStartupResult(
                    sequence: sequence,
                    diagnostics: diagnostics
                )
            case .failure(let failure):
                guard let failureCode = MojoRuntimeWorkerRemoteFailureCode(
                    rawValue: failure.code.rawValue
                ) else {
                    throw MojoRuntimeWorkerError.startupProtocolFailed
                }
                throw MojoRuntimeWorkerError.startupFailure(
                    code: failureCode,
                    diagnostic: String(
                        decoding: failure.diagnostic,
                        as: UTF8.self
                    )
                )
            case .createSession, .sessionCreated, .invokeFloat32,
                 .invocationResult, .shutdownSession, .sessionShutdown,
                 .shutdownWorker, .workerShutdown:
                throw MojoRuntimeWorkerError.startupProtocolFailed
            }
        } catch let error as MojoRuntimeWorkerError {
            throw error
        } catch {
            throw MojoRuntimeWorkerError.startupProtocolFailed
        }
    }

    private static func payloadCount(_ value: UInt64) throws -> Int {
        guard value <= UInt64(Int.max) else {
            throw MojoRuntimeWorkerError.startupProtocolFailed
        }
        return Int(value)
    }

    private static func readExactly(
        byteCount: Int,
        process: MojoPOSIXWorkerProcess,
        deadline: ContinuousClock.Instant,
        clock: ContinuousClock,
        diagnostics: inout Data,
        sawProtocolHangup: inout Bool
    ) throws -> Data {
        guard byteCount > 0 else { return Data() }
        var storage = Data(count: byteCount)
        var offset = 0

        while offset < byteCount {
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else {
                throw MojoRuntimeWorkerError.startupTimedOut
            }
            let pollResult = try MojoPOSIXWorkerSupport.poll(
                protocolDescriptor: process.protocolDescriptor,
                diagnosticDescriptor: process.diagnosticDescriptor,
                interests: .read,
                timeout: remaining
            )
            switch pollResult {
            case .timedOut:
                throw MojoRuntimeWorkerError.startupTimedOut
            case .interrupted:
                continue
            case .ready(let events):
                if events.contains(.diagnosticReadable)
                    || events.contains(.diagnosticHangup) {
                    try drainDiagnostics(
                        descriptor: process.diagnosticDescriptor,
                        into: &diagnostics,
                        deadline: deadline,
                        clock: clock
                    )
                }
                if events.contains(.diagnosticError) {
                    throw MojoRuntimeWorkerError.startupProtocolFailed
                }
                if events.contains(.protocolError) {
                    throw MojoRuntimeWorkerError.startupProtocolFailed
                }
                if events.contains(.protocolHangup) {
                    sawProtocolHangup = true
                }
                let mayReadProtocol =
                    events.contains(.protocolReadable)
                    || events.contains(.protocolHangup)
                if mayReadProtocol {
                    let result = try storage.withUnsafeMutableBytes { bytes in
                        let remainingBytes = UnsafeMutableRawBufferPointer(
                            rebasing: bytes[offset..<byteCount]
                        )
                        return try MojoPOSIXWorkerSupport.read(
                            descriptor: process.protocolDescriptor,
                            into: remainingBytes
                        )
                    }
                    switch result {
                    case .bytes(let count):
                        offset += count
                    case .interrupted, .wouldBlock:
                        continue
                    case .eof:
                        throw MojoRuntimeWorkerError.startupEOF(
                            expected: byteCount,
                            actual: offset
                        )
                    }
                    continue
                }
            }
        }
        return storage
    }

    private static func drainDiagnostics(
        descriptor: Int32,
        into diagnostics: inout Data,
        deadline: ContinuousClock.Instant,
        clock: ContinuousClock
    ) throws {
        var buffer = [UInt8](repeating: 0, count: 4_096)
        for _ in 0..<maximumDiagnosticReadsPerPoll {
            guard clock.now < deadline else {
                throw MojoRuntimeWorkerError.startupTimedOut
            }
            let result = try buffer.withUnsafeMutableBytes { bytes in
                try MojoPOSIXWorkerSupport.read(
                    descriptor: descriptor,
                    into: bytes
                )
            }
            switch result {
            case .bytes(let count):
                let available = maximumDiagnosticByteCount - diagnostics.count
                if available > 0 {
                    diagnostics.append(
                        contentsOf: buffer.prefix(min(count, available))
                    )
                }
            case .interrupted:
                continue
            case .wouldBlock, .eof:
                return
            }
        }
    }
}

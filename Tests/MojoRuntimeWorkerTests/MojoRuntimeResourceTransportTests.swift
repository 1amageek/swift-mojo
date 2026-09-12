import Foundation
import MojoPOSIXSupport
import MojoRuntimeProtocolCore
import MojoRuntimeWorker
import MojoRuntimeWorkerPOSIX
import Testing
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@Suite("Resource transport over a native worker socket")
struct MojoRuntimeResourceTransportTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func mappedAliasesAndCopiedSegmentsProduceTheSameNumbers(copied: Bool) throws {
        try exchange(copied: copied, behavior: "normal") { command in
            let result = try MojoRuntimeWorkerTransport.resources(command)
            #expect(result.metadata.status == 0)
            #expect(result.metadata.values == Data([0x2a]))
            // Two strided uint16 views of the same native region: 3 * 257 + 5 * 257.
            // The optional explicit host source contributes one million bytes of value 2.
            var expected = UInt64(8 * 257 + (copied ? 2 * 1_048_576 : 0)).littleEndian
            let bytes = withUnsafeBytes(of: &expected) { Data($0) }
            #expect(result.outputBuffers == [bytes])
            #expect(result.sharedHandlesSent == 1)
            #expect(result.inputPayloadBytesSent == (copied ? 1_048_576 : 0))
            #expect(result.controlBytesSent == UInt64(32 + command.invocation.control.count))
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["schema", "identifier", "rights", "capacity"])
    func rejectsInvalidTerminalResponses(behavior: String) throws {
        try exchange(copied: false, behavior: behavior) { command in
            do {
                _ = try MojoRuntimeWorkerTransport.resources(command)
                Issue.record("Invalid terminal response was accepted")
            } catch {
                switch behavior {
                case "schema":
                    #expect(error as? MojoRuntimeBufferError == .invalidSchema)
                case "identifier":
                    #expect(error as? MojoRuntimeWorkerError == .responseMismatch)
                case "capacity":
                    #expect(error as? MojoRuntimeBufferError == .countLimitExceeded)
                case "rights":
                    #expect(error as? MojoPOSIXRightsError == .operationFailed(code: EPROTO, cleanupCode: 0))
                default:
                    Issue.record("Unexpected fixture behavior")
                }
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationInterruptsAWorkerWaitingOnInput() throws {
        try exchange(copied: false, behavior: "normal") { command in
            command.lease.cancel()
            #expect(throws: MojoRuntimeWorkerError.cancellationRequested) {
                try MojoRuntimeWorkerTransport.resources(command)
            }
        }
    }

    private func exchange(
        copied: Bool, behavior: String,
        _ body: (MojoRuntimeResourceExchange) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Fixture removal failed: \(error)") }
        }
        let inputURL = root.appendingPathComponent("input")
        try Data(repeating: 1, count: 64).write(to: inputURL)
        let input = try FileHandle(forReadingFrom: inputURL)
        defer {
            do { try input.close() }
            catch { Issue.record("Input close failed: \(error)") }
        }
        let owner = try MojoPOSIXSharedInput.importReadOnly(
            descriptor: input.fileDescriptor, byteCount: 64, retaining: input, kind: .regularFile
        )
        var views = try [
            MojoBufferView(buffer: owner, elementType: .uint16, byteOffset: 2,
                           dimensions: [3], byteStrides: [4]),
            MojoBufferView(buffer: owner, elementType: .uint16, byteOffset: 4,
                           dimensions: [5], byteStrides: [2]),
        ]
        if copied {
            views.append(try MojoBufferView(
                buffer: MojoReadOnlyBuffer(hostSource: Data(repeating: 2, count: 1_048_576)),
                elementType: .uint8, dimensions: [1_048_576], byteStrides: [1]
            ))
        }
        let limits = try MojoRuntimeResourceLimits(
            buffer: MojoRuntimeBufferLimits(maximumRank: 2,
                                           maximumRegionByteCount: 2_097_152, allowsEmpty: false),
            maximumInputs: 3, maximumOutputs: 1, maximumArgumentBytes: 8,
            maximumResultValueBytes: 8, maximumControlBytes: 4096,
            maximumCopiedBytes: 2_097_152, maximumMappedBytes: 4096, maximumResultBytes: 4096
        )
        let prepared = try MojoRuntimePreparedInvocation(
            bindingID: 7, argumentSchema: MojoRuntimeValueSchema.digest([.uint8]),
            arguments: MojoInvocationArguments([.uint8(9)]), inputs: views,
            outputs: [MojoRuntimeOutputCapacity(element: .uint64, maximumElementCount: 1)],
            limits: limits
        )
        let scriptURL = root.appendingPathComponent("peer.py")
        try Self.peer.write(to: scriptURL, atomically: false, encoding: .utf8)
        let interpreter = try #require([
            "/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"
        ].first { FileManager.default.isExecutableFile(atPath: $0) })
        let stage = root.appendingPathComponent("stage")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        let gate = MojoRuntimeWorkerCancellationGate(wakeup: try MojoPOSIXWorkerSupport.createWakeup())
        let process: MojoPOSIXWorkerProcess
        do {
            process = try MojoPOSIXWorkerSupport.spawn(
                executablePath: interpreter, arguments: [scriptURL.path, behavior]
            )
        } catch {
            #expect(gate.close(deadline: ContinuousClock().now + .seconds(1)).isEmpty)
            throw error
        }
        defer {
            let now = ContinuousClock().now
            let outcome = MojoRuntimeWorkerTerminalizer.cleanup(
                process: process, stageRoot: stage, gate: gate,
                mode: behavior == "normal" ? .hard : .graceful,
                gracefulDeadline: now + .milliseconds(200),
                terminationDeadline: now + .milliseconds(400),
                forcedCleanupDeadline: now + .seconds(2)
            )
            #expect(outcome.reaped && outcome.groupTerminationConfirmed)
            #expect(outcome.failures.isEmpty)
        }
        let lease = try gate.beginExchange()
        defer { gate.endExchange(for: lease) }
        try body(MojoRuntimeResourceExchange(
            requestID: 3, invocation: prepared,
            expectedResultSchema: Array(repeating: 0x34, count: 32), limits: limits,
            process: process, gate: gate, lease: lease,
            deadline: ContinuousClock().now + .seconds(5)
        ))
    }

    // An independent peer decodes the bytes and maps actual received rights. It
    // intentionally does not reuse the production encoder or prepared metadata.
    private static let peer = #"""
    import array, hashlib, mmap, os, socket, struct, sys
    sock = socket.socket(fileno=3)
    sock.setblocking(True)
    sock.settimeout(5)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
    behavior = sys.argv[1]
    rights = []
    def read(n):
        result = bytearray()
        while len(result) < n:
            data, ancillary, flags, _ = sock.recvmsg(min(n-len(result), 4096), socket.CMSG_SPACE(16))
            assert data and not flags & socket.MSG_CTRUNC
            for level, kind, payload in ancillary:
                assert level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS
                handles = array.array('i')
                handles.frombytes(payload)
                rights.extend(handles)
            result.extend(data)
        return result
    header = read(32)
    magic, reserved, kind, request, payload_size, tail = struct.unpack('<4sHHQQQ', header)
    assert (magic, reserved, kind, request, tail) == (b'SMW1', 0, 4, 3, 0)
    payload = read(payload_size)
    binding, schema, arg_count, input_count, output_count = struct.unpack_from('<Q32sIHH', payload)
    assert binding == 7 and schema == hashlib.sha256(b'swift-mojo-values' + struct.pack('<HH', 1, 2)).digest() and output_count == 1
    offset = 48
    views = []
    for _ in range(input_count):
        storage, element, rank, reserved, ordinal, reserved2, region, start, body_offset = struct.unpack_from('<HHHHIIQQQ', payload, offset)
        assert reserved == reserved2 == 0 and rank == 1
        offset += 40
        count, stride = struct.unpack_from('<QQ', payload, offset)
        offset += 16
        views.append((storage, element, ordinal, region, start, body_offset, count, stride))
    assert struct.unpack_from('<HHQ', payload, offset) == (8, 0, 1)
    offset += 12
    assert payload[offset:offset+arg_count] == bytes([9])
    offset += arg_count
    assert len(rights) == 1
    mapped = mmap.mmap(rights[0], 64, access=mmap.ACCESS_READ)
    total = 0
    for storage, element, ordinal, region, start, body_offset, count, stride in views:
        if storage == 2:
            assert ordinal == 0 and region == 64 and body_offset == 0 and element == 4
            for index in range(count):
                total += struct.unpack_from('<H', mapped, start + index*stride)[0]
        else:
            assert storage == 1 and element == 2 and ordinal == 0xffffffff
            total += sum(payload[offset+body_offset+start:offset+body_offset+start+count*stride:stride])
    mapped.close()
    result_schema = bytes([0x35 if behavior == 'schema' else 0x34])*32
    result = struct.pack('<i32sIHHQ', 0, result_schema, 1, 1, 0, 2 if behavior == 'capacity' else 1)
    result += bytes([0x2a]) + struct.pack('<Q', total)
    response = struct.pack('<4sHHQQQ', b'SMW1', 0, 5, request + (behavior == 'identifier'), len(result), 0)
    if behavior == 'rights':
        sock.sendmsg([response], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array('i', rights))])
        sock.sendall(result)
    elif behavior != 'normal':
        sock.sendall(response + result)
    else:
        for byte in response + result:
            sock.sendall(bytes([byte]))
    for handle in rights:
        os.close(handle)
    """#
}

import Foundation
import MojoRuntimeProtocolCore
import Testing

@Suite("Native descriptor differential admission")
struct MojoRuntimeNativeDescriptorTests {
    @Test(.timeLimit(.minutes(1)))
    func nativeDecoderMatchesSwiftIncludingMalformedLayouts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Native fixture cleanup failed: \(error)") }
        }
        let limits = try MojoRuntimeBufferLimits(maximumRank: 2, maximumRegionByteCount: 1024, allowsEmpty: true)
        var fixtures: [(Data, UInt16, UInt16, Bool)] = []
        for element in MojoRuntimeElementType.allCases {
            for storage in [MojoRuntimeBufferStorageKind.copied, .sharedFile, .dmaBuf] {
                for dimensions: [UInt64] in [[], [3], [2, 3], [0, UInt64.max]] {
                    let descriptor = try MojoRuntimeBufferDescriptor(
                        storage: storage, element: element,
                        handleOrdinal: storage == .copied ? .max : 0,
                        regionByteCount: 1024, viewByteOffset: element.byteWidth,
                        payloadOffset: 0, dimensions: dimensions,
                        byteStrides: dimensions.map { _ in element.byteWidth * 4 }, limits: limits
                    )
                    var writer = MojoRuntimeByteWriter()
                    descriptor.encode(into: &writer)
                    let data = writer.data()
                    fixtures.append((data, element.rawValue, UInt16(dimensions.count), true))
                    fixtures.append((data, element.rawValue, UInt16(dimensions.count), false))
                }
            }
        }
        let base = fixtures[4] // Rank two, Int8 copied descriptor.
        for count in 0..<base.0.count { fixtures.append((Data(base.0.prefix(count)), base.1, base.2, true)) }
        for index in base.0.indices {
            for byte: UInt8 in [0, 1, 0x7f, 0xff] {
                var data = base.0
                data[index] = byte
                fixtures.append((data, base.1, base.2, true))
            }
        }
        // Multi-byte arithmetic overflows cannot be exercised by single-byte mutation.
        for offset in [16, 24, 32, 40, 48, 56, 64] {
            var data = base.0
            data.replaceSubrange(offset..<offset+8, with: repeatElement(UInt8.max, count: 8))
            fixtures.append((data, base.1, base.2, true))
        }
        var source = MojoRuntimeNativeDescriptor.source + "\n#include <assert.h>\nint main(void) {\n"
        var accepted = 0
        for (data, element, rank, allowsEmpty) in fixtures {
            var descriptor: MojoRuntimeBufferDescriptor?
            do {
                var reader = MojoRuntimeByteReader(data: data)
                let decoded = try MojoRuntimeBufferDescriptor.decode(from: &reader, limits: MojoRuntimeBufferLimits(
                    maximumRank: rank, maximumRegionByteCount: 1024, allowsEmpty: allowsEmpty
                ))
                if decoded.element.rawValue == element && decoded.dimensions.count == Int(rank) {
                    descriptor = decoded
                }
            } catch {
                descriptor = nil
            }
            let bytes = data.isEmpty ? "0" : data.map(String.init).joined(separator: ",")
            source += """
            {
                const uint8_t wire[] = {\(bytes)};
                swmo_buffer_view view;
                uint64_t dimensions[3] = {0,0,123}, strides[3] = {0,0,456};
                size_t consumed = 0;
                int status = swmo_descriptor(wire, \(data.count), \(element), \(rank), 1024, \(allowsEmpty ? 1 : 0), &view, dimensions, strides, &consumed);
                assert((status == 0) == \(descriptor == nil ? 0 : 1));
                assert(dimensions[2] == 123 && strides[2] == 456);
            """
            if let descriptor {
                accepted += 1
                source += """
                    assert(consumed == \(40 + Int(rank) * 16));
                    assert(view.storage == \(descriptor.storage.rawValue) && view.element == \(element) && view.rank == \(rank));
                    assert(view.ordinal == \(descriptor.handleOrdinal)u);
                    assert(view.region == \(descriptor.regionByteCount)ull && view.offset == \(descriptor.viewByteOffset)ull);
                    assert(view.payload_offset == \(descriptor.payloadOffset)ull && view.addressed_end == \(descriptor.addressedByteEnd)ull);
                    assert(view.empty == \(descriptor.isEmpty ? 1 : 0));
                """
                for index in descriptor.dimensions.indices {
                    source += "assert(dimensions[\(index)] == \(descriptor.dimensions[index])ull && strides[\(index)] == \(descriptor.byteStrides[index])ull);\n"
                }
            }
            source += "}\n"
        }
        source += "return 0; }\n"
        #expect(accepted > 100 && fixtures.count - accepted > 100)
        let sourceURL = root.appendingPathComponent("decoder.c")
        let executable = root.appendingPathComponent("decoder")
        try source.write(to: sourceURL, atomically: false, encoding: .utf8)
        try run("/usr/bin/clang", ["-std=c11", "-Wall", "-Wextra", "-Werror", "-fsanitize=address,undefined", sourceURL.path, "-o", executable.path], root: root)
        try run(executable.path, [], root: root)
        print("Native descriptor differential cases: \(fixtures.count), accepted: \(accepted)")
    }

    private func run(_ executable: String, _ arguments: [String], root: URL) throws {
        let log = root.appendingPathComponent(UUID().uuidString)
        try Data().write(to: log)
        let output = try FileHandle(forWritingTo: log)
        defer {
            do { try output.close() }
            catch { Issue.record("Native log close failed: \(error)") }
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let diagnostic = String(decoding: try Data(contentsOf: log), as: UTF8.self)
        try #require(process.terminationStatus == 0, "\(diagnostic)")
    }
}

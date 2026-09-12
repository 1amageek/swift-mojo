import Foundation
import MojoBindingCore
import MojoCompilerCore
import MojoRuntimeProtocolCore

package struct MojoRuntimeWorkerRenderedSources: Equatable, Sendable {
    package let mojo: MojoRenderedSource
    package let workerSource: String
    package let workerSourceDigest: String
    package let header: String
    package let executionContract: MojoRuntimeWorkerExecutionContract
    package let bindingTable: MojoRuntimeWorkerBindingTable

    package init(
        mojo: MojoRenderedSource,
        workerSource: String,
        header: String,
        executionContract: MojoRuntimeWorkerExecutionContract,
        bindingTable: MojoRuntimeWorkerBindingTable
    ) {
        self.mojo = mojo
        self.workerSource = workerSource
        self.workerSourceDigest = MojoCanonicalDigest.hex(
            Data(workerSource.utf8)
        )
        self.header = header
        self.executionContract = executionContract
        self.bindingTable = bindingTable
    }
}

package struct MojoRuntimeWorkerRenderer: Sendable {
    package static let generationVersion = 1
    package static let workerABIVersion: UInt32 = 1

    package init() {}

    package func render(
        inputGraph: MojoInputGraph,
        identity: MojoArtifactIdentity,
        target: MojoTargetConfiguration,
        compilerIdentity: String,
        generatedMojoSourceDigest: String,
        generatedMojoObjectDigest: String,
        receipt: MojoRuntimeDependencyReceipt,
        maximumFramePayloadBytes: UInt64
    ) throws -> MojoRuntimeWorkerRenderedSources {
        // FIXME(INCOMPLETE_IMPLEMENTATION): Resource binding metadata is admitted
        // by the graph, but this endpoint still dispatches Float32 calls. Worker
        // publication must fail until generated resource dispatch is qualified.
        guard !inputGraph.bindingGraph.bindings.contains(where: { $0.signature == .resourceInvocation }) else {
            throw MojoRuntimeProtocolError.invalidPayload(kind: .ready, reason: "resource worker dispatch is not implemented")
        }
        let limits = try MojoRuntimeProtocolLimits(
            maximumFramePayloadBytes: maximumFramePayloadBytes
        )
        let staticRenderer = MojoStaticSourceRenderer()
        let mojo = staticRenderer.render(
            inputGraph: inputGraph,
            identity: identity
        )
        let actualMojoSourceDigest = MojoCanonicalDigest.hex(
            Data(mojo.source.utf8)
        )
        guard actualMojoSourceDigest == generatedMojoSourceDigest else {
            throw MojoRuntimeProtocolError.invalidPayload(
                kind: .ready,
                reason: "generated Mojo source digest does not match rendered source"
            )
        }
        let bindingTable = try MojoRuntimeWorkerBindingTable(
            inputGraph: inputGraph
        )
        try bindingTable.validateMembership(in: inputGraph)
        let sourceMapDigest = MojoCanonicalDigest.hex(
            try mojo.sourceMap.encode()
        )
        let pipelineDigest = Self.pipelineDigest(for: inputGraph)
        let contract = try MojoRuntimeWorkerExecutionContract(
            workerABIVersion: Self.workerABIVersion,
            inputGraphDigest: inputGraph.digest,
            inputGraphIdentifier: inputGraph.digestIdentifier,
            bindingTable: bindingTable,
            target: target,
            generationPipelineDigest: pipelineDigest,
            compilerIdentity: compilerIdentity,
            sourceMapDigest: sourceMapDigest,
            generatedMojoSourceDigest: generatedMojoSourceDigest,
            generatedMojoObjectDigest: generatedMojoObjectDigest,
            maximumFramePayloadBytes: limits.maximumFramePayloadBytes,
            receiptClosure: MojoRuntimeWorkerReceiptClosure(receipt)
        )
        let readyPayload = try MojoRuntimeReadyPayload(
            executionContractDigest: contract.digest,
            inputGraphDigest: contract.inputGraphDigest,
            inputGraphIdentifier: contract.inputGraphIdentifier,
            bindingTableDigest: contract.bindingTable.digest,
            abiVersion: contract.workerABIVersion,
            targetTriple: contract.target.triple,
            targetCPU: contract.target.cpu,
            targetAccelerator: contract.target.accelerator,
            maximumFramePayloadBytes: contract.maximumFramePayloadBytes
        )
        let readyFrame = try MojoRuntimeFrame(
            requestID: 0,
            payload: .ready(readyPayload),
            limits: limits
        ).encodedData(limits: limits)
        let source = Self.workerSource(
            inputGraph: inputGraph,
            identity: identity,
            bindingTable: bindingTable,
            contract: contract,
            limits: limits,
            readyFrame: readyFrame
        )
        return MojoRuntimeWorkerRenderedSources(
            mojo: mojo,
            workerSource: source,
            header: staticRenderer.header(
                identity: identity,
                inputGraph: inputGraph
            ),
            executionContract: contract,
            bindingTable: bindingTable
        )
    }

    package func render(
        inputGraph: MojoInputGraph,
        identity: MojoArtifactIdentity,
        target: MojoTargetConfiguration,
        compilerVersion: String,
        generatedMojoSourceDigest: String,
        generatedMojoObjectDigest: String,
        receipt: MojoRuntimeDependencyReceipt,
        maximumFramePayloadBytes: UInt64
    ) throws -> MojoRuntimeWorkerRenderedSources {
        try render(
            inputGraph: inputGraph,
            identity: identity,
            target: target,
            compilerIdentity: compilerVersion,
            generatedMojoSourceDigest: generatedMojoSourceDigest,
            generatedMojoObjectDigest: generatedMojoObjectDigest,
            receipt: receipt,
            maximumFramePayloadBytes: maximumFramePayloadBytes
        )
    }

    private static func pipelineDigest(
        for inputGraph: MojoInputGraph
    ) -> String {
        let records = [
            "base=\(MojoGenerationPipeline.digest(for: inputGraph))",
            "worker-renderer=\(generationVersion)",
            "worker-abi=\(workerABIVersion)",
        ]
        var data = Data()
        for record in records {
            var length = UInt64(record.utf8.count).littleEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(contentsOf: record.utf8)
        }
        return MojoCanonicalDigest.hex(data)
    }

    private static func workerSource(
        inputGraph: MojoInputGraph,
        identity: MojoArtifactIdentity,
        bindingTable: MojoRuntimeWorkerBindingTable,
        contract: MojoRuntimeWorkerExecutionContract,
        limits: MojoRuntimeProtocolLimits,
        readyFrame: Data
    ) -> String {
        var lines: [String] = [
            "#include <errno.h>",
            "#include <stdint.h>",
            "#include <stddef.h>",
            "#include <stdlib.h>",
            "#include <string.h>",
            "#include <unistd.h>",
            "#include \"\(identity.moduleName).h\"",
            "",
            "#define SWIFT_MOJO_HEADER_BYTES 32u",
            "#define SWIFT_MOJO_MAX_PAYLOAD \(limits.maximumFramePayloadBytes)ull",
            "#define SWIFT_MOJO_ABI_VERSION \(contract.workerABIVersion)u",
            "#define SWIFT_MOJO_KIND_READY 1u",
            "#define SWIFT_MOJO_KIND_CREATE_SESSION 2u",
            "#define SWIFT_MOJO_KIND_SESSION_CREATED 3u",
            "#define SWIFT_MOJO_KIND_INVOKE_FLOAT32 4u",
            "#define SWIFT_MOJO_KIND_INVOCATION_RESULT 5u",
            "#define SWIFT_MOJO_KIND_SHUTDOWN_SESSION 6u",
            "#define SWIFT_MOJO_KIND_SESSION_SHUTDOWN 7u",
            "#define SWIFT_MOJO_KIND_SHUTDOWN_WORKER 8u",
            "#define SWIFT_MOJO_KIND_WORKER_SHUTDOWN 9u",
            "#define SWIFT_MOJO_KIND_FAILURE 10u",
            "#define SWIFT_MOJO_FAILURE_INVALID_FRAME 1u",
            "#define SWIFT_MOJO_FAILURE_INVALID_SEQUENCE 2u",
            "#define SWIFT_MOJO_FAILURE_INVALID_BINDING 3u",
            "#define SWIFT_MOJO_FAILURE_SESSION_UNAVAILABLE 4u",
            "#define SWIFT_MOJO_FAILURE_INVOCATION 5u",
            "#define SWIFT_MOJO_FAILURE_SHUTDOWN 6u",
            "#define SWIFT_MOJO_FAILURE_INTERNAL 7u",
            "",
            "static uint16_t swmo_u16(const uint8_t *p) {",
            "    return (uint16_t)p[0] | ((uint16_t)p[1] << 8);",
            "}",
            "",
            "static uint32_t swmo_u32(const uint8_t *p) {",
            "    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |",
            "        ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);",
            "}",
            "",
            "static uint64_t swmo_u64(const uint8_t *p) {",
            "    uint64_t value = 0;",
            "    for (size_t i = 0; i < 8u; ++i) {",
            "        value |= ((uint64_t)p[i]) << (8u * i);",
            "    }",
            "    return value;",
            "}",
            "",
            "static void swmo_put16(uint8_t *p, uint16_t value) {",
            "    p[0] = (uint8_t)value;",
            "    p[1] = (uint8_t)(value >> 8);",
            "}",
            "",
            "static void swmo_put32(uint8_t *p, uint32_t value) {",
            "    for (size_t i = 0; i < 4u; ++i) {",
            "        p[i] = (uint8_t)(value >> (8u * i));",
            "    }",
            "}",
            "",
            "static void swmo_put64(uint8_t *p, uint64_t value) {",
            "    for (size_t i = 0; i < 8u; ++i) {",
            "        p[i] = (uint8_t)(value >> (8u * i));",
            "    }",
            "}",
            "",
            "static int swmo_read_full(uint8_t *buffer, size_t count) {",
            "    size_t offset = 0;",
            "    while (offset < count) {",
            "        ssize_t result = read(3, buffer + offset, count - offset);",
            "        if (result < 0 && errno == EINTR) continue;",
            "        if (result <= 0) return -1;",
            "        offset += (size_t)result;",
            "    }",
            "    return 0;",
            "}",
            "",
            "static int swmo_write_full(const uint8_t *buffer, size_t count) {",
            "    size_t offset = 0;",
            "    while (offset < count) {",
            "        ssize_t result = write(3, buffer + offset, count - offset);",
            "        if (result < 0 && errno == EINTR) continue;",
            "        if (result <= 0) return -1;",
            "        offset += (size_t)result;",
            "    }",
            "    return 0;",
            "}",
            "",
            "static int swmo_append16(uint8_t *buffer, size_t capacity, size_t *offset, uint16_t value) {",
            "    if (*offset > capacity || capacity - *offset < 2u) return -1;",
            "    swmo_put16(buffer + *offset, value);",
            "    *offset += 2u;",
            "    return 0;",
            "}",
            "",
            "static int swmo_append32(uint8_t *buffer, size_t capacity, size_t *offset, uint32_t value) {",
            "    if (*offset > capacity || capacity - *offset < 4u) return -1;",
            "    swmo_put32(buffer + *offset, value);",
            "    *offset += 4u;",
            "    return 0;",
            "}",
            "",
            "static int swmo_send_segments(",
            "    uint16_t kind, uint64_t request_id,",
            "    const uint8_t *prefix, size_t prefix_count,",
            "    const uint8_t *body, size_t body_count",
            ") {",
            "    if (prefix_count > SIZE_MAX - body_count) return -1;",
            "    size_t total = prefix_count + body_count;",
            "    if ((uint64_t)total > SWIFT_MOJO_MAX_PAYLOAD) return -1;",
            "    uint8_t header[SWIFT_MOJO_HEADER_BYTES] = {",
            "        0x53, 0x4d, 0x57, 0x31, 0x00, 0x00,",
            "        0, 0, 0, 0, 0, 0, 0, 0,",
            "        0, 0, 0, 0, 0, 0, 0, 0,",
            "        0, 0, 0, 0, 0, 0, 0, 0,",
            "    };",
            "    swmo_put16(header + 6u, kind);",
            "    swmo_put64(header + 8u, request_id);",
            "    swmo_put64(header + 16u, (uint64_t)total);",
            "    if (swmo_write_full(header, sizeof(header)) != 0) return -1;",
            "    if (prefix_count != 0u && swmo_write_full(prefix, prefix_count) != 0) return -1;",
            "    if (body_count != 0u && swmo_write_full(body, body_count) != 0) return -1;",
            "    return 0;",
            "}",
            "",
            "static int swmo_send_frame(",
            "    uint16_t kind, uint64_t request_id,",
            "    const uint8_t *payload, size_t payload_count",
            ") {",
            "    return swmo_send_segments(kind, request_id, payload, payload_count, NULL, 0u);",
            "}",
            "",
            "static int swmo_failure(uint16_t code, uint64_t request_id, const char *message) {",
            "    uint8_t payload[512];",
            "    size_t offset = 0;",
            "    size_t length = strlen(message);",
            "    if (length > 480u) length = 480u;",
            "    if (swmo_append16(payload, sizeof(payload), &offset, code) != 0 ||",
            "        swmo_append16(payload, sizeof(payload), &offset, 0u) != 0 ||",
            "        swmo_append32(payload, sizeof(payload), &offset, (uint32_t)length) != 0) return -1;",
            "    memcpy(payload + offset, message, length);",
            "    offset += length;",
            "    (void)swmo_send_frame(SWIFT_MOJO_KIND_FAILURE, request_id, payload, offset);",
            "    return -1;",
            "}",
            "",
            "static int swmo_send_invocation_result(",
            "    uint8_t *send_storage, size_t send_capacity,",
            "    uint64_t request_id, int32_t status, uint64_t result_count",
            ") {",
            "    if (result_count > UINT64_MAX / 4u) return -1;",
            "    uint64_t body_count = result_count * 4u;",
            "    if (body_count > SWIFT_MOJO_MAX_PAYLOAD - 12u ||",
            "        body_count > SIZE_MAX || send_capacity < 12u ||",
            "        body_count > send_capacity - 12u) return -1;",
            "    swmo_put32(send_storage, (uint32_t)status);",
            "    swmo_put64(send_storage + 4u, result_count);",
            "    return swmo_send_segments(",
            "        SWIFT_MOJO_KIND_INVOCATION_RESULT, request_id,",
            "        send_storage, 12u, send_storage + 12u, (size_t)body_count",
            "    );",
            "}",
            "",
        ]

        lines.append(contentsOf: readySource(
            identity: identity,
            inputGraph: inputGraph,
            bindingTable: bindingTable,
            readyFrame: readyFrame
        ))
        lines.append(contentsOf: sessionSource(
            identity: identity,
            inputGraph: inputGraph
        ))
        lines.append(contentsOf: invocationSource(
            identity: identity,
            inputGraph: inputGraph,
            limits: limits
        ))
        lines.append(contentsOf: mainSource(
            identity: identity,
            inputGraph: inputGraph,
            limits: limits
        ))
        return lines.joined(separator: "\n") + "\n"
    }

    private static func readySource(
        identity: MojoArtifactIdentity,
        inputGraph: MojoInputGraph,
        bindingTable: MojoRuntimeWorkerBindingTable,
        readyFrame: Data
    ) -> [String] {
        let prefix = identity.symbolPrefix
        var lines: [String] = [
            "static const uint8_t swmo_ready_frame[] = {",
        ]
        let bytes = Array(readyFrame)
        for start in stride(from: 0, to: bytes.count, by: 16) {
            let end = min(start + 16, bytes.count)
            let values = bytes[start..<end].map {
                String(format: "0x%02x", $0)
            }.joined(separator: ", ")
            lines.append("    \(values),")
        }
        lines.append("};")
        lines.append("")
        lines.append(contentsOf: [
            "static int swmo_compiled_contract_is_ready(void) {",
            "    if (\(prefix)_static_abi_version() != SWIFT_MOJO_ABI_VERSION) return 0;",
            "    if (\(prefix)_input_graph_identifier() != \(inputGraph.digestIdentifier)ull) return 0;",
        ])
        for binding in bindingTable.bindings {
            lines.append(
                "    if (\(prefix)_has_binding(\(binding.bindingID)ull) == 0u) return 0;"
            )
        }
        lines.append("    return 1;")
        lines.append("}")
        lines.append("")
        lines.append("static int swmo_send_ready(void) {")
        lines.append(
            "    if (!swmo_compiled_contract_is_ready()) return swmo_failure(SWIFT_MOJO_FAILURE_INVALID_BINDING, 0u, \"compiled contract mismatch\");"
        )
        lines.append(
            "    return swmo_write_full(swmo_ready_frame, sizeof(swmo_ready_frame));"
        )
        lines.append("}")
        lines.append("")
        return lines
    }

    private static func sessionSource(
        identity: MojoArtifactIdentity,
        inputGraph: MojoInputGraph
    ) -> [String] {
        let prefix = identity.symbolPrefix
        let factories = inputGraph.bindingGraph.bindings.filter {
            $0.signature == .runtimeSessionFactory
        }
        var lines: [String] = [
            "static int swmo_create_session(",
            "    const uint8_t *payload, size_t count, uint64_t request_id,",
            "    void **session, uint64_t *selected_binding_id,",
            "    uint32_t *device, uint32_t *ordinal, uint64_t *capabilities",
            ") {",
            "    if (count != 28u) return swmo_failure(SWIFT_MOJO_FAILURE_INVALID_FRAME, request_id, \"create prefix\");",
            "    uint64_t binding_id = swmo_u64(payload);",
            "    uint32_t request_schema = swmo_u32(payload + 8u);",
            "    uint32_t requested_device = swmo_u32(payload + 12u);",
            "    uint32_t requested_ordinal = swmo_u32(payload + 16u);",
            "    uint64_t required_capabilities = swmo_u64(payload + 20u);",
            "    uint32_t response_schema = 0u;",
            "    *session = NULL;",
            "    *selected_binding_id = 0u;",
        ]
        if factories.isEmpty {
            lines.append(
                "    return swmo_failure(SWIFT_MOJO_FAILURE_SESSION_UNAVAILABLE, request_id, \"session factory unavailable\");"
            )
        } else {
            for binding in factories {
                lines.append("    if (binding_id == \(binding.bindingID)ull) {")
                lines.append(
                    "        int32_t status = \(prefix)_create_session_v1(binding_id, request_schema, requested_device, requested_ordinal, required_capabilities, session, &response_schema, device, ordinal, capabilities);"
                )
                lines.append(
                    "        if (status != 0 || *session == NULL || response_schema != request_schema) {"
                )
                lines.append(
                    "            if (*session != NULL) { \(prefix)_shutdown_session_v1(binding_id, *session); *session = NULL; }"
                )
                lines.append(
                    "            return swmo_failure(SWIFT_MOJO_FAILURE_SESSION_UNAVAILABLE, request_id, \"session creation failed\");"
                )
                lines.append("        }")
                lines.append("        *selected_binding_id = binding_id;")
                lines.append("        return 0;")
                lines.append("    }")
            }
            lines.append(
                "    return swmo_failure(SWIFT_MOJO_FAILURE_INVALID_BINDING, request_id, \"session binding unavailable\");"
            )
        }
        lines.append("}")
        lines.append("")
        lines.append(
            "static void swmo_destroy_session(uint64_t binding_id, void *session) {"
        )
        for binding in factories {
            lines.append("    if (binding_id == \(binding.bindingID)ull) {")
            lines.append("        \(prefix)_shutdown_session_v1(binding_id, session);")
            lines.append("        return;")
            lines.append("    }")
        }
        lines.append("}")
        lines.append("")
        lines.append(
            "static void swmo_cleanup_session(uint64_t *binding_id, void **session, int *live) {"
        )
        lines.append("    if (*live && *session != NULL) {")
        lines.append("        swmo_destroy_session(*binding_id, *session);")
        lines.append("        *session = NULL;")
        lines.append("        *live = 0;")
        lines.append("    }")
        lines.append("}")
        lines.append("")
        return lines
    }

    private static func invocationSource(
        identity: MojoArtifactIdentity,
        inputGraph: MojoInputGraph,
        limits: MojoRuntimeProtocolLimits
    ) -> [String] {
        let prefix = identity.symbolPrefix
        let sessionFactories = Dictionary(
            uniqueKeysWithValues: inputGraph.bindingGraph.bindings.compactMap {
                binding -> (String, UInt64)? in
                binding.signature == .runtimeSessionFactory
                    ? (binding.functionName, binding.bindingID)
                    : nil
            }
        )
        var lines: [String] = [
            "static int swmo_invoke_float32(",
            "    const uint8_t *payload, size_t count, uint64_t request_id,",
            "    void *session, uint64_t session_binding_id,",
            "    uint8_t *send_storage, size_t send_capacity",
            ") {",
            "    if (count < 24u) return swmo_failure(SWIFT_MOJO_FAILURE_INVALID_FRAME, request_id, \"invoke prefix\");",
            "    uint64_t binding_id = swmo_u64(payload);",
            "    uint64_t input_count = swmo_u64(payload + 8u);",
            "    uint64_t output_count = swmo_u64(payload + 16u);",
            "    if (input_count > UINT64_MAX / 4u) return swmo_failure(SWIFT_MOJO_FAILURE_INVALID_FRAME, request_id, \"input size overflow\");",
            "    uint64_t input_bytes = input_count * 4u;",
            "    if (input_bytes != (uint64_t)(count - 24u) || input_bytes > SWIFT_MOJO_MAX_PAYLOAD) return swmo_failure(SWIFT_MOJO_FAILURE_INVALID_FRAME, request_id, \"input size mismatch\");",
        ]
        for binding in inputGraph.bindingGraph.bindings {
            switch binding.signature {
            case .borrowedFloat32Buffer:
                lines.append("    if (binding_id == \(binding.bindingID)ull) {")
                lines.append(
                    "        if (output_count != 1u) return swmo_failure(SWIFT_MOJO_FAILURE_INVALID_FRAME, request_id, \"output shape\");"
                )
                lines.append(
                    "        float value = \(prefix)_call_f32_buffer_f32(binding_id, (const float *)(payload + 24u), input_count);"
                )
                lines.append(
                    "        if (send_capacity < 16u) return swmo_failure(SWIFT_MOJO_FAILURE_INTERNAL, request_id, \"result capacity\");"
                )
                lines.append(
                    "        memcpy(send_storage + 12u, &value, sizeof(value));"
                )
                lines.append(
                    "        return swmo_send_invocation_result(send_storage, send_capacity, request_id, 0, 1u);"
                )
                lines.append("    }")
            case .borrowedMutableFloat32Buffers:
                lines.append("    if (binding_id == \(binding.bindingID)ull) {")
                lines.append(
                    "        if (output_count == 0u || output_count > UINT64_MAX / 4u) return swmo_failure(SWIFT_MOJO_FAILURE_INVALID_FRAME, request_id, \"output shape\");"
                )
                lines.append(
                    "        uint64_t output_bytes = output_count * 4u;"
                )
                lines.append(
                    "        if (output_bytes > SWIFT_MOJO_MAX_PAYLOAD - 12u || output_bytes > SIZE_MAX || send_capacity < 12u || output_bytes > send_capacity - 12u) return swmo_failure(SWIFT_MOJO_FAILURE_INVALID_FRAME, request_id, \"output size\");"
                )
                lines.append(
                    "        float *output = (float *)(send_storage + 12u);"
                )
                lines.append(
                    "        int32_t status = \(prefix)_call_f32_buffer_f32_buffer_i32(binding_id, (const float *)(payload + 24u), input_count, output, output_count);"
                )
                lines.append(
                    "        uint64_t result_count = status == 0 ? output_count : 0u;"
                )
                lines.append(
                    "        return swmo_send_invocation_result(send_storage, send_capacity, request_id, status, result_count);"
                )
                lines.append("    }")
            case .resourceInvocation:
                // Rendering rejects this signature before dispatch generation.
                continue
            case .sessionBorrowedMutableFloat32Buffers:
                let factoryName: String?
                if case .sessionExternal(_, _, let factory) = binding.implementation {
                    factoryName = factory
                } else {
                    factoryName = nil
                }
                guard let factoryName,
                      let factoryBindingID = sessionFactories[factoryName] else {
                    continue
                }
                lines.append("    if (binding_id == \(binding.bindingID)ull) {")
                lines.append(
                    "        if (session == NULL || session_binding_id != \(factoryBindingID)ull) return swmo_failure(SWIFT_MOJO_FAILURE_INVALID_BINDING, request_id, \"session factory mismatch\");"
                )
                lines.append(
                    "        if (output_count == 0u || output_count > UINT64_MAX / 4u) return swmo_failure(SWIFT_MOJO_FAILURE_SESSION_UNAVAILABLE, request_id, \"session output shape\");"
                )
                lines.append(
                    "        uint64_t output_bytes = output_count * 4u;"
                )
                lines.append(
                    "        if (output_bytes > SWIFT_MOJO_MAX_PAYLOAD - 12u || output_bytes > SIZE_MAX || send_capacity < 12u || output_bytes > send_capacity - 12u) return swmo_failure(SWIFT_MOJO_FAILURE_INVALID_FRAME, request_id, \"session output size\");"
                )
                lines.append(
                    "        float *output = (float *)(send_storage + 12u);"
                )
                lines.append(
                    "        int32_t status = \(prefix)_call_session_f32_buffer_f32_buffer_i32_v1(\(binding.bindingID)ull, session, (const float *)(payload + 24u), input_count, output, output_count);"
                )
                lines.append(
                    "        uint64_t result_count = status == 0 ? output_count : 0u;"
                )
                lines.append(
                    "        return swmo_send_invocation_result(send_storage, send_capacity, request_id, status, result_count);"
                )
                lines.append("    }")
            case .runtimeSessionFactory, .sessionFloat32BufferFactory,
                 .borrowedMutableFloat64Buffers, .int32Binary:
                continue
            }
        }
        lines.append(
            "    return swmo_failure(SWIFT_MOJO_FAILURE_INVALID_BINDING, request_id, \"invocation binding unavailable\");"
        )
        lines.append("}")
        lines.append("")
        _ = limits
        return lines
    }

    private static func mainSource(
        identity: MojoArtifactIdentity,
        inputGraph: MojoInputGraph,
        limits: MojoRuntimeProtocolLimits
    ) -> [String] {
        var lines: [String] = [
            "int main(void) {",
            "    uint8_t *receive_storage = (uint8_t *)malloc((size_t)SWIFT_MOJO_MAX_PAYLOAD);",
            "    uint8_t *send_storage = (uint8_t *)malloc((size_t)SWIFT_MOJO_MAX_PAYLOAD);",
            "    if (receive_storage == NULL || send_storage == NULL) {",
            "        free(receive_storage);",
            "        free(send_storage);",
            "        (void)swmo_failure(SWIFT_MOJO_FAILURE_INTERNAL, 0u, \"worker storage allocation\");",
            "        return 1;",
            "    }",
            "    if (swmo_send_ready() != 0) {",
            "        free(receive_storage);",
            "        free(send_storage);",
            "        return 1;",
            "    }",
            "    void *session = NULL;",
            "    uint64_t session_binding_id = 0u;",
            "    int session_live = 0;",
            "    int session_shutdown = 0;",
            "    uint64_t last_request_id = 0u;",
            "    for (;;) {",
            "        uint8_t header[SWIFT_MOJO_HEADER_BYTES];",
            "        if (swmo_read_full(header, sizeof(header)) != 0) {",
            "            swmo_cleanup_session(&session_binding_id, &session, &session_live);",
            "            free(receive_storage);",
            "            free(send_storage);",
            "            return 1;",
            "        }",
            "        if (header[0] != 0x53 || header[1] != 0x4d || header[2] != 0x57 || header[3] != 0x31 || swmo_u16(header + 4u) != 0u || swmo_u64(header + 24u) != 0u) {",
            "            swmo_cleanup_session(&session_binding_id, &session, &session_live);",
            "            (void)swmo_failure(SWIFT_MOJO_FAILURE_INVALID_FRAME, 0u, \"header\");",
            "            free(receive_storage);",
            "            free(send_storage);",
            "            return 1;",
            "        }",
            "        uint16_t kind = swmo_u16(header + 6u);",
            "        uint64_t request_id = swmo_u64(header + 8u);",
            "        uint64_t payload_count = swmo_u64(header + 16u);",
            "        if (request_id == 0u || request_id <= last_request_id || payload_count > SWIFT_MOJO_MAX_PAYLOAD || payload_count > SIZE_MAX) {",
            "            swmo_cleanup_session(&session_binding_id, &session, &session_live);",
            "            (void)swmo_failure(SWIFT_MOJO_FAILURE_INVALID_SEQUENCE, request_id, \"request sequence\");",
            "            free(receive_storage);",
            "            free(send_storage);",
            "            return 1;",
            "        }",
            "        if (kind == SWIFT_MOJO_KIND_READY || kind == SWIFT_MOJO_KIND_SESSION_CREATED || kind == SWIFT_MOJO_KIND_INVOCATION_RESULT || kind == SWIFT_MOJO_KIND_SESSION_SHUTDOWN || kind == SWIFT_MOJO_KIND_WORKER_SHUTDOWN || kind == SWIFT_MOJO_KIND_FAILURE) {",
            "            swmo_cleanup_session(&session_binding_id, &session, &session_live);",
            "            (void)swmo_failure(SWIFT_MOJO_FAILURE_INVALID_SEQUENCE, request_id, \"response direction\");",
            "            free(receive_storage);",
            "            free(send_storage);",
            "            return 1;",
            "        }",
            "        if (payload_count != 0u && swmo_read_full(receive_storage, (size_t)payload_count) != 0) {",
            "            swmo_cleanup_session(&session_binding_id, &session, &session_live);",
            "            (void)swmo_failure(SWIFT_MOJO_FAILURE_INVALID_FRAME, request_id, \"payload\");",
            "            free(receive_storage);",
            "            free(send_storage);",
            "            return 1;",
            "        }",
            "        last_request_id = request_id;",
            "        if (kind == SWIFT_MOJO_KIND_CREATE_SESSION) {",
            "            if (session_live || session_shutdown) {",
            "                (void)swmo_failure(SWIFT_MOJO_FAILURE_INVALID_SEQUENCE, request_id, \"create sequence\");",
            "                swmo_cleanup_session(&session_binding_id, &session, &session_live);",
            "                free(receive_storage);",
            "                free(send_storage);",
            "                return 1;",
            "            }",
            "            uint32_t device = 0u, ordinal = 0u; uint64_t capabilities = 0u;",
            "            int status = swmo_create_session(receive_storage, (size_t)payload_count, request_id, &session, &session_binding_id, &device, &ordinal, &capabilities);",
            "            if (status != 0) {",
            "                swmo_cleanup_session(&session_binding_id, &session, &session_live);",
            "                free(receive_storage);",
            "                free(send_storage);",
            "                return 1;",
            "            }",
            "            session_live = 1;",
            "            swmo_put32(send_storage, 0u);",
            "            swmo_put32(send_storage + 4u, 1u);",
            "            swmo_put32(send_storage + 8u, device);",
            "            swmo_put32(send_storage + 12u, ordinal);",
            "            swmo_put64(send_storage + 16u, capabilities);",
            "            if (swmo_send_frame(SWIFT_MOJO_KIND_SESSION_CREATED, request_id, send_storage, 24u) != 0) {",
            "                swmo_cleanup_session(&session_binding_id, &session, &session_live);",
            "                free(receive_storage);",
            "                free(send_storage);",
            "                return 1;",
            "            }",
            "            continue;",
            "        }",
            "        if (kind == SWIFT_MOJO_KIND_INVOKE_FLOAT32) {",
            "            if (!session_live || session_shutdown) {",
            "                (void)swmo_failure(SWIFT_MOJO_FAILURE_INVALID_SEQUENCE, request_id, \"invoke sequence\");",
            "                swmo_cleanup_session(&session_binding_id, &session, &session_live);",
            "                free(receive_storage);",
            "                free(send_storage);",
            "                return 1;",
            "            }",
            "            int status = swmo_invoke_float32(receive_storage, (size_t)payload_count, request_id, session, session_binding_id, send_storage, (size_t)SWIFT_MOJO_MAX_PAYLOAD);",
            "            if (status != 0) {",
            "                swmo_cleanup_session(&session_binding_id, &session, &session_live);",
            "                free(receive_storage);",
            "                free(send_storage);",
            "                return 1;",
            "            }",
            "            continue;",
            "        }",
            "        if (kind == SWIFT_MOJO_KIND_SHUTDOWN_SESSION) {",
            "            if (payload_count != 0u || !session_live || session_shutdown) {",
            "                (void)swmo_failure(SWIFT_MOJO_FAILURE_INVALID_SEQUENCE, request_id, \"shutdown sequence\");",
            "                swmo_cleanup_session(&session_binding_id, &session, &session_live);",
            "                free(receive_storage);",
            "                free(send_storage);",
            "                return 1;",
            "            }",
            "            swmo_cleanup_session(&session_binding_id, &session, &session_live);",
            "            session_shutdown = 1;",
            "            if (swmo_send_frame(SWIFT_MOJO_KIND_SESSION_SHUTDOWN, request_id, NULL, 0u) != 0) {",
            "                free(receive_storage);",
            "                free(send_storage);",
            "                return 1;",
            "            }",
            "            continue;",
            "        }",
            "        if (kind == SWIFT_MOJO_KIND_SHUTDOWN_WORKER) {",
            "            if (payload_count != 0u || session_live || !session_shutdown) {",
            "                (void)swmo_failure(SWIFT_MOJO_FAILURE_INVALID_SEQUENCE, request_id, \"worker shutdown sequence\");",
            "                swmo_cleanup_session(&session_binding_id, &session, &session_live);",
            "                free(receive_storage);",
            "                free(send_storage);",
            "                return 1;",
            "            }",
            "            if (swmo_send_frame(SWIFT_MOJO_KIND_WORKER_SHUTDOWN, request_id, NULL, 0u) != 0) {",
            "                free(receive_storage);",
            "                free(send_storage);",
            "                return 1;",
            "            }",
            "            free(receive_storage);",
            "            free(send_storage);",
            "            (void)close(3);",
            "            return 0;",
            "        }",
            "        swmo_cleanup_session(&session_binding_id, &session, &session_live);",
            "        (void)swmo_failure(SWIFT_MOJO_FAILURE_INVALID_FRAME, request_id, \"unknown request\");",
            "        free(receive_storage);",
            "        free(send_storage);",
            "        return 1;",
            "    }",
        ]
        lines.append("}")
        _ = identity
        _ = inputGraph
        _ = limits
        return lines
    }

}

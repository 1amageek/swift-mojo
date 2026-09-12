import Foundation
import MojoRuntimeProtocolCore

/// Immutable admission result. It retains sources, never their borrowed pointers.
package struct MojoRuntimePreparedInvocation: Sendable {
    package struct CopiedRegion: Sendable {
        package let owner: MojoReadOnlyBuffer
        package let payloadOffset: UInt64
    }

    package let metadata: MojoRuntimeResourceInvocation
    package let control: Data
    package let owners: [MojoReadOnlyBuffer]
    package let copiedRegions: [CopiedRegion]
    package let sharedDescriptors: [Int32]
    package let retainedByteCount: UInt64

    package init(
        bindingID: UInt64, argumentSchema: [UInt8], arguments: Data,
        inputs: [MojoBufferView], outputs: [MojoRuntimeOutputCapacity],
        limits: MojoRuntimeResourceLimits
    ) throws {
        guard inputs.count <= Int(limits.maximumInputs),
              outputs.count <= Int(limits.maximumOutputs),
              arguments.count <= Int(limits.maximumArgumentBytes) else {
            throw MojoRuntimeBufferError.countLimitExceeded
        }
        var owners: [MojoReadOnlyBuffer] = []
        var indices: [ObjectIdentifier: Int] = [:]
        var alignments: [UInt64] = []
        for view in inputs {
            let identity = ObjectIdentifier(view.buffer)
            let alignment = view.elementType.wireType.byteWidth
            if let index = indices[identity] {
                alignments[index] = max(alignments[index], alignment)
            } else {
                indices[identity] = owners.count
                owners.append(view.buffer)
                alignments.append(alignment)
            }
        }

        var copiedRegions: [CopiedRegion] = []
        var descriptors: [Int32] = []
        var locations: [(kind: MojoRuntimeBufferStorageKind, ordinal: UInt32, offset: UInt64)] = []
        var copiedBytes: UInt64 = 0
        var retainedBytes: UInt64 = 0
        for index in owners.indices {
            let owner = owners[index]
            let bytes = UInt64(owner.byteCount)
            let (retained, retainedOverflow) = retainedBytes.addingReportingOverflow(bytes)
            guard !retainedOverflow else { throw MojoRuntimeBufferError.extentOverflow }
            retainedBytes = retained
            switch owner.storage {
            case .host:
                let alignment = alignments[index]
                let padding = (alignment - copiedBytes % alignment) % alignment
                let (offset, paddingOverflow) = copiedBytes.addingReportingOverflow(padding)
                let (end, extentOverflow) = offset.addingReportingOverflow(bytes)
                guard !paddingOverflow, !extentOverflow else {
                    throw MojoRuntimeBufferError.extentOverflow
                }
                copiedBytes = end
                copiedRegions.append(CopiedRegion(owner: owner, payloadOffset: offset))
                locations.append((.copied, UInt32.max, offset))
            case .shared(let descriptor, let kind, _):
                // Input count was bounded to UInt16 before the owner table grew.
                locations.append((kind, UInt32(descriptors.count), 0))
                descriptors.append(descriptor)
            }
        }
        var views: [MojoRuntimeBufferDescriptor] = []
        views.reserveCapacity(inputs.count)
        for view in inputs {
            guard let index = indices[ObjectIdentifier(view.buffer)] else {
                preconditionFailure("Every input owner was indexed before descriptor construction")
            }
            let location = locations[index]
            views.append(try MojoRuntimeBufferDescriptor(
                storage: location.kind, element: view.elementType.wireType,
                handleOrdinal: location.ordinal,
                regionByteCount: UInt64(view.buffer.byteCount),
                viewByteOffset: view.byteOffset, payloadOffset: location.offset,
                dimensions: view.dimensions, byteStrides: view.byteStrides,
                limits: limits.buffer
            ))
        }
        let metadata = try MojoRuntimeResourceInvocation(
            bindingID: bindingID, argumentSchema: argumentSchema, arguments: arguments,
            inputs: views, outputs: outputs, limits: limits
        )
        self.metadata = metadata
        self.control = metadata.encodedControl()
        self.owners = owners
        self.copiedRegions = copiedRegions
        self.sharedDescriptors = descriptors
        self.retainedByteCount = retainedBytes
    }
}

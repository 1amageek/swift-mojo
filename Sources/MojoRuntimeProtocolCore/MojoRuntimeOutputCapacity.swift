package struct MojoRuntimeOutputCapacity: Equatable, Sendable {
    package let element: MojoRuntimeElementType
    package let maximumElementCount: UInt64
    package let maximumByteCount: UInt64

    package init(
        element: MojoRuntimeElementType, maximumElementCount: UInt64
    ) throws(MojoRuntimeBufferError) {
        let (bytes, overflow) =
            maximumElementCount.multipliedReportingOverflow(by: element.byteWidth)
        guard !overflow, bytes <= UInt64(Int.max) else { throw .extentOverflow }
        self.element = element
        self.maximumElementCount = maximumElementCount
        self.maximumByteCount = bytes
    }
}

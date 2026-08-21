public protocol MojoFloat32Buffer: MojoSessionResource {
    var elementCount: UInt64 { get }
    var byteCount: UInt64 { get }
    var device: MojoDeviceKind { get }
    var memoryKind: MojoBufferMemoryKind { get }

    func copy(from source: borrowing [Float]) throws
    func copy(into destination: inout [Float]) throws
}

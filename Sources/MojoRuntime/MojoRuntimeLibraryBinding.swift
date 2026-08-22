public enum MojoRuntimeLibraryBindingSignature: String, Codable, Equatable,
    Hashable, Sendable
{
    case int32Binary
    case borrowedFloat32Buffer
    case borrowedMutableFloat32Buffers
    case borrowedMutableFloat64Buffers
    case runtimeSessionFactory
    case sessionFloat32BufferFactory
    case sessionBorrowedMutableFloat32Buffers
}

public struct MojoRuntimeLibraryBinding: Codable, Equatable, Sendable {
    public let bindingID: UInt64
    public let functionName: String
    public let signature: MojoRuntimeLibraryBindingSignature
    public let sessionFactoryFunctionName: String?

    public init(
        bindingID: UInt64,
        functionName: String,
        signature: MojoRuntimeLibraryBindingSignature,
        sessionFactoryFunctionName: String? = nil
    ) {
        self.bindingID = bindingID
        self.functionName = functionName
        self.signature = signature
        self.sessionFactoryFunctionName = sessionFactoryFunctionName
    }
}

import MojoRuntimeProtocolCore

public enum MojoRuntimeWorkerBindingSignature: String, Equatable, Hashable,
    Sendable
{
    case int32Binary
    case borrowedFloat32Buffer
    case borrowedMutableFloat32Buffers
    case borrowedMutableFloat64Buffers
    case runtimeSessionFactory
    case sessionFloat32BufferFactory
    case sessionBorrowedMutableFloat32Buffers
    case resourceInvocation
}

public struct MojoRuntimeWorkerBinding: Equatable, Sendable {
    public let bindingID: UInt64
    public let functionName: String
    public let signature: MojoRuntimeWorkerBindingSignature
    package let resourceSignature: MojoRuntimeResourceSignature?
    public let sessionFactoryFunctionName: String?

    package init(
        bindingID: UInt64,
        functionName: String,
        signature: MojoRuntimeWorkerBindingSignature,
        sessionFactoryFunctionName: String?,
        resourceSignature: MojoRuntimeResourceSignature? = nil
    ) {
        self.bindingID = bindingID
        self.functionName = functionName
        self.signature = signature
        self.resourceSignature = resourceSignature
        self.sessionFactoryFunctionName = sessionFactoryFunctionName
    }
}

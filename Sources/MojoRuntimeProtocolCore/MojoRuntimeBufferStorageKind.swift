/// Storage capability identifiers, not proof of native resource admission.
package enum MojoRuntimeBufferStorageKind: UInt16, Sendable {
    case copied = 1
    case sharedFile = 2
    case dmaBuf = 3
}

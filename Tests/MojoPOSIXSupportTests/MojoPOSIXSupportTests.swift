import Foundation
import MojoPOSIXSupport
import Testing

@Suite("POSIX platform support")
struct MojoPOSIXSupportTests {
    @Test(.timeLimit(.minutes(1)))
    func exclusiveLockRejectsASecondOwnerUntilRelease() throws {
        let lockURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let first = try MojoPOSIXSupport.openLockFile(path: lockURL.path)
        let second = try MojoPOSIXSupport.openLockFile(path: lockURL.path)
        defer {
            for descriptor in [first, second] {
                do {
                    try MojoPOSIXSupport.closeFile(descriptor)
                } catch {
                    Issue.record("Failed to close lock fixture: \(error)")
                }
            }
            do {
                try FileManager.default.removeItem(at: lockURL)
            } catch {
                Issue.record("Failed to remove lock fixture: \(error)")
            }
        }

        try MojoPOSIXSupport.lockExclusive(first)
        #expect(try !MojoPOSIXSupport.tryLockExclusive(second))
        try MojoPOSIXSupport.unlock(first)
        #expect(try MojoPOSIXSupport.tryLockExclusive(second))
        try MojoPOSIXSupport.unlock(second)
    }

    @Test(.timeLimit(.minutes(1)))
    func waitStatusDecodingMatchesExitedAndSignaledProcesses() {
        #expect(MojoPOSIXSupport.exitStatus(from: 42 << 8) == 42)
        #expect(MojoPOSIXSupport.exitStatus(from: 15) == 143)
    }

    @Test(.timeLimit(.minutes(1)))
    func currentHostProvidesTheRequiredPOSIXContract() {
        #expect(MojoPOSIXSupport.isSupported)
    }
}

import Testing
import Foundation

/// Tests container recreation from persisted state after daemon restart
/// This validates Task 2 of Phase 3.7: Container Recreation
@Suite("Container Recreation - CLI Integration", .serialized)
struct ContainerRecreationTests {
    static let socketPath = "/tmp/arca-test-recreation.sock"
    static let testImage = "alpine:latest"
    static let logFile = "/tmp/arca-recreation-test.log"

    /// Test that containers can be started after daemon restart (recreation from persisted state)
    @Test("Container can be started after daemon restart (recreates Container object)")
    func containerStartAfterRestart() async throws {
        let daemonPID1 = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID1) }

        // Pull image if needed
        _ = try docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create and start a container
        let containerID = try docker("run -d --name test-start-recreation alpine sleep 300", socketPath: Self.socketPath).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!containerID.isEmpty, "Container ID should not be empty")

        // Verify it's running
        let ps1 = try docker("ps", socketPath: Self.socketPath)
        #expect(ps1.contains("test-start-recreation"), "Container should be running")

        // Stop the daemon (simulates crash - container state persists in database)
        try stopDaemon(pid: daemonPID1)

        // Start daemon again
        let daemonPID2 = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID2) }

        // Container should exist in metadata but state should be "exited" (VM is gone)
        let psAll = try docker("ps -a", socketPath: Self.socketPath)
        #expect(psAll.contains("test-start-recreation"), "Container should exist in metadata")
        #expect(psAll.contains("Exited"), "Container should be exited (VM was destroyed)")

        // THE CRITICAL TEST: docker start should recreate the Container object and start it
        let startOutput = try docker("start test-start-recreation", socketPath: Self.socketPath)
        #expect(startOutput.contains("test-start-recreation"), "Start should succeed")

        // Verify container is now running
        let ps2 = try docker("ps", socketPath: Self.socketPath)
        #expect(ps2.contains("test-start-recreation"), "Container should be running after recreation")
        #expect(ps2.contains("Up"), "Container status should be Up")

        // Clean up
        _ = try? docker("rm -f test-start-recreation", socketPath: Self.socketPath)
    }

    /// Test that containers can be removed after daemon restart (database-only removal)
    @Test("Container can be removed after daemon restart (database-only)")
    func containerRemoveAfterRestart() async throws {
        let daemonPID1 = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID1) }

        // Create a container (don't start it)
        _ = try docker("create --name test-remove-recreation alpine sleep 300", socketPath: Self.socketPath)

        // Verify it exists
        let ps1 = try docker("ps -a", socketPath: Self.socketPath)
        #expect(ps1.contains("test-remove-recreation"), "Container should exist")

        // Stop the daemon
        try stopDaemon(pid: daemonPID1)

        // Start daemon again
        let daemonPID2 = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPID2) }

        // Container should exist in metadata
        let ps2 = try docker("ps -a", socketPath: Self.socketPath)
        #expect(ps2.contains("test-remove-recreation"), "Container should exist after restart")

        // THE CRITICAL TEST: docker rm should work even though Container object doesn't exist
        let rmOutput = try docker("rm -f test-remove-recreation", socketPath: Self.socketPath)
        #expect(rmOutput.contains("test-remove-recreation"), "Remove should succeed")

        // Verify container is gone
        let ps3 = try docker("ps -a", socketPath: Self.socketPath)
        #expect(!ps3.contains("test-remove-recreation"), "Container should be removed")
    }
}

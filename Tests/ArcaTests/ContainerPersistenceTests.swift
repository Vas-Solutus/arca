import Testing
import Foundation

/// Container Persistence Tests
/// Tests container state persistence across daemon restarts by:
/// 1. Starting Arca daemon
/// 2. Running actual Docker CLI commands
/// 3. Stopping daemon
/// 4. Starting daemon again
/// 5. Verifying state persisted
///
/// Prerequisites:
/// - Docker CLI installed
/// - Arca built at .build/debug/Arca
///
/// Note: Tests run serially to avoid race conditions
@Suite("Container Persistence - CLI Integration", .serialized)
struct ContainerPersistenceTests {

    static let socketPath = "/tmp/arca-test-persistence.sock"
    static let testImage = "alpine:latest"
    static let logFile = "/tmp/arca-persistence-test.log"

    // MARK: - Tests

    @Test("Container metadata persists across daemon restart")
    func containerMetadataPersists() async throws {
        // Start daemon
        let daemonPid = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPid) }

        // Pull image
        _ = try docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create container
        let containerName = "persist-test-metadata-\(Date().timeIntervalSince1970)"
        _ = try docker("create --name \(containerName) \(Self.testImage) echo hello", socketPath: Self.socketPath)

        // Get metadata before restart
        let imageBefore = try docker("inspect \(containerName) --format '{{.Image}}'", socketPath: Self.socketPath)
        let stateBefore = try docker("inspect \(containerName) --format '{{.State.Status}}'", socketPath: Self.socketPath)
        let createdBefore = try docker("inspect \(containerName) --format '{{.Created}}'", socketPath: Self.socketPath)

        print("Before restart: State=\(stateBefore), Image=\(imageBefore)")

        // Stop daemon
        try stopDaemon(pid: daemonPid)

        // Start daemon again
        let daemonPid2 = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPid2) }

        // Verify container still exists
        let containers = try docker("ps -a --format '{{.Names}}'", socketPath: Self.socketPath)
        #expect(containers.contains(containerName), "Container disappeared after restart")

        // Get metadata after restart
        let imageAfter = try docker("inspect \(containerName) --format '{{.Image}}'", socketPath: Self.socketPath)
        let stateAfter = try docker("inspect \(containerName) --format '{{.State.Status}}'", socketPath: Self.socketPath)
        let createdAfter = try docker("inspect \(containerName) --format '{{.Created}}'", socketPath: Self.socketPath)

        print("After restart: State=\(stateAfter), Image=\(imageAfter)")

        // Verify metadata matches
        #expect(imageBefore == imageAfter, "Image changed after restart")
        #expect(stateBefore == stateAfter, "State changed after restart")
        #expect(createdBefore == createdAfter, "Created timestamp changed after restart")

        // Cleanup
        _ = try? docker("rm -f \(containerName)", socketPath: Self.socketPath)
    }

    @Test("Container can be started after daemon restart")
    func containerStartsAfterRestart() async throws {
        let daemonPid = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPid) }

        _ = try docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create container (not started)
        let containerName = "persist-test-start-\(Date().timeIntervalSince1970)"
        _ = try docker("create --name \(containerName) \(Self.testImage) echo 'test output'", socketPath: Self.socketPath)

        // Stop daemon
        try stopDaemon(pid: daemonPid)

        // Start daemon again
        let daemonPid2 = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPid2) }

        // Start the container
        _ = try docker("start \(containerName)", socketPath: Self.socketPath)

        // Wait for it to complete
        try await Task.sleep(for: .seconds(1.0))

        // Check state is exited (echo command finishes)
        let state = try docker("inspect \(containerName) --format '{{.State.Status}}'", socketPath: Self.socketPath)
        #expect(state == "exited", "Container should have exited after running echo command")

        // Cleanup
        _ = try? docker("rm -f \(containerName)", socketPath: Self.socketPath)
    }

    @Test("Multiple containers persist across restart")
    func multipleContainersPersist() async throws {
        let daemonPid = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPid) }

        _ = try docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create multiple containers
        let timestamp = Date().timeIntervalSince1970
        let names = [
            "persist-multi-1-\(timestamp)",
            "persist-multi-2-\(timestamp)",
            "persist-multi-3-\(timestamp)"
        ]

        for name in names {
            _ = try docker("create --name \(name) \(Self.testImage) sleep 10", socketPath: Self.socketPath)
        }

        // Count containers before restart
        let countBefore = try docker("ps -a --format '{{.Names}}'", socketPath: Self.socketPath)
            .components(separatedBy: "\n")
            .filter { $0.hasPrefix("persist-multi-") }
            .count

        print("Containers before restart: \(countBefore)")

        // Restart daemon
        try stopDaemon(pid: daemonPid)
        let daemonPid2 = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPid2) }

        // Count containers after restart
        let countAfter = try docker("ps -a --format '{{.Names}}'", socketPath: Self.socketPath)
            .components(separatedBy: "\n")
            .filter { $0.hasPrefix("persist-multi-") }
            .count

        print("Containers after restart: \(countAfter)")

        #expect(countBefore == countAfter, "Container count changed after restart")
        #expect(countAfter == 3, "Expected 3 containers")

        // Verify all containers still exist by name
        for name in names {
            let containers = try docker("ps -a --format '{{.Names}}'", socketPath: Self.socketPath)
            #expect(containers.contains(name), "Container \(name) missing after restart")
        }

        // Cleanup
        for name in names {
            _ = try? docker("rm -f \(name)", socketPath: Self.socketPath)
        }
    }

    @Test("Container removal persists across restart")
    func containerRemovalPersists() async throws {
        let daemonPid = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPid) }

        _ = try docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create two containers
        let timestamp = Date().timeIntervalSince1970
        let keepName = "persist-keep-\(timestamp)"
        let removeName = "persist-remove-\(timestamp)"

        _ = try docker("create --name \(keepName) \(Self.testImage) sleep 10", socketPath: Self.socketPath)
        _ = try docker("create --name \(removeName) \(Self.testImage) sleep 10", socketPath: Self.socketPath)

        // Remove one container
        _ = try docker("rm \(removeName)", socketPath: Self.socketPath)

        // Verify removed
        let afterRemoval = try docker("ps -a --format '{{.Names}}'", socketPath: Self.socketPath)
        #expect(!afterRemoval.contains(removeName), "Container should be removed")

        // Restart daemon
        try stopDaemon(pid: daemonPid)
        let daemonPid2 = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPid2) }

        // Verify removal persisted
        let afterRestart = try docker("ps -a --format '{{.Names}}'", socketPath: Self.socketPath)
        #expect(!afterRestart.contains(removeName), "Removed container reappeared after restart")
        #expect(afterRestart.contains(keepName), "Kept container disappeared after restart")

        // Cleanup
        _ = try? docker("rm -f \(keepName)", socketPath: Self.socketPath)
    }

    @Test("Container exit code persists across restart")
    func exitCodePersists() async throws {
        var currentPid = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: currentPid) }

        _ = try docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create and run container with specific exit code (detached, then wait)
        let containerName = "persist-exitcode-\(Date().timeIntervalSince1970)"
        _ = try docker("run -d --name \(containerName) \(Self.testImage) sh -c 'exit 42'", socketPath: Self.socketPath)

        // Wait for container to exit
        _ = try docker("wait \(containerName)", socketPath: Self.socketPath)

        // Get exit code before restart
        let exitCodeBefore = try docker("inspect \(containerName) --format '{{.State.ExitCode}}'", socketPath: Self.socketPath)
        print("Exit code before restart: \(exitCodeBefore)")

        // Restart daemon
        try stopDaemon(pid: currentPid)
        currentPid = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)

        // Get exit code after restart
        let exitCodeAfter = try docker("inspect \(containerName) --format '{{.State.ExitCode}}'", socketPath: Self.socketPath)
        print("Exit code after restart: \(exitCodeAfter)")

        #expect(exitCodeBefore == exitCodeAfter, "Exit code changed after restart")
        #expect(exitCodeAfter == "42", "Exit code should be 42")

        // Cleanup
        _ = try? docker("rm -f \(containerName)", socketPath: Self.socketPath)
    }

    @Test("Container state database exists and is readable")
    func stateDatabaseExists() async throws {
        let daemonPid = try startDaemon(socketPath: Self.socketPath, logFile: Self.logFile)
        defer { try? stopDaemon(pid: daemonPid) }

        _ = try docker("pull \(Self.testImage)", socketPath: Self.socketPath)

        // Create a container
        let containerName = "persist-db-test-\(Date().timeIntervalSince1970)"
        _ = try docker("create --name \(containerName) \(Self.testImage) echo test", socketPath: Self.socketPath)

        // Check database exists
        let dbPath = "\(NSHomeDirectory())/.arca/state.db"
        #expect(FileManager.default.fileExists(atPath: dbPath), "State database should exist at \(dbPath)")

        // Verify database contains container (simple SQLite query)
        let count = try shell("sqlite3 \(dbPath) 'SELECT COUNT(*) FROM containers;'")
        let containerCount = Int(count) ?? 0
        #expect(containerCount > 0, "Database should contain at least one container")

        // Cleanup
        _ = try? docker("rm -f \(containerName)", socketPath: Self.socketPath)
    }
}

